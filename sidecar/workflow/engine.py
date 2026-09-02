"""0.2.1（TS-119）：工作流执行引擎。

节点类型：start / inference / tool / condition / parallel / loop / approval / end

关键设计（用户拍板 2026-09-02）：
1. 推理节点纯调用：不走 tool loop、无系统提示词、无工具列表——直接
   connector.chat(model, [user消息], images=...)。根治 OCR 专用小模型
   被"Agent 外壳"（长提示词/工具/循环）逼出乱码、复读任务书的问题。
2. 模型切换即卸载：执行推理节点前，若其模型与当前驻留模型不同 →
   先卸载旧模型（keep_alive:0）再执行（新模型由 Ollama 自动加载）；
   相同模型连续多步不卸载。工作流结束（含异常/取消路径）卸载驻留模型。
3. 条件分支：静态匹配（contains/equals/regex 等）或动态裁判（纯调用
   模型判定，输出决定走哪条 when 边）。
4. 人工审批：节点挂起（awaiting_approval）+ SSE 心跳保活，等待 /approve
   端点决议；客户端断开 → 取消生产者任务并卸载模型。
5. 并行：parallel 节点的 branches 列表内各节点（单节点粒度）并发执行。
6. 循环：loop 节点对列表变量逐项执行 branch 节点（{{item}} 可用）。

事件流架构：执行主体在独立任务中运行，事件经异步队列输出——
审批挂起期间仍可发心跳，客户端断开时能安全取消并卸载模型。
事件：node_start / node_done / node_error / approval_required / heartbeat /
workflow_done / workflow_failed / workflow_stopped。
"""
from __future__ import annotations

import asyncio
import re
import time
from dataclasses import dataclass
from typing import Any, AsyncIterator, Callable

from sidecar.storage.store import update_workflow_run, append_workflow_node_event

NODE_TYPES = ("start", "inference", "tool", "condition", "parallel", "loop", "approval", "end")

# 人工审批等待注册表：run_id → {"event": asyncio.Event, "approved": bool, "comment": str}
_APPROVALS: dict[str, dict[str, Any]] = {}

# 运行取消标志：run_id → True
_CANCEL_FLAGS: dict[str, bool] = {}

# 审批等待期间的 SSE 心跳间隔（秒）
APPROVAL_HEARTBEAT_S = 15.0


def request_workflow_cancel(run_id: str) -> None:
    _CANCEL_FLAGS[run_id] = True


def clear_workflow_cancel(run_id: str) -> None:
    _CANCEL_FLAGS.pop(run_id, None)


def is_workflow_cancelled(run_id: str) -> bool:
    return bool(_CANCEL_FLAGS.get(run_id))


def resolve_workflow_approval(run_id: str, approved: bool, comment: str = "") -> bool:
    """/approve 端点调用：对挂起的审批节点给出决议，唤醒引擎。"""
    entry = _APPROVALS.get(run_id)
    if entry is None:
        return False
    entry["approved"] = approved
    entry["comment"] = comment
    entry["event"].set()
    return True


class WorkflowCancel(Exception):
    pass


@dataclass
class NodeResult:
    node_id: str
    ok: bool = True
    output: Any = None
    error: str | None = None
    model_used: str | None = None
    duration_ms: int = 0
    retry_count: int = 0


# ---------- 模板渲染 ----------
_TPL_RE = re.compile(r"\{\{\s*([\w.\-]+)\s*\}\}")


def render_template(text: str, variables: dict[str, Any]) -> str:
    """把 {{node_id.output}} / {{params.x}} / {{item}} 替换为变量值。

    值为列表/字典时转成紧凑 JSON 文本；未定义的占位符原样保留（提示配置错误）。
    """
    if not text:
        return text

    def _sub(m: re.Match) -> str:
        path = m.group(1).split(".")
        cur: Any = variables
        for part in path:
            if isinstance(cur, dict) and part in cur:
                cur = cur[part]
            else:
                return m.group(0)  # 未定义 → 原样保留
        if isinstance(cur, (list, dict)):
            import json as _j
            return _j.dumps(cur, ensure_ascii=False)
        return str(cur)

    return _TPL_RE.sub(_sub, text)


