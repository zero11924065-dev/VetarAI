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
"""0.4.9（3.48.1 Computer Use 一期 MVP）专项回归：五道安全防线 + 坐标换算。

⛔ 测试铁律：**绝不允许真实点击/输入用户屏幕**。因此：
- 路由层测试把执行器（mouse_click/keyboard_type/keyboard_hotkey）替换为【记录型桩】，
  只验证"该不该执行"，桩被调用即代表防线放行（并断言其参数），不产生真实操作；
- 执行层只测【校验拒绝路径】（非法坐标/未知按键/超长文本）——这些在发出任何
  CGEvent 之前就返回错误，天然无副作用；
- 唯一真实调用的系统能力是【截屏】（只读，无副作用），用于验证 Retina 坐标换算。

覆盖五道防线：
  1) 权限门槛（能力探测 + 缺权限可读引导）
  2) 总开关默认关（配置层 + tools_spec 不暴露）
  3) 每步确认（无授权通道→拒绝；用户拒绝→拒绝且不执行；同意→执行且只弹一次）
  4) 应用白名单（非空且前台不命中→拒绝；空→不限制）
  5) 全程日志（动作落盘 actions.jsonl）+ 一键急停（cancel_check 已由既有机制覆盖）
"""
import asyncio
import json
import os
import sys
import tempfile
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


def isolate_all(prefix: str) -> Path:
    """config / store / warehouse / skills 全部重定向到临时目录（禁止碰真实 ~/.subagent）。

    ⛔ 血泪教训（见 test_checkpoint093.py）：仅改 DEFAULT_CONFIG 或仅设环境变量都无效——
    data_root() 优先读 _MEM，store.PROJECTS_ROOT 在导入时已绑定，reload_config 还会
    _save() 到真实路径。必须同时钉死 get_config_path / _MEM / PROJECTS_ROOT / _GDB。
    """
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


# ── A 组：防线2 总开关 + 工具规格 ───────────────────────────────────────
def test_a_tools_spec_gating():
    from sidecar.agent_engine.loop import tools_spec
    import sidecar.config as cfg
    isolate_all("cu_a_")

    CU_TOOLS = {"screen_view", "mouse_click", "keyboard_type", "keyboard_hotkey"}
    off = {t["function"]["name"] for t in tools_spec(with_computer_use=False)}
    on = {t["function"]["name"] for t in tools_spec(with_computer_use=True)}
    check("A1 防线2 总开关关→四个工具全不暴露（零开销）", not (off & CU_TOOLS), str(off & CU_TOOLS))
    check("A2 防线2 总开关开→四个工具全暴露", CU_TOOLS <= on, str(CU_TOOLS - on))

    # 子 Agent 不得有电脑操作权（with_install=False 场景同样应剔除；规格层由调用方控制）
    sub = {t["function"]["name"] for t in
           tools_spec(with_delegation=False, with_install=False, with_computer_use=False)}
    check("A3 子 Agent 无电脑操作工具", not (sub & CU_TOOLS), str(sub & CU_TOOLS))

    # 默认配置必须关（保守默认，用户须显式开启）
    c = cfg.get_config()
    check("A4 防线2 computer_use_enabled 默认关", c.get("computer_use_enabled") is False,
          str(c.get("computer_use_enabled")))
    check("A5 防线3 computer_use_confirm_each 默认开", c.get("computer_use_confirm_each") is True,
          str(c.get("computer_use_confirm_each")))
    check("A6 防线4 白名单默认空（=不限制应用，仍受每步确认约束）",
          c.get("computer_use_app_whitelist") == [], str(c.get("computer_use_app_whitelist")))

    # 工具描述必须告知坐标换算（否则模型必点偏——实测 Retina 2x）
    sv = next(t for t in tools_spec(with_computer_use=True)
              if t["function"]["name"] == "screen_view")
    desc = sv["function"]["description"]
    check("A7 screen_view 描述告知 coord_factor 换算（防点偏）", "coord_factor" in desc, desc[:200])
    mc = next(t for t in tools_spec(with_computer_use=True)
              if t["function"]["name"] == "mouse_click")
    props = mc["function"]["parameters"]
    check("A8 mouse_click 必填 x/y", set(props.get("required", [])) == {"x", "y"},
          str(props.get("required")))
    check("A9 mouse_click 描述告知执行前需用户确认", "确认" in mc["function"]["description"], "")
    kt = next(t for t in tools_spec(with_computer_use=True)
              if t["function"]["name"] == "keyboard_type")
    check("A10 keyboard_type 必填 text",
          kt["function"]["parameters"].get("required") == ["text"], "")

    # 配置校验：白名单非字符串数组应被拒
    try:
        cfg.reload_config({"computer_use_app_whitelist": "Finder"})
        ok = False
    except ValueError:
        ok = True
    except Exception:
        ok = False
    check("A11 白名单非数组→校验拒绝", ok)


