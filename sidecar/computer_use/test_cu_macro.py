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
"""0.4.32（CU 三期 P2，REQ-FUT-006）专项回归：任务宏 录制/保存/列表/回放/删除。

⛔ 测试铁律（同 test_computer_use.py / test_ax_element.py）：**绝不允许真实点击/输入
用户屏幕**——
- 录制挂钩（C 组）复用 test_ax_element 的假 CF/AS/CG 层（事件构造全记录、零真实输出）；
- 回放（D~H 组）把 executor.mouse_click / keyboard_type / keyboard_hotkey 与
  ax_element.app_elements 全部换成捕获桩，断言【调用参数】而非真实效果；
- 端点回放用例（I 组）有步宏回放时 executor 三动作全部桩化（_patch_replay），
  绝不触发真实动作；0 步宏只验证 422 拒绝（0.4.33 F2）。

变异测试机制（MUTATE=1|2|3|4|5 .venv/bin/python -m sidecar.computer_use.test_cu_macro）：
  1 = 重定位 title 匹配失效（同 role 多元素选错 → D 组灭）
  2 = 匹配不到回落像素失效（变成中止 → E 组灭）
  3 = app 未运行/无窗口中止失效（变成回落像素乱点 → F 组灭）
  4 = 0.4.33 F2 空宏防护失效：0 步照存（K6/K7、I4d/I4e 灭）
  5 = 0.4.33 F2 回放防护失效：0 步照放（K8、I6 灭）
"""
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


# ══════════ 变异机制（照 test_ax_element.py 范式：内存备份 + finally 还原 + reload）══
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
    import sidecar.computer_use.cu_macro as cm
    src = Path(cm.__file__)
    if MUTATE == 1:
        _mutate_file(src,
                     "        # ⛔ MUTATE锚点：title 必须参与匹配（同 role 多元素时靠 title 区分，否则点错按钮）\n"
                     "        cand = [e for e in cand if str(e.get(\"title\") or \"\") == title]",
                     "        cand = cand  # 变异1：title 不参与匹配，同 role 选错元素",
                     "cm")
    elif MUTATE == 2:
        _mutate_file(src,
                     "    # ⛔ MUTATE锚点：匹配不到回落 step 原像素坐标（计划 E4 既定回落路径）\n"
                     "    return (\"pixel_fallback\", ox, oy, \"\")",
                     "    return (\"abort\", None, None, \"变异2：匹配不到也中止\")",
                     "cm")
    elif MUTATE == 3:
        _mutate_file(src,
                     "            # ⛔ MUTATE锚点：app 未运行/无窗口必须中止（R4），不得回落像素乱点\n"
                     "            return (\"abort\", None, None, f\"目标应用「{app}」未运行或没有窗口（{err}）\")",
                     "            return (\"pixel_fallback\", ox, oy, \"\")  # 变异3：app 未开不中止",
                     "cm")
    elif MUTATE == 4:
        # 0 步照存：空宏防护失效（实测空转期 steps=[] 照存）
        _mutate_file(src,
                     "    if not rec[\"steps\"]:\n"
                     "        # ⛔ MUTATE锚点：0 步宏不得落盘（空宏防护：实测空转期 steps=[] 照存）",
                     "    if False:  # 变异4：0 步照存（空宏防护失效）",
                     "cm")
    elif MUTATE == 5:
        # 0 步照放：回放防护失效（0 步回放静默完成=假成功）
        _mutate_file(src,
                     "    if not (macro.get(\"steps\") or []):\n"
                     "        # ⛔ MUTATE锚点：0 步宏不得回放（静默完成等于假成功）",
                     "    if False:  # 变异5：0 步照放（回放防护失效）",
                     "cm")
    else:
        raise SystemExit(f"未知变异编号 {MUTATE}（支持 1|2|3|4|5）")
    importlib.reload(cm)


def _restore() -> None:
    if not MUTATE or not _BACKUP:
        return
    try:
        for path, s in _BACKUP.values():
            path.write_text(s, encoding="utf-8")
    finally:
        _BACKUP.clear()
        import sidecar.computer_use.cu_macro as cm
        importlib.reload(cm)


def isolate_all(prefix: str) -> Path:
    """config / store / warehouse / skills 全部重定向到临时目录（照 test_ax_element.py 同款）。"""
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


def _macro(mid="cu-20260918-120000-test-a1b2", name="测试宏", steps=None,
           created="2026-09-18T12:00:00"):
    return {"id": mid, "name": name, "created_at": created,
            "steps": steps if steps is not None else []}


_NO_ELEMENT = object()          # _click_step 哨兵：区分「未传」与「显式 None」


def _click_step(seq, x=10, y=10, app="FakeApp",
                element=_NO_ELEMENT, action="click"):
    if element is _NO_ELEMENT:
        element = {"role": "AXButton", "title": "删除", "frame": [100.0, 200.0, 40.0, 20.0]}
    return {"seq": seq, "action": action, "x": x, "y": y, "app": app,
            "element": element, "payload": {}, "ts": "2026-09-18T12:00:01"}


def _fresh_run(macro):
    return {"run_id": f"run-test-{id(macro)}", "macro_id": macro.get("id", ""),
            "macro_name": macro.get("name", ""), "status": "running",
            "started_at": "", "finished_at": "", "total": 0, "completed": 0,
            "failed_seq": None, "error": "", "steps": []}


