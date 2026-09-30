//
//  NativeOpenAIChatConnector.swift
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

//  逐行为移植（⛔ 只读行为规格源：subagent/sidecar/ollama/openai_compat.py）：
//    · chat_stream（L245-362）：POST {inference_base_url}/chat/completions（SSE，
//      stream_options.include_usage=true；Bearer 来自 inference_api_key）。
//      事件协议与 NativeOllamaChatConnector 完全一致（调用方零改动）：
//      content_delta / thinking_delta / tool_calls / done{counts} / stream_error。
//        - usage → counts 映射：prompt_tokens→prompt_eval_count、
//          completion_tokens→eval_count；缺 usage → 0（L323-326）
//        - thinking 双字段：reasoning_content 假值回落 reasoning（L333-335）
//        - 工具调用按 index 分块拼装：id/name 覆盖、arguments 追加；
//          finish_reason==tool_calls 或流末整体产出 Ollama 原生结构
//          [{id, function:{name, arguments}}]，id 空兜底 call_{idx}（L339-372）
//        - 400+tools 且 detail 含 tool/function → _ToolsUnsupported 降级
//          stream_error（逐字文案，非致命）（L384-387 + L358-360）
//        - 400/500+带图 → 剥图重试一次（重发 stream:false，stream_options/tools
//          原样保留，checkpoint-042）+ 多模态降级注记 + done(0,0)（L269-310）
//        - 超时 → stream_error「模型响应超时，已停止。已完成部分见上方事件。」
//    · chat（L182-242 无图路径：报错分析模型 analyze_error 用）
//    · _raise_stream_http / _raise_http（L374-400）：detail 提取（error 键或原文；
//      dict 取 message 或 str(dict)）、401/403 → 服务拒绝访问文案、
//      其余 → 对话请求失败（HTTP {status}）
//    · _base（L75-79）：地址未配置 → OllamaAPIError 逐字文案
//    · _client guard 契约（L81-119）：出站经 NativeNetworkGuard.assertGuard
//      （host = inference_base_url 主机名；代理应用差异见偏差②）
//
//  model_options 注入复用 P2-W4d2 移植（NativeWorkflowHTTPConnector.modelOptions，
//  backend=openai_compatible 显式传——对齐 openai_compat._INFER_BACKEND 语义漂移
//  修复）：num_ctx/top_k 静默丢弃、repeat_penalty→frequency_penalty、
//  num_predict→max_tokens；未配置 → 完全不注入（payload 键集逐字节不变）。
//  懒加载档位对 openai 天然 no-op：NativeLazyCtxTiers.lazyCeiling 仅
//  ollama/model_package 生效（对齐 infer_options.lazy_ceiling L245-258：
//  openai_compatible 的上下文由服务端自行管理，懒加载不介入）。
//
//  偏差（汇报清单同步）：
//    ① URLSession 的超时为整体 timeoutInterval，不细分 httpx connect/read 双超时
//       （同 W4a 偏差①）；连接/流内超时统一映射 stream_error。
//    ② 代理不经 URLSession 注入：guard 只做放行/拦截判定（NativeNetworkGuard 全仓
//       同款——git 子进程 egressArgs 是唯一代理应用点）；Python 经 httpx proxy
//       参数应用代理。trust_env=False 的「不吃环境变量代理」与 URLSession.shared
//       读系统代理存在语义差（系统代理≠环境变量，如实记录）。
//    ③ 错误体为「合法 JSON 但非对象」（如裸 JSON 字符串）时 Python .get("error")
//       抛 AttributeError 穿透至 gen() 安全网；原生按 detail=原文处理（真实服务端
//       错误体恒为对象或纯文本，判定不可达）。usage/choices 等非对象真值同理。
//    ④ timeout_stream_reading 钳制 10~7200、兜底 1800（M11 口径对齐，0.7.4）：
//       与 NativeOllamaChatConnector 完全一致——历史上本连接器按 Python
//       infer_options 旧口径钳 30~21600，两连接器分歧已消除（写路径
//       NativeConfigStore.timeoutKeys 同步放宽到 10~7200，面板可持久化全范围）。
//    ⑤ 非流式 chat 的 images 变体刻意裁剪（NativeChatConnector 协议无调用方；
//       非流式带图面已由 NativeWorkflowConnector.chatOpenAI 覆盖——工作流节点
//       路径，W2b 明确不触碰）。
//    ⑥ unload_model / list_loaded_models 为协议外 no-op（Python L409-427），
//       原生无调用点，不移植；list_models 已由 P3-W2a 推理端点面接管
//       （NativeInferenceEndpointAssembly.liveOpenAIModelIDs）。
//

