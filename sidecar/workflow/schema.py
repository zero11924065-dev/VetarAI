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
"""0.2.1（TS-119）：工作流定义校验与默认结构。

定义结构（前端编辑器产出、引擎消费的唯一契约）：
{
  "nodes": [
    {"id": "n1", "type": "start", "label": "开始"},
    {"id": "n2", "type": "inference", "label": "识别图片",
     "model": "glm-ocr:latest", "prompt": "...", "input_key": "images",
     "retry": 1},
    {"id": "n3", "type": "condition", "label": "是否包含文字",
     "match": {"variable": "n2.output", "operator": "contains", "value": "钱"}},
    {"id": "n4", "type": "parallel", "label": "并行处理", "branches": ["n5", "n6"]},
    {"id": "n7", "type": "approval", "label": "人工确认"},
    {"id": "n8", "type": "end", "label": "结束", "output": "{{n2.output}}"}
  ],
  "edges": [
    {"from": "n1", "to": "n2"},
    {"from": "n3", "to": "n4", "when": "true"},
    {"from": "n3", "to": "n8", "when": "false"}
  ],
  "params": {"input_dir": ""}
}
"""
from __future__ import annotations

from typing import Any

NODE_TYPES = ("start", "inference", "tool", "condition", "parallel", "loop",
              "approval", "file_input", "file_output", "file_read",
              # TS-121（0.3.1 补遗1）：文本输出/变量赋值/代码执行/消息回复
              "text_output", "variable_set", "code", "reply", "end")

# 推理节点：纯模型调用
CONDITION_OPERATORS = ("contains", "not_contains", "equals", "starts_with", "regex", "empty", "not_empty")