class _CapExec:
    """executor 三动作捕获桩：⛔ 绝不产生真实事件，只记录调用参数。"""

    def __init__(self, ok=True):
        self.clicks = []      # (x, y, button, clicks)
        self.types = []       # text
        self.keys = []        # keys
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


def _patch_replay(cap, els=None, last_error=""):
    """把回放依赖全部钉住：executor 三动作→捕获桩；app_elements→固定元素列表。
    返回还原函数。"""
    import sidecar.computer_use.cu_macro as cm
    import sidecar.computer_use.executor as ex
    import sidecar.computer_use.ax_element as axe
    saved = (ex.mouse_click, ex.keyboard_type, ex.keyboard_hotkey,
             axe.app_elements, cm.REPLAY_STEP_INTERVAL)
    ex.mouse_click = cap.mouse_click
    ex.keyboard_type = cap.keyboard_type
    ex.keyboard_hotkey = cap.keyboard_hotkey
    calls = {"n": 0}

    def fake_app_elements(app, depth=1):
        calls["n"] += 1
        return els if els is not None else []

    axe.app_elements = fake_app_elements
    axe.LAST_ERROR = last_error
    cm.REPLAY_STEP_INTERVAL = 0

    def undo():
        ex.mouse_click, ex.keyboard_type, ex.keyboard_hotkey, \
            axe.app_elements, cm.REPLAY_STEP_INTERVAL = saved

    return undo, calls


# ── A 组：存储（原子写 / 列表 / 读取 / 删除 / 路径穿越防御）────────────────
def test_a_storage():
    import sidecar.computer_use.cu_macro as cm
    tmp = isolate_all("cum_a_")

    # A1：保存 + 读回 roundtrip；文件落在 {data_root}/cu_macros/<id>.json
    m1 = _macro(steps=[_click_step(1)])
    path = cm.save_macro(m1)
    check("A1 宏落盘路径正确", path == tmp / "cu_macros" / f"{m1['id']}.json"
          and path.exists(), str(path))
    back = cm.load_macro(m1["id"])
    check("A1b 读回字段一致", back and back["name"] == "测试宏"
          and len(back["steps"]) == 1 and back["steps"][0]["element"]["title"] == "删除",
          str(back)[:200])

    # A2：⛔原子写——os.replace 中途失败 → 旧文件完好、不剩半截（config._save 同款守护）
    m2 = _macro(mid="cu-20260918-120001-test-c3d4", name="乙")
    cm.save_macro(m2)
    good = (tmp / "cu_macros" / f"{m2['id']}.json").read_text(encoding="utf-8")
    import os as _os
    real_replace = _os.replace

    def boom(*a, **k):
        raise OSError("模拟写一半被 kill")

    _os.replace = boom
    try:
        raised = False
        try:
            cm.save_macro(_macro(mid="cu-20260918-120001-test-c3d4", name="乙改"))
        except OSError:
            raised = True
        on_disk = (tmp / "cu_macros" / f"{m2['id']}.json").read_text(encoding="utf-8")
        check("A2 os.replace 异常→抛出且旧文件完好", raised and on_disk == good, "")
    finally:
        _os.replace = real_replace

    # A3：列表摘要（id/name/created_at/steps 数）+ 按 created_at 排序
    cm.save_macro(_macro(mid="cu-20260918-120002-test-e5f6", name="丙",
                         created="2026-09-18T11:00:00"))
    lst = cm.list_macros()
    ids = [m["id"] for m in lst]
    check("A3 列表含全部宏且按 created_at 升序",
          len(lst) == 3 and ids[0].endswith("e5f6"), str(ids))
    check("A3b 列表摘要字段（steps 为数不是全量）",
          all(set(m.keys()) == {"id", "name", "created_at", "steps"} for m in lst)
          and lst[0]["steps"] == 0
          and next(m for m in lst if m["id"] == m1["id"])["steps"] == 1, str(lst))

    # A4：删除 + 路径穿越防御（URL 来的 id 不可信）
    check("A4 删除存在宏→True", cm.delete_macro(m1["id"]) is True
          and not (tmp / "cu_macros" / f"{m1['id']}.json").exists())
    check("A4b 删除不存在→False", cm.delete_macro(m1["id"]) is False)
    for bad in ("../etc", "..%2F..%2Fetc", "a/b", "", "x.json", "a" * 200, None):
        check(f"A4c 非法 id {str(bad)[:20]!r}→valid  False 且 delete/load 安全",
              cm.valid_macro_id(bad) is False
              and cm.delete_macro(bad) is False and cm.load_macro(bad) is None)

    # A5：损坏 JSON → 列表跳过、load None（不阻断其他宏）
    bad_path = tmp / "cu_macros" / "cu-20260918-130000-broken-z9y8.json"
    bad_path.write_text("{半截", encoding="utf-8")
    check("A5 损坏文件列表跳过且 load→None",
          all(m["id"] != "cu-20260918-130000-broken-z9y8" for m in cm.list_macros())
          and cm.load_macro("cu-20260918-130000-broken-z9y8") is None
          and len(cm.list_macros()) == 2, str(cm.list_macros()))


