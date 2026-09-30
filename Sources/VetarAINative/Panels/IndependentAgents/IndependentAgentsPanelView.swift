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
//    · 空态说明（不属于任何项目 / 删项目不影响 / 全局能力照常）
//    · 列表行：bot 图标 + 名称 + 已设角色设定标记 + 行内模型切换 +
//      编辑角色设定 + 删除（确认弹窗）
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
            // ── 创建表单卡片：名称 / 模型 / 角色设定 ──
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    TextField("新独立 Agent 名称", text: $vm.newName)
                        .textFieldStyle(.plain)
                        .vInputStyle()
                        .onSubmit { vm.create() }
                        .accessibilityIdentifier("indepAgentNameField")
                    Button {
                        vm.create()
                    } label: {
                        HStack(spacing: 4) {
                            if vm.creating {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "plus")
                            }
                            Text("创建")
                        }
                    }
                    .buttonStyle(.vPrimary)
                    .controlSize(.small)
                    .disabled(vm.creating)
                    .accessibilityIdentifier("indepAgentCreateButton")
                }
                Picker("", selection: $vm.newModel) {
                    Text("模型（默认）").tag("")
                    ForEach(vm.modelList, id: \.name) { m in
                        Text(m.name).tag(m.name)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityIdentifier("indepAgentModelPicker")
                TextField("角色设定（可选）：如「你是严谨的文档审校员」，随对话注入模型",
                          text: $vm.newPrompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2...4)
                    .vInputStyle()
                    .accessibilityIdentifier("indepAgentPromptField")
            }
            .padding(10)
            .background(VTheme.bgCard, in: RoundedRectangle(cornerRadius: VTheme.Radius.m))
            .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.m).stroke(VTheme.borderDefault))

            // ── 空态 / 列表 ──
            if vm.agents.isEmpty {
                Text("暂无独立 Agent。独立 Agent 不属于任何项目，删项目不影响它；全局记忆/技能/插件照常可用。")
                    .font(VTheme.Typo.caption)
                    .foregroundStyle(VTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
            } else {
                ForEach(vm.agents) { agent in
                    IndependentAgentRowView(agent: agent, vm: vm,
                                            isSelected: vm.isSelected(agent))
                }
            }
        }
        // 原版展开区 padding: '4px 12px 10px'（IndependentAgentsPanel.tsx:208）
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }
}

// MARK: - 独立 Agent 行（选中卡态 + 行内操作 + 行内编辑区）

private struct IndependentAgentRowView: View {
    let agent: IndependentAgent
    @ObservedObject var vm: IndependentAgentsPanelViewModel
    let isSelected: Bool
    @State private var hovering = false

    private var isEditing: Bool { vm.editingId == agent.id }

