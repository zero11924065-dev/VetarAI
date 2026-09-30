//
//  NativeAsrDriverTests.swift
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

//  逐条锚定（⛔ 行为规格源 subagent/sidecar/model_packs/asr_driver.py）：
//    · resolve_asr_pack（L118-149）：五态文案逐字（未安装/非 asr/已禁用/
//      全禁用/一个都没装）+ 缺省首个启用包按 id 排序
//    · _pack_files（L152-183）：model_quant.onnx 首选 / 缺键清单 / 磁盘缺文件
//    · _ensure_loaded（L210-245）：依赖缺失「ASR 依赖缺失:」/ tokens 两种失败 /
//      am.mvn 失败 / manifest sample_rate 正整数才采纳
//    · unload（L248-256）：空载 false / 不匹配 false / 匹配 true；换包重载
//    · transcribe（L513-546）：language/textnorm ValueError 逐字 / 音频过短 /
//      端到端假会话链（logits→CTC→后处理→duration round(2)）
//
//  全程不要求真 dylib/真模型/真 afconvert：sessionFactoryProvider/decodeAudio/
//  ditherNoise 三缝注入。
//

import XCTest
@testable import VetarAINative

// MARK: - 夹具

private final class FakeAsrSession: NativeAsrSenseVoiceSession, @unchecked Sendable {
    var scripted: NativeAsrSenseVoiceOutput
    var calls: [(frames: Int, language: Int32, textnorm: Int32)] = []
    init(scripted: NativeAsrSenseVoiceOutput) { self.scripted = scripted }
    func runSenseVoice(speech: [Float], frames: Int,
                       language: Int32, textnorm: Int32) throws -> NativeAsrSenseVoiceOutput {
        calls.append((frames, language, textnorm))
        return scripted
    }
}

private struct FakeAsrFactory: NativeAsrSessionFactory {
    let session: FakeAsrSession
    func makeSession(onnxPath: URL) throws -> any NativeAsrSenseVoiceSession { session }
}

private final class FactoryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var count = 0
    func bump() { lock.lock(); count += 1; lock.unlock() }
}

final class NativeAsrDriverTests: XCTestCase {

    private var tmp: URL!
    private var packsRoot: URL!
    private var store: NativeModelPackStore!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("asrdrv_\(UUID().uuidString)")
        packsRoot = tmp.appendingPathComponent("packs")
        try? FileManager.default.createDirectory(at: packsRoot, withIntermediateDirectories: true)
        store = NativeModelPackStore(
            configProvider: { [:] },
            dataRootProvider: { self.tmp },
            environment: ["VETARAI_MODEL_PACKS_DIR": self.packsRoot.path])
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    // MARK: - 夹具构造

