//
//  TaskAgentPanelTests.swift
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

//  TaskPanel / AgentPanel 单测：
//    · TaskElapsed 已耗时格式化与 UTC 解析（checkpoint-067 N-3 口径）
//    · AgentTask / AgentTaskReport 宽容解码（REST 行与 SSE snapshot 同构）
//    · AgentCreateRequest / AgentUpdateRequest 编码（nil 键省略 = 后端 exclude_none 语义）
//    · TaskPanelViewModel 事件分发（snapshot/status/tool_call/tool_result/progress/
//      task_end/gap 逐分支）+ 重试/停止消息流（文案逐字）+ 6s 自动消隐
//    · AgentPanelViewModel 创建缺省值链 / 删除确认 / 行内编辑保存 / 切换模型 / 8s 轮询
//
//  Mock 客户端为本文件私有（W1MockClient），不改动 Wave 0 测试文件里的 MockSidecarClient。
//

import XCTest
@testable import VetarAINative

// MARK: - W1 Mock 客户端（全协议方法可注入/记录）

final class W1MockClient: SidecarClientProtocol {
    let baseURL = URL(string: "http://127.0.0.1:1/api")!

    // 注入结果
    var tasks: [AgentTask] = []
    var listTasksError: Error?
    var retryResult = TaskRetryResult(newTaskId: "t-new", ok: true, error: nil)
    var retryError: Error?
    var stopError: Error?
    var agents: [SidecarAgent] = []
    var models: [OllamaModel] = []
    var createAgentError: Error?
    var updateAgentError: Error?

    // 调用记录
    private(set) var listTasksCalls = 0
    private(set) var retryCalls: [String] = []
    private(set) var stopCalls: [String] = []
    private(set) var listAgentsCalls = 0
    private(set) var createCalls: [(name: String, type: String, model: String?, prompt: String?)] = []
    private(set) var updateCalls: [(agentId: String, update: AgentUpdateRequest)] = []
    private(set) var deleteCalls: [String] = []

    // SSE 进度流控制
    private(set) var tasksStreamCalls = 0
    private var streamContinuation: AsyncThrowingStream<SSEEvent, Error>.Continuation?
    private var streamFinished = false

    func pushStreamEvent(_ ev: SSEEvent) { streamContinuation?.yield(ev) }
    func finishStream(throwing error: Error? = nil) {
        if let error { streamContinuation?.finish(throwing: error) }
        else { streamContinuation?.finish() }
        streamFinished = true
    }

    // MARK: SidecarClientProtocol

    func probeReady() async throws -> Bool { true }
    func listModels() async throws -> [OllamaModel] { models }
    func listProjects() async throws -> [SidecarProject] { [] }
    func createProject(name: String, workingDir: String) async throws -> String { "p1" }
    func listAgents(projectId: String) async throws -> [SidecarAgent] {
        listAgentsCalls += 1
        return agents
    }
    func createAgent(projectId: String, name: String, type: String, modelName: String?) async throws -> String {
        createCalls.append((name, type, modelName, nil))
        return "a-new"
    }
    func listSessions(projectId: String, agentId: String) async throws -> [ChatSession] { [] }
    func createSession(projectId: String, agentId: String, title: String) async throws -> String { "s1" }
    func loadMessages(projectId: String, sessionId: String) async throws -> [ChatMessage] { [] }
    func stopChat(sessionId: String) async throws {}
    func respondAuth(_ body: AuthRespondRequest) async throws {}
    func chatStream(_ body: ChatStreamRequest) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func listTasks(projectId: String, limit: Int) async throws -> [AgentTask] {
        listTasksCalls += 1
        if let listTasksError { throw listTasksError }
        return tasks
    }
    func retryTask(projectId: String, taskId: String) async throws -> TaskRetryResult {
        retryCalls.append(taskId)
        if let retryError { throw retryError }
        return retryResult
    }
    func stopTask(projectId: String, taskId: String) async throws {
        stopCalls.append(taskId)
        if let stopError { throw stopError }
    }
    func tasksStream(projectId: String) -> AsyncThrowingStream<SSEEvent, Error> {
        tasksStreamCalls += 1
        return AsyncThrowingStream { cont in self.streamContinuation = cont }
    }
    func createAgent(projectId: String, name: String, type: String,
                     modelName: String?, systemPrompt: String?) async throws -> String {
        if let createAgentError { throw createAgentError }
        createCalls.append((name, type, modelName, systemPrompt))
        return "a-new"
    }
    func updateAgent(projectId: String, agentId: String, update: AgentUpdateRequest) async throws {
        if let updateAgentError { throw updateAgentError }
        updateCalls.append((agentId, update))
    }
    func deleteAgent(projectId: String, agentId: String) async throws {
        deleteCalls.append(agentId)
    }
}

