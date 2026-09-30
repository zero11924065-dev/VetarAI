//
//  NativeWorkflowConnector.swift
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

//  工作流引擎的模型调用面（connector 协议 + 生产实现）：
//    · 协议 NativeWorkflowConnector = 侧车 connector.chat / unload_model 的调用形态
//      （messages 数组 + images 可选 + read_timeout_s 可选覆盖）——测试桩与
//      checkpoint077 的 FakeConn 同形替换。
//    · 生产实现 NativeWorkflowHTTPConnector：逐行为移植
//      sidecar/ollama/connector.py chat/unload_model 与 openai_compat.py chat：
//        - POST {ollama_base}/api/chat（stream:false，图片 base64 合入末条 user 消息，
//          400/500+带图 → 剥图重试一次并加降级注记，>8MB base64 丢弃注记）
//        - keep_alive:0 空消息卸载（unload_model，失败静默 False）
//        - openai_compatible：POST {inference_base_url}/chat/completions（Bearer 可选，
//          image_url 块，同款剥图重试）
//        - model_options 注入（infer_options.py：三级键匹配 + 按后端参数映射 +
//          逐参数 coerce/范围校验；空 → 完全不注入，绝不出现在 payload）
//        - 超时：read_timeout_s 覆盖 > config timeout_reading（默认 300，钳 10~7200）
//
//  已知偏差（汇报清单同步）：
//    ① inference_backend=model_package / 模型包路由未原生接管（modelPacks 模块仍 HTTP，
//       P2-W3+ 排期）——该配置下推理节点报错「模型包后端尚未原生接管」。
//    ② ctx_lazy 懒加载档位注入未移植（0.4.31 聊天循环特性）：num_ctx 直接注配置值
//       （等价 ctx_lazy_enabled=false 路径）。
//    ③ URLSession 不区分 connect/read 超时（URLRequest.timeoutInterval 覆盖全程）。
//

import Foundation

// MARK: - 连接器协议（侧车 connector 调用形态）

public protocol NativeWorkflowConnector: Sendable {
    /// connector.chat(model, messages, images=..., read_timeout_s=...) → 文本。
    /// images nil = 不带图（Python `images if images else None` 口径）；
    /// readTimeoutS nil = 全局默认（Python 缺省不传 kwarg 的同语义）。
    func chat(model: String, messages: [[String: JSONValue]], images: [String]?,
              readTimeoutS: Double?) async throws -> String
    /// connector.unload_model(name) → Bool（失败静默 False，不阻塞流程）。
    @discardableResult
    func unloadModel(_ model: String) async -> Bool
}

// MARK: - 连接器错误（_exc_text 的 type(e).__name__ 对齐载体）

public enum WorkflowConnectorError: Error, Equatable {
    /// URLError.timedOut / 显式超时 → type 名对齐 Python 3.11+ asyncio.TimeoutError 别名。
    case timeout
    /// OllamaAPIError 等价（4xx/5xx 业务错误；openai_compat 复用同类——两边 type 名一致）。
    case api(status: Int, prefix: String)
    /// 网络层错误（httpx.ConnectError 族无法逐字对齐，给类型名 + 简述）。
    case network(String)
    /// model_package 后端未原生接管（见文件头偏差①）。
    case unsupportedBackend(String)

    /// Python type(e).__name__。
    public var pyTypeName: String {
        switch self {
        case .timeout: return "TimeoutError"
        case .api: return "OllamaAPIError"
        case .network: return "ConnectError"
        case .unsupportedBackend: return "RuntimeError"
        }
    }

    /// Python str(e)。
    public var pyMessage: String {
        switch self {
        case .timeout: return ""
        case .api(let status, let prefix): return "\(prefix)（HTTP \(status)）"
        case .network(let msg): return msg
        case .unsupportedBackend(let msg): return msg
        }
    }
}

// MARK: - 生产实现（Ollama / OpenAI 兼容，config 每次调用动态读——对齐 _client 指纹哲学）

public final class NativeWorkflowHTTPConnector: NativeWorkflowConnector {

    /// config 读取源（NativeConfigStore.getConfig；测试注入字典）。
    private let configProvider: @Sendable () throws -> [String: JSONValue]

    public init(config: NativeConfigStore) {
        self.configProvider = { try config.getConfig() }
        self.configStore = config
    }

