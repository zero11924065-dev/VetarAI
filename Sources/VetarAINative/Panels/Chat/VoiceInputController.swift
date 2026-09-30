//
//  VoiceInputController.swift
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

//  行为链对齐 subagent/renderer/src/panels/ChatPanel.tsx 0.4.29/0.4.30：
//    点击话筒 → ① ASR 守卫（ensureAsrReady L362-377：status 查询失败 fail-open
//      放行；!available 弹「语音转写不可用」——disabled/none 两条文案逐字）
//    → ② 系统麦克风权限（ensureMicPermission L382-396：denied 弹「无法使用麦克风」
//      + MIC_DENIED_HINT 逐字，引导去系统设置）
//    → ③ 起录 16kHz 单声道 PCM16 WAV（AVAudioRecorder；TSX 是 MediaRecorder→
//      WebAudio 转 16k WAV，原生直录省去转换）
//    → 再点停止 → ④ 全静音拦截（0.4.30 W1：SILENCE_RMS_THRESHOLD=8 LSB int16
//      刻度——权限链断裂录出的零流不进转写链，防模型幻听文本）
//    → ⑤ /api/asr/transcribe（language=auto，pid/sid 带上走 C7 落盘归属）
//    → ⑥ 转写文本上屏输入框
//
//  微差（汇报清单同步）：
//    ① 上屏形态：TSX 录音成品入**暂存区**作音频附件（两段式 chip+transcript），
//       原生端按 W3b 定案直插**输入框**（说话→文字上屏→可编辑→发送）；
//       转写失败 TSX 标红 chip，原生弹 alert「语音转写失败」+ detail。
//    ② 静音拦截文案：TSX 是 chip 标注「录音未检测到声音，未附文稿」，
//       原生无暂存区载体，弹 alert 同义提示。
//    ③ 录音秒数归零时机、临时文件即转即删（NSTemporaryDirectory）为原生实现细节。
//

import Foundation
import AVFoundation

/// 录音器缝（生产 = AVAudioRecorder 适配；单测 = 假录音器写固定 WAV）。
public protocol VoiceInputRecorder: AnyObject {
    var url: URL { get }
    func start() throws
    func stop()
}

/// AVAudioRecorder 生产适配：16kHz 单声道 LinearPCM16 WAV（ASR 端点原生格式，
/// 无需 afconvert 再转——afconvert 链对 wav 也是直通校验）。
private final class AVFoundationVoiceRecorder: VoiceInputRecorder {
    let url: URL
    private let recorder: AVAudioRecorder

    init(url: URL) throws {
        self.url = url
        recorder = try AVAudioRecorder(url: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
    }

    func start() throws {
        guard recorder.record() else {
            throw NSError(domain: "VetarAI.VoiceInput", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                                "录音设备不可用或被占用，请检查输入设备后重试"])
        }
    }

    func stop() { recorder.stop() }
}

@MainActor
public final class VoiceInputController: ObservableObject {

    /// 全静音判定阈值（ChatPanel.tsx SILENCE_RMS_THRESHOLD L320：int16 PCM 均方根 8 LSB，
    /// ≈ -72dBFS——远高于模数转换底噪、远低于任何可闻语音）。
    public static let silenceRmsThreshold = 8.0

    @Published public private(set) var isRecording = false
    @Published public private(set) var isTranscribing = false
    @Published public private(set) var recordSeconds = 0

    // ── 缝（生产默认 / 单测注入）──
    /// 提醒出口（生产 = DialogCenter 应用内弹窗，TSX alertDialog 同位；单测捕获）。
    public var alertSink: (String, String) -> Void = { title, message in
        Task { @MainActor in await DialogCenter.shared.alert(title: title, message: message) }
    }

    // ── 缝（生产默认 / 单测注入）──
    /// ASR 客户端供给（nil = 侧车未就绪：静默忽略，按钮待 nativeModuleReady 后可用）。
    public var clientProvider: () -> (any AsrPanelClient)? = { nil }
    /// C7 落盘归属 ids（pid/sid 缺一即空串——端点不落盘不报错，与 TSX 同口径）。
    public var idsProvider: () -> (projectId: String, sessionId: String) = { ("", "") }
    /// 转写文本上屏回调（ChatViewModel.insertTranscribedText）。
    public var onText: (String) -> Void = { _ in }
    /// 麦克风权限链（默认 AVCaptureDevice；单测脚本化）。
    public var micAccess: () async -> Bool = { await VoiceInputController.defaultMicAccess() }
    /// 录音器工厂（默认 AVAudioRecorder；单测注入假录音器）。
    public var recorderFactory: (URL) throws -> any VoiceInputRecorder = {
        try AVFoundationVoiceRecorder(url: $0)
    }
    /// 静音检测（默认 readWavPcm 读回算 RMS；单测脚本化——返回 int16 刻度 RMS，
    /// nil = 读不出（放行，交后端裁决，TSX 同款 fail-open））。
    public var wavRmsInt16: (URL) -> Double? = { VoiceInputController.measureWavRmsInt16($0) }

