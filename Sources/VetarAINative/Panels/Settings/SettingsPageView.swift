//
//  SettingsPageView.swift
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

//  设置整页覆盖（checkpoint-045 结构，对标 App.tsx:371-381 + SettingsPage.tsx:59-129）：
//    ┌──────────┬─────────────────────────────┐
//    │ 左侧分类导航 │ 右侧内容区（各面板直接内嵌）  │
//    │ 220pt    │                             │
//    │ 返回应用  │                             │
//    └──────────┴─────────────────────────────┘
//
//  V4（用户要求消灭三重导航）：rail「系统」组移除，低频模块全部收进本页内部导航，
//  知识记忆/推理后端/模型包/插件管理**直接内嵌**（对齐 SettingsPage.tsx:118-126），
//  消灭 V4 前「在侧栏打开」占位卡跳转层：
//    · 基础设置 = SettingsPanelView（含原生内核分区、打开日志文件夹/数据目录——
//      原「日志」「数据与诊断」两占位导航项的能力已在其中，随注册表一并删除）
//    · 知识记忆 = KnowledgePanelView（已内嵌知识仓库/记忆/技能标签，
//      原「仓库管理」导航项删除；「模型选项」已内嵌推理后端，导航项删除）
//    · 推理后端 = InferencePanelView / 模型包 = ModelPacksPanelView / 插件管理 = PluginsPanelView
//    · CU = SettingsCUView（原版 CU 区设置项，SettingsPanel.tsx:82-221；
//      CU 宏列表按用户拍板留在流程中心，宏位置放「打开 CU 宏面板」跳转）
//
//  0.7.1 Bug 7（业主拍板方案 A）：「关于」导航项撤除——菜单栏「关于 VetarAI」
//  恢复 macOS 标准关于弹窗（VetarAINativeApp.swift）；原 AboutPanel 的诊断能力
//  （运行时状态/数据根显示与修改/日志与数据根目录入口/调试 mock）收进
//  「基础设置」底部「诊断」区，accessibilityIdentifier 全部保留不变。
//
//  打开/关闭：rail 底部齿轮（AppState.toggleSettings）/
//  深链 `-ui.panel settings`（启动兜底打开，AppState.init）；返回应用 = 关闭回来源处。
//  分区深链：`-ui.settingsSection <key>`（对标 tsx initialSection；非法值回退 general，
//  AppState.init 读取）。
//

import SwiftUI

/// 设置覆盖页内部分区（对标 SettingsPage.tsx:36-44 SECTIONS + 原生 CU 扩展项；
/// 0.7.1 Bug 7：「关于」项撤除——菜单栏恢复标准关于弹窗，诊断能力并入基础设置）。
public enum SettingsSection: String, CaseIterable, Identifiable, Sendable {
    case general
    /// W1（0.6/0.7 联动）：账号（登录/激活/设备/baseURL）——声明序紧随基础设置
    case account
    /// v1.4（0.7.2）：更新与反馈（检查更新 + 问题反馈 + 我的反馈，单导航项防臃肿）
    case updatesFeedback = "updates-feedback"
    case knowledge
    case inference
    case modelPacks = "model-packs"
    case plugins
    case cu

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "基础设置"
        case .account: return "账号"
        case .updatesFeedback: return "更新与反馈"
        case .knowledge: return "知识记忆"
        case .inference: return "推理后端"
        case .modelPacks: return "模型包"
        case .plugins: return "插件管理"
        case .cu: return "CU"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .account: return "person.crop.circle"
        case .updatesFeedback: return "arrow.triangle.2.circlepath"
        case .knowledge: return "book"
        case .inference: return "cpu"
        case .modelPacks: return "shippingbox"
        case .plugins: return "puzzlepiece"
        case .cu: return "desktopcomputer"
        }
    }
}

public struct SettingsPageView: View {
    @EnvironmentObject private var appState: AppState

    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            navColumn
                .frame(width: 220)
                .background(VTheme.bgSidebar)
                .overlay(alignment: .trailing) { Divider() }
            contentArea
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                .background(VTheme.bgApp)
                .clipped()
        }
        // DBG-160：容器不挂 id（内有 settings.nav.*/backToApp 及内容区全部叶子 id）
    }

    // MARK: - 左侧分类导航（SettingsPage.tsx:62-111，§8.14）

    private var navColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            // ← 返回应用：关闭覆盖层回来源处（tsx onExit = setShowSettingsPage(false)，
            // App.tsx:376；原生 selectedModule/selectedPanel 未被改动，直接落回）
            Button {
                appState.closeSettings()
            } label: {
                Label("返回应用", systemImage: "arrow.left")
                    .font(VTheme.Typo.body)
                    .foregroundStyle(VTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 8)
            .accessibilityIdentifier("settings.backToApp")

            ForEach(SettingsSection.allCases) { s in
                SettingsNavRow(section: s, isActive: appState.settingsSection == s) {
                    appState.settingsSection = s
                }
                .accessibilityIdentifier("settings.nav.\(s.rawValue)")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
    }

    // MARK: - 右侧内容区（SettingsPage.tsx:113-127：各分区直接内嵌面板）

    @ViewBuilder
    private var contentArea: some View {
        switch appState.settingsSection {
        case .general:
            SettingsPanelView()
        case .account:
            AccountPanelView()
        case .updatesFeedback:
            UpdatesFeedbackPanelView()
        case .knowledge:
            KnowledgePanelView()
        case .inference:
            InferencePanelView()
        case .modelPacks:
            ModelPacksPanelView()
        case .plugins:
            PluginsPanelView()
        case .cu:
            SettingsCUView()
        }
    }
}

/// 导航行（tsx：active 蓝底强调字 / hover 浅底；32 高、圆角 s）。
private struct SettingsNavRow: View {
    let section: SettingsSection
    let isActive: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: section.icon)
                    .frame(width: 16)
                Text(section.title)
                    .font(.system(size: 13, weight: isActive ? .medium : .regular))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(isActive ? VTheme.bgSelected : (hovering ? VTheme.bgHover : Color.clear),
                        in: RoundedRectangle(cornerRadius: VTheme.Radius.s))
            .foregroundStyle(isActive ? VTheme.accentText : VTheme.textSecondary)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
