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
"""0.4.33（CU 三期 R1）专项回归：任务宏接入 Agent 工具组。

背景：0.4.32 宏只有 HTTP 层（/api/cu-macros/*）供前端用，Agent 完全感知不到——
用户说「把这个动作录成宏」时 Agent 自由发挥写 shell 脚本。R1 把宏能力接进
CU 工具组：cu_macro_record（start/stop）/ cu_macro_replay（id|name）/ cu_macro_list。

⛔ 测试铁律（同 test_computer_use.py / test_cu_macro.py）：**绝不允许真实点击/输入
用户屏幕**——回放用例把 executor 三动作与 ax_element.app_elements 全部换成捕获桩，
断言【调用参数】而非真实效果；防线（白名单/权限预检）钉在 sidecar.computer_use
包命名空间（与路由层导入点一致）。

契约捕获方式：路由层对宏模块函数是【原样透传】，故用模块级间谍包装
cm.start_recording / stop_recording / start_replay，逐字断言路由拿到的字典
（tool_result 事件只有 ok/summary/error 摘要，不含完整 result）。

变异测试机制（MUTATE=1|2|3 .venv/bin/python -m sidecar.computer_use.test_cu_macro_agent）：
  1 = 同名宏拒绝猜测失效（ambiguous 守卫变成总是猜第一个 → C 组灭）
  2 = replay not_found 翻译失效（422 语义不变 Agent 可读文本 → C 组灭）
  3 = 排除元组漏登 cu_macro_*（result 被 registry 二次执行覆盖 → B/C/D 组灭）
"""
import asyncio
import importlib
import json
import os
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

PASS = 0
FAIL = 0
FAILURES = []


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"PASS  {name}")
    else:
        FAIL += 1
        FAILURES.append(name)
        print(f"FAIL  {name}  {detail}")


# ══════════ 变异机制（照 test_cu_macro.py 范式：内存备份 + finally 还原 + reload）══
MUTATE = int(os.environ.get("MUTATE", "0"))
_BACKUP: dict[str, tuple[Path, str]] = {}


def _mutate_file(path: Path, old: str, new: str, tag: str) -> None:
    s = path.read_text(encoding="utf-8")
    _BACKUP[tag] = (path, s)
    patched = s.replace(old, new)
    assert patched != s, f"变异 {MUTATE} 未命中 {path.name} 源码锚点，测试无效"
    path.write_text(patched, encoding="utf-8")


def _apply_mutation() -> None:
    if not MUTATE:
        return
    import sidecar.agent_engine.loop as lp
    src = Path(lp.__file__)
    if MUTATE == 1:
        # 同名多个也猜第一个（回放真实键鼠，猜错后果可见）
        _mutate_file(src,
                     "                                if len(_matches) == 1:",
                     "                                if len(_matches) >= 1:  # 变异1：同名多个也猜",
                     "lp")
    elif MUTATE == 2:
        # not_found 不翻译成 Agent 可读文本（422 语义裸奔）
        _mutate_file(src,
                     '                                                if _err_m == "not_found":',
                     '                                                if _err_m == "never_match":  # 变异2',
                     "lp")
    elif MUTATE == 3:
        # 排除元组漏登 cu_macro_* → result 被 _run_tool 二次执行覆盖
        _mutate_file(src,
                     '                                  "keyboard_type", "keyboard_hotkey", "element_locate",\n'
                     '                                  "cu_macro_record", "cu_macro_replay", "cu_macro_list"):',
                     '                                  "keyboard_type", "keyboard_hotkey", "element_locate"):',
                     "lp")
    else:
        raise SystemExit(f"未知变异编号 {MUTATE}（支持 1|2|3）")
    importlib.reload(lp)


def _restore() -> None:
    if not MUTATE or not _BACKUP:
        return
    try:
        for path, s in _BACKUP.values():
            path.write_text(s, encoding="utf-8")
    finally:
        _BACKUP.clear()
        import sidecar.agent_engine.loop as lp
        importlib.reload(lp)


def isolate_all(prefix: str) -> Path:
    """config / store / warehouse / skills 全部重定向到临时目录（照 test_cu_macro.py 同款）。"""
    tmp = Path(tempfile.mkdtemp(prefix=prefix))
    os.environ["VETARAI_DATA_ROOT"] = str(tmp)
    import sidecar.config.store as cs
    cs.get_config_path = lambda: tmp / "config.json"
    cs._MEM = dict(cs.DEFAULT_CONFIG)
    cs._MEM["data_root"] = str(tmp)
    import sidecar.storage.store as store
    store.PROJECTS_ROOT = tmp / "projects"
    store.PROJECTS_ROOT.mkdir(parents=True, exist_ok=True)
    store._GDB = store.PROJECTS_ROOT / "_global.db"
    from sidecar.knowledge import warehouse as wh
    wh._DATA_ROOT_OVERRIDE = tmp
    wh._INDEX_DB_PATH = tmp / "knowledge" / "index.db"
    (tmp / "knowledge").mkdir(parents=True, exist_ok=True)
    import sidecar.skills_mgr.manager as skm
    sk_dir = tmp / "skills"
    sk_dir.mkdir(parents=True, exist_ok=True)
    skm.skills_root = lambda: sk_dir
    return tmp


