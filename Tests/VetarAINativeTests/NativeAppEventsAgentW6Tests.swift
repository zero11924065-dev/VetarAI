//
//  NativeAppEventsAgentW6Tests.swift
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

//  覆盖：
//    · 发布（端点层口径 NativeAppEvents.notify agent/update 带 agent_id）
//      → 订阅收到 resource_changed、载荷正确（agent_id / project_id）
//    · isAgentUpdatedEvent 过滤：agent/update 命中；其他资源/动作/控制事件不命中
//  发布侧端点层接线（updateAgent / updateIndependentAgent 成功即广播）
//  由既有端点测试覆盖，本文件锁 W6 新增的订阅侧契约。
//

import XCTest
@testable import VetarAINative

@MainActor
final class NativeAppEventsAgentW6Tests: XCTestCase {

    /// 发布 → 订阅收到、载荷正确（以 sinceSeq 隔离历史缓冲，不打扰其他测试）
    func testAgentUpdatePublishSubscribePayload() async {
        let since = NativeAppEvents.latestSeq()
        let stream = NativeAppEvents.subscribe(sinceSeq: since)
        var it = stream.makeAsyncIterator()
        _ = await it.next()   // _subscribed 握手

        // 端点层发布口径（app.py L812/L356 逐行为：成功 return 前 notify）
        NativeAppEvents.notify(NativeAppEvents.resourceAgent, NativeAppEvents.actionUpdate,
                               projectId: "p1", extra: ["agent_id": .string("a1")])

        // 跳过握手/心跳，取第一条 resource_changed（事件即刻投递，少量迭代内必到）
        var received: NativeAppBusEvent?
        for _ in 0..<8 {
            guard let ev = await it.next() else { break }
            if ev.event == "resource_changed" { received = ev; break }
        }
        let ev = try? XCTUnwrap(received, "未收到 agent/update 资源变更事件")
        XCTAssertEqual(ev?.data["resource"]?.string, "agent")
        XCTAssertEqual(ev?.data["action"]?.string, "update")
        XCTAssertEqual(ev?.data["agent_id"]?.string, "a1")
        XCTAssertEqual(ev?.data["project_id"]?.string, "p1")
        if let ev { XCTAssertTrue(NativeAppEvents.isAgentUpdatedEvent(ev)) }
    }

    /// 过滤助手：仅 agent/update 命中，其余一律不命中
    func testIsAgentUpdatedEventFilter() {
        let hit = NativeAppBusEvent(seq: 1, event: "resource_changed", data: [
            "resource": .string("agent"), "action": .string("update")])
        XCTAssertTrue(NativeAppEvents.isAgentUpdatedEvent(hit))

        // 其他资源
        let otherResource = NativeAppBusEvent(seq: 2, event: "resource_changed", data: [
            "resource": .string("workflow"), "action": .string("update")])
        XCTAssertFalse(NativeAppEvents.isAgentUpdatedEvent(otherResource))
        // 其他动作（agent/create、agent/delete 不冒充 updated）
        let create = NativeAppBusEvent(seq: 3, event: "resource_changed", data: [
            "resource": .string("agent"), "action": .string("create")])
        XCTAssertFalse(NativeAppEvents.isAgentUpdatedEvent(create))
        let delete = NativeAppBusEvent(seq: 4, event: "resource_changed", data: [
            "resource": .string("agent"), "action": .string("delete")])
        XCTAssertFalse(NativeAppEvents.isAgentUpdatedEvent(delete))
        // 控制事件（心跳/握手）
        let idle = NativeAppBusEvent(seq: 5, event: "_idle", data: [:])
        XCTAssertFalse(NativeAppEvents.isAgentUpdatedEvent(idle))
        let subscribed = NativeAppBusEvent(seq: 6, event: "_subscribed", data: [:])
        XCTAssertFalse(NativeAppEvents.isAgentUpdatedEvent(subscribed))
    }
}
