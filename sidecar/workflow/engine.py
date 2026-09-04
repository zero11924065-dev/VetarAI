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
"""0.2.1（TS-119）：工作流执行引擎。

节点类型：start / inference / tool / condition / parallel / loop / approval /
file_input / file_output / end

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
7. 文件输入/输出（0.2.2）：file_input 读本机路径（文件/文件夹+扩展名过滤）
   输出文件路径列表；file_output 把上游结果按模板写入本机文件。
   两者均为纯本地操作，不联网（应用铁律：除搜索外一律不联网）。

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
from pathlib import Path
from typing import Any, AsyncIterator, Callable

from sidecar.storage.store import update_workflow_run, append_workflow_node_event

NODE_TYPES = ("start", "inference", "tool", "condition", "parallel", "loop",
              "approval", "file_input", "file_output", "file_read",
              "text_output", "variable_set", "code", "reply", "end")

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
        """事件入队（供 SSE 消费）；同时回调可选监听器。

        0.2.4（W1）：所有事件统一注入 run_id——此前仅审批/终态事件带，
        导致前端运行中捕获不到 run_id，停止按钮空转（请求从未发出）。
        """
        data = {**data, "run_id": self.run_id}
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

    # ---- 0.2.3：图片路径扩展名（自动继承用） ----
    _IMAGE_EXTS = (".jpg", ".jpeg", ".png", ".gif", ".bmp", ".webp", ".tiff", ".heic")

    def _inherit_upstream_images(self, node: dict) -> list[str]:
        """0.2.3：推理节点未配置 images 时，自动继承上游图片。两级兜底：

        1. 直接上游是文件输入节点 → 继承其产出的图片路径（线性链路）；
        2. 处于循环节点内（变量空间有 batch / item）→ 用当批/当前项的图片路径
           （循环链路：{{item}} 为单个路径或 {{batch}} 为一批路径）。

        背景：用户把文件夹/图片塞进文件输入节点后，推理节点若没手动连
        {{上游.output}} 到图片字段，模型就收不到图（只收到一句默认提示词），
        OCR 模型直接报错或空转。此继承让"文件输入 → 推理"这条最常见链路
        零配置可用。仅继承真实存在且扩展名为图片的文件路径，避免误伤。
        """
        # 1. 直接上游文件输入节点（线性链路）
        incoming = [e for e in self.edges if str(e.get("to")) == str(node.get("id"))]
        for e in incoming:
            src = self.nodes.get(str(e.get("from")))
            if not src or src.get("type") != "file_input":
                continue
            val = (self.variables.get(str(src.get("id"))) or {}).get("output")
            if not val:
                continue
            imgs = self._filter_image_paths(val if isinstance(val, list) else [val])
            if imgs:
                return imgs
        # 2. 循环上下文（循环节点已写入 batch / item 变量）
        batch = self.variables.get("batch")
        if batch is not None:
            imgs = self._filter_image_paths(batch if isinstance(batch, list) else [batch])
            if imgs:
                return imgs
        item = self.variables.get("item")
        if item is not None:
            imgs = self._filter_image_paths(item if isinstance(item, list) else [item])
            if imgs:
                return imgs
        return []

    @staticmethod
    def _filter_image_paths(paths: list) -> list[str]:
        """过滤出真实存在且扩展名为图片的文件路径。"""
        imgs: list[str] = []
        for p in paths:
            try:
                pp = Path(str(p))
                if pp.is_file() and pp.suffix.lower() in WorkflowEngine._IMAGE_EXTS:
                    imgs.append(str(pp))
            except (OSError, ValueError):
                continue
        return imgs

    @staticmethod
    def _keep_image_files(images: list[str]) -> tuple[list[str], list[str]]:
        """0.2.4（W8）：仅图片保护。把待传图片列表分为（保留, 剔除）两组。

        分类规则（与连接器 _parse_image 对齐）：
        - data: URI → 保留（已编码图片）
        - 存在的文件：扩展名为图片 → 保留；非图片（音频/文档等）→ 剔除
        - 不存在的长字符串（视为已编码 base64）→ 保留
        - 其余（无效短路径）→ 剔除
        """
        kept: list[str] = []
        dropped: list[str] = []
        for img in images:
            if not isinstance(img, str) or not img:
                dropped.append(str(img))
                continue
            if img.startswith("data:"):
                kept.append(img)
                continue
            try:
                pp = Path(img)
                if pp.is_file():
                    if pp.suffix.lower() in WorkflowEngine._IMAGE_EXTS:
                        kept.append(img)
                    else:
                        dropped.append(img)
                    continue
            except (OSError, ValueError):
                pass
            if len(img) > 50:
                kept.append(img)  # 视为已编码 base64
            else:
                dropped.append(img)
        return kept, dropped

    async def _interruptible_chat(self, model: str, user_content: str,
                                  images: list[str]) -> str:
        """0.2.3：可中断的模型调用。

        旧实现直接 await 一次 HTTP 调用——模型加载/推理动辄数分钟，期间
        取消标志无人检查，用户点"停止"毫无反应（只能手动杀模型）。现改为
        后台任务 + 每 2 秒轮询取消标志，命中即取消底层请求并抛 WorkflowCancel。
        """
        task = asyncio.create_task(
            self.connector.chat(model, [{"role": "user", "content": user_content}],
                                images=images if images else None))
        try:
            while True:
                done, _ = await asyncio.wait({task}, timeout=2.0)
                if task in done:
                    return task.result()
                self._check_cancel()  # 命中取消 → 抛 WorkflowCancel（见下方清理）
        except WorkflowCancel:
            task.cancel()
            try:
                await task
            except BaseException:
                pass
            raise

    async def _run_inference(self, node: dict) -> NodeResult:
        """纯推理节点：无工具、无系统提示词，直接一问一答。"""
        model = str(node.get("model") or "").strip()
        if not model:
            return NodeResult(node["id"], ok=False, error="推理节点未配置模型")
        await self._ensure_model(model)
        prompt = render_template(str(node.get("prompt") or ""), self.variables)
        images = resolve_images(node, self.variables)
        # 0.2.3：自动图片继承——未配置 images 且上游是文件输入节点时，
        # 自动把上游产出的图片路径作为图片传入（用户无需手动连 {{上游.output}}）
        if not images:
            images = self._inherit_upstream_images(node)
        # 0.2.4（W8）：仅图片保护——剔除非图片扩展名的本地文件（如音频），
        # 防止被当图片传给视觉模型导致调用失败（用户实测：文件夹混入音频
        # → 第 16 批模型调用失败）。剔除的文件发事件提示，不静默。
        images, dropped = self._keep_image_files(images)
        if dropped:
            self._emit("images_dropped", {"node_id": node["id"],
                                          "dropped": dropped[:10],
                                          "reason": "非图片文件（如音频）不能作为图片输入，已剔除"})
        user_content = prompt or "请处理输入。"
        try:
            text = await self._interruptible_chat(model, user_content, images)
        except WorkflowCancel:
            raise
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
                text = await self._interruptible_chat(model, prompt, [])
            except WorkflowCancel:
                raise
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
        """循环节点：对 items 列表逐项执行分支（{{item}} / {{item_index}} 可用）。

        分支两种形态：
        - 单节点：branch = "node_id"
        - 顺序链：branch = ["id1", "id2", ...] —— 按序执行（如"推理→保存"），
          每步输出可被后续步骤用 {{id.output}} 读取；链的输出 = 最后节点输出。
          （有依赖关系的步骤禁止用 parallel 分支——并发执行会竞态读空。）

        0.2.4（W2/W9）执行模式与等待策略：
        - fail_policy：失败策略 "abort"（默认，某批失败即中止整个循环）/
          "skip"（跳过失败批，输出里该批为 null，继续后续批）/
          "continue"（记录失败但继续，同 skip，别名）
        - max_failures：允许的失败批数上限（0=不允许，达到上限后按
          fail_policy 为 skip/continue 时也中止并报错汇总）
        - wait_ms：批间等待毫秒（0=不等待），大批量推理时给模型/系统喘息，
          也方便用户中途观察；等待期间响应取消标志。
        """
        items = resolve_value(node.get("items", ""), self.variables)
        if not isinstance(items, list):
            return NodeResult(node["id"], ok=False,
                              error=f"loop.items 不是列表：{type(items).__name__}")
        raw_branch = node.get("branch")
        if isinstance(raw_branch, str):
            # 0.2.3：支持逗号分隔的顺序链字符串（前端表单输入形态，如 "ocr,save"）
            parts = [p.strip() for p in raw_branch.split(",") if p.strip()]
            chain_ids = parts if parts else ([raw_branch] if raw_branch else [])
        elif isinstance(raw_branch, list):
            chain_ids = [str(b) for b in raw_branch]
        else:
            chain_ids = []
        chain_nodes = [self.nodes.get(cid) for cid in chain_ids]
        if not chain_nodes or any(n is None for n in chain_nodes):
            return NodeResult(node["id"], ok=False, error="loop.branch 节点不存在")

        # 0.2.4（W2）：失败策略与容忍上限
        fail_policy = str(node.get("fail_policy") or "abort").strip().lower()
        if fail_policy == "continue":
            fail_policy = "skip"  # 别名归一
        if fail_policy not in ("abort", "skip"):
            fail_policy = "abort"
        try:
            max_failures = int(node.get("max_failures") or 0)
        except (TypeError, ValueError):
            max_failures = 0
        # 0.2.4（W9）：批间等待（毫秒）
        try:
            wait_ms = max(0, int(node.get("wait_ms") or 0))
        except (TypeError, ValueError):
            wait_ms = 0

        # 0.2.3：分批（batch_size）——把 items 切成每批 N 个，每轮 {{item}} 是
        # 一个列表（如多张图片），{{item_index}} 是批序号。用于"一次 2-3 张
        # 发给 OCR"场景；不设或 <=1 时保持逐项（{{item}} 为单个元素）。
        try:
            batch_size = int(node.get("batch_size") or 0)
        except (TypeError, ValueError):
            batch_size = 0
        if batch_size > 1:
            batches = [items[i:i + batch_size] for i in range(0, len(items), batch_size)]
        else:
            batches = [[it] for it in items]

        outputs: list[Any] = []
        failed_batches: list[str] = []  # 0.2.4：记录失败批描述
        for idx, batch in enumerate(batches):
            self._check_cancel()
            # 单元素批保持旧行为（{{item}} 为单个元素），多元素批 {{item}} 为列表
            first = batch[0] if len(batch) == 1 else batch
            self.variables["item"] = first
            self.variables["item_index"] = idx
            self.variables["batch"] = batch  # 始终可用的完整批次列表
            # 0.2.3：{{item_name}}（文件名）/ {{item_stem}}（无扩展名），
            # 供文件输出节点按原图名命名（如 {{item_stem}}.md）
            if isinstance(first, str):
                self.variables["item_name"] = Path(first).name
                self.variables["item_stem"] = Path(first).stem
            else:
                self.variables.pop("item_name", None)
                self.variables.pop("item_stem", None)
            last_output: Any = None
            batch_ok = True
            batch_error: str | None = None
            for cnode in chain_nodes:
                r = await self._execute_node(cnode)
                if not r.ok:
                    batch_ok = False
                    batch_error = r.error
                    break
                # 链内中间节点输出写入变量空间，供后续步骤模板引用
                self.variables[str(cnode["id"])] = {"output": r.output}
                last_output = r.output

            if batch_ok:
                outputs.append(last_output)
            else:
                # 0.2.4（W2）：按失败策略处理
                desc = f"第 {idx + 1} 批：{batch_error}"
                if fail_policy == "abort":
                    return NodeResult(node["id"], ok=False, output=outputs,
                                      error=desc)
                # skip：记录失败、输出占位、继续
                failed_batches.append(desc)
                outputs.append(None)
                self._emit("loop_batch_skipped",
                           {"loop_id": node["id"], "batch_index": idx, "error": str(batch_error)})
                if max_failures > 0 and len(failed_batches) >= max_failures:
                    return NodeResult(
                        node["id"], ok=False, output=outputs,
                        error=f"失败批数达到上限（{len(failed_batches)}/{max_failures}）："
                              + "；".join(failed_batches[:3]))

            # 0.2.4（W9）：批间等待（最后一批后不等；等待期间可被取消）
            if wait_ms > 0 and idx < len(batches) - 1:
                waited = 0.0
                step = 0.5
                while waited < wait_ms / 1000.0:
                    self._check_cancel()
                    await asyncio.sleep(min(step, wait_ms / 1000.0 - waited))
                    waited += step

        self.variables.pop("item", None)
        self.variables.pop("item_index", None)
        self.variables.pop("batch", None)
        self.variables.pop("item_name", None)
        self.variables.pop("item_stem", None)
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

    # ---------- 0.2.2：文件输入 / 文件输出节点（纯本地，不联网） ----------
    async def _run_file_input(self, node: dict) -> NodeResult:
        """文件输入节点：读本机路径（单文件或文件夹），输出文件路径列表。

        配置项：
          path（必填）：本机文件或文件夹路径（支持 {{变量}}）
          extensions（可选）：扩展名过滤，如 "jpg, png"（不填 = 不过滤）
          recursive（可选 bool）：文件夹是否递归（默认 False）

        输出：绝对路径列表（供循环节点 {{item}} 逐项消费）。
        """
        raw_path = render_template(str(node.get("path") or ""), self.variables)
        if not raw_path.strip():
            return NodeResult(node["id"], ok=False, error="文件输入节点未配置 path")
        p = Path(raw_path).expanduser()
        if not p.exists():
            return NodeResult(node["id"], ok=False, error=f"路径不存在：{p}")

        exts = {e.strip().lower().lstrip(".") for e in
                str(node.get("extensions") or "").split(",") if e.strip()}
        recursive = bool(node.get("recursive"))

        if p.is_file():
            files = [p]
        else:
            it = p.rglob("*") if recursive else p.iterdir()
            files = [f for f in it if f.is_file()]
        if exts:
            files = [f for f in files if f.suffix.lower().lstrip(".") in exts]
        files.sort(key=lambda f: str(f))
        out = [str(f) for f in files]
        if not out:
            return NodeResult(node["id"], ok=False,
                              error=f"文件夹内没有匹配的文件：{p}（extensions={sorted(exts) or '全部'}）")
        return NodeResult(node["id"], ok=True, output=out)

    async def _run_file_output(self, node: dict) -> NodeResult:
        """文件输出节点：把上游结果按模板写入本机文件（纯本地，不联网）。

        配置项：
          dir（必填）：保存目录（支持 {{变量}}，不存在会自动创建）
          filename（必填）：文件名模板（支持 {{item}} / {{node.output}} / {{item_index}}）
          content（必填）：内容模板（同上；也可用 {{变量}} 引用上游输出）
          encoding（可选）：默认 utf-8

        输出：写入的文件绝对路径（单个）；循环内使用时每轮写一个文件。
        """
        directory = render_template(str(node.get("dir") or ""), self.variables)
        filename = render_template(str(node.get("filename") or ""), self.variables)
        content = render_template(str(node.get("content") or ""), self.variables)
        encoding = str(node.get("encoding") or "utf-8")
        if not directory.strip() or not filename.strip():
            return NodeResult(node["id"], ok=False, error="文件输出节点需配置 dir 与 filename")
        target_dir = Path(directory).expanduser()
        # 防路径穿越：文件名不允许含分隔符/..（目录本身是用户配置的保存目录，放行）
        fname = Path(filename).name
        if not fname or fname != filename or ".." in filename:
            return NodeResult(node["id"], ok=False,
                              error=f"filename 不合法（不允许路径分隔符/..）：{filename!r}")
        try:
            target_dir.mkdir(parents=True, exist_ok=True)
            target = target_dir / fname
            target.write_text(content, encoding=encoding)
        except (OSError, UnicodeEncodeError, LookupError) as e:
            return NodeResult(node["id"], ok=False, error=f"写入失败：{e}")
        return NodeResult(node["id"], ok=True, output=str(target))

    # ---- TS-121（0.3.1 补遗1）：文本输出/变量赋值/代码执行/消息回复 ----
    async def _run_text_output(self, node: dict) -> NodeResult:
        """文本输出节点：按模板渲染文本作为输出（可再经边流转到下游/结束节点）。

        配置项：template（必填，支持 {{node.output}} / {{params.x}} / {{item}}）。
        与文件输出的区别：不落盘，只产出文本变量。"""
        tpl = str(node.get("template") or "")
        if not tpl.strip():
            return NodeResult(node["id"], ok=False, error="文本输出节点缺少 template")
        return NodeResult(node["id"], ok=True, output=render_template(tpl, self.variables))

    # 变量赋值禁止的保留名：会覆盖参数/循环内置变量导致下游错乱（查虫W-2）
    _RESERVED_VAR_NAMES = {"params", "item", "item_index", "batch"}

    async def _run_variable_set(self, node: dict) -> NodeResult:
        """变量赋值节点：把值写入变量空间（{{name}} 可供下游引用）。

        配置项：name（必填，变量名，不含 . 且不能是保留名 params/item/item_index/batch）、
        value（支持 {{...}} 引用；整串 {{x}} 保持原值类型，混合模板渲染为字符串）。
        变量空间与 node 输出空间并列：variables[name] = 值（不包 output 壳）。"""
        name = str(node.get("name") or "").strip()
        if not name or "." in name or "/" in name:
            return NodeResult(node["id"], ok=False, error=f"变量名非法：{name!r}（不能为空或含 . /）")
        if name in self._RESERVED_VAR_NAMES:
            return NodeResult(node["id"], ok=False,
                              error=f"变量名 {name!r} 是保留名（{', '.join(sorted(self._RESERVED_VAR_NAMES))}），请换一个")
        value = resolve_value(node.get("value", ""), self.variables)
        self.variables[name] = value
        return NodeResult(node["id"], ok=True, output=value)

    async def _run_code(self, node: dict) -> NodeResult:
        """代码执行节点：纯本地 exec 一段 Python，不联网（应用铁律）。

        配置项：code（必填 Python 源码）。约定：代码内通过 variables 字典
        读上游（variables['节点id']['output'] / variables['变量名']），
        把结果赋给 result 变量即为本节点输出。

        超时：默认 30s，可用节点字段 timeout_s 调整（1~300）（查虫W-1 修复：
        此前文档承诺超时但未实现，死循环会卡死工作流）。
        注意：Python 线程不可强杀——超时后节点判失败、工作流继续，但失控线程
        仍会占用一个 CPU 核直到自行结束，这是语言层限制，已在节点错误中说明。
        安全提示：代码在本机以本应用权限运行，与 tool 节点同级信任面。"""
        code_src = str(node.get("code") or "")
        if not code_src.strip():
            return NodeResult(node["id"], ok=False, error="代码执行节点缺少 code")
        try:
            timeout_s = min(max(int(node.get("timeout_s") or 30), 1), 300)
        except (TypeError, ValueError):
            timeout_s = 30
        # 给代码一个可读的只读引用 env（同时保留 variables 原引用供高级用法）
        env: dict[str, Any] = {"variables": self.variables, "result": None}
        try:
            compiled = compile(code_src, f"<workflow-node-{node['id']}>", "exec")
            loop = asyncio.get_running_loop()
            # 同步代码丢线程池不阻塞事件循环；超时防死循环卡死工作流
            await asyncio.wait_for(
                loop.run_in_executor(None, exec, compiled, env), timeout=timeout_s)
        except asyncio.TimeoutError:
            return NodeResult(node["id"], ok=False,
                              error=f"代码执行超时（{timeout_s}s）：可能存在死循环。工作流已继续，但失控线程会占用 CPU 直到其自行结束")
        except Exception as e:
            return NodeResult(node["id"], ok=False, error=f"代码执行异常：{type(e).__name__}: {e}")
        return NodeResult(node["id"], ok=True, output=env.get("result"))

    async def _run_reply(self, node: dict) -> NodeResult:
        """消息回复节点：把模板文本作为一条助手回复推给会话前端（纯本地展示）。

        配置项：text（必填，支持 {{...}} 变量）。输出同时写入节点变量供下游引用。"""
        text = render_template(str(node.get("text") or ""), self.variables)
        if not text.strip():
            return NodeResult(node["id"], ok=False, error="消息回复节点缺少 text")
        self._emit("workflow_reply", {"node_id": node["id"], "text": text})
        return NodeResult(node["id"], ok=True, output=text)

    async def _run_file_read(self, node: dict) -> NodeResult:
        """文件读取节点：批量读取本机文件内容，拼接成一段文本输出（纯本地，不联网）。

        配置项：
          path（必填）：单个文件，或文件夹（读取其内文件）；支持 {{变量}}
          extensions（可选）：扩展名过滤，如 "md, txt"
          separator（可选）：文件间分隔模板，默认带文件名标题；支持 {{filename}}
          max_bytes（可选）：单文件读取上限，默认 200000（防超大文件撑爆上下文）

        输出：拼接后的文本（供推理/分析节点消费）。
        """
        raw_path = render_template(str(node.get("path") or ""), self.variables)
        if not raw_path.strip():
            return NodeResult(node["id"], ok=False, error="文件读取节点未配置 path")
        p = Path(raw_path).expanduser()
        if not p.exists():
            return NodeResult(node["id"], ok=False, error=f"路径不存在：{p}")

        exts = {e.strip().lower().lstrip(".") for e in
                str(node.get("extensions") or "").split(",") if e.strip()}
        if p.is_file():
            files = [p]
        else:
            files = [f for f in p.iterdir() if f.is_file()]
            if exts:
                files = [f for f in files if f.suffix.lower().lstrip(".") in exts]
            files.sort(key=lambda f: str(f))
        if not files:
            return NodeResult(node["id"], ok=False,
                              error=f"没有可读的文件：{p}（extensions={sorted(exts) or '全部'}）")

        try:
            max_bytes = int(node.get("max_bytes") or 200000)
        except (TypeError, ValueError):
            max_bytes = 200000
        sep_tpl = node.get("separator")

        chunks: list[str] = []
        for f in files:
            try:
                text = f.read_bytes()[:max_bytes].decode("utf-8", errors="replace")
            except OSError as e:
                return NodeResult(node["id"], ok=False, error=f"读取失败 {f.name}：{e.strerror}")
            if sep_tpl is not None:
                header = render_template(str(sep_tpl), {**self.variables, "filename": f.name})
                chunks.append(f"{header}\n{text}")
            else:
                chunks.append(f"=== {f.name} ===\n{text}")
        return NodeResult(node["id"], ok=True, output="\n\n".join(chunks))

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
            elif ntype == "file_input":
                res = await self._run_file_input(node)
            elif ntype == "file_output":
                res = await self._run_file_output(node)
            elif ntype == "file_read":
                res = await self._run_file_read(node)
            elif ntype == "text_output":
                res = await self._run_text_output(node)
            elif ntype == "variable_set":
                res = await self._run_variable_set(node)
            elif ntype == "code":
                res = await self._run_code(node)
            elif ntype == "reply":
                res = await self._run_reply(node)
            elif ntype in ("start", "end"):
                res = NodeResult(node["id"], ok=True, output=None)
            elif ntype == "condition":
                # 0.2.4（W5）：条件节点允许放在循环/并行体内，此时作为
                # "条件求值器"执行——输出判定结果（"true"/"false" 或动态分支名），
                # 写入变量空间供链内下游节点 {{node_id.output}} 引用。
                # 路由（when 边）仅主链生效；循环体内不做分支跳转（循环链为顺序执行）。
                res, _when = await self._run_condition(node)
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