# ══════════ 工具循环驱动（照 test_computer_use.py D 组范式）═══════════════════
class _ToolConn:
    def __init__(self, calls: list[dict]):
        self.calls = calls
        self.n = 0

    async def chat_stream(self, model, messages, **kw):
        if self.n < len(self.calls):
            args = self.calls[self.n]
            self.n += 1
            yield {"tool_calls": [{"id": f"c{self.n}", "function": {
                "name": args["name"], "arguments": json.dumps(args.get("args") or {},
                                                              ensure_ascii=False)}}]}
            yield {"done": True, "counts": {"prompt_eval_count": 5, "eval_count": 2}}
        else:
            yield {"content_delta": "完成"}
            yield {"done": True, "counts": {"prompt_eval_count": 5, "eval_count": 2}}


def _run(calls: list[dict], ctx, authorizer=None, cfg_patch=None):
    """跑工具循环，返回 tool_result 事件列表。"""
    from sidecar.agent_engine.loop import run_tool_loop, tools_spec
    import sidecar.config as cfg
    if cfg_patch:
        cfg.reload_config(cfg_patch)
    tmp = tempfile.mkdtemp(prefix="cuma_loop_")
    conn = _ToolConn(calls)
    spec = tools_spec(with_delegation=False, with_computer_use=True)

    async def go():
        evs = []
        async for ev in run_tool_loop("m", [{"role": "user", "content": "操作宏"}], spec,
                                      sandbox_root=tmp, max_rounds=4, connector=conn,
                                      computer_use_ctx=ctx, authorizer=authorizer):
            evs.append(ev)
        return evs

    evs = asyncio.run(go())
    return [e for e in evs if e.get("event") == "tool_result"]


class _CapExec:
    """executor 三动作捕获桩：⛔ 绝不产生真实事件，只记录调用参数。"""

    def __init__(self, ok=True):
        self.clicks = []
        self.types = []
        self.keys = []
        self.ok = ok

    def mouse_click(self, x, y, button="left", clicks=1):
        self.clicks.append((x, y, button, clicks))
        return {"ok": self.ok, "error": "" if self.ok else "stub_click_failed"}

    def keyboard_type(self, text):
        self.types.append(text)
        return {"ok": self.ok, "error": "" if self.ok else "stub_type_failed"}

    def keyboard_hotkey(self, keys):
        self.keys.append(keys)
        return {"ok": self.ok, "error": "" if self.ok else "stub_key_failed"}


def _patch_replay_deps(cap, els=None, last_error=""):
    """回放依赖全部钉住（⛔ 零真实事件）：executor 三动作→捕获桩；app_elements→固定列表；
    步间间隔置 0。返回还原函数。"""
    import sidecar.computer_use.cu_macro as cm
    import sidecar.computer_use.executor as ex
    import sidecar.computer_use.ax_element as axe
    saved = (ex.mouse_click, ex.keyboard_type, ex.keyboard_hotkey,
             axe.app_elements, cm.REPLAY_STEP_INTERVAL)
    ex.mouse_click = cap.mouse_click
    ex.keyboard_type = cap.keyboard_type
    ex.keyboard_hotkey = cap.keyboard_hotkey
    axe.app_elements = lambda app, depth=1: (els if els is not None else [])
    axe.LAST_ERROR = last_error
    cm.REPLAY_STEP_INTERVAL = 0

    def undo():
        ex.mouse_click, ex.keyboard_type, ex.keyboard_hotkey, \
            axe.app_elements, cm.REPLAY_STEP_INTERVAL = saved

    return undo


def _patch_defenses(wl_ok=True, wl_reason="", perm_ok=True):
    """防线桩：白名单/权限预检。钉在 sidecar.computer_use 包命名空间——
    与路由层 `from sidecar.computer_use import check_whitelist ...` 导入点一致。"""
    import sidecar.computer_use as cu
    saved = (cu.check_whitelist, cu.check_permission_for)
    calls = {"wl": 0, "perm": []}

    def fake_wl(wl):
        calls["wl"] += 1
        return {"ok": wl_ok, "app": "Finder", "reason": wl_reason}

    def fake_perm(tool):
        calls["perm"].append(tool)
        if perm_ok:
            return {"ok": True, "error": ""}
        return {"ok": False, "error": "accessibility_denied: 辅助功能权限未授予（桩）"}

    cu.check_whitelist = fake_wl
    cu.check_permission_for = fake_perm

    def undo():
        cu.check_whitelist, cu.check_permission_for = saved

    return undo, calls


