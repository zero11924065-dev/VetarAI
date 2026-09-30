//
//  VetarAppDelegateW11Tests.swift
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

//  覆盖（真实 VetarAppDelegate 实例走消息，不只 QuitGatePolicy 纯函数）：
//    · 末窗关闭 → shouldTerminateAfterLastWindowClosed 恒 true（W11 关窗即退）
//    · 末窗关闭链一次性直通：afterLastWindowClosed 置位后 shouldTerminate
//      即使 busy 也 terminateNow 不弹窗（防双弹窗；弹窗路径不进测试——
//      runModal 会卡死 runner，该分叉由 QuitGatePolicy/PanelBusyGuard 纯逻辑
//      测试覆盖，委托层只验证「跳过」行为）
//    · 直通标记一次性消费：第三次 shouldTerminate 落回策略判定（空闲直通）
//    · 未布线 busyGuard / 空闲 busyGuard → terminateNow
//
//  ⛔ 无法覆盖并诚实声明：W15 崩溃类（release 构建旗标 -disable-reflection-metadata
//  剥离 SwiftUI 反射元数据致 environmentObject 注入链断裂）——XCTest 恒 debug
//  构建（元数据在），永远拦不住 release 旗标问题；该类的护栏是
//  PackagingHardeningW15Tests 的打包脚本旗标断言。
//

import XCTest
@testable import VetarAINative

@MainActor
final class VetarAppDelegateW11Tests: XCTestCase {

    func testShouldTerminateAfterLastWindowClosedAlwaysTrue() {
        let d = VetarAppDelegate()
        XCTAssertTrue(d.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }

    func testWindowCloseChainSkipsQuitGateOnceEvenWhenBusy() {
        let d = VetarAppDelegate()
        let guard_ = PanelBusyGuard()
        guard_.report(.workflow, isBusy: true)   // busy：若不跳过必弹模态（runner 会挂）
        d.busyGuard = guard_
        // 末窗关闭链：windowShouldClose 闸已取过同意 → 置位直通
        XCTAssertTrue(d.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
        // 随后的 shouldTerminate 必须直通（本断言成立本身即证明未弹窗——
        // 弹了 runModal 测试不会返回）
        XCTAssertEqual(d.applicationShouldTerminate(NSApplication.shared), .terminateNow)
    }

    func testSkipFlagConsumedOnce() {
        let d = VetarAppDelegate()
        let guard_ = PanelBusyGuard()   // 空闲
        d.busyGuard = guard_
        XCTAssertTrue(d.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
        XCTAssertEqual(d.applicationShouldTerminate(NSApplication.shared), .terminateNow)
        // 标记已消费：再来一次仍按策略走（空闲 → 直通；不依赖残留标记）
        XCTAssertEqual(d.applicationShouldTerminate(NSApplication.shared), .terminateNow)
    }

    func testNoBusyGuardTerminatesNow() {
        let d = VetarAppDelegate()
        XCTAssertEqual(d.applicationShouldTerminate(NSApplication.shared), .terminateNow)
    }

    func testIdleBusyGuardTerminatesNow() {
        let d = VetarAppDelegate()
        d.busyGuard = PanelBusyGuard()
        XCTAssertEqual(d.applicationShouldTerminate(NSApplication.shared), .terminateNow)
    }
}
