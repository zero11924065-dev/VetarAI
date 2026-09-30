//
//  KnowledgePanelView.swift
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

//  知识记忆面板（SwiftUI 移植，对标 KnowledgePanel.tsx，540 行）：
//    · 标题行 + 未选项目提示条 + 四标签连排（知识库 / 知识仓库 / 记忆 / 技能）
//    · 知识库：说明行 + 错误条 + 新建行 + 列表（状态点/启停胶囊/编辑/删除）
//      + 行内编辑区（TextEditor + 保存/取消）；未选项目 → 引导空态
//    · 知识仓库：嵌入 WarehouseManagerView（资产管理器，见 Panels/Warehouse/）
//    · 记忆：全局/项目两张卡（说明行 + 消息条 + TextEditor + 保存按钮）
//    · 技能：说明行 + 错误条 + 安装/新建行 + 表单卡 + 列表
//  文案逐字对齐现状实现；视觉用 VTheme 近似（接入指南 §3）。
//

import SwiftUI

// MARK: - 面板入口

public struct KnowledgePanelView: View {
    @EnvironmentObject private var appState: AppState
    @State private var tab: KnowledgeTab = .knowledge

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // 标题
                HStack(spacing: 8) {
                    Image(systemName: "book")
                        .font(.system(size: 14))
                        .foregroundStyle(VTheme.textPrimary)
                    Text("知识记忆")
                        .font(VTheme.Typo.sectionTitle)
                        .foregroundStyle(VTheme.textPrimary)
                }

                // 未选项目提示条
                if appState.currentProjectId == nil {
                    VCallout(.info, "当前未选择项目：「记忆」标签可管理全局记忆，「技能」全局可用；「知识库」与「项目记忆」需先在主界面选择一个项目。")
                        .accessibilityIdentifier("knowledge.noProject")
                }

                // 标签头：四标签连排
                KnowledgeTabBar(tab: $tab)

                // 标签内容（切换即重建视图与 VM——对齐 TSX 条件渲染卸载语义）
                switch tab {
                case .knowledge:
                    KnowledgeTabView()
                case .warehouse:
                    WarehouseManagerView(embedded: true)
                case .memory:
                    MemoryTabView()
                case .skills:
                    SkillsTabView()
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VTheme.bgApp)
    }
}

// MARK: - 标签定义与连排头

public enum KnowledgeTab: String, CaseIterable {
    case knowledge, warehouse, memory, skills

    var label: String {
        switch self {
        case .knowledge: return "知识库"
        case .warehouse: return "知识仓库"
        case .memory: return "记忆"
        case .skills: return "技能"
        }
    }

    var icon: String {
        switch self {
        case .knowledge: return "book"
        case .warehouse, .memory: return "cylinder"   // TSX: database
        case .skills: return "wrench.and.screwdriver"
        }
    }
}

/// 四标签连排头（对齐 TSX：flex 1 等分、30pt 高、相邻边框重叠 -1、
/// 选中白底 + 底部 2pt 强调色、两端圆角）。
private struct KnowledgeTabBar: View {
    @Binding var tab: KnowledgeTab
    private let tabs = KnowledgeTab.allCases

    var body: some View {
        HStack(spacing: -1) {
            ForEach(Array(tabs.enumerated()), id: \.element) { idx, t in
                let selected = tab == t
                Button {
                    tab = t
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: t.icon).font(.system(size: 12))
                        Text(t.label).font(.system(size: 13, weight: selected ? .medium : .regular))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .foregroundStyle(selected ? VTheme.accentText : VTheme.textSecondary)
                    .background(selected ? VTheme.bgCard : VTheme.bgHover)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(selected ? VTheme.accent : VTheme.borderStrong)
                            .frame(height: selected ? 2 : 1)
                    }
                    .overlay {
                        UnevenRoundedRectangle(
                            topLeadingRadius: idx == 0 ? VTheme.Radius.s : 0,
                            bottomLeadingRadius: 0,
                            bottomTrailingRadius: 0,
                            topTrailingRadius: idx == tabs.count - 1 ? VTheme.Radius.s : 0
                        )
                        .stroke(VTheme.borderStrong)
                    }
                }
                .buttonStyle(.plain)
                .frame(height: 30)
                .zIndex(selected ? 1 : 0)
                .accessibilityIdentifier("knowledge.tab.\(t.rawValue)")
            }
        }
    }
}

