//
//  SidecarModels.swift
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

//  契约模型：字段与 subagent/sidecar/app.py 各端点、
//  renderer/src/panels/ChatPanel.tsx 的实际用法一一对应。
//  全局共享：所有面板的请求/响应模型都放这里，键名以蛇形对齐后端。
//

import Foundation

// MARK: - 会话 / 消息（UI 模型）

public struct ToolStep: Identifiable, Equatable {
    public enum Status: String, Equatable {
        case running, ok, error, interrupted
    }
    public let id: String
    public var name: String
    public var status: Status
    public var summary: String?
    public var error: String?
    /// 参数 JSON 串（展示用；对齐现状 JSON.stringify(args, null, 2)）
    public var argsText: String?

    public init(id: String, name: String, status: Status = .running,
                summary: String? = nil, error: String? = nil, argsText: String? = nil) {
        self.id = id
        self.name = name
        self.status = status
        self.summary = summary
        self.error = error
        self.argsText = argsText
    }
}

/// 会话消息（UI 模型）。字段逐一对齐现状 useMessages.ts 的 Message：
/// 流式瞬态字段（thinkingActive/runElapsed/waitingSeconds 等）不落库、不随历史回读恢复；
/// DB 权威字段（dbId/createdAt/images/archived/promptEvalCount/stopped）由 loadMessages 填充。
public struct ChatMessage: Identifiable, Equatable {
    public var id: String                 // DB 数字 id 字符串化，或 local_ 前缀的流式临时 id（TS-121 对齐后可变）
    public var dbId: Int?                 // DB 数字 id（知识转移勾选只认它，TS-121）
    public var role: String               // "user" | "assistant" | "system"
    public var content: String
    public var modelUsed: String?
    public var createdAt: String?         // DB created_at（UTC 原文，显示走 formatChatTime）
    public var images: [String] = []      // dataURI/http（pending_images 与 DB images 归一）
    public var toolSteps: [ToolStep] = []
    public var isStreaming: Bool = false  // 正在流式的那条（打字机光标 / 工具组展开判据）
    public var streamError: String?
    public var errorAnalysis: String?       // 0.4.9 任务161：后端报错分析（人话诊断）
    public var errorAnalysisModel: String?
    public var errorKind: String?           // M5：business / network
    public var manuallyStopped: Bool = false  // C6：仅用户手动停止（显示「已手动停止」）
    public var interruptedNote: String?       // #13：异常中断半成品标记（与 manualStopped 互斥）
    public var archived: Bool = false         // TS-120：已移入知识仓库，占位显示
    public var step: Int?
    public var maxStep: Int?
    public var tokensUsed: Int?
    public var promptEvalCount: Int?          // H17：历史会话恢复指示器的兜底
    // ── 流式瞬态（计时/思考预览）──
    public var thinkingActive: Bool = false   // 当前处于思考阶段
    public var thinkingPreview: String = ""   // 末尾 120 字简版预览（0.4.33 F3 单行钳制）
    public var thinkingElapsed: Int?          // 当前思考阶段秒数（跳动）
    public var thinkingDuration: Int?         // 思考定格秒数（「思考 Ns」保留显示）
    public var startedAt: TimeInterval?       // 气泡出现时刻（epoch 秒）
    public var runElapsed: Int?               // B12：整轮进行计时（仅流式中显示）
    public var completedDuration: Int?        // TS-116：完成用时（气泡出现 → done/error）
    public var waitingSeconds: Int = 0        // M5：长加载已等待秒数（≥8 显示横幅）

    public init(id: String = UUID().uuidString, role: String, content: String,
                modelUsed: String? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.modelUsed = modelUsed
    }
}

// MARK: - 侧车 REST 资源（解码从简：仅取 pilot 用到的字段）

public struct OllamaModel: Decodable, Equatable {
    public let name: String
    public let size: Int64?
}

public struct SidecarProject: Decodable, Equatable {
    public let id: String
    public let name: String
}

