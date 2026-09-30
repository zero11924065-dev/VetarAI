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
        VStack(spacing: 10) {
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

/// 空态：图标卡片 + 标题 + 说明（对齐 App.tsx 空对话区观感）。
public struct VEmptyStateView: View {
    public let icon: String
    public let title: String
    public let message: String

    public init(icon: String, title: String, message: String) {
        self.icon = icon
        self.title = title
        self.message = message
    }

    public var body: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(VTheme.bgCard)
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(VTheme.borderSubtle))
                    .shadow(color: .black.opacity(0.04), radius: 1.5, y: 1)
                    .frame(width: 56, height: 56)
                Image(systemName: icon)
                    .font(.system(size: 24))
                    .foregroundStyle(VTheme.textDisabled)
            }
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(VTheme.textSecondary)
            Text(message)
                .font(VTheme.Typo.body)
                .foregroundStyle(VTheme.textTertiary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
