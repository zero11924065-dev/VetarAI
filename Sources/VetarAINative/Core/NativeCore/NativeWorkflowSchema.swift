//
//  NativeWorkflowSchema.swift
//  VetarAI — Local-first multi-agent orchestration application
//  Copyright (C) 2026 zero11924065-dev
//
//  This file is part of VetarAI.
//
//  VetarAI is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  VetarAI is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with VetarAI. If not, see <https://www.gnu.org/licenses/>.
//

//  逐字移植 subagent/sidecar/workflow/schema.py（⛔ 只读行为规格源）：
//    · NODE_TYPES 15 类 / CONDITION_OPERATORS 7 种（顺序保真——校验文案里
//      以 Python tuple repr 形态整串出现，双跑对照逐字比对）
//    · validate_definition(strict:)：创建/保存 strict=false（半成品可存），
//      运行 strict=true（完整性把关）——0.2.1 修正口径（W4 契约发现 #2）
//    · 错误文案逐字（含 Python repr/str 渲染与 f-string 细节）
//    · REQ-WF-016（0.7.4 判缺陷修）：condition 节点配了 model（动态裁判）时跳过
//      operator 必填校验（引擎 runCondition 同款口径）；无 model 无 operator 仍报错
//
//  已知微差（不影响任何真实输入路径，代码内随点标注）：
//    · match 为「真值非字典」（如字符串）时 Python 会 AttributeError 崩溃（端点 500）；
//      原生按空字典处理（不崩溃，给出 operator 校验错）——面板/引擎永不产出该形态。
//

import Foundation

// MARK: - Python 文本语义助手（schema/engine 共用，本模块唯一出处）

enum WFText {

    /// Python 真值判定：None/False/0/0.0/""/[]/{} → false。
    static func truthy(_ v: JSONValue?) -> Bool {
        guard let v else { return false }
        switch v {
        case .null: return false
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .double(let d): return d != 0
        case .string(let s): return !s.isEmpty
        case .array(let a): return !a.isEmpty
        case .object(let o): return !o.isEmpty
        }
    }

    /// `str(x or "")`：假值 → ""；真值 → str(x)。
    static func strOrEmpty(_ v: JSONValue?) -> String {
        guard truthy(v), let v else { return "" }
        return pyStr(v)
    }

    /// Python str(value)：None/True/False/数值/字符串原样；list/dict 走 repr 容器形态。
    static func pyStr(_ v: JSONValue) -> String {
        switch v {
        case .null: return "None"
        case .bool(let b): return b ? "True" : "False"
        case .int(let i): return String(i)
        case .double(let d):
            // Python str(float)：nan/inf 小写（区别于 json.dumps 的 NaN/Infinity）
            if d.isNaN { return "nan" }
            if d.isInfinite { return d > 0 ? "inf" : "-inf" }
            return NativeJSONWriter.pyFloatRepr(d)   // str(float)==repr(float)
        case .string(let s): return s
        case .array(let a): return "[" + a.map { pyRepr($0) }.joined(separator: ", ") + "]"
        case .object(let o):
            // Python dict 保插入序；JSONValue 无序 → 字典序（确定性优先，同 NativeJSONWriter 先例）
            return "{" + o.keys.sorted().map { "\(pyRepr(.string($0))): \(pyRepr(o[$0]!))" }
                .joined(separator: ", ") + "}"
        }
    }

    /// Python repr(value)。
    static func pyRepr(_ v: JSONValue) -> String {
        if case .string(let s) = v { return pyReprString(s) }
        return pyStr(v)
    }

