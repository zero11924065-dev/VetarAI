//
//  VoiceInputControllerTests.swift
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

//  逐条锚定（⛔ 行为规格源 subagent/renderer/src/panels/ChatPanel.tsx
//  0.4.29/0.4.30 语音输入链）：
//    · ASR 守卫（ensureAsrReady L362-377）：none/disabled 两条文案逐字；
//      status 查询失败 fail-open 放行
//    · 麦克风权限（ensureMicPermission L382-396）：denied → 「无法使用麦克风」
//      + MIC_DENIED_HINT 逐字
//    · 起录/停止两态 + 录音秒数（toggleRecording L1602-1636）
//    · 全静音拦截（0.4.30 W1：RMS < 8 LSB 不进转写链；读不出文件放行）
//    · 转写 → 文本上屏（W3b 原生定案：直插输入框而非暂存区音频附件——微差①）；
//      失败 alert 直达后端 detail；空文本不打扰输入框
//    · C7 ids 透传（project_id/session_id/language=auto/pack_id=nil）
//    · insertTranscribedText 拼接规则（非空且末尾非空白补一个空格）
//
//  全程不碰真麦克风/真模型：client/micAccess/recorderFactory/wavRmsInt16
//  四缝注入；alertSink 捕获弹窗。
//

import XCTest
@testable import VetarAINative

// MARK: - 夹具

private final class VoiceMockClient: AsrPanelClient, @unchecked Sendable {
    let baseURL = URL(string: "http://127.0.0.1:1/api")!

    var statusResult: Result<AsrStatusInfo, Error> =
        .success(AsrStatusInfo(available: true, state: "ready", pack_id: "sv", message: nil))
    var transcribeResult: Result<AsrTranscribeOutcome, Error> =
        .success(AsrTranscribeOutcome(text: "你好世界", duration_s: 1.0, model_pack_id: "sv"))
    var transcribeDelayNanos: UInt64 = 0
    private(set) var statusCalls = 0
    private(set) var transcribeCalls:
        [(path: String, packId: String?, language: String, projectId: String, sessionId: String)] = []

    func fetchAsrStatus() async throws -> AsrStatusInfo {
        statusCalls += 1
        return try statusResult.get()
    }

    func transcribeAsrAudio(path: String, packId: String?, language: String,
                            projectId: String, sessionId: String) async throws -> AsrTranscribeOutcome {
        transcribeCalls.append((path, packId, language, projectId, sessionId))
        if transcribeDelayNanos > 0 { try? await Task.sleep(nanoseconds: transcribeDelayNanos) }
        return try transcribeResult.get()
    }

    // ── SidecarClientProtocol 其余面（话筒链不触达，骨架实现）──
    func probeReady() async throws -> Bool { true }
    func listModels() async throws -> [OllamaModel] { [] }
    func listProjects() async throws -> [SidecarProject] { [] }
    func createProject(name: String, workingDir: String) async throws -> String { "p1" }
    func listAgents(projectId: String) async throws -> [SidecarAgent] { [] }
    func createAgent(projectId: String, name: String, type: String, modelName: String?) async throws -> String { "a1" }
    func listSessions(projectId: String, agentId: String) async throws -> [ChatSession] { [] }
    func createSession(projectId: String, agentId: String, title: String) async throws -> String { "s1" }
    func loadMessages(projectId: String, sessionId: String) async throws -> [ChatMessage] { [] }
    func stopChat(sessionId: String) async throws {}
    func respondAuth(_ body: AuthRespondRequest) async throws {}
    func chatStream(_ body: ChatStreamRequest) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func fetchConfig() async throws -> [String: Any] { [:] }
    func fetchContextLimit(model: String) async throws -> ContextLimitInfo {
        ContextLimitInfo(limit: 1000, source: "config")
    }
    func renameSession(projectId: String, sessionId: String, title: String) async throws {}
    func deleteSession(projectId: String, sessionId: String) async throws -> Bool { true }
    func compactSession(projectId: String, sessionId: String) async throws {}
    func exportSession(projectId: String, agentId: String, sessionId: String, dir: String?) async throws -> ExportResult { ExportResult() }
    func summarizeSession(projectId: String, agentId: String, sessionId: String, model: String) async throws -> SummarizeResult { SummarizeResult() }
    func parseAttachment(name: String, contentBase64: String, projectId: String,
                         sessionId: String) async throws -> AttachmentParseResult { AttachmentParseResult() }
    func injectMessage(projectId: String, agentId: String, sessionId: String,
                       content: String) async throws -> InjectResult { InjectResult(ok: true, detail: nil) }
    func updateAgentModel(projectId: String, agentId: String, modelName: String) async throws {}
    func pullModel(name: String) async throws {}
    func fetchInferenceBackend() async throws -> String { "ollama" }
    func transferToWarehouse(_ req: KnowledgeTransferRequest) async throws -> KnowledgeTransferResult {
        KnowledgeTransferResult()
    }
}

