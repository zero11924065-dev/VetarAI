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
"""0.4.34（CU 四期 R4）专项回归：用户手动操作录制宏（CGEventTap listen-only 路线）。

⛔ 测试铁律（同 test_cu_macro.py）：绝不需要真实 TCC 权限、绝不触碰真机键鼠——
- 归并层（A~G 组）：user_recorder 的全部系统探针（frontmost/hit-test/安全输入/时钟）
  依赖注入换成假探针，直接喂规范化事件流（_key/_down/_up），断言归并出的宏 step；
- 契约层（H 组）：patch user_recorder.start_capture / listen_access_granted 为假捕获，
  端点走 TestClient，回放链路 executor 三动作桩化（复用 test_cu_macro._patch_replay）；
- 真机路径（真实 tap 创建/CFRunLoop/系统弹窗）本套件不覆盖，标注「需实测」进挂起项。

变异测试机制（MUTATE=1|2|3|4|5 .venv/bin/python -m sidecar.computer_use.test_cu_user_record）：
  1 = 双击合并失效（吞成两个 click → B 组灭）
  2 = 密码防护失效（安全输入段照录 → D 组灭）
  3 = 自身过滤失效（VetarAI/Electron 前台事件照录 → E 组灭）
  4 = 特殊键截断失效（退格前后文本被吞进同一段 type → A 组灭）
  5 = user 模式未授权守卫失效（未授权也放行 → H 组 403 用例灭）
"""
import importlib
import os
import sys
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
    import sidecar.computer_use.user_recorder as ur
    import sidecar.computer_use.cu_macro as cm
    ur_src = Path(ur.__file__)
    if MUTATE == 1:
        _mutate_file(ur_src,
                     "        if button == \"left\" and self._dbl_armed and self._pending_click is not None:\n"
                     "            # ⛔ MUTATE锚点：同点双击必须合并为 double_click（而不是两个 click）",
                     "        if False:  # 变异1：双击不合并（吞成两个 click）",
                     "ur")
    elif MUTATE == 2:
        _mutate_file(ur_src,
                     "        if self._secure() is True or self._focused_secure():",
                     "        if False:  # 变异2：密码段照录（防护失效）",
                     "ur")
    elif MUTATE == 3:
        _mutate_file(ur_src,
                     "                if self._is_self(name, bid, pid):\n"
                     "                    # ⛔ MUTATE锚点：本应用（VetarAI/Electron）前台时事件不录",
                     "                if False:  # 变异3：自身事件照录",
                     "ur")
    elif MUTATE == 4:
        _mutate_file(ur_src,
                     "        # ⛔ MUTATE锚点：退格/回车等特殊键必须截断打字聚合\n"
                     "        self._flush_text_locked()",
                     "        pass  # 变异4：特殊键不截断（聚合吞并退格前后文本）",
                     "ur")
    elif MUTATE == 5:
        _mutate_file(Path(cm.__file__),
                     "            if _ur.listen_access_granted() is False:",
                     "            if False:  # 变异5：未授权也放行（403 守卫失效）",
                     "cm")
    else:
        raise SystemExit(f"未知变异编号 {MUTATE}（支持 1|2|3|4|5）")
    importlib.reload(ur)
    importlib.reload(cm)


def _restore() -> None:
    if not MUTATE or not _BACKUP:
        return
    try:
        for path, s in _BACKUP.values():
            path.write_text(s, encoding="utf-8")
    finally:
        _BACKUP.clear()
        import sidecar.computer_use.user_recorder as ur
        import sidecar.computer_use.cu_macro as cm
        importlib.reload(ur)
        importlib.reload(cm)


from sidecar.computer_use.test_cu_macro import (  # noqa: E402  复用既有隔离/桩件（同包先例）
    isolate_all, _CapExec, _patch_replay, _macro, _click_step)


# ── 事件流构造 + 假探针录制器工厂 ─────────────────────────────────────────
def _key(keycode, flags=0, text="", ts=1.0):
    return {"kind": "key", "keycode": keycode, "flags": flags, "text": text, "ts": ts}


def _down(x, y, button="left", ts=1.0):
    return {"kind": "mouse_down", "x": x, "y": y, "button": button, "ts": ts}


def _up(x, y, button="left", ts=1.0):
    return {"kind": "mouse_up", "x": x, "y": y, "button": button, "ts": ts}


