//
//  ChatAdoptModelDBG198Tests.swift
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

//  背景：独立 Agent / 项目 Agent 创建时绑定的模型（model_name）此前只有委派和
//  圆桌路径消费；会话窗口头部显示与发送链路都走 ChatViewModel.selectedModel，
//  而 adoptContext 只同步 agentName → 绑定模型不进会话（头部显示回落模型）。
//
//  覆盖（两分支同口径）：
//    · 独立 Agent：绑定非空 → selectedModel 采纳原值（不在 models 列表也采纳，
//      不静默回落）；nil / 空白 → 保持进入前值不动
//    · 项目 Agent：有绑定采纳 / 无绑定不动；只选项目落主 Agent 后同口径
//    · vmodel: 前缀绑定原样采纳（直通既有路由，不改写）
//    · agent:updated 总线刷新（refreshCurrentAgentInfo）只更新名称——
//      用户会话内手选模型不被盖回
//    · AppState 共享态写入 → externalContextChanged → switchContext 同口径采纳
//

import XCTest
@testable import VetarAINative

@MainActor
final class ChatAdoptModelDBG198Tests: XCTestCase {

    /// 同 ChatWaitStageW10Tests.bootedVM 模式：预置 AppState 选中态 → bootstrap 采纳上下文
    private func bootedVM(_ client: ChatMockClient,
                          projectId: String, agentId: String?,
                          file: StaticString = #filePath, line: UInt = #line) async throws -> ChatViewModel {
        let appState = TestRuntimeSupport.makeAppState(client: client)
        appState.currentProjectId = projectId
        appState.currentAgentId = agentId
        let vm = ChatViewModel(appState: appState)
        // runtime init 同步点亮 nativeReady → sink 触发 bootstrap，稍候即完成
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertTrue(vm.bootstrapped, "bootstrap 未完成", file: file, line: line)
        return vm
    }

    private func agent(_ id: String, _ name: String, type: String = "main",
                       model: String? = nil) -> SidecarAgent {
        SidecarAgent(id: id, name: name, type_: type, model_name: model,
                     role: nil, parent_agent_id: nil, system_prompt: nil)
    }

    // MARK: - 独立 Agent 分支

    /// 钉桩①：绑定 qwen3.6:35b（不在 models 列表）→ 采纳原值（业主报障场景）
    func testIndependentAgentBoundModelAdopted() async throws {
        let client = ChatMockClient()
        client.modelList = [OllamaModel(name: "qwen3:14b", size: nil)]
        client.independentAgents = [
            IndependentAgent(id: "ia1", name: "小助手", model_name: "qwen3.6:35b"),
        ]
        let vm = try await bootedVM(client, projectId: "ia-ia1", agentId: "ia1")
        XCTAssertEqual(vm.agentName, "小助手")
        XCTAssertEqual(vm.selectedModel, "qwen3.6:35b",
                       "DBG-198：绑定模型须采纳原值——即便不在 models 列表也不静默回落")
    }

    /// 钉桩②a：model_name 为 nil → selectedModel 保持进入前值（bootstrap 回落列表首项）
    func testIndependentAgentNilModelKeepsSelection() async throws {
        let client = ChatMockClient()
        client.modelList = [OllamaModel(name: "qwen3:14b", size: nil)]
        client.independentAgents = [IndependentAgent(id: "ia1", name: "无绑定")]
        let vm = try await bootedVM(client, projectId: "ia-ia1", agentId: "ia1")
        XCTAssertEqual(vm.selectedModel, "qwen3:14b",
                       "nil 绑定不得动 selectedModel（保持进入前的回落值）")
    }

    /// 钉桩②b：model_name 为空白串 → 同 nil 口径不动（trim 后为空视为无绑定）
    func testIndependentAgentBlankModelKeepsSelection() async throws {
        let client = ChatMockClient()
        client.modelList = [OllamaModel(name: "qwen3:14b", size: nil)]
        client.independentAgents = [IndependentAgent(id: "ia1", name: "空白绑定", model_name: "   ")]
        let vm = try await bootedVM(client, projectId: "ia-ia1", agentId: "ia1")
        XCTAssertEqual(vm.selectedModel, "qwen3:14b",
                       "空白绑定（trim 后为空）不得动 selectedModel")
    }

    // MARK: - 项目 Agent 分支（同口径）

    /// 钉桩③a：项目 Agent 有绑定 → 采纳原值
    func testProjectAgentBoundModelAdopted() async throws {
        let client = ChatMockClient()
        client.modelList = [OllamaModel(name: "qwen3:14b", size: nil)]
        client.agentList = [agent("a1", "主力", model: "deepseek-r1:14b")]
        let vm = try await bootedVM(client, projectId: "p1", agentId: "a1")
        XCTAssertEqual(vm.agentName, "主力")
        XCTAssertEqual(vm.selectedModel, "deepseek-r1:14b",
                       "DBG-198：项目 Agent 绑定模型同口径采纳原值")
    }