private final class FakeVoiceRecorder: VoiceInputRecorder {
    let url: URL
    private(set) var started = false
    private(set) var stopped = false
    init(url: URL) { self.url = url }
    func start() throws {
        started = true
        FileManager.default.createFile(atPath: url.path, contents: Data([0x52, 0x49, 0x46, 0x46]))
    }
    func stop() { stopped = true }
}

private final class VoiceAlertLog {
    private(set) var calls: [(title: String, message: String)] = []
    func add(_ title: String, _ message: String) { calls.append((title, message)) }
}

@MainActor
final class VoiceInputControllerTests: XCTestCase {

    private var client: VoiceMockClient!
    private var alerts: VoiceAlertLog!
    private var controller: VoiceInputController!
    private var recorders: [FakeVoiceRecorder]!
    private var texts: [String]!

    override func setUp() {
        super.setUp()
        client = VoiceMockClient()
        alerts = VoiceAlertLog()
        recorders = []
        texts = []
        controller = VoiceInputController()
        controller.clientProvider = { [client] in client }
        controller.idsProvider = { ("p1", "s1") }
        controller.alertSink = { [alerts] t, m in alerts?.add(t, m) }
        controller.micAccess = { true }
        controller.recorderFactory = { [weak self] url in
            let r = FakeVoiceRecorder(url: url)
            self?.recorders.append(r)
            return r
        }
        controller.wavRmsInt16 = { _ in 1000 }   // 默认非静音
        controller.onText = { [weak self] text in self?.texts.append(text) }
    }

    private func waitUntil(_ timeout: Double = 2.0,
                           _ cond: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return cond()
    }

    // MARK: - ① ASR 守卫（ensureAsrReady 文案逐字）

    func testAsrNoneAlert() async {
        client.statusResult = .success(AsrStatusInfo(
            available: false, state: "none", pack_id: nil,
            message: "尚未安装语音识别模型包。请到「模型包」面板安装一个 ASR 模型包（如 SenseVoiceSmall）后再试。"))
        controller.toggle()
        let seen = await waitUntil { !self.alerts.calls.isEmpty }
        XCTAssertTrue(seen)
        XCTAssertEqual(alerts.calls.first?.title, "语音转写不可用")
        XCTAssertEqual(alerts.calls.first?.message,
            "未安装语音转写（ASR）模型包，无法使用语音功能。请到「模型包」面板安装后再试。")
        XCTAssertTrue(recorders.isEmpty, "未安装不得起录")
        XCTAssertFalse(controller.isRecording)
    }

    func testAsrDisabledAlert() async {
        client.statusResult = .success(AsrStatusInfo(
            available: false, state: "disabled", pack_id: nil, message: "…"))
        controller.toggle()
        let seen = await waitUntil { !self.alerts.calls.isEmpty }
        XCTAssertTrue(seen)
        XCTAssertEqual(alerts.calls.first?.message,
            "语音转写模型包已安装但被禁用，请到「模型包」面板启用后再试。")
        XCTAssertTrue(recorders.isEmpty)
    }

    func testStatusFailureFailOpen() async {
        // TSX fetchAsrStatus → null 即放行（fail-open 不误伤可用场景）
        client.statusResult = .failure(SidecarError.decodeFailed("网络不可达样例"))
        controller.toggle()
        let recording = await waitUntil { self.controller.isRecording }
        XCTAssertTrue(recording, "status 查询失败须 fail-open 放行")
        XCTAssertTrue(alerts.calls.isEmpty)
    }

    // MARK: - ② 麦克风权限（MIC_DENIED_HINT 逐字）

    func testMicDeniedAlert() async {
        controller.micAccess = { false }
        controller.toggle()
        let seen = await waitUntil { !self.alerts.calls.isEmpty }
        XCTAssertTrue(seen)
        XCTAssertEqual(alerts.calls.first?.title, "无法使用麦克风")
        XCTAssertEqual(alerts.calls.first?.message,
            "麦克风权限已被拒绝，请到 系统设置→隐私与安全性→麦克风 开启 VetarAI")
        XCTAssertTrue(recorders.isEmpty, "权限拒绝不得起录")
    }

    // MARK: - ③ 起录/停止两态 + 完整转写链

    func testFullChainRecordsThenTranscribes() async {
        controller.toggle()
        let recording = await waitUntil { self.controller.isRecording }
        XCTAssertTrue(recording)
        XCTAssertEqual(recorders.count, 1)
        XCTAssertTrue(recorders[0].started)
        XCTAssertEqual(controller.recordSeconds, 0)

        controller.toggle()   // 再点 = 停止 → 转写
        let done = await waitUntil { !self.texts.isEmpty }
        XCTAssertTrue(done, "转写文本应上屏")
        XCTAssertEqual(texts, ["你好世界"])
        XCTAssertFalse(controller.isRecording)
        XCTAssertFalse(controller.isTranscribing)
        XCTAssertTrue(recorders[0].stopped)
        // C7 ids 透传 + language/pack 口径
        XCTAssertEqual(client.transcribeCalls.count, 1)
        XCTAssertEqual(client.transcribeCalls[0].packId, nil)
        XCTAssertEqual(client.transcribeCalls[0].language, "auto")
        XCTAssertEqual(client.transcribeCalls[0].projectId, "p1")
        XCTAssertEqual(client.transcribeCalls[0].sessionId, "s1")
        // 临时文件即转即删
        XCTAssertFalse(FileManager.default.fileExists(atPath: recorders[0].url.path))
        XCTAssertTrue(alerts.calls.isEmpty)
    }

