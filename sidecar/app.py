from __future__ import annotations
from typing import Any
from datetime import datetime
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import asyncio
import json as _json
import os as _os
import httpx
from fastapi.responses import JSONResponse, StreamingResponse
from sidecar.ollama.connector import get_ollama_connector, OllamaAPIError
from sidecar.agent_engine.loop import run_tool_loop, build_system_prompt, tools_spec
from sidecar.network.guard import NetworkGuardError
from sidecar.config import get_config, reload_config, get_config_path
from sidecar.storage.store import (
    create_project, delete_project, list_projects, rename_project, get_project,
    add_agent_config, remove_agent_config, list_agent_configs,
    update_agent_config, get_agent_config,
    create_session, list_sessions, rename_session, delete_session,
    save_message, load_messages, save_session_summary,
    log_compact, load_compact_log, delete_messages_before,
    list_agent_tasks, get_agent_task,
    # checkpoint-058：独立 Agent（与项目平级）
    INDEP_NS_PREFIX, independent_agent_dir,
    add_independent_agent, list_independent_agents, get_independent_agent,
    update_independent_agent, delete_independent_agent,
)
from sidecar.compactor import compact_session, export_session_md
from sidecar.agent_engine.delegation import (
    run_delegated_task, request_delegation_cancel)
from sidecar.agent_engine import roundtable as rt_mod
from sidecar.storage.store import (
    list_roundtables, get_roundtable, list_roundtable_messages,
)
# 0.2.1（TS-119）：工作流模块（一级模块"流程中心"）
from sidecar.storage.store import (
    create_workflow, update_workflow, list_workflows, get_workflow, delete_workflow,
    create_workflow_run, update_workflow_run, get_workflow_run, list_workflow_runs,
    list_workflow_node_events,
)
from sidecar.workflow.engine import (
    WorkflowEngine, resolve_workflow_approval, request_workflow_cancel,
)
from sidecar.workflow.schema import validate_definition
from sidecar.logging_setup import setup_logging, resolve_log_dir
import logging

# checkpoint-043（用户需求）：应用日志落盘——报错/bug 可在应用目录内 logs/ 排查。
# 幂等；失败不阻塞应用启动。
_LOG_PATH = setup_logging()
_log = logging.getLogger("sidecar.app")

app = FastAPI()
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])


# checkpoint-043：全局异常兜底——未被端点捕获的异常落日志后再返回 500。
# FastAPI 的 HTTPException（业务错误 400/404 等）走默认处理，不重复记日志。
@app.middleware("http")
async def _log_unhandled_errors(request, call_next):
    try:
        return await call_next(request)
    except Exception as exc:
        _log.exception("未处理异常 %s %s", request.method, request.url.path)
        return JSONResponse(status_code=500, content={"detail": f"内部错误: {exc}"})


@app.get("/api/logs/info")
async def api_logs_info():
    """checkpoint-043：日志目录信息（前端"打开日志文件夹"入口数据源）。"""
    try:
        d = resolve_log_dir()
        return {"log_dir": str(d), "log_file": str(_LOG_PATH) if _LOG_PATH else ""}
    except Exception as e:  # 查询失败不影响应用
        raise HTTPException(status_code=500, detail=str(e))


# ── M1-1 越界授权协调器（2026-08-28 问题2：实现延期的弹窗授权）──────────
# 侧车通过 SSE 发 auth_request 事件 → 前端弹窗 → 用户选择经 /api/auth/respond 回传
# _auth_pending: {request_id: {"event": asyncio.Event, "result": bool}}
_auth_pending: dict[str, dict] = {}
_AUTH_TIMEOUT = 120.0  # 用户 2 分钟未响应 → 自动拒绝


async def _sse_authorizer(tool_name: str, target_path: str, action: str) -> bool:
    """SSE 驱动的越界授权回调（注入 run_tool_loop 的 authorizer 参数）。

    流程：生成唯一 request_id → 存入 _auth_pending → yield auth_request 事件由 gen() 发出
    → 等待前端 /api/auth/respond 唤醒 Event → 返回用户选择。
    注意：此函数被 loop 调用时处于 gen() 的 async for 内，无法直接 yield SSE 事件；
    改为把请求挂到全局字典，由 gen() 主循环在下次迭代时检测并发出事件。
    """
    import uuid
    req_id = str(uuid.uuid4())[:8]
    evt = asyncio.Event()
    _auth_pending[req_id] = {"event": evt, "result": False,
                              "tool": tool_name, "path": target_path, "action": action}
    # 等待 gen() 主循环检测到新请求并发出 SSE 事件后，前端响应唤醒此 Event
    try:
        await asyncio.wait_for(evt.wait(), timeout=_AUTH_TIMEOUT)
    except asyncio.TimeoutError:
        _auth_pending.pop(req_id, None)
        return False
    entry = _auth_pending.pop(req_id, {})
    return entry.get("result", False)

@app.exception_handler(NetworkGuardError)
async def _guard_handler(request, exc: NetworkGuardError):
    """网络开关拒绝 / 出站失败 → 403 + 明确中文提示（P1-3）。不重试。"""
    from fastapi.responses import JSONResponse
    return JSONResponse(status_code=403, content={"detail": exc.message})

@app.exception_handler(OllamaAPIError)
async def _ollama_api_handler(request, exc: OllamaAPIError):
    """Ollama 业务错误（模型不存在/超限等）→ 400 + 原始 detail（P1-4 语义分离）。"""
    from fastapi.responses import JSONResponse
    return JSONResponse(status_code=exc.status_code, content={"detail": exc.message, "raw": exc.detail})


@app.on_event("startup")
async def _boot():
    # Ensure config.json exists (first run) and log the resolved location.
    cfg = get_config()
    print(f"[sidecar] config loaded from {get_config_path()}", flush=True)
    print(f"[sidecar] ollama={cfg['ollama_base_url']} data_root={cfg['data_root']}", flush=True)


@app.on_event("shutdown")
async def _shutdown():
    # TS-103 B09：退出时关闭共享连接池，避免连接残留
    try:
        await get_ollama_connector().aclose_all()
    except Exception as e:
        print(f"[sidecar] connector close error: {e}", flush=True)


@app.get("/api/config")
async def api_get_config():
    return get_config()


@app.put("/api/config")
async def api_update_config(body: dict):
    try:
        cfg = reload_config(body)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"保存配置失败: {e}")
    return cfg


@app.get("/api/config/path")
async def api_config_path():
    return {"path": str(get_config_path())}


class ChatReq(BaseModel):
    agent_id: str
    model: str
    messages: list[dict[str, Any]]
    images: list[str] | None = None
    project_id: str = ""
    session_id: str = ""

class ProjectCreateReq(BaseModel):
    name: str
    working_dir: str

class AgentCreateReq(BaseModel):
    project_id: str
    name: str
    type_: str
    model_name: str | None = None
    parent_agent_id: str | None = None
    role: str | None = None
    system_prompt: str | None = None

@app.post("/api/projects")
async def api_create_project(req: ProjectCreateReq):
    # checkpoint-061 查虫修复：名称/工作目录非空校验（前端有兜底，后端也要有防线）
    if not (req.name or "").strip():
        raise HTTPException(status_code=400, detail="项目名称不能为空")
    if not (req.working_dir or "").strip():
        raise HTTPException(status_code=400, detail="工作目录不能为空")
    # checkpoint-050 查虫修复 B-4：工作目录创建失败（非法路径/无权限）→ 400 用户可懂错误
    try:
        return {"project_id": create_project(req.name, req.working_dir)}
    except (PermissionError, OSError) as e:
        raise HTTPException(status_code=400, detail=str(e))

@app.get("/api/projects")
async def api_list_projects():
    return list_projects()

@app.delete("/api/projects/{project_id}")
async def api_delete_project(project_id: str):
    return {"deleted": delete_project(project_id)}

# ── checkpoint-058：独立 Agent（与项目平级的一等公民）──────────────────
# 不属于任何项目：全局注册表 + 独立数据目录（ia-<id>/）。删除任何项目不影响它；
# 全局记忆/技能/插件照常可用（均为全局作用域）。命名空间 project_id := "ia-<id>"。
class IndepAgentCreateReq(BaseModel):
    name: str
    model_name: str | None = None
    system_prompt: str | None = None

class IndepAgentUpdateReq(BaseModel):
    name: str | None = None
    system_prompt: str | None = None
    model_name: str | None = None

@app.post("/api/independent-agents")
async def api_add_independent_agent(req: IndepAgentCreateReq):
    name = req.name.strip()
    if not name:
        raise HTTPException(status_code=422, detail="名称不能为空")
    return {"agent_id": add_independent_agent(
        name, model_name=req.model_name, system_prompt=req.system_prompt)}

@app.get("/api/independent-agents")
async def api_list_independent_agents():
    return list_independent_agents()

@app.put("/api/independent-agents/{agent_id}")
async def api_update_independent_agent(agent_id: str, req: IndepAgentUpdateReq):
    ok = update_independent_agent(
        agent_id, name=req.name, system_prompt=req.system_prompt, model_name=req.model_name)
    if not ok:
        raise HTTPException(status_code=404, detail="独立 Agent 不存在或无有效更新字段")
    return {"updated": True}

@app.delete("/api/independent-agents/{agent_id}")
async def api_delete_independent_agent(agent_id: str):
    if not delete_independent_agent(agent_id):
        raise HTTPException(status_code=404, detail="独立 Agent 不存在")
    return {"deleted": True}

@app.post("/api/agents")
async def api_add_agent(req: AgentCreateReq):
    # checkpoint-050 查虫修复 B-3：type_ 端点校验（非法值转 422，不再落到 DB CHECK 约束裸抛）
    if req.type_ not in ("main", "sub"):
        raise HTTPException(status_code=422, detail="type_ 必须是 main 或 sub")
    # checkpoint-056：项目存在性校验——杜绝"幽灵项目"上建 Agent（项目已删/不存在 → 明确报错）
    if get_project(req.project_id) is None:
        raise HTTPException(status_code=404, detail="项目不存在或已被删除，请重新选择项目")
    return {"agent_id": add_agent_config(
        req.project_id, req.name, req.type_,
        model_name=req.model_name, parent_agent_id=req.parent_agent_id,
        role=req.role, system_prompt=req.system_prompt,
    )}

