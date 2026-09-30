//
//  NativeOpenAIChatConnectorTests.swift
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

//  逐条锚定（⛔ 行为规格源 subagent/sidecar/ollama/openai_compat.py，语义以源码为准）：
//    · SSE data: 行解析（L312-357：非 data 行/坏 JSON 跳过、[DONE] 终止、
//      空 choices 跳过、usage 在 choices 检查之前、空 usage 假值跳过、后到覆盖）
//    · counts 映射（L323-326：prompt_tokens→prompt_eval_count、
//      completion_tokens→eval_count；缺 usage → 0）
//    · thinking 双字段（L333-335：reasoning_content 假值回落 reasoning）
//    · 工具调用分块拼装（L339-372：index 归槽、id/name 覆盖、arguments 追加、
//      finish_reason==tool_calls 整体产出、流末残留产出、id 空兜底 call_{idx}）
//    · 400+tools 降级（L384-387 + L358-360：detail 含 tool/function →
//      stream_error 逐字文案；无 tools 或关键词不命中 → 抛错）
//    · 400/500+带图剥图重试（L269-310：重发 stream:false 保留 stream_options/tools、
//      content 数组拍平、多模态注记 + done(0,0)；重试失败 _raise_http 原文截 300）
//    · 图片合入（L135-179：image_url 块入最后一条 user 消息；data URI/base64 解析）
//    · model_options 映射（infer_options 复用：repeat_penalty→frequency_penalty、
//      num_predict→max_tokens、num_ctx/top_k 丢弃；未配置键集逐字节不变）
//    · _raise_stream_http/_raise_http（L374-400：401/403 服务拒绝访问文案、
//      其余 对话请求失败（HTTP N）、detail 截 300）
//    · _base 未配置逐字文案（L75-79）；guard 拒绝穿透（L81-85）
//    · 超时 → stream_error 逐字文案（L361-362）
//    · gen() 工具能力降级（app.py L1259-1264：supports_tools=false → 降级系统消息
//      + toolsSpec 置空）与 NativeSidecarClient 分流（openai_compatible→原生、
//      model_package→原生 MP（P3-W3a）、ollama→原生不扰动）
//
//  全程不触网：传输层注入脚本化 FakeTransport（ollamaTagsFetcher 先例），
//  请求逐条录证供字节级断言。
//

import XCTest
@testable import VetarAINative

// MARK: - 夹具：脚本化假传输（绝不触网；请求逐条录证）

private final class FakeTransport: NativeOpenAITransport, @unchecked Sendable {
    enum Step {
        case stream(Int, [String])                    // streamLines 正常返回
        case streamThrow(Error)                       // streamLines 调用即抛（连接级）
        case streamLinesThenThrow(Int, [String], Error)   // 流中途抛（如读超时）
        case post(Int, String)                        // postJSON 返回（状态码, 响应体）
    }
    struct Recorded {
        var url = ""
        var method = ""
        var authorization: String?
        var contentType: String?
        var timeout = 0.0
        var body: [String: JSONValue]?
    }
    private var steps: [Step]
    private(set) var recorded: [Recorded] = []
    init(_ steps: [Step]) { self.steps = steps }

    private func record(_ req: URLRequest) {
        var body: [String: JSONValue]?
        if let data = req.httpBody, let v = NativeJSONWriter.loads(data),
           case .object(let o) = v {
            body = o
        }
        recorded.append(Recorded(
            url: req.url?.absoluteString ?? "",
            method: req.httpMethod ?? "",
            authorization: req.value(forHTTPHeaderField: "Authorization"),
            contentType: req.value(forHTTPHeaderField: "Content-Type"),
            timeout: req.timeoutInterval,
            body: body))
    }

    func streamLines(_ req: URLRequest) async throws
        -> (status: Int, lines: AsyncThrowingStream<String, Error>) {
        record(req)
        guard !steps.isEmpty else { throw URLError(.badURL) }
        let step = steps.removeFirst()
        switch step {
        case .stream(let status, let lines):
            return (status, AsyncThrowingStream { cont in
                for l in lines { cont.yield(l) }
                cont.finish()
            })
        case .streamLinesThenThrow(let status, let lines, let err):
            return (status, AsyncThrowingStream { cont in
                for l in lines { cont.yield(l) }
                cont.finish(throwing: err)
            })
        case .streamThrow(let err):
            throw err
        case .post:
            XCTFail("步骤类型错配：期望 stream，实为 post")
            throw URLError(.badURL)
        }
    }

    func postJSON(_ req: URLRequest) async throws -> (status: Int, data: Data) {
        record(req)
        guard !steps.isEmpty else { throw URLError(.badURL) }
        let step = steps.removeFirst()
        guard case .post(let status, let body) = step else {
            XCTFail("步骤类型错配：期望 post，实为 stream")
            throw URLError(.badURL)
        }
        return (status, Data(body.utf8))
    }
}

// MARK: - 夹具：录证连接器（gen()/分流级测试注入）