def _spy_cm(*names):
    """模块级间谍：包装 cu_macro 指定函数，捕获【路由层拿到的真实返回字典】。
    路由对宏模块函数原样透传，故捕获字典即可逐字断言工具层契约。"""
    import sidecar.computer_use.cu_macro as cm
    captured: dict[str, list] = {n: [] for n in names}
    saved = {n: getattr(cm, n) for n in names}
    for n in names:
        def make(nm, fn):
            def spy(*a, **k):
                r = fn(*a, **k)
                captured[nm].append(r)
                return r
            return spy
        setattr(cm, n, make(n, saved[n]))

    def undo():
        for n, fn in saved.items():
            setattr(cm, n, fn)

    return captured, undo


def _cleanup_cm():
    """组间清理：录制单例 / 回放忙锁复位（进程级状态，防跨组泄漏）。"""
    import sidecar.computer_use.cu_macro as cm
    if cm.is_recording():
        cm.stop_recording()
    cm._REPLAY_BUSY = False


def _wait_run(run_id, rounds=50):
    import sidecar.computer_use.cu_macro as cm
    run = None
    for _ in range(rounds):
        run = cm.get_run(run_id)
        if run and run.get("status") != "running":
            break
        time.sleep(0.1)
    return run


def _macro(mid, name="测试宏", steps=None, created="2026-09-20T12:00:00"):
    return {"id": mid, "name": name, "created_at": created,
            "steps": steps if steps is not None else []}


def _click_step(seq, x=1, y=2, element=None, action="click"):
    return {"seq": seq, "action": action, "x": x, "y": y, "app": "FakeApp",
            "element": element, "payload": {}, "ts": "2026-09-20T12:00:01"}


# ── A 组：工具 spec 注册存在性（宏工具进 CU 条件组，既有 5 工具不动）─────────
def test_a_tools_spec():
    from sidecar.agent_engine.loop import tools_spec
    isolate_all("cuma_a_")

    MACRO_TOOLS = {"cu_macro_record", "cu_macro_replay", "cu_macro_list"}
    CU5 = {"screen_view", "mouse_click", "keyboard_type", "keyboard_hotkey",
           "element_locate"}
    off = {t["function"]["name"] for t in tools_spec(with_computer_use=False)}
    on = {t["function"]["name"] for t in tools_spec(with_computer_use=True)}
    check("A1 总开关关→宏工具零暴露（与 CU 组同可见性规则）",
          not (off & MACRO_TOOLS), str(off & MACRO_TOOLS))
    check("A2 总开关开→三个宏工具全暴露", MACRO_TOOLS <= on, str(MACRO_TOOLS - on))
    check("A3 既有 5 个 CU 工具仍在（R1 不动既有行为）", CU5 <= on, str(CU5 - on))

    # record：action 必填 + enum start/stop + name 参数；描述写清录制语义
    rec = next(t for t in tools_spec(with_computer_use=True)
               if t["function"]["name"] == "cu_macro_record")
    rp = rec["function"]["parameters"]
    check("A4 record 必填 action 且 enum=start/stop",
          rp.get("required") == ["action"]
          and set((rp["properties"]["action"] or {}).get("enum") or []) == {"start", "stop"},
          str(rp))
    rdesc = rec["function"]["description"]
    check("A5 record 描述写清【只录 Agent 自己的 CU 动作】（防误解为用户操作录制）",
          "你自己" in rdesc and "CU 动作" in rdesc and "不会被捕获" in rdesc, rdesc[:220])
    check("A5b record 描述写清 0 步不保存（saved=false 契约预告）",
          "saved=false" in rdesc, rdesc[:220])

    # replay：id/name 参数；描述写清语义重放 + 回落像素 + 0 步不可回放
    rep = next(t for t in tools_spec(with_computer_use=True)
               if t["function"]["name"] == "cu_macro_replay")
    rprops = rep["function"]["parameters"]["properties"]
    rdesc = rep["function"]["description"]
    check("A6 replay 有 id 与 name 参数（二选一）",
          "id" in rprops and "name" in rprops, str(list(rprops.keys())))
    check("A7 replay 描述写清【语义重放 + 元素失败回落像素坐标】",
          "语义重放" in rdesc and "回落" in rdesc and "像素坐标" in rdesc, rdesc[:260])
    check("A7b replay 描述写清 0 步空宏不可回放 + 真实键鼠需确认",
          "0 步" in rdesc and "真实键鼠" in rdesc and "确认" in rdesc, rdesc[:260])

    # list：无参数；描述含返回字段与删除指引（删除刻意不暴露给 Agent）
    lst = next(t for t in tools_spec(with_computer_use=True)
               if t["function"]["name"] == "cu_macro_list")
    ldesc = lst["function"]["description"]
    check("A8 list 描述含返回字段（id/名称/步数/创建时间）",
          all(k in ldesc for k in ("id", "名称", "步数", "创建时间")), ldesc[:220])
    check("A9 list 描述写明删除不开放给 Agent（引导用户去界面操作）",
          "删除" in ldesc and "界面" in ldesc, ldesc[:220])


