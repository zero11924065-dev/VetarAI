//
//  NativeDelegationEngineTests.swift
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

//  逐条翻译（⛔ 行为规格源 Python，语义以源码为准）：
//    · test_delegation.py §D 委派执行器：D6 追问后合法（6a-6d/9a-9c）/
//      D7 两次不合法 / D8 执行抛错不穿透 / D13c 取消路径 / D14 串行锁
//    · test_delegation2.py §2 queued 排队态（2a-2c）/ §4 委派集成
//      （4a 未命中+开关开+建议角色 / 4b 目标名兜底新建 / 4c 开关关转述用户）
//
//  隔离纪律：mktemp 数据根 + 假 connector（脚本化轮次），不打真网络/模型。
//  共享静态态（serialGate / 取消标志 / 上次模型 / 事件总线）各用例 setUp 复位；
//  本类用例依赖进程级串行锁，⛔ 不得并行化（swift test 默认串行）。
//
//  ⚠️VERIFY 未翻（原因）：无（本文件全量直译；REQ-AGT-020 总线层见 Route 套件标注）。
//

import XCTest
@testable import VetarAINative

/// test_delegation.RaisingConn 等价：首个 chunk 后抛错（模拟模型推理崩溃）。
private final class DelegRaisingConn: NativeChatConnector, @unchecked Sendable {
    struct Boom: Error, CustomStringConvertible { var description: String { "模型推理崩溃(模拟)" } }
    func chatStream(model: String, messages: [[String: JSONValue]],
                    tools: [JSONValue]?, images: [String]?)
        -> AsyncThrowingStream<NativeChatStreamEvent, Error> {
        AsyncThrowingStream { cont in
            cont.yield(.contentDelta("部分输出"))
            cont.finish(throwing: Boom())
        }
    }
    func chat(model: String, messages: [[String: JSONValue]]) async throws -> String { "" }
}

/// test_delegation.HangingConn 等价：首个 chunk 后挂起（模拟长时间推理）。
private final class DelegHangingConn: NativeChatConnector, @unchecked Sendable {
    func chatStream(model: String, messages: [[String: JSONValue]],
                    tools: [JSONValue]?, images: [String]?)
        -> AsyncThrowingStream<NativeChatStreamEvent, Error> {
        AsyncThrowingStream { cont in
            cont.yield(.contentDelta("部分"))
            // 永不 finish——挂起；取消由消费方终止迭代触发 onTermination 收口
        }
    }
    func chat(model: String, messages: [[String: JSONValue]]) async throws -> String { "" }
}

/// test_delegation.OrderConn 等价：记录进入/离开区间（验证串行锁），固定输出无效交卷。
private final class DelegOrderConn: NativeChatConnector, @unchecked Sendable {
    let name: String
    let order: LockedList<String>
    init(name: String, order: LockedList<String>) {
        self.name = name
        self.order = order
    }
    func chatStream(model: String, messages: [[String: JSONValue]],
                    tools: [JSONValue]?, images: [String]?)
        -> AsyncThrowingStream<NativeChatStreamEvent, Error> {
        order.append("\(name)_start")
        return AsyncThrowingStream { cont in
            cont.yield(.contentDelta("无效交卷"))
            // 30ms 推理窗口：无锁时两段区间必然交叠，有锁时不可能
            Task {
                try? await Task.sleep(nanoseconds: 30_000_000)
                cont.yield(.done(promptEvalCount: 5, evalCount: 5))
                cont.finish()
                order.append("\(self.name)_end")
            }
        }
    }
    func chat(model: String, messages: [[String: JSONValue]]) async throws -> String { "" }
}

final class NativeDelegationEngineTests: XCTestCase {