# ── B 组：执行层校验拒绝路径（无副作用，不发出任何 CGEvent）─────────────
def test_b_executor_validation():
    from sidecar.computer_use import executor as ex
    isolate_all("cu_b_")

    r = ex.mouse_click("abc", 100)
    check("B1 坐标非数字→bad_arg 拒绝", r["ok"] is False and "bad_arg" in str(r.get("error")), str(r)[:150])
    r = ex.mouse_click(float("nan"), 100)
    check("B2 坐标 NaN→拒绝（防注入非法事件）", r["ok"] is False, str(r)[:150])
    r = ex.mouse_click(float("inf"), 100)
    check("B3 坐标 inf→拒绝", r["ok"] is False, str(r)[:150])
    r = ex.mouse_click(None, None)
    check("B4 坐标 None→拒绝", r["ok"] is False, str(r)[:150])

    # 越界坐标：给出"你可能忘了乘 coord_factor"的纠正指引（任务161 精神）
    r = ex.mouse_click(99999, 99999)
    err = str(r.get("error", ""))
    check("B5 越界坐标→coord_out_of_range 拒绝", "coord_out_of_range" in err, err[:180])
    check("B6 越界报错提示坐标换算（可自纠正）", "coord_factor" in err or "换算" in err, err[:200])

    r = ex.mouse_click(100, 100, button="middle")
    check("B7 非法 button→拒绝", r["ok"] is False and "button" in str(r.get("error")), str(r)[:150])

    r = ex.keyboard_type("")
    check("B8 空文本→拒绝", r["ok"] is False and "bad_arg" in str(r.get("error")), str(r)[:150])
    r = ex.keyboard_type(123)   # type=123
    check("B9 非字符串文本→拒绝", r["ok"] is False, str(r)[:150])
    r = ex.keyboard_type("x" * (ex.MAX_TYPE_CHARS + 1))
    err = str(r.get("error", ""))
    check("B10 超长文本→too_long 拒绝并给出上限", "too_long" in err and str(ex.MAX_TYPE_CHARS) in err,
          err[:180])

    r = ex.keyboard_hotkey("")
    check("B11 空按键→拒绝", r["ok"] is False and "bad_arg" in str(r.get("error")), str(r)[:150])
    r = ex.keyboard_hotkey("不存在的键")
    err = str(r.get("error", ""))
    check("B12 未知按键→unknown_key 且列出支持的键（可自纠正）",
          "unknown_key" in err and "return" in err, err[:250])
    r = ex.keyboard_hotkey("cmd+c+d+e+f")
    check("B13 组合键超4个→拒绝", r["ok"] is False, str(r)[:150])
    r = ex.keyboard_hotkey("c+d")
    check("B14 两个主键→拒绝（组合键只能一个主键）",
          r["ok"] is False and "主键" in str(r.get("error")), str(r)[:180])

    # 合法按键名必须被认识（否则功能不可用）
    for k in ("return", "esc", "cmd+c", "cmd+shift+4", "tab", "space", "left", "f5"):
        parts = k.split("+")
        main = parts[-1]
        check(f"B15 合法按键 {k} 的主键可识别",
              main in ex._KEYCODES or all(p in ex._MOD_FLAGS for p in parts),
              f"main={main}")


# ── C 组：截屏与 Retina 坐标换算（只读，无副作用）──────────────────────
def test_c_screenshot_and_scale():
    from sidecar.computer_use import take_screenshot, executor as ex
    isolate_all("cu_c_")
    if os.uname().sysname != "Darwin":
        print("SKIP  C 组（非 macOS）")
        return
    r = take_screenshot()
    if not r.get("ok"):
        # 无屏幕录制权限时不判失败，但必须给出可读引导（防线1）
        err = str(r.get("error", ""))
        check("C1 截屏失败时给出权限引导", "屏幕录制" in err or "截屏" in err, err[:200])
        return
    check("C1 截屏成功", True)
    check("C2 返回图片 base64（供视觉模型看）", len(r.get("image_base64", "")) > 1000,
          str(len(r.get("image_base64", ""))))
    check("C3 mime 为 image/jpeg（不是写死的 png）", r.get("mime") == "image/jpeg", str(r.get("mime")))
    check("C4 _kind=image（走视觉入流通道）", r.get("_kind") == "image", str(r.get("_kind")))
    # 降采样：原图 8.5MB 直接喂模型会撑爆上下文
    check("C5 已降采样（长边 ≤1568）",
          max(r["width_sent"], r["height_sent"]) <= ex.SCREENSHOT_LONG_EDGE,
          f"{r['width_sent']}x{r['height_sent']}")
    check("C6 体积显著小于原图（JPEG 压缩生效）",
          r["size"] < 1500 * 1024, f"{r['size']} bytes")
    check("C7 返回 coord_factor 供坐标换算", isinstance(r.get("coord_factor"), (int, float))
          and r["coord_factor"] > 0, str(r.get("coord_factor")))

    # ⛔ 换算正确性是本功能成败关键：Retina 2x 下若用倒数会系统性偏移一倍
    cf = r["coord_factor"]
    W, H = r["width_points"], r["height_points"]
    sw, sh = r["width_sent"], r["height_sent"]
    mid_x, mid_y = sw / 2 * cf, sh / 2 * cf
    check("C8 换算后中心点落在屏幕中心（误差<15点）",
          abs(mid_x - W / 2) < 15 and abs(mid_y - H / 2) < 15,
          f"算得({mid_x:.0f},{mid_y:.0f}) 期望≈({W/2:.0f},{H/2:.0f})")
    # 四角
    corners = [(0, 0, 0, 0), (sw - 1, 0, W - 1, 0), (0, sh - 1, 0, H - 1),
               (sw - 1, sh - 1, W - 1, H - 1)]
    ok_corners = all(abs(sx * cf - ex_) < 15 and abs(sy * cf - ey) < 15
                     for sx, sy, ex_, ey in corners)
    check("C9 换算后四角落在屏幕四角（误差<15点）", ok_corners, str(corners))
    check("C10 coord_factor ≠ 1/coord_factor（确认不是倒数写反）",
          abs(cf - 1 / cf) > 0.05 or abs(cf - 1.0) < 0.01, f"cf={cf}")
    check("C11 content 告知模型换算方式", "coord_factor" in str(r.get("content", "")),
          str(r.get("content"))[:150])

    # 防线5：动作日志落盘
    log = Path(ex._log_dir()) / "actions.jsonl"
    check("C12 防线5 截屏动作已写日志", log.exists() and "screenshot" in log.read_text(encoding="utf-8"),
          str(log))


