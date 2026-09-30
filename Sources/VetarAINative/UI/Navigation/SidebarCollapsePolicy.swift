//
//  SidebarCollapsePolicy.swift
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

//  纯逻辑策略（可测规格本体）：窗口宽驱动侧栏自动隐藏/复位/手动唤出。
//  ⚠️ 视图接线注意（0.5.1 冒烟实证 + 0.5.2 B1a 滞回）：RootView 中 autoHidden
//  由 geo.size.width 在 body 内实时推导（resolve 纯函数），滞回记忆持 @State
//  （仅带内生效），pinned 持 @State——不采用 @State+onAppear/onChange 喂宽度：
//  「启动即窄窗」时 frameAutosave 恢复与视图树安装竞态会漏首次宽度事件，
//  三态机卡在初始 shown=true（实测复现 DBG-151）；带外（<920 / >1080）由
//  几何直接决定，不吃记忆，竞态面归零。
//  口径对齐 0.4.x App.tsx:58-73/215-230/300-318 + 0.5.2 滞回裁定：
//    · 窗口宽 < 920（折叠线）→ sidebarAutoHidden
//    · 窗口宽 > 1080（展开线）→ 自动复位且 pinned 归 false
//    · 920~1080 滞回带 → 保持来向状态（拖拽 resize 跨阈不反复翻转——0.5.1
//      实测单阈值下 resize 抖动期侧栏反复展开/收起、每帧全量重排是主线程
//      卡顿源之一）
//    · sidebarPinned = 窄窗下手动唤出（把手 chevron 切换）；带内/过折叠线
//      收窄 pinned 均保留（shown 仍 true，钉住不随 resize 抖动掉）
//    · sidebarShown = !autoHidden || pinned——展开态 = 自动可见 或 手动钉住
//    · 全程不卸载保活（视图树内壳宽 0↔固定宽动画 + 滑出偏移，非销毁重建）
//
//  ⚠️ 有意偏差（沿用 R3 数学，折叠线 1000→920）：rail 52 + 侧栏 260 +
//  内容区最小可用 ≈608 = 920；展开线 1080 开出 160pt 滞回带。0.5.2 W7：
//  窗 minWidth 960 → 800（低于折叠线，800~919 共 120pt 纯折叠区——960
//  地板曾使折叠对拖拽不可达，用户实证）；首帧（previous=nil）口径修正为
//  与 0.4.x 一致：宽 ≥ 折叠线 → 展开（0.4.x 在 960 宽启动时侧栏显示），
//  宽 < 折叠线 → 恒折叠（保 R3「启动即窄窗恒折叠」DBG-151 口径）。
//

import CoreGraphics

/// 侧栏折叠策略（0.4.x sidebarAutoHidden/sidebarPinned/sidebarShown 三态机
/// + 0.5.2 B1a 920/1080 滞回带）。
struct SidebarCollapsePolicy: Equatable {
    /// 折叠线：宽 < 920 → 自动隐藏（有意偏差 ≠ 0.4.x 860，见头注数学）。
    static let collapseLine: CGFloat = 920
    /// 展开线：宽 > 1080 → 自动展开（pinned 一并复位）。
    static let expandLine: CGFloat = 1080

    /// 窄窗自动隐藏（0.4.x sidebarAutoHidden）。
    private(set) var autoHidden = false
    /// 窄窗下手动唤出钉住（0.4.x sidebarPinned）。
    private(set) var pinned = false

    /// 展开态（0.4.x sidebarShown = !autoHidden || pinned）。
    var shown: Bool { !autoHidden || pinned }

    /// 滞回带判定（纯函数，RootView body 内实时推导用）：
    ///   宽 < collapseLine → true（恒隐，几何直接决定）
    ///   宽 > expandLine   → false（恒显，几何直接决定）
    ///   带内              → 保持 previous（来向状态）；previous = nil（首帧）
    ///                       → width < collapseLine（0.5.2 W7 对齐 0.4.x：
    ///                       ≥920 首帧展开、<920 恒折叠——上两分支已截住带外，
    ///                       落此分支时 width ∈ [920,1080]，故 nil 首帧 = 展开；
    ///                       <920 首帧折叠由第一分支保证，DBG-151 口径不丢）。
    static func resolve(width: CGFloat, previous: Bool?) -> Bool {
        if width < collapseLine { return true }
        if width > expandLine { return false }
        return previous ?? (width < collapseLine)
    }

    /// 窗口宽变化（实例态版，测试规格用）：过折叠线自动隐藏；过展开线自动复位
    /// （pinned 一并归零——0.4.x 同口径，宽窗无「钉住」概念）；滞回带内两态保持。
    mutating func onWidthChange(_ width: CGFloat) {
        if width < Self.collapseLine {
            autoHidden = true
        } else if width > Self.expandLine {
            autoHidden = false
            pinned = false
        }
        // 带内（920~1080）：autoHidden/pinned 均保持来向（滞回，防翻转抖动）
    }

    /// 把手切换：仅窄窗（autoHidden）下有效；宽窗无把手可点，调用为空操作。
    mutating func togglePinned() {
        guard autoHidden else { return }
        pinned.toggle()
    }
}
