//
//  WorkflowPanelW4Tests.swift
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

//  流程中心（WorkflowPanel / WorkflowEditor / WorkflowCanvas）单测：
//    · WorkflowLayout 画布几何（拓扑分层 / 同层居中 / 孤立垫底 / 破环收敛 / 隐式边 /
//      画布尺寸 / 命中测试 / 坐标变换）——移植自 lib/workflowLayout.ts 的纯函数口径
//    · 契约编解码（节点未知键往返保留 / built_in 双形态 / 请求体 nil 键省略 /
//      运行记录与节点事件宽容解码）
//    · 节点工厂缺省字段链（逐类型对齐 WorkflowEditor.tsx addNode）与 id 生成
//    · WorkflowPanelViewModel 状态机（选择回填 / 增删改置脏 / 连线守卫 /
//      运行 SSE 事件分发 / 审批卡片 / 停止顺序 / 资源变更 dirty 守卫 / 运行记录展开）
//
//  Mock 客户端为本文件私有（W4MockClient），不改动既有测试文件的 Mock。
//

import XCTest
@testable import VetarAINative

// MARK: - W4 Mock 客户端（全协议方法可注入/记录）

final class W4MockClient: SidecarClientProtocol, WorkflowPanelClient {
    let baseURL = URL(string: "http://127.0.0.1:1/api")!

    // 注入结果
    var workflows: [WorkflowRecord] = []
    var listWorkflowsError: Error?
    var createError: Error?
    var updateError: Error?
    var deleteError: Error?
    var inferenceModels: [InferenceModelEntry] = []
    var runs: [WorkflowRunRecord] = []
    var runDetail: WorkflowRunDetail?
    var runDetailError: Error?
    var approveError: Error?
    var stopError: Error?

    // 调用记录
    private(set) var listWorkflowsCalls = 0
    private(set) var createCalls: [(name: String, description: String, definition: WorkflowDefinition)] = []
    private(set) var updateCalls: [(id: String, update: WorkflowUpdateRequest)] = []
    private(set) var deleteCalls: [String] = []
    private(set) var listRunsCalls = 0
    private(set) var getRunCalls: [String] = []
    private(set) var approveCalls: [(runId: String, approved: Bool, comment: String)] = []
    private(set) var stopRunCalls: [String] = []
    private(set) var runWorkflowCalls: [(id: String, params: [String: JSONValue])] = []

    // 运行 SSE 流控制
    private var runContinuation: AsyncThrowingStream<SSEEvent, Error>.Continuation?
    private var pendingRunEvents: [SSEEvent] = []
    private var runStreamFinished = false
    private var runStreamError: Error?

    func pushRunEvent(_ ev: SSEEvent) {
        if let c = runContinuation { c.yield(ev) } else { pendingRunEvents.append(ev) }
    }
    func finishRunStream(throwing error: Error? = nil) {
        runStreamFinished = true
        runStreamError = error
        if let error { runContinuation?.finish(throwing: error) }
        else { runContinuation?.finish() }
    }

    // 资源变更流控制
    private(set) var appEventsCalls = 0
    private var appEventsContinuation: AsyncThrowingStream<SSEEvent, Error>.Continuation?
    func pushAppEvent(_ ev: SSEEvent) { appEventsContinuation?.yield(ev) }

    // MARK: SidecarClientProtocol

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

    // MARK: WorkflowPanelClient

    func listWorkflows() async throws -> [WorkflowRecord] {
        listWorkflowsCalls += 1
        if let listWorkflowsError { throw listWorkflowsError }
        return workflows
    }
    func createWorkflow(name: String, description: String,
                        definition: WorkflowDefinition) async throws -> String {
        if let createError { throw createError }
        createCalls.append((name, description, definition))
        return "wf-new"
    }
    func getWorkflow(id: String) async throws -> WorkflowRecord {
        guard let wf = workflows.first(where: { $0.id == id }) else {
            throw SidecarError.httpError(status: 404, detail: "工作流不存在")
        }
        return wf
    }
    func updateWorkflow(id: String, update: WorkflowUpdateRequest) async throws {
        updateCalls.append((id, update))
        if let updateError { throw updateError }
    }
    func deleteWorkflow(id: String) async throws {
        deleteCalls.append(id)
        if let deleteError { throw deleteError }
    }
    func runWorkflow(id: String, params: [String: JSONValue]) -> AsyncThrowingStream<SSEEvent, Error> {
        runWorkflowCalls.append((id, params))
        let pending = pendingRunEvents
        pendingRunEvents = []
        let finished = runStreamFinished
        let error = runStreamError
        return AsyncThrowingStream { cont in
            self.runContinuation = cont
            for ev in pending { cont.yield(ev) }
            if finished {
                if let error { cont.finish(throwing: error) } else { cont.finish() }
            }
        }
    }
    func listWorkflowRuns(workflowId: String?, limit: Int) async throws -> [WorkflowRunRecord] {
        listRunsCalls += 1
        if let workflowId { return runs.filter { $0.workflowId == workflowId } }
        return runs
    }
    func getWorkflowRun(id: String) async throws -> WorkflowRunDetail {
        getRunCalls.append(id)
        if let runDetailError { throw runDetailError }
        return runDetail ?? WorkflowRunDetail(id: id)
    }
    func approveWorkflowRun(runId: String, approved: Bool, comment: String) async throws {
        approveCalls.append((runId, approved, comment))
        if let approveError { throw approveError }
    }
    func stopWorkflowRun(runId: String) async throws {
        stopRunCalls.append(runId)
        if let stopError { throw stopError }
    }
    func fetchInferenceModels() async throws -> [InferenceModelEntry] { inferenceModels }
    func appEventsStream(since: Int) -> AsyncThrowingStream<SSEEvent, Error> {
        appEventsCalls += 1
        return AsyncThrowingStream { cont in self.appEventsContinuation = cont }
    }
}

// MARK: - 测试工具

@MainActor
private func makeAppState() -> AppState {
    TestRuntimeSupport.makeAppState(client: W4MockClient())
}

