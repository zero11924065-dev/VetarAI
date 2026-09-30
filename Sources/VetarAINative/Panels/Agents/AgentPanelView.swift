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
//    · Agent 列表行：类型徽标（主/子）+ 名称 + 已设角色设定标记 +
//      行内模型切换 + 编辑角色设定 + 删除（确认弹窗）
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                // ── 面板标题行 ──
                HStack {
                    Text("Agent")
                        .font(VTheme.Typo.panelTitle)
                        .foregroundStyle(VTheme.textSecondary)
                    Spacer()
                }
                .padding(.bottom, 0)

                // ── 创建表单卡片 ──
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        TextField("Agent 名称", text: $vm.newName)
                            .textFieldStyle(.plain)
                            .vInputStyle()
                            .onSubmit { vm.create() }
                            .accessibilityIdentifier("agentNameField")
                        Picker("", selection: $vm.newType) {
                            Text("主Agent").tag("main")
                            Text("子Agent").tag("sub")
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 96)
                        .accessibilityIdentifier("agentTypePicker")
                    }
                    HStack(spacing: 6) {
                        if vm.modelList.isEmpty {
                            // 模型未加载：禁用态（对齐现状「模型加载中…」）
                            Text("模型加载中…")
                                .font(VTheme.Typo.body)
                                .foregroundStyle(VTheme.textTertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .vInputStyle()
                        } else {
                            Picker("", selection: $vm.selectedModel) {
                                Text("模型（默认首个）").tag("")
                                ForEach(vm.modelList, id: \.name) { m in
                                    Text(m.name).tag(m.name)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .accessibilityIdentifier("agentModelPicker")
                        }
                        Button {
                            vm.create()
                        } label: {
                            HStack(spacing: 4) {
                                if vm.creating {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: "plus")
                                }
                                Text(vm.creating ? "创建中…" : "添加")
                            }
                        }
                        .buttonStyle(.vPrimary)
                        .controlSize(.small)
                        .disabled(vm.creating)
                        .accessibilityIdentifier("agentCreateButton")
                    }
                    // 创建时可选填角色设定（随对话注入模型）
                    TextField("角色设定（可选）：如「你是严谨的代码审查员」，随对话注入模型",
                              text: $vm.newPrompt, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(2...4)
                        .vInputStyle()
                        .accessibilityIdentifier("agentPromptField")
                }
                .padding(12)
                .background(VTheme.bgCard, in: RoundedRectangle(cornerRadius: VTheme.Radius.m))
                .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.m).stroke(VTheme.borderDefault))

                // ── 空态 ──
                if vm.agents.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "person.2")
                            .font(.system(size: 30))
                            .foregroundStyle(VTheme.borderStrong)
                        Text("暂无 Agent，先在上方填写并点\"+ 添加\"创建")
                            .font(VTheme.Typo.body)
                            .foregroundStyle(VTheme.textTertiary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }

                // ── Agent 列表 ──
                ForEach(vm.agents, id: \.id) { agent in
                    AgentRowView(agent: agent, vm: vm,
                                 isSelected: appState.currentAgentId == agent.id)
                }
            }
            .padding(12)
        }
    }
}

// MARK: - Agent 行（选中卡态 + 行内操作 + 行内编辑区）

private struct AgentRowView: View {
    let agent: SidecarAgent
    @ObservedObject var vm: AgentPanelViewModel
    let isSelected: Bool
    @State private var hovering = false

    private var isEditing: Bool { vm.editingId == agent.id }

    var body: some View {
        VStack(spacing: 0) {
            // 行本体
            HStack(spacing: 6) {
                // 类型徽标
                Text(agent.type_ == "main" ? "主" : "子")
                    .font(.system(size: 11))
                    .foregroundStyle(agent.type_ == "main" ? VTheme.accentText : VTheme.textSecondary)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(agent.type_ == "main" ? VTheme.accentBg : VTheme.bgHover,
                                in: RoundedRectangle(cornerRadius: 4))
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
                // 行内模型切换（对齐现状 select value={a.model_name}）
                if agent.model_name != nil {
                    Picker("", selection: Binding(
                        get: { agent.model_name ?? "" },
                        set: { vm.changeModel(agent, to: $0) }
                    )) {
                        ForEach(vm.modelList, id: \.name) { m in
                            Text(m.name).tag(m.name)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .font(.system(size: 11))
                    .frame(maxWidth: 140)
                    .help("切换该 Agent 的模型")
                    .accessibilityIdentifier("agentModelSelect.\(agent.id)")
                }
                Button { vm.beginEdit(agent) } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.vRowAction)
                .help("编辑角色设定")
                .accessibilityIdentifier("agentEditButton.\(agent.id)")
                Button { vm.delete(agent) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.vRowAction)
                .help("删除 Agent")
                .accessibilityIdentifier("agentDeleteButton.\(agent.id)")
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
            .contentShape(Rectangle())
            // U2：单击 = 选中 + 直达聊天（原版 selectAgent 单击即见聊天；
            // 行内编辑/删除/切模型为独立按钮，优先于行点击，不冲突）
            .onTapGesture { vm.startChat(agent) }
            .onHover { hovering = $0 }

            // 行内编辑区（贴行下半卡）
            if isEditing {
                VStack(spacing: 6) {
                    TextField("角色设定（system_prompt）：留空保存则清除",
                              text: $vm.editText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(3...6)
                        .vInputStyle()
                        .accessibilityIdentifier("agentPromptEditField")
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
                        .accessibilityIdentifier("agentPromptSaveButton")
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