# ── B 组：record start/stop 经工具层契约（含 0 步 saved:false 逐字）───────────
def test_b_record_contract():
    import sidecar.computer_use.cu_macro as cm
    isolate_all("cuma_b_")
    authz_calls: list[dict] = []

    async def authz_spy(tool, path, action, extra=None):
        authz_calls.append({"tool": tool, "action": action})
        return {"allowed": True}

    try:
        # B1：start 带 name → ok，录制单例生效
        cap, undo = _spy_cm("start_recording", "stop_recording")
        try:
            trs = _run([{"name": "cu_macro_record",
                         "args": {"action": "start", "name": "宏甲"}}],
                       ctx={"authorizer": authz_spy}, authorizer=authz_spy)
            check("B1 start 经工具层→ok",
                  trs and trs[0]["data"].get("ok") is True, str(trs)[:200])
            r_start = (cap["start_recording"] or [{}])[-1]
            check("B1b 透传契约（ok + name）且录制单例生效",
                  r_start.get("ok") is True and r_start.get("name") == "宏甲"
                  and cm.is_recording() is True, str(r_start))

            # B2：录制中重复 start → already_recording（透传模块错误，不熔断不弹窗）
            trs = _run([{"name": "cu_macro_record",
                         "args": {"action": "start", "name": "宏乙"}}],
                       ctx={"authorizer": authz_spy}, authorizer=authz_spy)
            err = str((trs[0]["data"] if trs else {}).get("error", ""))
            check("B2 重复 start→already_recording 可读错误",
                  "already_recording" in err and "宏甲" in err, err[:220])

            # B3：录制窗口内落 2 步（直调模块挂钩，等价 executor 成功动作落宏）→ stop saved
            cm.record_step({"action": "click", "x": 1, "y": 2, "app": "FakeApp",
                            "payload": {}})
            cm.record_step({"action": "type", "app": "FakeApp",
                            "payload": {"text": "你好"}})
            trs = _run([{"name": "cu_macro_record", "args": {"action": "stop"}}],
                       ctx={"authorizer": authz_spy}, authorizer=authz_spy)
            r_stop = (cap["stop_recording"] or [{}])[-1]
            check("B3 有步 stop→saved=True + 宏 id + 步数=2",
                  r_stop.get("ok") is True and r_stop.get("saved") is True
                  and str((r_stop.get("macro") or {}).get("id", "")).startswith("cu-")
                  and len((r_stop.get("macro") or {}).get("steps") or []) == 2,
                  str(r_stop)[:260])
            check("B3b 事件 ok 与透传字典一致",
                  trs and trs[0]["data"].get("ok") is True, str(trs)[:200])

            # B4：⛔ 0.4.33 空宏防护逐字契约经工具层：0 步 stop → saved:false+message
            _run([{"name": "cu_macro_record",
                   "args": {"action": "start", "name": "空转宏"}}],
                 ctx={"authorizer": authz_spy}, authorizer=authz_spy)
            n0 = len(cm.list_macros())
            trs = _run([{"name": "cu_macro_record", "args": {"action": "stop"}}],
                       ctx={"authorizer": authz_spy}, authorizer=authz_spy)
            r_stop0 = (cap["stop_recording"] or [{}])[-1]
            check("B4 0 步 stop→契约逐字（ok/saved:false/steps:0/message）",
                  r_stop0.get("ok") is True and r_stop0.get("saved") is False
                  and r_stop0.get("steps") == 0
                  and r_stop0.get("message") == "未捕获到任何动作，宏未保存",
                  str(r_stop0))
            check("B4b 0 步事件 ok=True（是契约不是失败）且宏未落盘",
                  trs and trs[0]["data"].get("ok") is True
                  and len(cm.list_macros()) == n0,
                  f"{str(trs)[:150]} macros={len(cm.list_macros())} vs {n0}")

            # B5：未在录制 stop → not_recording 可读错误
            trs = _run([{"name": "cu_macro_record", "args": {"action": "stop"}}],
                       ctx={"authorizer": authz_spy}, authorizer=authz_spy)
            err = str((trs[0]["data"] if trs else {}).get("error", ""))
            check("B5 未录制 stop→not_recording", "not_recording" in err, err[:200])

            # B6：非法 action → bad_arg（工具层自校验，不触模块）
            n_calls = len(cap["start_recording"]) + len(cap["stop_recording"])
            trs = _run([{"name": "cu_macro_record", "args": {"action": "pause"}}],
                       ctx={"authorizer": authz_spy}, authorizer=authz_spy)
            err = str((trs[0]["data"] if trs else {}).get("error", ""))
            check("B6 非法 action→bad_arg 且未触模块",
                  "bad_arg" in err and "start/stop" in err
                  and len(cap["start_recording"]) + len(cap["stop_recording"]) == n_calls,
                  err[:200])

            # B7：空名 start → bad_arg（模块层校验透传）
            trs = _run([{"name": "cu_macro_record",
                         "args": {"action": "start", "name": "   "}}],
                       ctx={"authorizer": authz_spy}, authorizer=authz_spy)
            err = str((trs[0]["data"] if trs else {}).get("error", ""))
            check("B7 空名 start→bad_arg 宏名称不能为空",
                  "bad_arg" in err and "宏名称" in err, err[:200])
        finally:
            undo()

        # B8：⛔ record 全程零确认弹窗（纯状态操作，不碰真实键鼠）
        check("B8 record 全程不弹确认（同 screen_view 只读纪律）",
              authz_calls == [], str(authz_calls)[:200])
    finally:
        _cleanup_cm()