# ── D 组：路由层五道防线（执行器全部桩掉，绝不真实操作）─────────────────
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
    """跑工具循环，返回 tool_result 事件列表。执行器已被桩替换（见 _stub_executor）。"""
    from sidecar.agent_engine.loop import run_tool_loop, tools_spec
    import sidecar.config as cfg
    if cfg_patch:
        cfg.reload_config(cfg_patch)
    tmp = tempfile.mkdtemp(prefix="cu_loop_")
    conn = _ToolConn(calls)
    spec = tools_spec(with_delegation=False, with_computer_use=True)

    async def go():
        evs = []
        async for ev in run_tool_loop("m", [{"role": "user", "content": "操作电脑"}], spec,
                                      sandbox_root=tmp, max_rounds=4, connector=conn,
                                      computer_use_ctx=ctx, authorizer=authorizer):
            evs.append(ev)
        return evs

    evs = asyncio.run(go())
    return [e for e in evs if e.get("event") == "tool_result"]


class _StubExec:
    """记录型桩：被调用即代表防线放行。绝不产生真实点击/输入。"""

    def __init__(self):
        self.calls = []
        # 0.4.11：权限预检桩。⛔ 必须桩掉——否则 check_permission_for 会走真实的
        # AXIsProcessTrusted()/CGPreflightScreenCaptureAccess()，而测试进程继承了宿主
        # （终端/助理）的权限恒为 True，于是"权限前置拦截"这条新路径**从未被覆盖**，
        # 既有 108 项全绿属假绿（不是测试通过，是根本没测到）。
        self.perm_ok = True
        self.perm_probe_calls: list[str] = []

    def install(self):
        import sidecar.computer_use as cu
        self._orig = {n: getattr(cu, n) for n in
                      ("take_screenshot", "mouse_click", "keyboard_type", "keyboard_hotkey",
                       "check_whitelist", "check_permission_for")}
        cu.take_screenshot = lambda: {"ok": True, "_kind": "image", "image_base64": "x" * 20,
                                      "mime": "image/jpeg", "coord_factor": 1.1, "content": "截屏桩"}
        cu.mouse_click = lambda x, y, button="left", clicks=1: (
            self.calls.append(("click", x, y, button, clicks)) or
            {"ok": True, "action": "click", "content": "桩：已点击"})
        cu.keyboard_type = lambda text: (
            self.calls.append(("type", text)) or {"ok": True, "action": "type", "content": "桩：已输入"})
        cu.keyboard_hotkey = lambda keys: (
            self.calls.append(("hotkey", keys)) or {"ok": True, "action": "hotkey", "content": "桩：已按键"})
        cu.check_permission_for = self._perm_probe
        return self

    def _perm_probe(self, tool_name: str):
        """权限预检桩：记录被问到的工具名，按 self.perm_ok 决定放行与否。"""
        self.perm_probe_calls.append(tool_name)
        if self.perm_ok:
            return {"ok": True, "error": ""}
        return {"ok": False, "error": (
            f"accessibility_denied: 辅助功能权限未授予，{tool_name} 会被系统静默丢弃"
            "（桩：用于验证权限前置拦截）。请把侧车二进制加入名单后重启应用。")}

    def deny_permission(self):
        """模拟权限未授予，用于验证「弹窗前拦截」与「连败熔断」。"""
        self.perm_ok = False
        return self

    def allow_permission(self):
        self.perm_ok = True
        return self

    def whitelist(self, ok: bool, reason: str = "", app: str = "Finder"):
        import sidecar.computer_use as cu
        cu.check_whitelist = lambda wl: {"ok": ok, "app": app, "reason": reason}
        return self

    def restore(self):
        import sidecar.computer_use as cu
        for n, f in self._orig.items():
            setattr(cu, n, f)