def _mk_rec(steps, front=None, hit=None, secure=False, focused=False,
            max_seconds=600.0, on_timeout=None):
    """构造全假探针的 UserRecorder（绝不 start()，直接 _ingest 事件流）。"""
    import sidecar.computer_use.user_recorder as ur
    state = {"front": front or ("Notes", "com.apple.Notes", 4242)}
    rec = ur.UserRecorder(
        on_step=steps.append,
        on_timeout=on_timeout,
        max_seconds=max_seconds,
        front_fn=lambda: state["front"],
        hit_fn=hit or (lambda x, y: None),
        secure_fn=(lambda: secure),
        focused_secure_fn=(lambda: focused),
        now_fn=lambda: 1000.0)
    return rec, state


def _feed(rec, *events):
    for ev in events:
        rec._ingest(ev)


def _types(steps):
    return [s["payload"]["text"] for s in steps if s["action"] == "type"]


def _keys(steps):
    return [s["payload"]["keys"] for s in steps if s["action"] == "key"]


def _clicks(steps):
    return [(s["action"], s["x"], s["y"]) for s in steps
            if s["action"] in ("click", "double_click", "right_click")]


# ── A 组：打字聚合与截断（归并质量核心）──────────────────────────────────
def test_a_typing_merge():
    import sidecar.computer_use.user_recorder as ur
    isolate_all("cur_a_")

    # A1：连续字符聚合成一个 type step；回车截断并落 key step
    steps = []
    rec, _ = _mk_rec(steps)
    _feed(rec, _key(4, ts=1.0), _key(14, ts=1.1), _key(37, ts=1.2),
          _key(37, ts=1.3), _key(31, ts=1.4),          # h e l l o
          _key(36, ts=1.5))                            # return
    check("A1 连续字符聚合为一个 type step", _types(steps) == ["hello"], str(steps))
    check("A1b 回车截断并落 key step（keys=return）",
          _keys(steps) == ["return"], str(steps))
    check("A1c type step 结构对齐宏契约（x/y None、app、element None）",
          steps[0]["x"] is None and steps[0]["y"] is None
          and steps[0]["app"] == "Notes" and steps[0]["element"] is None
          and set(steps[0].keys()) == {"action", "x", "y", "app", "element", "payload"},
          str(steps[0]))

    # A2：退格截断（⛔ 变异4 守护：退格前后文本不得吞进同一段）
    steps = []
    rec, _ = _mk_rec(steps)
    _feed(rec, _key(0, ts=1.0), _key(11, ts=1.1), _key(8, ts=1.2),   # a b c
          _key(51, ts=1.3),                                          # delete
          _key(2, ts=1.4))                                           # d
    rec.stop()                                                       # 收尾 flush 末段打字
    check("A2 退格截断聚合（abc | delete | d）",
          _types(steps) == ["abc", "d"] and _keys(steps) == ["delete"], str(steps))

    # A3：切换焦点截断（不同 app 的击键绝不聚进同一段）
    steps = []
    rec, st = _mk_rec(steps)
    _feed(rec, _key(0, ts=1.0), _key(11, ts=1.1))                    # App 默认 Notes: "ab"
    st["front"] = ("Safari", "com.apple.Safari", 5555)
    _feed(rec, _key(8, ts=1.2), _key(2, ts=1.3))                     # "cd"
    rec.stop()                                                       # 收尾 flush 末段打字
    ts_app = [(s["payload"]["text"], s["app"]) for s in steps if s["action"] == "type"]
    check("A3 切换焦点截断（ab@Notes / cd@Safari）",
          ts_app == [("ab", "Notes"), ("cd", "Safari")], str(steps))

    # A4：点击截断（打字中点击 → 先落 type，再记 click）
    steps = []
    rec, _ = _mk_rec(steps)
    _feed(rec, _key(0, ts=1.0), _key(11, ts=1.1),
          _down(100, 200, ts=1.2), _up(100, 200, ts=1.25))
    rec._tick(2.0)                                                   # 双击窗口过，点击定案
    check("A4 点击截断打字聚合且动作顺序正确",
          [s["action"] for s in steps] == ["type", "click"]
          and steps[0]["payload"]["text"] == "ab", str(steps))

    # A5：shift 变体与 IME text 直达
    steps = []
    rec, _ = _mk_rec(steps)
    _feed(rec, _key(0, flags=ur._F_SHIFT, ts=1.0),                   # A（shift 映射）
          _key(18, flags=ur._F_SHIFT, ts=1.1),                       # !
          _key(7, text="≈", ts=1.2))                                 # IME/option 字符直达
    rec.stop()
    check("A5 shift 变体 + IME text 直达聚合（A!≈）",
          _types(steps) == ["A!≈"], str(steps))

    # A6：option+字母无 text → 跳过（无法确定字符，录错比漏录糟）
    steps = []
    rec, _ = _mk_rec(steps)
    _feed(rec, _key(7, flags=ur._F_OPT, ts=1.0),
          _key(0, ts=1.1))
    rec.stop()
    check("A6 option+字母无 text 跳过、普通键不受影响",
          _types(steps) == ["a"], str(steps))


