//
//  NativeSessionOps.swift
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

//  端点逐行为复刻（⛔ 行为规格源 Python，语义以源码为准）：
//    · POST /api/sessions/{sid}/export（app.py L608-633）：
//      dir 非空 → compactor.export_session_md（compactor.py L145-172，目录白名单
//      L2：compact_archive_dir / 系统临时目录内，否则 ValueError → 400）；
//      dir 缺省 → exporter.export_session_md（exporter.py L71-131，统一目录解析
//      + 工具步骤摘要 MD；ValueError → 404）
//    · POST /api/sessions/{sid}/summarize（app.py L641-693）：≤8000 字符拼接
//      非归档 user/assistant 消息 → connector chat（中文 prompt）→
//      save_session_summary（MD + DB）→ {ok, summary, saved_file}
//    · exporter.resolve_export_dir（exporter.py L37-68）：config default_export_dir
//      → 项目工作目录 → <data_root>/exports 兜底（导出永不失败）
//
//  压缩 compact 不在本文件——复用 P2-W4d2 的 NativeCompactor.compactSession
//  （NativeChatEndpoints.swift:425，流内 compact_auto 与面板端点共用）。
//

import Foundation

public enum NativeSessionOps {

    // ════════════════════════════════════════════════════════════
    // MARK: - export：exporter.resolve_export_dir（L37-68）
    // ════════════════════════════════════════════════════════════

    /// 配置优先（mkdir + 可写探测，失败回退）→ 项目工作目录 → 数据目录兜底。
    /// 与 W4b NativeDelegation.resolveExportDir / W4d1 NativeRoundtable.resolveExportDir 同构。
    public static func resolveExportDir(config: [String: JSONValue], db: NativeDatabase,
                                        projectId: String) -> URL {
        let cfgDir = config["default_export_dir"]?.string?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !cfgDir.isEmpty {
            let p = URL(fileURLWithPath: (cfgDir as NSString).expandingTildeInPath)
            try? FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
            let probe = p.appendingPathComponent(".subagent_export_probe")
            if (try? "ok".write(to: probe, atomically: true, encoding: .utf8)) != nil {
                try? FileManager.default.removeItem(at: probe)
                return p
            }
        }
        if let proj = try? db.getProject(projectId), !proj.workingDir.isEmpty {
            return URL(fileURLWithPath: (proj.workingDir as NSString).expandingTildeInPath)
        }
        // projectsRoot = <data_root>/projects → data_root/exports
        return db.projectsRoot.deletingLastPathComponent().appendingPathComponent("exports")
    }

    // ════════════════════════════════════════════════════════════
    // MARK: - export：exporter.export_session_md（L71-131，dir 缺省分支）
    // ════════════════════════════════════════════════════════════

    /// 统一目录导出（含工具步骤摘要）。会话不存在或无消息 → 404（ValueError 口径）。
    /// 返回 (path: 绝对路径, name: 文件名)。
    public static func exportSessionUnified(db: NativeDatabase, config: [String: JSONValue],
                                            projectId: String, sessionId: String,
                                            agentId: String) throws -> (path: String, name: String) {
        // title 仅在传 agent_id 时查（L81-87）
        var title = ""
        if !agentId.isEmpty {
            let sessions = try db.listSessions(projectId: projectId, agentId: agentId)
            if let s = sessions.first(where: { $0.id == sessionId }) { title = s.title ?? "" }
        }
        let msgs = try db.loadMessages(projectId: projectId, sessionId: sessionId)
        guard !msgs.isEmpty else {
            throw SidecarError.httpError(status: 404, detail: "会话不存在或无消息")
        }
        let outDir = resolveExportDir(config: config, db: db, projectId: projectId)
            .appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        let df2 = DateFormatter()
        df2.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let fname = "session-\(sessionId.prefix(8))-\(df.string(from: Date())).md"
        let path = outDir.appendingPathComponent(fname)

        var lines = ["# 会话导出",
                     "> 会话: \(title.isEmpty ? sessionId : title)",
                     "> 导出时间: \(df2.string(from: Date()))",
                     ""]
        for m in msgs {
            let role = m.role
            let content = m.content ?? ""
            let created = m.createdAt ?? ""
            if m.archived {
                // TS-120：已移入知识仓库的消息导出时以占位提示替代，不带出原文
                lines.append("**\(role)** (\(created))")
                lines.append("（此内容已移入知识仓库）")
                lines.append("")
                continue
            }
            // assistant + 非空 tool_steps 且全员 dict → 工具步骤摘要段（L113-124）；
            // 任一步骤非 dict 对齐 Python except 回落普通渲染。
            if role == "assistant", let steps = m.toolSteps, !steps.isEmpty,
               steps.allSatisfy({ if case .object = $0 { return true } else { return false } }) {
                lines.append("**\(role)** (\(created))")
                for st in steps {
                    guard case .object(let o) = st else { continue }
                    lines.append("- 🔧 [\(o["name"]?.string ?? "tool")] \(o["summary"]?.string ?? "")"
                        + "（\((o["ok"]?.bool ?? false) ? "成功" : "失败")）")
                }
                lines.append("")
                lines.append(content)
                lines.append("")
                continue
            }
            lines.append("**\(role)** (\(created))")
            lines.append(content)
            lines.append("")
        }
        try lines.joined(separator: "\n").write(to: path, atomically: false, encoding: .utf8)
        return (path.path, fname)
    }

