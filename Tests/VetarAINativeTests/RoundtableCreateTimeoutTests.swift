//
//  RoundtableCreateTimeoutTests.swift
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

//  覆盖双管修复：
//    ① 客户端层：createRoundtable 超时放宽到流式同档 600s（TimeoutProfile.default.stream）——
//       端点同步执行第一轮才返回（subagent/sidecar/app.py L1855），30s REST 超时必误报；
//       Electron 现状 apiJson 为裸 fetch 无超时（RoundtablePanel.tsx handleCreate）。
//    ② ViewModel 层（超时兜底）：即使超时也自动重拉圆桌列表，出现「创建前不存在 +
//       议题相同」的新圆桌 → 视为成功：清表单 + 直接打开详情 + 不弹失败；
//       列表无新圆桌 / 非超时错误 / 重拉失败 → 维持原报错。
//    · RoundtableFormat.recoveredAfterTimeout 纯函数：只认新 id + 同议题，
//      防误判历史同议题圆桌。
//
//  Mock 复用 RoundtablePluginsPanelTests.swift 的 W5aMockClient（同测试 target 内部可见）。
//

import XCTest
@testable import VetarAINative

@MainActor
private func makeTimeoutAppState(client: W5aMockClient, projectId: String? = "p1") -> AppState {
    let state = TestRuntimeSupport.makeAppState(client: client)
    state.currentProjectId = projectId
    return state
}

