//
//  ModelIdentityTests.swift
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
//    · ModelIdentity 归一化全用例（":latest" 互认 / 带 tag 不动 / 注册表路径
//      不误判 / 端口 ":" 不算 tag / 大小写口径与全仓一致=精确）
//    · 四处接入点：
//      ① 默认模型 Picker 可用性（SettingsPanelView 基础区）
//      ② 报错分析模型 Picker 可用性（SettingsPanelView 报错分析区）
//      ③ 模型特长 isStale（SettingsPanelView 模型特长区）
//      ④ ChatViewModel bootstrap（归一化命中保留用户原值；真不可用才回退）
//    · 默认模型不可用指引文案三分支（defaultModelUnavailableHint）
//

import XCTest
@testable import VetarAINative

// MARK: - 归一化全用例

final class ModelIdentityTests: XCTestCase {

    func testLatestTagMutualRecognition() {
        // 核心假阳性场景：存储 "qwen3.8" vs 列表 "qwen3.8:latest"（双向互认）
        XCTAssertTrue(ModelIdentity.sameModel("qwen3.8", "qwen3.8:latest"))
        XCTAssertTrue(ModelIdentity.sameModel("qwen3.8:latest", "qwen3.8"))
        XCTAssertEqual(ModelIdentity.canonical("qwen3.8"), "qwen3.8:latest")
        XCTAssertEqual(ModelIdentity.canonical("qwen3.8:latest"), "qwen3.8:latest")
    }

    func testExplicitTagUntouched() {
        // 带 tag 不动：同 tag 命中，异 tag 即不同模型（严格口径，不跨 tag 容错）
        XCTAssertEqual(ModelIdentity.canonical("qwen3-vl:8b"), "qwen3-vl:8b")
        XCTAssertTrue(ModelIdentity.sameModel("qwen3-vl:8b", "qwen3-vl:8b"))
        XCTAssertFalse(ModelIdentity.sameModel("qwen3-vl:8b", "qwen3-vl:13b"))
        XCTAssertFalse(ModelIdentity.sameModel("qwen3-vl:8b", "qwen3-vl"))
        XCTAssertFalse(ModelIdentity.sameModel("qwen3-vl:8b", "qwen3-vl:latest"))
    }

    func testRegistryPathNotMistaken() {
        // 魔塔/注册表路径："/" 不干扰 ":latest" 归一
        XCTAssertTrue(ModelIdentity.sameModel("qwen/Qwen3-8B", "qwen/Qwen3-8B:latest"))
        XCTAssertEqual(ModelIdentity.canonical("qwen/Qwen3-8B"), "qwen/Qwen3-8B:latest")
        // ":" 在最后一个 "/" 之后 → 是 tag（hf.co/x/y:q4 ≠ hf.co/x/y[:latest]）
        XCTAssertEqual(ModelIdentity.canonical("hf.co/x/y:q4"), "hf.co/x/y:q4")
        XCTAssertFalse(ModelIdentity.sameModel("hf.co/x/y:q4", "hf.co/x/y"))
        XCTAssertFalse(ModelIdentity.sameModel("hf.co/x/y:q4", "hf.co/x/y:latest"))
        XCTAssertTrue(ModelIdentity.sameModel("hf.co/x/y:q4", "hf.co/x/y:q4"))
    }

    func testPortColonIsNotTag() {
        // ":" 在最后一个 "/" 之前 → 注册表主机端口，不算 tag
        XCTAssertTrue(ModelIdentity.sameModel("hf.co:8080/x/y", "hf.co:8080/x/y:latest"))
        XCTAssertEqual(ModelIdentity.canonical("hf.co:8080/x/y"), "hf.co:8080/x/y:latest")
        XCTAssertFalse(ModelIdentity.sameModel("hf.co:8080/x/y:q4", "hf.co:8080/x/y:latest"))
    }

