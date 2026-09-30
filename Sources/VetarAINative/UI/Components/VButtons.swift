//
//  VButtons.swift
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

//  按钮 / 输入框样式库（对齐 theme.ts 的 btnPrimary/btnSecondary/btnDanger/btnGhost/input）。
//  面板统一用这套 ButtonStyle / 修饰器，不要散落自定义样式。
//

import SwiftUI

// MARK: - 按钮样式

/// 主按钮：石墨黑底白字（danger 变体红底）。
public struct VPrimaryButtonStyle: ButtonStyle {
    public var danger: Bool = false
    public init(danger: Bool = false) { self.danger = danger }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VTheme.Typo.body.weight(.medium))
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(danger ? VTheme.danger : VTheme.ink,
                        in: RoundedRectangle(cornerRadius: VTheme.Radius.s))
            .foregroundStyle(danger ? Color.white : VTheme.onInk)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// 次按钮：白底灰框。
public struct VSecondaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VTheme.Typo.body)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(VTheme.bgCard, in: RoundedRectangle(cornerRadius: VTheme.Radius.s))
            .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.s).stroke(VTheme.borderStrong))
            .foregroundStyle(VTheme.textPrimary)
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// 幽灵按钮：无边无底（行内/工具栏操作）。
public struct VGhostButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VTheme.Typo.body)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .foregroundStyle(VTheme.textSecondary)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

public extension ButtonStyle where Self == VPrimaryButtonStyle {
    static var vPrimary: VPrimaryButtonStyle { VPrimaryButtonStyle() }
    static var vDanger: VPrimaryButtonStyle { VPrimaryButtonStyle(danger: true) }
}
public extension ButtonStyle where Self == VSecondaryButtonStyle {
    static var vSecondary: VSecondaryButtonStyle { VSecondaryButtonStyle() }
}
public extension ButtonStyle where Self == VGhostButtonStyle {
    static var vGhost: VGhostButtonStyle { VGhostButtonStyle() }
}

// MARK: - 行内操作小图标钮

/// 列表行内悬停操作钮（对齐原版 tsx 行内 icon button：~20×20 紧凑无大 padding）。
/// ⛔ 行内不得用 vGhost——它是面板级按钮（28pt 高 + 10pt 横 padding，且自定义
/// ButtonStyle 不响应 controlSize(.small)），opacity(0) 隐藏时仍占布局宽度，
/// 5 个即吃掉 ~183pt 把同行名称 Text 挤成「…」（DBG-146 项目名省略号事件）。
public struct VRowActionButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .frame(width: 20, height: 20)
            .foregroundStyle(VTheme.textSecondary)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

public extension ButtonStyle where Self == VRowActionButtonStyle {
    static var vRowAction: VRowActionButtonStyle { VRowActionButtonStyle() }
}

// MARK: - 图标钮命中目标

public extension View {
    /// 图标钮命中区扩面（用于 Button 的 label 内部，0.7.14 ⋯菜单 razor-thin 根治）。
    /// 实测（0.7.13 运行中应用 AX 命中取证）：本环境自定义 ButtonStyle 的 padding/
    /// frame 只进布局、不进命中区——按钮命中区 = label 本体框架。vGhost 图标钮实际
    /// 可点区域=字形框架：✓ 13×13 / ⛁ 11×14 尚可，ellipsis 仅 12×2.5——±3pt 瞄准
    /// 误差即落空（命中底层纯容器），表现为「更多菜单完全点不开」。
    /// label 扩为固定见方 + contentShape(Rectangle()) 后，命中区 = 该见方。
    func vIconHitTarget(_ side: CGFloat) -> some View {
        frame(width: side, height: side).contentShape(Rectangle())
    }
}

// MARK: - 输入框样式

/// 统一输入框外观（白底、1px 强边框、6 圆角、13 号字）。
public struct VTextFieldModifier: ViewModifier {
    public func body(content: Content) -> some View {
        content
            .font(VTheme.Typo.body)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(VTheme.bgCard, in: RoundedRectangle(cornerRadius: VTheme.Radius.s))
            .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.s).stroke(VTheme.borderStrong))
    }
}

public extension View {
    func vInputStyle() -> some View { modifier(VTextFieldModifier()) }
}
