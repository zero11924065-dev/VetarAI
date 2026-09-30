//
//  SidecarModels+Workflow.swift
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

//  工作流契约模型（流程中心三件套共用）：
//  字段逐条对照 subagent/sidecar/app.py 工作流端点与 storage/store.py 存储行：
//    GET    /api/workflows                     → [WorkflowRecord]（list_workflows）
//    GET    /api/workflows/{id}                → WorkflowRecord（get_workflow，404 不存在）
//    GET    /api/workflow-runs?workflow_id&limit → [WorkflowRunRecord]（list_workflow_runs）
//    GET    /api/workflow-runs/{id}            → WorkflowRunDetail（含 node_events）
//  定义结构（nodes/edges/params）是编辑器与引擎的唯一契约（sidecar/workflow/schema.py）。
//
//  保真设计（对齐 TSX 的 {...n} 展开语义）：
//    WorkflowNode 只把 id/type 提为类型化字段，**其余键全部留在 props 字典随编码往返**——
//    timeout_s / encoding / max_bytes 等现状表单未覆盖的键不会因保存丢失（schema.py 的
//    NODE_FIELD_SPECS 在演进，0.4.28 刚加过 timeout_s，客户端不能当漏斗）。
//

import Foundation

// MARK: - 工作流定义（编辑器/画布/引擎共用契约）

/// 工作流节点：id/type 类型化 + props 保真透传（label 也存 props，给便捷访问器）。
public struct WorkflowNode: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var type: String
    /// 除 id/type 外的全部节点字段（label/model/prompt/match/branches/…，未知键原样保留）。
    public var props: [String: JSONValue]

    public init(id: String, type: String, props: [String: JSONValue] = [:]) {
        self.id = id
        self.type = type
        self.props = props
    }

    // MARK: 便捷访问器（宽松取值，类型不符 → nil）

    public var label: String? {
        get { props["label"]?.string }
        set { props["label"] = newValue.map { .string($0) } }
    }
    /// 字符串字段读写（编辑表单用）。
    public subscript(text key: String) -> String {
        get { props[key]?.string ?? "" }
        set { props[key] = newValue.isEmpty ? nil : .string(newValue) }
    }

    private enum CodingKeys: String, CodingKey { case id, type }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        let all = try decoder.singleValueContainer().decode([String: JSONValue].self)
        var rest = all
        rest.removeValue(forKey: "id")
        rest.removeValue(forKey: "type")
        props = rest
    }

    public func encode(to encoder: Encoder) throws {
        var obj = props
        obj["id"] = .string(id)
        obj["type"] = .string(type)
        var c = encoder.singleValueContainer()
        try c.encode(obj)
    }
}

/// 连线（引擎只消费 from/to/when 三键；条件分支用 when 标签分流）。
public struct WorkflowEdge: Codable, Equatable, Sendable {
    public var from: String
    public var to: String
    public var when: String?

    public init(from: String, to: String, when: String? = nil) {
        self.from = from
        self.to = to
        self.when = when
    }
}

/// 工作流定义：nodes + edges + params（schema.py 顶部契约注释口径）。
public struct WorkflowDefinition: Codable, Equatable, Sendable {
    public var nodes: [WorkflowNode]
    public var edges: [WorkflowEdge]
    public var params: [String: JSONValue]

    public init(nodes: [WorkflowNode] = [], edges: [WorkflowEdge] = [],
                params: [String: JSONValue] = [:]) {
        self.nodes = nodes
        self.edges = edges
        self.params = params
    }

    /// 新建工作流的初始定义：仅一个开始节点（对齐 schema.py default_start_definition）。
    public static func startOnly() -> WorkflowDefinition {
        WorkflowDefinition(
            nodes: [WorkflowNode(id: "start", type: "start", props: ["label": .string("开始")])],
            edges: [], params: [:])
    }

    public func node(id: String) -> WorkflowNode? { nodes.first { $0.id == id } }