# ── B 组：鼠标归并（单击定案/双击合并/右键/拖拽取舍）─────────────────────
def test_b_mouse_merge():
    isolate_all("cur_b_")

    # B1：单击暂缓定案 → ticker 过双击窗口后落 click
    steps = []
    rec, _ = _mk_rec(steps)
    _feed(rec, _down(100, 200, ts=1.0), _up(100, 200, ts=1.1))
    check("B1 双击窗口内单击未定案（暂不落步）", steps == [], str(steps))
    rec._tick(1.7)
    check("B1b 窗口过后定案为 click（坐标=按下点，payload 契约）",
          _clicks(steps) == [("click", 100.0, 200.0)]
          and steps[0]["payload"] == {"button": "left", "clicks": 1}, str(steps))

    # B2：同点双击合并为一个 double_click（⛔ 变异1 守护）
    steps = []
    rec, _ = _mk_rec(steps)
    _feed(rec, _down(100, 200, ts=1.0), _up(100, 200, ts=1.1),
          _down(101, 201, ts=1.2), _up(101, 201, ts=1.3))
    check("B2 同点双击合并 double_click（clicks=2，坐标取首次按下点）",
          _clicks(steps) == [("double_click", 100.0, 200.0)]
          and steps[0]["payload"]["clicks"] == 2, str(steps))

    # B3：间隔超窗 → 两个 click；位移超阈 → 两个 click
    steps = []
    rec, _ = _mk_rec(steps)
    _feed(rec, _down(100, 200, ts=1.0), _up(100, 200, ts=1.1),
          _down(100, 200, ts=2.0), _up(100, 200, ts=2.1))             # 间隔 0.9s 超窗
    rec._tick(3.0)
    check("B3 间隔超双击窗口 → 两个 click",
          _clicks(steps) == [("click", 100.0, 200.0), ("click", 100.0, 200.0)], str(steps))
    steps = []
    rec, _ = _mk_rec(steps)
    _feed(rec, _down(100, 200, ts=1.0), _up(100, 200, ts=1.1),
          _down(140, 200, ts=1.2), _up(140, 200, ts=1.3))             # 位移 40px 超阈
    rec._tick(3.0)
    check("B3b 位移超阈 → 两个 click（不合并双击）",
          _clicks(steps) == [("click", 100.0, 200.0), ("click", 140.0, 200.0)], str(steps))

    # B4：右键 → right_click
    steps = []
    rec, _ = _mk_rec(steps)
    _feed(rec, _down(50, 60, button="right", ts=1.0), _up(50, 60, button="right", ts=1.1))
    rec._tick(2.0)
    check("B4 右键定案 right_click",
          _clicks(steps) == [("right_click", 50.0, 60.0)]
          and steps[0]["payload"] == {"button": "right", "clicks": 1}, str(steps))

    # B5：拖拽取舍（拍板）：记为【起点单击】+ payload.drag_to 落盘佐证，立即定案
    steps = []
    rec, _ = _mk_rec(steps)
    _feed(rec, _down(100, 100, ts=1.0), _up(300, 260, ts=1.6))
    check("B5 拖拽 → 起点单击 + drag_to，且立即定案（不待双击窗口）",
          _clicks(steps) == [("click", 100.0, 100.0)]
          and steps[0]["payload"].get("drag_to") == [300.0, 260.0], str(steps))

    # B6：中键 → 按 click 记，payload 如实写 button=other
    steps = []
    rec, _ = _mk_rec(steps)
    _feed(rec, _down(10, 10, button="other", ts=1.0), _up(10, 10, button="other", ts=1.1))
    rec._tick(2.0)
    check("B6 中键按 click 记（payload button=other）",
          _clicks(steps) == [("click", 10.0, 10.0)]
          and steps[0]["payload"]["button"] == "other", str(steps))


