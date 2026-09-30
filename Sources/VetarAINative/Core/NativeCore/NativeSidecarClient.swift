//
//  NativeSidecarClient.swift
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

//  SidecarClientProtocol 的原生实现（P3-W6 起为唯一生产实现）：
//    · 面板零感知——实现全部面板子协议，经 `as?` 注入点照常命中
//    · 每个方法按 NativeRoutingTable 分流到原生模块 → NativeKernel；
//      历史上未移植模块经 HTTP 转发给 fallback（URLSession 版客户端），
//      P3-W6 侧车归零后 fallback 机制整体删除，全 19 模块恒走原生。
//    · 原生路径抛错**不回落**（实验期要暴露分歧，静默回落会掩盖 bug）
//
//  错误映射（端点语义等价）：
//    · NativeCoreError.invalidConfig(msg) → httpError(400, msg)（PUT /api/config ValueError 口径）
//    · .notFound(msg) → httpError(404, msg)；.unprocessable(msg) → httpError(422, msg)
//    · config 保存的非校验异常 → httpError(500, "保存配置失败: …")（app.py L270-271）
//    · createProject 的 IO 失败 → httpError(400, 原文案)（app.py L308-309）
//

import Foundation

public final class NativeSidecarClient: SidecarClientProtocol {

    public let kernel: NativeKernel

    /// 协议要求（SidecarClientProtocol.baseURL 源自 HTTP 时代，面板/诊断仅作展示）。
    /// 原生内核是进程内对象，无 HTTP 地址——给语义化常量并注明，不构造真实 URL。
    public var baseURL: URL { URL(string: "native://kernel")! }

    public init(kernel: NativeKernel) {
        self.kernel = kernel
    }

    /// 内核错误 → 端点等价 SidecarError。
    func mapError(_ error: Error) -> SidecarError {
        if let e = error as? SidecarError { return e }
        switch error as? NativeCoreError {
        case .invalidConfig(let msg): return .httpError(status: 400, detail: msg)
        case .notFound(let msg): return .httpError(status: 404, detail: msg)
        case .unprocessable(let msg): return .httpError(status: 422, detail: msg)
        case .io(let msg), .database(let msg): return .httpError(status: 500, detail: msg)
        case .none: return .httpError(status: 500, detail: String(describing: error))
        }
    }

    // ════════════════════════════════════════════════════════════
    // MARK: - SidecarClientProtocol（基协议）
    // ════════════════════════════════════════════════════════════

    /// 探活（P3-W6 原生口径）：内核是进程内对象，init 同步建成即恒就绪——
    /// 调用方（启动链健康轮询/冒烟 await）语义 = 「内核可用」，恒 true。
    /// 历史上混合模式转发 HTTP 探侧车；侧车归零后无远端可探。
    @discardableResult
    public func probeReady() async throws -> Bool { true }

    /// 模型列表（P3-W6 纯原生）：ollama 后端走原生 /api/tags 直读
    /// （ollamaTagsFetcher，生产 = NativeChatEndpointAssembly.fetchOllamaModelNames，
    /// 同 gen() 画像过滤同款名单源——与侧车代理同源，空名单直接返回空，无语义损失；
    /// 历史上空名单回退 HTTP 的 W1 口径随侧车归零删除）。
    /// 非 ollama 后端（openai_compatible/model_package）本无 /api/ollama/models
    /// 面消费方，同样返回空（历史上经 HTTP 转发，端点行为见路由表 inference 条目）。
    public var ollamaTagsFetcher: ([String: JSONValue]) async -> [String] =
        NativeChatEndpointAssembly.fetchOllamaModelNames