# ── B 组：录制器（起停 / 单例 / step 语义字段 / 截断）──────────────────────
def test_b_recorder():
    import sidecar.computer_use.cu_macro as cm
    tmp = isolate_all("cum_b_")

    check("B1 空名→bad_arg", cm.start_recording("   ").get("ok") is False)
    r = cm.start_recording("我的流程")
    check("B2 开始录制→ok 且 is_recording", r.get("ok") is True
          and cm.is_recording() is True)
    r2 = cm.start_recording("另一个")
    check("B3 重复开始→already_recording（单例）", r2.get("ok") is False
          and "already_recording" in str(r2.get("error")), str(r2))

    # 逐步追加：seq 自增；element.title 截断 80（落盘契约，防大树文本爆炸）
    ok1 = cm.record_step({"action": "click", "x": 1, "y": 2, "app": "Finder",
                          "element": {"role": "AXButton", "title": "长" * 200,
                                      "frame": [0, 0, 10, 10]},
                          "payload": {"button": "left", "clicks": 1}})
    ok2 = cm.record_step({"action": "type", "app": "Finder",
                          "payload": {"text": "你好"}})
    ok3 = cm.record_step({"action": "key", "app": "", "element": "垃圾",
                          "payload": {"keys": "cmd+c"}})
    check("B4 record_step 三次都受理", ok1 and ok2 and ok3)
    st = cm.stop_recording()
    check("B5 停止→ok 且 is_recording 复原", st.get("ok") is True
          and cm.is_recording() is False)
    macro = st.get("macro") or {}
    steps = macro.get("steps") or []
    check("B5b 宏结构（id 风格/名称/created_at）",
          macro.get("id", "").startswith("cu-") and macro.get("name") == "我的流程"
          and bool(macro.get("created_at")), str({k: macro.get(k) for k in
                                                  ("id", "name", "created_at")}))
    check("B6 step 语义字段齐全且 seq 自增",
          len(steps) == 3
          and [s["seq"] for s in steps] == [1, 2, 3]
          and all(set(s.keys()) == {"seq", "action", "x", "y", "app",
                                    "element", "payload", "ts"} for s in steps)
          and all(s["ts"] for s in steps), str(steps)[:300])
    check("B7 ⛔element.title 截断 80（落盘契约）",
          len(steps[0]["element"]["title"]) == 80, str(len(steps[0]["element"]["title"])))
    check("B7b 非 dict element→None（防御），payload 保留",
          steps[2]["element"] is None and steps[2]["payload"] == {"keys": "cmd+c"})
    on_disk = cm.load_macro(macro["id"])
    check("B8 落盘可读回（步骤数一致）", on_disk and len(on_disk["steps"]) == 3)

    check("B9 未录制 stop→not_recording", cm.stop_recording().get("ok") is False)
    check("B9b 未录制 record_step→False", cm.record_step({"action": "click"}) is False)


# ── K 组：0.4.33（插单修复 F2）空宏防护 + recording_steps 实时步数 ──────────
def test_k_empty_macro_guard():
    import sidecar.computer_use.cu_macro as cm
    isolate_all("cum_k_")

    # recording_steps：未录制 0 → 录制中递增 → 停止归 0
    check("K1 未录制 recording_steps=0", cm.recording_steps() == 0)
    r = cm.start_recording("步数宏")
    check("K2 开始录制→recording_steps=0", r.get("ok") is True
          and cm.recording_steps() == 0)
    cm.record_step({"action": "click", "x": 1, "y": 2, "app": "Finder", "payload": {}})
    cm.record_step({"action": "key", "app": "Finder", "payload": {"keys": "cmd+c"}})
    check("K3 录制中 recording_steps 递增（=2）", cm.recording_steps() == 2)
    st = cm.stop_recording()
    check("K4 有步 stop→saved=True + macro", st.get("ok") is True
          and st.get("saved") is True
          and len((st.get("macro") or {}).get("steps") or []) == 2, str(st)[:200])
    check("K5 停止后 recording_steps 归 0", cm.recording_steps() == 0)

    # 空宏防护（问题3 实测：录制窗口内无任何动作，steps=[] 照存、回放静默完成）
    n0 = len(cm.list_macros())
    cm.start_recording("空转宏")
    st = cm.stop_recording()
    check("K6 0 步 stop→ok 且契约字段逐字（saved/steps/message）",
          st.get("ok") is True and st.get("saved") is False
          and st.get("steps") == 0
          and st.get("message") == "未捕获到任何动作，宏未保存", str(st))
    check("K7 0 步宏不落盘（列表数不变；变异 4 守护）",
          len(cm.list_macros()) == n0, f"before={n0} after={len(cm.list_macros())}")

    # 0 步宏回放拒绝（存量 0 步宏也拦；变异 5 守护）
    empty = _macro(mid="cu-20260918-125959-empty-e0f0", steps=[])
    cm.save_macro(empty)
    r = cm.start_replay(empty["id"])
    check("K8 0 步宏 start_replay→拒绝且含「宏没有可回放的步骤」",
          r.get("ok") is False and "宏没有可回放的步骤" in str(r.get("error")), str(r))
    check("K8b 0 步拒绝后忙锁未占用（可立即回放别的宏）", cm._REPLAY_BUSY is False)

    # 有步宏回放不受影响（executor 桩化，⛔零真实事件）
    cap = _CapExec()
    undo, _ = _patch_replay(cap, els=[])
    try:
        m2 = _macro(mid="cu-20260918-125958-ok-o1k1",
                    steps=[_click_step(1, x=1, y=2, element=None)])
        cm.save_macro(m2)
        r = cm.start_replay(m2["id"])
        check("K9 有步宏 start_replay 不受影响", r.get("ok") is True
              and str(r.get("run_id", "")).startswith("run-"), str(r))
        run = None
        for _ in range(50):
            run = cm.get_run(r["run_id"])
            if run and run.get("status") != "running":
                break
            time.sleep(0.1)
        check("K9b 有步宏回放 done 且按原像素点击",
              run and run.get("status") == "done"
              and cap.clicks == [(1, 2, "left", 1)],
              f"run={str(run)[:150]} clicks={cap.clicks}")
    finally:
        undo()
        cm._REPLAY_BUSY = False