private func sse(_ event: String, _ data: [String: Any] = [:]) -> SSEEvent {
    SSEEvent(event: event, data: data, rawData: "")
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

// MARK: - WorkflowLayout 画布几何

final class WorkflowLayoutTests: XCTestCase {

    private func def(_ nodes: [(String, String)], _ edges: [(String, String)],
                     parallelBranches: [String: [String]] = [:],
                     loopBranches: [String: String] = [:]) -> WorkflowDefinition {
        WorkflowDefinition(
            nodes: nodes.map { (id, type) in
                var props: [String: JSONValue] = [:]
                if let b = parallelBranches[id] { props["branches"] = .array(b.map { .string($0) }) }
                if let b = loopBranches[id] { props["branch"] = .string(b) }
                return WorkflowNode(id: id, type: type, props: props)
            },
            edges: edges.map { WorkflowEdge(from: $0.0, to: $0.1) })
    }

    // 单节点：位于 PAD 起点（与 TS layoutWorkflow 同坐标）
    func testSingleNodeOrigin() {
        let pos = WorkflowLayout.layout(def([("start", "start")], []))
        XCTAssertEqual(pos["start"], CGPoint(x: WorkflowLayout.pad, y: WorkflowLayout.pad))
    }

    // 线性链分层：y 逐层 +NODE_H+V_GAP；单列 x 相同
    func testLinearChainLayers() {
        let pos = WorkflowLayout.layout(def([("start", "start"), ("a", "inference"), ("b", "end")],
                                            [("start", "a"), ("a", "b")]))
        let dy = WorkflowLayout.nodeH + WorkflowLayout.vGap
        XCTAssertEqual(pos["a"]!.y, WorkflowLayout.pad + dy)
        XCTAssertEqual(pos["b"]!.y, WorkflowLayout.pad + dy * 2)
        XCTAssertEqual(pos["start"]!.x, pos["a"]!.x)
        XCTAssertEqual(pos["a"]!.x, pos["b"]!.x)
    }

    // 同层分支并排：y 相同、x 递增 NODE_W+H_GAP，整体居中
    func testParallelSameLayerCentered() {
        let pos = WorkflowLayout.layout(def([("start", "start"), ("a", "inference"),
                                             ("b", "inference"), ("c", "end")],
                                            [("start", "a"), ("start", "b"),
                                             ("a", "c"), ("b", "c")]))
        XCTAssertEqual(pos["a"]!.y, pos["b"]!.y)
        XCTAssertEqual(pos["b"]!.x - pos["a"]!.x, WorkflowLayout.nodeW + WorkflowLayout.hGap)
        // 居中：最宽层 2 个节点，单层节点居中于 totalW
        let totalW = 2 * WorkflowLayout.nodeW + WorkflowLayout.hGap
        let expectedX = WorkflowLayout.pad + (totalW - WorkflowLayout.nodeW) / 2
        XCTAssertEqual(pos["start"]!.x, expectedX)
        XCTAssertEqual(pos["c"]!.x, expectedX)
    }

    // 孤立节点垫底（start 不可达 → maxLayer+1 起逐一下排）
    func testIsolatedNodeGoesBottom() {
        let pos = WorkflowLayout.layout(def([("start", "start"), ("a", "end"), ("x", "code")],
                                            [("start", "a")]))
        XCTAssertGreaterThan(pos["x"]!.y, pos["a"]!.y)
    }

    // 无 start 兜底：入度为 0 的节点起层
    func testNoStartFallback() {
        let pos = WorkflowLayout.layout(def([("a", "inference"), ("b", "end")], [("a", "b")]))
        XCTAssertEqual(pos["a"]!.y, WorkflowLayout.pad)
        XCTAssertEqual(pos["b"]!.y, WorkflowLayout.pad + WorkflowLayout.nodeH + WorkflowLayout.vGap)
    }

    // 破环（0.2.4 W3）：回边剪除后布局收敛，节点不被压到深层
    func testCycleBroken() {
        let pos = WorkflowLayout.layout(def([("start", "start"), ("a", "inference"), ("b", "end")],
                                            [("start", "a"), ("a", "b"), ("b", "a")]))
        XCTAssertEqual(pos.count, 3)
        // 收敛：最深不超过 2 层
        let maxY = pos.values.map(\.y).max()!
        XCTAssertLessThanOrEqual(maxY, WorkflowLayout.pad + 2 * (WorkflowLayout.nodeH + WorkflowLayout.vGap))
    }

    // parallel.branches / loop.branch 隐式边参与分层
    func testImplicitBranchEdges() {
        let pos = WorkflowLayout.layout(def([("start", "start"), ("p", "parallel"),
                                             ("a", "inference"), ("b", "inference")],
                                            [("start", "p")],
                                            parallelBranches: ["p": ["a", "b"]]))
        XCTAssertEqual(pos["a"]!.y, pos["b"]!.y)
        XCTAssertGreaterThan(pos["a"]!.y, pos["p"]!.y)

        let pos2 = WorkflowLayout.layout(def([("start", "start"), ("l", "loop"), ("a", "inference")],
                                             [("start", "l")],
                                             loopBranches: ["l": "a"]))
        XCTAssertGreaterThan(pos2["a"]!.y, pos2["l"]!.y)
    }

    // 画布尺寸 = 最大右下 + PAD
    func testCanvasSize() {
        let pos = WorkflowLayout.layout(def([("start", "start")], []))
        let size = WorkflowLayout.canvasSize(pos)
        XCTAssertEqual(size.width, WorkflowLayout.pad + WorkflowLayout.nodeW + WorkflowLayout.pad)
        XCTAssertEqual(size.height, WorkflowLayout.pad + WorkflowLayout.nodeH + WorkflowLayout.pad)
    }

    // 命中测试：节点矩形内命中；空白处 nil；缩放平移换算
    func testHitTest() {
        let positions = ["start": CGPoint(x: 24, y: 24)]
        let hit = WorkflowCanvasView.hitTest(canvasPoint: CGPoint(x: 30, y: 30), positions: positions)
        XCTAssertEqual(hit, "start")
        let miss = WorkflowCanvasView.hitTest(canvasPoint: CGPoint(x: 500, y: 500), positions: positions)
        XCTAssertNil(miss)
        // 视口坐标 → 画布坐标：zoom 2、pan (10, 20)
        let p = WorkflowCanvasView.toCanvasPoint(CGPoint(x: 58, y: 68), zoom: 2,
                                                 pan: CGSize(width: 10, height: 20))
        XCTAssertEqual(p, CGPoint(x: 24, y: 24))
    }

    // 状态环映射（对齐 statusRing 三分支）
    func testStatusRingColors() {
        XCTAssertNil(WorkflowCanvasView.statusRing(nil))
        XCTAssertNil(WorkflowCanvasView.statusRing(.pending))
        XCTAssertNotNil(WorkflowCanvasView.statusRing(.running))
        XCTAssertNotNil(WorkflowCanvasView.statusRing(.done))
        XCTAssertNotNil(WorkflowCanvasView.statusRing(.error))
    }
}

// MARK: - 契约编解码

final class WorkflowContractTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // 节点未知键往返保留（保真设计核心：timeout_s 等表单未覆盖键不丢）
    func testNodeUnknownKeysRoundTrip() throws {
        let json = #"{"id":"n1","type":"inference","label":"识别","model":"glm:latest","timeout_s":1200,"future_field":{"a":1},"retry":2}"#
        let node = try decode(WorkflowNode.self, json)
        XCTAssertEqual(node.id, "n1")
        XCTAssertEqual(node.type, "inference")
        XCTAssertEqual(node.label, "识别")
        XCTAssertEqual(node.props["timeout_s"], .int(1200))
        XCTAssertEqual(node.props["future_field"], .object(["a": .int(1)]))
        let data = try JSONEncoder().encode(node)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["timeout_s"] as? Int, 1200)
        XCTAssertEqual((obj["future_field"] as? [String: Any])?["a"] as? Int, 1)
        XCTAssertEqual(obj["label"] as? String, "识别")
        XCTAssertEqual(obj["id"] as? String, "n1")
    }

    // 工作流记录解码：built_in 布尔 / 整数双形态；definition 内嵌解码
    func testWorkflowRecordDecode() throws {
        let wf = try decode(WorkflowRecord.self, """
        {"id":"w1","name":"图片批处理","description":"demo","built_in":false,
         "created_at":"2026-01-02 03:04:05","updated_at":"2026-01-02 04:05:06",
         "definition":{"nodes":[{"id":"start","type":"start","label":"开始"}],
                       "edges":[],"params":{"dir":"~/x"}}}
        """)
        XCTAssertEqual(wf.id, "w1")
        XCTAssertFalse(wf.builtIn)
        XCTAssertEqual(wf.definition.nodes.count, 1)
        XCTAssertEqual(wf.definition.params["dir"], .string("~/x"))

        let wf2 = try decode(WorkflowRecord.self, #"{"id":"w2","name":"内置","built_in":1}"#)
        XCTAssertTrue(wf2.builtIn)
        XCTAssertEqual(wf2.description, "")
        XCTAssertTrue(wf2.definition.nodes.isEmpty, "definition 缺省应宽容为空定义")
    }

    // 定义解码宽容：params 缺省 / edges 缺省
    func testDefinitionTolerantDecode() throws {
        let def = try decode(WorkflowDefinition.self, #"{"nodes":[{"id":"s","type":"start"}]}"#)
        XCTAssertEqual(def.edges, [])
        XCTAssertEqual(def.params, [:])
    }

    // 运行记录列表行解码（store.py 七键）
    func testRunRecordDecode() throws {
        let run = try decode(WorkflowRunRecord.self, """
        {"id":"r1","workflow_id":"w1","status":"awaiting_approval","current_node":"n3",
         "result":null,"error":null,"created_at":"2026-01-02 03:04:05"}
        """)
        XCTAssertEqual(run.status, "awaiting_approval")
        XCTAssertTrue(run.isActive)
        XCTAssertEqual(run.currentNode, "n3")
        let done = try decode(WorkflowRunRecord.self, #"{"id":"r2","workflow_id":"w1","status":"done"}"#)
        XCTAssertFalse(done.isActive)
    }

    // 运行详情：variables + node_events 内嵌；节点事件 id 字符串容错
    func testRunDetailDecode() throws {
        let detail = try decode(WorkflowRunDetail.self, """
        {"id":"r1","workflow_id":"w1","status":"failed","current_node":"n2",
         "variables":{"n1":{"output":"ok"}},"result":null,"error":"超时",
         "created_at":"2026-01-02 03:04:05","updated_at":"2026-01-02 03:05:05",
         "node_events":[{"id":1,"node_id":"n1","node_type":"inference","status":"done",
                         "model_used":"glm:latest","input_summary":"","output_summary":"ok",
                         "error":null,"retry_count":1,"duration_ms":830,
                         "created_at":"2026-01-02 03:04:06"},
                        {"id":"2","node_id":"n2","node_type":"code","status":"error",
                         "error":"超时","retry_count":0}]}
        """)
        XCTAssertEqual(detail.variables["n1"], .object(["output": .string("ok")]))
        XCTAssertEqual(detail.nodeEvents.count, 2)
        XCTAssertEqual(detail.nodeEvents[0].durationMs, 830)
        XCTAssertEqual(detail.nodeEvents[0].retryCount, 1)
        XCTAssertEqual(detail.nodeEvents[1].id, 2, "字符串 id 应容错解析")
        XCTAssertEqual(detail.nodeEvents[1].status, "error")
    }

    // 创建请求体：name/description/definition 全键
    func testCreateRequestEncoding() throws {
        let body = WorkflowCreateRequest(name: "新工作流", definition: .startOnly())
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(body)) as? [String: Any])
        XCTAssertEqual(obj["name"] as? String, "新工作流")
        XCTAssertEqual(obj["description"] as? String, "")
        let def = try XCTUnwrap(obj["definition"] as? [String: Any])
        let nodes = try XCTUnwrap(def["nodes"] as? [[String: Any]])
        XCTAssertEqual(nodes.first?["type"] as? String, "start")
    }

    // 更新请求体：nil 键省略（后端部分更新语义）
    func testUpdateRequestOmitsNilKeys() throws {
        let onlyName = WorkflowUpdateRequest(name: "改名")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(onlyName)) as? [String: Any])
        XCTAssertEqual(obj.count, 1)
        XCTAssertEqual(obj["name"] as? String, "改名")
    }

    // 审批请求体：approved + comment 缺省 ""
    func testApproveRequestEncoding() throws {
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(WorkflowApproveRequest(approved: true))) as? [String: Any])
        XCTAssertEqual(obj["approved"] as? Bool, true)
        XCTAssertEqual(obj["comment"] as? String, "")
    }

    // 运行请求体：params 包装（含嵌套数组/对象保真）
    func testRunRequestEncoding() throws {
        let body = WorkflowRunRequest(params: ["images": .array([.string("/a.png")]),
                                               "opt": .object(["k": .int(1)])])
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(body)) as? [String: Any])
        let params = try XCTUnwrap(obj["params"] as? [String: Any])
        XCTAssertEqual((params["images"] as? [Any])?.first as? String, "/a.png")
        XCTAssertEqual((params["opt"] as? [String: Any])?["k"] as? Int, 1)
    }
}