    /// P3-W3a：models 并集的**模型包部分**回源缝——MP 注册表原生直读
    /// （kernel.mpChatConnector.listModels → endpointRow 映射，mp_connector.list_models
    /// L93-105 同口径：task==chat 且 enabled，size=size_bytes，context_length 真值才带，
    /// source="model_pack"）。声明放主类（扩展不能有存储属性；ollamaTagsFetcher 同款先例）。
    public lazy var mpUnionFetcher: () async -> [InferenceModelEntry] = { [weak self] in
        guard let self else { return [] }
        return kernel.mpChatConnector.listModels()
            .compactMap(NativeInferenceEndpointAssembly.endpointRow)
    }

    /// REQ-FUT-020（0.7.5 W1）：/api/inference/models 并集的 .vmodel 部分——
    /// 原生注册表直读（enabled 条目，source="vmodel"；mpUnionFetcher 同款先例）。
    public lazy var vmodelUnionFetcher: () async -> [InferenceModelEntry] = { [weak self] in
        guard let self else { return [] }
        return NativeVModelParity.inferenceEntries(
            forEnabledIn: kernel.vmodelInstaller.listInstalled())
    }

    public func listModels() async throws -> [OllamaModel] {
        let cfg = (try? kernel.config.getConfig()) ?? [:]
        let backend = cfg["inference_backend"]?.string ?? "ollama"
        // REQ-FUT-020（0.7.5 W1）：.vmodel 全局平级——已启用 VetarModel 产物以
        // "vmodel:<slug>" 池名与 ollama 模型同款入列（智能中心会话/Agents 面板
        // 共用此面；选中后按前缀路由 MLX，见 NativeVModelRoutingConnector）。
        // 空注册表自然为空集，原口径不动。
        let vmodels = NativeVModelParity.poolNames(
            forEnabledIn: kernel.vmodelInstaller.listInstalled())
        guard backend == "ollama" else {
            // 非 ollama 后端本无此面的 ollama 部分（见上注），.vmodel 仍平级入列
            return vmodels.map { OllamaModel(name: $0, size: nil) }
        }
        let names = await ollamaTagsFetcher(cfg)
        return (names + vmodels).map { OllamaModel(name: $0, size: nil) }   // 空名单直返空（同源）
    }

    // ── projects（原生）──

    public func listProjects() async throws -> [SidecarProject] {
        do { return try kernel.database.listProjects() } catch { throw mapError(error) }
    }

