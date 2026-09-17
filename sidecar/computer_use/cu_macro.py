# VetarAI - Local-first multi-agent orchestration application
# Copyright (C) 2026 zero11924065-dev
#
# This file is part of VetarAI.
#
# VetarAI is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# VetarAI is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with VetarAI. If not, see <https://www.gnu.org/licenses/>.
"""0.4.32（CU 三期 P2，REQ-FUT-006）任务宏：录制 / 保存 / 列表 / 回放 / 删除。

三期口径（执行计划 E4，用户可异议但未异议，按此执行）：
- **录制** = 录制【Agent 自己发起的 CU 动作序列】：executor 各动作执行成功后
  经 `_maybe_record` 挂钩追加 step（语义化落盘：app + element role/title/frame + 坐标）。
  ⛔ 不是系统级用户操作录制（AXObserver/事件 tap 长驻监听）——那是范围外另一量级需求。
- **回放** = 逐步 element 语义重放：click 类按 step.app + element.role/title 经
  app_elements(depth≤2) 找匹配元素 → 点其 frame 中心（窗口挪位仍命中）；
  匹配不到回落 step 原像素坐标（走 executor 现有点击链）；type/key 类直接重放 payload。
- **跨应用编排** = 宏内天然多 app 步骤序列（每 step 自带 app 语义）。

关键决策（计划 R4 拍板）：回放时目标 app 未运行 / 窗口未开 → 该步错误返回并【中止】，
报错带步骤号（不做跳过策略——静默跳过会让后续步骤打在错误的界面上，比中止更危险）。

安全前提：回放执行复用 executor（真实 HID 事件，与录制同源同权限）。真实键鼠是
【独占资源】——同一时刻只允许一个回放运行（并发回放会互相踩坐标/抢焦点），
start_replay 用 _REPLAY_BUSY 守卫，忙时 422。

存储：`{data_root}/cu_macros/<macro_id>.json`，tmp + os.replace 原子写
（config/store.py:_save、model_packs/store.py:write_registry 同款先例）。
"""
from __future__ import annotations

import json
import os
import re
import threading
import time
import uuid
from datetime import datetime
from pathlib import Path
from typing import Any

# ── 协议常量（非用户可配）────────────────────────────────────────────────
TITLE_MAX = 80                    # element.title 落盘截断（与 executor element_locate 同款防爆）
ROLE_MAX = 40
REPLAY_STEP_INTERVAL = 0.3        # 回放步间间隔（秒；给界面留出响应时间，测试可置 0）
RUNS_KEPT = 50                    # 回放运行记录内存保留上限（进程级，重启无意义）
_MACRO_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$")
_CLICK_MAP = {"click": ("left", 1), "double_click": ("left", 2), "right_click": ("right", 1)}
# app_elements 失败原因中出现这些子串 = 目标 app 未运行 / 窗口未开（R4 中止条件）
_APP_MISSING_KEYS = ("app_not_found", "无窗口")


def _now() -> str:
    return datetime.now().isoformat(timespec="seconds")


def _slug(name: str) -> str:
    """名称 → id 用 slug（小写字母/数字/-；CJK 等非 ASCII 折叠为 -，空则 macro）。"""
    s = re.sub(r"[^a-z0-9]+", "-", str(name or "").lower()).strip("-")
    return (s or "macro")[:24]


def _new_macro_id(name: str) -> str:
    """macro_id：时间戳 + 名称 slug + uuid 短后缀（compactor 时间戳先例 + uuid 短型先例）。"""
    return f"cu-{datetime.now().strftime('%Y%m%d-%H%M%S')}-{_slug(name)}-{uuid.uuid4().hex[:4]}"


def valid_macro_id(macro_id: Any) -> bool:
    """id 合法性（防路径穿越：DELETE/replay 的 {id} 来自 URL，不可信）。"""
    return isinstance(macro_id, str) and bool(_MACRO_ID_RE.fullmatch(macro_id))


# ══════════ 存储（原子写）══════════════════════════════════════════════

def _macros_dir() -> Path:
    from sidecar.config import data_root
    d = data_root() / "cu_macros"
    d.mkdir(parents=True, exist_ok=True)
    return d


def _macro_path(macro_id: str) -> Path | None:
    if not valid_macro_id(macro_id):
        return None
    return _macros_dir() / f"{macro_id}.json"


_STORE_LOCK = threading.RLock()


