//
//  P3W1aReadinessTests.swift
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

//  P3-W6 改写口径：SidecarManager/nativeKernelEnabled 开关/HTTP fallback 均已退役，
//  原「内核开+侧车缺席」「内核关门不变」双态随被测类型一同消亡。保留并改写：
//    · NativeRuntime 恒原生就绪：init 同步点亮 nativeReady + client 恒
//      NativeSidecarClient（旧 nativeKernel.enabled=NO 残留仅记日志忽略）
//    · 会话面板 bootstrap：runtime 直注 mock 客户端 → 引导即完成（旧「内核关+
//      侧车 down 不引导」负分支随开关消亡）
//    · 项目 / 独立 Agent 面板：runtime 数据根预置数据 → 首拉即中（旧「client
//      缺席→点亮补拉」两段式随同步 init 消亡——nativeReady 先于 VM 挂载点亮）
//    · listModels 原生分支：ollama 原生名单直答 / 空名单直返空（P3-W6 起与侧车
//      代理同源，无 HTTP 兜底）/ 非 ollama 后端直返空（旧转发 HTTP 消亡）
//
//  全程 mktemp 数据根。
//

import XCTest
@testable import VetarAINative

@MainActor
final class P3W1aReadinessTests: XCTestCase {

    private var base: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3w1a_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
        base = nil
        try super.tearDownWithError()
    }

    private func waitUntil(_ cond: @escaping @MainActor () -> Bool,
                           timeoutMs: UInt64 = 3000) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return cond()
    }

    /// 数据根落本用例临时目录的 defaults（防污染真实数据根）。
    private func makeDefaults(legacySwitch: Bool? = nil) -> UserDefaults {
        let d = UserDefaults(suiteName: "vetarai-test-\(UUID().uuidString)")!
        d.set(base.appendingPathComponent("data-root-\(UUID().uuidString)").path,
              forKey: NativeRuntime.Keys.dataRoot)
        if let legacySwitch {
            d.set(legacySwitch, forKey: NativeRuntime.Keys.legacyNativeKernel)
        }
        return d
    }

    // ══ ① NativeRuntime 恒原生就绪 ══

    /// init 同步就绪：nativeReady 点亮、client 恒为 NativeSidecarClient
    /// （历史对应「内核开+侧车缺席 → nativeReady=true」；侧车归零后无缺席态）。
    func testRuntimeReadySynchronously() {
        let rt = NativeRuntime(defaults: makeDefaults(), logger: TestRuntimeSupport.makeLogger())
        XCTAssertTrue(rt.nativeReady)
        XCTAssertTrue(rt.client is NativeSidecarClient)
    }

    /// 旧 nativeKernel.enabled=NO 残留：记日志忽略，恒原生不回头
    /// （历史对应「内核关 → nativeReady 恒 false」负分支——开关废除后消亡）。
    func testLegacyNativeKernelSwitchIgnored() {
        let rt = NativeRuntime(defaults: makeDefaults(legacySwitch: false),
                               logger: TestRuntimeSupport.makeLogger())
        XCTAssertTrue(rt.nativeReady, "旧开关 NO 仅记日志忽略，恒原生")
        XCTAssertTrue(rt.client is NativeSidecarClient)
    }

    // ══ ② 会话面板：bootstrap 即完成 ══

    /// runtime 直注 mock 客户端 → bootstrap 完成（历史「内核开+侧车 down」场景的
    /// 承接：侧车归零后客户端恒在，引导无阻塞路径）。
    /// 0.7.6 实测 Bug1 新口径：无任何选择时**不播种**——引导完成但不建任何
    /// 项目/Agent/会话（原 pilot 默认上下文复活链已拔除；RootView 在
    /// currentProjectId==nil 时有「开始对话」引导空态兜底）。
    func testChatBootstrapProceeds() async throws {
        let appState = TestRuntimeSupport.makeAppState(client: MockSidecarClient())
        let vm = ChatViewModel(appState: appState)
        let ok = await waitUntil { vm.bootstrapped }
        XCTAssertTrue(ok, "nativeReady 同步点亮 → 会话面板引导即完成")
        XCTAssertNil(vm.currentSessionId, "无选择不播种：无初始会话")
        XCTAssertNil(vm.projectId, "无选择不播种：无项目上下文")
        XCTAssertNil(appState.currentProjectId, "无选择不播种：不回写 AppState 选中态")
    }

    // ══ ③ 项目 / 独立 Agent 面板：首拉即中 ══

    /// 项目面板：runtime 数据根预置数据 → 首拉即中（历史「nativeReady 点亮补拉」
    /// 的承接——同步 init 后点亮先于 VM 挂载，退避链不再全败）。
    func testProjectPanelLoadsOnStart() async throws {
        let root = base.appendingPathComponent("data-root-proj")
        let seed = NativeKernel(dataRoot: root)
        let pid = try seed.database.createProject(name: "预置项目", workingDir: base.path)

        let d = UserDefaults(suiteName: "vetarai-test-\(UUID().uuidString)")!
        d.set(root.path, forKey: NativeRuntime.Keys.dataRoot)
        let appState = AppState(defaults: d, logger: TestRuntimeSupport.makeLogger(),
                                runtime: NativeRuntime(defaults: d,
                                                       logger: TestRuntimeSupport.makeLogger()),
                                agreement: TestRuntimeSupport.makeIsolatedAgreement())
        let vm = ProjectPanelViewModel(appState: appState, retryDelays: [0, 0.05])
        vm.start()
        let ok = await waitUntil { vm.error == nil && vm.projects.count == 1 }
        XCTAssertTrue(ok, "client 恒在 → 项目面板首拉即中")
        XCTAssertEqual(vm.projects.first?.id, pid)
    }

    /// 独立 Agent 面板同口径：首拉命中预置数据。
    func testIndependentAgentsPanelLoadsOnStart() async throws {
        let root = base.appendingPathComponent("data-root-ia")
        let seed = NativeKernel(dataRoot: root)
        let aid = try seed.database.addIndependentAgent(name: "预置独立")

        let d = UserDefaults(suiteName: "vetarai-test-\(UUID().uuidString)")!
        d.set(root.path, forKey: NativeRuntime.Keys.dataRoot)
        let appState = AppState(defaults: d, logger: TestRuntimeSupport.makeLogger(),
                                runtime: NativeRuntime(defaults: d,
                                                       logger: TestRuntimeSupport.makeLogger()),
                                agreement: TestRuntimeSupport.makeIsolatedAgreement())
        let vm = IndependentAgentsPanelViewModel(appState: appState)
        vm.start()
        let ok = await waitUntil { vm.agents.count == 1 }
        XCTAssertTrue(ok, "client 恒在 → 独立 Agent 面板首拉即中")
        XCTAssertEqual(vm.agents.first?.id, aid)
    }
}

