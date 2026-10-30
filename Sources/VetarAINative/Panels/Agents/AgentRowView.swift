//
//  AgentRowView.swift
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

//  Agent 行共享组件：项目内 Agent（AgentPanelView，数据 SidecarAgent）与独立 Agent
//  （IndependentAgentsPanelView，数据 IndependentAgent）两面板行视图原约 120 行
//  复制粘贴双胞胎（原坐标 AgentPanelView.swift:141-282 /
//  IndependentAgentsPanelView.swift:108-256），本文件收编为单一实现，
//  两处调用点以参数/闭包注入差异。
//
//  已分叉 4 处的取舍（施工清单 P1-10 口径）：
//    1. 选中阴影（独立 Agent 有 / 项目内无）→ 统一无阴影：静止元素不投影，
//       选中态色阶 bgCard + 描边 borderDefault 已够。
//    2. 删除染色（独立 Agent 在 .vRowAction 外叠 dangerText / 项目内无染色）→
//       统一 .vRowActionDanger：外层叠色被样式内层 textSecondary 覆盖是死代码，
//       危险染色收进样式本体（VButtons 波次2 新增变体）。
//    3. 「开始对话」钮（独立 Agent 有 / 项目内无）→ onStartChat 可选闭包参数：
//       功能差异保留，传 nil 即不渲染（项目内 Agent 单击行本体已直达聊天）。
//    4. 行首标识（独立 Agent = person.crop.circle 图标 / 项目内 = 主/子 类型徽标）→
//       leadingIcon / typeBadge 双参数化，互斥不传另一个即可。
//
//  顺带统一项（施工清单 P2-13/14/15 与波次2 口径）：
//    · 行圆角 Radius.s → Radius.m（原行 Radius.s 与编辑半卡 Radius.m 嵌套不匹配）
//    · 「主」徽标 accentBg+accentText → 中性 bgActive+textSecondary（accent 只留
//      一枚克制藏蓝，身份徽标不占强调色）；「子」徽标沿用 bgHover
//    · person.crop.circle / doc.text 图标 accentText → textTertiary
//    · 徽标/模型 Picker 字号 .system(size:11) → Typo.micro；Picker 补 AX 标签「模型」
//    · 编辑区占位文案「角色设定（system_prompt）：…」露后端字段名 →
//      用户语言「角色设定：留空保存则清除」
//    · AX identifier 两面板既有契约不同（agentXxx / indepAgentXxx），
//      accessibilityPrefix + rowId 参数化逐字保留
//

import SwiftUI

/// Agent 行（选中卡态 + 行内操作 + 行内角色设定编辑区）。
/// 纯值+闭包注入，不绑定具体 ViewModel/模型类型——两面板各自把 vm/agent 适配进来。
struct AgentRowView: View {

    // ── 数据面 ──
    let rowId: String
    let name: String
    let hasPrompt: Bool
    let modelName: String?

    // ── 外观参数（分叉 4）──
    /// 行首头像图标（独立 Agent：person.crop.circle）；nil 不显示
    var leadingIcon: String? = nil
    /// 类型徽标文案（项目内 Agent：主/子）；nil 不显示
    var typeBadge: String? = nil
    /// 主 Agent 徽标（中性 bgActive 底）；false = 子 Agent（bgHover 底）
    var typeBadgeIsMain: Bool = false

    // ── 状态 ──
    let isSelected: Bool
    let isEditing: Bool

    // ── 行内模型切换 ──
    let modelList: [OllamaModel]
    /// 是否显示行内模型切换（项目内：model_name != nil；独立：模型列表非空）
    let showsModelPicker: Bool
    /// 独立 Agent：model_name 为空时 Picker 补「默认」兜底项
    var modelPickerHasDefault: Bool = false
    let onChangeModel: (String) -> Void

    // ── 行内操作 ──
    /// 「开始对话」钮（分叉 3：独立 Agent 有，项目内不传）
    var onStartChat: (() -> Void)? = nil
    let onEdit: () -> Void
    let onDelete: () -> Void
    /// 行本体单击（两面板同语义：选中 + 直达聊天）
    let onTap: () -> Void

    // ── 行内编辑区 ──
    let editText: Binding<String>
    let savingPrompt: Bool
    let onSavePrompt: () -> Void
    let onCancelEdit: () -> Void