// MARK: - 节点工厂

final class WorkflowNodeFactoryTests: XCTestCase {

    // 全类型缺省字段链（逐条对齐 WorkflowEditor.tsx addNode）
    func testDefaultsPerType() {
        let models = ["m1", "m2"]
        let inf = WorkflowNodeFactory.makeNode(type: "inference", id: "n2", models: models)
        XCTAssertEqual(inf.label, "推理节点")
        XCTAssertEqual(inf.props["model"], .string("m1"))
        XCTAssertEqual(inf.props["prompt"], .string(""))
        XCTAssertEqual(inf.props["retry"], .int(0))

        let tool = WorkflowNodeFactory.makeNode(type: "tool", id: "n2")
        XCTAssertEqual(tool.props["tool"], .string("write_file"))
        XCTAssertEqual(tool.props["args"], .object([:]))

        let cond = WorkflowNodeFactory.makeNode(type: "condition", id: "n2")
        XCTAssertEqual(cond.props["match"],
                       .object(["variable": .string(""), "operator": .string("contains"),
                                "value": .string("")]))

        XCTAssertEqual(WorkflowNodeFactory.makeNode(type: "parallel", id: "n2").props["branches"],
                       .array([]))
        let loop = WorkflowNodeFactory.makeNode(type: "loop", id: "n2")
        XCTAssertEqual(loop.props["items"], .string(""))
        XCTAssertEqual(loop.props["branch"], .string(""))

        XCTAssertEqual(WorkflowNodeFactory.makeNode(type: "approval", id: "n2").props["message"],
                       .string("请确认是否继续。"))

        let fi = WorkflowNodeFactory.makeNode(type: "file_input", id: "n2")
        XCTAssertEqual(fi.props["path"], .string(""))
        XCTAssertEqual(fi.props["recursive"], .bool(false))

        let fr = WorkflowNodeFactory.makeNode(type: "file_read", id: "n2")
        XCTAssertEqual(fr.props["separator"], .string(""))

        let fo = WorkflowNodeFactory.makeNode(type: "file_output", id: "n2")
        XCTAssertEqual(fo.props["dir"], .string(""))
        XCTAssertEqual(fo.props["filename"], .string(""))
        XCTAssertEqual(fo.props["content"], .string(""))

        XCTAssertEqual(WorkflowNodeFactory.makeNode(type: "text_output", id: "n2").props["template"],
                       .string(""))
        let vs = WorkflowNodeFactory.makeNode(type: "variable_set", id: "n2")
        XCTAssertEqual(vs.props["name"], .string(""))
        XCTAssertEqual(vs.props["value"], .string(""))
        XCTAssertEqual(WorkflowNodeFactory.makeNode(type: "code", id: "n2").props["code"],
                       .string(""))
        XCTAssertEqual(WorkflowNodeFactory.makeNode(type: "reply", id: "n2").props["text"],
                       .string(""))
        // end 仅 label，无额外键（对齐 TSX）
        let end = WorkflowNodeFactory.makeNode(type: "end", id: "n2")
        XCTAssertEqual(end.label, "结束")
        XCTAssertEqual(end.props.count, 1)
    }

