# VetarAI - Local-first multi-agent orchestration application
# Copyright (C) 2026 zero11924065-dev
# GPL-3.0-or-later（见仓库 LICENSE）
"""A6（0.4.18）专项：Agent 的工作流写能力（create/update/delete）。

═══ 治的是什么 ═══
APP_MODULE_REGISTRY 此前 3 模块 7 action，写类**仅 roundtable.create** ——
Agent 能跑工作流却不能建/改/删，用户只能去前端手工搭。现补 workflow create/update/delete。

═══ 关键设计（勿凭直觉改）═══
1. ⛔ **三个动作一律复用 app.py 的端点函数**（同 _roundtable_create 模式），不直调 store：
   端点已有 validate_definition(strict=False) 宽松校验、内置工作流保护(403)、
   422 错误前 5 条回传 → 复用即自动继承，且与前端行为逐字一致。
2. ⛔ **校验错误必须原样回传给 Agent**（不能吞掉）：工作流 schema 有 15 种节点类型 +
   连线/连通校验，Agent 易生成非法定义；回传具体原因它才能自修正。
3. ⛔ **definition 必须容错 JSON 字符串**：Agent 的工具参数由模型生成，嵌套对象常被
   序列化成字符串；直接当 dict 用会得到字符键值、校验必然失败且错误难懂。
4. ⛔ **节点类型清单动态取自 schema.NODE_TYPES**：手写版曾漏 file_output（写 14、真实 15）；
   交接文档里"14 种节点类型"同属失真。静态清单注定与 schema 漂移。
5. needs_confirm 分级：create/update = False（只写定义、无推理、可逆，避免 Agent 编排时
   频繁弹窗）；**delete = True**（破坏性不可逆，与 workflow_run 的高成本确认同级）。
6. ⛔ 内置工作流（built_in）不可改不可删 —— 端点已拦（403），动作须如实回传而非谎称成功。

运行：.venv/bin/python -m sidecar.app_modules.test_a6_workflow_write
"""
import asyncio
import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

PASS, FAIL = 0, 0
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


# 合法最简定义（strict=False 下可通过）
GOOD_DEFN = {"nodes": [{"id": "s", "type": "start"}, {"id": "e", "type": "end"}],
             "edges": [{"from": "s", "to": "e"}]}