private final class RecordingConn: NativeChatConnector, @unchecked Sendable {
    private(set) var calls = 0
    private(set) var lastTools: [JSONValue]?
    private(set) var lastMessages: [[String: JSONValue]] = []
    var reply = "好的"

    func chatStream(model: String, messages: [[String: JSONValue]],
                    tools: [JSONValue]?, images: [String]?)
        -> AsyncThrowingStream<NativeChatStreamEvent, Error> {
        calls += 1
        lastTools = tools
        lastMessages = messages
        let text = reply
        return AsyncThrowingStream { cont in
            cont.yield(.contentDelta(text))
            cont.yield(.done(promptEvalCount: 10, evalCount: 5))
            cont.finish()
        }
    }

    func chat(model: String, messages: [[String: JSONValue]]) async throws -> String { "" }
}

// MARK: - 夹具：HTTP 侧车探针（分流断言；协议面同 P3W1aReadinessTests 先例）

// MARK: - 测试本体

final class NativeOpenAIChatConnectorTests: XCTestCase {

    /// 基础配置：本地地址（guard 私网放行）+ 测试密钥。
    private let baseCfg: [String: JSONValue] = [
        "inference_backend": .string("openai_compatible"),
        "inference_base_url": .string("http://127.0.0.1:9/v1"),
        "inference_api_key": .string("sk-test"),
    ]

    private func makeConnector(cfg: [String: JSONValue], transport: FakeTransport,
                               guardCfg: [String: JSONValue]? = nil) -> NativeOpenAIChatConnector {
        let g = NativeNetworkGuard(configProvider: { guardCfg ?? cfg })
        return NativeOpenAIChatConnector(configProvider: { cfg }, guard: g, transport: transport)
    }

    private func collect(_ stream: AsyncThrowingStream<NativeChatStreamEvent, Error>)
        async throws -> [NativeChatStreamEvent] {
        var out: [NativeChatStreamEvent] = []
        for try await ev in stream { out.append(ev) }
        return out
    }

    private let userHi: [[String: JSONValue]] = [[
        "role": .string("user"), "content": .string("hi"),
    ]]

    private let multimodalNote = "\n\n[⚠️ 当前模型不支持多模态，图片未参与分析。"
        + "建议切换到视觉模型（如 qwen2.5-vl）后重试。]"

    // ══ ① SSE 解析 + counts 映射 + 请求形状（字节级）══

    func testStreamContentUsageDoneAndRequestShape() async throws {
        let t = FakeTransport([.stream(200, [
            #"data: {"choices":[{"delta":{"content":"你"}}]}"#,
            #"data: {"choices":[{"delta":{"content":"好"}}]}"#,
            #"data: {"choices":[],"usage":{"prompt_tokens":123,"completion_tokens":45}}"#,
            #"data: {"choices":[{"delta":{"content":"！"},"finish_reason":"stop"}]}"#,
            "data: [DONE]",
        ])])
        let conn = makeConnector(cfg: baseCfg, transport: t)
        let events = try await collect(conn.chatStream(
            model: "m", messages: userHi, tools: nil, images: nil))
        XCTAssertEqual(events, [
            .contentDelta("你"), .contentDelta("好"), .contentDelta("！"),
            .done(promptEvalCount: 123, evalCount: 45),
        ], "content 增量直通 + usage→counts 映射（choices 空也不漏 usage）")

        // 请求形状（字节级键集断言）
        XCTAssertEqual(t.recorded.count, 1)
        let rec = t.recorded[0]
        XCTAssertEqual(rec.url, "http://127.0.0.1:9/v1/chat/completions")
        XCTAssertEqual(rec.method, "POST")
        XCTAssertEqual(rec.authorization, "Bearer sk-test", "Bearer 来自 inference_api_key")
        XCTAssertEqual(rec.contentType, "application/json")
        XCTAssertEqual(rec.timeout, 1800.0, "timeout_stream_reading 缺省 1800")
        let body = try XCTUnwrap(rec.body)
        XCTAssertEqual(Set(body.keys), ["model", "messages", "stream", "stream_options"],
                       "未配置 model_options → 键集逐字节不变（L253-254）")
        XCTAssertEqual(body["model"], .string("m"))
        XCTAssertEqual(body["stream"], .bool(true))
        XCTAssertEqual(body["stream_options"], .object(["include_usage": .bool(true)]))
        XCTAssertNil(body["tools"], "tools=nil 不出现在 payload")
    }

    func testDoneCountsAbsentUsage() async throws {
        let t = FakeTransport([.stream(200, [
            #"data: {"choices":[{"delta":{"content":"x"}}]}"#,
            "data: [DONE]",
        ])])
        let conn = makeConnector(cfg: baseCfg, transport: t)
        let events = try await collect(conn.chatStream(
            model: "m", messages: userHi, tools: nil, images: nil))
        XCTAssertEqual(events, [.contentDelta("x"), .done(promptEvalCount: 0, evalCount: 0)],
                       "缺 usage → counts 全 0（L266 初始值）")
    }