import Foundation

// ════════════════════════════════════════════════════════════
// MARK: - 传输缝（ollamaTagsFetcher 先例：单测注入脚本化假传输，绝不触网）
// ════════════════════════════════════════════════════════════

/// OpenAI 兼容连接器的传输层。两个方法对应 httpx 的两种调用形态；
/// 生产 = URLSession，测试 = 脚本化假传输（请求逐条录证供字节级断言）。
public protocol NativeOpenAITransport: Sendable {
    /// client.stream("POST", url, json=payload) 等价：返回（状态码，逐行序列）。
    /// 行序列 = aiter_lines（行尾 \r\n 已剥离）；连接级错误（含超时）直接 throw，
    /// 流中途错误经序列 throw 上抛。
    func streamLines(_ req: URLRequest) async throws
        -> (status: Int, lines: AsyncThrowingStream<String, Error>)
    /// client.post(url, json=payload) 等价：返回（状态码，响应体）。
    func postJSON(_ req: URLRequest) async throws -> (status: Int, data: Data)
}

/// 生产传输（URLSession；信任环境差异见文件头偏差②）。
public struct NativeURLSessionOpenAITransport: NativeOpenAITransport {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func streamLines(_ req: URLRequest) async throws
        -> (status: Int, lines: AsyncThrowingStream<String, Error>) {
        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw NativeChatConnectorError.network("无效响应")
        }
        let lines = AsyncThrowingStream<String, Error> { cont in
            let task = Task {
                do {
                    for try await line in bytes.lines { cont.yield(line) }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            // 消费方结束迭代（含取消）→ 取消在飞读取，确保连接真正释放
            cont.onTermination = { @Sendable _ in task.cancel() }
        }
        return (http.statusCode, lines)
    }

    public func postJSON(_ req: URLRequest) async throws -> (status: Int, data: Data) {
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw NativeChatConnectorError.network("无效响应")
        }
        return (http.statusCode, data)
    }
}

// ════════════════════════════════════════════════════════════
// MARK: - 生产连接器（openai_compat.py 逐行为）
// ════════════════════════════════════════════════════════════

public final class NativeOpenAIChatConnector: NativeChatConnector {

    /// _ToolsUnsupported 等价物：带 tools 请求被 400 拒绝且判定工具不支持
    /// → 转降级事件（非致命，不裸抛）。
    private struct ToolsUnsupported: Error { let detail: String }

    /// 工具调用累积缓冲槽（tc_buf value 同构：id/name 覆盖、arguments 追加）。
    private struct ToolCallSlot {
        var id = ""
        var name = ""
        var arguments = ""
    }

    private let configProvider: @Sendable () -> [String: JSONValue]
    private let networkGuard: NativeNetworkGuard
    private let transport: any NativeOpenAITransport

    /// 生产装配：config 动态读（对齐 _client 配置指纹哲学），出站过内核守卫。
    public init(config: NativeConfigStore, guard networkGuard: NativeNetworkGuard) {
        self.configProvider = { (try? config.getConfig()) ?? NativeConfigStore.defaultConfig }
        self.networkGuard = networkGuard
        self.transport = NativeURLSessionOpenAITransport()
    }

    /// 测试/装配注入用（脚本化假传输，绝不触网）。
    public init(configProvider: @escaping @Sendable () -> [String: JSONValue],
                guard networkGuard: NativeNetworkGuard,
                transport: any NativeOpenAITransport) {
        self.configProvider = configProvider
        self.networkGuard = networkGuard
        self.transport = transport
    }

    private func config() -> [String: JSONValue] { configProvider() }