    // ════════════════════════════════════════════════════════════
    // MARK: - export：compactor.export_session_md（L145-172，dir 白名单分支）
    // ════════════════════════════════════════════════════════════

    /// Path.resolve() / os.path.realpath(strict=False) 等价：~ 展开 + 逐段处理
    ///（存在的符号链接段即时 realpath、".." 词法弹出、不存在尾部原样保留）。
    /// ⚠️ 不可用 URL.resolvingSymlinksInPath——新 Foundation 不触文件系统，
    /// /var→/private/var、/tmp→/private/tmp 解析不出来（白名单会失真）。
    static func pyResolve(_ p: String) -> String {
        let expanded = (p as NSString).expandingTildeInPath
        let abs = expanded.hasPrefix("/") ? expanded
            : FileManager.default.currentDirectoryPath + "/" + expanded
        var resolved = "/"
        for comp in abs.split(separator: "/").map(String.init) {
            if comp == "." { continue }
            if comp == ".." {
                resolved = (resolved as NSString).deletingLastPathComponent
                if resolved.isEmpty { resolved = "/" }
                continue
            }
            resolved = resolved == "/" ? "/" + comp : resolved + "/" + comp
            var st = stat()
            if lstat(resolved, &st) == 0, (st.st_mode & S_IFMT) == S_IFLNK {
                var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
                if realpath(resolved, &buf) != nil { resolved = String(cString: buf) }
            }
        }
        return resolved
    }