    private var recorder: (any VoiceInputRecorder)?
    private var timer: Timer?

    public init() {}

    // MARK: - 按钮主入口（TSX toggleRecording L1602-1636）

    public func toggle() {
        if isRecording {
            stopAndTranscribe()
            return
        }
        guard !isTranscribing else { return }
        Task { await startFlow() }
    }

    // MARK: - 起录链（ASR 守卫 → 权限 → 起录）

    private func startFlow() async {
        guard let client = clientProvider() else { return }
        // ① ASR 守卫（ensureAsrReady：查询失败/载荷异常 fail-open 放行，不误伤）
        if let st = try? await client.fetchAsrStatus(), !st.available {
            alertSink("语音转写不可用",
                      st.state == "disabled"
                        ? "语音转写模型包已安装但被禁用，请到「模型包」面板启用后再试。"
                        : "未安装语音转写（ASR）模型包，无法使用语音功能。请到「模型包」面板安装后再试。")
            return
        }
        // ② 系统麦克风权限（denied → MIC_DENIED_HINT 逐字）
        guard await micAccess() else {
            alertSink("无法使用麦克风",
                      "麦克风权限已被拒绝，请到 系统设置→隐私与安全性→麦克风 开启 VetarAI")
            return
        }
        // ③ 起录（临时文件；转写完即删）
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vetarai-voice-\(UUID().uuidString).wav")
        do {
            let rec = try recorderFactory(url)
            try rec.start()
            recorder = rec
            recordSeconds = 0
            isRecording = true
            startTimer()
        } catch {
            alertSink("无法开始录音", error.localizedDescription)
        }
    }

    // MARK: - 停止 → 静音拦截 → 转写 → 上屏（TSX finishRecording L1638-1657）

    private func stopAndTranscribe() {
        guard let rec = recorder else { return }
        rec.stop()
        recorder = nil
        isRecording = false
        stopTimer()
        let url = rec.url
        Task { await transcribeFlow(url) }
    }

    private func transcribeFlow(_ url: URL) async {
        defer { try? FileManager.default.removeItem(at: url) }
        // ④ 全静音拦截（8 LSB；读不出文件则放行进转写链交后端报错）
        if let rms = wavRmsInt16(url), rms < Self.silenceRmsThreshold {
            alertSink("未检测到声音",
                      "录音几乎是全静音（可能麦克风未开启或被占用），未进转写链。"
                        + "请确认输入设备后重试。")
            return
        }
        guard let client = clientProvider() else { return }
        let ids = idsProvider()
        isTranscribing = true
        defer { isTranscribing = false }
        do {
            // ⑤ 转写（pack 缺省=首个启用中 ASR 包；language=auto 与 TSX 一致）
            let out = try await client.transcribeAsrAudio(
                path: url.path, packId: nil, language: "auto",
                projectId: ids.projectId, sessionId: ids.sessionId)
            // ⑥ 上屏（空文本不打扰输入框）
            let text = out.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { onText(text) }
        } catch {
            alertSink("语音转写失败", Self.errorDetail(error))
        }
    }

    /// 转写失败文案：HTTP 错误取后端 detail（409/422/400 中文明细直达用户）。
    static func errorDetail(_ error: Error) -> String {
        if case .httpError(_, let detail) = error as? SidecarError, !detail.isEmpty {
            return detail
        }
        return error.localizedDescription
    }

    // MARK: - 录音秒表（TSX recordTimerRef 1s 滴答）

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.recordSeconds += 1 }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - 生产默认实现

    /// AVCaptureDevice 权限链（macOS TCC；须 Info.plist NSMicrophoneUsageDescription，
    /// 缺键进程直接被杀——package_app.sh 已配）。
    public static func defaultMicAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: .audio) { ok in
                    cont.resume(returning: ok)
                }
            }
        case .denied, .restricted: return false
        @unknown default: return false
        }
    }

    /// 读回 WAV 求 int16 刻度 RMS（静音判据；读不出 → nil 放行）。
    static func measureWavRmsInt16(_ url: URL) -> Double? {
        guard let (samples, _) = try? NativeAsrFeatures.readWavPcm(url),
              !samples.isEmpty else { return nil }
        var sum = 0.0
        for s in samples { let d = Double(s) * 32768.0; sum += d * d }
        return (sum / Double(samples.count)).squareRoot()
    }
}
