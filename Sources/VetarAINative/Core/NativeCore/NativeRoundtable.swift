//
//  NativeRoundtable.swift
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

//  逐行为移植 subagent/sidecar/agent_engine/roundtable.py（421 行）+
//  subagent/sidecar/storage/store.py 圆桌段（L993-1090，⛔ 只读行为规格源；
//  语义分歧以 Python 源码为准）：
//    · 决策 6：主持可选用户（默认）或 AI；用户主持每轮后 waiting_user（继续/结束
//      权 100% 在用户）；AI 主持判定共识 → confirm_end（仍需用户点"确认结束"），
//      未共识且未达上限 → 锁内自动续轮，达上限 → waiting_user
//    · 决策 7：发言基于共享"讨论纪要"（共识/分歧/各方观点），非共享会话历史
//    · 弱模型兼容（H14~H17 教训）：纪要/总结/共识判定纯文本宽松判定，不依赖严格格式
//    · 轮次串行（_ROUND_LOCK → roundGate，防并发抢 Ollama）；发言失败跳过继续
//      不中断；内核不设超时（模块文档 L25 明示——「创建 600s」是面板 HTTP
//      客户端口径，Phase 1 已放宽并锁定在 RoundtableCreateTimeoutTests）
//    · checkpoint-067 N-1 手动停止：request_cancel 置标志，执行循环在检查点
//      （每次发言前/纪要更新前/续轮前）检测即中止，已完成发言保留，状态置
//      waiting_user，清标志后返回
//
//  偏差（汇报清单同步）：
//    ① Python asyncio.Lock → 复用 W4b NativeDelegationGate（FIFO；等待中被取消
//       返回 false，调用方抛 CancellationError——DBG-140 先例的登记锁内
//       isCancelled 自查兜底已内建于 Gate）。
//    ② 端点层（app.py api_create_roundtable 的附件预处理：base64 解码/2MB·
//       3000 字·12000 字上限/视觉识别/原始文件落盘 work/roundtables/attachments）
//       不在内核——本引擎消费的 attachments 已是解析后的元数据（name/text/
//       truncated...），与 rt_mod.create_and_start 入参口径一致；端点装配属
//       路由翻转波次。
//    ③ max_rounds 的 `except (TypeError, ValueError) → 5` 分支对应 Python 动态
//       入参（字符串等）；Swift Int 型别已在编译期排除，仅保留 int 后的
//       max(2, min(x, 10)) 钳制。
//    ④ Python len/str 切片按码点；Swift String.prefix 按 Character（grapheme
//       cluster）——CJK 场景一致，emoji 组合序列边界有理论差（导出文件名
//       安全截断用，无行为断言依赖）。
//

import Foundation

/// ValueError 等价（API 层转 400 的载体）。
public struct NativeRoundtableError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

// ════════════════════════════════════════════════════════════
// MARK: - 提示词模板与纯函数（roundtable.py L58-129）+ 取消标志登记（L44-56）
// ════════════════════════════════════════════════════════════

public enum NativeRoundtable {

    // ── 模板逐字（弱模型兼容：宽松文本判定，不依赖严格格式）──

    /// INITIAL_MINUTES_TMPL
    public static func initialMinutesTmpl(topic: String) -> String {
        "【议题】\(topic)\n【共识】（尚无）\n【分歧】（尚无）\n【各方观点】（首轮待发言）"
    }

    /// SPEAK_PROMPT_TMPL
    public static func speakPrompt(topic: String, materials: String, minutes: String,
                                   name: String, role: String) -> String {
        "【圆桌讨论】\n议题：\(topic)\n\(materials)当前讨论纪要：\n\(minutes)\n\n"
            + "你是 \(name)（角色：\(role)）。请从你的角色立场出发，对议题发表本轮观点：\n"
            + "1) 明确的观点或结论 2) 理由或依据。\n"
            + "不要复述他人已说过的内容；同意或反对某人时请指名。发言控制在 300 字以内。"
    }

    /// MINUTES_UPDATE_PROMPT_TMPL
    public static func minutesUpdatePrompt(topic: String, minutes: String,
                                           speeches: String) -> String {
        "你是圆桌讨论的纪要员。根据议题与以下最新一轮的全部发言，更新讨论纪要。\n"
            + "议题：\(topic)\n\n旧纪要：\n\(minutes)\n\n本轮新发言：\n\(speeches)\n\n"
            + "请输出更新后的完整纪要，必须且仅包含三段：\n"
            + "【共识】…\n【分歧】…\n【各方观点】…\n"
            + "总字数不超过 500 字；只输出纪要正文，不要其他说明。"
    }

    /// CONSENSUS_PROMPT_TMPL
    public static func consensusPrompt(name: String, role: String, topic: String,
                                       minutes: String) -> String {
        "你是圆桌讨论的主持人（\(name)，角色：\(role)）。议题：\(topic)\n"
            + "当前纪要：\n\(minutes)\n\n请判断各方是否已就议题的核心达成共识。\n"
            + "第一行必须输出：达成共识：是 或 达成共识：否（二选一）\n"
            + "第二行用一句话说明理由。只输出这两行。"
    }