    /// Path.is_relative_to 等价（组件级前缀，大小写按文件系统原样——macOS 同卷一致）。
    static func pyIsRelativeTo(_ child: String, _ root: String) -> Bool {
        child == root || child.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// 指定目录导出（M3 前置安全加固 L2：白名单外 → 400）。
    /// 返回文件绝对路径（端点 {ok, path}——无 name 键，面板侧 name 留空）。
    public static func exportSessionToDir(db: NativeDatabase, config: [String: JSONValue],
                                          projectId: String, sessionId: String,
                                          dir: String) throws -> String {
        let archiveRaw = config["compact_archive_dir"]?.string ?? "~/.subagent/compressed"
        let allowedRoots = [
            pyResolve(archiveRaw),
            pyResolve(NSTemporaryDirectory()),   // tempfile.gettempdir()
            pyResolve("/tmp"),
        ]
        let outDir = pyResolve(dir)
        guard allowedRoots.contains(where: { pyIsRelativeTo(outDir, $0) }) else {
            throw SidecarError.httpError(
                status: 400,
                detail: "导出目录不在允许范围内（须在归档目录或系统临时目录内）: \(dir)")
        }
        let msgs = try db.loadMessages(projectId: projectId, sessionId: sessionId)
        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        let df2 = DateFormatter()
        df2.dateFormat = "yyyy-MM-dd HH:mm:ss"
        // ⚠️ 文件名用完整 session_id（compactor 口径；exporter 统一目录分支才用前 8 位）
        let path = URL(fileURLWithPath: outDir)
            .appendingPathComponent("session-\(sessionId)-\(df.string(from: Date())).md")
        var lines = ["# 会话导出 \(sessionId)",
                     "> 时间: \(df2.string(from: Date()))",
                     ""]
        for m in msgs {
            // 单元素内嵌换行（Python lines.append(f"**{role}** ({ts})\n{content}\n") 逐字）
            lines.append("**\(m.role)** (\(m.createdAt ?? ""))\n\(m.content ?? "")\n")
        }
        try lines.joined(separator: "\n").write(to: path, atomically: false, encoding: .utf8)
        return path.path
    }

    // ════════════════════════════════════════════════════════════
    // MARK: - summarize（app.py L641-693）
    // ════════════════════════════════════════════════════════════

    /// 参与总结的会话原文上限（_SUMMARY_MAX_SOURCE_CHARS，L639）。
    public static let summaryMaxSourceChars = 8000

    /// 总结 prompt（L676-678 逐字）。
    static func summarizePrompt(source: String) -> String {
        "请为以下对话写一份简明的中文总结（300 字以内）：先一句话概括结论/成果，"
            + "再列出关键讨论点与产出（如有文件/代码产出请点名），最后给出遗留事项（如有）。\n"
            + "只输出总结本身，不要输出任何解释。\n\n---\n" + source
    }

    /// 会话自动总结：拼接 → connector chat → save_session_summary（MD+DB）。
    /// connector 注入缝（测试 stub；生产 = kernel.chatConnector——Python 走
    /// get_ollama_connector()，ollama 口径一致）。
    /// 错误口径：无消息 404 / 无可总结内容 422 / 模型空回 502 /
    /// connector 业务错误直通（Python raise 走全局异常处理）/ 其他异常 500「总结生成失败：…」。
    public static func summarizeSession(db: NativeDatabase,
                                        connector: any NativeChatConnector,
                                        config: [String: JSONValue],
                                        projectId: String, sessionId: String,
                                        agentId: String, model: String)
        async throws -> (summary: String, savedFile: String) {
        // model 语义（L649）：body.model 空串（falsy）→ config default_model → "qwen3.8"
        let m = model.isEmpty ? (config["default_model"]?.string ?? "qwen3.8") : model

        let msgs = try db.loadMessages(projectId: projectId, sessionId: sessionId)
        guard !msgs.isEmpty else {
            throw SidecarError.httpError(status: 404, detail: "会话不存在或无消息，无法总结")
        }
        var lines: [String] = []
        var total = 0
        for msg in msgs {
            guard msg.role == "user" || msg.role == "assistant" else { continue }
            if msg.archived { continue }   // TS-120：已移入知识仓库的消息不参与总结
            let content = msg.content ?? ""
            if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let seg = "\(msg.role): \(content)"
            if total + seg.count > summaryMaxSourceChars {
                lines.append("（更早内容已截断）")
                break
            }
            lines.append(seg)
            total += seg.count
        }
        guard !lines.isEmpty else {
            throw SidecarError.httpError(status: 422, detail: "会话无可总结的内容")
        }
        let prompt = summarizePrompt(source: lines.joined(separator: "\n"))

        let raw: String
        do {
            raw = try await connector.chat(model: m, messages: [[
                "role": .string("user"), "content": .string(prompt)]])
        } catch let e as NativeChatConnectorError {
            // Python（L683-684）：NetworkGuardError/OllamaAPIError 不包 500，
            // re-raise 走全局异常处理——NetworkGuardError → 403 exc.message
            //（app.py L227-231）；OllamaAPIError → exc.status_code + exc.message
            //（app.py L233-237）。
            switch e {
            case .guardDenied(_, let detail):
                throw SidecarError.httpError(status: 403, detail: detail)
            case .api(let status, let detail):
                throw SidecarError.httpError(status: status, detail: detail)
            case .network(let msg):
                throw SidecarError.httpError(status: 500, detail: "总结生成失败：\(msg)")
            case .openAI(let status, let message, _):
                // P3-W2b（openai_compat 口径）：401/403 = NetworkGuardError → 403；
                // 其余 = OllamaAPIError → exc.status_code。detail 用 exc.message 逐字。
                throw SidecarError.httpError(
                    status: (status == 401 || status == 403) ? 403 : status, detail: message)
            }
        } catch let e as SidecarError {
            throw e
        } catch {
            throw SidecarError.httpError(status: 500, detail: "总结生成失败：\(error)")
        }
        let summary = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else {
            throw SidecarError.httpError(status: 502, detail: "模型未返回总结内容，请重试")
        }
        let fpath = try db.saveSessionSummary(projectId: projectId, sessionId: sessionId,
                                              agentId: agentId, summary: summary)
        return (summary, fpath)
    }
}

// ════════════════════════════════════════════════════════════
// MARK: - export_workgroup_json（exporter.py L134-180，P3-W6 翻原生）
// ════════════════════════════════════════════════════════════

/// TS-121 工作组 JSON 导出（POST /api/projects/{pid}/export-workgroup 等价，
/// app.py L1950-1958）：项目元信息 + 全部 Agent 配置 + 每 Agent 会话列表与消息
/// + 任务队列 + 圆桌讨论 → <导出目录>/workgroup/工作组-<名>-<ts>.json。
/// 纯本地读取不联网；项目不存在 → ValueError 口径 404（端点 HTTPException 同文案）。
public enum NativeWorkgroupExport {

