//
//  PilotFixTests.swift
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

//  · 问题2/3：ComposerSyncPolicy 状态机（绑定→视图回写闸门 / 占位符显隐），
//    以及「流式期间输入框可打字」的 ViewModel 级回归（input 不被禁用、不被清）。
//  · 问题1：跨面板联动——独立 Agent / 项目「开始对话」入口写 AppState + 跳聊天主页；
//    ChatViewModel 经 AppState 发布订阅跟随切换上下文（采纳 / 重绑）。
//    0.7.6 实测 Bug1 新口径：项目管理操作不得隐式创建任何项目/Agent——
//    清空选择只清会话上下文（不回落 pilot 播种复活）、空项目选中不创建 Agent
//    （projectMissingAgent 空态 + 输入禁用）、bootstrap 无选择不播种；
//    原 ensurePilotContext 及 pilot 常量已拔除（存量旧名项目 = 普通项目）。
//  · 0.7.6 补充一：输入框占位符命中穿透（ComposerPassthroughLabel）。
//  · 0.7.6 补充二：上下文指示器失败暂态不上屏红字 + 静默有界重试。
//  · 0.7.6 补充三：⋯ 菜单窗口内 overlay 下拉规格钉桩（见 ChatTopBarR2Tests）。
//  · 问题6：注册表收口——18 面板、工作流单入口、logs/diagnostics 保持归并占位，
//    旧记忆键 workflow-editor 深链恢复有兜底。
//  · U2（方案A）：「会话」移出智能中心面板列表 → 常驻聊天主页 chatHome；
//    任务跳转经 pickInitialSession 消费 AppState.currentSessionId 定位目标会话。
//  · U3（仓库归位）：「仓库」独立面板移出系统组（嵌回聊天右端窄栏）；
//    ChatViewModel.injectKnowledgeText = onInject 的输入框追加语义。
//  · V1（智能中心侧栏单栏堆叠复刻）：智能中心组五个导航项移出注册表（17→12）——
//    侧栏改由 IntelligenceSidebarView 单栏堆叠直接挂载（对齐 App.tsx:233-290），
//    注册表不再为智能中心列导航位；chatHome 仍为智能中心唯一可解析键与默认落点。
//  · V4（设置整页覆盖复刻）：「系统」组整体移出注册表（12→2）——rail 复刻原版
//    双模块 + 底部设置齿轮；低频模块收进 SettingsPageView 内部导航；AppState
//    showSettings/settingsSection 覆盖态、旧设置键/系统组键兜底、分区深链。
//

import XCTest
import AppKit
@testable import VetarAINative

// MARK: - 问题2/3：Composer 同步策略（状态机纯函数）

final class ComposerSyncPolicyTests: XCTestCase {

    // 占位符：text 非空即隐藏（问题3 基本口径）
    func testPlaceholderHiddenWhenTextNonEmpty() {
        XCTAssertFalse(ComposerSyncPolicy.placeholderHidden(viewString: "", hasMarkedText: false))
        XCTAssertTrue(ComposerSyncPolicy.placeholderHidden(viewString: "h", hasMarkedText: false))
    }

    // 占位符：IME 组字中（marked text，string 仍为空）也算「输入中」——
    // 中文输入首字母按下即隐藏灰字（问题3 关键分支）
    func testPlaceholderHiddenDuringMarkedText() {
        XCTAssertTrue(ComposerSyncPolicy.placeholderHidden(viewString: "", hasMarkedText: true))
        XCTAssertTrue(ComposerSyncPolicy.placeholderHidden(viewString: "n", hasMarkedText: true))
    }

    // 回写闸门：绑定值 == 上次同步值（用户自己敲的 / 流式 15fps 重渲）→ 不回写。
    // 这是「思考中无法打字、输入框一直在刷新」的根因修复：重渲帧不得覆盖 text storage。
    func testNoPushWhenBindingMatchesLastSync() {
        XCTAssertFalse(ComposerSyncPolicy.shouldPushBindingToView(
            binding: "", lastSynced: "", hasMarkedText: false))
        XCTAssertFalse(ComposerSyncPolicy.shouldPushBindingToView(
            binding: "你好", lastSynced: "你好", hasMarkedText: false))
    }

    // 回写闸门：外部变更（send() 清空输入框）且非组字中 → 回写
    func testPushOnExternalChange() {
        XCTAssertTrue(ComposerSyncPolicy.shouldPushBindingToView(
            binding: "", lastSynced: "已发送的内容", hasMarkedText: false))
    }

    // 回写闸门：IME 组字中无论绑定怎么变都禁止回写（保组字会话不被摧毁）
    func testNoPushDuringMarkedTextEvenOnExternalChange() {
        XCTAssertFalse(ComposerSyncPolicy.shouldPushBindingToView(
            binding: "", lastSynced: "abc", hasMarkedText: true))
    }
}

// MARK: - 联动测试用 mock（ChatPanelClient + IndependentAgentsPanelClient 全端点）

@MainActor
final class LinkageMockClient: ChatPanelClient, IndependentAgentsPanelClient {
    let baseURL = URL(string: "http://127.0.0.1:1/api")!