# ── 0.4.28（REQ-WF-014）：节点字段说明表（get_node_schema 读面数据源）──
# 每种节点类型一张字段表：{"name", "required", "type", "desc"}。
# 字段清单以 engine.py 各 _run_* 实际读取的键为准（写 definition 前 Agent 查这张表，
# 不再臆造字段名）。⛔ 键集必须与 NODE_TYPES 完全一致——漂移由测试守护
# （断言 set(NODE_FIELD_SPECS) == set(NODE_TYPES)），加节点类型时必须同步补表。
# 通用字段（不入表）：label（显示名）与 retry（失败重试次数，引擎对全类型生效）。
NODE_FIELD_SPECS: dict[str, list[dict[str, Any]]] = {
    "start": [],
    "inference": [
        {"name": "model", "required": True, "type": "str",
         "desc": "模型名（如 qwen3.8:latest）。纯调用：无工具、无系统提示词。"},
        {"name": "prompt", "required": False, "type": "str",
         "desc": "提示词，支持 {{node.output}} / {{params.x}} / {{item}} 模板；缺省发「请处理输入。」"},
        {"name": "images", "required": False, "type": "str | list[str]",
         "desc": "图片来源：变量引用（如 {{fi.output}}）或路径/data URI 列表；"
                 "未配置时自动继承直接上游 file_input 节点或循环上下文的图片。"},
        {"name": "retry", "required": False, "type": "int",
         "desc": "失败重试次数（默认 0，退避重试）。通用字段，所有节点可用。"},
        {"name": "timeout_s", "required": False, "type": "number",
         "desc": "0.4.28 新增：本节点模型调用的读超时（秒，10~7200）。长任务（如大模型处理超长文本）"
                 "可设大值（如 1200=20 分钟）；缺省用全局「非流式读超时」（设置→推理，默认 300s）。"},
    ],
    "tool": [
        {"name": "tool", "required": True, "type": "str",
         "desc": "注册表工具名（如写文件/读文件/列目录等）。"},
        {"name": "args", "required": False, "type": "dict",
         "desc": "工具参数；每个值支持 {{变量}} 引用。"},
    ],
    "condition": [
        {"name": "match", "required": False, "type": "dict",
         "desc": "静态匹配：{variable, operator, value}；operator 取 " +
                 "/".join(CONDITION_OPERATORS) + "（empty/not_empty 不需要 value）。"},
        {"name": "model", "required": False, "type": "str",
         "desc": "配置后走动态裁判：纯调用模型判定，输出首行即分支名（when 标签）。"},
        {"name": "prompt", "required": False, "type": "str",
         "desc": "动态裁判提示词（支持模板）；缺省「请判断并只输出分支名。」"},
        {"name": "timeout_s", "required": False, "type": "number",
         "desc": "0.4.28 新增：动态裁判模型调用的读超时（秒，10~7200）；仅配置了 model 时生效，"
                 "缺省用全局「非流式读超时」（默认 300s）。"},
    ],
    "parallel": [
        {"name": "branches", "required": True, "type": "list[str]",
         "desc": "并行分支：节点 id 列表（单节点粒度），各分支并发执行，输出收集为列表。"},
    ],
    "loop": [
        {"name": "items", "required": True, "type": "str | list",
         "desc": "要循环的列表：直接给数组或变量引用（如 {{fi.output}}）；{{item}} 逐项可用。"},
        {"name": "branch", "required": True, "type": "str | list[str]",
         "desc": "循环体：单节点 id、逗号分隔链（\"ocr,save\"）或 id 数组（顺序链，"
                 "每步输出可被后续步骤用 {{id.output}} 读取）。"},
        {"name": "fail_policy", "required": False, "type": "str",
         "desc": "失败策略：abort（默认，某批失败即中止）/ skip（跳过失败批继续，continue 为别名）。"},
        {"name": "max_failures", "required": False, "type": "int",
         "desc": "允许的失败批数上限（默认 0=不限制；达到上限即使 skip 也中止并报错汇总）。"},
        {"name": "wait_ms", "required": False, "type": "int",
         "desc": "批间等待毫秒（默认 0）；大批量推理时给模型/系统喘息，等待期间响应停止。"},
        {"name": "batch_size", "required": False, "type": "int",
         "desc": "分批大小（>1 时每轮 {{item}} 是一批列表，{{batch}} 恒为当批列表；"
                 "用于「一次 2-3 张图发给 OCR」场景）。"},
    ],
    "approval": [
        {"name": "message", "required": False, "type": "str",
         "desc": "给审批人的提示语（支持模板）；节点挂起等待人工决议，超时不限。"},
    ],
    "file_input": [
        {"name": "path", "required": True, "type": "str",
         "desc": "本机文件或文件夹路径（支持 {{变量}}）；输出文件路径列表。"},
        {"name": "extensions", "required": False, "type": "str",
         "desc": "扩展名过滤，逗号分隔（如 \"jpg, png\"）；不填=不过滤。"},
        {"name": "recursive", "required": False, "type": "bool",
         "desc": "文件夹是否递归遍历（默认 false）。"},
    ],
    "file_output": [
        {"name": "dir", "required": True, "type": "str",
         "desc": "保存目录（支持模板，不存在自动创建）。"},
        {"name": "filename", "required": True, "type": "str",
         "desc": "文件名模板（支持 {{item}} / {{item_stem}} / {{node.output}} 等）；"
                 "不允许路径分隔符与 ..（防穿越）。"},
        {"name": "content", "required": True, "type": "str",
         "desc": "写入内容模板（支持 {{变量}} 引用上游输出）。"},
        {"name": "encoding", "required": False, "type": "str",
         "desc": "文件编码（默认 utf-8）。"},
    ],
    "file_read": [
        {"name": "path", "required": True, "type": "str",
         "desc": "单个文件或文件夹（读其内文件，支持模板）；pdf/docx/xlsx/pptx 等走解析器。"},
        {"name": "extensions", "required": False, "type": "str",
         "desc": "文件夹模式下的扩展名过滤（如 \"md, txt\"）。"},
        {"name": "separator", "required": False, "type": "str",
         "desc": "文件间分隔模板（支持 {{filename}}）；缺省带 === 文件名 === 标题。"},
        {"name": "max_bytes", "required": False, "type": "int",
         "desc": "单文件输出文本上限（默认 200000，防超大文件撑爆上下文）；"
                 "二进制文档为整读后解析，另有 20MB 源文件字节上限。"},
    ],
    "text_output": [
        {"name": "template", "required": True, "type": "str",
         "desc": "内容模板（支持 {{node.output}} / {{params.x}} / {{item}}）；不落盘，只产出文本。"},
    ],
    "variable_set": [
        {"name": "name", "required": True, "type": "str",
         "desc": "变量名：不能含 . 或 /，且不能用保留名 params/item/item_index/batch。"},
        {"name": "value", "required": False, "type": "any",
         "desc": "变量值；整串 {{x}} 保持原值类型，混合模板渲染为字符串。"},
    ],
    "code": [
        {"name": "code", "required": True, "type": "str",
         "desc": "Python 源码（纯本地执行，不联网）；经 variables 字典读上游，结果赋给 result 变量。"},
        {"name": "timeout_s", "required": False, "type": "int",
         "desc": "执行超时秒数（1~300，默认 30）；超时节点判失败、工作流继续，"
                 "但失控线程仍会占 CPU 直到自行结束（Python 线程不可强杀）。"},
    ],
    "reply": [
        {"name": "text", "required": True, "type": "str",
         "desc": "回复文本（支持模板）；作为一条助手回复推给会话前端，同时写入节点变量。"},
    ],
    "end": [
        {"name": "output", "required": False, "type": "str",
         "desc": "最终结果引用（如 {{n2.output}}）；不填则工作流结果为结束节点自身输出。"},
    ],
}