    /// exporter.export_workgroup_json 逐行为。返回 (path: 绝对路径, name: 文件名)。
    /// dict 键名逐字对齐 Python store 层返回（get_project/list_agent_configs/
    /// list_sessions/load_messages/list_agent_tasks/_rt_row_to_dict/
    /// list_roundtable_messages）——导出文件是用户档案，键名即契约。
    public static func export(db: NativeDatabase, config: [String: JSONValue],
                              projectId: String) throws -> (path: String, name: String) {
        guard let project = try db.getProject(projectId) else {
            throw SidecarError.httpError(status: 404, detail: "项目不存在")
        }

        var agents: [JSONValue] = []
        for cfg in try db.listAgentConfigs(projectId: projectId) {
            var sessions: [JSONValue] = []
            for s in try db.listSessions(projectId: projectId, agentId: cfg.id) {
                let msgs = try db.loadMessages(projectId: projectId, sessionId: s.id)
                sessions.append(.object([
                    "id": .string(s.id),
                    "title": s.title.map { .string($0) } ?? .null,
                    "created_at": s.createdAt.map { .string($0) } ?? .null,
                    "updated_at": s.updatedAt.map { .string($0) } ?? .null,
                    "message_count": .int(s.messageCount),
                    "messages": .array(msgs.map(messageJSON)),
                ]))
            }
            agents.append(.object([
                "id": .string(cfg.id),
                "name": .string(cfg.name),
                "role": cfg.role.map { .string($0) } ?? .null,
                "system_prompt": cfg.systemPrompt.map { .string($0) } ?? .null,
                "model_name": cfg.modelName.map { .string($0) } ?? .null,
                "type_": .string(cfg.type_),
                "parent_agent_id": cfg.parentAgentId.map { .string($0) } ?? .null,
                "sessions": .array(sessions),
            ]))
        }

        let tasks = try db.listAgentTasks(projectId: projectId, limit: 200)
        let roundtables = try db.listRoundtables(projectId: projectId, limit: 50)
        var rts: [JSONValue] = []
        for rt in roundtables {
            let msgs = try db.listRoundtableMessages(projectId: projectId, rtId: rt.id)
            rts.append(.object(rtJSON(rt, messages: msgs)))
        }

        let payload: [String: JSONValue] = [
            "export_type": .string("vetarai_workgroup"),
            "version": .int(1),
            "exported_at": .string(pyNow("yyyy-MM-dd HH:mm:ss")),
            "project": .object([
                "id": .string(project.id),
                "name": .string(project.name),
                "working_dir": .string(project.workingDir),
            ]),
            "agents": .array(agents),
            "task_queue": .array(tasks.map(taskJSON)),
            "roundtables": .array(rts),
        ]

        let outDir = NativeSessionOps.resolveExportDir(config: config, db: db,
                                                       projectId: projectId)
            .appendingPathComponent("workgroup")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let ts = pyNow("yyyyMMdd-HHmmss")
        // Python: (c.isalnum() or c in " _-（）()")[:20] or "project"；isalnum 为
        // Unicode 口径（中文保留）——Swift isLetter/isNumber 同 Unicode 语义。
        // H8 裁决（0.7.4）：[:20] 对齐 Python 按 code point——用 unicodeScalars
        // 视图取前 20（Swift prefix(20) 按 grapheme 簇，👨‍👩‍👧 类簇计数不同；
        // unicodeScalars 恒为合法标量，切不出非法编码/半代理对）。
        let safeName = String(String(project.name.isEmpty ? "project" : project.name)
            .filter { $0.isLetter || $0.isNumber || " _-（）()".contains($0) }
            .unicodeScalars.prefix(20))
        let fname = "工作组-\(safeName.isEmpty ? "project" : safeName)-\(ts).json"
        let path = outDir.appendingPathComponent(fname)
        // json.dumps(ensure_ascii=False, indent=2) 逐字节等价（NativeJSONWriter 保真复刻）
        try Data(NativeJSONWriter.dumps(.object(payload)).utf8)
            .write(to: path, options: .atomic)
        return (path.path, fname)
    }