@app.delete("/api/agents/{project_id}/{agent_id}")
async def api_remove_agent(project_id: str, agent_id: str):
    # TS-114（3.25）+ TS-115（3.19② 维度 B/C）：删除前 stop 关联 running 委派任务。
    # 关联 = 该 Agent 是委派目标（target_agent_id）或发起者（parent_agent_id）。
    # TS-115 增强：stop 后等 1s 让执行循环检测到取消标志。
    stopped = 0
    try:
        for t in list_agent_tasks(project_id, limit=200):
            if t.get("status") in ("queued", "running") and (
                    t.get("target_agent_id") == agent_id or t.get("parent_agent_id") == agent_id):
                request_delegation_cancel(t["id"])
                stopped += 1
        if stopped:
            await asyncio.sleep(1)
    except Exception:
        pass  # stop 失败不影响删除
    removed = remove_agent_config(project_id, agent_id)
    return {"removed": removed, "stopped_tasks": stopped}

@app.get("/api/agents/{project_id}")
async def api_list_agents(project_id: str):
    return list_agent_configs(project_id)

@app.get("/api/ollama/models")
async def api_ollama_models():
    c = get_ollama_connector()
    models = await c.list_models()
    return [{"name": m.get("name"), "size": m.get("size", 0)} for m in models]

@app.post("/api/ollama/chat")
async def api_ollama_chat(req: ChatReq):
    project_id = req.project_id or ""
    if not req.messages:
        raise HTTPException(status_code=422, detail="messages 不能为空")
    if not req.session_id:
        raise HTTPException(status_code=422, detail="session_id 不能为空")

    c = get_ollama_connector()
    reply = await c.chat(model=req.model, messages=req.messages, images=req.images)

    # 持久化到 session
    last_msg = req.messages[-1]
    user_content = last_msg.get("content", "") if isinstance(last_msg, dict) else str(last_msg)
    save_message(project_id, req.session_id, req.agent_id, "user", user_content,
                 images=req.images)
    save_message(project_id, req.session_id, req.agent_id, "assistant", reply,
                 model_used=req.model)
    return {"content": reply}

@app.post("/api/ollama/pull")
async def api_ollama_pull(body: dict):
    c = get_ollama_connector()
    # M6（TS-112）：仅 Ollama 后端支持拉取（能力表是唯一事实源）
    if not c.capabilities().get("pull"):
        raise HTTPException(status_code=400, detail="当前推理后端不支持模型拉取（仅 Ollama 后端支持）")
    events = await c.pull_model(body.get("name", ""))
    return {"events": events}

@app.delete("/api/ollama/models/{name}")
async def api_ollama_delete(name: str, body: dict | None = None):
    c = get_ollama_connector()
    # M6（TS-112）：仅 Ollama 后端支持删除（能力表是唯一事实源）
    if not c.capabilities().get("delete"):
        raise HTTPException(status_code=400, detail="当前推理后端不支持模型删除（仅 Ollama 后端支持）")
    ok = await c.delete_model(name)
    return {"deleted": ok}

@app.get("/api/inference/status")
async def api_inference_status():
    """M6（TS-112）：当前推理后端状态（在线探测 + 能力表）。"""
    cfg = get_config()
    backend = str(cfg.get("inference_backend", "ollama")).strip()
    c = get_ollama_connector()
    caps = c.capabilities()
    try:
        await asyncio.wait_for(c.list_models(), timeout=8.0)
        online = True
        detail = ""
    except asyncio.TimeoutError:
        online = False
        detail = "连接超时（8s），请检查地址是否正确、服务是否启动"
    except Exception as e:
        online = False
        detail = str(e)[:200]
    base_url = (cfg.get("ollama_base_url") if backend == "ollama"
                else cfg.get("inference_base_url")) or ""
    return {"backend": backend, "base_url": base_url, "online": online,
            "detail": detail, "capabilities": caps}

@app.get("/api/inference/models")
async def api_inference_models():
    """M6（TS-112）：统一模型列表（ollama 带 size/context；openai_compatible 仅 name）。"""
    c = get_ollama_connector()
    try:
        models = await c.list_models()
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"推理后端不可达：{e}")
    out = []
    for m in models:
        name = m.get("name") or m.get("id") or ""
        if not name:
            continue
        entry: dict = {"name": name}
        if "size" in m:
            entry["size"] = m.get("size", 0)
        ctx = (m.get("details") or {}).get("context_length") or m.get("context_length")
        if ctx:
            entry["context_length"] = ctx
        out.append(entry)
    return out

@app.get("/api/ollama/model-status")
async def api_model_status(model: str = ""):
    """M5（TS-111）：模型状态探测（前端降级引导数据源）。

    返回 {"status": "online"|"missing"|"error", "models": [...], "detail": str}
    - online：指定模型在本地可用（model 为空时仅探测 Ollama 可达性）
    - missing：Ollama 可达但模型未安装
    - error：Ollama 不可达（detail 含原因）
    """
    import httpx as _httpx2
    cfg = get_config()
    base = cfg.get("ollama_base_url", "").rstrip("/")
    try:
        async with _httpx2.AsyncClient(timeout=_httpx2.Timeout(5.0, connect=5.0),
                                       trust_env=False) as client:
            r = await client.get(f"{base}/api/tags")
            r.raise_for_status()
            names = [m.get("name", "") for m in r.json().get("models", [])]
    except Exception as e:
        return {"status": "error", "models": [], "detail": f"Ollama 不可达：{e}"}
    if not model:
        return {"status": "online", "models": names, "detail": ""}
    hit = any(n == model or n.startswith(model + ":") for n in names)
    if hit:
        return {"status": "online", "models": names, "detail": ""}
    return {"status": "missing", "models": names,
            "detail": f"模型 {model} 未安装。本地可用：{'、'.join(names) if names else '（无）'}"}


@app.get("/api/context/limit")
async def api_context_limit(model: str = "qwen3.8"):
    """M2 上下文上限 API：返回模型的 context_length。

    - 已加载 → 从 /api/ps 读 context_length
    - 未加载 → 兜底 262144（协议常量：qwen 系默认上限）
    - Ollama 不可达 → {"context_length": 0, "source": "error"}
    - 非 Ollama 后端 → {"context_length": 0, "source": "unsupported"}（M6）
    整体超时 5s，失败不阻塞前端。
    """
    # M6（TS-112）：仅 Ollama 后端可查 /api/ps；其余后端返回 unsupported（前端隐藏指示器，不报错）
    if str(get_config().get("inference_backend", "ollama")) != "ollama":
        return {"context_length": 0, "source": "unsupported", "model": model}
    import httpx
    cfg = get_config()
    base = cfg.get("ollama_base_url", "http://localhost:11434").rstrip("/")
    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(5.0, connect=5.0),
                                     trust_env=False) as client:
            # 1) 尝试 /api/ps 读已加载模型的 context_length
            r = await client.get(f"{base}/api/ps")
            r.raise_for_status()
            data = r.json()
            for m in data.get("models", []):
                name = m.get("name", "")
                # name 形如 "qwen3.8:latest"，找以 {model} 开头的
                if name == model or name.startswith(model + ":") or name.startswith(model):
                    cl = m.get("context_length") or m.get("details", {}).get("context_length")
                    if cl:
                        return {"context_length": int(cl), "source": "ps", "model": name}
            # 2) 模型未加载 → 兜底
            return {"context_length": 262144, "source": "default", "model": model}
    except Exception:
        return {"context_length": 0, "source": "error", "model": model}


@app.post("/api/sessions/{session_id}/compact")
async def api_compact(session_id: str, project_id: str, body: dict | None = None):
    """M2 智能压缩：归档 → 摘要 → 落库。"""
    body = body or {}
    keep_recent = body.get("keep_recent")
    model = body.get("model", "qwen3.8")
    result = await compact_session(project_id, session_id, keep_recent=keep_recent, model=model)
    if not result.get("ok"):
        from fastapi import HTTPException
        raise HTTPException(status_code=422, detail=result.get("error", "压缩失败"))
    return result


@app.post("/api/sessions/{session_id}/export")
async def api_export(session_id: str, project_id: str | None = None, body: dict | None = None):
    """M2 导出会话 MD；M7（TS-113）：不传 dir 时走统一默认导出目录
    （含工具步骤摘要）；传 dir 保持旧行为（L2 目录白名单校验）。

    0.2.4（Z1 修复）：project_id 兼容查询参数与 JSON body 两种来源——
    此前仅认查询参数，前端放在 body 里 → 422 → 前端提示渲染成 [object Object]。
    """
    body = body or {}
    project_id = project_id or str(body.get("project_id") or "")
    if not project_id:
        raise HTTPException(status_code=400, detail="缺少 project_id")
    export_dir = body.get("dir")
    if export_dir:
        try:
            path = export_session_md(project_id, session_id, export_dir)
        except ValueError as e:
            # checkpoint-050 查虫修复：目录白名单拒绝（如路径穿越）→ 400 而非 500
            raise HTTPException(status_code=400, detail=str(e))
        return {"ok": True, "path": str(path)}
    try:
        from sidecar.exporter import export_session_md as export_unified
        result = export_unified(project_id, session_id, body.get("agent_id") or "")
    except ValueError as e:
        raise HTTPException(status_code=404, detail=str(e))
    return {"ok": True, "path": result["path"], "name": result["name"]}


# checkpoint-048（需求 3.6 断链修复）：会话自动总结端点。
# 流程：加载会话消息 → 截断拼接 → 模型生成总结 → save_session_summary 落 MD+DB。
# 消息内容总量上限（防超 context）；模型失败抛业务错误（前端提示重试）。
_SUMMARY_MAX_SOURCE_CHARS = 8000  # 参与总结的会话原文上限

