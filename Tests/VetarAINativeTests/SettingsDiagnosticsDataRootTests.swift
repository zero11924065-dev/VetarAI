//
//  SettingsDiagnosticsDataRootTests.swift
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

//  业主拍板（2026-10-01）：数据根路径与编辑框属开发者级信息，不对用户展示，
//  也不提供修改入口；文案只保留风险提示。本套件源码扫描钉桩防回归：
//    · 编辑框与其 AX id（about.dataRootField）不得回到用户面板
//    · 风险提示文案必须保留（核心数据不是缓存）
//    · 日志/数据根目录打开入口保留（售后与排查通道不丢）
//  修改通道本身不删：UserDefaults 键 sidecar.dataRoot / 命令行 -sidecar.dataRoot
//  注入（NativeRuntime），已持久化的自定义值不受影响。
//

import XCTest

final class SettingsDiagnosticsDataRootTests: XCTestCase {

    private func settingsPanelSource() throws -> String {
        let url = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent()   // VetarAINativeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo>
            .appendingPathComponent("Sources/VetarAINative/Panels/Settings/SettingsPanelView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// 数据根编辑框与其 AX id 不得回到用户面板（回归钉桩）。
    /// 扫描只认代码行——注释中的历史留痕（如移除说明里提到原 id）不计。
    func testDataRootFieldRemoved() throws {
        let code = try settingsPanelSource()
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertFalse(code.contains("about.dataRootField"),
                       "数据根编辑框 AX id 不得回到用户面板（1.0.1 业主拍板隐藏）")
        XCTAssertFalse(code.contains("TextField(\"VETARAI_DATA_ROOT\""),
                       "数据根编辑框不得回到用户面板（修改通道走 sidecar.dataRoot 键/命令行注入）")
        // 数据根区块标题也不应再出现（整段收拢）
        XCTAssertFalse(code.contains("FormLabel(\"数据根\")"),
                       "数据根区块标题应随编辑框一并收拢")
    }

    /// 风险提示文案必须保留（用户唯一需要知道的一句）。
    /// 方向2 波次2：⚠️ emoji 已升 VCallout(.warn) 图标承载，断言同步收编为
    /// 无 emoji 文案主体（警示语义不变——文案仍在且警示层级反升）。
    func testWarningHintRetained() throws {
        let text = try settingsPanelSource()
        XCTAssertTrue(text.contains("这里是核心数据不是缓存，删除会丢失项目、会话与知识库，请勿随意清理。"),
                      "数据根风险提示文案必须保留")
    }

    /// 目录打开入口保留（售后/排查通道）。
    func testDirectoryButtonsRetained() throws {
        let text = try settingsPanelSource()
        XCTAssertTrue(text.contains("about.openLogsButton"), "打开日志目录入口必须保留")
        XCTAssertTrue(text.contains("about.openDataRootButton"), "打开数据根目录入口必须保留")
    }
}
