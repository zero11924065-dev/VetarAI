//
//  NativeAsrEndpointsTests.swift
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

//  逐条锚定（⛔ 行为规格源 subagent/sidecar/app.py L2910-3027）：
//    · status（L2917-2946）：三态 ready/disabled/none + message 逐字复用
//      resolve_asr_pack 原文；永不抛（无注册表/损坏/意外一律 200 语义）
//    · transcribe 400 校验链（L2973-2998）七步逐字逐序：空 path → 非绝对 →
//      不存在（目录同款）→ 格式（pathlib suffix 语义：dotfile/尾随点/目录含点
//      均「（无扩展名）」）→ stat → 500MB 上限（银行家 .0f）→ 非法 pack_id
//    · 错误映射（L3019-3026）：PackUnavailable→409 / AudioDecode→422 /
//      ValueError→400
//    · C7 落盘归属（L3000-3013）：pid+sid 齐全才复制；成功 saved_path /
//      失败降级 save_error「OSError: 」前缀不谎称已保存；同名两份保留铁律
//
//  全程不要求真 dylib/真模型/真 afconvert：sessionFactoryProvider/decodeAudio
//  缝注入（同 NativeAsrDriverTests 夹具模式）。
//

import XCTest
@testable import VetarAINative

// MARK: - 夹具

private final class FakeAsrSessionEp: NativeAsrSenseVoiceSession, @unchecked Sendable {
    var scripted: NativeAsrSenseVoiceOutput
    init(scripted: NativeAsrSenseVoiceOutput) { self.scripted = scripted }
    func runSenseVoice(speech: [Float], frames: Int,
                       language: Int32, textnorm: Int32) throws -> NativeAsrSenseVoiceOutput {
        scripted
    }
}

private struct FakeAsrFactoryEp: NativeAsrSessionFactory {
    let session: FakeAsrSessionEp
    func makeSession(onnxPath: URL) throws -> any NativeAsrSenseVoiceSession { session }
}

final class NativeAsrEndpointsTests: XCTestCase {

    private var tmp: URL!
    private var packsRoot: URL!
    private var projectsRoot: URL!
    private var store: NativeModelPackStore!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("asrep_\(UUID().uuidString)")
        packsRoot = tmp.appendingPathComponent("packs")
        projectsRoot = tmp.appendingPathComponent("projects")
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

    // MARK: 夹具构造

    /// 注册并落盘一个 ASR 包（三件套；tokens/am.mvn 为合法最小集）。
    @discardableResult
    private func installAsrPack(_ packId: String, task: String = "asr",
                                status: String = "installed") -> URL {
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
                                       contents: Data(#"["<blk>","▁你","好"]"#.utf8))
        let vals = (0..<560).map { String($0 % 7 == 0 ? "-0.5" : "0.25") }.joined(separator: " ")
        let mvn = "<Nnet> \n<Splice> 560 560\n[ 0 ]\n"
            + "<AddShift> 560 560 \n<LearnRateCoef> 0 [ \(vals) ]\n"
            + "<Rescale> 560 560 \n<LearnRateCoef> 0 [ \(vals) ]\n"
        FileManager.default.createFile(atPath: dir.appendingPathComponent("am.mvn").path,
                                       contents: Data(mvn.utf8))
        FileManager.default.createFile(atPath: dir.appendingPathComponent("manifest.json").path,
                                       contents: Data("{\"pack_id\": \"\(packId)\", \"task\": \"\(task)\"}".utf8))
        return dir
    }

    /// 造一个内容已知的音频文件（内容由 decodeAudio 缝接管，磁盘只供校验/落盘）。
    private func makeAudioFile(_ name: String = "voice.wav",
                               bytes: Int = 64) -> URL {
        let url = tmp.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path,
                                       contents: Data((0..<bytes).map { UInt8($0 % 251) }))
        return url
    }

    private func sine(_ seconds: Double = 1.0) -> [Float] {
        let n = Int(seconds * 16000)
        return (0..<n).map { Float(0.1 * sin(2.0 * .pi * 440.0 * Double($0) / 16000.0)) }
    }

    /// logits (T'=4, V=3)：argmax [1,1,0,2] → 去重去 blank → [1,2] → "▁你"+"好" → "你好"。
    private func helloSession() -> FakeAsrSessionEp {
        var logits = [Float](repeating: 0, count: 4 * 3)
        for (r, id) in [1, 1, 0, 2].enumerated() { logits[r * 3 + id] = 1 }
        return FakeAsrSessionEp(scripted: .init(logits: logits, outFrames: 4, vocab: 3, outLen: 4))
    }