def default_start_definition() -> dict[str, Any]:
    """新建工作流的初始定义：仅一个开始节点。"""
    return {
        "nodes": [{"id": "start", "type": "start", "label": "开始"}],
        "edges": [],
        "params": {},
    }


def _node_errors(node: dict, idx: int) -> list[str]:
    errs: list[str] = []
    if not node.get("id"):
        errs.append(f"节点[{idx}] 缺少 id")
    ntype = node.get("type")
    if ntype not in NODE_TYPES:
        errs.append(f"节点[{idx}] 类型无效：{ntype!r}（应为 {NODE_TYPES}）")
        return errs
    if ntype == "inference":
        if not str(node.get("model") or "").strip():
            errs.append(f"节点[{idx}]（推理）缺少 model")
    # 0.4.28（REQ-WF-015）：inference / 条件裁判的节点级读超时 timeout_s。
    # 走 connector.chat 的两类节点都接受该可选字段；越界/非数值给清晰错误。
    # 本函数 strict 与非 strict 都会被调用，故两种保存路径同样受校。
    if ntype in ("inference", "condition"):
        ts = node.get("timeout_s")
        if ts is not None:
            _kind = "推理" if ntype == "inference" else "条件"
            if isinstance(ts, bool) or not isinstance(ts, (int, float)):
                errs.append(f"节点[{idx}]（{_kind}）timeout_s 必须是数值（秒），"
                            f"实为 {type(ts).__name__}：{ts!r}")
            elif not (10 <= ts <= 7200):
                errs.append(f"节点[{idx}]（{_kind}）timeout_s 越界：{ts}（合法范围 10~7200 秒）")
    if ntype == "condition":
        match = node.get("match") or {}
        op = match.get("operator")
        if op not in CONDITION_OPERATORS:
            errs.append(f"节点[{idx}]（条件）operator 无效：{op!r}（应为 {CONDITION_OPERATORS}）")
        if op not in ("empty", "not_empty") and not str(match.get("value", "")).strip() \
                and not str(node.get("model") or "").strip():
            # 静态匹配需要 value；动态裁判（有 model）不需要
            errs.append(f"节点[{idx}]（条件）静态匹配缺少 value，或需配置 model 走动态裁判")
    if ntype == "approval":
        # 审批节点无必填项，但建议有 label
        pass
    if ntype == "file_input":
        if not str(node.get("path") or "").strip():
            errs.append(f"节点[{idx}]（文件输入）缺少 path")
    if ntype == "file_read":
        if not str(node.get("path") or "").strip():
            errs.append(f"节点[{idx}]（文件读取）缺少 path")
    if ntype == "file_output":
        if not str(node.get("dir") or "").strip():
            errs.append(f"节点[{idx}]（文件输出）缺少 dir")
        if not str(node.get("filename") or "").strip():
            errs.append(f"节点[{idx}]（文件输出）缺少 filename")
    # TS-121（0.3.1 补遗1）：4 个新节点的必填校验
    if ntype == "text_output":
        if not str(node.get("template") or "").strip():
            errs.append(f"节点[{idx}]（文本输出）缺少 template（内容模板）")
    if ntype == "variable_set":
        name = str(node.get("name") or "").strip()
        if not name:
            errs.append(f"节点[{idx}]（变量赋值）缺少变量名")
        elif "." in name or "/" in name:
            errs.append(f"节点[{idx}]（变量赋值）变量名不能含 . 或 /：{name!r}")
        elif name in ("params", "item", "item_index", "batch"):
            errs.append(f"节点[{idx}]（变量赋值）{name!r} 是保留名，请换一个变量名")
    if ntype == "code":
        if not str(node.get("code") or "").strip():
            errs.append(f"节点[{idx}]（代码执行）缺少 code")
    if ntype == "reply":
        if not str(node.get("text") or "").strip():
            errs.append(f"节点[{idx}]（消息回复）缺少 text")
    return errs


