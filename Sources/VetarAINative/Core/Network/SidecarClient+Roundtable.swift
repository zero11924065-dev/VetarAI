//
//  SidecarClient+Roundtable.swift
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

//  圆桌讨论扩展端点。沿用 Wave 1/2 子协议分层（不改 SidecarClientProtocol 声明，
//  并行波次共享该文件）：RoundtablePanelClient 收圆桌全部端点，
//  生产实现 = NativeSidecarClient；面板测试注入自己的 mock。
//  HTTP 扩展实现已于 P3-W6 随侧车归零退役删除。
//
//  端点契约逐条对照 subagent/sidecar/app.py（行号为移植时核对位置）：
//    GET    /api/projects/{pid}/roundtables?limit   L1941  圆桌列表（现状 limit=20）
//    POST   /api/projects/{pid}/roundtables         L1855  创建并执行第一轮（同步等待返回）
//           请求体 RoundtableCreateReq：{topic, agent_ids, moderator('user'|'ai'),
//           moderator_agent_id?（user 主持时为 null/省略）, max_rounds(2~10),
//           attachments: [{name, content_base64}]（≤5 个、单个 ≤2MB，后端 L1843 双上限）}
//    GET    /api/roundtables/{rtid}?project_id=     L1959  详情（含 messages；
//           attachments 只回传名称/大小/类型标记，正文不回传）
//    POST   /api/roundtables/{rtid}/continue?project_id=  L2001  继续下一轮（仅 waiting_user）
//    POST   /api/roundtables/{rtid}/finish?project_id=    L2014  结束并总结
//           （仅 waiting_user / confirm_end）
//    POST   /api/roundtables/{rtid}/stop?project_id=      L2027  手动停止（置取消标志，
//           当前发言完成后中止本轮，已完成发言保留 → waiting_user；立即返回）
//    POST   /api/roundtables/{rtid}/export?project_id=    L1993  导出 Markdown {path, name}
//    DELETE /api/roundtables/{rtid}?project_id=           L1970  删除（running 时后端 400 拒绝）
//
//  圆桌无 SSE 推送通道——前端 RoundtablePanel/RoundtableView 均为 5s 轮询
//  （终态 done/failed 停轮询），原生侧同口径（纪律①③的合帧/flush 不适用：
//  无 token/thinking 增量，全部状态以 DB 轮询为唯一真相源）。
//

import Foundation

// MARK: - 契约模型（字段与 store.py _rt_row_to_dict / RoundtableView.tsx 一一对应）

/// 圆桌参与者（participants JSON 列元素；AgentLite 子集）。
public struct RTParticipant: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let role: String?
    public let model_name: String?

    public init(id: String, name: String, role: String? = nil, model_name: String? = nil) {
        self.id = id
        self.name = name
        self.role = role
        self.model_name = model_name
    }
}

/// 圆桌发言（roundtable_messages 行；id 为 DB 数字 id）。
public struct RTMessage: Decodable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let rt_id: String
    public let round: Int
    public let agent_id: String
    public let agent_name: String
    public let content: String
    /// false = 发言失败（UI 降透明度 + 「·发言失败」标注）。
    public let ok: Bool

    public init(id: Int, rt_id: String, round: Int, agent_id: String,
                agent_name: String, content: String, ok: Bool = true) {
        self.id = id
        self.rt_id = rt_id
        self.round = round
        self.agent_id = agent_id
        self.agent_name = agent_name
        self.content = content
        self.ok = ok
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // id 可能以数值或字符串落库，宽容处理
        if let n = try? c.decodeIfPresent(Int.self, forKey: .id) {
            id = n
        } else if let s = try? c.decodeIfPresent(String.self, forKey: .id), let n = Int(s) {
            id = n
        } else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(
                codingPath: decoder.codingPath, debugDescription: "RTMessage.id 缺失"))
        }
        rt_id = try c.decodeIfPresent(String.self, forKey: .rt_id) ?? ""
        round = try c.decodeIfPresent(Int.self, forKey: .round) ?? 0
        agent_id = try c.decodeIfPresent(String.self, forKey: .agent_id) ?? ""
        agent_name = try c.decodeIfPresent(String.self, forKey: .agent_name) ?? ""
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        // ok 落库为 0/1 整数（sqlite），兼容 Bool
        if let b = try? c.decodeIfPresent(Bool.self, forKey: .ok) {
            ok = b
        } else if let n = try? c.decodeIfPresent(Int.self, forKey: .ok) {
            ok = n != 0
        } else {
            ok = true
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, rt_id, round, agent_id, agent_name, content, ok
    }
}