    private func makeEndpoints(session: FakeAsrSessionEp? = nil,
                               decodeSamples: [Float]? = nil,
                               decodeError: Error? = nil) -> (NativeAsrEndpoints, NativeAsrDriver) {
        let d = NativeAsrDriver(store: store, environment: [:],
                                dataRootProvider: { self.tmp }, bundleResourceURL: nil)
        if let session {
            d.sessionFactoryProvider = { FakeAsrFactoryEp(session: session) }
        }
        if let decodeSamples {
            d.decodeAudio = { _, _ in (decodeSamples, Double(decodeSamples.count) / 16000.0) }
        }
        if let decodeError {
            d.decodeAudio = { _, _ in throw decodeError }
        }
        let ep = NativeAsrEndpoints(store: store, driver: d,
                                    projectsRootProvider: { self.projectsRoot })
        return (ep, d)
    }

    private func assertHttp(_ error: Error, _ status: Int, _ detail: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        guard case .httpError(let s, let d) = error as? SidecarError else {
            return XCTFail("错误形态不对: \(error)", file: file, line: line)
        }
        XCTAssertEqual(s, status, file: file, line: line)
        XCTAssertEqual(d, detail, file: file, line: line)
    }

    // MARK: - status 三态（L2917-2946）

    func testStatusNone() {
        let (ep, _) = makeEndpoints()
        let s = ep.status()
        XCTAssertFalse(s.available)
        XCTAssertEqual(s.state, "none")
        XCTAssertNil(s.pack_id)
        XCTAssertEqual(s.message,
            "尚未安装语音识别模型包。请到「模型包」面板安装一个 ASR 模型包（如 SenseVoiceSmall）后再试。")
    }

    func testStatusDisabled() {
        installAsrPack("sv", status: "disabled")
        installAsrPack("chat-x", task: "chat")   // 非 asr 包不计入 has_asr
        let (ep, _) = makeEndpoints()
        let s = ep.status()
        XCTAssertFalse(s.available)
        XCTAssertEqual(s.state, "disabled")
        XCTAssertNil(s.pack_id)
        XCTAssertEqual(s.message,
            "语音识别模型包已安装但全部被禁用。请到「模型包」面板启用后再转写。")
    }

    func testStatusReady() {
        installAsrPack("sv")
        installAsrPack("sv2", status: "disabled")   // 有启用中的即 ready
        let (ep, _) = makeEndpoints()
        let s = ep.status()
        XCTAssertTrue(s.available)
        XCTAssertEqual(s.state, "ready")
        XCTAssertEqual(s.pack_id, "sv")
        XCTAssertNil(s.message)
    }

    // MARK: - transcribe 400 校验链（L2973-2998 逐字逐序）

