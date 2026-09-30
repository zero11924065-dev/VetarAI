//
//  W5bPanelTests.swift
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

//  ProjectPanel / IndependentAgentsPanel / CuMacroPanel 单测：
//    · 契约模型解码/编码（IndependentAgent 宽容解码 / 请求体 nil 键省略 /
//      CuReplayRun 宽容解码 / CuMacroRecordStartRequest mode 省略 / detailText 口径）
//    · ProjectPanelViewModel：首启退避重试 / 选择写全局上下文 / 删除收敛（含 HTTP 错误
//      视同完成的现状口径）/ 行内改名 / 目录选择三态分支 / 查看根目录 / 工作组导出闪示
//    · IndependentAgentsPanelViewModel：创建缺省值链 + 创建即选中（ia- 命名空间）/
//      删除清选中态 / 行内切换模型 / 行内编辑角色设定
//    · CuMacroPanelViewModel：refresh 录制态映射（recording_mode 兜底）/ 双模式 start /
//      权限引导链（未授权 → 请求授权 → 复查补发）/ 0 步 saved:false 警告 /
//      空宏回放拦截 / 删除清 run / 轮询只同步步数不翻面（F2 防抖）/ 命中率与进度纯函数
//
//  Mock 客户端为本文件私有（W5bMockClient），不改动既有测试文件的 Mock。
//

import XCTest
@testable import VetarAINative

// MARK: - W5b Mock 客户端（三个子协议全端点可注入/记录）

final class W5bMockClient: ProjectsPanelClient, IndependentAgentsPanelClient, CuMacroPanelClient {
    let baseURL = URL(string: "http://127.0.0.1:1/api")!

    // ── 注入结果 ──
    var projects: [SidecarProject] = []
    var listProjectsError: Error?
    /// 前 N 次 listProjects 调用强制失败（首启退避重试测试用；0 = 不启用）
    var listProjectsFailFirstCalls = 0
    var createProjectError: Error?
    var deleteProjectError: Error?
    var renameError: Error?
    var exportResult = WorkgroupExportResult(ok: true, path: "/tmp/exp/工作组.json", name: "工作组.json")
    var exportError: Error?
    var openDirResult = OpenWorkingDirResult(ok: true, dir: "/tmp/wd", detail: nil)
    var openDirError: Error?

    var independentAgents: [IndependentAgent] = []
    var listIndepError: Error?
    var models: [OllamaModel] = []
    var createIndepResult = "ia-new-1"
    var createIndepError: Error?
    var updateIndepError: Error?
    var deleteIndepError: Error?

    var cuListState = CuMacroListState(macros: [], recording: false, recordingSteps: 0, recordingMode: nil)
    var cuListError: Error?
    var cuPermission = CuUserRecordPermission(granted: true)
    var cuPermissionError: Error?
    var cuPermissionRequestResult = CuUserRecordPermission(granted: true)
    var cuStartError: Error?
    var cuStartCalls: [(name: String, mode: String?)] = []
    var cuStartServerName = ""
    var cuStopResult = CuMacroStopResult(saved: true, steps: 3, message: nil)
    var cuStopError: Error?
    var cuReplayResult = "run-1"
    var cuReplayError: Error?
    var cuRunStatus = CuReplayRun(run_id: "run-1", macro_id: "m1", macro_name: "宏1",
                                  status: "running", total: 3, completed: 1,
                                  failed_seq: nil, error: "", steps: [])
    var cuRunError: Error?
    var cuDeleteError: Error?

    // ── 调用记录 ──
    private(set) var listProjectsCalls = 0
    private(set) var createProjectCalls: [(name: String, dir: String)] = []
    private(set) var deleteProjectCalls: [String] = []
    private(set) var renameCalls: [(id: String, name: String)] = []
    private(set) var exportCalls: [String] = []
    private(set) var openDirCalls: [String] = []
    private(set) var listIndepCalls = 0
    private(set) var createIndepCalls: [(name: String, model: String?, prompt: String?)] = []
    private(set) var updateIndepCalls: [(id: String, update: IndependentAgentUpdateRequest)] = []
    private(set) var deleteIndepCalls: [String] = []
    private(set) var cuListCalls = 0
    private(set) var cuPermissionCalls = 0
    private(set) var cuPermissionRequestCalls = 0
    private(set) var cuStopCalls = 0
    private(set) var cuReplayCalls: [String] = []
    private(set) var cuRunStatusCalls: [String] = []
    private(set) var cuDeleteCalls: [String] = []

    // ── SidecarClientProtocol 基础端点（最小实现；W1/W2 端点走协议缺省桩）──
    func probeReady() async throws -> Bool { true }
    func listModels() async throws -> [OllamaModel] { models }
    func listProjects() async throws -> [SidecarProject] {
        listProjectsCalls += 1
        if listProjectsCalls <= listProjectsFailFirstCalls {
            throw SidecarError.offline("未就绪")
        }
        if let listProjectsError { throw listProjectsError }
        return projects
    }
    func createProject(name: String, workingDir: String) async throws -> String {
        createProjectCalls.append((name, workingDir))
        if let createProjectError { throw createProjectError }
        return "p-new"
    }
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

    // ── ProjectsPanelClient ──
    func renameProject(projectId: String, name: String) async throws {
        renameCalls.append((projectId, name))
        if let renameError { throw renameError }
    }
    func deleteProject(projectId: String) async throws {
        deleteProjectCalls.append(projectId)
        if let deleteProjectError { throw deleteProjectError }
    }
    func exportWorkgroup(projectId: String) async throws -> WorkgroupExportResult {
        exportCalls.append(projectId)
        if let exportError { throw exportError }
        return exportResult
    }
    func openWorkingDir(projectId: String) async throws -> OpenWorkingDirResult {
        openDirCalls.append(projectId)
        if let openDirError { throw openDirError }
        return openDirResult
    }

    // ── IndependentAgentsPanelClient ──
    func listIndependentAgents() async throws -> [IndependentAgent] {
        listIndepCalls += 1
        if let listIndepError { throw listIndepError }
        return independentAgents
    }
    func createIndependentAgent(name: String, modelName: String?, systemPrompt: String?) async throws -> String {
        createIndepCalls.append((name, modelName, systemPrompt))
        if let createIndepError { throw createIndepError }
        return createIndepResult
    }
    func updateIndependentAgent(agentId: String, update: IndependentAgentUpdateRequest) async throws {
        updateIndepCalls.append((agentId, update))
        if let updateIndepError { throw updateIndepError }
    }
    func deleteIndependentAgent(agentId: String) async throws {
        deleteIndepCalls.append(agentId)
        if let deleteIndepError { throw deleteIndepError }
    }

    // ── CuMacroPanelClient ──
    func listCuMacros() async throws -> CuMacroListState {
        cuListCalls += 1
        if let cuListError { throw cuListError }
        return cuListState
    }
    func cuUserRecordPermission() async throws -> CuUserRecordPermission {
        cuPermissionCalls += 1
        if let cuPermissionError { throw cuPermissionError }
        return cuPermission
    }
    func requestCuUserRecordPermission() async throws -> CuUserRecordPermission {
        cuPermissionRequestCalls += 1
        return cuPermissionRequestResult
    }
    func startCuMacroRecording(name: String, mode: String?) async throws -> String {
        cuStartCalls.append((name, mode))
        if let cuStartError { throw cuStartError }
        return cuStartServerName
    }
    func stopCuMacroRecording() async throws -> CuMacroStopResult {
        cuStopCalls += 1
        if let cuStopError { throw cuStopError }
        return cuStopResult
    }
    func replayCuMacro(macroId: String) async throws -> String {
        cuReplayCalls.append(macroId)
        if let cuReplayError { throw cuReplayError }
        return cuReplayResult
    }
    func cuMacroReplayStatus(runId: String) async throws -> CuReplayRun {
        cuRunStatusCalls.append(runId)
        if let cuRunError { throw cuRunError }
        return cuRunStatus
    }
    func deleteCuMacro(macroId: String) async throws {
        cuDeleteCalls.append(macroId)
        if let cuDeleteError { throw cuDeleteError }
    }
}