    /// Python repr(str)：单引号优先；含单引号且不含双引号 → 双引号；反斜杠/控制符转义。
    static func pyReprString(_ s: String) -> String {
        let hasSingle = s.contains("'")
        let hasDouble = s.contains("\"")
        let quote: Character = (hasSingle && !hasDouble) ? "\"" : "'"
        var out = String(quote)
        for ch in s {
            if ch == "\\" { out += "\\\\"; continue }
            if ch == quote { out += "\\\(quote)"; continue }
            switch ch {
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if ch.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
                    for sc in ch.unicodeScalars { out += String(format: "\\x%02x", sc.value) }
                } else {
                    out.append(ch)
                }
            }
        }
        out.append(quote)
        return out
    }

    /// Python type(v).__name__。
    static func pyTypeName(_ v: JSONValue) -> String {
        switch v {
        case .null: return "NoneType"
        case .bool: return "bool"
        case .int: return "int"
        case .double: return "float"
        case .string: return "str"
        case .array: return "list"
        case .object: return "dict"
        }
    }

    /// 字符串列表的 Python list repr（['jpg', 'png']）——sorted(exts) 渲染用。
    static func pyListRepr(_ items: [String]) -> String {
        "[" + items.map { pyReprString($0) }.joined(separator: ", ") + "]"
    }

    /// 字符串数组的 Python tuple repr（('start', 'inference', ...)）——校验文案内嵌。
    static func pyTupleRepr(_ items: [String]) -> String {
        "(" + items.map { pyReprString($0) }.joined(separator: ", ") + ")"
    }

    /// Python str[:n]（按码点切片；Swift unicodeScalars 恒为合法标量，无半代理对风险）。
    static func pyPrefix(_ s: String, _ n: Int) -> String {
        guard s.unicodeScalars.count > n else { return s }
        return String(s.unicodeScalars.prefix(n))
    }
}

// MARK: - 工作流定义校验（schema.py validate_definition 逐字移植）

public enum NativeWorkflowSchema {

    /// NODE_TYPES（顺序 = Python tuple 顺序；校验文案整串内嵌）。
    public static let nodeTypes: [String] = [
        "start", "inference", "tool", "condition", "parallel", "loop",
        "approval", "file_input", "file_output", "file_read",
        "text_output", "variable_set", "code", "reply", "end",
    ]

    public static let conditionOperators: [String] = [
        "contains", "not_contains", "equals", "starts_with", "regex", "empty", "not_empty",
    ]

    /// default_start_definition()：仅一个开始节点。
    public static func defaultStartDefinition() -> JSONValue {
        .object([
            "nodes": .array([.object(["id": .string("start"), "type": .string("start"),
                                      "label": .string("开始")])]),
            "edges": .array([]),
            "params": .object([:]),
        ])
    }