# ── C 组：executor 录制挂钩（假 CG/CF/AS 层，⛔零真实事件）──────────────────
def test_c_executor_hook():
    import sidecar.computer_use.cu_macro as cm
    import sidecar.computer_use.executor as ex
    import sidecar.computer_use.test_ax_element as tax
    tmp = isolate_all("cum_c_")

    front_calls = {"n": 0}
    orig_front = ex.frontmost_app
    ex.frontmost_app = lambda: (front_calls.__setitem__("n", front_calls["n"] + 1),
                                "FakeFront")[1]

    try:
        cm.start_recording("挂钩宏")
        # C1：命中点击 → step 用校正链既有 hit_test 结果（element+frame+app），
        #     坐标=frame 中心（与实际点击点一致），⛔ 不重复 hit_test
        fas = tax.FakeAS(attrs={"el0": tax._full_elem(frame=(100.0, 200.0, 40.0, 20.0),
                                                      role="AXButton", title="存储")})
        undo = tax._inject(fas, tax.FakeCF())
        fcg, undo_cg = tax._install_fake_cg()
        try:
            r = ex.mouse_click(110, 210)
            steps = (cm._REC or {}).get("steps", [])
            check("C1 命中点击落 step（action/坐标=frame 中心）",
                  r.get("ok") is True and len(steps) == 1
                  and steps[0]["action"] == "click"
                  and steps[0]["x"] == 120.0 and steps[0]["y"] == 210.0,
                  str(steps)[:250])
            el = steps[0]["element"] if steps else None
            check("C1b element 语义（role/title/frame 来自既有 hit_test，不重复测）",
                  el and el["role"] == "AXButton" and el["title"] == "存储"
                  and el["frame"] == [100.0, 200.0, 40.0, 20.0]
                  and len(fas.hit_calls) == 1, f"el={el} hit_calls={fas.hit_calls}")
            check("C1c app 有值（hit 带不出时回落 frontmost app）",
                  steps[0]["app"] == "FakeFront", str(steps[0]["app"]))
            # C2：双击/右键映射
            ex.mouse_click(110, 210, clicks=2)
            ex.mouse_click(110, 210, button="right")
            acts = [s["action"] for s in cm._REC["steps"]]
            check("C2 双击→double_click、右键→right_click",
                  acts == ["click", "double_click", "right_click"], str(acts))
        finally:
            undo_cg()
            undo()

        # C3：未命中（pixel_fallback）→ element=None + 原坐标 + frontmost app
        fas2 = tax.FakeAS(hit_err=-25212)
        undo = tax._inject(fas2, tax.FakeCF())
        fcg, undo_cg = tax._install_fake_cg()
        try:
            ex.mouse_click(300, 400)
            s = cm._REC["steps"][-1]
            check("C3 pixel_fallback 点击→element=None、原坐标",
                  s["element"] is None and s["x"] == 300 and s["y"] == 400
                  and s["app"] == "FakeFront", str(s))
        finally:
            undo_cg()
            undo()

        # C4：type/key → payload 落盘（element 按代码事实为 None，app=frontmost）
        undo = tax._inject(tax.FakeAS(), tax.FakeCF())
        fcg, undo_cg = tax._install_fake_cg()
        try:
            ex.keyboard_type("你好世界")
            ex.keyboard_hotkey("cmd+c")
            st, sk = cm._REC["steps"][-2], cm._REC["steps"][-1]
            check("C4 type 步骤 payload.text + element=None",
                  st["action"] == "type" and st["payload"] == {"text": "你好世界"}
                  and st["element"] is None and st["app"] == "FakeFront", str(st))
            check("C4b key 步骤 payload.keys",
                  sk["action"] == "key" and sk["payload"] == {"keys": "cmd+c"},
                  str(sk))
        finally:
            undo_cg()
            undo()

        # C5：⛔失败动作不落宏（回放一个当时就没成功的动作无意义）
        n_before = len(cm._REC["steps"])
        r = ex.mouse_click("x", 1)          # bad_arg：未到执行层
        check("C5 失败动作不落 step", r.get("ok") is False
              and len(cm._REC["steps"]) == n_before)

        # C6：停止录制后 → 零开销（frontmost_app 不再被调、step 不再增）
        st = cm.stop_recording()
        check("C6 stop 落盘 6 步", st.get("ok") is True
              and len(st["macro"]["steps"]) == 6, str(len(st.get("macro", {}).get("steps", []))))
        front_calls["n"] = 0
        undo = tax._inject(tax.FakeAS(attrs={"el0": tax._full_elem()}), tax.FakeCF())
        fcg, undo_cg = tax._install_fake_cg()
        try:
            ex.mouse_click(110, 210)
            check("C6b 未录制→frontmost 零调用（录制挂钩零开销）",
                  front_calls["n"] == 0, str(front_calls))
        finally:
            undo_cg()
            undo()
    finally:
        ex.frontmost_app = orig_front
        if cm.is_recording():
            cm.stop_recording()