# ── C 组：replay 经工具层（id/name 解析 + 422 语义翻译 + 防线 + 整宏一次确认）───
def test_c_replay_routing():
    import sidecar.computer_use.cu_macro as cm
    isolate_all("cuma_c_")

    # 数据准备：1 步宏（像素回落路径）/ 0 步空宏 / 2 步宏 / 同名宏×2
    m_one = _macro("cu-20260920-120000-one-a1b2", name="唯一宏",
                   steps=[_click_step(1, x=1, y=2)])
    m_empty = _macro("cu-20260920-120001-empty-c3d4", name="空宏", steps=[])
    m_two = _macro("cu-20260920-120002-two-e5f6", name="两步宏", steps=[
        _click_step(1, x=5, y=6),
        {"seq": 2, "action": "type", "x": None, "y": None, "app": "FakeApp",
         "element": None, "payload": {"text": "宏输入"}, "ts": "t"},
    ])
    m_dup1 = _macro("cu-20260920-120003-dup1-g7h8", name="同名宏",
                    steps=[_click_step(1)])
    m_dup2 = _macro("cu-20260920-120004-dup2-i9j0", name="同名宏",
                    steps=[_click_step(1)], created="2026-09-20T12:01:00")
    for m in (m_one, m_empty, m_two, m_dup1, m_dup2):
        cm.save_macro(m)

    cap = _CapExec()
    undo_replay = _patch_replay_deps(cap)
    undo_def, def_calls = _patch_defenses(wl_ok=True, perm_ok=True)
    authz_calls: list[dict] = []

    async def authz_yes(tool, path, action, extra=None):
        authz_calls.append({"tool": tool, "action": action, "extra": extra})
        return {"allowed": True}

    try:
        # C1：不存在 id → 422 not_found 翻译成 Agent 可读文本（⛔ 变异2 守护）
        trs = _run([{"name": "cu_macro_replay",
                     "args": {"id": "cu-20990101-000000-none-zzzz"}}],
                   ctx={"authorizer": authz_yes}, authorizer=authz_yes,
                   cfg_patch={"computer_use_confirm_each": False})
        err = str((trs[0]["data"] if trs else {}).get("error", ""))
        check("C1 不存在宏→not_found 可读翻译（含「不存在或已删除」+ list 指引）",
              "不存在或已删除" in err and "cu_macro_list" in err, err[:240])

        # C2：⛔ 0 步空宏 → 422 empty_macro 语义转成 Agent 可读错误文本
        trs = _run([{"name": "cu_macro_replay", "args": {"id": m_empty["id"]}}],
                   ctx={"authorizer": authz_yes}, authorizer=authz_yes,
                   cfg_patch={"computer_use_confirm_each": False})
        d = trs[0]["data"] if trs else {}
        check("C2 0 步宏回放→ok=False 且含「宏没有可回放的步骤」",
              d.get("ok") is False and "宏没有可回放的步骤" in str(d.get("error", "")),
              str(d)[:220])
        check("C2b 0 步拒绝未占用忙锁", cm._REPLAY_BUSY is False)

        # C3：按 name 唯一匹配回放成功（confirm_each 关 → 不弹窗）
        authz_calls.clear()
        cap.clicks.clear()
        spy, undo_spy = _spy_cm("start_replay")
        try:
            trs = _run([{"name": "cu_macro_replay", "args": {"name": "唯一宏"}}],
                       ctx={"authorizer": authz_yes}, authorizer=authz_yes,
                       cfg_patch={"computer_use_confirm_each": False})
            d = trs[0]["data"] if trs else {}
            r_rep = (spy["start_replay"] or [{}])[-1]
            check("C3 name 唯一匹配→回放启动 ok 且 run_id 透传",
                  d.get("ok") is True and r_rep.get("ok") is True
                  and str(r_rep.get("run_id", "")).startswith("run-"),
                  f"{str(d)[:150]} {str(r_rep)[:150]}")
            check("C3b 回放成功带异步提示（别干等/可截屏核对）",
                  "后台" in str(r_rep.get("hint", ""))
                  and "screen_view" in str(r_rep.get("hint", "")),
                  str(r_rep.get("hint"))[:220])
            run = _wait_run(r_rep.get("run_id", ""))
            check("C3c 语义重放真实发生（像素回落点击录制坐标，⛔桩捕获零真实事件）",
                  run and run.get("status") == "done"
                  and cap.clicks == [(1, 2, "left", 1)],
                  f"run={str(run)[:120]} clicks={cap.clicks}")
            check("C3d confirm_each 关→零弹窗", authz_calls == [], str(authz_calls))
        finally:
            undo_spy()
            _cleanup_cm()

        # C4：name 无匹配 → not_found（含名单指引）
        trs = _run([{"name": "cu_macro_replay", "args": {"name": "不存在名"}}],
                   ctx={"authorizer": authz_yes}, authorizer=authz_yes,
                   cfg_patch={"computer_use_confirm_each": False})
        err = str((trs[0]["data"] if trs else {}).get("error", ""))
        check("C4 name 无匹配→not_found 含「不存在名」与 cu_macro_list 指引",
              "not_found" in err and "不存在名" in err and "cu_macro_list" in err,
              err[:240])

        # C5：⛔ name 多匹配 → ambiguous 拒绝猜测（回放真实键鼠不能猜；变异1 守护）
        spy, undo_spy = _spy_cm("start_replay")
        try:
            trs = _run([{"name": "cu_macro_replay", "args": {"name": "同名宏"}}],
                       ctx={"authorizer": authz_yes}, authorizer=authz_yes,
                       cfg_patch={"computer_use_confirm_each": False})
            err = str((trs[0]["data"] if trs else {}).get("error", ""))
            check("C5 同名多个→ambiguous 列出候选 id 且要求改用 id",
                  "ambiguous" in err and m_dup1["id"] in err and m_dup2["id"] in err
                  and "id" in err, err[:280])
            check("C5b ambiguous 时【绝不】启动回放（猜错后果真实可见）",
                  spy["start_replay"] == [], str(spy["start_replay"]))
        finally:
            undo_spy()

        # C6：缺 id/name → bad_arg
        trs = _run([{"name": "cu_macro_replay", "args": {}}],
                   ctx={"authorizer": authz_yes}, authorizer=authz_yes,
                   cfg_patch={"computer_use_confirm_each": False})
        err = str((trs[0]["data"] if trs else {}).get("error", ""))
        check("C6 缺参→bad_arg 指引先 list", "bad_arg" in err and "cu_macro_list" in err,
              err[:220])

        # C7：防线3 整宏【一次】确认（2 步宏也只弹一次；逐步确认=弹窗风暴同款事故）
        authz_calls.clear()
        cap.clicks.clear()
        cap.types.clear()
        trs = _run([{"name": "cu_macro_replay", "args": {"id": m_two["id"]}}],
                   ctx={"authorizer": authz_yes}, authorizer=authz_yes,
                   cfg_patch={"computer_use_confirm_each": True})
        d = trs[0]["data"] if trs else {}
        check("C7 confirm_each 开 + 用户同意→回放启动",
                  d.get("ok") is True, str(trs)[:200])
        check("C7b ⛔ 2 步宏只弹一次确认（整宏一次，非逐步）",
              len(authz_calls) == 1, str(authz_calls)[:240])
        check("C7c 确认请求带工具名/描述/宏 id",
              authz_calls and authz_calls[0]["action"] == "computer_use"
              and (authz_calls[0]["extra"] or {}).get("tool") == "cu_macro_replay"
              and (authz_calls[0]["extra"] or {}).get("desc") == "回放宏"
              and (authz_calls[0]["extra"] or {}).get("args") == {"id": m_two["id"]},
              str(authz_calls)[:280])
        run = None
        if d.get("ok"):
            # run_id 不在事件摘要里，从忙锁释放后的 _RUNS 里找（测试内直接查模块）
            import sidecar.computer_use.cu_macro as _cm2
            for _ in range(50):
                runs = [r for r in _cm2._RUNS.values()
                        if r.get("macro_id") == m_two["id"] and r.get("status") != "running"]
                if runs:
                    run = runs[-1]
                    break
                time.sleep(0.1)
        check("C7d 2 步宏回放完成（click + type 都重放，⛔桩捕获零真实事件）",
              run and run.get("status") == "done"
              and cap.clicks == [(5, 6, "left", 1)] and cap.types == ["宏输入"],
              f"run={str(run)[:120]} clicks={cap.clicks} types={cap.types}")
        _cleanup_cm()

        # C8：用户拒绝 → denied_by_user 且【绝不】启动回放
        async def authz_deny(tool, path, action, extra=None):
            return {"allowed": False}

        spy, undo_spy = _spy_cm("start_replay")
        try:
            trs = _run([{"name": "cu_macro_replay", "args": {"id": m_one["id"]}}],
                       ctx={"authorizer": authz_deny}, authorizer=authz_deny,
                       cfg_patch={"computer_use_confirm_each": True})
            err = str((trs[0]["data"] if trs else {}).get("error", ""))
            check("C8 用户拒绝→denied_by_user 且禁止重试",
                  "denied_by_user" in err and "不要再重试" in err, err[:240])
            check("C8b 拒绝时 start_replay 绝未被调用", spy["start_replay"] == [],
                  str(spy["start_replay"]))
        finally:
            undo_spy()

        # C9：需确认但无授权通道 → computer_use_denied（不擅自操作电脑）
        trs = _run([{"name": "cu_macro_replay", "args": {"id": m_one["id"]}}],
                   ctx={"authorizer": None},
                   cfg_patch={"computer_use_confirm_each": True})
        err = str((trs[0]["data"] if trs else {}).get("error", ""))
        check("C9 无授权通道→computer_use_denied", "computer_use_denied" in err, err[:220])

        # C10：防线4 白名单不命中 → app_not_allowed，且不弹窗不启动
        undo_def2, _ = _patch_defenses(wl_ok=False,
                                       wl_reason="前台应用「Safari」不在白名单内（桩）")
        spy, undo_spy = _spy_cm("start_replay")
        try:
            authz_calls.clear()
            trs = _run([{"name": "cu_macro_replay", "args": {"id": m_one["id"]}}],
                       ctx={"authorizer": authz_yes}, authorizer=authz_yes,
                       cfg_patch={"computer_use_confirm_each": True,
                                  "computer_use_app_whitelist": ["Finder"]})
            err = str((trs[0]["data"] if trs else {}).get("error", ""))
            check("C10 白名单不命中→app_not_allowed 且不弹窗不启动",
                  "app_not_allowed" in err and authz_calls == []
                  and spy["start_replay"] == [], err[:220])
        finally:
            undo_spy()
            undo_def2()

        # C11：防线1 权限缺失 → 预检拦截（弹窗之前），不启动
        undo_def3, perm_calls = None, None
        undo_def3, perm_calls = _patch_defenses(wl_ok=True, perm_ok=False)
        spy, undo_spy = _spy_cm("start_replay")
        try:
            authz_calls.clear()
            trs = _run([{"name": "cu_macro_replay", "args": {"id": m_one["id"]}}],
                       ctx={"authorizer": authz_yes}, authorizer=authz_yes,
                       cfg_patch={"computer_use_confirm_each": True})
            err = str((trs[0]["data"] if trs else {}).get("error", ""))
            check("C11 权限缺失→accessibility_denied 且弹窗前拦截（不启动不弹窗）",
                  "accessibility_denied" in err and authz_calls == []
                  and spy["start_replay"] == [], err[:220])
            check("C11b 权限预检以 cu_macro_replay 名义调用（走辅助功能路径）",
                  perm_calls["perm"] == ["cu_macro_replay"], str(perm_calls))
        finally:
            undo_spy()
            undo_def3()

        # C12：总开关关（无 ctx）→ 拒绝并指引去设置开启
        trs = _run([{"name": "cu_macro_replay", "args": {"id": m_one["id"]}}], ctx=None)
        err = str((trs[0]["data"] if trs else {}).get("error", ""))
        check("C12 无 ctx→拒绝并指引去 设置→Computer Use 开启",
              "Computer Use" in err and "设置" in err, err[:220])
    finally:
        undo_def()
        undo_replay()
        _cleanup_cm()
        import sidecar.config as cfg
        cfg.reload_config({"computer_use_confirm_each": True,
                           "computer_use_app_whitelist": []})