# ── C 组：hotkey 与特殊键 ────────────────────────────────────────────────
def test_c_hotkey():
    import sidecar.computer_use.user_recorder as ur
    isolate_all("cur_c_")

    # C1：cmd+c / cmd+shift+4 → hotkey step（回放走 keyboard_hotkey，键名须其认得）
    steps = []
    rec, _ = _mk_rec(steps)
    _feed(rec, _key(8, flags=ur._F_CMD, ts=1.0),                     # cmd+c
          _key(21, flags=ur._F_CMD | ur._F_SHIFT, ts=1.1))           # cmd+shift+4
    check("C1 修饰组合键 → hotkey step（cmd+c / cmd+shift+4）",
          _keys(steps) == ["cmd+c", "cmd+shift+4"], str(steps))

    # C2：组合键截断打字聚合
    steps = []
    rec, _ = _mk_rec(steps)
    _feed(rec, _key(0, ts=1.0), _key(8, flags=ur._F_CMD, ts=1.1))
    check("C2 hotkey 截断打字聚合", _types(steps) == ["a"] and _keys(steps) == ["cmd+c"],
          str(steps))

    # C3：纯修饰键 down 不记（组合键以主键为准）
    steps = []
    rec, _ = _mk_rec(steps)
    _feed(rec, _key(55, ts=1.0), _key(56, ts=1.1))
    rec.stop()
    check("C3 纯修饰键不落步", steps == [], str(steps))

    # C4：option+方向键 → option+left（键名须 keyboard_hotkey 认得）
    steps = []
    rec, _ = _mk_rec(steps)
    _feed(rec, _key(123, flags=ur._F_OPT, ts=1.0))
    check("C4 option+left → option+left", _keys(steps) == ["option+left"], str(steps))

    # C5：shift+return → shift+return
    steps = []
    rec, _ = _mk_rec(steps)
    _feed(rec, _key(36, flags=ur._F_SHIFT, ts=1.0))
    check("C5 shift+return → shift+return", _keys(steps) == ["shift+return"], str(steps))

    # C6：hotkey 产物可被 executor.keyboard_hotkey 解析（键名合法性的硬保证）
    from sidecar.computer_use import executor as _ex
    bad = [k for k in ("cmd+c", "cmd+shift+4", "option+left", "shift+return", "return",
                       "delete", "tab", "escape")
           if k.split("+")[-1] not in _ex._KEYCODES]
    check("C6 全部键名 executor.keyboard_hotkey 认得", bad == [], str(bad))


# ── D 组：密码防护（安全输入段整段不记，连长度都不记）─────────────────────
def test_d_secure_guard():
    isolate_all("cur_d_")

    # D1：IsSecureEventInputEnabled → 按键整段丢弃（⛔ 变异2 守护）
    steps = []
    rec, _ = _mk_rec(steps, secure=True)
    _feed(rec, _key(35, ts=1.0), _key(13, ts=1.1), _key(51, ts=1.2),
          _key(8, flags=1 << 20, ts=1.3))
    check("D1 安全输入段按键/退格/组合键全部不落步", steps == [], str(steps))
    check("D1b 丢弃计数（诊断用，不进宏——连长度都不记）",
          rec.secure_dropped == 4, str(rec.secure_dropped))

    # D2：焦点 AXSecureTextField（系统标志未开时第二道闸）
    steps = []
    rec, _ = _mk_rec(steps, secure=False, focused=True)
    _feed(rec, _key(35, ts=1.0))
    check("D2 焦点密码框（AXSecureTextField）同样整段不记", steps == []
          and rec.secure_dropped == 1, str(steps))

    # D3：进入密码段前的明文先落（它不属于密码），离开后恢复正常
    steps = []
    state = {"secure": False}
    rec, _ = _mk_rec(steps)
    rec._secure = lambda: state["secure"]
    _feed(rec, _key(0, ts=1.0), _key(11, ts=1.1))                    # "ab"（明文）
    state["secure"] = True
    _feed(rec, _key(35, ts=1.2))                                     # 密码字符 → 丢弃
    state["secure"] = False
    _feed(rec, _key(8, ts=1.3))                                      # "c"（恢复明文）
    rec.stop()
    check("D3 密码段前后明文各自成段、密码字符零泄漏",
          _types(steps) == ["ab", "c"], str(steps))


