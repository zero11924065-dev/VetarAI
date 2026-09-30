//
//  NativeDatabase.swift
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

//  逐函数移植 subagent/sidecar/storage/store.py（唯一事实源，⛔ 只读）。
//  数据兼容红线：直接读写现状 ~/.subagent 形态的库文件，无任何迁移。
//
//  本波覆盖（P2-W0 路由表 .native 部分）：
//    projects / independent_agents（ia-<id> 命名空间）/ agent_configs /
//    sessions / session_messages / compact_log 读 / archive / delete_messages_before
//  留给后续波次（仍 HTTP）：agent_tasks / roundtables / workflows 的行级 CRUD
//  （schema 已随 _ensure_schema 全量建出，库文件兼容不受影响）。
//
//  结构对齐：
//    · 全局库 _global.db（projects/independent_agents/workflows…）在 projects 根；
//      每项目库 <projects>/<pid>/agents.db（agent_configs/sessions/messages…）
//    · 写锁串行化（对标 _WRITE_LOCK）；读不加锁
//    · 忙等待：全局库 10s（checkpoint-050）/ 项目库 5s（TS-115）
//    · 连接随用随开随关（checkpoint-050 B-1：成功提交/异常回滚/必关闭）
//

import Foundation

public final class NativeDatabase: @unchecked Sendable {

    /// PROJECTS_ROOT（=<data_root>/projects，构造即建目录——对齐 store.py L31-32 模块级副作用）。
    public let projectsRoot: URL
    /// _GDB = PROJECTS_ROOT/_global.db
    public var globalDBPath: String { projectsRoot.appendingPathComponent("_global.db").path }

    /// 写锁（对标 _WRITE_LOCK = threading.Lock：非递归）。
    private let writeLock = NSLock()
    public var log: (String) -> Void

    /// - Parameter projectsRoot: 调用方（NativeKernel）已按 config data_root 解析好。
    public init(projectsRoot: URL, log: @escaping (String) -> Void = { _ in }) {
        self.projectsRoot = projectsRoot
        self.log = log
        try? FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
    }

    // MARK: - 连接管理（_gconn / _agent_conn / _write_* / _read_*）

    private func openGlobal() throws -> SQLiteConnection {
        let conn = try SQLiteConnection(path: globalDBPath, busyTimeoutMs: 10_000)
        try ensureSchema(conn)
        return conn
    }

    private func openProject(_ projectId: String) throws -> SQLiteConnection {
        let pdir = projectsRoot.appendingPathComponent(projectId)
        try FileManager.default.createDirectory(at: pdir, withIntermediateDirectories: true)
        let conn = try SQLiteConnection(path: pdir.appendingPathComponent("agents.db").path,
                                        busyTimeoutMs: 5_000)
        try ensureSchema(conn)
        return conn
    }

    private func ensureSchema(_ conn: SQLiteConnection) throws {
        try conn.execScript(NativeDatabaseSchema.ddl)
        try NativeDatabaseSchema.migrate(on: conn)
    }

    /// _write_conn / _write_gconn：锁内 open → 显式事务 → 成功 commit / 异常 rollback / 必 close。
    /// internal（非 private）：P2-W2 起 NativeWorkflowStore 复用同一套连接纪律
    /// （workflows/workflow_runs/workflow_node_events 表在全局库，禁止另起连接管理）。
    @discardableResult
    func withWriteConn<T>(global: Bool, projectId: String = "",
                          _ body: (SQLiteConnection) throws -> T) throws -> T {
        writeLock.lock()
        defer { writeLock.unlock() }
        let conn = try (global ? openGlobal() : openProject(projectId))
        do {
            try conn.begin()
            let result = try body(conn)
            try conn.commit()
            try? conn.close()
            return result
        } catch {
            try? conn.rollback()
            try? conn.close()
            throw error
        }
    }

    /// _read_conn / _read_gconn：不加锁，必关闭。（internal：同上的 P2-W2 复用）
    func withReadConn<T>(global: Bool, projectId: String = "",
                         _ body: (SQLiteConnection) throws -> T) throws -> T {
        let conn = try (global ? openGlobal() : openProject(projectId))
        defer { try? conn.close() }
        return try body(conn)
    }

    // MARK: - 小工具

    /// Python str(uuid.uuid4())：小写带连字符（Swift uuidString 是大写——必须降格）。
    static func newUUID() -> String { UUID().uuidString.lowercased() }

    /// json.dumps(images)（默认 ensure_ascii=True，紧凑空格分隔）——images 为 dataURI/http 字符串数组。
    static func dumpsASCII(_ value: JSONValue) -> String { compactDumps(value, ascii: true) }

    /// json.dumps(x, ensure_ascii=False)——tool_steps/participants 等含中文的结构。
    static func dumpsUTF8(_ value: JSONValue) -> String { compactDumps(value, ascii: false) }

