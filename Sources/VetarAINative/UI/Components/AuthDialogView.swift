//
//  AuthDialogView.swift
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

//  全局授权弹窗：由 AuthCenter.pending 驱动，挂在 RootView 顶层 overlay。
//  按钮语义对齐 0.4.34（Dialog.tsx R2 + ChatPanel.tsx auth_request 分支）：
//    [拒绝] [本会话不再询问] [永久允许] [允许/允许安装/允许执行]
//    · 「本会话不再询问 / 永久允许」= 允许 + 记忆（remember:"session"/"always"）
//    · 普通「允许」不带 remember（仅本次）
//    · 联网安装（net_install）不显示记忆按钮，每次必问；
//      extra.need_enable_network 时附「同时开启全量联网」勾选
//

import SwiftUI

public struct AuthDialogHostView: View {
    @ObservedObject var auth: AuthCenter
    @State private var enableNetwork = true

    public init(auth: AuthCenter) { self.auth = auth }

    public var body: some View {
        if let prompt = auth.pending {
            ZStack {
                Color.black.opacity(0.36)
                    .ignoresSafeArea()
                    .onTapGesture { deny() }   // 遮罩点击 = 拒绝（对齐前端 Esc/遮罩 = 取消 = 拒绝）
                card(prompt)
            }
            .transition(.opacity)
            .onAppear { enableNetwork = true }
        }
    }

    private func card(_ prompt: AuthPrompt) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(prompt.dialogTitle)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(VTheme.textPrimary)
                .padding(.bottom, 12)
            Text(prompt.dialogMessage)
                .font(VTheme.Typo.body)
                .foregroundStyle(VTheme.textSecondary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if prompt.showsEnableNetworkCheckbox {
                Toggle(AuthPrompt.enableNetworkCheckboxLabel, isOn: $enableNetwork)
                    .font(VTheme.Typo.caption)
                    .foregroundStyle(VTheme.textSecondary)
                    .padding(.top, 12)
                    .accessibilityIdentifier("authEnableNetworkCheckbox")
            }
            HStack(spacing: 8) {
                Spacer()
                Button("拒绝") { deny() }
                    .buttonStyle(.vSecondary)
                    .accessibilityIdentifier("authDenyButton")
                if prompt.showsRememberButtons {
                    Button("本会话不再询问") { allow(remember: .session) }
                        .buttonStyle(.vSecondary)
                        .accessibilityIdentifier("authRememberSessionButton")
                    Button("永久允许") { allow(remember: .always) }
                        .buttonStyle(.vSecondary)
                        .accessibilityIdentifier("authRememberAlwaysButton")
                }
                Button(prompt.confirmLabel) { allow(remember: nil) }
                    .buttonStyle(.vDanger)   // 前端四类分支全部 danger: true
                    .accessibilityIdentifier("authAllowButton")
            }
            .padding(.top, 22)
        }
        .padding(EdgeInsets(top: 22, leading: 24, bottom: 22, trailing: 24))
        .frame(width: 460)
        .background(VTheme.bgCard, in: RoundedRectangle(cornerRadius: VTheme.Radius.l))
        .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.l).stroke(VTheme.borderSubtle))
        .shadow(color: .black.opacity(0.12), radius: 15, y: 5)
        .background(
            Button("") { deny() }   // Esc = 拒绝
                .keyboardShortcut(.cancelAction)
                .hidden()
        )
    }

    private func deny() {
        Task { await auth.decide(allowed: false) }
    }

    private func allow(remember: AuthRemember?) {
        Task { await auth.decide(allowed: true, remember: remember, enableNetwork: enableNetwork) }
    }
}