    /// SUMMARY_PROMPT_TMPL
    public static func summaryPrompt(topic: String, minutes: String,
                                     speeches: String) -> String {
        "你是圆桌讨论的总结人。议题：\(topic)\n最终纪要：\n\(minutes)\n\n"
            + "各方全部发言：\n\(speeches)\n\n请输出讨论总结，必须且仅包含四段：\n"
            + "【共识】…\n【分歧】…\n【结论】…\n【建议】…\n"
            + "总字数不超过 800 字；只输出总结正文，不要其他说明。"
    }

    // ── 小工具 ──

    /// Python str.strip()（首尾空白；对齐 W4b pyTrim 口径）。
    static func pyTrim(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Python 真值判定（att.get("truncated") 等）。
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

    /// _build_materials_text：从附件元数据重构背景材料文本（每轮发言独立注入，
    /// 不依赖纪要保留——纪要每轮会被模型重写，材料若只存纪要里会在更新后丢失）。
    public static func buildMaterialsText(_ attachments: [[String: JSONValue]]?) -> String {
        guard let attachments, !attachments.isEmpty else { return "" }
        var parts: [String] = []
        for att in attachments {
            let text = pyTrim(att["text"]?.string ?? "")
            if text.isEmpty { continue }
            let truncated = truthy(att["truncated"]) ? "（超长已截断）" : ""
            parts.append("【附件：\(att["name"]?.string ?? "未命名")】\(truncated)\n\(text)")
        }
        if parts.isEmpty { return "" }
        return "背景材料（用户提供的参考文件，请以其为依据）：\n" + parts.joined(separator: "\n\n") + "\n\n"
    }

    /// _initial_minutes：初始纪要（TS-109 增强 H18-3：议题附件文本注入，供各
    /// 参与者发言时参考）。注意与 buildMaterialsText 的差异：附件名缺省 ''、
    /// 材料段前缀带【背景材料】标题、无尾部 \n\n。
    public static func initialMinutes(topic: String,
                                      attachments: [[String: JSONValue]]? = nil) -> String {
        var minutes = initialMinutesTmpl(topic: topic)
        let materials = buildMaterialsText(attachments)
        if !materials.isEmpty, let attachments {
            let body = attachments
                .filter { !pyTrim($0["text"]?.string ?? "").isEmpty }
                .map { a in
                    "【附件：\(a["name"]?.string ?? "")】"
                        + (truthy(a["truncated"]) ? "（超长已截断）" : "")
                        + "\n\(pyTrim(a["text"]?.string ?? ""))"
                }
                .joined(separator: "\n\n")
            minutes += "\n\n【背景材料】（用户提供的参考文件，讨论时请以其为依据）\n" + body
        }
        return minutes
    }

    // ── 取消标志登记（checkpoint-067 N-1：_CANCEL_FLAGS dict 等价）──

    private static let cancelLock = NSLock()
    private static var cancelFlags: Set<String> = []

    /// request_cancel：置取消标志（执行循环在检查点检测即中止）。
    public static func requestCancel(_ rtId: String) {
        cancelLock.lock(); cancelFlags.insert(rtId); cancelLock.unlock()
    }

    /// clear_cancel：清取消标志。
    public static func clearCancel(_ rtId: String) {
        cancelLock.lock(); cancelFlags.remove(rtId); cancelLock.unlock()
    }

    /// _is_cancelled：查取消标志。
    public static func isCancelled(_ rtId: String) -> Bool {
        cancelLock.lock(); defer { cancelLock.unlock() }
        return cancelFlags.contains(rtId)
    }

    /// 测试用：清空全部取消标志（对齐各套件 setUp 复位纪律）。
    public static func resetSharedState() {
        cancelLock.lock(); cancelFlags.removeAll(); cancelLock.unlock()
    }
}

// ════════════════════════════════════════════════════════════
// MARK: - 圆桌行级 CRUD（store.py L993-1090；扩展 NativeDatabase，复用连接纪律）
// ════════════════════════════════════════════════════════════

/// roundtables 行（_rt_row_to_dict 等价；participants/attachments 为 JSON 数组）。
public struct NativeRoundtableRow: Equatable, Sendable {
    public let id: String
    public let projectId: String
    public let topic: String
    public let participants: [[String: JSONValue]]
    public let moderator: String
    public let moderatorAgentId: String?
    public let maxRounds: Int
    public let round: Int
    public let status: String
    public let minutes: String?
    public let summary: String?
    public let createdAt: String?
    public let updatedAt: String?
    public let attachments: [[String: JSONValue]]
}

/// roundtable_messages 行（list_roundtable_messages 元素等价）。
public struct NativeRoundtableMessageRow: Equatable, Sendable {
    public let id: Int64
    public let rtId: String
    public let round: Int
    public let agentId: String
    public let agentName: String
    public let content: String?
    public let ok: Bool
    public let createdAt: String?
}

extension NativeDatabase {