    func testTranscribeValidationChain() async {
        installAsrPack("sv")
        let (ep, _) = makeEndpoints(session: helloSession(), decodeSamples: sine())

        // ① 空 path（strip 后空同款）
        for p in ["", "   "] {
            do {
                _ = try await ep.transcribe(path: p, packId: nil, language: "auto",
                                            projectId: "", sessionId: "")
                XCTFail("应 400")
            } catch { assertHttp(error, 400, "path 不能为空（须本地音频绝对路径）") }
        }
        // ② 非绝对（repr 单引号）
        do {
            _ = try await ep.transcribe(path: "rel/x.wav", packId: nil, language: "auto",
                                        projectId: "", sessionId: "")
            XCTFail("应 400")
        } catch { assertHttp(error, 400, "path 须为绝对路径: 'rel/x.wav'") }
        // ③ 不存在
        do {
            _ = try await ep.transcribe(path: "/tmp/asrep-no-such-x.wav", packId: nil,
                                        language: "auto", projectId: "", sessionId: "")
            XCTFail("应 400")
        } catch { assertHttp(error, 400, "音频文件不存在: '/tmp/asrep-no-such-x.wav'") }
        // ③b 目录不是文件（p.is_file() false 同款）
        do {
            _ = try await ep.transcribe(path: packsRoot.path, packId: nil, language: "auto",
                                        projectId: "", sessionId: "")
            XCTFail("应 400")
        } catch { assertHttp(error, 400, "音频文件不存在: '\(packsRoot.path)'") }
        // ④ 不支持的格式（sorted 序即错误文案序）
        let txt = tmp.appendingPathComponent("note.txt")
        FileManager.default.createFile(atPath: txt.path, contents: Data("hi".utf8))
        do {
            _ = try await ep.transcribe(path: txt.path, packId: nil, language: "auto",
                                        projectId: "", sessionId: "")
            XCTFail("应 400")
        } catch {
            assertHttp(error, 400, "不支持的音频格式 .txt；支持: "
                + ".aac .aif .aiff .caf .flac .m4a .mp3 .ogg .opus .wav .webm")
        }
        // ④b 无扩展名 → 「（无扩展名）」
        let noext = tmp.appendingPathComponent("noext")
        FileManager.default.createFile(atPath: noext.path, contents: Data([0]))
        do {
            _ = try await ep.transcribe(path: noext.path, packId: nil, language: "auto",
                                        projectId: "", sessionId: "")
            XCTFail("应 400")
        } catch {
            assertHttp(error, 400, "不支持的音频格式 （无扩展名）；支持: "
                + ".aac .aif .aiff .caf .flac .m4a .mp3 .ogg .opus .wav .webm")
        }
        // ④c pathlib suffix 语义：dotfile「.wav」suffix=""（_ext_of 会误判 .wav，pathlib 不会）
        let dotfile = tmp.appendingPathComponent(".wav")
        FileManager.default.createFile(atPath: dotfile.path, contents: Data([0]))
        do {
            _ = try await ep.transcribe(path: dotfile.path, packId: nil, language: "auto",
                                        projectId: "", sessionId: "")
            XCTFail("应 400")
        } catch {
            assertHttp(error, 400, "不支持的音频格式 （无扩展名）；支持: "
                + ".aac .aif .aiff .caf .flac .m4a .mp3 .ogg .opus .wav .webm")
        }
        // ④d 目录名含点而文件名无点：pathlib 只看末级 → 「（无扩展名）」
        let dotDir = tmp.appendingPathComponent("a.d")
        try? FileManager.default.createDirectory(at: dotDir, withIntermediateDirectories: true)
        let inner = dotDir.appendingPathComponent("x")
        FileManager.default.createFile(atPath: inner.path, contents: Data([0]))
        do {
            _ = try await ep.transcribe(path: inner.path, packId: nil, language: "auto",
                                        projectId: "", sessionId: "")
            XCTFail("应 400")
        } catch {
            assertHttp(error, 400, "不支持的音频格式 （无扩展名）；支持: "
                + ".aac .aif .aiff .caf .flac .m4a .mp3 .ogg .opus .wav .webm")
        }
        // ⑦ 非法 pack_id（在校验链末端——文件合法才走到）
        let ok = makeAudioFile()
        do {
            _ = try await ep.transcribe(path: ok.path, packId: "bad id!", language: "auto",
                                        projectId: "", sessionId: "")
            XCTFail("应 400")
        } catch { assertHttp(error, 400, "非法 pack_id: 'bad id!'") }
        // 链序证明：非法 pack_id + 不存在文件 → 先报不存在（③在⑦前）
        do {
            _ = try await ep.transcribe(path: "/tmp/asrep-no-such-y.wav", packId: "bad id!",
                                        language: "auto", projectId: "", sessionId: "")
            XCTFail("应 400")
        } catch { assertHttp(error, 400, "音频文件不存在: '/tmp/asrep-no-such-y.wav'") }
    }

    func testTranscribeTooLarge() async throws {
        installAsrPack("sv")
        let (ep, _) = makeEndpoints(session: helloSession(), decodeSamples: sine())
        // 稀疏文件：逻辑大小 501MB（truncate 不写盘，stat 读逻辑大小）
        let big = tmp.appendingPathComponent("big.wav")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let fh = try FileHandle(forWritingTo: big)
        try fh.truncate(atOffset: UInt64(501 * 1024 * 1024))
        try fh.close()
        do {
            _ = try await ep.transcribe(path: big.path, packId: nil, language: "auto",
                                        projectId: "", sessionId: "")
            XCTFail("应 400")
        } catch {
            assertHttp(error, 400,
                       "音频文件超过 500MB 上限（实际 501MB），请切分后再转写")
        }
        // 边界：恰 500MB 不触发上限（继续走到转写——无包则 409 证明 400 未拦）
        let exact = tmp.appendingPathComponent("exact.wav")
        FileManager.default.createFile(atPath: exact.path, contents: nil)
        let fh2 = try FileHandle(forWritingTo: exact)
        try fh2.truncate(atOffset: UInt64(500 * 1024 * 1024))
        try fh2.close()
        let out = try await ep.transcribe(path: exact.path, packId: nil, language: "auto",
                                          projectId: "", sessionId: "")
        XCTAssertEqual(out.text, "你好")
    }