    var body: some View {
        VStack(spacing: 0) {
            // 行本体
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(VTheme.accentText)
                Text(agent.name)
                    .font(VTheme.Typo.body.weight(isSelected ? .medium : .regular))
                    .foregroundStyle(VTheme.textPrimary)
                    .lineLimit(1)
                if let prompt = agent.system_prompt, !prompt.isEmpty {
                    Image(systemName: "doc.text")
                        .font(.system(size: 11))
                        .foregroundStyle(VTheme.accentText)
                        .help("已设角色设定")
                }
                Spacer(minLength: 4)
                // 问题1联动：明显的「开始对话」入口（选中 + 切到会话面板）
                Button { vm.startChat(agent) } label: {
                    Image(systemName: "bubble.left.and.bubble.right")
                }
                .buttonStyle(.vRowAction)
                .help("开始对话（切到会话面板）")
                .accessibilityIdentifier("indepAgentChatButton.\(agent.id)")
                // 行内模型切换（无 model_name 也可选，兜底「默认」项；模型列表为空不显示）
                if !vm.modelList.isEmpty {
                    Picker("", selection: Binding(
                        get: { agent.model_name ?? "" },
                        set: { vm.switchModel(agent, to: $0) }
                    )) {
                        if agent.model_name == nil {
                            Text("默认").tag("")
                        }
                        ForEach(vm.modelList, id: \.name) { m in
                            Text(m.name).tag(m.name)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .font(.system(size: 11))
                    .frame(maxWidth: 140)
                    .help("切换该独立 Agent 的模型")
                    .accessibilityIdentifier("indepAgentModelSelect.\(agent.id)")
                }
                Button { vm.beginEdit(agent) } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.vRowAction)
                .help("编辑角色设定")
                .accessibilityIdentifier("indepAgentEditButton.\(agent.id)")
                Button { vm.delete(agent) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.vRowAction)
                .foregroundStyle(VTheme.dangerText)
                .help("删除独立 Agent")
                .accessibilityIdentifier("indepAgentDeleteButton.\(agent.id)")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                isSelected ? VTheme.bgCard : (hovering ? VTheme.bgHover : Color.clear),
                in: isEditing
                    ? UnevenRoundedRectangle(topLeadingRadius: VTheme.Radius.s,
                                             bottomLeadingRadius: 0,
                                             bottomTrailingRadius: 0,
                                             topTrailingRadius: VTheme.Radius.s)
                    : UnevenRoundedRectangle(topLeadingRadius: VTheme.Radius.s,
                                             bottomLeadingRadius: VTheme.Radius.s,
                                             bottomTrailingRadius: VTheme.Radius.s,
                                             topTrailingRadius: VTheme.Radius.s)
            )
            .overlay(
                (isEditing
                    ? UnevenRoundedRectangle(topLeadingRadius: VTheme.Radius.s,
                                             bottomLeadingRadius: 0,
                                             bottomTrailingRadius: 0,
                                             topTrailingRadius: VTheme.Radius.s)
                    : UnevenRoundedRectangle(topLeadingRadius: VTheme.Radius.s,
                                             bottomLeadingRadius: VTheme.Radius.s,
                                             bottomTrailingRadius: VTheme.Radius.s,
                                             topTrailingRadius: VTheme.Radius.s))
                .stroke(isSelected ? VTheme.borderDefault : Color.clear)
            )
            .shadow(color: isSelected ? .black.opacity(0.05) : .clear, radius: 1.5, y: 1)
            .contentShape(Rectangle())
            // U2：单击 = 选中 + 直达聊天（对齐原版 selectIndependentAgent 单击即见聊天；
            // 原「双击开始对话」手势随之取消。行内编辑/删除为独立按钮，优先于行点击）
            .onTapGesture { vm.startChat(agent) }
            .onHover { hovering = $0 }

            // 行内角色设定编辑区（贴行下半卡）
            if isEditing {
                VStack(spacing: 6) {
                    TextField("角色设定（system_prompt）：留空保存则清除",
                              text: $vm.editText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(3...6)
                        .vInputStyle()
                        .accessibilityIdentifier("indepAgentPromptEditField")
                    HStack(spacing: 6) {
                        Spacer()
                        Button("取消") { vm.cancelEdit() }
                            .buttonStyle(.vSecondary)
                            .controlSize(.small)
                        Button {
                            vm.savePrompt(agent)
                        } label: {
                            HStack(spacing: 4) {
                                if vm.savingPrompt {
                                    ProgressView().controlSize(.mini)
                                }
                                Text(vm.savingPrompt ? "保存中…" : "保存")
                            }
                        }
                        .buttonStyle(.vPrimary)
                        .controlSize(.small)
                        .disabled(vm.savingPrompt)
                        .accessibilityIdentifier("indepAgentPromptSaveButton")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(VTheme.bgCard,
                            in: UnevenRoundedRectangle(topLeadingRadius: 0,
                                                       bottomLeadingRadius: VTheme.Radius.m,
                                                       bottomTrailingRadius: VTheme.Radius.m,
                                                       topTrailingRadius: 0))
                .overlay(
                    UnevenRoundedRectangle(topLeadingRadius: 0,
                                           bottomLeadingRadius: VTheme.Radius.m,
                                           bottomTrailingRadius: VTheme.Radius.m,
                                           topTrailingRadius: 0)
                    .stroke(VTheme.borderDefault)
                )
            }
        }
        .padding(.vertical, 2)
    }
}
