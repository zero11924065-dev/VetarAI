//
//  NativeWorkflowEngineTests.swift
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

//  逐条对照 subagent/sidecar/workflow/engine.py（⛔ 只读行为规格源，1212 行）与
//  sidecar/workflow/test_checkpoint077.py（双跑基线）：
//    · 线性流事件序 + 结果透传（L1）；全事件注入 run_id（G1，0.2.4 W1 契约）
//    · 推理纯调用（M4：单 user 消息、无系统提示词；缺省提示词「请处理输入。」）
//    · 条件静态分支 7 算子 / 动态裁判（L2/L3；裁判失败按 false 文案但主链 failed——
//      Python res.ok=False → workflow_failed 的实际行为保真）
//    · 并行收集保序（L4）；循环逐项/分批/逗号链/fail_policy（L5/G2/G3）
//    · 审批挂起/批准/驳回（L6/L7）；停止语义（L10 + C5：非进行中不置取消）
//    · 模型驻留（M1/M2/M3：切换卸旧、相同不卸、结束卸驻留）
//    · REQ-WF-015：节点级 timeout_s 透传 connector + 超时文案写实际生效秒数
//    · 文件输入/输出/读取（F1-F6/F11）；图片继承与剔除（F8/G5）
//    · text_output/variable_set/code/reply（H1-H4/H7b）
//
//  隔离纪律：假 connector（不起真网络/真 Ollama）；mktemp 临时库存储；
//  code 节点经 /usr/bin/env python3 子进程（实现自身机制，纯本地不联网）。
//

import XCTest
@testable import VetarAINative

// MARK: - 假 connector（checkpoint077 FakeConn 同形）

private final class FakeWFConnector: NativeWorkflowConnector, @unchecked Sendable {
    struct Call {
        let model: String
        let messages: [[String: JSONValue]]
        let images: [String]?
        let readTimeoutS: Double?
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _unloads: [String] = []

    /// model → 响应闭包（抛错 = 模型调用失败）；缺省回显用户消息内容。
    var responders: [String: (Call) async throws -> String] = [:]

    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }
    var unloads: [String] { lock.lock(); defer { lock.unlock() }; return _unloads }

    func chat(model: String, messages: [[String: JSONValue]], images: [String]?,
              readTimeoutS: Double?) async throws -> String {
        let call = Call(model: model, messages: messages, images: images,
                        readTimeoutS: readTimeoutS)
        lock.lock(); _calls.append(call); lock.unlock()
        let responder: ((Call) async throws -> String)? = { self.lock.lock(); defer { self.lock.unlock() }
            return self.responders[model] }()
        if let responder { return try await responder(call) }
        return messages.last?["content"]?.string ?? ""
    }

    @discardableResult
    func unloadModel(_ model: String) async -> Bool {
        lock.lock(); _unloads.append(model); lock.unlock()
        return true
    }
}

// MARK: - 假工具执行器（P2-W3 注入口）

private final class FakeToolExecutor: NativeWorkflowToolExecutor, @unchecked Sendable {
    private let lock = NSLock()
    var result: [String: JSONValue] = ["ok": .bool(true)]
    var thrown: Error?
    private(set) var received: [(tool: String, args: [String: JSONValue], sandbox: String)] = []

    func executeTool(_ tool: String, args: [String: JSONValue],
                     sandboxRoot: String) async throws -> [String: JSONValue] {
        lock.lock(); received.append((tool, args, sandboxRoot)); lock.unlock()
        if let thrown { throw thrown }
        return result
    }
}

final class NativeWorkflowEngineTests: XCTestCase {

