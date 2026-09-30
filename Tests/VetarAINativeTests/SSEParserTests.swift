//
//  SSEParserTests.swift
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

//  SSE 解析器边界测试：多事件 / 半行粘包 / 注释心跳行 / [DONE] 哨兵 /
//  坏 JSON / 缺 event 行 / 空 data / 多行 data / CRLF / flush 兜底 / UTF-8 切断。
//

import XCTest
@testable import VetarAINative

final class SSEParserTests: XCTestCase {

    // 1. 单个完整事件（侧车 _sse_format 实际输出形状）
    func testSingleEvent() {
        var p = SSEParser()
        let evs = p.push("event: token\ndata: {\"delta\":\"你\"}\n\n")
        XCTAssertEqual(evs.count, 1)
        XCTAssertEqual(evs[0].event, "token")
        XCTAssertEqual(evs[0].string("delta"), "你")
    }

    // 2. 一个分片内多个事件
    func testMultipleEventsInOneChunk() {
        var p = SSEParser()
        let evs = p.push("event: token\ndata: {\"delta\":\"a\"}\n\nevent: token\ndata: {\"delta\":\"b\"}\n\nevent: done\ndata: {\"content\":\"ab\"}\n\n")
        XCTAssertEqual(evs.map(\.event), ["token", "token", "done"])
        XCTAssertEqual(evs[2].string("content"), "ab")
    }

    // 3. 半行粘包：事件被任意切碎，分隔符未到前不得产出
    func testSplitAcrossChunks() {
        var p = SSEParser()
        XCTAssertTrue(p.push("event: tok").isEmpty)
        XCTAssertTrue(p.push("en\nda").isEmpty)
        XCTAssertTrue(p.push("ta: {\"delta\":\"x\"}\n").isEmpty)  // 只有一个 \n，块未闭合
        let evs = p.push("\n")                                     // 补齐 \n\n
        XCTAssertEqual(evs.count, 1)
        XCTAssertEqual(evs[0].event, "token")
        XCTAssertEqual(evs[0].string("delta"), "x")
    }

    // 4. 心跳注释行被忽略，且不影响相邻事件
    func testHeartbeatCommentIgnored() {
        var p = SSEParser()
        let evs = p.push(": ping\n\nevent: state\ndata: {\"step\":0,\"max\":200}\n\n: ping\n\n")
        XCTAssertEqual(evs.count, 1)
        XCTAssertEqual(evs[0].event, "state")
        XCTAssertEqual(evs[0].int("max"), 200)
    }

    // 5. 注释行夹在不完整事件中间也不产出事件
    func testCommentOnlyBlockYieldsNothing() {
        var p = SSEParser()
        XCTAssertTrue(p.push(": ping\n: ping\n\n").isEmpty)
    }

    // 6. data: 多行拼接（工具 args 可能含换行）
    func testMultiLineData() {
        var p = SSEParser()
        let raw = "event: tool_call\ndata: {\"id\":\"t1\",\ndata: \"name\":\"run\"}\n\n"
        let evs = p.push(raw)
        XCTAssertEqual(evs.count, 1)
        XCTAssertEqual(evs[0].string("id"), "t1")
        XCTAssertEqual(evs[0].string("name"), "run")
    }

    // 7. data: 后任意数量前导空格被剥离（TS-102 B16）
    func testDataLeadingSpacesStripped() {
        var p = SSEParser()
        let evs = p.push("event: token\ndata:    {\"delta\":\"y\"}\n\n")
        XCTAssertEqual(evs[0].string("delta"), "y")
    }

    // 8. 坏 JSON → raw 兜底，不抛异常
    func testBadJSONFallsBackToRaw() {
        var p = SSEParser()
        let evs = p.push("event: token\ndata: {not json}\n\n")
        XCTAssertEqual(evs.count, 1)
        XCTAssertEqual(evs[0].data["raw"] as? String, "{not json}")
    }

    // 9. 缺 event 行 → 默认 message
    func testMissingEventLineDefaultsToMessage() {
        var p = SSEParser()
        let evs = p.push("data: {\"delta\":\"z\"}\n\n")
        XCTAssertEqual(evs[0].event, "message")
    }

    // 10. 空 data → 空字典
    func testEmptyDataYieldsEmptyDict() {
        var p = SSEParser()
        let evs = p.push("event: ping\ndata:\n\n")
        XCTAssertEqual(evs[0].event, "ping")
        XCTAssertTrue(evs[0].data.isEmpty)
    }

    // 11. [DONE] 终止哨兵：安全解析 + 可识别
    func testDoneSentinel() {
        var p = SSEParser()
        let evs = p.push("data: [DONE]\n\n")
        XCTAssertEqual(evs.count, 1)
        XCTAssertTrue(evs[0].isDoneSentinel)
        XCTAssertEqual(evs[0].data["raw"] as? String, "[DONE]")
    }

    // 12. 非对象 JSON（数字/数组）→ value 兜底
    func testNonObjectJSONWrappedAsValue() {
        var p = SSEParser()
        let evs = p.push("event: metric\ndata: 42\n\n")
        XCTAssertEqual((evs[0].data["value"] as? NSNumber)?.intValue, 42)
    }

    // 13. CRLF 分隔符（代理改写场景）
    func testCRLFSeparators() {
        var p = SSEParser()
        let evs = p.push("event: token\r\ndata: {\"delta\":\"c\"}\r\n\r\nevent: done\r\ndata: {\"content\":\"c\"}\r\n\r\n")
        XCTAssertEqual(evs.map(\.event), ["token", "done"])
    }

