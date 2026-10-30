//
//  AgentPanelView.swift
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

//  项目内 Agent 面板内容（对标 subagent/renderer/src/panels/AgentPanel.tsx，280 行）：
//    · 标题行「Agent」（:147-149）+ 创建表单卡片：名称输入（Enter 提交）+
//      类型选择（主Agent/子Agent）+ 模型选择（空列表显示「模型加载中…」禁用态）+
//      添加按钮 + 可选角色设定
//    · 错误条：列表拉取失败 + 手动「重试」（方向2 波次2 新增——原静默假空）
//    · Agent 列表行：类型徽标（主/子）+ 名称 + 已设角色设定标记 +
//      行内模型切换 + 编辑角色设定 + 删除（确认弹窗）
//      —— 行视图为共享组件 AgentRowView（方向2 波次2 收编，Panels/Agents/AgentRowView.swift）
//    · 行内编辑区：角色设定多行编辑 + 取消/保存
//  V1（智能中心侧栏单栏堆叠复刻）：整页面板壳移除——本文件只提供侧栏分区内容
//  视图 `AgentPanelContentView`（原版 AgentPanel 选中项目时同栏在下方出现，
//  App.tsx:236-243；整区 flex:1 独立滚动，AgentPanel.tsx:143-144）；
//  VM 生命周期随侧栏分区挂载。
//  文案与缺省值链逐字对齐现状实现；视觉用 VTheme 近似（接入指南 §3）。
//

import SwiftUI

/// 延迟构建 AgentPanelViewModel（需要已注入的 AppState）。
@MainActor
final class AgentPanelViewModelBox: ObservableObject {
    @Published var vm: AgentPanelViewModel?
    func attach(appState: AppState) {
        if vm == nil { vm = AgentPanelViewModel(appState: appState) }
    }
}

/// 项目内 Agent 区内容（原版 AgentPanel.tsx:142-279 整段：标题 + 创建表单 + 列表，
/// 整区滚动）。VM start/stop 由侧栏分区驱动。
struct AgentPanelContentView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var vm: AgentPanelViewModel
    /// 波次7（业主拍板对齐 Kimi/WorkBuddy「分组平铺+弹窗创建」）：创建表单撤出侧栏，
    /// 标题行「新建」只负责唤起弹窗（弹窗由 IntelligenceSidebarView overlay 承载）
    let onShowCreate: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                // ── 面板标题行（波次7：「新建」唤起弹窗，表单不再进侧栏）──
                HStack {
                    Text("Agent")
                        .font(VTheme.Typo.panelTitle)
                        .foregroundStyle(VTheme.textSecondary)
                    Spacer()
                    Button {
                        onShowCreate()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                                .font(VTheme.Typo.micro)
                            Text("新建")
                                .font(VTheme.Typo.caption)
                        }
                    }
                    .buttonStyle(.vGhost)
                    .accessibilityIdentifier("agentCreateFormToggle")
                }

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
                        .accessibilityIdentifier("agentRetryButton")
                    }
                }

                // ── 空态（方向2 波次2：错误态下不显示，避免错误条与空态同框假空）──
                if vm.agents.isEmpty && vm.error == nil {
                    VStack(spacing: 8) {
                        Image(systemName: "person.2")
                            .font(.system(size: 30))
                            .foregroundStyle(VTheme.borderStrong)
                        Text("暂无 Agent，点上方 + 新建")
                            .font(VTheme.Typo.body)
                            .foregroundStyle(VTheme.textTertiary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }

                // ── Agent 列表（方向2 波次2：行视图收编共享组件 AgentRowView，
                //    原私有实现 :141-282 退役——与独立 Agent 行是复制粘贴双胞胎）──
                ForEach(vm.agents, id: \.id) { agent in
                    AgentRowView(
                        rowId: agent.id,
                        name: agent.name,
                        hasPrompt: !(agent.system_prompt?.isEmpty ?? true),
                        modelName: agent.model_name,
                        typeBadge: agent.type_ == "main" ? "主" : "子",
                        typeBadgeIsMain: agent.type_ == "main",
                        isSelected: appState.currentAgentId == agent.id,
                        isEditing: vm.editingId == agent.id,
                        modelList: vm.modelList,
                        showsModelPicker: agent.model_name != nil,
                        onChangeModel: { vm.changeModel(agent, to: $0) },
                        onEdit: { vm.beginEdit(agent) },
                        onDelete: { vm.delete(agent) },
                        onTap: { vm.startChat(agent) },
                        editText: $vm.editText,
                        savingPrompt: vm.savingPrompt,
                        onSavePrompt: { vm.savePrompt(agent) },
                        onCancelEdit: { vm.cancelEdit() },
                        accessibilityPrefix: "agent",
                        entityLabel: "Agent"
                    )
                }
            }
            .padding(12)
        }
    }
}

// 方向2 波次2：原私有 AgentRowView（:141-282）已收编为共享组件
// Panels/Agents/AgentRowView.swift——与 IndependentAgentRowView 是约 120 行
// 复制粘贴双胞胎；逐分叉取舍见共享文件头注释。
