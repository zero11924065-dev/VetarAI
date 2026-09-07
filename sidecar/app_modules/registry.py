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
"""0.4.9（3.48.2）应用内模块控制：模块能力注册表 + app_control 统一执行器。

设计目标（需求文档 3.48.2）：
- Agent 可自主调用应用内模块（工作流 / 知识仓库 / 圆桌）；
- **新模块自动接入**：以后加新模块只需在 APP_MODULE_REGISTRY 登记一条，
  Agent 立刻获得调动能力——这是"新模块增加时 Agent 能否调动"的前瞻答案；
- 安全分级：查询类（低成本）直接执行；副作用类（高成本，如运行工作流、创建圆桌）
  须经用户确认（确认清单由配置 app_control_confirm 控制，可在设置调整）。

执行方式：**直接调用 Python 层函数**，不经 HTTP 自调用。
理由：①侧车自调 HTTP 需要知道端口、且会绕一圈网络栈与 guard，无谓开销；
②直接调用可复用同一进程内的存储连接与引擎实例，行为与端点完全一致；
③避免"应用调自己"造成的死锁风险（工作流运行是长任务）。
"""
from __future__ import annotations

import asyncio
from typing import Any, Callable, Awaitable

# 执行器签名：async (params: dict, ctx: dict) -> dict
# ctx 由 loop 传入：{"project_id", "session_id", "sandbox_root"}
Handler = Callable[[dict, dict], Awaitable[dict]]

# 0.4.11：workflow_run 有界等待（wait_s）参数。
WORKFLOW_RUN_MAX_WAIT = 120.0          # wait_s 上限（秒）：工具循环不可被单个动作长时间占住
_WORKFLOW_FINAL_STATUSES = ("done", "failed", "stopped")   # 终态（running 为进行中）


# ── 各模块动作的执行器（与 app.py 端点行为一致，直接调 Python 层）──────────

async def _workflow_list(params: dict, ctx: dict) -> dict:
    """列出工作流（查询类，直接执行）。"""
    from sidecar.storage.store import list_workflows
    items = list_workflows() or []
    brief = [{"id": w.get("id"), "name": w.get("name"),
              "description": (w.get("description") or "")[:120],
              "updated_at": w.get("updated_at")} for w in items]
    return {"ok": True, "count": len(brief), "workflows": brief}


async def _workflow_get_runs(params: dict, ctx: dict) -> dict:
    """查询工作流运行记录与状态（查询类）。运行是长任务，故触发后靠本动作轮询结果。"""
    from sidecar.storage.store import list_workflow_runs, get_workflow_run
    run_id = str(params.get("run_id") or "").strip()
    if run_id:
        r = get_workflow_run(run_id)
        if r is None:
            return {"ok": False, "error": f"run_not_found: 运行记录 {run_id} 不存在"}
        return {"ok": True, "run": r}
    wf_id = str(params.get("workflow_id") or "").strip() or None
    try:
        limit = max(1, min(int(params.get("limit") or 10), 50))
    except (TypeError, ValueError):
        limit = 10
    runs = list_workflow_runs(wf_id, limit) or []
    return {"ok": True, "count": len(runs), "runs": runs}


