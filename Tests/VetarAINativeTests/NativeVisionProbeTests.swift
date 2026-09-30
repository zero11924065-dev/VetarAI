//
//  NativeVisionProbeTests.swift
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

//  逐条对照 app.py L1869-1900（⛔ 只读行为规格源）：
//    · _use_vision = bool(get_config().get("vision_parse_attachments", False))——
//      关 → 探针 nil（图片仅标注，与 Python 关开关逐字一致）
//    · _vision_parse（L1871-1885）：扩展名末段小写（无点号 → "png"）组装
//      data:image/<ext>;base64, URI → conn.chat(config default_model 缺省
//      "qwen3.8", [user/prompt 逐字], images=[data_uri]) → result or ""
//    · ANY 失败 → 空串 → 调用方 `or None` 仅标注，绝不阻塞圆桌创建
//    · 视觉文本同走单件 3000 截断（L1902-1904）
//    · 仅 kind=="image" 且解析为 None 才触发（L1899 逐字）
//

import XCTest
@testable import VetarAINative

// MARK: - 夹具：脚本化视觉 chat 的假 connector

private final class StubVisionConn: NativeVisionChatConnector, @unchecked Sendable {
    var result: Result<String, Error> = .success("图中是一份合同首页")
    private(set) var calls: [(model: String, messages: [[String: JSONValue]], images: [String])] = []

    func chat(model: String, messages: [[String: JSONValue]], images: [String]) async throws -> String {
        calls.append((model, messages, images))
        return try result.get()
    }
}

private struct StubError: Error {}

final class NativeVisionProbeTests: XCTestCase {

    private func pngInput(_ name: String = "照片.png") -> RTAttachmentInput {
        RTAttachmentInput(name: name,
                          content_base64: Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString())
    }

    // MARK: 开关判定（L1869 逐字）

    /// 关（缺省/显式 false）→ 探针 nil；开 → 非 nil。
    func testFlagGating() {
        let stub = StubVisionConn()
        XCTAssertNil(NativeRoundtableEndpoints.visionProbeIfEnabled(config: [:], connector: stub),
                     "缺省（get 缺省 False）→ 关")
        XCTAssertNil(NativeRoundtableEndpoints.visionProbeIfEnabled(
            config: ["vision_parse_attachments": .bool(false)], connector: stub))
        XCTAssertNotNil(NativeRoundtableEndpoints.visionProbeIfEnabled(
            config: ["vision_parse_attachments": .bool(true)], connector: stub))
    }

    // MARK: 模型解析（L1878：config default_model 缺省 qwen3.8）

    /// 探针闭包把 default_model 传给 connector；缺省键 → "qwen3.8"。
    func testModelResolution() async {
        let stub = StubVisionConn()
        let probe = NativeRoundtableEndpoints.visionProbeIfEnabled(
            config: ["vision_parse_attachments": .bool(true)], connector: stub)!
        _ = await probe(Data([0x01]), "a.png")
        XCTAssertEqual(stub.calls.last?.model, "qwen3.8", "缺省 default_model → qwen3.8")

        let probe2 = NativeRoundtableEndpoints.visionProbeIfEnabled(
            config: ["vision_parse_attachments": .bool(true),
                     "default_model": .string("qwen2.5-vl")], connector: stub)!
        _ = await probe2(Data([0x01]), "a.png")
        XCTAssertEqual(stub.calls.last?.model, "qwen2.5-vl")
    }

    // MARK: data URI 组装 + prompt 逐字（L1875-1882）

    /// 扩展名末段小写（.JPG → image/jpg，Python 不做 jpg→jpeg 归一）；无点号 → png；
    /// 单条 user 消息，prompt 逐字；images=[dataURI]。
    func testDataURIAssembly() async throws {
        let stub = StubVisionConn()
        _ = await NativeVisionProbe.describe(raw: Data([0xAA, 0xBB]), name: "照片.JPG",
                                             connector: stub, model: "m")
        let call = try XCTUnwrap(stub.calls.last)
        XCTAssertEqual(call.images, ["data:image/jpg;base64,qrs="])
        XCTAssertEqual(call.messages.count, 1)
        XCTAssertEqual(call.messages[0]["role"], .string("user"))
        XCTAssertEqual(call.messages[0]["content"], .string("请描述这张图片的关键内容，供讨论参考。"))

        _ = await NativeVisionProbe.describe(raw: Data([0x01]), name: "无扩展名",
                                             connector: stub, model: "m")
        XCTAssertEqual(stub.calls.last?.images.first, "data:image/png;base64,AQ==")
    }

    // MARK: 失败静默（L1884-1885：ANY 失败 → ""）