    /// Python json.dumps 默认分隔（', ' / ': '）紧凑格式。
    private static func compactDumps(_ value: JSONValue, ascii: Bool) -> String {
        switch value {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d): return NativeJSONWriter.pyFloatRepr(d)
        case .string(let s): return escape(s, ascii: ascii)
        case .array(let arr):
            return "[" + arr.map { compactDumps($0, ascii: ascii) }.joined(separator: ", ") + "]"
        case .object(let obj):
            // Python 保插入序；Swift 字典无序 → 字典序（确定性；读回侧 json.loads 无序语义）。
            let inner = obj.keys.sorted().map {
                "\(escape($0, ascii: ascii)): \(compactDumps(obj[$0]!, ascii: ascii))"
            }.joined(separator: ", ")
            return "{" + inner + "}"
        }
    }

    private static func escape(_ s: String, ascii: Bool) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else if ascii && scalar.value > 0x7F {
                    if scalar.value > 0xFFFF {
                        // Python ensure_ascii 对非 BMP 输出代理对
                        let v = scalar.value - 0x10000
                        out += String(format: "\\u%04x\\u%04x", 0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF))
                    } else {
                        out += String(format: "\\u%04x", scalar.value)
                    }
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// 宽容 json.loads：失败 → nil（对齐 load_messages 的 try/except JSONDecodeError: pass）。
    static func tolerantJSON(_ text: String) -> JSONValue? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    private static func str(_ v: SQLiteValue?) -> String? {
        guard case .text(let s) = v else { return nil }
        return s
    }
    private static func int(_ v: SQLiteValue?) -> Int64? {
        guard case .integer(let i) = v else { return nil }
        return i
    }
    private static func strOrNull(_ s: String?) -> SQLiteValue { s.map { .text($0) } ?? .null }
    private func strOrNull(_ s: String?) -> SQLiteValue { Self.strOrNull(s) }

    // ════════════════════════════════════════════════════════════
    // MARK: - Project CRUD（store.py L348-394 / L495-499）
    // ════════════════════════════════════════════════════════════

    /// create_project：uuid + 工作目录落盘验证（mkdir + 写测试文件）+ 全局库插入。
    /// - Throws: NativeCoreError.io（对齐 PermissionError/OSError 文案）。
    @discardableResult
    public func createProject(name: String, workingDir: String) throws -> String {
        let pid = Self.newUUID()
        // Path(working_dir).expanduser().resolve()：~ 展开 + realpath（/var→/private/var firmlink 亦解）
        let wd = NativeConfigStore.resolvePath(
            NativeConfigStore.expandUser(workingDir).standardizedFileURL)
        let fm = FileManager.default
        do {
            if !fm.fileExists(atPath: wd.path) {
                try fm.createDirectory(at: wd, withIntermediateDirectories: true)
            }
            let testFile = wd.appendingPathComponent(".subagent_write_test")
            try "ok".write(to: testFile, atomically: false, encoding: .utf8)
            try fm.removeItem(at: testFile)
        } catch {
            // Python 先 PermissionError 后 OSError；Swift 错误域不细分——按 errno 判别权限
            let nsErr = error as NSError
            if nsErr.domain == NSCocoaErrorDomain,
               [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(nsErr.code) {
                throw NativeCoreError.io("工作目录无写入权限: \(wd.path)")
            }
            throw NativeCoreError.io("无法创建工作目录 \(wd.path): \(error.localizedDescription)")
        }
        try withWriteConn(global: true) { conn in
            try conn.execute("INSERT INTO projects (id, name, working_dir) VALUES (?, ?, ?)",
                             [.text(pid), .text(name), .text(wd.path)])
        }
        return pid
    }

    /// delete_project：删行 + rmtree 项目目录（ignore_errors 对齐）。
    @discardableResult
    public func deleteProject(_ pid: String) throws -> Bool {
        let deleted = try withWriteConn(global: true) { conn in
            try conn.execute("DELETE FROM projects WHERE id = ?", [.text(pid)]) > 0
        }
        if deleted {
            let pdir = projectsRoot.appendingPathComponent(pid)
            if FileManager.default.fileExists(atPath: pdir.path) {
                try? FileManager.default.removeItem(at: pdir)
            }
        }
        return deleted
    }

    /// list_projects → 面板契约模型（SidecarProject 只有 id/name；working_dir 走 listProjectRows）。
    public func listProjects() throws -> [SidecarProject] {
        try withReadConn(global: true) { conn in
            try conn.query("SELECT id, name, working_dir FROM projects ORDER BY created_at DESC")
                .map { row in
                    SidecarProject(id: Self.str(row[0]) ?? "", name: Self.str(row[1]) ?? "")
                }
        }
    }

    /// 原始行（working_dir 含——双跑对照/诊断用；面板模型 SidecarProject 无此字段）。
    public func listProjectRows() throws -> [[String: String]] {
        try withReadConn(global: true) { conn in
            try conn.query("SELECT id, name, working_dir FROM projects ORDER BY created_at DESC")
                .map { ["id": Self.str($0[0]) ?? "", "name": Self.str($0[1]) ?? "",
                        "working_dir": Self.str($0[2]) ?? ""] }
        }
    }

    /// get_project（checkpoint-056：端点存在性校验用）。
    public func getProject(_ pid: String) throws -> (id: String, name: String, workingDir: String)? {
        try withReadConn(global: true) { conn in
            guard let row = try conn.queryOne(
                "SELECT id, name, working_dir FROM projects WHERE id = ?", [.text(pid)]) else { return nil }
            return (Self.str(row[0]) ?? "", Self.str(row[1]) ?? "", Self.str(row[2]) ?? "")
        }
    }

    @discardableResult
    public func renameProject(_ pid: String, name: String) throws -> Bool {
        try withWriteConn(global: true) { conn in
            try conn.execute("UPDATE projects SET name = ?, updated_at = datetime('now') WHERE id = ?",
                             [.text(name), .text(pid)]) > 0
        }
    }

    // ════════════════════════════════════════════════════════════
    // MARK: - 独立 Agent（checkpoint-058，ia-<id> 命名空间；L397-492）
    // ════════════════════════════════════════════════════════════

    public static let independentNSPrefix = "ia-"

    public func independentAgentDir(_ agentId: String) -> URL {
        projectsRoot.appendingPathComponent("\(Self.independentNSPrefix)\(agentId)")
    }

    /// add_independent_agent：全局注册 + 命名空间 agents.db 注册 + 沙盒目录。
    @discardableResult
    public func addIndependentAgent(name: String, role: String? = nil,
                                    systemPrompt: String? = nil, modelName: String? = nil) throws -> String {
        let aid = Self.newUUID()
        try withWriteConn(global: true) { conn in
            try conn.execute(
                "INSERT INTO independent_agents (id, name, role, system_prompt, model_name) VALUES (?, ?, ?, ?, ?)",
                [.text(aid), .text(name), strOrNull(role), strOrNull(systemPrompt), strOrNull(modelName)])
        }
        let ns = "\(Self.independentNSPrefix)\(aid)"
        try withWriteConn(global: false, projectId: ns) { conn in
            try conn.execute(
                "INSERT INTO agent_configs (id, project_id, name, type_, role, system_prompt, model_name) VALUES (?, ?, ?, 'main', ?, ?, ?)",
                [.text(aid), .text(ns), .text(name), strOrNull(role), strOrNull(systemPrompt), strOrNull(modelName)])
        }
        let sb = independentAgentDir(aid).appendingPathComponent("sandbox")
        try FileManager.default.createDirectory(at: sb, withIntermediateDirectories: true)
        return aid
    }

    public struct IndependentAgentRow: Equatable, Sendable {
        public let id: String
        public let name: String
        public let role: String?
        public let systemPrompt: String?
        public let modelName: String?
        public let createdAt: String?
    }

    public func listIndependentAgents() throws -> [IndependentAgentRow] {
        try withReadConn(global: true) { conn in
            try conn.query(
                "SELECT id, name, role, system_prompt, model_name, created_at FROM independent_agents ORDER BY created_at"
            ).map { r in
                IndependentAgentRow(id: Self.str(r[0]) ?? "", name: Self.str(r[1]) ?? "",
                                    role: Self.str(r[2]), systemPrompt: Self.str(r[3]),
                                    modelName: Self.str(r[4]), createdAt: Self.str(r[5]))
            }
        }
    }

    public func getIndependentAgent(_ agentId: String) throws -> IndependentAgentRow? {
        try withReadConn(global: true) { conn in
            guard let r = try conn.queryOne(
                "SELECT id, name, role, system_prompt, model_name FROM independent_agents WHERE id = ?",
                [.text(agentId)]) else { return nil }
            return IndependentAgentRow(id: Self.str(r[0]) ?? "", name: Self.str(r[1]) ?? "",
                                       role: Self.str(r[2]), systemPrompt: Self.str(r[3]),
                                       modelName: Self.str(r[4]), createdAt: nil)
        }
    }

    /// update_independent_agent：显式分支双写（全局表为准；命名空间同步失败不回滚——对齐 L477-478）。
    /// 全 None → false（无有效更新）。
    @discardableResult
    public func updateIndependentAgent(_ agentId: String, name: String? = nil, role: String? = nil,
                                       systemPrompt: String? = nil, modelName: String? = nil) throws -> Bool {
        var updated = false
        try withWriteConn(global: true) { conn in
            if let name {
                updated = try conn.execute("UPDATE independent_agents SET name = ? WHERE id = ?",
                                           [.text(name), .text(agentId)]) > 0 || updated
            }
            if let role {
                updated = try conn.execute("UPDATE independent_agents SET role = ? WHERE id = ?",
                                           [.text(role), .text(agentId)]) > 0 || updated
            }
            if let systemPrompt {
                updated = try conn.execute("UPDATE independent_agents SET system_prompt = ? WHERE id = ?",
                                           [.text(systemPrompt), .text(agentId)]) > 0 || updated
            }
            if let modelName {
                updated = try conn.execute("UPDATE independent_agents SET model_name = ? WHERE id = ?",
                                           [.text(modelName), .text(agentId)]) > 0 || updated
            }
        }
        let ns = "\(Self.independentNSPrefix)\(agentId)"
        do {
            try withWriteConn(global: false, projectId: ns) { conn in
                if let name {
                    _ = try conn.execute("UPDATE agent_configs SET name = ? WHERE id = ?",
                                         [.text(name), .text(agentId)])
                }
                if let role {
                    _ = try conn.execute("UPDATE agent_configs SET role = ? WHERE id = ?",
                                         [.text(role), .text(agentId)])
                }
                if let systemPrompt {
                    _ = try conn.execute("UPDATE agent_configs SET system_prompt = ? WHERE id = ?",
                                         [.text(systemPrompt), .text(agentId)])
                }
                if let modelName {
                    _ = try conn.execute("UPDATE agent_configs SET model_name = ? WHERE id = ?",
                                         [.text(modelName), .text(agentId)])
                }
            }
        } catch {
            // 命名空间同步失败不回滚全局表（下次读取以全局表为准）——Python except: pass
            log("独立 Agent 命名空间同步失败（忽略）: \(error)")
        }
        return updated
    }

    /// delete_independent_agent：注册记录 + 命名空间目录全清。
    @discardableResult
    public func deleteIndependentAgent(_ agentId: String) throws -> Bool {
        let deleted = try withWriteConn(global: true) { conn in
            try conn.execute("DELETE FROM independent_agents WHERE id = ?", [.text(agentId)]) > 0
        }
        if deleted {
            let d = independentAgentDir(agentId)
            if FileManager.default.fileExists(atPath: d.path) {
                try? FileManager.default.removeItem(at: d)
            }
        }
        return deleted
    }

    // ════════════════════════════════════════════════════════════
    // MARK: - Agent config CRUD（项目库；L504-582）
    // ════════════════════════════════════════════════════════════

    @discardableResult
    public func addAgentConfig(projectId: String, name: String, type: String,
                               role: String? = nil, systemPrompt: String? = nil,
                               modelName: String? = nil, parentAgentId: String? = nil) throws -> String {
        let aid = Self.newUUID()
        try withWriteConn(global: false, projectId: projectId) { conn in
            try conn.execute(
                "INSERT INTO agent_configs (id, project_id, name, type_, role, system_prompt, model_name, parent_agent_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                [.text(aid), .text(projectId), .text(name), .text(type),
                 strOrNull(role), strOrNull(systemPrompt), strOrNull(modelName), strOrNull(parentAgentId)])
        }
        return aid
    }

    /// remove_agent_config：删 Agent 及其会话/消息/摘要（全清）。
    @discardableResult
    public func removeAgentConfig(projectId: String, agentId: String) throws -> Bool {
        try withWriteConn(global: false, projectId: projectId) { conn in
            try conn.execute("DELETE FROM session_messages WHERE agent_id = ?", [.text(agentId)])
            try conn.execute("DELETE FROM session_summaries WHERE agent_id = ?", [.text(agentId)])
            try conn.execute("DELETE FROM sessions WHERE agent_id = ?", [.text(agentId)])
            return try conn.execute("DELETE FROM agent_configs WHERE id = ?", [.text(agentId)]) > 0
        }
    }

    /// update_agent_config（TS-103 B12 显式分支；传非白名单或全 None → false）。
    @discardableResult
    public func updateAgentConfig(projectId: String, agentId: String,
                                  name: String? = nil, role: String? = nil,
                                  systemPrompt: String? = nil, modelName: String? = nil,
                                  parentAgentId: String? = nil) throws -> Bool {
        var updated = false
        try withWriteConn(global: false, projectId: projectId) { conn in
            if let name {
                updated = try conn.execute(
                    "UPDATE agent_configs SET name = ? WHERE id = ? AND project_id = ?",
                    [.text(name), .text(agentId), .text(projectId)]) > 0 || updated
            }
            if let role {
                updated = try conn.execute(
                    "UPDATE agent_configs SET role = ? WHERE id = ? AND project_id = ?",
                    [.text(role), .text(agentId), .text(projectId)]) > 0 || updated
            }
            if let systemPrompt {
                updated = try conn.execute(
                    "UPDATE agent_configs SET system_prompt = ? WHERE id = ? AND project_id = ?",
                    [.text(systemPrompt), .text(agentId), .text(projectId)]) > 0 || updated
            }
            if let modelName {
                updated = try conn.execute(
                    "UPDATE agent_configs SET model_name = ? WHERE id = ? AND project_id = ?",
                    [.text(modelName), .text(agentId), .text(projectId)]) > 0 || updated
            }
            if let parentAgentId {
                updated = try conn.execute(
                    "UPDATE agent_configs SET parent_agent_id = ? WHERE id = ? AND project_id = ?",
                    [.text(parentAgentId), .text(agentId), .text(projectId)]) > 0 || updated
            }
        }
        return updated
    }

    public struct AgentConfigRow: Equatable, Sendable {
        public let id: String
        public let name: String
        public let role: String?
        public let systemPrompt: String?
        public let modelName: String?
        public let type_: String
        public let parentAgentId: String?
    }

    public func listAgentConfigs(projectId: String) throws -> [AgentConfigRow] {
        try withReadConn(global: false, projectId: projectId) { conn in
            try conn.query(
                "SELECT id, name, role, system_prompt, model_name, type_, parent_agent_id FROM agent_configs ORDER BY created_at"
            ).map(Self.agentRow)
        }
    }

    public func getAgentConfig(projectId: String, agentId: String) throws -> AgentConfigRow? {
        try withReadConn(global: false, projectId: projectId) { conn in
            guard let row = try conn.queryOne(
                "SELECT id, name, role, system_prompt, model_name, type_, parent_agent_id FROM agent_configs WHERE id = ?",
                [.text(agentId)]) else { return nil }
            return Self.agentRow(row)
        }
    }

    private static func agentRow(_ r: [SQLiteValue]) -> AgentConfigRow {
        AgentConfigRow(id: str(r[0]) ?? "", name: str(r[1]) ?? "", role: str(r[2]),
                       systemPrompt: str(r[3]), modelName: str(r[4]),
                       type_: str(r[5]) ?? "", parentAgentId: str(r[6]))
    }

    // ════════════════════════════════════════════════════════════
    // MARK: - Session CRUD（L587-627 / L739-746）
    // ════════════════════════════════════════════════════════════

    @discardableResult
    public func createSession(projectId: String, agentId: String, title: String = "新会话") throws -> String {
        let sid = Self.newUUID()
        try withWriteConn(global: false, projectId: projectId) { conn in
            try conn.execute("INSERT INTO sessions (id, agent_id, project_id, title) VALUES (?, ?, ?, ?)",
                             [.text(sid), .text(agentId), .text(projectId), .text(title)])
        }
        return sid
    }

    public struct SessionRow: Equatable, Sendable {
        public let id: String
        public let title: String?
        public let createdAt: String?
        public let updatedAt: String?
        public let messageCount: Int64
    }

    /// list_sessions（TS-115：LEFT JOIN 消 N+1）。
    public func listSessions(projectId: String, agentId: String) throws -> [SessionRow] {
        try withReadConn(global: false, projectId: projectId) { conn in
            try conn.query("""
                SELECT s.id, s.title, s.created_at, s.updated_at,
                       COUNT(m.id) AS message_count
                FROM sessions s
                LEFT JOIN session_messages m ON m.session_id = s.id
                WHERE s.agent_id = ?
                GROUP BY s.id
                ORDER BY s.updated_at DESC
                """, [.text(agentId)]).map { r in
                SessionRow(id: Self.str(r[0]) ?? "", title: Self.str(r[1]),
                           createdAt: Self.str(r[2]), updatedAt: Self.str(r[3]),
                           messageCount: Self.int(r[4]) ?? 0)
            }
        }
    }

    @discardableResult
    public func renameSession(projectId: String, sessionId: String, title: String) throws -> Bool {
        try withWriteConn(global: false, projectId: projectId) { conn in
            try conn.execute("UPDATE sessions SET title = ?, updated_at = datetime('now') WHERE id = ?",
                             [.text(title), .text(sessionId)]) > 0
        }
    }

    /// delete_session：删会话及消息/摘要（附件清理由端点层负责——P3-W1a 起
    /// 端点编排在 NativeSidecarClient.deleteSession 复刻 app.py L729-756）。
    @discardableResult
    public func deleteSession(projectId: String, sessionId: String) throws -> Bool {
        try withWriteConn(global: false, projectId: projectId) { conn in
            try conn.execute("DELETE FROM session_messages WHERE session_id = ?", [.text(sessionId)])
            try conn.execute("DELETE FROM session_summaries WHERE session_id = ?", [.text(sessionId)])
            return try conn.execute("DELETE FROM sessions WHERE id = ?", [.text(sessionId)]) > 0
        }
    }

    /// delete_session_attachments（store.py L715-736 逐行为）：删会话连带清附件目录
    /// <projects_root>/<pid>/attachments/<sid>/，返回删掉的文件数。
    /// 只做「删会话连带清理」，不做定期清理——消息正文里存着绝对路径，
    /// 定期清会误删仍在引用的副本（Python docstring 口径）。
    /// 单层遍历（iterdir 口径：子目录不递归、不计数）；目录清空才 rmdir，
    /// 非空（有子项）保留；单文件删不掉不阻塞（except OSError: pass）。
    @discardableResult
    public func deleteSessionAttachments(projectId: String, sessionId: String) -> Int {
        let dir = projectsRoot.appendingPathComponent(projectId)
            .appendingPathComponent("attachments").appendingPathComponent(sessionId)
        guard FileManager.default.fileExists(atPath: dir.path) else { return 0 }
        var n = 0
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in entries {
            var isDir: ObjCBool = false
            // is_file() 口径（跟随符号链接；目录/子项跳过）
            guard FileManager.default.fileExists(atPath: f.path, isDirectory: &isDir),
                  !isDir.boolValue else { continue }
            if (try? FileManager.default.removeItem(at: f)) != nil { n += 1 }   // 单个删不掉不阻塞
        }
        // rmdir 等价：仅目录已空才删（removeItem 对非空目录会递归删——必须先判空）
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? ["<unreadable>"]
        if remaining.isEmpty { try? FileManager.default.removeItem(at: dir) }
        return n
    }

    // ════════════════════════════════════════════════════════════
    // MARK: - Summary（store.py L856-872）
    // ════════════════════════════════════════════════════════════

    /// save_session_summary（L858-872 逐行为）：MD 落盘
    /// <projects_root>/<pid>/work/summaries/<aid前8>_<sid前8>_<yyyyMMdd_HHmmss>.md
    /// （内容 "# Session Summary\n\n<text>"）+ session_summaries 行，返回文件路径。
    @discardableResult
    public func saveSessionSummary(projectId: String, sessionId: String, agentId: String,
                                   summary: String) throws -> String {
        let workDir = projectsRoot.appendingPathComponent(projectId)
            .appendingPathComponent("work").appendingPathComponent("summaries")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"
        let fname = "\(agentId.prefix(8))_\(sessionId.prefix(8))_\(df.string(from: Date())).md"
        let fpath = workDir.appendingPathComponent(fname)
        try "# Session Summary\n\n\(summary)".write(to: fpath, atomically: false, encoding: .utf8)
        try withWriteConn(global: false, projectId: projectId) { conn in
            try conn.execute(
                "INSERT INTO session_summaries (session_id, agent_id, project_id, summary_text) VALUES (?, ?, ?, ?)",
                [.text(sessionId), .text(agentId), .text(projectId), .text(summary)])
        }
        return fpath.path
    }

    // ════════════════════════════════════════════════════════════
    // MARK: - Message persistence（L751-853）
    // ════════════════════════════════════════════════════════════

    /// save_message（C8：stopped 落库为权威字段；写后 touch sessions.updated_at）。
    public func saveMessage(projectId: String, sessionId: String, agentId: String,
                            role: String, content: String,
                            images: [String]? = nil, modelUsed: String? = nil,
                            toolSteps: JSONValue? = nil, truncated: Bool = false,
                            promptEvalCount: Int64? = nil, stopped: Bool = false) throws {
        try withWriteConn(global: false, projectId: projectId) { conn in
            try conn.execute(
                "INSERT INTO session_messages (session_id, agent_id, project_id, role, content, images, model_used, tool_steps, truncated, prompt_eval_count, stopped) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                [.text(sessionId), .text(agentId), .text(projectId), .text(role), .text(content),
                 images.map { .text(Self.dumpsASCII(.array($0.map { .string($0) }))) } ?? .null,
                 strOrNull(modelUsed),
                 toolSteps.map { .text(Self.dumpsUTF8($0)) } ?? .null,
                 .integer(truncated ? 1 : 0),
                 promptEvalCount.map { .integer($0) } ?? .null,
                 .integer(stopped ? 1 : 0)])
            try conn.execute("UPDATE sessions SET updated_at = datetime('now') WHERE id = ?",
                             [.text(sessionId)])
        }
    }

    /// load_messages 行（对齐 L811-839 的 dict 装配语义：falsy 字段不进字典）。
    public struct MessageRow: Equatable, Sendable {
        public let id: Int64
        public let role: String
        public let content: String?
        public let modelUsed: String?
        public let createdAt: String?
        public let images: [JSONValue]?        // images 列 JSON 解析成功才非 nil
        public let toolSteps: [JSONValue]?
        public let truncated: Bool
        public let promptEvalCount: Int64?     // 列非 NULL 才非 nil（W5b 口径：NULL≠0）
        public let archived: Bool
        public let stopped: Bool
    }

    public func loadMessages(projectId: String, sessionId: String) throws -> [MessageRow] {
        try withReadConn(global: false, projectId: projectId) { conn in
            try conn.query(
                "SELECT id, role, content, images, model_used, created_at, tool_steps, truncated, prompt_eval_count, COALESCE(archived, 0), COALESCE(stopped, 0) FROM session_messages WHERE session_id = ? ORDER BY id",
                [.text(sessionId)]).map { r in
                var images: [JSONValue]?
                if case .text(let t) = r[3], !t.isEmpty,   // Python `if r[3]:`（NULL/空串都跳）
                   case .array(let arr) = Self.tolerantJSON(t) { images = arr }
                var toolSteps: [JSONValue]?
                if case .text(let t) = r[6], !t.isEmpty,
                   case .array(let arr) = Self.tolerantJSON(t) { toolSteps = arr }
                return MessageRow(
                    id: Self.int(r[0]) ?? 0,
                    role: Self.str(r[1]) ?? "",
                    content: Self.str(r[2]),
                    modelUsed: Self.str(r[4]),
                    createdAt: Self.str(r[5]),
                    images: images,
                    toolSteps: toolSteps,
                    truncated: (Self.int(r[7]) ?? 0) != 0,
                    promptEvalCount: Self.int(r[8]),
                    archived: (Self.int(r[9]) ?? 0) != 0,
                    stopped: (Self.int(r[10]) ?? 0) != 0
                )
            }
        }
    }

    /// log_compact（M2：成功/失败都写）。
    public func logCompact(projectId: String, sessionId: String,
                           beforeTokens: Int64, afterTokens: Int64,
                           archivePath: String?, summary: String?, error: String? = nil) throws {
        try withWriteConn(global: false, projectId: projectId) { conn in
            try conn.execute(
                "INSERT INTO compact_log (session_id, project_id, before_tokens, after_tokens, archive_path, summary, error) VALUES (?, ?, ?, ?, ?, ?, ?)",
                [.text(sessionId), .text(projectId), .integer(beforeTokens), .integer(afterTokens),
                 strOrNull(archivePath), strOrNull(summary), strOrNull(error)])
        }
    }

    public struct CompactLogRow: Equatable, Sendable {
        public let id: Int64
        public let ts: String?
        public let beforeTokens: Int64?
        public let afterTokens: Int64?
        public let archivePath: String?
        public let summary: String?
        public let error: String?
    }

    /// load_compact_log（最近 N 条）。
    public func loadCompactLog(projectId: String, sessionId: String, limit: Int = 3) throws -> [CompactLogRow] {
        try withReadConn(global: false, projectId: projectId) { conn in
            try conn.query(
                "SELECT id, ts, before_tokens, after_tokens, archive_path, summary, error FROM compact_log WHERE session_id = ? ORDER BY id DESC LIMIT ?",
                [.text(sessionId), .integer(Int64(limit))]).map { r in
                CompactLogRow(id: Self.int(r[0]) ?? 0, ts: Self.str(r[1]),
                              beforeTokens: Self.int(r[2]), afterTokens: Self.int(r[3]),
                              archivePath: Self.str(r[4]), summary: Self.str(r[5]),
                              error: Self.str(r[6]))
            }
        }
    }

    /// delete_messages_before（M2：保留最近 keepRecent 条，返回删除条数）。
    @discardableResult
    public func deleteMessagesBefore(projectId: String, sessionId: String, keepRecent: Int) throws -> Int {
        try withWriteConn(global: false, projectId: projectId) { conn in
            guard let row = try conn.queryOne(
                "SELECT id FROM session_messages WHERE session_id = ? ORDER BY id DESC LIMIT 1 OFFSET ?",
                [.text(sessionId), .integer(Int64(keepRecent - 1))]) else { return 0 }
            let cutoff = Self.int(row[0]) ?? 0
            return try conn.execute(
                "DELETE FROM session_messages WHERE session_id = ? AND id < ?",
                [.text(sessionId), .integer(cutoff)])
        }
    }

    /// archive_messages（TS-120：标记已归档；空列表直接 0）。
    @discardableResult
    public func archiveMessages(projectId: String, messageIds: [Int64]) throws -> Int {
        if messageIds.isEmpty { return 0 }
        let placeholders = messageIds.map { _ in "?" }.joined(separator: ",")
        return try withWriteConn(global: false, projectId: projectId) { conn in
            try conn.execute("UPDATE session_messages SET archived = 1 WHERE id IN (\(placeholders))",
                             messageIds.map { .integer($0) })
        }
    }

    // ════════════════════════════════════════════════════════════
    // MARK: - Agent task CRUD（store.py L877-989；P2-W4b 委派引擎落库）
    // ════════════════════════════════════════════════════════════

    /// get_agent_task / list_agent_tasks 行（report 反序列化；解析失败 {"raw": 原文}）。
    public struct AgentTaskRow: Equatable, Sendable {
        public let id: String
        public let parentAgentId: String
        public let parentSessionId: String
        public let targetAgentId: String
        public let targetAgentName: String
        public let task: String
        public let expect: String
        public let status: String
        public let report: JSONValue?        // report 列 JSON 解析成功才非 nil
        public let failReason: String?
        public let validationFailures: Int64
        public let sessionId: String?
        public let createdAt: String?
        public let updatedAt: String?
    }

    /// create_agent_task：创建一条委派任务（初始 status 走表 DEFAULT 'queued'），返回 task_id。
    @discardableResult
    public func createAgentTask(projectId: String, parentAgentId: String,
                                parentSessionId: String, targetAgentId: String,
                                targetAgentName: String, task: String, expect: String) throws -> String {
        let tid = Self.newUUID()
        try withWriteConn(global: false, projectId: projectId) { conn in
            try conn.execute(
                "INSERT INTO agent_tasks (id, project_id, parent_agent_id, parent_session_id, "
                + "target_agent_id, target_agent_name, task, expect) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                [.text(tid), .text(projectId), .text(parentAgentId), .text(parentSessionId),
                 .text(targetAgentId), .text(targetAgentName), .text(task), .text(expect)])
        }
        return tid
    }

    /// update_agent_task（_TASK_UPDATABLE 白名单显式分支：status/report/fail_reason/
    /// validation_failures/session_id；每个非 nil 字段一条 UPDATE，任一命中即 true）。
    @discardableResult
    public func updateAgentTask(projectId: String, taskId: String,
                                status: String? = nil, report: String? = nil,
                                failReason: String? = nil,
                                validationFailures: Int64? = nil,
                                sessionId: String? = nil) throws -> Bool {
        var updated = false
        try withWriteConn(global: false, projectId: projectId) { conn in
            if let status {
                updated = try conn.execute(
                    "UPDATE agent_tasks SET status = ?, updated_at = datetime('now') "
                    + "WHERE id = ? AND project_id = ?",
                    [.text(status), .text(taskId), .text(projectId)]) > 0 || updated
            }
            if let report {
                updated = try conn.execute(
                    "UPDATE agent_tasks SET report = ?, updated_at = datetime('now') "
                    + "WHERE id = ? AND project_id = ?",
                    [.text(report), .text(taskId), .text(projectId)]) > 0 || updated
            }
            if let failReason {
                updated = try conn.execute(
                    "UPDATE agent_tasks SET fail_reason = ?, updated_at = datetime('now') "
                    + "WHERE id = ? AND project_id = ?",
                    [.text(failReason), .text(taskId), .text(projectId)]) > 0 || updated
            }
            if let validationFailures {
                updated = try conn.execute(
                    "UPDATE agent_tasks SET validation_failures = ?, updated_at = datetime('now') "
                    + "WHERE id = ? AND project_id = ?",
                    [.integer(validationFailures), .text(taskId), .text(projectId)]) > 0 || updated
            }
            if let sessionId {
                updated = try conn.execute(
                    "UPDATE agent_tasks SET session_id = ?, updated_at = datetime('now') "
                    + "WHERE id = ? AND project_id = ?",
                    [.text(sessionId), .text(taskId), .text(projectId)]) > 0 || updated
            }
        }
        return updated
    }

    private static let agentTaskColumns =
        "id, parent_agent_id, parent_session_id, target_agent_id, target_agent_name, "
        + "task, expect, status, report, fail_reason, validation_failures, session_id, "
        + "created_at, updated_at"

    private static func agentTaskRow(_ r: [SQLiteValue]) -> AgentTaskRow {
        var report: JSONValue?
        if case .text(let t) = r[8], !t.isEmpty {
            report = tolerantJSON(t) ?? .object(["raw": .string(t)])
        }
        return AgentTaskRow(
            id: str(r[0]) ?? "", parentAgentId: str(r[1]) ?? "",
            parentSessionId: str(r[2]) ?? "", targetAgentId: str(r[3]) ?? "",
            targetAgentName: str(r[4]) ?? "", task: str(r[5]) ?? "",
            expect: str(r[6]) ?? "", status: str(r[7]) ?? "",
            report: report, failReason: str(r[9]),
            validationFailures: int(r[10]) ?? 0, sessionId: str(r[11]),
            createdAt: str(r[12]), updatedAt: str(r[13]))
    }

    /// get_agent_task。
    public func getAgentTask(projectId: String, taskId: String) throws -> AgentTaskRow? {
        try withReadConn(global: false, projectId: projectId) { conn in
            guard let row = try conn.queryOne(
                "SELECT \(Self.agentTaskColumns) FROM agent_tasks WHERE id = ?",
                [.text(taskId)]) else { return nil }
            return Self.agentTaskRow(row)
        }
    }

    /// list_agent_tasks（倒序：created_at DESC, rowid DESC——最新在前）。
    public func listAgentTasks(projectId: String, limit: Int = 50) throws -> [AgentTaskRow] {
        try withReadConn(global: false, projectId: projectId) { conn in
            try conn.query(
                "SELECT \(Self.agentTaskColumns) FROM agent_tasks "
                + "ORDER BY created_at DESC, rowid DESC LIMIT ?",
                [.integer(Int64(limit))]).map(Self.agentTaskRow)
        }
    }

    /// list_recent_delegations_to_target（checkpoint-068 D-8 前置守卫数据源，新→旧）。
    public struct DelegationHistoryRow: Equatable, Sendable {
        public let id: String
        public let status: String
        public let task: String
        public let createdAt: String?
    }

    public func listRecentDelegationsToTarget(projectId: String, targetAgentId: String,
                                              limit: Int = 30) throws -> [DelegationHistoryRow] {
        try withReadConn(global: false, projectId: projectId) { conn in
            try conn.query(
                "SELECT id, status, task, created_at FROM agent_tasks "
                + "WHERE project_id = ? AND target_agent_id = ? "
                + "ORDER BY created_at DESC, rowid DESC LIMIT ?",
                [.text(projectId), .text(targetAgentId), .integer(Int64(limit))]).map { r in
                DelegationHistoryRow(id: Self.str(r[0]) ?? "", status: Self.str(r[1]) ?? "",
                                     task: Self.str(r[2]) ?? "", createdAt: Self.str(r[3]))
            }
        }
    }
}