    /// validate_definition(definition, strict:) → 错误列表（空 = 合法）。文案逐字。
    public static func validateDefinition(_ definition: JSONValue, strict: Bool) -> [String] {
        var errs: [String] = []
        guard case .object(let def) = definition else {
            return ["定义必须是 JSON 对象"]
        }
        let nodes = def["nodes"]
        let edges = def["edges"]
        guard case .array(let nodeList) = nodes, !nodeList.isEmpty else {
            return ["nodes 必须是非空列表"]
        }
        guard case .array(let edgeList) = edges else {
            return ["edges 必须是列表"]
        }

        var ids = Set<String>()
        for (i, node) in nodeList.enumerated() {
            guard case .object(let nodeObj) = node else {
                errs.append("节点[\(i)] 必须是对象")
                continue
            }
            let nid = WFText.strOrEmpty(nodeObj["id"])
            if !nid.isEmpty && ids.contains(nid) {
                errs.append("节点 id 重复：\(nid)")
            }
            ids.insert(nid)
            errs.append(contentsOf: nodeErrors(nodeObj, idx: i))
        }

        let startCount = nodeList.filter {
            if case .object(let o) = $0 { return o["type"] == .string("start") }
            return false
        }.count
        let endCount = nodeList.filter {
            if case .object(let o) = $0 { return o["type"] == .string("end") }
            return false
        }.count
        if strict {
            if startCount != 1 {
                errs.append("必须恰好有一个开始节点（当前 \(startCount) 个）")
            }
            if endCount < 1 {
                errs.append("必须至少有一个结束节点")
            }
        }

        for (i, edge) in edgeList.enumerated() {
            guard case .object(let e) = edge else {
                errs.append("边[\(i)] 必须是对象")
                continue
            }
            if !ids.contains(WFText.strOrEmpty(e["from"])) {
                errs.append("边[\(i)] 起点不存在：\(WFText.pyRepr(e["from"] ?? .null))")
            }
            if !ids.contains(WFText.strOrEmpty(e["to"])) {
                errs.append("边[\(i)] 终点不存在：\(WFText.pyRepr(e["to"] ?? .null))")
            }
        }

        // 孤岛检测：从 start 出发 BFS，未访问到的节点报错（仅严格模式）
        if strict {
            var nodeMap: [String: [String: JSONValue]] = [:]
            var nodeOrder: [String] = []   // Python dict 插入序 = 定义序（报错顺序保真）
            for n in nodeList {
                guard case .object(let o) = n else { continue }
                let nid = WFText.strOrEmpty(o["id"])
                if !nid.isEmpty {
                    if nodeMap[nid] == nil { nodeOrder.append(nid) }
                    nodeMap[nid] = o
                }
            }
            let startNodes = nodeList.compactMap { n -> [String: JSONValue]? in
                guard case .object(let o) = n, o["type"] == .string("start") else { return nil }
                return o
            }
            if !startNodes.isEmpty && !nodeMap.isEmpty {
                var adj: [String: [String]] = nodeMap.mapValues { _ in [] }
                for edge in edgeList {
                    guard case .object(let e) = edge else { continue }
                    let f = WFText.strOrEmpty(e["from"]), t = WFText.strOrEmpty(e["to"])
                    if adj[f] != nil && nodeMap[t] != nil { adj[f]!.append(t) }
                }
                // parallel.branches 与 loop.branch 算可达边（隐式调用，不画连线）
                for (nid, node) in nodeMap {
                    if node["type"] == .string("parallel") {
                        if case .array(let branches) = node["branches"] {
                            for b in branches {
                                let bs = WFText.pyStr(b)
                                if nodeMap[bs] != nil { adj[nid]!.append(bs) }
                            }
                        }
                    }
                    if node["type"] == .string("loop") {
                        switch node["branch"] {
                        case .string(let b):
                            // 0.2.4（W4 修复）：逗号分隔顺序链字符串
                            let parts = b.split(separator: ",").map {
                                $0.trimmingCharacters(in: .whitespaces)
                            }.filter { !$0.isEmpty }
                            for p in (parts.isEmpty ? (b.isEmpty ? [] : [b]) : parts) {
                                if nodeMap[p] != nil { adj[nid]!.append(p) }
                            }
                        case .array(let arr):
                            for bb in arr {
                                let s = WFText.pyStr(bb)
                                if nodeMap[s] != nil { adj[nid]!.append(s) }
                            }
                        default: break
                        }
                    }
                }
                var visited = Set<String>()
                var queue = [WFText.strOrEmpty(startNodes[0]["id"])]
                while !queue.isEmpty {
                    let cur = queue.removeFirst()
                    if visited.contains(cur) { continue }
                    visited.insert(cur)
                    queue.append(contentsOf: adj[cur] ?? [])
                }
                for nid in nodeOrder {   // Python dict 序（定义序）
                    if !visited.contains(nid) {
                        let label = WFText.strOrEmpty(nodeMap[nid]?["label"])
                        errs.append("节点「\(label.isEmpty ? nid : label)」未与开始节点连通")
                    }
                }
            }
        }
        return errs
    }