# ── D 组：list 经工具层返回字段（id/name/步数/创建时间 + 录制状态）─────────────
def test_d_list_contract():
    import sidecar.computer_use.cu_macro as cm
    isolate_all("cuma_d_")

    cm.save_macro(_macro("cu-20260920-130000-aa-a1a1", name="甲",
                         steps=[_click_step(1), _click_step(2)]))
    cm.save_macro(_macro("cu-20260920-130001-bb-b2b2", name="乙", steps=[]))

    authz_calls: list[dict] = []

    async def authz_spy(tool, path, action, extra=None):
        authz_calls.append({"tool": tool})
        return {"allowed": True}

    captured, undo = _spy_cm("list_macros", "is_recording", "recording_steps")
    try:
        # D1：list 返回宏摘要（经间谍断言路由取到的字段），事件 ok
        trs = _run([{"name": "cu_macro_list", "args": {}}],
                   ctx={"authorizer": authz_spy}, authorizer=authz_spy)
        check("D1 list 经工具层→ok", trs and trs[0]["data"].get("ok") is True,
              str(trs)[:200])
        macros = (captured["list_macros"] or [[]])[-1]
        check("D1b 摘要字段逐字（id/name/created_at/steps 数）",
              len(macros) == 2
              and all(set(m.keys()) == {"id", "name", "created_at", "steps"}
                      for m in macros)
              and next(m for m in macros if m["name"] == "甲")["steps"] == 2
              and next(m for m in macros if m["name"] == "乙")["steps"] == 0,
              str(macros)[:260])
        check("D1c 录制状态字段一并查询（recording/recording_steps）",
              captured["is_recording"] and captured["recording_steps"]
              and captured["is_recording"][-1] is False
              and captured["recording_steps"][-1] == 0,
              f"{captured['is_recording']} {captured['recording_steps']}")

        # D2：录制中 list → recording=True 且实时步数透出
        cm.start_recording("进行中")
        cm.record_step({"action": "click", "x": 1, "y": 2, "app": "FakeApp",
                        "payload": {}})
        trs = _run([{"name": "cu_macro_list", "args": {}}],
                   ctx={"authorizer": authz_spy}, authorizer=authz_spy)
        check("D2 录制中 list→ok 且 recording=True / steps=1",
              trs and trs[0]["data"].get("ok") is True
              and captured["is_recording"][-1] is True
              and captured["recording_steps"][-1] == 1,
              f"{captured['is_recording'][-1]} {captured['recording_steps'][-1]}")
        cm.stop_recording()

        # D3：⛔ list 全程零确认弹窗（只读元数据）
        check("D3 list 全程不弹确认（只读，同 screen_view 纪律）",
              authz_calls == [], str(authz_calls)[:200])

        # D4：无 ctx（总开关关）→ 拒绝指引
        trs = _run([{"name": "cu_macro_list", "args": {}}], ctx=None)
        err = str((trs[0]["data"] if trs else {}).get("error", ""))
        check("D4 无 ctx→拒绝并指引去设置开启",
              "Computer Use" in err and "设置" in err, err[:200])
    finally:
        undo()
        _cleanup_cm()


