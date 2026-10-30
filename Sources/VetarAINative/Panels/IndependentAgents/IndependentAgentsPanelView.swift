//
//  IndependentAgentsPanelView.swift
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

//  独立 Agent 面板内容（对标 subagent/renderer/src/panels/IndependentAgentsPanel.tsx，305 行）：
//    · 创建表单卡片：名称输入（Enter 提交）+ 创建按钮 + 模型下拉（默认）+ 角色设定
//    · 错误条：列表拉取失败 + 手动「重试」（方向2 波次2 新增——原静默假空）
//    · 空态说明（不属于任何项目 / 删项目不影响 / 全局能力照常）
//    · 列表行：bot 图标 + 名称 + 已设角色设定标记 + 行内模型切换 +
//      编辑角色设定 + 删除（确认弹窗）
//      —— 行视图为共享组件 AgentRowView（方向2 波次2 收编，Panels/Agents/AgentRowView.swift）
//    · 行内编辑区：角色设定多行编辑 + 取消/保存
//  V1（智能中心侧栏单栏堆叠复刻）：整页面板壳移除——本文件只提供手风琴展开区
//  内容视图 `IndependentAgentsPanelContentView`（原版 IndependentAgentsPanel.tsx:207-301
//  Accordion  children：创建表单 + 列表）；手风琴壳（标题 + 数量徽标 + 展开箭头，
//  :182-201）由 IntelligenceSidebarView 承载，VM 生命周期随侧栏分区挂载。
//  文案与缺省值链逐字对齐现状实现；视觉用 VTheme 近似（接入指南 §3）。
//

import SwiftUI

/// 延迟构建 IndependentAgentsPanelViewModel（需要已注入的 AppState）。
@MainActor
final class IndependentAgentsPanelViewModelBox: ObservableObject {
    @Published var vm: IndependentAgentsPanelViewModel?
    func attach(appState: AppState) {
        if vm == nil { vm = IndependentAgentsPanelViewModel(appState: appState) }
    }
}

/// 独立 Agent 手风琴展开区内容（原版 IndependentAgentsPanel.tsx:207-301：创建表单 + 列表）。
/// 标题行/数量徽标/折叠壳在 IntelligenceSidebarView；VM start/stop 由侧栏分区驱动。
struct IndependentAgentsPanelContentView: View {
    @ObservedObject var vm: IndependentAgentsPanelViewModel
    /// 行选中高亮的数据源是 AppState 全局上下文（vm.isSelected 读 currentAgentId），
    /// 必须经环境订阅——只观察 vm 时切 agent 不触发本视图重渲染（白色选中滞后到
    /// 手风琴折叠/展开重建才更新；对齐 AgentPanelContentView 订阅 appState 的既有口径）
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // ── 错误提示条（方向2 波次2 新增：列表拉取失败 + 手动重试，
            //    照 Projects 错误条口径 VCallout accessory 槽承载重试钮）──
            if let error = vm.error {
                VCallout(.error, error) {
                    Button {
                        vm.retry()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text("重试")
                        }
                    }
                    .buttonStyle(.vSecondary)
                    .accessibilityIdentifier("indepAgentRetryButton")
                }
            }

            // ── 空态 / 列表 ──
            // 波次7（业主拍板对齐 Kimi/WorkBuddy）：创建表单撤出侧栏改弹窗
            // （由 IntelligenceSidebarView 的 overlay 承载，⊕ 入口在手风琴头）；
            // 方向2 波次2：空态收编 VEmptyStateView 三件套（原单行裸文本）；
            // 错误态下不显示空态，避免错误条与空态同框假空
            if vm.agents.isEmpty && vm.error == nil {
                VEmptyStateView(
                    icon: "person.crop.circle",
                    title: "暂无独立 Agent",
                    message: "独立 Agent 不属于任何项目，删项目不影响它；全局记忆/技能/插件照常可用。"
                )
            } else if !vm.agents.isEmpty {
                // 方向2 波次2：行视图收编共享组件 AgentRowView，原私有
                // IndependentAgentRowView（:108-256）退役——与项目内 Agent 行是双胞胎
                ForEach(vm.agents) { agent in
                    AgentRowView(
                        rowId: agent.id,
                        name: agent.name,
                        hasPrompt: !(agent.system_prompt?.isEmpty ?? true),
                        modelName: agent.model_name,
                        leadingIcon: "person.crop.circle",
                        isSelected: vm.isSelected(agent),
                        isEditing: vm.editingId == agent.id,
                        modelList: vm.modelList,
                        showsModelPicker: !vm.modelList.isEmpty,
                        modelPickerHasDefault: agent.model_name == nil,
                        onChangeModel: { vm.switchModel(agent, to: $0) },
                        onStartChat: { vm.startChat(agent) },
                        onEdit: { vm.beginEdit(agent) },
                        onDelete: { vm.delete(agent) },
                        onTap: { vm.startChat(agent) },
                        editText: $vm.editText,
                        savingPrompt: vm.savingPrompt,
                        onSavePrompt: { vm.savePrompt(agent) },
                        onCancelEdit: { vm.cancelEdit() },
                        accessibilityPrefix: "indepAgent",
                        entityLabel: "独立 Agent"
                    )
                }
            }
        }
        // 原版展开区 padding: '4px 12px 10px'（IndependentAgentsPanel.tsx:208）
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }
}

// 方向2 波次2：原私有 IndependentAgentRowView（:108-256）已收编为共享组件
// Panels/Agents/AgentRowView.swift——与项目内 Agent 行是约 120 行复制粘贴
// 双胞胎；逐分叉取舍（阴影/删除染色/开始对话钮/行首图标）见共享文件头注释。
