//
//  NativeAsrDriver.swift
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

//  逐行为移植（⛔ 只读行为规格源：subagent/sidecar/model_packs/asr_driver.py
//  L116-256 包解析与懒加载 / L511-546 对外 transcribe）：
//    · resolve_asr_pack（L118-149）：pack_id 缺省 = 注册表首个启用中 task=asr 包
//      （按 id 排序，确定性选择）；未装/非 asr/已禁用 → PackUnavailableError 中文
//      明细逐字（「一个都没装」与「装了但全被禁用」文案区分——指引动作不同）
//    · _pack_files（L152-183）：注册表 files[] 解析 (onnx, am.mvn, tokens.json)，
//      model_quant.onnx（INT8）首选；清单缺键/磁盘缺文件 → PackUnavailableError 逐字
//    · _ensure_loaded（L210-245）：懒加载 (session, tokens, cmvn, sample_rate)，
//      锁内单例按 pack_id 键控，换包即重载；manifest 可选键 sample_rate
//      （正整数才采纳，缺省 16000）
//    · unload（L248-256）：卸载＝释放 session；pack_id 不匹配时不动（防误卸）
//    · transcribe（L513-546）：resolve → 参数校验（language/textnorm ValueError）
//      → ensure_loaded → load_audio → fbank（0 帧 → 音频过短 422 文案）→
//      LFR+CMVN → ONNX 推理（锁内串行化，L540-542 同款）→ CTC 贪心 + 后处理
//      → {text, duration_s: round(·, 2), model_pack_id}
//
//  线程模型：NSLock 等价 threading.Lock（同进程内转写为用户节奏低频请求，
//  串行足够且规避 ORT 并发不确定性——Python 注释原意）。transcribe 本体为同步
//  CPU 密集函数，调用方（端点层）必须放后台任务（run_in_executor 同款纪律）。
//
//  推理缝：NativeAsrSenseVoiceSession 协议——生产 = dlopen ORT 会话适配器，
//  单测注入假会话（绝不要求真 dylib/真模型）。audioDecode 缝隔离 afconvert。
//

import Foundation

/// PackUnavailableError 等价物：ASR 模型包不可用（未安装/已禁用/缺文件/依赖缺失）——
/// 端点层转 409 中文明细给用户。
public struct NativeAsrPackUnavailableError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// ValueError 等价物：参数问题（language/textnorm 非法）——端点层转 400。
public struct NativeAsrValueError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// SenseVoice 推理会话缝（生产 = ORT 适配器；单测 = 假会话脚本化 logits）。
public protocol NativeAsrSenseVoiceSession: AnyObject {
    /// 喂 (1,T,560) f32 特征 + language/textnorm 码 → ctc_logits 行主序 (T',V) + 有效帧数。
    func runSenseVoice(speech: [Float], frames: Int,
                       language: Int32, textnorm: Int32) throws -> NativeAsrSenseVoiceOutput
}

public struct NativeAsrSenseVoiceOutput {
    /// ctc_logits 行主序 (outFrames, vocab)。
    public let logits: [Float]
    public let outFrames: Int
    public let vocab: Int
    /// encoder_out_lens（有效帧数，CTC 解码截断用）。
    public let outLen: Int
    public init(logits: [Float], outFrames: Int, vocab: Int, outLen: Int) {
        self.logits = logits
        self.outFrames = outFrames
        self.vocab = vocab
        self.outLen = outLen
    }
}

/// 生产会话适配器：NativeOnnxSession → SenseVoice 图契约
/// （funasr export_meta 核实，asr_driver L53-57 注释同款：
/// 输入 speech(B,T,560)f32 / speech_lengths(B,)i32 / language(B,)i32 / textnorm(B,)i32；
/// 输出 ctc_logits(B,T',V) / encoder_out_lens(B,)i32）。
public final class NativeOnnxSenseVoiceSession: NativeAsrSenseVoiceSession {
    private let session: NativeOnnxSession

    public init(session: NativeOnnxSession) {
        self.session = session
    }

