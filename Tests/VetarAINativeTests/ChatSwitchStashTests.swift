//
//  ChatSwitchStashTests.swift
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

//  根因与修法（文件：行号，修复前）：
//    Bug1（切去子 agent 再切回主 agent，消息只剩 1 条）：
//      ChatViewModel.switchContext 切走时无条件 streamingMessageId/streamingSessionId=nil
//      + messages=[]；切回时 currentSessionIdChanged 用 DB 快照整体覆盖——委派场景主流
//      仍在跑，assistant 回复 done 才落库（DB 只有用户消息）→ 只剩 1 条；后续 token
//      事件 patchMessage 按 id 找不到气泡全部丢弃；再切换 DB 重拉（已落库）就"恢复"。
//      修法 = 旧线 DBG-089 H16 + checkpoint-055 同症修法：后台流 stash（切走整包收下、
//      事件分流进 stash、切回瞬装回）+ 加载收口 mergeDbWithLocal（DB 权威 + 合并本地
//      未落盘流式气泡，ChatModels.swift 逐字移植旧线 ChatPanel.tsx L776-839）。
//    Bug2a（消失态指示器 5345）：孤儿流 apply(.state) 无归属判断，后台流 ctx_chars
//      持续回写当前视图 tokenIndicator → 修 = state 分支按 isLive 分流，后台只进 stash。
//    Bug2b（恢复态 246）：restoreTokenIndicator est>0 恒短路，chars×0.6 漏算系统提示词
//      → 修 = max(est, pec)，pec 取 DB 已持久化 prompt_eval_count（无归档消息时）。
//
//  隔离纪律：ChatMockClient 全假（项目感知会话列表 + 可控续流 continuation）；
//  TestRuntimeSupport 数据根落临时目录，绝不碰真实 ~/.subagent。
//

import XCTest
@testable import VetarAINative

@MainActor
final class ChatSwitchStashTests: XCTestCase {

    private func ev(_ event: String, _ data: [String: Any] = [:]) -> SSEEvent {
        SSEEvent(event: event, data: data, rawData: "")
    }

    /// 同 ChatPanelW1Tests.bootstrappedVM 模式（runtime init 同步点亮 nativeReady →
    /// sink 触发 bootstrap，睡 800ms 完成）；返回 vm + appState（切上下文要写 appState）。
    private func bootstrappedVM(_ client: ChatMockClient) async throws
        -> (vm: ChatViewModel, appState: AppState) {
        let appState = TestRuntimeSupport.makeAppState(client: client)
        appState.currentProjectId = "p1"
        appState.currentAgentId = "a1"
        let vm = ChatViewModel(appState: appState)
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertTrue(vm.bootstrapped, "bootstrap 未完成")
        XCTAssertEqual(vm.currentSessionId, "s1")
        return (vm, appState)
    }

    // ══ Bug1 核心：切去子 agent 再切回，主流气泡不丢、后台推进续上、done 完整收敛 ══

    func testSwitchBackToMainAgentKeepsStreamingMessages() async throws {
        let client = ChatMockClient()
        client.streamNeverEnds = true
        client.streamEvents = [ev("token", ["delta": "流式中"])]
        client.dbMessages = []   // DB 此刻空（assistant done 才落库——Bug1 的真实前提）
        let (vm, appState) = try await bootstrappedVM(client)

        vm.input = "hi"
        vm.send()
        try await Task.sleep(nanoseconds: 400_000_000)
        // 预置：主流在跑，user + assistant 流式气泡齐全
        XCTAssertTrue(vm.sending)
        XCTAssertEqual(vm.messages.count, 2)
        XCTAssertEqual(vm.messages.last?.content, "流式中")
        XCTAssertEqual(vm.messages.last?.isStreaming, true)

        // 切去子 agent 上下文（Bug1 场景动作：主流仍在后台跑）
        appState.currentProjectId = "p2"
        appState.currentAgentId = "a2"
        try await Task.sleep(nanoseconds: 900_000_000)   // 60ms 防抖 + 切换 + 加载
        XCTAssertFalse(vm.sending, "切走后新上下文无活流")

        // 后台流仍在推进：补一个 token——绝不进当前视图（也不崩溃丢失）
        client.pushStreamEvent(ev("token", ["delta": "，后台推进"]))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(vm.messages.last(where: { $0.role == "assistant" }),
                     "后台流 token 不得落进当前看的会话视图")

        // 切回主 agent
        appState.currentProjectId = "p1"
        appState.currentAgentId = "a1"
        try await Task.sleep(nanoseconds: 900_000_000)

        // Bug1 钉桩①：气泡不丢——stash 瞬装回 + DB 权威合并（live 保留流式气泡）
        XCTAssertTrue(vm.sending, "切回后流仍是进行中（不再假死）")
        XCTAssertEqual(vm.messages.count, 2, "切回后 user + assistant 双气泡齐全")
        XCTAssertEqual(vm.messages.first(where: { $0.role == "user" })?.content, "hi")
        let assistant = vm.messages.last(where: { $0.role == "assistant" })
        XCTAssertEqual(assistant?.content, "流式中，后台推进",
                       "Bug1：切走期间的后台 token 必须续在气泡上（修复前全部丢弃）")
        XCTAssertEqual(assistant?.isStreaming, true)

        // 流 done：全文覆盖收敛，内容完整
        client.pushStreamEvent(ev("done", ["content": "流式中，后台推进。完"]))
        client.finishStream()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(vm.sending)
        XCTAssertEqual(vm.messages.last(where: { $0.role == "assistant" })?.content,
                       "流式中，后台推进。完")
        XCTAssertEqual(vm.messages.count, 2, "done 后不多不少（local_ 气泡不产生副本）")
    }