# ── D 组：回放语义重定位（窗口挪位仍命中 → 点新 frame 中心）────────────────
def test_d_replay_relocate():
    import sidecar.computer_use.cu_macro as cm
    isolate_all("cum_d_")

    # 录制时「删除」按钮在 (100,200,40,20)；回放时窗口挪位：app_elements 返回
    # 挪位后的 frame (500,600,40,20)。同 role 还有个「保存」按钮（混淆项，
    # ⛔ 变异1 守护：title 不参与匹配就会错点「保存」中心 (5,5)）。
    moved = [
        {"role": "AXButton", "title": "保存", "frame": (0.0, 0.0, 10.0, 10.0), "depth": 1},
        {"role": "AXButton", "title": "删除", "frame": (500.0, 600.0, 40.0, 20.0), "depth": 1},
    ]
    cap = _CapExec()
    undo, enum_calls = _patch_replay(cap, els=moved)
    try:
        macro = _macro(steps=[_click_step(1, x=110, y=210)])
        run = cm.run_replay(_fresh_run(macro), macro)
        check("D1 ⛔语义重定位：点挪位后 frame 中心（不是录制时旧坐标）",
              cap.clicks == [(520.0, 610.0, "left", 1)], str(cap.clicks))
        check("D1b run done 且 step method=element",
              run["status"] == "done" and run["completed"] == 1
              and run["steps"][0]["method"] == "element" and run["steps"][0]["ok"] is True,
              str({k: run[k] for k in ("status", "steps")})[:250])

        # D2：double_click/right_click 映射（button/clicks 正确传给 executor）
        cap.clicks.clear()
        macro2 = _macro(steps=[_click_step(1, action="double_click"),
                               _click_step(2, action="right_click")])
        run2 = cm.run_replay(_fresh_run(macro2), macro2)
        check("D2 动作映射（double→left×2，right→right×1）",
              cap.clicks == [(520.0, 610.0, "left", 2), (520.0, 610.0, "right", 1)],
              str(cap.clicks))
        check("D2b 枚举深度 ≤2（禁止全树遍历铁律不破）",
              enum_calls["n"] >= 1, str(enum_calls))
    finally:
        undo()


# ── E 组：回放回落像素（匹配不到 / 录制时无元素 / 枚举失败）─────────────────
def test_e_replay_fallback():
    import sidecar.computer_use.cu_macro as cm
    isolate_all("cum_e_")

    # E1：枚举有元素但 role/title 都不匹配 → 回落 step 原像素坐标（⛔ 变异2 守护）
    cap = _CapExec()
    undo, _ = _patch_replay(cap, els=[{"role": "AXSlider", "title": "别的",
                                       "frame": (0.0, 0.0, 5.0, 5.0), "depth": 1}])
    try:
        macro = _macro(steps=[_click_step(1, x=110, y=210)])
        run = cm.run_replay(_fresh_run(macro), macro)
        check("E1 匹配不到→回落原像素坐标（method=pixel_fallback）",
              cap.clicks == [(110, 210, "left", 1)] and run["status"] == "done"
              and run["steps"][0]["method"] == "pixel_fallback", str(cap.clicks))
    finally:
        undo()

    # E2：录制时就未命中元素（element=None）→ 直接像素回落，不发起枚举
    cap2 = _CapExec()
    undo2, enum2 = _patch_replay(cap2, els=[])
    try:
        macro = _macro(steps=[_click_step(1, x=33, y=44, element=None)])
        run = cm.run_replay(_fresh_run(macro), macro)
        check("E2 无元素语义→直接像素回落且零枚举开销",
              cap2.clicks == [(33, 44, "left", 1)] and enum2["n"] == 0,
              f"clicks={cap2.clicks} enum={enum2}")
    finally:
        undo2()

    # E3：枚举失败但【非】app 缺失（如 cannotComplete）→ 仍回落像素，不中止
    cap3 = _CapExec()
    undo3, _ = _patch_replay(cap3, els=[], last_error="AXWindows err=-25204(cannotComplete)")
    try:
        macro = _macro(steps=[_click_step(1, x=55, y=66)])
        run = cm.run_replay(_fresh_run(macro), macro)
        check("E3 枚举失败（非 app 缺失）→回落像素不中止",
              cap3.clicks == [(55, 66, "left", 1)] and run["status"] == "done",
              f"clicks={cap3.clicks} status={run['status']}")
    finally:
        undo3()