@app.post("/api/sessions/{session_id}/summarize")
async def api_summarize_session(session_id: str, project_id: str | None = None, body: dict | None = None):
    body = body or {}
    # 0.2.4（Z1 修复）：project_id 兼容查询参数与 JSON body 两种来源
    project_id = project_id or str(body.get("project_id") or "")
    if not project_id:
        raise HTTPException(status_code=400, detail="缺少 project_id")
    agent_id = str(body.get("agent_id") or "")
    model = str(body.get("model") or get_config().get("default_model", "qwen3.8"))

    msgs = load_messages(project_id, session_id)
    if not msgs:
        raise HTTPException(status_code=404, detail="会话不存在或无消息，无法总结")

    # 拼接对话原文（角色 + 内容），超长截断
    lines = []
    total = 0
    for m in msgs:
        role = m.get("role", "?")
        if role not in ("user", "assistant"):
            continue
        if m.get("archived"):
            continue  # TS-120：已移入知识仓库的消息不参与总结
        content = str(m.get("content") or "")
        if not content.strip():
            continue
        seg = f"{role}: {content}"
        if total + len(seg) > _SUMMARY_MAX_SOURCE_CHARS:
            lines.append("（更早内容已截断）")
            break
        lines.append(seg)
        total += len(seg)
    if not lines:
        raise HTTPException(status_code=422, detail="会话无可总结的内容")

    source = "\n".join(lines)
    prompt = ("请为以下对话写一份简明的中文总结（300 字以内）：先一句话概括结论/成果，"
              "再列出关键讨论点与产出（如有文件/代码产出请点名），最后给出遗留事项（如有）。\n"
              "只输出总结本身，不要输出任何解释。\n\n---\n" + source)

    try:
        conn = get_ollama_connector()
        summary = await conn.chat(model, [{"role": "user", "content": prompt}])
    except (NetworkGuardError, OllamaAPIError) as e:
        raise  # 走全局异常处理（403/400 + 中文提示）
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"总结生成失败：{e}")

    summary = (summary or "").strip()
    if not summary:
        raise HTTPException(status_code=502, detail="模型未返回总结内容，请重试")

    fpath = save_session_summary(project_id, session_id, agent_id, summary)
    return {"ok": True, "summary": summary, "saved_file": str(fpath)}


@app.get("/api/sessions/{session_id}/compact_log")
async def api_compact_log(session_id: str, project_id: str):
    """M2 读压缩日志（最近 3 条）。"""
    logs = load_compact_log(project_id, session_id, limit=3)
    return {"logs": logs}


class SummaryReq(BaseModel):
    project_id: str
    agent_id: str
    session_id: str
    summary_text: str

@app.post("/api/summaries")
async def api_save_summary(req: SummaryReq):
    fpath = save_session_summary(req.project_id, req.session_id, req.agent_id, req.summary_text)
    return {"saved_file": str(fpath)}

# ── Session CRUD ──────────────────────────────

class SessionCreateReq(BaseModel):
    project_id: str
    agent_id: str
    title: str = "新会话"

class SessionRenameReq(BaseModel):
    title: str

@app.post("/api/sessions")
async def api_create_session(req: SessionCreateReq):
    sid = create_session(req.project_id, req.agent_id, req.title)
    return {"session_id": sid}

@app.get("/api/sessions")
async def api_list_sessions(project_id: str, agent_id: str):
    return list_sessions(project_id, agent_id)

@app.put("/api/sessions/{session_id}")
async def api_rename_session(session_id: str, req: SessionRenameReq, project_id: str):
    ok = rename_session(project_id, session_id, req.title)
    if not ok:
        raise HTTPException(status_code=404, detail="会话不存在")
    return {"renamed": True}

@app.delete("/api/sessions/{session_id}")
async def api_delete_session(session_id: str, project_id: str):
    # TS-114（3.25）+ TS-115（3.19② 维度 B/C）：删除前 stop 关联 running 委派任务。
    # TS-115 增强：stop 后等 1s 让执行循环检测到取消标志（不再发起新的模型调用），
    # 并清理该会话挂起的未响应授权请求（_auth_pending，防内存泄漏）。
    stopped = 0
    try:
        for t in list_agent_tasks(project_id, limit=200):
            if t.get("status") in ("queued", "running") and (
                    t.get("session_id") == session_id or t.get("parent_session_id") == session_id):
                request_delegation_cancel(t["id"])
                stopped += 1
        if stopped:
            await asyncio.sleep(1)  # 等执行循环走到下一检查点（发起新模型调用之前）
    except Exception:
        pass  # stop 失败不影响删除
    ok = delete_session(project_id, session_id)
    if not ok:
        raise HTTPException(status_code=404, detail="会话不存在")
    return {"deleted": True, "stopped_tasks": stopped}

@app.get("/api/sessions/{session_id}/messages")
async def api_load_session_messages(session_id: str, project_id: str):
    msgs = load_messages(project_id, session_id)
    # B06 收尾：tool_steps(下划线) → toolSteps(前端驼峰)；旧数据缺 status 时按 ok 归一，
    # 让历史消息的工具折叠条可正常回放（绿✅/红❌），且字段结构与流式时一致
    for m in msgs:
        if m.get("tool_steps"):
            for st in m["tool_steps"]:
                if not st.get("status"):
                    st["status"] = "ok" if st.get("ok") else "error"
            m["toolSteps"] = m["tool_steps"]
    return msgs


# ── M1-1 越界授权响应端点（2026-08-28 问题2）──────────────────────
class AuthRespondReq(BaseModel):
    request_id: str
    allowed: bool

@app.post("/api/auth/respond")
async def api_auth_respond(req: AuthRespondReq):
    """前端回传用户对越界操作的授权决定。"""
    entry = _auth_pending.get(req.request_id)
    if entry is None:
        raise HTTPException(status_code=404, detail="授权请求不存在或已过期")
    entry["result"] = req.allowed
    entry["event"].set()
    return {"ok": True}


# ── Agent update ─────────────────────────────

class AgentUpdateReq(BaseModel):
    name: str | None = None
    model_name: str | None = None
    system_prompt: str | None = None

@app.put("/api/agents/{project_id}/{agent_id}")
async def api_update_agent(project_id: str, agent_id: str, req: AgentUpdateReq):
    ok = update_agent_config(project_id, agent_id, **req.model_dump(exclude_none=True))
    if not ok:
        raise HTTPException(status_code=404, detail="Agent 不存在")
    return {"updated": True}

# ── Project rename ───────────────────────────

class ProjectRenameReq(BaseModel):
    name: str

@app.put("/api/projects/{project_id}")
async def api_rename_project(project_id: str, req: ProjectRenameReq):
    ok = rename_project(project_id, req.name)
    if not ok:
        raise HTTPException(status_code=404, detail="项目不存在")
    return {"renamed": True}


# ─────────────────────────────────────────────
# 插件系统 API
# ─────────────────────────────────────────────
from sidecar.plugin_loader.loader import PluginLoader

class PluginInstallReq(BaseModel):
    repo_url: str

class PluginHookReq(BaseModel):
    hook_name: str
    agent_context: dict[str, Any] = {}
    plugin_name: str | None = None

loader = PluginLoader()

@app.post("/api/plugins/install")
async def api_plugin_install(req: PluginInstallReq):
    try:
        result = await loader.install_from_github(req.repo_url)
        return {"success": True, **result}
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))

@app.get("/api/plugins")
async def api_plugin_list():
    plugins = loader.list_installed()
    # 补充 entry_point 和 hooks 信息
    for p in plugins:
        if "entry_point" not in p:
            p["entry_point"] = "plugin.py"
        if "hooks" not in p:
            p["hooks"] = []
    return plugins

@app.delete("/api/plugins/{name}")
async def api_plugin_uninstall(name: str):
    ok = loader.uninstall(name)
    if not ok:
        raise HTTPException(status_code=404, detail=f"插件 {name} 未安装")
    return {"deleted": True}

@app.post("/api/plugins/{name}/toggle")
async def api_plugin_toggle(name: str):
    """checkpoint-047：插件逐项启用开关（关闭时该插件的 hook 不再执行）。"""
    new_state = loader.toggle_enabled(name)
    if new_state is None:
        raise HTTPException(status_code=400, detail="切换失败（插件不存在）")
    return {"ok": True, "enabled": new_state}

@app.post("/api/plugins/{name}/hooks/{hook_name}")
async def api_plugin_hook(name: str, hook_name: str, req: PluginHookReq | None = None):
    # checkpoint-047：逐项开关——被禁用的插件拒绝执行
    if not loader.is_enabled(name):
        raise HTTPException(status_code=403,
                            detail=f"插件「{name}」已被禁用（设置 → 插件与技能），无法调用")
    ctx = req.agent_context if req else {}
    result = await loader.execute_hook(hook_name, ctx, plugin_name=name)
    if result is None:
        raise HTTPException(status_code=404, detail=f"插件 {name} 没有 hook: {hook_name}")
    return result

@app.get("/api/plugins/{name}/hooks")
async def api_plugin_hooks(name: str):
    """返回某个插件的所有可用 hook（从 manifest 读取）"""
    plugins = loader.list_installed()
    for p in plugins:
        if p.get("name") == name:
            return {"name": name, "hooks": p.get("hooks", []), "entry_point": p.get("entry_point", "plugin.py")}
    raise HTTPException(status_code=404, detail=f"插件 {name} 未安装")


class ChatStreamReq(ChatReq):
    """M1-2：ChatReq + sandbox_root（可选；缺省从 agent_id 查 DB working_dir）。"""
    # M5（TS-111）：前端断线重连时置 true —— user 消息首次请求已落库，重连不重复保存
    skip_user_persist: bool = False
    sandbox_root: str | None = None


# checkpoint-048：聊天上传附件解析端点（复用圆桌内置解析器，限制与圆桌一致）。
class ChatAttachmentParseReq(BaseModel):
    name: str
    content_base64: str

@app.post("/api/attachments/parse")
async def api_parse_chat_attachment(req: ChatAttachmentParseReq):
    """解析聊天上传的附件为文本（PDF/Word/Excel/CSV/文本族）。
    checkpoint-067 R-2（完整优先）：律所分析要求内容完整，聊天附件使用大幅放宽的
    专用上限（单文件 10MB / 文本 20 万字符），不再按圆桌 3000 字截断。
    无法解析 → text=null，前端仅作为文件名标注。"""
    import base64 as _b64
    try:
        raw = _b64.b64decode(req.content_base64 or "")
    except Exception:
        raise HTTPException(status_code=400, detail=f"附件 {req.name} 编码非法")
    if len(raw) > _CHAT_ATT_MAX_BYTES:
        raise HTTPException(status_code=400, detail=f"附件 {req.name} 超过 10MB 限制")
    from sidecar.attachments.parser import parse_attachment
    text, kind = parse_attachment(req.name, raw)
    truncated = False
    if text is not None and len(text) > _CHAT_ATT_MAX_CHARS_EACH:
        text = text[:_CHAT_ATT_MAX_CHARS_EACH]
        truncated = True
    return {"name": req.name, "kind": kind, "text": text, "truncated": truncated}


def _sse_format(event: str, data: dict) -> str:
    return f"event: {event}\ndata: {_json.dumps(data, ensure_ascii=False)}\n\n"


