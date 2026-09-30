//
//  UpdatesFeedbackPanelView.swift
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

//  任务书 C/D 组落点：设置覆盖页单个导航项「更新与反馈」（不拆两项防导航臃肿）：
//    · 检查更新卡（本文件，C 组）：当前版本 + 手动「检查更新」按钮——
//      结果全交 Sparkle 原生弹窗（有更新弹更新窗 / 无更新弹「已是最新版本」，
//      仅手动才显示已是最新——C 边界）；本卡只保留离线直拒错误条。
//    · 问题反馈卡 + 我的反馈卡（D 组，同面板追加——见 FeedbackViews.swift）。
//

import SwiftUI

public struct UpdatesFeedbackPanelView: View {
    @EnvironmentObject private var appState: AppState
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("更新与反馈")
                    .font(VTheme.Typo.title2)
                    .foregroundStyle(VTheme.textPrimary)

                // ── 检查更新卡（C 组）──
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(VTheme.accentText)
                        Text("检查更新")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(VTheme.textPrimary)
                    }
                    HStack(spacing: 8) {
                        Text("当前版本")
                            .font(VTheme.Typo.caption)
                            .foregroundStyle(VTheme.textTertiary)
                        Text("V\(AppVersion.current)（build \(AppVersion.build)）")
                            .font(VTheme.Typo.caption)
                            .foregroundStyle(VTheme.textPrimary)
                            .accessibilityIdentifier("updates.currentVersion")
                    }
                    HStack(spacing: 12) {
                        Button {
                            appState.update.checkNowManually(
                                isOnline: appState.network.isOnline)
                        } label: {
                            Text("检查更新")
                                .font(.system(size: 13, weight: .medium))
                                .frame(width: 120, height: 32)
                                .background(VTheme.accentBgSoft,
                                            in: RoundedRectangle(cornerRadius: VTheme.Radius.m2))
                                .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.m2)
                                    .stroke(VTheme.accentBorder, lineWidth: 1))
                                .foregroundStyle(VTheme.accentText)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("updates.checkButton")

                        // 离线直拒错误条（其余结果——有更新/已是最新——全由
                        // Sparkle 原生弹窗呈现，本卡不重复文案）
                        if let error = appState.update.lastManualError {
                            Text(error)
                                .font(VTheme.Typo.caption)
                                .foregroundStyle(VTheme.dangerText)
                                .accessibilityIdentifier("updates.manualError")
                        }
                    }
                    Text("有新版本时会自动提示；更新包经 EdDSA 签名验证后自动安装并重启，登录态与数据不受影响。")
                        .font(VTheme.Typo.micro)
                        .foregroundStyle(VTheme.textTertiary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(VTheme.bgCard, in: RoundedRectangle(cornerRadius: VTheme.Radius.m))
                .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.m)
                    .stroke(VTheme.borderSubtle, lineWidth: 1))

                // ── 问题反馈卡 + 我的反馈卡（D 组，FeedbackViews.swift）──
                FeedbackFormCard()
                FeedbackMineCard()
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        // 下拉刷新 = 刷新我的反馈（任务书 D「支持下拉刷新」）
        .refreshable {
            await appState.feedback.refreshMine(isOnline: appState.network.isOnline)
        }
        // 容器不挂 id（DBG-160 纪律；叶子 id 全在内部）
    }
}