// MARK: - 测试工具

@MainActor
private func makeAppState() -> AppState {
    TestRuntimeSupport.makeAppState(client: W1MockClient())
}

private func sse(_ event: String, _ data: [String: Any] = [:]) -> SSEEvent {
    SSEEvent(event: event, data: data, rawData: "")
}

private func makeTask(_ id: String, status: String = "running",
                      target: String = "子Agent", targetId: String? = "a1",
                      createdAt: String? = nil) -> AgentTask {
    AgentTask(id: id, target_agent_name: target, task: "任务\(id)",
              status: status, target_agent_id: targetId, created_at: createdAt)
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

// MARK: - TaskElapsed

final class TaskElapsedTests: XCTestCase {

    // fmtElapsed 三档（逐字对齐 TaskPanel.tsx）
    func testFormatTiers() {
        XCTAssertEqual(TaskElapsed.format(seconds: 0), "0s")
        XCTAssertEqual(TaskElapsed.format(seconds: 45), "45s")
        XCTAssertEqual(TaskElapsed.format(seconds: 59), "59s")
        XCTAssertEqual(TaskElapsed.format(seconds: 60), "1m0s")
        XCTAssertEqual(TaskElapsed.format(seconds: 125), "2m5s")
        XCTAssertEqual(TaskElapsed.format(seconds: 3599), "59m59s")
        XCTAssertEqual(TaskElapsed.format(seconds: 3600), "1h0m")
        XCTAssertEqual(TaskElapsed.format(seconds: 3661), "1h1m")
    }

    // created_at 按 UTC 解析（SQLite datetime('now') 口径，补 Z 语义）
    func testParseCreatedAtAsUTC() throws {
        let d = try XCTUnwrap(TaskElapsed.parseCreatedAt("2026-01-02 03:04:05"))
        // 与前端 Date.parse("2026-01-02T03:04:05Z") 同值
        XCTAssertEqual(d.timeIntervalSince1970, 1_767_323_045, accuracy: 1)
        XCTAssertNil(TaskElapsed.parseCreatedAt("not-a-date"))
    }

    // 已耗时端到端：now - created_at → 格式化；负值钳 0
    func testElapsedEndToEnd() {
        let start = TaskElapsed.parseCreatedAt("2026-01-02 03:04:05")!
        let now = start.addingTimeInterval(90)
        XCTAssertEqual(TaskElapsed.elapsed(createdAt: "2026-01-02 03:04:05", now: now), "1m30s")
        XCTAssertEqual(TaskElapsed.elapsed(createdAt: nil, now: now), nil)
        XCTAssertEqual(TaskElapsed.elapsed(createdAt: "bad", now: now), nil)
    }
}

// MARK: - 契约模型解码 / 编码

final class TaskAgentContractTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // REST 行全字段（对齐 store.py list_agent_tasks 返回键）
    func testAgentTaskFullRow() throws {
        let t = try decode(AgentTask.self, """
        {"id":"t1","parent_agent_id":"a0","parent_session_id":"s0",
         "target_agent_id":"a1","target_agent_name":"代码审查员",
         "task":"审查 PR","expect":"给出结论","status":"done",
         "report":{"status":"ok","summary":"全部通过","prompt_eval_count":1234},
         "fail_reason":null,"validation_failures":0,"session_id":"s1",
         "created_at":"2026-01-02 03:04:05","updated_at":"2026-01-02 03:05:05"}
        """)
        XCTAssertEqual(t.id, "t1")
        XCTAssertEqual(t.target_agent_name, "代码审查员")
        XCTAssertEqual(t.status, "done")
        XCTAssertEqual(t.report?.summary, "全部通过")
        XCTAssertEqual(t.report?.prompt_eval_count, 1234)
        XCTAssertEqual(t.session_id, "s1")
        XCTAssertFalse(t.isActive)
    }

    // 最小行宽容解码：仅 id，其余落缺省
    func testAgentTaskMinimalRow() throws {
        let t = try decode(AgentTask.self, #"{"id":"t2"}"#)
        XCTAssertEqual(t.status, "queued")
        XCTAssertEqual(t.target_agent_name, "")
        XCTAssertTrue(t.isActive)          // queued 属进行中
        XCTAssertNil(t.report)
    }

    // report 为 null / prompt_eval_count 为字符串的宽容分支
    func testAgentTaskReportTolerant() throws {
        let t1 = try decode(AgentTask.self, #"{"id":"t3","status":"failed","report":null,"fail_reason":"超时"}"#)
        XCTAssertNil(t1.report)
        XCTAssertEqual(t1.fail_reason, "超时")
        let t2 = try decode(AgentTask.self, #"{"id":"t4","report":{"prompt_eval_count":"88"}}"#)
        XCTAssertEqual(t2.report?.prompt_eval_count, 88)
    }

    // SSE snapshot 内嵌任务数组解码（decodeTasks 路径）
    func testDecodeTasksFromSnapshotPayload() {
        let tasks: [[String: Any]] = [
            ["id": "t1", "status": "running", "target_agent_name": "A", "task": "x"],
            ["id": "t2", "status": "done"],
        ]
        let decoded = TaskPanelViewModel.decodeTasks(tasks)
        XCTAssertEqual(decoded.map(\.id), ["t1", "t2"])
        XCTAssertEqual(TaskPanelViewModel.decodeTasks(nil), [])
        XCTAssertEqual(TaskPanelViewModel.decodeTasks("junk"), [])
    }

    // AgentCreateRequest：system_prompt 缺省省略（nil 键不进 JSON）
    func testAgentCreateRequestOmitsNilPrompt() throws {
        let body = AgentCreateRequest(project_id: "p1", name: "A", type_: "main", model_name: "m1")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(body)) as? [String: Any])
        XCTAssertNil(obj["system_prompt"])
        let body2 = AgentCreateRequest(project_id: "p1", name: "A", type_: "sub",
                                       model_name: "m1", system_prompt: "你是审查员")
        let obj2 = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(body2)) as? [String: Any])
        XCTAssertEqual(obj2["system_prompt"] as? String, "你是审查员")
    }

    // AgentUpdateRequest：nil 键省略（后端 model_dump(exclude_none=True) 语义）
    func testAgentUpdateRequestOmitsNilKeys() throws {
        let onlyPrompt = AgentUpdateRequest(system_prompt: "新设定")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(onlyPrompt)) as? [String: Any])
        XCTAssertEqual(obj.count, 1)
        XCTAssertEqual(obj["system_prompt"] as? String, "新设定")
        let onlyModel = AgentUpdateRequest(model_name: "m2")
        let obj2 = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(onlyModel)) as? [String: Any])
        XCTAssertEqual(obj2.count, 1)
        XCTAssertEqual(obj2["model_name"] as? String, "m2")
    }
}