// MARK: - P3-W1 listModels 原生分支（P3-W6 口径：无 HTTP 兜底层）

@MainActor
final class P3W1ListModelsTests: XCTestCase {

    private var base: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3w1lm_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
        base = nil
        try super.tearDownWithError()
    }

    /// ollama 后端：原生 /api/tags 名单非空 → 直接答。
    func testOllamaBackendReadsNativeTags() async throws {
        let kernel = NativeKernel(dataRoot: base.appendingPathComponent("d1"))
        let client = NativeSidecarClient(kernel: kernel)
        client.ollamaTagsFetcher = { _ in ["qwen3.8", "qwen3-vl:8b"] }
        let models = try await client.listModels()
        XCTAssertEqual(models.map(\.name), ["qwen3.8", "qwen3-vl:8b"])
    }

    /// ollama 后端但原生名单空（ollama 未运行等）→ 直返空（P3-W6：与侧车代理
    /// 同源——历史「回退 HTTP 保旧口径」分支随 fallback 层删除消亡）。
    func testOllamaEmptyTagsReturnsEmpty() async throws {
        let kernel = NativeKernel(dataRoot: base.appendingPathComponent("d2"))
        let client = NativeSidecarClient(kernel: kernel)
        client.ollamaTagsFetcher = { _ in [] }
        let models = try await client.listModels()
        XCTAssertEqual(models, [])
    }

    /// 非 ollama 后端：不得走原生名单，直返空（历史「全量转发 HTTP」消亡——
    /// openai_compatible 后端模型面归设置页 inference 端点，不属本清单口径）。
    func testNonOllamaBackendReturnsEmpty() async throws {
        let kernel = NativeKernel(dataRoot: base.appendingPathComponent("d3"))
        _ = try kernel.config.reloadConfig(patch: [
            "inference_backend": .string("openai_compatible"),
            "inference_base_url": .string("http://127.0.0.1:1/v1"),
        ])
        let client = NativeSidecarClient(kernel: kernel)
        client.ollamaTagsFetcher = { _ in
            XCTFail("非 ollama 后端不得走原生名单")
            return []
        }
        let models = try await client.listModels()
        XCTAssertEqual(models, [])
    }
}