    // id 生成：n{数量+1}；撞名补随机后缀（逐字对齐 TSX while 追加语义：
    // existing=[n2] 时 idx=2 → "n2" 撞名 → n2_<suffix>）
    func testGenerateID() {
        XCTAssertEqual(WorkflowNodeFactory.generateID(existing: []), "n1")
        let one = [WorkflowNode(id: "n1", type: "start")]
        XCTAssertEqual(WorkflowNodeFactory.generateID(existing: one), "n2")
        // 撞名：idx=数量+1 恰好撞上已有 id → 追加随机后缀
        let clash = [WorkflowNode(id: "n2", type: "end")]
        XCTAssertEqual(WorkflowNodeFactory.generateID(existing: clash, randomSuffix: { 555 }),
                       "n2_555")
        // 不撞名：按序取 n3
        let two = [WorkflowNode(id: "n1", type: "start"), WorkflowNode(id: "n2", type: "end")]
        XCTAssertEqual(WorkflowNodeFactory.generateID(existing: two), "n3")
    }

    // 类型元数据：中文名 + 未知类型回落
    func testTypeMeta() {
        XCTAssertEqual(WorkflowNodeTypes.meta(for: "inference").label, "推理")
        XCTAssertEqual(WorkflowNodeTypes.meta(for: "file_read").label, "文件读取")
        XCTAssertEqual(WorkflowNodeTypes.meta(for: "whatever").label, "whatever")
        XCTAssertEqual(WorkflowNodeTypes.addOptions.count, 14, "对齐 NODE_TYPE_OPTIONS")
        XCTAssertFalse(WorkflowNodeTypes.addOptions.contains { $0.value == "start" })
        XCTAssertEqual(WorkflowNodeTypes.conditionOps.count, 7)
    }