    /// datetime.now().strftime(fmt) 等价（本地时区）。
    private static func pyNow(_ fmt: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = fmt
        return f.string(from: Date())
    }

    /// load_messages 行 dict（键序对齐 Python L819-838 的条件追加顺序）。
    private static func messageJSON(_ r: NativeDatabase.MessageRow) -> JSONValue {
        var obj: [String: JSONValue] = [
            "id": .int(r.id),
            "role": .string(r.role),
            "content": r.content.map { .string($0) } ?? .null,
            "model_used": r.modelUsed.map { .string($0) } ?? .null,
            "created_at": r.createdAt.map { .string($0) } ?? .null,
        ]
        if let images = r.images { obj["images"] = .array(images) }
        if let steps = r.toolSteps { obj["tool_steps"] = .array(steps) }
        if r.truncated { obj["truncated"] = .bool(true) }
        if let pec = r.promptEvalCount { obj["prompt_eval_count"] = .int(pec) }
        if r.archived { obj["archived"] = .bool(true) }
        if r.stopped { obj["stopped"] = .bool(true) }
        return .object(obj)
    }

    /// list_agent_tasks 行 dict（L969-975 键序逐字；report 解析失败 {"raw": …} 分支
    /// 由 DB 层 tolerantJSON 先行归一——原生行 report 已是 JSONValue?）。
    private static func taskJSON(_ r: NativeDatabase.AgentTaskRow) -> JSONValue {
        .object([
            "id": .string(r.id),
            "parent_agent_id": .string(r.parentAgentId),
            "parent_session_id": .string(r.parentSessionId),
            "target_agent_id": .string(r.targetAgentId),
            "target_agent_name": .string(r.targetAgentName),
            "task": .string(r.task),
            "expect": .string(r.expect),
            "status": .string(r.status),
            "report": r.report ?? .null,
            "fail_reason": r.failReason.map { .string($0) } ?? .null,
            "validation_failures": .int(r.validationFailures),
            "session_id": r.sessionId.map { .string($0) } ?? .null,
            "created_at": r.createdAt.map { .string($0) } ?? .null,
            "updated_at": r.updatedAt.map { .string($0) } ?? .null,
        ])
    }

    /// _rt_row_to_dict（L1023-1028）+ {**rt, "messages": …}（exporter.py L168-169）。
    private static func rtJSON(_ r: NativeRoundtableRow,
                               messages: [NativeRoundtableMessageRow]) -> [String: JSONValue] {
        [
            "id": .string(r.id),
            "project_id": .string(r.projectId),
            "topic": .string(r.topic),
            "participants": .array(r.participants.map { .object($0) }),
            "moderator": .string(r.moderator),
            "moderator_agent_id": r.moderatorAgentId.map { .string($0) } ?? .null,
            "max_rounds": .int(Int64(r.maxRounds)),
            "round": .int(Int64(r.round)),
            "status": .string(r.status),
            "minutes": r.minutes.map { .string($0) } ?? .null,
            "summary": r.summary.map { .string($0) } ?? .null,
            "created_at": r.createdAt.map { .string($0) } ?? .null,
            "updated_at": r.updatedAt.map { .string($0) } ?? .null,
            "attachments": .array(r.attachments.map { .object($0) }),
            "messages": .array(messages.map { m in
                .object([
                    "id": .int(m.id),
                    "rt_id": .string(m.rtId),
                    "round": .int(Int64(m.round)),
                    "agent_id": .string(m.agentId),
                    "agent_name": .string(m.agentName),
                    "content": m.content.map { .string($0) } ?? .null,
                    "ok": .bool(m.ok),
                    "created_at": m.createdAt.map { .string($0) } ?? .null,
                ])
            }),
        ]
    }
}