# ── F 组：R4 中止——app 未运行/窗口未开 → 该步错误返回并中止（报步骤号）───────
def test_f_replay_abort():
    import sidecar.computer_use.cu_macro as cm
    isolate_all("cum_f_")

    cap = _CapExec()
    undo, _ = _patch_replay(cap, els=[],
                            last_error="app_not_found: 找不到运行中的应用「FakeApp」")
    try:
        macro = _macro(steps=[
            {"seq": 1, "action": "type", "x": None, "y": None, "app": "FakeApp",
             "element": None, "payload": {"text": "先输入"}, "ts": "t"},
            _click_step(2, x=10, y=10),
            _click_step(3, x=20, y=20),
        ])
        run = cm.run_replay(_fresh_run(macro), macro)
        # ⛔ 变异3 守护：app 未开必须中止；若变成回落像素，step2/3 会真点出去
        check("F1 app 未运行→第 2 步中止并报步骤号",
              run["status"] == "error" and run["failed_seq"] == 2
              and "第 2 步" in run["error"] and "FakeApp" in run["error"],
              str({k: run[k] for k in ("status", "failed_seq", "error")}))
        check("F1b 后续步骤未执行（第 3 步没有点出去）",
              cap.types == ["先输入"] and cap.clicks == [],
              f"types={cap.types} clicks={cap.clicks}")
        check("F1c 步骤明细只到失败步（step1 ok / step2 失败）",
              len(run["steps"]) == 2 and run["steps"][0]["ok"] is True
              and run["steps"][1]["ok"] is False
              and run["steps"][1]["method"] == "abort", str(run["steps"])[:250])
    finally:
        undo()

    # F2：动作本身执行失败（executor 返回 ok=False）→ 同样中止报步骤号
    cap2 = _CapExec(ok=False)
    undo2, _ = _patch_replay(cap2, els=[{"role": "AXButton", "title": "删除",
                                         "frame": (1.0, 1.0, 4.0, 4.0), "depth": 1}])
    try:
        macro = _macro(steps=[_click_step(1), _click_step(2)])
        run = cm.run_replay(_fresh_run(macro), macro)
        check("F2 动作执行失败→中止报步骤号（后续不执行）",
              run["status"] == "error" and run["failed_seq"] == 1
              and len(cap2.clicks) == 1, str(run["error"])[:150])
    finally:
        undo2()

    # F3：未知动作（宏文件损坏）→ 中止，不猜不跳过
    cap3 = _CapExec()
    undo3, _ = _patch_replay(cap3)
    try:
        macro = _macro(steps=[{"seq": 1, "action": "teleport", "x": 1, "y": 2,
                               "app": "", "element": None, "payload": {}, "ts": "t"}])
        run = cm.run_replay(_fresh_run(macro), macro)
        check("F3 未知动作→中止（unknown_action）",
              run["status"] == "error" and run["failed_seq"] == 1
              and "unknown_action" in run["error"], str(run["error"])[:150])
    finally:
        undo3()


# ── G 组：type/key 直接重放 payload ─────────────────────────────────────
def test_g_replay_payload():
    import sidecar.computer_use.cu_macro as cm
    isolate_all("cum_g_")
    cap = _CapExec()
    undo, _ = _patch_replay(cap)
    try:
        macro = _macro(steps=[
            {"seq": 1, "action": "type", "x": None, "y": None, "app": "备忘录",
             "element": None, "payload": {"text": "会议纪要"}, "ts": "t"},
            {"seq": 2, "action": "key", "x": None, "y": None, "app": "备忘录",
             "element": None, "payload": {"keys": "cmd+s"}, "ts": "t"},
        ])
        run = cm.run_replay(_fresh_run(macro), macro)
        check("G1 type/key 按 payload 重放（method=payload）",
              cap.types == ["会议纪要"] and cap.keys == ["cmd+s"]
              and run["status"] == "done"
              and [s["method"] for s in run["steps"]] == ["payload", "payload"],
              f"types={cap.types} keys={cap.keys} steps={run['steps']}")
    finally:
        undo()


# ── H 组：回放步骤事件序列（app_events：seq/action/命中方式/ok）─────────────
def test_h_replay_events():
    import sidecar.computer_use.cu_macro as cm
    import sidecar.agent_engine.app_events as ae
    isolate_all("cum_h_")

    events = []
    orig_notify = ae.notify
    ae.notify = lambda resource, action, project_id=None, **kw: \
        (events.append({"resource": resource, "action": action, **kw}), True)[1]
    cap = _CapExec()
    moved = [{"role": "AXButton", "title": "删除",
              "frame": (500.0, 600.0, 40.0, 20.0), "depth": 1}]
    undo, _ = _patch_replay(cap, els=moved)
    try:
        macro = _macro(mid="cu-20260918-150000-evt-h7j6", steps=[
            _click_step(1),
            _click_step(2, x=7, y=8, element=None),      # 这步走像素回落
        ])
        run = cm.run_replay(_fresh_run(macro), macro)
        check("H1 每步推 replay_step 事件（resource=cu_macro）",
              len(events) == 2
              and all(e["resource"] == "cu_macro" and e["action"] == "replay_step"
                      for e in events), str(events))
        check("H1b 事件带 seq/step_action/命中方式/ok 且顺序正确",
              [e["seq"] for e in events] == [1, 2]
              and [e["step_action"] for e in events] == ["click", "click"]
              and [e["method"] for e in events] == ["element", "pixel_fallback"]
              and all(e["ok"] is True for e in events)
              and all(e["macro_id"] == macro["id"] for e in events), str(events))
    finally:
        undo()
        ae.notify = orig_notify

    # H2：中止路径也推事件（失败步 ok=False，事件序列不含后续步）
    events.clear()
    ae.notify = lambda resource, action, project_id=None, **kw: \
        (events.append({"resource": resource, "action": action, **kw}), True)[1]
    cap2 = _CapExec()
    undo2, _ = _patch_replay(cap2, els=[], last_error="app_not_found: x")
    try:
        macro = _macro(steps=[_click_step(1), _click_step(2)])
        cm.run_replay(_fresh_run(macro), macro)
        check("H2 中止步推 ok=False 事件且事件即止于此",
              len(events) == 1 and events[0]["ok"] is False
              and events[0]["method"] == "abort" and events[0]["seq"] == 1, str(events))
    finally:
        undo2()
        ae.notify = orig_notify