public struct SidecarAgent: Decodable, Equatable {
    public let id: String
    public let name: String
    public let type_: String
    public let model_name: String?
    /// Wave 1（AgentPanel）：角色设定与父子关系字段（后端 list_agent_configs 全量返回）。
    public let role: String?
    public let parent_agent_id: String?
    public let system_prompt: String?
}

public struct ChatSession: Decodable, Equatable, Identifiable {
    public let id: String
    public let title: String?
    public let message_count: Int?
}

// MARK: - 请求体（编码契约，单测覆盖）

/// POST /api/ollama/chat/stream 请求体。
/// 字段对齐 ChatPanel.tsx 实际发送项；sandbox_root 为后端 ChatStreamReq 的可选增强。
public struct ChatStreamRequest: Encodable {
    public let agent_id: String
    public let model: String
    public let messages: [ChatStreamMessage]
    public let images: [String]?
    public let project_id: String
    public let session_id: String
    public let skip_user_persist: Bool
    public let sandbox_root: String?
    public let auto_archive_unit: Bool

    public init(agent_id: String, model: String, messages: [ChatStreamMessage],
                images: [String]? = nil, project_id: String, session_id: String,
                skip_user_persist: Bool = false, sandbox_root: String? = nil,
                auto_archive_unit: Bool = false) {
        self.agent_id = agent_id
        self.model = model
        self.messages = messages
        self.images = images
        self.project_id = project_id
        self.session_id = session_id
        self.skip_user_persist = skip_user_persist
        self.sandbox_root = sandbox_root
        self.auto_archive_unit = auto_archive_unit
    }
}

public struct ChatStreamMessage: Encodable, Equatable {
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

public struct SessionCreateRequest: Encodable {
    public let project_id: String
    public let agent_id: String
    public let title: String
}

public struct ProjectCreateRequest: Encodable {
    public let name: String
    public let working_dir: String
}

public struct AgentCreateRequest: Encodable {
    public let project_id: String
    public let name: String
    public let type_: String
    public let model_name: String?
    /// Wave 1（AgentPanel）：创建时可选填角色设定（后端 AgentCreateReq.system_prompt）。
    public let system_prompt: String?

    public init(project_id: String, name: String, type_: String,
                model_name: String? = nil, system_prompt: String? = nil) {
        self.project_id = project_id
        self.name = name
        self.type_ = type_
        self.model_name = model_name
        self.system_prompt = system_prompt
    }
}

/// POST /api/auth/respond 请求体（授权弹窗结论回传）。
/// 语义对齐 ChatPanel.tsx auth_request 分支（0.4.34 / R2 0.4.33）：
///   · remember 缺省（nil）= 仅本次；合成 Encodable 对 nil 可选键自动省略。
///   · "session" = 本会话不再询问；"always" = 永久允许（后端 config 持久化）。
///   · enable_network 恒带（联网安装勾选「同时开启全量联网」时 true）。
public struct AuthRespondRequest: Encodable {
    public let request_id: String
    public let allowed: Bool
    public let enable_network: Bool
    public let remember: String?

    public init(request_id: String, allowed: Bool,
                enable_network: Bool = false, remember: String? = nil) {
        self.request_id = request_id
        self.allowed = allowed
        self.enable_network = enable_network
        self.remember = remember
    }
}

/// 授权记忆级别（对齐前端 remember 字段取值）。
public enum AuthRemember: String, Sendable {
    case session    // 本会话不再询问（app 内内存表 + 后端 session 记忆双保险）
    case always     // 永久允许（仅回传后端，由后端 config 持久化）
}

// MARK: - Wave 1 Chat 全量移植新增契约

/// GET /api/context/limit?model= 响应（0.4.34 口径）。
/// 懒加载生效时 contextLimit = 当前档、ceiling = 用户配置上限、lazy = true。
public struct ContextLimitInfo: Equatable {
    public var limit: Int = 0          // context_limit || context_length（懒加载时为当前档）
    public var source: String = ""     // config/ps/show/default/manifest/error/unsupported
    public var ceiling: Int = 0        // lazy 且 ceiling>0 时生效（用户上限）
    public var lazy: Bool = false