    private var tmp: URL!
    private var db: NativeDatabase!
    private var sandbox: URL!
    private var pid: String!
    private var mainId: String!
    private var betaId: String!
    private var parentSid: String!
    private var beta: NativeDatabase.AgentConfigRow!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("p2w4b_engine_\(UUID().uuidString)")
        sandbox = tmp.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        db = NativeDatabase(projectsRoot: tmp.appendingPathComponent("projects"))
        pid = try db.createProject(name: "m31", workingDir: tmp.appendingPathComponent("wd").path)
        mainId = try db.addAgentConfig(projectId: pid, name: "Alpha", type: "main",
                                       modelName: "qwen3.8")
        betaId = try db.addAgentConfig(projectId: pid, name: "Beta", type: "sub",
                                       role: "写手", systemPrompt: "简洁", modelName: "qwen3.8")
        _ = try db.addAgentConfig(projectId: pid, name: "Gamma", type: "sub",
                                  modelName: "qwen3.8")
        parentSid = try db.createSession(projectId: pid, agentId: mainId, title: "主会话")
        beta = try db.getAgentConfig(projectId: pid, agentId: betaId)
        NativeDelegationEngine.resetSharedState()
        NativeDelegationEvents.clearAll()
    }

    override func tearDownWithError() throws {
        NativeDelegationEvents.clearAll()
        NativeDelegationEngine.resetSharedState()
        try? FileManager.default.removeItem(at: tmp)
        try super.tearDownWithError()
    }

    private func makeEngine(_ conn: any NativeChatConnector,
                            config: [String: JSONValue] = [:]) -> NativeDelegationEngine {
        NativeDelegationEngine(db: db, connector: conn, configProvider: { config })
    }

    private func req(_ task: String, _ expect: String) -> NativeDelegationTaskRequest {
        NativeDelegationTaskRequest(projectId: pid, parentAgentId: mainId,
                                    parentSessionId: parentSid, targetAgent: beta,
                                    task: task, expect: expect,
                                    sandboxRoot: sandbox.path, maxRounds: 5)
    }

    // ══ D6 首次不合法 → 追问 → 第二次合法（用例 6+9）══

    func testD6_retryThenValidReport() async throws {
        try db.saveMessage(projectId: pid, sessionId: parentSid, agentId: mainId,
                           role: "user", content: "MAIN_CONV_MARKER 主对话私密内容")
        let conn = DelegScriptConn([
            .text("我做完了，但没有按格式交卷。"),
            .dynamic(delegGoodReport()),
        ], db: db, pid: pid)
        let res = try await makeEngine(conn).runDelegatedTask(req("写一首诗", "交一首五言绝句"))

        XCTAssertEqual(res["ok"], .bool(true), "D6a 追问后合法 → ok=True + 契约字段齐全")
        XCTAssertEqual(res["status"]?.string, "success")
        XCTAssertEqual(res["summary"]?.string, "子任务完成")
        XCTAssertEqual(res["artifacts"], .array([.string("out.md")]))

        let taskId = try XCTUnwrap(res["task_id"]?.string)
        let task6 = try db.getAgentTask(projectId: pid, taskId: taskId)
        XCTAssertEqual(task6?.status, "done", "D6b 任务落库 status=done + report 可解析")
        XCTAssertEqual(task6?.report?.object?["summary"]?.string, "子任务完成")

        let childSid = try XCTUnwrap(task6?.sessionId)
        let childMsgs = try db.loadMessages(projectId: pid, sessionId: childSid)
        XCTAssertEqual(childMsgs.count, 4, "D6c 追问留痕：子会话 user×2 assistant×2")
        XCTAssertEqual(childMsgs.map { $0.role }, ["user", "assistant", "user", "assistant"])
        XCTAssertTrue(childMsgs[2].content?.contains("重新交卷") ?? false,
                      "D6d 追问文案含格式要求")
        XCTAssertTrue(childMsgs.allSatisfy { !($0.content ?? "").contains("MAIN_CONV_MARKER") },
                      "D9a 上下文隔离：子会话不含主对话内容")
        let first = childMsgs[0].content ?? ""
        XCTAssertTrue(first.contains("【委派任务】") && first.contains(taskId)
                      && first.contains("交一首五言绝句"),
                      "D9b 首条 user 为任务书（含任务ID与交卷标准）")
        XCTAssertFalse(childMsgs.contains { $0.role == "system" },
                       "D9c 子会话无 system 消息落库（prompt 只在内存）")
    }

    // ══ D7 两次均不合法 → failed（用例 7）══

    func testD7_twiceInvalidFails() async throws {
        let expect7 = "交付一份市场分析报告"
        let conn = DelegScriptConn(["没按格式", "还是没按格式"], db: db, pid: pid)
        let res = try await makeEngine(conn).runDelegatedTask(req("做市场分析", expect7))

        XCTAssertEqual(res["ok"], .bool(false), "D7a 两次不合法 → ok=False")
        let err = res["error"]?.string ?? ""
        XCTAssertTrue(err.contains("Beta") && err.contains("两次交卷均未通过")
                      && err.contains(expect7),
                      "D7b error 含子 Agent 名与缺失说明")
        let taskId = try XCTUnwrap(res["task_id"]?.string)
        let task7 = try db.getAgentTask(projectId: pid, taskId: taskId)
        XCTAssertEqual(task7?.status, "failed",
                       "D7c DB failed + validation_failures=2 + fail_reason")
        XCTAssertEqual(task7?.validationFailures, 2)
        XCTAssertTrue(task7?.failReason?.contains("校验") ?? false)
    }

    // ══ D8 执行抛错 → 不穿透（用例 8）══

    func testD8_raisingConnectorContained() async throws {
        let res = try await makeEngine(DelegRaisingConn()).runDelegatedTask(req("任意任务", "任意标准"))
        XCTAssertEqual(res["ok"], .bool(false), "D8a 执行抛错 → ok=False 不穿透")
        XCTAssertTrue(res["error"]?.string?.contains("执行出错") ?? false)
        let taskId = try XCTUnwrap(res["task_id"]?.string)
        let task8 = try db.getAgentTask(projectId: pid, taskId: taskId)
        XCTAssertEqual(task8?.status, "failed", "D8b DB failed + fail_reason 非空")
        XCTAssertFalse(task8?.failReason?.isEmpty ?? true)
    }

    // ══ D13c 取消路径（验收标准 8：停止主会话 → 中断标记 + 锁正常释放）══

    func testD13c_cancellationMarksInterrupted() async throws {
        let nBefore = try db.listAgentTasks(projectId: pid, limit: 200).count
        let engine = makeEngine(DelegHangingConn())
        let request = req("长任务", "标准")
        let task = Task { try await engine.runDelegatedTask(request) }
        try await Task.sleep(nanoseconds: 400_000_000)   // 0.4s：等其进入挂起的推理
        task.cancel()                                    // asyncio.wait_for 超时取消等价
        let result = await task.result
        XCTAssertThrowsError(try result.get(),
                             "D13c 取消生效（执行被中断，CancelledError 上抛）") { err in
            XCTAssertTrue(err is CancellationError)
        }
        let newTasks = try db.listAgentTasks(projectId: pid, limit: 200)
        XCTAssertEqual(newTasks.count, nBefore + 1, "D13c 取消后 DB 恰新增 1 条任务")
        let tNew = try XCTUnwrap(newTasks.first)
        XCTAssertEqual(tNew.status, "failed", "D13c 任务标 failed + fail_reason 含中断")
        XCTAssertTrue(tNew.failReason?.contains("中断") ?? false, tNew.failReason ?? "")
    }

    // ══ D14 串行锁：并发 2 个委派 → 锁内区间无交叠（用例 14）══

    func testD14_concurrentDelegationsSerialized() async throws {
        let order = LockedList<String>()
        let engineA = makeEngine(DelegOrderConn(name: "A", order: order))
        let engineB = makeEngine(DelegOrderConn(name: "B", order: order))
        async let resA = engineA.runDelegatedTask(req("并发A", "标准"))
        async let resB = engineB.runDelegatedTask(req("并发B", "标准"))
        let results = try await [resA, resB]

        let seq = order.snapshot
        func intervals(_ name: String) -> [(Int, Int)] {
            let starts = seq.indices.filter { seq[$0] == "\(name)_start" }
            let ends = seq.indices.filter { seq[$0] == "\(name)_end" }
            return Array(zip(starts, ends))
        }
        let ia = intervals("A"), ib = intervals("B")
        let noOverlap = !ia.isEmpty && !ib.isEmpty && ia.allSatisfy { a in
            ib.allSatisfy { b in b.1 < a.0 || a.1 < b.0 }
        }
        XCTAssertEqual(ia.count, 2, "D14 并发委派串行执行（锁内区间无交叠）")
        XCTAssertEqual(ib.count, 2)
        XCTAssertTrue(noOverlap, seq.joined(separator: ","))
        XCTAssertTrue(results.allSatisfy {
            $0["ok"] == .bool(false)
                && ($0["error"]?.string?.contains("两次交卷均未通过") ?? false)
        }, "D14b 两个并发委派都正常落结果（两次不合法→failed）")
    }

    // ══ §2. queued 排队态（test_delegation2.py 2a-2c）══

    func testQueuedSemantics() async throws {
        // 2a create_agent_task 落库即 queued
        let tidQ = try db.createAgentTask(projectId: pid, parentAgentId: mainId,
                                          parentSessionId: parentSid, targetAgentId: betaId,
                                          targetAgentName: "Beta", task: "任务", expect: "标准")
        XCTAssertEqual(try db.getAgentTask(projectId: pid, taskId: tidQ)?.status, "queued",
                       "2a create_agent_task 落库即 queued")

        // 2b/2c：手动持有锁 → 委派应停在 queued → 释放后转 running→done
        let gate = NativeDelegationEngine.serialGate
        let held = await gate.acquire()
        XCTAssertTrue(held, "测试自身先占住串行锁")
        let engine = makeEngine(DelegScriptConn([.dynamic(delegGoodReport())], db: db, pid: pid))
        let request = req("排队任务", "标准")
        let delegTask = Task { try await engine.runDelegatedTask(request) }
        try await Task.sleep(nanoseconds: 200_000_000)   // 确保委派已落库并停在等锁
        let newest = try XCTUnwrap(try db.listAgentTasks(projectId: pid, limit: 1).first)
        XCTAssertEqual(newest.status, "queued", "2b 锁等待期间任务为 queued")
        XCTAssertEqual(newest.task, "排队任务")
        gate.release()
        let resQ = try await delegTask.value
        XCTAssertEqual(resQ["ok"], .bool(true), "2c 释放锁后执行至 done")
        let tid = try XCTUnwrap(resQ["task_id"]?.string)
        XCTAssertEqual(try db.getAgentTask(projectId: pid, taskId: tid)?.status, "done")
    }

    // ══ §4. 委派集成：未命中 + 开关语义（test_delegation2.py 4a-4c）══

    /// 驱动一轮真实 runToolLoop：模型首轮发 delegate_task，次轮收尾。
    private func driveMainLoop(args: [String: JSONValue],
                               config: [String: JSONValue])
        async -> (evs: [NativeAgentLoopEvent], conn: DelegRoundConn) {
        let childConn = DelegScriptConn([.dynamic(delegGoodReport(summary: "完成",
                                                                artifacts: []))],
                                        db: db, pid: pid)
        let engine = NativeDelegationEngine(db: db, connector: childConn,
                                            configProvider: { config })
        let mainConn = DelegRoundConn([
            (content: [], tools: [("delegate_task", args)]),
            (content: ["收到，已建好。"], tools: []),
        ])
        let dctx = NativeDelegationContext(projectId: pid, agentId: mainId,
                                           sessionId: parentSid, model: "qwen3.8",
                                           runner: engine)
        var evs: [NativeAgentLoopEvent] = []
        for await ev in NativeAgentLoop.runToolLoop(
            model: "qwen3.8", messages: [["role": .string("user"), "content": .string("hi")]],
            toolsSpecList: NativeAgentLoop.toolsSpec(withDelegation: true),
            sandboxRoot: sandbox.path, connector: mainConn, maxRounds: 5,
            delegationCtx: dctx, configProvider: { config }) {
            evs.append(ev)
        }
        return (evs, mainConn)
    }

    private func delegateToolResult(_ evs: [NativeAgentLoopEvent]) -> [String: JSONValue]? {
        evs.first { $0.event == "tool_result" && $0.data["name"]?.string == "delegate_task" }?.data
    }

    func test4a_autoCreateWithSuggestedRole() async throws {
        let config: [String: JSONValue] = ["network_switch": .string("auto"),
                                           "auto_create_sub_agents": .bool(true),
                                           "max_tool_rounds": .int(5)]
        let (evs, _) = await driveMainLoop(args: [
            "target": .string("幽灵"), "task": .string("T"), "expect": .string("E"),
            "suggested_role": .string("速记员"),
        ], config: config)
        let tr = try XCTUnwrap(delegateToolResult(evs), "4a 应有 delegate_task 结果")
        let created = try db.listAgentConfigs(projectId: pid).filter { $0.name == "速记员" }
        XCTAssertEqual(tr["ok"], .bool(true), "4a 未命中+开关开+建议角色 → 自动新建并执行")
        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(created.first?.type_, "sub", "4a2 新建的 Agent 是 sub 且角色正确")
        XCTAssertEqual(created.first?.role, "速记员")
        XCTAssertEqual(tr["created_agent"]?.string, "速记员", "4a3 结果含 created_agent 标注")
    }

    func test4b_autoCreateFallbackToTargetName() async throws {
        let config: [String: JSONValue] = ["network_switch": .string("auto"),
                                           "auto_create_sub_agents": .bool(true),
                                           "max_tool_rounds": .int(5)]
        let nBefore = try db.listAgentConfigs(projectId: pid).count
        let (evs, _) = await driveMainLoop(args: [
            "target": .string("人事专员"), "task": .string("T"), "expect": .string("E"),
        ], config: config)
        let tr = try XCTUnwrap(delegateToolResult(evs), "4b 应有 delegate_task 结果")
        let created = try db.listAgentConfigs(projectId: pid).filter { $0.name == "人事专员" }
        XCTAssertEqual(tr["ok"], .bool(true),
                       "4b 无建议角色 → 用目标名兜底新建并执行")
        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(try db.listAgentConfigs(projectId: pid).count, nBefore + 1)
        XCTAssertEqual(created.first?.role, "人事专员", "4b2 兜底新建的角色=目标名")
        XCTAssertEqual(created.first?.type_, "sub")
    }

    func test4c_switchOffDeclines() async throws {
        let config: [String: JSONValue] = ["network_switch": .string("auto"),
                                           "auto_create_sub_agents": .bool(false),
                                           "max_tool_rounds": .int(5)]
        let nBefore = try db.listAgentConfigs(projectId: pid).count
        let (evs, _) = await driveMainLoop(args: [
            "target": .string("不存在3"), "task": .string("T"), "expect": .string("E"),
            "suggested_role": .string("会计"),
        ], config: config)
        let tr = try XCTUnwrap(delegateToolResult(evs), "4c 应有 delegate_task 结果")
        let err = tr["error"]?.string ?? ""
        XCTAssertEqual(tr["ok"], .bool(false), "4c 开关关 → error 含已关闭+设置面板指引 且不新建")
        XCTAssertTrue(err.contains("已关闭") && err.contains("设置面板"), err)
        XCTAssertEqual(try db.listAgentConfigs(projectId: pid).count, nBefore)
    }
}


