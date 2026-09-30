//
//  NativeArchive.swift
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

//  逐行为移植 subagent/sidecar/agent_engine/loop.py L67-150 的 archive_work_unit
//  （⛔ 只读行为规格源；语义分歧以 Python 源码为准）：
//    · 【归档点自追踪】以"最后一条已归档消息"为上次归档点，打包其后全部未归档消息；
//      archived 标记本身就是归档点，无需额外状态字段
//    · 【首条用户消息永不归档】它是任务总指令，保留它 Agent 才能始终看到总任务
//    · 【防滥用】候选消息 < ARCHIVE_MIN_MESSAGES(4) 条时拒绝（避免上下文被切碎）
//    · 【先落盘后归档】由调用方（提示词纪律）保证产出已写盘；本函数只搬移对话
//    · 正文组装与 0.3.0 手动转移同构（**角色**：内容；首行可选 **单元摘要**）
//    · source 复用 'chat'（knowledge_entries.source 的 CHECK 约束只允许 chat/manual，
//      归档本质就是"把对话搬进仓库"，靠 category="工作单元归档" 区分来源）
//    · prune_missing() 外部删除对账先行（与既有端点一致，不返回幽灵条目）
//
//  W4c 装配：NativeWorkUnitArchiver 真实现（NativeChatRuntime.swift 协议），
//  替换 NativeAgentLoop.routeArchive 的「归档编排装配于后续波次」占位。
//  存储面：loadMessages/archiveMessages 走 W0 NativeDatabase（session_messages 表），
//  知识条目写入走 W1 NativeKnowledgeStore（index.db + .md 文件，含 CHECK 约束同源）。
//

import Foundation

public final class NativeWorkUnitArchiveExecutor: NativeWorkUnitArchiver, @unchecked Sendable {

    /// ARCHIVE_MIN_MESSAGES（loop.py L64：距上次归档点不足此条数则拒绝归档）。
    public static let archiveMinMessages = 4

    private let database: NativeDatabase
    private let knowledge: NativeKnowledgeStore

    public init(database: NativeDatabase, knowledge: NativeKnowledgeStore) {
        self.database = database
        self.knowledge = knowledge
    }

    /// archive_work_unit(project_id, session_id, title, summary, scope="project")。
    /// 返回 {"ok": True, "entry_id", "title", "archived", ...} 或 {"ok": False, "error": 原因}。
    public func archiveWorkUnit(projectId: String, sessionId: String,
                                title: String, summary: String, scope: String) -> [String: JSONValue] {
        func err(_ message: String) -> [String: JSONValue] {
            ["ok": .bool(false), "error": .string(message)]
        }
        if projectId.isEmpty || sessionId.isEmpty {
            return err("缺少 project_id / session_id，无法归档")
        }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty {
            return err("archive_work_unit 需要 title（工作单元名称）")
        }

        let msgs: [NativeDatabase.MessageRow]
        do {
            msgs = try database.loadMessages(projectId: projectId, sessionId: sessionId)
        } catch {
            // Python load_messages 异常会穿透到路由层 {"ok":False,"error":f"归档失败：{e}"}；
            // 执行器内直接给出同构失败（路由层 try/except 语义内联）。
            return err("归档失败：\(error)")
        }
        if msgs.isEmpty {
            return err("会话中还没有任何消息，无需归档")
        }

        // 首条用户消息的 id：永不归档（任务总指令）
        let firstUserId = msgs.first(where: {
            $0.role == "user" && !($0.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })?.id

        // 上次归档点 = 最后一条已归档消息的位置；其后未归档的才是本次候选
        var lastArchivedIdx = -1
        for (i, m) in msgs.enumerated() where m.archived { lastArchivedIdx = i }
        var candidates: [NativeDatabase.MessageRow] = []
        for m in msgs[(lastArchivedIdx + 1)...] {
            if m.archived { continue }
            if let fid = firstUserId, m.id == fid { continue }     // 首条用户消息永不归档
            let content = (m.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if content.isEmpty { continue }                        // 空内容不进仓库
            candidates.append(m)
        }

        if candidates.count < Self.archiveMinMessages {
            return err("距上次归档点只有 \(candidates.count) 条消息（不足 \(Self.archiveMinMessages) 条），"
                + "已拒绝归档。请在【一个工作单元真正完成、且产出已落盘】后再调用；"
                + "频繁归档会把上下文切碎，反而丢失必要信息。")
        }

        // 组装正文（与 0.3.0 手动转移同构：角色: 内容）
        var bodyLines: [String] = summary.isEmpty ? [] : ["**单元摘要**：\(summary)"]
        for m in candidates {
            let content = (m.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty {
                bodyLines.append("**\(m.role)**：\(content)")
            }
        }
        let body = bodyLines.joined(separator: "\n\n")
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return err("候选消息无文本内容，未归档")
        }

        _ = knowledge.pruneMissing()   // 外部删除对账（不返回幽灵条目）
        // source 复用 'chat'：归档本质就是"把对话搬进仓库"（CHECK 约束同源）；
        // 靠 category="工作单元归档" 区分来源。
        guard let entry = knowledge.addEntry(
            scope: scope, projectId: scope == "project" ? projectId : nil,
            title: title, body: body, category: "工作单元归档",
            keywords: [title], source: "chat") else {
            return err("知识条目写入失败（知识库目录不可用），本次未归档")
        }

        let ids = candidates.map { $0.id }
        let archived: Int
        do {
            archived = try database.archiveMessages(projectId: projectId, messageIds: ids)
        } catch {
            return err("归档失败：\(error)")
        }
        return [
            "ok": .bool(true),
            "entry_id": .string(entry.id),
            "title": .string(title),
            "file_path": .string(entry.filePath),
            "archived": .int(Int64(archived)),
            "kept_first_user_message": .bool(firstUserId != nil),
            "note": .string("本单元对话已移入知识仓库并脱离上下文；需要时可用 search_knowledge 搜回。"),
        ]
    }
}