    func testCaseSensitivityMatchesRepoConvention() {
        // 大小写口径 = 精确（与全仓现存比较、NativeDelegation 校验一致：
        // ollama 返回名原样入列、配置原样存储，不做大小写折叠）
        XCTAssertFalse(ModelIdentity.sameModel("Qwen3.8", "qwen3.8:latest"))
        XCTAssertFalse(ModelIdentity.sameModel("QWEN3-VL:8B", "qwen3-vl:8b"))
    }

    func testVModelPoolNames() {
        // vmodel:<slug> 池名：精确命中；slug 不同即不同（REQ-FUT-020 不错配）
        XCTAssertTrue(ModelIdentity.sameModel("vmodel:abc", "vmodel:abc"))
        XCTAssertFalse(ModelIdentity.sameModel("vmodel:abc", "vmodel:abd"))
        XCTAssertFalse(ModelIdentity.sameModel("vmodel:abc", "vmodel"))
    }

    func testIsAvailableInList() {
        let list = ["qwen3.8:latest", "qwen3-vl:8b", "glm-ocr:latest"]
        XCTAssertTrue(ModelIdentity.isAvailable("qwen3.8", in: list))        // 无 tag 命中 :latest
        XCTAssertTrue(ModelIdentity.isAvailable("qwen3.8:latest", in: list)) // 精确命中
        XCTAssertTrue(ModelIdentity.isAvailable("qwen3-vl:8b", in: list))
        XCTAssertFalse(ModelIdentity.isAvailable("qwen3-vl:13b", in: list))  // 异 tag 不命中
        XCTAssertFalse(ModelIdentity.isAvailable("deepseek-r1", in: list))
        XCTAssertFalse(ModelIdentity.isAvailable("qwen3.8", in: []))         // 空列表 → false
        XCTAssertFalse(ModelIdentity.isAvailable("", in: list))              // 空串不命中
    }
}

// MARK: - 接入点①②③：设置页三处判断（Picker 可用性 / isStale 共用 isAvailable 口径）

final class SettingsModelAvailabilityTests: XCTestCase {

    /// 接入点①：默认模型 Picker —— "qwen3.8" 不再被 "qwen3.8:latest" 误判「当前不可用」
    func testDefaultModelPickerAvailability() {
        let options = ["qwen3.8:latest", "qwen3-vl:8b"]
        // 归一化命中 → 不显示「（当前不可用）」标签（判断式同 SettingsPanelView 基础区）
        XCTAssertTrue(ModelIdentity.isAvailable("qwen3.8", in: options))
        // 真不可用 → 仍显示「（当前不可用）」标签
        XCTAssertFalse(ModelIdentity.isAvailable("qwen2.5:7b", in: options))
    }

    /// 接入点②：报错分析模型 Picker —— 同款判断同口径
    func testErrorAnalysisPickerAvailability() {
        let options = ["glm-ocr:latest"]
        XCTAssertTrue(ModelIdentity.isAvailable("glm-ocr", in: options))
        XCTAssertFalse(ModelIdentity.isAvailable("glm-ocr:9b", in: options))
    }

    /// 接入点③：模型特长 isStale —— 归一化命中不标「已不可用」；列表空不标（口径不变）
    func testModelStrengthsStalePredicate() {
        func isStale(_ model: String, options: [String]) -> Bool {
            !options.isEmpty && !ModelIdentity.isAvailable(model, in: options)
        }
        let options = ["qwen3.8:latest"]
        XCTAssertFalse(isStale("qwen3.8", options: options))     // 修复点：不再误标
        XCTAssertTrue(isStale("old-model:7b", options: options)) // 真移除仍标
        XCTAssertFalse(isStale("qwen3.8", options: []))          // 列表空 → 不标（原口径）
    }
}

// MARK: - 默认模型不可用指引文案（三分支）

final class DefaultModelUnavailableHintTests: XCTestCase {