    private static let rtSelect =
        "SELECT id, project_id, topic, participants, moderator, moderator_agent_id, "
        + "max_rounds, round, status, minutes, summary, created_at, updated_at, attachments "
        + "FROM roundtables"

    /// JSON 数组宽容解析（json.loads try/except → [] 等价；非数组亦按 []）。
    private static func jsonArray(_ text: String?) -> [[String: JSONValue]] {
        guard let text, !text.isEmpty,
              case .array(let arr) = tolerantJSON(text) else { return [] }
        return arr.compactMap { if case .object(let o) = $0 { return o } ; return nil }
    }

    private static func rtRow(_ r: [SQLiteValue]) -> NativeRoundtableRow {
        func s(_ i: Int) -> String? { if case .text(let t) = r[i] { return t } ; return nil }
        func i(_ i: Int) -> Int64? { if case .integer(let v) = r[i] { return v } ; return nil }
        return NativeRoundtableRow(
            id: s(0) ?? "", projectId: s(1) ?? "", topic: s(2) ?? "",
            participants: jsonArray(s(3)),
            moderator: s(4) ?? "user", moderatorAgentId: s(5),
            maxRounds: Int(i(6) ?? 5), round: Int(i(7) ?? 0),
            status: s(8) ?? "running", minutes: s(9), summary: s(10),
            createdAt: s(11), updatedAt: s(12), attachments: jsonArray(s(13)))
    }

    /// create_roundtable：uuid + 插入（participants/attachments 经
    /// json.dumps(ensure_ascii=False) 落库；attachments None → "[]"）。
    @discardableResult
    public func createRoundtable(projectId: String, topic: String,
                                 participants: [[String: JSONValue]],
                                 moderator: String, moderatorAgentId: String?,
                                 maxRounds: Int, minutes: String,
                                 attachments: [[String: JSONValue]]? = nil) throws -> String {
        let rtId = Self.newUUID()
        try withWriteConn(global: false, projectId: projectId) { conn in
            try conn.execute(
                "INSERT INTO roundtables (id, project_id, topic, participants, moderator, "
                    + "moderator_agent_id, max_rounds, minutes, attachments) "
                    + "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                [.text(rtId), .text(projectId), .text(topic),
                 .text(Self.dumpsUTF8(.array(participants.map { .object($0) }))),
                 .text(moderator),
                 moderatorAgentId.map { SQLiteValue.text($0) } ?? .null,
                 .integer(Int64(maxRounds)), .text(minutes),
                 .text(Self.dumpsUTF8(.array((attachments ?? []).map { .object($0) })))])
        }
        return rtId
    }

    /// get_roundtable：单行或 nil。
    public func getRoundtable(projectId: String, rtId: String) throws -> NativeRoundtableRow? {
        try withReadConn(global: false, projectId: projectId) { conn in
            guard let row = try conn.queryOne(
                Self.rtSelect + " WHERE id = ? AND project_id = ?",
                [.text(rtId), .text(projectId)]) else { return nil }
            return Self.rtRow(row)
        }
    }

    /// list_roundtables：created_at DESC, rowid DESC LIMIT。
    public func listRoundtables(projectId: String, limit: Int = 20) throws -> [NativeRoundtableRow] {
        try withReadConn(global: false, projectId: projectId) { conn in
            try conn.query(
                Self.rtSelect + " WHERE project_id = ? ORDER BY created_at DESC, rowid DESC LIMIT ?",
                [.text(projectId), .integer(Int64(limit))]).map(Self.rtRow)
        }
    }

    /// update_roundtable：字段白名单显式分支（round/status/minutes/summary；
    /// 禁止 SET 拼接——B12 教训），各分支附带 updated_at = datetime('now')。
    @discardableResult
    public func updateRoundtable(projectId: String, rtId: String,
                                 round: Int? = nil, status: String? = nil,
                                 minutes: String? = nil, summary: String? = nil) throws -> Bool {
        var updated = false
        try withWriteConn(global: false, projectId: projectId) { conn in
            if let round {
                updated = try conn.execute(
                    "UPDATE roundtables SET round = ?, updated_at = datetime('now') "
                        + "WHERE id = ? AND project_id = ?",
                    [.integer(Int64(round)), .text(rtId), .text(projectId)]) > 0 || updated
            }
            if let status {
                updated = try conn.execute(
                    "UPDATE roundtables SET status = ?, updated_at = datetime('now') "
                        + "WHERE id = ? AND project_id = ?",
                    [.text(status), .text(rtId), .text(projectId)]) > 0 || updated
            }
            if let minutes {
                updated = try conn.execute(
                    "UPDATE roundtables SET minutes = ?, updated_at = datetime('now') "
                        + "WHERE id = ? AND project_id = ?",
                    [.text(minutes), .text(rtId), .text(projectId)]) > 0 || updated
            }
            if let summary {
                updated = try conn.execute(
                    "UPDATE roundtables SET summary = ?, updated_at = datetime('now') "
                        + "WHERE id = ? AND project_id = ?",
                    [.text(summary), .text(rtId), .text(projectId)]) > 0 || updated
            }
        }
        return updated
    }