    /// connector 抛错 → 空串（不抛）；返回文本原样带出。
    func testFailSilent() async {
        let stub = StubVisionConn()
        stub.result = .failure(StubError())
        let s = await NativeVisionProbe.describe(raw: Data([0x01]), name: "a.png",
                                                 connector: stub, model: "m")
        XCTAssertEqual(s, "")
        stub.result = .success("识别文本")
        let s2 = await NativeVisionProbe.describe(raw: Data([0x01]), name: "a.png",
                                                  connector: stub, model: "m")
        XCTAssertEqual(s2, "识别文本")
    }

    // MARK: 预处理接线（L1899-1900：image 且开关开才触发）

    /// 探针 nil（关开关口径）→ 图片仅标注：text=nil、is_text=false、kind=image。
    func testPreprocessWithoutProbe() async throws {
        let (metas, files) = try await NativeRoundtableEndpoints.preprocessAttachments(
            [pngInput()], visionProbe: nil)
        XCTAssertEqual(metas.count, 1)
        XCTAssertEqual(metas[0]["kind"], .string("image"))
        XCTAssertEqual(metas[0]["is_text"], .bool(false))
        XCTAssertEqual(metas[0]["text"], .null)
        XCTAssertEqual(files.count, 1)
    }

    /// 探针开 + stub 返回描述 → 附件标注注入（text=描述、is_text=true）。
    func testPreprocessWithProbeAnnotates() async throws {
        let stub = StubVisionConn()
        let probe: (@Sendable (Data, String) async -> String) = { raw, name in
            await NativeVisionProbe.describe(raw: raw, name: name, connector: stub, model: "m")
        }
        let (metas, _) = try await NativeRoundtableEndpoints.preprocessAttachments(
            [pngInput()], visionProbe: probe)
        XCTAssertEqual(metas[0]["text"], .string("图中是一份合同首页"))
        XCTAssertEqual(metas[0]["is_text"], .bool(true))
        XCTAssertEqual(stub.calls.count, 1)
    }

    /// connector 抛错 → 空标注但创建照常（metas 产出、不抛）——`or None` 口径。
    func testPreprocessProbeThrowsStillSucceeds() async throws {
        let stub = StubVisionConn()
        stub.result = .failure(StubError())
        let probe: (@Sendable (Data, String) async -> String) = { raw, name in
            await NativeVisionProbe.describe(raw: raw, name: name, connector: stub, model: "m")
        }
        let (metas, files) = try await NativeRoundtableEndpoints.preprocessAttachments(
            [pngInput()], visionProbe: probe)
        XCTAssertEqual(metas.count, 1, "视觉失败不阻塞附件预处理（创建继续）")
        XCTAssertEqual(metas[0]["text"], .null)
        XCTAssertEqual(metas[0]["is_text"], .bool(false))
        XCTAssertEqual(files.count, 1, "原始文件仍待落盘")
    }

    /// 非图片附件不触发探针（L1899 `text is None and kind == "image"` 双条件逐字）。
    func testProbeOnlyForImages() async throws {
        final class Counter: @unchecked Sendable { var n = 0 }
        let counter = Counter()
        let probe: (@Sendable (Data, String) async -> String) = { _, _ in
            counter.n += 1
            return "不该被调用"
        }
        let txt = RTAttachmentInput(name: "笔记.txt",
                                    content_base64: Data("正文".utf8).base64EncodedString())
        let bin = RTAttachmentInput(name: "包.bin",
                                    content_base64: Data([0x00, 0x01]).base64EncodedString())
        let (metas, _) = try await NativeRoundtableEndpoints.preprocessAttachments(
            [txt, bin], visionProbe: probe)
        XCTAssertEqual(counter.n, 0, "文本可解析/非图片不触发视觉识别")
        XCTAssertEqual(metas[0]["text"], .string("正文"))
        XCTAssertEqual(metas[1]["is_text"], .bool(false))
    }

    /// 视觉文本同走单件 3000 截断（L1902-1904 截断标记）。
    func testVisionTextTruncated() async throws {
        let stub = StubVisionConn()
        stub.result = .success(String(repeating: "字", count: 3500))
        let probe: (@Sendable (Data, String) async -> String) = { raw, name in
            await NativeVisionProbe.describe(raw: raw, name: name, connector: stub, model: "m")
        }
        let (metas, _) = try await NativeRoundtableEndpoints.preprocessAttachments(
            [pngInput()], visionProbe: probe)
        XCTAssertEqual(metas[0]["truncated"], .bool(true))
        XCTAssertEqual(metas[0]["text"]?.string?.unicodeScalars.count, 3000)
    }
}