# ── E 组：自身过滤（VetarAI/Electron 前台事件不录）────────────────────────
def test_e_self_filter():
    isolate_all("cur_e_")

    # E1：frontmost=VetarAI → 键鼠全部不录（⛔ 变异3 守护）
    steps = []
    rec, _ = _mk_rec(steps, front=("VetarAI", "com.vetarai.app", 9001))
    _feed(rec, _key(0, ts=1.0), _down(100, 100, ts=1.1), _up(100, 100, ts=1.2))
    rec._tick(2.0)
    check("E1 VetarAI 前台事件全部不录", steps == [], str(steps))

    # E2：开发态 Electron 名同样过滤；bundle id com.vetarai* 过滤（名字再花哨也拦）
    for front in (("Electron", "", 9002), ("随便什么名", "com.vetarai.dev", 9003)):
        steps = []
        rec, _ = _mk_rec(steps, front=front)
        _feed(rec, _key(0, ts=1.0))
        rec.stop()
        check(f"E2 自身前台 {front[0]!r}/{front[1]!r} 不录", steps == [], str(steps))

    # E3：切回自己窗口 = 焦点切换，截断已聚合的打字段（打字内容本身不丢）
    steps = []
    rec, st = _mk_rec(steps)
    _feed(rec, _key(0, ts=1.0), _key(11, ts=1.1))                    # Notes 里 "ab"
    st["front"] = ("VetarAI", "com.vetarai.app", 9001)
    _feed(rec, _key(8, ts=1.2))                                      # 点宏面板的按键 → 不录
    st["front"] = ("Notes", "com.apple.Notes", 4242)
    _feed(rec, _key(8, ts=1.3))                                      # 回 Notes "c"
    rec.stop()
    check("E3 自身段只截断不吞并（ab | c，宏面板按键零泄漏）",
          _types(steps) == ["ab", "c"], str(steps))


# ── F 组：元素语义富化（AX hit-test 复用，失败只记坐标）──────────────────
def test_f_element_enrich():
    isolate_all("cur_f_")

    # F1：命中 → role/title/frame/app 写进 step（回放语义重定位的燃料）
    hit = {"role": "AXButton", "title": "存储", "frame": [100.0, 200.0, 40.0, 20.0],
           "app": "FakeApp"}
    steps = []
    rec, _ = _mk_rec(steps, hit=lambda x, y: hit)
    _feed(rec, _down(110, 210, ts=1.0), _up(110, 210, ts=1.1))
    rec._tick(2.0)
    el = steps[0]["element"] if steps else None
    check("F1 命中元素写进 step（role/title/frame/app）",
          el == {"role": "AXButton", "title": "存储",
                 "frame": [100.0, 200.0, 40.0, 20.0]}
          and steps[0]["app"] == "FakeApp", str(steps))

    # F2：hit-test 失败 → 只记坐标 + frontmost app（回放自然回落 pixel_fallback）
    steps = []
    rec, _ = _mk_rec(steps, hit=lambda x, y: None)
    _feed(rec, _down(33, 44, ts=1.0), _up(33, 44, ts=1.1))
    rec._tick(2.0)
    check("F2 未命中 → element=None + frontmost app",
          steps[0]["element"] is None and steps[0]["app"] == "Notes", str(steps))

    # F3：hit-test 抛异常 → 同失败回落（命中是增强，坐标才是主流程）
    def boom(x, y):
        raise RuntimeError("AX 炸了")
    steps = []
    rec, _ = _mk_rec(steps, hit=boom)
    _feed(rec, _down(55, 66, ts=1.0), _up(55, 66, ts=1.1))
    rec._tick(2.0)
    check("F3 hit-test 异常不炸录制、回落纯坐标",
          _clicks(steps) == [("click", 55.0, 66.0)] and steps[0]["element"] is None,
          str(steps))


# ── G 组：生命周期（硬上限自动停 / stop flush 收尾 / 幂等）─────────────────
def test_g_lifecycle():
    isolate_all("cur_g_")

    # G1：硬上限到点 → on_timeout 恰好触发一次（视作正常 stop 的触发源）
    fired = []
    steps = []
    rec, _ = _mk_rec(steps, max_seconds=600.0, on_timeout=lambda: fired.append(1))
    rec._tick(1000.0 + 599.9)                                        # 未到点
    check("G1 未到上限不触发", fired == [], str(fired))
    rec._tick(1000.0 + 600.0)                                        # 到点
    rec._tick(1000.0 + 900.0)                                        # 重复 tick 不重复触发
    check("G1b 到点触发且仅一次（⛔ 硬上限自动停）", fired == [1], str(fired))

    # G2：stop flush 收尾——打字段 + 待定案点击全部落宏（宏不丢尾巴）
    steps = []
    rec, _ = _mk_rec(steps)
    _feed(rec, _key(0, ts=1.0), _key(11, ts=1.1),
          _down(100, 200, ts=1.2), _up(100, 200, ts=1.25))
    rec.stop()
    check("G2 stop flush 收尾步骤全落（type + click）",
          [s["action"] for s in steps] == ["type", "click"]
          and steps[0]["payload"]["text"] == "ab", str(steps))

    # G3：stop 幂等（重复 stop 不炸、不重复落步）；未 start 直接 stop 安全
    rec.stop()
    check("G3 stop 幂等且不重复 flush",
          [s["action"] for s in steps] == ["type", "click"], str(steps))
    steps2 = []
    rec2, _ = _mk_rec(steps2)
    rec2.stop()
    check("G3b 空录制 stop 安全（零步骤零异常）", steps2 == [], str(steps2))


