//
//  NativeWorkflowStore.swift
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

//  逐函数移植 subagent/sidecar/storage/store.py 工作流段（L1103-1283，⛔ 只读行为规格源）：
//    create_workflow / update_workflow / list_workflows / get_workflow / delete_workflow
//    create_workflow_run / update_workflow_run / get_workflow_run / list_workflow_runs
//    append_workflow_node_event / list_workflow_node_events
//
//  数据兼容红线：表在全局库 _global.db（schema 已随 NativeDatabaseSchema 全量建出，
//  逐字一致）；写操作一律 withWriteConn(global:)（锁内提交/回滚/必关闭），
//  UPDATE 显式分支（B12 教训：禁止 SET 拼接）；input/output_summary 落库截 2000。
//
//  返回模型直接复用 Phase 1 W4 契约类型（WorkflowRecord/WorkflowRunRecord/
//  WorkflowRunDetail/WorkflowNodeEventRecord）——面板零改动（任务书硬约束）。
//

import Foundation

public final class NativeWorkflowStore: @unchecked Sendable {

    /// 定义 JSON 解析失败的兜底（store.py：json.JSONDecodeError → {"nodes": [], "edges": []}）。
    private static let fallbackDefinitionJSON = "{\"nodes\": [], \"edges\": []}"

    public let database: NativeDatabase
    public var log: (String) -> Void

    public init(database: NativeDatabase, log: @escaping (String) -> Void = { _ in }) {
        self.database = database
        self.log = log
    }

    // MARK: - 小工具

    private static func str(_ v: SQLiteValue?) -> String? {
        guard case .text(let s) = v else { return nil }
        return s
    }
    private static func int(_ v: SQLiteValue?) -> Int64? {
        guard case .integer(let i) = v else { return nil }
        return i
    }
    private static func strOrNull(_ s: String?) -> SQLiteValue { s.map { .text($0) } ?? .null }

    /// json.dumps(x, ensure_ascii=False)（Python 默认分隔 ', ' / ': '）。
    private static func dumps(_ v: JSONValue) -> String { NativeDatabase.dumpsUTF8(v) }

    /// definition TEXT → JSONValue；解析失败回退兜底定义（store.py L1150-1154/L1168-1171）。
    static func parseDefinition(_ text: String) -> JSONValue {
        if let data = text.data(using: .utf8), let v = NativeJSONWriter.loads(data) {
            return v
        }
        return NativeJSONWriter.loads(Data(fallbackDefinitionJSON.utf8))!
    }

    /// definition TEXT → 面板契约模型。
    static func parseDefinitionTyped(_ text: String) -> WorkflowDefinition {
        WorkflowDefinition.fromJSONValue(parseDefinition(text))
    }

    // ════════════════════════════════════════════════════════════
    // MARK: - 工作流定义 CRUD（store.py L1108-1183）
    // ════════════════════════════════════════════════════════════

    /// create_workflow：uuid + definition 完整 JSON 落库，返回 id。
    @discardableResult
    public func createWorkflow(name: String, definition: JSONValue, description: String = "",
                               builtIn: Bool = false) throws -> String {
        let wfId = NativeDatabase.newUUID()
        try database.withWriteConn(global: true) { conn in
            try conn.execute(
                "INSERT INTO workflows (id, name, description, definition, built_in) "
                + "VALUES (?, ?, ?, ?, ?)",
                [.text(wfId), .text(name), .text(description), .text(Self.dumps(definition)),
                 .integer(builtIn ? 1 : 0)])
        }
        return wfId
    }

    /// update_workflow：部分更新（显式分支，禁止 SET 拼接——B12 教训）。
    @discardableResult
    public func updateWorkflow(_ wfId: String, name: String? = nil,
                               definition: JSONValue? = nil,
                               description: String? = nil) throws -> Bool {
        try database.withWriteConn(global: true) { conn in
            var updated = false
            if let name {
                updated = try conn.execute(
                    "UPDATE workflows SET name = ?, updated_at = datetime('now') WHERE id = ?",
                    [.text(name), .text(wfId)]) > 0 || updated
            }
            if let description {
                updated = try conn.execute(
                    "UPDATE workflows SET description = ?, updated_at = datetime('now') WHERE id = ?",
                    [.text(description), .text(wfId)]) > 0 || updated
            }
            if let definition {
                updated = try conn.execute(
                    "UPDATE workflows SET definition = ?, updated_at = datetime('now') WHERE id = ?",
                    [.text(Self.dumps(definition)), .text(wfId)]) > 0 || updated
            }
            return updated
        }
    }

    /// 工作流行（内部；typed/raw 两个读面共用）。
    public struct WorkflowRow {
        public let id: String
        public let name: String
        public let description: String
        public let definitionText: String
        public let builtIn: Bool
        public let createdAt: String
        public let updatedAt: String

