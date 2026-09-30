//
//  NativeAppEventsTests.swift
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

//  逐条翻译 subagent/sidecar/agent_engine/test_a13_app_events.py（⛔ 行为规格源
//  Python，语义以源码为准）：
//    T1 多订阅者广播（共享 Event 丢唤醒回归点 → 每订阅者独立信箱）
//    T2 晚到订阅者补发（since_seq 之后仍在缓冲的事件一次性补发）
//    T3 gap 断档检测（缓冲被挤掉后发 gap，不拿半截状态渲染）
//    T4 notify 异常安全（空 resource → false 不抛；空 action 仍投递；无订阅者
//       也入缓冲供晚到者补发）
//    T5 空闲产出 _idle（端点据此发 SSE 心跳防代理断连）
//    T6 订阅者断开后注销（onTermination ≡ Python finally，无计数泄漏）
//    T7 clear_all 通知全部订阅者结束（_bus_closed）并清空缓冲
//    T10 跨执行上下文投递（Python 跨 loop call_soon_threadsafe 回归点；Swift
//       NSLock 信箱天然跨上下文安全——订阅者跑在独立 Task 仍被唤醒）
//    REQ-AGT-020：notifyChildSessionChanged 的 payload 形态（S1c/S2e 的
//       resource=session/action=create/session_id/message_role/project_id
//       字段对账——W4b 挂起项本波补齐）
//
//  ⚠️VERIFY 未翻（原因）：
//    · T11/T12（19 个写端点 _notify_change 源码断言与端点行为实测）——端点
//      装配属路由层；内核侧等价覆盖：REQ-AGT-020 写点接线由 Route 套件
//      S2（总线级在线订阅实测）守住。
//    · T13（MUTATE=1|2|3 源码打补丁变异）——Swift 编译期绑定无法运行时变异；
//      变异 1/3 守护的修复点（跨上下文投递/gap 断档）由 T10/T3 行为断言守住，
//      变异 2（端点 notify 接线）随 T11 一并挂起。
//  P3-W6 翻转补票（原挂起项，本波已覆盖）：
//    · T8/T9（SSE 端点：connected 握手/字段下发/_subscribed·_idle 过滤/断开注销）
//      ——原生无 HTTP 序列化层（StreamingResponse/响应头不适用），端点行为由
//      testT8T9_endpointStream 锚定；客户端分发层由 testP3W6_clientDispatch 锚定。
//  形态适配（非规格偏差）：
//    · Python aclose() 订阅注销 → Swift for-await break/任务取消触发
//      onTermination；计数断言前留 ≤100ms 收口窗口（W4b 同例）。
//    · _take（取 n 条保持在线）→ collect 任务 break 前不取消；断言订阅者
//      在线期间完成。
//

import XCTest
@testable import VetarAINative

