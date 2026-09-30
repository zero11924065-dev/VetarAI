//
//  SidebarCollapseR3Tests.swift
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

//  覆盖（0.5.1 实测驱动：拖拽 resize 跨单阈值时侧栏反复翻转、每帧全量重排
//  是主线程卡顿源之一）：
//    · 滞回带：<920 恒隐、>1080 恒显、920~1080 保持来向
//    · 边界序列：1440→1000 保持显、→919 折、→1000/1079 保持折、→1081 展
//    · resolve 纯函数：带外几何直接决定（不吃记忆）；带内吃记忆；previous
//      nil（首帧）= width < 折叠线（0.5.2 W7 对齐 0.4.x：≥920 首帧展开，
//      <920 首帧恒折叠保 DBG-151；窗 minWidth 800 低于折叠线，折叠可达）
//    · shown 三态 / 过展开线 pinned 复位（带内 pinned 保持）/ 把手空操作守卫
//    · 侧栏宽固定 260（0.5.2 B2：撤 24vw 弹性，resize 期间侧栏零重排）
//

import XCTest
@testable import VetarAINative

final class SidebarCollapseR3Tests: XCTestCase {

    /// 滞回带边界序列：带内保持来向，带外几何直接决定。
    func testHysteresisBandSequence() {
        var p = SidebarCollapsePolicy()
        p.onWidthChange(1440)
        XCTAssertFalse(p.autoHidden)
        XCTAssertTrue(p.shown)
        p.onWidthChange(1000)
        XCTAssertFalse(p.autoHidden, "带内（920~1080）保持来向：宽→1000 仍显")
        p.onWidthChange(919)
        XCTAssertTrue(p.autoHidden, "919 < 折叠线 920 → 折叠")
        XCTAssertFalse(p.shown)
        p.onWidthChange(1000)
        XCTAssertTrue(p.autoHidden, "带内保持来向：窄→1000 仍折")
        p.onWidthChange(1079)
        XCTAssertTrue(p.autoHidden, "1079 仍在带内 → 保持折")
        p.onWidthChange(1081)
        XCTAssertFalse(p.autoHidden, "1081 > 展开线 1080 → 展开")
        XCTAssertTrue(p.shown)
    }

    /// 滞回线钉死：折叠线 920 / 展开线 1080（160pt 带；沿用 R3 有意偏差数学，
    /// rail 52 + 侧栏 260 + 内容区最小可用 ≈608 = 920）。
    func testHysteresisLines() {
        XCTAssertEqual(SidebarCollapsePolicy.collapseLine, 920)
        XCTAssertEqual(SidebarCollapsePolicy.expandLine, 1080)
    }

    /// resolve 纯函数：带外由几何直接决定（不吃记忆）；带内吃记忆；
    /// previous nil（首帧）= width < 折叠线（0.5.2 W7：≥920 首帧展开对齐
    /// 0.4.x；<920 首帧恒折叠保 R3「启动即窄窗恒折叠」DBG-151 口径）。
    func testResolvePureFunction() {
        XCTAssertTrue(SidebarCollapsePolicy.resolve(width: 919, previous: false),
                      "<920 恒隐，与记忆无关")
        XCTAssertFalse(SidebarCollapsePolicy.resolve(width: 1081, previous: true),
                       ">1080 恒显，与记忆无关")
        XCTAssertTrue(SidebarCollapsePolicy.resolve(width: 1000, previous: true),
                      "带内保持折（来向窄）")
        XCTAssertFalse(SidebarCollapsePolicy.resolve(width: 1000, previous: false),
                       "带内保持显（来向宽）")
        XCTAssertTrue(SidebarCollapsePolicy.resolve(width: 919, previous: nil),
                      "首帧 nil 且 <920 → 恒折叠（启动即窄窗恒折叠，DBG-151）")
        XCTAssertFalse(SidebarCollapsePolicy.resolve(width: 960, previous: nil),
                       "首帧 nil 且 ≥920 → 展开（0.5.2 W7 对齐 0.4.x：960 宽启动侧栏显示）")
        XCTAssertFalse(SidebarCollapsePolicy.resolve(width: 1000, previous: nil),
                       "首帧 nil 落带内 → 展开（带内 nil 分支 = width < collapseLine）")
    }

    /// shown 三态：宽窗恒展开；窄窗默认收起；窄窗 + 把手唤出 → 展开；再点 → 收起。
    func testShownThreeStates() {
        var p = SidebarCollapsePolicy()
        // 宽窗
        p.onWidthChange(1440)
        XCTAssertTrue(p.shown, "!autoHidden → shown")
        // 窄窗默认收起
        p.onWidthChange(900)
        XCTAssertFalse(p.shown, "autoHidden 且未 pinned → 收起")
        // 把手唤出
        p.togglePinned()
        XCTAssertTrue(p.pinned)
        XCTAssertTrue(p.shown, "pinned → shown（0.4.x sidebarShown = !autoHidden || pinned）")
        // 再点收起
        p.togglePinned()
        XCTAssertFalse(p.pinned)
        XCTAssertFalse(p.shown)
    }

    /// 过展开线自动复位：窄窗 pinned 后拖入带内 pinned 保持（钉住不随 resize
    /// 抖动掉），拖过 1080 → autoHidden 与 pinned 双归零（0.4.x 同口径）。
    func testExpandLineResetsPinned() {
        var p = SidebarCollapsePolicy()
        p.onWidthChange(900)
        p.togglePinned()
        XCTAssertTrue(p.pinned)
        p.onWidthChange(1000)
        XCTAssertTrue(p.pinned, "带内 pinned 保持（滞回带不翻状态）")
        XCTAssertTrue(p.shown)
        p.onWidthChange(1280)
        XCTAssertFalse(p.autoHidden)
        XCTAssertFalse(p.pinned, "过展开线 pinned 必须复位（0.4.x 同口径：宽窗无钉住概念）")
        XCTAssertTrue(p.shown)
    }

    /// 把手守卫：宽窗下 togglePinned 是空操作（UI 上把手本就不显示）。
    func testTogglePinnedNoopWhenWide() {
        var p = SidebarCollapsePolicy()
        p.onWidthChange(1440)
        p.togglePinned()
        XCTAssertFalse(p.pinned, "非 autoHidden 态 togglePinned 不得生效")
        XCTAssertTrue(p.shown)
    }

    /// 侧栏宽固定 260（0.5.2 B2 有意偏差：原版 clamp(260, 24vw, 320) 弹性是
    /// 浏览器行为——CSS 重算合成免费，SwiftUI 拖拽每帧按新宽重排整条侧栏
    /// 视图树不免费；固定后 resize 期间侧栏零重排）。
    func testSidebarWidthFixed260() {
        XCTAssertEqual(RootView.sidebarWidth(for: 800), 260, "最窄窗（W7 minWidth 800）恒 260")
        XCTAssertEqual(RootView.sidebarWidth(for: 1200), 260, "弹性已撤：不再 24vw")
        XCTAssertEqual(RootView.sidebarWidth(for: 2000), 260, "超宽窗仍 260（不再顶到 320）")
    }
}