// MARK: - 0.7.4 W11 H6 核对：视觉守卫三向 + 换装编排注入缝回归锁

extension NativeDelegationEngineTests {

    /// ① 名称层命中 → true 且不调 probe（名称层能判就不触达元数据探测）。
    func testModelSupportsVisionNameHitSkipsProbe() async {
        final class ProbeBox: @unchecked Sendable { var calls = 0 }
        let box = ProbeBox()
        let engine = NativeDelegationEngine(
            db: db, connector: DelegRaisingConn(), configProvider: { [:] },
            visionProbe: { _ in box.calls += 1; return false })
        let hit = await engine.modelSupportsVision("qwen2.5-vl-7b")
        XCTAssertTrue(hit, "名称层命中视觉模型 → true")
        XCTAssertEqual(box.calls, 0, "名称层能判 → probe 不触达")
    }

    /// ② probe 未注入（nil）→ true 不阻塞（降级口径，对齐 Python None 放行）。
    func testModelSupportsVisionNilProbeDefaultsTrue() async {
        let engine = makeEngine(DelegRaisingConn())
        let r = await engine.modelSupportsVision("qwen3.8")   // 名称层判不了
        XCTAssertTrue(r, "probe=nil → true 不阻塞")
    }

    /// ③ probe 注入假闭包 → 名称层判不了时调用一次、透传模型名、以 probe 结果为准。
    func testModelSupportsVisionProbeConsulted() async {
        final class ProbeBox: @unchecked Sendable { var calls: [String] = [] }
        let box = ProbeBox()
        let engine = NativeDelegationEngine(
            db: db, connector: DelegRaisingConn(), configProvider: { [:] },
            visionProbe: { m in box.calls.append(m); return false })
        let r = await engine.modelSupportsVision("qwen3.8")
        XCTAssertFalse(r, "probe 返回 false → 判不支持视觉")
        XCTAssertEqual(box.calls, ["qwen3.8"], "probe 被调一次且透传模型名")
    }