// MARK: - 共享小件（本面板族内复用）

/// 胶囊状态按钮（对齐 TSX capsuleBtn：22pt 高、11 号字、on=强调底/关=灰底）。
struct VCapsuleButton: View {
    let on: Bool
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(on ? VTheme.accentBg : VTheme.bgHover, in: Capsule())
                .foregroundStyle(on ? VTheme.accentText : VTheme.textSecondary)
        }
        .buttonStyle(.plain)
    }
}

/// 卡片容器（对齐 theme.ts cardL：白底 + 细分隔边框 + 12 圆角 + 内边距）。
struct VCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VTheme.bgCard, in: RoundedRectangle(cornerRadius: VTheme.Radius.l))
        .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.l).stroke(VTheme.borderSubtle))
    }
}

/// 多行文本编辑（对齐 theme.ts textarea 观感：白底强边框圆角）。
struct VTextArea: View {
    @Binding var text: String
    var minHeight: CGFloat = 160

    var body: some View {
        TextEditor(text: $text)
            .font(VTheme.Typo.body)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(minHeight: minHeight)
            .background(VTheme.bgCard, in: RoundedRectangle(cornerRadius: VTheme.Radius.s))
            .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.s).stroke(VTheme.borderStrong))
    }
}

// MARK: - 知识库标签页

private struct KnowledgeTabView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var vmBox = KnowledgeTabViewModelBox()

    var body: some View {
        if let vm = vmBox.vm {
            KnowledgeTabBody(vm: vm, runtime: appState.runtime,
                             projectId: appState.currentProjectId)
        } else {
            VLoadingView("知识库初始化…")
                .frame(minHeight: 120)
                .task { vmBox.attach(appState: appState) }
        }
    }
}

@MainActor
final class KnowledgeTabViewModelBox: ObservableObject {
    @Published var vm: KnowledgeTabViewModel?
    func attach(appState: AppState) {
        if vm == nil { vm = KnowledgeTabViewModel(appState: appState) }
    }
}

private struct KnowledgeTabBody: View {
    @ObservedObject var vm: KnowledgeTabViewModel
    @ObservedObject var runtime: NativeRuntime
    let projectId: String?

