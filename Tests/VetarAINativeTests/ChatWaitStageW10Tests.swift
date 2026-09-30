//
//  ChatWaitStageW10Tests.swift
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
//    · 阶段机文案：loading/generating 两阶段文案 + 「已等待 Ns」口径保留
//    · 预估后缀：无样本/剩余≤0 不显示（绝不编造）；剩余>0 显示「预计还需约 Xs」
//    · FirstTokenStats：无样本 nil / 记录→均值 / 超 5 截尾 / 非法值忽略 / 按模型隔离
//    · VM 集成（脚本化 SSE）：无事件=loading；thinking=generating；
//      首个正文 token 记录样本；预置样本后 waitEstimate 就位
//

import XCTest
@testable import VetarAINative

@MainActor
final class ChatWaitStageW10Tests: XCTestCase {

    private func isolatedStats() -> FirstTokenStats {
        FirstTokenStats(defaults: UserDefaults(
            suiteName: "vetarai-test-w10-\(UUID().uuidString)")!)
    }

    private func ev(_ event: String, _ data: [String: Any] = [:]) -> SSEEvent {
        SSEEvent(event: event, data: data, rawData: "")
    }

    // MARK: - 阶段机文案

    func testBannerTextStages() {
        XCTAssertEqual(ChatWaitStage.loading.bannerText(waitedSeconds: 9),
                       "模型装载/装填中，较久属正常（本地模型）…已等待 9s")
        XCTAssertEqual(ChatWaitStage.generating.bannerText(waitedSeconds: 12),
                       "生成中…已等待 12s")
    }

    // MARK: - 预估后缀（保守口径：无样本/剩余≤0 不显示）

    func testEstimateSuffixNeverFabricates() {
        XCTAssertEqual(ChatWaitStage.estimateSuffix(estimate: nil, waitedSeconds: 10), "")
        XCTAssertEqual(ChatWaitStage.estimateSuffix(estimate: 10, waitedSeconds: 10), "")
        XCTAssertEqual(ChatWaitStage.estimateSuffix(estimate: 8, waitedSeconds: 20), "")
        XCTAssertEqual(ChatWaitStage.estimateSuffix(estimate: 30, waitedSeconds: 10),
                       "，预计还需约 20s")
    }

    // MARK: - F5（0.7.12 实测修复）：「进行中 Ns」chip 预估——第 1 秒可见、正文出即隐

    /// chip 口径核心：正文空（首 token 未到）+ 有样本剩余 > 0 → 第 1 秒就追加预估
    ///（旧设计需 8 ≤ waited < estimate，本地模型 2–5s 首 token 永远够不着）。
    func testChipSuffixVisibleFromFirstSecond() {
        XCTAssertEqual(ChatWaitStage.chipSuffix(estimate: 5, waitedSeconds: 1,
                                                contentEmpty: true),
                       "，预计还需约 4s", "1 个样本、第 1 秒即显示——F5 修复点")
        XCTAssertEqual(ChatWaitStage.chipSuffix(estimate: 3, waitedSeconds: 2,
                                                contentEmpty: true),
                       "，预计还需约 1s")
    }

    /// 正文一出（首 token 到达）预估使命完成 → 不再追加（哪怕剩余 > 0）。
    func testChipSuffixDisappearsOnceContentArrives() {
        XCTAssertEqual(ChatWaitStage.chipSuffix(estimate: 30, waitedSeconds: 2,
                                                contentEmpty: false), "")
    }

    /// chip 同样守保守红线：无样本 / 剩余 ≤ 0 静默。
    func testChipSuffixNeverFabricates() {
        XCTAssertEqual(ChatWaitStage.chipSuffix(estimate: nil, waitedSeconds: 1,
                                                contentEmpty: true), "")
        XCTAssertEqual(ChatWaitStage.chipSuffix(estimate: 2, waitedSeconds: 5,
                                                contentEmpty: true), "")
    }

    // MARK: - FirstTokenStats 样本库