    // ══ Bug2a：后台孤儿流的 ctx_chars 绝不回写当前视图指示器；切回才恢复真值 ══

    func testBackgroundStreamDoesNotLeakIntoTokenIndicator() async throws {
        let client = ChatMockClient()
        client.streamNeverEnds = true
        client.streamEvents = [ev("state", ["step": 1, "max": 200, "tokens_used": 100,
                                            "ctx_chars": 500])]
        client.dbMessages = []
        let (vm, appState) = try await bootstrappedVM(client)

        vm.input = "hi"
        vm.send()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(vm.tokenIndicator.used, 300, "live 流的 state 正常回写（500×0.6）")

        // 切走：指示器随上下文复位
        appState.currentProjectId = "p2"
        appState.currentAgentId = "a2"
        try await Task.sleep(nanoseconds: 900_000_000)
        XCTAssertEqual(vm.tokenIndicator.used, 0, "切走后指示器复位（新上下文无真值）")

        // 后台孤儿流来 state ctx_chars=8908（Bug2 消失态 5345 的复现输入）
        client.pushStreamEvent(ev("state", ["step": 2, "max": 200, "tokens_used": 200,
                                            "ctx_chars": 8908]))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(vm.tokenIndicator.used, 0,
                       "Bug2a：后台流 ctx_chars 绝不回写当前视图指示器（修复前此处变 5345）")

        // 切回：stash 里的后端真值恢复
        appState.currentProjectId = "p1"
        appState.currentAgentId = "a1"
        try await Task.sleep(nanoseconds: 900_000_000)
        XCTAssertTrue(vm.sending)
        XCTAssertEqual(vm.tokenIndicator.used, 5345,
                       "切回后指示器恢复 stash 真值（8908×0.6=5345，单调守门保留）")
    }

    // ══ Bug2b：恢复指示器取 max(est, pec)——DB 持久化真值不再被 chars×0.6 短路 ══

    func testRestoreTokenIndicatorPrefersPersistedPromptEvalCount() async throws {
        // 场景A：DB 历史带真实 prompt_eval_count → 恢复取 pec（est 漏算系统提示词是假低）
        let client = ChatMockClient()
        var assistant = ChatMessage(id: "2", role: "assistant", content: "也短")
        assistant.promptEvalCount = 5000
        client.dbMessages = [ChatMessage(id: "1", role: "user", content: "短"), assistant]
        let (vm, _) = try await bootstrappedVM(client)
        XCTAssertEqual(vm.tokenIndicator.used, 5000,
                       "Bug2b：恢复态优先 DB 持久化真值（修复前 est=2 短路 → 显示 2，"
                       + "与实测恢复态 246 同源）")

        // 场景B：存在已归档消息 → pec 是归档前旧真值（偏高），回落 est（跳过 archived）
        let clientB = ChatMockClient()
        var archived = ChatMessage(id: "4", role: "assistant", content: "也短")
        archived.promptEvalCount = 5000
        archived.archived = true
        clientB.dbMessages = [ChatMessage(id: "3", role: "user", content: "短"), archived]
        let (vmB, _) = try await bootstrappedVM(clientB)
        XCTAssertEqual(vmB.tokenIndicator.used, 1,
                       "有归档 → pec 弃用（旧真值偏高），回落 est（1 字 ×0.6 ≈ 1）")
    }

    // ══ Bug1 纯函数桩：mergeDbWithLocal（DB 权威 + local_ 合并全分支）══