    var body: some View {
        Group {
            if projectId == nil {
                // 未选项目引导空态
                VStack(spacing: 8) {
                    Image(systemName: "book")
                        .font(.system(size: 36))
                        .foregroundStyle(VTheme.borderStrong)
                    Text("请先在主界面选择一个项目，即可管理该项目的知识库（项目文件夹/knowledge/）。")
                        .font(VTheme.Typo.body)
                        .foregroundStyle(VTheme.textTertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                VCard {
                    Text("知识文件存放在项目文件夹的 knowledge/ 目录，对话时自动注入给 Agent（以 _ 开头的文件不注入）。")
                        .font(VTheme.Typo.caption)
                        .foregroundStyle(VTheme.textTertiary)
                        .lineSpacing(3)
                        .padding(.bottom, 12)

                    if let error = vm.error {
                        VCallout(.error, error)
                            .accessibilityIdentifier("knowledge.error")
                            .padding(.bottom, 12)
                    }

                    // 新建行
                    HStack(spacing: 8) {
                        TextField("新知识文件名（.md）", text: $vm.newName)
                            .textFieldStyle(.plain)
                            .vInputStyle()
                            .accessibilityIdentifier("knowledge.newName")
                        Button {
                            vm.createNew()
                        } label: {
                            HStack(spacing: 4) {
                                if vm.busy {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "plus").font(.system(size: 12))
                                }
                                Text("新建")
                            }
                        }
                        .buttonStyle(.vSecondary)
                        .controlSize(.small)
                        .disabled(vm.busy)
                        .accessibilityIdentifier("knowledge.create")
                    }
                    .padding(.bottom, 12)

                    if vm.items.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 36))
                                .foregroundStyle(VTheme.borderStrong)
                            Text("暂无知识文件")
                                .font(VTheme.Typo.body)
                                .foregroundStyle(VTheme.textTertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    }

                    ForEach(vm.items, id: \.name) { item in
                        VStack(spacing: 0) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(item.enabled ? VTheme.ok : VTheme.borderStrong)
                                    .frame(width: 8, height: 8)
                                Text(item.name)
                                    .font(VTheme.Typo.body)
                                    .foregroundStyle(item.enabled ? VTheme.textPrimary : VTheme.textTertiary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                VCapsuleButton(on: item.enabled,
                                               label: item.enabled ? "启用" : "禁用") {
                                    vm.toggle(item.name)
                                }
                                Button {
                                    vm.openEdit(item.name)
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "pencil").font(.system(size: 11))
                                        Text("编辑")
                                    }
                                }
                                .buttonStyle(.vGhost)
                                .controlSize(.small)
                                .accessibilityIdentifier("knowledge.edit.\(item.name)")
                                Button(role: .destructive) {
                                    vm.remove(item.name)
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "trash").font(.system(size: 11))
                                        Text("删除")
                                    }
                                }
                                .buttonStyle(.vGhost)
                                .controlSize(.small)
                                .foregroundStyle(VTheme.dangerText)
                                .accessibilityIdentifier("knowledge.delete.\(item.name)")
                            }
                            .padding(.vertical, 6)
                            .opacity(item.enabled ? 1 : 0.6)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(VTheme.borderSubtle).frame(height: 1)
                            }

                            // 行内编辑区
                            if vm.editing == item.name {
                                VStack(alignment: .leading, spacing: 6) {
                                    VTextArea(text: $vm.editContent, minHeight: 160)
                                    HStack(spacing: 8) {
                                        Button {
                                            vm.saveEdit(item.name)
                                        } label: {
                                            HStack(spacing: 4) {
                                                if vm.busy { ProgressView().controlSize(.small) }
                                                Text("保存")
                                            }
                                        }
                                        .buttonStyle(.vSecondary)
                                        .controlSize(.small)
                                        .disabled(vm.busy)
                                        Button("取消") { vm.cancelEdit() }
                                            .buttonStyle(.vGhost)
                                            .controlSize(.small)
                                    }
                                }
                                .padding(.vertical, 8)
                            }
                        }
                    }
                }
            }
        }
        .onAppear { vm.start() }
        .onDisappear { vm.stop() }
        // P3-W6⑤：nativeReady 于 runtime init 同步点亮、任何视图出现前恒 true，
        // 旧「就绪自愈」onChange（永不触发）随侧车归零删除——首拉在挂载链路上。
        .onChange(of: projectId) { _, _ in vm.onProjectChanged() }
    }
}

// MARK: - 记忆标签页

private struct MemoryTabView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var vmBox = MemoryTabViewModelBox()

    var body: some View {
        if let vm = vmBox.vm {
            MemoryTabBody(vm: vm, projectId: appState.currentProjectId)
        } else {
            VLoadingView("记忆初始化…")
                .frame(minHeight: 120)
                .task { vmBox.attach(appState: appState) }
        }
    }
}

@MainActor
final class MemoryTabViewModelBox: ObservableObject {
    @Published var vm: MemoryTabViewModel?
    func attach(appState: AppState) {
        if vm == nil { vm = MemoryTabViewModel(appState: appState) }
    }
}