# ── H 组：端点契约 1-6（TestClient + 假捕获层，⛔零真实 TCC/键鼠）──────────
class _FakeCapture:
    """user_recorder.start_capture 的假产物：记录回调与 stop 调用。"""

    def __init__(self):
        self.stopped = False

    def stop(self):
        self.stopped = True


def _patch_user_record(granted=True):
    """把 user_recorder 的系统面全部钉住。返回 (caps, undo)；
    caps 暴露 on_step/on_timeout/max_seconds/capture 供驱动录制。"""
    import sidecar.computer_use.user_recorder as ur
    saved = (ur.listen_access_granted, ur.request_listen_access, ur.start_capture)
    caps: dict = {}
    ur.listen_access_granted = lambda: granted
    ur.request_listen_access = lambda: granted

    def fake_start(on_step=None, on_timeout=None, max_seconds=600.0, **kw):
        caps["on_step"] = on_step
        caps["on_timeout"] = on_timeout
        caps["max_seconds"] = max_seconds
        caps["capture"] = _FakeCapture()
        return caps["capture"]

    ur.start_capture = fake_start

    def undo():
        (ur.listen_access_granted, ur.request_listen_access, ur.start_capture) = saved

    return caps, undo


def _cleanup_cm():
    import sidecar.computer_use.cu_macro as cm
    try:
        if cm.is_recording():
            cm.stop_recording()
    except Exception:
        pass
    cm._REPLAY_BUSY = False