    // MARK: - 错误映射（L3019-3026）

    func testTranscribePackUnavailable409() async {
        let ok = makeAudioFile()
        // 一个都没装 → 409「尚未安装…」
        do {
            let (ep, _) = makeEndpoints()
            _ = try await ep.transcribe(path: ok.path, packId: nil, language: "auto",
                                        projectId: "", sessionId: "")
            XCTFail("应 409")
        } catch {
            assertHttp(error, 409,
                "尚未安装语音识别模型包。请到「模型包」面板安装一个 ASR 模型包（如 SenseVoiceSmall）后再试。")
        }
        // 全禁用 → 409「已安装但全部被禁用…」
        installAsrPack("sv", status: "disabled")
        do {
            let (ep, _) = makeEndpoints()
            _ = try await ep.transcribe(path: ok.path, packId: nil, language: "auto",
                                        projectId: "", sessionId: "")
            XCTFail("应 409")
        } catch {
            assertHttp(error, 409,
                "语音识别模型包已安装但全部被禁用。请到「模型包」面板启用后再转写。")
        }
        // 指定未安装的 pack_id → 409「未安装…」
        installAsrPack("sv2")
        do {
            let (ep, _) = makeEndpoints()
            _ = try await ep.transcribe(path: ok.path, packId: "ghost", language: "auto",
                                        projectId: "", sessionId: "")
            XCTFail("应 409")
        } catch {
            assertHttp(error, 409,
                "模型包 'ghost' 未安装。请到「模型包」面板安装语音识别模型包。")
        }
    }

    func testTranscribeDecodeError422() async {
        installAsrPack("sv")
        let ok = makeAudioFile()
        let (ep, _) = makeEndpoints(session: helloSession(),
                                    decodeError: NativeAsrAudioDecodeError("测试解码失败样例"))
        do {
            _ = try await ep.transcribe(path: ok.path, packId: nil, language: "auto",
                                        projectId: "", sessionId: "")
            XCTFail("应 422")
        } catch { assertHttp(error, 422, "测试解码失败样例") }
    }

    func testTranscribeValueError400() async {
        installAsrPack("sv")
        let ok = makeAudioFile()
        let (ep, _) = makeEndpoints(session: helloSession(), decodeSamples: sine())
        do {
            _ = try await ep.transcribe(path: ok.path, packId: nil, language: "xx",
                                        projectId: "", sessionId: "")
            XCTFail("应 400")
        } catch {
            assertHttp(error, 400,
                "language 必须是 auto/zh/en/yue/ja/ko/nospeech 之一，得到 'xx'")
        }
    }

    // MARK: - 成功路径 + C7 落盘归属（L3000-3013）

    func testTranscribeHappyPathNoSave() async throws {
        installAsrPack("sv")
        let ok = makeAudioFile()
        let (ep, d) = makeEndpoints(session: helloSession(), decodeSamples: sine(1.0))
        // pid/sid 缺省 → 只转写不落盘，不报错（双 nil）
        let out = try await ep.transcribe(path: ok.path, packId: nil, language: "auto",
                                          projectId: "", sessionId: "")
        XCTAssertEqual(out.text, "你好")
        XCTAssertEqual(out.duration_s, 1.0)
        XCTAssertEqual(out.model_pack_id, "sv")
        XCTAssertNil(out.saved_path)
        XCTAssertNil(out.save_error)
        XCTAssertEqual(d.loadedPackId, "sv")
        // pid 有 sid 无 → 同样不落盘
        let out2 = try await ep.transcribe(path: ok.path, packId: nil, language: "auto",
                                           projectId: "p1", sessionId: "  ")
        XCTAssertNil(out2.saved_path)
        XCTAssertNil(out2.save_error)
    }