    /// app.py L1935-1936 附件落盘路径写回（`UPDATE roundtables SET attachments = ? WHERE id = ?`；
    /// Python 不带 project_id 条件——id 为 uuid 全局唯一，此处同口径）。
    @discardableResult
    public func updateRoundtableAttachments(projectId: String, rtId: String,
                                            attachments: [[String: JSONValue]]) throws -> Bool {
        try withWriteConn(global: false, projectId: projectId) { conn in
            try conn.execute(
                "UPDATE roundtables SET attachments = ? WHERE id = ?",
                [.text(NativeDatabase.dumpsUTF8(.array(attachments.map { .object($0) }))),
                 .text(rtId)]) > 0
        }
    }

    /// add_roundtable_message：发言落库（ok → INTEGER 1/0）。
    public func addRoundtableMessage(projectId: String, rtId: String, round: Int,
                                     agentId: String, agentName: String,
                                     content: String, ok: Bool = true) throws {        try withWriteConn(global: false, projectId: projectId) { conn in
            try conn.execute(
                "INSERT INTO roundtable_messages (rt_id, round, agent_id, agent_name, content, ok) "
                    + "VALUES (?, ?, ?, ?, ?, ?)",
                [.text(rtId), .integer(Int64(round)), .text(agentId), .text(agentName),
                 .text(content), .integer(ok ? 1 : 0)])
        }
    }

    /// list_roundtable_messages：ORDER BY id（时间序）。
    public func listRoundtableMessages(projectId: String,
                                       rtId: String) throws -> [NativeRoundtableMessageRow] {
        try withReadConn(global: false, projectId: projectId) { conn in
            try conn.query(
                "SELECT id, rt_id, round, agent_id, agent_name, content, ok, created_at "
                    + "FROM roundtable_messages WHERE rt_id = ? ORDER BY id",
                [.text(rtId)]).map { r in
                    func s(_ i: Int) -> String? {
                        if case .text(let t) = r[i] { return t } ; return nil
                    }
                    func i(_ i: Int) -> Int64 {
                        if case .integer(let v) = r[i] { return v } ; return 0
                    }
                    return NativeRoundtableMessageRow(
                        id: i(0), rtId: s(1) ?? "", round: Int(i(2)),
                        agentId: s(3) ?? "", agentName: s(4) ?? "",
                        content: s(5), ok: i(6) != 0, createdAt: s(7))
                }
        }
    }

    /// delete_roundtable：删圆桌及其全部发言记录（全清）。
    @discardableResult
    public func deleteRoundtable(projectId: String, rtId: String) throws -> Bool {
        try withWriteConn(global: false, projectId: projectId) { conn in
            try conn.execute("DELETE FROM roundtable_messages WHERE rt_id = ?", [.text(rtId)])
            return try conn.execute(
                "DELETE FROM roundtables WHERE id = ? AND project_id = ?",
                [.text(rtId), .text(projectId)]) > 0
        }
    }
}

// ════════════════════════════════════════════════════════════
// MARK: - 圆桌执行引擎（create_and_start / run_round / continue / finish / export）
// ════════════════════════════════════════════════════════════

public final class NativeRoundtableEngine: @unchecked Sendable {

    /// _ROUND_LOCK 等价（轮次串行，防并发抢 Ollama）。复用 W4b FIFO Gate：
    /// 等待中被取消返回 false（DBG-140 先例），调用方抛 CancellationError。
    public static let roundGate = NativeDelegationGate()

    private let db: NativeDatabase
    private let connector: any NativeChatConnector
    private let configProvider: @Sendable () -> [String: JSONValue]
    /// 0.7.7 W6：vmodel 发言 agentic 执行缝（nil = 0.7.6 口径单轮聚合——
    /// 测试直构引擎缺省不变；生产由 NativeKernel 装配真回路）。
    private let vmodelAgentic: NativeVModelAgenticFn?

    public init(db: NativeDatabase, connector: any NativeChatConnector,
                configProvider: @escaping @Sendable () -> [String: JSONValue] = { [:] },
                vmodelAgentic: NativeVModelAgenticFn? = nil) {
        self.db = db
        self.connector = connector
        self.configProvider = configProvider
        self.vmodelAgentic = vmodelAgentic
    }

    /// Python `p.get("model_name") or "qwen3.8"`（空串亦回退）。
    private static func modelOrDefault(_ v: JSONValue?) -> String {
        let m = v?.string ?? ""
        return m.isEmpty ? "qwen3.8" : m
    }

    /// Python `p.get("role") or "专家"` / `or "主持人"`（空串亦回退）。
    private static func roleOr(_ v: JSONValue?, _ fallback: String) -> String {
        let r = v?.string ?? ""
        return r.isEmpty ? fallback : r
    }