    /// _node_errors(node, idx)（strict 与非 strict 共用——timeout_s 两路同校，REQ-WF-015）。
    private static func nodeErrors(_ node: [String: JSONValue], idx: Int) -> [String] {
        var errs: [String] = []
        if !WFText.truthy(node["id"]) {
            errs.append("节点[\(idx)] 缺少 id")
        }
        let ntypeValue = node["type"] ?? .null
        guard case .string(let ntype) = ntypeValue, nodeTypes.contains(ntype) else {
            errs.append("节点[\(idx)] 类型无效：\(WFText.pyRepr(ntypeValue))"
                        + "（应为 \(WFText.pyTupleRepr(nodeTypes))）")
            return errs
        }
        if ntype == "inference" {
            if WFText.strOrEmpty(node["model"]).trimmingCharacters(in: .whitespaces).isEmpty {
                errs.append("节点[\(idx)]（推理）缺少 model")
            }
        }
        // 0.4.28（REQ-WF-015）：inference / 条件裁判的节点级读超时 timeout_s
        if ntype == "inference" || ntype == "condition" {
            if let ts = node["timeout_s"], ts != .null {
                let kind = ntype == "inference" ? "推理" : "条件"
                switch ts {
                case .bool:
                    errs.append("节点[\(idx)]（\(kind)）timeout_s 必须是数值（秒），"
                                + "实为 bool：\(WFText.pyRepr(ts))")
                case .int(let i):
                    if !(10...7200).contains(i) {
                        errs.append("节点[\(idx)]（\(kind)）timeout_s 越界：\(i)（合法范围 10~7200 秒）")
                    }
                case .double(let d):
                    if !(10...7200).contains(d) {
                        errs.append("节点[\(idx)]（\(kind)）timeout_s 越界："
                                    + "\(NativeJSONWriter.pyFloatRepr(d))（合法范围 10~7200 秒）")
                    }
                default:
                    errs.append("节点[\(idx)]（\(kind)）timeout_s 必须是数值（秒），"
                                + "实为 \(WFText.pyTypeName(ts))：\(WFText.pyRepr(ts))")
                }
            }
        }
        if ntype == "condition" {
            // match 真值非字典时 Python 会 AttributeError（端点 500）；原生按空字典处理
            let match = node["match"]?.object ?? [:]
            // REQ-WF-016（0.7.4 判缺陷修，业主拍板）：节点配了 model 走动态裁判时
            // 跳过 operator 必填校验——引擎 runCondition 中 model 非空即走裁判模型路径，
            // 根本不读 match.operator（旧 Python schema.py:207-211 强制必填是缺陷）；
            // 无 model 时 operator 仍是静态匹配的唯一判定，必填校验保留。
            let hasJudgeModel = !WFText.strOrEmpty(node["model"])
                .trimmingCharacters(in: .whitespaces).isEmpty
            let opValue = match["operator"] ?? .null
            let op = opValue.string
            if !hasJudgeModel {
                let opValid = op.map { conditionOperators.contains($0) } ?? false
                if !opValid {
                    errs.append("节点[\(idx)]（条件）operator 无效：\(WFText.pyRepr(opValue))"
                                + "（应为 \(WFText.pyTupleRepr(conditionOperators))）")
                }
            }
            let valueStr: String = {
                guard let v = match["value"] else { return "" }
                return WFText.pyStr(v)   // str(None)="None" 怪癖保留（null 不判空）
            }()
            if !(op == "empty" || op == "not_empty")
                && valueStr.trimmingCharacters(in: .whitespaces).isEmpty
                && WFText.strOrEmpty(node["model"]).trimmingCharacters(in: .whitespaces).isEmpty {
                errs.append("节点[\(idx)]（条件）静态匹配缺少 value，或需配置 model 走动态裁判")
            }
        }
        if ntype == "approval" {
            // 审批节点无必填项，但建议有 label（schema.py 注释口径）
        }
        if ntype == "file_input" {
            if WFText.strOrEmpty(node["path"]).trimmingCharacters(in: .whitespaces).isEmpty {
                errs.append("节点[\(idx)]（文件输入）缺少 path")
            }
        }
        if ntype == "file_read" {
            if WFText.strOrEmpty(node["path"]).trimmingCharacters(in: .whitespaces).isEmpty {
                errs.append("节点[\(idx)]（文件读取）缺少 path")
            }
        }
        if ntype == "file_output" {
            if WFText.strOrEmpty(node["dir"]).trimmingCharacters(in: .whitespaces).isEmpty {
                errs.append("节点[\(idx)]（文件输出）缺少 dir")
            }
            if WFText.strOrEmpty(node["filename"]).trimmingCharacters(in: .whitespaces).isEmpty {
                errs.append("节点[\(idx)]（文件输出）缺少 filename")
            }
        }
        // TS-121（0.3.1 补遗1）：4 个新节点的必填校验
        if ntype == "text_output" {
            if WFText.strOrEmpty(node["template"]).trimmingCharacters(in: .whitespaces).isEmpty {
                errs.append("节点[\(idx)]（文本输出）缺少 template（内容模板）")
            }
        }
        if ntype == "variable_set" {
            let name = WFText.strOrEmpty(node["name"]).trimmingCharacters(in: .whitespaces)
            if name.isEmpty {
                errs.append("节点[\(idx)]（变量赋值）缺少变量名")
            } else if name.contains(".") || name.contains("/") {
                errs.append("节点[\(idx)]（变量赋值）变量名不能含 . 或 /：\(WFText.pyReprString(name))")
            } else if ["params", "item", "item_index", "batch"].contains(name) {
                errs.append("节点[\(idx)]（变量赋值）\(WFText.pyReprString(name)) 是保留名，请换一个变量名")
            }
        }
        if ntype == "code" {
            if WFText.strOrEmpty(node["code"]).trimmingCharacters(in: .whitespaces).isEmpty {
                errs.append("节点[\(idx)]（代码执行）缺少 code")
            }
        }
        if ntype == "reply" {
            if WFText.strOrEmpty(node["text"]).trimmingCharacters(in: .whitespaces).isEmpty {
                errs.append("节点[\(idx)]（消息回复）缺少 text")
            }
        }
        return errs
    }
}