    func testTranscribeSaveAttachment() async throws {
        installAsrPack("sv")
        let src = makeAudioFile("meeting.wav", bytes: 128)
        let expectBytes = try Data(contentsOf: src)
        let (ep, _) = makeEndpoints(session: helloSession(), decodeSamples: sine())
        let out = try await ep.transcribe(path: src.path, packId: nil, language: "auto",
                                          projectId: "p1", sessionId: "s1")
        XCTAssertEqual(out.text, "你好")
        XCTAssertNil(out.save_error)
        let saved = try XCTUnwrap(out.saved_path)
        // 落盘位置：projectsRoot/p1/attachments/s1/meeting.wav（原件复制，内容一致）
        let expectDir = projectsRoot.appendingPathComponent("p1")
            .appendingPathComponent("attachments").appendingPathComponent("s1")
        XCTAssertEqual(saved, expectDir.appendingPathComponent("meeting.wav").path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: saved)), expectBytes)
    }

    func testTranscribeSaveAttachmentFailureDegrades() async throws {
        installAsrPack("sv")
        let src = makeAudioFile()
        // projectsRoot 被同名文件占住 → createDirectory 必败 → save_error 降级
        FileManager.default.createFile(atPath: projectsRoot.path, contents: Data([0]))
        let (ep, _) = makeEndpoints(session: helloSession(), decodeSamples: sine())
        let out = try await ep.transcribe(path: src.path, packId: nil, language: "auto",
                                          projectId: "p1", sessionId: "s1")
        // 文稿是主价值：落盘失败不得让转写失败
        XCTAssertEqual(out.text, "你好")
        XCTAssertNil(out.saved_path)
        let err = try XCTUnwrap(out.save_error)
        XCTAssertTrue(err.hasPrefix("OSError: "), "save_error 形态: \(err)")
    }

    func testSaveAttachmentNameCollisionKeepsBoth() async throws {
        installAsrPack("sv")
        let src = makeAudioFile("dup.wav", bytes: 32)
        let (ep, _) = makeEndpoints(session: helloSession(), decodeSamples: sine())
        let out1 = try await ep.transcribe(path: src.path, packId: nil, language: "auto",
                                           projectId: "p1", sessionId: "s1")
        let out2 = try await ep.transcribe(path: src.path, packId: nil, language: "auto",
                                           projectId: "p1", sessionId: "s1")
        let p1 = try XCTUnwrap(out1.saved_path)
        let p2 = try XCTUnwrap(out2.saved_path)
        XCTAssertNotEqual(p1, p2, "同名不覆盖：第二份须 -<8位hex> 后缀")
        XCTAssertTrue(URL(fileURLWithPath: p1).lastPathComponent == "dup.wav")
        let name2 = URL(fileURLWithPath: p2).lastPathComponent
        XCTAssertTrue(name2.hasPrefix("dup-"), name2)
        XCTAssertTrue(name2.hasSuffix(".wav"), name2)
        // 两份都真实存在（同名两份保留铁律）
        XCTAssertTrue(FileManager.default.fileExists(atPath: p1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: p2))
    }

    // MARK: - 辅助语义

    func testPyFormat0fBankers() {
        XCTAssertEqual(NativeAsrEndpoints.pyFormat0f(0.4), "0")
        XCTAssertEqual(NativeAsrEndpoints.pyFormat0f(0.5), "0")   // 五成双
        XCTAssertEqual(NativeAsrEndpoints.pyFormat0f(1.5), "2")
        XCTAssertEqual(NativeAsrEndpoints.pyFormat0f(2.5), "2")   // 五成双
        XCTAssertEqual(NativeAsrEndpoints.pyFormat0f(499.5), "500")
        XCTAssertEqual(NativeAsrEndpoints.pyFormat0f(500.5), "500")
        XCTAssertEqual(NativeAsrEndpoints.pyFormat0f(501.4), "501")
    }

    func testPyPathSuffixPathlibSemantics() {
        XCTAssertEqual(NativeAsrEndpoints.pyPathSuffix("/tmp/x.wav"), ".wav")
        XCTAssertEqual(NativeAsrEndpoints.pyPathSuffix("/tmp/X.WAV"), ".wav")   // lower
        XCTAssertEqual(NativeAsrEndpoints.pyPathSuffix("/tmp/.wav"), "")        // dotfile
        XCTAssertEqual(NativeAsrEndpoints.pyPathSuffix("/tmp/x."), "")          // 尾随点
        XCTAssertEqual(NativeAsrEndpoints.pyPathSuffix("/tmp/a.d/x"), "")       // 目录含点
        XCTAssertEqual(NativeAsrEndpoints.pyPathSuffix("/tmp/a.b.c"), ".c")     // 取末段
        XCTAssertEqual(NativeAsrEndpoints.pyPathSuffix("/tmp/noext"), "")
    }
}