        /// 面板契约模型读面。
        public var record: WorkflowRecord {
            WorkflowRecord(id: id, name: name, description: description,
                           definition: NativeWorkflowStore.parseDefinitionTyped(definitionText),
                           builtIn: builtIn, createdAt: createdAt, updatedAt: updatedAt)
        }
    }

    private static func workflowRow(_ r: [SQLiteValue]) -> WorkflowRow {
        WorkflowRow(id: str(r[0]) ?? "", name: str(r[1]) ?? "", description: str(r[2]) ?? "",
                    definitionText: str(r[3]) ?? "", builtIn: (int(r[4]) ?? 0) != 0,
                    createdAt: str(r[5]) ?? "", updatedAt: str(r[6]) ?? "")
    }

    /// list_workflows：全部定义（新→旧：created_at DESC, rowid DESC）。
    public func listWorkflowRows() throws -> [WorkflowRow] {
        try database.withReadConn(global: true) { conn in
            try conn.query(
                "SELECT id, name, description, definition, built_in, created_at, updated_at "
                + "FROM workflows ORDER BY created_at DESC, rowid DESC"
            ).map(Self.workflowRow)
        }
    }

    /// get_workflow（nil = 不存在）。
    public func getWorkflowRow(_ wfId: String) throws -> WorkflowRow? {
        try database.withReadConn(global: true) { conn in
            try conn.queryOne(
                "SELECT id, name, description, definition, built_in, created_at, updated_at "
                + "FROM workflows WHERE id = ?", [.text(wfId)]).map(Self.workflowRow)
        }
    }

    /// delete_workflow：内置不可删；运行记录与节点事件保留作历史。
    @discardableResult
    public func deleteWorkflow(_ wfId: String) throws -> Bool {
        guard let wf = try getWorkflowRow(wfId), !wf.builtIn else { return false }
        return try database.withWriteConn(global: true) { conn in
            try conn.execute("DELETE FROM workflows WHERE id = ?", [.text(wfId)]) > 0
        }
    }

    // ════════════════════════════════════════════════════════════
    // MARK: - 运行记录（store.py L1186-1254）
    // ════════════════════════════════════════════════════════════

    /// create_workflow_run：status='running' + variables JSON，返回 run_id。
    @discardableResult
    public func createWorkflowRun(workflowId: String, variables: JSONValue? = nil) throws -> String {
        let runId = NativeDatabase.newUUID()
        try database.withWriteConn(global: true) { conn in
            try conn.execute(
                "INSERT INTO workflow_runs (id, workflow_id, status, variables) VALUES (?, ?, 'running', ?)",
                [.text(runId), .text(workflowId), .text(Self.dumps(variables ?? .object([:])))])
        }
        return runId
    }

    /// update_workflow_run：显式分支部分更新（B12 教训）。
    @discardableResult
    public func updateWorkflowRun(_ runId: String, status: String? = nil,
                                  currentNode: String? = nil, variables: JSONValue? = nil,
                                  result: String? = nil, error: String? = nil) throws -> Bool {
        try database.withWriteConn(global: true) { conn in
            var updated = false
            if let status {
                updated = try conn.execute(
                    "UPDATE workflow_runs SET status = ?, updated_at = datetime('now') WHERE id = ?",
                    [.text(status), .text(runId)]) > 0 || updated
            }
            if let currentNode {
                updated = try conn.execute(
                    "UPDATE workflow_runs SET current_node = ?, updated_at = datetime('now') WHERE id = ?",
                    [.text(currentNode), .text(runId)]) > 0 || updated
            }
            if let variables {
                updated = try conn.execute(
                    "UPDATE workflow_runs SET variables = ?, updated_at = datetime('now') WHERE id = ?",
                    [.text(Self.dumps(variables)), .text(runId)]) > 0 || updated
            }
            if let result {
                updated = try conn.execute(
                    "UPDATE workflow_runs SET result = ?, updated_at = datetime('now') WHERE id = ?",
                    [.text(result), .text(runId)]) > 0 || updated
            }
            if let error {
                updated = try conn.execute(
                    "UPDATE workflow_runs SET error = ?, updated_at = datetime('now') WHERE id = ?",
                    [.text(error), .text(runId)]) > 0 || updated
            }
            return updated
        }
    }

    /// 运行记录行（内部读面；variables 保留 JSON 文本与解析后两态）。
    public struct WorkflowRunRow {
        public let id: String
        public let workflowId: String
        public let status: String
        public let currentNode: String?
        public let variables: JSONValue    // json.loads 兜底 {}（store.py L1232-1234）
        public let result: String?
        public let error: String?
        public let createdAt: String
        public let updatedAt: String

        public var listRecord: WorkflowRunRecord {
            WorkflowRunRecord(id: id, workflowId: workflowId, status: status,
                              currentNode: currentNode, result: result, error: error,
                              createdAt: createdAt)
        }
    }