    public func runSenseVoice(speech: [Float], frames: Int,
                              language: Int32, textnorm: Int32) throws -> NativeAsrSenseVoiceOutput {
        var speechBuf = speech
        var lengthsBuf: [Int32] = [Int32(frames)]
        var langBuf: [Int32] = [language]
        var normBuf: [Int32] = [textnorm]
        return try speechBuf.withUnsafeMutableBufferPointer { speechPtr in
            try lengthsBuf.withUnsafeMutableBufferPointer { lenPtr in
                try langBuf.withUnsafeMutableBufferPointer { langPtr in
                    try normBuf.withUnsafeMutableBufferPointer { normPtr in
                        let inputs = [
                            NativeOnnxSession.TensorInput(
                                name: "speech", shape: [1, Int64(frames), 560],
                                dataType: NativeOnnxSession.typeFloat,
                                byteCount: speech.count * 4, bytes: speechPtr.baseAddress!),
                            NativeOnnxSession.TensorInput(
                                name: "speech_lengths", shape: [1],
                                dataType: NativeOnnxSession.typeInt32,
                                byteCount: 4, bytes: lenPtr.baseAddress!),
                            NativeOnnxSession.TensorInput(
                                name: "language", shape: [1],
                                dataType: NativeOnnxSession.typeInt32,
                                byteCount: 4, bytes: langPtr.baseAddress!),
                            NativeOnnxSession.TensorInput(
                                name: "textnorm", shape: [1],
                                dataType: NativeOnnxSession.typeInt32,
                                byteCount: 4, bytes: normPtr.baseAddress!),
                        ]
                        let outs = try session.run(inputs: inputs,
                                                   outputNames: ["ctc_logits", "encoder_out_lens"])
                        guard outs.count == 2, outs[0].shape.count == 3 else {
                            throw NativeOnnxRuntimeError(
                                "ONNX 推理输出形状异常（期望 ctc_logits 三维 + encoder_out_lens）")
                        }
                        let outFrames = Int(outs[0].shape[1])
                        let vocab = Int(outs[0].shape[2])
                        let outLen = Int(outs[1].int32s.first ?? Int32(outFrames))
                        return NativeAsrSenseVoiceOutput(
                            logits: outs[0].floats, outFrames: outFrames,
                            vocab: vocab, outLen: outLen)
                    }
                }
            }
        }
    }
}

/// 会话工厂缝（生产 = dlopen ORT；单测注入假工厂——绝不要求真 dylib/真模型）。
public protocol NativeAsrSessionFactory: Sendable {
    func makeSession(onnxPath: URL) throws -> any NativeAsrSenseVoiceSession
}

/// 生产工厂：NativeOnnxRuntime.createSession → SenseVoice 适配器。
public struct NativeOnnxSenseVoiceSessionFactory: NativeAsrSessionFactory {
    public let rt: NativeOnnxRuntime
    public init(rt: NativeOnnxRuntime) { self.rt = rt }
    public func makeSession(onnxPath: URL) throws -> any NativeAsrSenseVoiceSession {
        NativeOnnxSenseVoiceSession(session: try rt.createSession(modelPath: onnxPath))
    }
}

public final class NativeAsrDriver: @unchecked Sendable {

    /// language 码表（L107，插入序即错误文案 join 序，勿动）。
    public static let langIds: [(String, Int32)] = [
        ("auto", 0), ("zh", 3), ("en", 4), ("yue", 7), ("ja", 11), ("ko", 12), ("nospeech", 13),
    ]
    /// textnorm 码表（L108 同款）。
    public static let textnormIds: [(String, Int32)] = [("withitn", 14), ("woitn", 15)]

    public let store: NativeModelPackStore
    public var environment: [String: String]
    public var dataRootProvider: @Sendable () -> URL
    /// 冻结包内 Resources 候选（生产 = Bundle.main.resourceURL；测试注入 nil/临时目录）。
    public var bundleResourceURL: URL?
    /// 会话工厂供给缝（默认 = 三态解析 + dlopen ORT；单测注入假工厂）。
    public var sessionFactoryProvider: @Sendable () throws -> any NativeAsrSessionFactory
    /// 音频解码缝（默认 afconvert 链；单测注入固定波形）。
    public var decodeAudio: @Sendable (URL, Int) throws -> (samples: [Float], durationS: Double) = {
        path, sr in try NativeAsrFeatures.loadAudio(path, targetSampleRate: sr)
    }
    /// fbank dither 噪声缝（测试复现金样；nil = 生产高斯随机）。
    public var ditherNoise: [Double]?
    public var log: @Sendable (String) -> Void = { _ in }