    // RunEvent 行文本与错误判定（对齐 TSX 事件行拼接）
    func testRunEventLineText() {
        let e1 = WorkflowPanelViewModel.RunEvent(event: "node_done", data: [
            "node_id": "n1", "output_preview": String(repeating: "x", count: 100)])
        XCTAssertTrue(e1.lineText.hasPrefix("node_done · n1 · "))
        XCTAssertEqual(e1.lineText.count, "node_done · n1 · ".count + 80, "preview 截 80 字")
        XCTAssertFalse(e1.isError)

        let e2 = WorkflowPanelViewModel.RunEvent(event: "workflow_failed", data: ["error": "炸了"])
        XCTAssertEqual(e2.lineText, "workflow_failed · 炸了")
        XCTAssertTrue(e2.isError)

        let e3 = WorkflowPanelViewModel.RunEvent(event: "workflow_reply",
                                                 data: ["node_id": "n4", "text": "好了"])
        XCTAssertEqual(e3.lineText, "workflow_reply · n4 💬 好了")

        let e4 = WorkflowPanelViewModel.RunEvent(event: "node_error", data: ["node_id": "n2"])
        XCTAssertTrue(e4.isError, "事件名含 error 即标红")
    }
}

// MARK: - WorkflowPanelViewModel 状态机

@MainActor
final class WorkflowPanelViewModelTests: XCTestCase {

    /// 捕获弹窗的便捷容器。
    private final class AlertBox {
        var alerts: [(String, String)] = []
    }

    private func makeVMWithAlerts(client: W4MockClient) -> (WorkflowPanelViewModel, AlertBox) {
        let box = AlertBox()
        let vm = WorkflowPanelViewModel(appState: makeAppState(), clientOverride: client,
                                        retryInterval: 0.05)
        vm.alertPresenter = { t, m in box.alerts.append((t, m)) }
        return (vm, box)
    }

    // 选择：回填名称/描述/定义 + 清脏 + 清节点选择 + 触发运行记录加载
    func testSelectWorkflowPopulates() async {
        let client = W4MockClient()
        let wf = makeWorkflow("w1")
        client.workflows = [wf]
        client.runs = [WorkflowRunRecord(id: "r1", workflowId: "w1", status: "done")]
        let (vm, _) = makeVMWithAlerts(client: client)
        vm.selectWorkflow(wf)
        XCTAssertEqual(vm.selectedId, "w1")
        XCTAssertEqual(vm.name, "流程w1")
        XCTAssertEqual(vm.desc, "描述w1")
        XCTAssertEqual(vm.definition.nodes.count, 2)
        XCTAssertFalse(vm.dirty, "回填不得置脏")
        XCTAssertNil(vm.selectedNodeId)
        let ok = await waitFor { client.listRunsCalls == 1 }
        XCTAssertTrue(ok)
        XCTAssertEqual(vm.runs.map(\.id), ["r1"])
    }

    // 新建：POST 默认定义 → 重拉 → 选中新项
    func testCreateWorkflow() async {
        let client = W4MockClient()
        let (vm, _) = makeVMWithAlerts(client: client)
        vm.createWorkflow()
        let ok = await waitFor { !client.createCalls.isEmpty }
        XCTAssertTrue(ok)
        XCTAssertEqual(client.createCalls[0].name, "新工作流")
        XCTAssertEqual(client.createCalls[0].definition.nodes.first?.type, "start")
        let ok2 = await waitFor { vm.selectedId == "wf-new" }
        XCTAssertTrue(ok2)
        XCTAssertEqual(vm.name, "新工作流")
        XCTAssertFalse(vm.dirty)
    }

    // 新建失败 → 弹「创建失败」
    func testCreateFailureAlerts() async {
        let client = W4MockClient()
        client.createError = SidecarError.httpError(status: 422, detail: "节点[0] 类型无效")
        let (vm, box) = makeVMWithAlerts(client: client)
        vm.createWorkflow()
        let ok = await waitFor { !box.alerts.isEmpty }
        XCTAssertTrue(ok)
        XCTAssertEqual(box.alerts[0].0, "创建失败")
        XCTAssertTrue(box.alerts[0].1.contains("节点[0] 类型无效"))
    }

    // 保存成功：清脏 + 清校验信息 + 重拉；请求体三键全量
    func testSaveSuccess() async {
        let client = W4MockClient()
        let wf = makeWorkflow("w1")
        client.workflows = [wf]
        let (vm, _) = makeVMWithAlerts(client: client)
        vm.selectWorkflow(wf)
        vm.name = "改名"
        XCTAssertTrue(vm.dirty)
        let saved = await vm.saveWorkflow()
        XCTAssertTrue(saved)
        XCTAssertFalse(vm.dirty)
        XCTAssertEqual(vm.validateMsg, "")
        XCTAssertEqual(client.updateCalls.count, 1)
        XCTAssertEqual(client.updateCalls[0].id, "w1")
        XCTAssertEqual(client.updateCalls[0].update.name, "改名")
        XCTAssertNotNil(client.updateCalls[0].update.definition)
        let ok = await waitFor { client.listWorkflowsCalls >= 1 }
        XCTAssertTrue(ok, "保存成功后应重拉列表")
    }

    // 保存失败（422）：detail 落 validateMsg + 弹窗 + 保持脏
    func testSaveFailureKeepsDirty() async {
        let client = W4MockClient()
        client.updateError = SidecarError.httpError(status: 422, detail: "必须恰好有一个开始节点")
        let (vm, box) = makeVMWithAlerts(client: client)
        vm.selectWorkflow(makeWorkflow("w1"))
        vm.name = "x"
        let saved = await vm.saveWorkflow()
        XCTAssertFalse(saved)
        XCTAssertTrue(vm.dirty, "失败不得清脏")
        XCTAssertEqual(vm.validateMsg, "HTTP 422：必须恰好有一个开始节点")
        XCTAssertEqual(box.alerts.first?.0, "保存失败")
    }