def compute_heartbeat_interval(event_times: list, base: float,
                               now: float | None = None) -> float:
    """M5（TS-111）：心跳动态间隔公式（模块级，可单测）。

    间隔 = max(base, 近 10 次事件间隔均值 × 1.5)。
    事件少于 2 个（无法算间隔）→ 返回 base。
    event_times：事件到达时间戳列表（升序）；now 缺省取最后一个时间戳。
    """
    if len(event_times) < 2:
        return base
    ts = event_times[-10:]
    deltas = [ts[i + 1] - ts[i] for i in range(len(ts) - 1)]
    avg = sum(deltas) / len(deltas)
    if avg <= 0:
        return base
    return max(base, avg * 1.5)


def _resolve_sandbox_root(req: ChatStreamReq) -> str | None:
    if req.sandbox_root:
        return req.sandbox_root
    # checkpoint-058 / checkpoint-061：独立 Agent 命名空间（ia- 前缀）。
    # 061 加固：目录一律从已注册的 agent_id 推导（不信任 project_id 后缀），
    # 既堵路径穿越，也让"已删除的独立 Agent"无法复活（不存在 → 返回 None → 422）。
    if req.project_id and req.project_id.startswith(INDEP_NS_PREFIX):
        if get_independent_agent(req.agent_id or "") is None:
            return None
        sb = independent_agent_dir(req.agent_id) / "sandbox"
        sb.mkdir(parents=True, exist_ok=True)
        return str(sb)
    if req.project_id and req.agent_id:
        agent = get_agent_config(req.project_id, req.agent_id)
        if agent:
            # working_dir 存于 projects 表；agent 归属项目，取该项目 working_dir
            for proj in list_projects():
                if proj["id"] == req.project_id:
                    return proj.get("working_dir")
    return None


# ── M1-2 补漏（需求 3.11）：每步状态落盘 work/state.json ──────────────
# 契约：stream 端点每收到一个推进性事件（tool_call/tool_result/state/done/error）
# 都把当前执行快照写入 <data_root>/projects/<pid>/work/state.json（原子写：先 .tmp 再 rename）。
# 用途：中断（客户端断开/报错/熔断）后，状态文件保留最后一步的完整现场，
# 配合 B06 的 DB 截断落盘，实现"中断可查、可续"（前端可凭 status != done 判断中断态）。
def _write_state_file(project_id: str, state: dict) -> None:
    """把执行状态快照写入项目 work/ 目录。失败静默（不阻塞流式回复主链路）。"""
    if not project_id:
        return
    try:
        from sidecar.storage import store as _store_mod
        work_dir = _store_mod.PROJECTS_ROOT / project_id / "work"
        work_dir.mkdir(parents=True, exist_ok=True)
        target = work_dir / "state.json"
        tmp = work_dir / "state.json.tmp"
        tmp.write_text(_json.dumps(state, ensure_ascii=False, indent=2), encoding="utf-8")
        _os.replace(str(tmp), str(target))  # 原子替换，避免半截文件
    except Exception:
        pass  # 状态落盘失败不影响流式回复（DB 截断落盘是第二保险）


