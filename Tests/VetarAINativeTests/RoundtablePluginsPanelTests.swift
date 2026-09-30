//
//  RoundtablePluginsPanelTests.swift
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

//  RoundtablePanel / RoundtableView / PluginPanel 单测：
//    · Roundtable / RTMessage / RTAttachmentMeta / SidecarPlugin 宽容解码
//      （DB 行 ok=0/1 整数、id 数值/字符串、缺省字段回落）
//    · RoundtableCreateRequest 编码（moderator=user 时 moderator_agent_id 省略
//      = 后端 None 语义；attachments 原样上送）
//    · RoundtableFormat：状态文案五态 / 头像六色板哈希（UTF-16 码元口径）/
//      议题 40 字截断 / 已耗时复用 TaskElapsed
//    · RoundtablePanelViewModel：创建校验三连（议题空/参与者<2/AI 主持未选）/
//      创建成功清表单并打开详情 / 附件上限（>5 拒、单文件 >2MB 跳过）/
//      详情轮询终态停止 / 继续·结束·停止·导出·删除流程（文案逐字 + busy 防连点 +
//      删除 danger 确认 + 成功后退出大屏）/ 按轮分组 / 主持人文案
//    · PluginsPanelViewModel：列表加载 / 联网安装确认链（远端每次必弹·无记忆·
//      取消不发请求；本地路径直装；勾选全量联网先 PUT config 再安装，顺序断言）/
//      toggle 乐观更新文案 / 卸载确认 / 备注保存与清除 / 钩子触发输出映射四分支 /
//      资源变更流（resource=="plugin" 与 gap 触发重拉，其他资源忽略）
//
//  Mock 客户端为本文件私有（W5aMockClient），不改动其他波次测试文件。
//

import XCTest
@testable import VetarAINative

// MARK: - W5a Mock 客户端（圆桌 + 插件双协议，全端点可注入/记录）

final class W5aMockClient: RoundtablePanelClient, PluginsPanelClient {
    let baseURL = URL(string: "http://127.0.0.1:1/api")!

    // ── 注入结果 ──
    var agents: [SidecarAgent] = []
    var roundtables: [Roundtable] = []
    var detail: Roundtable?
    var createdRoundtable = Roundtable(id: "rt-new")
    var plugins: [SidecarPlugin] = []
    var installResult = PluginInstallResult(name: "demo", version: "1.0")
    var hookResponse: [String: Any] = ["result": "ok-text"]
    var config: [String: Any] = ["network_switch": "direct"]

    var listRoundtablesError: Error?
    var detailError: Error?
    var createError: Error?
    var actionError: Error?        // continue/finish/stop 共用
    var exportError: Error?
    var deleteError: Error?
    var listPluginsError: Error?
    var installError: Error?
    var toggleError: Error?
    var noteError: Error?
    var hookError: Error?
    var putConfigError: Error?

    // ── 调用记录 ──
    private(set) var listRoundtablesCalls = 0
    private(set) var listAgentsCalls = 0
    private(set) var detailCalls: [String] = []
    private(set) var createCalls: [RoundtableCreateRequestLite] = []
    private(set) var continueCalls: [String] = []
    private(set) var finishCalls: [String] = []
    private(set) var stopCalls: [String] = []
    private(set) var exportCalls: [String] = []
    private(set) var deleteCalls: [String] = []
    private(set) var listPluginsCalls = 0
    private(set) var installCalls: [String] = []
    private(set) var uninstallCalls: [String] = []
    private(set) var toggleCalls: [(String, Bool)] = []
    private(set) var noteCalls: [(String, String)] = []
    private(set) var hookCalls: [(String, String)] = []
    private(set) var putConfigCalls: [[String: Any]] = []
    /// 事件顺序流水（断言「先 PUT config 再 install」用）
    private(set) var order: [String] = []

    /// RoundtableCreateRequest 不可 Equatable，记录轻量投影
    struct RoundtableCreateRequestLite {
        let topic: String
        let agentIDs: [String]
        let moderator: String
        let moderatorAgentID: String?
        let maxRounds: Int
        let attachmentCount: Int
    }

    // SSE 流控制
    private var streamContinuation: AsyncThrowingStream<SSEEvent, Error>.Continuation?
    private(set) var streamCalls = 0
    func pushStreamEvent(_ ev: SSEEvent) { streamContinuation?.yield(ev) }
    func finishStream(throwing error: Error? = nil) {
        if let error { streamContinuation?.finish(throwing: error) }
        else { streamContinuation?.finish() }
    }

    // MARK: SidecarClientProtocol 基座

    func probeReady() async throws -> Bool { true }
    func listModels() async throws -> [OllamaModel] { [] }
    func listProjects() async throws -> [SidecarProject] { [] }
    func createProject(name: String, workingDir: String) async throws -> String { "p1" }
    func listAgents(projectId: String) async throws -> [SidecarAgent] {
        listAgentsCalls += 1
        return agents
    }
    func createAgent(projectId: String, name: String, type: String, modelName: String?) async throws -> String { "a1" }
    func listSessions(projectId: String, agentId: String) async throws -> [ChatSession] { [] }
    func createSession(projectId: String, agentId: String, title: String) async throws -> String { "s1" }
    func loadMessages(projectId: String, sessionId: String) async throws -> [ChatMessage] { [] }
    func stopChat(sessionId: String) async throws {}
    func respondAuth(_ body: AuthRespondRequest) async throws {}
    func chatStream(_ body: ChatStreamRequest) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    // MARK: RoundtablePanelClient