def resolve_value(ref: Any, variables: dict[str, Any]) -> Any:
    """解析变量引用：整串 "{{...}}" → 原值（保持类型）；含模板的字符串 → 渲染；其他原样。"""
    if isinstance(ref, str):
        m = re.fullmatch(r"\{\{\s*([\w.\-]+)\s*\}\}", ref.strip())
        if m:
            path = m.group(1).split(".")
            cur: Any = variables
            for part in path:
                if isinstance(cur, dict) and part in cur:
                    cur = cur[part]
                else:
                    return None
            return cur
        return render_template(ref, variables)
    return ref


def resolve_images(node: dict, variables: dict[str, Any]) -> list[str]:
    """推理节点图片来源：node.images（变量引用或列表）→ data URI / 路径列表。"""
    raw = node.get("images")
    if raw is None:
        return []
    val = resolve_value(raw, variables)
    if isinstance(val, list):
        return [str(v) for v in val if v]
    if isinstance(val, str) and val:
        return [val]
    return []


# ---------- 条件求值 ----------
def _eval_condition(node: dict, variables: dict[str, Any]) -> bool:
    match = node.get("match") or {}
    target = resolve_value(match.get("variable", ""), variables)
    op = str(match.get("operator") or "")
    value = str(match.get("value", ""))
    text = "" if target is None else str(target)
    if op == "contains":
        return value in text
    if op == "not_contains":
        return value not in text
    if op == "equals":
        return text == value
    if op == "starts_with":
        return text.startswith(value)
    if op == "regex":
        try:
            return re.search(value, text) is not None
        except re.error:
            return False
    if op == "empty":
        return not text.strip()
    if op == "not_empty":
        return bool(text.strip())
    return False