// MARK: - TaskPanelViewModel

@MainActor
final class TaskPanelViewModelTests: XCTestCase {

    private func makeVM(client: W1MockClient,
                        messageTTL: TimeInterval = 0.05) -> (TaskPanelViewModel, AppState) {
        let appState = makeAppState()
        appState.currentProjectId = "p1"
        let vm = TaskPanelViewModel(appState: appState, clientOverride: client,
                                    retryInterval: 0.05, tickInterval: 0.05,
                                    messageTTL: messageTTL)
        return (vm, appState)
    }

    // snapshot：整体替换 + 清掉已不在列表的实时进度
    func testSnapshotReplacesAndPrunesLive() async {
        let client = W1MockClient()
        let (vm, _) = makeVM(client: client)
        client.tasks = [makeTask("t1")]
        vm.apply(event: sse("tool_call", ["task_id": "t-stale", "name": "fs_read"]))
        XCTAssertNotNil(vm.live["t-stale"])
        vm.apply(event: sse("snapshot", ["tasks": [["id": "t1", "status": "running"]]]))
        XCTAssertEqual(vm.tasks.map(\.id), ["t1"])
        XCTAssertNil(vm.live["t-stale"], "snapshot 应清掉已不在列表里的实时进度")
    }

    // tool_call → tool_result → progress 增量合成 LiveProgress
    func testLiveProgressAccumulates() {
        let client = W1MockClient()
        let (vm, _) = makeVM(client: client)
        vm.apply(event: sse("tool_call", ["task_id": "t1", "name": "fs_read"]))
        XCTAssertEqual(vm.live["t1"]?.toolName, "fs_read")
        XCTAssertNil(vm.live["t1"]?.toolOk, "tool_call 后结果未回应为 nil（转圈态）")
        vm.apply(event: sse("tool_result", ["task_id": "t1", "ok": false]))
        XCTAssertEqual(vm.live["t1"]?.toolOk, false)
        vm.apply(event: sse("progress", ["task_id": "t1", "step": 3, "max": 10, "chars": 256]))
        XCTAssertEqual(vm.live["t1"]?.step, 3)
        XCTAssertEqual(vm.live["t1"]?.max, 10)
        XCTAssertEqual(vm.live["t1"]?.chars, 256)
        // 再次 tool_call：toolOk 复位 nil（新一轮工具转圈）
        vm.apply(event: sse("tool_call", ["task_id": "t1", "name": "web"] ))
        XCTAssertEqual(vm.live["t1"]?.toolName, "web")
        XCTAssertNil(vm.live["t1"]?.toolOk)
        // 空 task_id 忽略
        vm.apply(event: sse("tool_call", ["name": "x"]))
        XCTAssertEqual(vm.live.count, 1)
    }