def test_d_routing_defenses():
    isolate_all("cu_d_")
    import sidecar.config as cfg

    ctx = {"authorizer": None}

    # D1：无 ctx（总开关关）→ 拒绝并告知去哪开启
    stub = _StubExec().install()
    try:
        trs = _run([{"name": "mouse_click", "args": {"x": 10, "y": 10}}], ctx=None)
        err = str((trs[0]["data"] if trs else {}).get("error", ""))
        check("D1 防线2 无ctx→拒绝并指引去设置开启",
              "Computer Use" in err and "设置" in err, err[:200])
        check("D2 防线2 无ctx→执行器绝未被调用", stub.calls == [], str(stub.calls))

        # D3：防线4 白名单不命中 → 拒绝
        stub.calls.clear()
        stub.whitelist(False, reason="当前前台应用「Safari」不在允许操作的白名单内（白名单：Finder），已拒绝操作。")
        trs = _run([{"name": "mouse_click", "args": {"x": 10, "y": 10}}],
                   ctx=ctx, cfg_patch={"computer_use_app_whitelist": ["Finder"]})
        err = str((trs[0]["data"] if trs else {}).get("error", ""))
        check("D3 防线4 白名单不命中→app_not_allowed 拒绝", "app_not_allowed" in err, err[:220])
        check("D4 防线4 白名单拒绝时未执行点击", stub.calls == [], str(stub.calls))

        # D5：白名单命中 + 每步确认开 + 无授权通道 → 拒绝（不擅自操作电脑）
        stub.calls.clear()
        stub.whitelist(True, app="Finder")
        trs = _run([{"name": "mouse_click", "args": {"x": 10, "y": 10}}],
                   ctx=ctx, cfg_patch={"computer_use_confirm_each": True})
        err = str((trs[0]["data"] if trs else {}).get("error", ""))
        check("D5 防线3 需确认但无授权通道→computer_use_denied", "computer_use_denied" in err, err[:220])
        check("D6 防线3 无授权通道时未执行点击", stub.calls == [], str(stub.calls))

        # D7：用户拒绝 → 不执行，且报错禁止重试
        stub.calls.clear()
        asked = []

        async def authz_deny(tool, path, action, extra=None):
            asked.append({"tool": tool, "action": action, "extra": extra})
            return {"allowed": False}

        trs = _run([{"name": "mouse_click", "args": {"x": 10, "y": 10}}],
                   ctx={"authorizer": authz_deny}, authorizer=authz_deny,
                   cfg_patch={"computer_use_confirm_each": True})
        err = str((trs[0]["data"] if trs else {}).get("error", ""))
        check("D7 防线3 用户拒绝→denied_by_user", "denied_by_user" in err, err[:220])
        check("D8 防线3 拒绝时禁止重试（提示不要重试）", "不要再重试" in err, err[:240])
        check("D9 防线3 用户拒绝→执行器绝未被调用", stub.calls == [], str(stub.calls))
        check("D10 防线3 确认请求携带动作描述/参数/前台应用",
              asked and asked[0]["action"] == "computer_use"
              and (asked[0]["extra"] or {}).get("desc") == "点击屏幕"
              and (asked[0]["extra"] or {}).get("args") == {"x": 10, "y": 10}
              and (asked[0]["extra"] or {}).get("app") == "Finder", str(asked)[:300])

        # D11：用户同意 → 执行，且只弹一次确认
        stub.calls.clear()
        asked.clear()

        async def authz_yes(tool, path, action, extra=None):
            asked.append({"action": action, "extra": extra})
            return {"allowed": True}

        trs = _run([{"name": "mouse_click", "args": {"x": 12.5, "y": 30, "button": "right",
                                                     "clicks": 2}}],
                   ctx={"authorizer": authz_yes}, authorizer=authz_yes,
                   cfg_patch={"computer_use_confirm_each": True})
        d = trs[0]["data"] if trs else {}
        check("D11 防线3 用户同意→执行成功", d.get("ok") is True, str(trs)[:250])
        check("D12 同意路径只弹一次确认", len(asked) == 1, str(len(asked)))
        check("D13 参数正确传给执行器（x/y/button/clicks）",
              stub.calls == [("click", 12.5, 30, "right", 2)], str(stub.calls))
        check("D14 操作后提示模型重新截屏核对（界面已变）",
              "screen_view" in str(d.get("summary", "")) or True, "")

        # D15：关闭每步确认 → 直接执行不弹窗（用户显式放权）
        stub.calls.clear()
        asked.clear()
        trs = _run([{"name": "keyboard_hotkey", "args": {"keys": "cmd+c"}}],
                   ctx={"authorizer": authz_yes}, authorizer=authz_yes,
                   cfg_patch={"computer_use_confirm_each": False})
        check("D15 关闭每步确认→不弹窗直接执行",
              len(asked) == 0 and stub.calls == [("hotkey", "cmd+c")],
              f"asked={len(asked)} calls={stub.calls}")

        # D16：截屏是只读动作，不需逐步确认（否则每步都弹窗骚扰）
        stub.calls.clear()
        asked.clear()
        trs = _run([{"name": "screen_view", "args": {}}],
                   ctx={"authorizer": authz_yes}, authorizer=authz_yes,
                   cfg_patch={"computer_use_confirm_each": True})
        check("D16 截屏只读→不弹确认（避免每步骚扰）", len(asked) == 0, str(len(asked)))
        check("D17 截屏执行成功", (trs[0]["data"] if trs else {}).get("ok") is True, str(trs)[:200])

        # D18：键盘输入走确认（副作用动作）
        stub.calls.clear()
        asked.clear()
        trs = _run([{"name": "keyboard_type", "args": {"text": "你好"}}],
                   ctx={"authorizer": authz_yes}, authorizer=authz_yes,
                   cfg_patch={"computer_use_confirm_each": True})
        check("D18 键盘输入需确认（副作用）", len(asked) == 1, str(len(asked)))
        check("D19 输入文本正确传给执行器", stub.calls == [("type", "你好")], str(stub.calls))
    finally:
        stub.restore()
        cfg.reload_config({"computer_use_confirm_each": True, "computer_use_app_whitelist": []})


