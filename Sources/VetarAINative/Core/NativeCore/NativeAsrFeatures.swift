//
//  NativeAsrFeatures.swift
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
//  L259-422）：
//    · 解码（L295-338）：macOS 一律 afconvert 子进程转 16kHz 单声道 PCM16 WAV
//      （tempdir + 120s 超时护栏；成败以产物文件 >44B 为准，不轻信 exit code）；
//      _read_wav_pcm 支持 8/16/32bit PCM + 多声道均值（直读兜底面，macOS 主链
//      产出恒为单声道 LEI16）
//    · fbank（L367-393）：kaldi_native_fbank 纯 numpy 移植的再移植——波形 ×32768
//      到 int16 刻度 → dither(高斯×1.0) → 去直流 → 预加重 0.97 → hamming(400)
//      → 补零 512 → rfft 功率谱 → 80 维 HTK 三角 mel（1127·ln(1+f/700)，
//      low=20Hz，high=Nyquist）→ log(max(·, FLT_EPSILON))；snip_edges 帧数
//      1+(N-400)//160
//    · mel 滤波器组（L348-364）：knf InitKaldiMelBanks 逐行（mel 域线性、无归一化）
//    · LFR(7,6)（L396-415）：左端首帧复制 3 行，末帧不足以末帧补齐
//    · CMVN（L418-422）：(x + means) × vars（float64 域；喂模型前才落 float32）
//    · am.mvn 解析（L186-207）：<AddShift>/<Rescale> 各行 <LearnRateCoef> 行
//      取第 3 列到倒数第 1 列
//
//  数值口径：全管线 Double（float64）对齐 numpy；fbank 出口落 Float32（Python
//  astype(float32) 同款），CMVN 在 float64 域计算（Python float32+float64→float64
//  同款）。金样逐阶段比对（预加重后波形 / 功率谱 / mel 谱 / LFR+CMVN 后特征，
//  max abs diff < 1e-4）见 NativeAsrFeatureGoldenTests。dither 是高斯随机——
//  金样比对经 ditherNoise 缝注入 numpy 同款噪声矩阵复现，生产用系统 RNG。
//

import Foundation
import Accelerate

/// 音频解码失败（asr_driver.AudioDecodeError 等价物；message 一律中文）。
public struct NativeAsrAudioDecodeError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public enum NativeAsrFeatures {

    // ═══════════ SenseVoiceSmall 固定参数（asr_driver L96-108 逐字，勿凭直觉改）═══════════
    public static let sampleRateDefault = 16000
    public static let frameLen = 400            // 25ms @16k
    public static let frameShift = 160          // 10ms @16k
    public static let nFFT = 512                // 补零到 2 的幂（knf round_to_power_of_two）
    public static let nMels = 80
    public static let preemph = 0.97
    public static let ditherScale = 1.0         // WavFrontend 缺省；knf 语义：高斯噪声×系数
    public static let melLowFreq = 20.0         // knf MelBanksOptions 缺省
    public static let lfrM = 7
    public static let lfrN = 6
    /// np.finfo(np.float32).eps（L392 的 log 下限）。
    public static let float32Eps: Double = 1.1920928955078125e-07

    // ══════════════ 音频解码（16kHz 单声道 float32[-1,1]）══════════════