/// 议题附件元数据（详情端点不回传正文，只有名称/大小/类型标记）。
public struct RTAttachmentMeta: Decodable, Equatable, Identifiable, Sendable {
    public let name: String
    public let size: Int?
    /// false = 非文本/无法解析（UI 标注「（非文本）」）。
    public let is_text: Bool?
    public let truncated: Bool?

    public var id: String { name }

    public init(name: String, size: Int? = nil, is_text: Bool? = nil, truncated: Bool? = nil) {
        self.name = name
        self.size = size
        self.is_text = is_text
        self.truncated = truncated
    }
}

/// 圆桌（列表行与详情同构；详情多 messages，附件正文已剥离）。
/// status 原始字符串保留：running / waiting_user / confirm_end / done / failed，
/// 未知状态由 UI 回落到 running 徽标（对齐 TSX `STATUS_BADGE[s] || running`）。
public struct Roundtable: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let topic: String
    public let participants: [RTParticipant]
    public let moderator: String              // "user" | "ai"
    public let moderator_agent_id: String?
    public let max_rounds: Int
    public let round: Int
    public let status: String
    public let minutes: String?
    public let summary: String?
    public let messages: [RTMessage]?         // 仅详情端点带
    public let attachments: [RTAttachmentMeta]?
    public let created_at: String?            // SQLite datetime('now') UTC（checkpoint-067 N-3）
    public let updated_at: String?

    public init(id: String, topic: String = "", participants: [RTParticipant] = [],
                moderator: String = "user", moderator_agent_id: String? = nil,
                max_rounds: Int = 5, round: Int = 0, status: String = "running",
                minutes: String? = nil, summary: String? = nil,
                messages: [RTMessage]? = nil, attachments: [RTAttachmentMeta]? = nil,
                created_at: String? = nil, updated_at: String? = nil) {
        self.id = id
        self.topic = topic
        self.participants = participants
        self.moderator = moderator
        self.moderator_agent_id = moderator_agent_id
        self.max_rounds = max_rounds
        self.round = round
        self.status = status
        self.minutes = minutes
        self.summary = summary
        self.messages = messages
        self.attachments = attachments
        self.created_at = created_at
        self.updated_at = updated_at
    }

    /// 终态（轮询与计时停止条件，对齐 TSX detail.status === 'done' || 'failed'）。
    public var isTerminal: Bool { status == "done" || status == "failed" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = try c.decodeIfPresent(String.self, forKey: .id) else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(
                codingPath: decoder.codingPath, debugDescription: "Roundtable.id 缺失"))
        }
        self.id = id
        topic = try c.decodeIfPresent(String.self, forKey: .topic) ?? ""
        participants = try c.decodeIfPresent([RTParticipant].self, forKey: .participants) ?? []
        moderator = try c.decodeIfPresent(String.self, forKey: .moderator) ?? "user"
        moderator_agent_id = try c.decodeIfPresent(String.self, forKey: .moderator_agent_id)
        max_rounds = try c.decodeIfPresent(Int.self, forKey: .max_rounds) ?? 5
        round = try c.decodeIfPresent(Int.self, forKey: .round) ?? 0
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "running"
        minutes = try c.decodeIfPresent(String.self, forKey: .minutes)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        messages = try c.decodeIfPresent([RTMessage].self, forKey: .messages)
        attachments = try c.decodeIfPresent([RTAttachmentMeta].self, forKey: .attachments)
        created_at = try c.decodeIfPresent(String.self, forKey: .created_at)
        updated_at = try c.decodeIfPresent(String.self, forKey: .updated_at)
    }

    private enum CodingKeys: String, CodingKey {
        case id, topic, participants, moderator, moderator_agent_id, max_rounds, round
        case status, minutes, summary, messages, attachments, created_at, updated_at
    }
}