    @discardableResult
    public func createProject(name: String, workingDir: String) async throws -> String {
        // 端点校验逐字（app.py L299-303）
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            throw SidecarError.httpError(status: 400, detail: "项目名称不能为空")
        }
        if workingDir.trimmingCharacters(in: .whitespaces).isEmpty {
            throw SidecarError.httpError(status: 400, detail: "工作目录不能为空")
        }
        do {
            let pid = try kernel.database.createProject(name: name, workingDir: workingDir)
            // A13（app.py L307）：端点成功 return 前 notify（用户路径）
            NativeEndpointNotify.change(NativeAppEvents.resourceProject,
                                        NativeAppEvents.actionCreate, projectId: pid)
            return pid
        } catch {
            // app.py：PermissionError/OSError → 400
            if case .io(let msg) = error as? NativeCoreError {
                throw SidecarError.httpError(status: 400, detail: msg)
            }
            throw mapError(error)
        }
    }

    // ── agents（原生）──

    public func listAgents(projectId: String) async throws -> [SidecarAgent] {
        do {
            return try kernel.database.listAgentConfigs(projectId: projectId).map { r in
                SidecarAgent(id: r.id, name: r.name, type_: r.type_, model_name: r.modelName,
                             role: r.role, parent_agent_id: r.parentAgentId,
                             system_prompt: r.systemPrompt)
            }
        } catch { throw mapError(error) }
    }

    @discardableResult
    public func createAgent(projectId: String, name: String, type: String,
                            modelName: String?) async throws -> String {
        try await createAgent(projectId: projectId, name: name, type: type,
                              modelName: modelName, systemPrompt: nil)
    }

    @discardableResult
    public func createAgent(projectId: String, name: String, type: String,
                            modelName: String?, systemPrompt: String?) async throws -> String {
        // 端点校验逐字（app.py L330-341）
        guard type == "main" || type == "sub" else {
            throw SidecarError.httpError(status: 422, detail: "type_ 必须是 main 或 sub")
        }
        do {
            if try kernel.database.getProject(projectId) == nil {
                throw SidecarError.httpError(status: 404, detail: "项目不存在或已被删除，请重新选择项目")
            }
            return try kernel.database.addAgentConfig(projectId: projectId, name: name, type: type,
                                                      systemPrompt: systemPrompt, modelName: modelName)
        } catch { throw mapError(error) }
    }

    public func updateAgent(projectId: String, agentId: String, update: AgentUpdateRequest) async throws {
        do {
            // AgentUpdateReq = name/model_name/system_prompt（app.py L805-812）
            let ok = try kernel.database.updateAgentConfig(
                projectId: projectId, agentId: agentId,
                name: update.name, systemPrompt: update.system_prompt, modelName: update.model_name)
            if !ok { throw SidecarError.httpError(status: 404, detail: "Agent 不存在") }
            // A13（app.py L812）：agent/update 带 project_id + agent_id
            NativeEndpointNotify.change(NativeAppEvents.resourceAgent,
                                        NativeAppEvents.actionUpdate, projectId: projectId,
                                        extra: ["agent_id": .string(agentId)])
        } catch { throw mapError(error) }
    }

    /// DELETE /api/agents/{pid}/{aid} 等价（app.py L380-397 逐行为，P3-W1a 翻原生）：
    /// 删除前 stop 关联 running 委派任务——关联 = 该 Agent 是委派目标（target_agent_id）
    /// 或发起者（parent_agent_id），status ∈ (queued, running)，list_agent_tasks
    /// limit=200；有停止则等 1s 让执行循环检测到取消标志（TS-114/TS-115）。
    /// stop 段整体 except 吞掉（stop 失败不影响删除）；removed=false 不抛 404。
    /// ⚠️ 端点无 SSE notify（对照 independent-agents 删除有 A13——此端点逐字不发）。
    public func deleteAgent(projectId: String, agentId: String) async throws {
        do {
            let tasks = try kernel.database.listAgentTasks(projectId: projectId, limit: 200)
            var stopped = 0
            for t in tasks where (t.status == "queued" || t.status == "running")
                && (t.targetAgentId == agentId || t.parentAgentId == agentId) {
                NativeDelegationEngine.requestDelegationCancel(t.id)
                stopped += 1
            }
            if stopped > 0 { try? await Task.sleep(nanoseconds: 1_000_000_000) }
        } catch { /* stop 失败不影响删除 */ }
        do {
            _ = try kernel.database.removeAgentConfig(projectId: projectId, agentId: agentId)
        } catch { throw mapError(error) }
    }

    // ── sessions（原生）──

    public func listSessions(projectId: String, agentId: String) async throws -> [ChatSession] {
        do {
            return try kernel.database.listSessions(projectId: projectId, agentId: agentId).map { r in
                ChatSession(id: r.id, title: r.title, message_count: Int(r.messageCount))
            }
        } catch { throw mapError(error) }
    }

    @discardableResult
    public func createSession(projectId: String, agentId: String, title: String) async throws -> String {
        do {
            return try kernel.database.createSession(projectId: projectId, agentId: agentId, title: title)
        } catch { throw mapError(error) }
    }

    /// 删会话原生（P3-W1a）：连带取消委派任务 + 清附件目录，编排在
    /// +Panels 的 ChatPanelClient.deleteSession 复刻 app.py L729-756。
    /// ⚠️ 规格偏差：端点 docstring（app.py L733）声称清 _auth_pending 授权挂起，
    /// 端点体并未执行——按实际行为复刻（不做授权清理）。

    // ── messages（原生读）──

    /// load_messages 行 → ChatMessage（宽容解码口径与已退役的 HTTP 版 loadMessages 相同）。
    public func loadMessages(projectId: String, sessionId: String) async throws -> [ChatMessage] {
        do {
            return try kernel.database.loadMessages(projectId: projectId, sessionId: sessionId).map { r in
                var msg = ChatMessage(id: String(r.id), role: r.role,
                                      content: r.content ?? "", modelUsed: r.modelUsed)
                msg.dbId = Int(r.id)
                msg.createdAt = r.createdAt
                msg.images = r.images?.compactMap { $0.string } ?? []
                if let steps = r.toolSteps {
                    msg.toolSteps = steps.map { st in
                        let obj = st.object ?? [:]
                        return ToolStep(
                            id: obj["id"]?.string ?? UUID().uuidString,
                            name: obj["name"]?.string ?? "tool",
                            status: ToolStep.Status(rawValue: obj["status"]?.string ?? "ok") ?? .ok,
                            summary: obj["summary"]?.string,
                            error: obj["error"]?.string,
                            argsText: (obj["args"]?.object)
                                .flatMap { try? JSONSerialization.data(
                                    withJSONObject: $0.mapValues { $0.anyValue }, options: [.prettyPrinted]) }
                                .flatMap { String(data: $0, encoding: .utf8) }
                        )
                    }
                }
                if r.stopped { msg.manuallyStopped = true }
                if r.archived { msg.archived = true }
                msg.promptEvalCount = r.promptEvalCount.map { Int($0) }
                return msg
            }
        } catch { throw mapError(error) }
    }

    // ── chat / auth（P2-W4d2 原生：app.py L1069-1622 端点装配）──

    /// 停止聊天流（api_chat_stop L1565-1584）：422 空 sid；无活流不抛错（Void 协议）。
    public func stopChat(sessionId: String) async throws {
        do { try await kernel.chatEndpoints.stopChat(sessionId: sessionId) }
        catch { throw mapError(error) }
    }

    /// 授权决议回传（api_auth_respond L781-797）：未知 request_id → 404。
    public func respondAuth(_ body: AuthRespondRequest) async throws {
        do { try await kernel.chatEndpoints.respondAuth(body) }
        catch { throw mapError(error) }
    }

    /// P3-W2b 测试缝：openai_compatible 后端 chatStream 的原生连接器覆盖
    /// （生产 nil = kernel.openAIChatConnector；ollamaTagsFetcher 同款先例——
    /// 单测注入脚本化假连接器，绝不触网）。
    public var openAIChatConnectorOverride: (any NativeChatConnector)? = nil

    /// P3-W3a 测试缝：MP 连接器覆盖（生产 nil = kernel.mpChatConnector）。
    public var mpChatConnectorOverride: NativeMPChatConnector? = nil

    /// 流式对话（api_ollama_chat_stream L1069-1562）。P3-W2b：openai_compatible
    /// 后端翻原生；P3-W3a：三已知后端统一经 NativeRoutingChatConnector 逐轮归边
    /// （routing.py L165-186——loop 每轮重路由+前置换装钩子）；model_package 退化
    /// 全走 MP（active 占位为 MP 自身，routing.py _active() 退化同款，永不调用）；
    /// tiersOverride 仅 MP 路由时传内核共享档位表（loop 升档与驱动异档重启同一份
    /// 状态），ollama/openai 非包模型保持每流自建。
    /// 未知后端（P3-W6 对齐 routing.py L81-89 _active() 兜底语义）：
    ///   config 写入侧 NativeConfigStore 校验链已 400 拦截（config/store.py
    ///   L344-346 逐字）；手改 config.json 灌入未知值时 Python 路由层不报错——
    ///   _active() 条件链落空直返 ollama 单例（_ollama_singleton()），即未知后端
    ///   按 ollama 处理。native 同口径：default 分支落 kernel.chatConnector。
    public func chatStream(_ body: ChatStreamRequest) -> AsyncThrowingStream<SSEEvent, Error> {
        let cfg = (try? kernel.config.getConfig()) ?? [:]
        let backend = cfg["inference_backend"]?.string ?? "ollama"
        let stripped = backend.trimmingCharacters(in: .whitespaces)
        // 已知三后端 + 未知后端（routing.py _active() 兜底 = ollama）统一走原生；
        // openai_compatible/MP 特判，其余（含未知）活动连接器 = ollama。
        // REQ-FUT-020（0.7.5 W1主）：vmodel:<slug> 池名 → .vmodel 路由连接器
        // （主会话 agent-loop 真走 MLX：流式 + 工具回路 + 真值计量；⛔ 不静默
        // 换 ollama——旧口径落 ollama 只会 model-not-found，属诚实但不可用）。
        let mp = mpChatConnectorOverride ?? kernel.mpChatConnector
        let active: any NativeChatConnector
        if NativeVModelChat.isVModelName(body.model) {
            active = kernel.vmodelRoutingConnector
        } else if stripped == "model_package" {
            active = mp
        } else if backend == "openai_compatible" {
            active = openAIChatConnectorOverride ?? kernel.openAIChatConnector
        } else {
            active = kernel.chatConnector
        }
        let conn = NativeRoutingChatConnector(
            router: kernel.modelPackRouter, mp: mp, active: active)
        let routeMP = stripped == "model_package" || kernel.modelPackRouter.isChatPack(body.model)
        return kernel.chatEndpoints.chatStream(
            body, connectorOverride: conn,
            tiersOverride: routeMP ? kernel.lazyCtxTiers : nil)
    }

    // ── tasks（P2-W4d2 原生：app.py L1643-1825 + agent_engine/delegation.py）──

    /// 任务列表（api_list_agent_tasks L1643-1650）：limit 钳 max(1, min(limit, 200))。
    public func listTasks(projectId: String, limit: Int) async throws -> [AgentTask] {
        do {
            let lim = max(1, min(limit, 200))
            return try kernel.database.listAgentTasks(projectId: projectId, limit: lim).map { r in
                AgentTask(
                    id: r.id, target_agent_name: r.targetAgentName, task: r.task, status: r.status,
                    parent_agent_id: r.parentAgentId.isEmpty ? nil : r.parentAgentId,
                    parent_session_id: r.parentSessionId.isEmpty ? nil : r.parentSessionId,
                    target_agent_id: r.targetAgentId.isEmpty ? nil : r.targetAgentId,
                    expect: r.expect.isEmpty ? nil : r.expect,
                    report: r.report?.object.map { rep in
                        AgentTaskReport(
                            status: rep["status"]?.string,
                            summary: rep["summary"]?.string,
                            prompt_eval_count: rep["prompt_eval_count"].flatMap {
                                $0.int.map { Int($0) } ?? $0.string.flatMap { Int($0) }
                            })
                    },
                    fail_reason: r.failReason,
                    validation_failures: Int(r.validationFailures),
                    session_id: r.sessionId,
                    created_at: r.createdAt, updated_at: r.updatedAt)
            }
        } catch { throw mapError(error) }
    }

    /// 一键重试（api_retry_agent_task L1776-1811）：404/400 文案链逐字；
    /// authorizer=nil（重试走 HTTP 口径——敏感操作按默认拒绝）；旧记录保留。
    @discardableResult
    public func retryTask(projectId: String, taskId: String) async throws -> TaskRetryResult {
        do {
            guard let old = try kernel.database.getAgentTask(projectId: projectId, taskId: taskId) else {
                throw SidecarError.httpError(status: 404, detail: "任务不存在")
            }
            guard old.status == "failed" else {
                throw SidecarError.httpError(status: 400,
                                             detail: "仅失败任务可重试（当前状态：\(old.status)）")
            }
            guard let target = try kernel.database.getAgentConfig(
                projectId: projectId, agentId: old.targetAgentId) else {
                throw SidecarError.httpError(status: 400, detail: "目标 Agent 已不存在，无法重试")
            }
            // checkpoint-058：独立 Agent 命名空间 → 专属沙盒目录
            let sandboxRoot: String
            if projectId.hasPrefix(NativeDatabase.independentNSPrefix) {
                let sb = kernel.database.projectsRoot.appendingPathComponent(projectId)
                    .appendingPathComponent("sandbox")
                try? FileManager.default.createDirectory(at: sb, withIntermediateDirectories: true)
                sandboxRoot = sb.path
            } else {
                sandboxRoot = (try? kernel.database.getProject(projectId))?.workingDir ?? ""
            }
            guard !sandboxRoot.isEmpty else {
                throw SidecarError.httpError(status: 400, detail: "项目工作目录缺失，无法重试")
            }
            let cfg = (try? kernel.config.getConfig()) ?? NativeConfigStore.defaultConfig
            let maxRounds = Int(cfg["max_tool_rounds"].flatMap(PySem.toFloat) ?? 200)
            let result = try await kernel.delegationEngine.runDelegatedTask(
                NativeDelegationTaskRequest(
                    projectId: projectId, parentAgentId: old.parentAgentId,
                    parentSessionId: old.parentSessionId, targetAgent: target,
                    task: old.task, expect: old.expect,
                    sandboxRoot: sandboxRoot, maxRounds: maxRounds))
            return TaskRetryResult(
                newTaskId: result["task_id"]?.string,
                ok: result["ok"]?.bool ?? false,
                error: result["error"]?.string)
        } catch let e as SidecarError { throw e }
        catch { throw mapError(error) }
    }

    /// 停止委派任务（api_stop_delegation_task L1814-1825）：404/400 文案链逐字；
    /// 置取消标志（执行循环检查点中止）。协议 Void：200 语义不抛错。
    public func stopTask(projectId: String, taskId: String) async throws {
        do {
            guard let task = try kernel.database.getAgentTask(projectId: projectId, taskId: taskId) else {
                throw SidecarError.httpError(status: 404, detail: "任务不存在")
            }
            guard task.status != "done" && task.status != "failed" else {
                throw SidecarError.httpError(status: 400,
                                             detail: "任务已结束（\(task.status)），无需停止")
            }
            NativeDelegationEngine.requestDelegationCancel(taskId)
        } catch let e as SidecarError { throw e }
        catch { throw mapError(error) }
    }

    /// 委派任务实时进度流（api_stream_agent_tasks L1653-1713）：snapshot 权威基线 +
    /// 原生总线增量（委派全链路已原生：chat 委派与本文件 retry 均经原生引擎推真事件）。
    public func tasksStream(projectId: String) -> AsyncThrowingStream<SSEEvent, Error> {
        NativeTasksStreamEndpoint.stream(db: kernel.database, projectId: projectId)
    }
}

// MARK: - JSONValue ↔ Any（fetchConfig/putConfig 桥）

public extension JSONValue {
    /// JSONSerialization 等价物（Bool 保持 Bool——JSONSerialization 产出 NSNumber，
    /// 消费侧 `as? Bool`/`as? Int` 两者都兼容 Swift 原生 Bool/Int）。
    var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map { $0.anyValue }
        case .object(let o): return o.mapValues { $0.anyValue }
        }
    }

    /// Any（JSONSerialization 产物）→ JSONValue。
    /// ⚠️ NSNumber 必须先查 CFBoolean（NSNumber(1) as? Bool 也会成功——先判 bool 型别本身）。
    init?(anyValue: Any) {
        switch anyValue {
        case is NSNull: self = .null
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) }
            else if n.doubleValue == n.doubleValue.rounded() && abs(n.doubleValue) < 9.0e15 {
                self = .int(n.int64Value)
            } else { self = .double(n.doubleValue) }
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.compactMap { JSONValue(anyValue: $0) })
        case let o as [String: Any]:
            var obj: [String: JSONValue] = [:]
            for (k, v) in o { obj[k] = JSONValue(anyValue: v) ?? .null }
            self = .object(obj)
        default: return nil
        }
    }
}
