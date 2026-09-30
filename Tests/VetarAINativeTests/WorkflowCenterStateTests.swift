//
//  WorkflowCenterStateTests.swift
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

//  流程中心共享态（WorkflowCenterState）联动单测：
//    · attach 懒建并共享 工作流/CU 宏 VM（幂等——侧栏手风琴与内容区同一实例）
//    · 点工作流行 → selectPanel("workflows")（模块联动）+ 共享 VM 选中回填
//    · 点宏行 → selectPanel("cu-macro") + 共享 CU VM 选中
//    · 侧栏「+」新建 → 切「工作流」面板 + VM create（成功后选中新项）
//    · 删除选中宏 → 清选中态；删除非选中宏 → 选中态保留
//    · CU VM selected 计算属性随列表收敛；attach/detach 计数生命周期
//
//  Mock 客户端为本文件私有（V5MockClient），不改动既有测试文件的 Mock。
//

import XCTest
@testable import VetarAINative

// MARK: - V5 Mock 客户端（工作流 + CU 宏双协议，可注入/记录）

final class V5MockClient: SidecarClientProtocol, WorkflowPanelClient, CuMacroPanelClient {
    let baseURL = URL(string: "http://127.0.0.1:1/api")!

    // ── 注入结果 ──
    var workflows: [WorkflowRecord] = []
    var createWorkflowResult = "wf-new"
    var cuListState = CuMacroListState(macros: [], recording: false,
                                     recordingSteps: 0, recordingMode: nil)
    var cuDeleteError: Error?

    // ── 调用记录 ──
    private(set) var listWorkflowsCalls = 0
    private(set) var createWorkflowCalls: [String] = []
    private(set) var cuDeleteCalls: [String] = []

    // ── SidecarClientProtocol 基础端点（最小实现；其余走协议缺省桩）──
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

    // ── WorkflowPanelClient ──
    func listWorkflows() async throws -> [WorkflowRecord] {
        listWorkflowsCalls += 1
        return workflows
    }
    func createWorkflow(name: String, description: String,
                        definition: WorkflowDefinition) async throws -> String {
        createWorkflowCalls.append(name)
        return createWorkflowResult
    }
    func getWorkflow(id: String) async throws -> WorkflowRecord {
        guard let wf = workflows.first(where: { $0.id == id }) else {
            throw SidecarError.httpError(status: 404, detail: "工作流不存在")
        }
        return wf
    }
    func updateWorkflow(id: String, update: WorkflowUpdateRequest) async throws {}
    func deleteWorkflow(id: String) async throws {}
    func runWorkflow(id: String, params: [String: JSONValue]) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func listWorkflowRuns(workflowId: String?, limit: Int) async throws -> [WorkflowRunRecord] { [] }
    func getWorkflowRun(id: String) async throws -> WorkflowRunDetail {
        throw SidecarError.httpError(status: 404, detail: "运行记录不存在")
    }
    func approveWorkflowRun(runId: String, approved: Bool, comment: String) async throws {}
    func stopWorkflowRun(runId: String) async throws {}
    func fetchInferenceModels() async throws -> [InferenceModelEntry] { [] }
    func appEventsStream(since: Int) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    // ── CuMacroPanelClient ──
    func listCuMacros() async throws -> CuMacroListState { cuListState }
    func cuUserRecordPermission() async throws -> CuUserRecordPermission {
        CuUserRecordPermission(granted: true)
    }
    func requestCuUserRecordPermission() async throws -> CuUserRecordPermission {
        CuUserRecordPermission(granted: true)
    }
    func startCuMacroRecording(name: String, mode: String?) async throws -> String { name }
    func stopCuMacroRecording() async throws -> CuMacroStopResult {
        CuMacroStopResult(saved: true, steps: 3, message: nil)
    }
    func replayCuMacro(macroId: String) async throws -> String { "run-1" }
    func cuMacroReplayStatus(runId: String) async throws -> CuReplayRun {
        CuReplayRun(run_id: runId, macro_id: "m1", macro_name: "宏-m1",
                    status: "done", total: 3, completed: 3,
                    failed_seq: nil, error: "", steps: [])
    }
    func deleteCuMacro(macroId: String) async throws {
        cuDeleteCalls.append(macroId)
        if let cuDeleteError { throw cuDeleteError }
    }
}

// MARK: - 测试工具

@MainActor
private func makeAppState(client: V5MockClient) -> AppState {
    TestRuntimeSupport.makeAppState(client: client)
}

