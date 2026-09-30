//
//  ChatTopBarR2Tests.swift
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

//  覆盖（用户实测反馈驱动：窗口拖窄时顶条右侧控件被挤出/文字截断看不见）：
//    · ChatTopBarSpec 常量逐字钉 0.4.x 口径（ChatPanel.tsx:2547-2657）——
//      徽章 minWidth:48 / 会话 select 80…180 / 模型名 maxWidth:140
//    · 红线回归：上下文指示器全文案 displayText 永不缩写（0.4.x 从不缩写）——
//      窄窗下文字要么完整显示，要么不存在截断版文案
//    · 失败态文案与正常态互不串味
//

import XCTest
@testable import VetarAINative

final class ChatTopBarR2Tests: XCTestCase {

    /// R2 规格常量钉死 0.4.x 口径（ChatPanel.tsx:2547-2657）：
    /// 徽章 flexShrink:1 minWidth:48 · select 容器 minWidth:0 maxWidth:180
    /// （select 自身 minWidth:80）· 模型名文本 maxWidth:140。
    func testTopBarSpecConstantsMatch04x() {
        XCTAssertEqual(ChatTopBarSpec.badgeMinWidth, 48,
                       "Agent 徽章最小宽 = 0.4.x minWidth:48")
        XCTAssertEqual(ChatTopBarSpec.sessionMinWidth, 80,
                       "会话 Picker 最小宽 = 0.4.x select minWidth:80")
        XCTAssertEqual(ChatTopBarSpec.sessionMaxWidth, 180,
                       "会话 Picker 最大宽 = 0.4.x 容器 maxWidth:180")
        XCTAssertEqual(ChatTopBarSpec.modelMaxWidth, 140,
                       "模型 Picker 最大宽 = 0.4.x 模型名 maxWidth:140")
        XCTAssertLessThan(ChatTopBarSpec.sessionMinWidth, ChatTopBarSpec.sessionMaxWidth)
    }

    /// 红线：上下文指示器全文案不缩写——懒加载档（ceiling>0）逐字 0.4.x 形态。
    /// 窄窗下该文案必须完整显示（右组 .fixedSize()），不允许出现截断版。
    func testContextIndicatorFullTextNeverAbbreviated() {
        var st = TokenIndicatorState()
        st.used = 12345
        st.limit = 128000
        st.ceiling = 200000
        XCTAssertEqual(st.displayText, "上下文 ≈12,345 / 200,000（当前档 128,000）",
                       "指示器文案逐字 0.4.x：≈used / ceiling（当前档 limit），无缩写形态")
    }

    /// 单值形态（无懒加载上限）：≈used / limit，无「当前档」尾巴。
    func testContextIndicatorSingleValueText() {
        var st = TokenIndicatorState()
        st.used = 3000
        st.limit = 128000
        XCTAssertEqual(st.displayText, "上下文 ≈3,000 / 128,000")
        XCTAssertNil(st.failedText, "正常态不得混入失败文案")
    }

    /// 失败态：limit==0 且 source==error → 「上下文：获取失败」，且不产生正常文案误导。
    func testContextIndicatorFailedText() {
        var st = TokenIndicatorState()
        st.source = "error"
        XCTAssertEqual(st.failedText, "上下文：获取失败")
        st.source = "ok"
        XCTAssertNil(st.failedText)
    }

    /// 补充三（0.7.6 实测）：⋯ 菜单 = 窗口内 overlay 下拉——右缘对齐顶栏右内边距，
    /// 约束永不越出应用窗口右缘（原 NSPopover 只避让屏幕边界不避让窗口边界）。
    func testMoreMenuSpecKeepsDropdownInsideWindow() {
        XCTAssertEqual(ChatMoreMenuSpec.menuWidth, 190, "菜单宽 = A12 既有 190 口径")
        XCTAssertEqual(ChatMoreMenuSpec.trailingInset, 12,
                       "右内边距 = 顶栏 horizontal padding，菜单右缘不越出窗口")
        XCTAssertEqual(ChatMoreMenuSpec.topOffset, 44, "贴顶栏下缘展开")
    }

    // MARK: - F1（0.7.12 实测修复）：右组宽度分配——按钮恒足额、指示器吸收压缩

    /// 宽窗：指示器拿足理想宽（零截断）——像素与旧布局一致，仅窄窗行为变化。
    func testLayoutWideWindowIndicatorGetsFullIdealWidth() {
        let w = ChatTopBarLayout.indicatorWidth(available: 500, indicatorIdeal: 210, buttonCount: 3)
        XCTAssertEqual(w, 210, "余量充足时指示器足额，不截断")
    }

    /// 窄窗：按钮区先足额扣减，余量全给指示器（指示器截尾/裁切吸收压缩）。
    func testLayoutNarrowWindowIndicatorAbsorbsCompression() {
        let buttons = ChatTopBarLayout.buttonsWidth(buttonCount: 3)   // 3×42+2×10 = 146
        XCTAssertEqual(buttons, 146)
        // 可用 = 按钮 146 + 间距 10 + 指示器余量 60
        let w = ChatTopBarLayout.indicatorWidth(available: 216, indicatorIdeal: 210, buttonCount: 3)
        XCTAssertEqual(w, 60, "指示器只拿余量，按钮一分不少")
    }

    /// 极端窄：指示器让位到 0，按钮区恒完整（旧 ZStack+fixedSize 整组右溢的根治点）。
    func testLayoutExtremeNarrowButtonsNeverOverflow() {
        let w = ChatTopBarLayout.indicatorWidth(available: 100, indicatorIdeal: 210, buttonCount: 3)
        XCTAssertEqual(w, 0, "余量为负 → 指示器归零，绝不动按钮")
        XCTAssertFalse(ChatTopBarLayout.buttonsAlwaysFit(available: 100, buttonCount: 3),
                       "100pt 装不下按钮区（146）——窗口最小宽约束兜底，布局层如实上报")
        XCTAssertTrue(ChatTopBarLayout.buttonsAlwaysFit(available: 146, buttonCount: 3))
    }

    /// 无按钮态（无会话）：指示器独占可用宽，不扣间距。
    func testLayoutNoButtonsIndicatorTakesAll() {
        let w = ChatTopBarLayout.indicatorWidth(available: 150, indicatorIdeal: 210, buttonCount: 0)
        XCTAssertEqual(w, 150)
        XCTAssertEqual(ChatTopBarLayout.buttonsWidth(buttonCount: 0), 0)
    }

    /// 不变量：任何 available ≥ 按钮区理想宽时，指示器让位后按钮永不缺额。
    func testLayoutButtonsInvariantAcrossWidths() {
        let buttons = ChatTopBarLayout.buttonsWidth(buttonCount: 3)
        for available in stride(from: buttons, through: 600, by: 7) {
            XCTAssertTrue(ChatTopBarLayout.buttonsAlwaysFit(available: available, buttonCount: 3))
            let w = ChatTopBarLayout.indicatorWidth(available: available,
                                                    indicatorIdeal: 210, buttonCount: 3)
            XCTAssertGreaterThanOrEqual(w, 0)
            XCTAssertLessThanOrEqual(w, 210)
            XCTAssertEqual(available - buttons - ChatTopBarLayout.groupSpacing >= 0,
                           w == min(210, available - buttons - ChatTopBarLayout.groupSpacing))
        }
    }
}
