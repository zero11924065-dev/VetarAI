//
//  NativeChatRuntime.swift
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

//  逐行为移植（⛔ 只读行为规格源）：
//    · sidecar/ollama/connector.py chat_stream / chat（流式 NDJSON 事件契约、
//      tools/images 传参格式、剥图重试降级、流内超时兜底 stream_error）
//    · sidecar/agent_engine/cancel.py（会话级停止登记：register/unregister 配对、
//      残留标志杜绝、asyncio.Event 立即唤醒 → awaitCancel）
//    · sidecar/agent_engine/inject.py（思考中注入队列：begin/end 配对、
//      只在有活流时接受 push、drain 取出即清空、end_stream 清残留）
//
//  工具路由占位协议（本波不注入实现，loop 层按 Python 原文案如实报错）：
//    · NativeDelegationRunner / NativeDelegationContext —— W4b 注入委派执行器
//    · NativeAppControlDispatcher / NativeAppControlContext —— W4c 注入
//    · NativeComputerUseExecutor / NativeComputerUseContext —— W4c 注入
//    · NativeWorkUnitArchiver / NativeArchiveContext —— 归档开关开启时由调用方装配
//    · NativeSkillReader —— skills_mgr 仍走 HTTP 侧车（路由表 knowledge 条目）
//
//  偏差（汇报清单同步）：
//    ① URLSession bytes 的超时为整体 timeoutInterval，不细分 httpx 的
//       connect/read 双超时（同 P2-W2 偏差③）；流内超时映射为 stream_error 兜底。
//    ② Ollama 流是 NDJSON 而非 SSE：用 URLSession bytes.lines 逐行解析
//       （等价 httpx aiter_lines），不经 SSEParser（那是 SSE 事件块格式）。
//    ③ openai_compatible 后端的 chat_stream 已翻原生（P3-W2b：
//       NativeOpenAIChatConnector，openai_compat.py 逐行为，独立文件）；
//       model_package 后端仍走 HTTP 侧车（P3-W3 排期）。
//

import Foundation

// ════════════════════════════════════════════════════════════
// MARK: - 流式模型事件（connector.chat_stream 的 yield dict 同构）
// ════════════════════════════════════════════════════════════

/// connector.chat_stream 产出的事件（Python dict 逐键映射）：
///   {"content_delta": str} / {"thinking_delta": str} /
///   {"tool_calls": [原生 Ollama 结构]} / {"done": True, "counts": {...}} /
///   {"stream_error": str}
public enum NativeChatStreamEvent: Sendable, Equatable {
    case contentDelta(String)
    case thinkingDelta(String)
    /// 原生 Ollama tool_calls 列表（{"id":..,"function":{"name":..,"arguments":str|dict}}），
    /// 归一化（arguments 字符串 → dict、补 id）由 loop 层做（loop.py L1347-1360）。
    case toolCalls([[String: JSONValue]])
    /// done 计数：prompt_eval_count / eval_count（缺省 0）。
    case done(promptEvalCount: Int, evalCount: Int)
    /// 流中途超时兜底（connector 层不裸抛异常的约定出口）。
    case streamError(String)
}

// ════════════════════════════════════════════════════════════
// MARK: - 连接器协议（测试注入假 connector 的接缝）
// ════════════════════════════════════════════════════════════

public protocol NativeChatConnector: Sendable {
    /// chat_stream(model, messages, tools=..., images=...)。
    /// images=nil 等价 Python 缺省不传 kwarg（loop 只在有图时才传）。
    func chatStream(model: String, messages: [[String: JSONValue]],
                    tools: [JSONValue]?, images: [String]?)
        -> AsyncThrowingStream<NativeChatStreamEvent, Error>
    /// chat(model, messages) 非流式（报错分析模型用，loop._analyze_error）。
    func chat(model: String, messages: [[String: JSONValue]]) async throws -> String
}