/// 轮询等待条件成立（替代固定 sleep，降低时序抖动）。
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

private func makeWorkflow(_ id: String, name: String? = nil,
                          builtIn: Bool = false) -> WorkflowRecord {
    WorkflowRecord(id: id, name: name ?? "流程\(id)",
                   description: "描述\(id)",
                   definition: WorkflowDefinition(
                    nodes: [WorkflowNode(id: "start", type: "start", props: ["label": .string("开始")]),
                            WorkflowNode(id: "n2", type: "end", props: ["label": .string("结束")])],
                    edges: [WorkflowEdge(from: "start", to: "n2")]),
                   builtIn: builtIn)
}

private func makeMacro(_ id: String, name: String? = nil, steps: Int = 3) -> CuMacroSummary {
    CuMacroSummary(id: id, name: name ?? "宏-\(id)", created_at: "2026-01-01 00:00:00", steps: steps)
}

// MARK: - WorkflowCenterState 联动

@MainActor
final class WorkflowCenterStateTests: XCTestCase {

    private func makeCenter(client: V5MockClient) -> (WorkflowCenterState, AppState) {
        let appState = makeAppState(client: client)
        // P3-W6：runtime init 同步点亮 nativeReady 且 clientOverride 直注 mock——
        // 无需再 start() 驱动状态机（历史：sidecar.start() 同步装好 client）
        let center = WorkflowCenterState()
        center.attach(appState: appState)
        return (center, appState)
    }

    // attach：懒建双 VM 并共享（幂等——重复 attach 不重建，侧栏/内容区同一实例）
    func testAttachBuildsSharedVMsOnce() {
        let client = V5MockClient()
        let (center, appState) = makeCenter(client: client)
        XCTAssertNotNil(center.workflowVM)
        XCTAssertNotNil(center.cuMacroVM)
        let wf = center.workflowVM
        let cu = center.cuMacroVM
        center.attach(appState: appState)
        XCTAssertTrue(center.workflowVM === wf, "重复 attach 不得重建工作流 VM")
        XCTAssertTrue(center.cuMacroVM === cu, "重复 attach 不得重建 CU 宏 VM")
    }

    // 点工作流行：切「工作流」面板（模块联动）+ 共享 VM 选中回填
    func testSelectWorkflowSwitchesPanelAndSelects() async {
        let client = V5MockClient()
        let (center, appState) = makeCenter(client: client)
        // 先落在 CU 宏面板，验证跨面板切换
        appState.selectPanel(PanelRegistry.panel(forKey: "cu-macro")!)
        let wf = makeWorkflow("w1")
        client.workflows = [wf]
        await center.workflowVM?.loadWorkflows()

        center.selectWorkflow(wf)

        XCTAssertEqual(appState.selectedPanel.key, "workflows")
        XCTAssertEqual(appState.selectedModule, .workflow)
        XCTAssertEqual(center.workflowVM?.selectedId, "w1")
        XCTAssertEqual(center.workflowVM?.name, "流程w1", "选中回填名称（同源选中态）")
        XCTAssertNotNil(center.workflowVM?.selected)
    }

    // 点宏行：切「CU 宏」面板 + 共享 CU VM 选中
    func testSelectMacroSwitchesPanelAndSelects() async {
        let client = V5MockClient()
        let (center, appState) = makeCenter(client: client)
        appState.selectPanel(PanelRegistry.panel(forKey: "workflows")!)
        let macro = makeMacro("m1")
        client.cuListState = CuMacroListState(macros: [macro], recording: false,
                                              recordingSteps: 0, recordingMode: nil)
        await center.cuMacroVM?.refresh()

        center.selectMacro(macro)

        XCTAssertEqual(appState.selectedPanel.key, "cu-macro")
        XCTAssertEqual(appState.selectedModule, .workflow)
        XCTAssertEqual(center.cuMacroVM?.selectedId, "m1")
        XCTAssertEqual(center.cuMacroVM?.selected, macro, "详情卡数据源 = 同一选中态")
    }

    // 侧栏「+」新建：切「工作流」面板 + VM create（成功后选中新项）
    func testCreateWorkflowSwitchesPanelAndCreates() async {
        let client = V5MockClient()
        let (center, appState) = makeCenter(client: client)
        appState.selectPanel(PanelRegistry.panel(forKey: "cu-macro")!)

        center.createWorkflow()

        XCTAssertEqual(appState.selectedPanel.key, "workflows")
        let ok = await waitFor { !client.createWorkflowCalls.isEmpty }
        XCTAssertTrue(ok)
        XCTAssertEqual(client.createWorkflowCalls.first, "新工作流")
        let ok2 = await waitFor { center.workflowVM?.selectedId == "wf-new" }
        XCTAssertTrue(ok2, "新建成功后共享 VM 选中新项（内容区同源联动）")
    }

