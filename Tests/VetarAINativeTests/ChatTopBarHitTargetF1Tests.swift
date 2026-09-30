//
//  ChatTopBarHitTargetF1Tests.swift
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

//  真因（0.7.13 运行中应用 AX 命中取证）：本环境自定义 ButtonStyle 的
//  padding/frame 只进布局、不进命中区——按钮命中区 = label 本体框架。
//  顶栏三图标钮命中带实测：✓ 13×13 / ⛁ 11×14 / ⋯ 12×2.5——ellipsis 字形
//  razor-thin，±3pt 瞄准误差即落空（命中底层纯容器 AXGroup），表现为
//  「更多菜单完全点不开」。修法：label 内扩 22×22 + contentShape(Rectangle())
//  （vIconHitTarget），命中区 = 22×22；布局行高不变（22 ≤ vGhost 布局高 28）。
//

import XCTest
@testable import VetarAINative

final class ChatTopBarHitTargetF1Tests: XCTestCase {

    /// 命中目标边长上下限：下限 20（macOS 指针精度实践底线，低于此人手难命中）；
    /// 上限 28（≤ vGhost 布局高，防撑高顶栏行）。
    func testIconHitTargetWithinBounds() {
        XCTAssertGreaterThanOrEqual(ChatTopBarSpec.iconHitTarget, 20,
                                    "命中目标不得低于 macOS 指针精度底线（⋯12×2.5 教训）")
        XCTAssertLessThanOrEqual(ChatTopBarSpec.iconHitTarget, 28,
                                 "命中目标不得超 vGhost 布局高 28，防撑行")
    }

    /// 源码扫描钉桩：顶栏三图标钮（✓ 勾选 / ⛁ 仓库 / ⋯ 更多）label 必须挂
    /// vIconHitTarget——任一被改回裸 Image 即 razor-thin 回归。
    func testTopBarIconButtonsCarryHitTarget() throws {
        let url = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent()   // VetarAINativeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo>
            .appendingPathComponent("Sources/VetarAINative/Panels/Chat/ChatPanelView.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.components(separatedBy: "\n")
        for axid in ["selectModeButton", "warehouseToggle", "moreMenuButton"] {
            guard let idx = lines.firstIndex(where: {
                $0.contains(".accessibilityIdentifier(\"\(axid)\")")
            }) else {
                XCTFail("顶栏按钮 \(axid) 未找到"); continue
            }
            let lo = max(0, idx - 8)
            let window = lines[lo...idx].joined(separator: "\n")
            XCTAssertTrue(window.contains(".vIconHitTarget("),
                          "顶栏按钮 \(axid) label 未挂 vIconHitTarget——razor-thin 回归")
        }
    }

    /// 布局宽估一致性：buttonIdealWidth 须 = iconHitTarget + vGhost 横 padding 20
    ///（右组分配逻辑按足额扣减，估小则窄窗下按钮区实宽超估、指示器被多裁）。
    func testButtonIdealWidthMatchesHitTargetPlusPadding() {
        XCTAssertEqual(ChatTopBarLayout.buttonIdealWidth, ChatTopBarSpec.iconHitTarget + 20,
                       "按钮理想宽估须随命中目标同步（label 22 + 横 padding 20 = 42）")
    }
}