async def _workflow_run(params: dict, ctx: dict) -> dict:
    """触发工作流运行（副作用类，默认需确认）。

    ⚠️ 工作流是长任务（含多节点推理，可能数分钟）。Agent 的工具循环无法长时间阻塞等待，
    故采用【后台运行 + 立即返回 run_id】：Agent 拿到 run_id 后用 workflow_get_runs 查状态。
    这与前端 SSE 订阅是同一套 run 记录，行为一致。
    """
    from sidecar.storage.store import (get_workflow, create_workflow_run,
                                       update_workflow_run)
    from sidecar.workflow.engine import WorkflowEngine
    from sidecar.workflow.schema import validate_definition
    from sidecar.ollama.connector import get_ollama_connector

    wf_id = str(params.get("workflow_id") or params.get("id") or "").strip()
    if not wf_id:
        return {"ok": False, "error": "bad_arg: 需要 workflow_id（可先用 workflow_list 查看有哪些工作流）"}
    wf = get_workflow(wf_id)
    if wf is None:
        return {"ok": False, "error": f"workflow_not_found: 工作流 {wf_id} 不存在"}
    errors = validate_definition(wf.get("definition") or {})
    if errors:
        return {"ok": False, "error": "工作流定义有错误：" + "；".join(str(e) for e in errors[:5])}

    wf_params = params.get("params") if isinstance(params.get("params"), dict) else {}
    sandbox_root = str(params.get("sandbox_root") or ctx.get("sandbox_root") or "").strip()
    if not sandbox_root:
        import os as _os
        sandbox_root = str(_os.path.expanduser("~/Desktop"))
    run_id = create_workflow_run(wf_id, wf_params)

    async def _drive() -> None:
        """后台消费引擎事件直至结束；任何异常都落库为 failed（与端点 gen() 同构）。"""
        engine = WorkflowEngine(run_id, wf["definition"], get_ollama_connector(),
                                sandbox_root, params=wf_params)
        agen = engine.run()
        try:
            async for _ev in agen:
                pass
        except asyncio.CancelledError:
            raise
        except Exception as e:
            try:
                update_workflow_run(run_id, status="failed", error=str(e))
            except Exception:
                pass
        finally:
            try:
                await agen.aclose()   # 关闭引擎 → 卸载驻留模型（任何退出路径不漏释放）
            except Exception:
                pass

    asyncio.create_task(_drive())

    # 0.4.11：有界等待（wait_s）。此前一律「后台跑 + 返 run_id」，Agent 必须自己反复调
    # workflow_get_runs 轮询——每次轮询都是一整轮模型往返（读结果→决定再查→再读），
    # 一个几十秒的短流程要空耗好几轮 token 与时间。
    # 现允许 Agent 显式指定最多等多少秒：
    #   - 短流程：等到终态直接返回 status/result/error，一轮拿完
    #   - 长流程：超时即返回 running + run_id，退回原有轮询模式（不阻塞工具循环）
    # ⛔ 上限 120s：工具循环不能被单个动作长时间占住（与委派活性超时同一考量）。
    try:
        wait_s = float(params.get("wait_s") or 0)
    except (TypeError, ValueError):
        wait_s = 0.0
    wait_s = max(0.0, min(wait_s, WORKFLOW_RUN_MAX_WAIT))

    if wait_s > 0:
        from sidecar.storage.store import get_workflow_run
        # ⛔ 用 get_running_loop()：get_event_loop() 在 Python 3.12+ 已弃用，
        #    且本函数必在事件循环内被调用（async），running loop 一定存在。
        _loop = asyncio.get_running_loop()
        deadline = _loop.time() + wait_s
        poll = 0.4
        while True:
            await asyncio.sleep(poll)
            rec = get_workflow_run(run_id) or {}
            status = str(rec.get("status") or "")
            if status in _WORKFLOW_FINAL_STATUSES:
                return {"ok": True, "run_id": run_id, "workflow_name": wf.get("name"),
                        "status": status,
                        "waited_s": round(wait_s - (deadline - _loop.time()), 1),
                        "result": rec.get("result"), "error": rec.get("error"),
                        "current_node": rec.get("current_node"),
                        "note": "工作流已结束（在等待窗口内完成），无需再轮询。"}
            if _loop.time() >= deadline:
                return {"ok": True, "run_id": run_id, "workflow_name": wf.get("name"),
                        "status": status or "running",
                        "note": (f"等待 {wait_s:.0f}s 后仍未结束（工作流含多节点推理，可能需数分钟）。"
                                 f"已转为后台运行，用 workflow_get_runs(run_id=\"{run_id}\") 查询进度与结果。")}
            poll = min(poll * 1.5, 3.0)   # 退避轮询，避免频繁读库

    return {"ok": True, "run_id": run_id, "workflow_name": wf.get("name"),
            "status": "running",
            "note": ("工作流已在后台开始运行。用 workflow_get_runs(run_id=...) 查询进度与结果；"
                     "若想在本轮直接拿到结果，可传 wait_s（秒，上限 "
                     f"{int(WORKFLOW_RUN_MAX_WAIT)}）等待其结束。")}