/// 连接器错误（OllamaAPIError / NetworkGuardError 的载体；loop 兜底转 error 事件）。
public enum NativeChatConnectorError: Error, Equatable {
    /// OllamaAPIError 等价（400/404 等业务错误）。
    case api(status: Int, detail: String)
    /// NetworkGuardError 等价（其余非 2xx）。
    case guardDenied(status: Int, detail: String)
    /// 传输层错误（连接失败等；httpx.HTTPError 族无法逐字对齐）。
    case network(String)
    /// openai_compat.py 的 OllamaAPIError/NetworkGuardError 等价物（P3-W2b）：
    /// message 逐字自持——_raise_stream_http/_raise_http 的业务错误为
    /// 「对话请求失败（HTTP {status}）」（detail 截 300 另存 detail 字段，gen() 只消费
    /// message，与 Python e.message 逐字一致）；401/403 为「对话请求失败：服务拒绝访问
    /// （HTTP {status}）。{detail[:300]}」；_base() 未配置为「推理后端地址未配置
    /// （设置面板：推理后端 → 地址）」。
    case openAI(status: Int, message: String, detail: String)

    public var message: String {
        switch self {
        case .api(_, let detail): return "对话请求失败: \(detail)"
        case .guardDenied(let status, let detail): return "对话请求失败(HTTP \(status)): \(detail)"
        case .network(let msg): return msg
        case .openAI(_, let message, _): return message
        }
    }
}

// ════════════════════════════════════════════════════════════
// MARK: - 生产连接器（Ollama /api/chat 流式，connector.py chat_stream 逐行为）
// ════════════════════════════════════════════════════════════

public final class NativeOllamaChatConnector: NativeChatConnector {

    private let configProvider: @Sendable () -> [String: JSONValue]
    private let session: URLSession

    public init(config: NativeConfigStore) {
        self.configProvider = { (try? config.getConfig()) ?? NativeConfigStore.defaultConfig }
        self.session = .shared
    }

    /// 测试/装配注入用。
    public init(configProvider: @escaping @Sendable () -> [String: JSONValue],
                session: URLSession = .shared) {
        self.configProvider = configProvider
        self.session = session
    }

    private func config() -> [String: JSONValue] { configProvider() }

    /// timeout_stream_reading()：默认 1800（checkpoint-067 R-2 完整优先），钳 10~7200。
    public func timeoutStreamReading() -> Double {
        guard let f = config()["timeout_stream_reading"].flatMap(PySem.toFloat), f > 0 else {
            return 1800.0
        }
        return min(max(f, 10.0), 7200.0)
    }

    private var baseURL: String {
        (config()["ollama_base_url"]?.string ?? "http://localhost:11434")
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    }

    // MARK: chat_stream（connector.py L248-352）