    /// 测试/双跑注入用。
    public init(configProvider: @escaping @Sendable () throws -> [String: JSONValue]) {
        self.configProvider = configProvider
        self.configStore = nil
    }

    /// REQ-FUT-020：.vmodel 推理测试缝（生产 nil = NativeVModelChatRouter.shared
    /// + 真注册表；单测注入假闭包，绝不触模型文件）。
    public var vmodelChatOverride: (@Sendable (String, [[String: JSONValue]])
        async throws -> String)? = nil

    /// configStore 持有（vmodel 分支装 installer 用；configProvider 测试注入形态为 nil）
    private let configStore: NativeConfigStore?

    private func config() -> [String: JSONValue] { (try? configProvider()) ?? [:] }

    // MARK: infer_options.py 超时（_read_timeout：<=0/非法 → 兜底常量；钳范围）

    /// timeout_reading()：默认 300，钳 10~7200。
    public func timeoutReading() -> Double {
        Self.readTimeout(config()["timeout_reading"], fallback: 300.0, range: 10.0...7200.0)
    }

    /// timeout_connect()：默认 10，钳 1~600。
    public func timeoutConnect() -> Double {
        Self.readTimeout(config()["timeout_connect"], fallback: 10.0, range: 1.0...600.0)
    }

    private static func readTimeout(_ raw: JSONValue?, fallback: Double, range: ClosedRange<Double>) -> Double {
        guard let f = raw.flatMap(PySem.toFloat), f > 0 else { return fallback }
        return min(max(f, range.lowerBound), range.upperBound)
    }