    /// timeout_stream_reading()：兜底 1800，钳 10~7200（M11 口径对齐：
    /// 与 NativeOllamaChatConnector 同范围，0.7.4 起两连接器一致，原 W4a 遗留
    /// 30~21600 分歧口径消除——infer_options L134-136 旧值不再单独保留）。
    public func timeoutStreamReading() -> Double {
        guard let f = config()["timeout_stream_reading"].flatMap(PySem.toFloat), f > 0 else {
            return 1800.0
        }
        return min(max(f, 10.0), 7200.0)
    }

    /// _base()（L75-79）：地址未配置 → OllamaAPIError 逐字文案。
    private func baseURL() throws -> String {
        let base = NativeInferenceEndpointAssembly.openAIBase(config())
        guard !base.isEmpty else {
            throw NativeChatConnectorError.openAI(
                status: 400,
                message: "推理后端地址未配置（设置面板：推理后端 → 地址）",
                detail: "")
        }
        return base
    }

    /// _host_of（L46-48）：urlparse(base).hostname or ""。
    private static func host(of base: String) -> String {
        URL(string: base)?.host ?? ""
    }

    /// 出站守卫（_guard L81-85）：被拒抛 NativeNetworkGuardError（gen()/loop 转
    /// error 事件消费其 message）；代理差异见文件头偏差②。
    private func assertEgress(_ base: String) throws {
        _ = try networkGuard.assertGuard(Self.host(of: base))
    }