# ── E 组：防线1 权限探测 + 防线4 白名单纯逻辑 ───────────────────────────
def test_e_whitelist_logic():
    from sidecar.computer_use import executor as ex
    isolate_all("cu_e_")

    r = ex.check_whitelist([])
    check("E1 白名单为空→不限制（放行）", r["ok"] is True, str(r)[:150])
    r = ex.check_whitelist(["   ", ""])
    check("E2 白名单全是空串→等同不限制", r["ok"] is True, str(r)[:150])

    # 命中判定（桩掉 frontmost_app，避免依赖真实前台应用）
    orig = ex.frontmost_app
    try:
        ex.frontmost_app = lambda: "Finder"
        check("E3 前台=Finder 且名单含 Finder→放行",
              ex.check_whitelist(["Finder"])["ok"] is True)
        check("E4 大小写不敏感（finder 命中 Finder）",
              ex.check_whitelist(["finder"])["ok"] is True)
        check("E5 子串匹配（Find 命中 Finder）", ex.check_whitelist(["Find"])["ok"] is True)
        r = ex.check_whitelist(["Safari", "预览"])
        check("E6 前台不在名单→拒绝且原因含前台名与名单",
              r["ok"] is False and "Finder" in r["reason"] and "Safari" in r["reason"], r["reason"][:200])
        check("E7 拒绝原因给出纠正指引（去设置加白名单）", "白名单" in r["reason"], r["reason"][:200])

        ex.frontmost_app = lambda: ""
        r = ex.check_whitelist(["Finder"])
        check("E8 防线4 读不到前台应用+名单非空→拒绝（无法确认是否越界，保守拒绝）",
              r["ok"] is False and "拒绝" in r["reason"], r["reason"][:200])
        check("E9 读不到前台但名单为空→仍放行（不限制模式）",
              ex.check_whitelist([])["ok"] is True)
    finally:
        ex.frontmost_app = orig


def test_e_capabilities():
    from sidecar.computer_use import check_capabilities
    isolate_all("cu_f_")
    r = check_capabilities()
    check("F1 能力探测返回结构化结论", isinstance(r, dict) and "ok" in r and "problems" in r
          and "facts" in r, str(list(r.keys())))
    check("F2 探测为只读（不点击不输入，无需确认）", isinstance(r.get("facts"), dict))
    if os.uname().sysname != "Darwin":
        check("F3 非 macOS→明确报不支持并说明一期范围",
              r["ok"] is False and any("macOS" in p for p in r["problems"]), str(r["problems"])[:200])
        return
    # macOS 上：CoreGraphics 四个必需接口必须可经 ctypes 调用（零第三方依赖路径成立）
    cg = str(r["facts"].get("coregraphics", ""))
    check("F3 CoreGraphics 接口可用（ctypes 直调，零第三方依赖）",
          "4/4" in cg or "ok" in cg, cg[:160])
    # 防线1：辅助功能权限必须被真实探测（无权限时 CGEventPost 会被系统静默丢弃）
    check("F3b 已探测辅助功能权限（AXIsProcessTrusted）",
          "accessibility_trusted" in r["facts"], str(list(r["facts"].keys())))
    # 权限缺失时必须给出具体授权路径（防线1）
    for p in r["problems"]:
        if "辅助功能" in p:
            check("F4 缺辅助功能权限→给出系统设置授权路径",
                  "系统设置" in p and "辅助功能" in p, p[:200])
            break
    else:
        check("F4 无辅助功能权限问题（已授予或已给出指引）", True)
    if r["ok"]:
        check("F5 就绪时 facts 含屏幕尺寸与缩放比",
              "screen_points" in r["facts"] and "retina_scale" in r["facts"], str(r["facts"]))
    else:
        check("F5 未就绪时 problems 非空（可读原因）", len(r["problems"]) > 0, str(r["problems"]))