async def _knowledge_search(params: dict, ctx: dict) -> dict:
    """检索知识仓库（查询类，直接执行）。与 search_knowledge 工具同源，
    区别：本动作经 app_control 统一入口，便于 Agent 以"模块动作"心智调用。"""
    from sidecar.knowledge import warehouse as _wh
    q = str(params.get("query") or params.get("q") or "").strip()
    if not q:
        return {"ok": False, "error": "bad_arg: 需要 query（检索词）"}
    scope = str(params.get("scope") or "all").strip()
    mode = str(params.get("mode") or "hybrid").strip()
    try:
        limit = max(1, min(int(params.get("limit") or 5), 20))
    except (TypeError, ValueError):
        limit = 5
    _wh.prune_missing()   # 外部删除对账，不返回幽灵条目
    pid = str(params.get("project_id") or ctx.get("project_id") or "") or None
    if scope == "project":
        hits = _wh.hybrid_search(q, "project", pid, limit, mode=mode)
    elif scope == "global":
        hits = _wh.hybrid_search(q, "global", None, limit, mode=mode)
    else:
        h1 = _wh.hybrid_search(q, "project", pid, limit, mode=mode)
        h2 = _wh.hybrid_search(q, "global", None, limit, mode=mode)
        hits = sorted(h1 + h2, key=lambda e: -float(e.get("score") or 0))[:limit]
    items = [{"id": h.get("id"), "title": h.get("title"), "scope": h.get("scope"),
              "score": h.get("score"), "body": (h.get("body") or "")[:1500]} for h in hits]
    return {"ok": True, "count": len(items), "items": items,
            "note": "检索结果仅本轮可见，不会写入对话上下文（拉模式）。"}


async def _knowledge_inject(params: dict, ctx: dict) -> dict:
    """把指定知识条目正文拼为文本返回（查询类：不写库、不改会话，只是取内容）。

    与端点 /api/knowledge/inject 同构。返回的 text 由 Agent 自行决定如何使用
    （通常作为后续推理的依据）。不做"自动注入会话"——注入是前端行为，
    Agent 侧只需拿到内容，避免越权修改会话历史。
    """
    from sidecar.knowledge import warehouse as _wh
    ids = params.get("entry_ids") or params.get("ids") or []
    if isinstance(ids, str):
        ids = [x.strip() for x in ids.split(",") if x.strip()]
    if not isinstance(ids, list) or not ids:
        return {"ok": False, "error": "bad_arg: 需要 entry_ids（知识条目 id 列表，可先用 knowledge_search 获取）"}
    _wh.prune_missing()
    parts = []
    missing = []
    for eid in ids:
        e = _wh.get_entry(str(eid))
        if e is None:
            missing.append(str(eid))
            continue
        parts.append(f"## {e.get('title','')}\n\n{e.get('body','')}")
    if not parts:
        return {"ok": False, "error": f"entries_not_found: 条目不存在或已被删除（{', '.join(missing[:5])}）"}
    text = "\n\n---\n\n".join(parts)
    out = {"ok": True, "count": len(parts), "text": text[:20000]}
    if missing:
        out["missing"] = missing
    return out


async def _knowledge_groups(params: dict, ctx: dict) -> dict:
    """知识仓库分组概览（查询类）：全局 + 各项目的条数与目录。

    直接复用 app.py 的端点函数 api_knowledge_groups（真实存在，warehouse 层并无
    groups()），保证与设置页资产管理器看到的口径完全一致（含外部删除对账）。
    """
    from sidecar import app as _app
    try:
        groups = await _app.api_knowledge_groups()
    except Exception as e:
        return {"ok": False, "error": f"{type(e).__name__}: {e}"}
    return {"ok": True, "count": len(groups or []), "groups": groups or []}