    /// 请求构造：Bearer（inference_api_key，L114-116）+ JSON body + 整体超时。
    private func makeRequest(base: String, payload: [String: JSONValue],
                             timeout: TimeInterval) throws -> URLRequest {
        guard let url = URL(string: "\(base)/chat/completions") else {
            throw NativeChatConnectorError.network("无效地址: \(base)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = NativeInferenceEndpointAssembly.openAIKey(config())
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        req.timeoutInterval = timeout
        req.httpBody = try JSONSerialization.data(withJSONObject: payload.mapValues { $0.anyValue })
        return req
    }

    // MARK: - chat_stream（openai_compat.py L245-362 逐行为）

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
                } catch let e as NativeNetworkGuardError {
                    // guard 拒绝穿透（_client 在 try 外上抛同语义；loop 消费 message）
                    continuation.finish(throwing: e)
                } catch let e as URLError where e.code == .timedOut {
                    // httpx.TimeoutException 兜底：超时不裸抛 → stream_error
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

    // swiftlint:disable:next function_body_length
    private func streamMain(
        model: String, messages: [[String: JSONValue]],
        tools: [JSONValue]?, images: [String]?,
        continuation: AsyncThrowingStream<NativeChatStreamEvent, Error>.Continuation
    ) async throws {
        // ── payload（L253-262）：stream_options.include_usage 恒 true ──
        var payload: [String: JSONValue] = [
            "model": .string(model),
            "messages": .array(messages.map { .object($0) }),
            "stream": .bool(true),
            "stream_options": .object(["include_usage": .bool(true)]),
        ]
        // A2/A4：model_options 注入（显式 backend=openai_compatible；空 dict 绝不注入）
        for (k, v) in NativeWorkflowHTTPConnector.modelOptions(
            model: model, backend: "openai_compatible", config: config()) {
            payload[k] = v
        }
        if let tools, !tools.isEmpty {
            payload["tools"] = .array(tools)
        }
        // 图片 → OpenAI content 数组（_image_parts L135-144 + _merge L166-179）：
        // 解析失败的图静默跳过（流式路径无 dropped 计数）；合入【最后一条 user 消息】。
        var parsedImages: [String] = []
        for img in images ?? [] {
            if let b64 = NativeWorkflowHTTPConnector.parseImage(img) { parsedImages.append(b64) }
        }
        if !parsedImages.isEmpty, var msgs = payload["messages"]?.array {
            merge: for i in stride(from: msgs.count - 1, through: 0, by: -1) {
                guard case .object(let m) = msgs[i], m["role"]?.string == "user" else { continue }
                let text = m["content"]?.string ?? WFText.pyStr(m["content"] ?? .null)
                var parts: [JSONValue] = [.object(["type": .string("text"),
                                                   "text": .string(text)])]
                parts += parsedImages.map { b64 -> JSONValue in
                    .object(["type": .string("image_url"),
                             "image_url": .object(["url": .string("data:image/png;base64," + b64)])])
                }
                var m2 = m
                m2["content"] = .array(parts)
                msgs[i] = .object(m2)
                payload["messages"] = .array(msgs)
                break merge
            }
        }
        // had_images（L270）：任一消息 content 为数组即真（与 Python isinstance list 同口径）
        let hadImages = payload["messages"]?.array?.contains {
            if case .object(let m) = $0, case .array = m["content"] { return true }
            return false
        } ?? false

        let base = try baseURL()
        try assertEgress(base)   // guard 拒绝 → NativeNetworkGuardError 穿透（_client 同语义）

        let req = try makeRequest(base: base, payload: payload, timeout: timeoutStreamReading())
        let (status, lines) = try await transport.streamLines(req)

        // ── 非 200（L274-311）──
        if status != 200 {
            // aread 等价：读全量错误体（utf-8 errors=replace ≈ String(decoding:)）
            var body = ""
            for try await line in lines { body += line + "\n" }
            // checkpoint-041：400/500 + 带图 → 剥图重试一次（stream:false）+ 降级文案
            if (status == 400 || status == 500), hadImages {
                try await retryWithoutImages(base: base, payload: payload,
                                             continuation: continuation)
                return
            }
            do {
                try raiseStreamHTTP(status: status, body: body,
                                    toolsRequested: tools?.isEmpty == false)
            } catch let e as ToolsUnsupported {
                // L358-360：降级 stream_error（非致命）
                continuation.yield(.streamError(
                    "当前推理后端不支持工具调用（\(e.detail)）。"
                    + "可在设置面板关闭工具支持，或换用支持工具的后端/模型。"))
                return
            }
            return
        }

        // ── SSE 逐行（L312-357）──
        var usagePE = 0
        var usageEC = 0
        var tcBuf: [Int: ToolCallSlot] = [:]
        streamLoop: for try await rawLine in lines {
            try Task.checkCancellation()
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("data:") else { continue }
            let dataStr = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if dataStr == "[DONE]" { break streamLoop }
            guard let data = dataStr.data(using: .utf8),
                  let v = NativeJSONWriter.loads(data),
                  case .object(let obj) = v else { continue }
            // usage（L323-326）：choices 检查【之前】；空 dict 假值跳过；后到者覆盖
            if case .object(let u)? = obj["usage"], !u.isEmpty {
                usagePE = Int(PySem.toFloat(u["prompt_tokens"] ?? .null) ?? 0)
                usageEC = Int(PySem.toFloat(u["completion_tokens"] ?? .null) ?? 0)
            }
            guard case .array(let choices)? = obj["choices"], let first = choices.first,
                  case .object(let ch) = first else { continue }
            let delta = ch["delta"]?.object ?? [:]
            // thinking（L333-335）：reasoning_content 假值 → reasoning 回落；真值才产出
            var th = delta["reasoning_content"]
            if !WFText.truthy(th) { th = delta["reasoning"] }
            if WFText.truthy(th), let ths = th?.string {
                continuation.yield(.thinkingDelta(ths))
            }
            // content（L336-338）：真值才产出
            if let content = delta["content"]?.string, !content.isEmpty {
                continuation.yield(.contentDelta(content))
            }
            // 工具调用分块拼装（L340-349）：id/name 覆盖、arguments 追加
            if case .array(let tcds)? = delta["tool_calls"] {
                for tcd in tcds {
                    guard case .object(let t) = tcd else { continue }
                    let idx = Int(PySem.toFloat(t["index"] ?? .null) ?? 0)
                    var slot = tcBuf[idx] ?? ToolCallSlot()
                    if let id = t["id"]?.string, !id.isEmpty { slot.id = id }
                    if case .object(let fn)? = t["function"] {
                        if let name = fn["name"]?.string, !name.isEmpty { slot.name = name }
                        if let args = fn["arguments"]?.string, !args.isEmpty {
                            slot.arguments += args
                        }
                    }
                    tcBuf[idx] = slot
                }
            }
            // finish_reason==tool_calls → 整体产出并清缓冲（L350-353）
            if ch["finish_reason"]?.string == "tool_calls", !tcBuf.isEmpty {
                continuation.yield(.toolCalls(Self.flushToolCalls(tcBuf)))
                tcBuf = [:]
            }
        }
        // [DONE] 或流结束：残留工具调用整体产出（L354-356）
        if !tcBuf.isEmpty {
            continuation.yield(.toolCalls(Self.flushToolCalls(tcBuf)))
        }
        continuation.yield(.done(promptEvalCount: usagePE, evalCount: usageEC))
    }

    /// _flush_tool_calls（L364-372）：累积缓冲 → Ollama 原生工具调用结构
    /// [{id, function:{name, arguments}}]（index 升序；id 空兜底 call_{idx}）。
    private static func flushToolCalls(_ buf: [Int: ToolCallSlot]) -> [[String: JSONValue]] {
        buf.keys.sorted().map { idx in
            let slot = buf[idx]!
            return [
                "id": .string(slot.id.isEmpty ? "call_\(idx)" : slot.id),
                "function": .object([
                    "name": .string(slot.name),
                    "arguments": .string(slot.arguments),
                ]),
            ]
        }
    }

    /// checkpoint-041/042（L276-310）：剥图重试一次——重发必须 stream:false
    /// （否则服务端返回多行流式响应，一次性 .json() 抛 "Extra data"）；
    /// {**payload, "stream": False} 逐字：stream_options/tools 原样保留。
    private func retryWithoutImages(
        base: String, payload: [String: JSONValue],
        continuation: AsyncThrowingStream<NativeChatStreamEvent, Error>.Continuation
    ) async throws {
        var stripped = payload
        if var msgs = stripped["messages"]?.array {
            for i in msgs.indices {
                guard case .object(var m) = msgs[i],
                      case .array(let parts)? = m["content"] else { continue }
                // content 数组拍平为纯文本（仅 text 块，join 无分隔）
                let joined = parts.compactMap { p -> String? in
                    guard case .object(let po) = p, po["type"]?.string == "text" else { return nil }
                    return po["text"]?.string ?? ""
                }.joined()
                m["content"] = .string(joined)
                msgs[i] = .object(m)
            }
            stripped["messages"] = .array(msgs)
        }
        stripped["stream"] = .bool(false)
        let req = try makeRequest(base: base, payload: stripped,
                                  timeout: timeoutStreamReading())
        let (status, data) = try await transport.postJSON(req)
        guard status == 200 else {
            try raiseHTTP(status: status, body: String(decoding: data, as: UTF8.self))
            return
        }
        // content 提取（L290-305）：单 JSON → choices[0].message.content；
        // 防御多行 SSE → 逐行 data: 拼接（[DONE] 出现即跳过该行）
        var content = ""
        if let v = NativeJSONWriter.loads(data), case .object(let o) = v {
            var ch: [String: JSONValue] = [:]
            if case .array(let choices)? = o["choices"], let first = choices.first,
               case .object(let c0) = first {
                ch = c0
            }
            if case .object(let msg)? = ch["message"] {
                content = msg["content"]?.string ?? ""
            }
        } else {
            for line0 in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                let line = line0.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("data:"), !line.contains("[DONE]") else { continue }
                let ds = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard let d = ds.data(using: .utf8), let v = NativeJSONWriter.loads(d),
                      case .object(let obj) = v,
                      case .array(let choices)? = obj["choices"], let first = choices.first,
                      case .object(let ch) = first,
                      case .object(let delta)? = ch["delta"] else { continue }
                content += delta["content"]?.string ?? ""
            }
        }
        continuation.yield(.contentDelta(content
            + "\n\n[⚠️ 当前模型不支持多模态，图片未参与分析。建议切换到视觉模型（如 qwen2.5-vl）后重试。]"))
        continuation.yield(.done(promptEvalCount: 0, evalCount: 0))
    }

    // MARK: - 错误出口（_raise_stream_http L374-392 / _raise_http L394-400 逐行为）

    /// Python str(x)[:300]（码点截断，NativeAgentLoop.pyPrefix 同口径）。
    private static func pyPrefix300(_ s: String) -> String {
        String(s.unicodeScalars.prefix(300))
    }

    /// _raise_stream_http：detail 提取（error 键真值或原文；dict 取 message 或
    /// str(dict)）→ 400+tools+tool/function 关键词 → _ToolsUnsupported；
    /// 401/403 → 服务拒绝访问；其余 → 对话请求失败（HTTP {status}）。
    private func raiseStreamHTTP(status: Int, body: String, toolsRequested: Bool) throws {
        var detail = body
        if let data = body.data(using: .utf8), let v = NativeJSONWriter.loads(data),
           case .object(let o) = v, let e = o["error"], WFText.truthy(e) {
            // detail = loads(body).get("error") or body（假值 → 原文）
            if case .object(let eo) = e {
                // str(detail.get("message") or detail)
                if let msg = eo["message"], WFText.truthy(msg) {
                    detail = WFText.pyStr(msg)
                } else {
                    detail = WFText.pyStr(e)
                }
            } else {
                detail = WFText.pyStr(e)
            }
        }
        // 带 tools 请求 400 且与工具相关 → 后端不支持工具（转降级事件，非致命）
        if status == 400, toolsRequested {
            let lower = detail.lowercased()
            if lower.contains("tool") || lower.contains("function") {
                throw ToolsUnsupported(detail: detail)
            }
        }
        if status == 401 || status == 403 {
            let d300 = Self.pyPrefix300(detail)
            let msg = "对话请求失败：服务拒绝访问（HTTP \(status)）。\(d300)"
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw NativeChatConnectorError.openAI(status: status, message: msg, detail: d300)
        }
        throw NativeChatConnectorError.openAI(
            status: status, message: "对话请求失败（HTTP \(status)）",
            detail: Self.pyPrefix300(detail))
    }

    /// _raise_http（prefix="对话请求失败"）：detail = 原文截 300（无 error 键提取）。
    private func raiseHTTP(status: Int, body: String) throws {
        let detail = Self.pyPrefix300(body)
        if status == 401 || status == 403 {
            let msg = "对话请求失败：服务拒绝访问（HTTP \(status)）。\(detail)"
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw NativeChatConnectorError.openAI(status: status, message: msg, detail: detail)
        }
        throw NativeChatConnectorError.openAI(
            status: status, message: "对话请求失败（HTTP \(status)）", detail: detail)
    }

    // MARK: - chat（L182-242 无图路径；报错分析模型 analyze_error 用）

    public func chat(model: String, messages: [[String: JSONValue]]) async throws -> String {
        var payload: [String: JSONValue] = [
            "model": .string(model),
            "messages": .array(messages.map { .object($0) }),
            "stream": .bool(false),
        ]
        for (k, v) in NativeWorkflowHTTPConnector.modelOptions(
            model: model, backend: "openai_compatible", config: config()) {
            payload[k] = v
        }
        let base = try baseURL()
        try assertEgress(base)
        // 双保险（NativeOllamaChatConnector 同款：调用方 analyzeError 有超时竞速）；
        // 写死 60s → 配置化 error_analysis_timeout_s（0.7.5 W13，缺省 60 钳 5~600，两处同源）
        let req = try makeRequest(base: base, payload: payload,
                                  timeout: NativeConfigStore.errorAnalysisTimeoutS(config()))
        let (status, data) = try await transport.postJSON(req)
        guard status == 200 else {
            try raiseHTTP(status: status, body: String(decoding: data, as: UTF8.self))
            return ""
        }
        // ((data.get("choices") or [{}])[0].get("message") or {}).get("content", "")；
        // 任何解析失败 → 原文（L238-242 except Exception 宽口径）
        if let v = NativeJSONWriter.loads(data), case .object(let o) = v {
            var ch: [String: JSONValue] = [:]
            if case .array(let choices)? = o["choices"], let first = choices.first,
               case .object(let c0) = first {
                ch = c0
            }
            if case .object(let msg)? = ch["message"] {
                return msg["content"]?.string ?? ""
            }
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }
}