    // 14. 混合 \n\n 与 \r\n\r\n：取靠后者消费
    func testMixedSeparators() {
        var p = SSEParser()
        let evs = p.push("event: a\ndata: {\"v\":1}\r\n\r\nevent: b\ndata: {\"v\":2}\n\n")
        XCTAssertEqual(evs.map(\.event), ["a", "b"])
    }

    // 15. flush 兜底：流结尾无分隔符的残留事件
    func testFlushRemainder() {
        var p = SSEParser()
        XCTAssertTrue(p.push("event: token\ndata: {\"delta\":\"t\"}").isEmpty)
        let evs = p.flush()
        XCTAssertEqual(evs.count, 1)
        XCTAssertEqual(evs[0].string("delta"), "t")
        XCTAssertTrue(p.flush().isEmpty)
    }

    // 16. 逐字节喂入（最严粘包场景）
    func testByteByByteFeed() {
        var p = SSEParser()
        let payload = "event: token\ndata: {\"delta\":\"逐\"}\n\nevent: done\ndata: {\"content\":\"逐\"}\n\n"
        var all: [SSEEvent] = []
        for ch in payload {
            all.append(contentsOf: p.push(String(ch)))
        }
        XCTAssertEqual(all.map(\.event), ["token", "done"])
        XCTAssertEqual(all[0].string("delta"), "逐")
    }
}

final class UTF8StreamDecoderTests: XCTestCase {

    // 多字节字符在分片边界被切断
    func testMultibyteSplitAcrossChunks() {
        var d = UTF8StreamDecoder()
        let full = "data: {\"delta\":\"你\"}"
        let bytes = Array(full.utf8)
        let niuBytes = Array("你".utf8)          // 3 字节
        // 找到「你」在字节流中的起点，切在其第 2 字节前
        let niuStart = bytes.count - niuBytes.count - 2  // 其后还有 `"` 与 `}`
        XCTAssertEqual(Array(bytes[niuStart..<(niuStart+3)]), niuBytes)
        let cut = niuStart + 1
        let head = d.push(Array(bytes.prefix(cut)))
        XCTAssertTrue(head.hasSuffix("{\"delta\":\""))   // 「你」未凑齐，不得提前产出
        let tail = d.push(Array(bytes.suffix(from: cut)))
        XCTAssertEqual(head + tail, full)
    }

    // 流结束冲刷残尾
    func testFinishFlushesLeftover() {
        var d = UTF8StreamDecoder()
        let bytes = Array("你好".utf8)
        _ = d.push(Array(bytes.prefix(bytes.count - 1)))  // 最后一个字缺 1 字节
        let tail = d.finish()
        XCTAssertFalse(tail.isEmpty)  // 替换符兜底，不丢不崩
    }

    // 空块不产出
    func testEmptyPush() {
        var d = UTF8StreamDecoder()
        XCTAssertEqual(d.push([]), "")
    }
}

final class RequestEncodingTests: XCTestCase {

    // chat/stream 请求体编码契约：键名与值逐项对齐 ChatPanel.tsx 实际发送
    func testChatStreamRequestEncoding() throws {
        let req = ChatStreamRequest(
            agent_id: "agent-1",
            model: "qwen3-vl:8b",
            messages: [ChatStreamMessage(role: "user", content: "用三句话介绍你自己")],
            images: nil,
            project_id: "proj-1",
            session_id: "sess-1",
            skip_user_persist: false,
            sandbox_root: "/tmp/vetarai-pilot",
            auto_archive_unit: false
        )
        let data = try JSONEncoder().encode(req)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["agent_id"] as? String, "agent-1")
        XCTAssertEqual(obj["model"] as? String, "qwen3-vl:8b")
        XCTAssertEqual(obj["project_id"] as? String, "proj-1")
        XCTAssertEqual(obj["session_id"] as? String, "sess-1")
        XCTAssertEqual(obj["skip_user_persist"] as? Bool, false)
        XCTAssertEqual(obj["sandbox_root"] as? String, "/tmp/vetarai-pilot")
        XCTAssertEqual(obj["auto_archive_unit"] as? Bool, false)
        let msgs = try XCTUnwrap(obj["messages"] as? [[String: Any]])
        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs[0]["role"] as? String, "user")
        XCTAssertEqual(msgs[0]["content"] as? String, "用三句话介绍你自己")
    }

    // images 为 nil 时键可省略（后端字段 Optional，缺省 = None）
    func testOptionalImagesOmitted() throws {
        let req = ChatStreamRequest(agent_id: "a", model: "m",
                                    messages: [ChatStreamMessage(role: "user", content: "hi")],
                                    project_id: "p", session_id: "s")
        let data = try JSONEncoder().encode(req)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let images = obj["images"]
        XCTAssertTrue(images == nil || images is NSNull)
    }

    // 建会话请求体编码契约
    func testSessionCreateEncoding() throws {
        let req = SessionCreateRequest(project_id: "p1", agent_id: "a1", title: "会话 1")
        let data = try JSONEncoder().encode(req)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["project_id"] as? String, "p1")
        XCTAssertEqual(obj["agent_id"] as? String, "a1")
        XCTAssertEqual(obj["title"] as? String, "会话 1")
    }

    // 建项目请求体编码契约
    func testProjectCreateEncoding() throws {
        let req = ProjectCreateRequest(name: "VetarAI Native Pilot", working_dir: "/tmp/x")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(req)) as? [String: Any])
        XCTAssertEqual(obj["name"] as? String, "VetarAI Native Pilot")
        XCTAssertEqual(obj["working_dir"] as? String, "/tmp/x")
    }
}