    var projects: [SidecarProject] = []
    var agentsByProject: [String: [SidecarAgent]] = [:]
    var independentAgents: [IndependentAgent] = []
    var sessionsByContext: [String: [ChatSession]] = [:]   // key = "pid|aid"
    var nextProjectId = "p-new"
    var nextAgentId = "a-new"
    var nextSessionId = "s-new"
    var streamEvents: [SSEEvent] = []
    var streamNeverEnds = false

    private(set) var listSessionsCalls: [(pid: String, aid: String)] = []
    private(set) var createProjectCalls: [(name: String, dir: String)] = []
    private(set) var createAgentCalls: [(pid: String, name: String)] = []
    private(set) var createSessionCalls: [(pid: String, aid: String)] = []

    func probeReady() async throws -> Bool { true }
    func listModels() async throws -> [OllamaModel] { [OllamaModel(name: "qwen3.8", size: nil)] }
    func listProjects() async throws -> [SidecarProject] { projects }
    func createProject(name: String, workingDir: String) async throws -> String {
        createProjectCalls.append((name, workingDir))
        return nextProjectId
    }
    func listAgents(projectId: String) async throws -> [SidecarAgent] { agentsByProject[projectId] ?? [] }
    func createAgent(projectId: String, name: String, type: String, modelName: String?) async throws -> String {
        createAgentCalls.append((projectId, name))
        return nextAgentId
    }
    func listSessions(projectId: String, agentId: String) async throws -> [ChatSession] {
        listSessionsCalls.append((projectId, agentId))
        return sessionsByContext["\(projectId)|\(agentId)"] ?? []
    }
    func createSession(projectId: String, agentId: String, title: String) async throws -> String {
        createSessionCalls.append((projectId, agentId))
        return nextSessionId
    }
    func loadMessages(projectId: String, sessionId: String) async throws -> [ChatMessage] { [] }
    func stopChat(sessionId: String) async throws {}
    func respondAuth(_ body: AuthRespondRequest) async throws {}
    func chatStream(_ body: ChatStreamRequest) -> AsyncThrowingStream<SSEEvent, Error> {
        let events = streamEvents
        let neverEnds = streamNeverEnds
        return AsyncThrowingStream { cont in
            for ev in events { cont.yield(ev) }
            if neverEnds { cont.onTermination = { _ in }; return }
            cont.finish()
        }
    }

    // ChatPanelClient 扩展端点（最小桩）
    func fetchConfig() async throws -> [String: Any] { [:] }
    /// 补充二测试注入：非空时逐次弹出（耗尽后回落 contextLimitFallback）
    var contextLimitQueue: [ContextLimitInfo] = []
    var contextLimitFallback = ContextLimitInfo(limit: 1000, source: "config")
    private(set) var fetchContextLimitCalls = 0
    func fetchContextLimit(model: String) async throws -> ContextLimitInfo {
        fetchContextLimitCalls += 1
        if !contextLimitQueue.isEmpty { return contextLimitQueue.removeFirst() }
        return contextLimitFallback
    }
    func renameSession(projectId: String, sessionId: String, title: String) async throws {}
    func deleteSession(projectId: String, sessionId: String) async throws -> Bool { true }
    func compactSession(projectId: String, sessionId: String) async throws {}
    func exportSession(projectId: String, agentId: String, sessionId: String, dir: String?) async throws -> ExportResult {
        ExportResult()
    }
    func summarizeSession(projectId: String, agentId: String, sessionId: String, model: String) async throws -> SummarizeResult {
        SummarizeResult()
    }
    func parseAttachment(name: String, contentBase64: String, projectId: String,
                         sessionId: String) async throws -> AttachmentParseResult {
        AttachmentParseResult()
    }
    func injectMessage(projectId: String, agentId: String, sessionId: String,
                       content: String) async throws -> InjectResult {
        InjectResult(ok: true, detail: nil)
    }
    func updateAgentModel(projectId: String, agentId: String, modelName: String) async throws {}
    func pullModel(name: String) async throws {}
    func fetchInferenceBackend() async throws -> String { "ollama" }
    func transferToWarehouse(_ req: KnowledgeTransferRequest) async throws -> KnowledgeTransferResult {
        KnowledgeTransferResult()
    }

    // IndependentAgentsPanelClient
    func listIndependentAgents() async throws -> [IndependentAgent] { independentAgents }
    func createIndependentAgent(name: String, modelName: String?, systemPrompt: String?) async throws -> String { "ia-new" }
    func updateIndependentAgent(agentId: String, update: IndependentAgentUpdateRequest) async throws {}
    func deleteIndependentAgent(agentId: String) async throws {}
}

// MARK: - 测试工具

@MainActor
private func makeLinkageAppState<C: SidecarClientProtocol>(client: C) -> AppState {
    TestRuntimeSupport.makeAppState(client: client)
}