private struct MemoryTabBody: View {
    @ObservedObject var vm: MemoryTabViewModel
    let projectId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // 全局记忆卡
            VCard {
                Text("记忆是 Agent 的持久信息。以\"禁止/不得/不允许/严禁\"开头的行会进入红线（必须遵守）。与知识库冲突时，以记忆为准；项目记忆与全局记忆冲突时，以项目记忆为准。")
                    .font(VTheme.Typo.caption)
                    .foregroundStyle(VTheme.textTertiary)
                    .lineSpacing(3)
                    .padding(.bottom, 12)

                if let msg = vm.msg {
                    VCallout(vm.msgIsError ? .error : .success, msg)
                        .accessibilityIdentifier("memory.msg")
                        .padding(.bottom, 12)
                }

                HStack(spacing: 6) {
                    Image(systemName: "globe")
                        .font(.system(size: 12))
                        .foregroundStyle(VTheme.accentText)
                    Text("全局记忆（所有项目生效，存于数据目录）")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(VTheme.textPrimary)
                }
                .padding(.bottom, 8)

                VTextArea(text: $vm.globalMem, minHeight: 120)
                    .accessibilityIdentifier("memory.global")

                Button {
                    vm.save(scope: "global")
                } label: {
                    HStack(spacing: 4) {
                        if vm.busy { ProgressView().controlSize(.small) }
                        Text("保存全局记忆")
                    }
                }
                .buttonStyle(.vSecondary)
                .controlSize(.small)
                .disabled(vm.busy)
                .padding(.top, 8)
                .accessibilityIdentifier("memory.saveGlobal")
            }

            // 项目记忆卡
            VCard {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                        .foregroundStyle(VTheme.accentText)
                    Text("项目记忆（仅本项目，存于项目文件夹 memory.md）")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(VTheme.textPrimary)
                }
                .padding(.bottom, 8)

                if projectId != nil {
                    VTextArea(text: $vm.projectMem, minHeight: 120)
                        .accessibilityIdentifier("memory.project")

                    Button {
                        vm.save(scope: "project")
                    } label: {
                        HStack(spacing: 4) {
                            if vm.busy { ProgressView().controlSize(.small) }
                            Text("保存项目记忆")
                        }
                    }
                    .buttonStyle(.vSecondary)
                    .controlSize(.small)
                    .disabled(vm.busy)
                    .padding(.top, 8)
                    .accessibilityIdentifier("memory.saveProject")
                } else {
                    VCallout(.info, "未选择项目：请先在主界面选择一个项目，即可编辑项目记忆。")
                }
            }
        }
        .onAppear { vm.load() }
        .onChange(of: projectId) { _, _ in vm.load() }
    }
}

// MARK: - 技能标签页

private struct SkillsTabView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var vmBox = SkillsTabViewModelBox()

    var body: some View {
        if let vm = vmBox.vm {
            SkillsTabBody(vm: vm)
        } else {
            VLoadingView("技能初始化…")
                .frame(minHeight: 120)
                .task { vmBox.attach(appState: appState) }
        }
    }
}

@MainActor
final class SkillsTabViewModelBox: ObservableObject {
    @Published var vm: SkillsTabViewModel?
    func attach(appState: AppState) {
        if vm == nil { vm = SkillsTabViewModel(appState: appState) }
    }
}

private struct SkillsTabBody: View {
    @ObservedObject var vm: SkillsTabViewModel