    public init(limit: Int = 0, source: String = "", ceiling: Int = 0, lazy: Bool = false) {
        self.limit = limit
        self.source = source
        self.ceiling = ceiling
        self.lazy = lazy
    }
}

/// POST /api/attachments/parse 响应（checkpoint-048 / C7 0.4.18）。
public struct AttachmentParseResult: Equatable {
    public var name: String = ""
    public var kind: String = ""
    public var text: String?           // nil = 后端裁决无法解析 → 前端显示「（仅文件名）」
    public var truncated: Bool = false
    public var savedPath: String?      // 后端落盘绝对路径（拉模式正文注入用）
    public var saveError: String?

    public init() {}
}

/// POST /api/chat/{sid}/inject 响应（A5 0.4.16）。
public struct InjectResult: Equatable {
    public var ok: Bool
    public var detail: String?

    public init(ok: Bool, detail: String?) {
        self.ok = ok
        self.detail = detail
    }
}

/// POST /api/sessions/{sid}/export 响应（M7：统一默认导出目录；dir 旧行为）。
public struct ExportResult: Equatable {
    public var ok: Bool = false
    public var path: String = ""
    public var name: String = ""

    public init() {}
}

/// POST /api/sessions/{sid}/summarize 响应（checkpoint-048）。
public struct SummarizeResult: Equatable {
    public var ok: Bool = false
    public var summary: String = ""
    public var savedFile: String = ""

    public init() {}
}

/// POST /api/knowledge/transfer 请求体（TS-120 0.3.0）。message_ids 只认 DB 数字 id。
public struct KnowledgeTransferRequest: Encodable {
    public let project_id: String
    public let session_id: String
    public let message_ids: [Int]
    public let scope: String           // "project" | "global"
    public let title: String?          // 留空后端自动取首条前 20 字
    public let category: String
    public let keywords: [String]

    public init(projectId: String, sessionId: String, messageIds: [Int],
                scope: String, title: String?, category: String, keywords: [String]) {
        self.project_id = projectId
        self.session_id = sessionId
        self.message_ids = messageIds
        self.scope = scope
        self.title = title
        self.category = category
        self.keywords = keywords
    }
}

/// POST /api/knowledge/transfer 响应。
public struct KnowledgeTransferResult: Equatable {
    public var ok: Bool = false
    public var title: String = ""
    public var archived: Int = 0

    public init() {}
}

// MARK: - Wave 1：委派任务（TaskPanel，对标 TaskPanel.tsx + sidecar/storage/store.py list_agent_tasks）

/// 委派任务报告（agent_tasks.report JSON 列；宽容解码，字段均可缺）。
public struct AgentTaskReport: Decodable, Equatable {
    public let status: String?
    public let summary: String?
    public let prompt_eval_count: Int?

    public init(status: String? = nil, summary: String? = nil, prompt_eval_count: Int? = nil) {
        self.status = status
        self.summary = summary
        self.prompt_eval_count = prompt_eval_count
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        // prompt_eval_count 可能以数值或字符串落库，宽容处理
        if let n = try? c.decodeIfPresent(Int.self, forKey: .prompt_eval_count) {
            prompt_eval_count = n
        } else if let s = try? c.decodeIfPresent(String.self, forKey: .prompt_eval_count) {
            prompt_eval_count = Int(s)
        } else {
            prompt_eval_count = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case status, summary, prompt_eval_count
    }
}

/// 委派任务（GET /api/projects/{pid}/tasks 行 + tasks/stream snapshot 内嵌任务同构）。
/// 字段与 store.py list_agent_tasks 返回一一对应；status 原始字符串保留，
/// 未知状态由 UI 回落到 queued 徽标（对齐 TaskPanel.tsx `STATUS_BADGE[t.status] || queued`）。
public struct AgentTask: Decodable, Equatable, Identifiable {
    public let id: String
    public let parent_agent_id: String?
    public let parent_session_id: String?
    public let target_agent_id: String?
    public let target_agent_name: String
    public let task: String
    public let expect: String?
    public let status: String
    public let report: AgentTaskReport?
    public let fail_reason: String?
    public let validation_failures: Int?
    public let session_id: String?
    public let created_at: String?
    public let updated_at: String?