    // MARK: create_and_start（L132-165）

    /// 创建圆桌并执行第一轮。校验失败抛 NativeRoundtableError（API 层转 400）。
    @discardableResult
    public func createAndStart(projectId: String, topic: String, agentIds: [String],
                               moderator: String = "user", moderatorAgentId: String? = nil,
                               maxRounds: Int = 5,
                               attachments: [[String: JSONValue]]? = nil) async throws
        -> NativeRoundtableRow {
        let topic = NativeRoundtable.pyTrim(topic)
        if topic.isEmpty { throw NativeRoundtableError("议题不能为空") }
        let agentsAll = Dictionary(uniqueKeysWithValues:
            try db.listAgentConfigs(projectId: projectId).map { ($0.id, $0) })
        var participants: [[String: JSONValue]] = []
        for aid in agentIds {
            guard let a = agentsAll[aid] else {
                throw NativeRoundtableError("参与者不存在: \(aid)")
            }
            participants.append([
                "id": .string(a.id), "name": .string(a.name),
                "role": a.role.map { JSONValue.string($0) } ?? .null,
                "model_name": a.modelName.map { JSONValue.string($0) } ?? .null,
            ])
        }
        if participants.count < 2 { throw NativeRoundtableError("圆桌至少需要 2 个参与者") }
        if moderator != "user" && moderator != "ai" {
            throw NativeRoundtableError("moderator 必须是 user 或 ai")
        }
        if moderator == "ai" {
            let ids = participants.compactMap { $0["id"]?.string }
            guard let mid = moderatorAgentId, ids.contains(mid) else {
                throw NativeRoundtableError("AI 主持时 moderator_agent_id 必须是参与者之一")
            }
        }
        // Python try int(max_rounds) except → 5：Int 型别已排除非数值入参（偏差③）
        let clampedRounds = max(2, min(maxRounds, 10))

        let rtId = try db.createRoundtable(
            projectId: projectId, topic: topic, participants: participants,
            moderator: moderator, moderatorAgentId: moderatorAgentId,
            maxRounds: clampedRounds,
            minutes: NativeRoundtable.initialMinutes(topic: topic, attachments: attachments),
            attachments: attachments)
        _ = try await runRound(projectId: projectId, rtId: rtId)
        guard let row = try db.getRoundtable(projectId: projectId, rtId: rtId) else {
            throw NativeRoundtableError("圆桌不存在")
        }
        return row
    }

    // MARK: 发言 / 纪要 / 共识判定（L168-214）

    /// _one_speech：单个参与者的一轮发言（单轮非流式；返回 strip 后文本）。
    /// 0.7.7 W6：vmodel 角色且已装配 agentic 缝 → 走工具调用回路（多步 + 知识库/
    /// 文件等既有工具集，与主会话同一注册表口径）；降级时回路返回单轮聚合文本
    /// + 中文提示，提示以 [⚠️ …] 并入发言记录透出（诚信红线：不静默降级）。
    /// 取消（requestCancel 标志 / Task 取消）→ CancellationError 原样上抛，
    /// 由 runRoundInner 按取消语义收尾（不记发言失败占位）。
    private func oneSpeech(model: String, topic: String, minutes: String,
                           p: [String: JSONValue], materialsText: String,
                           projectId: String, rtId: String) async throws -> String {
        let name = p["name"]?.string ?? ""
        let role = Self.roleOr(p["role"], "专家")
        let sysPrompt = "你是 \(name)，角色：\(role)。"
            + "你正在参加一场多角色圆桌讨论，请按主持方给出的发言指令发言。"
        let userPrompt = NativeRoundtable.speakPrompt(
            topic: topic, materials: materialsText, minutes: minutes, name: name, role: role)
        let msgs: [[String: JSONValue]] = [
            ["role": .string("system"), "content": .string(sysPrompt)],
            ["role": .string("user"), "content": .string(userPrompt)],
        ]
        if NativeVModelChat.isVModelName(model), let agentic = vmodelAgentic {
            // 沙盒根 = 项目工作目录（与 resolveExportDir 同真源；缺省 Desktop）
            let wd = NativeRoundtable.pyTrim((try? db.getProject(projectId))?.workingDir ?? "")
            let sandbox = wd.isEmpty ? NSHomeDirectory() + "/Desktop"
                                     : (wd as NSString).expandingTildeInPath
            let outcome = try await agentic(NativeVModelAgenticRequest(
                model: model, messages: msgs, surface: "roundtable",
                projectId: projectId, sandboxRoot: sandbox,
                maxRounds: NativeVModelAgentic.roundtableSpeechMaxRounds,
                cancelCheck: { NativeRoundtable.isCancelled(rtId) || Task.isCancelled }))
            var text = NativeRoundtable.pyTrim(outcome.text)
            if let notice = outcome.notice, !notice.isEmpty {
                text += (text.isEmpty ? "" : "\n\n") + "[⚠️ \(notice)]"
            }
            return text
        }
        let text = try await connector.chat(model: model, messages: msgs)
        return NativeRoundtable.pyTrim(text)
    }

