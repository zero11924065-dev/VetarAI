//
//  PanelBusyGuardW9Tests.swift
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
//    · .quit 场景：工作流 busy → 「确认退出」+ 进度中断语义 + 「退出」钮
//    · .quit 场景：圆桌 busy → 如实「退出即中断」；⛔ 不得沿用「后台继续/后台运行」
//      （讨论跑在本进程内核，退出即终止——W8 切走口径的「后台继续」在 quit 场景不成立）
//    · .quit 场景：双源同忙 → 合并文案；空闲 → 直通 nil
//    · QuitGatePolicy：末窗关闭链一次性直通（防双弹窗）/ busy / 空闲 三态
//    · W11 联动：closeWindow 两源文案升级为「退出应用」必然口径
//

import XCTest
@testable import VetarAINative

@MainActor
final class PanelBusyGuardW9Tests: XCTestCase {

    // MARK: - .quit 场景文案（如实分叉）

    func testQuitWorkflowBusyNeedsConfirmationWithInterruptCopy() {
        let guard_ = PanelBusyGuard()
        guard_.report(.workflow, isBusy: true)
        let q = guard_.confirmation(for: .quit)
        XCTAssertEqual(q?.title, "确认退出")
        XCTAssertEqual(q?.confirmText, "退出")
        XCTAssertTrue(q?.message.contains("工作流正在运行") ?? false)
        XCTAssertTrue(q?.message.contains("退出应用") ?? false)
        XCTAssertTrue(q?.message.contains("中断") ?? false)
        XCTAssertTrue(q?.message.contains("运行记录") ?? false)
        XCTAssertTrue(q?.message.hasSuffix("确定退出吗？") ?? false)
    }

    func testQuitRoundtableBusyTruthfulInterruptNoBackgroundLie() {
        let guard_ = PanelBusyGuard()
        guard_.report(.roundtable, isBusy: true)
        let q = guard_.confirmation(for: .quit)
        XCTAssertEqual(q?.title, "确认退出")
        XCTAssertEqual(q?.confirmText, "退出")
        XCTAssertTrue(q?.message.contains("圆桌讨论进行中") ?? false)
        XCTAssertTrue(q?.message.contains("退出应用") ?? false)
        XCTAssertTrue(q?.message.contains("中断") ?? false)
        // 如实红线：quit 场景讨论随进程终止——不得出现「后台继续/后台运行」字样
        XCTAssertFalse(q?.message.contains("后台继续") ?? true)
        XCTAssertFalse(q?.message.contains("后台运行") ?? true)
    }

    func testQuitBothBusySourcesCombinedMessage() {
        let guard_ = PanelBusyGuard()
        guard_.report(.workflow, isBusy: true)
        guard_.report(.roundtable, isBusy: true)
        let q = guard_.confirmation(for: .quit)
        XCTAssertTrue(q?.message.contains("工作流正在运行") ?? false)
        XCTAssertTrue(q?.message.contains("圆桌讨论进行中") ?? false)
    }

    func testQuitIdlePassesThrough() {
        let guard_ = PanelBusyGuard()
        XCTAssertNil(guard_.confirmation(for: .quit))
    }

    // MARK: - QuitGatePolicy（终止闸决策纯逻辑）

    func testQuitGatePolicySkipAfterWindowClosePassesThrough() {
        // 末窗关闭链已取过同意（windowShouldClose 闸弹过一次）→ 直通防双弹窗
        XCTAssertFalse(QuitGatePolicy.needsConfirmation(skipAfterWindowClose: true,
                                                        isBusy: true))
        XCTAssertFalse(QuitGatePolicy.needsConfirmation(skipAfterWindowClose: true,
                                                        isBusy: false))
    }

    func testQuitGatePolicyBusyNeedsConfirmationIdlePasses() {
        XCTAssertTrue(QuitGatePolicy.needsConfirmation(skipAfterWindowClose: false,
                                                       isBusy: true))
        XCTAssertFalse(QuitGatePolicy.needsConfirmation(skipAfterWindowClose: false,
                                                        isBusy: false))
    }

    // MARK: - W11 联动：closeWindow 文案升级（关窗=退出=必然中断）

    func testCloseWindowWorkflowCopyReflectsQuitSemantics() {
        let guard_ = PanelBusyGuard()
        guard_.report(.workflow, isBusy: true)
        let cw = guard_.confirmation(for: .closeWindow)
        XCTAssertEqual(cw?.title, "确认关闭窗口")
        XCTAssertEqual(cw?.confirmText, "关闭")
        XCTAssertTrue(cw?.message.contains("关闭窗口将退出应用") ?? false)
        XCTAssertTrue(cw?.message.contains("中断本次运行") ?? false)
    }