# ---------- 引擎 ----------
class WorkflowEngine:
    """单个工作流运行实例的执行器。

    connector 必须提供：
      async chat(model, messages, images=None) -> str
      async unload_model(model) -> bool

    用法：
      async for ev in engine.run():  # ev = {"event": ..., "data": ...}
          ...
    """

    def __init__(self, run_id: str, definition: dict[str, Any], connector: Any,
                 sandbox_root: str, params: dict[str, Any] | None = None,
                 on_event: Callable[[str, dict], None] | None = None):
        self.run_id = run_id
        self.definition = definition or {}
        self.nodes: dict[str, dict] = {
            str(n.get("id")): n for n in (definition.get("nodes") or [])
            if isinstance(n, dict) and n.get("id")
        }
        self.edges: list[dict] = [e for e in (definition.get("edges") or []) if isinstance(e, dict)]
        self.connector = connector
        self.sandbox_root = sandbox_root
        self.on_event = on_event
        # 运行时变量：node_id → {"output": ...}；params → 启动参数
        self.variables: dict[str, Any] = {"params": params or {}}
        self._current_model: str | None = None  # 当前驻留模型（卸载判定用）
        self._cancelled = False
        self._q: asyncio.Queue = asyncio.Queue()  # 事件输出队列

    # ---- 事件 ----
    def _emit(self, event: str, data: dict) -> None:
        """事件入队（供 SSE 消费）；同时回调可选监听器。"""
        self._q.put_nowait({"event": event, "data": data})
        if self.on_event:
            try:
                self.on_event(event, data)
            except Exception:
                pass

    # ---- 模型驻留管理（用户拍板的释放规则）----
    async def _ensure_model(self, model: str) -> None:
        """执行推理前确保驻留模型正确：不同 → 卸载旧的；相同 → 不动。"""
        if self._current_model and self._current_model != model:
            await self.connector.unload_model(self._current_model)
        self._current_model = model

    async def _release_model(self) -> None:
        """工作流结束（任何路径）：卸载最后驻留的模型，彻底释放内存。"""
        if self._current_model:
            try:
                await self.connector.unload_model(self._current_model)
            except Exception:
                pass
            self._current_model = None

    # ---- 边与后继 ----
    def _out_edges(self, node_id: str) -> list[dict]:
        return [e for e in self.edges if str(e.get("from")) == node_id]

    def _pick_next(self, node: dict, when: str | None = None) -> dict | None:
        """按 when 标签选下一条边对应的节点；无条件时取唯一出边。"""
        outs = self._out_edges(str(node.get("id")))
        if not outs:
            return None
        if when is not None:
            for e in outs:
                if str(e.get("when", "")) == when:
                    return self.nodes.get(str(e.get("to")))
            return None
        return self.nodes.get(str(outs[0].get("to")))

    # ---- 节点执行 ----
    def _check_cancel(self) -> None:
        if is_workflow_cancelled(self.run_id) or self._cancelled:
            self._cancelled = True
            raise WorkflowCancel()

    async def _run_inference(self, node: dict) -> NodeResult:
        """纯推理节点：无工具、无系统提示词，直接一问一答。"""
        model = str(node.get("model") or "").strip()
        if not model:
            return NodeResult(node["id"], ok=False, error="推理节点未配置模型")
        await self._ensure_model(model)
        prompt = render_template(str(node.get("prompt") or ""), self.variables)
        images = resolve_images(node, self.variables)
        user_content = prompt or "请处理输入。"
        try:
            text = await self.connector.chat(
                model, [{"role": "user", "content": user_content}],
                images=images if images else None)
        except Exception as e:
            return NodeResult(node["id"], ok=False, error=f"模型调用失败：{e}", model_used=model)
        return NodeResult(node["id"], ok=True, output=text, model_used=model)

    async def _run_tool(self, node: dict) -> NodeResult:
        """工具节点：调用注册表工具（写文件/读文件/列目录等）。"""
        from sidecar.tools.registry import execute as execute_tool
        tool_name = str(node.get("tool") or "").strip()
        if not tool_name:
            return NodeResult(node["id"], ok=False, error="工具节点未配置 tool")
        raw_args = node.get("args") or {}
        args: dict[str, Any] = {}
        for k, v in raw_args.items():
            args[k] = resolve_value(v, self.variables)
        try:
            result = await execute_tool(tool_name, args, self.sandbox_root, None)
        except Exception as e:
            return NodeResult(node["id"], ok=False, error=f"工具执行异常：{e}")
        if not isinstance(result, dict) or not result.get("ok"):
            err = str((result or {}).get("error", "工具执行失败")) if isinstance(result, dict) else "工具执行失败"
            return NodeResult(node["id"], ok=False, error=err)
        return NodeResult(node["id"], ok=True, output=result)

    async def _run_condition(self, node: dict) -> tuple[NodeResult, str]:
        """条件节点：返回结果 + when 标签（"true"/"false" 或动态分支名）。"""
        # 动态裁判：配置了 model → 纯调用模型判定，输出首行即 when 标签
        model = str(node.get("model") or "").strip()
        if model:
            await self._ensure_model(model)
            prompt = render_template(str(node.get("prompt") or "请判断并只输出分支名。"), self.variables)
            try:
                text = await self.connector.chat(model, [{"role": "user", "content": prompt}])
            except Exception as e:
                return (NodeResult(node["id"], ok=False, error=f"裁判模型调用失败：{e}",
                                   model_used=model), "false")
            lines = [ln.strip() for ln in (text or "").splitlines() if ln.strip()]
            branch = lines[0] if lines else ""
            return NodeResult(node["id"], ok=True, output=branch, model_used=model), branch
        # 静态匹配
        hit = _eval_condition(node, self.variables)
        return NodeResult(node["id"], ok=True, output=hit), ("true" if hit else "false")

    async def _run_parallel(self, node: dict) -> NodeResult:
        """并行节点：branches 内各节点（单节点粒度）并发执行，输出收集为列表。"""
        branches = [str(b) for b in (node.get("branches") or []) if str(b) in self.nodes]
        if not branches:
            return NodeResult(node["id"], ok=False, error="并行节点未配置 branches")
        results = await asyncio.gather(
            *[self._execute_node(self.nodes[b]) for b in branches],
            return_exceptions=False)
        outputs = [r.output for r in results]
        errors = [f"{r.node_id}: {r.error}" for r in results if not r.ok]
        if errors:
            return NodeResult(node["id"], ok=False, output=outputs, error="；".join(errors))
        return NodeResult(node["id"], ok=True, output=outputs)

    async def _run_loop(self, node: dict) -> NodeResult:
        """循环节点：对 items 列表逐项执行 branch 节点（{{item}} / {{item_index}} 可用）。"""
        items = resolve_value(node.get("items", ""), self.variables)
        if not isinstance(items, list):
            return NodeResult(node["id"], ok=False,
                              error=f"loop.items 不是列表：{type(items).__name__}")
        branch_id = str(node.get("branch") or "")
        branch_node = self.nodes.get(branch_id)
        if branch_node is None:
            return NodeResult(node["id"], ok=False, error="loop.branch 节点不存在")
        outputs: list[Any] = []
        for idx, item in enumerate(items):
            self._check_cancel()
            self.variables["item"] = item
            self.variables["item_index"] = idx
            r = await self._execute_node(branch_node)
            if not r.ok:
                return NodeResult(node["id"], ok=False, output=outputs,
                                  error=f"第 {idx + 1} 项失败：{r.error}")
            outputs.append(r.output)
        self.variables.pop("item", None)
        self.variables.pop("item_index", None)
        return NodeResult(node["id"], ok=True, output=outputs)

    async def _run_approval(self, node: dict) -> NodeResult:
        """人工审批节点：挂起等待 /approve 决议；等待期间每 15s 发 SSE 心跳。"""
        entry: dict[str, Any] = {"event": asyncio.Event(), "approved": False, "comment": ""}
        _APPROVALS[self.run_id] = entry
        update_workflow_run(self.run_id, status="awaiting_approval",
                            current_node=str(node.get("id")),
                            variables=self._snapshot_vars())
        self._emit("approval_required", {
            "run_id": self.run_id, "node_id": node["id"],
            "label": node.get("label") or "人工审批",
            "message": render_template(str(node.get("message") or "请确认是否继续。"), self.variables),
        })
        try:
            while not entry["event"].is_set():
                try:
                    await asyncio.wait_for(entry["event"].wait(), timeout=APPROVAL_HEARTBEAT_S)
                except asyncio.TimeoutError:
                    # 心跳：保持 SSE 连接活跃（审批可能等待很久）
                    self._q.put_nowait({"event": "heartbeat", "data": {"run_id": self.run_id}})
        finally:
            _APPROVALS.pop(self.run_id, None)
        # 被停止（驳回解锁）→ 优先走取消路径
        self._check_cancel()
        if not entry["approved"]:
            return NodeResult(node["id"], ok=False,
                              error=f"审批被驳回：{entry.get('comment') or '用户驳回'}")
        return NodeResult(node["id"], ok=True, output=entry.get("comment") or "approved")

    async def _execute_node(self, node: dict) -> NodeResult:
        """执行单个节点（含重试）。"""
        retry_limit = int(node.get("retry") or 0)
        attempt = 0
        t0 = time.time()
        while True:
            self._check_cancel()
            ntype = node.get("type")
            if ntype == "inference":
                res = await self._run_inference(node)
            elif ntype == "tool":
                res = await self._run_tool(node)
            elif ntype == "parallel":
                res = await self._run_parallel(node)
            elif ntype == "loop":
                res = await self._run_loop(node)
            elif ntype == "approval":
                res = await self._run_approval(node)
            elif ntype in ("start", "end"):
                res = NodeResult(node["id"], ok=True, output=None)
            elif ntype == "condition":
                res = NodeResult(node["id"], ok=False,
                                 error="条件节点只能作为主链节点，不能放在并行分支/循环内")
            else:
                res = NodeResult(node["id"], ok=False, error=f"未知节点类型：{ntype}")
            res.duration_ms = int((time.time() - t0) * 1000)
            res.retry_count = attempt
            if res.ok or attempt >= retry_limit:
                return res
            attempt += 1
            await asyncio.sleep(min(2 * attempt, 10))  # 退避重试

    def _snapshot_vars(self) -> dict[str, Any]:
        """运行快照（落库用）：截断长文本，保证可序列化。"""
        snap: dict[str, Any] = {}
        for k, v in self.variables.items():
            if isinstance(v, dict) and "output" in v:
                out = v["output"]
                snap[k] = {"output": str(out)[:2000] if out is not None else None}
            else:
                snap[k] = v
        return snap

    # ---- 主执行（生产者：在独立任务中运行） ----
    async def _run_main(self) -> None:
        """主链执行：事件经 _emit 入队；任何退出路径都保证卸载驻留模型。"""
        start_nodes = [n for n in self.nodes.values() if n.get("type") == "start"]
        if not start_nodes:
            self._emit("workflow_failed", {"error": "缺少开始节点"})
            return
        node: dict | None = start_nodes[0]
        final_result: Any = None
        try:
            while node is not None:
                self._check_cancel()
                node_id = str(node.get("id"))
                update_workflow_run(self.run_id, current_node=node_id,
                                    variables=self._snapshot_vars())
                self._emit("node_start", {"node_id": node_id,
                                          "label": node.get("label") or node_id,
                                          "type": node.get("type")})
                append_workflow_node_event(self.run_id, node_id, str(node.get("type")), "running")

                when: str | None = None
                if node.get("type") == "condition":
                    res, when = await self._run_condition(node)
                else:
                    res = await self._execute_node(node)

                # 结果写入变量空间
                self.variables[node_id] = {"output": res.output}
                if node.get("type") == "end":
                    out_ref = node.get("output")
                    final_result = resolve_value(out_ref, self.variables) if out_ref else res.output

                if res.ok:
                    append_workflow_node_event(
                        self.run_id, node_id, str(node.get("type")), "done",
                        model_used=res.model_used,
                        output_summary=str(res.output)[:2000] if res.output is not None else "",
                        retry_count=res.retry_count, duration_ms=res.duration_ms)
                    self._emit("node_done", {
                        "node_id": node_id,
                        "output_preview": str(res.output)[:300] if res.output else ""})
                else:
                    append_workflow_node_event(
                        self.run_id, node_id, str(node.get("type")), "error",
                        model_used=res.model_used, error=res.error,
                        retry_count=res.retry_count, duration_ms=res.duration_ms)
                    self._emit("node_error", {"node_id": node_id, "error": res.error})
                    update_workflow_run(self.run_id, status="failed", error=res.error,
                                        variables=self._snapshot_vars())
                    await self._release_model()
                    self._emit("workflow_failed", {"node_id": node_id, "error": res.error})
                    return

                if node.get("type") == "end":
                    break
                node = self._pick_next(node, when)

            update_workflow_run(self.run_id, status="done",
                                result=str(final_result)[:4000] if final_result is not None else None,
                                variables=self._snapshot_vars())
            await self._release_model()
            self._emit("workflow_done", {"run_id": self.run_id,
                                         "result_preview": str(final_result)[:300] if final_result else ""})
        except WorkflowCancel:
            update_workflow_run(self.run_id, status="stopped", error="用户已停止",
                                variables=self._snapshot_vars())
            await self._release_model()
            self._emit("workflow_stopped", {"run_id": self.run_id})
        except asyncio.CancelledError:
            # 客户端断开 → 生产者任务被取消：卸载模型后上抛
            try:
                update_workflow_run(self.run_id, status="stopped", error="客户端断开",
                                    variables=self._snapshot_vars())
            except Exception:
                pass
            await self._release_model()
            raise
        except Exception as e:
            update_workflow_run(self.run_id, status="failed", error=str(e),
                                variables=self._snapshot_vars())
            await self._release_model()
            self._emit("workflow_failed", {"error": str(e)})

    # ---- 对外入口（消费者：从队列取事件） ----
    async def run(self) -> AsyncIterator[dict[str, Any]]:
        """执行工作流，yield 事件 dict（{"event": ..., "data": ...}）。"""
        task = asyncio.create_task(self._run_main())
        try:
            while True:
                item = await self._q.get()
                yield item
                if item["event"] in ("workflow_done", "workflow_failed", "workflow_stopped"):
                    break
        finally:
            if not task.done():
                task.cancel()
                try:
                    await task
                except (asyncio.CancelledError, Exception):
                    pass
            else:
                # 确保生产者异常不丢失
                try:
                    await task
                except Exception:
                    pass