    /// _update_minutes：纪要更新。失败/空回复返回 nil（保留旧纪要，不中断）。
    private func updateMinutes(model: String, topic: String, minutes: String,
                               speeches: [[String: JSONValue]]) async -> String? {
        do {
            let speechText = speeches
                .filter { NativeRoundtable.truthy($0["ok"]) }
                .map { "【\($0["name"]?.string ?? "")】\n\($0["content"]?.string ?? "")" }
                .joined(separator: "\n\n")
            let text = try await connector.chat(model: model, messages: [
                ["role": .string("system"),
                 "content": .string("你是圆桌讨论的纪要员，只输出纪要正文。")],
                ["role": .string("user"),
                 "content": .string(NativeRoundtable.minutesUpdatePrompt(
                    topic: topic, minutes: minutes, speeches: speechText))],
            ])
            let t = NativeRoundtable.pyTrim(text)
            return t.isEmpty ? nil : t
        } catch {
            return nil
        }
    }

    /// _judge_consensus：AI 主持共识判定（宽松判定）。返回 (是否共识, 判定原文)。
    /// 失败按未共识。静态化（对齐 Python 模块级函数，测试可直接驱动）。
    public static func judgeConsensus(conn: any NativeChatConnector,
                                      moderator: [String: JSONValue],
                                      topic: String, minutes: String) async -> (Bool, String) {
        do {
            let name: String
            if let v = moderator["name"] { name = v.string ?? "None" } else { name = "None" }
            let text = try await conn.chat(
                model: modelOrDefault(moderator["model_name"]), messages: [
                    ["role": .string("system"),
                     "content": .string("你是圆桌主持人，负责判定各方是否达成共识。")],
                    ["role": .string("user"),
                     "content": .string(NativeRoundtable.consensusPrompt(
                        name: name, role: roleOr(moderator["role"], "主持人"),
                        topic: topic, minutes: minutes))],
                ])
            let t = NativeRoundtable.pyTrim(text)
            let firstLine = t.split(separator: "\n", omittingEmptySubsequences: false)
                .first.map(String.init) ?? ""
            let isConsensus = !firstLine.contains("否") && firstLine.contains("是")
            return (isConsensus, t)
        } catch {
            return (false, "")
        }
    }

    // MARK: run_round / _run_round_inner（L217-302）

    /// 执行一轮（含 AI 主持的自动续轮，整场持锁）。
    @discardableResult
    public func runRound(projectId: String, rtId: String) async throws -> NativeRoundtableRow {
        guard await Self.roundGate.acquire() else { throw CancellationError() }
        defer { Self.roundGate.release() }
        return try await runRoundInner(projectId: projectId, rtId: rtId)
    }