    // 侧栏 CU 宏「+」录制新宏：切「CU 宏」面板（零宏时进面板的唯一入口，P3-W4 收口修复）
    func testOpenCuMacroPanelSwitchesPanel() async {
        let client = V5MockClient()
        let (center, appState) = makeCenter(client: client)
        appState.selectPanel(PanelRegistry.panel(forKey: "workflows")!)

        center.openCuMacroPanel()

        XCTAssertEqual(appState.selectedPanel.key, "cu-macro")
        XCTAssertEqual(appState.selectedModule, .workflow)
    }

    // 删除选中宏 → 清选中态（内容区详情卡回落引导空态）
    func testDeleteSelectedMacroClearsSelection() async {
        let client = V5MockClient()
        let m1 = makeMacro("m1")
        let m2 = makeMacro("m2")
        client.cuListState = CuMacroListState(macros: [m1, m2], recording: false,
                                              recordingSteps: 0, recordingMode: nil)
        let (center, _) = makeCenter(client: client)
        let vm = center.cuMacroVM!
        vm.confirmDelete = { _ in true }
        await vm.refresh()
        vm.select(m1)
        XCTAssertEqual(vm.selectedId, "m1")

        vm.delete(m1)

        let ok = await waitFor { client.cuDeleteCalls == ["m1"] }
        XCTAssertTrue(ok)
        let ok2 = await waitFor { vm.selectedId == nil }
        XCTAssertTrue(ok2, "删除选中宏后必须清选中态")
    }

    // 删除非选中宏 → 选中态保留
    func testDeleteOtherMacroKeepsSelection() async {
        let client = V5MockClient()
        let m1 = makeMacro("m1")
        let m2 = makeMacro("m2")
        client.cuListState = CuMacroListState(macros: [m1, m2], recording: false,
                                              recordingSteps: 0, recordingMode: nil)
        let (center, _) = makeCenter(client: client)
        let vm = center.cuMacroVM!
        vm.confirmDelete = { _ in true }
        await vm.refresh()
        vm.select(m1)

        vm.delete(m2)

        let ok = await waitFor { client.cuDeleteCalls == ["m2"] }
        XCTAssertTrue(ok)
        let ok2 = await waitFor { !vm.busy }
        XCTAssertTrue(ok2)
        XCTAssertEqual(vm.selectedId, "m1", "删除非选中宏不得动选中态")
    }

    // selected 计算属性：列表重拉后选中项不在列表中 → 视为未选中（详情卡回落空态）
    func testSelectedConvergesWithList() async {
        let client = V5MockClient()
        let m1 = makeMacro("m1")
        client.cuListState = CuMacroListState(macros: [m1], recording: false,
                                              recordingSteps: 0, recordingMode: nil)
        let (center, _) = makeCenter(client: client)
        let vm = center.cuMacroVM!
        await vm.refresh()
        vm.select(m1)
        XCTAssertEqual(vm.selected, m1)

        client.cuListState = CuMacroListState(macros: [], recording: false,
                                              recordingSteps: 0, recordingMode: nil)
        await vm.refresh()
        XCTAssertNil(vm.selected, "选中项已不在列表中 → selected 为 nil")
    }

    // attach/detach 计数生命周期：首个挂载点启动拉列表；过量 detach 钳 0 不崩；
    // 归零后再 attach 可重新启动（侧栏/内容区双挂载点任一存活即不停的底座）
    func testWorkflowVMAttachDetachLifecycle() async {
        let client = V5MockClient()
        let (center, _) = makeCenter(client: client)
        let vm = center.workflowVM!

        vm.attach()
        let ok = await waitFor { client.listWorkflowsCalls >= 1 }
        XCTAssertTrue(ok, "首个挂载点出现即启动拉列表")

        vm.detach()
        vm.detach()   // 过量 detach 钳 0（对齐圆桌 max(0, count-1) 口径）
        vm.attach()
        let ok2 = await waitFor { client.listWorkflowsCalls >= 2 }
        XCTAssertTrue(ok2, "归零后重新挂载可再次启动")
        vm.detach()
    }
}