    /// shutil.which("afconvert")：PATH 逐目录找可执行文件。
    public static func whichAfconvert(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let pathVar = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for dir in pathVar.split(separator: ":") {
            let p = "\(dir)/afconvert"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// _read_wav_pcm（L261-281）：stdlib wave 读 PCM WAV → (float32[-1,1] 单声道, 采样率)。
    /// 非 PCM/损坏 → AudioDecodeError。多声道均值在 float32 域（numpy 同款）。
    public static func readWavPcm(_ path: URL) throws -> (samples: [Float], sampleRate: Int) {
        let data: Data
        do { data = try Data(contentsOf: path) } catch {
            throw NativeAsrAudioDecodeError("WAV 读取失败（文件损坏或非 PCM 编码）: \(error.localizedDescription)")
        }
        guard data.count >= 44 else {
            throw NativeAsrAudioDecodeError("WAV 读取失败（文件损坏或非 PCM 编码）: 文件过短（\(data.count)B）")
        }
        let bytes = [UInt8](data)
        func ascii(_ range: Range<Int>) -> String {
            String(decoding: bytes[range], as: UTF8.self)
        }
        func u32(_ off: Int) -> UInt32 {
            UInt32(bytes[off]) | UInt32(bytes[off + 1]) << 8
                | UInt32(bytes[off + 2]) << 16 | UInt32(bytes[off + 3]) << 24
        }
        func u16(_ off: Int) -> Int {
            Int(UInt16(bytes[off]) | UInt16(bytes[off + 1]) << 8)
        }
        guard ascii(0..<4) == "RIFF", ascii(8..<12) == "WAVE" else {
            throw NativeAsrAudioDecodeError("WAV 读取失败（文件损坏或非 PCM 编码）: 缺 RIFF/WAVE 头")
        }
        // chunk 遍历：fmt 拿格式，data 拿负载（afconvert 可能夹带其他 chunk）
        var off = 12
        var audioFormat = 0, channels = 0, sampleRate = 0, bitsPerSample = 0
        var pcmRange: Range<Int>?
        while off + 8 <= bytes.count {
            let tag = ascii(off..<(off + 4))
            let size = Int(u32(off + 4))
            let body = off + 8
            guard body + size <= bytes.count else { break }
            if tag == "fmt " {
                guard size >= 16 else { break }
                audioFormat = u16(body)
                channels = u16(body + 2)
                sampleRate = Int(u32(body + 4))
                bitsPerSample = u16(body + 14)
            } else if tag == "data" {
                pcmRange = body..<(body + size)
            }
            off = body + size + (size & 1)   // RIFF chunk 偶对齐
        }
        guard audioFormat == 1, channels > 0, let range = pcmRange else {
            throw NativeAsrAudioDecodeError("WAV 读取失败（文件损坏或非 PCM 编码）: 非 PCM 或缺 data chunk")
        }
        let raw = Array(bytes[range])
        var arr: [Float]
        switch bitsPerSample {
        case 16:
            arr = stride(from: 0, to: raw.count - raw.count % 2, by: 2).map { i in
                let v = Int16(bitPattern: UInt16(raw[i]) | UInt16(raw[i + 1]) << 8)
                return Float(v) / 32768.0
            }
        case 32:
            arr = stride(from: 0, to: raw.count - raw.count % 4, by: 4).map { i in
                let v = Int32(bitPattern: UInt32(raw[i]) | UInt32(raw[i + 1]) << 8
                    | UInt32(raw[i + 2]) << 16 | UInt32(raw[i + 3]) << 24)
                return Float(v) / 2147483648.0
            }
        case 8:
            arr = raw.map { (Float($0) - 128.0) / 128.0 }
        default:
            throw NativeAsrAudioDecodeError("不支持的 WAV 位深（\(bitsPerSample)bit），请转 16bit PCM")
        }
        if channels > 1 {
            let frames = arr.count / channels
            var mono = [Float](repeating: 0, count: frames)
            for f in 0..<frames {
                var acc: Float = 0
                for c in 0..<channels { acc += arr[f * channels + c] }
                mono[f] = acc / Float(channels)
            }
            arr = mono
        }
        return (arr, sampleRate)
    }

    /// _decode_via_afconvert（L295-317）：系统 afconvert 统一转 PCM16 WAV。
    /// 外部系统进程 + 超时护栏；成败以产物文件为准，不轻信 exit code。
    /// - Parameter runner: 子进程缝（测试注入假进程，绝不要求真 afconvert）。
    public static func decodeViaAfconvert(
        _ path: URL, targetSampleRate: Int,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        runner: (String, [String], URL) throws -> Bool = defaultAfconvertRunner
    ) throws -> [Float] {
        guard let afconvert = whichAfconvert(environment: environment) else {
            throw NativeAsrAudioDecodeError("系统缺少 afconvert（非 macOS？），该音频格式无法解码")
        }
        let td = FileManager.default.temporaryDirectory
            .appendingPathComponent("asr_dec_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: td) }
        try FileManager.default.createDirectory(at: td, withIntermediateDirectories: true)
        let out = td.appendingPathComponent("out.wav")
        let ok = try runner(afconvert,
                            ["-f", "WAVE", "-d", "LEI16@\(targetSampleRate)", "-c", "1",
                             path.path, out.path], out)
        guard ok, FileManager.default.fileExists(atPath: out.path),
              let size = try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int,
              size > 44 else {
            throw NativeAsrAudioDecodeError(
                "音频解码失败：该格式不受支持或文件已损坏"
                + "（支持 wav/mp3/m4a/aac/aiff/caf/flac；webm/ogg/opus 请先转 wav 或 m4a）")
        }
        let (samples, _) = try readWavPcm(out)
        return samples
    }

    /// 生产 afconvert 执行体：120s 超时（L309 TimeoutExpired → 「音频解码超时（120s）」）；
    /// 启动失败（OSError 等价）→ 「无法启动 afconvert: …」。返回 true = 进程正常结束。
    public static func defaultAfconvertRunner(_ exe: String, _ args: [String], _ out: URL) throws -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch {
            throw NativeAsrAudioDecodeError("无法启动 afconvert: \(error.localizedDescription)")
        }
        let deadline = Date().addingTimeInterval(120)
        while proc.isRunning {
            if Date() >= deadline {
                proc.terminate()
                throw NativeAsrAudioDecodeError("音频解码超时（120s）")
            }
            usleep(50_000)
        }
        return true
    }

    /// load_audio（L320-338）：macOS 一律 afconvert；空波形 → AudioDecodeError。
    public static func loadAudio(_ path: URL, targetSampleRate: Int = sampleRateDefault,
                                 environment: [String: String] = ProcessInfo.processInfo.environment,
                                 runner: (String, [String], URL) throws -> Bool = defaultAfconvertRunner
    ) throws -> (samples: [Float], durationS: Double) {
        let arr = try decodeViaAfconvert(path, targetSampleRate: targetSampleRate,
                                         environment: environment, runner: runner)
        if arr.isEmpty {
            throw NativeAsrAudioDecodeError("音频内容为空（0 采样点）")
        }
        return (arr, Double(arr.count) / Double(targetSampleRate))
    }

    // ══════════════ 特征：kaldi fbank 移植（knf csrc 逐行对照）══════════════

    /// HTK mel（L343-345：knf MelBanks::MelScale；is_librosa=false 的 kaldi 默认路径）。
    public static func melScale(_ freq: Double) -> Double {
        1127.0 * log(1.0 + freq / 700.0)
    }

    /// (n_mels, n_fft/2) 三角 mel 权重（L348-364 逐行：mel 域线性、无归一化、
    /// low=20Hz、high=Nyquist；行主序 [b*256+i]）。
    public static func melFilterbank(sampleRate: Int) -> [Double] {
        let nBins = nFFT / 2
        let nyq = 0.5 * Double(sampleRate)
        let melLo = melScale(melLowFreq), melHi = melScale(nyq)
        let delta = (melHi - melLo) / Double(nMels + 1)
        let fftBinWidth = Double(sampleRate) / Double(nFFT)
        var fb = [Double](repeating: 0, count: nMels * nBins)
        for b in 0..<nMels {
            let lm = melLo + Double(b) * delta
            let cm = melLo + Double(b + 1) * delta
            let rm = melLo + Double(b + 2) * delta
            for i in 0..<nBins {
                let mel = melScale(fftBinWidth * Double(i))
                if lm < mel && mel < rm {
                    fb[b * nBins + i] = mel <= cm ? (mel - lm) / (cm - lm) : (rm - mel) / (rm - cm)
                }
            }
        }
        return fb
    }

    /// 生产 dither：Box-Muller 高斯（均值 0 方差 1）× ditherScale。
    /// numpy standard_normal 数值不可复现（Mersenne Twister），金样比对走注入缝。
    public static func gaussianNoise(count: Int,
                                     rng: inout SystemRandomNumberGenerator) -> [Double] {
        var out = [Double](repeating: 0, count: count)
        var i = 0
        while i < count {
            let u1 = max(Double.random(in: 0..<1, using: &rng), .ulpOfOne)
            let u2 = Double.random(in: 0..<1, using: &rng)
            let r = (-2.0 * log(u1)).squareRoot()
            out[i] = r * cos(2.0 * .pi * u2) * ditherScale
            if i + 1 < count { out[i + 1] = r * sin(2.0 * .pi * u2) * ditherScale }
            i += 2
        }
        return out
    }

    /// fbank（L367-393）：波形 → log-mel fbank (T, 80)，行主序 Float32。
    /// - Parameters:
    ///   - ditherNoise: 测试缝——注入 (T,400) 行主序噪声矩阵（金样复现 numpy
    ///     standard_normal）；nil = 生产高斯随机。
    ///   - stages: 测试缝——非 nil 时填充中间阶段（预加重后波形/加窗后/功率谱），
    ///     供金样逐阶段比对；生产 nil 零开销。
    public static func fbank(
        waveform: [Float], sampleRate: Int = sampleRateDefault,
        ditherNoise: [Double]? = nil,
        stages: NativeAsrFbankStages? = nil
    ) -> [Float] {
        // wave_i16（L375：×32768 到 int16 刻度——knf 按 int16 幅值约定处理）
        let waveI16 = waveform.map { Double($0) * 32768.0 }
        let n = waveI16.count
        guard n >= frameLen else { return [] }   // L377-378：(0, 80) 空特征
        let nFrames = 1 + (n - frameLen) / frameShift   // snip_edges=True（L379）
        // 分帧 + dither + 去直流 + 预加重 + 加窗（L380-389 顺序勿动）
        let noise = ditherNoise ?? {
            var rng = SystemRandomNumberGenerator()
            return gaussianNoise(count: nFrames * frameLen, rng: &rng)
        }()
        var frames = [Double](repeating: 0, count: nFrames * frameLen)
        for t in 0..<nFrames {
            let base = t * frameShift
            for i in 0..<frameLen {
                frames[t * frameLen + i] = waveI16[base + i] + noise[t * frameLen + i]
            }
            // 去直流（L385 remove_dc_offset）
            var mean = 0.0
            for i in 0..<frameLen { mean += frames[t * frameLen + i] }
            mean /= Double(frameLen)
            for i in 0..<frameLen { frames[t * frameLen + i] -= mean }
            // 预加重（L386-387：x[1:] -= 0.97*x[:-1]（用原值副本）；x[0] *= 0.03）
            var prev = frames[t * frameLen]
            frames[t * frameLen] *= (1.0 - preemph)
            for i in 1..<frameLen {
                let cur = frames[t * frameLen + i]
                frames[t * frameLen + i] = cur - preemph * prev
                prev = cur
            }
        }
        stages?.preemphasisFrames = frames
        // hamming 窗（L388：0.54 - 0.46*cos(2πi/(400-1))，float64 手工算——
        // 不用 vDSP_hamm_window，免定义漂移）
        var ham = [Double](repeating: 0, count: frameLen)
        for i in 0..<frameLen {
            ham[i] = 0.54 - 0.46 * cos(2.0 * .pi * Double(i) / Double(frameLen - 1))
        }
        for t in 0..<nFrames {
            for i in 0..<frameLen { frames[t * frameLen + i] *= ham[i] }
        }
        stages?.windowedFrames = frames
        // rfft 功率谱（L390：补零 512 → |rfft|²，取前 257 维）
        let power = powerSpectrum(frames: frames, nFrames: nFrames, stages: stages)
        // 80 维 mel（L391：power[:, :256] @ filterbank.T）
        let fb = melFilterbank(sampleRate: sampleRate)
        let nBins = nFFT / 2
        // ⚠️ power 行宽 257（含 Nyquist），mmul 要求 A 密集 (T×256)——先裁列压实
        // （numpy power[:, :256] 显式切片的等价物；否则第 2 行起逐行错位 1 元素）
        var power256 = [Double](repeating: 0, count: nFrames * nBins)
        for t in 0..<nFrames {
            power256[(t * nBins)..<((t + 1) * nBins)] =
                power[(t * (nBins + 1))..<(t * (nBins + 1) + nBins)]
        }
        // vDSP_mmulD 无转置-B 形态：C(T×80)=power256(T×256)×fbT(256×80)——先转置滤波器组
        var fbT = [Double](repeating: 0, count: nMels * nBins)
        for b in 0..<nMels {
            for i in 0..<nBins { fbT[i * nMels + b] = fb[b * nBins + i] }
        }
        var mel = [Double](repeating: 0, count: nFrames * nMels)
        // mel[t, b] = Σ_i power[t, i] * fb[b, i]（float64 域）
        vDSP_mmulD(power256, 1, fbT, 1, &mel, 1,
                   vDSP_Length(nFrames), vDSP_Length(nMels), vDSP_Length(nBins))
        // log(max(·, FLT_EPSILON)) → float32（L392-393）
        var out = [Float](repeating: 0, count: nFrames * nMels)
        for idx in 0..<(nFrames * nMels) {
            out[idx] = Float(log(max(mel[idx], float32Eps)))
        }
        stages?.fbankLogMel = out
        return out
    }

    /// rfft 功率谱 (T, 257) 行主序（vDSP 实数 FFT，float64）。
    /// ⚠️ vDSP zrip 实数 FFT 输出 = 2× 数学 DFT（Accelerate 文档口径），统一 ×0.5 归一——
    /// 金样功率谱阶段比对（容差 1e-4）钉死该系数，勿凭直觉删。
    private static func powerSpectrum(frames: [Double], nFrames: Int,
                                      stages: NativeAsrFbankStages?) -> [Double] {
        let log2n = vDSP_Length(9)   // 512 = 2^9
        guard let setup = vDSP_create_fftsetupD(log2n, FFTRadix(FFT_RADIX2)) else {
            return []   // 不可达（512 恒合法）；防御空特征由上游帧数门禁兜住
        }
        defer { vDSP_destroy_fftsetupD(setup) }
        let half = nFFT / 2   // 256
        var power = [Double](repeating: 0, count: nFrames * (half + 1))
        var realp = [Double](repeating: 0, count: half)
        var imagp = [Double](repeating: 0, count: half)
        var frame512 = [Double](repeating: 0, count: nFFT)
        frames.withUnsafeBufferPointer { srcBuf in
            let srcBase = srcBuf.baseAddress!
            realp.withUnsafeMutableBufferPointer { rBuf in
                imagp.withUnsafeMutableBufferPointer { iBuf in
                    var split = DSPDoubleSplitComplex(realp: rBuf.baseAddress!,
                                                      imagp: iBuf.baseAddress!)
                    for t in 0..<nFrames {
                        // 帧（400）拷进 512 补零缓冲（400 之后恒零——缓冲初始零且只写前 400）
                        frame512.withUnsafeMutableBufferPointer { fBuf in
                            fBuf.baseAddress!.assign(from: srcBase + t * frameLen, count: frameLen)
                            // 512 实数 → 256 复数（ctoz 偶奇交织）
                            fBuf.baseAddress!.withMemoryRebound(to: DSPDoubleComplex.self,
                                                                capacity: half) { cbuf in
                                vDSP_ctozD(cbuf, 2, &split, 1, vDSP_Length(half))
                            }
                        }
                    vDSP_fft_zripD(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    // 功率谱：bin0=realp[0]（DC），bin256=imagp[0]（Nyquist），
                    // bins 1...255=(realp[k], imagp[k])；zrip 输出 2× DFT → 平方后 ×0.25
                    let base = t * (half + 1)
                    power[base] = rBuf.baseAddress![0] * rBuf.baseAddress![0] * 0.25
                    for k in 1..<half {
                        let re = rBuf.baseAddress![k], im = iBuf.baseAddress![k]
                        power[base + k] = (re * re + im * im) * 0.25
                    }
                    power[base + half] = iBuf.baseAddress![0] * iBuf.baseAddress![0] * 0.25
                }
            }
        }
        }
        stages?.powerSpectrum = power
        return power
    }

    /// apply_lfr（L396-415）：低帧率堆叠 m=7/n=6。
    /// 左端以首帧复制 (m-1)//2=3 行，末帧不足以末帧逐条补齐。入/出均为行主序。
    public static func applyLfr(feat: [Float], frames: Int, dim: Int = nMels) -> [Float] {
        guard frames > 0 else { return [] }
        let tLfr = Int(ceil(Double(frames) / Double(lfrN)))
        let leftPad = (lfrM - 1) / 2
        // padded = [feat[0] × leftPad] + feat
        var padded = [Float](repeating: 0, count: (frames + leftPad) * dim)
        for r in 0..<leftPad {
            padded[(r * dim)..<((r + 1) * dim)] = feat[0..<dim]
        }
        padded[(leftPad * dim)..<((leftPad + frames) * dim)] = feat[0..<(frames * dim)]
        let tPad = frames + leftPad
        var out = [Float](repeating: 0, count: tLfr * lfrM * dim)
        for i in 0..<tLfr {
            let start = i * lfrN
            let dst = i * lfrM * dim
            if lfrM <= tPad - start {
                // 完整窗口：padded[start ..< start+m] 拉平
                out[dst..<(dst + lfrM * dim)] = padded[(start * dim)..<((start + lfrM) * dim)]
            } else {
                // 尾帧不足：已有行拉平后，以末帧逐条补齐（L409-413 逐行）
                let avail = tPad - start
                out[dst..<(dst + avail * dim)] = padded[(start * dim)..<(tPad * dim)]
                for p in 0..<(lfrM - avail) {
                    out[(dst + (avail + p) * dim)..<(dst + (avail + p + 1) * dim)] =
                        padded[((tPad - 1) * dim)..<(tPad * dim)]
                }
            }
        }
        return out
    }

    /// apply_cmvn（L418-422）：(x + means) × vars，float64 域（Python float32+float64
    /// → float64 同款）；喂 ONNX 前由调用方落 float32（asr_driver L533 astype 同款）。
    public static func applyCmvn(feat: [Float], dim: Int, cmvn: NativeAsrCmvn) -> [Double] {
        var out = [Double](repeating: 0, count: feat.count)
        for i in 0..<feat.count {
            let c = i % dim
            out[i] = (Double(feat[i]) + cmvn.means[c]) * cmvn.vars[c]
        }
        return out
    }
}

/// fbank 中间阶段观察窗（金样逐阶段比对用；生产传 nil 零开销）。
public final class NativeAsrFbankStages {
    /// 预加重后波形（T,400）行主序 float64（dither+去直流+预加重完成态）。
    public var preemphasisFrames: [Double]?
    /// 加窗后波形（T,400）行主序 float64。
    public var windowedFrames: [Double]?
    /// 功率谱（T,257）行主序 float64。
    public var powerSpectrum: [Double]?
    /// log-mel fbank（T,80）行主序 float32。
    public var fbankLogMel: [Float]?
    public init() {}
}

/// am.mvn CMVN 统计（asr_driver._load_cmvn L186-207 同款解析：<AddShift>/<Rescale>
/// 各自的 <LearnRateCoef> 行，取第 3 列到倒数第 1 列）。
public struct NativeAsrCmvn: Sendable, Equatable {
    public let means: [Double]
    public let vars: [Double]

    public init(means: [Double], vars: [Double]) {
        self.means = means
        self.vars = vars
    }

    /// 解析失败 → nil（驱动层转 PackUnavailableError 中文明细）。
    public static func parse(_ text: String) -> NativeAsrCmvn? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var means: [Double] = []
        var rescale: [Double] = []
        for (i, rawLine) in lines.enumerated() {
            let item = rawLine.split(separator: " ", omittingEmptySubsequences: true)
            guard !item.isEmpty else { continue }
            if item[0] == "<AddShift>", i + 1 < lines.count {
                let nxt = lines[i + 1].split(separator: " ", omittingEmptySubsequences: true)
                if !nxt.isEmpty, nxt[0] == "<LearnRateCoef>", nxt.count >= 4 {
                    means = nxt[3..<(nxt.count - 1)].compactMap { Double($0) }
                }
            } else if item[0] == "<Rescale>", i + 1 < lines.count {
                let nxt = lines[i + 1].split(separator: " ", omittingEmptySubsequences: true)
                if !nxt.isEmpty, nxt[0] == "<LearnRateCoef>", nxt.count >= 4 {
                    rescale = nxt[3..<(nxt.count - 1)].compactMap { Double($0) }
                }
            }
        }
        guard !means.isEmpty, !rescale.isEmpty else { return nil }
        return NativeAsrCmvn(means: means, vars: rescale)
    }
}