@MainActor
private func waitUntil(_ timeoutMs: UInt64 = 2000,
                       _ cond: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
    while Date() < deadline {
        if cond() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return cond()
}

// MARK: - 纯函数：recoveredAfterTimeout

final class RoundtableRecoveredAfterTimeoutTests: XCTestCase {

    private func rt(_ id: String, _ topic: String) -> Roundtable {
        Roundtable(id: id, topic: topic)
    }

    func testMatchesNewSameTopicEntry() {
        let before = [rt("old", "旧议题")]
        let after = [rt("new", "新议题"), rt("old", "旧议题")]
        XCTAssertEqual(RoundtableFormat.recoveredAfterTimeout(
            before: before, after: after, topic: "新议题")?.id, "new")
    }

    func testRejectsPreExistingSameTopicEntry() {
        // 创建前列表里已有同议题圆桌 → 不能误判为本次创建成功
        let before = [rt("old", "同议题")]
        let after = [rt("old", "同议题")]
        XCTAssertNil(RoundtableFormat.recoveredAfterTimeout(before: before, after: after, topic: "同议题"))
    }

    func testRejectsNewEntryWithDifferentTopic() {
        let after = [rt("new", "别的议题")]
        XCTAssertNil(RoundtableFormat.recoveredAfterTimeout(before: [], after: after, topic: "我的议题"))
    }

    func testEmptyAfterReturnsNil() {
        XCTAssertNil(RoundtableFormat.recoveredAfterTimeout(before: [], after: [], topic: "议题"))
    }

    func testPrefersNewestWhenMultipleNewSameTopic() {
        // 列表倒序（最新在前）：两条新同议题命中第一条
        let after = [rt("newest", "议题"), rt("older-new", "议题")]
        XCTAssertEqual(RoundtableFormat.recoveredAfterTimeout(
            before: [], after: after, topic: "议题")?.id, "newest")
    }
}

// MARK: - ViewModel：创建超时兜底

@MainActor
final class RoundtableCreateTimeoutFallbackTests: XCTestCase {

    private func makeVM(client: W5aMockClient) -> RoundtablePanelViewModel {
        RoundtablePanelViewModel(appState: makeTimeoutAppState(client: client),
                                 clientOverride: client,
                                 pollInterval: 3600, tickInterval: 3600)
    }

    /// 填好可过校验的表单（议题 + 两参与者，用户主持）。
    private func fillForm(_ vm: RoundtablePanelViewModel, topic: String = "测试议题") {
        vm.topic = topic
        vm.toggleAgent("a1")
        vm.toggleAgent("a2")
        XCTAssertNil(vm.createValidationError)
    }

    func testCreateTimeoutButLandedRecoversAsSuccess() async {
        let client = W5aMockClient()
        // 创建前 VM 列表为空；服务器实际已建成功 → 兜底重拉列表时出现新圆桌
        let landed = Roundtable(id: "rt-landed", topic: "测试议题", status: "running")
        client.createError = SidecarError.timeout
        client.roundtables = [landed]
        let vm = makeVM(client: client)
        fillForm(vm)
        vm.create()
        let recovered = await waitUntil { vm.selectedId == "rt-landed" }
        XCTAssertTrue(recovered, "超时兜底应识别已落库圆桌并进入详情")
        XCTAssertNil(vm.error, "兜底认成功后不得弹「创建失败」")
        XCTAssertEqual(vm.topic, "", "认成功后表单应清空")
        XCTAssertTrue(vm.selectedAgentIds.isEmpty)
        XCTAssertGreaterThanOrEqual(client.listRoundtablesCalls, 1, "兜底必须重拉列表")
        XCTAssertFalse(vm.creating)
    }

    func testCreateTimeoutWithoutLandingKeepsError() async {
        let client = W5aMockClient()
        client.createError = SidecarError.timeout
        // 重拉列表仍为空（服务器也没建成）→ 维持报错
        client.roundtables = []
        let vm = makeVM(client: client)
        fillForm(vm)
        vm.create()
        let ok = await waitUntil { !vm.creating && vm.error != nil }
        XCTAssertTrue(ok)
        XCTAssertEqual(vm.error, "创建失败: 请求超时")
        XCTAssertNil(vm.selectedId, "未落库不得进详情")
    }

    func testCreateTimeoutIgnoresPreExistingSameTopic() async {
        let client = W5aMockClient()
        // 创建前已存在同议题历史圆桌（先入 VM 列表）
        let old = Roundtable(id: "rt-old", topic: "测试议题", status: "done")
        client.roundtables = [old]
        let vm = makeVM(client: client)
        await vm.fetchRoundtables()
        client.createError = SidecarError.timeout
        // 超时后重拉列表还是只有这条旧圆桌 → 不得误判
        fillForm(vm)
        vm.create()
        let ok = await waitUntil { !vm.creating && vm.error != nil }
        XCTAssertTrue(ok)
        XCTAssertEqual(vm.error, "创建失败: 请求超时")
        XCTAssertNil(vm.selectedId)
    }

    func testCreateNonTimeoutErrorDoesNotRecover() async {
        let client = W5aMockClient()
        client.createError = SidecarError.httpError(status: 400, detail: "至少选择 2 个参与者")
        let vm = makeVM(client: client)
        fillForm(vm)
        vm.create()
        let ok = await waitUntil { !vm.creating && vm.error != nil }
        XCTAssertTrue(ok)
        XCTAssertEqual(vm.error, "创建失败: HTTP 400：至少选择 2 个参与者")
        XCTAssertNil(vm.selectedId)
    }

    func testCreateTimeoutRecoveryFailsWhenListRefetchFails() async {
        let client = W5aMockClient()
        client.createError = SidecarError.timeout
        client.listRoundtablesError = SidecarError.offline("down")
        let vm = makeVM(client: client)
        fillForm(vm)
        vm.create()
        let ok = await waitUntil { !vm.creating && vm.error != nil }
        XCTAssertTrue(ok)
        XCTAssertEqual(vm.error, "创建失败: 请求超时")
        XCTAssertNil(vm.selectedId)
    }

    func testCreateSuccessPathUnaffected() async {
        let client = W5aMockClient()
        client.createdRoundtable = Roundtable(id: "rt-new", topic: "测试议题")
        let vm = makeVM(client: client)
        fillForm(vm)
        vm.create()
        let ok = await waitUntil { vm.selectedId == "rt-new" }
        XCTAssertTrue(ok)
        XCTAssertNil(vm.error)
        XCTAssertEqual(vm.topic, "")
    }
}