    public func chatStream(model: String, messages: [[String: JSONValue]],
                           tools: [JSONValue]?, images: [String]?)
        -> AsyncThrowingStream<NativeChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.streamMain(model: model, messages: messages,
                                              tools: tools, images: images,
                                              continuation: continuation)
                } catch is CancellationError {
                    // 客户端断开（Python asyncio.CancelledError）：静默结束流
                } catch let e as NativeChatConnectorError {
                    continuation.finish(throwing: e)
                } catch let e as URLError where e.code == .timedOut {
                    // httpx.TimeoutException 兜底：流中途超时不裸抛 → stream_error
                    continuation.yield(.streamError("模型响应超时，已停止。已完成部分见上方事件。"))
                } catch {
                    continuation.finish(throwing: NativeChatConnectorError.network(
                        error.localizedDescription))
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func streamMain(model: String, messages: [[String: JSONValue]],
                            tools: [JSONValue]?, images: [String]?,
                            continuation: AsyncThrowingStream<NativeChatStreamEvent, Error>.Continuation) async throws {
        var payload: [String: JSONValue] = [
            "model": .string(model),
            "messages": .array(messages.map { .object($0) }),
            "stream": .bool(true),
        ]
        // A2/A4：model_options 注入（空 dict 绝不注入）
        for (k, v) in NativeWorkflowHTTPConnector.modelOptions(model: model, backend: "ollama",
                                                               config: config()) {
            payload[k] = v
        }
        if let tools, !tools.isEmpty {
            payload["tools"] = .array(tools)
        }
        // M6（TS-112）图片入流：解析后合入【最后一条 user 消息】（Ollama images=base64 列表）
        var parsedImages: [String] = []
        for img in images ?? [] {
            if let p = NativeWorkflowHTTPConnector.parseImage(img) { parsedImages.append(p) }
        }
        var hadImages = false
        if !parsedImages.isEmpty, var msgs = payload["messages"]?.array {
            for i in stride(from: msgs.count - 1, through: 0, by: -1) {
                guard case .object(let m) = msgs[i], m["role"]?.string == "user" else { continue }
                var m2 = m
                m2["images"] = .array(parsedImages.map { .string($0) })
                msgs[i] = .object(m2)
                payload["messages"] = .array(msgs)
                hadImages = true
                break
            }
        }

        var req = URLRequest(url: URL(string: "\(baseURL)/api/chat")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = timeoutStreamReading()
        req.httpBody = try JSONSerialization.data(withJSONObject: payload.mapValues { $0.anyValue })

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: req)
        } catch let e as URLError where e.code == .timedOut {
            continuation.yield(.streamError("模型响应超时，已停止。已完成部分见上方事件。"))
            return
        }
        guard let http = response as? HTTPURLResponse else {
            throw NativeChatConnectorError.network("无效响应")
        }
        if http.statusCode != 200 {
            // 读错误体（_raise_stream_http：400/404 → OllamaAPIError；其余 → guard 语义）
            var body = ""
            for try await line in bytes.lines { body += line + "\n" }
            let detail = Self.errorDetail(body)
            // checkpoint-041：400/500 + 带图 → 剥图重试一次（stream:false）+ 降级文案
            if (http.statusCode == 400 || http.statusCode == 500), hadImages {
                try await retryWithoutImages(payload: payload, continuation: continuation)
                return
            }
            if http.statusCode == 400 || http.statusCode == 404 {
                throw NativeChatConnectorError.api(status: http.statusCode, detail: detail)
            }
            throw NativeChatConnectorError.guardDenied(status: http.statusCode, detail: detail)
        }

        // NDJSON 逐行解析（aiter_lines 等价；空行跳过、坏行跳过）
        for try await rawLine in bytes.lines {
            try Task.checkCancellation()
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard let data = line.data(using: .utf8),
                  let v = NativeJSONWriter.loads(data),
                  case .object(let obj) = v else { continue }
            let msg: [String: JSONValue] = {
                if case .object(let m)? = obj["message"] { return m }
                return [:]
            }()
            // TS-102 B13：thinking 增量透传
            if let th = msg["thinking"]?.string, !th.isEmpty {
                continuation.yield(.thinkingDelta(th))
            }
            if let delta = msg["content"]?.string, !delta.isEmpty {
                continuation.yield(.contentDelta(delta))
            }
            if case .array(let tcs)? = msg["tool_calls"], !tcs.isEmpty {
                let raw = tcs.compactMap { $0.object }
                if !raw.isEmpty { continuation.yield(.toolCalls(raw)) }
            }
            if obj["done"] == .bool(true) {
                continuation.yield(.done(
                    promptEvalCount: Int(obj["prompt_eval_count"]?.int ?? 0),
                    evalCount: Int(obj["eval_count"]?.int ?? 0)))
            }
        }
    }

    /// 非 200 错误体取 detail：json.error 或原文（_raise_stream_http L355-364）。
    private static func errorDetail(_ body: String) -> String {
        if let data = body.data(using: .utf8), let v = NativeJSONWriter.loads(data),
           case .object(let o) = v, let e = o["error"]?.string {
            return e
        }
        return body
    }

    /// checkpoint-041/042：剥图重试（stream:false），成功 → content_delta + done(0,0)。
    private func retryWithoutImages(
        payload: [String: JSONValue],
        continuation: AsyncThrowingStream<NativeChatStreamEvent, Error>.Continuation
    ) async throws {
        var stripped = payload
        if var msgs = stripped["messages"]?.array {
            for i in msgs.indices {
                guard case .object(var m) = msgs[i] else { continue }
                m.removeValue(forKey: "images")
                msgs[i] = .object(m)
            }
            stripped["messages"] = .array(msgs)
        }
        stripped["stream"] = .bool(false)
        var req = URLRequest(url: URL(string: "\(baseURL)/api/chat")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = timeoutStreamReading()
        req.httpBody = try JSONSerialization.data(withJSONObject: stripped.mapValues { $0.anyValue })
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 400 || status == 404 {
                throw NativeChatConnectorError.api(status: status,
                                                   detail: Self.errorDetail(String(decoding: data, as: UTF8.self)))
            }
            throw NativeChatConnectorError.guardDenied(
                status: status, detail: Self.errorDetail(String(decoding: data, as: UTF8.self)))
        }
        // checkpoint-042：防御多行 NDJSON → 逐行解析拼接
        var content = ""
        if let v = NativeJSONWriter.loads(data), case .object(let o) = v,
           case .object(let msg) = o["message"], let c = msg["content"]?.string {
            content = c
        } else {
            for line0 in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                let line = line0.trimmingCharacters(in: .whitespaces)
                if line.isEmpty { continue }
                guard let d = line.data(using: .utf8), let v = NativeJSONWriter.loads(d),
                      case .object(let o) = v, case .object(let msg) = o["message"],
                      let c = msg["content"]?.string else { continue }
                content += c
            }
        }
        continuation.yield(.contentDelta(content
            + "\n\n[⚠️ 当前模型不支持多模态，图片未参与分析。建议切换到视觉模型（如 qwen2.5-vl）后重试。]"))
        continuation.yield(.done(promptEvalCount: 0, evalCount: 0))
    }

    // MARK: chat（connector.py chat L166-246 的极简面：报错分析模型用）

    public func chat(model: String, messages: [[String: JSONValue]]) async throws -> String {
        var payload: [String: JSONValue] = [
            "model": .string(model),
            "messages": .array(messages.map { .object($0) }),
            "stream": .bool(false),
        ]
        for (k, v) in NativeWorkflowHTTPConnector.modelOptions(model: model, backend: "ollama",
                                                               config: config()) {
            payload[k] = v
        }
        var req = URLRequest(url: URL(string: "\(baseURL)/api/chat")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // _ERROR_ANALYSIS_TIMEOUT → 配置化（0.7.5 W13）：error_analysis_timeout_s
        // 同源读取（缺省 60 钳 5~600）；调用方 analyzeError 仍有超时竞速，双保险
        req.timeoutInterval = NativeConfigStore.errorAnalysisTimeoutS(config())
        req.httpBody = try JSONSerialization.data(withJSONObject: payload.mapValues { $0.anyValue })
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw NativeChatConnectorError.network("无效响应")
        }
        guard http.statusCode == 200 else {
            throw NativeChatConnectorError.api(status: http.statusCode,
                                               detail: Self.errorDetail(String(decoding: data, as: UTF8.self)))
        }
        if let v = NativeJSONWriter.loads(data), case .object(let o) = v,
           case .object(let msg) = o["message"], let c = msg["content"]?.string {
            return c
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: chat with images（connector.py chat L166-246 图片流；_vision_parse 通道，P3-W1b）

    /// conn.chat(model, messages, images=[...]) 等价：data URI/路径/base64 解析合入
    /// 最后一条消息 images 键；400/500 + 带图 → 剥图重试一次 + 多模态提示尾注
    /// （checkpoint-041）；>8MB 图丢弃并尾注。读超时走 timeout_reading（缺省 300s，
    /// 与 Python _client() 动态取值同口径）。
    public func chat(model: String, messages: [[String: JSONValue]],
                     images: [String]) async throws -> String {
        var payload: [String: JSONValue] = [
            "model": .string(model),
            "messages": .array(messages.map { .object($0) }),
            "stream": .bool(false),
        ]
        for (k, v) in NativeWorkflowHTTPConnector.modelOptions(model: model, backend: "ollama",
                                                               config: config()) {
            payload[k] = v
        }
        var droppedImages = 0
        var parsedImages: [String] = []
        for img in images {
            if let parsed = NativeWorkflowHTTPConnector.parseImage(img) {
                parsedImages.append(parsed)
            } else {
                droppedImages += 1
            }
        }
        var hadImages = false
        if !parsedImages.isEmpty, var msgs = payload["messages"]?.array, !msgs.isEmpty,
           case .object(var last) = msgs[msgs.count - 1] {
            last["images"] = .array(parsedImages.map { .string($0) })
            msgs[msgs.count - 1] = .object(last)
            payload["messages"] = .array(msgs)
            hadImages = true
        }
        let (status, data) = try await postChat(payload: payload)

        // 400/500 + 带图 → 模型不支持图片，剥图重试一次（M6 checkpoint-041）
        if (status == 400 || status == 500) && hadImages {
            if var msgs = payload["messages"]?.array, !msgs.isEmpty,
               case .object(var last) = msgs[msgs.count - 1] {
                last.removeValue(forKey: "images")
                msgs[msgs.count - 1] = .object(last)
                payload["messages"] = .array(msgs)
            }
            let (status2, data2) = try await postChat(payload: payload)
            guard status2 == 200 else {
                throw NativeChatConnectorError.api(status: status2,
                                                   detail: Self.errorDetail(String(decoding: data2, as: UTF8.self)))
            }
            var note = "\n\n[⚠️ 当前模型不支持多模态，图片未参与分析。建议切换到视觉模型（如 qwen2.5-vl）后重试。]"
            if droppedImages > 0 { note += "\n\n[⚠️ \(droppedImages) 张图片过大已丢弃，未参与分析。]" }
            return Self.ollamaContent(data2) + note
        }
        guard status == 200 else {
            throw NativeChatConnectorError.api(status: status,
                                               detail: Self.errorDetail(String(decoding: data, as: UTF8.self)))
        }
        let note = droppedImages > 0 ? "\n\n[⚠️ \(droppedImages) 张图片过大已丢弃，未参与分析。]" : ""
        return Self.ollamaContent(data) + note
    }

    /// /api/chat POST（timeout_reading 动态值，缺省 300 钳 10~7200——connector.py
    /// _client() 的 httpx timeout 口径；guard 拒绝/连接失败按错误类型映射）。
    private func postChat(payload: [String: JSONValue]) async throws -> (Int, Data) {
        var req = URLRequest(url: URL(string: "\(baseURL)/api/chat")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let rawTimeout = config()["timeout_reading"].flatMap(PySem.toFloat)
        req.timeoutInterval = min(max((rawTimeout ?? 0) > 0 ? rawTimeout! : 300.0, 10.0), 7200.0)
        req.httpBody = try JSONSerialization.data(withJSONObject: payload.mapValues { $0.anyValue })
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw NativeChatConnectorError.network("无效响应")
        }
        return (http.statusCode, data)
    }

    /// 响应取文本（connector.py L236-246：json.message.content；解析失败 → 原文）。
    private static func ollamaContent(_ data: Data) -> String {
        if let v = NativeJSONWriter.loads(data), case .object(let o) = v,
           case .object(let msg) = o["message"], let c = msg["content"]?.string {
            return c
        }
        return String(decoding: data, as: UTF8.self)
    }
}

// ════════════════════════════════════════════════════════════
// MARK: - 工具路由 ctx 与占位协议（W4b/W4c 注入）
// ════════════════════════════════════════════════════════════

/// search_knowledge 检索面（TS-120 阶段二；NativeKnowledgeStore 适配，本波已接）。
public protocol NativeKnowledgeSearcher: Sendable {
    /// warehouse.search_scoped(query, scope, project_id, limit, mode)。
    func searchScoped(_ query: String, scope: String, projectId: String?,
                      limit: Int, mode: String) -> [NativeKnowledgeSearchHit]
}

/// search_knowledge 结果条目（loop 组装 items 的字段源）。
public struct NativeKnowledgeSearchHit: Sendable, Equatable {
    public var title: String?
    public var scope: String?
    public var score: Double?
    public var body: String
    public init(title: String?, scope: String?, score: Double?, body: String) {
        self.title = title
        self.scope = scope
        self.score = score
        self.body = body
    }
}

/// knowledge_ctx（TS-120）：启用 search_knowledge 路由；nil → 该工具调用直接报错。
public struct NativeKnowledgeContext: Sendable {
    public var projectId: String
    public var searcher: any NativeKnowledgeSearcher
    public init(projectId: String, searcher: any NativeKnowledgeSearcher) {
        self.projectId = projectId
        self.searcher = searcher
    }
}

/// delegate_task 执行器（TS-107 M3-1，W4b 落地：NativeDelegationEngine）。
/// 对齐 loop.py delegate_task 路由段（L1822-2017）的完整入参面：
/// 工具参数原样透传 + 主会话四件套（project/agent/session/parentModel）
/// + sandbox/maxRounds/聊天附着图。取消经 CancellationError 上抛（Python
/// CancelledError 穿透 run_tool_loop 等价；loop 层捕获后按取消语义收尾）。
public protocol NativeDelegationRunner: Sendable {
    func routeDelegateTask(args: [String: JSONValue], projectId: String, agentId: String,
                           sessionId: String, parentModel: String, sandboxRoot: String,
                           maxRounds: Int, firstRoundImages: [String]?) async throws -> [String: JSONValue]
}

/// delegation_ctx（TS-107）：主会话传入；nil → 不允许委派（子会话双保险）。
public struct NativeDelegationContext: Sendable {
    public var projectId: String
    public var agentId: String
    public var sessionId: String
    public var model: String?
    /// nil = 委派执行器尚未注入（W4b）：loop 如实报「尚未原生接管」。
    public var runner: (any NativeDelegationRunner)?
    public init(projectId: String, agentId: String, sessionId: String,
                model: String? = nil, runner: (any NativeDelegationRunner)? = nil) {
        self.projectId = projectId
        self.agentId = agentId
        self.sessionId = sessionId
        self.model = model
        self.runner = runner
    }
}

/// app_control 分发器占位（0.4.9 3.48.2，W4c 注入）。
public protocol NativeAppControlDispatcher: Sendable {
    /// action_needs_confirm(module, action, confirm_list)。
    func actionNeedsConfirm(_ module: String, _ action: String,
                            confirmList: [String]?) -> Bool
    /// dispatch(module, action, params, ctx)。
    func dispatch(_ module: String, _ action: String, params: [String: JSONValue],
                  projectId: String, sessionId: String, sandboxRoot: String) async -> [String: JSONValue]
}

/// app_control_ctx：nil → 该工具调用直接报错（规格层本就不附加）。
public struct NativeAppControlContext: Sendable {
    public var projectId: String
    public var sessionId: String
    public var sandboxRoot: String
    public var authorizer: (any NativeToolAuthorizer)?
    /// nil = 分发器尚未注入（W4c）：loop 如实报「尚未原生接管」。
    public var dispatcher: (any NativeAppControlDispatcher)?
    public init(projectId: String, sessionId: String, sandboxRoot: String,
                authorizer: (any NativeToolAuthorizer)? = nil,
                dispatcher: (any NativeAppControlDispatcher)? = nil) {
        self.projectId = projectId
        self.sessionId = sessionId
        self.sandboxRoot = sandboxRoot
        self.authorizer = authorizer
        self.dispatcher = dispatcher
    }
}

/// Computer Use 执行器占位（0.4.9 3.48.1 + 0.4.32/0.4.33，W4c 注入）。
public protocol NativeComputerUseExecutor: Sendable {
    /// screen_view / mouse_click / keyboard_type / keyboard_hotkey / element_locate /
    /// cu_macro_record / cu_macro_replay / cu_macro_list 的统一执行面（W4c 补全）。
    func executeComputerUse(_ tool: String, args: [String: JSONValue]) async -> [String: JSONValue]
}

/// computer_use_ctx：nil → CU 工具调用直接报错（规格层本就不附加）。
public struct NativeComputerUseContext: Sendable {
    public var authorizer: (any NativeToolAuthorizer)?
    /// nil = 执行器尚未注入（W4c）：loop 如实报「尚未原生接管」。
    public var executor: (any NativeComputerUseExecutor)?
    public init(authorizer: (any NativeToolAuthorizer)? = nil,
                executor: (any NativeComputerUseExecutor)? = nil) {
        self.authorizer = authorizer
        self.executor = executor
    }
}

/// archive_work_unit 执行器（0.4.9 3.47.1；归档=搬移本会话消息入知识仓库）。
public protocol NativeWorkUnitArchiver: Sendable {
    /// loop.archive_work_unit(project_id, session_id, title, summary, scope)。
    func archiveWorkUnit(projectId: String, sessionId: String,
                         title: String, summary: String, scope: String) -> [String: JSONValue]
}

/// archive_ctx：nil → 该工具调用直接报错（会话窗开关关闭时规格层不附加该工具）。
public struct NativeArchiveContext: Sendable {
    public var projectId: String
    public var sessionId: String
    /// nil = 归档执行器尚未注入：loop 如实报「尚未原生接管」。
    public var archiver: (any NativeWorkUnitArchiver)?
    public init(projectId: String, sessionId: String,
                archiver: (any NativeWorkUnitArchiver)? = nil) {
        self.projectId = projectId
        self.sessionId = sessionId
        self.archiver = archiver
    }
}

/// read_skill 读取面（TS-110 M4；skills_mgr 仍走 HTTP 侧车 → 生产注入在 W4c）。
public protocol NativeSkillReader: Sendable {
    /// skills_mgr.read_skill(name) → {dir_name, description, content, enabled}；不存在 → nil。
    func readSkill(_ name: String) -> NativeSkillInfo?
    /// skills_mgr.list_skills() 的 dir_name 清单（报错列出可用技能用）。
    func listSkillNames() -> [String]
}

public struct NativeSkillInfo: Sendable, Equatable {
    public var dirName: String
    public var description: String
    public var content: String
    public var enabled: Bool
    public init(dirName: String, description: String, content: String, enabled: Bool) {
        self.dirName = dirName
        self.description = description
        self.content = content
        self.enabled = enabled
    }
}

// ════════════════════════════════════════════════════════════
// MARK: - 聊天运行时登记处（cancel.py + inject.py 逐行为）
// ════════════════════════════════════════════════════════════

/// 会话级停止/注入的进程内登记处（对标侧车模块全局字典；内核单例使用）。
///
/// cancel.py 语义：
///   · register/unregister 配对——每次注册创建**全新未置位**状态，结构上不可能残留
///   · 只有已注册（确有活流）的会话才接受取消请求（stop 端点如实回答）
///   · awaitCancel = asyncio.Event 等价：置位立即唤醒（gen() 硬取消在飞请求，W4c 消费）
/// inject.py 语义：
///   · begin/end_stream 配对；只在有活流时接受 push；drain 取出即清空；
///     end_stream 清残留队列（防下一轮流读到旧消息）
public final class NativeChatRuntimeCenter: @unchecked Sendable {

    private let lock = NSLock()

    // cancel.py _EVENTS 等价物：sessionId → 取消状态（含等待者）
    private struct CancelState {
        var isSet = false
        var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    }
    private var cancelStates: [String: CancelState] = [:]

    // inject.py _QUEUES / _ACTIVE 等价物
    private var injectQueues: [String: [String]] = [:]
    private var activeStreams: Set<String> = []

    public init() {}

    private static func sid(_ sessionId: String) -> String {
        sessionId.trimmingCharacters(in: .whitespaces)
    }

    // MARK: cancel.py

    /// register_stream：流开始时注册。空 sid → false（调用方跳过取消监听）。
    /// 每次注册都是全新未置位状态（旧条目直接丢弃，对齐 Python 赋值语义）。
    @discardableResult
    public func registerStream(_ sessionId: String) -> Bool {
        let sid = Self.sid(sessionId)
        guard !sid.isEmpty else { return false }
        lock.lock()
        cancelStates[sid] = CancelState()
        lock.unlock()
        return true
    }

    /// unregister_stream：流结束必须调用（finally）。丢弃状态，杜绝残留。
    public func unregisterStream(_ sessionId: String) {
        let sid = Self.sid(sessionId)
        guard !sid.isEmpty else { return }
        lock.lock()
        let entry = cancelStates[sid]
        cancelStates[sid] = nil
        lock.unlock()
        // 防御：残留等待者放行
        for (_, cont) in entry?.waiters ?? [:] { cont.resume() }
    }

    /// request_chat_cancel：true=确有活流并已请求取消；false=该会话本无活流。
    @discardableResult
    public func requestChatCancel(_ sessionId: String) -> Bool {
        let sid = Self.sid(sessionId)
        guard !sid.isEmpty else { return false }
        lock.lock()
        guard var entry = cancelStates[sid] else {
            lock.unlock()
            return false
        }
        let wasSet = entry.isSet
        entry.isSet = true
        let waiters = entry.waiters
        entry.waiters = [:]
        cancelStates[sid] = entry
        lock.unlock()
        for (_, cont) in waiters { cont.resume() }
        return !wasSet
    }

    /// is_chat_cancelled（run_tool_loop cancel_check 的轮询式 bool 语义；第二道防线）。
    public func isChatCancelled(_ sessionId: String) -> Bool {
        let sid = Self.sid(sessionId)
        guard !sid.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        return cancelStates[sid]?.isSet ?? false
    }

    /// make_cancel_check：构造传给 runToolLoop(cancelCheck:) 的回调。
    public func makeCancelCheck(_ sessionId: String) -> @Sendable () -> Bool {
        { [weak self] in self?.isChatCancelled(sessionId) ?? false }
    }

    /// asyncio.Event.wait() 等价（gen() 硬取消在飞请求用，W4c 消费；DBG-140 同款竞态兜底）。
    public func awaitChatCancel(_ sessionId: String) async {
        let sid = Self.sid(sessionId)
        guard !sid.isEmpty else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                var resumeNow = false
                lock.lock()
                if cancelStates[sid]?.isSet == true || Task<Never, Never>.isCancelled {
                    resumeNow = true
                } else {
                    cancelStates[sid]?.waiters[id] = cont
                }
                lock.unlock()
                if resumeNow { cont.resume() }
            }
        } onCancel: {
            lock.lock()
            let cont = cancelStates[sid]?.waiters[id]
            cancelStates[sid]?.waiters[id] = nil
            lock.unlock()
            cont?.resume()
        }
    }

    // MARK: inject.py

    /// begin_stream：标记该会话有活流（与 registerStream 同一处调用）。
    public func beginStream(_ sessionId: String) {
        let sid = Self.sid(sessionId)
        guard !sid.isEmpty else { return }
        lock.lock()
        activeStreams.insert(sid)
        if injectQueues[sid] == nil { injectQueues[sid] = [] }
        lock.unlock()
    }

    /// end_stream：清空残留队列（finally，与 unregisterStream 同一处调用）。
    public func endStream(_ sessionId: String) {
        let sid = Self.sid(sessionId)
        guard !sid.isEmpty else { return }
        lock.lock()
        activeStreams.remove(sid)
        injectQueues[sid] = nil
        lock.unlock()
    }

    /// push：true=已入队（有活流）；false=当前无活流应走正常发送。调用方须先落库。
    @discardableResult
    public func push(_ sessionId: String, content: String) -> Bool {
        let sid = Self.sid(sessionId)
        let text = content
        guard !sid.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        lock.lock()
        guard activeStreams.contains(sid) else {
            lock.unlock()
            return false
        }
        injectQueues[sid, default: []].append(text)
        lock.unlock()
        return true
    }

    /// drain：取出并清空（loop 每轮开始前调）。取出即清空，同一条只并入一次。
    public func drain(_ sessionId: String) -> [String] {
        let sid = Self.sid(sessionId)
        guard !sid.isEmpty else { return [] }
        lock.lock()
        guard let q = injectQueues[sid], !q.isEmpty else {
            lock.unlock()
            return []
        }
        injectQueues[sid] = []
        lock.unlock()
        return q
    }

    /// pending：诊断/测试用——该会话当前待注入消息条数。
    public func pending(_ sessionId: String) -> Int {
        let sid = Self.sid(sessionId)
        guard !sid.isEmpty else { return 0 }
        lock.lock()
        defer { lock.unlock() }
        return injectQueues[sid]?.count ?? 0
    }

    /// is_active：该会话当前是否有活流。
    public func isActive(_ sessionId: String) -> Bool {
        let sid = Self.sid(sessionId)
        guard !sid.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        return activeStreams.contains(sid)
    }

    /// make_inject_check：构造传给 runToolLoop(injectCheck:) 的回调（每轮 drain 一次）。
    public func makeInjectCheck(_ sessionId: String) -> @Sendable () -> [String] {
        { [weak self] in self?.drain(sessionId) ?? [] }
    }

    /// clear_all：测试用——清空全部注册。
    public func clearAll() {
        lock.lock()
        let states = cancelStates
        cancelStates = [:]
        injectQueues = [:]
        activeStreams = []
        lock.unlock()
        for (_, entry) in states {
            for (_, cont) in entry.waiters { cont.resume() }
        }
    }
}