# ── E 组：系统提示词 CU 段（宏能力说明 + 开关关闭零开销）─────────────────────
def test_e_system_prompt():
    from sidecar.agent_engine.loop import build_system_prompt
    isolate_all("cuma_e_")

    sp = build_system_prompt("小助手", "工程师", "/data/ws", "auto",
                             computer_use_enabled=True)
    check("E1 CU 段含任务宏指引（何时用：录成宏/录制这个动作/回放宏）",
          "任务宏" in sp and "录成宏" in sp and "回放宏" in sp, sp[-500:])
    check("E2 CU 段点名三个宏工具（Agent 据此选工具）",
          all(t in sp for t in ("cu_macro_record", "cu_macro_replay", "cu_macro_list")),
          sp[-500:])
    check("E3 CU 段写清录制语义（只捕获 Agent 自己的 CU 动作序列）",
          "你自己" in sp and "动作序列" in sp, sp[-500:])
    check("E4 CU 段写清回放是语义重放（元素重定位，失败回落像素坐标）",
          "语义重放" in sp and "像素坐标" in sp, sp[-500:])
    check("E5 CU 段禁止自己写脚本模拟（治实测自由发挥写 shell）",
          "不要自己写脚本" in sp, sp[-500:])

    sp_off = build_system_prompt("小助手", "工程师", "/data/ws", "auto")
    check("E6 开关关→CU 段零注入（零开销，默认参数不破既有调用）",
          "cu_macro_record" not in sp_off and "【Computer Use】" not in sp_off,
          sp_off[-300:])
    sp_off2 = build_system_prompt("小助手", "工程师", "/data/ws", "auto",
                                  computer_use_enabled=False)
    check("E6b 显式 False 同样零注入", "cu_macro_record" not in sp_off2, "")