    // task_end：删除进度记录 + 触发静默重拉（不动 loading）
    func testTaskEndRemovesLiveAndReloads() async {
        let client = W1MockClient()
        let (vm, _) = makeVM(client: client)
        vm.apply(event: sse("tool_call", ["task_id": "t1", "name": "fs_read"]))
        let before = client.listTasksCalls
        vm.apply(event: sse("task_end", ["task_id": "t1"]))
        XCTAssertNil(vm.live["t1"])
        let ok1 = await waitFor { client.listTasksCalls > before }
        XCTAssertTrue(ok1, "task_end 应触发静默重拉")
        XCTAssertFalse(vm.loading, "静默重拉不得动 loading（防按钮闪烁）")
    }

    // status：仅 done/failed 触发重拉；running 不触发
    func testStatusTerminalReloadOnly() async {
        let client = W1MockClient()
        let (vm, _) = makeVM(client: client)
        var before = client.listTasksCalls
        vm.apply(event: sse("status", ["task_id": "t1", "state": "running"]))
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(client.listTasksCalls, before, "running 不应触发重拉")
        vm.apply(event: sse("status", ["task_id": "t1", "state": "done"]))
        let ok2 = await waitFor { client.listTasksCalls > before }
        XCTAssertTrue(ok2)
        before = client.listTasksCalls
        vm.apply(event: sse("status", ["task_id": "t1", "state": "failed"]))
        let ok3 = await waitFor { client.listTasksCalls > before }
        XCTAssertTrue(ok3)
    }

