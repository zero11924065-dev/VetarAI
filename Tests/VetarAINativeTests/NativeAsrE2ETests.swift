//
//  NativeAsrE2ETests.swift
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

//  全链真跑：NativeModelPackStore（真注册表）→ NativeAsrDriver（三态解析
//  → dlopen 真 onnxruntime → 真 SenseVoice-small int8 会话）→ afconvert
//  解码 → fbank/LFR/CMVN → CTC 贪心 → rich_transcription_postprocess。
//
//  skip-unless 三条件（缺一即跳过，不算失败）：
//    ① 真包：~/.subagent/models/packs/sensevoice-small 四件套 + registry.json
//       （**只读**——Python 侧车的用户数据，绝不写入）
//    ② ORT dylib：subagent venv 实物 libonnxruntime.1.29.0.dylib（只读 dlopen）
//    ③ 语音样本：Tests/Fixtures/asr/e2e_voice.wav（仓库内，Tingting 合成
//       16kHz 单声道 PCM16「你好，这是一段语音转写测试。」3.01s）
//

import XCTest
@testable import VetarAINative

final class NativeAsrE2ETests: XCTestCase {

    /// 真包根（Python 侧车已装的 sensevoice-small；只读，绝不写入）。
    private static let packsRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".subagent/models/packs")
    /// ORT dylib（subagent venv 实物；只读 dlopen）。
    private static let ortDylib = URL(fileURLWithPath:
        "/Users/vetar/Desktop/beta/subagent/.venv/lib/python3.14/site-packages/"
        + "onnxruntime/capi/libonnxruntime.1.29.0.dylib")

    /// 语音样本（#filePath = <repo>/Tests/VetarAINativeTests/NativeAsrE2ETests.swift）。
    private static func wavURL(_ file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // VetarAINativeTests
            .deletingLastPathComponent()   // Tests
            .appendingPathComponent("Fixtures/asr/e2e_voice.wav")
    }

    private func prerequisitesMet() -> Bool {
        let pack = Self.packsRoot.appendingPathComponent("sensevoice-small")
        for f in ["model_quant.onnx", "am.mvn", "tokens.json", "manifest.json"] {
            guard FileManager.default.fileExists(atPath: pack.appendingPathComponent(f).path)
            else { return false }
        }
        guard FileManager.default.fileExists(
                atPath: Self.packsRoot.appendingPathComponent("registry.json").path),
              FileManager.default.fileExists(atPath: Self.ortDylib.path),
              FileManager.default.fileExists(atPath: Self.wavURL().path)
        else { return false }
        return true
    }

    func testE2ERealModelTranscribe() throws {
        try XCTSkipUnless(prerequisitesMet(),
                          "真包/ORT dylib/语音样本不齐——跳过端到端真模型转写")
        let store = NativeModelPackStore(
            configProvider: { [:] },
            dataRootProvider: { Self.packsRoot },
            environment: [NativeModelPackStore.envPacksDir: Self.packsRoot.path])
        let driver = NativeAsrDriver(
            store: store,
            environment: ["VETARAI_ONNXRUNTIME": Self.ortDylib.path],
            dataRootProvider: { Self.packsRoot },
            bundleResourceURL: nil)
        defer { driver.unload() }

        let result = try driver.transcribe(path: Self.wavURL())

        XCTAssertEqual(result.modelPackId, "sensevoice-small")
        XCTAssertGreaterThan(result.durationS, 2.0, "样本 3.01s，时长不应严重缩水")
        XCTAssertLessThan(result.durationS, 4.0)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(text.isEmpty, "真模型转写文本不能为空")
        XCTAssertFalse(text.contains("ONNX"), "疑似异常泄漏: \(text)")
        XCTAssertFalse(text.lowercased().contains("error"), "疑似异常泄漏: \(text)")
        XCTAssertGreaterThanOrEqual(text.count, 4, "3 秒中文语音转写不应只有零星字符: \(text)")
        // Tingting 清晰合成音，SenseVoice-small 应至少命中关键词之一
        XCTAssertTrue(text.contains("你") || text.contains("测试") || text.contains("语音"),
                      "转写内容可疑（Tingting「你好，这是一段语音转写测试。」）: \(text)")
    }
}
