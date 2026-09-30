//
//  PanelBusyGuardW8Tests.swift
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

//  覆盖（busy 判定逻辑纯逻辑层）：
//    · 空闲 → 直通（confirmation 为 nil）
//    · 工作流运行中 → 需确认，文案如实含「中断」语义（切走/关窗分叉）
//    · 圆桌讨论进行中 → 需确认，切走文案如实含「后台运行」语义
//    · 双源同忙 → 合并文案两源俱全
//    · 撤报 → 恢复直通
//    · 圆桌详情返回闸：running 才弹、终态直通
//

import XCTest
@testable import VetarAINative

@MainActor
final class PanelBusyGuardW8Tests: XCTestCase {

    func testIdlePassesThroughWithoutConfirmation() {
        let guard_ = PanelBusyGuard()
        XCTAssertFalse(guard_.isBusy)
        XCTAssertNil(guard_.confirmation(for: .switchAway))
        XCTAssertNil(guard_.confirmation(for: .closeWindow))
    }

    func testWorkflowRunningNeedsConfirmation() {
        let guard_ = PanelBusyGuard()
        guard_.report(.workflow, isBusy: true)
        XCTAssertTrue(guard_.isBusy)
        // 切走：实时进度中断（如实；结果可在运行记录查看）
        let sw = guard_.confirmation(for: .switchAway)
        XCTAssertEqual(sw?.title, "确认离开")
        XCTAssertEqual(sw?.confirmText, "离开")
        XCTAssertTrue(sw?.message.contains("工作流正在运行") ?? false)
        XCTAssertTrue(sw?.message.contains("中断") ?? false)
        XCTAssertTrue(sw?.message.contains("运行记录") ?? false)
        // 关窗：中断语义 + 关闭钮
        let cw = guard_.confirmation(for: .closeWindow)
        XCTAssertEqual(cw?.title, "确认关闭窗口")
        XCTAssertEqual(cw?.confirmText, "关闭")
        XCTAssertTrue(cw?.message.contains("工作流正在运行") ?? false)
        XCTAssertTrue(cw?.message.contains("中断") ?? false)
    }

    func testRoundtableRunningNeedsConfirmationWithBackgroundCopy() {
        let guard_ = PanelBusyGuard()
        guard_.report(.roundtable, isBusy: true)
        // 切走：讨论在内核继续跑——如实告知后台继续（不谎称中断）
        let sw = guard_.confirmation(for: .switchAway)
        XCTAssertTrue(sw?.message.contains("圆桌讨论进行中") ?? false)
        XCTAssertTrue(sw?.message.contains("后台运行") ?? false)
        XCTAssertFalse(sw?.message.contains("中断") ?? true)
        // 关窗（0.7.5 W11 后：末窗关闭即退出应用，条件变必然，如实直写）
        let cw = guard_.confirmation(for: .closeWindow)
        XCTAssertTrue(cw?.message.contains("退出应用") ?? false)
        XCTAssertTrue(cw?.message.contains("中断") ?? false)
    }

    func testBothBusySourcesCombinedMessage() {
        let guard_ = PanelBusyGuard()
        guard_.report(.workflow, isBusy: true)
        guard_.report(.roundtable, isBusy: true)
        let sw = guard_.confirmation(for: .switchAway)
        XCTAssertTrue(sw?.message.contains("工作流正在运行") ?? false)
        XCTAssertTrue(sw?.message.contains("圆桌讨论进行中") ?? false)
    }

    func testUnreportRestoresPassThrough() {
        let guard_ = PanelBusyGuard()
        guard_.report(.workflow, isBusy: true)
        XCTAssertNotNil(guard_.confirmation(for: .switchAway))
        guard_.report(.workflow, isBusy: false)
        XCTAssertFalse(guard_.isBusy)
        XCTAssertNil(guard_.confirmation(for: .switchAway))
    }

    /// 重复上报幂等
    func testReportIdempotent() {
        let guard_ = PanelBusyGuard()
        guard_.report(.workflow, isBusy: true)
        guard_.report(.workflow, isBusy: true)
        XCTAssertEqual(guard_.busySources, [.workflow])
        guard_.report(.roundtable, isBusy: false)   // 未报过的源撤报无副作用
        XCTAssertEqual(guard_.busySources, [.workflow])
    }

    /// 圆桌详情「返回列表」闸：running 才弹，其余状态直通
    func testRoundtableDetailCloseConfirmationOnlyWhenRunning() {
        XCTAssertNotNil(PanelBusyGuard.roundtableDetailCloseConfirmation(running: true))
        XCTAssertNil(PanelBusyGuard.roundtableDetailCloseConfirmation(running: false))
        let c = PanelBusyGuard.roundtableDetailCloseConfirmation(running: true)
        XCTAssertTrue(c?.message.contains("后台运行") ?? false)
    }
}