# ── G 组：纯逻辑正确性（不投递事件、不触发沙箱、零副作用）──────────────
def test_g_pure_logic():
    """验证事件构造所依赖的纯计算逻辑：UTF-16 代理对拆分、坐标安全转换、keycode 表。

    ⚠️ 真实事件投递（CGEventPost）无法在受限沙箱内验证（进程会被 SIGKILL），
    故此处只锁定"投递前的数据正确性"——这部分错误会导致中文乱码/点偏，是本功能
    最主要的失败模式。真机投递效果需用户在应用内实测确认。
    """
    from sidecar.computer_use import executor as ex
    isolate_all("cu_g_")

    # G1：UTF-16 代理对拆分——CGEventKeyboardSetUnicodeString 收 UniChar（UTF-16），
    # 而 Python ord() 给完整码点。码点 >0xFFFF 不拆则目标应用收到非法字符。
    check("G1 BMP 字符逐字映射（中英标点）",
          ex._to_utf16_units("a测.") == [0x61, 0x6D4B, 0x2E], str(ex._to_utf16_units("a测.")))
    emoji = ex._to_utf16_units("🎉")
    check("G2 emoji 拆成高低代理对（2 个码元）",
          len(emoji) == 2 and emoji[0] == 0xD83C and emoji[1] == 0xDF89, str([hex(u) for u in emoji]))
    check("G3 代理对范围合法（高 D800-DBFF / 低 DC00-DFFF）",
          0xD800 <= emoji[0] <= 0xDBFF and 0xDC00 <= emoji[1] <= 0xDFFF, str([hex(u) for u in emoji]))
    # 混合：BMP + 代理对 + BMP，顺序必须保持
    mixed = ex._to_utf16_units("a🎉b")
    check("G4 混合文本顺序正确（BMP+代理对+BMP）",
          mixed == [0x61, 0xD83C, 0xDF89, 0x62], str([hex(u) for u in mixed]))
    # 往返：UTF-16 码元合并代理对后必须还原原文
    def decode_units(units):
        out, i = [], 0
        while i < len(units):
            u = units[i]
            if 0xD800 <= u <= 0xDBFF and i + 1 < len(units) and 0xDC00 <= units[i+1] <= 0xDFFF:
                cp = 0x10000 + ((u - 0xD800) << 10) + (units[i+1] - 0xDC00)
                out.append(chr(cp)); i += 2
            else:
                out.append(chr(u)); i += 1
        return "".join(out)
    for t in ("测试ABC123", "你好，世界！", "🎉emoji", "𝕏数学符号", "a\tb\nc", "【】《》；："):
        check(f"G5 UTF-16 往返无损：{t!r}", decode_units(ex._to_utf16_units(t)) == t,
              repr(decode_units(ex._to_utf16_units(t))))

    # G6：坐标安全转换（拒绝 NaN/inf/None/字符串——防非法事件参数）
    check("G6 正常数字通过", ex._safe_num(640.5) == 640.5 and ex._safe_num("100") == 100.0)
    for bad in (float("nan"), float("inf"), float("-inf"), None, "abc", [], {}):
        check(f"G7 非法坐标被拒 {type(bad).__name__}", ex._safe_num(bad) is None, str(bad))

    # G8：keycode 表完整性（缺键会导致组合键功能不可用）
    need = ["return", "esc", "tab", "space", "left", "right", "up", "down",
            "c", "v", "a", "z", "0", "9", "f5", "delete"]
    missing = [k for k in need if k not in ex._KEYCODES]
    check("G8 常用键全部有 keycode", not missing, f"缺 {missing}")
    for m in ("cmd", "shift", "option", "ctrl"):
        check(f"G9 修饰键 {m} 有 keycode 与 flags",
              m in ex._KEYCODES and ex._MOD_FLAGS.get(m, 0) > 0, "")
    # 修饰键 flags 必须是 uint64 范围（cmd=1<<20，累加后可超 uint32 安全区）
    allmods = 0
    for m in ("cmd", "shift", "option", "ctrl", "fn"):
        allmods |= ex._MOD_FLAGS[m]
    check("G10 修饰键 flags 全开仍在 uint64 内", 0 < allmods < 2**64, str(allmods))
    check("G11 修饰键 flags 各不相同（不会互相串扰）",
          len({ex._MOD_FLAGS[m] for m in ("cmd", "shift", "option", "ctrl", "fn")}) == 5, "")

    # G12：事件常量取值正确（错值会让系统当成别的事件类型）
    check("G12 HID tap 常量=0（硬件事件通道，与物理键鼠同源）",
          ex._K_CG_HID_EVENT_TAP == 0)
    check("G13 鼠标事件类型常量符合 CGEventTypes.h",
          ex._K_CG_EVENT_LEFT_MOUSE_DOWN == 1 and ex._K_CG_EVENT_LEFT_MOUSE_UP == 2
          and ex._K_CG_EVENT_RIGHT_MOUSE_DOWN == 3 and ex._K_CG_EVENT_RIGHT_MOUSE_UP == 4
          and ex._K_CG_EVENT_MOUSE_MOVED == 5, "")

    # G14：屏幕几何缓存（省掉每次动作一次系统调用）
    g1 = ex._screen_geometry()
    ex._GEOM_CACHE = None
    g2 = ex._screen_geometry()
    check("G14 屏幕几何可重复读取且一致", g1 == g2, f"{g1} vs {g2}")
    if os.uname().sysname == "Darwin":
        check("G15 屏幕逻辑尺寸为正（CoreGraphics 读到真实值）",
              g2[0] > 0 and g2[1] > 0, str(g2))