    /// ④ 换装编排回归锁：parentModel≠childModel 且 swap 开关开（缺省开）→
    /// safeUnloadModel 委派前卸父模型、交卷后卸子模型各一次（NativeDelegation.swift
    /// 1538-1560 编排路径本身未变，W11 接管后此用例锁定注入缝真实被调）。
    func testSwapOrchestrationCallsSafeUnload() async throws {
        final class UnloadRec: @unchecked Sendable { var calls: [String] = [] }
        let rec = UnloadRec()
        _ = try db.addAgentConfig(projectId: pid, name: "Delta", type: "sub",
                                  modelName: "qwen2.5-text")
        let childConn = DelegScriptConn([.dynamic(delegGoodReport(summary: "完成",
                                                                artifacts: []))],
                                        db: db, pid: pid)
        let engine = NativeDelegationEngine(db: db, connector: childConn,
                                            configProvider: { [:] },
                                            safeUnloadModel: { m in rec.calls.append(m); return true })
        let mainConn = DelegRoundConn([
            (content: [], tools: [("delegate_task", ["target": .string("Delta"),
                                                     "task": .string("T"),
                                                     "expect": .string("E")])]),
            (content: ["ok"], tools: []),
        ])
        let dctx = NativeDelegationContext(projectId: pid, agentId: mainId,
                                           sessionId: parentSid, model: "qwen3.8",
                                           runner: engine)
        var evs: [NativeAgentLoopEvent] = []
        for await ev in NativeAgentLoop.runToolLoop(
            model: "qwen3.8", messages: [["role": .string("user"), "content": .string("hi")]],
            toolsSpecList: NativeAgentLoop.toolsSpec(withDelegation: true),
            sandboxRoot: sandbox.path, connector: mainConn, maxRounds: 5,
            delegationCtx: dctx, configProvider: { [:] }) {
            evs.append(ev)
        }
        XCTAssertEqual(rec.calls, ["qwen3.8", "qwen2.5-text"],
                       "委派前卸父模型、交卷后卸子模型各一次")
    }
}