    // gap / stream_end / stream_error → 重拉对齐
    func testGapAndStreamEndReload() async {
        let client = W1MockClient()
        let (vm, _) = makeVM(client: client)
        for ev in ["gap", "stream_end", "stream_error"] {
            let before = client.listTasksCalls
            vm.apply(event: sse(ev))
            let ok4 = await waitFor { client.listTasksCalls > before }
        XCTAssertTrue(ok4, "\(ev) 应触发重拉")
        }
        // 未知事件：忽略，不重拉
        let before = client.listTasksCalls
        vm.apply(event: sse("future_event"))
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(client.listTasksCalls, before)
    }

    // 重试成功：文案逐字 + 记录端点调用 + 6s（测试 0.05s）自动消隐
    func testRetrySuccessMessageAndClear() async {
        let client = W1MockClient()
        client.retryResult = TaskRetryResult(newTaskId: "t9", ok: true, error: nil)
        let (vm, _) = makeVM(client: client)
        vm.retry(taskId: "t1")
        XCTAssertEqual(vm.retryingId, "t1")
        let ok5 = await waitFor { vm.retryingId == nil }
        XCTAssertTrue(ok5)
        XCTAssertEqual(vm.retryMsg, "重试完成：子任务成功交卷")
        XCTAssertEqual(client.retryCalls, ["t1"])
        let ok6 = await waitFor { vm.retryMsg == nil }
        XCTAssertTrue(ok6, "消息应按 TTL 自动消隐")
    }

    // 重试未成功（ok=false + error 缺失）→ 「未知原因」兜底
    func testRetryIncompleteMessage() async {
        let client = W1MockClient()
        client.retryResult = TaskRetryResult(newTaskId: nil, ok: false, error: nil)
        let (vm, _) = makeVM(client: client)
        vm.retry(taskId: "t1")
        let ok7 = await waitFor { vm.retryMsg != nil }
        XCTAssertTrue(ok7)
        XCTAssertEqual(vm.retryMsg, "重试完成但未成功：未知原因")
    }

    func testRetryFailureMessage() async {
        let client = W1MockClient()
        client.retryError = SidecarError.httpError(status: 400, detail: "仅失败任务可重试")
        let (vm, _) = makeVM(client: client)
        vm.retry(taskId: "t1")
        let ok8 = await waitFor { vm.retryMsg != nil }
        XCTAssertTrue(ok8)
        XCTAssertEqual(vm.retryMsg, "重试失败: HTTP 400：仅失败任务可重试")
    }

    // 停止：文案逐字 + 端点调用
    func testStopMessage() async {
        let client = W1MockClient()
        let (vm, _) = makeVM(client: client)
        vm.stopTask("t1")
        XCTAssertEqual(vm.stoppingId, "t1")
        let ok9 = await waitFor { vm.stoppingId == nil }
        XCTAssertTrue(ok9)
        XCTAssertEqual(vm.stopMsg, "已请求停止，将在当前步骤完成后中止")
        XCTAssertEqual(client.stopCalls, ["t1"])
    }

    // SSE 流生命周期：start() 起流 → 事件进 apply；stop() 断流且指示灯灭
    func testStreamLifecycle() async {
        let client = W1MockClient()
        let (vm, _) = makeVM(client: client)
        vm.start()
        let ok10 = await waitFor { client.tasksStreamCalls == 1 }
        XCTAssertTrue(ok10)
        client.pushStreamEvent(sse("snapshot", ["tasks": [["id": "t1", "status": "running"]]]))
        let ok11 = await waitFor { vm.streamOn && vm.tasks.count == 1 }
        XCTAssertTrue(ok11)
        client.pushStreamEvent(sse("progress", ["task_id": "t1", "step": 2]))
        let ok12 = await waitFor { vm.live["t1"]?.step == 2 }
        XCTAssertTrue(ok12)
        vm.stop()
        let ok13 = await waitFor { !vm.streamOn }
        XCTAssertTrue(ok13)
    }