    private var backend: String {
        (config()["inference_backend"]?.string ?? "ollama")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - chat 分发（routing.py _active：openai_compatible → OpenAI 兼容端；其余 → Ollama）

    public func chat(model: String, messages: [[String: JSONValue]], images: [String]?,
                     readTimeoutS: Double?) async throws -> String {
        // REQ-FUT-020（0.7.5 W1）：.vmodel 节点模型全局平级——前缀命中走 MLX 路由，
        // 不进后端分发（ollama/openai 均无此模型，误发只会 404 且语义错位）。
        // 失败抛 NativeVModelError 黑盒上抛（引擎节点错误链如实呈现，不静默换模型）。
        if NativeVModelChat.isVModelName(model) {
            if let vmodelChatOverride { return try await vmodelChatOverride(model, messages) }
            guard let configStore else {
                throw WorkflowConnectorError.network("vmodel 推理通道未装配")
            }
            return try await NativeVModelChatRouter.shared.chat(
                poolName: model, installer: NativeVModelInstaller(config: configStore),
                messages: messages)
        }
        switch backend {
        case "openai_compatible":
            return try await chatOpenAI(model: model, messages: messages, images: images,
                                        readTimeoutS: readTimeoutS)
        case "model_package":
            throw WorkflowConnectorError.unsupportedBackend(
                "模型包后端尚未原生接管（P2-W3+ 排期）：工作流推理节点请暂用 Ollama/OpenAI 兼容后端")
        default:
            return try await chatOllama(model: model, messages: messages, images: images,
                                        readTimeoutS: readTimeoutS)
        }
    }

    // MARK: - Ollama /api/chat（connector.py chat L166-246 逐行为）

    private func chatOllama(model: String, messages: [[String: JSONValue]], images: [String]?,
                            readTimeoutS: Double?) async throws -> String {
        let base = (config()["ollama_base_url"]?.string ?? "http://localhost:11434")
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        var payload: [String: JSONValue] = [
            "model": .string(model),
            "messages": .array(messages.map { .object($0) }),
            "stream": .bool(false),
        ]
        // A2/A4：model_options 注入（空 dict 绝不注入——部分服务端空 options 报 400）
        for (k, v) in Self.modelOptions(model: model, backend: "ollama", config: config()) {
            payload[k] = v
        }
        // 图片解析（_parse_image：data URI 取 base64 段 / 文件读字节 / >50 视为已编码；>8MB 丢弃）
        var droppedImages = 0
        var parsedImages: [String] = []
        for img in images ?? [] {
            if let parsed = Self.parseImage(img) {
                parsedImages.append(parsed)
            } else {
                droppedImages += 1
            }
        }
        var hadImages = false
        if !parsedImages.isEmpty, var msgs = payload["messages"]?.array, !msgs.isEmpty {
            if case .object(var last) = msgs[msgs.count - 1] {
                last["images"] = .array(parsedImages.map { .string($0) })
                msgs[msgs.count - 1] = .object(last)
                payload["messages"] = .array(msgs)
                hadImages = true
            }
        }

        let timeout = readTimeoutS ?? timeoutReading()
        let (status, body) = try await postJSON("\(base)/api/chat", payload: payload,
                                                headers: [:], timeout: timeout)

        // 400/500 + 带图 → 模型不支持图片，剥图重试一次（checkpoint-041）
        if (status == 400 || status == 500) && hadImages {
            if var msgs = payload["messages"]?.array, !msgs.isEmpty,
               case .object(var last) = msgs[msgs.count - 1] {
                last.removeValue(forKey: "images")
                msgs[msgs.count - 1] = .object(last)
                payload["messages"] = .array(msgs)
            }
            let (status2, body2) = try await postJSON("\(base)/api/chat", payload: payload,
                                                      headers: [:], timeout: timeout)
            guard status2 == 200 else { throw WorkflowConnectorError.api(status: status2, prefix: "对话请求失败") }
            let content = Self.ollamaContent(body2)
            var note = "\n\n[⚠️ 当前模型不支持多模态，图片未参与分析。建议切换到视觉模型（如 qwen2.5-vl）后重试。]"
            if droppedImages > 0 { note += "\n\n[⚠️ \(droppedImages) 张图片过大已丢弃，未参与分析。]" }
            return content + note
        }
        guard status == 200 else { throw WorkflowConnectorError.api(status: status, prefix: "对话请求失败") }
        var note = ""
        if droppedImages > 0 { note = "\n\n[⚠️ \(droppedImages) 张图片过大已丢弃，未参与分析。]" }
        return Self.ollamaContent(body) + note
    }

    /// 响应取文本：json.message.content；JSON 解析失败 → 原文（connector.py L236-246）。
    private static func ollamaContent(_ body: Data) -> String {
        if let v = NativeJSONWriter.loads(body), case .object(let o) = v,
           case .object(let msg) = o["message"], let content = msg["content"]?.string {
            return content
        }
        let text = String(decoding: body, as: UTF8.self)
        if text.trimmingCharacters(in: .whitespaces).hasPrefix("{"),
           let data = text.data(using: .utf8), let v = NativeJSONWriter.loads(data),
           case .object(let o) = v, case .object(let msg) = o["message"] {
            return msg["content"]?.string ?? ""
        }
        return text
    }

    // MARK: - OpenAI 兼容 /chat/completions（openai_compat.py chat L182-242 逐行为）

    private func chatOpenAI(model: String, messages: [[String: JSONValue]], images: [String]?,
                            readTimeoutS: Double?) async throws -> String {
        let base = (config()["inference_base_url"]?.string ?? "")
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard !base.isEmpty else {
            // openai_compat._base() 未配置即抛——文案对齐其报错口径
            throw WorkflowConnectorError.network("推理后端地址未配置（inference_base_url）")
        }
        var payload: [String: JSONValue] = [
            "model": .string(model),
            "messages": .array(messages.map { .object($0) }),
            "stream": .bool(false),
        ]
        for (k, v) in Self.modelOptions(model: model, backend: "openai_compatible", config: config()) {
            payload[k] = v
        }
        var droppedImages = 0
        var parsedImages: [String] = []
        for img in images ?? [] {
            if let parsed = Self.parseImage(img) {
                parsedImages.append(parsed)
            } else {
                droppedImages += 1
            }
        }
        var hadImages = false
        if !parsedImages.isEmpty, var msgs = payload["messages"]?.array {
            // 合入最后一条 user 消息（OpenAI content 数组格式）
            for i in stride(from: msgs.count - 1, through: 0, by: -1) {
                guard case .object(let m) = msgs[i], m["role"]?.string == "user" else { continue }
                let text = m["content"]?.string ?? WFText.pyStr(m["content"] ?? .null)
                var parts: [JSONValue] = [.object(["type": .string("text"), "text": .string(text)])]
                parts += parsedImages.map { b64 -> JSONValue in
                    let url = "data:image/png;base64," + b64
                    return .object(["type": .string("image_url"),
                                    "image_url": .object(["url": .string(url)])])
                }
                var m2 = m
                m2["content"] = .array(parts)
                msgs[i] = .object(m2)
                payload["messages"] = .array(msgs)
                hadImages = true
                break
            }
        }

        var headers: [String: String] = [:]
        if let key = config()["inference_api_key"]?.string, !key.isEmpty {
            headers["Authorization"] = "Bearer \(key)"
        }
        let timeout = readTimeoutS ?? timeoutReading()
        let (status, body) = try await postJSON("\(base)/chat/completions", payload: payload,
                                                headers: headers, timeout: timeout)

        // 400/500 + 带图 → 剥图重试一次（content 数组拍平为纯文本）
        if (status == 400 || status == 500) && hadImages {
            if var msgs = payload["messages"]?.array {
                for i in msgs.indices {
                    guard case .object(var m) = msgs[i], case .array(let parts) = m["content"] else { continue }
                    let joined = parts.compactMap { p -> String? in
                        guard case .object(let po) = p, po["type"]?.string == "text" else { return nil }
                        return po["text"]?.string ?? ""
                    }.joined()
                    m["content"] = .string(joined)
                    msgs[i] = .object(m)
                }
                payload["messages"] = .array(msgs)
            }
            let (status2, body2) = try await postJSON("\(base)/chat/completions", payload: payload,
                                                      headers: headers, timeout: timeout)
            guard status2 == 200 else { throw WorkflowConnectorError.api(status: status2, prefix: "对话请求失败") }
            let content = Self.openAIContent(body2)
            var note = "\n\n[⚠️ 当前模型不支持多模态，图片未参与分析。建议切换到视觉模型（如 qwen2.5-vl）后重试。]"
            if droppedImages > 0 { note += "\n\n[⚠️ \(droppedImages) 张图片过大已丢弃，未参与分析。]" }
            return content + note
        }
        guard status == 200 else { throw WorkflowConnectorError.api(status: status, prefix: "对话请求失败") }
        var note = ""
        if droppedImages > 0 { note = "\n\n[⚠️ \(droppedImages) 张图片过大已丢弃，未参与分析。]" }
        return Self.openAIContent(body) + note
    }

    /// choices[0].message.content；解析失败 → 原文。
    private static func openAIContent(_ body: Data) -> String {
        if let v = NativeJSONWriter.loads(body), case .object(let o) = v,
           case .array(let choices) = o["choices"], let first = choices.first,
           case .object(let c) = first, case .object(let msg) = c["message"] {
            return msg["content"]?.string ?? ""
        }
        return String(decoding: body, as: UTF8.self)
    }

    // MARK: - unload_model（connector.py L432-447：keep_alive:0 空消息，失败静默 False）

    @discardableResult
    public func unloadModel(_ model: String) async -> Bool {
        switch backend {
        case "openai_compatible":
            return true   // openai_compat.unload_model：无状态后端，恒 True no-op
        case "model_package":
            return false  // 偏差①：MP 驱动未接管
        default:
            let base = (config()["ollama_base_url"]?.string ?? "http://localhost:11434")
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
            let payload: [String: JSONValue] = [
                "model": .string(model), "messages": .array([]),
                "stream": .bool(false), "keep_alive": .int(0),
            ]
            do {
                let (status, _) = try await postJSON("\(base)/api/chat", payload: payload,
                                                     headers: [:], timeout: 15)
                return status == 200
            } catch {
                return false
            }
        }
    }

    // MARK: - HTTP 基础（URLSession；超时即 timeoutInterval——偏差③）

    private func postJSON(_ url: String, payload: [String: JSONValue],
                          headers: [String: String], timeout: TimeInterval) async throws -> (Int, Data) {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.timeoutInterval = timeout
        req.httpBody = try JSONSerialization.data(withJSONObject: payload.mapValues { $0.anyValue })
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch let e as URLError where e.code == .timedOut {
            throw WorkflowConnectorError.timeout
        } catch {
            throw WorkflowConnectorError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw WorkflowConnectorError.network("无效响应")
        }
        return (http.statusCode, data)
    }

    // MARK: - _parse_image（connector.py L382-393 逐行为）

    /// data: URI 取逗号后段；存在的文件读字节转 base64；>50 字符视为已编码 base64
    /// （>8MB 丢弃返回 nil）；其余 nil。
    static func parseImage(_ src: String) -> String? {
        if src.hasPrefix("data:") {
            guard let comma = src.firstIndex(of: ",") else { return "" }
            return String(src[src.index(after: comma)...])
        }
        if FileManager.default.fileExists(atPath: src),
           let data = try? Data(contentsOf: URL(fileURLWithPath: src)) {
            return data.base64EncodedString()
        }
        if src.count > 50 {
            if src.count > 8_000_000 { return nil }
            return src
        }
        return nil
    }

    // MARK: - model_options（infer_options.py L148-188 + L323-387 逐行为）

    /// 该模型应注入的推理参数（已按后端映射）。空 dict = 完全不注入。
    static func modelOptions(model: String, backend: String, config: [String: JSONValue]) -> [String: JSONValue] {
        let raw = rawModelOptions(model: model, config: config)
        if raw.isEmpty { return [:] }
        let mapping: [String: String?] = backend == "ollama" ? paramMapOllama : paramMapOpenAI
        var out: [String: JSONValue] = [:]
        for (canon, val) in raw {
            guard let target = mapping[canon] ?? nil else { continue }   // 后端不支持 → 静默丢弃
            guard let coerced = coerce(canon: canon, value: val) else { continue }
            out[target] = coerced
        }
        if out.isEmpty { return [:] }
        // Ollama 参数必须包在 options 里；OpenAI 兼容端是顶层字段
        return backend == "ollama" ? ["options": .object(out)] : out
    }

    static let paramMapOllama: [String: String?] = [
        "num_ctx": "num_ctx", "temperature": "temperature", "top_p": "top_p", "top_k": "top_k",
        "repeat_penalty": "repeat_penalty", "num_predict": "num_predict", "seed": "seed", "stop": "stop",
    ]

    static let paramMapOpenAI: [String: String?] = [
        "num_ctx": nil, "temperature": "temperature", "top_p": "top_p", "top_k": nil,
        "repeat_penalty": "frequency_penalty", "num_predict": "max_tokens", "seed": "seed", "stop": "stop",
    ]

    /// _raw_model_options：精确命中 → 查询名去 tag → 配置键去 tag（三级）。
    /// ⚠️ 第三级 Python 按 dict 插入序遍历先配先中；JSONValue 无序 → 字典序（确定性兜底，
    ///    仅多键同 base 时命中序可能不同——配置面罕见，记为已知微差）。
    static func rawModelOptions(model: String, config: [String: JSONValue]) -> [String: JSONValue] {
        guard case .object(let mo) = config["model_options"], !mo.isEmpty else { return [:] }
        let name = model.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return [:] }
        if case .object(let hit) = mo[name] { return hit }
        let base = stripTag(name)
        if case .object(let hit) = mo[base] { return hit }
        for k in mo.keys.sorted() {
            if stripTag(k) == base, case .object(let v) = mo[k] { return v }
        }
        return [:]
    }