    // 删除：确认 → DELETE + 清选中；取消 → 不调端点；内置不可删
    func testDeleteFlow() async {
        let client = W4MockClient()
        let wf = makeWorkflow("w1")
        let builtIn = makeWorkflow("w2", builtIn: true)
        client.workflows = [wf, builtIn]
        let (vm, _) = makeVMWithAlerts(client: client)
        await vm.loadWorkflows()     // selected 派生自列表（对齐 TSX workflows.find）
        vm.selectWorkflow(wf)
        vm.confirmDelete = { _ in true }
        vm.deleteWorkflow()
        let ok = await waitFor { client.deleteCalls == ["w1"] }
        XCTAssertTrue(ok)
        let ok2 = await waitFor { vm.selectedId == nil }
        XCTAssertTrue(ok2)

        vm.selectWorkflow(wf)
        vm.confirmDelete = { _ in false }
        vm.deleteWorkflow()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(client.deleteCalls, ["w1"], "取消删除不得调端点")

        vm.selectWorkflow(builtIn)
        vm.confirmDelete = { _ in true }
        vm.deleteWorkflow()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(client.deleteCalls, ["w1"], "内置工作流不可删")
    }

    // 节点编辑：patchNode 置脏 + nil 删键；removeNode 级联删边并清选中
    func testNodeMutations() {
        let client = W4MockClient()
        let (vm, _) = makeVMWithAlerts(client: client)
        vm.selectWorkflow(makeWorkflow("w1"))
        XCTAssertFalse(vm.dirty)

        vm.patchNode(id: "start", patch: ["label": .string("起点")])
        XCTAssertTrue(vm.dirty)
        XCTAssertEqual(vm.definition.node(id: "start")?.label, "起点")

        vm.patchNode(id: "start", patch: ["label": nil])
        XCTAssertNil(vm.definition.node(id: "start")?.label, "nil 补丁 = 删除键（undefined 语义）")

        vm.selectedNodeId = "n2"
        vm.removeNode(id: "n2")
        XCTAssertNil(vm.definition.node(id: "n2"))
        XCTAssertTrue(vm.definition.edges.isEmpty, "删节点应级联删关联连线")
        XCTAssertNil(vm.selectedNodeId, "删除选中节点应清选择")
    }

    // addNode：缺省字段 + 自动选中新节点 + 置脏
    func testAddNode() {
        let client = W4MockClient()
        client.inferenceModels = [InferenceModelEntry(name: "glm:latest")]
        let (vm, _) = makeVMWithAlerts(client: client)
        vm.selectWorkflow(makeWorkflow("w1"))
        vm.addNode(type: "inference")
        XCTAssertEqual(vm.definition.nodes.count, 3)
        let added = vm.definition.nodes.last
        XCTAssertEqual(added?.type, "inference")
        XCTAssertEqual(added?.props["model"]?.string, "", "VM 未拉模型时缺省空串")
        XCTAssertEqual(vm.selectedNodeId, added?.id)
        XCTAssertTrue(vm.dirty)
    }

    // 连线守卫：自环/空端点/完全重复（含 when）拒绝；不同 when 可共存
    func testEdgeGuards() {
        let client = W4MockClient()
        let (vm, _) = makeVMWithAlerts(client: client)
        // 三节点无边定义（避开 makeWorkflow 自带的 start→n2 边干扰重复守卫断言）
        let wf = WorkflowRecord(id: "w1", name: "守卫", definition: WorkflowDefinition(
            nodes: [WorkflowNode(id: "start", type: "start"),
                    WorkflowNode(id: "n2", type: "inference"),
                    WorkflowNode(id: "n3", type: "end")]))
        vm.selectWorkflow(wf)
        XCTAssertEqual(vm.definition.edges.count, 0)

        XCTAssertFalse(vm.addEdge(from: "", to: "n2", when: ""), "空起点拒绝")
        XCTAssertFalse(vm.addEdge(from: "start", to: "", when: ""), "空终点拒绝")
        XCTAssertFalse(vm.addEdge(from: "start", to: "start", when: ""), "自环拒绝")
        XCTAssertTrue(vm.addEdge(from: "start", to: "n2", when: ""))
        XCTAssertFalse(vm.addEdge(from: "start", to: "n2", when: ""), "完全重复拒绝")
        XCTAssertTrue(vm.addEdge(from: "start", to: "n2", when: "true"), "不同 when 可共存")
        XCTAssertTrue(vm.addEdge(from: "n2", to: "n3", when: ""))
        XCTAssertEqual(vm.definition.edges.count, 3)
        XCTAssertEqual(vm.definition.edges[1].when, "true")

        vm.removeEdge(at: 1)
        XCTAssertEqual(vm.definition.edges.count, 2)
        vm.removeEdge(at: 99)   // 越界静默忽略
        XCTAssertEqual(vm.definition.edges.count, 2)
    }

    // 运行事件分发：node_start/done/error 状态机 + approval_required 卡片 + 终态复位
    func testRunEventDispatch() {
        let client = W4MockClient()
        let (vm, _) = makeVMWithAlerts(client: client)
        vm.apply(runEvent: sse("node_start", ["node_id": "n1", "run_id": "r1"]))
        XCTAssertEqual(vm.nodeStatus["n1"], .running)
        vm.apply(runEvent: sse("node_done", ["node_id": "n1", "output_preview": "ok"]))
        XCTAssertEqual(vm.nodeStatus["n1"], .done)
        vm.apply(runEvent: sse("node_error", ["node_id": "n2", "error": "超时"]))
        XCTAssertEqual(vm.nodeStatus["n2"], .error)
        XCTAssertEqual(vm.events.count, 3, "全部事件入流")

        vm.apply(runEvent: sse("approval_required",
                               ["node_id": "n3", "label": "人工确认", "message": "继续？"]))
        XCTAssertEqual(vm.approval, .init(nodeId: "n3", label: "人工确认", message: "继续？"))

        // heartbeat / workflow_reply 仅入流，不改状态
        vm.apply(runEvent: sse("heartbeat"))
        XCTAssertEqual(vm.events.count, 5)

        vm.apply(runEvent: sse("workflow_failed", ["error": "超时"]))
        XCTAssertFalse(vm.running)
        XCTAssertNil(vm.approval, "终态清审批卡片")
    }