    // 断流退避重连（retryInterval 0.05s）：finish 后自动重开
    func testStreamReconnectsAfterDrop() async {
        let client = W1MockClient()
        let (vm, _) = makeVM(client: client)
        vm.start()
        let ok14 = await waitFor { client.tasksStreamCalls == 1 }
        XCTAssertTrue(ok14)
        client.finishStream()
        let ok15 = await waitFor { client.tasksStreamCalls >= 2 }
        XCTAssertTrue(ok15, "断流应退避重连")
        vm.stop()
        let calls = client.tasksStreamCalls
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(client.tasksStreamCalls, calls, "stop 后绝不重连")
    }

    // 进行中任务每秒走表（tick 注入 0.05s）；全终态后停表
    func testTickerRunsOnlyWhileActive() async {
        let client = W1MockClient()
        let (vm, _) = makeVM(client: client)
        client.tasks = [makeTask("t1", status: "running",
                                 createdAt: "2026-01-02 03:04:05")]
        vm.reload()
        let ok16 = await waitFor { !vm.tasks.isEmpty }
        XCTAssertTrue(ok16)
        XCTAssertTrue(vm.hasActive)
        let now1 = vm.now
        try? await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertGreaterThan(vm.now, now1, "有进行中任务时应走表")
        client.tasks = [makeTask("t1", status: "done")]
        vm.reload()
        let ok17 = await waitFor { vm.tasks.first?.status == "done" }
        XCTAssertTrue(ok17)
        XCTAssertFalse(vm.hasActive)
    }

    // 手动刷新失败 → 错误条文案
    func testReloadFailureSetsError() async {
        let client = W1MockClient()
        client.listTasksError = SidecarError.offline("连接被拒")
        let (vm, _) = makeVM(client: client)
        vm.reload()
        let ok18 = await waitFor { vm.error != nil }
        XCTAssertTrue(ok18)
        XCTAssertEqual(vm.error, "加载失败: 连接失败：连接被拒")
        XCTAssertFalse(vm.loading)
    }
}

// MARK: - AgentPanelViewModel

@MainActor
final class AgentPanelViewModelTests: XCTestCase {

    private func makeAgent(_ id: String, name: String? = nil,
                           type: String = "main", model: String? = "m1",
                           prompt: String? = nil) -> SidecarAgent {
        // 经 JSON 解码构造（生产路径同构，顺带覆盖 SidecarAgent 新字段解码）
        let name = name ?? "Agent-\(id)"
        let json = """
        {"id":"\(id)","name":"\(name)","type_":"\(type)",
         \(model.map { "\"model_name\":\"\($0)\"," } ?? "")
         "role":null,"parent_agent_id":null,
         \(prompt.map { "\"system_prompt\":\"\($0)\"" } ?? "\"system_prompt\":null")}
        """
        return try! JSONDecoder().decode(SidecarAgent.self, from: Data(json.utf8))
    }

    private func makeVM(client: W1MockClient,
                        pollInterval: TimeInterval = 60) -> (AgentPanelViewModel, AppState) {
        let appState = makeAppState()
        appState.currentProjectId = "p1"
        let vm = AgentPanelViewModel(appState: appState, clientOverride: client,
                                     pollInterval: pollInterval)
        return (vm, appState)
    }