    private struct Loaded {
        var packId: String
        var session: any NativeAsrSenseVoiceSession
        var tokens: [String]
        var cmvn: NativeAsrCmvn
        var sampleRate: Int
    }
    /// 懒加载单例（L112-113 _state 同款：按 pack_id 键控，换包重载）。
    private var state: Loaded?
    private let lock = NSLock()

    public init(store: NativeModelPackStore,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                dataRootProvider: @escaping @Sendable () -> URL,
                bundleResourceURL: URL? = Bundle.main.resourceURL) {
        self.store = store
        self.environment = environment
        self.dataRootProvider = dataRootProvider
        self.bundleResourceURL = bundleResourceURL
        // 默认供给：三态解析（bundle > env > dataRoot，P3-W6④ 翻转）+ dlopen
        // （参数按值捕获，不持 self——Sendable 干净）
        self.sessionFactoryProvider = {
            let dylib = try NativeOnnxRuntime.resolveDylib(
                environment: environment, dataRootProvider: dataRootProvider,
                bundleResourceURL: bundleResourceURL)
            let rt = try NativeOnnxRuntime.load(path: dylib)
            return NativeOnnxSenseVoiceSessionFactory(rt: rt)
        }
    }

    // ══════════════ 包解析（L118-149）══════════════

    /// resolve_asr_pack：pack_id 缺省 → 注册表首个启用中 task=asr 包（按 id 排序）。
    public func resolveAsrPack(_ packId: String? = nil) throws -> String {
        let reg = store.readRegistry()
        if let packId {
            guard let entry = reg[packId] else {
                throw NativeAsrPackUnavailableError(
                    "模型包 \(PySem.reprString(packId)) 未安装。请到「模型包」面板安装语音识别模型包。")
            }
            guard entry["task"]?.string == "asr" else {
                let taskRepr = entry["task"].map { PySem.repr($0) } ?? "None"
                throw NativeAsrPackUnavailableError(
                    "模型包 \(PySem.reprString(packId)) 不是语音识别包（task=\(taskRepr)），"
                    + "请检查 catalog 清单。")
            }
            guard entry["status"]?.string == "installed" else {
                throw NativeAsrPackUnavailableError(
                    "模型包 \(PySem.reprString(packId)) 已禁用。请到「模型包」面板启用后再转写。")
            }
            return packId
        }
        let candidates = reg.keys
            .filter { reg[$0]?["task"]?.string == "asr" && reg[$0]?["status"]?.string == "installed" }
            .sorted()
        guard let first = candidates.first else {
            if reg.values.contains(where: { $0["task"]?.string == "asr" }) {
                throw NativeAsrPackUnavailableError(
                    "语音识别模型包已安装但全部被禁用。请到「模型包」面板启用后再转写。")
            }
            throw NativeAsrPackUnavailableError(
                "尚未安装语音识别模型包。请到「模型包」面板安装一个 ASR 模型包"
                + "（如 SenseVoiceSmall）后再试。")
        }
        return first
    }