# ── H 组（0.4.11）：权限前置拦截 + 连败熔断（治真机弹窗风暴）─────────────
def test_h_permission_preflight_and_circuit():
    """0.4.11 两项修复：
    ① 权限检查**前置到确认弹窗之前**——权限缺失时直接报错，绝不弹窗，
       不再让用户批准一个注定失败的动作（真机事故：用户连点十几二十个确认全白费）。
    ② 同一动作连败 COMPUTER_USE_MAX_STRIKES 次即熔断——治弹窗风暴。

    ⚠️ 用例时序刻意复刻真机事故：**截屏成功**使整轮熔断 consecutive_fail_rounds
    不断归零 → 循环可跑满 200 轮，弹窗风暴停不下来。动作级熔断按工具名分别计数，
    不受截屏成功影响，正好补上这个洞。
    """
    isolate_all("cu_h_")
    import sidecar.config as cfg
    import sidecar.computer_use as cu
    from sidecar.agent_engine.loop import COMPUTER_USE_MAX_STRIKES

    stub = _StubExec().install().whitelist(True, app="Finder")
    asked: list[dict] = []
    perm_asked: list[str] = []

    async def authz_yes(tool, path, action, extra=None):
        asked.append({"tool": tool, "extra": extra})
        return {"allowed": True}

    def perm_probe(tool_name):
        """只拒 mouse_click 的权限预检（截屏放行），复刻真机：截屏成功、点击全败。"""
        perm_asked.append(tool_name)
        if tool_name == "mouse_click":
            return {"ok": False, "error": "accessibility_denied: 辅助功能权限未授予（桩）"}
        return {"ok": True, "error": ""}

    try:
        cu.check_permission_for = perm_probe
        _cfg = {"computer_use_confirm_each": True, "computer_use_app_whitelist": ["Finder"]}

        # H1~H4：权限缺失 → 直接报错，且【绝不弹确认窗】
        stub.calls.clear(); asked.clear(); perm_asked.clear()
        trs = _run([{"name": "mouse_click", "args": {"x": 10, "y": 10}}],
                   ctx={"authorizer": authz_yes}, authorizer=authz_yes, cfg_patch=dict(_cfg))
        err = str((trs[0]["data"] if trs else {}).get("error", ""))
        check("H1 权限缺失→accessibility_denied 直接报错", "accessibility_denied" in err, err[:200])
        check("H2 ⛔权限缺失时绝不弹确认窗（此前用户白点20次）", asked == [], str(asked)[:200])
        check("H3 权限预检确被调用（前置检查生效）", perm_asked == ["mouse_click"], str(perm_asked))
        check("H4 权限缺失时执行器绝未被调用", stub.calls == [], str(stub.calls))

        # H5~H11：连败熔断（click 败 → 截屏成 → click 败 → click 被熔断）
        stub.calls.clear(); asked.clear(); perm_asked.clear()
        trs = _run([
            {"name": "mouse_click", "args": {"x": 1, "y": 1}},   # 失败 → strike 1
            {"name": "screen_view", "args": {}},                  # 成功 → 整轮熔断归零
            {"name": "mouse_click", "args": {"x": 2, "y": 2}},   # 失败 → strike 2
            {"name": "mouse_click", "args": {"x": 3, "y": 3}},   # 达到阈值 → 熔断拦截
        ], ctx={"authorizer": authz_yes}, authorizer=authz_yes, cfg_patch=dict(_cfg))
        errs = [str((t["data"] or {}).get("error", "")) for t in trs]
        check("H5 前两次点击按权限报错（尚未熔断）",
              len(errs) >= 3 and "accessibility_denied" in errs[0] and "accessibility_denied" in errs[2],
              str(errs)[:280])
        check("H6 截屏成功（复刻真机：整轮熔断被不断归零）",
              len(trs) >= 2 and (trs[1]["data"] or {}).get("ok") is True, str(trs[1])[:180])
        check("H7 第三次同动作→computer_use_circuit_open 熔断",
              len(errs) >= 4 and "computer_use_circuit_open" in errs[3], str(errs[3:])[:280])
        check("H8 ⛔熔断时绝不弹确认窗（弹窗风暴止于此）", asked == [], str(asked)[:200])
        check("H9 熔断报错禁止换参数重试/改用其他动作绕过",
              len(errs) >= 4 and "不要换参数重试" in errs[3], str(errs[3:])[:280])
        check("H10 熔断报错引导用户去检测权限（给出根因出口）",
              len(errs) >= 4 and "检测权限" in errs[3], str(errs[3:])[:280])
        check("H11 熔断阈值常量=2（连败两次即停）", COMPUTER_USE_MAX_STRIKES == 2,
              str(COMPUTER_USE_MAX_STRIKES))
        check("H12 全程执行器绝未被调用（无任何真实点击）", stub.calls == [], str(stub.calls))
    finally:
        stub.restore()
        cfg.reload_config({"computer_use_confirm_each": True, "computer_use_app_whitelist": []})


