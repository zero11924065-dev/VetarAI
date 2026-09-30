//
//  ProjectPanelView.swift
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

//  项目组面板内容（对标 subagent/renderer/src/panels/ProjectPanel.tsx，415 行）：
//    · 标题行：「项目」+ 新建项目按钮（loading/error 时禁用；loading 转圈）
//    · 错误条：连接错误附手动「重试」（checkpoint-064）
//    · 通知条：工作组导出结果闪示（「导出失败」前缀 = error 样式，否则 success）
//    · 手动目录输入卡片（目录选择器不可用的内联 fallback，Enter 提交 / 留空取消）
//    · 项目列表（限高 30vh 独立滚动，ProjectPanel.tsx:326）：空态 / 加载中 /
//      行（选中卡态 + 悬停操作：查看根目录 / 导出工作组 / 重命名 / 删除）+
//      行内改名编辑区（Enter 保存 / Esc 取消）
//  V1（智能中心侧栏单栏堆叠复刻）：整页面板壳移除——本文件只提供侧栏分区内容
//  视图 `ProjectPanelContentView`（原版 ProjectPanel 无折叠壳，App.tsx:234 直接渲染）；
//  VM 生命周期随侧栏分区挂载。
//  文案逐字对齐现状实现；视觉用 VTheme 近似（接入指南 §3）。
//

import SwiftUI

/// 延迟构建 ProjectPanelViewModel（需要已注入的 AppState）。
@MainActor
final class ProjectPanelViewModelBox: ObservableObject {
    @Published var vm: ProjectPanelViewModel?
    func attach(appState: AppState) {
        if vm == nil { vm = ProjectPanelViewModel(appState: appState) }
    }
}

/// 项目区内容（原版 ProjectPanel.tsx:262-413 整段：标题行 + 提示条 + 手动输入 + 限高列表）。
/// VM start/stop 由侧栏分区驱动。
struct ProjectPanelContentView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var vm: ProjectPanelViewModel
    /// 侧栏视口高（原版列表限高 30vh，ProjectPanel.tsx:326）
    let viewportHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // ── 面板标题行 ──
            HStack {
                Text("项目")
                    .font(VTheme.Typo.panelTitle)
                    .foregroundStyle(VTheme.textSecondary)
                Spacer()
                Button {
                    vm.create()
                } label: {
                    HStack(spacing: 4) {
                        if vm.loading {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "plus")
                        }
                        Text("新建项目")
                    }
                }
                .buttonStyle(.vGhost)
                .controlSize(.small)
                .disabled(vm.loading || vm.error != nil)
                .accessibilityIdentifier("projectCreateButton")
            }

            // ── 错误提示条（连接错误附手动重试，checkpoint-064）──
            if let error = vm.error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: VCalloutKind.error.icon)
                        .font(.system(size: 12))
                        .padding(.top, 1)
                    Text(error)
                        .font(VTheme.Typo.body)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if error.contains("无法连接") {
                        Button {
                            vm.retry()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.clockwise")
                                Text("重试")
                            }
                        }
                        .buttonStyle(.vSecondary)
                        .controlSize(.small)
                        .accessibilityIdentifier("projectRetryButton")
                    }
                }
                .foregroundStyle(VCalloutKind.error.foreground)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(VCalloutKind.error.background,
                            in: RoundedRectangle(cornerRadius: VTheme.Radius.s))
                .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.s)
                    .stroke(VCalloutKind.error.border))
            }

            // ── 工作组导出结果闪示（TS-121：前缀「导出失败」= error 样式）──
            if let notice = vm.notice {
                VCallout(notice.hasPrefix("导出失败") ? .error : .success, notice)
                    .accessibilityIdentifier("projectNoticeCallout")
            }

            // ── 手动输入工作目录（内联 fallback；留空 = 取消）──
            if vm.manualMode {
                VStack(alignment: .leading, spacing: 6) {
                    Text("请输入项目工作目录的绝对路径（留空取消）：")
                        .font(VTheme.Typo.caption)
                        .foregroundStyle(VTheme.textSecondary)
                    HStack(spacing: 6) {
                        TextField("/Users/you/projects/demo", text: $vm.manualPath)
                            .textFieldStyle(.plain)
                            .vInputStyle()
                            .onSubmit { vm.createManual() }
                            .accessibilityIdentifier("projectManualPathField")
                        Button("确定") { vm.createManual() }
                            .buttonStyle(.vPrimary)
                            .controlSize(.small)
                            .accessibilityIdentifier("projectManualConfirmButton")
                        Button("取消") { vm.cancelManual() }
                            .buttonStyle(.vSecondary)
                            .controlSize(.small)
                            .accessibilityIdentifier("projectManualCancelButton")
                    }
                }
                .padding(10)
                .background(VTheme.bgCard, in: RoundedRectangle(cornerRadius: VTheme.Radius.m))
                .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.m).stroke(VTheme.borderDefault))
            }

            // ── 项目列表：独立滚动区（限高 30vh，ProjectPanel.tsx:326）──
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if vm.projects.isEmpty && vm.error == nil && !vm.loading {
                        // 空态
                        VStack(spacing: 8) {
                            Image(systemName: "folder")
                                .font(.system(size: 30))
                                .foregroundStyle(VTheme.borderStrong)
                            Text("暂无项目，点击上方按钮创建")
                                .font(VTheme.Typo.body)
                                .foregroundStyle(VTheme.textTertiary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    } else if vm.loading && vm.projects.isEmpty {
                        // 加载中
                        VStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("加载中…")
                                .font(VTheme.Typo.caption)
                                .foregroundStyle(VTheme.textTertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    } else {
                        ForEach(vm.projects, id: \.id) { project in
                            ProjectRowView(project: project, vm: vm,
                                           isSelected: appState.currentProjectId == project.id)
                        }
                    }
                }
            }
            .frame(maxHeight: viewportHeight * 0.30)
        }
        // 原版外层 padding: 8（ProjectPanel.tsx:265）
        .padding(8)
    }
}