def save_macro(macro: dict[str, Any]) -> Path:
    """原子写宏 JSON：tmp + os.replace（写一半被 kill 不得留下半截文件）。
    写盘失败抛异常——调用方（stop_recording）转成 ok:False，绝不静默丢宏。"""
    with _STORE_LOCK:
        path = _macros_dir() / f"{macro['id']}.json"
        tmp = path.with_name(path.name + ".tmp")
        tmp.write_text(json.dumps(macro, ensure_ascii=False, indent=2), encoding="utf-8")
        os.replace(str(tmp), str(path))      # 同目录原子替换
        return path


def load_macro(macro_id: str) -> dict[str, Any] | None:
    """读宏；id 非法 / 文件缺失 / JSON 损坏 → None（调用方按 404 处理）。"""
    path = _macro_path(macro_id)
    if path is None:
        return None
    try:
        if path.exists():
            data = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(data, dict) and isinstance(data.get("steps"), list):
                return data
    except Exception:
        pass
    return None


def list_macros() -> list[dict[str, Any]]:
    """列表（摘要：id/name/created_at/steps 数，按 created_at 排序）。损坏文件跳过。"""
    out: list[dict[str, Any]] = []
    try:
        files = sorted(_macros_dir().glob("*.json"))
    except Exception:
        return out
    for f in files:
        try:
            data = json.loads(f.read_text(encoding="utf-8"))
            if not isinstance(data, dict):
                continue
            steps = data.get("steps")
            out.append({"id": str(data.get("id") or f.stem),
                        "name": str(data.get("name") or ""),
                        "created_at": str(data.get("created_at") or ""),
                        "steps": len(steps) if isinstance(steps, list) else 0})
        except Exception:
            continue                 # 损坏文件不阻断列表（model_packs read_registry 同款）
    out.sort(key=lambda m: (m["created_at"], m["id"]))
    return out


def delete_macro(macro_id: str) -> bool:
    """删除宏文件。id 非法 / 不存在 → False（端点按 404）。"""
    path = _macro_path(macro_id)
    if path is None:
        return False
    try:
        path.unlink()
        return True
    except FileNotFoundError:
        return False
    except Exception:
        return False


# ══════════ 录制器（进程级单例，线程安全）═══════════════════════════════
# 语义：录制的是 Agent 经 executor 发起的动作；executor 在每个动作【成功后】调
# record_step（失败动作不落宏——回放一个当时就没成功的动作无意义）。
_REC: dict[str, Any] | None = None     # {"name","started_at","steps":[...]}；None=未录制
_REC_LOCK = threading.RLock()


def is_recording() -> bool:
    with _REC_LOCK:
        return _REC is not None


def start_recording(name: str) -> dict[str, Any]:
    """开始录制。已在录制 / 名称为空 → ok:False（端点按 422）。"""
    nm = str(name or "").strip()
    if not nm:
        return {"ok": False, "error": "bad_arg: 宏名称不能为空"}
    global _REC
    with _REC_LOCK:
        if _REC is not None:
            return {"ok": False, "error": (
                f"already_recording: 正在录制宏「{_REC['name']}」，请先停止当前录制")}
        _REC = {"name": nm[:TITLE_MAX], "started_at": _now(), "steps": []}
        return {"ok": True, "name": _REC["name"]}


def record_step(step: dict[str, Any]) -> bool:
    """executor 挂钩：追加一步。⛔ 绝不抛异常——录制是旁路，绝不能搞挂动作本身。

    step 输入：{action, x, y, app, element:{role,title,frame}|None, payload}；
    本函数补 seq/ts 并做截断防御（title≤80，与落盘契约一致）。
    """
    try:
        with _REC_LOCK:
            if _REC is None:
                return False
            el = step.get("element")
            if isinstance(el, dict):
                element = {"role": str(el.get("role") or "")[:ROLE_MAX],
                           "title": str(el.get("title") or "")[:TITLE_MAX],
                           "frame": el.get("frame")}
            else:
                element = None
            payload = step.get("payload")
            steps = _REC["steps"]
            steps.append({
                "seq": len(steps) + 1,
                "action": str(step.get("action") or ""),
                "x": step.get("x"),
                "y": step.get("y"),
                "app": str(step.get("app") or ""),
                "element": element,
                "payload": payload if isinstance(payload, dict) else {},
                "ts": _now(),
            })
            return True
    except Exception:
        return False


def stop_recording() -> dict[str, Any]:
    """停止录制并落盘。返回 {"ok": True, "macro": 完整宏 dict}；未在录制 → ok:False。"""
    global _REC
    with _REC_LOCK:
        if _REC is None:
            return {"ok": False, "error": "not_recording: 当前没有进行中的录制"}
        rec, _REC = _REC, None
    macro = {"id": _new_macro_id(rec["name"]),
             "name": rec["name"],
             "created_at": rec["started_at"],
             "steps": rec["steps"]}
    try:
        save_macro(macro)
    except Exception as e:
        return {"ok": False, "error": f"save_failed: 宏落盘失败（{type(e).__name__}: {e}）"}
    return {"ok": True, "macro": macro}