    /// 单轮执行主体（调用方须已持 roundGate）。AI 主持未共识且未达上限时锁内递归续轮。
    private func runRoundInner(projectId: String, rtId: String) async throws -> NativeRoundtableRow {
        guard let rt = try db.getRoundtable(projectId: projectId, rtId: rtId) else {
            throw NativeRoundtableError("圆桌不存在")
        }
        let roundNo = rt.round + 1
        let topic = rt.topic
        var minutes = (rt.minutes ?? "").isEmpty
            ? NativeRoundtable.initialMinutes(topic: topic) : rt.minutes ?? ""
        let participants = rt.participants
        // 纪要员/总结/主持判定用模型：取第一个参与者的模型
        let judgeModel = Self.modelOrDefault(participants.first?["model_name"])

        _ = try db.updateRoundtable(projectId: projectId, rtId: rtId,
                                    round: roundNo, status: "running")

        // 背景材料：每轮独立注入（纪要会被模型重写，材料不能只靠纪要保留）
        let materialsText = NativeRoundtable.buildMaterialsText(rt.attachments)

        // ── 各参与者顺序发言（决策 7：基于纪要，非共享会话历史）──
        // checkpoint-067 N-1：每次发言前检查取消标志；取消则保留已完成的本轮发言，中止本轮。
        var roundSpeeches: [[String: JSONValue]] = []
        var cancelled = false
        for p in participants {
            if NativeRoundtable.isCancelled(rtId) { cancelled = true; break }
            do {
                let text = try await oneSpeech(model: Self.modelOrDefault(p["model_name"]),
                                               topic: topic, minutes: minutes, p: p,
                                               materialsText: materialsText,
                                               projectId: projectId, rtId: rtId)
                if text.isEmpty { throw NativeRoundtableError("空回复") }
                try db.addRoundtableMessage(projectId: projectId, rtId: rtId, round: roundNo,
                                            agentId: p["id"]?.string ?? "",
                                            agentName: p["name"]?.string ?? "",
                                            content: text, ok: true)
                roundSpeeches.append(["name": p["name"] ?? .null,
                                      "content": .string(text), "ok": .bool(true)])
            } catch is CancellationError {
                // 0.7.7 W6：agentic 发言中途被停（点停即停）——取消不是发言失败，
                // 不记失败占位；按 checkpoint-067 N-1 取消语义收尾（保已完成发言）。
                cancelled = true
                break
            } catch {
                try db.addRoundtableMessage(projectId: projectId, rtId: rtId, round: roundNo,
                                            agentId: p["id"]?.string ?? "",
                                            agentName: p["name"]?.string ?? "",
                                            content: "（本轮发言失败）", ok: false)
                roundSpeeches.append(["name": p["name"] ?? .null,
                                      "content": .string(""), "ok": .bool(false)])
            }
        }

        // checkpoint-067 N-1：已取消 → 不再更新纪要/续轮，状态置 waiting_user
        // （保留已完成发言，用户可继续或结束），清标志后返回。
        if cancelled {
            NativeRoundtable.clearCancel(rtId)
            _ = try db.updateRoundtable(projectId: projectId, rtId: rtId, status: "waiting_user")
            return try mustGet(projectId: projectId, rtId: rtId)
        }

        // ── 纪要更新（失败保留旧纪要，不中断）──
        // checkpoint-067 N-1：纪要更新前再次检查取消（发言循环内取消已在上面返回，此处兜底）。
        if NativeRoundtable.isCancelled(rtId) {
            NativeRoundtable.clearCancel(rtId)
            _ = try db.updateRoundtable(projectId: projectId, rtId: rtId, status: "waiting_user")
            return try mustGet(projectId: projectId, rtId: rtId)
        }
        if let newMinutes = await updateMinutes(model: judgeModel, topic: topic,
                                                minutes: minutes, speeches: roundSpeeches) {
            minutes = newMinutes
            _ = try db.updateRoundtable(projectId: projectId, rtId: rtId, minutes: minutes)
        }

        // ── 状态分流（决策 6）──
        if rt.moderator == "ai" {
            let moderator = participants.first(where: {
                $0["id"]?.string == rt.moderatorAgentId
            }) ?? participants[0]
            let (isConsensus, _) = await Self.judgeConsensus(
                conn: connector, moderator: moderator, topic: topic, minutes: minutes)
            if isConsensus {
                _ = try db.updateRoundtable(projectId: projectId, rtId: rtId,
                                            status: "confirm_end")
            } else if roundNo >= (rt.maxRounds == 0 ? 5 : rt.maxRounds) {
                _ = try db.updateRoundtable(projectId: projectId, rtId: rtId,
                                            status: "waiting_user")
            } else {
                // 未共识且未达上限 → 锁内自动续轮。
                // checkpoint-067 N-1：续轮前最后检查取消（防止 AI 主持无限续轮时无法停止）。
                if NativeRoundtable.isCancelled(rtId) {
                    NativeRoundtable.clearCancel(rtId)
                    _ = try db.updateRoundtable(projectId: projectId, rtId: rtId,
                                                status: "waiting_user")
                    return try mustGet(projectId: projectId, rtId: rtId)
                }
                return try await runRoundInner(projectId: projectId, rtId: rtId)
            }
        } else {
            _ = try db.updateRoundtable(projectId: projectId, rtId: rtId, status: "waiting_user")
        }
        return try mustGet(projectId: projectId, rtId: rtId)
    }

    /// get_roundtable 非空断言（Python 直接返回 dict；此处兜底 ValueError 口径）。
    private func mustGet(projectId: String, rtId: String) throws -> NativeRoundtableRow {
        guard let row = try db.getRoundtable(projectId: projectId, rtId: rtId) else {
            throw NativeRoundtableError("圆桌不存在")
        }
        return row
    }

    // MARK: continue / finish（L305-341）

    /// 用户主持点"继续"→ 下一轮（仅 waiting_user 允许——API 层守卫，内核不重复）。
    @discardableResult
    public func continueRoundtable(projectId: String, rtId: String) async throws
        -> NativeRoundtableRow {
        try await runRound(projectId: projectId, rtId: rtId)
    }

    /// 结束并生成总结。总结失败 → 纪要兜底，仍置 done。
    @discardableResult
    public func finishRoundtable(projectId: String, rtId: String) async throws
        -> NativeRoundtableRow {
        guard await Self.roundGate.acquire() else { throw CancellationError() }
        defer { Self.roundGate.release() }
        let rt = try mustGet(projectId: projectId, rtId: rtId)
        let topic = rt.topic
        let minutes = (rt.minutes ?? "").isEmpty
            ? NativeRoundtable.initialMinutes(topic: topic) : rt.minutes ?? ""
        let judgeModel = Self.modelOrDefault(rt.participants.first?["model_name"])

        let msgs = try db.listRoundtableMessages(projectId: projectId, rtId: rtId)
        let speechesText = msgs.filter { $0.ok }
            .map { "【\($0.agentName)·第\($0.round)轮】\n\($0.content ?? "")" }
            .joined(separator: "\n\n")

        var summary: String?
        do {
            let text = try await connector.chat(model: judgeModel, messages: [
                ["role": .string("system"),
                 "content": .string("你是圆桌讨论的总结人，只输出总结正文。")],
                ["role": .string("user"),
                 "content": .string(NativeRoundtable.summaryPrompt(
                    topic: topic, minutes: minutes, speeches: speechesText))],
            ])
            let t = NativeRoundtable.pyTrim(text)
            summary = t.isEmpty ? nil : t
        } catch {
            summary = nil
        }
        let final = summary ?? "（总结生成失败，纪要如下）\n" + minutes
        _ = try db.updateRoundtable(projectId: projectId, rtId: rtId,
                                    status: "done", summary: final)
        return try mustGet(projectId: projectId, rtId: rtId)
    }