def main():
    # 隔离：数据根指向临时目录（工作流存 _global.db，绝不能碰用户真实库）
    tmp = Path(tempfile.mkdtemp(prefix="a6_"))
    import sidecar.storage.store as store
    store.PROJECTS_ROOT = tmp / "projects"
    store.PROJECTS_ROOT.mkdir(parents=True, exist_ok=True)
    store._GDB = store.PROJECTS_ROOT / "_global.db"

    from sidecar.app_modules import (dispatch, action_needs_confirm, list_actions,
                                     APP_MODULE_REGISTRY)
    from sidecar.app_modules.registry import _coerce_definition
    from sidecar.storage.store import create_workflow, get_workflow
    from sidecar.workflow.schema import NODE_TYPES

    ctx = {"project_id": "p1", "session_id": "s1", "sandbox_root": str(tmp)}
    run = lambda *a, **kw: asyncio.run(dispatch(*a, **kw))

    # ── T1 注册表登记：写能力真的接入了（不是只写了 handler 没登记）──
    acts = list_actions()
    check("T1a 动作总数 7 → 10", len(acts) == 10, str(len(acts)))
    for a in ("workflow_create", "workflow_update", "workflow_delete"):
        check(f"T1b {a} 已登记且可路由", a in acts, str(acts))
    wf_acts = set(APP_MODULE_REGISTRY["workflow"]["actions"].keys())
    check("T1c workflow 模块含 6 个动作",
          wf_acts == {"list", "run", "get_runs", "create", "update", "delete"}, str(wf_acts))

    # ── T2 needs_confirm 分级 ──
    check("T2a create 默认不需确认（只写定义、可逆）",
          action_needs_confirm("workflow", "create", None) is False)
    check("T2b update 默认不需确认", action_needs_confirm("workflow", "update", None) is False)
    check("T2c ⛔ delete 默认需确认（破坏性不可逆）",
          action_needs_confirm("workflow", "delete", None) is True)
    # 配置仍可覆盖（既有机制不退化）
    check("T2d 配置可把 create 也纳入确认",
          action_needs_confirm("workflow", "create", ["workflow_create"]) is True)

    # ── T3 节点类型清单动态取自 schema（防手写漂移）──
    desc = APP_MODULE_REGISTRY["workflow"]["actions"]["create"]["description"]
    check("T3a create 描述含节点类型清单", "合法节点类型：" in desc, desc[-120:])
    check("T3b ⛔ 清单与 schema.NODE_TYPES 逐项一致（含 file_output，手写版曾漏）",
          all(t in desc for t in NODE_TYPES), 
          str([t for t in NODE_TYPES if t not in desc]))
    check("T3c file_output 确在清单里（曾经的漏项）", "file_output" in desc)

    # ── T4 definition 归一：dict / JSON 字符串 / 坏输入 ──
    d, err = _coerce_definition(GOOD_DEFN)
    check("T4a dict 原样通过", d == GOOD_DEFN and err is None, str(err))
    d, err = _coerce_definition(json.dumps(GOOD_DEFN))
    check("T4b JSON 字符串解析为 dict（Agent 常见形态）", d == GOOD_DEFN and err is None, str(err))
    d, err = _coerce_definition(None)
    check("T4c None → (None, None)（update 部分更新合法）", d is None and err is None)
    d, err = _coerce_definition("{不是json")
    check("T4d 坏 JSON → 明确报错不崩", d is None and err and "JSON" in err, str(err))
    d, err = _coerce_definition("[1,2,3]")
    check("T4e JSON 数组（非对象）→ 报错并说明应为对象",
          d is None and err and "对象" in err, str(err))
    d, err = _coerce_definition(123)
    check("T4f 非法类型（int）→ 报错", d is None and err and "类型非法" in err, str(err))

    # ── T5 create 端到端 ──
    r = run("workflow", "create",
            {"name": "A6测试流", "definition": GOOD_DEFN, "description": "端到端"}, ctx)
    check("T5a create 成功", r.get("ok") is True, str(r))
    wf_id = r.get("workflow_id") or ""
    check("T5b 返回 workflow_id 且真落库",
          bool(wf_id) and (get_workflow(wf_id) or {}).get("name") == "A6测试流", str(wf_id))
    check("T5c 回传说明含运行前完整性校验提示", "完整性校验" in str(r.get("note")), str(r.get("note")))

    r2 = run("workflow", "create", {"name": "字符串定义流", "definition": json.dumps(GOOD_DEFN)}, ctx)
    check("T5d definition 传 JSON 字符串也能创建", r2.get("ok") is True, str(r2))

    # ── T6 create 参数校验（如实报错，不谎称成功）──
    check("T6a 缺 name → bad_arg",
          run("workflow", "create", {"definition": GOOD_DEFN}, ctx).get("error", "").startswith("bad_arg"))
    check("T6b 缺 definition → bad_arg",
          run("workflow", "create", {"name": "x"}, ctx).get("error", "").startswith("bad_arg"))
    check("T6c 空 name（纯空格）→ bad_arg",
          run("workflow", "create", {"name": "   ", "definition": GOOD_DEFN}, ctx).get("ok") is False)

    # ── T7 ⛔ 非法定义：校验错误必须回传（A6 的命门——Agent 靠它自修正）──
    bad = {"nodes": [{"id": "s", "type": "start"}, {"id": "x", "type": "不存在的类型"}], "edges": []}
    r7 = run("workflow", "create", {"name": "非法流", "definition": bad}, ctx)
    check("T7a 非法节点类型被拒", r7.get("ok") is False, str(r7))
    check("T7b ⛔ 错误含**具体**校验原因（非笼统失败）",
          "类型无效" in str(r7.get("error")) and "不存在的类型" in str(r7.get("error")),
          str(r7.get("error"))[:160])
    check("T7c 附 hint 指引自修正（含合法类型清单）",
          "hint" in r7 and "合法节点类型" in str(r7["hint"]), str(r7.get("hint"))[:120])
    check("T7d 非法定义未落库（不产生垃圾工作流）",
          not any(w.get("name") == "非法流" for w in __import__("sidecar.storage.store", fromlist=["list_workflows"]).list_workflows()))

    # 连线指向不存在节点（另一类硬伤）
    bad2 = {"nodes": [{"id": "s", "type": "start"}], "edges": [{"from": "s", "to": "ghost"}]}
    r7e = run("workflow", "create", {"name": "坏连线", "definition": bad2}, ctx)
    check("T7e 连线指向不存在节点也被拒并回传原因",
          r7e.get("ok") is False and len(str(r7e.get("error"))) > 20, str(r7e)[:140])

    # ── T8 update ──
    r8 = run("workflow", "update", {"workflow_id": wf_id, "name": "改过名的流"}, ctx)
    check("T8a update 改名成功", r8.get("ok") is True and get_workflow(wf_id)["name"] == "改过名的流", str(r8))
    r8b = run("workflow", "update", {"workflow_id": wf_id, "description": "新说明"}, ctx)
    check("T8b update 改说明成功（部分更新）",
          r8b.get("ok") is True and get_workflow(wf_id)["description"] == "新说明", str(r8b))
    check("T8c 部分更新未误改其他字段（name 仍是改过的）",
          get_workflow(wf_id)["name"] == "改过名的流")
    r8d = run("workflow", "update", {"workflow_id": wf_id, "definition": json.dumps(GOOD_DEFN)}, ctx)
    check("T8d update 的 definition 也容错 JSON 字符串", r8d.get("ok") is True, str(r8d))
    r8e = run("workflow", "update", {"workflow_id": wf_id}, ctx)
    check("T8e ⛔ 空更新（三字段都不传）→ 如实拒绝而非谎称成功",
          r8e.get("ok") is False and "至少传一个" in str(r8e.get("error")), str(r8e))
    r8f = run("workflow", "update", {"workflow_id": "no-such", "name": "x"}, ctx)
    check("T8f 不存在的工作流 → 报错含原因",
          r8f.get("ok") is False and "不存在" in str(r8f.get("error")), str(r8f))
    check("T8g 缺 workflow_id → bad_arg",
          run("workflow", "update", {"name": "x"}, ctx).get("error", "").startswith("bad_arg"))
    # update 非法定义同样回传校验错误
    r8h = run("workflow", "update", {"workflow_id": wf_id, "definition": bad}, ctx)
    check("T8h update 传非法定义 → 同样回传校验原因",
          r8h.get("ok") is False and "类型无效" in str(r8h.get("error")), str(r8h)[:120])
    check("T8i update 被拒后原定义未被破坏",
          (get_workflow(wf_id) or {}).get("definition", {}).get("nodes") == GOOD_DEFN["nodes"])

    # ── T9 内置工作流保护 ──
    bi = create_workflow("内置示范", GOOD_DEFN, "", built_in=True)
    r9u = run("workflow", "update", {"workflow_id": bi, "name": "篡改内置"}, ctx)
    r9d = run("workflow", "delete", {"workflow_id": bi}, ctx)
    check("T9a 改内置被拒", r9u.get("ok") is False and "内置" in str(r9u.get("error")), str(r9u))
    check("T9b 删内置被拒", r9d.get("ok") is False and "内置" in str(r9d.get("error")), str(r9d))
    check("T9c 内置工作流完好未被改动", get_workflow(bi)["name"] == "内置示范")

    # ── T10 delete ──
    r10 = run("workflow", "delete", {"workflow_id": wf_id}, ctx)
    check("T10a delete 成功", r10.get("ok") is True, str(r10))
    check("T10b 定义确已删除", get_workflow(wf_id) is None)
    r10c = run("workflow", "delete", {"workflow_id": wf_id}, ctx)
    check("T10c 重复删除 → 如实报错（不谎称成功）",
          r10c.get("ok") is False and "不存在" in str(r10c.get("error")), str(r10c))
    check("T10d 缺 workflow_id → bad_arg",
          run("workflow", "delete", {}, ctx).get("error", "").startswith("bad_arg"))
    # id 别名：workflow_id 与 id 都接受（与 _workflow_run 一致）
    tmp_id = (run("workflow", "create", {"name": "别名测试", "definition": GOOD_DEFN}, ctx) or {}).get("workflow_id")
    r10e = run("workflow", "delete", {"id": tmp_id}, ctx)
    check("T10e delete 接受 id 别名（与 workflow_run 一致）", r10e.get("ok") is True, str(r10e))

    # ── T11 既有契约不退化 ──
    r11 = run("workflow", "nope", {}, ctx)
    check("T11a 未知动作仍可读报错并列出可用动作",
          r11.get("ok") is False and "create" in str(r11.get("error")), str(r11)[:120])
    r11b = run("workflow", "list", {}, ctx)
    check("T11b workflow_list 仍可用", r11b.get("ok") is True, str(r11b)[:100])
    r11c = run("nosuchmodule", "create", {}, ctx)
    check("T11c 未知模块仍可读报错", r11c.get("ok") is False and "unknown_module" in str(r11c.get("error")))

    # ── T12 复用端点（源码断言：不直调 store，保证与前端行为一致）──
    reg_src = (Path(__file__).resolve().parent / "registry.py").read_text(encoding="utf-8")
    for fn in ("_workflow_create", "_workflow_update", "_workflow_delete"):
        seg = reg_src.split(f"async def {fn}")[1].split("\nasync def ")[0]
        check(f"T12 {fn} 复用 app.py 端点（不直调 store 绕过校验）",
              "_app.api_" in seg and "create_workflow(" not in seg.replace("api_create_workflow(", ""),
              seg[:200])

    print(f"\n===== A6 专项: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        for f in FAILURES:
            print("  ✗", f)
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