    func testBranch1BackendDisconnected() {
        // ① 列表空（后端未连接/拉取失败）→ 连接指引
        let hint = defaultModelUnavailableHint(current: "qwen3.8", options: [], loading: false)
        XCTAssertEqual(hint, "当前无法连接推理后端，请确认后端已启动；恢复后该模型自动可用。")
    }

    func testBranch2ModelRemoved() {
        // ② 列表非空但归一化仍不命中 → 已移除指引（默认值保留、恢复自动生效）
        let hint = defaultModelUnavailableHint(
            current: "qwen3.8", options: ["qwen3-vl:8b"], loading: false)
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint!.contains("已不在本机可用列表中"))
        XCTAssertTrue(hint!.contains("重新拉取同名模型"))
        XCTAssertTrue(hint!.contains("当前默认值会保留"))
    }

    func testNoHintWhenAvailableOrLoadingOrEmpty() {
        // ③ 归一化命中（":latest" 互认）→ 不显示
        XCTAssertNil(defaultModelUnavailableHint(
            current: "qwen3.8", options: ["qwen3.8:latest"], loading: false))
        // 正在拉取 → 不显示（输入框已有「正在拉取可用模型…」占位）
        XCTAssertNil(defaultModelUnavailableHint(current: "qwen3.8", options: [], loading: true))
        // 当前值为空 → 不显示
        XCTAssertNil(defaultModelUnavailableHint(
            current: "", options: ["qwen3.8:latest"], loading: false))
    }
}

// MARK: - 接入点④：ChatViewModel bootstrap（VM 级）

@MainActor
final class ChatBootstrapModelIdentityTests: XCTestCase {

    /// 同 ChatViewModelIntegrationTests 的引导套路，但允许预置 selectedModel：
    /// init 后同步窗口内写入（nativeReady sink 已排队的 bootstrap Task 尚未落地）。
    private func bootstrappedVM(_ client: ChatMockClient,
                                preselectedModel: String?) async throws -> ChatViewModel {
        let appState = TestRuntimeSupport.makeAppState(client: client)
        appState.currentProjectId = "p1"
        appState.currentAgentId = "a1"
        let vm = ChatViewModel(appState: appState)
        if let preselectedModel { vm.selectedModel = preselectedModel }
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertTrue(vm.bootstrapped, "bootstrap 未完成")
        return vm
    }

    /// 归一化命中 → 保留用户原选择值（不改写、不静默换成列表名）
    func testBootstrapKeepsUserModelOnNormalizedMatch() async throws {
        let client = ChatMockClient()
        client.modelList = [OllamaModel(name: "qwen3.8:latest", size: nil),
                            OllamaModel(name: "qwen3-vl:8b", size: nil)]
        let vm = try await bootstrappedVM(client, preselectedModel: "qwen3.8")
        XCTAssertEqual(vm.selectedModel, "qwen3.8",
                       "归一化命中必须保留用户原值，不得静默换成列表名 qwen3.8:latest")
    }

    /// 真不可用（异 tag 也不命中）→ 回退列表第一个（原回退语义不变）
    func testBootstrapFallsBackWhenTrulyUnavailable() async throws {
        let client = ChatMockClient()
        client.modelList = [OllamaModel(name: "qwen3.8:latest", size: nil),
                            OllamaModel(name: "qwen3-vl:8b", size: nil)]
        let vm = try await bootstrappedVM(client, preselectedModel: "qwen3.8:8b")
        XCTAssertEqual(vm.selectedModel, "qwen3.8:latest")
    }

    /// 未预选 → 回退列表第一个（原语义不变）
    func testBootstrapDefaultsToFirstWhenNothingSelected() async throws {
        let client = ChatMockClient()
        client.modelList = [OllamaModel(name: "qwen3-vl:8b", size: nil)]
        let vm = try await bootstrappedVM(client, preselectedModel: nil)
        XCTAssertEqual(vm.selectedModel, "qwen3-vl:8b")
    }
}