    // MARK: export_roundtable_md（L344-421）

    /// exporter.resolve_export_dir 等价（配置优先 → 项目工作目录 → 数据目录兜底，
    /// 导出永不失败）。与 W4b NativeDelegation.resolveExportDir 同构。
    private func resolveExportDir(_ projectId: String) -> URL {
        let cfgDir = NativeRoundtable.pyTrim(configProvider()["default_export_dir"]?.string ?? "")
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

    /// 把整场讨论导出为 Markdown 文件（TS-109 增强 H18-2 保存模块）。
    /// 保存位置：outDir（可选）→ 默认 resolveExportDir(projectId)/roundtables/
    /// （用户 2026-08-29 纠正：存到用户的项目文件夹，不存软件数据目录）。
    /// 返回 (path: 绝对路径, name: 文件名)；圆桌不存在抛 NativeRoundtableError。
    @discardableResult
    public func exportRoundtableMd(projectId: String, rtId: String,
                                   outDir: String? = nil) throws -> (path: String, name: String) {
        let rt = try mustGet(projectId: projectId, rtId: rtId)
        let msgs = try db.listRoundtableMessages(projectId: projectId, rtId: rtId)

        let targetDir: URL
        if let outDir {
            targetDir = URL(fileURLWithPath: (outDir as NSString).expandingTildeInPath)
        } else {
            targetDir = resolveExportDir(projectId).appendingPathComponent("roundtables")
        }
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"
        let ts = df.string(from: Date())
        // 文件名：时间戳 + 议题前 20 字（清洗非法字符 \/:*?"<>|）
        let cleaned = rt.topic.filter { !"\\/:*?\"<>|".contains($0) }
        let safeTopic = {
            let t = NativeRoundtable.pyTrim(cleaned)
            return t.isEmpty ? "圆桌讨论" : String(t.prefix(20))
        }()
        let fname = "roundtable_\(ts)_\(safeTopic).md"
        let fpath = targetDir.appendingPathComponent(fname)

        var moderatorLine = "用户主持"
        if rt.moderator == "ai",
           let ma = rt.participants.first(where: { $0["id"]?.string == rt.moderatorAgentId }) {
            moderatorLine = "AI 主持：\(ma["name"]?.string ?? "")"
        }

        let df2 = DateFormatter()
        df2.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var lines: [String] = []
        lines.append("# 圆桌讨论记录：\(rt.topic)")
        lines.append("")
        lines.append("- **状态**：\(rt.status)")
        lines.append("- **轮次**：\(rt.round)/\(rt.maxRounds)")
        lines.append("- **主持人**：\(moderatorLine)")
        lines.append("- **参与者**："
            + rt.participants.map { $0["name"]?.string ?? "" }.joined(separator: "、"))
        lines.append("- **创建时间**：\(rt.createdAt ?? "")")
        lines.append("- **导出时间**：\(df2.string(from: Date()))")
        if !rt.attachments.isEmpty {
            let names = rt.attachments.map { $0["name"]?.string ?? "" }.joined(separator: "、")
            lines.append("- **议题附件**：\(names)")
        }
        lines.append("")
        if let minutes = rt.minutes, !minutes.isEmpty {
            lines.append("## 讨论纪要")
            lines.append("")
            lines.append(minutes)
            lines.append("")
        }
        // 逐轮发言
        var rounds: [Int: [NativeRoundtableMessageRow]] = [:]
        for m in msgs { rounds[m.round, default: []].append(m) }
        for rn in rounds.keys.sorted() {
            lines.append("## 第 \(rn) 轮")
            lines.append("")
            for m in rounds[rn] ?? [] {
                let okMark = m.ok ? "" : "（发言失败）"
                lines.append("### \(m.agentName)\(okMark)")
                lines.append("")
                lines.append(m.content ?? "")
                lines.append("")
            }
        }
        if let summary = rt.summary, !summary.isEmpty {
            lines.append("## 讨论总结")
            lines.append("")
            lines.append(summary)
            lines.append("")
        }

        try lines.joined(separator: "\n").write(to: fpath, atomically: false, encoding: .utf8)
        return (fpath.path, fname)
    }
}
