//
//  NativeDelegationEventsTests.swift
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

//  逐条翻译 test_p15_delegation_stream.py（⛔ 行为规格源 Python，语义以源码为准）：
//    T1 多订阅者广播 / T2 晚到订阅者补发 / T3 gap 断档检测 / T4 end_task 必发
//    task_end 且无订阅者回收 / T5 有订阅者不回收 / T6 订阅者断开回收 /
//    T7 push 异常安全 / T8 _idle 心跳 / T9 通道上限只淘汰空闲 /
//    T13 委派接线（直译为行为断言：真实委派的事件序覆盖 begin/push/end_task，
//        含失败路径 defer 收口）/ T14 token 节流（直译为行为断言：50 个 token
//        仅 1 条字节流 progress、总线零 token 事件、tool_call/tool_result 逐条）。
//
//  ⚠️VERIFY 未翻（原因）：
//    · T10/T11/T12（SSE 端点：snapshot 首条/keepalive 过滤/格式与 chat/stream
//      一致）——属 app.py HTTP 序列化层，原生内核无 SSE 端点（W4b 不翻路由，
//      NativeDelegationEvents.swift 头注偏差②），路由翻转波次覆盖。
//    · T15/变异机制（MUTATE=1|2|3 源码打补丁）——Swift 编译期绑定无法运行时
//      变异；T13/T14 已改直译行为断言守住同一修复点（事件序/节流计数）。
//  形态适配（非规格偏差）：
//    · Python aclose() 订阅注销 → Swift for-await break/任务取消触发
//      onTermination；计数断言前留 ≤50ms 收口窗口。
//    · T4 首个订阅用 idleTimeout=0.2（Python 默认 15s 心跳等出第 2 条事件；
//      语义相同，缩短等待）。
//

import XCTest
@testable import VetarAINative

/// T14 用假工具执行器：全部工具返回 ok（不打真工具链）。
private final class DelegFakeExecutor: NativeLoopToolExecutor, @unchecked Sendable {
    func executeLoopTool(_ name: String, args: [String: JSONValue],
                         sandboxRoot: String) async -> [String: JSONValue] {
        ["ok": .bool(true), "result": .string("fake-ok")]
    }
}