// MARK: - 项目行（选中卡态 + 悬停操作 + 行内改名编辑区）

private struct ProjectRowView: View {
    let project: SidecarProject
    @ObservedObject var vm: ProjectPanelViewModel
    let isSelected: Bool
    @State private var hovering = false

    private var isRenaming: Bool { vm.renamingId == project.id }

    var body: some View {
        HStack(spacing: 6) {
            if isRenaming {
                // M5（TS-111）：行内改名编辑框（Enter 保存 / Esc 取消）
                TextField("项目名称", text: $vm.renameValue)
                    .textFieldStyle(.plain)
                    .vInputStyle()
                    .onSubmit { vm.saveRename(project) }
                    .onExitCommand { vm.cancelRename() }
                    .accessibilityIdentifier("projectRenameField")
                Button("保存") { vm.saveRename(project) }
                    .buttonStyle(.vPrimary)
                    .controlSize(.small)
                    .accessibilityIdentifier("projectRenameSaveButton")
                Button("取消") { vm.cancelRename() }
                    .buttonStyle(.vSecondary)
                    .controlSize(.small)
                    .accessibilityIdentifier("projectRenameCancelButton")
            } else {
                Image(systemName: "folder")
                    .font(.system(size: 13))
                    .foregroundStyle(VTheme.textTertiary)
                Text(project.name)
                    .font(VTheme.Typo.body.weight(isSelected ? .medium : .regular))
                    .foregroundStyle(VTheme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                // 悬停操作（对齐现状 opacity 0→1）
                HStack(spacing: 2) {
                    // 问题1联动：明显的「去对话」入口（选中 + 切到会话面板）
                    Button {
                        vm.startChat(project)
                    } label: {
                        Image(systemName: "bubble.left.and.bubble.right")
                    }
                    .buttonStyle(.vRowAction)
                    .help("去对话（切到会话面板，落到主 Agent）")
                    .accessibilityIdentifier("projectChatButton.\(project.id)")
                    // 0.4.5：查看项目工作根目录（Finder 打开）
                    Button {
                        vm.openWorkingDir(project)
                    } label: {
                        if vm.openingDirId == project.id {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.up.forward.square")
                        }
                    }
                    .buttonStyle(.vRowAction)
                    .help("查看根目录")
                    .accessibilityIdentifier("projectOpenDirButton.\(project.id)")
                    // TS-121（0.3.1 补遗2）：工作组 JSON 导出
                    Button {
                        vm.exportWorkgroup(project)
                    } label: {
                        if vm.exportingId == project.id {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "square.and.arrow.down")
                        }
                    }
                    .buttonStyle(.vRowAction)
                    .help("导出工作组（JSON：项目+Agent+会话+任务+圆桌）")
                    .accessibilityIdentifier("projectExportButton.\(project.id)")
                    Button {
                        vm.beginRename(project)
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.vRowAction)
                    .help("重命名")
                    .accessibilityIdentifier("projectRenameButton.\(project.id)")
                    Button {
                        vm.delete(project)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.vRowAction)
                    .foregroundStyle(VTheme.dangerText)
                    .help("删除")
                    .accessibilityIdentifier("projectDeleteButton.\(project.id)")
                }
                .opacity(hovering || isSelected ? 1 : 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            isSelected ? VTheme.bgCard : (hovering ? VTheme.bgHover : Color.clear),
            in: RoundedRectangle(cornerRadius: VTheme.Radius.s)
        )
        .overlay(
            RoundedRectangle(cornerRadius: VTheme.Radius.s)
                .stroke(isSelected ? VTheme.borderDefault : Color.clear)
        )
        .shadow(color: isSelected ? .black.opacity(0.05) : .clear, radius: 1.5, y: 1)
        .contentShape(Rectangle())
        // 单击 = 选中（现状 onSelect）；双击 = 去对话（问题1联动入口之二）
        .onTapGesture(count: 2) {
            if !isRenaming { vm.startChat(project) }
        }
        .onTapGesture(count: 1) {
            if !isRenaming { vm.select(project) }
        }
        .onHover { hovering = $0 }
        .padding(.vertical, 2)
    }
}
