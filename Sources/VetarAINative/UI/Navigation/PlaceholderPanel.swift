//
//  PlaceholderPanel.swift
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

//  「待重写」占位页：图标 + 标题 + 状态徽标 + 对标源文件 + 职责说明。
//

import SwiftUI

public struct PlaceholderPanel: View {
    public let panel: PanelDescriptor

    public init(panel: PanelDescriptor) { self.panel = panel }

    public var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .fill(VTheme.bgCard)
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(VTheme.borderSubtle))
                    .shadow(color: .black.opacity(0.04), radius: 1.5, y: 1)
                    .frame(width: 64, height: 64)
                Image(systemName: panel.icon)
                    .font(.system(size: 26))
                    .foregroundStyle(VTheme.textTertiary)
            }
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Text(panel.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(VTheme.textPrimary)
                    Text("待重写")
                        .font(VTheme.Typo.micro.weight(.medium))
                        .foregroundStyle(VTheme.warnText)
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background(VTheme.warnBg, in: Capsule())
                        .overlay(Capsule().stroke(VTheme.warnBorder))
                }
                Text(panel.summary)
                    .font(VTheme.Typo.body)
                    .foregroundStyle(VTheme.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            VStack(spacing: 4) {
                Text("对标现状实现")
                    .font(VTheme.Typo.micro)
                    .foregroundStyle(VTheme.textDisabled)
                Text(panel.referencePath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(VTheme.textTertiary)
                    .textSelection(.enabled)
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VTheme.bgApp)
        .accessibilityIdentifier("placeholder.\(panel.key)")
    }
}