    var body: some View {
        VCard {
            Text("技能（SKILL.md）是 Agent 按需引用的指令集：启用后出现在提示词清单，Agent 需要时调 read_skill 读取正文。")
                .font(VTheme.Typo.caption)
                .foregroundStyle(VTheme.textTertiary)
                .lineSpacing(3)
                .padding(.bottom, 12)

            if let error = vm.error {
                VCallout(.error, error)
                    .accessibilityIdentifier("skills.error")
                    .padding(.bottom, 12)
            }

            // 安装 + 新建行
            HStack(spacing: 8) {
                TextField("从仓库/本地路径安装（含 SKILL.md）", text: $vm.installUrl)
                    .textFieldStyle(.plain)
                    .vInputStyle()
                    .accessibilityIdentifier("skills.installUrl")
                Button {
                    vm.install()
                } label: {
                    HStack(spacing: 4) {
                        if vm.busy { ProgressView().controlSize(.small) }
                        Text("安装")
                    }
                }
                .buttonStyle(.vSecondary)
                .controlSize(.small)
                .disabled(vm.busy)
                .accessibilityIdentifier("skills.install")
                Button {
                    vm.toggleCreating()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus").font(.system(size: 12))
                        Text("新建")
                    }
                }
                .buttonStyle(.vPrimary)
                .controlSize(.small)
                .accessibilityIdentifier("skills.new")
            }
            .padding(.bottom, 12)

            // 新建/编辑表单卡
            if vm.formVisible {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("技能名（字母/数字/中文/-/_）", text: $vm.form.name)
                        .textFieldStyle(.plain)
                        .vInputStyle()
                        .disabled(vm.editing != nil)   // 编辑态名不可改（对齐 TSX disabled）
                        .accessibilityIdentifier("skills.form.name")
                    TextField("一句话描述（何时用这个技能）", text: $vm.form.description)
                        .textFieldStyle(.plain)
                        .vInputStyle()
                        .accessibilityIdentifier("skills.form.description")
                    VTextArea(text: $vm.form.body, minHeight: 160)
                        .accessibilityIdentifier("skills.form.body")
                    HStack(spacing: 8) {
                        Button {
                            vm.save()
                        } label: {
                            HStack(spacing: 4) {
                                if vm.busy { ProgressView().controlSize(.small) }
                                Text("保存")
                            }
                        }
                        .buttonStyle(.vSecondary)
                        .controlSize(.small)
                        .disabled(vm.busy)
                        .accessibilityIdentifier("skills.form.save")
                        Button("取消") { vm.cancelForm() }
                            .buttonStyle(.vGhost)
                            .controlSize(.small)
                    }
                }
                .padding(12)
                .background(VTheme.bgCard, in: RoundedRectangle(cornerRadius: VTheme.Radius.m))
                .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.m).stroke(VTheme.borderDefault))
                .padding(.bottom, 12)
            }

            if vm.skills.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 36))
                        .foregroundStyle(VTheme.borderStrong)
                    Text("暂无技能")
                        .font(VTheme.Typo.body)
                        .foregroundStyle(VTheme.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }

            ForEach(vm.skills, id: \.dir_name) { skill in
                HStack(spacing: 8) {
                    Circle()
                        .fill(skill.enabled ? VTheme.ok : VTheme.borderStrong)
                        .frame(width: 8, height: 8)
                    Text(skill.name)
                        .font(VTheme.Typo.body)
                        .foregroundStyle(skill.enabled ? VTheme.textPrimary : VTheme.textTertiary)
                    Text(skill.description)
                        .font(VTheme.Typo.caption)
                        .foregroundStyle(VTheme.textTertiary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    VCapsuleButton(on: skill.enabled,
                                   label: skill.enabled ? "启用" : "禁用") {
                        vm.toggle(skill.dir_name)
                    }
                    Button {
                        vm.openEdit(skill.dir_name)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "pencil").font(.system(size: 11))
                            Text("编辑")
                        }
                    }
                    .buttonStyle(.vGhost)
                    .controlSize(.small)
                    .accessibilityIdentifier("skills.edit.\(skill.dir_name)")
                    Button(role: .destructive) {
                        vm.remove(skill.dir_name)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trash").font(.system(size: 11))
                            Text("删除")
                        }
                    }
                    .buttonStyle(.vGhost)
                    .controlSize(.small)
                    .foregroundStyle(VTheme.dangerText)
                    .accessibilityIdentifier("skills.delete.\(skill.dir_name)")
                }
                .padding(.vertical, 6)
                .opacity(skill.enabled ? 1 : 0.6)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(VTheme.borderSubtle).frame(height: 1)
                }
            }
        }
        .onAppear { vm.refresh() }
    }
}