    /// 注册并落盘一个 ASR 包（三件套文件；tokens/am.mvn 内容为合法最小集）。
    @discardableResult
    private func installAsrPack(_ packId: String, task: String = "asr",
                                status: String = "installed",
                                tokensJson: String = #"["<blk>","▁你","好","<|zh|>","<|HAPPY|>"]"#,
                                cmvnDim: Int = 560,
                                sampleRate: Int? = nil) -> URL {
        let pack: [String: JSONValue] = [
            "version": .string("1.0.0"), "task": .string(task),
            "format": .string("onnx"), "driver": .string("onnxruntime"),
            "files": .array([
                .object(["path": .string("model_quant.onnx"), "size_bytes": .int(3),
                         "sha256": .string("aa")]),
                .object(["path": .string("am.mvn"), "size_bytes": .int(3),
                         "sha256": .string("bb")]),
                .object(["path": .string("tokens.json"), "size_bytes": .int(3),
                         "sha256": .string("cc")]),
            ]),
        ]
        try! store.registerPack(packId, pack: pack)
        if status != "installed" { store.setEnabled(packId, enabled: false) }
        let dir = packsRoot.appendingPathComponent(packId)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("model_quant.onnx").path,
                                       contents: Data([1, 2, 3]))
        FileManager.default.createFile(atPath: dir.appendingPathComponent("tokens.json").path,
                                       contents: Data(tokensJson.utf8))
        let vals = (0..<cmvnDim).map { String($0 % 7 == 0 ? "-0.5" : "0.25") }.joined(separator: " ")
        let mvn = "<Nnet> \n<Splice> \(cmvnDim) \(cmvnDim)\n[ 0 ]\n"
            + "<AddShift> \(cmvnDim) \(cmvnDim) \n<LearnRateCoef> 0 [ \(vals) ]\n"
            + "<Rescale> \(cmvnDim) \(cmvnDim) \n<LearnRateCoef> 0 [ \(vals) ]\n"
        FileManager.default.createFile(atPath: dir.appendingPathComponent("am.mvn").path,
                                       contents: Data(mvn.utf8))
        var manifest = "{\"pack_id\": \"\(packId)\", \"task\": \"\(task)\""
        if let sampleRate { manifest += ", \"sample_rate\": \(sampleRate)" }
        manifest += "}"
        FileManager.default.createFile(atPath: dir.appendingPathComponent("manifest.json").path,
                                       contents: Data(manifest.utf8))
        return dir
    }

    private func makeDriver(session: FakeAsrSession? = nil,
                            decodeSamples: [Float]? = nil,
                            decodeError: Error? = nil,
                            factoryCounter: FactoryCounter? = nil) -> NativeAsrDriver {
        let d = NativeAsrDriver(store: store,
                                environment: [:],
                                dataRootProvider: { self.tmp },
                                bundleResourceURL: nil)
        if let session {
            d.sessionFactoryProvider = {
                factoryCounter?.bump()
                return FakeAsrFactory(session: session)
            }
        }
        if let decodeSamples {
            d.decodeAudio = { _, _ in
                (decodeSamples, Double(decodeSamples.count) / 16000.0)
            }
        }
        if let decodeError {
            d.decodeAudio = { _, _ in throw decodeError }
        }
        d.ditherNoise = [Double](repeating: 0, count: 100_000_000 / 4)   // 零噪声定值（够长即可）
        return d
    }

    /// 1 秒正弦波形（16000 采样）。
    private func sine(_ seconds: Double = 1.0) -> [Float] {
        let n = Int(seconds * 16000)
        return (0..<n).map { Float(0.1 * sin(2.0 * .pi * 440.0 * Double($0) / 16000.0)) }
    }

    // MARK: - resolve_asr_pack（L118-149）

    func testResolveNoPackAtAll() {
        let d = makeDriver()
        XCTAssertThrowsError(try d.resolveAsrPack()) { error in
            XCTAssertEqual((error as? NativeAsrPackUnavailableError)?.message,
                "尚未安装语音识别模型包。请到「模型包」面板安装一个 ASR 模型包"
                + "（如 SenseVoiceSmall）后再试。")
        }
    }

    func testResolveAllDisabled() {
        installAsrPack("sv", status: "disabled")
        let d = makeDriver()
        XCTAssertThrowsError(try d.resolveAsrPack()) { error in
            XCTAssertEqual((error as? NativeAsrPackUnavailableError)?.message,
                "语音识别模型包已安装但全部被禁用。请到「模型包」面板启用后再转写。")
        }
    }

    func testResolveDefaultFirstById() throws {
        installAsrPack("zeta-pack")
        installAsrPack("alpha-pack")
        let d = makeDriver()
        XCTAssertEqual(try d.resolveAsrPack(), "alpha-pack")
    }

    func testResolveExplicitNotInstalled() {
        let d = makeDriver()
        XCTAssertThrowsError(try d.resolveAsrPack("ghost")) { error in
            XCTAssertEqual((error as? NativeAsrPackUnavailableError)?.message,
                "模型包 'ghost' 未安装。请到「模型包」面板安装语音识别模型包。")
        }
    }

    func testResolveExplicitNotAsrTask() {
        installAsrPack("chatpack", task: "chat")
        let d = makeDriver()
        XCTAssertThrowsError(try d.resolveAsrPack("chatpack")) { error in
            XCTAssertEqual((error as? NativeAsrPackUnavailableError)?.message,
                "模型包 'chatpack' 不是语音识别包（task='chat'），请检查 catalog 清单。")
        }
    }

    func testResolveExplicitDisabled() {
        installAsrPack("sv", status: "disabled")
        let d = makeDriver()
        XCTAssertThrowsError(try d.resolveAsrPack("sv")) { error in
            XCTAssertEqual((error as? NativeAsrPackUnavailableError)?.message,
                "模型包 'sv' 已禁用。请到「模型包」面板启用后再转写。")
        }
    }

    // MARK: - _pack_files（L152-183）

    func testPackFilesMissingManifestKeys() {
        // 手工注册缺三件套条目的包
        let pack: [String: JSONValue] = [
            "version": .string("1"), "task": .string("asr"), "format": .string("onnx"),
            "driver": .string("onnxruntime"),
            "files": .array([.object(["path": .string("weights.bin"),
                                      "size_bytes": .int(1), "sha256": .string("aa")])]),
        ]
        try! store.registerPack("broken", pack: pack)
        let d = makeDriver()
        XCTAssertThrowsError(try d.packFiles("broken")) { error in
            XCTAssertEqual((error as? NativeAsrPackUnavailableError)?.message,
                "模型包 'broken' 清单缺文件（onnx, am.mvn, tokens.json），"
                + "SenseVoiceSmall 包须含 model_quant.onnx（或 .onnx）/ am.mvn / tokens.json。")
        }
    }

    func testPackFilesMissingOnDisk() {
        installAsrPack("sv")
        try! FileManager.default.removeItem(
            at: packsRoot.appendingPathComponent("sv/tokens.json"))
        let d = makeDriver()
        XCTAssertThrowsError(try d.packFiles("sv")) { error in
            XCTAssertEqual((error as? NativeAsrPackUnavailableError)?.message,
                "模型包 'sv' 的文件在磁盘上缺失: tokens.json"
                + "（安装不完整或被手动删除），请到「模型包」面板重新安装。")
        }
    }

    func testPackFilesPrefersModelQuant() throws {
        // 同时含 model.onnx 与 model_quant.onnx → 首选后者（L159-163）
        let pack: [String: JSONValue] = [
            "version": .string("1"), "task": .string("asr"), "format": .string("onnx"),
            "driver": .string("onnxruntime"),
            "files": .array([
                .object(["path": .string("model.onnx"), "size_bytes": .int(1), "sha256": .string("aa")]),
                .object(["path": .string("model_quant.onnx"), "size_bytes": .int(1), "sha256": .string("bb")]),
                .object(["path": .string("am.mvn"), "size_bytes": .int(1), "sha256": .string("cc")]),
                .object(["path": .string("tokens.json"), "size_bytes": .int(1), "sha256": .string("dd")]),
            ]),
        ]
        try! store.registerPack("dual", pack: pack)
        let dir = packsRoot.appendingPathComponent("dual")
        for f in ["model.onnx", "model_quant.onnx", "am.mvn", "tokens.json"] {
            try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: dir.appendingPathComponent(f).path,
                                           contents: Data([1]))
        }
        let d = makeDriver()
        let files = try d.packFiles("dual")
        XCTAssertEqual(files.onnx.lastPathComponent, "model_quant.onnx")
    }

    // MARK: - transcribe 参数校验（L523-526）

    func testTranscribeInvalidLanguage() {
        installAsrPack("sv")
        let d = makeDriver()
        XCTAssertThrowsError(try d.transcribe(path: URL(fileURLWithPath: "/tmp/x.wav"),
                                              language: "fr")) { error in
            XCTAssertEqual((error as? NativeAsrValueError)?.message,
                "language 必须是 auto/zh/en/yue/ja/ko/nospeech 之一，得到 'fr'")
        }
    }

    func testTranscribeAudioTooShort() {
        installAsrPack("sv")
        let session = FakeAsrSession(scripted: .init(logits: [], outFrames: 0, vocab: 1, outLen: 0))
        let d = makeDriver(session: session, decodeSamples: [Float](repeating: 0, count: 100))
        XCTAssertThrowsError(try d.transcribe(path: URL(fileURLWithPath: "/tmp/x.wav"))) { error in
            XCTAssertEqual((error as? NativeAsrAudioDecodeError)?.message,
                "音频过短（不足一帧 25ms），无法转写")
        }
    }

    // MARK: - _ensure_loaded 失败面（L216-236）

    func testEnsureLoadedDependencyMissing() {
        installAsrPack("sv")
        let d = NativeAsrDriver(store: store, environment: [:],
                                dataRootProvider: { self.tmp }, bundleResourceURL: nil)
        // 默认 provider：tmp 下无 drivers/onnxruntime → 依赖缺失
        XCTAssertThrowsError(try d.transcribe(path: URL(fileURLWithPath: "/tmp/x.wav"))) { error in
            let msg = (error as? NativeAsrPackUnavailableError)?.message ?? ""
            XCTAssertTrue(msg.hasPrefix("ASR 依赖缺失: 未找到 onnxruntime 动态库"), msg)
        }
    }

    func testEnsureLoadedBadTokens() {
        installAsrPack("sv", tokensJson: #"{"not": "array"}"#)
        let session = FakeAsrSession(scripted: .init(logits: [], outFrames: 0, vocab: 1, outLen: 0))
        let d = makeDriver(session: session, decodeSamples: sine())
        XCTAssertThrowsError(try d.transcribe(path: URL(fileURLWithPath: "/tmp/x.wav"))) { error in
            XCTAssertEqual((error as? NativeAsrPackUnavailableError)?.message,
                "tokens.json 须为非空字符串数组（SenseVoice 词表）")
        }
    }

    func testEnsureLoadedBadCmvn() {
        installAsrPack("sv")
        FileManager.default.createFile(
            atPath: packsRoot.appendingPathComponent("sv/am.mvn").path,
            contents: Data("<Nnet> garbage\n".utf8))
        let session = FakeAsrSession(scripted: .init(logits: [], outFrames: 0, vocab: 1, outLen: 0))
        let d = makeDriver(session: session, decodeSamples: sine())
        XCTAssertThrowsError(try d.transcribe(path: URL(fileURLWithPath: "/tmp/x.wav"))) { error in
            let msg = (error as? NativeAsrPackUnavailableError)?.message ?? ""
            XCTAssertTrue(msg.hasPrefix("am.mvn 解析失败（缺 AddShift/Rescale 段）"), msg)
        }
    }

    // MARK: - 端到端假会话链（L527-546）

    func testTranscribeHappyPath() throws {
        installAsrPack("sv")
        // logits (T'=4, V=5)：argmax [1,1,0,2] → 去重去 blank → [1,2] → "▁你"+"好" → " 你好"
        let tokens5: [(Int, Float)] = [(1, 1), (1, 1), (0, 1), (2, 1)]
        var logits = [Float](repeating: 0, count: 4 * 5)
        for (r, (id, v)) in tokens5.enumerated() { logits[r * 5 + id] = v }
        let session = FakeAsrSession(scripted: .init(logits: logits, outFrames: 4,
                                                     vocab: 5, outLen: 4))
        let d = makeDriver(session: session, decodeSamples: sine(1.0))
        let result = try d.transcribe(path: URL(fileURLWithPath: "/tmp/x.wav"))
        XCTAssertEqual(result.text, "你好")
        XCTAssertEqual(result.durationS, 1.0)
        XCTAssertEqual(result.modelPackId, "sv")
        // fbank T=98 → LFR ceil(98/6)=17 帧；language/textnorm 默认 0/14
        XCTAssertEqual(session.calls.first?.frames, 17)
        XCTAssertEqual(session.calls.first?.language, 0)
        XCTAssertEqual(session.calls.first?.textnorm, 14)
        XCTAssertEqual(d.loadedPackId, "sv")
    }

    func testTranscribeSampleRateFromManifest() throws {
        installAsrPack("sv", sampleRate: 8000)
        var gotSr = 0
        let session = FakeAsrSession(scripted: .init(logits: [0, 1], outFrames: 1,
                                                     vocab: 2, outLen: 1))
        let d = makeDriver(session: session)
        d.decodeAudio = { _, sr in
            gotSr = sr
            return (self.sine(1.0), 1.0)
        }
        _ = try d.transcribe(path: URL(fileURLWithPath: "/tmp/x.wav"), language: "zh")
        XCTAssertEqual(gotSr, 8000)
        XCTAssertEqual(session.calls.first?.language, 3)
    }

    // MARK: - unload / 换包（L248-256）

    func testUnloadSemantics() throws {
        installAsrPack("sv")
        installAsrPack("sv2")
        let session = FakeAsrSession(scripted: .init(logits: [0, 1], outFrames: 1,
                                                     vocab: 2, outLen: 1))
        let d = makeDriver(session: session, decodeSamples: sine())
        // 空载 unload → false
        XCTAssertFalse(d.unload())
        _ = try d.transcribe(path: URL(fileURLWithPath: "/tmp/x.wav"), packId: "sv")
        XCTAssertEqual(d.loadedPackId, "sv")
        // 不匹配 → false 且不动
        XCTAssertFalse(d.unload("sv2"))
        XCTAssertEqual(d.loadedPackId, "sv")
        // 匹配 → true 且清空
        XCTAssertTrue(d.unload("sv"))
        XCTAssertNil(d.loadedPackId)
    }

    func testSwitchPackReloads() throws {
        installAsrPack("sv")
        installAsrPack("sv2")
        let session = FakeAsrSession(scripted: .init(logits: [0, 1], outFrames: 1,
                                                     vocab: 2, outLen: 1))
        let counter = FactoryCounter()
        let d = makeDriver(session: session, decodeSamples: sine(), factoryCounter: counter)
        _ = try d.transcribe(path: URL(fileURLWithPath: "/tmp/x.wav"), packId: "sv")
        _ = try d.transcribe(path: URL(fileURLWithPath: "/tmp/x.wav"), packId: "sv")
        XCTAssertEqual(counter.count, 1, "同包复用不重载")
        _ = try d.transcribe(path: URL(fileURLWithPath: "/tmp/x.wav"), packId: "sv2")
        XCTAssertEqual(counter.count, 2, "换包即重载")
        XCTAssertEqual(d.loadedPackId, "sv2")
    }
}
