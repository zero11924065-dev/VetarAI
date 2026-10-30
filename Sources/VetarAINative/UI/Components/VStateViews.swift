//
//  VStateViews.swift
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

//  Loading / 空态组件（面板通用）。
//

import SwiftUI

/// 居中 loading（可选说明文字）。
public struct VLoadingView: View {
    public let text: String?
    public init(_ text: String? = nil) { self.text = text }

    public var body: some View {
        VStack(spacing: VTheme.Space.s2) {
            ProgressView()
                .controlSize(.regular)
            if let text {
                Text(text)
                    .font(VTheme.Typo.caption)
                    .foregroundStyle(VTheme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 空态：图标卡片 + 宋体大标题 + 说明 + 可选示例操作组（方向2 L4，2026-10-19 拍板）。
/// 波次1 顺带修：图标卡圆角 16→Radius.l 令牌化、去阴影留边（边/影取其一）、
/// 标题手写 15pt → Typo.display 展示层宋体（textPrimary 墨黑）。
public struct VEmptyStateView: View {
    public let icon: String
    public let title: String
    public let message: String
    /// 方向2 L4 新增：示例操作组（如「试试问……」），空数组或无回调则不显示
    public let suggestions: [String]
    public let onPick: ((String) -> Void)?

    public init(icon: String, title: String, message: String,
                suggestions: [String] = [], onPick: ((String) -> Void)? = nil) {
        self.icon = icon
        self.title = title
        self.message = message
        self.suggestions = suggestions
        self.onPick = onPick
    }

    public var body: some View {
        VStack(spacing: VTheme.Space.s3) {
            ZStack {
                RoundedRectangle(cornerRadius: VTheme.Radius.l)
                    .fill(VTheme.bgCard)
                    .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.l).stroke(VTheme.borderSubtle))
                    .frame(width: 56, height: 56)
                Image(systemName: icon)
                    .font(.system(size: 24))
                    .foregroundStyle(VTheme.textDisabled)
            }
            Text(title)
                .font(VTheme.Typo.display)
                .foregroundStyle(VTheme.textPrimary)
            Text(message)
                .font(VTheme.Typo.body)
                .foregroundStyle(VTheme.textTertiary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 340)
            if !suggestions.isEmpty, let onPick {
                HStack(spacing: VTheme.Space.s2) {
                    ForEach(suggestions, id: \.self) { s in
                        Button(s) { onPick(s) }
                            .buttonStyle(.vSecondary)
                    }
                }
                .padding(.top, VTheme.Space.s1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