# ── I 组：端点（TestClient；有步宏回放时 executor 桩化，⛔绝不触发真实动作）───
def test_i_endpoints():
    isolate_all("cum_i_")
    from fastapi.testclient import TestClient
    import sidecar.app as appmod
    import sidecar.computer_use.cu_macro as cm
    c = TestClient(appmod.app)

    r = c.get("/api/cu-macros")
    check("I1 空列表 + recording=False + recording_steps=0 + recording_mode=None（0.4.34 R4 新字段）",
          r.status_code == 200 and r.json() == {"ok": True, "macros": [],
                                                "recording": False,
                                                "recording_steps": 0,
                                                "recording_mode": None}, r.text[:150])

    r = c.post("/api/cu-macros/record/start", json={})
    check("I2 缺 name→422", r.status_code == 422, f"{r.status_code}")
    r = c.post("/api/cu-macros/record/start", json={"name": "   "})
    check("I2b 空白名→422", r.status_code == 422, f"{r.status_code}")

    r = c.post("/api/cu-macros/record/start", json={"name": "端点宏"})
    check("I3 开始录制→ok", r.status_code == 200 and r.json().get("ok") is True,
          r.text[:150])
    r = c.post("/api/cu-macros/record/start", json={"name": "重复"})
    check("I3b 重复开始→422（单例）", r.status_code == 422, f"{r.status_code}")
    r = c.get("/api/cu-macros")
    check("I3c 列表 recording=True 且 recording_steps=0",
          r.json().get("recording") is True and r.json().get("recording_steps") == 0,
          r.text[:150])
    # 录制中落一步（直接调模块挂钩，等价 executor 成功动作落宏），轮询应见递增
    cm.record_step({"action": "click", "x": 1, "y": 2, "app": "FakeApp", "payload": {}})
    r = c.get("/api/cu-macros")
    check("I3d 录制中 recording_steps=1（前端轮询实时步数）",
          r.json().get("recording_steps") == 1, r.text[:150])

    r = c.post("/api/cu-macros/record/stop")
    body = r.json()
    check("I4 有步停止→saved=True 落盘返回完整宏", r.status_code == 200
          and body.get("ok") is True and body.get("saved") is True
          and body.get("macro", {}).get("name") == "端点宏"
          and body["macro"].get("id", "").startswith("cu-")
          and len(body["macro"].get("steps") or []) == 1, r.text[:200])
    mid = body["macro"]["id"]
    r = c.get("/api/cu-macros")
    check("I4b 列表含新宏（steps=1 摘要）且 recording_steps 归 0",
          any(m["id"] == mid and m["steps"] == 1 for m in r.json().get("macros", []))
          and r.json().get("recording_steps") == 0, r.text[:200])

    # 0.4.33（F2）空宏防护（问题3 实测）：录制窗口内无任何动作 → 不落盘，
    # HTTP 200 契约逐字 {ok, saved:false, steps:0, message}
    r = c.post("/api/cu-macros/record/start", json={"name": "空转宏"})
    check("I4c 再次开始录制→ok", r.status_code == 200 and r.json().get("ok") is True,
          r.text[:150])
    r = c.post("/api/cu-macros/record/stop")
    check("I4d 0 步 stop→200 且契约逐字（变异 4 守护）",
          r.status_code == 200
          and r.json() == {"ok": True, "saved": False, "steps": 0,
                           "message": "未捕获到任何动作，宏未保存"}, r.text[:200])
    r = c.get("/api/cu-macros")
    check("I4e 0 步未落盘（列表仍只有 1 个宏）且未在录制",
          len(r.json().get("macros", [])) == 1
          and r.json().get("recording") is False, r.text[:200])

    r = c.post("/api/cu-macros/record/stop")
    check("I5 未录制 stop→422", r.status_code == 422, f"{r.status_code}")

    # 0.4.33（F2）0 步宏回放 → 422「宏没有可回放的步骤」（此前静默完成=假成功）
    cm.save_macro(_macro(mid="cu-20260918-130000-empty-e5m5", steps=[]))
    r = c.post("/api/cu-macros/cu-20260918-130000-empty-e5m5/replay")
    check("I6 0 步宏回放→422 含「宏没有可回放的步骤」（变异 5 守护）",
          r.status_code == 422
          and "宏没有可回放的步骤" in str(r.json().get("detail")),
          f"{r.status_code} {r.text[:150]}")

    # 有步宏回放不受影响（executor 桩化，⛔零真实事件）
    cap = _CapExec()
    undo, _ = _patch_replay(cap, els=[])
    try:
        r = c.post(f"/api/cu-macros/{mid}/replay")
        check("I6b 有步宏回放→立即返回 run_id", r.status_code == 200
              and str(r.json().get("run_id", "")).startswith("run-"), r.text[:150])
        run_id = r.json()["run_id"]
        st = None
        for _ in range(50):                       # 轮询回放状态（≤5s）
            rr = c.get(f"/api/cu-macros/replays/{run_id}")
            if rr.status_code == 200 and rr.json().get("run", {}).get("status") != "running":
                st = rr.json()["run"]
                break
            time.sleep(0.1)
        check("I6c 有步宏回放→done 且按原像素点击（不受空宏防护影响）",
              st and st.get("status") == "done" and st.get("macro_id") == mid
              and cap.clicks == [(1, 2, "left", 1)],
              f"run={str(st)[:150]} clicks={cap.clicks}")
    finally:
        undo()
        cm._REPLAY_BUSY = False

    r = c.post("/api/cu-macros/cu-20990101-000000-none-zzzz/replay")
    check("I7 回放不存在宏→404", r.status_code == 404, f"{r.status_code}")
    r = c.post("/api/cu-macros/..%2F..%2Fetc/replay")
    check("I7b 回放路径穿越→非 200", r.status_code != 200, f"{r.status_code}")
    r = c.get("/api/cu-macros/replays/run-nonexistent")
    check("I8 查询不存在 run→404", r.status_code == 404, f"{r.status_code}")

    r = c.delete("/api/cu-macros/..%2F..%2Fetc")
    check("I9 删除路径穿越→非 200（id 校验）", r.status_code != 200, f"{r.status_code}")
    r = c.delete("/api/cu-macros/cu-20990101-000000-none-zzzz")
    check("I9b 删除不存在→404", r.status_code == 404, f"{r.status_code}")
    r = c.delete(f"/api/cu-macros/{mid}")
    check("I9c 删除→deleted=True",
          r.status_code == 200 and r.json().get("deleted") is True, r.text[:150])
    r = c.delete("/api/cu-macros/cu-20260918-130000-empty-e5m5")
    check("I9d 删除存量 0 步宏→列表清空",
          r.status_code == 200
          and c.get("/api/cu-macros").json().get("macros") == [], r.text[:150])