// MARK: - 测试工具

@MainActor
private func makeAppState(client: W5bMockClient) -> AppState {
    TestRuntimeSupport.makeAppState(client: client)
}

private func makeLogger() -> AppLogger {
    AppLogger(logDirectory: FileManager.default.temporaryDirectory
        .appendingPathComponent("vetarai-test-logs-\(UUID().uuidString)"))
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

private func makeProject(_ id: String, _ name: String? = nil) -> SidecarProject {
    // 经 JSON 解码构造（生产路径同构）
    let n = name ?? "项目-\(id)"
    let json = "{\"id\":\"\(id)\",\"name\":\"\(n)\",\"working_dir\":\"/tmp/\(id)\"}"
    return try! JSONDecoder().decode(SidecarProject.self, from: Data(json.utf8))
}

private func makeIndepAgent(_ id: String, name: String? = nil,
                            model: String? = nil, prompt: String? = nil) -> IndependentAgent {
    IndependentAgent(id: id, name: name ?? "独立-\(id)",
                     system_prompt: prompt, model_name: model, created_at: "2026-01-01 00:00:00")
}

private func makeMacro(_ id: String, name: String? = nil, steps: Int = 3) -> CuMacroSummary {
    CuMacroSummary(id: id, name: name ?? "宏-\(id)", created_at: "2026-01-01 00:00:00", steps: steps)
}

// MARK: - 契约模型解码 / 编码

final class W5bContractTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // IndependentAgent 全字段行（对齐 store.list_independent_agents 返回键）
    func testIndependentAgentFullRow() throws {
        let a = try decode(IndependentAgent.self, """
        {"id":"ia1","name":"文档审校员","role":null,"system_prompt":"你是审校员",
         "model_name":"qwen3.8","created_at":"2026-01-01 00:00:00"}
        """)
        XCTAssertEqual(a.id, "ia1")
        XCTAssertEqual(a.system_prompt, "你是审校员")
        XCTAssertEqual(a.model_name, "qwen3.8")
    }

    // 最小行宽容解码：仅 id，其余落缺省
    func testIndependentAgentMinimalRow() throws {
        let a = try decode(IndependentAgent.self, #"{"id":"ia2"}"#)
        XCTAssertEqual(a.name, "")
        XCTAssertNil(a.system_prompt)
        XCTAssertNil(a.model_name)
    }

    // 创建请求：nil 键省略（后端 None = 存 NULL）
    func testIndepCreateRequestOmitsNilKeys() throws {
        let body = IndependentAgentCreateRequest(name: "A")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(body)) as? [String: Any])
        XCTAssertEqual(obj.count, 1)
        XCTAssertEqual(obj["name"] as? String, "A")
        let body2 = IndependentAgentCreateRequest(name: "B", model_name: "m1", system_prompt: "设定")
        let obj2 = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(body2)) as? [String: Any])
        XCTAssertEqual(obj2["model_name"] as? String, "m1")
        XCTAssertEqual(obj2["system_prompt"] as? String, "设定")
    }

    // 更新请求：nil 键省略；空串照常编码（system_prompt:"" = 清除语义）
    func testIndepUpdateRequestKeepsEmptyString() throws {
        let body = IndependentAgentUpdateRequest(system_prompt: "")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(body)) as? [String: Any])
        XCTAssertEqual(obj.count, 1)
        XCTAssertEqual(obj["system_prompt"] as? String, "")
        let body2 = IndependentAgentUpdateRequest(model_name: "m2")
        let obj2 = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(body2)) as? [String: Any])
        XCTAssertEqual(obj2.count, 1)
        XCTAssertNil(obj2["system_prompt"])
    }

    // CU 录制 start 请求体：agent 模式 mode 键省略（现状零变化契约）；user 模式带 mode
    func testCuRecordStartRequestModeOmission() throws {
        let agent = CuMacroRecordStartRequest(name: "宏A", mode: nil)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(agent)) as? [String: Any])
        XCTAssertEqual(obj.count, 1, "agent 模式 body 只带 name（后端缺省 mode=agent）")
        XCTAssertNil(obj["mode"])
        let user = CuMacroRecordStartRequest(name: "宏B", mode: "user")
        let obj2 = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(user)) as? [String: Any])
        XCTAssertEqual(obj2["mode"] as? String, "user")
    }

    // CuReplayRun 宽容解码：缺键落缺省
    func testCuReplayRunTolerantDecode() throws {
        let run = try decode(CuReplayRun.self, #"{"run_id":"r1","macro_id":"m1"}"#)
        XCTAssertEqual(run.status, "running")
        XCTAssertEqual(run.total, 0)
        XCTAssertEqual(run.error, "")
        XCTAssertTrue(run.steps.isEmpty)
        let full = try decode(CuReplayRun.self, """
        {"run_id":"r2","macro_id":"m2","macro_name":"晨间整理","status":"error",
         "total":5,"completed":2,"failed_seq":3,"error":"第 3 步失败",
         "steps":[{"seq":1,"action":"click","method":"element","ok":true},
                  {"seq":3,"action":"click","method":"pixel_fallback","ok":false,"error":"未命中"}]}
        """)
        XCTAssertEqual(full.failed_seq, 3)
        XCTAssertEqual(full.steps.count, 2)
        XCTAssertEqual(full.steps[1].method, "pixel_fallback")
        XCTAssertEqual(full.steps[1].error, "未命中")
    }

    // CuMacroSummary 解码（steps 为步骤数）
    func testCuMacroSummaryDecode() throws {
        let m = try decode(CuMacroSummary.self,
                           #"{"id":"m1","name":"每日晨间整理","created_at":"2026-01-02 03:04:05","steps":7}"#)
        XCTAssertEqual(m.steps, 7)
        XCTAssertEqual(m.name, "每日晨间整理")
    }

    // detailText：apiJson 口径（httpError 只上屏 detail；非 HTTP 错误走 describe）
    func testDetailTextExtraction() {
        let http = SidecarError.httpError(status: 409, detail: "already_recording: 正在录制宏「x」")
        XCTAssertEqual(SidecarError.detailText(http), "already_recording: 正在录制宏「x」")
        let offline = SidecarError.offline("连接被拒")
        XCTAssertEqual(SidecarError.detailText(offline), "连接失败：连接被拒")
        XCTAssertEqual(SidecarError.detailText(SidecarError.timeout), "请求超时")
    }
}

// MARK: - ProjectPanelViewModel

@MainActor
final class ProjectPanelViewModelTests: XCTestCase {

    private func makeVM(client: W5bMockClient,
                        retryDelays: [TimeInterval] = [0],
                        noticeTTL: TimeInterval = 0.05) -> (ProjectPanelViewModel, AppState) {
        let appState = makeAppState(client: client)
        let vm = ProjectPanelViewModel(appState: appState, clientOverride: client,
                                       retryDelays: retryDelays, noticeTTL: noticeTTL)
        return (vm, appState)
    }

    // 拉取成功：列表落位 + 错误清空
    func testFetchSuccess() async {
        let client = W5bMockClient()
        client.projects = [makeProject("p1"), makeProject("p2")]
        let (vm, _) = makeVM(client: client)
        let ok = await vm.fetchProjects()
        XCTAssertTrue(ok)
        XCTAssertEqual(vm.projects.map(\.id), ["p1", "p2"])
        XCTAssertNil(vm.error)
    }

    // 拉取失败：上屏错误文案（常量口径），列表不动
    func testFetchFailureShowsConnectError() async {
        let client = W5bMockClient()
        client.listProjectsError = SidecarError.offline("连接被拒")
        let (vm, _) = makeVM(client: client)
        let ok = await vm.fetchProjects()
        XCTAssertFalse(ok)
        XCTAssertEqual(vm.error, ProjectPanelViewModel.connectError)
        XCTAssertTrue(vm.projects.isEmpty)
    }

    // MARK: R2（0.7.12 实测 A6）：新建项目默认名 = 绑定文件夹名

    // 基本口径：文件夹名作默认名（消费者心智「项目 = 文件夹」）
    func testDefaultProjectNameUsesFolderName() {
        XCTAssertEqual(ProjectPanelViewModel.defaultProjectName(
            forDir: "/Users/vetar/Documents/E2E测试项目目录", existingNames: []),
            "E2E测试项目目录")
    }

    // 重名冲突：追加序号取第一个空位
    func testDefaultProjectNameConflictGetsSequence() {
        XCTAssertEqual(ProjectPanelViewModel.defaultProjectName(
            forDir: "/a/素材库", existingNames: ["素材库"]), "素材库 2")
        XCTAssertEqual(ProjectPanelViewModel.defaultProjectName(
            forDir: "/a/素材库", existingNames: ["素材库", "素材库 2"]), "素材库 3")
        // 「素材库 2」被占但「素材库」空闲 → 不冲突直接用
        XCTAssertEqual(ProjectPanelViewModel.defaultProjectName(
            forDir: "/a/素材库", existingNames: ["素材库 2"]), "素材库")
    }

    // 路径形态：尾斜杠/手动输入空白包裹都取到真文件夹名
    func testDefaultProjectNamePathShapes() {
        XCTAssertEqual(ProjectPanelViewModel.defaultProjectName(
            forDir: "/a/b/我的项目/", existingNames: []), "我的项目")
        XCTAssertEqual(ProjectPanelViewModel.defaultProjectName(
            forDir: "  /a/b/调研  ", existingNames: []), "调研")
    }

    // 极端回退：文件夹名取不到（根目录/纯空白）→ 旧口径「项目 N」
    func testDefaultProjectNameFallback() {
        XCTAssertEqual(ProjectPanelViewModel.defaultProjectName(
            forDir: "/", existingNames: []), "项目 1")
        XCTAssertEqual(ProjectPanelViewModel.defaultProjectName(
            forDir: "   ", existingNames: ["x", "y"]), "项目 3")
    }

    // VM 接线：createWithDir 上送的名字 = 文件夹名（重名加序号）
    func testCreateWithDirSendsFolderDerivedName() async {
        let client = W5bMockClient()
        client.projects = [makeProject("p1", "素材"), makeProject("p2", "项目-p2")]
        let (vm, _) = makeVM(client: client)
        _ = await vm.fetchProjects()
        await vm.createWithDir("/Users/vetar/Documents/素材")   // 与现有项目「素材」同名
        XCTAssertEqual(client.createProjectCalls.last?.0, "素材 2",
                       "重名 → 文件夹名加序号")
        XCTAssertEqual(client.createProjectCalls.last?.1, "/Users/vetar/Documents/素材")
        await vm.createWithDir("/Users/vetar/Documents/全新目录")
        XCTAssertEqual(client.createProjectCalls.last?.0, "全新目录")
    }

    // 首启退避重试（checkpoint-064）：前 1 次失败第 2 次成功 → 收敛且错误清空
    func testInitialLoadRetriesWithBackoff() async {
        let client = W5bMockClient()
        client.projects = [makeProject("p1")]
        client.listProjectsFailFirstCalls = 1
        let (vm, _) = makeVM(client: client, retryDelays: [0, 0.02, 0.02])
        vm.start()
        let recovered = await waitFor { vm.projects.count == 1 }
        XCTAssertTrue(recovered)
        XCTAssertNil(vm.error)
        XCTAssertEqual(client.listProjectsCalls, 2, "第 1 次失败 → 退避后第 2 次成功")
        vm.stop()
    }

    // 全部重试失败：保留连接错误（错误条手动重试入口）
    func testInitialLoadAllFailKeepsError() async {
        let client = W5bMockClient()
        client.listProjectsError = SidecarError.offline("无侧车")
        let (vm, _) = makeVM(client: client, retryDelays: [0, 0.01, 0.01])
        vm.start()
        let done = await waitFor { client.listProjectsCalls >= 3 }
        XCTAssertTrue(done)
        XCTAssertEqual(vm.error, ProjectPanelViewModel.connectError)
        vm.stop()
    }

    // 选择项目：写 currentProjectId，并清旧项目作用域的 Agent/会话（换项目语义）
    func testSelectWritesAppStateAndClearsScope() async {
        let client = W5bMockClient()
        let (vm, appState) = makeVM(client: client)
        appState.currentProjectId = "p-old"
        appState.currentAgentId = "a-old"
        appState.currentSessionId = "s-old"
        vm.select(makeProject("p1"))
        XCTAssertEqual(appState.currentProjectId, "p1")
        XCTAssertNil(appState.currentAgentId)
        XCTAssertNil(appState.currentSessionId)
        // 重复选同一项目：幂等不清（无意义状态翻转）
        appState.currentAgentId = "a1"
        vm.select(makeProject("p1"))
        XCTAssertEqual(appState.currentAgentId, "a1", "同项目重选不应清 Agent")
    }

    // 删除：确认 → DELETE；删当前项目清全局选中态（checkpoint-056）；取消 → 不调端点
    func testDeleteFlow() async {
        let client = W5bMockClient()
        client.projects = [makeProject("p1"), makeProject("p2")]
        let (vm, appState) = makeVM(client: client)
        _ = await vm.fetchProjects()
        appState.currentProjectId = "p2"
        appState.currentAgentId = "a2"
        appState.currentSessionId = "s2"
        vm.confirmDelete = { name in
            XCTAssertEqual(name, "项目-p2", "确认弹窗应带项目名")
            return true
        }
        vm.delete(vm.projects[1])
        let ok1 = await waitFor { client.deleteProjectCalls == ["p2"] }
        XCTAssertTrue(ok1)
        let ok2 = await waitFor { appState.currentProjectId == nil }
        XCTAssertTrue(ok2, "删当前项目应清 currentProjectId")
        XCTAssertNil(appState.currentAgentId)
        XCTAssertNil(appState.currentSessionId)

        vm.confirmDelete = { _ in false }
        vm.delete(vm.projects[0])
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(client.deleteProjectCalls, ["p2"], "取消删除不得调端点")
    }

    // 删除非当前项目：不清选中态
    func testDeleteOtherProjectKeepsSelection() async {
        let client = W5bMockClient()
        client.projects = [makeProject("p1"), makeProject("p2")]
        let (vm, appState) = makeVM(client: client)
        _ = await vm.fetchProjects()
        appState.currentProjectId = "p2"
        vm.confirmDelete = { _ in true }
        vm.delete(vm.projects[0])
        let ok = await waitFor { client.deleteProjectCalls == ["p1"] }
        XCTAssertTrue(ok)
        XCTAssertEqual(appState.currentProjectId, "p2")
    }

    // 删除 HTTP 错误（如 404）：现状 fetch 不检响应码——视同完成照常清选中态 + 刷新
    func testDeleteHTTPErrorStillConverges() async {
        let client = W5bMockClient()
        client.projects = [makeProject("p1")]
        client.deleteProjectError = SidecarError.httpError(status: 404, detail: "项目不存在")
        let (vm, appState) = makeVM(client: client)
        _ = await vm.fetchProjects()
        appState.currentProjectId = "p1"
        vm.confirmDelete = { _ in true }
        let before = client.listProjectsCalls
        vm.delete(vm.projects[0])
        let ok = await waitFor { appState.currentProjectId == nil && client.listProjectsCalls > before }
        XCTAssertTrue(ok, "HTTP 错误应按现状口径照常收敛（清选中 + 刷新）")
    }

    // 删除网络层失败：现状 console.error 后不刷新、不清选中
    func testDeleteOfflineSkipsConvergence() async {
        let client = W5bMockClient()
        client.projects = [makeProject("p1")]
        client.deleteProjectError = SidecarError.offline("连接被拒")
        let (vm, appState) = makeVM(client: client)
        _ = await vm.fetchProjects()
        appState.currentProjectId = "p1"
        vm.confirmDelete = { _ in true }
        let before = client.listProjectsCalls
        vm.delete(vm.projects[0])
        let ok = await waitFor { !client.deleteProjectCalls.isEmpty }
        XCTAssertTrue(ok)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(appState.currentProjectId, "p1", "网络失败不得清选中态")
        XCTAssertEqual(client.listProjectsCalls, before, "网络失败不刷新")
    }

    // 行内改名：空名不请求直接退出编辑态；成功 PUT + 刷新 + 退编辑态
    func testRenameFlow() async {
        let client = W5bMockClient()
        client.projects = [makeProject("p1", "旧名")]
        let (vm, _) = makeVM(client: client)
        _ = await vm.fetchProjects()
        let p = vm.projects[0]

        vm.beginRename(p)
        XCTAssertEqual(vm.renamingId, "p1")
        XCTAssertEqual(vm.renameValue, "旧名")
        vm.renameValue = "   "
        vm.saveRename(p)
        XCTAssertNil(vm.renamingId, "空名直接取消")
        XCTAssertTrue(client.renameCalls.isEmpty, "空名不发请求")

        vm.beginRename(p)
        vm.renameValue = "新名字"
        vm.saveRename(p)
        let ok = await waitFor { !client.renameCalls.isEmpty }
        XCTAssertTrue(ok)
        XCTAssertEqual(client.renameCalls[0].id, "p1")
        XCTAssertEqual(client.renameCalls[0].name, "新名字")
        let done = await waitFor { vm.renamingId == nil && vm.renameValue == "" }
        XCTAssertTrue(done)
    }

    // 改名失败收敛（现状口径核对）：saveRename 的 catch 置「改名失败: <detail>」，
    // 但末尾 fetchProjects 开头即清错误（TSX setError(null)）——改名错误在侧车健康时
    // 转瞬即逝；侧车同时断开时终态为连接错误。断言：请求发出 + 退编辑态 + 刷新执行。
    func testRenameFailureConverges() async {
        let client = W5bMockClient()
        client.projects = [makeProject("p1")]
        client.renameError = SidecarError.httpError(status: 404, detail: "项目不存在")
        let (vm, _) = makeVM(client: client)
        _ = await vm.fetchProjects()
        let before = client.listProjectsCalls
        vm.beginRename(vm.projects[0])
        vm.renameValue = "x"
        vm.saveRename(vm.projects[0])
        let ok = await waitFor { !client.renameCalls.isEmpty && client.listProjectsCalls > before }
        XCTAssertTrue(ok)
        XCTAssertNil(vm.renamingId, "失败也退编辑态（对齐现状）")
        XCTAssertNil(vm.error, "改名错误被紧随的刷新清空（对齐现状 setError(null) 顺序）")

        // 侧车同时断开：终态为连接错误（改名错误的瞬态已被覆盖）
        client.listProjectsError = SidecarError.offline("断")
        vm.beginRename(vm.projects[0])
        vm.renameValue = "y"
        vm.saveRename(vm.projects[0])
        let ok2 = await waitFor { vm.error == ProjectPanelViewModel.connectError }
        XCTAssertTrue(ok2)
    }

    // 新建三态分支：取消 = 直接取消创建；不可用 = 落手动输入；选中 = 创建
    func testCreatePickerBranches() async {
        let client = W5bMockClient()
        let (vm, _) = makeVM(client: client)
        _ = await vm.fetchProjects()

        // 取消分支
        vm.pickDirectory = { .cancelled }
        vm.create()
        let ok1 = await waitFor { !vm.loading }
        XCTAssertTrue(ok1)
        XCTAssertTrue(client.createProjectCalls.isEmpty, "取消选择器不得创建")
        XCTAssertFalse(vm.manualMode)

        // 不可用分支 → manualMode
        vm.pickDirectory = { .unavailable }
        vm.create()
        let ok2 = await waitFor { vm.manualMode }
        XCTAssertTrue(ok2)
        XCTAssertTrue(client.createProjectCalls.isEmpty)

        // 手动输入：留空 = 取消（退出手动模式，不发请求）
        vm.manualPath = "   "
        vm.createManual()
        XCTAssertFalse(vm.manualMode)
        XCTAssertTrue(client.createProjectCalls.isEmpty)

        // 选中分支：R2（0.7.12 实测 A6）起默认名 = 绑定文件夹名（旧「项目 N」口径退役，
        // 仅文件夹名取不到时回退——命名纯逻辑钉桩见 defaultProjectName 系列）
        vm.pickDirectory = { .picked("/tmp/demo") }
        vm.create()
        let ok3 = await waitFor { !client.createProjectCalls.isEmpty }
        XCTAssertTrue(ok3)
        XCTAssertEqual(client.createProjectCalls[0].name, "demo")
        XCTAssertEqual(client.createProjectCalls[0].dir, "/tmp/demo")
        let ok4 = await waitFor { !vm.loading }
        XCTAssertTrue(ok4)
    }

    // 手动输入确认：路径走 createWithDir，成功后退出手动态并清空
    func testCreateManualWithPath() async {
        let client = W5bMockClient()
        let (vm, _) = makeVM(client: client)
        _ = await vm.fetchProjects()
        vm.manualMode = true
        vm.manualPath = " /tmp/manual "
        vm.createManual()
        let ok = await waitFor { !client.createProjectCalls.isEmpty }
        XCTAssertTrue(ok)
        XCTAssertEqual(client.createProjectCalls[0].dir, "/tmp/manual")
        let done = await waitFor { !vm.manualMode && vm.manualPath == "" }
        XCTAssertTrue(done, "成功后应清手动态")
    }

    // 创建失败：错误上屏「创建失败: <detail>」
    func testCreateFailureSetsError() async {
        let client = W5bMockClient()
        client.createProjectError = SidecarError.httpError(status: 400, detail: "工作目录不能为空")
        let (vm, _) = makeVM(client: client)
        _ = await vm.fetchProjects()
        vm.pickDirectory = { .picked("/tmp/x") }
        vm.create()
        let ok = await waitFor { vm.error != nil }
        XCTAssertTrue(ok)
        XCTAssertEqual(vm.error, "创建失败: 工作目录不能为空")
        XCTAssertFalse(vm.loading)
    }

    // error 存在时新建按钮禁用（现状 disabled={loading || !!error} 语义）
    func testCreateBlockedWhileError() async {
        let client = W5bMockClient()
        let (vm, _) = makeVM(client: client)
        _ = await vm.fetchProjects()
        client.renameError = SidecarError.httpError(status: 500, detail: "x")
        // 制造 error 态
        client.listProjectsError = SidecarError.offline("断")
        _ = await vm.fetchProjects()
        XCTAssertNotNil(vm.error)
        vm.pickDirectory = { .picked("/tmp/y") }
        vm.create()
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertTrue(client.createProjectCalls.isEmpty, "error 态下不得发起创建")
    }

    // 查看根目录：HTTP 错误上屏；200 软失败（ok:false）不上屏（现状静默忽略）
    func testOpenWorkingDir() async {
        let client = W5bMockClient()
        client.projects = [makeProject("p1")]
        let (vm, _) = makeVM(client: client)
        _ = await vm.fetchProjects()

        // 软失败：ok=false + detail → 静默（仅日志）
        client.openDirResult = OpenWorkingDirResult(ok: false, dir: "/tmp/x", detail: "打开超时")
        vm.openWorkingDir(vm.projects[0])
        var ok = await waitFor { !client.openDirCalls.isEmpty && vm.openingDirId == nil }
        XCTAssertTrue(ok)
        XCTAssertNil(vm.error, "软失败不上屏（对齐现状静默忽略）")

        // HTTP 错误：上屏「打开工作目录失败: <detail>」
        client.openDirError = SidecarError.httpError(status: 400, detail: "工作目录不存在：/tmp/x")
        vm.openWorkingDir(vm.projects[0])
        ok = await waitFor { vm.error != nil }
        XCTAssertTrue(ok)
        XCTAssertEqual(vm.error, "打开工作目录失败: 工作目录不存在：/tmp/x")
    }

    // 工作组导出：成功闪示（目录 = path 去末段）；失败闪示「导出失败：…」；TTL 自动消隐
    func testExportWorkgroupNotice() async {
        let client = W5bMockClient()
        client.projects = [makeProject("p1")]
        client.exportResult = WorkgroupExportResult(ok: true, path: "/Users/a/exports/p1-工作组.json",
                                                    name: "p1-工作组.json")
        let (vm, _) = makeVM(client: client, noticeTTL: 0.05)
        _ = await vm.fetchProjects()
        vm.exportWorkgroup(vm.projects[0])
        var ok = await waitFor { vm.notice != nil }
        XCTAssertTrue(ok)
        XCTAssertEqual(vm.notice, "工作组已导出：p1-工作组.json（目录：/Users/a/exports）")
        ok = await waitFor { vm.notice == nil }
        XCTAssertTrue(ok, "通知应按 TTL 自动消隐")

        client.exportError = SidecarError.httpError(status: 404, detail: "项目不存在")
        vm.exportWorkgroup(vm.projects[0])
        ok = await waitFor { vm.notice?.hasPrefix("导出失败") == true }
        XCTAssertTrue(ok)
        XCTAssertEqual(vm.notice, "导出失败：项目不存在")
    }
}

// MARK: - IndependentAgentsPanelViewModel

@MainActor
final class IndependentAgentsPanelViewModelTests: XCTestCase {

    private func makeVM(client: W5bMockClient) -> (IndependentAgentsPanelViewModel, AppState) {
        let appState = makeAppState(client: client)
        let vm = IndependentAgentsPanelViewModel(appState: appState, clientOverride: client)
        return (vm, appState)
    }

    // 拉取失败静默（现状 catch{} 语义：不抛错、不上屏、列表保持）
    func testFetchSilentFailure() async {
        let client = W5bMockClient()
        client.listIndepError = SidecarError.offline("断")
        let (vm, _) = makeVM(client: client)
        await vm.fetchAgents()
        XCTAssertTrue(vm.agents.isEmpty)
    }

    // 创建：空名缺省「独立 Agent N」；模型空串 → nil；角色设定空白 → nil；
    // 成功清空输入 + 刷新 + 直接进入对话（选中新建的，ia- 命名空间）
    func testCreateDefaultsAndAutoSelect() async {
        let client = W5bMockClient()
        client.independentAgents = [makeIndepAgent("ia-a")]
        client.models = [OllamaModel(name: "m1", size: nil)]
        client.createIndepResult = "ia-new-9"
        let (vm, appState) = makeVM(client: client)
        await vm.fetchAgents()
        vm.newName = "   "
        vm.newModel = ""
        vm.newPrompt = "  "
        vm.create()
        let ok1 = await waitFor { !client.createIndepCalls.isEmpty }
        XCTAssertTrue(ok1)
        let call = client.createIndepCalls[0]
        XCTAssertEqual(call.name, "独立 Agent 2", "空名缺省为 独立 Agent N（N=列表数+1）")
        XCTAssertNil(call.model)
        XCTAssertNil(call.prompt)
        let ok2 = await waitFor { appState.currentAgentId == "ia-new-9" }
        XCTAssertTrue(ok2, "创建成功后应直接选中（进入对话）")
        XCTAssertEqual(appState.currentProjectId, "ia-ia-new-9", "命名空间 ia-<id> 作为项目作用域")
        XCTAssertNil(appState.currentSessionId)
        XCTAssertEqual(vm.newName, "")
        XCTAssertFalse(vm.creating)
    }

    // 创建：显式字段透传
    func testCreateWithAllFields() async {
        let client = W5bMockClient()
        let (vm, _) = makeVM(client: client)
        vm.newName = "文档审校员"
        vm.newModel = "qwen3.8"
        vm.newPrompt = "你是严谨的文档审校员"
        vm.create()
        let ok = await waitFor { !client.createIndepCalls.isEmpty }
        XCTAssertTrue(ok)
        XCTAssertEqual(client.createIndepCalls[0].name, "文档审校员")
        XCTAssertEqual(client.createIndepCalls[0].model, "qwen3.8")
        XCTAssertEqual(client.createIndepCalls[0].prompt, "你是严谨的文档审校员")
    }

    // 创建失败：弹「创建失败」+ detail 原文（apiJson 口径）
    func testCreateFailureAlerts() async {
        let client = W5bMockClient()
        client.createIndepError = SidecarError.httpError(status: 422, detail: "名称不能为空")
        let (vm, _) = makeVM(client: client)
        var alerts: [(String, String)] = []
        vm.alertPresenter = { t, m in alerts.append((t, m)) }
        vm.create()
        let ok = await waitFor { !alerts.isEmpty }
        XCTAssertTrue(ok)
        XCTAssertEqual(alerts[0].0, "创建失败")
        XCTAssertEqual(alerts[0].1, "名称不能为空")
        XCTAssertFalse(vm.creating)
    }

    // 删除：确认 → DELETE；删当前选中项清全局选中态（checkpoint-061）；失败弹「删除失败」
    func testDeleteFlow() async {
        let client = W5bMockClient()
        client.independentAgents = [makeIndepAgent("a1"), makeIndepAgent("a2")]
        let (vm, appState) = makeVM(client: client)
        await vm.fetchAgents()
        appState.currentProjectId = "ia-a2"
        appState.currentAgentId = "a2"
        appState.currentSessionId = "s2"
        vm.confirmDelete = { agent in
            XCTAssertEqual(agent.id, "a2")
            return true
        }
        vm.delete(vm.agents[1])
        let ok1 = await waitFor { client.deleteIndepCalls == ["a2"] }
        XCTAssertTrue(ok1)
        let ok2 = await waitFor { appState.currentAgentId == nil }
        XCTAssertTrue(ok2, "删当前选中项应清空选中态")
        XCTAssertNil(appState.currentProjectId, "ia- 命名空间选中态应一并清除")
        XCTAssertNil(appState.currentSessionId)

        // 取消不调端点
        vm.confirmDelete = { _ in false }
        vm.delete(vm.agents[0])
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(client.deleteIndepCalls, ["a2"])

        // 失败弹窗
        client.deleteIndepError = SidecarError.httpError(status: 404, detail: "独立 Agent 不存在")
        vm.confirmDelete = { _ in true }
        var alerts: [(String, String)] = []
        vm.alertPresenter = { t, m in alerts.append((t, m)) }
        vm.delete(vm.agents[0])
        let ok3 = await waitFor { !alerts.isEmpty }
        XCTAssertTrue(ok3)
        XCTAssertEqual(alerts[0].0, "删除失败")
        XCTAssertEqual(alerts[0].1, "独立 Agent 不存在")
    }

    // 删除非当前选中项：不清选中态
    func testDeleteOtherKeepsSelection() async {
        let client = W5bMockClient()
        client.independentAgents = [makeIndepAgent("a1"), makeIndepAgent("a2")]
        let (vm, appState) = makeVM(client: client)
        await vm.fetchAgents()
        appState.currentProjectId = "ia-a2"
        appState.currentAgentId = "a2"
        vm.confirmDelete = { _ in true }
        vm.delete(vm.agents[0])
        let ok = await waitFor { client.deleteIndepCalls == ["a1"] }
        XCTAssertTrue(ok)
        XCTAssertEqual(appState.currentAgentId, "a2")
        XCTAssertEqual(appState.currentProjectId, "ia-a2")
    }

    // 行内切换模型：PUT 仅带 model_name；空值不触发（现状「默认」占位项语义）；
    // 失败也照常刷新（现状 fetchAgents() 不挂在 ok 分支上）
    func testSwitchModel() async {
        let client = W5bMockClient()
        let agent = makeIndepAgent("a1", model: "m1")
        client.independentAgents = [agent]
        let (vm, _) = makeVM(client: client)
        vm.switchModel(agent, to: "")
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertTrue(client.updateIndepCalls.isEmpty, "空模型值不触发请求")

        vm.switchModel(agent, to: "m2")
        let ok = await waitFor { !client.updateIndepCalls.isEmpty }
        XCTAssertTrue(ok)
        XCTAssertEqual(client.updateIndepCalls[0].update.model_name, "m2")
        XCTAssertNil(client.updateIndepCalls[0].update.system_prompt)

        client.updateIndepError = SidecarError.httpError(status: 404, detail: "x")
        let before = client.listIndepCalls
        vm.switchModel(agent, to: "m3")
        let ok2 = await waitFor { client.listIndepCalls > before }
        XCTAssertTrue(ok2, "失败仍照常刷新（对齐现状）")
    }

    // 行内编辑角色设定：PUT {system_prompt}；留空保存 = 清除（空串照传）
    func testSavePrompt() async {
        let client = W5bMockClient()
        let agent = makeIndepAgent("a1", prompt: "旧设定")
        client.independentAgents = [agent]
        let (vm, _) = makeVM(client: client)
        vm.beginEdit(agent)
        XCTAssertEqual(vm.editingId, "a1")
        XCTAssertEqual(vm.editText, "旧设定")
        vm.editText = ""
        vm.savePrompt(agent)
        let ok = await waitFor { !client.updateIndepCalls.isEmpty }
        XCTAssertTrue(ok)
        XCTAssertEqual(client.updateIndepCalls[0].update.system_prompt, "")
        XCTAssertNil(client.updateIndepCalls[0].update.name)
        let done = await waitFor { vm.editingId == nil && !vm.savingPrompt }
        XCTAssertTrue(done)
    }

    // 保存失败：弹「保存失败」，保持编辑态
    func testSavePromptFailureKeepsEditing() async {
        let client = W5bMockClient()
        client.updateIndepError = SidecarError.httpError(status: 404, detail: "独立 Agent 不存在或无有效更新字段")
        let agent = makeIndepAgent("a1")
        let (vm, _) = makeVM(client: client)
        var alerts: [(String, String)] = []
        vm.alertPresenter = { t, m in alerts.append((t, m)) }
        vm.beginEdit(agent)
        vm.savePrompt(agent)
        let ok = await waitFor { !alerts.isEmpty }
        XCTAssertTrue(ok)
        XCTAssertEqual(alerts[0].0, "保存失败")
        XCTAssertEqual(vm.editingId, "a1", "失败不应退出编辑态")
        XCTAssertFalse(vm.savingPrompt)
    }

    // 选中：写 ia- 命名空间上下文（对齐 App.tsx selectIndependentAgent）
    func testSelectWritesNamespace() {
        let client = W5bMockClient()
        let (vm, appState) = makeVM(client: client)
        appState.currentSessionId = "s-old"
        vm.select(makeIndepAgent("a9"))
        XCTAssertEqual(appState.currentProjectId, "ia-a9")
        XCTAssertEqual(appState.currentAgentId, "a9")
        XCTAssertNil(appState.currentSessionId)
    }

    // 行高亮选中源：isSelected 实时跟随 appState.currentAgentId（0.7.5 实测修复——
    // 侧栏列表视图订阅 AppState 环境后以此为准：任意来源切 agent，白色选中立即翻转，
    // 不再滞后到手风琴折叠/展开重建）
    func testIsSelectedFollowsAppState() {
        let client = W5bMockClient()
        let (vm, appState) = makeVM(client: client)
        let a1 = makeIndepAgent("a1")
        let a2 = makeIndepAgent("a2")
        XCTAssertFalse(vm.isSelected(a1))
        XCTAssertFalse(vm.isSelected(a2))
        appState.currentProjectId = "ia-a1"
        appState.currentAgentId = "a1"
        XCTAssertTrue(vm.isSelected(a1))
        XCTAssertFalse(vm.isSelected(a2))
        // 模拟从会话/他处切走（非本列表点击）：选中源同步翻转
        appState.currentProjectId = "ia-a2"
        appState.currentAgentId = "a2"
        XCTAssertFalse(vm.isSelected(a1))
        XCTAssertTrue(vm.isSelected(a2))
        appState.currentAgentId = nil
        XCTAssertFalse(vm.isSelected(a2))
    }
}

// MARK: - CuMacroPanelViewModel

@MainActor
final class CuMacroPanelViewModelTests: XCTestCase {

    private func makeVM(client: W5bMockClient,
                        pollInterval: TimeInterval = 60) -> CuMacroPanelViewModel {
        CuMacroPanelViewModel(clientProvider: { client },
                              pollInterval: pollInterval, logger: makeLogger())
    }

    // refresh：列表 + 录制态映射（recording_mode user/agent/nil；录制中缺键按 agent 兜底）
    func testRefreshMapsRecordingState() async {
        let client = W5bMockClient()
        client.cuListState = CuMacroListState(macros: [makeMacro("m1", steps: 5)],
                                              recording: true, recordingSteps: 4,
                                              recordingMode: "user")
        let vm = makeVM(client: client)
        await vm.refresh()
        XCTAssertEqual(vm.macros?.count, 1)
        XCTAssertTrue(vm.recording)
        XCTAssertEqual(vm.recordingSteps, 4)
        XCTAssertEqual(vm.recordingMode, .user)

        // 录制中缺 mode 键 → agent 兜底（旧后端无该键时只有 agent 录制）
        client.cuListState = CuMacroListState(macros: [], recording: true,
                                              recordingSteps: 1, recordingMode: nil)
        await vm.refresh()
        XCTAssertEqual(vm.recordingMode, .agent)

        // 未录制 → mode nil + 录制名清空
        client.cuListState = CuMacroListState(macros: [], recording: false,
                                              recordingSteps: 0, recordingMode: nil)
        await vm.refresh()
        XCTAssertFalse(vm.recording)
        XCTAssertNil(vm.recordingMode)
        XCTAssertEqual(vm.recordingName, "")
    }

    // refresh 失败：错误上屏
    func testRefreshFailureSetsError() async {
        let client = W5bMockClient()
        client.cuListError = SidecarError.offline("断")
        let vm = makeVM(client: client)
        await vm.refresh()
        XCTAssertEqual(vm.error, "读取宏列表失败: 连接失败：断")
    }

    // 「录制 Agent 操作」：body 只带 name（mode nil）；start 成功落本地录制态
    func testStartAgentRecord() async {
        let client = W5bMockClient()
        client.cuStartServerName = "晨间整理"
        let vm = makeVM(client: client)
        vm.recName = " 晨间整理 "
        vm.startRecord()
        let ok = await waitFor { vm.recording }
        XCTAssertTrue(ok)
        XCTAssertEqual(client.cuStartCalls.count, 1)
        XCTAssertEqual(client.cuStartCalls[0].name, "晨间整理", "名称去首尾空白")
        XCTAssertNil(client.cuStartCalls[0].mode, "agent 模式 mode 必须省略（后端缺省 agent）")
        XCTAssertEqual(vm.recordingName, "晨间整理", "以服务端登记名为准")
        XCTAssertEqual(vm.recordingMode, .agent)
        XCTAssertEqual(vm.recordingSteps, 0)
        XCTAssertEqual(vm.recName, "", "start 成功后清输入框")
        XCTAssertFalse(vm.busy)
    }

    // 空名称 / busy 防重
    func testStartGuards() async {
        let client = W5bMockClient()
        let vm = makeVM(client: client)
        vm.recName = "   "
        vm.startRecord()
        vm.startUserRecord()
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertTrue(client.cuStartCalls.isEmpty, "空名称不得发起录制")
    }

    // 「录制我的操作」：未授权 → 引导 callout，不发 start
    func testStartUserRecordDenied() async {
        let client = W5bMockClient()
        client.cuPermission = CuUserRecordPermission(granted: false)
        let vm = makeVM(client: client)
        vm.recName = "我的宏"
        vm.startUserRecord()
        let ok = await waitFor { vm.permDenied }
        XCTAssertTrue(ok)
        XCTAssertTrue(client.cuStartCalls.isEmpty, "未授权不得发 start")
        XCTAssertFalse(vm.recording)
        XCTAssertFalse(vm.busy)
    }

    // 已授权 → POST start {name, mode:"user"}
    func testStartUserRecordGranted() async {
        let client = W5bMockClient()
        client.cuPermission = CuUserRecordPermission(granted: true)
        let vm = makeVM(client: client)
        vm.recName = "我的宏"
        vm.startUserRecord()
        let ok = await waitFor { vm.recording }
        XCTAssertTrue(ok)
        XCTAssertEqual(client.cuStartCalls[0].mode, "user")
        XCTAssertEqual(vm.recordingMode, .user)
        XCTAssertFalse(vm.permDenied)
    }

    // start 403 input_monitoring_not_granted（权限被收回等）→ 落引导 callout 而非错误条
    func testStart403FallsToPermissionGuide() async {
        let client = W5bMockClient()
        client.cuStartError = SidecarError.httpError(
            status: 403, detail: "input_monitoring_not_granted: 「输入监控」权限未授予…")
        let vm = makeVM(client: client)
        vm.recName = "宏"
        vm.startRecord()
        let ok = await waitFor { vm.permDenied }
        XCTAssertTrue(ok)
        XCTAssertNil(vm.error)
        XCTAssertFalse(vm.recording)
    }

    // 409 互斥冲突 → 错误条 detail 原文上屏（可读提示）
    func testStart409ReadableConflict() async {
        let client = W5bMockClient()
        client.cuStartError = SidecarError.httpError(
            status: 409, detail: "already_recording: 正在录制宏「x」（user 模式），请先停止当前录制")
        let vm = makeVM(client: client)
        vm.recName = "宏"
        vm.startRecord()
        let ok = await waitFor { vm.error != nil }
        XCTAssertTrue(ok)
        XCTAssertEqual(vm.error, "开始录制失败: already_recording: 正在录制宏「x」（user 模式），请先停止当前录制")
        XCTAssertFalse(vm.permDenied)
    }

    // 「请求授权」链：POST request → GET 复查 granted → 直接补发 user start
    func testRequestPermissionThenAutoStart() async {
        let client = W5bMockClient()
        client.cuPermission = CuUserRecordPermission(granted: false)
        client.cuPermissionRequestResult = CuUserRecordPermission(granted: true)
        let vm = makeVM(client: client)
        vm.recName = "我的宏"
        // 先走一次未授权（落引导态）
        vm.startUserRecord()
        _ = await waitFor { vm.permDenied }
        // 复查时改为已授权
        client.cuPermission = CuUserRecordPermission(granted: true)
        vm.requestPermission()
        let ok = await waitFor { vm.recording }
        XCTAssertTrue(ok, "复查已授权应直接补发 user start")
        XCTAssertEqual(client.cuPermissionRequestCalls, 1)
        XCTAssertEqual(client.cuStartCalls.last?.mode, "user")
        XCTAssertFalse(vm.permDenied)
        XCTAssertFalse(vm.permBusy)
    }

    // 复查仍未授权 → 保持引导 callout，不发 start
    func testRequestPermissionStillDenied() async {
        let client = W5bMockClient()
        client.cuPermission = CuUserRecordPermission(granted: false)
        client.cuPermissionRequestResult = CuUserRecordPermission(granted: false)
        let vm = makeVM(client: client)
        vm.recName = "我的宏"
        // 先走一次未授权（落引导态）
        vm.startUserRecord()
        _ = await waitFor { vm.permDenied }
        vm.requestPermission()
        let ok = await waitFor { client.cuPermissionRequestCalls == 1 && !vm.permBusy }
        XCTAssertTrue(ok)
        XCTAssertTrue(vm.permDenied, "复查未授权应保持引导 callout")
        XCTAssertTrue(client.cuStartCalls.isEmpty)
        XCTAssertFalse(vm.recording)
    }

    // 停止：saved:true → 刷新列表；saved:false（0 步契约）→ 警告原文上屏且不 refresh
    func testStopRecordSavedVsEmpty() async {
        let client = W5bMockClient()
        client.cuListState = CuMacroListState(macros: [makeMacro("m1")], recording: false,
                                              recordingSteps: 0, recordingMode: nil)
        let vm = makeVM(client: client)
        await vm.refresh()
        // 进入录制态
        vm.recName = "宏"
        vm.startRecord()
        _ = await waitFor { vm.recording }

        // saved:true → 刷新出新宏
        client.cuStopResult = CuMacroStopResult(saved: true, steps: 3, message: nil)
        client.cuListState = CuMacroListState(macros: [makeMacro("m2", name: "宏", steps: 3)],
                                              recording: false, recordingSteps: 0, recordingMode: nil)
        let before = client.cuListCalls
        vm.stopRecord()
        var ok = await waitFor { !vm.recording && client.cuListCalls > before }
        XCTAssertTrue(ok, "saved:true 应 refresh 出新宏")
        XCTAssertNil(vm.warn)
        XCTAssertEqual(vm.macros?.first?.id, "m2")

        // saved:false → 警告原文上屏，⛔ 不 refresh
        vm.recName = "空宏"
        vm.startRecord()
        _ = await waitFor { vm.recording }
        client.cuStopResult = CuMacroStopResult(saved: false, steps: 0,
                                                message: "未捕获到任何动作，宏未保存")
        let before2 = client.cuListCalls
        vm.stopRecord()
        ok = await waitFor { vm.warn != nil }
        XCTAssertTrue(ok)
        XCTAssertEqual(vm.warn, "未捕获到任何动作，宏未保存")
        XCTAssertEqual(client.cuListCalls, before2, "0 步未落盘不得 refresh（列表无新项可刷）")
        XCTAssertFalse(vm.recording)
        XCTAssertEqual(vm.recordingSteps, 0)
        XCTAssertNil(vm.recordingMode)
    }

    // 停止失败：错误条上屏
    func testStopRecordFailure() async {
        let client = W5bMockClient()
        let vm = makeVM(client: client)
        vm.recName = "宏"
        vm.startRecord()
        _ = await waitFor { vm.recording }
        client.cuStopError = SidecarError.httpError(status: 422, detail: "not_recording: 当前没有进行中的录制")
        vm.stopRecord()
        let ok = await waitFor { vm.error != nil }
        XCTAssertTrue(ok)
        XCTAssertEqual(vm.error, "停止录制失败: not_recording: 当前没有进行中的录制")
    }

    // 回放：空宏拦截（双保险）；成功 → run 初始化 running；422 空宏 detail 上屏
    func testStartReplay() async {
        let client = W5bMockClient()
        let vm = makeVM(client: client)
        // 空宏（含历史遗留）不回放
        vm.startReplay(makeMacro("m0", steps: 0))
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertTrue(client.cuReplayCalls.isEmpty, "空宏不得发起回放")

        // 正常宏 → run 落位 running
        vm.startReplay(makeMacro("m1", name: "晨间整理", steps: 5))
        var ok = await waitFor { vm.run != nil }
        XCTAssertTrue(ok)
        XCTAssertEqual(vm.run?.run_id, "run-1")
        XCTAssertEqual(vm.run?.status, "running")
        XCTAssertEqual(vm.run?.total, 5)
        XCTAssertTrue(vm.runActive)

        // 进行中防重
        vm.startReplay(makeMacro("m2", steps: 2))
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(client.cuReplayCalls.count, 1, "回放进行中不得再启动")

        // 422 空宏 detail 上屏（按钮置灰后的服务端兜底路径）
        let vm2 = makeVM(client: client)
        client.cuReplayError = SidecarError.httpError(status: 422, detail: "empty_macro: 宏没有可回放的步骤")
        vm2.startReplay(makeMacro("m3", steps: 1))
        ok = await waitFor { vm2.error != nil }
        XCTAssertTrue(ok)
        XCTAssertEqual(vm2.error, "回放启动失败: empty_macro: 宏没有可回放的步骤")
        XCTAssertNil(vm2.run)
    }

    // 删除：确认 → DELETE；删正在回放的宏清 run；取消不调端点
    func testDeleteMacro() async {
        let client = W5bMockClient()
        client.cuListState = CuMacroListState(macros: [makeMacro("m1"), makeMacro("m2")],
                                              recording: false, recordingSteps: 0, recordingMode: nil)
        let vm = makeVM(client: client)
        await vm.refresh()
        // 先起回放
        vm.startReplay(vm.macros![0])
        _ = await waitFor { vm.run != nil }

        vm.confirmDelete = { m in
            XCTAssertEqual(m.id, "m1")
            return true
        }
        client.cuListState = CuMacroListState(macros: [makeMacro("m2")], recording: false,
                                              recordingSteps: 0, recordingMode: nil)
        vm.delete(makeMacro("m1"))
        let ok = await waitFor { client.cuDeleteCalls == ["m1"] && vm.macros?.count == 1 }
        XCTAssertTrue(ok)
        XCTAssertNil(vm.run, "删正在回放的宏应清 run")
        XCTAssertFalse(vm.busy)

        vm.confirmDelete = { _ in false }
        vm.delete(makeMacro("m2"))
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(client.cuDeleteCalls, ["m1"], "取消删除不得调端点")
    }

    // 录制中轮询：只同步步数，⛔ 不翻面 recording 开关态（0.4.33 F2 防抖）
    func testRecordingPollSyncsStepsOnly() async {
        let client = W5bMockClient()
        // 服务端录制中（refresh 收敛录制态）
        client.cuListState = CuMacroListState(macros: [], recording: true,
                                              recordingSteps: 3, recordingMode: "agent")
        let vm = makeVM(client: client, pollInterval: 0.05)
        vm.start()
        let settled = await waitFor { vm.recording && vm.recordingSteps == 3 }
        XCTAssertTrue(settled)
        // 对端步数增长、甚至对端已被他端停止（recording:false）：轮询只同步步数，
        // 本地录制态不得被闪没（F2：stop 落盘宏后由列表刷新收敛）
        client.cuListState = CuMacroListState(macros: [], recording: false,
                                              recordingSteps: 7, recordingMode: nil)
        let ok = await waitFor { vm.recordingSteps == 7 }
        XCTAssertTrue(ok)
        XCTAssertTrue(vm.recording, "轮询只同步步数，不得翻面录制开关态")
        vm.stop()
        let calls = client.cuListCalls
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(client.cuListCalls, calls, "stop 后轮询应停")
    }

    // 回放轮询：running 时逐拍更新 run；done 后停更新
    func testReplayPollUpdatesRun() async {
        let client = W5bMockClient()
        client.cuRunStatus = CuReplayRun(run_id: "run-1", macro_id: "m1", macro_name: "宏",
                                         status: "running", total: 3, completed: 1,
                                         failed_seq: nil, error: "",
                                         steps: [CuReplayStep(seq: 1, action: "click", method: "element", ok: true)])
        let vm = makeVM(client: client, pollInterval: 0.05)
        vm.startReplay(makeMacro("m1", steps: 3))
        _ = await waitFor { vm.run != nil }
        vm.start()
        let ok = await waitFor { vm.run?.completed == 1 }
        XCTAssertTrue(ok)
        // done 后：轮询继续跑但条件不满足（run.status != running），状态定格
        client.cuRunStatus = CuReplayRun(run_id: "run-1", macro_id: "m1", macro_name: "宏",
                                         status: "done", total: 3, completed: 3,
                                         failed_seq: nil, error: "", steps: [])
        let ok2 = await waitFor { vm.run?.status == "done" }
        XCTAssertTrue(ok2)
        let calls = client.cuRunStatusCalls
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(client.cuRunStatusCalls, calls, "done 后不再拉回放状态")
        vm.stop()
    }

    // 命中率（回放口径）与进度纯函数
    func testHitRateAndProgress() {
        let steps = [
            CuReplayStep(seq: 1, action: "click", method: "element", ok: true),
            CuReplayStep(seq: 2, action: "click", method: "element", ok: true),
            CuReplayStep(seq: 3, action: "click", method: "pixel_fallback", ok: true),
            CuReplayStep(seq: 4, action: "type", method: "payload", ok: true),
        ]
        let hr = CuMacroPanelViewModel.hitRate(steps: steps)
        XCTAssertEqual(hr.element, 2)
        XCTAssertEqual(hr.pixelFallback, 1)
        XCTAssertEqual(hr.percent, 67)   // 2/3 ≈ 66.67 → Math.round = 67
        XCTAssertNil(CuMacroPanelViewModel.hitRate(steps: []).percent, "样本 0 = 暂无回放样本")
        XCTAssertNil(CuMacroPanelViewModel.hitRate(
            steps: [CuReplayStep(seq: 1, action: "type", method: "payload", ok: true)]).percent)

        let run = CuReplayRun(run_id: "r", macro_id: "m", macro_name: "", status: "running",
                              total: 3, completed: 2, failed_seq: nil, error: "", steps: [])
        XCTAssertEqual(CuMacroPanelViewModel.progressPercent(run: run), 67)
        XCTAssertEqual(CuMacroPanelViewModel.progressPercent(run: nil), 0)
        let zero = CuReplayRun(run_id: "r", macro_id: "m", macro_name: "", status: "running",
                               total: 0, completed: 0, failed_seq: nil, error: "", steps: [])
        XCTAssertEqual(CuMacroPanelViewModel.progressPercent(run: zero), 0)
    }

    // 录制态文案双模式（R4：recording_mode 分叉）
    func testRecordingModeCopy() async {
        let client = W5bMockClient()
        let vm = makeVM(client: client)
        vm.recName = "宏"
        vm.startRecord()
        _ = await waitFor { vm.recording }
        XCTAssertEqual(vm.recordingMode, .agent)
        // 文案由 View 拼：● 正在录制「宏」 · 录制 Agent 操作中…已捕获 N 步——此后 Agent 的每个 CU 动作都会记为一步
        // 此处锚定 VM 侧提供的状态即可（文案拼装属 View 层）
    }
}