    private var tmp: URL!
    private var db: NativeDatabase!
    private var store: NativeWorkflowStore!
    private var runtime: NativeWorkflowRuntimeCenter!
    private var conn: FakeWFConnector!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("w2wfeng_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        db = NativeDatabase(projectsRoot: tmp.appendingPathComponent("projects"))
        store = NativeWorkflowStore(database: db)
        runtime = NativeWorkflowRuntimeCenter()
        conn = FakeWFConnector()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    // MARK: - 构造助手

    private func jnode(_ id: String, _ type: String,
                       _ props: [String: JSONValue] = [:]) -> JSONValue {
        var o = props
        o["id"] = .string(id)
        o["type"] = .string(type)
        return .object(o)
    }

    private func jedge(_ from: String, _ to: String, _ when: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["from": .string(from), "to": .string(to)]
        if let when { o["when"] = .string(when) }
        return .object(o)
    }

    private func jdef(_ nodes: [JSONValue], _ edges: [JSONValue]) -> JSONValue {
        .object(["nodes": .array(nodes), "edges": .array(edges), "params": .object([:])])
    }

    private func makeEngine(_ def: JSONValue, params: [String: JSONValue] = [:],
                            globalTimeout: Double = 300,
                            toolExecutor: NativeWorkflowToolExecutor? = nil)
        throws -> (NativeWorkflowEngine, String) {
        let runId = try store.createWorkflowRun(workflowId: "wf-test",
                                                variables: .object(params))
        let engine = NativeWorkflowEngine(
            runId: runId, definition: def, connector: conn, store: store, runtime: runtime,
            sandboxRoot: tmp.path, params: params, toolExecutor: toolExecutor,
            globalReadTimeout: { globalTimeout })
        return (engine, runId)
    }

    /// 跑完整个事件流并收集（终态事件后流自然结束）。
    private func runCollect(_ engine: NativeWorkflowEngine) async -> [WorkflowEngineEvent] {
        var evs: [WorkflowEngineEvent] = []
        let stream = await engine.run()
        for await ev in stream { evs.append(ev) }
        return evs
    }

    private func writeFile(_ rel: String, _ content: String) throws -> String {
        let url = tmp.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try content.write(to: url, atomically: false, encoding: .utf8)
        return url.path
    }

    // ════════════════════════════════════════════════════════════
    // MARK: - 线性流 + run_id 注入（L1 / G1）
    // ════════════════════════════════════════════════════════════

    func testLinearFlowEventsAndResult() async throws {
        let def = jdef([
            jnode("s", "start", ["label": .string("开始")]),
            jnode("t1", "text_output", ["template": .string("汇总：{{params.topic}}")]),
            jnode("e", "end", ["output": .string("{{t1.output}}")]),
        ], [jedge("s", "t1"), jedge("t1", "e")])
        let (engine, runId) = try makeEngine(def, params: ["topic": .string("财报")])
        let evs = await runCollect(engine)

        // 事件序逐字（L1a）
        XCTAssertEqual(evs.map(\.event), [
            "node_start", "node_done",   // s
            "node_start", "node_done",   // t1
            "node_start", "node_done",   // e
            "workflow_done",
        ])
        // G1a/G1b：所有事件（含 node_start/node_done/终态）都带 run_id
        XCTAssertTrue(evs.allSatisfy { $0.data["run_id"] == .string(runId) },
                      "事件缺 run_id：\(evs)")
        // node_start 载荷
        XCTAssertEqual(evs[0].data["node_id"], .string("s"))
        XCTAssertEqual(evs[0].data["label"], .string("开始"))
        XCTAssertEqual(evs[0].data["type"], .string("start"))
        XCTAssertEqual(evs[2].data["label"], .string("t1"))   // 无 label → id
        // node_done 预览（≤300 截）
        XCTAssertEqual(evs[3].data["output_preview"], .string("汇总：财报"))
        // L1b：end 的 output 引用透传为工作流结果
        XCTAssertEqual(evs.last?.data["result_preview"], .string("汇总：财报"))

        // 落库：run 终态 done + result；节点事件 running/done 成对
        let run = try XCTUnwrap(try store.getWorkflowRun(runId))
        XCTAssertEqual(run.status, "done")
        XCTAssertEqual(run.result, "汇总：财报")
        let records = try store.listWorkflowNodeEvents(runId)
        XCTAssertEqual(records.map(\.status),
                       ["running", "done", "running", "done", "running", "done"])
        XCTAssertEqual(Set(records.map(\.nodeId)), ["s", "t1", "e"])
    }

    /// end 节点无 output 引用 → 结果为结束节点自身输出（Python L1136-1137 else 分支）。
    func testEndWithoutOutputRef() async throws {
        let def = jdef([jnode("s", "start"), jnode("e", "end")], [jedge("s", "e")])
        let (engine, runId) = try makeEngine(def)
        let evs = await runCollect(engine)
        XCTAssertEqual(evs.last?.event, "workflow_done")
        // final_result None → result NULL、preview ""
        XCTAssertEqual(evs.last?.data["result_preview"], .string(""))
        let run = try XCTUnwrap(try store.getWorkflowRun(runId))
        XCTAssertEqual(run.status, "done")
        XCTAssertNil(run.result)
    }

    // ════════════════════════════════════════════════════════════
    // MARK: - 推理节点（M4 纯调用 / 模板 / 缺省提示词）
    // ════════════════════════════════════════════════════════════

    func testInferencePureCall() async throws {
        let def = jdef([
            jnode("s", "start"),
            jnode("n1", "inference", ["model": .string("m1"),
                                      "prompt": .string("识别 {{params.file}}")]),
            jnode("e", "end", ["output": .string("{{n1.output}}")]),
        ], [jedge("s", "n1"), jedge("n1", "e")])
        let (engine, runId) = try makeEngine(def, params: ["file": .string("1.jpg")])
        let evs = await runCollect(engine)
        XCTAssertEqual(evs.last?.event, "workflow_done")

        // M4a：纯调用只有一条 user 消息（无系统提示词/工具）
        let call = try XCTUnwrap(conn.calls.first)
        XCTAssertEqual(call.model, "m1")
        XCTAssertEqual(call.messages.count, 1)
        XCTAssertEqual(call.messages[0]["role"], .string("user"))
        // M4b：模板渲染参数
        XCTAssertEqual(call.messages[0]["content"], .string("识别 1.jpg"))
        // 未配置 images / timeout_s → nil（Python 不传 kwarg 同语义）
        XCTAssertNil(call.images)
        XCTAssertNil(call.readTimeoutS)
        // 回显即输出 → 结果透传
        XCTAssertEqual(evs.last?.data["result_preview"], .string("识别 1.jpg"))
        // 结束卸载驻留模型（M3）
        XCTAssertEqual(conn.unloads, ["m1"])
        // model_used 落库
        let done = try store.listWorkflowNodeEvents(runId).first { $0.status == "done" && $0.nodeId == "n1" }
        XCTAssertEqual(done?.modelUsed, "m1")
    }

    func testInferenceDefaultPrompt() async throws {
        let def = jdef([jnode("s", "start"),
                        jnode("n1", "inference", ["model": .string("m1")]),
                        jnode("e", "end")], [jedge("s", "n1"), jedge("n1", "e")])
        let (engine, _) = try makeEngine(def)
        _ = await runCollect(engine)
        XCTAssertEqual(conn.calls.first?.messages[0]["content"], .string("请处理输入。"))
    }

    func testInferenceMissingModel() async throws {
        let def = jdef([jnode("s", "start"), jnode("n1", "inference"), jnode("e", "end")],
                       [jedge("s", "n1"), jedge("n1", "e")])
        let (engine, runId) = try makeEngine(def)
        let evs = await runCollect(engine)
        XCTAssertEqual(evs.map(\.event).last, "workflow_failed")
        XCTAssertEqual(evs.last?.data["node_id"], .string("n1"))
        XCTAssertEqual(evs.last?.data["error"], .string("推理节点未配置模型"))
        // node_error 事件 + run 落库 failed
        XCTAssertTrue(evs.contains { $0.event == "node_error" })
        let run = try XCTUnwrap(try store.getWorkflowRun(runId))
        XCTAssertEqual(run.status, "failed")
        XCTAssertEqual(run.error, "推理节点未配置模型")
        // 失败路径也卸载驻留模型（本例无驻留 → 无 unload 调用）
        XCTAssertEqual(conn.unloads, [])
    }

    // ════════════════════════════════════════════════════════════
    // MARK: - 模型驻留（M1/M2/M3）
    // ════════════════════════════════════════════════════════════

    func testModelSwitchUnloadsPrevious() async throws {
        let def = jdef([
            jnode("s", "start"),
            jnode("a", "inference", ["model": .string("modelA")]),
            jnode("b", "inference", ["model": .string("modelB")]),
            jnode("e", "end"),
        ], [jedge("s", "a"), jedge("a", "b"), jedge("b", "e")])
        let (engine, _) = try makeEngine(def)
        _ = await runCollect(engine)
        // M1 切换时卸旧 + M3 结束时卸最后驻留
        XCTAssertEqual(conn.unloads, ["modelA", "modelB"])
    }

    func testModelSameNoMidUnload() async throws {
        let def = jdef([
            jnode("s", "start"),
            jnode("a", "inference", ["model": .string("same")]),
            jnode("b", "inference", ["model": .string("same")]),
            jnode("e", "end"),
        ], [jedge("s", "a"), jedge("a", "b"), jedge("b", "e")])
        let (engine, _) = try makeEngine(def)
        _ = await runCollect(engine)
        // M2：相同模型连续多步不卸载，只在结束卸一次
        XCTAssertEqual(conn.unloads, ["same"])
        XCTAssertEqual(conn.calls.count, 2)
    }

    // ════════════════════════════════════════════════════════════
    // MARK: - 条件节点（L2 静态 / L3 动态裁判 / 算子表）
    // ════════════════════════════════════════════════════════════

    private func conditionDef(value: String, op: String = "contains",
                              matchValue: String = "钱") -> JSONValue {
        jdef([
            jnode("s", "start"),
            jnode("n1", "text_output", ["template": .string(value)]),
            jnode("c", "condition", ["match": .object([
                "variable": .string("{{n1.output}}"), "operator": .string(op),
                "value": .string(matchValue)])]),
            jnode("tt", "text_output", ["template": .string("命中分支")]),
            jnode("ff", "text_output", ["template": .string("未命中分支")]),
            jnode("e", "end", ["output": .string("{{tt.output}}|{{ff.output}}")]),
        ], [
            jedge("s", "n1"), jedge("n1", "c"),
            jedge("c", "tt", "true"), jedge("c", "ff", "false"),
            jedge("tt", "e"), jedge("ff", "e"),
        ])
    }

    func testConditionStaticTrueBranch() async throws {
        let (engine, runId) = try makeEngine(conditionDef(value: "账单里有钱"))
        let evs = await runCollect(engine)
        // L2a：命中走 true 分支——tt 执行、ff 不执行
        let starts = evs.filter { $0.event == "node_start" }.compactMap { $0.data["node_id"]?.string }
        XCTAssertEqual(starts, ["s", "n1", "c", "tt", "e"])
        XCTAssertEqual(evs.last?.event, "workflow_done")
        // 条件节点输出 true 落变量（快照 str() 化——Python L1103 `str(out)[:2000]`）
        let run = try XCTUnwrap(try store.getWorkflowRun(runId))
        XCTAssertEqual(run.variables.object?["c"]?.object?["output"], .string("True"))
    }

    func testConditionStaticFalseBranch() async throws {
        let (engine, _) = try makeEngine(conditionDef(value: "账单里没有金"))
        let evs = await runCollect(engine)
        let starts = evs.filter { $0.event == "node_start" }.compactMap { $0.data["node_id"]?.string }
        XCTAssertEqual(starts, ["s", "n1", "c", "ff", "e"])   // L2b：不中走 false 分支
    }

    /// _eval_condition 七种算子逐条对照（engine.py L218-241）。
    func testConditionOperators() {
        let vars: [String: JSONValue] = ["n1": .object(["output": .string("hello world")])]
        func node(_ op: String, _ value: String, variable: String = "{{n1.output}}")
            -> [String: JSONValue] {
            ["id": .string("c"), "type": .string("condition"),
             "match": .object(["variable": .string(variable), "operator": .string(op),
                               "value": .string(value)])]
        }
        XCTAssertTrue(NativeWorkflowEngine.evalCondition(node("contains", "world"), vars))
        XCTAssertFalse(NativeWorkflowEngine.evalCondition(node("contains", "WORLD"), vars))
        XCTAssertTrue(NativeWorkflowEngine.evalCondition(node("not_contains", "xyz"), vars))
        XCTAssertFalse(NativeWorkflowEngine.evalCondition(node("not_contains", "hello"), vars))
        XCTAssertTrue(NativeWorkflowEngine.evalCondition(node("equals", "hello world"), vars))
        XCTAssertFalse(NativeWorkflowEngine.evalCondition(node("equals", "hello"), vars))
        XCTAssertTrue(NativeWorkflowEngine.evalCondition(node("starts_with", "hello"), vars))
        XCTAssertFalse(NativeWorkflowEngine.evalCondition(node("starts_with", "world"), vars))
        XCTAssertTrue(NativeWorkflowEngine.evalCondition(node("regex", "w.rld"), vars))
        // 非法正则 → False（Python re.error 吞掉）
        XCTAssertFalse(NativeWorkflowEngine.evalCondition(node("regex", "(["), vars))
        // empty / not_empty 作用于 strip 后文本
        let emptyVars: [String: JSONValue] = ["n1": .object(["output": .string("  ")])]
        XCTAssertTrue(NativeWorkflowEngine.evalCondition(node("empty", ""), emptyVars))
        XCTAssertFalse(NativeWorkflowEngine.evalCondition(node("not_empty", ""), emptyVars))
        XCTAssertTrue(NativeWorkflowEngine.evalCondition(node("not_empty", ""), vars))
        // 未知算子 → False；变量缺失 → target None → text ""
        XCTAssertFalse(NativeWorkflowEngine.evalCondition(node("bogus", "x"), vars))
        XCTAssertTrue(NativeWorkflowEngine.evalCondition(
            node("empty", "", variable: "{{missing}}"), vars))
    }

    func testConditionDynamicReferee() async throws {
        conn.responders["judge"] = { _ in "是图片\n因为看到了像素" }
        let def = jdef([
            jnode("s", "start"),
            jnode("c", "condition", ["model": .string("judge")]),
            jnode("img", "text_output", ["template": .string("判为图片")]),
            jnode("oth", "text_output", ["template": .string("判为其他")]),
            jnode("e", "end", ["output": .string("{{img.output}}")]),
        ], [
            jedge("s", "c"), jedge("c", "img", "是图片"), jedge("c", "oth", "其他"),
            jedge("img", "e"), jedge("oth", "e"),
        ])
        let (engine, runId) = try makeEngine(def)
        let evs = await runCollect(engine)
        // L3：动态裁判输出首行即分支名 → 走「是图片」边
        let starts = evs.filter { $0.event == "node_start" }.compactMap { $0.data["node_id"]?.string }
        XCTAssertEqual(starts, ["s", "c", "img", "e"])
        XCTAssertEqual(evs.last?.data["result_preview"], .string("判为图片"))
        // 裁判输出写入节点变量；缺省提示词
        XCTAssertEqual(conn.calls.first?.messages[0]["content"], .string("请判断并只输出分支名。"))
        let run = try XCTUnwrap(try store.getWorkflowRun(runId))
        XCTAssertEqual(run.variables.object?["c"]?.object?["output"], .string("是图片"))
        // 裁判模型参与驻留管理
        XCTAssertEqual(conn.unloads, ["judge"])
    }

    /// 裁判调用失败：返回 (ok=False, "false")，主链 res.ok=False → workflow_failed
    /// （Python 实际行为；「已按 false 分支继续」只是错误文案措辞）。
    func testConditionRefereeFailureFailsWorkflow() async throws {
        conn.responders["judge"] = { _ in
            throw WorkflowConnectorError.api(status: 500, prefix: "对话请求失败")
        }
        let def = jdef([
            jnode("s", "start"),
            jnode("c", "condition", ["model": .string("judge")]),
            jnode("e", "end"),
        ], [jedge("s", "c"), jedge("c", "e")])
        let (engine, runId) = try makeEngine(def)
        let evs = await runCollect(engine)
        XCTAssertEqual(evs.last?.event, "workflow_failed")
        XCTAssertEqual(evs.last?.data["error"],
                       .string("裁判模型调用失败：OllamaAPIError: 对话请求失败（HTTP 500）"))
        let run = try XCTUnwrap(try store.getWorkflowRun(runId))
        XCTAssertEqual(run.status, "failed")
    }

    // ════════════════════════════════════════════════════════════
    // MARK: - 并行（L4：收集保序 / 错误聚合）
    // ════════════════════════════════════════════════════════════

    func testParallelCollectsOutputsInOrder() async throws {
        conn.responders["slow"] = { _ in
            try await Task.sleep(nanoseconds: 300_000_000)
            return "结果A"
        }
        conn.responders["fast"] = { _ in "结果B" }
        let def = jdef([
            jnode("s", "start"),
            jnode("p", "parallel", ["branches": .array([.string("b1"), .string("b2")])]),
            jnode("b1", "inference", ["model": .string("slow")]),
            jnode("b2", "inference", ["model": .string("fast")]),
            jnode("e", "end", ["output": .string("{{p.output}}")]),
        ], [jedge("s", "p"), jedge("p", "e")])
        let (engine, _) = try makeEngine(def)
        let evs = await runCollect(engine)
        XCTAssertEqual(evs.last?.event, "workflow_done")
        // asyncio.gather 保序：声明序而非完成序（slow 先声明但后完成）
        let run = try XCTUnwrap(try store.getWorkflowRun(try XCTUnwrap(
            evs.last?.data["run_id"]?.string)))
        XCTAssertEqual(run.result, "['结果A', '结果B']")   // Python str(list) repr 形态
    }

    func testParallelErrorAggregation() async throws {
        conn.responders["bad"] = { _ in
            throw WorkflowConnectorError.api(status: 500, prefix: "对话请求失败")
        }
        let def = jdef([
            jnode("s", "start"),
            jnode("p", "parallel", ["branches": .array([.string("b1"), .string("b2")])]),
            jnode("b1", "inference", ["model": .string("echo")]),
            jnode("b2", "inference", ["model": .string("bad")]),
            jnode("e", "end"),
        ], [jedge("s", "p"), jedge("p", "e")])
        let (engine, runId) = try makeEngine(def)
        let evs = await runCollect(engine)
        XCTAssertEqual(evs.last?.event, "workflow_failed")
        // errors 用「；」拼接，形态 "node_id: error"
        XCTAssertEqual(evs.last?.data["error"],
                       .string("b2: 模型调用失败：OllamaAPIError: 对话请求失败（HTTP 500）"))
        let run = try XCTUnwrap(try store.getWorkflowRun(runId))
        XCTAssertEqual(run.status, "failed")
    }

    func testParallelEmptyBranches() async throws {
        let def = jdef([
            jnode("s", "start"),
            jnode("p", "parallel", ["branches": .array([.string("ghost")])]),   // 不存在被滤掉
            jnode("e", "end"),
        ], [jedge("s", "p"), jedge("p", "e")])
        let (engine, _) = try makeEngine(def)
        let evs = await runCollect(engine)
        XCTAssertEqual(evs.last?.data["error"], .string("并行节点未配置 branches"))
    }

    // ════════════════════════════════════════════════════════════
    // MARK: - 循环（L5 逐项/分批/逗号链；G2/G3 失败策略；契约点 4）
    // ════════════════════════════════════════════════════════════

    private func loopDef(items: JSONValue, branch: JSONValue,
                         extra: [String: JSONValue] = [:]) -> JSONValue {
        var props: [String: JSONValue] = ["items": items, "branch": branch]
        for (k, v) in extra { props[k] = v }
        return jdef([
            jnode("s", "start"),
            jnode("lp", "loop", props),
            jnode("n2", "inference", ["model": .string("m"),
                                      "prompt": .string("处理 {{item}}")]),
            jnode("e", "end", ["output": .string("{{lp.output}}")]),
        ], [jedge("s", "lp"), jedge("lp", "e")])
    }

    func testLoopItemIteration() async throws {
        let def = loopDef(items: .array([.string("a"), .string("b"), .string("c")]),
                          branch: .string("n2"))
        let (engine, runId) = try makeEngine(def)
        let evs = await runCollect(engine)
        XCTAssertEqual(evs.last?.event, "workflow_done")
        // L5a：逐项执行 3 次；L5b：{{item}} 渲染进提示词
        XCTAssertEqual(conn.calls.count, 3)
        XCTAssertEqual(conn.calls.map { $0.messages[0]["content"]?.string },
                       ["处理 a", "处理 b", "处理 c"])
        // 输出收集为列表（末节点输出 = 回显）
        let run = try XCTUnwrap(try store.getWorkflowRun(runId))
        XCTAssertEqual(run.result, "['处理 a', '处理 b', '处理 c']")
        // 循环变量清栈（item/item_index/batch 不残留）
        XCTAssertNil(run.variables.object?["item"])
        XCTAssertNil(run.variables.object?["item_index"])
        XCTAssertNil(run.variables.object?["batch"])
    }

    func testLoopBatching() async throws {
        let def = loopDef(items: .array(["a", "b", "c", "d", "e"].map { .string($0) }),
                          branch: .string("n2"), extra: ["batch_size": .int(2)])
        let (engine, _) = try makeEngine(def)
        let evs = await runCollect(engine)
        XCTAssertEqual(evs.last?.event, "workflow_done")
        // L5c：5 项按 2 分批 → 3 轮
        XCTAssertEqual(conn.calls.count, 3)
        // L5d：多元素批 {{item}} 为列表 → 模板渲染紧凑 JSON
        XCTAssertEqual(conn.calls[0].messages[0]["content"], .string(#"处理 ["a", "b"]"#))
        XCTAssertEqual(conn.calls[1].messages[0]["content"], .string(#"处理 ["c", "d"]"#))
        XCTAssertEqual(conn.calls[2].messages[0]["content"], .string("处理 e"))   // 单元素批旧行为
    }

    func testLoopCommaChain() async throws {
        // 0.2.3：逗号分隔顺序链字符串（"ocr, save" 容忍空白）
        let def = jdef([
            jnode("s", "start"),
            jnode("lp", "loop", ["items": .array([.string("x")]),
                                 "branch": .string("s1, s2")]),
            jnode("s1", "inference", ["model": .string("m"),
                                      "prompt": .string("第一步 {{item}}")]),
            jnode("s2", "inference", ["model": .string("m"),
                                      "prompt": .string("第二步 {{s1.output}}")]),
            jnode("e", "end", ["output": .string("{{lp.output}}")]),
        ], [jedge("s", "lp"), jedge("lp", "e")])
        let (engine, runId) = try makeEngine(def)
        let evs = await runCollect(engine)
        XCTAssertEqual(evs.last?.event, "workflow_done")
        // L5e：链两步各执行一次；L5e2：链内引用上游输出
        XCTAssertEqual(conn.calls.map { $0.messages[0]["content"]?.string },
                       ["第一步 x", "第二步 第一步 x"])
        // 链的输出 = 末节点输出
        let run = try XCTUnwrap(try store.getWorkflowRun(runId))
        XCTAssertEqual(run.result, "['第二步 第一步 x']")
    }

    func testLoopArrayBranch() async throws {
        let def = loopDef(items: .array([.string("a")]),
                          branch: .array([.string("n2")]))
        let (engine, _) = try makeEngine(def)
        let evs = await runCollect(engine)
        XCTAssertEqual(evs.last?.event, "workflow_done")
        XCTAssertEqual(conn.calls.count, 1)
    }

    /// 契约点 4：loop.branch 形态校验（engine.py L649-660 逐条）。
    func testLoopBranchValidation() async throws {
        // 指向不存在的节点
        var (engine, runId) = try makeEngine(
            loopDef(items: .array([.string("a")]), branch: .string("ghost")))
        var evs = await runCollect(engine)
        XCTAssertEqual(evs.last?.event, "workflow_failed")
        XCTAssertEqual(evs.last?.data["error"], .string("loop.branch 节点不存在"))
        XCTAssertEqual(try XCTUnwrap(try store.getWorkflowRun(runId)).error,
                       "loop.branch 节点不存在")
        // 缺 branch 字段
        (engine, runId) = try makeEngine(
            loopDef(items: .array([.string("a")]), branch: .null))
        evs = await runCollect(engine)
        XCTAssertEqual(evs.last?.data["error"], .string("loop.branch 节点不存在"))
        // items 非列表 → type 名入文案
        (engine, runId) = try makeEngine(
            loopDef(items: .string("abc"), branch: .string("n2")))
        evs = await runCollect(engine)
        XCTAssertEqual(evs.last?.data["error"], .string("loop.items 不是列表：str"))
        (engine, _) = try makeEngine(
            loopDef(items: .object(["k": .int(1)]), branch: .string("n2")))
        evs = await runCollect(engine)
        XCTAssertEqual(evs.last?.data["error"], .string("loop.items 不是列表：dict"))
    }

    func testLoopFailPolicyAbort() async throws {
        conn.responders["m"] = { call in
            let content = call.messages[0]["content"]?.string ?? ""
            if content.contains("处理 b") {
                throw WorkflowConnectorError.api(status: 500, prefix: "对话请求失败")
            }
            return content
        }
        let def = loopDef(items: .array([.string("a"), .string("b"), .string("c")]),
                          branch: .string("n2"))
        let (engine, runId) = try makeEngine(def)
        let evs = await runCollect(engine)
        // G3：abort（默认）某批失败即中止——c 不再执行
        XCTAssertEqual(evs.last?.event, "workflow_failed")
        XCTAssertEqual(conn.calls.count, 2)
        let run = try XCTUnwrap(try store.getWorkflowRun(runId))
        XCTAssertEqual(run.error,
                       "第 2 批：模型调用失败：OllamaAPIError: 对话请求失败（HTTP 500）")
    }

    func testLoopFailPolicySkip() async throws {
        conn.responders["m"] = { call in
            let content = call.messages[0]["content"]?.string ?? ""
            if content.contains("处理 b") {
                throw WorkflowConnectorError.api(status: 500, prefix: "对话请求失败")
            }
            return content
        }
        let def = loopDef(items: .array([.string("a"), .string("b"), .string("c")]),
                          branch: .string("n2"), extra: ["fail_policy": .string("skip")])
        let (engine, runId) = try makeEngine(def)
        let evs = await runCollect(engine)
        // G2a：skip 整体成功
        XCTAssertEqual(evs.last?.event, "workflow_done")
        // G2b：失败批发跳过事件（带 run_id）
        let skipped = evs.filter { $0.event == "loop_batch_skipped" }
        XCTAssertEqual(skipped.count, 1)
        XCTAssertEqual(skipped[0].data["loop_id"], .string("lp"))
        XCTAssertEqual(skipped[0].data["batch_index"], .int(1))
        XCTAssertEqual(skipped[0].data["error"],
                       .string("模型调用失败：OllamaAPIError: 对话请求失败（HTTP 500）"))
        XCTAssertEqual(skipped[0].data["run_id"], .string(runId))
        // G2c：失败批占位 None（str 形态）
        let run = try XCTUnwrap(try store.getWorkflowRun(runId))
        XCTAssertEqual(run.result, "['处理 a', None, '处理 c']")
    }

    func testLoopMaxFailures() async throws {
        conn.responders["m"] = { _ in
            throw WorkflowConnectorError.api(status: 500, prefix: "对话请求失败")
        }
        let def = loopDef(items: .array([.string("a"), .string("b"), .string("c")]),
                          branch: .string("n2"),
                          extra: ["fail_policy": .string("continue"),   // 别名归一为 skip
                                  "max_failures": .int(1)])
        let (engine, _) = try makeEngine(def)
        let evs = await runCollect(engine)
        XCTAssertEqual(evs.last?.event, "workflow_failed")
        // 达上限即中止：只跑了第 1 批
        XCTAssertEqual(conn.calls.count, 1)
        XCTAssertEqual(evs.last?.data["error"],
                       .string("失败批数达到上限（1/1）：第 1 批：模型调用失败："
                               + "OllamaAPIError: 对话请求失败（HTTP 500）"))
    }

    // ════════════════════════════════════════════════════════════
    // MARK: - 审批（L6/L7；契约点 5 引擎侧）
    // ════════════════════════════════════════════════════════════

    private func approvalDef() -> JSONValue {
        jdef([
            jnode("s", "start"),
            jnode("ap", "approval", ["message": .string("请确认 {{params.plan}}")]),
            jnode("e", "end", ["output": .string("{{ap.output}}")]),
        ], [jedge("s", "ap"), jedge("ap", "e")])
    }

    func testApprovalApproveResumes() async throws {
        let (engine, runId) = try makeEngine(approvalDef(), params: ["plan": .string("方案A")])
        var evs: [WorkflowEngineEvent] = []
        var resolved = false
        let stream = await engine.run()
        for await ev in stream {
            evs.append(ev)
            if ev.event == "approval_required", !resolved {
                resolved = true
                // L6a：挂起事件载荷（label 缺省「人工审批」；message 模板渲染）
                XCTAssertEqual(ev.data["node_id"], .string("ap"))
                XCTAssertEqual(ev.data["label"], .string("人工审批"))
                XCTAssertEqual(ev.data["message"], .string("请确认 方案A"))
                XCTAssertEqual(ev.data["run_id"], .string(runId))
                // 挂起落库 awaiting_approval + current_node
                let run = try XCTUnwrap(try store.getWorkflowRun(runId))
                XCTAssertEqual(run.status, "awaiting_approval")
                XCTAssertEqual(run.currentNode, "ap")
                // 批准
                XCTAssertTrue(runtime.resolveApproval(runId, approved: true, comment: "同意"))
            }
        }
        // L6b：批准后完成；审批节点输出 = comment
        XCTAssertEqual(evs.last?.event, "workflow_done")
        XCTAssertEqual(evs.last?.data["result_preview"], .string("同意"))
        // 审批结束后注册表已弹出（再决议 → false）
        XCTAssertFalse(runtime.resolveApproval(runId, approved: true, comment: ""))
        let run = try XCTUnwrap(try store.getWorkflowRun(runId))
        XCTAssertEqual(run.status, "done")
    }

    func testApprovalApprovedEmptyComment() async throws {
        let (engine, runId) = try makeEngine(approvalDef())
        let stream = await engine.run()
        for await ev in stream where ev.event == "approval_required" {
            XCTAssertTrue(runtime.resolveApproval(runId, approved: true, comment: ""))
        }
        // comment 空 → 输出 "approved"（Python `entry.get("comment") or "approved"`）
        let run = try XCTUnwrap(try store.getWorkflowRun(runId))
        XCTAssertEqual(run.result, "approved")
    }

    func testApprovalRejectFails() async throws {
        let (engine, runId) = try makeEngine(approvalDef())
        var evs: [WorkflowEngineEvent] = []
        let stream = await engine.run()
        for await ev in stream {
            evs.append(ev)
            if ev.event == "approval_required" {
                XCTAssertTrue(runtime.resolveApproval(runId, approved: false, comment: "不行"))
            }
        }
        // L7：驳回 → workflow_failed，文案带 comment
        XCTAssertEqual(evs.last?.event, "workflow_failed")
        XCTAssertEqual(evs.last?.data["error"], .string("审批被驳回：不行"))
        let run = try XCTUnwrap(try store.getWorkflowRun(runId))
        XCTAssertEqual(run.status, "failed")
    }

    func testApprovalRejectEmptyComment() async throws {
        let (engine, runId) = try makeEngine(approvalDef())
        let stream = await engine.run()
        var lastError: String?
        for await ev in stream {
            if ev.event == "approval_required" {
                XCTAssertTrue(runtime.resolveApproval(runId, approved: false, comment: ""))
            }
            if ev.event == "workflow_failed" { lastError = ev.data["error"]?.string }
        }
        // comment 空 → 「用户驳回」
        XCTAssertEqual(lastError, "审批被驳回：用户驳回")
    }

    // ════════════════════════════════════════════════════════════
    // MARK: - 停止（L10 + C5；契约点 3 引擎侧）
    // ════════════════════════════════════════════════════════════

    func testStopDuringInference() async throws {
        let def = jdef([
            jnode("s", "start"),
            jnode("n1", "inference", ["model": .string("m1")]),
            jnode("e", "end"),
        ], [jedge("s", "n1"), jedge("n1", "e")])
        let (engine, runId) = try makeEngine(def)
        // 确定性同步（对齐 checkpoint077 L10「模型驻留后取消」口径）：
        // 在 responder 内取消——chat 已发出 ⇒ ensureModel 已驻留 m1 ⇒ 停止路径必卸载。
        // （原先在 node_start 事件点取消：与生产者 ensureModel 竞速，偶发无驻留可卸）
        conn.responders["m1"] = { [runtime] _ in
            runtime!.requestCancel(runId)   // 推理在飞 → 点停止
            try await Task.sleep(nanoseconds: 10_000_000_000)   // 慢调用，等停止
            return "晚到"
        }
        var evs: [WorkflowEngineEvent] = []
        let stream = await engine.run()
        for await ev in stream {
            evs.append(ev)
        }
        // L10：走 stopped 而非 failed/done
        XCTAssertEqual(evs.map(\.event).last, "workflow_stopped")
        XCTAssertEqual(evs.last?.data["run_id"], .string(runId))
        let run = try XCTUnwrap(try store.getWorkflowRun(runId))
        XCTAssertEqual(run.status, "stopped")
        XCTAssertEqual(run.error, "用户已停止")
        // 停止路径卸载驻留模型
        XCTAssertEqual(conn.unloads, ["m1"])
        // clearCancel 后可复用同 runId（clear_workflow_cancel 语义）
        runtime.clearCancel(runId)
        XCTAssertFalse(runtime.isCancelled(runId))
    }

    /// 停止卡在审批的 run：取消标志 + 驳回解锁（app.py L2362-2364 双动作）。
    func testStopDuringApproval() async throws {
        let (engine, runId) = try makeEngine(approvalDef())
        var evs: [WorkflowEngineEvent] = []
        let stream = await engine.run()
        for await ev in stream {
            evs.append(ev)
            if ev.event == "approval_required" {
                runtime.requestCancel(runId)
                XCTAssertTrue(runtime.resolveApproval(runId, approved: false,
                                                      comment: "用户已停止"))
            }
        }
        // 取消优先于驳回（Python：pop 后 _check_cancel 先抛 WorkflowCancel）
        XCTAssertEqual(evs.map(\.event).last, "workflow_stopped")
        let run = try XCTUnwrap(try store.getWorkflowRun(runId))
        XCTAssertEqual(run.status, "stopped")
        XCTAssertEqual(run.error, "用户已停止")
    }

    // ════════════════════════════════════════════════════════════
    // MARK: - 重试（L9：退避重试 + retry_count 落库）
    // ════════════════════════════════════════════════════════════

    func testRetrySucceedsAfterFailure() async throws {
        let def = jdef([
            jnode("s", "start"),
            jnode("n1", "inference", ["model": .string("flaky"), "retry": .int(1)]),
            jnode("e", "end", ["output": .string("{{n1.output}}")]),
        ], [jedge("s", "n1"), jedge("n1", "e")])
        let (engine, runId) = try makeEngine(def)
        // 首次失败、第二次成功
        conn.responders["flaky"] = { [conn] _ in
            if conn!.calls.count == 1 {
                throw WorkflowConnectorError.api(status: 500, prefix: "对话请求失败")
            }
            return "成功"
        }
        let evs = await runCollect(engine)
        XCTAssertEqual(evs.last?.event, "workflow_done")
        XCTAssertEqual(evs.last?.data["result_preview"], .string("成功"))
        XCTAssertEqual(conn.calls.count, 2)   // 1 + 1 次重试
        // retry_count 落库
        let done = try store.listWorkflowNodeEvents(runId)
            .first { $0.nodeId == "n1" && $0.status == "done" }
        XCTAssertEqual(done?.retryCount, 1)
    }

    // ════════════════════════════════════════════════════════════
    // MARK: - REQ-WF-015：节点级超时（契约点 6）
    // ════════════════════════════════════════════════════════════

    /// _node_timeout_s 钳制表（engine.py L389-406 逐行）。
    func testNodeTimeoutSClamp() {
        func node(_ ts: JSONValue?) -> [String: JSONValue] {
            var n: [String: JSONValue] = ["id": .string("n")]
            if let ts { n["timeout_s"] = ts }
            return n
        }
        XCTAssertNil(NativeWorkflowEngine.nodeTimeoutS(node(nil)))          // 未配
        XCTAssertNil(NativeWorkflowEngine.nodeTimeoutS(node(.null)))        // null
        XCTAssertNil(NativeWorkflowEngine.nodeTimeoutS(node(.bool(true))))  // bool 拒绝
        XCTAssertNil(NativeWorkflowEngine.nodeTimeoutS(node(.string("abc"))))
        XCTAssertNil(NativeWorkflowEngine.nodeTimeoutS(node(.double(.infinity))))
        XCTAssertNil(NativeWorkflowEngine.nodeTimeoutS(node(.double(.nan))))
        XCTAssertNil(NativeWorkflowEngine.nodeTimeoutS(node(.array([]))))
        XCTAssertEqual(NativeWorkflowEngine.nodeTimeoutS(node(.int(1200))), 1200)
        XCTAssertEqual(NativeWorkflowEngine.nodeTimeoutS(node(.double(600.5))), 600.5)
        XCTAssertEqual(NativeWorkflowEngine.nodeTimeoutS(node(.string("1200"))), 1200)  // float(raw) 宽松
        XCTAssertEqual(NativeWorkflowEngine.nodeTimeoutS(node(.int(5))), 10)     // clamp 下界
        XCTAssertEqual(NativeWorkflowEngine.nodeTimeoutS(node(.int(99999))), 7200)  // clamp 上界
    }

    /// 节点 timeout_s 透传 connector（read_timeout_s kwarg 语义）。
    func testNodeTimeoutPassedToConnector() async throws {
        let def = jdef([
            jnode("s", "start"),
            jnode("n1", "inference", ["model": .string("m1"), "timeout_s": .int(1200)]),
            jnode("n2", "inference", ["model": .string("m1")]),   // 未配 → 全局默认（不传）
            jnode("e", "end"),
        ], [jedge("s", "n1"), jedge("n1", "n2"), jedge("n2", "e")])
        let (engine, _) = try makeEngine(def)
        _ = await runCollect(engine)
        XCTAssertEqual(conn.calls.count, 2)
        XCTAssertEqual(conn.calls[0].readTimeoutS, 1200)
        XCTAssertNil(conn.calls[1].readTimeoutS)
    }

    /// 超时错误文案写**实际生效**秒数（0.4.28：节点值优先于全局值）。
    func testInferenceTimeoutErrorText() async throws {
        conn.responders["m1"] = { _ in throw WorkflowConnectorError.timeout }
        // 节点配 1200 → 文案写 1200
        var def = jdef([
            jnode("s", "start"),
            jnode("n1", "inference", ["model": .string("m1"), "timeout_s": .int(1200)]),
            jnode("e", "end"),
        ], [jedge("s", "n1"), jedge("n1", "e")])
        var (engine, runId) = try makeEngine(def, globalTimeout: 900)
        var evs = await runCollect(engine)
        XCTAssertEqual(evs.last?.event, "workflow_failed")
        var expect = "模型调用失败：模型调用超时：TimeoutError。已等待 1200s 仍未返回"
            + "（非流式调用的 reading 超时上限）。常见原因：本地大参数模型（如 35B）"
            + "处理超长文本推理耗时超过该上限。可尝试：① 减小单批输入（循环节点分批更小）"
            + "② 换更小的模型 ③ 给本节点配置更大的 timeout_s（秒，10~7200），"
            + "或在 设置→推理 调大「非流式读超时」。模型：m1"
        XCTAssertEqual(evs.last?.data["error"], .string(expect))
        XCTAssertEqual(try XCTUnwrap(try store.getWorkflowRun(runId)).error, expect)
        // 未配节点值 → 用全局动态值（900，而非硬编码 300）
        def = jdef([
            jnode("s", "start"),
            jnode("n1", "inference", ["model": .string("m1")]),
            jnode("e", "end"),
        ], [jedge("s", "n1"), jedge("n1", "e")])
        (engine, _) = try makeEngine(def, globalTimeout: 900)
        evs = await runCollect(engine)
        expect = expect.replacingOccurrences(of: "已等待 1200s", with: "已等待 900s")
        XCTAssertEqual(evs.last?.data["error"], .string(expect))
    }

    /// 动态裁判超时同样写实际生效秒数（裁判版文案 + 按 false 继续措辞）。
    func testRefereeTimeoutErrorText() async throws {
        conn.responders["judge"] = { _ in throw WorkflowConnectorError.timeout }
        let def = jdef([
            jnode("s", "start"),
            jnode("c", "condition", ["model": .string("judge"), "timeout_s": .double(600.5)]),
            jnode("e", "end"),
        ], [jedge("s", "c"), jedge("c", "e")])
        let (engine, _) = try makeEngine(def)
        let evs = await runCollect(engine)
        XCTAssertEqual(evs.last?.event, "workflow_failed")
        let expect = "裁判模型调用失败：裁判模型调用超时：TimeoutError。已等待 600s 仍未返回"
            + "（条件分支的动态裁判无法判定，已按 false 分支继续）。模型：judge"
        XCTAssertEqual(evs.last?.data["error"], .string(expect))
    }

    // ════════════════════════════════════════════════════════════
    // MARK: - 模板与变量（L11）
    // ════════════════════════════════════════════════════════════

    func testRenderTemplateAndResolveValue() {
        let vars: [String: JSONValue] = [
            "params": .object(["dir": .string("/tmp")]),
            "n1": .object(["output": .string("hello")]),
            "lst": .array([.int(1), .int(2), .int(3)]),
        ]
        // L11a-d
        XCTAssertEqual(NativeWorkflowEngine.renderTemplate("目录 {{params.dir}}", vars),
                       "目录 /tmp")
        XCTAssertEqual(NativeWorkflowEngine.renderTemplate("{{n1.output}}!", vars), "hello!")
        // 列表 → 紧凑 JSON（json.dumps ensure_ascii=False）
        XCTAssertEqual(NativeWorkflowEngine.renderTemplate("{{lst}}", vars), "[1, 2, 3]")
        // 未定义占位符原样保留
        XCTAssertEqual(NativeWorkflowEngine.renderTemplate("{{nope.x}}", vars), "{{nope.x}}")
        XCTAssertEqual(NativeWorkflowEngine.renderTemplate("", vars), "")
        // L11e：resolve_value 整串引用保持类型（容忍首尾空白）
        XCTAssertEqual(NativeWorkflowEngine.resolveValue(.string("{{lst}}"), vars),
                       .array([.int(1), .int(2), .int(3)]))
        XCTAssertEqual(NativeWorkflowEngine.resolveValue(.string("  {{ lst }}  "), vars),
                       .array([.int(1), .int(2), .int(3)]))
        // 缺失 → .null（Python 返回 None）
        XCTAssertEqual(NativeWorkflowEngine.resolveValue(.string("{{missing}}"), vars), .null)
        // 混合模板 → 字符串
        XCTAssertEqual(NativeWorkflowEngine.resolveValue(.string("a {{lst}}"), vars),
                       .string("a [1, 2, 3]"))
        // 非字符串原样
        XCTAssertEqual(NativeWorkflowEngine.resolveValue(.int(5), vars), .int(5))
    }

    /// resolve_images：变量引用 / 列表 / 单串三形态（engine.py L204-214）。
    func testResolveImages() {
        let vars: [String: JSONValue] = [
            "fi": .object(["output": .array([.string("a.jpg"), .string(""), .string("b.jpg")])]),
        ]
        // 未配置 → []
        XCTAssertEqual(NativeWorkflowEngine.resolveImages(["id": .string("n")], vars), [])
        // 整串变量引用 → 列表（假值元素过滤）
        XCTAssertEqual(NativeWorkflowEngine.resolveImages(
            ["id": .string("n"), "images": .string("{{fi.output}}")], vars), ["a.jpg", "b.jpg"])
        // 单串非模板 → [串]
        XCTAssertEqual(NativeWorkflowEngine.resolveImages(
            ["id": .string("n"), "images": .string("one.jpg")], vars), ["one.jpg"])
        // 列表原样 → 字符串化
        XCTAssertEqual(NativeWorkflowEngine.resolveImages(
            ["id": .string("n"), "images": .array([.string("x.jpg"), .int(0)])], vars), ["x.jpg"])
    }

    // ════════════════════════════════════════════════════════════
    // MARK: - 图片继承与剔除（F8 自动继承 / G5 仅图片保护）
    // ════════════════════════════════════════════════════════════

    func testImagesDroppedEvent() async throws {
        let jpg = try writeFile("imgs/a.jpg", "fake-jpg")
        let mp3 = try writeFile("imgs/b.mp3", "fake-mp3")
        let dataURI = "data:image/png;base64,QUJD"
        let def = jdef([
            jnode("s", "start"),
            jnode("n1", "inference", ["model": .string("m1"),
                                      "images": .array([.string(jpg), .string(mp3),
                                                        .string(dataURI)])]),
            jnode("e", "end"),
        ], [jedge("s", "n1"), jedge("n1", "e")])
        let (engine, runId) = try makeEngine(def)
        let evs = await runCollect(engine)
        XCTAssertEqual(evs.last?.event, "workflow_done")
        // G5a：音频被剔除，chat 只收到图片（保序）
        XCTAssertEqual(conn.calls.first?.images, [jpg, dataURI])
        // G5b：剔除发事件提示（不静默），带 run_id
        let dropped = try XCTUnwrap(evs.first { $0.event == "images_dropped" })
        XCTAssertEqual(dropped.data["node_id"], .string("n1"))
        XCTAssertEqual(dropped.data["dropped"], .array([.string(mp3)]))
        XCTAssertEqual(dropped.data["reason"],
                       .string("非图片文件（如音频）不能作为图片输入，已剔除"))
        XCTAssertEqual(dropped.data["run_id"], .string(runId))
    }

    func testAutoInheritUpstreamImages() async throws {
        let jpg = try writeFile("pool/a.jpg", "fake-jpg")
        _ = try writeFile("pool/b.txt", "文本")
        let def = jdef([
            jnode("s", "start"),
            jnode("fi", "file_input", ["path": .string(tmp.appendingPathComponent("pool").path)]),
            jnode("n1", "inference", ["model": .string("m1")]),   // 未配置 images
            jnode("e", "end"),
        ], [jedge("s", "fi"), jedge("fi", "n1"), jedge("n1", "e")])
        let (engine, _) = try makeEngine(def)
        let evs = await runCollect(engine)
        XCTAssertEqual(evs.last?.event, "workflow_done")
        // F8b/F8c：自动继承上游 file_input 的真实图片路径（非图片被过滤）
        XCTAssertEqual(conn.calls.first?.images, [jpg])
    }

    // ════════════════════════════════════════════════════════════
    // MARK: - 文件节点（F1-F6 / F11）
    // ════════════════════════════════════════════════════════════

    func testFileInputVariants() async throws {
        // F1：单文件
        let single = try writeFile("in/one.txt", "x")
        var def = jdef([
            jnode("s", "start"),
            jnode("fi", "file_input", ["path": .string(single)]),
            jnode("e", "end", ["output": .string("{{fi.output}}")]),
        ], [jedge("s", "fi"), jedge("fi", "e")])
        var (engine, runId) = try makeEngine(def)
        _ = await runCollect(engine)
        XCTAssertEqual(try XCTUnwrap(try store.getWorkflowRun(runId)).result, "['\(single)']")

        // F2：目录 + 扩展名过滤（排序确定性）
        let dir = tmp.appendingPathComponent("in2").path
        _ = try writeFile("in2/a.jpg", "x")
        _ = try writeFile("in2/b.png", "x")
        _ = try writeFile("in2/c.txt", "x")
        def = jdef([
            jnode("s", "start"),
            jnode("fi", "file_input", ["path": .string(dir),
                                       "extensions": .string("jpg, png")]),
            jnode("e", "end", ["output": .string("{{fi.output}}")]),
        ], [jedge("s", "fi"), jedge("fi", "e")])
        (engine, runId) = try makeEngine(def)
        _ = await runCollect(engine)
        let result = try XCTUnwrap(try store.getWorkflowRun(runId)).result
        XCTAssertEqual(result, "['\(dir)/a.jpg', '\(dir)/b.png']")

        // F3：递归子目录
        _ = try writeFile("in3/sub/deep.jpg", "x")
        _ = try writeFile("in3/top.jpg", "x")
        func recursiveRun(_ recursive: Bool) async throws -> String? {
            let d = jdef([
                jnode("s", "start"),
                jnode("fi", "file_input", ["path": .string(tmp.appendingPathComponent("in3").path),
                                           "extensions": .string("jpg"),
                                           "recursive": .bool(recursive)]),
                jnode("e", "end", ["output": .string("{{fi.output}}")]),
            ], [jedge("s", "fi"), jedge("fi", "e")])
            let (eng, rid) = try makeEngine(d)
            _ = await runCollect(eng)
            return try store.getWorkflowRun(rid)?.result
        }
        let flat = try await recursiveRun(false)
        XCTAssertEqual(flat, "['\(tmp.appendingPathComponent("in3/top.jpg").path)']")
        let deep = try await recursiveRun(true)
        XCTAssertEqual(deep, "['\(tmp.appendingPathComponent("in3/sub/deep.jpg").path)', "
                       + "'\(tmp.appendingPathComponent("in3/top.jpg").path)']")

        // F4：路径不存在
        def = jdef([
            jnode("s", "start"),
            jnode("fi", "file_input", ["path": .string(tmp.appendingPathComponent("nope").path)]),
            jnode("e", "end"),
        ], [jedge("s", "fi"), jedge("fi", "e")])
        (engine, runId) = try makeEngine(def)
        let evs = await runCollect(engine)
        XCTAssertEqual(evs.last?.event, "workflow_failed")
        XCTAssertEqual(evs.last?.data["error"],
                       .string("路径不存在：\(tmp.appendingPathComponent("nope").path)"))

        // 空匹配：extensions 清单入文案（sorted list repr）
        def = jdef([
            jnode("s", "start"),
            jnode("fi", "file_input", ["path": .string(dir),
                                       "extensions": .string("gif")]),
            jnode("e", "end"),
        ], [jedge("s", "fi"), jedge("fi", "e")])
        (engine, _) = try makeEngine(def)
        let evs2 = await runCollect(engine)
        XCTAssertEqual(evs2.last?.data["error"],
                       .string("文件夹内没有匹配的文件：\(dir)（extensions=['gif']）"))
    }

    func testFileOutputWritesAndTraversalGuard() async throws {
        // F5a/F5b：写入 + 内容模板渲染
        let outDir = tmp.appendingPathComponent("out").path
        var def = jdef([
            jnode("s", "start"),
            jnode("t1", "text_output", ["template": .string("识别出的文字")]),
            jnode("fo", "file_output", ["dir": .string(outDir),
                                        "filename": .string("result.txt"),
                                        "content": .string("内容：{{t1.output}}")]),
            jnode("e", "end", ["output": .string("{{fo.output}}")]),
        ], [jedge("s", "t1"), jedge("t1", "fo"), jedge("fo", "e")])
        var (engine, runId) = try makeEngine(def)
        _ = await runCollect(engine)
        let target = tmp.appendingPathComponent("out/result.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "内容：识别出的文字")
        // 节点输出 = 写入的绝对路径
        XCTAssertEqual(try XCTUnwrap(try store.getWorkflowRun(runId)).result, target.path)

        // F6：路径穿越拒绝（../ 与分隔符两种形态）
        for bad in ["../evil.txt", "sub/x.txt"] {
            def = jdef([
                jnode("s", "start"),
                jnode("fo", "file_output", ["dir": .string(outDir),
                                            "filename": .string(bad),
                                            "content": .string("x")]),
                jnode("e", "end"),
            ], [jedge("s", "fo"), jedge("fo", "e")])
            (engine, _) = try makeEngine(def)
            let evs = await runCollect(engine)
            XCTAssertEqual(evs.last?.event, "workflow_failed")
            XCTAssertEqual(evs.last?.data["error"],
                           .string("filename 不合法（不允许路径分隔符/..）：'\(bad)'"))
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: tmp.appendingPathComponent("evil.txt").path))
        }

        // 缺 dir/filename
        def = jdef([
            jnode("s", "start"),
            jnode("fo", "file_output", ["content": .string("x")]),
            jnode("e", "end"),
        ], [jedge("s", "fo"), jedge("fo", "e")])
        (engine, _) = try makeEngine(def)
        let evs = await runCollect(engine)
        XCTAssertEqual(evs.last?.data["error"], .string("文件输出节点需配置 dir 与 filename"))
    }

    func testFileReadConcatAndTruncation() async throws {
        // F11：目录读取 + 文件名标题 + 扩展名过滤
        let dir = tmp.appendingPathComponent("docs").path
        _ = try writeFile("docs/1.md", "第一段内容")
        _ = try writeFile("docs/2.md", "第二段")
        _ = try writeFile("docs/ignore.txt", "不该被读到")
        var def = jdef([
            jnode("s", "start"),
            jnode("fr", "file_read", ["path": .string(dir), "extensions": .string("md")]),
            jnode("e", "end", ["output": .string("{{fr.output}}")]),
        ], [jedge("s", "fr"), jedge("fr", "e")])
        var (engine, runId) = try makeEngine(def)
        _ = await runCollect(engine)
        XCTAssertEqual(try XCTUnwrap(try store.getWorkflowRun(runId)).result,
                       "=== 1.md ===\n第一段内容\n\n=== 2.md ===\n第二段")

        // 自定义 separator（{{filename}} 模板）
        def = jdef([
            jnode("s", "start"),
            jnode("fr", "file_read", ["path": .string(dir), "extensions": .string("md"),
                                      "separator": .string("--- {{filename}} ---")]),
            jnode("e", "end", ["output": .string("{{fr.output}}")]),
        ], [jedge("s", "fr"), jedge("fr", "e")])
        (engine, runId) = try makeEngine(def)
        _ = await runCollect(engine)
        XCTAssertEqual(try XCTUnwrap(try store.getWorkflowRun(runId)).result,
                       "--- 1.md ---\n第一段内容\n\n--- 2.md ---\n第二段")

        // max_bytes 截断标注（源字节数 + 输出上限）
        let big = try writeFile("docs/big.txt",
                                String(repeating: "0123456789", count: 10))   // 100 字节
        def = jdef([
            jnode("s", "start"),
            jnode("fr", "file_read", ["path": .string(big), "max_bytes": .int(10)]),
            jnode("e", "end", ["output": .string("{{fr.output}}")]),
        ], [jedge("s", "fr"), jedge("fr", "e")])
        (engine, runId) = try makeEngine(def)
        _ = await runCollect(engine)
        XCTAssertEqual(try XCTUnwrap(try store.getWorkflowRun(runId)).result,
                       "=== big.txt ===\n0123456789\n（已截断：源文件 100 字节，输出上限 10 字）")

        // 路径不存在
        def = jdef([
            jnode("s", "start"),
            jnode("fr", "file_read", ["path": .string(tmp.appendingPathComponent("nope").path)]),
            jnode("e", "end"),
        ], [jedge("s", "fr"), jedge("fr", "e")])
        (engine, _) = try makeEngine(def)
        let evs = await runCollect(engine)
        XCTAssertEqual(evs.last?.data["error"],
                       .string("路径不存在：\(tmp.appendingPathComponent("nope").path)"))
    }

    // ════════════════════════════════════════════════════════════
    // MARK: - TS-121 四节点（H1/H2/H4/H7b）
    // ════════════════════════════════════════════════════════════

    func testVariableSetTextOutputReply() async throws {
        let def = jdef([
            jnode("s", "start"),
            jnode("v1", "variable_set", ["name": .string("total"), "value": .int(42)]),
            jnode("t1", "text_output", ["template": .string("总数={{total}}")]),
            jnode("r1", "reply", ["text": .string("回复：{{t1.output}}")]),
            jnode("e", "end", ["output": .string("{{t1.output}}")]),
        ], [jedge("s", "v1"), jedge("v1", "t1"), jedge("t1", "r1"), jedge("r1", "e")])
        let (engine, runId) = try makeEngine(def)
        let evs = await runCollect(engine)
        // H2：变量赋值 → 下游引用（整串 {{x}} 保类型：42 渲染为 "42"）
        XCTAssertEqual(evs.last?.data["result_preview"], .string("总数=42"))
        // H4：workflow_reply 事件含渲染文本（带 run_id）
        let reply = try XCTUnwrap(evs.first { $0.event == "workflow_reply" })
        XCTAssertEqual(reply.data["node_id"], .string("r1"))
        XCTAssertEqual(reply.data["text"], .string("回复：总数=42"))
        XCTAssertEqual(reply.data["run_id"], .string(runId))
        // variable_set 直写变量空间（不包 output 壳 → 快照保原类型）
        let run = try XCTUnwrap(try store.getWorkflowRun(runId))
        XCTAssertEqual(run.variables.object?["total"], .int(42))
        // 节点输出空间走 str() 快照（Python L1103）
        XCTAssertEqual(run.variables.object?["v1"]?.object?["output"], .string("42"))
    }

    func testVariableSetReservedAndIllegalNames() async throws {
        // H7b：保留名运行时拦截（sorted 清单逐字）
        var def = jdef([
            jnode("s", "start"),
            jnode("v1", "variable_set", ["name": .string("item"), "value": .int(1)]),
            jnode("e", "end"),
        ], [jedge("s", "v1"), jedge("v1", "e")])
        var (engine, _) = try makeEngine(def)
        var evs = await runCollect(engine)
        XCTAssertEqual(evs.last?.data["error"],
                       .string("变量名 'item' 是保留名（batch, item, item_index, params），请换一个"))
        // 含 . 非法
        def = jdef([
            jnode("s", "start"),
            jnode("v1", "variable_set", ["name": .string("a.b"), "value": .int(1)]),
            jnode("e", "end"),
        ], [jedge("s", "v1"), jedge("v1", "e")])
        (engine, _) = try makeEngine(def)
        evs = await runCollect(engine)
        XCTAssertEqual(evs.last?.data["error"], .string("变量名非法：'a.b'（不能为空或含 . /）"))
    }

    func testTextOutputMissingTemplate() async throws {
        let def = jdef([
            jnode("s", "start"), jnode("t1", "text_output"), jnode("e", "end"),
        ], [jedge("s", "t1"), jedge("t1", "e")])
        let (engine, _) = try makeEngine(def)
        let evs = await runCollect(engine)
        XCTAssertEqual(evs.last?.data["error"], .string("文本输出节点缺少 template"))
    }

    // ════════════════════════════════════════════════════════════
    // MARK: - code 节点（H3/H6：python3 子进程，纯本地）
    // ════════════════════════════════════════════════════════════

    func testCodeNodeResult() async throws {
        let def = jdef([
            jnode("s", "start"),
            jnode("c1", "code", ["code": .string("result = sum([1, 2, 3])")]),
            jnode("t1", "text_output", ["template": .string("和={{c1.output}}")]),
            jnode("e", "end", ["output": .string("{{t1.output}}")]),
        ], [jedge("s", "c1"), jedge("c1", "t1"), jedge("t1", "e")])
        let (engine, _) = try makeEngine(def)
        let evs = await runCollect(engine)
        // H3a：代码经 variables/result 约定产出
        XCTAssertEqual(evs.last?.event, "workflow_done")
        XCTAssertEqual(evs.last?.data["result_preview"], .string("和=6"))
    }

    func testCodeNodeReadsVariables() async throws {
        let def = jdef([
            jnode("s", "start"),
            jnode("t1", "text_output", ["template": .string("上游文本")]),
            jnode("c1", "code", ["code": .string(
                "result = variables['t1']['output'] + '（已加工）'")]),
            jnode("e", "end", ["output": .string("{{c1.output}}")]),
        ], [jedge("s", "t1"), jedge("t1", "c1"), jedge("c1", "e")])
        let (engine, _) = try makeEngine(def)
        let evs = await runCollect(engine)
        XCTAssertEqual(evs.last?.data["result_preview"], .string("上游文本（已加工）"))
    }

    func testCodeNodeException() async throws {
        let def = jdef([
            jnode("s", "start"),
            jnode("c1", "code", ["code": .string("result = 1 / 0")]),
            jnode("e", "end"),
        ], [jedge("s", "c1"), jedge("c1", "e")])
        let (engine, _) = try makeEngine(def)
        let evs = await runCollect(engine)
        // H3b：异常 → 节点错误（stderr 末行 = Python 异常行）
        XCTAssertEqual(evs.last?.event, "workflow_failed")
        let err = evs.last?.data["error"]?.string ?? ""
        XCTAssertTrue(err.hasPrefix("代码执行异常："), err)
        XCTAssertTrue(err.contains("ZeroDivisionError"), err)
    }

    func testCodeNodeTimeout() async throws {
        let def = jdef([
            jnode("s", "start"),
            jnode("c1", "code", ["code": .string("while True: pass"),
                                 "timeout_s": .int(1)]),
            jnode("e", "end"),
        ], [jedge("s", "c1"), jedge("c1", "e")])
        let (engine, _) = try makeEngine(def)
        let t0 = Date()
        let evs = await runCollect(engine)
        let elapsed = Date().timeIntervalSince(t0)
        // H6a/H6b：超时判失败且在约 1s 级返回（子进程被真杀，不卡死）
        XCTAssertEqual(evs.last?.event, "workflow_failed")
        XCTAssertEqual(evs.last?.data["error"],
                       .string("代码执行超时（1s）：可能存在死循环。"
                               + "工作流已继续，但失控线程会占用 CPU 直到其自行结束"))
        XCTAssertLessThan(elapsed, 10)
    }

    // ════════════════════════════════════════════════════════════
    // MARK: - tool 节点（P2-W3 注入口）
    // ════════════════════════════════════════════════════════════

    func testToolNodeWithoutExecutor() async throws {
        let def = jdef([
            jnode("s", "start"),
            jnode("t", "tool", ["tool": .string("write_file")]),
            jnode("e", "end"),
        ], [jedge("s", "t"), jedge("t", "e")])
        let (engine, _) = try makeEngine(def)
        let evs = await runCollect(engine)
        // 未注入执行器 → 如实失败（不静默吞）
        XCTAssertEqual(evs.last?.event, "workflow_failed")
        XCTAssertEqual(evs.last?.data["error"],
                       .string("工具执行异常：RuntimeError: 工具注册表尚未原生接管"
                               + "（P2-W3 排期；原生内核期工作流暂不支持 tool 节点）"))
    }

    func testToolNodeWithExecutor() async throws {
        let exec = FakeToolExecutor()
        exec.result = ["ok": .bool(true), "written": .string("已写")]
        let def = jdef([
            jnode("s", "start"),
            jnode("t", "tool", ["tool": .string("write_file"),
                                "args": .object(["path": .string("{{params.p}}"),
                                                 "raw": .int(7)])]),
            jnode("e", "end", ["output": .string("{{t.output}}")]),
        ], [jedge("s", "t"), jedge("t", "e")])
        let (engine, runId) = try makeEngine(def, params: ["p": .string("/tmp/x.txt")],
                                             toolExecutor: exec)
        let evs = await runCollect(engine)
        XCTAssertEqual(evs.last?.event, "workflow_done")
        // args 逐值 resolve_value（模板解析 + 非字符串原样）
        XCTAssertEqual(exec.received.count, 1)
        XCTAssertEqual(exec.received[0].tool, "write_file")
        XCTAssertEqual(exec.received[0].args["path"], .string("/tmp/x.txt"))
        XCTAssertEqual(exec.received[0].args["raw"], .int(7))
        XCTAssertEqual(exec.received[0].sandbox, tmp.path)
        // 输出 = 整个结果字典（Python output=result；str(dict) repr 形态——单引号/True）
        let run = try XCTUnwrap(try store.getWorkflowRun(runId))
        XCTAssertEqual(run.result, "{'ok': True, 'written': '已写'}")

        // ok=false → error 字段直传
        exec.result = ["ok": .bool(false), "error": .string("磁盘满了")]
        let (engine2, _) = try makeEngine(def, params: ["p": .string("/tmp/x.txt")],
                                          toolExecutor: exec)
        let evs2 = await runCollect(engine2)
        XCTAssertEqual(evs2.last?.data["error"], .string("磁盘满了"))

        // 执行器抛异常 → 工具执行异常：类型名: 消息
        exec.thrown = WorkflowConnectorError.api(status: 500, prefix: "对话请求失败")
        let (engine3, _) = try makeEngine(def, params: ["p": .string("/tmp/x.txt")],
                                          toolExecutor: exec)
        let evs3 = await runCollect(engine3)
        XCTAssertEqual(evs3.last?.data["error"],
                       .string("工具执行异常：OllamaAPIError: 对话请求失败（HTTP 500）"))
    }

    // ════════════════════════════════════════════════════════════
    // MARK: - 兜底路径
    // ════════════════════════════════════════════════════════════

    func testUnknownNodeType() async throws {
        let def = jdef([
            jnode("s", "start"), jnode("x", "bogus"), jnode("e", "end"),
        ], [jedge("s", "x"), jedge("x", "e")])
        let (engine, _) = try makeEngine(def)
        let evs = await runCollect(engine)
        XCTAssertEqual(evs.last?.event, "workflow_failed")
        XCTAssertEqual(evs.last?.data["error"], .string("未知节点类型：bogus"))
    }

    /// 缺开始节点：workflow_failed 且**不落库**（Python 怪癖保留：run 停留 running）。
    func testMissingStartNode() async throws {
        let def = jdef([jnode("e", "end")], [])
        let (engine, runId) = try makeEngine(def)
        let evs = await runCollect(engine)
        XCTAssertEqual(evs.map(\.event), ["workflow_failed"])
        XCTAssertEqual(evs.last?.data["error"], .string("缺少开始节点"))
        XCTAssertEqual(evs.last?.data["run_id"], .string(runId))
        let run = try XCTUnwrap(try store.getWorkflowRun(runId))
        XCTAssertEqual(run.status, "running")   // 未被更新（strict 校验保证线上不可达）
    }

    /// _snapshot_vars：长输出截 2000 落库（L1097-1106）。
    func testSnapshotVarsTruncation() async throws {
        let long = String(repeating: "字", count: 3000)
        let def = jdef([
            jnode("s", "start"),
            jnode("t1", "text_output", ["template": .string(long)]),
            jnode("e", "end"),
        ], [jedge("s", "t1"), jedge("t1", "e")])
        let (engine, runId) = try makeEngine(def)
        let evs = await runCollect(engine)
        XCTAssertEqual(evs.last?.event, "workflow_done")
        // node_done 预览截 300
        let done = try XCTUnwrap(evs.first { $0.event == "node_done"
            && $0.data["node_id"] == .string("t1") })
        XCTAssertEqual(done.data["output_preview"]?.string?.count, 300)
        // 快照截 2000
        let run = try XCTUnwrap(try store.getWorkflowRun(runId))
        XCTAssertEqual(run.variables.object?["t1"]?.object?["output"]?.string?.count, 2000)
        // 节点事件 output_summary 截 2000
        let rec = try XCTUnwrap(try store.listWorkflowNodeEvents(runId)
            .first { $0.nodeId == "t1" && $0.status == "done" })
        XCTAssertEqual(rec.outputSummary.count, 2000)
    }

    /// _exc_text 直查（0.4.11：永远带类型名；超时走专项提示）。
    func testExcText() {
        XCTAssertEqual(NativeWorkflowEngine.excText(WorkflowConnectorError.timeout),
                       "超时：TimeoutError（已等待超过上限仍未返回）")
        XCTAssertEqual(NativeWorkflowEngine.excText(WorkflowConnectorError.timeout,
                                                    timeoutHint: "自定义"),
                       "自定义")
        XCTAssertEqual(NativeWorkflowEngine.excText(
            WorkflowConnectorError.api(status: 404, prefix: "对话请求失败")),
            "OllamaAPIError: 对话请求失败（HTTP 404）")
        XCTAssertEqual(NativeWorkflowEngine.excText(
            WorkflowConnectorError.network("连接被拒")),
            "ConnectError: 连接被拒")
    }

    /// 带环定义引擎不崩溃（G7：环边 body→loop 存在但不在主链上——
    /// loop 的首条出边指向 end，_pick_next 取第一条 → 正常终结）。
    /// ⛔ 不做执行级真环（t1→t1）：Python 引擎同样无 visited 集会无限循环，
    ///    且 Swift 同步节点路径不让出 actor——热循环属定义错误而非引擎缺陷。
    func testCycleDoesNotCrashEngine() async throws {
        let def = jdef([
            jnode("s", "start"),
            jnode("lp", "loop", ["items": .array([.string("a")]), "branch": .string("body")]),
            jnode("body", "inference", ["model": .string("m"), "prompt": .string("x")]),
            jnode("e", "end"),
        ], [jedge("s", "lp"), jedge("lp", "e"),
            jedge("body", "lp")])   // 回环边：构成图环但不影响主链
        let (engine, runId) = try makeEngine(def)
        let evs = await runCollect(engine)
        XCTAssertEqual(evs.last?.event, "workflow_done")
        XCTAssertEqual(conn.calls.count, 1)
        let run = try XCTUnwrap(try store.getWorkflowRun(runId))
        XCTAssertEqual(run.status, "done")
    }
}