    // MARK: - ④ 全静音拦截（8 LSB）

    func testSilenceIntercepted() async {
        controller.wavRmsInt16 = { _ in 3.2 }   // < 8 LSB
        controller.toggle()
        _ = await waitUntil { self.controller.isRecording }
        controller.toggle()
        let seen = await waitUntil { !self.alerts.calls.isEmpty }
        XCTAssertTrue(seen)
        XCTAssertEqual(alerts.calls.first?.title, "未检测到声音")
        XCTAssertTrue(client.transcribeCalls.isEmpty, "静音流不进转写链（防幻听文本）")
        XCTAssertTrue(texts.isEmpty)
        // 临时文件同样清理
        XCTAssertFalse(FileManager.default.fileExists(atPath: recorders[0].url.path))
    }

    func testSilenceUnreadablePassesThrough() async {
        controller.wavRmsInt16 = { _ in nil }   // 读不出 → 放行交后端裁决
        controller.toggle()
        _ = await waitUntil { self.controller.isRecording }
        controller.toggle()
        let done = await waitUntil { !self.texts.isEmpty }
        XCTAssertTrue(done)
        XCTAssertEqual(client.transcribeCalls.count, 1)
    }

    // MARK: - ⑤ 转写失败/空文本

    func testTranscribeFailureShowsBackendDetail() async {
        client.transcribeResult = .failure(SidecarError.httpError(
            status: 422, detail: "音频解码失败样例：不支持的编码"))
        controller.toggle()
        _ = await waitUntil { self.controller.isRecording }
        controller.toggle()
        let seen = await waitUntil { !self.alerts.calls.isEmpty }
        XCTAssertTrue(seen)
        XCTAssertEqual(alerts.calls.first?.title, "语音转写失败")
        XCTAssertEqual(alerts.calls.first?.message, "音频解码失败样例：不支持的编码")
        XCTAssertTrue(texts.isEmpty)
        XCTAssertFalse(controller.isTranscribing)
    }

    func testBlankTextNotInserted() async {
        client.transcribeResult = .success(AsrTranscribeOutcome(
            text: "  \n ", duration_s: 0.5, model_pack_id: "sv"))
        controller.toggle()
        _ = await waitUntil { self.controller.isRecording }
        controller.toggle()
        let settled = await waitUntil { !self.controller.isTranscribing && self.client.transcribeCalls.count == 1 }
        XCTAssertTrue(settled)
        XCTAssertTrue(texts.isEmpty, "空文本不打扰输入框")
        XCTAssertTrue(alerts.calls.isEmpty)
    }

    // MARK: - ⑥ 边界

    func testToggleWhileTranscribingIgnored() async {
        client.transcribeDelayNanos = 300_000_000
        controller.toggle()
        _ = await waitUntil { self.controller.isRecording }
        controller.toggle()   // 停止 → 转写开始
        let transcribing = await waitUntil { self.controller.isTranscribing }
        XCTAssertTrue(transcribing)
        controller.toggle()   // 转写中再点 = 忽略（不得二次起录/二次查 status）
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(recorders.count, 1)
        XCTAssertEqual(client.statusCalls, 1)
        let done = await waitUntil { !self.texts.isEmpty }
        XCTAssertTrue(done)
    }

    func testErrorDetailMapping() {
        let http = SidecarError.httpError(status: 409, detail: "尚未安装语音识别模型包。")
        XCTAssertEqual(VoiceInputController.errorDetail(http), "尚未安装语音识别模型包。")
        let other = NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "通用失败"])
        XCTAssertEqual(VoiceInputController.errorDetail(other), "通用失败")
    }

    // MARK: - ⑦ insertTranscribedText 拼接规则

    func testInsertTranscribedTextSpacing() {
        let appState = TestRuntimeSupport.makeAppState(client: client)
        let vm = ChatViewModel(appState: appState)
        vm.insertTranscribedText("第一段")
        XCTAssertEqual(vm.input, "第一段")
        vm.insertTranscribedText("第二段")
        XCTAssertEqual(vm.input, "第一段 第二段", "末尾非空白补一个空格拼接")
        vm.input = "带换行\n"
        vm.insertTranscribedText("第三段")
        XCTAssertEqual(vm.input, "带换行\n第三段", "末尾已是空白不重复补")
    }
}