    // params 历史数据可能缺省；nodes/edges 后端保证是列表（validate_definition 把关），
    // 但解码仍宽容（缺省 → 空），避免一条坏记录让整个列表页白屏。
    private enum CodingKeys: String, CodingKey { case nodes, edges, params }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodes = try c.decodeIfPresent([WorkflowNode].self, forKey: .nodes) ?? []
        edges = try c.decodeIfPresent([WorkflowEdge].self, forKey: .edges) ?? []
        params = try c.decodeIfPresent([String: JSONValue].self, forKey: .params) ?? [:]
    }
}

// MARK: - REST 资源记录

/// 工作流记录（GET /api/workflows 列表行 / GET /api/workflows/{id} 同构）。
public struct WorkflowRecord: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let definition: WorkflowDefinition
    public let builtIn: Bool
    public let createdAt: String?
    public let updatedAt: String?

    public init(id: String, name: String, description: String = "",
                definition: WorkflowDefinition = .startOnly(), builtIn: Bool = false,
                createdAt: String? = nil, updatedAt: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.definition = definition
        self.builtIn = builtIn
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, description, definition, built_in, created_at, updated_at
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        definition = try c.decodeIfPresent(WorkflowDefinition.self, forKey: .definition)
            ?? WorkflowDefinition()
        // built_in 落库为 0/1（store.py bool(r[4]) 转出 true/false；容错两种形态）
        if let b = try? c.decodeIfPresent(Bool.self, forKey: .built_in) {
            builtIn = b
        } else if let n = try? c.decodeIfPresent(Int.self, forKey: .built_in) {
            builtIn = n != 0
        } else {
            builtIn = false
        }
        createdAt = try c.decodeIfPresent(String.self, forKey: .created_at)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updated_at)
    }
}

/// 运行记录列表行（GET /api/workflow-runs；store.py list_workflow_runs 七键）。
/// status 原始字符串保留：running / awaiting_approval / done / failed / stopped。
public struct WorkflowRunRecord: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let workflowId: String
    public let status: String
    public let currentNode: String?
    public let result: String?
    public let error: String?
    public let createdAt: String?

    public init(id: String, workflowId: String = "", status: String = "running",
                currentNode: String? = nil, result: String? = nil, error: String? = nil,
                createdAt: String? = nil) {
        self.id = id
        self.workflowId = workflowId
        self.status = status
        self.currentNode = currentNode
        self.result = result
        self.error = error
        self.createdAt = createdAt
    }

    /// 进行中（可停止）：引擎 status 口径只有这两档活着。
    public var isActive: Bool { status == "running" || status == "awaiting_approval" }

    private enum CodingKeys: String, CodingKey {
        case id, workflow_id, status, current_node, result, error, created_at
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        workflowId = try c.decodeIfPresent(String.self, forKey: .workflow_id) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "running"
        currentNode = try c.decodeIfPresent(String.self, forKey: .current_node)
        result = try c.decodeIfPresent(String.self, forKey: .result)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        createdAt = try c.decodeIfPresent(String.self, forKey: .created_at)
    }
}

/// 节点事件记录（workflow_node_events 表行；运行记录详情内嵌）。
public struct WorkflowNodeEventRecord: Decodable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let nodeId: String
    public let nodeType: String
    public let status: String          // running / done / error
    public let modelUsed: String?
    public let inputSummary: String
    public let outputSummary: String
    public let error: String?
    public let retryCount: Int
    public let durationMs: Int?
    public let createdAt: String?

    public init(id: Int, nodeId: String, nodeType: String = "", status: String = "running",
                modelUsed: String? = nil, inputSummary: String = "", outputSummary: String = "",
                error: String? = nil, retryCount: Int = 0, durationMs: Int? = nil,
                createdAt: String? = nil) {
        self.id = id
        self.nodeId = nodeId
        self.nodeType = nodeType
        self.status = status
        self.modelUsed = modelUsed
        self.inputSummary = inputSummary
        self.outputSummary = outputSummary
        self.error = error
        self.retryCount = retryCount
        self.durationMs = durationMs
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, node_id, node_type, status, model_used, input_summary
        case output_summary, error, retry_count, duration_ms, created_at
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // id 是 SQLite rowid（整数）；宽容接受字符串形态
        if let n = try? c.decodeIfPresent(Int.self, forKey: .id) {
            id = n
        } else if let s = try? c.decodeIfPresent(String.self, forKey: .id), let n = Int(s) {
            id = n
        } else {
            id = 0
        }
        nodeId = try c.decodeIfPresent(String.self, forKey: .node_id) ?? ""
        nodeType = try c.decodeIfPresent(String.self, forKey: .node_type) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "running"
        modelUsed = try c.decodeIfPresent(String.self, forKey: .model_used)
        inputSummary = try c.decodeIfPresent(String.self, forKey: .input_summary) ?? ""
        outputSummary = try c.decodeIfPresent(String.self, forKey: .output_summary) ?? ""
        error = try c.decodeIfPresent(String.self, forKey: .error)
        retryCount = try c.decodeIfPresent(Int.self, forKey: .retry_count) ?? 0
        durationMs = try c.decodeIfPresent(Int.self, forKey: .duration_ms)
        createdAt = try c.decodeIfPresent(String.self, forKey: .created_at)
    }
}

