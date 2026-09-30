//
//  ChatTopBarLayout.swift
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

//  背景（E2E 0.7.12 A1/项8：⋯ 菜单「看得见点不着」类故障的结构性根治）：
//  旧右组 = ZStack(alignment:.leading) { HStack.fixedSize() }——整组报理想宽，
//  分得窄于理想时超宽内容向右溢出组框：按钮被画到命中界外（实测 1100 档
//  出现按钮消失/命中错位）。ZStack 只决定「往哪边溢」，不解决「溢出即点不着」。
//
//  新策略（本文件 = 策略纯逻辑；ChatPanelView 顶栏右组按同口径声明式落地）：
//    · 三按钮（✓ 勾选 / ⛁ 知识仓库 / ⋯ 更多）恒足额——fixedSize 报理想且最小，
//      任何窗口宽度下完整留在命中界内，永不溢出被裁；
//    · 上下文指示器吸收全部压缩——文字先截尾（lineLimit(1) 去 fixedSize），
//      再窄裁指示器区（minWidth:0 + clipped），tooltip（.help）兜底全文；
//    · 宽窗下指示器拿足理想宽、零截断——像素与旧布局一致（仅窄窗行为变化）。
//
//  三思考：
//    ① 真正原因：fixedSize 整组零压缩 + ZStack 右溢 → 命中界外渲染；
//    ② 影响模块：仅智能中心顶栏右组（指示器/三按钮），菜单 overlay 不动；
//    ③ 防新问题：分配策略提纯函数钉 XCTest——「按钮恒足额、指示器吸收压缩」
//      两个不变量可回归；声明式结构（截尾 Text + fixedSize 按钮组）与函数同口径。
//

import CoreGraphics

/// 顶栏右组宽度分配策略（F1；纯逻辑，XCTest 载体）。
public enum ChatTopBarLayout {

    /// 图标钮理想宽估（label 命中目标 22（ChatTopBarSpec.iconHitTarget）+
    /// .vGhost 横 padding 10×2 = 42pt/枚；0.7.14 前纯字形估 28 作废——
    /// 0.7.13 AX 实测命中区=label 框架，label 扩 22×22 后实宽即 42）。
    public static let buttonIdealWidth: CGFloat = 42
    /// 右组内间距（指示器 ↔ 按钮组、按钮 ↔ 按钮统一 10pt，与视图 HStack(spacing:) 同值）。
    public static let groupSpacing: CGFloat = 10

    /// 按钮区理想总宽（按钮恒足额 + 按钮间间距）。
    public static func buttonsWidth(buttonCount: Int) -> CGFloat {
        guard buttonCount > 0 else { return 0 }
        return CGFloat(buttonCount) * buttonIdealWidth
            + CGFloat(buttonCount - 1) * groupSpacing
    }

    /// 指示器分得宽度：按钮区先足额扣减（含指示器↔按钮间距），余量全给指示器、
    /// 不超过其理想宽；余量为负 → 0（指示器整体让位，按钮区恒完整）。
    public static func indicatorWidth(available: CGFloat,
                                      indicatorIdeal: CGFloat,
                                      buttonCount: Int) -> CGFloat {
        let spacing = buttonCount > 0 ? groupSpacing : 0
        let remainder = available - buttonsWidth(buttonCount: buttonCount) - spacing
        return max(0, min(indicatorIdeal, remainder))
    }

    /// 不变量钉桩：可用宽 ≥ 按钮区理想宽 ⇒ 指示器让位后按钮永不缺额
    ///（视图层 fixedSize 按钮组 + 截尾指示器保证同一性质）。
    public static func buttonsAlwaysFit(available: CGFloat, buttonCount: Int) -> Bool {
        available >= buttonsWidth(buttonCount: buttonCount)
    }
}