    func listRoundtables(projectId: String, limit: Int) async throws -> [Roundtable] {
        listRoundtablesCalls += 1
        order.append("listRoundtables")
        if let listRoundtablesError { throw listRoundtablesError }
        return roundtables
    }
    func createRoundtable(projectId: String, request: RoundtableCreateRequest) async throws -> Roundtable {
        createCalls.append(RoundtableCreateRequestLite(
            topic: request.topic, agentIDs: request.agent_ids, moderator: request.moderator,
            moderatorAgentID: request.moderator_agent_id, maxRounds: request.max_rounds,
            attachmentCount: request.attachments.count))
        order.append("createRoundtable")
        if let createError { throw createError }
        return createdRoundtable
    }
    func getRoundtable(projectId: String, rtId: String) async throws -> Roundtable {
        detailCalls.append(rtId)
        if let detailError { throw detailError }
        return detail ?? Roundtable(id: rtId)
    }
    func continueRoundtable(projectId: String, rtId: String) async throws {
        continueCalls.append(rtId)
        if let actionError { throw actionError }
    }
    func finishRoundtable(projectId: String, rtId: String) async throws {
        finishCalls.append(rtId)
        if let actionError { throw actionError }
    }
    func stopRoundtable(projectId: String, rtId: String) async throws {
        stopCalls.append(rtId)
        if let actionError { throw actionError }
    }
    func exportRoundtable(projectId: String, rtId: String) async throws -> RoundtableExportResult {
        exportCalls.append(rtId)
        if let exportError { throw exportError }
        return RoundtableExportResult(path: "/tmp/rt.md", name: "rt.md")
    }
    func deleteRoundtable(projectId: String, rtId: String) async throws {
        deleteCalls.append(rtId)
        if let deleteError { throw deleteError }
    }

    // MARK: PluginsPanelClient

    func fetchConfig() async throws -> [String: Any] { config }
    func putConfig(_ patch: [String: Any]) async throws {
        putConfigCalls.append(patch)
        order.append("putConfig")
        if let putConfigError { throw putConfigError }
        for (k, v) in patch { config[k] = v }
    }
    func appEventsStream(since: Int) -> AsyncThrowingStream<SSEEvent, Error> {
        streamCalls += 1
        return AsyncThrowingStream { cont in self.streamContinuation = cont }
    }
    func listPlugins() async throws -> [SidecarPlugin] {
        listPluginsCalls += 1
        order.append("listPlugins")
        if let listPluginsError { throw listPluginsError }
        return plugins
    }
    func installPlugin(repoUrl: String) async throws -> PluginInstallResult {
        installCalls.append(repoUrl)
        order.append("install")
        if let installError { throw installError }
        return installResult
    }
    func uninstallPlugin(name: String) async throws {
        uninstallCalls.append(name)
    }
    func togglePlugin(name: String, enabled: Bool) async throws -> Bool {
        toggleCalls.append((name, enabled))
        if let toggleError { throw toggleError }
        return enabled
    }
    func setPluginNote(name: String, note: String) async throws -> String {
        noteCalls.append((name, note))
        if let noteError { throw noteError }
        return note
    }
    func triggerPluginHook(plugin: String, hook: String) async throws -> [String: Any] {
        hookCalls.append((plugin, hook))
        if let hookError { throw hookError }
        return hookResponse
    }
}

// MARK: - 测试工具

@MainActor
private func makeAppState(client: W5aMockClient, projectId: String? = "p1") -> AppState {
    let state = TestRuntimeSupport.makeAppState(client: client)
    state.currentProjectId = projectId
    return state
}

private func sse(_ event: String, _ data: [String: Any] = [:]) -> SSEEvent {
    SSEEvent(event: event, data: data, rawData: "")
}