/// 运行记录详情（GET /api/workflow-runs/{id}：列表行 + variables/updated_at + node_events）。
public struct WorkflowRunDetail: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let workflowId: String
    public let status: String
    public let currentNode: String?
    public let variables: [String: JSONValue]
    public let result: String?
    public let error: String?
    public let createdAt: String?
    public let updatedAt: String?
    public let nodeEvents: [WorkflowNodeEventRecord]

    public init(id: String, workflowId: String = "", status: String = "running",
                currentNode: String? = nil, variables: [String: JSONValue] = [:],
                result: String? = nil, error: String? = nil,
                createdAt: String? = nil, updatedAt: String? = nil,
                nodeEvents: [WorkflowNodeEventRecord] = []) {
        self.id = id
        self.workflowId = workflowId
        self.status = status
        self.currentNode = currentNode
        self.variables = variables
        self.result = result
        self.error = error
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.nodeEvents = nodeEvents
    }

    private enum CodingKeys: String, CodingKey {
        case id, workflow_id, status, current_node, variables, result, error
        case created_at, updated_at, node_events
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        workflowId = try c.decodeIfPresent(String.self, forKey: .workflow_id) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "running"
        currentNode = try c.decodeIfPresent(String.self, forKey: .current_node)
        variables = try c.decodeIfPresent([String: JSONValue].self, forKey: .variables) ?? [:]
        result = try c.decodeIfPresent(String.self, forKey: .result)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        createdAt = try c.decodeIfPresent(String.self, forKey: .created_at)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updated_at)
        nodeEvents = try c.decodeIfPresent([WorkflowNodeEventRecord].self, forKey: .node_events) ?? []
    }
}

// MARK: - 请求体（编码契约）

/// POST /api/workflows（WorkflowCreateReq：name 必填、description 缺省 ""、definition 必填）。
public struct WorkflowCreateRequest: Encodable {
    public let name: String
    public let description: String
    public let definition: WorkflowDefinition

    public init(name: String, description: String = "", definition: WorkflowDefinition) {
        self.name = name
        self.description = description
        self.definition = definition
    }
}

/// PUT /api/workflows/{id}（WorkflowUpdateReq：三键均可选，nil 键省略 = 后端部分更新语义）。
public struct WorkflowUpdateRequest: Encodable {
    public let name: String?
    public let description: String?
    public let definition: WorkflowDefinition?

    public init(name: String? = nil, description: String? = nil,
                definition: WorkflowDefinition? = nil) {
        self.name = name
        self.description = description
        self.definition = definition
    }
}

/// POST /api/workflows/{id}/run（WorkflowRunReq：params 可选；sandbox_root 缺省后端取 ~/Desktop，
/// 面板不暴露该配置——与现状 TSX 一致只发 params）。
public struct WorkflowRunRequest: Encodable {
    public let params: [String: JSONValue]

    public init(params: [String: JSONValue] = [:]) {
        self.params = params
    }
}

/// POST /api/workflow-runs/{id}/approve（WorkflowApproveReq：approved + comment 缺省 ""）。
public struct WorkflowApproveRequest: Encodable {
    public let approved: Bool
    public let comment: String

    public init(approved: Bool, comment: String = "") {
        self.approved = approved
        self.comment = comment
    }
}