# ══════════ 回放（语义重放 + 失败回落像素 + R4 中止）═════════════════════

_RUNS: dict[str, dict[str, Any]] = {}  # run_id → 运行记录（进程级内存，重启无意义）
_RUN_LOCK = threading.RLock()
_REPLAY_BUSY = False                   # 真实键鼠独占守卫：同一时刻只允许一个回放


def get_run(run_id: str) -> dict[str, Any] | None:
    """回放状态查询（端点轮询用；同时步骤事件经 app_events 推送）。"""
    with _RUN_LOCK:
        r = _RUNS.get(str(run_id or ""))
        return dict(r) if r else None


def start_replay(macro_id: str) -> dict[str, Any]:
    """校验宏存在 → 登记 run → 后台线程回放。立即返回 run_id（异步，照 workflow
    engine 后台执行范式；⛔ 端点不能同步等回放——回放是秒级的真实键鼠操作）。"""
    if not valid_macro_id(macro_id):
        return {"ok": False, "error": "not_found"}
    macro = load_macro(macro_id)
    if macro is None:
        return {"ok": False, "error": "not_found"}
    global _REPLAY_BUSY
    with _RUN_LOCK:
        if _REPLAY_BUSY:
            return {"ok": False, "error": (
                "replay_busy: 已有回放进行中（真实键鼠是独占资源，并发回放会互相踩坐标），"
                "请等当前回放完成")}
        _REPLAY_BUSY = True
        run_id = f"run-{uuid.uuid4().hex[:12]}"
        _RUNS[run_id] = {
            "run_id": run_id, "macro_id": macro.get("id") or macro_id,
            "macro_name": macro.get("name") or "",
            "status": "running",            # running | done | error
            "started_at": _now(), "finished_at": "",
            "total": len(macro.get("steps") or []), "completed": 0,
            "failed_seq": None, "error": "", "steps": [],
        }
        while len(_RUNS) > RUNS_KEPT:       # 上限保护：挤掉最旧记录
            _RUNS.pop(next(iter(_RUNS)))
    th = threading.Thread(target=_replay_thread, args=(run_id, macro),
                          name=f"cu-macro-replay-{run_id}", daemon=True)
    th.start()
    return {"ok": True, "run_id": run_id}


def _replay_thread(run_id: str, macro: dict[str, Any]) -> None:
    """后台线程壳：执行 + 释放独占守卫 + 异常兜底（线程内异常不得静默吞掉状态）。"""
    global _REPLAY_BUSY
    try:
        with _RUN_LOCK:
            run = _RUNS.get(run_id)
        if run is not None:
            try:
                run_replay(run, macro)
            except Exception as e:
                run["status"] = "error"
                run["error"] = f"回放执行异常：{type(e).__name__}: {e}"
                run["finished_at"] = _now()
    finally:
        with _RUN_LOCK:
            _REPLAY_BUSY = False


def _push_step_event(run: dict[str, Any], macro: dict[str, Any], seq: int,
                     action: str, method: str, ok: bool) -> None:
    """每步经 app_events 推步骤事件（seq/step_action/命中方式/ok）。⛔ 绝不抛异常。

    ⚠️ 步骤的 CU 动作名只能放 step_action——notify(resource, action, ...) 的第二个
    位置参数就叫 action，再传 action= kwarg 会 TypeError（本函数吞异常→事件静默丢失，
    测试期实测踩中）。"""
    try:
        from sidecar.agent_engine import app_events as _ae
        _ae.notify(_ae.RESOURCE_CU_MACRO, "replay_step",
                   run_id=run.get("run_id") or "",
                   macro_id=str(macro.get("id") or ""),
                   seq=seq, step_action=action, method=method, ok=bool(ok))
    except Exception:
        pass


def _step_finish(run: dict[str, Any], macro: dict[str, Any], seq: int, action: str,
                 method: str, ok: bool, error: str = "") -> None:
    """登记一步结果 + 推事件（成功与失败同路径，保证事件序列完整）。"""
    run["steps"].append({"seq": seq, "action": action, "method": method,
                         "ok": bool(ok), "error": error})
    if ok:
        run["completed"] += 1
    _push_step_event(run, macro, seq, action, method, ok)