async def _roundtable_create(params: dict, ctx: dict) -> dict:
    """创建圆桌讨论并执行第一轮（副作用类，默认需确认）。

    复用 app.py 的圆桌创建端点函数，保证行为完全一致（含附件落盘、纪要初始化）。
    """
    from sidecar import app as _app
    topic = str(params.get("topic") or "").strip()
    if not topic:
        return {"ok": False, "error": "bad_arg: 需要 topic（讨论议题）"}
    agent_ids = params.get("agent_ids") or []
    if isinstance(agent_ids, str):
        agent_ids = [x.strip() for x in agent_ids.split(",") if x.strip()]
    if not isinstance(agent_ids, list) or len(agent_ids) < 2:
        return {"ok": False, "error": "bad_arg: agent_ids 至少需要 2 个 Agent（圆桌是多方会诊）"}
    pid = str(params.get("project_id") or ctx.get("project_id") or "").strip()
    if not pid:
        return {"ok": False, "error": "bad_arg: 需要 project_id（圆桌属于某个项目）"}
    try:
        max_rounds = max(1, min(int(params.get("max_rounds") or 5), 20))
    except (TypeError, ValueError):
        max_rounds = 5
    req = _app.RoundtableCreateReq(
        topic=topic,
        agent_ids=[str(a) for a in agent_ids],
        moderator=str(params.get("moderator") or "user"),
        moderator_agent_id=params.get("moderator_agent_id"),
        max_rounds=max_rounds,
        attachments=[],
    )
    try:
        rt = await _app.api_create_roundtable(pid, req)
    except Exception as e:
        # HTTPException 也走这里：把 detail 作为可读原因回传（任务161：报错必带原因）
        detail = getattr(e, "detail", None) or str(e)
        return {"ok": False, "error": f"roundtable_create_failed: {detail}"}
    return {"ok": True, "roundtable": rt,
            "note": "圆桌已创建并完成第一轮。后续轮次由用户在圆桌面板继续（结束权在用户）。"}


# ── 模块能力注册表 ──────────────────────────────────────────────────────
# ⭐ 新模块接入方式：在此登记一条（module/action/description/params/handler/needs_confirm），
#    Agent 立即获得调用能力，无需改 loop.py 或前端。这是 3.48.2 的前瞻性设计核心。
APP_MODULE_REGISTRY: dict[str, dict[str, Any]] = {
    "workflow": {
        "description": "流程中心：可视化工作流（确定性节点编排，适合批量识图/转写/文件处理）",
        "actions": {
            "list": {
                "description": "列出全部工作流（id/名称/描述）。调用 workflow_run 前先用它拿到 workflow_id。",
                "params": {},
                "handler": _workflow_list,
                "needs_confirm": False,
            },
            "run": {
                "description": "触发运行指定工作流。工作流是长任务，默认立即返回 run_id 并在后台执行，"
                             "之后用 get_runs 查询进度与结果。"
                             "⚡ 若希望本轮直接拿到结果（省去反复轮询的多轮往返），可传 wait_s 有界等待：短流程等到结束即返回 "
                             "status/result/error；长流程超时则返回 running + run_id，退回轮询。",
                "params": {
                    "workflow_id": "str（必填，工作流 id；用 workflow.list 查）",
                    "params": "dict（可选，工作流入参 variables）",
                    "sandbox_root": "str（可选，文件节点的根目录；默认用当前会话工作目录）",
                    "wait_s": "float（可选，0.4.11 新增，有界等待秒数，上限 120；"
                              "不传或 0=立即返回 run_id 后台跑；传正值=最多等这么久拿结果）",
                },
                "handler": _workflow_run,
                "needs_confirm": True,   # 高成本：会跑多节点推理、占用模型与内存
            },
            "get_runs": {
                "description": "查询工作流运行记录与状态。传 run_id 查单次运行详情；"
                             "传 workflow_id 查该工作流最近运行；都不传则查全局最近运行。",
                "params": {
                    "run_id": "str（可选，单次运行 id）",
                    "workflow_id": "str（可选，按工作流过滤）",
                    "limit": "int（可选，默认 10，上限 50）",
                },
                "handler": _workflow_get_runs,
                "needs_confirm": False,
            },
        },
    },
    "knowledge": {
        "description": "知识仓库：把对话/材料沉淀为本地知识（拉模式，永不自动注入上下文）",
        "actions": {
            "search": {
                "description": "检索知识仓库（关键词+语义混合）。仅当需要引用历史沉淀时使用。",
                "params": {
                    "query": "str（必填，检索词或自然语言描述）",
                    "scope": "str（可选，project/global/all，默认 all）",
                    "mode": "str（可选，hybrid/keyword/semantic，默认 hybrid）",
                    "limit": "int（可选，默认 5，上限 20）",
                },
                "handler": _knowledge_search,
                "needs_confirm": False,
            },
            "inject": {
                "description": "取出指定知识条目的正文（按 entry_ids）。返回文本供你作为依据使用；"
                             "不会自动写入会话历史。",
                "params": {"entry_ids": "list[str]（必填，条目 id；用 knowledge.search 获取）"},
                "handler": _knowledge_inject,
                "needs_confirm": False,
            },
            "groups": {
                "description": "查看知识仓库分组概览（全局/各项目的条数）。",
                "params": {},
                "handler": _knowledge_groups,
                "needs_confirm": False,
            },
        },
    },
    "roundtable": {
        "description": "圆桌讨论：多个 Agent 就一个议题会诊（专家会诊模式）",
        "actions": {
            "create": {
                "description": "创建圆桌讨论并执行第一轮。需至少 2 个 Agent。"
                             "后续轮次与结束由用户在圆桌面板掌控。",
                "params": {
                    "topic": "str（必填，讨论议题）",
                    "agent_ids": "list[str]（必填，≥2 个参与 Agent 的 id）",
                    "project_id": "str（可选，默认当前项目）",
                    "moderator": "str（可选，user/ai，默认 user）",
                    "max_rounds": "int（可选，默认 5，上限 20）",
                },
                "handler": _roundtable_create,
                "needs_confirm": True,   # 高成本：多方多轮推理
            },
        },
    },
}