// MARK: - WorkflowDefinition ↔ JSONValue 桥（面板类型化模型 ↔ 引擎原始字典）

public extension WorkflowDefinition {

    /// 引擎/校验消费的原始对象形态（props 保真透传，对齐 Python dict 语义）。
    var asJSONValue: JSONValue {
        .object([
            "nodes": .array(nodes.map { $0.asJSONValue }),
            "edges": .array(edges.map { e in
                var o: [String: JSONValue] = ["from": .string(e.from), "to": .string(e.to)]
                if let when = e.when { o["when"] = .string(when) }
                return .object(o)
            }),
            "params": .object(params),
        ])
    }

    /// DB 文本/原始 JSON → 类型化定义（宽容：坏 JSON → 空 nodes/edges，对齐
    /// store.py list_workflows 的 JSONDecodeError 兜底 {"nodes": [], "edges": []}）。
    static func fromJSONValue(_ v: JSONValue) -> WorkflowDefinition {
        guard case .object(let o) = v else { return WorkflowDefinition() }
        var nodes: [WorkflowNode] = []
        if case .array(let arr) = o["nodes"] {
            nodes = arr.compactMap { n in
                guard case .object(let no) = n else { return nil }
                return WorkflowNode(nodeJSON: no)
            }
        }
        var edges: [WorkflowEdge] = []
        if case .array(let arr) = o["edges"] {
            edges = arr.compactMap { e in
                guard case .object(let eo) = e,
                      case .string(let f) = eo["from"] ?? .null,
                      case .string(let t) = eo["to"] ?? .null else { return nil }
                return WorkflowEdge(from: f, to: t, when: eo["when"]?.string)
            }
        }
        let params = o["params"]?.object ?? [:]
        return WorkflowDefinition(nodes: nodes, edges: edges, params: params)
    }
}

public extension WorkflowNode {
    /// 原始字典形态：props 全量 + id/type 覆盖（与 Python 节点 dict 同构）。
    var asJSONValue: JSONValue {
        var o = props
        o["id"] = .string(id)
        o["type"] = .string(type)
        return .object(o)
    }

    /// 原始字典 → 节点（id/type 宽松转字符串，其余键保真入 props）。
    init?(nodeJSON o: [String: JSONValue]) {
        let id = WFText.strOrEmpty(o["id"])
        let type = WFText.strOrEmpty(o["type"])
        var props = o
        props.removeValue(forKey: "id")
        props.removeValue(forKey: "type")
        self.init(id: id, type: type, props: props)
    }
}