    func testUsageEmptyIgnoredAndOverwritten() async throws {
        let t = FakeTransport([.stream(200, [
            #"data: {"usage":{"prompt_tokens":10,"completion_tokens":2},"choices":[]}"#,
            #"data: {"usage":{},"choices":[{"delta":{"content":"x"}}]}"#,
            #"data: {"usage":{"prompt_tokens":99,"completion_tokens":7},"choices":[]}"#,
            "data: [DONE]",
        ])])
        let conn = makeConnector(cfg: baseCfg, transport: t)
        let events = try await collect(conn.chatStream(
            model: "m", messages: userHi, tools: nil, images: nil))
        XCTAssertEqual(events, [.contentDelta("x"), .done(promptEvalCount: 99, evalCount: 7)],
                       "空 usage 假值跳过；后到 usage 覆盖先到（L323-326）")
    }

    // ══ ② thinking 双字段 ══

    func testThinkingReasoningContentFallback() async throws {
        let t = FakeTransport([.stream(200, [
            #"data: {"choices":[{"delta":{"reasoning_content":"想"}}]}"#,
            #"data: {"choices":[{"delta":{"reasoning_content":"","reasoning":"退路"}}]}"#,
            #"data: {"choices":[{"delta":{"reasoning":"直出"}}]}"#,
            #"data: {"choices":[{"delta":{"content":""}}]}"#,
            "data: [DONE]",
        ])])
        let conn = makeConnector(cfg: baseCfg, transport: t)
        let events = try await collect(conn.chatStream(
            model: "m", messages: userHi, tools: nil, images: nil))
        XCTAssertEqual(events, [
            .thinkingDelta("想"), .thinkingDelta("退路"), .thinkingDelta("直出"),
            .done(promptEvalCount: 0, evalCount: 0),
        ], "reasoning_content 假值回落 reasoning；空 content 跳过（L333-338）")
    }

    // ══ ③ 工具调用分块拼装 ══