    /// 钉桩③b：项目 Agent 无绑定 → selectedModel 保持进入前值
    func testProjectAgentNilModelKeepsSelection() async throws {
        let client = ChatMockClient()
        client.modelList = [OllamaModel(name: "qwen3:14b", size: nil)]
        client.agentList = [agent("a1", "无绑定")]
        let vm = try await bootedVM(client, projectId: "p1", agentId: "a1")
        XCTAssertEqual(vm.selectedModel, "qwen3:14b",
                       "项目 Agent 无绑定不得动 selectedModel")
    }

    /// 钉桩③c：只选项目（agentId=nil）→ 落主 Agent → 采纳其绑定（规范化 aid 路径）
    func testProjectOnlySelectionAdoptsMainAgentBinding() async throws {
        let client = ChatMockClient()
        client.modelList = [OllamaModel(name: "qwen3:14b", size: nil)]
        client.agentList = [
            agent("a9", "普通", type: "sub"),
            agent("a1", "主 Agent", model: "qwen3.6:35b"),
        ]
        let vm = try await bootedVM(client, projectId: "p1", agentId: nil)
        XCTAssertEqual(vm.agentName, "主 Agent")
        XCTAssertEqual(vm.selectedModel, "qwen3.6:35b",
                       "落主 Agent 后同口径采纳其绑定模型")
    }

    // MARK: - vmodel: 前缀直通

    /// 钉桩⑤：vmodel: 前缀绑定值原样采纳（不改写，直通既有 vmodel 路由）
    func testVModelPrefixBindingAdoptedVerbatim() async throws {
        let client = ChatMockClient()
        client.modelList = [OllamaModel(name: "qwen3:14b", size: nil)]
        client.independentAgents = [
            IndependentAgent(id: "ia1", name: "虚拟模型", model_name: "vmodel:my-pack"),
        ]
        let vm = try await bootedVM(client, projectId: "ia-ia1", agentId: "ia1")
        XCTAssertEqual(vm.selectedModel, "vmodel:my-pack",
                       "vmodel: 前缀绑定须原样采纳（不改写、不截断）")
    }

    // MARK: - agent:updated 总线刷新不盖回手选

    /// 钉桩④：用户会话内手选模型后，agent:updated 刷新只更新名称——selectedModel 不动
    func testAgentUpdatedRefreshDoesNotOverrideManualSelection() async throws {
        let client = ChatMockClient()
        client.modelList = [OllamaModel(name: "qwen3:14b", size: nil)]
        client.independentAgents = [
            IndependentAgent(id: "ia1", name: "小助手", model_name: "qwen3.6:35b"),
        ]
        let vm = try await bootedVM(client, projectId: "ia-ia1", agentId: "ia1")
        XCTAssertEqual(vm.selectedModel, "qwen3.6:35b")

        // 用户会话内手选（对齐 ChatPanel 模型下拉直写 selectedModel 的既有测试口径）
        vm.selectedModel = "qwen3:14b"
        try await Task.sleep(nanoseconds: 100_000_000)

        // 他面板行内改名 → 广播 agent:updated（W6 总线口径，载荷指向当前 Agent）
        client.independentAgents = [
            IndependentAgent(id: "ia1", name: "改名了", model_name: "qwen3.6:35b"),
        ]
        NativeAppEvents.notify(NativeAppEvents.resourceAgent, NativeAppEvents.actionUpdate,
                               projectId: "ia-ia1", extra: ["agent_id": .string("ia1")])
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(vm.agentName, "改名了", "agent:updated 应刷新名称（证明刷新确实发生）")
        XCTAssertEqual(vm.selectedModel, "qwen3:14b",
                       "DBG-198 边界：agent:updated 刷新不得盖回用户手选模型")
    }

    // MARK: - 切换路径（externalContextChanged → switchContext）同口径

    /// 钉桩⑥：bootstrap 之外的日常路径——他面板写 AppState 共享态 →
    /// 会话面板跟随切换 → adoptContext 同口径采纳绑定模型
    func testContextSwitchViaAppStateAdoptsBinding() async throws {
        let client = ChatMockClient()
        client.modelList = [OllamaModel(name: "qwen3:14b", size: nil)]
        client.agentList = [agent("a1", "项目Agent")]
        client.independentAgents = [
            IndependentAgent(id: "ia1", name: "小助手", model_name: "qwen3.6:35b"),
        ]
        let vm = try await bootedVM(client, projectId: "p1", agentId: "a1")
        XCTAssertEqual(vm.selectedModel, "qwen3:14b")   // 项目 Agent 无绑定 → 保持回落值

        // 他面板选中独立 Agent → 共享态写入（防抖 60ms 合并为一次切换）
        vm.appState.currentProjectId = "ia-ia1"
        vm.appState.currentAgentId = "ia1"
        try await Task.sleep(nanoseconds: 800_000_000)

        XCTAssertEqual(vm.agentName, "小助手")
        XCTAssertEqual(vm.selectedModel, "qwen3.6:35b",
                       "切换上下文同口径采纳绑定模型（bootstrap 之外的日常路径）")
    }
}