    public init(id: String, target_agent_name: String = "", task: String = "", status: String = "queued",
                parent_agent_id: String? = nil, parent_session_id: String? = nil,
                target_agent_id: String? = nil, expect: String? = nil,
                report: AgentTaskReport? = nil, fail_reason: String? = nil,
                validation_failures: Int? = nil, session_id: String? = nil,
                created_at: String? = nil, updated_at: String? = nil) {
        self.id = id
        self.target_agent_name = target_agent_name
        self.task = task
        self.status = status
        self.parent_agent_id = parent_agent_id
        self.parent_session_id = parent_session_id
        self.target_agent_id = target_agent_id
        self.expect = expect
        self.report = report
        self.fail_reason = fail_reason
        self.validation_failures = validation_failures
        self.session_id = session_id
        self.created_at = created_at
        self.updated_at = updated_at
    }

    /// 进行中（queued/running）：计时与实时进度的展示门控（对齐 TaskPanel.tsx hasActive）。
    public var isActive: Bool { status == "queued" || status == "running" }

    /// 宽容解码：除 id 外全部可缺（SSE snapshot 与 REST 行共用同一解码路径）。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = try c.decodeIfPresent(String.self, forKey: .id) else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(
                codingPath: decoder.codingPath, debugDescription: "AgentTask.id 缺失"))
        }
        self.id = id
        target_agent_name = try c.decodeIfPresent(String.self, forKey: .target_agent_name) ?? ""
        task = try c.decodeIfPresent(String.self, forKey: .task) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "queued"
        parent_agent_id = try c.decodeIfPresent(String.self, forKey: .parent_agent_id)
        parent_session_id = try c.decodeIfPresent(String.self, forKey: .parent_session_id)
        target_agent_id = try c.decodeIfPresent(String.self, forKey: .target_agent_id)
        expect = try c.decodeIfPresent(String.self, forKey: .expect)
        report = try c.decodeIfPresent(AgentTaskReport.self, forKey: .report)
        fail_reason = try c.decodeIfPresent(String.self, forKey: .fail_reason)
        validation_failures = try c.decodeIfPresent(Int.self, forKey: .validation_failures)
        session_id = try c.decodeIfPresent(String.self, forKey: .session_id)
        created_at = try c.decodeIfPresent(String.self, forKey: .created_at)
        updated_at = try c.decodeIfPresent(String.self, forKey: .updated_at)
    }

    private enum CodingKeys: String, CodingKey {
        case id, parent_agent_id, parent_session_id, target_agent_id, target_agent_name
        case task, expect, status, report, fail_reason, validation_failures
        case session_id, created_at, updated_at
    }
}

/// POST /api/projects/{pid}/tasks/{tid}/retry 响应（{"new_task_id", "result": {...}}）。
/// result.ok 缺失按 false 处理（对齐前端 `data?.result?.ok`  falsy 分支）。
public struct TaskRetryResult: Equatable {
    public let newTaskId: String?
    public let ok: Bool
    public let error: String?

    public init(newTaskId: String?, ok: Bool, error: String?) {
        self.newTaskId = newTaskId
        self.ok = ok
        self.error = error
    }
}

/// PUT /api/agents/{pid}/{aid} 请求体（后端 model_dump(exclude_none=True)：nil 键必须省略，
/// 合成 Encodable 对 nil 可选键自动省略，语义一致）。
public struct AgentUpdateRequest: Encodable {
    public let name: String?
    public let model_name: String?
    public let system_prompt: String?

    public init(name: String? = nil, model_name: String? = nil, system_prompt: String? = nil) {
        self.name = name
        self.model_name = model_name
        self.system_prompt = system_prompt
    }
}