    // ── AX 契约 ──
    /// identifier 前缀（"agent" / "indepAgent"），逐字保留两面板既有契约
    let accessibilityPrefix: String
    /// help 文案实体名（"Agent" / "独立 Agent"）
    let entityLabel: String

    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            // 行本体
            HStack(spacing: 6) {
                if let typeBadge {
                    // 类型徽标（方向2 波次2：「主」accentBg+accentText → 中性
                    // bgActive+textSecondary——身份徽标不占强调色；字号归 Typo.micro）
                    Text(typeBadge)
                        .font(VTheme.Typo.micro)
                        .foregroundStyle(VTheme.textSecondary)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(typeBadgeIsMain ? VTheme.bgActive : VTheme.bgHover,
                                    in: RoundedRectangle(cornerRadius: 4))
                }
                if let leadingIcon {
                    // 方向2 波次2：行首图标 accentText → textTertiary
                    Image(systemName: leadingIcon)
                        .font(.system(size: 13))
                        .foregroundStyle(VTheme.textTertiary)
                }
                Text(name)
                    .font(VTheme.Typo.body.weight(isSelected ? .medium : .regular))
                    .foregroundStyle(VTheme.textPrimary)
                    .lineLimit(1)
                if hasPrompt {
                    // 方向2 波次2：已设角色设定标记 accentText → textTertiary
                    Image(systemName: "doc.text")
                        .font(.system(size: 11))
                        .foregroundStyle(VTheme.textTertiary)
                        .help("已设角色设定")
                }
                Spacer(minLength: 4)
                // 分叉 3：行内「开始对话」钮（仅独立 Agent 传）
                if let onStartChat {
                    Button(action: onStartChat) {
                        Image(systemName: "bubble.left.and.bubble.right")
                    }
                    .buttonStyle(.vRowAction)
                    .help("开始对话（切到会话面板）")
                    // 方向2 波次4：AX 补账
                    .accessibilityLabel("开始对话")
                    .accessibilityIdentifier("\(accessibilityPrefix)ChatButton.\(rowId)")
                }
                // 行内模型切换（对齐现状 select value={a.model_name}）
                if showsModelPicker {
                    Picker("", selection: Binding(
                        get: { modelName ?? "" },
                        set: onChangeModel
                    )) {
                        if modelPickerHasDefault {
                            Text("默认").tag("")
                        }
                        ForEach(modelList, id: \.name) { m in
                            Text(m.name).tag(m.name)
                        }
                    }
                    .labelsHidden()
                    // 方向2 波次2：labelsHidden 的 Picker 补 AX 标签
                    .accessibilityLabel("模型")
                    .pickerStyle(.menu)
                    .font(VTheme.Typo.micro)     // 方向2 波次2：.system(size:11) 归 Typo 档
                    .frame(maxWidth: 140)
                    .help("切换该\(entityLabel)的模型")
                    .accessibilityIdentifier("\(accessibilityPrefix)ModelSelect.\(rowId)")
                }
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.vRowAction)
                .help("编辑角色设定")
                .accessibilityLabel("编辑角色设定")
                .accessibilityIdentifier("\(accessibilityPrefix)EditButton.\(rowId)")
                Button(action: onDelete) {
                    Image(systemName: "trash")
                }
                // 分叉 2：统一 .vRowActionDanger（染色在样式本体生效）
                .buttonStyle(.vRowActionDanger)
                .help("删除\(entityLabel)")
                .accessibilityLabel("删除\(entityLabel)")
                .accessibilityIdentifier("\(accessibilityPrefix)DeleteButton.\(rowId)")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                isSelected ? VTheme.bgCard : (hovering ? VTheme.bgHover : Color.clear),
                in: rowShape
            )
            .overlay(
                rowShape.stroke(isSelected ? VTheme.borderDefault : Color.clear)
            )
            // 分叉 1：统一无阴影（静止元素不投影）
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .onHover { hovering = $0 }

            // 行内编辑区（贴行下半卡）
            if isEditing {
                VStack(spacing: 6) {
                    // 方向2 波次2：占位文案去后端字段名 system_prompt → 用户语言
                    TextField("角色设定：留空保存则清除",
                              text: editText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(3...6)
                        .vInputStyle()
                        .accessibilityIdentifier("\(accessibilityPrefix)PromptEditField")
                    HStack(spacing: 6) {
                        Spacer()
                        Button("取消", action: onCancelEdit)
                            .buttonStyle(.vSecondary)
                        Button(action: onSavePrompt) {
                            HStack(spacing: 4) {
                                if savingPrompt {
                                    ProgressView().controlSize(.mini)
                                }
                                Text(savingPrompt ? "保存中…" : "保存")
                            }
                        }
                        .buttonStyle(.vPrimary)
                        .disabled(savingPrompt)
                        .accessibilityIdentifier("\(accessibilityPrefix)PromptSaveButton")
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

    /// 行本体圆角形状（编辑中只留上圆角贴下半卡）。
    /// 方向2 波次2：Radius.s → Radius.m，与编辑半卡 Radius.m 嵌套一致。
    private var rowShape: UnevenRoundedRectangle {
        isEditing
            ? UnevenRoundedRectangle(topLeadingRadius: VTheme.Radius.m,
                                     bottomLeadingRadius: 0,
                                     bottomTrailingRadius: 0,
                                     topTrailingRadius: VTheme.Radius.m)
            : UnevenRoundedRectangle(topLeadingRadius: VTheme.Radius.m,
                                     bottomLeadingRadius: VTheme.Radius.m,
                                     bottomTrailingRadius: VTheme.Radius.m,
                                     topTrailingRadius: VTheme.Radius.m)
    }
}
