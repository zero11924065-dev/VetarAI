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

import re
from typing import Any

NODE_TYPES = ("start", "inference", "tool", "condition", "parallel", "loop",
              "approval", "file_input", "file_output", "file_read",
              # TS-121（0.3.1 补遗1）：文本输出/变量赋值/代码执行/消息回复
              "text_output", "variable_set", "code", "reply", "end")

# 推理节点：纯模型调用
CONDITION_OPERATORS = ("contains", "not_contains", "equals", "starts_with", "regex", "empty", "not_empty")


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