# ── F 组：权限预检分派（cu_macro_replay 走辅助功能路径，⛔零真实事件）───────────
def test_f_permission_dispatch():
    from sidecar.computer_use import executor as ex
    isolate_all("cuma_f_")

    orig = (ex._ax_trusted, ex._screen_capture_access)
    try:
        # F1：辅助功能缺失 → 回放预检拦截（回放要发 HID 事件，同点击/输入）
        ex._ax_trusted = lambda: False
        ex._screen_capture_access = lambda: True
        r = ex.check_permission_for("cu_macro_replay")
        check("F1 cu_macro_replay 辅助功能缺失→accessibility_denied",
              r["ok"] is False and "accessibility_denied" in str(r["error"]), str(r)[:180])
        # F2：两项权限齐备 → 放行（回放不需要屏幕录制，但屏幕录制开不影响）
        ex._ax_trusted = lambda: True
        r = ex.check_permission_for("cu_macro_replay")
        check("F2 辅助功能已授→放行", r["ok"] is True, str(r)[:150])
        # F3：屏幕录制缺失不影响回放预检（回放不截屏）
        ex._screen_capture_access = lambda: False
        r = ex.check_permission_for("cu_macro_replay")
        check("F3 屏幕录制缺失不误伤回放预检", r["ok"] is True, str(r)[:150])
    finally:
        ex._ax_trusted, ex._screen_capture_access = orig


def main():
    print("=" * 70)
    print("0.4.33（CU 三期 R1）任务宏接入 Agent 工具组 专项回归")
    print("⛔ 全程不产生真实点击/输入（executor/防线全桩化 + 模块级间谍捕获契约）")
    if MUTATE:
        print(f"⚠️ 变异 {MUTATE} 已注入（预期本套件变红；全绿=断言无效）")
    print("=" * 70)
    try:
        _apply_mutation()
        test_a_tools_spec()
        test_b_record_contract()
        test_c_replay_routing()
        test_d_list_contract()
        test_e_system_prompt()
        test_f_permission_dispatch()
    finally:
        _restore()
    print("\n" + "=" * 70)
    print(f"===== SUMMARY: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("FAILED:")
        for f in FAILURES:
            print("  -", f)
    print("=" * 70)
    if MUTATE:
        if FAIL:
            print(f"变异 {MUTATE} 已命中（FAIL={FAIL}，符合预期）")
            return 0
        print(f"⛔ 变异 {MUTATE} 未被抓住 —— 本测试对该修复无效，断言需加强")
        return 3
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