def _abort(run: dict[str, Any], macro: dict[str, Any], seq: int, action: str,
           method: str, reason: str) -> dict[str, Any]:
    """R4 拍板【默认中止】：登记失败步、报步骤号、不再执行后续步骤。

    为什么中止而非跳过：后续步骤的前提界面来自前面步骤的效果，静默跳过会把
    点击/输入打到错误的界面上（真实键鼠，误操作后果真实可见）——比中止危险得多。
    """
    _step_finish(run, macro, seq, action, method, False, reason[:200])
    run["status"] = "error"
    run["failed_seq"] = seq
    run["error"] = f"第 {seq} 步（{action}）失败：{reason}。已中止，后续步骤未执行。"
    run["finished_at"] = _now()
    return run


def _relocate(step: dict[str, Any]) -> tuple[str, Any, Any, str]:
    """click 类步骤的语义重定位。返回 (method, x, y, err)：
      - "element"：app_elements(depth≤2) 匹配到 role+title 一致的元素 → 其 frame 中心
        （窗口挪位仍命中——这正是三期相对一期纯坐标的核心收益）；
      - "pixel_fallback"：录制时本无元素语义 / 枚举失败 / 匹配不到 → step 原像素坐标；
      - "abort"：目标 app 未运行 / 窗口未开（R4：该步错误并中止，err 为可读原因）。
    """
    el = step.get("element") or {}
    app = str(step.get("app") or "")
    ox, oy = step.get("x"), step.get("y")
    if not el or not app:
        return ("pixel_fallback", ox, oy, "")      # 录制时未命中元素，只能按像素重放
    from sidecar.computer_use import ax_element as _axe
    els = _axe.app_elements(app, depth=2)
    if not els:
        err = _axe.LAST_ERROR or ""
        if any(k in err for k in _APP_MISSING_KEYS):
            # ⛔ MUTATE锚点：app 未运行/无窗口必须中止（R4），不得回落像素乱点
            return ("abort", None, None, f"目标应用「{app}」未运行或没有窗口（{err}）")
        # ⛔ MUTATE锚点：枚举失败（权限/超时等）回落像素，不阻断回放
        return ("pixel_fallback", ox, oy, "")
    role = str(el.get("role") or "")
    title = str(el.get("title") or "")
    cand = [e for e in els if str(e.get("role") or "") == role]
    if title:
        # ⛔ MUTATE锚点：title 必须参与匹配（同 role 多元素时靠 title 区分，否则点错按钮）
        cand = [e for e in cand if str(e.get("title") or "") == title]
    for e in cand:
        fr = e.get("frame")
        if fr and len(fr) == 4 and fr[2] > 0 and fr[3] > 0:
            return ("element", fr[0] + fr[2] / 2.0, fr[1] + fr[3] / 2.0, "")
    # ⛔ MUTATE锚点：匹配不到回落 step 原像素坐标（计划 E4 既定回落路径）
    return ("pixel_fallback", ox, oy, "")


def run_replay(run: dict[str, Any], macro: dict[str, Any]) -> dict[str, Any]:
    """回放同步核心（start_replay 的后台线程与测试都调它）。

    逐步执行：click 类语义重定位 → executor 现有动作链（含二期校正）；type/key 类
    直接重放 payload。任一步失败即 _abort 中止（报步骤号）；每步推事件。
    """
    from sidecar.computer_use import executor as _ex
    steps = macro.get("steps") or []
    run["total"] = len(steps)
    for st in steps:
        seq = int(st.get("seq") or 0)
        action = str(st.get("action") or "")
        try:
            if action in _CLICK_MAP:
                method, x, y, err = _relocate(st)
                if method == "abort":
                    return _abort(run, macro, seq, action, method, err)
                btn, n = _CLICK_MAP[action]
                r = _ex.mouse_click(x, y, btn, n)
            elif action == "type":
                method = "payload"
                r = _ex.keyboard_type(str((st.get("payload") or {}).get("text") or ""))
            elif action == "key":
                method = "payload"
                r = _ex.keyboard_hotkey(str((st.get("payload") or {}).get("keys") or ""))
            else:
                return _abort(run, macro, seq, action or "?", "",
                              f"unknown_action: 不认识的宏动作 {action!r}（宏文件可能损坏）")
        except Exception as e:
            return _abort(run, macro, seq, action, "", f"{type(e).__name__}: {e}")
        if not (r or {}).get("ok"):
            return _abort(run, macro, seq, action, method,
                          str((r or {}).get("error") or "动作执行失败"))
        _step_finish(run, macro, seq, action, method, True)
        time.sleep(REPLAY_STEP_INTERVAL)
    run["status"] = "done"
    run["finished_at"] = _now()
    return run