def list_actions(needs_confirm_list: list[str] | None = None) -> list[str]:
    """列出全部动作名（形如 workflow_run / knowledge_search）。

    needs_confirm_list 由配置 app_control_confirm 提供，用于在清单中标注哪些需确认
    （注册表里的 needs_confirm 是默认值，配置可覆盖）。
    """
    out = []
    for mod, spec in APP_MODULE_REGISTRY.items():
        for act in spec.get("actions", {}):
            out.append(f"{mod}_{act}")
    return out


def action_needs_confirm(module: str, action: str, confirm_list: list[str] | None) -> bool:
    """判定某动作是否需要用户确认。

    优先级：配置 app_control_confirm（用户可在设置调整）> 注册表默认 needs_confirm。
    配置为 None 时用注册表默认；配置为列表时，动作名在列表内即需确认。
    """
    name = f"{module}_{action}"
    if confirm_list is not None:
        return name in [str(x) for x in confirm_list]
    act = (APP_MODULE_REGISTRY.get(module, {}).get("actions", {}) or {}).get(action, {})
    return bool(act.get("needs_confirm", False))


def build_module_catalog_text() -> str:
    """把可用动作清单渲染为提示词文本，让 Agent 知道自己能调用什么。"""
    lines = []
    for mod, spec in APP_MODULE_REGISTRY.items():
        lines.append(f"- {mod}：{spec.get('description','')}")
        for act, a in (spec.get("actions", {}) or {}).items():
            lines.append(f"    · {mod}.{act} — {a.get('description','')}")
    return "\n".join(lines)


async def dispatch(module: str, action: str, params: dict, ctx: dict) -> dict:
    """按注册表路由到对应执行器。未知模块/动作 → 返回可读错误并列出可用项
    （任务161 精神：报错必带原因 + 纠正指引，不返回裸 unknown）。"""
    mod_spec = APP_MODULE_REGISTRY.get(module)
    if mod_spec is None:
        return {"ok": False, "error": (
            f"unknown_module: 没有名为「{module}」的应用模块。"
            f"可用模块：{'、'.join(APP_MODULE_REGISTRY.keys())}。")}
    act_spec = (mod_spec.get("actions", {}) or {}).get(action)
    if act_spec is None:
        return {"ok": False, "error": (
            f"unknown_action: 模块「{module}」没有动作「{action}」。"
            f"该模块可用动作：{'、'.join((mod_spec.get('actions') or {}).keys())}。")}
    handler: Handler = act_spec["handler"]
    try:
        return await handler(params or {}, ctx or {})
    except Exception as e:
        return {"ok": False, "error": f"{type(e).__name__}: {e}"}