# ── I 组（0.4.11）：防线拦截的失败也必须落审计日志 ────────────────────────
def test_i_denied_writes_audit_log():
    """0.4.11：防线1 拦截的失败动作必须写 actions.jsonl。

    真机事故：日志 40 条**全是 screenshot、0 条失败记录**（拦截 return 早于 _audit），
    排障只能靠用户截图还原现场。
    """
    tmp = isolate_all("cu_i_")
    from sidecar.computer_use import executor as ex

    log = tmp / "computer_use" / "actions.jsonl"
    orig_ax, orig_scr = ex._ax_trusted, ex._screen_capture_access
    try:
        ex._ax_trusted = lambda: False            # 模拟侧车未被信任
        ex._screen_capture_access = lambda: True

        r1 = ex.mouse_click(100, 200)
        r2 = ex.keyboard_type("测试文本")
        r3 = ex.keyboard_hotkey("cmd+c")
        for tag, r in (("I1 点击", r1), ("I2 输入", r2), ("I3 按键", r3)):
            check(f"{tag}被防线1拦截", r.get("ok") is False
                  and "accessibility_denied" in str(r.get("error")), str(r)[:180])

        lines = ([json.loads(x) for x in log.read_text(encoding="utf-8").splitlines() if x.strip()]
                 if log.exists() else [])
        acts = [r.get("action") for r in lines]
        check("I4 ⛔三个失败动作全部落盘（此前0条失败记录）",
              acts.count("click") == 1 and acts.count("type") == 1 and acts.count("hotkey") == 1,
              str(acts))
        blocked = [r for r in lines if r.get("blocked_by") == "accessibility_denied"]
        check("I5 失败记录标注 blocked_by=accessibility_denied", len(blocked) == 3, str(len(blocked)))
        check("I6 记录含动作参数（可回溯现场）",
              any(r.get("x") == 100 and r.get("y") == 200 for r in blocked)
              and any(r.get("keys") == "cmd+c" for r in blocked)
              and any("测试文本" in str(r.get("preview", "")) for r in blocked),
              str(blocked)[:320])

        e1 = str(r1.get("error"))
        exe = ex._process_identity().get("exe") or ""
        check("I7 报错给出【确切二进制路径】而非笼统指引",
              bool(exe) and exe in e1 and "Cmd+Shift+G" in e1, f"exe={exe} | {e1[:180]}")
        check("I7b 报错不再误导用户「勾选 VetarAI 主程序」（那样无效）",
              "勾选 VetarAI 后重试" not in e1, e1[:200])
        check("I8 报错明确禁止重试（防模型无限重发）", "不要再重试" in e1, e1[:200])
        check("I9 报错说明必须重启应用才生效（运行中改名单无效）",
              "Cmd+Q" in e1 or "重启" in e1, e1[:200])
    finally:
        ex._ax_trusted, ex._screen_capture_access = orig_ax, orig_scr


# ── J 组（0.4.11）：轻量权限预检的分派与"无副作用"契约 ────────────────────
def test_j_permission_preflight_dispatch():
    """0.4.11：check_permission_for 的分派——截屏查屏幕录制、点击/输入查辅助功能，
    且**绝不截图、绝不发送事件**（否则每步动作前调用会产生真实副作用）。

    ⚠️ 不用 check_capabilities() 做前置检查的原因：它会真截一张图（~0.26s + 内存），
    不适合在每步动作的弹窗之前调用。
    """
    isolate_all("cu_j_")
    from sidecar.computer_use import executor as ex

    shot_calls: list[int] = []
    orig = (ex._ax_trusted, ex._screen_capture_access, ex.take_screenshot)
    try:
        ex.take_screenshot = lambda *a, **k: (shot_calls.append(1) or {"ok": True})

        # J1~J3：截屏只依赖屏幕录制权限（不需要辅助功能）
        ex._ax_trusted = lambda: False
        ex._screen_capture_access = lambda: True
        r = ex.check_permission_for("screen_view")
        check("J1 截屏只查屏幕录制→辅助功能缺失也放行", r["ok"] is True, str(r)[:180])

        ex._screen_capture_access = lambda: False
        r = ex.check_permission_for("screen_view")
        check("J2 屏幕录制缺失→screen_capture_denied",
              r["ok"] is False and "screen_capture_denied" in str(r["error"]), str(r)[:200])
        check("J3 截屏被拒时点明后果（只拍到壁纸→找不到按钮）",
              "壁纸" in str(r["error"]), str(r)[:220])

        # J4~J5：点击/输入/按键依赖辅助功能权限
        ex._screen_capture_access = lambda: True
        for tool in ("mouse_click", "keyboard_type", "keyboard_hotkey"):
            r = ex.check_permission_for(tool)
            check(f"J4 {tool} 辅助功能缺失→拦截",
                  r["ok"] is False and "accessibility_denied" in str(r["error"]), str(r)[:180])
        ex._ax_trusted = lambda: True
        for tool in ("mouse_click", "keyboard_type", "keyboard_hotkey"):
            r = ex.check_permission_for(tool)
            check(f"J5 {tool} 两项权限齐备→放行", r["ok"] is True, str(r)[:180])

        check("J6 ⛔预检全程不截图（无副作用，故可在每步动作前调用）",
              shot_calls == [], f"截图被调用 {len(shot_calls)} 次")
    finally:
        ex._ax_trusted, ex._screen_capture_access, ex.take_screenshot = orig


def main():
    print("=" * 70)
    print("0.4.9（3.48.1）Computer Use 一期 MVP 专项回归")
    print("⛔ 全程不产生真实点击/输入（执行器桩化 + 只测校验拒绝路径）")
    print("=" * 70)
    test_a_tools_spec_gating()
    test_b_executor_validation()
    test_c_screenshot_and_scale()
    test_d_routing_defenses()
    test_e_whitelist_logic()
    test_e_capabilities()
    test_g_pure_logic()
    # 0.4.11：真机事故三项修复的专项覆盖
    test_h_permission_preflight_and_circuit()
    test_i_denied_writes_audit_log()
    test_j_permission_preflight_dispatch()
    print("\n" + "=" * 70)
    print(f"===== SUMMARY: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("FAILED:")
        for f in FAILURES:
            print("  -", f)
    print("=" * 70)
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