    func testMergeDbWithLocalKeepsInFlightBubble() {
        let dbUser = ChatMessage(id: "1", role: "user", content: "hi")

        // ① live=true：同文 local_ user 被 DB 定稿去重；流式 assistant 原样保留
        let localUser = ChatMessage(id: "local_1", role: "user", content: "hi")
        var streaming = ChatMessage(id: "local_2", role: "assistant", content: "进行中")
        streaming.isStreaming = true
        let merged = mergeDbWithLocal(db: [dbUser], local: [localUser, streaming], live: true)
        XCTAssertEqual(merged.map(\.id), ["1", "local_2"],
                       "DB 权威 + 同文 local_ 去重 + 活流气泡保留（H16）")
        XCTAssertTrue(merged[1].isStreaming, "活流气泡原样保留（流会继续推进）")

        // ② live=false：空内容无步骤的僵尸气泡丢弃（后端要么完成要么中断，以 DB 为准）；
        //    R1（0.7.12 A5）：丢弃后末条停在 user → 补「已中断」标记气泡（悬空不再静默）
        var emptyZombie = ChatMessage(id: "local_3", role: "assistant", content: "")
        emptyZombie.isStreaming = true
        let mergedE = mergeDbWithLocal(db: [dbUser], local: [emptyZombie], live: false)
        XCTAssertEqual(mergedE.count, 2, "僵尸空气泡不恢复（checkpoint-059）；R1 补中断标记")
        XCTAssertEqual(mergedE[0].id, "1")
        XCTAssertEqual(mergedE[1].role, "assistant")
        XCTAssertEqual(mergedE[1].interruptedNote, "已中断执行（应用退出或崩溃，本轮未生成回复）")
        XCTAssertNotEqual(mergedE[1].id, "local_3", "标记是新建气泡，不是复活的僵尸")

        // ③ live=false：有内容的僵尸 → 清活态 + 标中断半成品（不谎称手动停止）
        var zombie = ChatMessage(id: "local_4", role: "assistant", content: "半成品")
        zombie.isStreaming = true
        zombie.thinkingActive = true
        zombie.waitingSeconds = 12
        let mergedZ = mergeDbWithLocal(db: [dbUser], local: [zombie], live: false)
        XCTAssertEqual(mergedZ.count, 2)
        let z = mergedZ[1]
        XCTAssertFalse(z.isStreaming)
        XCTAssertFalse(z.thinkingActive)
        XCTAssertEqual(z.waitingSeconds, 0)
        XCTAssertEqual(z.interruptedNote, "已中断执行（应用断开或崩溃，内容为半成品）")
        XCTAssertFalse(z.manuallyStopped, "不置 manualStopped（不能谎称用户手动停止）")

        // ④ C8 前缀去重：缓存 content 是 DB 定稿的前缀 → 不追加副本
        let dbDone = ChatMessage(id: "2", role: "assistant", content: "你好世界")
        let localPrefix = ChatMessage(id: "local_5", role: "assistant", content: "你好")
        XCTAssertEqual(mergeDbWithLocal(db: [dbDone], local: [localPrefix], live: false)
                        .map(\.id), ["2"], "前缀匹配去重（abort 少收几个 token 的场景）")

        // ⑤ C8 补漏：空正文按工具步骤签名去重（running 视同 interrupted）
        var dbTool = ChatMessage(id: "3", role: "assistant", content: "")
        dbTool.toolSteps = [ToolStep(id: "t1", name: "shell", status: .interrupted)]
        var localTool = ChatMessage(id: "local_6", role: "assistant", content: "")
        localTool.toolSteps = [ToolStep(id: "t1", name: "shell", status: .running)]
        XCTAssertEqual(mergeDbWithLocal(db: [dbTool], local: [localTool], live: false)
                        .map(\.id), ["3"], "空正文按步骤签名去重（running≡interrupted）")

        // ⑥ 极端兜底：非 local_ 的本地 id 不在 DB → 保留；
        //    R1：保留后末条停在 user → 同样补中断标记（孤儿 user 也是未答轮次）
        let orphan = ChatMessage(id: "99", role: "user", content: "孤儿")
        let mergedO = mergeDbWithLocal(db: [dbUser], local: [orphan], live: false)
        XCTAssertEqual(mergedO.map(\.id).prefix(2), ["1", "99"])
        XCTAssertEqual(mergedO.count, 3)
        XCTAssertEqual(mergedO.last?.interruptedNote, "已中断执行（应用退出或崩溃，本轮未生成回复）")
    }
}