    func testStatsNoSampleReturnsNil() {
        XCTAssertNil(isolatedStats().estimate(for: "qwen3.8"))
    }

    func testStatsRecordAndMean() {
        let stats = isolatedStats()
        stats.record(model: "qwen3.8", seconds: 10)
        stats.record(model: "qwen3.8", seconds: 14)
        XCTAssertEqual(stats.estimate(for: "qwen3.8"), 12)   // (10+14)/2
    }

    func testStatsRingKeepsLatestFive() {
        let stats = isolatedStats()
        for s in [10, 10, 10, 10, 10, 40, 40] { stats.record(model: "m", seconds: s) }
        // 只留最近 5 次：[10,10,10,40,40] → 均值 22
        XCTAssertEqual(stats.estimate(for: "m"), 22)
    }

    func testStatsInvalidInputIgnored() {
        let stats = isolatedStats()
        stats.record(model: "", seconds: 5)
        stats.record(model: "m", seconds: -3)
        XCTAssertNil(stats.estimate(for: ""))
        XCTAssertNil(stats.estimate(for: "m"))
    }

    func testStatsPerModelIsolation() {
        let stats = isolatedStats()
        stats.record(model: "a", seconds: 10)
        XCTAssertNil(stats.estimate(for: "b"))
        XCTAssertEqual(stats.estimate(for: "a"), 10)
    }

    // MARK: - VM 集成（脚本化 SSE）

    private func bootedVM(_ client: ChatMockClient,
                          stats: FirstTokenStats) async throws -> ChatViewModel {
        let appState = TestRuntimeSupport.makeAppState(client: client)
        // 0.7.6 实测 Bug1 新口径：无 pilot 播种——上下文 = 用户选中态，测试显式预置
        appState.currentProjectId = "p1"
        appState.currentAgentId = "a1"
        let vm = ChatViewModel(appState: appState, firstTokenStats: stats)
        // runtime init 同步点亮 nativeReady → sink 触发 bootstrap，稍候即完成
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertTrue(vm.bootstrapped, "bootstrap 未完成")
        return vm
    }

    /// 无任何流事件 → 保持装载/装填段（无信号不造假翻阶段）；无样本不显示预估
    func testStageStaysLoadingWithoutEvents() async throws {
        let client = ChatMockClient()
        client.streamEvents = []
        client.streamNeverEnds = true
        let vm = try await bootedVM(client, stats: isolatedStats())
        vm.input = "hi"
        vm.send()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(vm.waitStage, .loading)
        XCTAssertNil(vm.waitEstimate)
    }

    /// thinking delta（真实信号：prefill 完成、生成开始）→ 阶段翻「生成中」
    func testStageGeneratingOnThinking() async throws {
        let client = ChatMockClient()
        client.streamEvents = [ev("thinking", ["delta": "先想想"])]
        client.streamNeverEnds = true
        let vm = try await bootedVM(client, stats: isolatedStats())
        vm.input = "hi"
        vm.send()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(vm.waitStage, .generating)
    }

    /// 首个正文 token → 记样本（下轮同模型预估就位）
    func testFirstTokenRecordsSample() async throws {
        let stats = isolatedStats()
        let client = ChatMockClient()
        client.streamEvents = [ev("token", ["delta": "答"]), ev("done", ["content": "答"])]
        let vm = try await bootedVM(client, stats: stats)
        vm.input = "hi"
        vm.send()
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertNotNil(stats.estimate(for: "qwen3.8"), "首 token 耗时应已记录")
    }

    /// 预置样本 → 发送即显示预估
    func testEstimatePresentWithSamples() async throws {
        let stats = isolatedStats()
        stats.record(model: "qwen3.8", seconds: 20)
        stats.record(model: "qwen3.8", seconds: 24)
        let client = ChatMockClient()
        client.streamEvents = []
        client.streamNeverEnds = true
        let vm = try await bootedVM(client, stats: stats)
        vm.input = "hi"
        vm.send()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(vm.waitEstimate, 22)
        XCTAssertEqual(vm.waitStage, .loading)
    }
}