def test_h_contracts():
    isolate_all("cur_h_")
    from fastapi.testclient import TestClient
    import sidecar.app as appmod
    import sidecar.computer_use.cu_macro as cm
    c = TestClient(appmod.app)

    # ── 契约4：permission 端点（GET 查询 / POST 触发弹窗后如实返回）──
    caps, undo = _patch_user_record(granted=False)
    try:
        r = c.get("/api/cu-macros/user-record/permission")
        check("H1 GET permission → {ok, granted:false}",
              r.status_code == 200
              and r.json() == {"ok": True, "granted": False}, r.text[:150])
        r = c.post("/api/cu-macros/user-record/permission/request")
        check("H1b POST permission/request → {ok, granted:false}（用户未批）",
              r.status_code == 200
              and r.json() == {"ok": True, "granted": False}, r.text[:150])
    finally:
        undo()
    caps, undo = _patch_user_record(granted=True)
    try:
        r = c.get("/api/cu-macros/user-record/permission")
        check("H1c 已授权 → granted:true", r.json() == {"ok": True, "granted": True},
              r.text[:150])
    finally:
        undo()

    # ── 契约5：user 模式未授权 → 403 + 中文指引（⛔ 变异5 守护）──
    caps, undo = _patch_user_record(granted=False)
    try:
        r = c.post("/api/cu-macros/record/start", json={"name": "u宏", "mode": "user"})
        check("H2 user 未授权 → 403", r.status_code == 403, f"{r.status_code}")
        detail = str(r.json().get("detail"))
        check("H2b detail 前缀 + 中文指引「系统设置→隐私与安全性→输入监控」",
              detail.startswith("input_monitoring_not_granted")
              and "系统设置→隐私与安全性→输入监控" in detail, detail[:200])
        check("H2c 未授权未进入录制（recording_mode=None）",
              cm.recording_mode() is None and cm.is_recording() is False)
    finally:
        undo()
        _cleanup_cm()

    # ── 契约1+2：mode 字段与 recording_mode；缺省 agent 零变化 ──
    caps, undo = _patch_user_record(granted=True)
    try:
        r = c.post("/api/cu-macros/record/start", json={"name": "缺省宏"})
        check("H3 缺省 mode=agent（现状零变化）",
              r.status_code == 200 and r.json().get("ok") is True
              and cm.recording_mode() == "agent", r.text[:150])
        r = c.get("/api/cu-macros")
        check("H3b 契约2：recording_mode=agent",
              r.json().get("recording_mode") == "agent"
              and r.json().get("recording") is True, r.text[:150])
        r = c.post("/api/cu-macros/record/start", json={"name": "重", "mode": "user"})
        check("H3c agent 录制中 user start → 409（契约6 跨模式互斥）",
              r.status_code == 409, f"{r.status_code}")
        r = c.post("/api/cu-macros/record/start", json={"name": "重2"})
        check("H3d agent+agent 重复开始保持 422（现状零变化）",
              r.status_code == 422, f"{r.status_code}")
        c.post("/api/cu-macros/record/stop")
        r = c.post("/api/cu-macros/record/start", json={"name": "bad", "mode": "root"})
        check("H3e 非法 mode → 422", r.status_code == 422, f"{r.status_code}")
    finally:
        undo()
        _cleanup_cm()

    # ── user 模式完整生命周期：start → 假捕获吐步 → 轮询步数 → stop 落盘 ──
    caps, undo = _patch_user_record(granted=True)
    try:
        r = c.post("/api/cu-macros/record/start", json={"name": "用户宏", "mode": "user"})
        check("H4 user start → ok 且 recording_mode=user",
              r.status_code == 200 and r.json().get("ok") is True
              and r.json().get("mode") == "user"
              and cm.recording_mode() == "user", r.text[:150])
        check("H4b max_seconds 来自 config 默认 600", caps.get("max_seconds") == 600.0,
              str(caps.get("max_seconds")))
        r = c.post("/api/cu-macros/record/start", json={"name": "重", "mode": "user"})
        check("H4c user 录制中再 start → 409 already_recording 风格",
              r.status_code == 409 and "already_recording" in str(r.json().get("detail")),
              f"{r.status_code} {r.text[:120]}")
        # 假捕获吐两步（等价 tap 归并后的 record_step 回调）
        caps["on_step"]({"action": "click", "x": 11, "y": 22, "app": "FakeApp",
                         "element": None, "payload": {"button": "left", "clicks": 1}})
        caps["on_step"]({"action": "type", "x": None, "y": None, "app": "FakeApp",
                         "element": None, "payload": {"text": "你好"}})
        r = c.get("/api/cu-macros")
        check("H4d 录制中 recording_steps=2（recording/recording_steps 原义不变）",
              r.json().get("recording") is True
              and r.json().get("recording_steps") == 2
              and r.json().get("recording_mode") == "user", r.text[:150])

        # ── 契约6：user 录制中 replay → 409 ──
        cm.save_macro(_macro(mid="cu-20260920-100000-rep-r1r1",
                             steps=[_click_step(1, element=None)]))
        r = c.post("/api/cu-macros/cu-20260920-100000-rep-r1r1/replay")
        check("H5 user 录制中回放 → 409 user_recording_busy（互斥）",
              r.status_code == 409
              and "user_recording_busy" in str(r.json().get("detail")),
              f"{r.status_code} {r.text[:150]}")

        # stop：假捕获被拆除 + 落盘（契约3：有步 saved:true）
        r = c.post("/api/cu-macros/record/stop")
        body = r.json()
        check("H6 user 有步 stop → saved:true 落盘（契约3 两模式同一契约）",
              r.status_code == 200 and body.get("ok") is True
              and body.get("saved") is True
              and len(body.get("macro", {}).get("steps") or []) == 2
              and body["macro"]["steps"][0]["action"] == "click"
              and body["macro"]["steps"][1]["payload"] == {"text": "你好"},
              r.text[:200])
        check("H6b stop 拆除了系统级捕获（capture.stop 被调）",
              caps["capture"].stopped is True)
        umid = body["macro"]["id"]
        r = c.get("/api/cu-macros")
        check("H6c 停止后 recording_mode=None 且宏入列表",
              r.json().get("recording_mode") is None
              and any(m["id"] == umid for m in r.json().get("macros", [])), r.text[:200])

        # ── 契约3 另一半：user 模式 0 步 stop → saved:false 不落盘（逐字契约）──
        r = c.post("/api/cu-macros/record/start", json={"name": "空转", "mode": "user"})
        check("H7 user 空转 start → ok", r.status_code == 200, r.text[:120])
        r = c.post("/api/cu-macros/record/stop")
        check("H7b user 0 步 stop → 200 契约逐字（saved:false 不落盘）",
              r.status_code == 200
              and r.json() == {"ok": True, "saved": False, "steps": 0,
                               "message": "未捕获到任何动作，宏未保存"}, r.text[:200])

        # ── 硬上限自动停：on_timeout 触发 = 正常 stop（有步落盘）──
        r = c.post("/api/cu-macros/record/start", json={"name": "超时宏", "mode": "user"})
        check("H8 再次 user start → ok", r.status_code == 200, r.text[:120])
        caps["on_step"]({"action": "key", "x": None, "y": None, "app": "FakeApp",
                         "element": None, "payload": {"keys": "cmd+c"}})
        caps["on_timeout"]()                                            # ticker 到点
        check("H8b 超时自动停：recording=False 且有步落盘（视作正常 stop）",
              cm.is_recording() is False
              and any(m["name"] == "超时宏" and m["steps"] == 1
                      for m in cm.list_macros()), str(cm.list_macros()))
        check("H8c 超时停也拆除了捕获", caps["capture"].stopped is True)

        # ── 集成证明（实现要求8）：user 模式录出的宏能被 start_replay 正常加载 ──
        cap_exec = _CapExec()
        undo2, _ = _patch_replay(cap_exec, els=[])
        try:
            r = c.post(f"/api/cu-macros/{umid}/replay")
            check("H9 user 宏 start_replay 正常加载（⛔零真实事件，executor 桩化）",
                  r.status_code == 200
                  and str(r.json().get("run_id", "")).startswith("run-"), r.text[:150])
            run = None
            for _ in range(50):
                run = cm.get_run(r.json()["run_id"])
                if run and run.get("status") != "running":
                    break
                time.sleep(0.1)
            check("H9b user 宏回放 done：click 按像素回落 + type 按 payload 重放",
                  run and run.get("status") == "done"
                  and cap_exec.clicks == [(11, 22, "left", 1)]
                  and cap_exec.types == ["你好"],
                  f"run={str(run)[:150]} clicks={cap_exec.clicks} types={cap_exec.types}")
        finally:
            undo2()
            cm._REPLAY_BUSY = False
    finally:
        undo()
        _cleanup_cm()

    # ── 契约6 反向：replay 进行中 user start → 409 replay_busy 风格 ──
    caps, undo = _patch_user_record(granted=True)
    try:
        cm._REPLAY_BUSY = True
        r = c.post("/api/cu-macros/record/start", json={"name": "冲突", "mode": "user"})
        check("H10 replay 中 user start → 409 replay_busy（对齐 _REPLAY_BUSY 守卫风格）",
              r.status_code == 409 and "replay_busy" in str(r.json().get("detail")),
              f"{r.status_code} {r.text[:150]}")
        cm._REPLAY_BUSY = False
        r = c.post("/api/cu-macros/record/start", json={"name": "不冲突"})
        check("H10b replay 中 agent start 不受新互斥影响（agent 现状零变化）",
              r.status_code == 200, f"{r.status_code}")
        c.post("/api/cu-macros/record/stop")
    finally:
        cm._REPLAY_BUSY = False
        undo()
        _cleanup_cm()


