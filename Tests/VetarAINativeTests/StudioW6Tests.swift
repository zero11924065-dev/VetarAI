//
//  StudioW6Tests.swift
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

//  业主原话（2026-09-22）：「启动直进工作室且回不去，默认页应为智能中心」
//  「这是重复错误，之前就提到过。背景文字应当在我输入开始的那一刻就消失，一起修复。」
//
//  覆盖：
//  ① 启动恢复集合排除工作室——上次退出停在工作室也恒落智能中心聊天主页，
//     且 didSet 回写 UserDefaults 自愈；其余模块记忆恢复口径不变。
//  ② 工作室进出切换——rail 点击语义（selectPanel 组默认面板）双向落点正确，
//     竖条常驻由 RootView 布局保证（竖条无条件挂载，见 RootView 注释红线）。
//  ③ 占位文字即输即消——showsPlaceholder 纯逻辑：聚焦即消（IME 组字不落
//     binding 的重复错误根治），非空即消。
//

import XCTest
@testable import VetarAINative

@MainActor
final class StudioW6Tests: XCTestCase {

    private func makeAppState(panelKey: String? = nil, moduleKey: String? = nil)
        -> (AppState, UserDefaults) {
        let suite = "vetarai-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        if let panelKey { defaults.set(panelKey, forKey: "ui.panel") }
        if let moduleKey { defaults.set(moduleKey, forKey: "ui.module") }
        return (TestRuntimeSupport.makeAppState(client: LinkageMockClient(), defaults: defaults),
                defaults)
    }

    // MARK: - ① 启动默认面板 = 智能中心（恢复集合排除工作室）

    func testFreshLaunchLandsIntelligence() {
        let (appState, _) = makeAppState()
        XCTAssertEqual(appState.selectedModule, .intelligence)
        XCTAssertEqual(appState.selectedPanel.key, "chat")
    }

    func testStudioMemoryNotRestored() {
        // 上次退出停在工作室（ui.module=studio + ui.panel=studio）→ 恒落智能中心
        let (appState, defaults) = makeAppState(panelKey: "studio", moduleKey: "studio")
        XCTAssertEqual(appState.selectedModule, .intelligence,
                       "P0：启动恢复集合排除工作室")
        XCTAssertEqual(appState.selectedPanel.key, "chat")
        // didSet 回写自愈——下次启动不再命中 studio 键
        XCTAssertEqual(defaults.string(forKey: "ui.module"), "intelligence")
        XCTAssertEqual(defaults.string(forKey: "ui.panel"), "chat")
    }

    func testStudioModuleKeyOnlyNotRestored() {
        // 只有模块键是 studio（面板键缺失）→ defaultPanel(in: .studio) 也被排除
        let (appState, _) = makeAppState(moduleKey: "studio")
        XCTAssertEqual(appState.selectedModule, .intelligence)
        XCTAssertEqual(appState.selectedPanel.key, "chat")
    }

    func testStudioPanelKeyOnlyNotRestored() {
        // 只有面板键是 studio（模块键缺失/正常）→ 同样排除
        let (appState, _) = makeAppState(panelKey: "studio", moduleKey: "intelligence")
        XCTAssertEqual(appState.selectedModule, .intelligence)
        XCTAssertEqual(appState.selectedPanel.key, "chat")
    }

    func testWorkflowMemoryStillRestored() {
        // 非工作室模块的记忆恢复口径不变（排除集合只含 studio）
        let (appState, _) = makeAppState(panelKey: "workflows", moduleKey: "workflow")
        XCTAssertEqual(appState.selectedModule, .workflow)
        XCTAssertEqual(appState.selectedPanel.key, "workflows")
    }

    // MARK: - ② 工作室进出切换（rail 点击语义）

    func testStudioInOutSwitch() {
        let (appState, _) = makeAppState()
        // 进：点竖条工作室钮 = selectPanel(defaultPanel(in: .studio))
        appState.selectPanel(PanelRegistry.defaultPanel(in: .studio))
        XCTAssertEqual(appState.selectedModule, .studio)
        XCTAssertEqual(appState.selectedPanel.key, "studio")
        // 出：点竖条智能中心钮 = selectPanel(defaultPanel(in: .intelligence))
        appState.selectPanel(PanelRegistry.defaultPanel(in: .intelligence))
        XCTAssertEqual(appState.selectedModule, .intelligence)
        XCTAssertEqual(appState.selectedPanel.key, "chat")
        // 再进出流程中心也正常（三模块互切无锁死）
        appState.selectPanel(PanelRegistry.defaultPanel(in: .workflow))
        XCTAssertEqual(appState.selectedModule, .workflow)
        appState.selectPanel(PanelRegistry.defaultPanel(in: .intelligence))
        XCTAssertEqual(appState.selectedModule, .intelligence)
    }

    // MARK: - ③ 占位文字即输即消（内容口径，共享策略）

    func testPlaceholderFollowsContentRule() {
        // P0-C 根治口径（业主 2026-09-22：「背景文字应当在我输入开始的那一刻就消失」）：
        // 工作室需求框/添加便签/复审意见框 + 工作流编辑器 textArea 全部换装
        // VPlaceholderTextEditor，占位显隐复用 ComposerSyncPolicy.placeholderHidden——
        // 挂「内容」（含 IME marked text），不挂焦点，不看 isEmpty 单条件。
        // 空且无组字 → 显示；非空 → 消；组字中（绑定仍空）→ 也消（本次复发根治病灶）。
        XCTAssertFalse(ComposerSyncPolicy.placeholderHidden(viewString: "", hasMarkedText: false))
        XCTAssertTrue(ComposerSyncPolicy.placeholderHidden(viewString: "需", hasMarkedText: false))
        XCTAssertTrue(ComposerSyncPolicy.placeholderHidden(viewString: "", hasMarkedText: true))
        XCTAssertTrue(ComposerSyncPolicy.placeholderHidden(viewString: "n", hasMarkedText: true))
    }
}