@MainActor
private func fixWaitFor(_ timeoutMs: UInt64 = 3000,
                        _ cond: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
    while Date() < deadline {
        if cond() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return cond()
}

private func fixProject(_ id: String, _ name: String) -> SidecarProject {
    let json = "{\"id\":\"\(id)\",\"name\":\"\(name)\"}"
    return try! JSONDecoder().decode(SidecarProject.self, from: Data(json.utf8))
}

private func fixAgent(_ id: String, _ name: String, _ type: String = "main") -> SidecarAgent {
    let json = "{\"id\":\"\(id)\",\"name\":\"\(name)\",\"type_\":\"\(type)\"}"
    return try! JSONDecoder().decode(SidecarAgent.self, from: Data(json.utf8))
}

private func fixEvent(_ event: String, _ data: [String: Any] = [:]) -> SSEEvent {
    SSEEvent(event: event, data: data, rawData: "")
}

// MARK: - 问题2：流式期间输入框可用（ViewModel 级回归）

@MainActor
final class ChatStreamingInputTests: XCTestCase {

    private func bootstrappedVM(_ client: LinkageMockClient) async throws -> ChatViewModel {
        let appState = makeLinkageAppState(client: client)
        // 0.7.6 实测 Bug1 新口径：无 pilot 播种——上下文 = 用户选中态，测试显式预置
        appState.currentProjectId = "p1"
        appState.currentAgentId = "a1"
        let vm = ChatViewModel(appState: appState)
        let ok = await fixWaitFor { vm.bootstrapped }
        XCTAssertTrue(ok, "bootstrap 未完成")
        return vm
    }

    // 流式期间：输入不被禁用、用户已敲内容不被流式合帧抹掉、可随时再发送（注入）。
    // 对照现状 Electron：思考中流式期间可正常打字甚至插入新消息。
    func testInputStaysUsableWhileStreaming() async throws {
        let client = LinkageMockClient()
        client.streamNeverEnds = true
        client.streamEvents = [fixEvent("thinking", ["delta": "…"])]
        let vm = try await bootstrappedVM(client)

        vm.input = "第一条"
        vm.send()
        let streaming = await fixWaitFor { vm.sending }
        XCTAssertTrue(streaming)

        // 流式期间打字：input 可写且保持（不被任何合帧/重绑清空）
        XCTAssertFalse(vm.inputDisabled, "流式期间输入框不得禁用（仅 compact 警告才禁用）")
        vm.input = "流式中敲的补充"
        try await Task.sleep(nanoseconds: 300_000_000)   // 跨过若干 15fps 合帧
        XCTAssertEqual(vm.input, "流式中敲的补充")

        // 发送按钮口径保持现状：流式中发送 = 注入（A5），不打断当前轮
        vm.send()
        let injected = await fixWaitFor {
            vm.messages.contains { $0.role == "user" && $0.content == "流式中敲的补充" }
        }
        XCTAssertTrue(injected, "流式中再发应走注入路径（乐观气泡）")
        XCTAssertEqual(vm.input, "", "注入后输入框清空")
        vm.stop()
    }
}

// MARK: - 问题1：跨面板联动（AppState 发布订阅）

@MainActor
final class ChatContextLinkageTests: XCTestCase {

    // 引导时采纳外部已选上下文（如从独立 Agent 面板带着选中态进会话面板）
    func testBootstrapAdoptsExternalContext() async throws {
        let client = LinkageMockClient()
        client.projects = [fixProject("p9", "调研项目")]
        client.agentsByProject["p9"] = [fixAgent("a9", "调研助手")]
        client.sessionsByContext["p9|a9"] = [ChatSession(id: "s9", title: "旧会话", message_count: 2)]
        let appState = makeLinkageAppState(client: client)
        appState.currentProjectId = "p9"
        appState.currentAgentId = "a9"
        let vm = ChatViewModel(appState: appState)

        let ok = await fixWaitFor { vm.bootstrapped }
        XCTAssertTrue(ok)
        XCTAssertEqual(vm.agentName, "调研助手")
        XCTAssertEqual(vm.contextScope, "调研项目")
        XCTAssertEqual(vm.contextTitle, "调研项目 · 调研助手")
        XCTAssertTrue(client.listSessionsCalls.contains { $0.pid == "p9" && $0.aid == "a9" },
                      "应按外部上下文拉会话列表")
        XCTAssertEqual(vm.currentSessionId, "s9", "选中该上下文已有会话")
    }

    // 引导后外部改选独立 Agent → 会话面板跟随重绑（ia- 命名空间 + 名称解析）
    func testFollowsIndependentAgentSelection() async throws {
        let client = LinkageMockClient()
        client.independentAgents = [IndependentAgent(id: "x1", name: "文档审校员")]
        let appState = makeLinkageAppState(client: client)
        let vm = ChatViewModel(appState: appState)
        let booted = await fixWaitFor { vm.bootstrapped }
        XCTAssertTrue(booted)

        // 模拟独立 Agent 面板「开始对话」：写 AppState（ia- 命名空间）
        appState.currentProjectId = "ia-x1"
        appState.currentAgentId = "x1"

        let switched = await fixWaitFor {
            client.listSessionsCalls.contains { $0.pid == "ia-x1" && $0.aid == "x1" }
        }
        XCTAssertTrue(switched, "会话面板应跟随切到独立 Agent 上下文")
        XCTAssertEqual(vm.agentName, "文档审校员")
        XCTAssertEqual(vm.contextScope, "独立 Agent")
        XCTAssertEqual(vm.contextTitle, "独立 Agent · 文档审校员")
        XCTAssertEqual(vm.currentSessionId, "s-new", "新上下文无会话则新建")
        XCTAssertTrue(client.createSessionCalls.contains { $0.pid == "ia-x1" && $0.aid == "x1" })
    }

    // 只选项目（无 agent）→ 自动落主 Agent（「去对话」入口语义）
    func testProjectOnlySelectionFallsToMainAgent() async throws {
        let client = LinkageMockClient()
        client.projects = [fixProject("p7", "Demo 项目")]
        client.agentsByProject["p7"] = [fixAgent("a7m", "主 Agent"), fixAgent("a7s", "子 Agent", "sub")]
        let appState = makeLinkageAppState(client: client)
        let vm = ChatViewModel(appState: appState)
        let booted = await fixWaitFor { vm.bootstrapped }
        XCTAssertTrue(booted)

        appState.currentProjectId = "p7"
        appState.currentAgentId = nil

        let switched = await fixWaitFor {
            client.listSessionsCalls.contains { $0.pid == "p7" && $0.aid == "a7m" }
        }
        XCTAssertTrue(switched, "只选项目应落到主 Agent")
        XCTAssertEqual(vm.agentName, "主 Agent")
        XCTAssertEqual(vm.contextScope, "Demo 项目")
        XCTAssertEqual(appState.currentAgentId, "a7m", "规范化后的 agentId 回写 AppState")
    }

    // 0.7.6 实测 Bug1 新口径：外部清空选择（删除当前 agent/项目的「杜绝幽灵」收敛）
    // → 只清会话上下文，绝不复活 pilot 项目组/Agent（旧口径删除后 ensurePilotContext
    // 立刻复活「VetarAI」项目组 + Pilot Agent，业主判定为 bug，链路已拔除）
    func testClearedSelectionDoesNotResurrect() async throws {
        let client = LinkageMockClient()
        client.projects = [fixProject("p9", "调研项目")]
        client.agentsByProject["p9"] = [fixAgent("a9", "调研助手")]
        let appState = makeLinkageAppState(client: client)
        appState.currentProjectId = "p9"
        appState.currentAgentId = "a9"
        let vm = ChatViewModel(appState: appState)
        let booted = await fixWaitFor { vm.bootstrapped && vm.agentName == "调研助手" }
        XCTAssertTrue(booted)

        // 删除当前项目 → AppState 清空（checkpoint-056）
        appState.currentProjectId = nil
        appState.currentAgentId = nil
        appState.currentSessionId = nil

        // 等防抖 + 切换跑完（旧口径此处会复活；新口径必须什么都不建）
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(client.createProjectCalls.isEmpty,
                      "删除清空后不得新建任何项目：\(client.createProjectCalls)")
        XCTAssertTrue(client.createAgentCalls.isEmpty,
                      "删除清空后不得新建任何 Agent：\(client.createAgentCalls)")
        XCTAssertNil(vm.projectId, "只清会话上下文，不留可发消息的幽灵上下文")
        XCTAssertEqual(vm.agentName, "")
        XCTAssertEqual(vm.contextScope, "")
        XCTAssertNil(appState.currentProjectId,
                     "不回写 AppState 选中态（RootView「开始对话」空态兜底）")
        XCTAssertFalse(vm.projectMissingAgent)
    }

    // 0.7.6 实测 Bug1 新口径 c/d)：bootstrap 无任何选择时不播种——首次安装也不
    // 预建 Pilot 项目组；存量「VetarAI Native Pilot」项目自此就是普通项目，
    // 不再有任何特殊兼容逻辑（原 ensurePilotContext/legacy 回退已拔除）
    func testBootstrapWithoutSelectionSeedsNothing() async throws {
        let client = LinkageMockClient()
        client.projects = [fixProject("p-old", "VetarAI Native Pilot")]
        client.agentsByProject["p-old"] = [fixAgent("a-old", "Pilot")]
        let appState = makeLinkageAppState(client: client)
        let vm = ChatViewModel(appState: appState)
        let booted = await fixWaitFor { vm.bootstrapped }
        XCTAssertTrue(booted)
        XCTAssertTrue(client.createProjectCalls.isEmpty, "无选择不播种：不得新建项目")
        XCTAssertTrue(client.createAgentCalls.isEmpty, "无选择不播种：不得新建 Agent")
        XCTAssertNil(vm.projectId)
        XCTAssertNil(appState.currentProjectId, "不采纳不回写：存量旧名项目只是普通项目")
        XCTAssertNil(appState.currentAgentId)
    }

    // 0.7.6 实测 Bug1 新口径 a)：选中一个没有任何 Agent 的项目 → 不创建 Agent
    // （projectMissingAgent 空态 + 输入禁用，由用户在左侧 Agent 区显式「+ 添加」）；
    // 选中已有 Agent 的项目仍自动落 main/首个 Agent（「选择」语义保留）
    func testEmptyProjectSelectionCreatesNoAgent() async throws {
        let client = LinkageMockClient()
        client.projects = [fixProject("p7", "空项目"), fixProject("p9", "调研项目")]
        client.agentsByProject["p7"] = []
        client.agentsByProject["p9"] = [fixAgent("a9", "调研助手")]
        let appState = makeLinkageAppState(client: client)
        appState.currentProjectId = "p9"
        appState.currentAgentId = "a9"
        let vm = ChatViewModel(appState: appState)
        let booted = await fixWaitFor { vm.bootstrapped }
        XCTAssertTrue(booted)

        appState.currentProjectId = "p7"
        appState.currentAgentId = nil

        let switched = await fixWaitFor { vm.projectId == "p7" && vm.projectMissingAgent }
        XCTAssertTrue(switched, "空项目选中 → 进入「该项目还没有 Agent」空态")
        XCTAssertTrue(client.createAgentCalls.isEmpty,
                      "空项目选中不得创建 Agent：\(client.createAgentCalls)")
        XCTAssertEqual(vm.agentName, "")
        XCTAssertEqual(vm.contextScope, "空项目")
        XCTAssertTrue(client.listSessionsCalls.allSatisfy { $0.pid != "p7" },
                      "无 Agent 不拉会话")
        XCTAssertNil(appState.currentAgentId, "规范化回写不得无中生有")
        XCTAssertNil(vm.currentSessionId)

        // 回到已有 Agent 的项目：仍落主 Agent（保留「选择」语义）
        appState.currentProjectId = "p9"
        let fellToMain = await fixWaitFor { vm.projectId == "p9" && vm.agentName == "调研助手" }
        XCTAssertTrue(fellToMain, "有 Agent 的项目仍自动落主 Agent")
        XCTAssertFalse(vm.projectMissingAgent)
        XCTAssertEqual(appState.currentAgentId, "a9", "规范化回写主 Agent id")
    }

    // 独立 Agent 面板「开始对话」入口：选中 + 跳聊天主页（U2：智能中心常驻聊天）
    func testIndependentAgentStartChatNavigates() async {
        let client = LinkageMockClient()
        let appState = makeLinkageAppState(client: client)
        let vm = IndependentAgentsPanelViewModel(appState: appState, clientOverride: client)
        let agent = IndependentAgent(id: "x9", name: "审校员")
        vm.startChat(agent)
        XCTAssertEqual(appState.currentProjectId, "ia-x9")
        XCTAssertEqual(appState.currentAgentId, "x9")
        XCTAssertNil(appState.currentSessionId)
        XCTAssertEqual(appState.selectedPanel.key, "chat", "应切到聊天主页（chatHome）")
        XCTAssertEqual(appState.selectedModule, .intelligence)
    }

    // 项目组面板「去对话」入口：选中 + 跳聊天主页
    func testProjectStartChatNavigates() async {
        let client = W5bMockClient()   // ProjectsPanelClient 全端点可注入（W5b 既有 mock）
        let appState = makeLinkageAppState(client: client)
        let vm = ProjectPanelViewModel(appState: appState, clientOverride: client)
        appState.currentProjectId = "p-old"
        appState.currentAgentId = "a-old"
        vm.startChat(fixProject("p3", "Demo"))
        XCTAssertEqual(appState.currentProjectId, "p3")
        XCTAssertNil(appState.currentAgentId, "换项目清旧 agent（主 Agent 由会话面板落）")
        XCTAssertNil(appState.currentSessionId)
        XCTAssertEqual(appState.selectedPanel.key, "chat")
        XCTAssertEqual(appState.selectedModule, .intelligence)
    }

    // U2：任务队列跳转——切上下文时消费 AppState.currentSessionId（修跳转丢目标会话，
    // 对齐 ChatPanel.tsx jumpToSessionId：目标会话在列表中 → 选中它而非首个）
    func testSwitchContextPicksJumpTargetSession() async throws {
        let client = LinkageMockClient()
        client.projects = [fixProject("p9", "调研项目")]
        client.agentsByProject["p9"] = [fixAgent("a9", "调研助手")]
        client.sessionsByContext["p9|a9"] = [
            ChatSession(id: "s1", title: "旧会话", message_count: 2),
            ChatSession(id: "s2", title: "委派会话", message_count: 4),
        ]
        let appState = makeLinkageAppState(client: client)
        // 模拟 TaskPanelViewModel.jumpToAgent 写入的三字段
        appState.currentProjectId = "p9"
        appState.currentAgentId = "a9"
        appState.currentSessionId = "s2"
        let vm = ChatViewModel(appState: appState)

        let ok = await fixWaitFor { vm.bootstrapped }
        XCTAssertTrue(ok)
        XCTAssertEqual(vm.currentSessionId, "s2", "目标会话在列表中 → 选中它而非 sessions.first")
        XCTAssertEqual(appState.currentSessionId, "s2")
    }

    // U2：目标会话不在新列表（已删除 / 跨上下文残留）→ 回落 sessions.first
    func testSwitchContextStaleSessionFallsBackToFirst() async throws {
        let client = LinkageMockClient()
        client.projects = [fixProject("p9", "调研项目")]
        client.agentsByProject["p9"] = [fixAgent("a9", "调研助手")]
        client.sessionsByContext["p9|a9"] = [
            ChatSession(id: "s1", title: "旧会话", message_count: 2),
            ChatSession(id: "s2", title: "委派会话", message_count: 4),
        ]
        let appState = makeLinkageAppState(client: client)
        appState.currentProjectId = "p9"
        appState.currentAgentId = "a9"
        appState.currentSessionId = "s-gone"   // 过期目标（其他上下文的会话残留）
        let vm = ChatViewModel(appState: appState)

        let ok = await fixWaitFor { vm.bootstrapped }
        XCTAssertTrue(ok)
        XCTAssertEqual(vm.currentSessionId, "s1", "目标不存在 → 回落 sessions.first")
    }
}

// MARK: - 0.7.6 补充一：输入框占位符命中穿透（「新建 Agent 后输入框无法输入文字」）

final class ComposerPlaceholderPassthroughTests: XCTestCase {

    /// 占位符 label 命中测试必须穿透——它是 ComposerNSTextView 的前柱子视图，
    /// AppKit 命中落在它上面时点击不会把焦点交给下面的 text view（label 拒当
    /// first responder，mouseDown 被空吞），表象「输入框无法输入文字」；
    /// 偶发性 = 取决于点击落点与既有焦点（新建 Agent 后输入框必空、占位符必
    /// 可见，且新建流程焦点在侧栏，点输入区首行即命中）。
    func testPlaceholderLabelHitTestPassesThrough() {
        let label = ComposerPassthroughLabel(labelWithString: "输入消息...")
        label.frame = NSRect(x: 0, y: 0, width: 200, height: 20)
        XCTAssertNil(label.hitTest(NSPoint(x: 10, y: 10)),
                     "占位符不得拦截鼠标事件（点击必须穿透落到下面的 text view）")
    }
}

// MARK: - 0.7.6 补充二：上下文指示器失败暂态（启动早期「获取失败」红字自愈）

@MainActor
final class ChatContextLimitRetryTests: XCTestCase {

    /// 失败暂态（活动后端暂不可达，source==error）不上屏红字——保持空态隐藏，
    /// 静默重试就绪后自然显示真值；错误态与成功态切换干净（失败永不落屏）。
    func testContextLimitErrorStaysHiddenAndHeals() async throws {
        let client = LinkageMockClient()
        client.projects = [fixProject("p9", "调研项目")]
        client.agentsByProject["p9"] = [fixAgent("a9", "调研助手")]
        client.contextLimitQueue = [ContextLimitInfo(limit: 0, source: "error"),
                                    ContextLimitInfo(limit: 8000, source: "ps")]
        client.contextLimitFallback = ContextLimitInfo(limit: 8000, source: "ps")
        let appState = makeLinkageAppState(client: client)
        appState.currentProjectId = "p9"
        appState.currentAgentId = "a9"
        let vm = ChatViewModel(appState: appState)
        vm.contextLimitRetryInterval = 0.05
        let booted = await fixWaitFor { vm.bootstrapped }
        XCTAssertTrue(booted)

        let healed = await fixWaitFor { vm.tokenIndicator.limit == 8000 }
        XCTAssertTrue(healed, "静默重试就绪后应显示真值")
        XCTAssertNil(vm.tokenIndicator.failedText, "全程不得上屏「上下文：获取失败」红字")
        XCTAssertEqual(vm.tokenIndicator.source, "ps")
    }

    /// 后端持续不可达：重试有界（≤5 次）后停止，指示器保持隐藏——
    /// 与「unsupported 前端隐藏指示器」同口径，不瞎兜底、不上屏红字。
    func testContextLimitErrorRetryExhaustedStaysHidden() async throws {
        let client = LinkageMockClient()
        client.projects = [fixProject("p9", "调研项目")]
        client.agentsByProject["p9"] = [fixAgent("a9", "调研助手")]
        client.contextLimitFallback = ContextLimitInfo(limit: 0, source: "error")
        let appState = makeLinkageAppState(client: client)
        appState.currentProjectId = "p9"
        appState.currentAgentId = "a9"
        let vm = ChatViewModel(appState: appState)
        vm.contextLimitRetryInterval = 0.05
        let booted = await fixWaitFor { vm.bootstrapped }
        XCTAssertTrue(booted)

        try await Task.sleep(nanoseconds: 800_000_000)   // 远超 5×50ms 重试窗
        XCTAssertEqual(vm.tokenIndicator.limit, 0)
        XCTAssertNil(vm.tokenIndicator.failedText, "重试耗尽也不上屏红字（隐藏口径）")
        // 有界：bootstrap 显式拉 + 模型 didSet 一次 + ≤5 次重试，不无限轮询
        XCTAssertLessThanOrEqual(client.fetchContextLimitCalls, 8,
                                 "失败重试必须有界：\(client.fetchContextLimitCalls)")
    }
}

// MARK: - 问题6：注册表收口（2 面板 / 工作流单入口 / 归并确认 / U2 聊天主页 / U3 仓库归位 / V1 智能中心无注册项 / V4 系统组移除）

final class PanelRegistryConsolidationTests: XCTestCase {

    func testTotalPanels2() {
        // V4 修正理由：设置整页覆盖复刻——「系统」组 10 个导航项（知识记忆/推理后端/
        // 模型包/模型选项/插件/仓库管理/基础设置/日志/数据诊断/关于）全部移出注册表，
        // 低频模块收进 SettingsPageView 内部导航（对齐 ModuleNav.tsx:44-47 只有两模块图标
        // + 底部设置齿轮；SettingsPage.tsx:38-44 五个内嵌分区）。注册表只剩流程中心 2 项。
        XCTAssertEqual(PanelRegistry.all.count, 2,
                       "问题6收口 21→19；U2 → 18；U3 → 17；V1 → 12；V4 系统组移除 → 2")
    }

    func testSystemModuleGroupRemoved() {
        // V4：ModuleGroup 只剩 智能中心/流程中心（ModuleNav.tsx:34 ModuleKey 只有两值）
        // W3（0.7 超级工作室）：rail 新增第三枚一级按钮「工作室」（总体规划 §一
        // 拍板：和智能中心、流程中心一样的独立一级模块）——allCases 随规格演进为三值。
        XCTAssertEqual(ModuleGroup.allCases, [.intelligence, .workflow, .studio])
        XCTAssertNil(ModuleGroup(rawValue: "system"),
                     "旧「系统」组模块键恢复落空 → AppState 启动兜底智能中心，不崩")
    }

    func testRemovedSystemPanelKeysFallBack() {
        // V4 修正理由：原 U3 断言系统组 10 键列表；V4 后这些键全部不可解析——
        // 各能力已内嵌：知识记忆/推理后端/模型包/插件管理 → 设置覆盖页内嵌分区；
        // 模型选项 → 推理后端内嵌（InferencePanelView:359 ModelOptionsEditorView）；
        // 仓库管理 → 知识记忆「知识仓库」标签（KnowledgePanelView:52 WarehouseManagerView）；
        // 日志/数据诊断 → 基础设置「打开日志文件夹/数据目录」按钮；
        // 设置/关于 → 覆盖页内部导航。旧记忆键恢复落空 → 启动兜底组默认面板，不崩。
        for key in ["warehouse", "knowledge", "inference", "model-packs", "model-options",
                    "plugins", "warehouse-manager", "settings", "logs", "diagnostics", "about"] {
            XCTAssertNil(PanelRegistry.panel(forKey: key),
                         "V4：\(key) 不再注册（设置覆盖页内嵌或删除），旧记忆键恢复落空兜底不崩")
        }
    }

    func testChatHomeNotInSidebarListButResolvable() {
        // U2 方案A：「会话」从智能中心组移除——聊天是内容区常驻主页，不占侧栏导航位
        XCTAssertFalse(PanelRegistry.all.contains { $0.key == "chat" },
                       "会话不再注册为智能中心面板")
        // V1：智能中心五面板（独立 Agent/项目/项目内 Agent/任务队列/圆桌）全部移出
        // 注册表——侧栏改单栏堆叠由 IntelligenceSidebarView 直接挂载（App.tsx:233-290），
        // 智能中心组不再有任何注册导航位
        XCTAssertEqual(PanelRegistry.panels(in: .intelligence).map { $0.key }, [],
                       "V1：智能中心组无注册项（五块由侧栏单栏堆叠直接挂载）")
        for key in ["independent-agents", "projects", "agents", "tasks", "roundtable"] {
            XCTAssertNil(PanelRegistry.panel(forKey: key),
                         "旧记忆键 \(key) 恢复落空 → 启动兜底 chatHome，不崩")
        }
        // 但 chatHome 键仍可解析：UserDefaults 记忆恢复 / 深链 / 导航目标不崩
        let home = PanelRegistry.panel(forKey: "chat")
        XCTAssertEqual(home?.key, "chat")
        XCTAssertEqual(home?.group, .intelligence)
        XCTAssertEqual(PanelRegistry.defaultPanel(in: .intelligence).key, "chat",
                       "智能中心默认落聊天主页（切模块即见聊天 / 引导空态）")
    }

    func testSingleWorkflowEntry() {
        let keys = PanelRegistry.all.map { $0.key }
        XCTAssertFalse(keys.contains("workflow-editor"), "工作流编辑器入口已移除（内嵌 WorkflowPanelView）")
        XCTAssertFalse(keys.contains("workflow-canvas"), "工作流画布入口已移除（内嵌 WorkflowPanelView）")
        let wf = PanelRegistry.panel(forKey: "workflows")
        XCTAssertEqual(wf?.status, .linked, "保留的「工作流」入口保持点亮")
        XCTAssertEqual(PanelRegistry.panels(in: .workflow).map { $0.key }, ["workflows", "cu-macro"])
    }

    @MainActor
    func testStaleWorkflowEditorDeepLinkFallsBack() {
        // 旧版本 UserDefaults 记忆了已移除的面板键 → 启动兜底到组默认面板，不崩溃
        let suite = "vetarai-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("workflow-editor", forKey: "ui.panel")
        let appState = TestRuntimeSupport.makeAppState(client: LinkageMockClient(), defaults: defaults)
        XCTAssertNotEqual(appState.selectedPanel.key, "workflow-editor")
        XCTAssertEqual(appState.selectedPanel.key, PanelRegistry.defaultPanel(in: .intelligence).key)
    }
}

// MARK: - V4：设置整页覆盖（rail 齿轮 / 覆盖开关 / 旧键兜底 / 深链分区）

@MainActor
final class SettingsOverlayV4Tests: XCTestCase {

    private func makeAppState(panelKey: String? = nil, moduleKey: String? = nil,
                              sectionKey: String? = nil) -> AppState {
        let suite = "vetarai-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        if let panelKey { defaults.set(panelKey, forKey: "ui.panel") }
        if let moduleKey { defaults.set(moduleKey, forKey: "ui.module") }
        if let sectionKey { defaults.set(sectionKey, forKey: "ui.settingsSection") }
        return TestRuntimeSupport.makeAppState(client: LinkageMockClient(), defaults: defaults)
    }

    // 齿轮开关：打开不改模块/面板（关闭回来源处，用户拍板口径；
    // 优于原版 App.tsx:204 onOpenSettings 强制 setActiveModule('intelligence')）
    func testToggleSettingsKeepsSourceModule() {
        let appState = makeAppState(panelKey: "workflows")
        XCTAssertEqual(appState.selectedModule, .workflow)
        appState.toggleSettings()
        XCTAssertTrue(appState.showSettings)
        XCTAssertEqual(appState.selectedModule, .workflow, "打开设置不离开流程中心")
        XCTAssertEqual(appState.selectedPanel.key, "workflows")
        appState.toggleSettings()
        XCTAssertFalse(appState.showSettings)
        XCTAssertEqual(appState.selectedModule, .workflow, "关闭设置回来源处")
        XCTAssertEqual(appState.selectedPanel.key, "workflows")
    }

    // 打开设置指定分区（0.7.1 Bug 7 前此例走 .about——macOS 菜单「关于」已改弹
    // 标准关于弹窗，.about 分区撤除；改用 .account 验证同一 openSettings 语义）
    func testOpenSettingsAtSection() {
        let appState = makeAppState()
        appState.openSettings(.account)
        XCTAssertTrue(appState.showSettings)
        XCTAssertEqual(appState.settingsSection, .account)
    }

    // 旧「settings」记忆键/深链 → 启动打开设置覆盖页 + 落聊天主页兜底（不崩）
    func testStaleSettingsKeyOpensOverlay() {
        let appState = makeAppState(panelKey: "settings")
        XCTAssertTrue(appState.showSettings)
        XCTAssertEqual(appState.selectedPanel.key, "chat")
        XCTAssertEqual(appState.selectedModule, .intelligence)
    }

    // 旧「系统」组模块键 + 系统组面板键 → 双双落空兜底智能中心默认面板（不崩、不开覆盖页）
    func testStaleSystemGroupKeysFallBack() {
        let appState = makeAppState(panelKey: "warehouse", moduleKey: "system")
        XCTAssertFalse(appState.showSettings)
        XCTAssertEqual(appState.selectedPanel.key, "chat")
        XCTAssertEqual(appState.selectedModule, .intelligence)
    }

    // 设置分区深链（tsx initialSection，0.4.30）：合法值采用，非法值回退 general
    func testSettingsSectionDeepLink() {
        XCTAssertEqual(makeAppState(sectionKey: "model-packs").settingsSection, .modelPacks)
        XCTAssertEqual(makeAppState(sectionKey: "cu").settingsSection, .cu)
        XCTAssertEqual(makeAppState(sectionKey: "bogus").settingsSection, .general)
        // 0.7.1 Bug 7：.about 分区撤除——旧版本留下的 "about" 记忆/深链值回退 general（不崩）
        XCTAssertEqual(makeAppState(sectionKey: "about").settingsSection, .general)
        XCTAssertEqual(makeAppState().settingsSection, .general)
    }

    // CU 跳转链路语义：关闭覆盖页 + 切流程中心 CU 宏（SettingsCUView 宏入口按钮口径）
    func testCUMacroJumpClosesOverlay() {
        let appState = makeAppState()
        appState.openSettings(.cu)
        // 模拟 SettingsCUView「打开 CU 宏面板」按钮
        appState.closeSettings()
        appState.selectPanel(PanelRegistry.panel(forKey: "cu-macro")!)
        XCTAssertFalse(appState.showSettings)
        XCTAssertEqual(appState.selectedPanel.key, "cu-macro")
        XCTAssertEqual(appState.selectedModule, .workflow)
    }
}

// MARK: - U3：知识仓库注入（输入框追加 + Toast，对齐 ChatPanel.tsx:3158-3162 onInject）

@MainActor
final class ChatKnowledgeInjectTests: XCTestCase {

    private func makeVM() -> ChatViewModel {
        let appState = makeLinkageAppState(client: LinkageMockClient())
        return ChatViewModel(appState: appState)
    }

    // 空输入框 → 直接放入；已有内容 → 空两行拼接（逐字对齐 setInput(prev => prev ? prev + '\n\n' + text : text)）
    func testInjectKnowledgeTextAppendsToInput() {
        let vm = makeVM()
        XCTAssertEqual(vm.input, "")
        vm.injectKnowledgeText("知识条目一")
        XCTAssertEqual(vm.input, "知识条目一", "空输入框直接放入注入文本")
        vm.injectKnowledgeText("知识条目二")
        XCTAssertEqual(vm.input, "知识条目一\n\n知识条目二", "已有内容空两行拼接")
        // Toast「知识已注入输入框，确认后发送」为 UI 侧效应（ToastCenter.shared），
        // 注入不直接发送、不动 messages——拉模式铁律由 send() 把关
        XCTAssertTrue(vm.messages.isEmpty, "注入只进输入框，不产生消息")
    }
}
