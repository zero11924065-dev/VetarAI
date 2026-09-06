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
"""0.4.9（3.48.2 应用内模块控制）专项回归：注册表 + dispatch 路由 + 确认分级。

覆盖：
- 注册表清单：7 个动作、目录文本渲染、新模块登记即可被 Agent 调用（结构性验证）
- 确认分级：默认只有 workflow_run / roundtable_create 需确认；配置 app_control_confirm 可覆盖
- dispatch：未知模块/未知动作 → 可读错误 + 列出可用项（任务161 精神：报错必带原因与纠正指引）
- 真实执行器：workflow_list / workflow_get_runs / knowledge_search / knowledge_inject /
  knowledge_groups / roundtable_create 的参数校验与正常路径
- loop 路由层：无 ctx 拒绝 / 需确认但无授权通道拒绝 / 用户拒绝→不执行 dispatch /
  用户同意→执行 / 查询类动作不触发确认
- tools_spec：with_app_control 开关控制工具暴露

⛔ 测试隔离（血泪教训，见 test_checkpoint093.py isolate_data_dir 注释）：
必须同时钉死 config 路径、store.PROJECTS_ROOT/_GDB、warehouse 数据根与索引库，
否则会把测试数据写进用户真实 ~/.subagent（曾污染 config.json 6 项与技能目录）。
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
    """把 config / store / warehouse 全部重定向到临时目录（禁止碰真实 ~/.subagent）。"""
    tmp = Path(tempfile.mkdtemp(prefix=prefix))
    os.environ["VETARAI_DATA_ROOT"] = str(tmp)

    # ① config：monkeypatch get_config_path（_load_from_disk/_save 都在运行时调它）。
    #    ⛔ 不可用 reload_config({"data_root": tmp})：它会先按真实路径 _load 再 _save，
    #    把 data_root 冲回 ~/.subagent（已实际污染过用户配置）。
    import sidecar.config.store as cs
    cs.get_config_path = lambda: tmp / "config.json"
    cs._MEM = dict(cs.DEFAULT_CONFIG)
    cs._MEM["data_root"] = str(tmp)

    # ② store：PROJECTS_ROOT/_GDB 在模块导入时已求值绑定，仅设环境变量无效
    import sidecar.storage.store as store
    store.PROJECTS_ROOT = tmp / "projects"
    store.PROJECTS_ROOT.mkdir(parents=True, exist_ok=True)
    store._GDB = store.PROJECTS_ROOT / "_global.db"

    # ③ warehouse：模块自带测试钩子，直接钉死数据根与索引库
    from sidecar.knowledge import warehouse as wh
    wh._DATA_ROOT_OVERRIDE = tmp
    wh._INDEX_DB_PATH = tmp / "knowledge" / "index.db"
    (tmp / "knowledge").mkdir(parents=True, exist_ok=True)

    # ④ 技能目录：运行时调 data_root()，会被冲回真实值 → 钉死
    import sidecar.skills_mgr.manager as skm
    sk_dir = tmp / "skills"
    sk_dir.mkdir(parents=True, exist_ok=True)
    skm.skills_root = lambda: sk_dir
    return tmp


# ── A 组：注册表结构与确认分级 ─────────────────────────────────────────
def test_a_registry_structure():
    from sidecar.app_modules import (APP_MODULE_REGISTRY, list_actions,
                                     action_needs_confirm, build_module_catalog_text)

    actions = list_actions()
    check("A1 注册表暴露 7 个动作", len(actions) == 7, str(actions))
    expected = {"workflow_list", "workflow_run", "workflow_get_runs",
                "knowledge_search", "knowledge_inject", "knowledge_groups",
                "roundtable_create"}
    check("A2 动作名与预期一致", set(actions) == expected, str(set(actions) ^ expected))
    check("A3 三个模块齐备（工作流/知识仓库/圆桌）",
          set(APP_MODULE_REGISTRY.keys()) == {"workflow", "knowledge", "roundtable"},
          str(list(APP_MODULE_REGISTRY.keys())))

    # 每条登记项都必须齐备（新模块接入的最小契约，缺一即 Agent 调不动）
    bad = []
    for mod, spec in APP_MODULE_REGISTRY.items():
        if not spec.get("description"):
            bad.append(f"{mod} 缺 description")
        for act, a in (spec.get("actions") or {}).items():
            if not callable(a.get("handler")):
                bad.append(f"{mod}.{act} 缺 handler")
            if not a.get("description"):
                bad.append(f"{mod}.{act} 缺 description")
            if "needs_confirm" not in a:
                bad.append(f"{mod}.{act} 缺 needs_confirm")
            if not isinstance(a.get("params"), dict):
                bad.append(f"{mod}.{act} params 不是 dict")
    check("A4 每条登记项字段齐备（description/handler/needs_confirm/params）",
          not bad, str(bad[:4]))

    # 确认分级：默认只有两个高成本动作需确认
    check("A5 workflow_run 默认需确认（跑多节点推理，高成本）",
          action_needs_confirm("workflow", "run", None) is True)
    check("A6 roundtable_create 默认需确认（多方多轮推理，高成本）",
          action_needs_confirm("roundtable", "create", None) is True)
    for m, a in (("workflow", "list"), ("workflow", "get_runs"),
                 ("knowledge", "search"), ("knowledge", "inject"), ("knowledge", "groups")):
        check(f"A7 {m}_{a} 查询类默认不确认（避免弹窗骚扰）",
              action_needs_confirm(m, a, None) is False)

    # 配置覆盖优先于注册表默认
    check("A8 配置可扩大确认范围（把 knowledge_search 也纳入确认）",
          action_needs_confirm("knowledge", "search", ["knowledge_search"]) is True)
    check("A9 配置可缩小确认范围（空列表 → workflow_run 也不确认）",
          action_needs_confirm("workflow", "run", []) is False)
    check("A10 未知动作在配置模式下不需确认（不会误弹窗）",
          action_needs_confirm("nope", "nope", ["workflow_run"]) is False)

    catalog = build_module_catalog_text()
    check("A11 目录文本含全部模块名", all(m in catalog for m in ("workflow", "knowledge", "roundtable")),
          catalog[:120])
    check("A12 目录文本含动作说明（供 Agent 知道自己能调什么）",
          "workflow.run" in catalog and "knowledge.search" in catalog, catalog[:200])
    check("A13 目录文本非空且有行数", len(catalog.splitlines()) >= 10,
          f"{len(catalog.splitlines())} 行")


# ── B 组：dispatch 路由与错误可读性 ────────────────────────────────────
def test_b_dispatch_errors():
    from sidecar.app_modules import dispatch
    isolate_all("ac_b_")

    async def go():
        ctx = {"project_id": "", "session_id": "", "sandbox_root": tempfile.mkdtemp()}

        r = await dispatch("不存在的模块", "list", {}, ctx)
        err = str(r.get("error", ""))
        check("B1 未知模块→ok=False", r.get("ok") is False, str(r)[:120])
        check("B2 未知模块→错误含 unknown_module 标识", "unknown_module" in err, err[:150])
        check("B3 未知模块→列出可用模块（纠正指引，非裸报错）",
              all(m in err for m in ("workflow", "knowledge", "roundtable")), err[:200])

        r2 = await dispatch("workflow", "不存在的动作", {}, ctx)
        err2 = str(r2.get("error", ""))
        check("B4 未知动作→ok=False", r2.get("ok") is False, str(r2)[:120])
        check("B5 未知动作→错误含 unknown_action 标识", "unknown_action" in err2, err2[:150])
        check("B6 未知动作→列出该模块可用动作",
              "list" in err2 and "run" in err2 and "get_runs" in err2, err2[:220])

        # handler 内部抛异常也必须被兜住并回传原因（不得裸抛穿透到 loop）
        r3 = await dispatch("workflow", "run", {}, ctx)
        check("B7 缺 workflow_id→bad_arg 且给出纠正指引",
              r3.get("ok") is False and "bad_arg" in str(r3.get("error", ""))
              and "workflow_list" in str(r3.get("error", "")), str(r3)[:180])

    asyncio.run(go())


def test_b_dispatch_real_modules():
    """真实执行器：查询类动作走真实存储层（隔离目录内）。"""
    from sidecar.app_modules import dispatch
    tmp = isolate_all("ac_c_")
    import sidecar.storage.store as store
    from sidecar.knowledge import warehouse as wh

    # 造一条工作流 + 一条全局知识
    wf_id = store.create_workflow("测试流程", {
        "nodes": [{"id": "s", "type": "start", "label": "开始"},
                  {"id": "e", "type": "end", "label": "结束"}],
        "edges": [{"from": "s", "to": "e"}], "params": {}}, description="测试用")
    entry = wh.add_entry("global", None, "借款事实备忘", "被告于2023年借款64万元未还",
                         category="测试", keywords=["借款"], source="manual")

    async def go():
        ctx = {"project_id": "", "session_id": "", "sandbox_root": str(tmp)}

        r = await dispatch("workflow", "list", {}, ctx)
        check("C1 workflow.list 成功", r.get("ok") is True, str(r)[:150])
        check("C2 workflow.list 返回真实条数与 id",
              r.get("count") == 1 and r["workflows"][0]["id"] == wf_id, str(r)[:200])
        check("C3 workflow.list 含名称（Agent 据此挑选）",
              r["workflows"][0].get("name") == "测试流程", str(r)[:200])

        r2 = await dispatch("workflow", "get_runs", {"run_id": "不存在的run"}, ctx)
        check("C4 get_runs 查不存在的 run→run_not_found（可读原因）",
              r2.get("ok") is False and "run_not_found" in str(r2.get("error", "")), str(r2)[:180])
        r3 = await dispatch("workflow", "get_runs", {}, ctx)
        check("C5 get_runs 无参→列出运行记录（空列表也算成功）",
              r3.get("ok") is True and isinstance(r3.get("runs"), list), str(r3)[:150])

        # knowledge.search 走真实检索（keyword 模式，避免触发嵌入模型拖慢测试）
        r4 = await dispatch("knowledge", "search", {"query": "", "mode": "keyword"}, ctx)
        check("C6 search 缺 query→bad_arg", r4.get("ok") is False
              and "bad_arg" in str(r4.get("error", "")), str(r4)[:150])
        r5 = await dispatch("knowledge", "search",
                            {"query": "借款", "scope": "global", "mode": "keyword"}, ctx)
        check("C7 search 真实检索命中", r5.get("ok") is True and r5.get("count", 0) >= 1,
              str(r5)[:200])
        check("C8 search 结果含条目 id（供 inject 使用）",
              bool(r5.get("items")) and r5["items"][0].get("id"), str(r5)[:200])
        check("C9 search 声明拉模式（结果不写入上下文）",
              "不会写入对话上下文" in str(r5.get("note", "")), str(r5)[:200])

        r6 = await dispatch("knowledge", "inject", {}, ctx)
        check("C10 inject 缺 entry_ids→bad_arg 且指引先 search",
              r6.get("ok") is False and "bad_arg" in str(r6.get("error", ""))
              and "knowledge_search" in str(r6.get("error", "")), str(r6)[:200])
        r7 = await dispatch("knowledge", "inject", {"entry_ids": ["不存在id"]}, ctx)
        check("C11 inject 条目不存在→entries_not_found（不静默返回空）",
              r7.get("ok") is False and "entries_not_found" in str(r7.get("error", "")),
              str(r7)[:180])
        eid = entry.get("id") if entry else ""
        r8 = await dispatch("knowledge", "inject", {"entry_ids": [eid]}, ctx)
        check("C12 inject 成功取回正文", r8.get("ok") is True and "64万" in str(r8.get("text", "")),
              str(r8)[:200])
        check("C13 inject 字符串 id 也接受（模型常传逗号分隔串）",
              (await dispatch("knowledge", "inject", {"entry_ids": eid}, ctx)).get("ok") is True)

        r9 = await dispatch("knowledge", "groups", {}, ctx)
        check("C14 groups 成功返回分组", r9.get("ok") is True and isinstance(r9.get("groups"), list),
              str(r9)[:200])

        # roundtable.create 参数校验（不真跑推理，只验证前置校验）
        r10 = await dispatch("roundtable", "create", {}, ctx)
        check("C15 create 缺 topic→bad_arg", r10.get("ok") is False
              and "topic" in str(r10.get("error", "")), str(r10)[:180])
        r11 = await dispatch("roundtable", "create", {"topic": "议题"}, ctx)
        check("C16 create 缺 agent_ids→bad_arg 且说明至少2个",
              r11.get("ok") is False and "至少需要 2 个" in str(r11.get("error", "")),
              str(r11)[:200])
        r12 = await dispatch("roundtable", "create",
                             {"topic": "议题", "agent_ids": ["a1"]}, ctx)
        check("C17 create 只有1个Agent→拒绝（圆桌是多方会诊）",
              r12.get("ok") is False and "至少需要 2 个" in str(r12.get("error", "")),
              str(r12)[:200])
        r13 = await dispatch("roundtable", "create",
                             {"topic": "议题", "agent_ids": ["a1", "a2"]}, ctx)
        check("C18 create 缺 project_id→bad_arg（ctx 也无）",
              r13.get("ok") is False and "project_id" in str(r13.get("error", "")),
              str(r13)[:200])

    asyncio.run(go())


# ── D 组：loop 路由层（开关 / ctx / 确认分级）──────────────────────────
class _ToolConn:
    """桩连接器：第一轮发出指定的 app_control 调用，第二轮收尾。"""

    def __init__(self, tool_args: list[dict]):
        self.tool_args = tool_args
        self.n = 0

    async def chat_stream(self, model, messages, **kw):
        if self.n < len(self.tool_args):
            args = self.tool_args[self.n]
            self.n += 1
            yield {"tool_calls": [{"id": f"c{self.n}", "function": {
                "name": "app_control", "arguments": json.dumps(args, ensure_ascii=False)}}]}
            yield {"done": True, "counts": {"prompt_eval_count": 5, "eval_count": 2}}
        else:
            yield {"content_delta": "已完成"}
            yield {"done": True, "counts": {"prompt_eval_count": 5, "eval_count": 2}}


def _run_loop(args: dict, ctx, authorizer=None):
    """跑一轮工具循环，返回 (tool_result 事件列表, 全部事件)。"""
    from sidecar.agent_engine.loop import run_tool_loop, tools_spec
    tmp = tempfile.mkdtemp(prefix="ac_loop_")
    conn = _ToolConn([args])
    spec = tools_spec(with_delegation=False, with_app_control=True)
    # app_control 路由从 app_control_ctx["authorizer"] 读取授权回调（loop.py:1074），
    # 不是从 run_tool_loop 的 authorizer 参数——故必须把 authorizer 注入 ctx 副本。
    _ctx = ctx
    if isinstance(ctx, dict):
        _ctx = dict(ctx)
        _ctx["authorizer"] = authorizer

    async def go():
        evs = []
        async for ev in run_tool_loop("m", [{"role": "user", "content": "调模块"}], spec,
                                      sandbox_root=tmp, max_rounds=3, connector=conn,
                                      app_control_ctx=_ctx, authorizer=authorizer):
            evs.append(ev)
        return evs

    evs = asyncio.run(go())
    return [e for e in evs if e.get("event") == "tool_result"], evs


def test_d_loop_routing():
    tmp = isolate_all("ac_d_")
    import sidecar.storage.store as store
    store.create_workflow("流程甲", {
        "nodes": [{"id": "s", "type": "start", "label": "开始"},
                  {"id": "e", "type": "end", "label": "结束"}],
        "edges": [{"from": "s", "to": "e"}], "params": {}})

    # D1：无 ctx（开关关闭）→ 明确报错并告知去哪开启，不静默失败
    trs, _ = _run_loop({"module": "workflow", "action": "list"}, ctx=None)
    check("D1 无ctx→拒绝并告知需在设置开启",
          trs and trs[0]["data"].get("ok") is False
          and "设置" in str(trs[0]["data"].get("error", "")), str(trs)[:250])

    ctx = {"project_id": "", "session_id": "", "sandbox_root": str(tmp)}

    # D2：缺 module/action → 报错指向清单
    trs, _ = _run_loop({"module": "", "action": ""}, ctx=ctx)
    check("D2 缺module/action→报错并指向清单",
          trs and "module 与 action" in str(trs[0]["data"].get("error", "")), str(trs)[:250])

    # D3：查询类动作 → 不触发确认，直接执行
    calls = []

    async def authz_allow(tool, path, action, extra=None):
        calls.append({"tool": tool, "action": action, "extra": extra})
        return {"allowed": True} if isinstance(action, str) else True

    trs, _ = _run_loop({"module": "workflow", "action": "list"}, ctx=ctx, authorizer=authz_allow)
    d = trs[0]["data"] if trs else {}
    # tool_result 事件只带 ok/summary/error（不透传 dispatch 的 count 等字段），故只断言 ok
    check("D3 查询类动作执行成功", d.get("ok") is True, str(trs)[:250])
    check("D4 查询类动作不弹窗确认（不骚扰用户）", len(calls) == 0, str(calls)[:200])

    # D5：高成本动作 + 无授权通道 → 拒绝执行，不擅自跑工作流
    trs, _ = _run_loop({"module": "workflow", "action": "run",
                        "params": {"workflow_id": "x"}}, ctx=ctx, authorizer=None)
    err = str((trs[0]["data"] if trs else {}).get("error", ""))
    check("D5 需确认但无授权通道→拒绝（不擅自执行副作用）",
          "app_module_denied" in err, err[:200])

    # D6：高成本动作 + 用户拒绝 → 不执行，且报错禁止重试
    calls.clear()

    async def authz_deny(tool, path, action, extra=None):
        calls.append({"tool": tool, "action": action, "extra": extra})
        return {"allowed": False, "enable_network": False}

    trs, _ = _run_loop({"module": "workflow", "action": "run",
                        "params": {"workflow_id": "x"}}, ctx=ctx, authorizer=authz_deny)
    err = str((trs[0]["data"] if trs else {}).get("error", ""))
    check("D6 用户拒绝→denied_by_user", "denied_by_user" in err, err[:200])
    check("D7 拒绝时报错明确禁止重试该动作", "不要再重试" in err, err[:220])
    check("D8 确认请求携带模块/动作/参数（前端据此弹窗）",
          calls and calls[0]["action"] == "app_module"
          and (calls[0]["extra"] or {}).get("module") == "workflow"
          and (calls[0]["extra"] or {}).get("action") == "run"
          and (calls[0]["extra"] or {}).get("params") == {"workflow_id": "x"},
          str(calls)[:300])

    # D9：高成本动作 + 用户同意 → 真正执行（这里用不存在的 workflow_id 验证确实进了 dispatch）
    calls.clear()

    async def authz_yes(tool, path, action, extra=None):
        calls.append({"action": action})
        return {"allowed": True}

    trs, _ = _run_loop({"module": "workflow", "action": "run",
                        "params": {"workflow_id": "不存在"}}, ctx=ctx, authorizer=authz_yes)
    err = str((trs[0]["data"] if trs else {}).get("error", ""))
    check("D9 用户同意→执行 dispatch（到达真实执行器）",
          "workflow_not_found" in err, err[:200])
    check("D10 同意路径只弹一次确认", len(calls) == 1, str(calls)[:150])

    # D11：配置可把查询类也纳入确认（用户在设置里收紧）
    import sidecar.config as cfg
    cfg.reload_config({"app_control_confirm": ["workflow_list"]})
    calls.clear()
    trs, _ = _run_loop({"module": "workflow", "action": "list"}, ctx=ctx, authorizer=authz_deny)
    err = str((trs[0]["data"] if trs else {}).get("error", ""))
    check("D11 配置收紧→查询类也需确认且被拒", "denied_by_user" in err, err[:200])
    cfg.reload_config({"app_control_confirm": ["workflow_run", "roundtable_create"]})


def test_d_tools_spec_and_config():
    from sidecar.agent_engine.loop import tools_spec, build_system_prompt
    import sidecar.config as cfg
    isolate_all("ac_e_")

    off = [t["function"]["name"] for t in tools_spec(with_app_control=False)]
    on = [t["function"]["name"] for t in tools_spec(with_app_control=True)]
    check("E1 开关关闭→不暴露 app_control（零开销）", "app_control" not in off, str(off))
    check("E2 开关开启→暴露 app_control", "app_control" in on, str(on))
    ac = next((t for t in tools_spec(with_app_control=True)
               if t["function"]["name"] == "app_control"), None)
    props = (ac or {}).get("function", {}).get("parameters", {})
    check("E3 app_control 必填 module/action",
          set(props.get("required", [])) == {"module", "action"}, str(props.get("required")))
    check("E4 params 声明为 object（结构化传参）",
          props.get("properties", {}).get("params", {}).get("type") == "object",
          str(props.get("properties", {}).get("params")))

    # 提示词注入：有清单才注入，无清单零膨胀
    cat = "· workflow.run — 触发运行"
    p1 = build_system_prompt("A", "r", "/tmp", "auto", module_catalog_text=cat)
    check("E5 开启时注入【可用应用模块动作】清单",
          "【可用应用模块动作】" in p1 and "app_control" in p1, p1[-300:])
    p2 = build_system_prompt("A", "r", "/tmp", "auto", module_catalog_text="")
    check("E6 关闭时不注入（零膨胀）", "【可用应用模块动作】" not in p2, "")

    # 配置默认值：功能默认关，确认清单默认含两个高成本动作
    c = cfg.get_config()
    check("E7 app_control_enabled 默认关（保守默认）", c.get("app_control_enabled") is False,
          str(c.get("app_control_enabled")))
    check("E8 app_control_confirm 默认含 workflow_run/roundtable_create",
          set(c.get("app_control_confirm") or []) == {"workflow_run", "roundtable_create"},
          str(c.get("app_control_confirm")))
    check("E9 确认清单非字符串数组时校验拒绝",
          _raises(lambda: cfg.reload_config({"app_control_confirm": "workflow_run"})))


def _raises(fn) -> bool:
    try:
        fn()
        return False
    except ValueError:
        return True
    except Exception:
        return False


def main():
    print("=" * 70)
    print("0.4.9（3.48.2）应用内模块控制 专项回归")
    print("=" * 70)
    test_a_registry_structure()
    test_b_dispatch_errors()
    test_b_dispatch_real_modules()
    test_d_loop_routing()
    test_d_tools_spec_and_config()
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