@MainActor
private func waitFor(_ timeoutMs: UInt64 = 2000,
                     _ cond: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
    while Date() < deadline {
        if cond() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return cond()
}

/// 断言条件最终成立（先 await 再断言，绕开 XCTAssert autoclosure 不支持并发）。
@MainActor
private func assertEventually(_ timeoutMs: UInt64 = 2000,
                              _ cond: @MainActor () -> Bool,
                              file: StaticString = #filePath, line: UInt = #line) async {
    let ok = await waitFor(timeoutMs, cond)
    XCTAssertTrue(ok, file: file, line: line)
}

// MARK: - 解码

final class RoundtableModelTests: XCTestCase {

    func testRoundtableDetailDecode() throws {
        let json: [String: Any] = [
            "id": "rt1", "topic": "议题", "moderator": "ai", "moderator_agent_id": "a1",
            "max_rounds": 5, "round": 2, "status": "waiting_user",
            "participants": [["id": "a1", "name": "甲", "role": "主持"],
                             ["id": "a2", "name": "乙"]],
            "minutes": "纪要文本", "summary": NSNull(),
            "messages": [["id": 1, "rt_id": "rt1", "round": 1, "agent_id": "a1",
                          "agent_name": "甲", "content": "你好", "ok": 1],
                         ["id": 2, "rt_id": "rt1", "round": 1, "agent_id": "a2",
                          "agent_name": "乙", "content": "失败发言", "ok": 0]],
            "attachments": [["name": "a.txt", "size": 12, "is_text": true],
                            ["name": "b.bin", "is_text": false]],
            "created_at": "2026-08-30 14:00:00",
        ]
        let rt = try JSONDecoder().decode(Roundtable.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(rt.id, "rt1")
        XCTAssertEqual(rt.moderator, "ai")
        XCTAssertEqual(rt.moderator_agent_id, "a1")
        XCTAssertEqual(rt.participants.count, 2)
        XCTAssertEqual(rt.participants[1].role, nil)
        XCTAssertEqual(rt.minutes, "纪要文本")
        XCTAssertNil(rt.summary)
        XCTAssertEqual(rt.messages?.count, 2)
        XCTAssertEqual(rt.messages?[0].ok, true)   // ok=1 整数 → true
        XCTAssertEqual(rt.messages?[1].ok, false)  // ok=0 → false
        XCTAssertEqual(rt.attachments?.count, 2)
        XCTAssertEqual(rt.attachments?[1].is_text, false)
        XCTAssertFalse(rt.isTerminal)
    }

    func testRoundtableTerminalStates() {
        XCTAssertTrue(Roundtable(id: "1", status: "done").isTerminal)
        XCTAssertTrue(Roundtable(id: "1", status: "failed").isTerminal)
        XCTAssertFalse(Roundtable(id: "1", status: "running").isTerminal)
        XCTAssertFalse(Roundtable(id: "1", status: "waiting_user").isTerminal)
        XCTAssertFalse(Roundtable(id: "1", status: "confirm_end").isTerminal)
    }

    func testRoundtableMinimalDecode() throws {
        // 列表行可大量缺省（宽容解码），id 必填
        let rt = try JSONDecoder().decode(Roundtable.self, from: JSONSerialization.data(
            withJSONObject: ["id": "rt9"]))
        XCTAssertEqual(rt.id, "rt9")
        XCTAssertEqual(rt.moderator, "user")
        XCTAssertEqual(rt.max_rounds, 5)
        XCTAssertEqual(rt.status, "running")
        XCTAssertNil(rt.messages)
    }

    func testRoundtableMissingIDThrows() {
        XCTAssertThrowsError(try JSONDecoder().decode(
            Roundtable.self, from: JSONSerialization.data(withJSONObject: ["topic": "x"])))
    }

    func testRTMessageStringIDDecode() throws {
        let msg = try JSONDecoder().decode(RTMessage.self, from: JSONSerialization.data(
            withJSONObject: ["id": "42", "round": 3]))
        XCTAssertEqual(msg.id, 42)
        XCTAssertEqual(msg.round, 3)
        XCTAssertTrue(msg.ok)   // 缺省 true
    }

    func testSidecarPluginDecode() throws {
        let p = try JSONDecoder().decode(SidecarPlugin.self, from: JSONSerialization.data(
            withJSONObject: ["name": "greeter", "version": "0.1", "enabled": false,
                             "hooks": ["on_msg"], "note": "打招呼", "description": "desc"]))
        XCTAssertEqual(p.name, "greeter")
        XCTAssertEqual(p.version, "0.1")
        XCTAssertTrue(p.isDisabled)
        XCTAssertEqual(p.hooks, ["on_msg"])
        XCTAssertEqual(p.note, "打招呼")
    }

    func testSidecarPluginEnabledNilMeansEnabled() {
        XCTAssertFalse(SidecarPlugin(name: "x").isDisabled)          // nil → 启用（TSX enabled===false 判定）
        XCTAssertFalse(SidecarPlugin(name: "x", enabled: true).isDisabled)
        XCTAssertTrue(SidecarPlugin(name: "x", enabled: false).isDisabled)
    }
}

// MARK: - 编码

final class RoundtableEncodingTests: XCTestCase {

    private func encodedJSON(_ req: RoundtableCreateRequest) throws -> [String: Any] {
        let data = try JSONEncoder().encode(req)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    func testCreateRequestUserModeratorOmitsAgentID() throws {
        // moderator=user 时 moderator_agent_id=nil → 键省略（后端 None 缺省同语义；TSX 传 null 等价）
        let obj = try encodedJSON(RoundtableCreateRequest(
            topic: "议题", agent_ids: ["a1", "a2"], moderator: "user",
            moderator_agent_id: nil, max_rounds: 5))
        XCTAssertEqual(obj["topic"] as? String, "议题")
        XCTAssertEqual(obj["agent_ids"] as? [String], ["a1", "a2"])
        XCTAssertEqual(obj["moderator"] as? String, "user")
        XCTAssertNil(obj["moderator_agent_id"])
        XCTAssertEqual(obj["max_rounds"] as? Int, 5)
        XCTAssertEqual((obj["attachments"] as? [Any])?.count, 0)
    }

    func testCreateRequestAIModeratorWithAttachments() throws {
        let obj = try encodedJSON(RoundtableCreateRequest(
            topic: "议题", agent_ids: ["a1", "a2"], moderator: "ai",
            moderator_agent_id: "a2", max_rounds: 3,
            attachments: [RTAttachmentInput(name: "m.md", content_base64: "aGk=")]))
        XCTAssertEqual(obj["moderator_agent_id"] as? String, "a2")
        let atts = obj["attachments"] as? [[String: Any]]
        XCTAssertEqual(atts?.count, 1)
        XCTAssertEqual(atts?.first?["name"] as? String, "m.md")
        XCTAssertEqual(atts?.first?["content_base64"] as? String, "aGk=")
    }
}

// MARK: - RoundtableFormat 纯函数

final class RoundtableFormatTests: XCTestCase {

    func testStatusLabels() {
        XCTAssertEqual(RoundtableFormat.statusLabel("running"), "讨论中")
        XCTAssertEqual(RoundtableFormat.statusLabel("waiting_user"), "等待用户")
        XCTAssertEqual(RoundtableFormat.statusLabel("confirm_end"), "待确认结束")
        XCTAssertEqual(RoundtableFormat.statusLabel("done"), "已结束")
        XCTAssertEqual(RoundtableFormat.statusLabel("failed"), "异常")
        XCTAssertEqual(RoundtableFormat.statusLabel("???"), "讨论中")   // 未知回落 running
    }

    func testAvatarColorHashStable() {
        // 对齐 TSX avatarColor：h = (h*31 + charCode) >>> 0，取模 6
        let i1 = RoundtableFormat.avatarColorIndex("agent-a")
        let i2 = RoundtableFormat.avatarColorIndex("agent-a")
        XCTAssertEqual(i1, i2)
        XCTAssertTrue((0..<6).contains(i1))
        // 不同 id 落不同槽位（构造已知哈希差异的两个输入）
        let all = (0..<20).map { RoundtableFormat.avatarColorIndex("agent-\($0)") }
        XCTAssertGreaterThan(Set(all).count, 1)
        // 中文名（UTF-16 码元口径，BMP 内与码点一致）
        XCTAssertTrue((0..<6).contains(RoundtableFormat.avatarColorIndex("甲方辩手")))
    }

    func testAvatarPaletteValues() {
        XCTAssertEqual(RoundtableFormat.avatarPalette.count, 6)
        XCTAssertEqual(RoundtableFormat.avatarPalette[0].bg, 0xDCF1FE)
        XCTAssertEqual(RoundtableFormat.avatarPalette[5].fg, 0x0F7490)
    }

    func testTruncatedTopic() {
        let short = String(repeating: "议", count: 40)
        XCTAssertEqual(RoundtableFormat.truncatedTopic(short), short)
        let long = String(repeating: "题", count: 41)
        XCTAssertEqual(RoundtableFormat.truncatedTopic(long),
                       String(repeating: "题", count: 40) + "…")
    }

    func testElapsed() {
        XCTAssertNil(RoundtableFormat.elapsed(createdAt: nil))
        XCTAssertNil(RoundtableFormat.elapsed(createdAt: "not-a-date"))
        // UTC 解析（checkpoint-067 N-3）：不补 Z 会多算一个时区
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let created = "2027-01-15 08:00:00"   // 对应上方 epoch 的 UTC 串
        let now = started.addingTimeInterval(75)
        XCTAssertEqual(RoundtableFormat.elapsed(createdAt: created, now: now), "1m15s")
    }
}

// MARK: - RoundtablePanelViewModel

@MainActor
final class RoundtablePanelViewModelTests: XCTestCase {

    private func makeVM(client: W5aMockClient,
                        projectId: String? = "p1") -> RoundtablePanelViewModel {
        RoundtablePanelViewModel(appState: makeAppState(client: client, projectId: projectId),
                                 clientOverride: client, pollInterval: 3600, tickInterval: 3600)
    }

    private func fillValidForm(_ vm: RoundtablePanelViewModel, client: W5aMockClient) async {
        client.agents = [
            SidecarAgent(id: "a1", name: "甲", type_: "main", model_name: nil,
                         role: "辩手", parent_agent_id: nil, system_prompt: nil),
            SidecarAgent(id: "a2", name: "乙", type_: "main", model_name: nil,
                         role: nil, parent_agent_id: nil, system_prompt: nil),
        ]
        await vm.fetchAgents()
        vm.topic = "  讨论架构  "
        vm.toggleAgent("a1")
        vm.toggleAgent("a2")
    }

    func testCreateValidationEmptyTopic() {
        let client = W5aMockClient()
        let vm = makeVM(client: client)
        XCTAssertEqual(vm.createValidationError, "请输入议题")
        vm.topic = "   "
        XCTAssertEqual(vm.createValidationError, "请输入议题")
    }

    func testCreateValidationMinTwoAgents() {
        let client = W5aMockClient()
        let vm = makeVM(client: client)
        vm.topic = "议题"
        XCTAssertEqual(vm.createValidationError, "至少选择 2 个参与者")
        vm.toggleAgent("a1")
        XCTAssertEqual(vm.createValidationError, "至少选择 2 个参与者")
        vm.toggleAgent("a2")
        XCTAssertNil(vm.createValidationError)
    }

    func testCreateValidationAIModeratorRequired() {
        let client = W5aMockClient()
        let vm = makeVM(client: client)
        vm.topic = "议题"
        vm.toggleAgent("a1"); vm.toggleAgent("a2")
        vm.moderator = "ai"
        XCTAssertEqual(vm.createValidationError, "请选择 AI 主持人")
        vm.moderatorAgentId = "a2"
        XCTAssertNil(vm.createValidationError)
    }

    func testToggleAgentIdempotent() {
        let client = W5aMockClient()
        let vm = makeVM(client: client)
        vm.toggleAgent("a1")
        vm.toggleAgent("a1")
        vm.toggleAgent("a2")
        XCTAssertEqual(vm.selectedAgentIds, ["a2"])
    }

    func testModeratorCandidatesLimitedToSelected() async {
        let client = W5aMockClient()
        let vm = makeVM(client: client)
        await fillValidForm(vm, client: client)
        XCTAssertEqual(vm.moderatorCandidates.map(\.id), ["a1", "a2"])
        vm.toggleAgent("a1")
        XCTAssertEqual(vm.moderatorCandidates.map(\.id), ["a2"])
    }

    func testCreateSuccessClearsFormAndOpensDetail() async {
        let client = W5aMockClient()
        let vm = makeVM(client: client)
        await fillValidForm(vm, client: client)
        vm.moderator = "ai"
        vm.moderatorAgentId = "a2"
        vm.maxRounds = 3
        vm.addAttachments([(name: "m.md", data: Data("hi".utf8))])

        vm.create()
        await assertEventually { vm.selectedId == "rt-new" }

        XCTAssertEqual(client.createCalls.count, 1)
        let sent = client.createCalls[0]
        XCTAssertEqual(sent.topic, "讨论架构")          // trim 后上送
        XCTAssertEqual(sent.agentIDs, ["a1", "a2"])
        XCTAssertEqual(sent.moderator, "ai")
        XCTAssertEqual(sent.moderatorAgentID, "a2")
        XCTAssertEqual(sent.maxRounds, 3)
        XCTAssertEqual(sent.attachmentCount, 1)

        // 表单清空（对齐 TSX setTopic('') 等链）
        XCTAssertEqual(vm.topic, "")
        XCTAssertEqual(vm.selectedAgentIds, [])
        XCTAssertEqual(vm.moderator, "user")
        XCTAssertEqual(vm.moderatorAgentId, "")
        XCTAssertTrue(vm.pendingAttachments.isEmpty)
        XCTAssertFalse(vm.creating)
        // 创建后重拉列表 + 拉详情
        XCTAssertGreaterThanOrEqual(client.listRoundtablesCalls, 1)
        await assertEventually { client.detailCalls.contains("rt-new") }
    }

    func testCreateFailureShowsError() async {
        let client = W5aMockClient()
        client.createError = SidecarError.httpError(status: 400, detail: "至少选择 2 个参与者")
        let vm = makeVM(client: client)
        await fillValidForm(vm, client: client)
        vm.create()
        await assertEventually { vm.error != nil }
        XCTAssertEqual(vm.error, "创建失败: HTTP 400：至少选择 2 个参与者")
        XCTAssertNil(vm.selectedId)
        XCTAssertFalse(vm.creating)
    }

    func testCreateValidationBlocksRequest() async {
        let client = W5aMockClient()
        let vm = makeVM(client: client)
        vm.create()   // 议题为空
        XCTAssertEqual(vm.error, "请输入议题")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(client.createCalls.count, 0)
    }

    func testAddAttachmentsLimits() {
        let client = W5aMockClient()
        let vm = makeVM(client: client)
        // 单文件 >2MB 跳过并提示
        vm.addAttachments([(name: "big.bin", data: Data(count: 2 * 1024 * 1024 + 1))])
        XCTAssertTrue(vm.pendingAttachments.isEmpty)
        XCTAssertEqual(vm.error, "文件 big.bin 超过 2MB，已跳过")
        // 最多 5 个
        for i in 0..<5 {
            vm.addAttachments([(name: "f\(i).txt", data: Data("x".utf8))])
        }
        XCTAssertEqual(vm.pendingAttachments.count, 5)
        vm.addAttachments([(name: "f5.txt", data: Data("x".utf8))])
        XCTAssertEqual(vm.error, "最多上传 5 个附件")
        XCTAssertEqual(vm.pendingAttachments.count, 5)
        // 移除
        vm.removeAttachment(at: 0)
        XCTAssertEqual(vm.pendingAttachments.count, 4)
        XCTAssertEqual(vm.pendingAttachments[0].name, "f1.txt")
    }

    func testDetailTerminalStopsPolling() async {
        let client = W5aMockClient()
        client.detail = Roundtable(id: "rt1", status: "done", summary: "结论")
        let vm = makeVM(client: client, projectId: "p1")
        vm.select("rt1")
        await assertEventually { vm.detail?.status == "done" }
        let calls = client.detailCalls.count
        // pollInterval=3600s 保证测试内不会自然轮询；终态分支显式 cancel 双保险
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(client.detailCalls.count, calls)
        XCTAssertFalse(vm.detailActive)
    }

    func testGroupedRoundsSorted() async {
        let client = W5aMockClient()
        client.detail = Roundtable(id: "rt1", status: "waiting_user", messages: [
            RTMessage(id: 3, rt_id: "rt1", round: 2, agent_id: "a1", agent_name: "甲", content: "二轮"),
            RTMessage(id: 1, rt_id: "rt1", round: 1, agent_id: "a1", agent_name: "甲", content: "一轮"),
            RTMessage(id: 2, rt_id: "rt1", round: 1, agent_id: "a2", agent_name: "乙", content: "一轮乙"),
        ])
        let vm = makeVM(client: client)
        vm.select("rt1")
        await assertEventually { vm.detail != nil }
        let groups = vm.groupedRounds
        XCTAssertEqual(groups.map(\.round), [1, 2])
        XCTAssertEqual(groups[0].messages.map(\.id), [1, 2])
        XCTAssertEqual(groups[1].messages.map(\.id), [3])
    }

    func testModeratorLabel() async {
        let client = W5aMockClient()
        client.detail = Roundtable(id: "rt1", participants: [RTParticipant(id: "a2", name: "乙")],
                                   moderator: "ai", moderator_agent_id: "a2")
        let vm = makeVM(client: client)
        vm.select("rt1")
        await assertEventually { vm.detail != nil }
        XCTAssertEqual(vm.moderatorLabel, "AI 主持：乙")
        // 找不到主持人 →（未知）
        client.detail = Roundtable(id: "rt1", moderator: "ai", moderator_agent_id: "ghost")
        await vm.fetchDetail()
        XCTAssertEqual(vm.moderatorLabel, "AI 主持：（未知）")
        // 用户主持
        client.detail = Roundtable(id: "rt1", moderator: "user")
        await vm.fetchDetail()
        XCTAssertEqual(vm.moderatorLabel, "用户主持（结束权在你）")
    }

    func testContinueFinishStopExportFlows() async {
        let client = W5aMockClient()
        client.detail = Roundtable(id: "rt1", status: "waiting_user")
        let vm = makeVM(client: client)
        vm.select("rt1")
        await assertEventually { vm.detail != nil }

        vm.continueDiscussion()
        await assertEventually { client.continueCalls == ["rt1"] }
        XCTAssertNil(vm.error)
        XCTAssertFalse(vm.detailBusy)

        vm.finishDiscussion()
        await assertEventually { client.finishCalls == ["rt1"] }

        client.detail = Roundtable(id: "rt1", status: "running")
        await vm.fetchDetail()
        vm.stopDiscussion()
        await assertEventually { client.stopCalls == ["rt1"] }
        XCTAssertEqual(vm.notice, "已请求停止，将在当前发言完成后中止")
        XCTAssertFalse(vm.stopping)

        vm.exportDiscussion()
        await assertEventually { client.exportCalls == ["rt1"] }
        XCTAssertEqual(vm.notice, "已保存：/tmp/rt.md")
    }

    func testContinueErrorCopy() async {
        let client = W5aMockClient()
        client.actionError = SidecarError.httpError(status: 400, detail: "当前状态（running）不允许继续")
        client.detail = Roundtable(id: "rt1", status: "waiting_user")
        let vm = makeVM(client: client)
        vm.select("rt1")
        await assertEventually { vm.detail != nil }
        vm.continueDiscussion()
        await assertEventually { vm.error != nil }
        XCTAssertEqual(vm.error, "继续失败: HTTP 400：当前状态（running）不允许继续")
        XCTAssertFalse(vm.detailBusy)
    }

    func testDeleteFlowWithConfirm() async {
        let client = W5aMockClient()
        client.detail = Roundtable(id: "rt1", status: "done")
        let vm = makeVM(client: client)
        vm.select("rt1")
        await assertEventually { vm.detail != nil }

        var confirmArgs: (title: String, message: String, confirm: String, danger: Bool)?
        vm.confirmHandler = { t, m, c, d in
            confirmArgs = (t, m, c, d)
            return true
        }
        vm.deleteDiscussion()
        await assertEventually { client.deleteCalls == ["rt1"] }
        XCTAssertEqual(confirmArgs?.title, "删除圆桌讨论")
        XCTAssertEqual(confirmArgs?.message, "确定删除这场圆桌讨论吗？全部发言记录将被清除，不可恢复。")
        XCTAssertEqual(confirmArgs?.confirm, "删除")
        XCTAssertEqual(confirmArgs?.danger, true)
        // 删除成功 → 退出大屏
        await assertEventually { vm.selectedId == nil }
        XCTAssertNil(vm.detail)
    }

    func testDeleteCancelledSkipsRequest() async {
        let client = W5aMockClient()
        client.detail = Roundtable(id: "rt1", status: "done")
        let vm = makeVM(client: client)
        vm.select("rt1")
        await assertEventually { vm.detail != nil }
        vm.confirmHandler = { _, _, _, _ in false }
        vm.deleteDiscussion()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(client.deleteCalls, [])
        XCTAssertEqual(vm.selectedId, "rt1")
    }

    func testSelectExitDetailResetsState() async {
        let client = W5aMockClient()
        client.detail = Roundtable(id: "rt1", status: "running")
        let vm = makeVM(client: client)
        vm.select("rt1")
        await assertEventually { vm.detail != nil }
        XCTAssertTrue(vm.detailActive)
        vm.exitDetail()
        XCTAssertNil(vm.selectedId)
        XCTAssertNil(vm.detail)
        XCTAssertFalse(vm.detailActive)
    }
}

// MARK: - PluginsPanelViewModel

@MainActor
final class PluginsPanelViewModelTests: XCTestCase {

    private func makeVM(client: W5aMockClient) -> PluginsPanelViewModel {
        PluginsPanelViewModel(appState: makeAppState(client: client),
                              clientOverride: client, retryInterval: 3600)
    }

    func testFetchPluginsSuccess() async {
        let client = W5aMockClient()
        client.plugins = [SidecarPlugin(name: "a", version: "1.0"),
                          SidecarPlugin(name: "b", enabled: false)]
        let vm = makeVM(client: client)
        await vm.fetchPlugins()
        XCTAssertEqual(vm.plugins.map(\.name), ["a", "b"])
        XCTAssertNil(vm.error)
        XCTAssertFalse(vm.loading)
    }

    func testFetchPluginsErrorCopy() async {
        let client = W5aMockClient()
        client.listPluginsError = SidecarError.offline("连不上")
        let vm = makeVM(client: client)
        await vm.fetchPlugins()
        XCTAssertEqual(vm.error, "无法获取插件列表: 连接失败：连不上")
    }

    // ── 联网安装确认链 ──

    func testIsRemoteURL() {
        XCTAssertTrue(PluginsPanelViewModel.isRemoteURL("https://github.com/x/y"))
        XCTAssertTrue(PluginsPanelViewModel.isRemoteURL("  HTTP://example.com/r "))
        XCTAssertFalse(PluginsPanelViewModel.isRemoteURL("/Users/x/plugin"))
        XCTAssertFalse(PluginsPanelViewModel.isRemoteURL("~/plugins/demo"))
        XCTAssertFalse(PluginsPanelViewModel.isRemoteURL("git@github.com:x/y.git"))
    }

    func testRemoteInstallConfirmsEveryTime() async {
        let client = W5aMockClient()
        let vm = makeVM(client: client)
        await vm.fetchConfig()   // network_switch=direct
        var confirmCount = 0
        var lastArgs: (title: String, message: String, confirm: String, danger: Bool, checkbox: String?)?
        vm.confirmHandler = { t, m, c, d, cb, _ in
            confirmCount += 1
            lastArgs = (t, m, c, d, cb)
            return (true, false)
        }
        vm.repoUrl = "https://github.com/owner/repo"
        vm.install()
        await assertEventually { client.installCalls.count == 1 }
        XCTAssertEqual(confirmCount, 1)
        XCTAssertEqual(lastArgs?.title, "联网安装确认")
        XCTAssertEqual(lastArgs?.confirm, "允许安装")
        XCTAssertEqual(lastArgs?.danger, true)
        // github.com = 境外 + 非全量联网 → 附勾选
        XCTAssertEqual(lastArgs?.checkbox, AuthPrompt.enableNetworkCheckboxLabel)
        XCTAssertTrue(lastArgs?.message.contains("https://github.com/owner/repo") == true)

        // 第二次安装同样必弹（无记忆口径）
        vm.repoUrl = "https://github.com/owner/repo2"
        vm.install()
        await assertEventually { client.installCalls.count == 2 }
        XCTAssertEqual(confirmCount, 2)
    }

    func testRemoteInstallCancelSkipsRequest() async {
        let client = W5aMockClient()
        let vm = makeVM(client: client)
        vm.confirmHandler = { _, _, _, _, _, _ in (false, false) }
        vm.repoUrl = "https://github.com/owner/repo"
        vm.install()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(client.installCalls.count, 0)   // 取消则不联网、不安装
        XCTAssertNil(vm.error)
    }

    func testLocalPathInstallsWithoutConfirm() async {
        let client = W5aMockClient()
        let vm = makeVM(client: client)
        vm.confirmHandler = { _, _, _, _, _, _ in
            XCTFail("本地路径不应弹联网安装确认")
            return (false, false)
        }
        vm.repoUrl = "/Users/x/my-plugin"
        vm.install()
        await assertEventually { client.installCalls == ["/Users/x/my-plugin"] }
        XCTAssertEqual(vm.notice, "插件 \"demo\" v1.0 安装成功")
        XCTAssertEqual(vm.repoUrl, "")
    }

    func testProxyCheckboxPutConfigBeforeInstall() async {
        let client = W5aMockClient()
        let vm = makeVM(client: client)
        await vm.fetchConfig()
        vm.confirmHandler = { _, _, _, _, _, _ in (true, true) }   // 确认且勾选全量联网
        vm.repoUrl = "https://github.com/owner/repo"
        vm.install()
        await assertEventually { client.installCalls.count == 1 }
        // 顺序断言：先 PUT network_switch=proxy 再 install
        XCTAssertEqual(client.order, ["putConfig", "install", "listPlugins"])
        XCTAssertEqual(client.putConfigCalls.first?["network_switch"] as? String, "proxy")
        XCTAssertEqual(vm.networkSwitch, "proxy")   // 本地 cfg 同步更新
    }

    func testProxyCheckboxNotOfferedWhenAlreadyProxy() async {
        let client = W5aMockClient()
        client.config = ["network_switch": "proxy"]
        let vm = makeVM(client: client)
        await vm.fetchConfig()
        var checkbox: String??
        vm.confirmHandler = { _, _, _, _, cb, _ in
            checkbox = cb
            return (true, false)
        }
        vm.repoUrl = "https://github.com/owner/repo"
        vm.install()
        await assertEventually { client.installCalls.count == 1 }
        XCTAssertTrue(checkbox! == nil)   // 已是全量联网 → 不附勾选
        XCTAssertEqual(client.putConfigCalls.count, 0)
    }

    func testProxySwitchFailureAbortsInstall() async {
        let client = W5aMockClient()
        client.putConfigError = SidecarError.timeout
        let vm = makeVM(client: client)
        await vm.fetchConfig()
        vm.confirmHandler = { _, _, _, _, _, _ in (true, true) }
        vm.repoUrl = "https://github.com/owner/repo"
        vm.install()
        await assertEventually { vm.error != nil }
        XCTAssertEqual(vm.error, "开启全量联网失败: 请求超时")
        XCTAssertEqual(client.installCalls.count, 0)
    }

    func testInstallFailureErrorCopy() async {
        let client = W5aMockClient()
        client.installError = SidecarError.httpError(status: 400, detail: "clone 失败")
        let vm = makeVM(client: client)
        vm.repoUrl = "/local/path"
        vm.install()
        await assertEventually { vm.error != nil }
        XCTAssertEqual(vm.error, "安装失败: HTTP 400：clone 失败")
        XCTAssertFalse(vm.installing)
    }

    // ── 启用/禁用 ──

    func testToggleEnabledUpdatesListAndNotice() async {
        let client = W5aMockClient()
        client.plugins = [SidecarPlugin(name: "a", enabled: true)]
        let vm = makeVM(client: client)
        await vm.fetchPlugins()
        vm.toggleEnabled(vm.plugins[0])
        await assertEventually { client.toggleCalls.count == 1 }
        XCTAssertEqual(client.toggleCalls[0].0, "a")
        XCTAssertEqual(client.toggleCalls[0].1, false)
        XCTAssertEqual(vm.plugins[0].enabled, false)
        XCTAssertEqual(vm.notice, "插件 \"a\" 已禁用")

        vm.toggleEnabled(vm.plugins[0])
        await assertEventually { client.toggleCalls.count == 2 }
        XCTAssertEqual(vm.notice, "插件 \"a\" 已启用")
        XCTAssertEqual(vm.plugins[0].enabled, true)
    }

    func testToggleFailureErrorCopy() async {
        let client = W5aMockClient()
        client.toggleError = SidecarError.httpError(status: 400, detail: "切换失败（插件不存在）")
        client.plugins = [SidecarPlugin(name: "a")]
        let vm = makeVM(client: client)
        await vm.fetchPlugins()
        vm.toggleEnabled(vm.plugins[0])
        await assertEventually { vm.error != nil }
        XCTAssertEqual(vm.error, "切换失败: HTTP 400：切换失败（插件不存在）")
    }

    // ── 卸载 ──

    func testUninstallWithConfirm() async {
        let client = W5aMockClient()
        client.plugins = [SidecarPlugin(name: "a")]
        let vm = makeVM(client: client)
        await vm.fetchPlugins()
        var args: (String, String, String, Bool)?
        vm.uninstallConfirmHandler = { t, m, c, d in args = (t, m, c, d); return true }
        vm.uninstall("a")
        await assertEventually { client.uninstallCalls == ["a"] }
        XCTAssertEqual(args?.0, "卸载插件")
        XCTAssertEqual(args?.1, "确定卸载插件 \"a\"？")
        XCTAssertEqual(args?.2, "卸载")
        XCTAssertEqual(args?.3, true)
        XCTAssertEqual(vm.notice, "插件 \"a\" 已卸载")
        await assertEventually { client.listPluginsCalls >= 2 }   // 卸载后重拉
    }

    func testUninstallCancelled() async {
        let client = W5aMockClient()
        let vm = makeVM(client: client)
        vm.uninstallConfirmHandler = { _, _, _, _ in false }
        vm.uninstall("a")
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(client.uninstallCalls, [])
    }

    // ── 备注 ──

    func testSaveNoteUpdatesList() async {
        let client = W5aMockClient()
        client.plugins = [SidecarPlugin(name: "a", note: nil, description: "desc")]
        let vm = makeVM(client: client)
        await vm.fetchPlugins()
        vm.beginEditNote(vm.plugins[0])
        XCTAssertEqual(vm.editingNote, "a")
        XCTAssertEqual(vm.noteDraft, "")
        vm.noteDraft = "给消息加时间戳前缀"
        vm.saveNote("a")
        await assertEventually { client.noteCalls.count == 1 }
        XCTAssertEqual(client.noteCalls[0].1, "给消息加时间戳前缀")
        XCTAssertEqual(vm.plugins[0].note, "给消息加时间戳前缀")
        XCTAssertNil(vm.editingNote)
        XCTAssertEqual(vm.notice, "插件 \"a\" 备注已保存")
    }

    func testSaveEmptyNoteClears() async {
        let client = W5aMockClient()
        client.plugins = [SidecarPlugin(name: "a", note: "old")]
        let vm = makeVM(client: client)
        await vm.fetchPlugins()
        vm.beginEditNote(vm.plugins[0])
        XCTAssertEqual(vm.noteDraft, "old")
        vm.noteDraft = "   "
        vm.saveNote("a")
        await assertEventually { client.noteCalls.count == 1 }
        XCTAssertEqual(vm.notice, "插件 \"a\" 备注已清除")
    }

    // ── Hooks ──

    func testHookOutputMappingBranches() {
        // error 真值分支
        XCTAssertEqual(PluginsPanelViewModel.mapHookOutput(["error": "炸了"]),
                       PluginHookResult(ok: false, text: "执行出错：炸了"))
        // result 缺失 →（无返回值）
        XCTAssertEqual(PluginsPanelViewModel.mapHookOutput([:]),
                       PluginHookResult(ok: true, text: "（无返回值）"))
        // result null →（无返回值）
        XCTAssertEqual(PluginsPanelViewModel.mapHookOutput(["result": NSNull()]),
                       PluginHookResult(ok: true, text: "（无返回值）"))
        // 字符串原文
        XCTAssertEqual(PluginsPanelViewModel.mapHookOutput(["result": "done!"]),
                       PluginHookResult(ok: true, text: "done!"))
        // 对象 → pretty JSON（2 空格缩进）
        let out = PluginsPanelViewModel.mapHookOutput(["result": ["a": 1]])
        XCTAssertTrue(out.ok)
        XCTAssertTrue(out.text.contains("\"a\" : 1") || out.text.contains("\"a\": 1"))
    }

    func testTriggerHookSuccessAndSingleFlight() async {
        let client = W5aMockClient()
        client.hookResponse = ["result": "已处理 3 条"]
        let vm = makeVM(client: client)
        vm.triggerHook(plugin: "a", hook: "on_msg")
        await assertEventually { vm.hookOutputs["a|on_msg"] != nil }
        XCTAssertEqual(vm.hookOutputs["a|on_msg"], PluginHookResult(ok: true, text: "已处理 3 条"))
        XCTAssertNil(vm.runningHook)
        XCTAssertEqual(client.hookCalls.count, 1)
    }

    func testTriggerHookFailure() async {
        let client = W5aMockClient()
        client.hookError = SidecarError.httpError(status: 403, detail: "插件「a」已被禁用（设置 → 插件与技能），无法调用")
        let vm = makeVM(client: client)
        vm.triggerHook(plugin: "a", hook: "on_msg")
        await assertEventually { vm.hookOutputs["a|on_msg"] != nil }
        XCTAssertEqual(vm.hookOutputs["a|on_msg"]?.ok, false)
        XCTAssertTrue(vm.hookOutputs["a|on_msg"]?.text.hasPrefix("触发失败：") == true)
    }

    func testHooksExpandedToggle() {
        let client = W5aMockClient()
        let vm = makeVM(client: client)
        vm.toggleHooksExpanded("a")
        XCTAssertTrue(vm.expandedHooks.contains("a"))
        vm.toggleHooksExpanded("a")
        XCTAssertFalse(vm.expandedHooks.contains("a"))
    }

    // ── 资源变更流（A13）──

    func testResourceChangedPluginTriggersRefetch() async {
        let client = W5aMockClient()
        let vm = makeVM(client: client)
        await vm.fetchPlugins()
        let before = client.listPluginsCalls
        vm.apply(event: sse("resource_changed", ["resource": "plugin", "action": "create", "seq": 1]))
        await assertEventually { client.listPluginsCalls > before }
    }

    func testResourceChangedOtherResourceIgnored() async {
        let client = W5aMockClient()
        let vm = makeVM(client: client)
        await vm.fetchPlugins()
        let before = client.listPluginsCalls
        vm.apply(event: sse("resource_changed", ["resource": "model_pack", "action": "create", "seq": 2]))
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(client.listPluginsCalls, before)
    }

    func testGapTriggersRefetch() async {
        let client = W5aMockClient()
        let vm = makeVM(client: client)
        await vm.fetchPlugins()
        let before = client.listPluginsCalls
        vm.apply(event: sse("gap"))
        await assertEventually { client.listPluginsCalls > before }
    }
}