    // 运行全流程：先保存 → POST run → 首条 run_id 捕获 → SSE 驱动 → 终态后重拉运行记录
    func testRunWorkflowEndToEnd() async {
        let client = W4MockClient()
        let wf = makeWorkflow("w1")
        client.workflows = [wf]
        client.runs = [WorkflowRunRecord(id: "r1", workflowId: "w1", status: "done")]
        let (vm, _) = makeVMWithAlerts(client: client)
        vm.selectWorkflow(wf)
        let runsBefore = client.listRunsCalls

        vm.runWorkflow()
        let ok = await waitFor { !client.runWorkflowCalls.isEmpty }
        XCTAssertTrue(ok, "应先保存再 POST run")
        XCTAssertEqual(client.updateCalls.count, 1, "运行前先保存（保证服务端定义最新）")
        XCTAssertEqual(client.runWorkflowCalls[0].id, "w1")
        XCTAssertEqual(client.runWorkflowCalls[0].params, [:], "缺省 paramsText={} 解析为空字典")

        client.pushRunEvent(sse("node_start", ["node_id": "start", "run_id": "r1"]))
        let ok2 = await waitFor { vm.runId == "r1" }
        XCTAssertTrue(ok2, "首条带 run_id 的事件应捕获 runId")
        client.pushRunEvent(sse("node_start", ["node_id": "n2", "run_id": "r1"]))
        client.pushRunEvent(sse("node_done", ["node_id": "n2", "run_id": "r1",
                                              "output_preview": "完成"]))
        client.pushRunEvent(sse("workflow_done", ["run_id": "r1", "result_preview": "完成"]))
        client.finishRunStream()
        let ok3 = await waitFor { !vm.running && vm.nodeStatus["n2"] == .done }
        XCTAssertTrue(ok3)
        let ok4 = await waitFor { client.listRunsCalls > runsBefore }
        XCTAssertTrue(ok4, "终态后应重拉运行记录")
    }

    // 运行参数非法 JSON → 弹窗且不发起运行
    func testRunParamsInvalidJSON() async {
        let client = W4MockClient()
        client.workflows = [makeWorkflow("w1")]
        let (vm, box) = makeVMWithAlerts(client: client)
        vm.selectWorkflow(makeWorkflow("w1"))
        vm.paramsText = "{bad json"
        vm.runWorkflow()
        let ok = await waitFor { !box.alerts.isEmpty }
        XCTAssertTrue(ok)
        XCTAssertEqual(box.alerts[0].1, "运行参数不是合法 JSON")
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(client.runWorkflowCalls.isEmpty, "参数非法不得发起运行")
        XCTAssertFalse(vm.running)
    }

    // 启动失败（422 严格校验）：弹「启动失败」+ running 复位
    func testRunStartFailure() async {
        let client = W4MockClient()
        client.workflows = [makeWorkflow("w1")]
        let (vm, box) = makeVMWithAlerts(client: client)
        vm.selectWorkflow(makeWorkflow("w1"))
        vm.runWorkflow()
        let ok = await waitFor { !client.runWorkflowCalls.isEmpty }
        XCTAssertTrue(ok)
        client.finishRunStream(throwing: SidecarError.httpError(status: 422, detail: "工作流定义有错误"))
        let ok2 = await waitFor { !box.alerts.isEmpty }
        XCTAssertTrue(ok2)
        XCTAssertEqual(box.alerts[0].0, "启动失败")
        let ok3 = await waitFor { !vm.running }
        XCTAssertTrue(ok3)
    }

    // 停止：先 POST /workflow-runs/{id}/stop 再断本地流（顺序断言）
    func testStopOrder() async {
        let client = W4MockClient()
        client.workflows = [makeWorkflow("w1")]
        let (vm, _) = makeVMWithAlerts(client: client)
        vm.selectWorkflow(makeWorkflow("w1"))
        vm.runWorkflow()
        let ok = await waitFor { !client.runWorkflowCalls.isEmpty }
        XCTAssertTrue(ok)
        client.pushRunEvent(sse("node_start", ["node_id": "start", "run_id": "r9"]))
        let ok2 = await waitFor { vm.runId == "r9" && vm.running }
        XCTAssertTrue(ok2)

        vm.stopRunServer()
        let ok3 = await waitFor { client.stopRunCalls == ["r9"] }
        XCTAssertTrue(ok3, "停止必须先调服务端 stop 端点")
        let ok4 = await waitFor { !vm.running }
        XCTAssertTrue(ok4, "随后断本地流清运行态")
    }

    // 审批决议：成功清卡片；失败弹「审批失败」保留卡片
    func testApprovalRespond() async {
        let client = W4MockClient()
        client.workflows = [makeWorkflow("w1")]
        let (vm, box) = makeVMWithAlerts(client: client)
        vm.selectWorkflow(makeWorkflow("w1"))
        vm.runWorkflow()
        let ok = await waitFor { !client.runWorkflowCalls.isEmpty }
        XCTAssertTrue(ok)
        client.pushRunEvent(sse("approval_required",
                                ["node_id": "n3", "label": "人工确认", "message": "继续？",
                                 "run_id": "r5"]))
        let ok2 = await waitFor { vm.approval != nil }
        XCTAssertTrue(ok2)

        vm.respondApproval(approved: true, comment: "看着没问题")
        let ok3 = await waitFor { client.approveCalls.count == 1 }
        XCTAssertTrue(ok3)
        XCTAssertEqual(client.approveCalls[0].runId, "r5")
        XCTAssertTrue(client.approveCalls[0].approved)
        XCTAssertEqual(client.approveCalls[0].comment, "看着没问题")
        let ok4 = await waitFor { vm.approval == nil }
        XCTAssertTrue(ok4, "审批成功清卡片")

        // 失败分支：409 弹窗，卡片保留（对齐 TSX else 分支不 setApproval(null)）
        client.approveError = SidecarError.httpError(status: 409, detail: "当前状态 done 不在等待审批")
        vm.apply(runEvent: sse("approval_required",
                               ["node_id": "n3", "label": "L", "message": "M", "run_id": "r5"]))
        vm.respondApproval(approved: false)
        let ok5 = await waitFor { !box.alerts.isEmpty }
        XCTAssertTrue(ok5)
        XCTAssertEqual(box.alerts[0].0, "审批失败")
        XCTAssertNotNil(vm.approval)
    }