    // 创建：空名 → "Agent N"；模型缺省链（未选 → 列表首个）；prompt 空 → nil
    func testCreateDefaultsChain() async {
        let client = W1MockClient()
        client.models = [OllamaModel(name: "m-first", size: 1), OllamaModel(name: "m2", size: 2)]
        client.agents = [makeAgent("a1")]
        let (vm, _) = makeVM(client: client)
        await vm.fetchAgents()          // 面板挂载后列表已加载，缺省名基于现有数量
        await vm.fetchModels()
        vm.newName = "   "
        vm.newPrompt = ""
        vm.selectedModel = ""
        vm.create()
        let ok19 = await waitFor { !client.createCalls.isEmpty }
        XCTAssertTrue(ok19)
        let call = client.createCalls[0]
        XCTAssertEqual(call.name, "Agent 2", "空名缺省为 Agent N（N=列表数+1）")
        XCTAssertEqual(call.type, "main")
        XCTAssertEqual(call.model, "m-first", "未选模型时取列表首个")
        XCTAssertNil(call.prompt, "空角色设定应传 nil（后端存 NULL）")
        let ok20 = await waitFor { vm.newName == "" && !vm.creating }
        XCTAssertTrue(ok20)
    }

    // 创建：显式名称/类型/模型/角色设定透传
    func testCreateWithAllFields() async {
        let client = W1MockClient()
        client.models = [OllamaModel(name: "m1", size: nil)]
        let (vm, _) = makeVM(client: client)
        vm.newName = "代码审查员"
        vm.newType = "sub"
        vm.selectedModel = "m1"
        vm.newPrompt = "你是严谨的代码审查员"
        vm.create()
        let ok21 = await waitFor { !client.createCalls.isEmpty }
        XCTAssertTrue(ok21)
        let call = client.createCalls[0]
        XCTAssertEqual(call.name, "代码审查员")
        XCTAssertEqual(call.type, "sub")
        XCTAssertEqual(call.prompt, "你是严谨的代码审查员")
        let ok22 = await waitFor { vm.newPrompt == "" }
        XCTAssertTrue(ok22, "成功后应清空角色设定输入")
    }

    // 创建失败 → 弹「创建失败」+ 最后仍刷新列表
    func testCreateFailureAlerts() async {
        let client = W1MockClient()
        client.createAgentError = SidecarError.httpError(status: 404, detail: "项目不存在或已被删除，请重新选择项目")
        let (vm, _) = makeVM(client: client)
        var alerts: [(String, String)] = []
        vm.alertPresenter = { t, m in alerts.append((t, m)) }
        let before = client.listAgentsCalls
        vm.create()
        let ok23 = await waitFor { !alerts.isEmpty }
        XCTAssertTrue(ok23)
        XCTAssertEqual(alerts[0].0, "创建失败")
        XCTAssertTrue(alerts[0].1.contains("项目不存在"))
        let ok24 = await waitFor { client.listAgentsCalls > before }
        XCTAssertTrue(ok24, "失败后仍应刷新列表")
        XCTAssertFalse(vm.creating)
    }

    // 删除：确认 → DELETE；删当前选中项清空选择；取消 → 不调端点
    func testDeleteFlow() async {
        let client = W1MockClient()
        client.agents = [makeAgent("a1"), makeAgent("a2")]
        let (vm, appState) = makeVM(client: client)
        appState.currentAgentId = "a2"
        vm.confirmDelete = { true }
        vm.delete(client.agents[1])
        let ok25 = await waitFor { client.deleteCalls == ["a2"] }
        XCTAssertTrue(ok25)
        let ok26 = await waitFor { appState.currentAgentId == nil }
        XCTAssertTrue(ok26, "删当前选中项应清空选择")

        vm.confirmDelete = { false }
        vm.delete(client.agents[0])
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(client.deleteCalls, ["a2"], "取消删除不得调端点")
    }

