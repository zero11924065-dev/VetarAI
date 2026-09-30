//
//  SidecarClient.swift
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

//  网络 Service 层协议（纯声明，供全部 21 个面板复用）：
//  · SidecarClientProtocol —— 面板只依赖协议；测试注入 Mock 即可脱离真实后端。
//  · 生产实现 = NativeSidecarClient（Core/NativeCore，原生内核绞杀者外壳）。
//  · 历史上的 HTTP 默认实现（URLSession 版）已于 P3-W6 随侧车归零整体退役删除。
//  统一约定：
//  · 错误类型统一为 SidecarError（含 .timeout/.offline 归一化）
//  · 请求体一律 JSONEncoder；响应体一律 JSONDecoder（loadMessages 例外：DB 行宽容解码）
//
//  端点契约来自对 subagent 仓的发现（前端实际调用 + sidecar/app.py 后端核对）：
//    GET  /api/config                          探活（拿到任意 HTTP 响应即就绪）
//    GET  /api/ollama/models                   模型列表
//    GET  /api/projects                        项目列表
//    POST /api/projects                        建项目 {name, working_dir}
//    GET  /api/agents/{pid}                    Agent 列表
//    POST /api/agents                          建 Agent {project_id, name, type_, model_name?}
//    GET  /api/sessions?project_id&agent_id    会话列表
//    POST /api/sessions                        建会话 {project_id, agent_id, title}
//    GET  /api/sessions/{sid}/messages?project_id  历史消息
//    POST /api/ollama/chat/stream              SSE 流式对话（agent 循环端点）
//    POST /api/chat/{sid}/stop                 真停生成（后端硬取消）
//    POST /api/auth/respond                    授权响应 {request_id, allowed, enable_network, remember?}
//    ── Wave 1（TaskPanel / AgentPanel）──
//    GET  /api/projects/{pid}/tasks?limit      委派任务列表
//    GET  /api/projects/{pid}/tasks/stream     委派任务实时进度 SSE
//    POST /api/projects/{pid}/tasks/{tid}/retry   失败任务一键重试
//    POST /api/projects/{pid}/tasks/{tid}/stop    停止进行中委派任务
//    PUT  /api/agents/{pid}/{aid}              改 Agent（model_name/system_prompt/name）
//    DELETE /api/agents/{pid}/{aid}            删 Agent
//

import Foundation

// MARK: - 协议

public protocol SidecarClientProtocol {
    var baseURL: URL { get }

    /// 探活：拿到任意 HTTP 响应即就绪（冒烟口径）；网络层失败抛错。
    @discardableResult
    func probeReady() async throws -> Bool

    // REST 资源
    func listModels() async throws -> [OllamaModel]
    func listProjects() async throws -> [SidecarProject]
    @discardableResult
    func createProject(name: String, workingDir: String) async throws -> String
    func listAgents(projectId: String) async throws -> [SidecarAgent]
    @discardableResult
    func createAgent(projectId: String, name: String, type: String, modelName: String?) async throws -> String
    func listSessions(projectId: String, agentId: String) async throws -> [ChatSession]
    @discardableResult
    func createSession(projectId: String, agentId: String, title: String) async throws -> String
    func loadMessages(projectId: String, sessionId: String) async throws -> [ChatMessage]

    /// 真停生成：后端置取消标志 → loop 下一轮边界/在飞请求硬取消。
    /// 纪律②：面板实现「停止」必须先调本方法，再断本地流。
    func stopChat(sessionId: String) async throws

    /// 授权响应（remember 缺省 = 仅本次；"session"/"always" 由后端记忆）。
    func respondAuth(_ body: AuthRespondRequest) async throws

    /// SSE 流式对话。取消消费方 Task 即断流；业务停止请先调 stopChat（纪律②）。
    func chatStream(_ body: ChatStreamRequest) -> AsyncThrowingStream<SSEEvent, Error>

    // MARK: Wave 1 面板端点（TaskPanel / AgentPanel）

    /// 委派任务列表：GET /api/projects/{pid}/tasks?limit=N（TaskPanel 现状 limit=30）。
    func listTasks(projectId: String, limit: Int) async throws -> [AgentTask]

    /// 一键重试失败任务：POST /api/projects/{pid}/tasks/{tid}/retry（同步等执行完成）。
    @discardableResult
    func retryTask(projectId: String, taskId: String) async throws -> TaskRetryResult

    /// 停止进行中委派任务：POST /api/projects/{pid}/tasks/{tid}/stop（置取消标志，立即返回）。
    func stopTask(projectId: String, taskId: String) async throws

    /// 委派任务实时进度流：GET /api/projects/{pid}/tasks/stream（SSE）。
    /// 事件名不走 SSEEventKind（snapshot/status/progress/task_end/gap/stream_end 等
    /// 非聊天契约事件），面板按 SSEEvent.event 原始名分发。
    func tasksStream(projectId: String) -> AsyncThrowingStream<SSEEvent, Error>

    /// 建 Agent（含角色设定）：POST /api/agents（AgentPanel 创建表单）。
    @discardableResult
    func createAgent(projectId: String, name: String, type: String,
                     modelName: String?, systemPrompt: String?) async throws -> String

    /// 改 Agent：PUT /api/agents/{pid}/{aid}（model_name / system_prompt / name，nil 键省略）。
    func updateAgent(projectId: String, agentId: String, update: AgentUpdateRequest) async throws

    /// 删 Agent：DELETE /api/agents/{pid}/{aid}（后端先停关联委派任务）。
    func deleteAgent(projectId: String, agentId: String) async throws
}

public extension SidecarClientProtocol {
    /// 便捷默认参数（对齐 pilot 时代的调用形态）。
    @discardableResult
    func createAgent(projectId: String, name: String, type: String = "main",
                     modelName: String? = nil) async throws -> String {
        try await createAgent(projectId: projectId, name: name, type: type, modelName: modelName)
    }

    // MARK: Wave 1 端点缺省桩（让 Wave 0 测试桩 MockSidecarClient 免改即可编译；
    // 生产客户端 NativeSidecarClient 全部覆写；面板测试用自己的 Mock 注入结果）。
    func listTasks(projectId: String, limit: Int) async throws -> [AgentTask] {
        throw SidecarError.decodeFailed("listTasks 缺省桩未实现")
    }
    @discardableResult
    func retryTask(projectId: String, taskId: String) async throws -> TaskRetryResult {
        throw SidecarError.decodeFailed("retryTask 缺省桩未实现")
    }
    func stopTask(projectId: String, taskId: String) async throws {
        throw SidecarError.decodeFailed("stopTask 缺省桩未实现")
    }
    func tasksStream(projectId: String) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: SidecarError.decodeFailed("tasksStream 缺省桩未实现")) }
    }
    @discardableResult
    func createAgent(projectId: String, name: String, type: String,
                     modelName: String?, systemPrompt: String?) async throws -> String {
        // 缺省桩回落到旧签名（丢弃 systemPrompt）；真实客户端覆写本方法。
        try await createAgent(projectId: projectId, name: name, type: type, modelName: modelName)
    }
    func updateAgent(projectId: String, agentId: String, update: AgentUpdateRequest) async throws {
        throw SidecarError.decodeFailed("updateAgent 缺省桩未实现")
    }
    func deleteAgent(projectId: String, agentId: String) async throws {
        throw SidecarError.decodeFailed("deleteAgent 缺省桩未实现")
    }
}