    /// _strip_tag：`qwen3.8:latest` → `qwen3.8`。
    static func stripTag(_ name: String) -> String {
        name.split(separator: ":", maxSplits: 1).first.map(String.init) ?? name
    }

    /// _coerce：按参数类型收窄；非法 → nil（调用方丢弃）。
    static func coerce(canon: String, value: JSONValue) -> JSONValue? {
        if canon == "stop" {
            if case .string(let s) = value { return s.isEmpty ? nil : .array([.string(s)]) }
            if case .array(let arr) = value, !arr.isEmpty,
               arr.allSatisfy({ $0.string != nil }) { return .array(arr) }
            return nil
        }
        if canon == "seed" {
            if case .bool = value { return nil }
            switch value {
            case .int(let i): return .int(i)
            case .double(let d) where d.isFinite: return .int(Int64(d))
            case .string(let s):
                guard let i = Int64(s.trimmingCharacters(in: .whitespaces)) else { return nil }
                return .int(i)
            default: return nil
            }
        }
        if ["num_ctx", "top_k", "num_predict"].contains(canon) {
            guard let f = PySem.toFloat(value) else { return nil }
            let iv = Int64(f)
            let range: ClosedRange<Int64>
            switch canon {
            case "num_ctx": range = 256...1_048_576
            case "top_k": range = 1...1000
            default: range = -2...1_048_576   // num_predict
            }
            guard range.contains(iv) else { return nil }
            return .int(iv)
        }
        // 浮点参数（temperature / top_p / repeat_penalty）
        guard let f = PySem.toFloat(value) else { return nil }
        let range: ClosedRange<Double>
        switch canon {
        case "temperature": range = 0.0...2.0
        case "top_p": range = 0.0...1.0
        default: range = 0.0...3.0   // repeat_penalty
        }
        guard range.contains(f) else { return nil }
        return .double(f)
    }
}