    /// _pack_files（L152-183）：注册表 files[] 解析 (onnx, am.mvn, tokens.json)；缺一即拒。
    public func packFiles(_ packId: String) throws -> (onnx: URL, cmvn: URL, tokens: URL) {
        let entry = store.getEntry(packId) ?? [:]
        let base: URL
        do { base = try store.packDir(packId) } catch {
            // pack_dir 的非法 pack_id（store.py L82 ValueError）——ASR 语义归为包不可用
            throw NativeAsrPackUnavailableError(
                (error as? NativeModelPackError)?.message ?? "非法 pack_id: \(packId)")
        }
        let files = entry["files"]?.array ?? []
        var onnxRel = ""
        for f in files {
            let p = f.object?["path"].map(WFText.pyStr) ?? ""
            if p == "model_quant.onnx" { onnxRel = p; break }   // INT8 首选（官方仓只发这个）
            if p.lowercased().hasSuffix(".onnx"), onnxRel.isEmpty { onnxRel = p }
        }
        var rels: [(key: String, rel: String)] = [("onnx", onnxRel)]
        for want in ["am.mvn", "tokens.json"] {
            var rel = ""
            for f in files {
                let p = f.object?["path"].map(WFText.pyStr) ?? ""
                if p == want || p.hasSuffix("/" + want) { rel = p; break }
            }
            rels.append((want, rel))
        }
        let missingKeys = rels.filter { $0.rel.isEmpty }.map(\.key)
        guard missingKeys.isEmpty else {
            throw NativeAsrPackUnavailableError(
                "模型包 \(PySem.reprString(packId)) 清单缺文件（\(missingKeys.joined(separator: ", "))），"
                + "SenseVoiceSmall 包须含 model_quant.onnx（或 .onnx）/ am.mvn / tokens.json。")
        }
        let paths = rels.map { base.appendingPathComponent($0.rel) }
        let missingDisk = paths.filter {
            var isDir: ObjCBool = false
            return !(FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDir)
                     && !isDir.boolValue)
        }.map { $0.lastPathComponent }
        guard missingDisk.isEmpty else {
            throw NativeAsrPackUnavailableError(
                "模型包 \(PySem.reprString(packId)) 的文件在磁盘上缺失: \(missingDisk.joined(separator: ", "))"
                + "（安装不完整或被手动删除），请到「模型包」面板重新安装。")
        }
        return (paths[0], paths[1], paths[2])
    }

    // ══════════════ 懒加载（L210-245）/ 卸载（L248-256）══════════════

    private func ensureLoaded(_ packId: String) throws -> Loaded {
        lock.lock()
        defer { lock.unlock() }
        if let s = state, s.packId == packId { return s }
        let (onnxPath, cmvnPath, tokensPath) = try packFiles(packId)
        // ORT 依赖（L216-220 ImportError → 「ASR 依赖缺失」同款语义）：
        // 三态解析/dlopen 失败 → 依赖缺失明细
        let factory: any NativeAsrSessionFactory
        do {
            factory = try sessionFactoryProvider()
        } catch let e as NativeOnnxRuntimeError {
            throw NativeAsrPackUnavailableError("ASR 依赖缺失: \(e.message)")
        } catch {
            throw NativeAsrPackUnavailableError("ASR 依赖缺失: \(error.localizedDescription)")
        }
        // ONNX 模型加载（L224-228；createSession 已带「ONNX 模型加载失败: <名>」前缀）
        let session: any NativeAsrSenseVoiceSession
        do {
            session = try factory.makeSession(onnxPath: onnxPath)
        } catch let e as NativeOnnxRuntimeError {
            throw NativeAsrPackUnavailableError(e.message)
        } catch let e as NativeAsrPackUnavailableError {
            throw e
        } catch {
            throw NativeAsrPackUnavailableError(
                "ONNX 模型加载失败: \(onnxPath.lastPathComponent): \(error.localizedDescription)")
        }
        // tokens.json（L229-235）：读/解析失败 → 「tokens.json 解析失败: …」；
        // 非非空字符串数组 → 「tokens.json 须为非空字符串数组（SenseVoice 词表）」
        let tokensParsed: JSONValue
        do {
            let data = try Data(contentsOf: tokensPath)
            guard let v = NativeJSONWriter.loads(data) else {
                // 微差：Python JSONDecodeError 含行列号，原生 JSON 解析器不产——
                // 归一为「非法 JSON」后缀（形态对齐，不逐字）
                throw NativeAsrPackUnavailableError("tokens.json 解析失败: 非法 JSON")
            }
            tokensParsed = v
        } catch let e as NativeAsrPackUnavailableError {
            throw e
        } catch {
            throw NativeAsrPackUnavailableError("tokens.json 解析失败: \(error.localizedDescription)")
        }
        guard case .array(let arr) = tokensParsed,
              !arr.isEmpty,
              arr.allSatisfy({ if case .string = $0 { return true } else { return false } }) else {
            throw NativeAsrPackUnavailableError("tokens.json 须为非空字符串数组（SenseVoice 词表）")
        }
        let tokens = arr.compactMap { $0.string }
        // am.mvn（L236 + L186-207）
        guard let cmvnText = try? String(contentsOf: cmvnPath, encoding: .utf8),
              let cmvn = NativeAsrCmvn.parse(cmvnText) else {
            throw NativeAsrPackUnavailableError("am.mvn 解析失败（缺 AddShift/Rescale 段）: \(cmvnPath.path)")
        }
        // manifest 可选键 sample_rate（L237-240：正整数非 bool 才采纳，缺省 16000）
        var sr = NativeAsrFeatures.sampleRateDefault
        if let manSr = store.readManifest(packId)["sample_rate"],
           PySem.isInt(manSr, boolOk: false), case .int(let n) = manSr, n > 0 {
            sr = Int(n)
        }
        let loaded = Loaded(packId: packId, session: session, tokens: tokens,
                            cmvn: cmvn, sampleRate: sr)
        state = loaded
        log("ASR 模型已加载: pack=\(packId) onnx=\(onnxPath.lastPathComponent)")
        return loaded
    }

    /// unload（L248-256）：卸载＝释放 session（D6）。pack_id 不匹配时不动（防误卸正在用的包）。
    @discardableResult
    public func unload(_ packId: String? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let s = state else { return false }
        if let packId, s.packId != packId { return false }
        state = nil
        return true
    }

    /// 当前装载的包 id（状态面/测试观测用；Python _state["pack_id"] 等价）。
    public var loadedPackId: String? {
        lock.lock()
        defer { lock.unlock() }
        return state?.packId
    }

    // ══════════════ 对外 API（L513-546）══════════════

    public struct TranscribeResult {
        public let text: String
        public let durationS: Double
        public let modelPackId: String
    }

    /// transcribe：同步、CPU 密集——调用方（端点层）必须放后台任务
    /// （run_in_executor 同款纪律），不得直接在事件循环/主线程里调。
    public func transcribe(path: URL, packId: String? = nil,
                           language: String = "auto", textnorm: String = "withitn") throws -> TranscribeResult {
        let pid = try resolveAsrPack(packId)
        guard let langId = Self.langIds.first(where: { $0.0 == language })?.1 else {
            throw NativeAsrValueError(
                "language 必须是 \(Self.langIds.map(\.0).joined(separator: "/")) 之一，"
                + "得到 \(PySem.reprString(language))")
        }
        guard let normId = Self.textnormIds.first(where: { $0.0 == textnorm })?.1 else {
            throw NativeAsrValueError(
                "textnorm 必须是 \(Self.textnormIds.map(\.0).joined(separator: "/")) 之一，"
                + "得到 \(PySem.reprString(textnorm))")
        }
        let loaded = try ensureLoaded(pid)
        let (waveform, durationS) = try decodeAudio(path, loaded.sampleRate)
        let fbank = NativeAsrFeatures.fbank(waveform: waveform, sampleRate: loaded.sampleRate,
                                            ditherNoise: ditherNoise)
        let fbankFrames = fbank.count / NativeAsrFeatures.nMels
        guard fbankFrames > 0 else {
            throw NativeAsrAudioDecodeError("音频过短（不足一帧 25ms），无法转写")
        }
        let lfr = NativeAsrFeatures.applyLfr(feat: fbank, frames: fbankFrames)
        let lfrFrames = Self.lfrFramesCount(fbankFrames)
        let cmvned = NativeAsrFeatures.applyCmvn(feat: lfr, dim: NativeAsrFeatures.nMels * NativeAsrFeatures.lfrM,
                                                 cmvn: loaded.cmvn)
        let speech = cmvned.map { Float($0) }   // astype(float32)（L533 同款）
        // ORT session.run 串行化（L540-542：转写是用户节奏的低频请求，串行足够）
        lock.lock()
        let output: NativeAsrSenseVoiceOutput
        do {
            output = try loaded.session.runSenseVoice(speech: speech, frames: lfrFrames,
                                                      language: langId, textnorm: normId)
        } catch {
            lock.unlock()
            throw error
        }
        lock.unlock()
        let text = NativeAsrPostprocess.ctcGreedyDecode(
            logits: output.logits, frames: output.outFrames, vocab: output.vocab,
            outLen: output.outLen, tokens: loaded.tokens)
        return TranscribeResult(
            text: NativeAsrPostprocess.richTranscriptionPostprocess(text),
            durationS: Self.pyRound2(durationS),
            modelPackId: pid)
    }

    /// ceil(T / lfrN)（apply_lfr 的 T_lfr；公开给驱动内推理帧数）。
    static func lfrFramesCount(_ fbankFrames: Int) -> Int {
        Int(ceil(Double(fbankFrames) / Double(NativeAsrFeatures.lfrN)))
    }

    /// Python round(x, 2)：银行家舍入（round-half-even），2 位小数。
    static func pyRound2(_ x: Double) -> Double {
        let scaled = x * 100.0
        let floor = scaled.rounded(.down)
        let frac = scaled - floor
        var r: Double
        if frac < 0.5 { r = floor }
        else if frac > 0.5 { r = floor + 1 }
        else { r = floor.truncatingRemainder(dividingBy: 2) == 0 ? floor : floor + 1 }
        return r / 100.0
    }
}