# ── J 组：config 新键（默认值 + 校验）────────────────────────────────────
def test_j_config():
    tmp = isolate_all("cur_j_")
    import sidecar.config.store as cs

    cfg = cs.get_config()
    check("J1 cu_user_record_max_seconds 默认 600",
          cfg.get("cu_user_record_max_seconds") == 600, str(cfg.get("cu_user_record_max_seconds")))

    cfg = cs.reload_config({"cu_user_record_max_seconds": 120})
    check("J2 合法值 120 接受", cfg.get("cu_user_record_max_seconds") == 120)

    for bad in (0, 5, 9, 86401, "600", True, None if False else -1):
        try:
            cs.reload_config({"cu_user_record_max_seconds": bad})
            ok = False
        except ValueError:
            ok = True
        check(f"J3 非法值 {bad!r} 拒绝（硬上限无 0=不限档）", ok)
    # 非法写入不污染既有配置
    check("J4 非法拒绝后配置仍为先前合法值",
          cs.get_config().get("cu_user_record_max_seconds") == 120)


def main():
    print("=" * 70)
    print("0.4.34（CU 四期 R4）用户手动操作录制宏 专项回归")
    print("⛔ 全程零真实 TCC 权限/真机键鼠（假探针 + 假捕获层 + executor 桩）")
    if MUTATE:
        print(f"⚠️ 变异 {MUTATE} 已注入（预期本套件变红；全绿=断言无效）")
    print("=" * 70)
    try:
        _apply_mutation()
        test_a_typing_merge()
        test_b_mouse_merge()
        test_c_hotkey()
        test_d_secure_guard()
        test_e_self_filter()
        test_f_element_enrich()
        test_g_lifecycle()
        test_h_contracts()
        test_j_config()
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