    // 行内编辑保存：PUT {system_prompt}；成功后退出编辑态
    func testSavePrompt() async {
        let client = W1MockClient()
        let agent = makeAgent("a1", prompt: "旧设定")
        client.agents = [agent]
        let (vm, _) = makeVM(client: client)
        vm.beginEdit(agent)
        XCTAssertEqual(vm.editingId, "a1")
        XCTAssertEqual(vm.editText, "旧设定")
        vm.editText = "新设定"
        vm.savePrompt(agent)
        let ok27 = await waitFor { !client.updateCalls.isEmpty }
        XCTAssertTrue(ok27)
        XCTAssertEqual(client.updateCalls[0].agentId, "a1")
        XCTAssertEqual(client.updateCalls[0].update.system_prompt, "新设定")
        XCTAssertNil(client.updateCalls[0].update.model_name)
        let ok28 = await waitFor { vm.editingId == nil && !vm.savingPrompt }
        XCTAssertTrue(ok28)
    }

    // 留空保存 = 清除（空串照传，后端按空串覆盖）
    func testSavePromptEmptyClears() async {
        let client = W1MockClient()
        let agent = makeAgent("a1", prompt: "旧设定")
        let (vm, _) = makeVM(client: client)
        vm.beginEdit(agent)
        vm.editText = ""
        vm.savePrompt(agent)
        let ok29 = await waitFor { !client.updateCalls.isEmpty }
        XCTAssertTrue(ok29)
        XCTAssertEqual(client.updateCalls[0].update.system_prompt, "")
    }

    // 保存失败 → 弹「保存失败」，保持编辑态
    func testSavePromptFailureKeepsEditing() async {
        let client = W1MockClient()
        client.updateAgentError = SidecarError.httpError(status: 404, detail: "Agent 不存在")
        let agent = makeAgent("a1")
        let (vm, _) = makeVM(client: client)
        var alerts: [(String, String)] = []
        vm.alertPresenter = { t, m in alerts.append((t, m)) }
        vm.beginEdit(agent)
        vm.savePrompt(agent)
        let ok30 = await waitFor { !alerts.isEmpty }
        XCTAssertTrue(ok30)
        XCTAssertEqual(alerts[0].0, "保存失败")
        XCTAssertEqual(vm.editingId, "a1", "失败不应退出编辑态")
        XCTAssertFalse(vm.savingPrompt)
    }

    // 行内切换模型：PUT {model_name}
    func testChangeModel() async {
        let client = W1MockClient()
        let agent = makeAgent("a1", model: "m1")
        let (vm, _) = makeVM(client: client)
        vm.changeModel(agent, to: "m2")
        let ok31 = await waitFor { !client.updateCalls.isEmpty }
        XCTAssertTrue(ok31)
        XCTAssertEqual(client.updateCalls[0].update.model_name, "m2")
        XCTAssertNil(client.updateCalls[0].update.system_prompt)
    }

    // 8s 轮询（测试注入 0.05s）：委派新建子 Agent 兜底刷新
    func testPollingRefreshesAgents() async {
        let client = W1MockClient()
        let (vm, _) = makeVM(client: client, pollInterval: 0.05)
        vm.start()
        let ok32 = await waitFor { client.listAgentsCalls >= 3 }
        XCTAssertTrue(ok32, "轮询应持续刷新列表")
        vm.stop()
        let calls = client.listAgentsCalls
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(client.listAgentsCalls, calls, "stop 后轮询应停")
    }

    // 选择 Agent → 写 AppState.currentAgentId
    func testSelectWritesAppState() {
        let client = W1MockClient()
        let agent = makeAgent("a9")
        let (vm, appState) = makeVM(client: client)
        vm.select(agent)
        XCTAssertEqual(appState.currentAgentId, "a9")
    }

    // U2：项目内 Agent 单击 = 选中 + 直达聊天主页（原版 selectAgent 单击即见聊天）
    func testStartChatSelectsAndNavigates() {
        let client = W1MockClient()
        let agent = makeAgent("a9")
        let (vm, appState) = makeVM(client: client)
        vm.startChat(agent)
        XCTAssertEqual(appState.currentAgentId, "a9", "单击先选中该 Agent")
        XCTAssertEqual(appState.selectedPanel.key, "chat", "单击直达聊天主页（chatHome）")
        XCTAssertEqual(appState.selectedModule, .intelligence)
    }
}