    func testToolCallReassemblyAcrossChunks() async throws {
        let t = FakeTransport([.stream(200, [
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a","function":{"name":"web_search","arguments":"{\"que"}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":1,"function":{"name":"read_file","arguments":"{\"path\":"}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"ry\":\"x\"}"}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":1,"function":{"arguments":"\"/tmp\"}"}}],"finish_reason":"tool_calls"}}]}"#,
            #"data: {"usage":{"prompt_tokens":5,"completion_tokens":3},"choices":[]}"#,
            "data: [DONE]",
        ])])
        let conn = makeConnector(cfg: baseCfg, transport: t)
        let events = try await collect(conn.chatStream(
            model: "m", messages: userHi, tools: nil, images: nil))
        XCTAssertEqual(events.count, 2)
        guard case .toolCalls(let tcs) = events[0] else {
            return XCTFail("首事件应为 tool_calls 整体产出: \(events)")
        }
        XCTAssertEqual(tcs.count, 2, "两个 index 槽按升序产出")
        XCTAssertEqual(tcs[0]["id"], .string("call_a"), "id 首块到达后即保留")
        XCTAssertEqual(tcs[0]["function"]?.object?["name"], .string("web_search"))
        XCTAssertEqual(tcs[0]["function"]?.object?["arguments"],
                       .string(#"{"query":"x"}"#), "arguments 跨块追加")
        XCTAssertEqual(tcs[1]["id"], .string("call_1"), "id 空兜底 call_{idx}（L370）")
        XCTAssertEqual(tcs[1]["function"]?.object?["name"], .string("read_file"))
        XCTAssertEqual(tcs[1]["function"]?.object?["arguments"], .string(#"{"path":"/tmp"}"#))
        XCTAssertEqual(events[1], .done(promptEvalCount: 5, evalCount: 3))
    }

    func testToolCallResidualFlushAtStreamEnd() async throws {
        // 无 finish_reason==tool_calls：[DONE]/流末残留整体产出（L354-356）
        let t = FakeTransport([.stream(200, [
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_x","function":{"name":"list_dir","arguments":"{}"}}]}}]}"#,
            "data: [DONE]",
        ])])
        let conn = makeConnector(cfg: baseCfg, transport: t)
        let events = try await collect(conn.chatStream(
            model: "m", messages: userHi, tools: nil, images: nil))
        XCTAssertEqual(events.count, 2)
        guard case .toolCalls(let tcs) = events[0] else {
            return XCTFail("残留工具调用应在 done 前产出: \(events)")
        }
        XCTAssertEqual(tcs.count, 1)
        XCTAssertEqual(tcs[0]["function"]?.object?["name"], .string("list_dir"))
        XCTAssertEqual(events[1], .done(promptEvalCount: 0, evalCount: 0))
    }

    // ══ ④ 畸形行跳过 ══

    func testMalformedLinesSkipped() async throws {
        let t = FakeTransport([.stream(200, [
            "",                                     // 空行
            "  ",                                   // 空白行
            ": comment",                            // SSE 注释行
            "event: message",                       // 非 data 行
            "data: {bad json",                      // 坏 JSON（JSONDecodeError → 跳过）
            #"data: {"choices":[]}"#,               // 空 choices
            #"data: {"choices":[{"delta":{}}]}"#,   // 空 delta
            #"data: {"choices":[{"delta":{"content":"正"}}]}"#,
            "data: [DONE]",
            #"data: {"choices":[{"delta":{"content":"晚了"}}]}"#,   // DONE 后不再消费
        ])])
        let conn = makeConnector(cfg: baseCfg, transport: t)
        let events = try await collect(conn.chatStream(
            model: "m", messages: userHi, tools: nil, images: nil))
        XCTAssertEqual(events, [.contentDelta("正"), .done(promptEvalCount: 0, evalCount: 0)],
                       "非 data 行/坏 JSON/空 choices 跳过；[DONE] 终止（L313-318）")
    }

    // ══ ⑤ 400+tools 降级 ══

    func testTools400DowngradeEvent() async throws {
        let t = FakeTransport([.stream(400, [
            #"{"error":{"message":"This model does not support tools"}}"#,
        ])])
        let conn = makeConnector(cfg: baseCfg, transport: t)
        let events = try await collect(conn.chatStream(
            model: "m", messages: userHi,
            tools: [.object(["type": .string("function")])], images: nil))
        XCTAssertEqual(events, [.streamError(
            "当前推理后端不支持工具调用（This model does not support tools）。"
            + "可在设置面板关闭工具支持，或换用支持工具的后端/模型。")],
            "400+tools+tool 关键词 → 降级 stream_error 逐字文案（L358-360）")
        // payload 确实带了 tools（降级发生在服务端拒绝后）
        XCTAssertNotNil(t.recorded[0].body?["tools"])
    }

    func testTools400DowngradeFunctionKeyword() async throws {
        let t = FakeTransport([.stream(400, [
            #"{"error":{"message":"Function calling is not enabled"}}"#,
        ])])
        let conn = makeConnector(cfg: baseCfg, transport: t)
        let events = try await collect(conn.chatStream(
            model: "m", messages: userHi,
            tools: [.object(["type": .string("function")])], images: nil))
        guard case .streamError(let msg) = events.first, events.count == 1 else {
            return XCTFail("function 关键词同样命中降级: \(events)")
        }
        XCTAssertTrue(msg.hasPrefix("当前推理后端不支持工具调用（Function calling is not enabled）"))
    }

    func testTools400UnrelatedDetailThrows() async throws {
        let t = FakeTransport([.stream(400, [
            #"{"error":{"message":"model not found"}}"#,
        ])])
        let conn = makeConnector(cfg: baseCfg, transport: t)
        do {
            _ = try await collect(conn.chatStream(
                model: "m", messages: userHi,
                tools: [.object(["type": .string("function")])], images: nil))
            XCTFail("关键词不命中应抛业务错误")
        } catch let e as NativeChatConnectorError {
            XCTAssertEqual(e, .openAI(status: 400,
                                      message: "对话请求失败（HTTP 400）",
                                      detail: "model not found"),
                           "OllamaAPIError 逐字（detail 取 error.message，L379-381）")
        }
    }

    func test400WithoutToolsParamThrows() async throws {
        // detail 含 tool 但未传 tools → 不降级（tools_requested=False，L385）
        let t = FakeTransport([.stream(400, [
            #"{"error":{"message":"tools not supported"}}"#,
        ])])
        let conn = makeConnector(cfg: baseCfg, transport: t)
        do {
            _ = try await collect(conn.chatStream(
                model: "m", messages: userHi, tools: nil, images: nil))
            XCTFail("未传 tools 不触发降级")
        } catch let e as NativeChatConnectorError {
            XCTAssertEqual(e, .openAI(status: 400,
                                      message: "对话请求失败（HTTP 400）",
                                      detail: "tools not supported"))
        }
    }

    // ══ ⑥ 401/403 与 detail 截断 ══

    func test401GuardStyleMessage() async throws {
        let longMsg = String(repeating: "错", count: 400)
        let t = FakeTransport([.stream(401, [
            #"{"error":{"message":""# + longMsg + #""}}"#,
        ])])
        let conn = makeConnector(cfg: baseCfg, transport: t)
        do {
            _ = try await collect(conn.chatStream(model: "m", messages: userHi,
                                                  tools: nil, images: nil))
            XCTFail("401 应抛服务拒绝访问")
        } catch let e as NativeChatConnectorError {
            guard case .openAI(let status, let message, let detail) = e else {
                return XCTFail("错误形态不符: \(e)")
            }
            XCTAssertEqual(status, 401)
            XCTAssertEqual(detail.unicodeScalars.count, 300, "detail 截 300 码点（L392）")
            XCTAssertEqual(message,
                           "对话请求失败：服务拒绝访问（HTTP 401）。"
                           + String(repeating: "错", count: 300))
        }
    }

    func test403PlainTextBody() async throws {
        let t = FakeTransport([.stream(403, ["Forbidden by gateway"])])
        let conn = makeConnector(cfg: baseCfg, transport: t)
        do {
            _ = try await collect(conn.chatStream(model: "m", messages: userHi,
                                                  tools: nil, images: nil))
            XCTFail("403 应抛服务拒绝访问")
        } catch let e as NativeChatConnectorError {
            guard case .openAI(let status, let message, _) = e else {
                return XCTFail("错误形态不符: \(e)")
            }
            XCTAssertEqual(status, 403)
            XCTAssertEqual(message, "对话请求失败：服务拒绝访问（HTTP 403）。Forbidden by gateway",
                           "非 JSON 错误体 detail=原文；组成文案后 .strip() 等价（L389-391）")
        }
    }

    // ══ ⑦ 图片：成功路径合入 + 剥图重试 ══

    func testImageMergeSuccessPath() async throws {
        let b64 = String(repeating: "a", count: 60)   // >50 字符视为已编码 base64
        let t = FakeTransport([.stream(200, [
            #"data: {"choices":[{"delta":{"content":"看见了"}}]}"#,
            "data: [DONE]",
        ])])
        let conn = makeConnector(cfg: baseCfg, transport: t)
        let messages: [[String: JSONValue]] = [
            ["role": .string("system"), "content": .string("s")],
            ["role": .string("user"), "content": .string("第一张")],
            ["role": .string("assistant"), "content": .string("好")],
            ["role": .string("user"), "content": .string("看图")],
        ]
        let events = try await collect(conn.chatStream(
            model: "m", messages: messages, tools: nil,
            images: ["data:image/png;base64,QUJD", b64]))
        XCTAssertEqual(events, [.contentDelta("看见了"),
                                .done(promptEvalCount: 0, evalCount: 0)])
        // 合入【最后一条 user 消息】（_merge_images_into_messages L166-179）
        let body = try XCTUnwrap(t.recorded[0].body)
        let msgs = try XCTUnwrap(body["messages"]?.array)
        XCTAssertEqual(msgs.count, 4)
        XCTAssertEqual(msgs[0].object?["content"], .string("s"), "system 不动")
        XCTAssertEqual(msgs[1].object?["content"], .string("第一张"), "早先 user 消息不动")
        XCTAssertEqual(msgs[2].object?["content"], .string("好"), "assistant 不动")
        let parts = try XCTUnwrap(msgs[3].object?["content"]?.array)
        XCTAssertEqual(parts.count, 3, "text 块 + 两个 image_url 块")
        XCTAssertEqual(parts[0], .object(["type": .string("text"), "text": .string("看图")]))
        XCTAssertEqual(parts[1], .object([
            "type": .string("image_url"),
            "image_url": .object(["url": .string("data:image/png;base64,QUJD")]),
        ]), "data URI 取逗号后段")
        XCTAssertEqual(parts[2], .object([
            "type": .string("image_url"),
            "image_url": .object(["url": .string("data:image/png;base64," + b64)]),
        ]))
    }

    func testImageStripRetryOn400() async throws {
        let b64 = String(repeating: "b", count: 60)
        let t = FakeTransport([
            .stream(400, ["Bad Request: images not supported"]),
            .post(200, #"{"choices":[{"message":{"content":"纯文本答复"}}]}"#),
        ])
        let conn = makeConnector(cfg: baseCfg, transport: t)
        let events = try await collect(conn.chatStream(
            model: "m", messages: userHi,
            tools: [.object(["type": .string("function")])], images: [b64]))
        XCTAssertEqual(events, [
            .contentDelta("纯文本答复" + multimodalNote),
            .done(promptEvalCount: 0, evalCount: 0),
        ], "400+带图 → 剥图重试 + 多模态注记 + done(0,0)（L276-310）")
        // 两次请求录证
        XCTAssertEqual(t.recorded.count, 2)
        let first = try XCTUnwrap(t.recorded[0].body)
        XCTAssertEqual(first["stream"], .bool(true))
        XCTAssertNotNil(first["messages"]?.array?.first?.object?["content"]?.array,
                        "首发带 content 数组（图已合入）")
        let second = try XCTUnwrap(t.recorded[1].body)
        XCTAssertEqual(second["stream"], .bool(false), "重发必须 stream:false（checkpoint-042）")
        XCTAssertEqual(second["stream_options"], .object(["include_usage": .bool(true)]),
                       "{**payload, stream:False}：stream_options 原样保留")
        XCTAssertNotNil(second["tools"], "tools 原样保留")
        XCTAssertEqual(second["messages"]?.array?.first?.object?["content"], .string("hi"),
                       "content 数组拍平为纯文本（L277-281）")
        XCTAssertEqual(t.recorded[1].url, "http://127.0.0.1:9/v1/chat/completions")
        XCTAssertEqual(t.recorded[1].authorization, "Bearer sk-test")
    }

    func testImageStripRetryOn500MultilineSSE() async throws {
        let b64 = String(repeating: "c", count: 60)
        let t = FakeTransport([
            .stream(500, ["Internal Server Error"]),
            .post(200, "data: {\"choices\":[{\"delta\":{\"content\":\"拼\"}}]}\n"
                  + "data: {\"choices\":[{\"delta\":{\"content\":\"接\"}}]}\n"
                  + "data: [DONE]\n"),
        ])
        let conn = makeConnector(cfg: baseCfg, transport: t)
        let events = try await collect(conn.chatStream(
            model: "m", messages: userHi, tools: nil, images: [b64]))
        XCTAssertEqual(events, [
            .contentDelta("拼接" + multimodalNote),
            .done(promptEvalCount: 0, evalCount: 0),
        ], "500 同样剥图重试（checkpoint-041）；多行 SSE 防御逐行拼接（L294-305）")
    }

    func testImageStripRetryFailureRaises() async throws {
        let b64 = String(repeating: "d", count: 60)
        let t = FakeTransport([
            .stream(400, ["Bad Request"]),
            .post(500, #"{"error":{"message":"still bad"}}"#),
        ])
        let conn = makeConnector(cfg: baseCfg, transport: t)
        do {
            _ = try await collect(conn.chatStream(model: "m", messages: userHi,
                                                  tools: nil, images: [b64]))
            XCTFail("重试失败应抛错")
        } catch let e as NativeChatConnectorError {
            guard case .openAI(let status, let message, let detail) = e else {
                return XCTFail("错误形态不符: \(e)")
            }
            XCTAssertEqual(status, 500)
            XCTAssertEqual(message, "对话请求失败（HTTP 500）")
            XCTAssertEqual(detail, #"{"error":{"message":"still bad"}}"#,
                           "_raise_http 的 detail=原文截 300（不做 error 键提取，L396）")
        }
    }

    func testImageStripRetry401RaisesGuardStyle() async throws {
        let b64 = String(repeating: "e", count: 60)
        let t = FakeTransport([
            .stream(400, ["Bad Request"]),
            .post(401, "unauthorized"),
        ])
        let conn = makeConnector(cfg: baseCfg, transport: t)
        do {
            _ = try await collect(conn.chatStream(model: "m", messages: userHi,
                                                  tools: nil, images: [b64]))
            XCTFail("重试 401 应抛服务拒绝访问")
        } catch let e as NativeChatConnectorError {
            guard case .openAI(let status, let message, _) = e else {
                return XCTFail("错误形态不符: \(e)")
            }
            XCTAssertEqual(status, 401)
            XCTAssertEqual(message, "对话请求失败：服务拒绝访问（HTTP 401）。unauthorized")
        }
    }

    // ══ ⑧ model_options 映射（字节级）══

    func testOptionsMappingByteLevel() async throws {
        var cfg = baseCfg
        cfg["model_options"] = .object([
            "m": .object([
                "num_ctx": .int(8192),           // → 丢弃
                "temperature": .double(0.5),     // → temperature
                "top_p": .double(0.9),           // → top_p
                "top_k": .int(40),               // → 丢弃
                "repeat_penalty": .double(1.1),  // → frequency_penalty
                "num_predict": .int(256),        // → max_tokens
                "seed": .int(7),                 // → seed
                "stop": .string("停"),            // → stop（字符串包数组）
            ]),
        ])
        let t = FakeTransport([.stream(200, ["data: [DONE]"])])
        let conn = makeConnector(cfg: cfg, transport: t)
        _ = try await collect(conn.chatStream(model: "m", messages: userHi,
                                              tools: nil, images: nil))
        let body = try XCTUnwrap(t.recorded[0].body)
        XCTAssertEqual(Set(body.keys),
                       ["model", "messages", "stream", "stream_options",
                        "temperature", "top_p", "frequency_penalty", "max_tokens",
                        "seed", "stop"],
                       "映射后顶层字段键集（num_ctx/top_k 静默丢弃）")
        XCTAssertNil(body["num_ctx"], "OpenAI 兼容端无此参数（_OPENAI_COMPAT_MAP）")
        XCTAssertNil(body["top_k"], "非 OpenAI 标准参数")
        XCTAssertEqual(body["temperature"], .double(0.5))
        XCTAssertEqual(body["top_p"], .double(0.9))
        XCTAssertEqual(body["frequency_penalty"], .double(1.1), "repeat_penalty 改名")
        XCTAssertEqual(body["max_tokens"], .int(256), "num_predict 改名")
        XCTAssertEqual(body["seed"], .int(7))
        XCTAssertEqual(body["stop"], .array([.string("停")]))
        XCTAssertNil(body["options"], "OpenAI 端参数是顶层字段，不包 options")
    }

    func testOptionsUnconfiguredNoInjection() async throws {
        var cfg = baseCfg
        cfg["model_options"] = .object([
            "other-model": .object(["temperature": .double(0.5)]),
        ])
        let t = FakeTransport([.stream(200, ["data: [DONE]"])])
        let conn = makeConnector(cfg: cfg, transport: t)
        _ = try await collect(conn.chatStream(model: "m", messages: userHi,
                                              tools: nil, images: nil))
        let body = try XCTUnwrap(t.recorded[0].body)
        XCTAssertEqual(Set(body.keys), ["model", "messages", "stream", "stream_options"],
                       "该模型未配置 → 完全不注入（键集逐字节不变，铁律）")
    }

    // ══ ⑨ 地址 / 守卫 / 超时 ══

    func testBaseURLMissing() async throws {
        let cfg: [String: JSONValue] = [
            "inference_backend": .string("openai_compatible"),
            "inference_base_url": .string(""),
        ]
        let t = FakeTransport([])
        let conn = makeConnector(cfg: cfg, transport: t)
        do {
            _ = try await collect(conn.chatStream(model: "m", messages: userHi,
                                                  tools: nil, images: nil))
            XCTFail("地址未配置应抛错")
        } catch let e as NativeChatConnectorError {
            XCTAssertEqual(e, .openAI(status: 400,
                                      message: "推理后端地址未配置（设置面板：推理后端 → 地址）",
                                      detail: ""),
                           "_base() 逐字文案（L77-78）")
        }
        XCTAssertTrue(t.recorded.isEmpty, "未发任何请求")
    }

    func testGuardRejected() async throws {
        let cfg: [String: JSONValue] = [
            "inference_backend": .string("openai_compatible"),
            "inference_base_url": .string("http://example.com/v1"),
        ]
        let guardCfg: [String: JSONValue] = [
            "network_switch": .string("on"),   // 全量代理模式 + 未配端口 → 拦截
            "proxy_http_port": .int(0),
        ]
        let t = FakeTransport([])
        let conn = makeConnector(cfg: cfg, transport: t, guardCfg: guardCfg)
        do {
            _ = try await collect(conn.chatStream(model: "m", messages: userHi,
                                                  tools: nil, images: nil))
            XCTFail("guard 拒绝应抛错")
        } catch let e as NativeNetworkGuardError {
            XCTAssertTrue(e.message.contains("example.com"),
                          "NetworkGuardError 穿透（_client guard 同语义）: \(e.message)")
        }
        XCTAssertTrue(t.recorded.isEmpty, "拦截在请求发出前")
    }

    func testTimeoutMapsStreamError() async throws {
        // 连接级超时（streamLines 调用即抛）
        let t1 = FakeTransport([.streamThrow(URLError(.timedOut))])
        let conn1 = makeConnector(cfg: baseCfg, transport: t1)
        let events1 = try await collect(conn1.chatStream(model: "m", messages: userHi,
                                                         tools: nil, images: nil))
        XCTAssertEqual(events1, [.streamError("模型响应超时，已停止。已完成部分见上方事件。")],
                       "httpx.TimeoutException 兜底逐字（L361-362）")
        // 流中途超时（已产出的增量保留，超时转 stream_error）
        let t2 = FakeTransport([.streamLinesThenThrow(200, [
            #"data: {"choices":[{"delta":{"content":"半"}}]}"#,
        ], URLError(.timedOut))])
        let conn2 = makeConnector(cfg: baseCfg, transport: t2)
        let events2 = try await collect(conn2.chatStream(model: "m", messages: userHi,
                                                         tools: nil, images: nil))
        XCTAssertEqual(events2, [
            .contentDelta("半"),
            .streamError("模型响应超时，已停止。已完成部分见上方事件。"),
        ], "流中途超时：已完成部分见上方事件")
    }

    func testStreamTimeoutConfigClamp() async throws {
        var cfg = baseCfg
        cfg["timeout_stream_reading"] = .double(5)        // 低于下限 → 钳 10
        let t = FakeTransport([.stream(200, ["data: [DONE]"])])
        let conn = makeConnector(cfg: cfg, transport: t)
        _ = try await collect(conn.chatStream(model: "m", messages: userHi,
                                              tools: nil, images: nil))
        XCTAssertEqual(t.recorded[0].timeout, 10.0,
                       "timeout_stream_reading 钳 10~7200（M11 口径：与 Ollama 连接器一致）")
        cfg["timeout_stream_reading"] = .double(100000)   // 高于上限 → 钳 7200
        let t2 = FakeTransport([.stream(200, ["data: [DONE]"])])
        let conn2 = makeConnector(cfg: cfg, transport: t2)
        _ = try await collect(conn2.chatStream(model: "m", messages: userHi,
                                               tools: nil, images: nil))
        XCTAssertEqual(t2.recorded[0].timeout, 7200.0)
    }

    // ══ ⑩ 非流式 chat（报错分析模型路径）══

    func testNonStreamChat() async throws {
        // 200 → choices[0].message.content
        let t = FakeTransport([.post(200, #"{"choices":[{"message":{"content":"诊断"}}]}"#)])
        let conn = makeConnector(cfg: baseCfg, transport: t)
        let text = try await conn.chat(model: "m", messages: userHi)
        XCTAssertEqual(text, "诊断")
        let body = try XCTUnwrap(t.recorded[0].body)
        XCTAssertEqual(Set(body.keys), ["model", "messages", "stream"],
                       "非流式无 stream_options（L188）")
        XCTAssertEqual(body["stream"], .bool(false))
        XCTAssertEqual(t.recorded[0].timeout, 60.0, "60s 双保险（调用方超时竞速同款）")

        // 非 200 → _raise_http
        let t2 = FakeTransport([.post(500, "server error")])
        let conn2 = makeConnector(cfg: baseCfg, transport: t2)
        do {
            _ = try await conn2.chat(model: "m", messages: userHi)
            XCTFail("非 200 应抛错")
        } catch let e as NativeChatConnectorError {
            XCTAssertEqual(e, .openAI(status: 500, message: "对话请求失败（HTTP 500）",
                                      detail: "server error"))
        }

        // 解析失败 → 原文（L241-242 except Exception 宽口径）
        let t3 = FakeTransport([.post(200, "plain text response")])
        let conn3 = makeConnector(cfg: baseCfg, transport: t3)
        let text3 = try await conn3.chat(model: "m", messages: userHi)
        XCTAssertEqual(text3, "plain text response")
    }

    // ══ ⑪ gen() 工具能力降级 + NativeSidecarClient 分流 ══

    private var base: URL!
    private var kernel: NativeKernel!

    override func setUpWithError() throws {
        try super.setUpWithError()
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3w2b_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        kernel = nil
        try? FileManager.default.removeItem(at: base)
        base = nil
        try super.tearDownWithError()
    }

    /// openai_compat_supports_tools=false → gen() 追加降级系统消息 + toolsSpec 置空
    /// （app.py L1259-1264）；NativeSidecarClient 把 openai_compatible 分流到原生连接器。
    func testGenLevelToolsGateAndNativeRouting() async throws {
        kernel = NativeKernel(dataRoot: base)
        _ = try kernel.config.reloadConfig(patch: [
            "inference_backend": .string("openai_compatible"),
            "openai_compat_supports_tools": .bool(false),
            "inference_base_url": .string("http://127.0.0.1:9/v1"),
            "ollama_base_url": .string("http://127.0.0.1:1"),   // contextLimit 探测快速失败
        ])
        let client = NativeSidecarClient(kernel: kernel)
        let rec = RecordingConn()
        client.openAIChatConnectorOverride = rec
        let req = ChatStreamRequest(
            agent_id: "", model: "m",
            messages: [ChatStreamMessage(role: "user", content: "你好")],
            project_id: "", session_id: "s1", sandbox_root: base.path)
        var names: [String] = []
        for try await ev in client.chatStream(req) { names.append(ev.event) }
        XCTAssertTrue(names.contains("done"), "原生链路事件流完整: \(names)")
        XCTAssertEqual(rec.calls, 1, "openai_compatible → 原生连接器（分流生效）")
        XCTAssertEqual(rec.lastTools ?? [.null], [],
                       "能力表 tools=false → toolsSpec 置空（app.py L1296）")
        let last = try XCTUnwrap(rec.lastMessages.last)
        XCTAssertEqual(last["role"]?.string, "system")
        XCTAssertEqual(last["content"]?.string,
                       "当前推理后端不支持工具调用，本轮仅直接对话，不可读写文件或搜索。",
                       "降级系统消息追加到 msgs 末尾（app.py L1262-1263）")
    }

    /// 分流矩阵：model_package 退化翻原生（P3-W3a——全走 MP，未安装包 openAI(400)
    /// 中文明细转 error 事件）；ollama 原生不扰动（连接拒绝走原生 loop 错误事件）。
    func testRoutingModelPackageGoesNativeAndOllamaUndisturbed() async throws {
        // model_package → 原生 MP（无已安装包 → ensure 失败转 error 事件）
        kernel = NativeKernel(dataRoot: base)
        _ = try kernel.config.reloadConfig(patch: [
            "inference_backend": .string("model_package"),
        ])
        let client = NativeSidecarClient(kernel: kernel)
        let rec = RecordingConn()
        client.openAIChatConnectorOverride = rec
        let req = ChatStreamRequest(
            agent_id: "", model: "m",
            messages: [ChatStreamMessage(role: "user", content: "你好")],
            project_id: "", session_id: "s1", sandbox_root: base.path)
        var events: [String] = []
        for try await ev in client.chatStream(req) { events.append(ev.event) }
        XCTAssertTrue(events.contains("error"),
                      "model_package 已原生（P3-W3a）：未安装包 400 转 error: \(events)")
        XCTAssertEqual(rec.calls, 0, "退化全走 MP，不触 openai 连接器")

        // ollama → 原生（127.0.0.1:1 连接拒绝 → 原生 loop 转 error 事件）
        _ = try kernel.config.reloadConfig(patch: [
            "inference_backend": .string("ollama"),
            "ollama_base_url": .string("http://127.0.0.1:1"),
        ])
        var events2: [String] = []
        for try await ev in client.chatStream(req) { events2.append(ev.event) }
        XCTAssertTrue(events2.contains("error"), "ollama 原生链路（连接拒绝转 error 事件）: \(events2)")
    }
}