@app.post("/api/ollama/chat/stream")
async def api_ollama_chat_stream(req: ChatStreamReq):
    """M1-2 SSE 流式 tool-loop 端点。旧 /api/ollama/chat 保留（M1-4 前端切换后下线）。"""
    if not req.messages:
        raise HTTPException(status_code=422, detail="messages 不能为空")
    sandbox_root = _resolve_sandbox_root(req)
    if not sandbox_root:
        raise HTTPException(status_code=422,
                            detail="sandbox_root 缺失：请传 sandbox_root 或 project_id+agent_id")
    agent = get_agent_config(req.project_id, req.agent_id) if (req.project_id and req.agent_id) else None
    net_switch = str(get_config().get("network_switch", "off"))
    # TS-110 M4：知识/记忆/技能注入（加载失败一律降级为空，不阻塞对话）
    _knowledge_text = ""
    _memory_text = ""
    _prohibitions: list = []
    _skills_list_text = ""
    try:
        from sidecar.knowledge import build_knowledge_text, build_memory_injection
        _knowledge_text = build_knowledge_text(req.project_id) if req.project_id else ""
        _memory_text, _prohibitions = build_memory_injection(req.project_id) if req.project_id else build_memory_injection()
    except Exception:
        pass
    try:
        # 技能清单只含启用项（逐项开关生效：禁用技能不注入、不可用，见 checkpoint-047）
        from sidecar.skills_mgr import build_skills_list_text
        _skills_list_text = build_skills_list_text()
    except Exception:
        pass
    # TS-107 M3-1：委派上下文（仅主会话：project+agent+session 齐备时可委派；
    # connector 置 None → 委派执行器走连接器单例，与主流共用连接池）
    _pid_e = req.project_id or ""
    _aid_e = req.agent_id or ""
    _sid_e = req.session_id
    _can_delegate = bool(_pid_e and _aid_e and _sid_e)
    delegation_ctx = ({"project_id": _pid_e, "agent_id": _aid_e, "session_id": _sid_e,
                       "connector": None, "model": req.model} if _can_delegate else None)
    sys_prompt = build_system_prompt(
        agent_name=agent.get("name") if agent else "SubAgent",
        agent_role=agent.get("role") if agent else None,
        sandbox_root=sandbox_root,
        network_switch=net_switch,
        system_prompt=(agent or {}).get("system_prompt"),
        can_delegate=_can_delegate,
        knowledge_text=_knowledge_text,
        memory_text=_memory_text,
        prohibitions=_prohibitions,
        skills_list_text=_skills_list_text,
    )
    msgs = [{"role": "system", "content": sys_prompt}] + list(req.messages)

    # M5（TS-111）：SSE 心跳动态间隔。
    # 间隔 = max(配置 heartbeat_interval, 近 10 次事件间隔均值 × 1.5)；事件稀疏时回退配置值。
    # 协议不变（`: ping` 注释行，客户端忽略）。公式抽为模块级函数便于单测。
    try:
        _HB_BASE = max(5.0, min(float(get_config().get("heartbeat_interval", 15.0)), 60.0))
    except Exception:
        _HB_BASE = 15.0
    _event_times: list[float] = []  # 近 ≤10 个事件到达时间戳（环形）

    def _heartbeat_interval() -> float:
        return compute_heartbeat_interval(_event_times, _HB_BASE)

    # B06（TS-101）：stream 端点持久化。请求入口先落 user 消息，
    # 流内累积 assistant 文本/工具步骤，done 或中断时落盘 assistant 消息。
    _pid = req.project_id or ""
    _sid = req.session_id
    _aid = req.agent_id or ""
    if _pid and _sid and not req.skip_user_persist:
        _last = req.messages[-1]
        _user_content = _last.get("content", "") if isinstance(_last, dict) else str(_last)
        save_message(_pid, _sid, _aid, "user", _user_content, images=req.images)

    _state: dict = {"text": "", "steps": [], "saved": False, "prompt_eval_count": None}

    def _persist_assistant(truncated: bool = False):
        if not (_pid and _sid) or _state["saved"]:
            return
        _state["saved"] = True
        try:
            save_message(_pid, _sid, _aid, "assistant", _state["text"],
                         model_used=req.model, tool_steps=_state["steps"] or None,
                         truncated=truncated,
                         prompt_eval_count=_state.get("prompt_eval_count"))
        except Exception:
            pass  # 持久化失败不阻塞流（前端仍持有事件内容）

    # M1-2 补漏（需求 3.11）：执行状态快照。每步（工具调用/结果/轮次/终态）刷新到
    # work/state.json，中断后文件保留最后现场（status != done 即中断态，可据此续跑）。
    _exec_state: dict = {
        "session_id": _sid, "agent_id": _aid, "model": req.model,
        "status": "running", "step": 0, "max_rounds": 5, "tokens_used": 0,
        "started_at": datetime.now().isoformat(timespec="seconds"),
        "updated_at": datetime.now().isoformat(timespec="seconds"),
        "text_chars": 0, "steps": [],
    }

    def _flush_exec_state(status: str | None = None, detail: str | None = None):
        if status is not None:
            _exec_state["status"] = status
        if detail is not None:
            _exec_state["detail"] = detail
        _exec_state["updated_at"] = datetime.now().isoformat(timespec="seconds")
        _exec_state["text_chars"] = len(_state["text"])
        _exec_state["steps"] = _state["steps"]
        _write_state_file(_pid, _exec_state)

    _flush_exec_state()  # 流开始即写初始状态（running）

    async def gen():
        # 2026-08-28 问题1：轮次上限改为可配置（默认 200），不再硬编码 5
        _max_rounds = int(get_config().get("max_tool_rounds", 200))
        # M6（TS-112）工具能力降级：后端不支持工具调用 → 不传工具 + 提示词声明（确定性降级）
        _caps = get_ollama_connector().capabilities()
        _tools_enabled = bool(_caps.get("tools", True))
        if not _tools_enabled:
            msgs.append({"role": "system",
                         "content": "当前推理后端不支持工具调用，本轮仅直接对话，不可读写文件或搜索。"})
        # M2：拉取上下文上限（失败不阻塞，传 0 则跳过预警）
        import httpx as _httpx
        _ctx_limit = 0
        try:
            _cfg = get_config()
            _base = _cfg.get("ollama_base_url", "").rstrip("/")
            async with _httpx.AsyncClient(timeout=_httpx.Timeout(5.0, connect=5.0), trust_env=False) as _c:
                _r = await _c.get(f"{_base}/api/ps")
                for _m in _r.json().get("models", []):
                    _n = _m.get("name", "")
                    if _n == req.model or _n.startswith(req.model + ":") or _n.startswith(req.model):
                        _ctx_limit = int(_m.get("context_length") or _m.get("details", {}).get("context_length") or 0)
                        break
            if not _ctx_limit:
                _ctx_limit = 262144  # 协议常量：qwen 系默认上限
        except Exception:
            _ctx_limit = 0
        aiter = run_tool_loop(req.model, msgs,
                              tools_spec(with_delegation=True) if _tools_enabled else [],
                              sandbox_root,
                              authorizer=_sse_authorizer, max_rounds=_max_rounds,
                              context_limit=_ctx_limit,
                              delegation_ctx=delegation_ctx if _tools_enabled else None,
                              first_round_images=req.images).__aiter__()
        # M2 打回修复（2026-08-29）：compact_auto 服务端闭环。
        # loop 发 compact_auto 只是"通知该压缩了"，真正压缩在此处执行。
        # 同一次请求内最多自动压缩 1 次（防 compact_session 成功但 prompt_eval 仍高导致二次触发死循环）。
        _auto_compact_done = False
        _auto_compact_failed = False
        next_task = None
        try:
            while True:
                if next_task is None:
                    next_task = asyncio.ensure_future(aiter.__anext__())
                timer = asyncio.ensure_future(asyncio.sleep(_heartbeat_interval()))
                # M1-1 越界授权（2026-08-28）：同时监听待处理的授权请求，
                # 有新请求时立即发出 auth_request SSE 事件给前端弹窗
                wait_set = {next_task, timer}
                auth_watchers: dict[str, asyncio.Task] = {}
                for rid, entry in list(_auth_pending.items()):
                    if not entry["event"].is_set():
                        auth_watchers[rid] = asyncio.ensure_future(entry["event"].wait())
                        wait_set.add(auth_watchers[rid])
                done, _pending = await asyncio.wait(
                    wait_set, return_when=asyncio.FIRST_COMPLETED)
                timer.cancel()
                # 检查是否有授权请求被触发（前端已响应或超时）
                for rid, watcher in auth_watchers.items():
                    if watcher in done:
                        pass  # Event 已 set，_sse_authorizer 会自行返回
                    else:
                        watcher.cancel()
                # 检查是否有新的待处理授权请求需要发 SSE 事件
                for rid, entry in list(_auth_pending.items()):
                    if not entry.get("sent") and not entry["event"].is_set():
                        entry["sent"] = True
                        yield _sse_format("auth_request", {
                            "request_id": rid,
                            "tool_name": entry["tool"],
                            "target_path": entry["path"],
                            "action": entry["action"],
                        })
                if next_task in done:
                    try:
                        ev = next_task.result()
                    except StopAsyncIteration:
                        # 生成器耗尽：若未收到 done（loop 异常提前结束），状态兜底标 error，
                        # 避免 state.json 永远停在 running
                        if _exec_state.get("status") == "running":
                            _flush_exec_state(status="error", detail="流异常结束（未收到 done 事件）")
                        break
                    next_task = None
                    # M5：记录事件到达时间戳（心跳动态间隔数据源；环形 ≤10）
                    _event_times.append(asyncio.get_event_loop().time())
                    if len(_event_times) > 10:
                        _event_times.pop(0)
                    _e, _d = ev["event"], ev["data"]
                    if _e == "token":
                        _state["text"] += _d.get("delta", "")
                    elif _e == "tool_call":
                        _state["steps"].append({
                            "id": _d.get("id", ""),
                            "name": _d.get("name", ""), "args": _d.get("args", {}),
                            "status": "running",
                        })
                        _flush_exec_state()  # 每步推进 → 落盘
                    elif _e == "tool_result":
                        # B06 收尾：补 status（前端 ToolStepBar 靠它渲染✅/❌），
                        # 并保留对应 tool_call 的 args，避免替换时丢失
                        entry = {"name": _d.get("name", ""), "ok": bool(_d.get("ok", True)),
                                 "error": _d.get("error"), "summary": _d.get("summary"),
                                 "status": "ok" if _d.get("ok") else "error"}
                        if _state["steps"] and _state["steps"][-1].get("name") == entry["name"] \
                                and _state["steps"][-1].get("status") == "running":
                            entry["id"] = _state["steps"][-1].get("id", "")
                            entry["args"] = _state["steps"][-1].get("args")
                            _state["steps"][-1] = entry
                        else:
                            _state["steps"].append(entry)
                        _flush_exec_state()  # 每步推进 → 落盘
                    elif _e == "compact_auto":
                        # M2 自动压缩闭环：loop 通知"该压缩了" → 服务端真正执行压缩。
                        if _auto_compact_done or _auto_compact_failed:
                            # 第二次触发：不再自动压缩，降级为 compact_required 让用户三选一
                            yield _sse_format("compact_required", _d)
                            break
                        _auto_compact_done = True
                        try:
                            from sidecar.compactor import compact_session as _compact
                            _cr = await _compact(_pid, _sid, model=req.model)
                            if not _cr.get("ok"):
                                raise RuntimeError(_cr.get("error", "压缩失败"))
                        except Exception as _cex:
                            # 压缩失败 → 不能装没事发生：降级 compact_required，前端三选一
                            _auto_compact_failed = True
                            yield _sse_format("compact_required", _d)
                            break
                        # 压缩成功 → 继续消费 loop 后续事件（不中断）
                    elif _e == "compact_required":
                        # loop 已暂停等待用户决策（未勾自动压缩）→ 转发给前端弹警告条
                        _flush_exec_state(status="paused", detail="上下文接近上限，等待用户处理")
                    elif _e == "state":
                        # tool loop 的轮次/累计 token（M2 数据源，此处顺带进状态文件）
                        _exec_state["step"] = _d.get("step", _exec_state["step"])
                        _exec_state["max_rounds"] = _d.get("max", _exec_state["max_rounds"])
                        _exec_state["tokens_used"] = _d.get("tokens_used", _exec_state["tokens_used"])
                        # H17 问题3：记录最新 prompt_eval_count，落库供历史会话恢复指示器
                        if isinstance(_d.get("prompt_eval_count"), int):
                            _state["prompt_eval_count"] = _d["prompt_eval_count"]
                        _flush_exec_state()
                    elif _e == "error":
                        # tool loop 的熔断/超时/空回复 → error 事件，状态文件记终态
                        _flush_exec_state(status="error", detail=str(_d.get("detail", "")))
                    elif _e == "done":
                        if isinstance(_d.get("content"), str):
                            _state["text"] = _d["content"]
                        _persist_assistant(truncated=False)
                        _flush_exec_state(status="done")  # 终态落盘
                    yield _sse_format(_e, _d)
                elif timer in done:
                    yield ": ping\n\n"  # 空闲心跳，客户端忽略
        except (NetworkGuardError, OllamaAPIError) as e:
            _persist_assistant(truncated=True)
            _flush_exec_state(status="error", detail=str(e.message))
            yield _sse_format("error", {"detail": e.message})
        except httpx.HTTPError:
            _persist_assistant(truncated=True)
            _flush_exec_state(status="error", detail="与模型的连接中断")
            # 网络中断（非超时，超时已在 connector 兜底）→ 转 error 事件后结束
            yield _sse_format("error", {"detail": "与模型的连接中断，已停止。已完成部分见上方事件。"})
        except asyncio.CancelledError:
            # B06：客户端断开 → 已生成部分落盘（truncated 标记）后静默结束。
            # 注意：取消路径下不允许 await，落盘用 sqlite 同步连接（本函数内为同步调用）。
            _persist_assistant(truncated=True)
            _flush_exec_state(status="interrupted", detail="客户端断开")
            raise
        except Exception as e:  # 最终安全网：任何异常都转 error 事件，不裸抛堆栈
            _persist_assistant(truncated=True)
            _flush_exec_state(status="error", detail=f"内部错误: {e}")
            yield _sse_format("error", {"detail": f"内部错误: {e}"})
        finally:
            if next_task is not None and not next_task.done():
                next_task.cancel()
                # TS-103 B04：cancel 后必须 await 吃掉取消结果，确保底层流/连接真正释放，
                # 否则协程残留直到 GC（高频断开时 "Task was destroyed but it is pending" 刷屏）
                try:
                    await next_task
                except BaseException:
                    pass  # 清理路径：取消/业务异常一律吞掉
            # M3 前置安全加固 M1：清理未响应的授权请求，防内存泄漏。
            # 客户端断开后 _auth_pending 若残留，_sse_authorizer 的 await evt.wait()
            # 会一直挂着；这里 pop 出来并 set() 唤醒等待者（拿到 result=False 安全拒绝）。
            for _rid in list(_auth_pending.keys()):
                _entry = _auth_pending.pop(_rid, None)
                if _entry is not None and not _entry["event"].is_set():
                    _entry["result"] = False
                    _entry["event"].set()
            _persist_assistant(truncated=True)
            # M1-2 补漏：任何未走到 done/error 终态的结束（客户端断开抛 CancelledError、
            # 迭代器关闭抛 GeneratorExit 等）→ 统一标 interrupted，防 state.json 停在 running
            if _exec_state.get("status") == "running":
                _flush_exec_state(status="interrupted", detail="流未正常结束（客户端断开或迭代器关闭）")

    return StreamingResponse(gen(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})


@app.get("/api/projects/{project_id}/state")
async def api_get_project_state(project_id: str):
    """M1-2 补漏：读取最近一次执行的 work/state.json（中断可查）。

    返回字段含 status：running（进行中）/ done（完成）/ error / interrupted（客户端断开）。
    前端/用户可凭 status != done 判断上次执行是否被中断，并据 steps 了解已完成部分。
    """
    try:
        from sidecar.storage import store as _store_mod
        f = _store_mod.PROJECTS_ROOT / project_id / "work" / "state.json"
        if not f.exists():
            return {"exists": False}
        return {"exists": True, "state": _json.loads(f.read_text(encoding="utf-8"))}
    except Exception:
        return {"exists": False}


@app.get("/api/projects/{project_id}/tasks")
async def api_list_agent_tasks(project_id: str, limit: int = 50):
    """TS-107 M3-1：委派任务列表（只读；审核与第二段任务状态面板复用）。
    按创建时间倒序，最多 limit 条（1-200）。"""
    try:
        lim = max(1, min(int(limit), 200))
    except (TypeError, ValueError):
        lim = 50
    return list_agent_tasks(project_id, limit=lim)


@app.post("/api/projects/{project_id}/tasks/{task_id}/retry")
async def api_retry_agent_task(project_id: str, task_id: str):
    """TS-108 M3-2 决策 5：一键重试失败任务。

    仅 failed 任务可重试；用原目标/任务书/交卷标准重新执行，生成新任务记录，
    旧记录保留。同步等待执行完成后返回 {"new_task_id", "result"}。
    重试走 HTTP（无 SSE 通道）→ authorizer=None（敏感操作按默认拒绝，安全侧保守）。
    """
    old = get_agent_task(project_id, task_id)
    if not old:
        raise HTTPException(status_code=404, detail="任务不存在")
    if old.get("status") != "failed":
        raise HTTPException(status_code=400, detail=f"仅失败任务可重试（当前状态：{old.get('status')}）")
    target = get_agent_config(project_id, old["target_agent_id"])
    if not target:
        raise HTTPException(status_code=400, detail="目标 Agent 已不存在，无法重试")
    sandbox_root = None
    # checkpoint-058：独立 Agent 命名空间 → 专属沙盒目录
    if project_id.startswith(INDEP_NS_PREFIX):
        from sidecar.storage.store import PROJECTS_ROOT as _PROOT
        _sb = _PROOT / project_id / "sandbox"
        _sb.mkdir(parents=True, exist_ok=True)
        sandbox_root = str(_sb)
    else:
        for proj in list_projects():
            if proj["id"] == project_id:
                sandbox_root = proj.get("working_dir")
                break
    if not sandbox_root:
        raise HTTPException(status_code=400, detail="项目工作目录缺失，无法重试")
    _max_rounds = int(get_config().get("max_tool_rounds", 200))
    result = await run_delegated_task(
        project_id, old["parent_agent_id"], old["parent_session_id"], target,
        old["task"], old["expect"], sandbox_root=sandbox_root,
        authorizer=None, max_rounds=_max_rounds, connector=None)
    return {"new_task_id": result.get("task_id"), "result": result}