# ── J 组：start_replay 异步契约（busy 守卫 / not_found / 线程执行）───────────
def test_j_start_replay():
    import sidecar.computer_use.cu_macro as cm
    isolate_all("cum_j_")

    check("J1 宏不存在→not_found", cm.start_replay("cu-20990101-000000-none-zzzz")
          .get("error") == "not_found")
    check("J1b 非法 id→not_found（不触盘）",
          cm.start_replay("../etc").get("error") == "not_found")

    # J2：busy 守卫——真实键鼠独占，并发回放 422 语义
    #（0.4.33 F2：busy 校验在空宏防护之后，故本用例必须用有步宏才能走到 busy 分支）
    macro = _macro(steps=[_click_step(1)])
    cm.save_macro(macro)
    cm._REPLAY_BUSY = True
    try:
        r = cm.start_replay(macro["id"])
        check("J2 回放中再起→replay_busy", r.get("ok") is False
              and "replay_busy" in str(r.get("error")), str(r))
    finally:
        cm._REPLAY_BUSY = False

    # J3：后台线程真实执行（executor 已桩化，⛔零真实事件）且忙锁事后释放
    cap = _CapExec()
    moved = [{"role": "AXButton", "title": "删除",
              "frame": (500.0, 600.0, 40.0, 20.0), "depth": 1}]
    undo, _ = _patch_replay(cap, els=moved)
    try:
        m2 = _macro(mid="cu-20260918-160000-thr-k9m8", steps=[_click_step(1)])
        cm.save_macro(m2)
        r = cm.start_replay(m2["id"])
        check("J3 异步回放→立即返回 run_id", r.get("ok") is True
              and str(r.get("run_id", "")).startswith("run-"), str(r))
        run = None
        for _ in range(50):
            run = cm.get_run(r["run_id"])
            if run and run.get("status") != "running":
                break
            time.sleep(0.1)
        check("J3b 线程跑完→done 且点击落在重定位中心",
              run and run.get("status") == "done"
              and cap.clicks == [(520.0, 610.0, "left", 1)],
              f"run={str(run)[:150]} clicks={cap.clicks}")
        check("J3c 忙锁已释放（可再次回放）", cm._REPLAY_BUSY is False)
    finally:
        undo()
        cm._REPLAY_BUSY = False


def main():
    print("=" * 70)
    print("0.4.32（CU 三期 P2）任务宏：录制/保存/列表/回放/删除 专项回归")
    print("⛔ 全程不产生真实点击/输入（假 CG/CF/AS 层 + executor 捕获桩）")
    if MUTATE:
        print(f"⚠️ 变异 {MUTATE} 已注入（预期本套件变红；全绿=断言无效）")
    print("=" * 70)
    try:
        _apply_mutation()
        test_a_storage()
        test_b_recorder()
        test_k_empty_macro_guard()
        test_c_executor_hook()
        test_d_replay_relocate()
        test_e_replay_fallback()
        test_f_replay_abort()
        test_g_replay_payload()
        test_h_replay_events()
        test_i_endpoints()
        test_j_start_replay()
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