    func testCloseWindowRoundtableCopyReflectsQuitSemantics() {
        let guard_ = PanelBusyGuard()
        guard_.report(.roundtable, isBusy: true)
        let cw = guard_.confirmation(for: .closeWindow)
        XCTAssertTrue(cw?.message.contains("关闭窗口将退出应用") ?? false)
        XCTAssertTrue(cw?.message.contains("讨论将中断") ?? false)
    }

    // MARK: - F2（0.7.12 实测修复）：.chat 源——生成中退出/关窗拦截、切走直通

    func testQuitChatBusyNeedsConfirmationWithInterruptCopy() {
        let guard_ = PanelBusyGuard()
        guard_.report(.chat, isBusy: true)
        let q = guard_.confirmation(for: .quit)
        XCTAssertEqual(q?.title, "确认退出")
        XCTAssertEqual(q?.confirmText, "退出")
        XCTAssertTrue(q?.message.contains("正在生成回复") ?? false)
        XCTAssertTrue(q?.message.contains("退出应用") ?? false)
        XCTAssertTrue(q?.message.contains("中断本次生成") ?? false)
        XCTAssertTrue(q?.message.hasSuffix("确定退出吗？") ?? false)
    }

    func testCloseWindowChatCopyReflectsQuitSemantics() {
        let guard_ = PanelBusyGuard()
        guard_.report(.chat, isBusy: true)
        let cw = guard_.confirmation(for: .closeWindow)
        XCTAssertEqual(cw?.title, "确认关闭窗口")
        XCTAssertEqual(cw?.confirmText, "关闭")
        XCTAssertTrue(cw?.message.contains("正在生成回复") ?? false)
        XCTAssertTrue(cw?.message.contains("关闭窗口将退出应用") ?? false)
        XCTAssertTrue(cw?.message.contains("中断本次生成") ?? false)
    }

    func testSwitchAwayChatOnlyPassesThrough() {
        // chat 切走后台续跑属实（0.7.8 后台流 stash）——单源 .chat 不拦不弹
        let guard_ = PanelBusyGuard()
        guard_.report(.chat, isBusy: true)
        XCTAssertNil(guard_.confirmation(for: .switchAway))
    }

    func testSwitchAwayChatMixedWithWorkflowShowsWorkflowOnly() {
        // 混合场景：chat 不掺和文案（它不中断），工作流如实拦截
        let guard_ = PanelBusyGuard()
        guard_.report(.chat, isBusy: true)
        guard_.report(.workflow, isBusy: true)
        let s = guard_.confirmation(for: .switchAway)
        XCTAssertTrue(s?.message.contains("工作流正在运行") ?? false)
        XCTAssertFalse(s?.message.contains("正在生成回复") ?? true)
    }

    func testChatReportIsIdempotent() {
        let guard_ = PanelBusyGuard()
        guard_.report(.chat, isBusy: true)
        guard_.report(.chat, isBusy: true)
        XCTAssertEqual(guard_.busySources, [.chat])
        guard_.report(.chat, isBusy: false)
        XCTAssertFalse(guard_.isBusy)
    }

    // MARK: - F2 接线：ChatViewModel 流式生命周期 → busyGuard .chat 登记/注销

    func testChatViewModelSendingRegistersChatBusySource() async throws {
        let client = ChatMockClient()
        client.streamNeverEnds = true
        client.streamEvents = [SSEEvent(event: "token", data: ["delta": "生成中"], rawData: "")]
        let appState = TestRuntimeSupport.makeAppState(client: client)
        appState.currentProjectId = "p1"
        appState.currentAgentId = "a1"
        let vm = ChatViewModel(appState: appState)
        try await Task.sleep(nanoseconds: 800_000_000)   // bootstrap（同 ChatSwitchStashTests 口径）
        XCTAssertTrue(vm.bootstrapped)
        XCTAssertFalse(appState.busyGuard.busySources.contains(.chat), "空闲不得登记")

        vm.input = "hi"
        vm.send()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(vm.sending)
        XCTAssertTrue(appState.busyGuard.busySources.contains(.chat),
                      "流式进行中必须登记 .chat（Cmd+Q 忙守的拦截依据）")
        XCTAssertNotNil(appState.busyGuard.confirmation(for: .quit),
                        "生成中 Cmd+Q 必须弹确认闸（0.7.12 实测失效的修复点）")

        // 手动停止 → 流终结 → 注销
        vm.stop()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(vm.sending)
        XCTAssertFalse(appState.busyGuard.busySources.contains(.chat), "流终结必须注销 .chat")
    }
}