final class NativeAppEventsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        NativeAppEvents.clearAll()
    }

    override func tearDown() {
        NativeAppEvents.clearAll()
        super.tearDown()
    }

    /// 收集订阅流前 n 条到 out（break 触发 onTermination 注销，等价 Python aclose）。
    @discardableResult
    private func collect(_ n: Int, into out: LockedList<NativeAppBusEvent>,
                         sinceSeq: Int = 0,
                         idleTimeout: TimeInterval = 15) -> Task<Void, Never> {
        Task {
            for await e in NativeAppEvents.subscribe(sinceSeq: sinceSeq,
                                                     idleTimeout: idleTimeout) {
                out.append(e)
                if out.count >= n { break }
            }
        }
    }

    /// 轮询等待条件成立（默认 2s 上限）。
    private func waitUntil(_ cond: @escaping () -> Bool,
                           timeoutMs: UInt64 = 2000) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return cond()
    }

    // ══ T1 多订阅者广播（⛔ 共享 Event 丢唤醒回归点 → 每订阅者独立信箱）══

    func testT1_multiSubscriberBroadcast() async throws {
        let a = LockedList<NativeAppBusEvent>()
        let b = LockedList<NativeAppBusEvent>()
        // ⛔ _take 语义：两个订阅者取完握手后必须仍在线，才能验证一对多广播
        let ta = collect(2, into: a, idleTimeout: 0.2)
        let tb = collect(2, into: b, idleTimeout: 0.2)
        let registered = await waitUntil { NativeAppEvents.subscriberCount() == 2 }
        XCTAssertTrue(registered, "T1a 两个订阅者都已注册")
        XCTAssertTrue(NativeAppEvents.notify(NativeAppEvents.resourceWorkflow,
                                             NativeAppEvents.actionUpdate,
                                             extra: ["workflow_id": .string("wf1")]))
        _ = await ta.value
        _ = await tb.value
        XCTAssertEqual(a.snapshot.map { $0.event }, ["_subscribed", "resource_changed"],
                       "T1b 订阅者A收到握手+变更")
        XCTAssertEqual(b.snapshot.map { $0.event }, ["_subscribed", "resource_changed"],
                       "T1b 订阅者B同样收到（不丢唤醒）")
        XCTAssertEqual(a.snapshot[1].data["workflow_id"], .string("wf1"),
                       "T1b 附加字段并入 data 下发")
        XCTAssertEqual(b.snapshot[1].data["workflow_id"], .string("wf1"))
    }

    // ══ T2 晚到订阅者补发：面板中途连上也要补齐缓冲区内错过的变更 ══

    func testT2_lateSubscriberBackfill() async throws {
        NativeAppEvents.notify(NativeAppEvents.resourceProject,
                               NativeAppEvents.actionCreate, projectId: "p1")
        NativeAppEvents.notify(NativeAppEvents.resourceProject,
                               NativeAppEvents.actionDelete, projectId: "p2")
        NativeAppEvents.notify(NativeAppEvents.resourcePlugin,
                               NativeAppEvents.actionUpdate,
                               extra: ["plugin_name": .string("x")])
        let out = LockedList<NativeAppBusEvent>()
        // since_seq=1 → 只补发 seq 2、3（_subscribed + 2 条 = 3 条后 aclose）
        await collect(3, into: out, sinceSeq: 1, idleTimeout: 0.2).value
        let evs = out.snapshot.filter { $0.event == "resource_changed" }
        XCTAssertEqual(evs.map { $0.seq }, [2, 3], "T2a 补发 seq>since_seq 的全部事件")
        XCTAssertEqual(evs.map { $0.data["resource"] }, [.string("project"), .string("plugin")],
                       "T2b 补发内容正确（project delete + plugin update）")
        XCTAssertEqual(evs[0].data["action"], .string("delete"))
        XCTAssertEqual(evs[0].data["project_id"], .string("p2"))
    }

    // ══ T3 gap 断档检测：缓冲被挤掉后必须发 gap（订阅者据此重拉）══

    func testT3_gapDetection() async throws {
        for i in 0..<(NativeAppEvents.bufferMax + 10) {   // 灌满并挤掉最旧
            NativeAppEvents.notify(NativeAppEvents.resourceKnowledge,
                                   NativeAppEvents.actionUpdate,
                                   extra: ["n": .int(Int64(i))])
        }
        let out = LockedList<NativeAppBusEvent>()
        await collect(2, into: out, sinceSeq: 1, idleTimeout: 0.2).value
        let names = out.snapshot.map { $0.event }
        XCTAssertTrue(names.contains("gap"), "T3a 断档时收到 gap 事件（实际 \(names)）")
        let gap = out.snapshot.first { $0.event == "gap" }
        XCTAssertEqual(gap?.data["from"], .int(1), "T3b gap 携带 from")
        if case .int = gap?.data["oldest_available"] {
            // T3b oldest_available 为 int（供前端判断落后多少）
        } else {
            XCTFail("T3b gap 携带 oldest_available（int）")
        }
    }

    // ══ T4 notify 异常安全：⛔ 总线是旁路，非法入参不得抛到写库主流程 ══

    func testT4_notifyExceptionSafety() {
        XCTAssertFalse(NativeAppEvents.notify("", NativeAppEvents.actionCreate),
                       "T4a 空 resource → False 且不抛")
        XCTAssertFalse(NativeAppEvents.notify(nil, nil),
                       "T4b 全 None → False 且不抛")
        XCTAssertTrue(NativeAppEvents.notify(NativeAppEvents.resourceWorkflow, ""),
                      "T4c 合法 resource + 空 action → 仍投递（不抛）")
        XCTAssertTrue(NativeAppEvents.latestSeq() >= 1
                      && NativeAppEvents.bufferedCount() >= 1,
                      "T4d 无订阅者时 notify 也返回 True（事件入缓冲供晚到者补发）")
    }

    // ══ T5 空闲产出 _idle：端点据此发心跳注释行（防代理断连）══

    func testT5_idleHeartbeat() async throws {
        let out = LockedList<NativeAppBusEvent>()
        await collect(2, into: out, idleTimeout: 0.05).value
        XCTAssertTrue(out.snapshot.map { $0.event }.contains("_idle"),
                      "T5a 无事件时空闲超时产出 _idle")
    }

    // ══ T6 订阅者断开后注销：⛔ onTermination 必须摘掉队列，否则计数泄漏 ══

    func testT6_subscriberCleanup() async throws {
        let out = LockedList<NativeAppBusEvent>()
        await collect(1, into: out, idleTimeout: 0.2).value   // 取握手后 break → aclose
        let cleaned = await waitUntil { NativeAppEvents.subscriberCount() == 0 }
        XCTAssertTrue(cleaned, "T6a aclose 后订阅者计数归零（无泄漏）")
    }

    // ══ T7 clear_all 通知订阅者结束（不静默挂死）并清空缓冲 ══

    func testT7_clearAllCloses() async throws {
        NativeAppEvents.notify(NativeAppEvents.resourceAgent, NativeAppEvents.actionCreate)
        let out = LockedList<NativeAppBusEvent>()
        // ⛔ _take 语义：取完握手保持在线（收 clear_all 通知），流自然结束后退出
        let t = Task {
            for await e in NativeAppEvents.subscribe(sinceSeq: 0, idleTimeout: 0.2) {
                out.append(e)
            }
        }
        let online = await waitUntil {
            out.count >= 2 && NativeAppEvents.subscriberCount() == 1
        }
        XCTAssertTrue(online, "T7 前置：握手+补发到达且订阅者在线")
        NativeAppEvents.clearAll()
        _ = await t.value
        XCTAssertTrue(out.snapshot.contains { $0.event == "_bus_closed" },
                      "T7a clear_all 后订阅者收到 _bus_closed")
        XCTAssertEqual(NativeAppEvents.bufferedCount(), 0, "T7b clear_all 清空缓冲")
        XCTAssertEqual(NativeAppEvents.latestSeq(), 0, "T7b clear_all 清空 seq")
    }

    // ══ T10 跨执行上下文投递（Python 跨 loop call_soon_threadsafe 回归点）══

    func testT10_crossContextDelivery() async throws {
        // 订阅者跑在独立 Task（另一执行上下文），notify 从当前上下文调用。
        // Python 撤掉 call_soon_threadsafe 即静默失败；Swift 信箱天然跨上下文
        // 安全（NSLock + continuation 唤醒无 loop 亲和），本用例守住等价行为。
        let got = LockedList<NativeAppBusEvent>()
        let ready = LockedList<String>()
        let worker = Task.detached {
            for await ev in NativeAppEvents.subscribe(sinceSeq: 0, idleTimeout: 1.0) {
                if ev.event == "_subscribed" { ready.append("ready"); continue }
                got.append(ev)
                break
            }
        }
        let readyOk = await waitUntil {
            !ready.snapshot.isEmpty && NativeAppEvents.subscriberCount() >= 1
        }
        XCTAssertTrue(readyOk, "T10a 另一上下文上的订阅者已注册")
        NativeAppEvents.notify(NativeAppEvents.resourcePlugin,
                               NativeAppEvents.actionCreate,
                               extra: ["plugin_name": .string("cross")])
        _ = await worker.value
        XCTAssertEqual(got.snapshot.first?.data["resource"], .string("plugin"),
                       "T10b 跨上下文投递唤醒订阅者")
    }

    // ══ REQ-AGT-020：notifyChildSessionChanged 的 payload 形态对账 ══
    // （Python S1c/S2e 挂起段：resource=session/action=create/session_id/
    //   message_role/project_id 五要素；W4b 钩层只覆盖三要素，本波补齐总线形态）

    func testAGT020_childSessionNotifyPayloadShape() async throws {
        let out = LockedList<NativeAppBusEvent>()
        let t = collect(2, into: out, idleTimeout: 0.2)
        let subOne = await waitUntil { NativeAppEvents.subscriberCount() == 1 }
        XCTAssertTrue(subOne)
        NativeAppEvents.notifyChildSessionChanged(projectId: "p1", sessionId: "child-1",
                                                  messageRole: "user")
        _ = await t.value
        let ev = try XCTUnwrap(out.snapshot.last)
        XCTAssertEqual(ev.event, "resource_changed")
        XCTAssertEqual(ev.data["resource"], .string("session"),
                       "AGT-020 payload resource=session（前端据此重拉 ChatPanel）")
        XCTAssertEqual(ev.data["action"], .string("create"))
        XCTAssertEqual(ev.data["session_id"], .string("child-1"), "定向重拉凭 session_id")
        XCTAssertEqual(ev.data["message_role"], .string("user"))
        XCTAssertEqual(ev.data["project_id"], .string("p1"))
    }

    // ══ T8/T9 端点级翻转（P3-W6 补票：NativeAppEventsEndpoint.stream 逐行为锚定）══
    //  原生无 HTTP 序列化层——T8a/b/c（StreamingResponse/content-type/防缓冲头）
    //  不适用；T8d/e（connected 握手带 seq）、T9a-f（resource_changed 真实下发、
    //  _subscribed/_idle 过滤、payload 五要素）、T9g（断开注销）逐条覆盖。

    func testT8T9_endpointStream() async throws {
        var it = NativeAppEventsEndpoint.stream(since: 0).makeAsyncIterator()

        // T8d/T8e 首条 connected 握手，携带当前 seq（int，前端据此初始化游标）
        let first = try await it.next()
        XCTAssertEqual(first?.event, "connected", "T8d 首条事件是 connected 握手")
        XCTAssertNotNil(first?.int("seq"), "T8e connected 携带 seq（int）")

        // T9 notify 的变更真实下发，字段齐全（_subscribed/_idle 被端点过滤——
        // 第二条直接是 resource_changed）
        NativeAppEvents.notify(NativeAppEvents.resourceWorkflow,
                               NativeAppEvents.actionCreate, projectId: "p9",
                               extra: ["workflow_id": .string("wf9")])
        let second = try await it.next()
        XCTAssertEqual(second?.event, "resource_changed",
                       "T9a resource_changed 真实下发（_subscribed/_idle 不下发，T9b/T9c）")
        XCTAssertEqual(second?.string("resource"), "workflow", "T9e payload 含 resource")
        XCTAssertEqual(second?.string("action"), "create", "T9e payload 含 action")
        XCTAssertNotNil(second?.int("seq"), "T9f payload 含 seq（int）")
        XCTAssertEqual(second?.string("workflow_id"), "wf9", "T9f payload 含业务字段 workflow_id")
        XCTAssertEqual(second?.string("project_id"), "p9", "T9f payload 含 project_id")
        // T9d SSE 行格式等价物：rawData 是可 JSON 解析的对象文本（面板解析器零改动）
        XCTAssertTrue(second?.rawData.hasPrefix("{") ?? false,
                      "T9d rawData 为 JSON 对象文本（_sse_format 同构）")
    }

    // ══ T9g 端点流断开注销（客户端断开后订阅者计数归零，无幽灵连接）══

    func testT9g_endpointStreamDisconnectCleanup() async throws {
        let got = LockedList<String>()
        let consumer = Task {
            do {
                for try await ev in NativeAppEventsEndpoint.stream(since: 0) {
                    got.append(ev.event)
                }
            } catch { /* 取消路径不抛 */ }
        }
        let online = await waitUntil {
            got.snapshot.contains("connected") && NativeAppEvents.subscriberCount() == 1
        }
        XCTAssertTrue(online, "T9g 前置：端点流已订阅（握手到达且计数=1）")
        consumer.cancel()
        let cleaned = await waitUntil { NativeAppEvents.subscriberCount() == 0 }
        XCTAssertTrue(cleaned, "T9g 客户端断开后订阅者注销（onTermination 归还计数）")
    }

    // ══ P3-W6 客户端分发层：NativeSidecarClient.appEventsStream 直返原生端点 ══
    //  （偏差⑦收口——五面板 VM 经协议调用，协议零改动；端到端：notify → 客户端流收到）

    func testP3W6_clientDispatch() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("w6disp_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let kernel = NativeKernel(dataRoot: tmp)
        let client = NativeSidecarClient(kernel: kernel)

        var it = client.appEventsStream(since: 0).makeAsyncIterator()
        let first = try await it.next()
        XCTAssertEqual(first?.event, "connected", "客户端分发：首条 connected 握手")
        XCTAssertNotNil(first?.int("seq"))

        NativeAppEvents.notify(NativeAppEvents.resourcePlugin,
                               NativeAppEvents.actionUpdate,
                               extra: ["plugin_name": .string("w6")])
        let second = try await it.next()
        XCTAssertEqual(second?.event, "resource_changed", "客户端分发：notify 端到端送达")
        XCTAssertEqual(second?.string("resource"), "plugin")
        XCTAssertEqual(second?.string("plugin_name"), "w6")
        XCTAssertNotNil(second?.int("seq"), "payload 补 seq（端点逐行为）")
    }
}