    private static func runRow(_ r: [SQLiteValue], withVariables: Bool) -> WorkflowRunRow {
        var variables: JSONValue = .object([:])
        if withVariables, let text = str(r[4]), let data = text.data(using: .utf8),
           let v = NativeJSONWriter.loads(data) {
            variables = v
        }
        return WorkflowRunRow(
            id: Self.str(r[0]) ?? "", workflowId: Self.str(r[1]) ?? "",
            status: Self.str(r[2]) ?? "", currentNode: Self.str(r[3]),
            variables: variables,
            result: Self.str(r[5]), error: Self.str(r[6]),
            createdAt: Self.str(r[7]) ?? "", updatedAt: Self.str(r[8]) ?? "")
    }

    /// get_workflow_run（nil = 不存在）。
    public func getWorkflowRun(_ runId: String) throws -> WorkflowRunRow? {
        try database.withReadConn(global: true) { conn in
            try conn.queryOne(
                "SELECT id, workflow_id, status, current_node, variables, result, error, "
                + "created_at, updated_at FROM workflow_runs WHERE id = ?", [.text(runId)]
            ).map { Self.runRow($0, withVariables: true) }
        }
    }

    /// list_workflow_runs：新→旧，可按工作流过滤；limit 由调用方（端点层）钳 1...100。
    public func listWorkflowRuns(workflowId: String? = nil, limit: Int = 30) throws -> [WorkflowRunRecord] {
        try database.withReadConn(global: true) { conn in
            let rows: [[SQLiteValue]]
            if let workflowId {
                rows = try conn.query(
                    "SELECT id, workflow_id, status, current_node, result, error, created_at "
                    + "FROM workflow_runs WHERE workflow_id = ? ORDER BY created_at DESC LIMIT ?",
                    [.text(workflowId), .integer(Int64(limit))])
            } else {
                rows = try conn.query(
                    "SELECT id, workflow_id, status, current_node, result, error, created_at "
                    + "FROM workflow_runs ORDER BY created_at DESC LIMIT ?",
                    [.integer(Int64(limit))])
            }
            return rows.map { r in
                WorkflowRunRecord(id: Self.str(r[0]) ?? "", workflowId: Self.str(r[1]) ?? "",
                                  status: Self.str(r[2]) ?? "", currentNode: Self.str(r[3]),
                                  result: Self.str(r[4]), error: Self.str(r[5]),
                                  createdAt: Self.str(r[6]))
            }
        }
    }

    // ════════════════════════════════════════════════════════════
    // MARK: - 节点事件（store.py L1257-1282）
    // ════════════════════════════════════════════════════════════

    /// append_workflow_node_event：追加一条节点事件（input/output_summary 截 2000）。
    public func appendWorkflowNodeEvent(runId: String, nodeId: String, nodeType: String,
                                        status: String, modelUsed: String? = nil,
                                        inputSummary: String = "", outputSummary: String = "",
                                        error: String? = nil, retryCount: Int = 0,
                                        durationMs: Int? = nil) throws {
        try database.withWriteConn(global: true) { conn in
            try conn.execute(
                "INSERT INTO workflow_node_events (run_id, node_id, node_type, status, model_used, "
                + "input_summary, output_summary, error, retry_count, duration_ms) "
                + "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                [.text(runId), .text(nodeId), .text(nodeType), .text(status),
                 Self.strOrNull(modelUsed),
                 .text(WFText.pyPrefix(inputSummary, 2000)),
                 .text(WFText.pyPrefix(outputSummary, 2000)),
                 Self.strOrNull(error), .integer(Int64(retryCount)),
                 durationMs.map { .integer(Int64($0)) } ?? .null])
        }
    }

    /// list_workflow_node_events：按 id 升序（执行序回放）。
    public func listWorkflowNodeEvents(_ runId: String) throws -> [WorkflowNodeEventRecord] {
        try database.withReadConn(global: true) { conn in
            try conn.query(
                "SELECT id, node_id, node_type, status, model_used, input_summary, "
                + "output_summary, error, retry_count, duration_ms, created_at "
                + "FROM workflow_node_events WHERE run_id = ? ORDER BY id",
                [.text(runId)]
            ).map { r in
                WorkflowNodeEventRecord(
                    id: Int(Self.int(r[0]) ?? 0), nodeId: Self.str(r[1]) ?? "",
                    nodeType: Self.str(r[2]) ?? "", status: Self.str(r[3]) ?? "",
                    modelUsed: Self.str(r[4]), inputSummary: Self.str(r[5]) ?? "",
                    outputSummary: Self.str(r[6]) ?? "", error: Self.str(r[7]),
                    retryCount: Int(Self.int(r[8]) ?? 0),
                    durationMs: Self.int(r[9]).map { Int($0) }, createdAt: Self.str(r[10]))
            }
        }
    }
}