// MARK: - 请求体

/// 议题附件输入（创建时上送；content_base64 为文件原始字节的 base64）。
public struct RTAttachmentInput: Encodable, Equatable, Sendable {
    public let name: String
    public let content_base64: String

    public init(name: String, content_base64: String) {
        self.name = name
        self.content_base64 = content_base64
    }
}

/// POST /api/projects/{pid}/roundtables 请求体（后端 RoundtableCreateReq）。
/// moderator_agent_id 为 nil 时键省略 —— 后端 `str | None = None` 缺省同语义
/// （TSX 显式传 null；省略与 null 对 pydantic 等价）。
public struct RoundtableCreateRequest: Encodable {
    public let topic: String
    public let agent_ids: [String]
    public let moderator: String              // "user" | "ai"
    public let moderator_agent_id: String?
    public let max_rounds: Int
    public let attachments: [RTAttachmentInput]

    public init(topic: String, agent_ids: [String], moderator: String,
                moderator_agent_id: String?, max_rounds: Int,
                attachments: [RTAttachmentInput] = []) {
        self.topic = topic
        self.agent_ids = agent_ids
        self.moderator = moderator
        self.moderator_agent_id = moderator_agent_id
        self.max_rounds = max_rounds
        self.attachments = attachments
    }
}

/// POST /api/roundtables/{rtid}/export 响应（{"path", "name"}）。
public struct RoundtableExportResult: Equatable, Sendable {
    public let path: String?
    public let name: String?

    public init(path: String?, name: String?) {
        self.path = path
        self.name = name
    }
}

// MARK: - 子协议

public protocol RoundtablePanelClient: SidecarClientProtocol {
    /// GET /api/projects/{pid}/roundtables?limit=（列表页 5s 轮询；现状 limit=20）。
    func listRoundtables(projectId: String, limit: Int) async throws -> [Roundtable]

    /// POST /api/projects/{pid}/roundtables：创建并同步执行第一轮，返回整场圆桌（含 id）。
    /// 校验失败（参与者 <2 等）→ SidecarError.httpError(400, detail)（detail 为后端原文案）。
    @discardableResult
    func createRoundtable(projectId: String, request: RoundtableCreateRequest) async throws -> Roundtable

    /// GET /api/roundtables/{rtid}?project_id=：详情（含 messages）。
    func getRoundtable(projectId: String, rtId: String) async throws -> Roundtable

    /// POST .../continue：继续下一轮（仅 waiting_user；其他状态后端 400）。
    func continueRoundtable(projectId: String, rtId: String) async throws

    /// POST .../finish：结束并生成总结（仅 waiting_user / confirm_end）。
    func finishRoundtable(projectId: String, rtId: String) async throws

    /// POST .../stop：手动停止（置取消标志，立即返回；当前发言完成后中止本轮）。
    func stopRoundtable(projectId: String, rtId: String) async throws

    /// POST .../export：导出讨论记录为 Markdown，返回落盘 {path, name}。
    func exportRoundtable(projectId: String, rtId: String) async throws -> RoundtableExportResult

    /// DELETE /api/roundtables/{rtid}?project_id=：删除圆桌及全部发言（running 时 400）。
    func deleteRoundtable(projectId: String, rtId: String) async throws
}