@app.post("/api/projects/{project_id}/tasks/{task_id}/stop")
async def api_stop_delegation_task(project_id: str, task_id: str):
    """TS-114（3.25）：停止进行中的委派任务（同圆桌 /stop 机制）。
    置取消标志，执行循环在下一个检查点（当前轮模型调用完成后）中止，
    任务标 failed（fail_reason 含"已停止"），不再发起新的模型调用。立即返回。"""
    task = get_agent_task(project_id, task_id)
    if not task:
        raise HTTPException(status_code=404, detail="任务不存在")
    if task["status"] in ("done", "failed"):
        raise HTTPException(status_code=400, detail=f"任务已结束（{task['status']}），无需停止")
    request_delegation_cancel(task_id)
    return {"ok": True, "detail": "已请求停止，将在当前步骤完成后中止"}



# ── M3-3（TS-109）：圆桌讨论端点 ─────────────────────

class RoundtableAttachment(BaseModel):
    name: str
    content_base64: str = ""

class RoundtableCreateReq(BaseModel):
    topic: str
    agent_ids: list[str]
    moderator: str = "user"          # 'user' | 'ai'
    moderator_agent_id: str | None = None
    max_rounds: int = 5
    attachments: list[RoundtableAttachment] = []   # TS-109 增强（H18-3）：议题背景材料

# 附件限制（H18-3）——圆桌（保持原值，圆桌纪要为摘要场景）
_RT_ATT_MAX_COUNT = 5
_RT_ATT_MAX_BYTES = 2 * 1024 * 1024   # 单文件 2MB
_RT_ATT_MAX_CHARS_EACH = 3000          # 单文件注入纪要的字符上限
_RT_ATT_MAX_CHARS_TOTAL = 12000        # 全部附件注入纪要的字符总量上限

# checkpoint-067 R-2（用户拍板"完整优先，宁慢勿断"）——聊天附件专用上限。
# 律所分析客户材料要求内容完整，不得截断，故大幅放宽（远高于圆桌摘要场景）：
# 单文件 10MB / 单文件文本 20 万字符 / 无总量截断。保留安全上限仅为防止病态超大输入撑爆模型上下文。
_CHAT_ATT_MAX_BYTES = 10 * 1024 * 1024   # 单文件 10MB
_CHAT_ATT_MAX_CHARS_EACH = 200000        # 单文件注入文本字符上限（正常法律文档不会触及）

@app.post("/api/projects/{project_id}/roundtables")
async def api_create_roundtable(project_id: str, req: RoundtableCreateReq):
    """创建圆桌并执行第一轮（决策 6/7）。弱模型单轮耗时可控，同步等待返回。
    附件（H18-3 / M7 TS-113）：原始文件落盘到项目 work/roundtables/attachments/，
    内置解析器（PDF/Word/Excel/CSV/文本；图片可选视觉识别）提取文本注入初始纪要；
    无法解析的文件仅标注不注入。"""
    # ── 附件预处理 ──
    att_metas: list[dict] = []
    att_files: list[tuple[str, bytes]] = []
    if req.attachments:
        if len(req.attachments) > _RT_ATT_MAX_COUNT:
            raise HTTPException(status_code=400, detail=f"附件最多 {_RT_ATT_MAX_COUNT} 个")
        import base64 as _b64
        # M7（TS-113）：图片附件可选走视觉模型识别（配置开关）
        _use_vision = bool(get_config().get("vision_parse_attachments", False))

        async def _vision_parse(img_raw: bytes, img_name: str) -> str:
            """图片附件视觉识别：失败/不支持 → 返回空串（调用方标注）。"""
            try:
                import base64 as _b64v
                _ext = img_name.rsplit(".", 1)[-1].lower() if "." in img_name else "png"
                data_uri = f"data:image/{_ext};base64," + _b64v.b64encode(img_raw).decode("ascii")
                conn = get_ollama_connector()
                model = str(get_config().get("default_model", "qwen3.8"))
                result = await conn.chat(
                    model,
                    [{"role": "user", "content": "请描述这张图片的关键内容，供讨论参考。"}],
                    images=[data_uri])
                return result or ""
            except Exception:
                return ""

        from sidecar.attachments.parser import parse_attachment
        for att in req.attachments:
            try:
                raw = _b64.b64decode(att.content_base64 or "")
            except Exception:
                raise HTTPException(status_code=400, detail=f"附件 {att.name} 编码非法")
            if len(raw) > _RT_ATT_MAX_BYTES:
                raise HTTPException(status_code=400,
                                    detail=f"附件 {att.name} 超过 2MB 限制")
            att_files.append((att.name, raw))
            # M7（TS-113）：内置解析器提取文本（解析失败→标注不注入）
            text, kind = parse_attachment(att.name, raw)
            if text is None and kind == "image" and _use_vision:
                text = await _vision_parse(raw, att.name) or None
            truncated = False
            if text is not None and len(text) > _RT_ATT_MAX_CHARS_EACH:
                text = text[:_RT_ATT_MAX_CHARS_EACH]
                truncated = True
            att_metas.append({"name": att.name, "size": len(raw),
                              "is_text": text is not None, "text": text,
                              "kind": kind, "truncated": truncated})
        total_chars = sum(len(m["text"]) for m in att_metas if m.get("text"))
        if total_chars > _RT_ATT_MAX_CHARS_TOTAL:
            raise HTTPException(
                status_code=400,
                detail=f"附件文本总量超过 {_RT_ATT_MAX_CHARS_TOTAL} 字，请精简材料")
    try:
        rt = await rt_mod.create_and_start(
            project_id, req.topic, req.agent_ids, req.moderator,
            req.moderator_agent_id, req.max_rounds, attachments=att_metas or None)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    # ── 附件原始文件落盘（创建成功后；失败仅提示不影响讨论）──
    if att_files:
        try:
            from sidecar.storage.store import PROJECTS_ROOT as _PROOT
            _att_dir = _PROOT / project_id / "work" / "roundtables" / "attachments" / rt["id"]
            _att_dir.mkdir(parents=True, exist_ok=True)
            for meta, (name, raw) in zip(att_metas, att_files):
                safe = "".join(c for c in name if c not in r'\/:*?"<>|').strip() or "attachment"
                fp = _att_dir / safe
                fp.write_bytes(raw)
                meta["saved_path"] = str(fp)
            # 落盘路径写回 attachments 列
            import json as _json_local
            from sidecar.storage import store as _st
            # checkpoint-050 查虫修复：改用统一写上下文管理器（防连接泄漏）
            with _st._write_conn(project_id) as _c:
                _c.execute("UPDATE roundtables SET attachments = ? WHERE id = ?",
                           (_json_local.dumps(att_metas, ensure_ascii=False), rt["id"]))
        except Exception:
            pass  # 落盘失败不影响讨论本身
    return rt

@app.get("/api/projects/{project_id}/roundtables")
async def api_list_roundtables(project_id: str, limit: int = 20):
    try:
        lim = max(1, min(int(limit), 100))
    except (TypeError, ValueError):
        lim = 20
    return list_roundtables(project_id, limit=lim)

# TS-121（0.3.1 补遗2）：工作组 JSON 导出（项目+agents+会话+任务队列+圆桌）
@app.post("/api/projects/{project_id}/export-workgroup")
async def api_export_workgroup(project_id: str):
    from sidecar.exporter import export_workgroup_json
    try:
        result = export_workgroup_json(project_id)
    except ValueError as e:
        raise HTTPException(status_code=404, detail=str(e))
    return {"ok": True, "path": result["path"], "name": result["name"]}

@app.get("/api/roundtables/{rt_id}")
async def api_get_roundtable(rt_id: str, project_id: str):
    rt = get_roundtable(project_id, rt_id)
    if not rt:
        raise HTTPException(status_code=404, detail="圆桌不存在")
    rt["messages"] = list_roundtable_messages(project_id, rt_id)
    # 附件元数据不回传正文（可能很大），只回传名称/大小/类型标记
    for att in rt.get("attachments") or []:
        att.pop("text", None)
    return rt

@app.delete("/api/roundtables/{rt_id}")
async def api_delete_roundtable(rt_id: str, project_id: str):
    """删除圆桌及全部发言（H18-1）。讨论进行中禁止删除。"""
    rt = get_roundtable(project_id, rt_id)
    if not rt:
        raise HTTPException(status_code=404, detail="圆桌不存在")
    if rt["status"] == "running":
        raise HTTPException(status_code=400, detail="讨论进行中，不能删除")
    from sidecar.storage.store import delete_roundtable as _del_rt
    deleted = _del_rt(project_id, rt_id)
    # 清理附件文件（尽力而为）
    for att in rt.get("attachments") or []:
        p = att.get("saved_path")
        if p:
            try:
                from pathlib import Path as _P
                _f = _P(p)
                if _f.exists():
                    _f.unlink()
            except Exception:
                pass
    return {"deleted": deleted}

@app.post("/api/roundtables/{rt_id}/export")
async def api_export_roundtable(rt_id: str, project_id: str):
    """导出讨论记录为 Markdown 文件（H18-2 保存模块）。返回 {path, name}。"""
    try:
        return rt_mod.export_roundtable_md(project_id, rt_id)
    except ValueError as e:
        raise HTTPException(status_code=404, detail=str(e))

@app.post("/api/roundtables/{rt_id}/continue")
async def api_continue_roundtable(rt_id: str, project_id: str):
    """用户点继续 → 下一轮。仅 waiting_user 允许（决策 6：用户主持/到达上限）。"""
    rt = get_roundtable(project_id, rt_id)
    if not rt:
        raise HTTPException(status_code=404, detail="圆桌不存在")
    if rt["status"] != "waiting_user":
        raise HTTPException(status_code=400, detail=f"当前状态（{rt['status']}）不允许继续")
    try:
        return await rt_mod.continue_roundtable(project_id, rt_id)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))