    // A13 资源变更：resource==workflow / gap 重拉；dirty 守卫；其他资源忽略
    func testAppEventDirtyGuard() async {
        let client = W4MockClient()
        let (vm, _) = makeVMWithAlerts(client: client)
        let before = client.listWorkflowsCalls

        vm.apply(appEvent: sse("resource_changed", ["resource": "plugin", "seq": 1]))
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(client.listWorkflowsCalls, before, "其他资源变更忽略")

        vm.apply(appEvent: sse("resource_changed", ["resource": "workflow", "seq": 2]))
        let ok = await waitFor { client.listWorkflowsCalls > before }
        XCTAssertTrue(ok, "workflow 变更应重拉")

        // dirty 守卫：编辑中绝不冲掉未保存改动
        vm.selectWorkflow(makeWorkflow("w1"))
        vm.name = "编辑中"
        XCTAssertTrue(vm.dirty)
        let beforeDirty = client.listWorkflowsCalls
        vm.apply(appEvent: sse("resource_changed", ["resource": "workflow", "seq": 3]))
        vm.apply(appEvent: sse("gap", ["seq": 4]))
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(client.listWorkflowsCalls, beforeDirty, "dirty 时跳过重拉")

        // gap 在非 dirty 时重拉
        vm.selectWorkflow(makeWorkflow("w1"))
        vm.apply(appEvent: sse("gap", ["seq": 5]))
        let ok2 = await waitFor { client.listWorkflowsCalls > beforeDirty }
        XCTAssertTrue(ok2)
    }

    // 运行记录展开/收起：展开拉详情（含节点事件），再点收起
    func testRunDetailToggle() async {
        let client = W4MockClient()
        client.runDetail = WorkflowRunDetail(
            id: "r1", workflowId: "w1", status: "done",
            nodeEvents: [WorkflowNodeEventRecord(id: 1, nodeId: "n1", nodeType: "inference",
                                                 status: "done", durationMs: 120)])
        let (vm, _) = makeVMWithAlerts(client: client)
        vm.toggleRunDetail("r1")
        XCTAssertEqual(vm.expandedRunId, "r1")
        let ok = await waitFor { vm.runDetail != nil }
        XCTAssertTrue(ok)
        XCTAssertEqual(vm.runDetail?.nodeEvents.first?.nodeId, "n1")
        vm.toggleRunDetail("r1")
        XCTAssertNil(vm.expandedRunId)
        XCTAssertNil(vm.runDetail)
    }

    // 生命周期：start 幂等；stop 断流且运行态复位
    func testStartStopLifecycle() async {
        let client = W4MockClient()
        let (vm, _) = makeVMWithAlerts(client: client)
        client.inferenceModels = [InferenceModelEntry(name: "glm:latest"),
                                  InferenceModelEntry(name: "")]
        vm.start()
        let ok = await waitFor { client.listWorkflowsCalls == 1 && client.appEventsCalls == 1 }
        XCTAssertTrue(ok)
        let ok2 = await waitFor { vm.models == ["glm:latest"] }
        XCTAssertTrue(ok2, "模型名抽取 + 空名过滤（对齐 m.name || m + filter(Boolean)）")
        vm.start()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(client.appEventsCalls, 1, "start 幂等，不重复起流")
        vm.stop()
        XCTAssertFalse(vm.running)
    }

    // ══ P3-W6⑤ 回归：nativeReady 同步点亮时序下的列表加载可靠性 ══

    /// nativeReady 于 runtime init 同步点亮——VM 创建/订阅时恒已 true，
    /// 列表加载不得依赖任何「就绪翻转」信号（历史上 status onChange 触发的
    /// 补拉已消亡）。走 runtime.client 生产路径（无 clientOverride）。
    func testAttachLoadsListWhenNativeReadyAlreadyTrue() async {
        let client = W4MockClient()
        client.workflows = [makeWorkflow("w1")]
        let appState = TestRuntimeSupport.makeAppState(client: client)
        XCTAssertTrue(appState.runtime.nativeReady, "前置：订阅前 nativeReady 已 true")
        let vm = WorkflowPanelViewModel(appState: appState, retryInterval: 0.05)
        vm.attach()
        defer { vm.detach() }
        let ok = await waitFor { vm.workflows.map(\.id) == ["w1"] }
        XCTAssertTrue(ok, "nativeReady 恒 true 时序下 attach 应可靠加载列表")
    }

    /// 自愈承接：首拉失败（didLoadWorkflows=false）→ 流 connected 握手补拉一次；
    /// 已成功后再握手不重复拉（只兜底失败态）；dirty 时不拉（同 resource_changed 守卫）。
    func testConnectedHandshakeReloadsAfterFailedInitialLoad() async {
        let client = W4MockClient()
        client.listWorkflowsError = SidecarError.offline("down")
        let (vm, _) = makeVMWithAlerts(client: client)
        await vm.loadWorkflows()   // 首拉失败
        XCTAssertTrue(vm.workflows.isEmpty)

        // dirty 守卫：编辑中即使握手也不拉
        client.listWorkflowsError = nil
        client.workflows = [makeWorkflow("w1")]
        vm.selectWorkflow(makeWorkflow("w0"))
        vm.name = "编辑中"
        XCTAssertTrue(vm.dirty)
        let callsBefore = client.listWorkflowsCalls
        vm.apply(appEvent: sse("connected", ["seq": 0]))
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(client.listWorkflowsCalls, callsBefore, "dirty 时握手不补拉")

        // 非 dirty：握手补拉失败态首拉
        vm.selectWorkflow(makeWorkflow("w0"))   // 回填清脏
        vm.apply(appEvent: sse("connected", ["seq": 0]))
        let ok = await waitFor { vm.workflows.map(\.id) == ["w1"] }
        XCTAssertTrue(ok, "connected 握手应补拉失败的首拉")

        // 已成功后再握手不重复拉
        let callsAfter = client.listWorkflowsCalls
        vm.apply(appEvent: sse("connected", ["seq": 0]))
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(client.listWorkflowsCalls, callsAfter, "已成功后握手不重复拉")
    }
}