def validate_definition(definition: dict[str, Any], *, strict: bool = True) -> list[str]:
    """校验工作流定义，返回错误列表（空 = 合法）。

    校验项：
    1. nodes/edges 为列表
    2. 每个节点类型合法 + 必填字段
    3. （仅 strict）恰好一个 start、至少一个 end
    4. edges 引用的节点都存在
    5. 节点 id 唯一
    6. （仅 strict）start 可达所有节点（无孤岛节点）

    0.2.1 修正：创建/保存用 strict=False——编辑中的半成品工作流（如只有
    开始节点）必须能存；完整性（开始/结束/连通）只在运行前把关（strict=True）。
    """
    errs: list[str] = []
    if not isinstance(definition, dict):
        return ["定义必须是 JSON 对象"]
    nodes = definition.get("nodes")
    edges = definition.get("edges")
    if not isinstance(nodes, list) or not nodes:
        return ["nodes 必须是非空列表"]
    if not isinstance(edges, list):
        return ["edges 必须是列表"]

    ids: set[str] = set()
    for i, node in enumerate(nodes):
        if not isinstance(node, dict):
            errs.append(f"节点[{i}] 必须是对象")
            continue
        nid = str(node.get("id") or "")
        if nid and nid in ids:
            errs.append(f"节点 id 重复：{nid}")
        ids.add(nid)
        errs.extend(_node_errors(node, i))

    start_count = sum(1 for n in nodes if isinstance(n, dict) and n.get("type") == "start")
    end_count = sum(1 for n in nodes if isinstance(n, dict) and n.get("type") == "end")
    if strict:
        if start_count != 1:
            errs.append(f"必须恰好有一个开始节点（当前 {start_count} 个）")
        if end_count < 1:
            errs.append("必须至少有一个结束节点")

    for i, edge in enumerate(edges):
        if not isinstance(edge, dict):
            errs.append(f"边[{i}] 必须是对象")
            continue
        if str(edge.get("from") or "") not in ids:
            errs.append(f"边[{i}] 起点不存在：{edge.get('from')!r}")
        if str(edge.get("to") or "") not in ids:
            errs.append(f"边[{i}] 终点不存在：{edge.get('to')!r}")

    # 孤岛检测：从 start 出发 BFS，未访问到的节点报错（仅严格模式）
    if strict:
        node_map = {str(n.get("id")): n for n in nodes if isinstance(n, dict) and n.get("id")}
        start_nodes = [n for n in nodes if isinstance(n, dict) and n.get("type") == "start"]
        if start_nodes and node_map:
            adj: dict[str, list[str]] = {nid: [] for nid in node_map}
            for edge in edges:
                if isinstance(edge, dict):
                    f, t = str(edge.get("from") or ""), str(edge.get("to") or "")
                    if f in adj and t in node_map:
                        adj[f].append(t)
            # parallel 的 branches 与 loop 的 branch 也算可达边（隐式调用，不画连线）
            for nid, node in node_map.items():
                if node.get("type") == "parallel":
                    for b in (node.get("branches") or []):
                        if str(b) in node_map:
                            adj[nid].append(str(b))
                if node.get("type") == "loop":
                    b = node.get("branch")
                    if isinstance(b, str):
                        # 0.2.4（W4 修复）：支持逗号分隔顺序链字符串（引擎 0.2.3 起支持，
                        # 如 "ocr,save"）。此前只认整串==单个节点 ID → 循环体节点被误判
                        # "未连通"，用户被迫显式连线。
                        parts = [p.strip() for p in b.split(",") if p.strip()]
                        for p in (parts if parts else ([b] if b else [])):
                            if p in node_map:
                                adj[nid].append(p)
                    elif isinstance(b, list):
                        # 顺序链：链内全部节点可达
                        for bb in b:
                            if str(bb) in node_map:
                                adj[nid].append(str(bb))
            visited: set[str] = set()
            queue = [str(start_nodes[0].get("id"))]
            while queue:
                cur = queue.pop(0)
                if cur in visited:
                    continue
                visited.add(cur)
                queue.extend(adj.get(cur, []))
            for nid in node_map:
                if nid not in visited:
                    errs.append(f"节点「{node_map[nid].get('label') or nid}」未与开始节点连通")
    return errs