@app.post("/api/roundtables/{rt_id}/finish")
async def api_finish_roundtable(rt_id: str, project_id: str):
    """结束并生成总结。仅 waiting_user / confirm_end 允许（决策 6）。"""
    rt = get_roundtable(project_id, rt_id)
    if not rt:
        raise HTTPException(status_code=404, detail="圆桌不存在")
    if rt["status"] not in ("waiting_user", "confirm_end"):
        raise HTTPException(status_code=400, detail=f"当前状态（{rt['status']}）不允许结束")
    try:
        return await rt_mod.finish_roundtable(project_id, rt_id)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))

@app.post("/api/roundtables/{rt_id}/stop")
async def api_stop_roundtable(rt_id: str, project_id: str):
    """checkpoint-067 N-1：手动停止进行中的圆桌。
    置取消标志，执行循环在下一个检查点（当前发言完成后）中止本轮，
    已完成发言保留，状态置 waiting_user（用户可继续或结束）。立即返回。"""
    rt = get_roundtable(project_id, rt_id)
    if not rt:
        raise HTTPException(status_code=404, detail="圆桌不存在")
    if rt["status"] in ("done", "failed"):
        raise HTTPException(status_code=400, detail=f"圆桌已结束（{rt['status']}），无需停止")
    rt_mod.request_cancel(rt_id)
    return {"ok": True, "detail": "已请求停止，将在当前发言完成后中止"}


# ── M4（TS-110）：知识库 / 记忆 / Skill 端点 ─────────────

from sidecar.knowledge import (
    list_knowledge as _k_list, read_knowledge as _k_read,
    write_knowledge as _k_write, delete_knowledge as _k_delete,
    toggle_knowledge as _k_toggle, read_memory as _mem_read, write_memory as _mem_write,
)
from sidecar.skills_mgr import (
    list_skills as _sk_list, read_skill as _sk_read,
    create_or_update_skill as _sk_save, delete_skill as _sk_delete,
    toggle_skill as _sk_toggle, install_skill_from_repo as _sk_install,
)

@app.get("/api/projects/{project_id}/knowledge")
async def api_list_knowledge(project_id: str):
    return _k_list(project_id)

@app.get("/api/projects/{project_id}/knowledge/{name}")
async def api_read_knowledge(project_id: str, name: str):
    content = _k_read(project_id, name)
    if content is None:
        raise HTTPException(status_code=404, detail="知识文件不存在或文件名非法")
    return {"name": name, "content": content}

class KnowledgeWriteReq(BaseModel):
    name: str
    content: str = ""

@app.put("/api/projects/{project_id}/knowledge")
async def api_write_knowledge(project_id: str, req: KnowledgeWriteReq):
    name = req.name.strip()
    if not name.endswith(".md"):
        raise HTTPException(status_code=400, detail="文件名必须以 .md 结尾")
    if not _k_write(project_id, name, req.content):
        raise HTTPException(status_code=400, detail="保存失败（文件名非法或项目工作目录不可写）")
    return {"ok": True, "name": name}

@app.delete("/api/projects/{project_id}/knowledge/{name}")
async def api_delete_knowledge(project_id: str, name: str):
    if not _k_delete(project_id, name):
        raise HTTPException(status_code=404, detail="知识文件不存在或文件名非法")
    return {"ok": True}

@app.post("/api/projects/{project_id}/knowledge/{name}/toggle")
async def api_toggle_knowledge(project_id: str, name: str):
    new_name = _k_toggle(project_id, name)
    if new_name is None:
        raise HTTPException(status_code=400, detail="切换失败（文件不存在或同名冲突）")
    return {"ok": True, "name": new_name}

@app.get("/api/memory")
async def api_read_memory(scope: str = "global", project_id: str = ""):
    if scope not in ("global", "project"):
        raise HTTPException(status_code=400, detail="scope 必须是 global 或 project")
    return {"scope": scope, "content": _mem_read(scope, project_id or None)}

class MemoryWriteReq(BaseModel):
    scope: str
    project_id: str = ""
    content: str = ""

@app.put("/api/memory")
async def api_write_memory(req: MemoryWriteReq):
    if req.scope not in ("global", "project"):
        raise HTTPException(status_code=400, detail="scope 必须是 global 或 project")
    if not _mem_write(req.scope, req.content, req.project_id or None):
        raise HTTPException(status_code=400, detail="保存失败（项目记忆需要有效的项目工作目录）")
    return {"ok": True}

@app.get("/api/skills")
async def api_list_skills():
    return _sk_list()

class SkillSaveReq(BaseModel):
    name: str
    description: str = ""
    body: str = ""
    enabled: bool = True

@app.post("/api/skills")
async def api_create_skill(req: SkillSaveReq):
    if not _sk_save(req.name, req.description, req.body, req.enabled):
        raise HTTPException(status_code=400, detail="技能名非法（限字母/数字/中文/-/_，≤64 字符）")
    return {"ok": True, "name": req.name}

@app.put("/api/skills/{name}")
async def api_update_skill(name: str, req: SkillSaveReq):
    if not _sk_save(name, req.description, req.body, req.enabled):
        raise HTTPException(status_code=400, detail="更新失败")
    return {"ok": True, "name": name}

@app.get("/api/skills/{name}")
async def api_read_skill(name: str):
    sk = _sk_read(name)
    if sk is None:
        raise HTTPException(status_code=404, detail="技能不存在")
    return sk

@app.delete("/api/skills/{name}")
async def api_delete_skill(name: str):
    if not _sk_delete(name):
        raise HTTPException(status_code=404, detail="技能不存在或名称非法")
    return {"ok": True}

@app.post("/api/skills/{name}/toggle")
async def api_toggle_skill(name: str):
    new_state = _sk_toggle(name)
    if new_state is None:
        raise HTTPException(status_code=400, detail="切换失败（技能不存在）")
    return {"ok": True, "enabled": new_state}

class SkillInstallReq(BaseModel):
    url: str

@app.post("/api/skills/install")
async def api_install_skill(req: SkillInstallReq):
    result = _sk_install(req.url)
    if not result.get("ok"):
        raise HTTPException(status_code=400, detail=result.get("error", "安装失败"))
    return result


@app.post("/api/dialog/choose-dir")
async def api_dialog_choose_dir():
    """原生"选择文件夹"对话框（2026-08-28 新增）。

    用途：Electron 主进程为旧版（preload 未生效）或纯浏览器环境下，
    前端仍可经侧车弹出 macOS 系统文件夹选择器（osascript），不必手填路径。
    返回：{"dir": "/abs/path"} 或 {"canceled": true}；非 macOS / 弹窗失败 → {"error": ...}
    """
    import platform
    import subprocess
    if platform.system() != "Darwin":
        raise HTTPException(status_code=501, detail="仅 macOS 支持系统文件夹选择器")
    # checkpoint-050 查虫修复 B-2：choose folder 只支持 with prompt / default location，
    # 不支持 default button / cancel button（旧写法语法错误，纯浏览器环境选择器必然失败）
    script = 'POSIX path of (choose folder with prompt "选择项目工作目录")'
    try:
        proc = await asyncio.to_thread(
            subprocess.run, ["osascript", "-e", script],
            capture_output=True, text=True, timeout=300,
        )
    except subprocess.TimeoutExpired:
        return {"canceled": True}
    if proc.returncode == 0:
        return {"dir": proc.stdout.strip().rstrip("/")}
    # osascript 用户点"取消" → returncode 1。系统语言不同报错文案不同：
    # 英文 "User canceled" / 中文 "用户已取消" / 错误码 -128 三者任一命中即视为取消
    # （checkpoint-050 查虫修复：原判定只认英文，中文系统点取消误报 500）
    stderr = proc.stderr or ""
    if "User canceled" in stderr or "用户已取消" in stderr or "-128" in stderr:
        return {"canceled": True}
    raise HTTPException(status_code=500, detail=f"文件夹选择器异常: {stderr.strip()[:200]}")


# ── 0.2.1（TS-119）：工作流模块（一级模块"流程中心"）──────────────────
# 工作流是全局资源（与"智能中心"平级的一级模块），API 不挂 project 前缀。
# 推理节点纯调用（无 tool loop）+ 模型切换即卸载，见 sidecar/workflow/engine.py。

class WorkflowCreateReq(BaseModel):
    name: str
    description: str = ""
    definition: dict[str, Any]


class WorkflowUpdateReq(BaseModel):
    name: str | None = None
    description: str | None = None
    definition: dict[str, Any] | None = None


class WorkflowRunReq(BaseModel):
    params: dict[str, Any] | None = None
    sandbox_root: str | None = None


class WorkflowApproveReq(BaseModel):
    approved: bool
    comment: str = ""


@app.get("/api/workflows")
async def api_list_workflows():
    return list_workflows()


@app.post("/api/workflows")
async def api_create_workflow(req: WorkflowCreateReq):
    # 0.2.1 修正：创建用宽松校验（strict=False）——新建的空白工作流只有开始节点，
    # 属于合法的"半成品"（用户边搭边存）。节点类型/连线引用等硬伤仍拦截；
    # 完整性（开始/结束/连通）只把运行关（/run 走严格校验）。
    errors = validate_definition(req.definition, strict=False)
    if errors:
        raise HTTPException(status_code=422, detail="；".join(errors[:5]))
    wf_id = create_workflow(req.name.strip() or "未命名工作流", req.definition, req.description)
    return {"ok": True, "id": wf_id}


@app.get("/api/workflows/{wf_id}")
async def api_get_workflow(wf_id: str):
    wf = get_workflow(wf_id)
    if wf is None:
        raise HTTPException(status_code=404, detail="工作流不存在")
    return wf


@app.put("/api/workflows/{wf_id}")
async def api_update_workflow(wf_id: str, req: WorkflowUpdateReq):
    wf = get_workflow(wf_id)
    if wf is None:
        raise HTTPException(status_code=404, detail="工作流不存在")
    if wf.get("built_in"):
        raise HTTPException(status_code=403, detail="内置工作流不可修改")
    # 0.2.1 修正：保存用宽松校验（strict=False）——编辑中途的半成品也要能存；
    # 完整性（开始/结束/连通）只把运行关（/run 走严格校验）。
    if req.definition is not None:
        errors = validate_definition(req.definition, strict=False)
        if errors:
            raise HTTPException(status_code=422, detail="；".join(errors[:5]))
    ok = update_workflow(wf_id, name=req.name, definition=req.definition,
                         description=req.description)
    return {"ok": ok}