final class NativeDelegationEventsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        NativeDelegationEvents.clearAll()
        NativeDelegationEngine.resetSharedState()
    }

    override func tearDown() {
        NativeDelegationEvents.clearAll()
        super.tearDown()
    }

    /// 收集订阅流前 n 条到 out（break 触发 onTermination 注销，等价 Python aclose）。
    private func collect(_ pid: String, _ n: Int, into out: LockedList<NativeDelegationBusEvent>,
                         sinceSeq: Int = 0, idleTimeout: TimeInterval = 15) -> Task<Void, Never> {
        Task {
            for await e in NativeDelegationEvents.subscribe(pid, sinceSeq: sinceSeq,
                                                            idleTimeout: idleTimeout) {
                out.append(e)
                if out.count >= n { break }
            }
        }
    }

    // ══ T1 多订阅者广播（⛔ 共享 Event 丢唤醒回归点 → 每订阅者独立信箱）══

    func testT1_multiSubscriberBroadcast() async throws {
        let P = "p_t1"
        NativeDelegationEvents.beginTask(P, "t1")
        let a = LockedList<NativeDelegationBusEvent>()
        let b = LockedList<NativeDelegationBusEvent>()
        let ta = collect(P, 3, into: a)
        let tb = collect(P, 3, into: b)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(NativeDelegationEvents.subscriberCount(P), 2, "T1a 两个订阅者都注册成功")
        NativeDelegationEvents.push(P, "t1", "tool_call", ["name": .string("read_file")])
        NativeDelegationEvents.push(P, "t1", "tool_result", ["ok": .bool(true)])
        _ = await ta.value
        _ = await tb.value
        let ea = a.snapshot.map { $0.event }
        let eb = b.snapshot.map { $0.event }
        XCTAssertEqual(ea, ["_subscribed", "tool_call", "tool_result"],
                       "T1b 订阅者A收到握手+两事件")
        XCTAssertEqual(eb, ["_subscribed", "tool_call", "tool_result"],
                       "T1c 订阅者B同样收到（无丢唤醒）")
        XCTAssertEqual(a.snapshot[1].taskId, "t1", "T1d 事件携带 task_id")
        XCTAssertLessThan(a.snapshot[1].seq, a.snapshot[2].seq, "T1e seq 单调递增")
    }

    // ══ T2 晚到订阅者补发缓冲区事件 ══

    func testT2_lateSubscriberBackfill() async throws {
        let P = "p_t2"
        NativeDelegationEvents.beginTask(P, "t1")
        NativeDelegationEvents.push(P, "t1", "tool_call", ["name": .string("A")])
        NativeDelegationEvents.push(P, "t1", "tool_call", ["name": .string("B")])
        XCTAssertEqual(NativeDelegationEvents.bufferedCount(P), 2, "T2a 缓冲含 2 条")
        let late = LockedList<NativeDelegationBusEvent>()
        await collect(P, 3, into: late).value
        XCTAssertEqual(late.snapshot.map { $0.event }, ["_subscribed", "tool_call", "tool_call"],
                       "T2b 晚到订阅者补发缓冲 2 条")
        XCTAssertEqual(late.snapshot.dropFirst().map { $0.data["name"]?.string }, ["A", "B"],
                       "T2c 补发内容正确且有序")
        let part = LockedList<NativeDelegationBusEvent>()
        await collect(P, 2, into: part, sinceSeq: 1).value
        XCTAssertEqual(part.snapshot.count, 2, "T2d since_seq 过滤生效（只补 seq>1）")
        XCTAssertEqual(part.snapshot[1].data["name"]?.string, "B")
    }

    // ══ T3 环形缓冲溢出后必须发 gap ══

    func testT3_gapDetection() async throws {
        let P = "p_t3"
        NativeDelegationEvents.beginTask(P, "t1")
        for i in 0..<(NativeDelegationEvents.bufferMax + 50) {
            NativeDelegationEvents.push(P, "t1", "progress", ["i": .int(Int64(i))])
        }
        let g = LockedList<NativeDelegationBusEvent>()
        let t = Task {
            for await e in NativeDelegationEvents.subscribe(P, sinceSeq: 5) {
                g.append(e)
                if e.event == "gap" || g.count >= 3 { break }
            }
        }
        await t.value
        let evs = g.snapshot
        let gap = evs.first { $0.event == "gap" }
        XCTAssertNotNil(gap, "T3a 断档时发 gap 事件")
        XCTAssertEqual(gap?.data["from"]?.int, 5, "T3b gap 携带 from 与 oldest_available")
        XCTAssertNotNil(gap?.data["oldest_available"]?.int)
        XCTAssertLessThanOrEqual(NativeDelegationEvents.bufferedCount(P),
                                 NativeDelegationEvents.bufferMax, "T3c 缓冲不超上限")
    }

    // ══ T4 end_task 必发 task_end；无订阅者时回收通道 ══

    func testT4_endTaskAndRecycle() async throws {
        let P = "p_t4"
        NativeDelegationEvents.beginTask(P, "t1")
        XCTAssertEqual(NativeDelegationEvents.activeTaskCount(P), 1, "T4a 活跃任务数=1")
        XCTAssertEqual(NativeDelegationEvents.channelCount(), 1, "T4b 通道已建")
        let rec = LockedList<NativeDelegationBusEvent>()
        await collect(P, 2, into: rec, idleTimeout: 0.2).value   // 订阅者在场时（握手+心跳）
        NativeDelegationEvents.clearAll()   // 重新建通道再测"无订阅者"回收
        NativeDelegationEvents.beginTask(P, "t2")
        NativeDelegationEvents.endTask(P, "t2")
        XCTAssertEqual(NativeDelegationEvents.channelCount(), 0,
                       "T4c 无订阅者时 end_task 回收通道")
        XCTAssertEqual(NativeDelegationEvents.activeTaskCount(P), 0,
                       "T4d end_task 后活跃任务=0")
    }

    // ══ T5 有订阅者时绝不回收通道 ══

    func testT5_noRecycleWithSubscriber() async throws {
        let P = "p_t5"
        NativeDelegationEvents.beginTask(P, "t1")
        let hold = LockedList<NativeDelegationBusEvent>()
        let th = collect(P, 99, into: hold, idleTimeout: 0.2)
        try await Task.sleep(nanoseconds: 50_000_000)
        NativeDelegationEvents.endTask(P, "t1")
        XCTAssertEqual(NativeDelegationEvents.channelCount(), 1, "T5a 有订阅者时通道保留")
        XCTAssertEqual(NativeDelegationEvents.activeTaskCount(P), 0, "T5b 活跃任务已清零")
        th.cancel()
        _ = await th.value
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(NativeDelegationEvents.channelCount(), 0, "T5c 订阅者断开后通道回收")
    }

    // ══ T6 订阅者注销必须在 onTermination（Python finally 等价）══

    func testT6_subscriberCleanup() async throws {
        let P = "p_t6"
        NativeDelegationEvents.beginTask(P, "t1")
        let s = NativeDelegationEvents.subscribe(P)
        XCTAssertEqual(NativeDelegationEvents.subscriberCount(P), 1,
                       "T6a 订阅中 subscriber_count=1")
        let t = Task { for await _ in s { /* 挂住模拟在线订阅者 */ } }
        try await Task.sleep(nanoseconds: 50_000_000)   // 等握手被消费
        t.cancel()                                      // aclose 等价：客户端断开
        _ = await t.value
        try await Task.sleep(nanoseconds: 50_000_000)   // onTermination 收口窗口
        XCTAssertEqual(NativeDelegationEvents.subscriberCount(P), 0,
                       "T6b 断开后 subscriber_count=0")
        XCTAssertEqual(NativeDelegationEvents.channelCount(), 1,
                       "T6c 任务仍活跃时通道保留（不淘汰活跃通道）")
        NativeDelegationEvents.endTask(P, "t1")
        XCTAssertEqual(NativeDelegationEvents.channelCount(), 0,
                       "T6d 任务结束+无订阅者 → 通道回收")
    }

    // ══ T7 push 异常安全：任何异常都不得影响委派本身 ══

    func testT7_pushExceptionSafety() {
        XCTAssertFalse(NativeDelegationEvents.push("nope", "t", "status"),
                       "T7a 无通道 push 返回 False（不抛）")
        XCTAssertFalse(NativeDelegationEvents.push("", "t", "status"),
                       "T7b 空 project push 返回 False")
        XCTAssertFalse(NativeDelegationEvents.push("p", "t", ""),
                       "T7c 空 event push 返回 False")
        XCTAssertFalse(NativeDelegationEvents.push("", "", ""),
                       "T7d 空参数不抛（Python None 等价）")
        NativeDelegationEvents.beginTask("p7", "t7")
        XCTAssertTrue(NativeDelegationEvents.push("p7", "t7", "status"),
                      "T7e data 缺省不抛且可推送")
    }

    // ══ T8 空闲产出 _idle 心跳 ══

    func testT8_idleHeartbeat() async {
        let P = "p_t8"
        NativeDelegationEvents.beginTask(P, "t1")
        let out = LockedList<NativeDelegationBusEvent>()
        await collect(P, 2, into: out, idleTimeout: 0.12).value
        XCTAssertEqual(out.snapshot.map { $0.event }, ["_subscribed", "_idle"],
                       "T8a 空闲产出 _subscribed + _idle")
    }

    // ══ T9 通道淘汰只针对空闲通道 ══

    func testT9_evictionOnlyIdle() {
        for i in 0..<NativeDelegationEvents.maxChannels {
            NativeDelegationEvents.beginTask("busy_\(i)", "t\(i)")
        }
        XCTAssertEqual(NativeDelegationEvents.channelCount(), NativeDelegationEvents.maxChannels,
                       "T9a 活跃通道数达上限")
        NativeDelegationEvents.beginTask("one_more", "t")
        XCTAssertEqual(NativeDelegationEvents.channelCount(),
                       NativeDelegationEvents.maxChannels + 1,
                       "T9b 全忙时宁可超上限也不淘汰活跃通道")
        for i in 0..<NativeDelegationEvents.maxChannels {
            XCTAssertEqual(NativeDelegationEvents.activeTaskCount("busy_\(i)"), 1,
                           "T9c 活跃通道一个都没丢")
        }
        NativeDelegationEvents.endTask("one_more", "t")
        NativeDelegationEvents.beginTask("trigger", "t")
        XCTAssertLessThanOrEqual(NativeDelegationEvents.channelCount(),
                                 NativeDelegationEvents.maxChannels + 1,
                                 "T9d 有空闲通道时淘汰生效")
    }

    // ══ T13 委派接线（直译行为断言）+ T14 token 节流（直译行为断言）══

    /// 建临时项目/引擎；本测试类每个工程用例独立 mktemp。
    private func makeFixture(
        _ conn: any NativeChatConnector,
        executor: (any NativeLoopToolExecutor)? = nil
    ) throws -> (URL, NativeDatabase, String, NativeDelegationEngine, NativeDelegationTaskRequest) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("p2w4b_bus_\(UUID().uuidString)")
        let sandbox = tmp.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let db = NativeDatabase(projectsRoot: tmp.appendingPathComponent("projects"))
        let pid = try db.createProject(name: "bus", workingDir: tmp.appendingPathComponent("wd").path)
        let mainId = try db.addAgentConfig(projectId: pid, name: "Alpha", type: "main",
                                           modelName: "qwen3.8")
        let betaId = try db.addAgentConfig(projectId: pid, name: "Beta", type: "sub",
                                           modelName: "qwen3.8")
        let sid = try db.createSession(projectId: pid, agentId: mainId, title: "主会话")
        let beta = try XCTUnwrap(try db.getAgentConfig(projectId: pid, agentId: betaId))
        let engine = NativeDelegationEngine(db: db, connector: conn,
                                            toolExecutor: executor, configProvider: { [:] })
        let req = NativeDelegationTaskRequest(projectId: pid, parentAgentId: mainId,
                                              parentSessionId: sid, targetAgent: beta,
                                              task: "写一首诗", expect: "交一首五言绝句",
                                              sandboxRoot: sandbox.path, maxRounds: 5)
        return (tmp, db, pid, engine, req)
    }

    /// T13b-d：真实委派 → 订阅者收到 status(queued)→status(running)→…→status(done)
    /// →task_end 全序；结束后活跃任务清零（begin/end_task/push 接线齐全，end_task defer 收口）。
    func testT13_wiringEventSequenceAndDeferCleanup() async throws {
        let (tmp, _, pid, engine, req) = try makeFixture(
            DelegScriptConn([.dynamic(delegGoodReport())]))
        defer { try? FileManager.default.removeItem(at: tmp) }

        let evs = LockedList<NativeDelegationBusEvent>()
        let sub = Task {
            for await e in NativeDelegationEvents.subscribe(pid, idleTimeout: 0.3) {
                evs.append(e)
                if e.event == "task_end" { break }
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)   // 订阅者先就位
        let res = try await engine.runDelegatedTask(req)
        XCTAssertEqual(res["ok"], .bool(true))
        try await Task.sleep(nanoseconds: 300_000_000)   // 等 task_end 送达
        sub.cancel()
        _ = await sub.value

        let seq = evs.snapshot
        let states = seq.filter { $0.event == "status" }
            .compactMap { $0.data["state"]?.string }
        XCTAssertEqual(states, ["queued", "running", "done"],
                       "T13b/c 接线：queued→running→done 状态序齐全")
        XCTAssertEqual(seq.last?.event, "task_end", "T13d end_task 必发 task_end 收口")
        let tid = try XCTUnwrap(res["task_id"]?.string)
        XCTAssertTrue(seq.dropFirst().allSatisfy { $0.taskId == tid },
                      "事件全部携带本任务 task_id")
        XCTAssertEqual(NativeDelegationEvents.activeTaskCount(pid), 0,
                       "T13d 结束后活跃任务清零（通道可回收）")
        let seqs = seq.map { $0.seq }
        XCTAssertEqual(seqs, seqs.sorted(), "seq 单调")
    }

    /// T13d 失败路径：两次交卷不合法（failed 返回路径）也必须发 task_end
    ///（Python finally 等价 = Swift defer——返回/异常/取消全路径收口）。
    func testT13_failurePathStillEndsTask() async throws {
        let failing = DelegScriptConn(["没按格式", "还是没按格式"])
        let (tmp, _, pid, engine, req) = try makeFixture(failing)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let evs = LockedList<NativeDelegationBusEvent>()
        let sub = Task {
            for await e in NativeDelegationEvents.subscribe(pid, idleTimeout: 0.3) {
                evs.append(e)
                if e.event == "task_end" { break }
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let res = try await engine.runDelegatedTask(req)
        XCTAssertEqual(res["ok"], .bool(false))   // 交卷两次不合法 → failed 返回路径
        try await Task.sleep(nanoseconds: 300_000_000)
        sub.cancel()
        _ = await sub.value
        XCTAssertEqual(evs.snapshot.last?.event, "task_end",
                       "T13d 失败路径也必发 task_end（defer 收口，前端不转圈）")
        XCTAssertEqual(NativeDelegationEvents.activeTaskCount(pid), 0)
    }

    /// T14 token 节流（行为直译）：50 个 token 仅产生 1 条字节流 progress；
    /// 总线零 "token" 事件；tool_call/tool_result 逐条转发。
    func testT14_tokenThrottleAndToolForwarding() async throws {
        // 第 1 轮两个工具调用，第 2 轮 50 个小 token 拼出合法交卷
        let report = "{\"task_id\": \"TID\", \"status\": \"success\", "
            + "\"summary\": \"子任务完成\", \"artifacts\": []}"
        let chunks = [report] + Array(repeating: "", count: 49)
        let conn = DelegRoundConn([
            (content: [], tools: [("list_dir", ["path": .string(".")]),
                                  ("read_file", ["path": .string("a.txt")])]),
            (content: chunks, tools: []),
        ])
        let (tmp, _, pid, engine, req) = try makeFixture(conn, executor: DelegFakeExecutor())
        defer { try? FileManager.default.removeItem(at: tmp) }

        let evs = LockedList<NativeDelegationBusEvent>()
        let sub = Task {
            for await e in NativeDelegationEvents.subscribe(pid, idleTimeout: 0.3) {
                evs.append(e)
                if e.event == "task_end" { break }
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let res = try await engine.runDelegatedTask(req)
        XCTAssertEqual(res["ok"], .bool(true))
        try await Task.sleep(nanoseconds: 300_000_000)
        sub.cancel()
        _ = await sub.value

        let seq = evs.snapshot
        // 字节流 progress：仅 token 分支产生（无 step / 无 round_done 标记）
        let tokenProgress = seq.filter {
            $0.event == "progress" && $0.data["step"] == nil && $0.data["round_done"] == nil
        }
        XCTAssertEqual(tokenProgress.count, 1,
                       "T14b 50 个 token 仅 1 条字节流 progress（≥2s 时间门控）")
        XCTAssertNotNil(tokenProgress.first?.data["chars"]?.int)
        XCTAssertFalse(seq.contains { $0.event == "token" },
                       "T14c token 分支不逐条 push token 事件")
        XCTAssertEqual(seq.filter { $0.event == "tool_call" }.count, 2,
                       "T14d tool_call 逐条转发")
        let trs = seq.filter { $0.event == "tool_result" }
        XCTAssertEqual(trs.count, 2, "T14e tool_result 逐条转发")
        XCTAssertEqual(trs.map { $0.data["name"]?.string }, ["list_dir", "read_file"])
        XCTAssertEqual(trs.map { $0.data["ok"] }, [.bool(true), .bool(true)])
        XCTAssertEqual(seq.last?.event, "task_end")
    }
}