@app.delete("/api/workflows/{wf_id}")
async def api_delete_workflow(wf_id: str):
    wf = get_workflow(wf_id)
    if wf is None:
        raise HTTPException(status_code=404, detail="工作流不存在")
    if wf.get("built_in"):
        raise HTTPException(status_code=403, detail="内置工作流不可删除")
    ok = delete_workflow(wf_id)
    return {"ok": ok}


@app.post("/api/workflows/{wf_id}/run")
async def api_run_workflow(wf_id: str, req: WorkflowRunReq):
    """运行工作流：SSE 实时推送节点事件（node_start/node_done/node_error/
    approval_required/workflow_done/workflow_failed/workflow_stopped）。"""
    wf = get_workflow(wf_id)
    if wf is None:
        raise HTTPException(status_code=404, detail="工作流不存在")
    errors = validate_definition(wf["definition"])
    if errors:
        raise HTTPException(status_code=422, detail="工作流定义有错误：" + "；".join(errors[:5]))

    run_id = create_workflow_run(wf_id, req.params or {})
    sandbox_root = req.sandbox_root or str(_os.path.expanduser("~/Desktop"))

    async def gen():
        try:
            conn = get_ollama_connector()
            engine = WorkflowEngine(run_id, wf["definition"], conn, sandbox_root,
                                    params=req.params or {})
            agen = engine.run()
            try:
                async for ev in agen:
                    yield _sse_format(ev["event"], ev["data"])
            finally:
                # 客户端断开/正常结束：关闭引擎消费器 → 引擎内部取消生产者任务
                # 并卸载驻留模型（任何退出路径都不漏释放内存）
                await agen.aclose()
        except asyncio.CancelledError:
            raise
        except Exception as e:
            try:
                update_workflow_run(run_id, status="failed", error=str(e))
            except Exception:
                pass
            yield _sse_format("workflow_failed", {"error": str(e)})

    return StreamingResponse(gen(), media_type="text/event-stream")


@app.get("/api/workflow-runs")
async def api_list_workflow_runs(workflow_id: str | None = None, limit: int = 30):
    return list_workflow_runs(workflow_id, min(max(limit, 1), 100))


@app.get("/api/workflow-runs/{run_id}")
async def api_get_workflow_run(run_id: str):
    run = get_workflow_run(run_id)
    if run is None:
        raise HTTPException(status_code=404, detail="运行记录不存在")
    run["node_events"] = list_workflow_node_events(run_id)
    return run


@app.post("/api/workflow-runs/{run_id}/approve")
async def api_workflow_approve(run_id: str, req: WorkflowApproveReq):
    """人工审批决议：唤醒挂起在审批节点的引擎继续/终止。"""
    run = get_workflow_run(run_id)
    if run is None:
        raise HTTPException(status_code=404, detail="运行记录不存在")
    if run["status"] != "awaiting_approval":
        raise HTTPException(status_code=409, detail=f"当前状态 {run['status']} 不在等待审批")
    ok = resolve_workflow_approval(run_id, req.approved, req.comment)
    if not ok:
        raise HTTPException(status_code=409, detail="审批已失效（运行可能已结束）")
    # 恢复为运行中（引擎被唤醒后会继续推进节点）
    update_workflow_run(run_id, status="running")
    return {"ok": True}


@app.post("/api/workflow-runs/{run_id}/stop")
async def api_workflow_stop(run_id: str):
    """停止运行中的工作流：引擎在下一节点边界检测标志后中止，并卸载驻留模型。"""
    run = get_workflow_run(run_id)
    if run is None:
        raise HTTPException(status_code=404, detail="运行记录不存在")
    if run["status"] not in ("running", "awaiting_approval"):
        return {"ok": False, "detail": f"当前状态 {run['status']}，无需停止"}
    request_workflow_cancel(run_id)
    # 若卡在审批等待，驳回以解锁引擎（引擎会以取消标志中止）
    resolve_workflow_approval(run_id, False, "用户已停止")
    return {"ok": True}


# ── TS-120（0.3.0）：知识仓库（拉模式）────────────────────────────
# 与 M4 知识（推模式）严格区分：本模块内容永不自动注入，仅按需检索/勾选注入。
from sidecar.knowledge import warehouse as _wh
from sidecar.storage.store import archive_messages as _archive_msgs


class KnowledgeTransferReq(BaseModel):
    project_id: str
    session_id: str
    message_ids: list[int]
    scope: str = "project"          # project | global
    title: str | None = None        # 留空自动取首条前 20 字
    category: str = ""
    keywords: list[str] | None = None


@app.post("/api/knowledge/transfer")
async def api_knowledge_transfer(req: KnowledgeTransferReq):
    """把勾选的会话消息转移入知识仓库：生成 .md 条目 + 标记消息归档。"""
    if req.scope not in ("project", "global"):
        raise HTTPException(status_code=400, detail="scope 必须是 project 或 global")
    msgs = load_messages(req.project_id, req.session_id)
    id_set = set(req.message_ids)
    picked = [m for m in msgs if m.get("id") in id_set]
    if not picked:
        raise HTTPException(status_code=404, detail="未找到指定消息")
    # 组装正文（角色: 内容）
    body_lines = []
    for m in picked:
        role = m.get("role", "?")
        content = str(m.get("content") or "").strip()
        if content:
            body_lines.append(f"**{role}**：{content}")
    body = "\n\n".join(body_lines)
    if not body.strip():
        raise HTTPException(status_code=422, detail="勾选的消息无文本内容")
    # 标题：用户指定 > 首条前 20 字
    title = (req.title or "").strip()
    if not title:
        first = next((str(m.get("content") or "") for m in picked if str(m.get("content") or "").strip()), "")
        title = first[:20] or "未命名"
    entry = _wh.add_entry(req.scope, req.project_id if req.scope == "project" else None,
                          title, body, category=req.category,
                          keywords=req.keywords or [], source="chat")
    if entry is None:
        raise HTTPException(status_code=500, detail="知识条目写入失败（目录不可用）")
    # 归档消息（脱离模型上下文）
    archived = _archive_msgs(req.project_id, req.message_ids)
    return {"ok": True, "entry_id": entry["id"], "title": title,
            "file_path": entry["file_path"], "archived": archived}


@app.get("/api/knowledge/entries")
async def api_knowledge_list(scope: str | None = None, project_id: str | None = None):
    """列出知识条目（可按作用域/项目过滤）。读取前对账：外部删除的 .md 同步清出索引。"""
    _wh.prune_missing()
    return _wh.list_entries(scope, project_id)


@app.get("/api/knowledge/entries/{entry_id}")
async def api_knowledge_get(entry_id: str):
    entry = _wh.get_entry(entry_id)
    if entry is None:
        raise HTTPException(status_code=404, detail="知识条目不存在")
    return entry


@app.delete("/api/knowledge/entries/{entry_id}")
async def api_knowledge_delete(entry_id: str):
    ok = _wh.delete_entry(entry_id)
    if not ok:
        raise HTTPException(status_code=404, detail="知识条目不存在")
    return {"ok": True}


@app.get("/api/knowledge/search")
async def api_knowledge_search(q: str, scope: str | None = None,
                               project_id: str | None = None, limit: int = 20):
    """关键词检索（FTS5 + jieba 分词）。读取前对账：外部删除的 .md 不再命中。"""
    _wh.prune_missing()
    return _wh.search_entries(q, scope, project_id, min(max(limit, 1), 100))


class KnowledgeInjectReq(BaseModel):
    entry_ids: list[str]


@app.post("/api/knowledge/inject")
async def api_knowledge_inject(req: KnowledgeInjectReq):
    """把勾选条目的正文拼为可发送文本（前端作为用户消息注入会话）。"""
    parts = []
    for eid in req.entry_ids:
        e = _wh.get_entry(eid)
        if e:
            parts.append(f"【知识：{e['title']}】\n{e.get('body', '')}")
    if not parts:
        raise HTTPException(status_code=404, detail="未找到任何有效条目")
    return {"ok": True, "text": "\n\n---\n\n".join(parts)}


@app.post("/api/knowledge/rebuild-index")
async def api_knowledge_rebuild():
    """重建索引（扫描全部 .md 重建，容灾）。"""
    n = _wh.rebuild_index()
    return {"ok": True, "entries": n}


@app.get("/api/knowledge/groups")
async def api_knowledge_groups():
    """设置页资产管理器：全局知识组 + 各项目知识组（含条数与目录路径）。读取前对账。"""
    from sidecar.storage.store import list_projects
    _wh.prune_missing()
    groups = []
    # 全局
    g_entries = _wh.list_entries("global")
    groups.append({"scope": "global", "project_id": None, "project_name": "全局",
                   "count": len(g_entries), "dir": str(_wh.global_knowledge_dir())})
    # 各项目
    try:
        projects = list_projects()
    except Exception:
        projects = []
    for p in projects:
        pid = p.get("id")
        name = p.get("name") or pid
        p_entries = _wh.list_entries("project", pid)
        kdir = _wh.project_knowledge_dir(pid)
        groups.append({"scope": "project", "project_id": pid, "project_name": name,
                       "count": len(p_entries), "dir": str(kdir) if kdir else ""})
    return groups


class OpenKnowledgeDirReq(BaseModel):
    scope: str = "global"
    project_id: str | None = None


@app.post("/api/knowledge/open-dir")
async def api_knowledge_open_dir(req: OpenKnowledgeDirReq):
    """在 Finder 打开知识目录（仅全局/项目知识库目录，白名单校验防任意路径打开）。"""
    import platform
    import subprocess
    kdir = _wh.scope_dir(req.scope, req.project_id)
    if kdir is None:
        raise HTTPException(status_code=400, detail="无效的作用域或项目")
    kdir.mkdir(parents=True, exist_ok=True)
    if platform.system() != "Darwin":
        return {"ok": False, "dir": str(kdir), "detail": "非 macOS，请手动打开：" + str(kdir)}
    try:
        await asyncio.to_thread(subprocess.run, ["open", str(kdir)],
                                capture_output=True, timeout=15)
    except subprocess.TimeoutExpired:
        return {"ok": False, "dir": str(kdir), "detail": "打开超时"}
    return {"ok": True, "dir": str(kdir)}
