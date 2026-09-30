//
//  PluginsPanelView.swift
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

//  插件管理面板（对标 PluginPanel.tsx 419 行；现状挂在设置页「插件与技能」分区）：
//    · 标题行「插件管理」
//    · 安装区：仓库地址/本地路径输入 + 安装按钮（Enter 提交；远端 URL 走联网安装
//      确认链——每次必弹、无记忆按钮、境外来源附全量联网勾选，见 ViewModel）
//    · 插件列表：名称 + 版本（mono）+ 启用/禁用开关 + 卸载（danger 确认）+
//      备注区（用户备注 > manifest 描述 > 占位引导；行内编辑 Enter 保存/Esc 取消）+
//      Hooks 展开（逐钩「触发」，执行结果等宽字体展示，禁用的插件禁触发）
//    · 说明卡：manifest.json / plugin.py / hook 签名 / 手动触发口径
//  文案与数值逐字对齐现状实现；视觉用 VTheme 近似（接入指南 §3）。
//

import SwiftUI

public struct PluginsPanelView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var vmBox = PluginsPanelViewModelBox()

    public init() {}

    public var body: some View {
        if let vm = vmBox.vm {
            PluginsPanelBody(vm: vm, runtime: appState.runtime)
        } else {
            VLoadingView("插件面板初始化…")
                .task { vmBox.attach(appState: appState) }
        }
    }
}

/// 延迟构建 PluginsPanelViewModel（需要已注入的 AppState）。
@MainActor
final class PluginsPanelViewModelBox: ObservableObject {
    @Published var vm: PluginsPanelViewModel?
    func attach(appState: AppState) {
        if vm == nil { vm = PluginsPanelViewModel(appState: appState) }
    }
}

private struct PluginsPanelBody: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var vm: PluginsPanelViewModel
    /// 直接观察 NativeRuntime：AppState 不转发子服务的 objectWillChange，
    /// 历史上经 appState.sidecar.status 的 onChange 不会触发（收口修正，原写法自愈失效）。
    @ObservedObject var runtime: NativeRuntime

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // ── 标题行 ──
                HStack(spacing: 8) {
                    Image(systemName: "puzzlepiece")
                        .foregroundStyle(VTheme.textPrimary)
                    Text("插件管理")
                        .font(VTheme.Typo.sectionTitle)
                        .foregroundStyle(VTheme.textPrimary)
                }

                if let error = vm.error {
                    VCallout(.error, error)
                }
                if let notice = vm.notice {
                    VCallout(.success, notice)
                }

                installSection
                listSection
                infoSection
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { vm.start() }
        .onDisappear { vm.stop() }
        // P3-W6⑤：nativeReady 于 runtime init 同步点亮、任何视图出现前恒 true，
        // 旧「就绪自愈」onChange（永不触发）随侧车归零删除——首拉在挂载链路上。
    }

    // MARK: - 安装区（分区卡）

    private var installSection: some View {
        sectionCard {
            Text("安装插件")
                .font(VTheme.Typo.sectionTitle)
                .foregroundStyle(VTheme.textPrimary)
                .padding(.bottom, 12)
            HStack(spacing: 8) {
                TextField("https://github.com/owner/repo 或本地路径", text: $vm.repoUrl)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .vInputStyle()
                    .onSubmit { vm.install() }   // 对齐 Enter 提交（输入法合成中由 AppKit 保证不触发）
                    .accessibilityIdentifier("pluginRepoInput")
                Button { vm.install() } label: {
                    HStack(spacing: 4) {
                        if vm.installing {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "plus")
                        }
                        Text(vm.installing ? "安装中..." : "安装")
                    }
                }
                .buttonStyle(.vPrimary)
                .disabled(vm.installing || vm.repoUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("pluginInstallButton")
            }
        }
    }

    // MARK: - 插件列表（分区卡）

    private var listSection: some View {
        sectionCard {
            Text("插件列表")
                .font(VTheme.Typo.sectionTitle)
                .foregroundStyle(VTheme.textPrimary)
                .padding(.bottom, 12)

            if vm.loading && vm.plugins.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.regular)
                    Text("加载中…")
                        .font(VTheme.Typo.caption)
                        .foregroundStyle(VTheme.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else if vm.plugins.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "puzzlepiece")
                        .font(.system(size: 30))
                        .foregroundStyle(VTheme.borderStrong)
                    Text("暂无插件。在上方输入 GitHub 仓库地址安装。")
                        .font(VTheme.Typo.body)
                        .foregroundStyle(VTheme.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                VStack(spacing: 12) {
                    ForEach(vm.plugins) { plugin in
                        PluginCardView(plugin: plugin, vm: vm)
                    }
                }
            }
        }
    }

    // MARK: - 说明卡

    private var infoSection: some View {
        sectionCard {
            (Text("插件格式：").bold()
             + Text("仓库需包含 ")
             + Text("manifest.json").font(.system(size: 12, design: .monospaced))
             + Text("（name, version, entry_point, hooks）和入口文件（默认 ")
             + Text("plugin.py").font(.system(size: 12, design: .monospaced))
             + Text("）。Hook 函数签名：")
             + Text("def hook_name(context: dict) -> dict").font(.system(size: 12, design: .monospaced))
             + Text("。钩子采用手动触发（展开 Hooks → 触发）；启用/禁用开关在每个插件名称旁。"))
                .font(VTheme.Typo.caption)
                .foregroundStyle(VTheme.textTertiary)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sectionCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VTheme.bgCard, in: RoundedRectangle(cornerRadius: VTheme.Radius.l))
            .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.l).stroke(VTheme.borderDefault))
    }
}

// MARK: - 插件卡

private struct PluginCardView: View {
    let plugin: SidecarPlugin
    @ObservedObject var vm: PluginsPanelViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 头行：名称 + 版本 + 启停开关｜卸载
            HStack(spacing: 8) {
                Text(plugin.name)
                    .font(VTheme.Typo.body)
                    .fontWeight(.medium)
                    .foregroundStyle(plugin.isDisabled ? VTheme.textTertiary : VTheme.textPrimary)
                if let version = plugin.version, !version.isEmpty {
                    Text("v\(version)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(VTheme.textTertiary)
                }
                Button { vm.toggleEnabled(plugin) } label: {
                    Text(plugin.isDisabled ? "启用" : "禁用")
                        .font(VTheme.Typo.caption)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(plugin.isDisabled ? VTheme.bgHover : VTheme.accentBg,
                                    in: RoundedRectangle(cornerRadius: VTheme.Radius.s))
                        .foregroundStyle(plugin.isDisabled ? VTheme.textSecondary : VTheme.accentText)
                }
                .buttonStyle(.plain)
                .help(plugin.isDisabled ? "点击启用此插件" : "点击禁用此插件")
                .accessibilityIdentifier("pluginToggle.\(plugin.name)")

                Spacer()

                Button { vm.uninstall(plugin.name) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                        Text("卸载")
                    }
                    .font(VTheme.Typo.caption)
                }
                .buttonStyle(.vSecondary)
                .controlSize(.small)
                .tint(VTheme.dangerText)
                .accessibilityIdentifier("pluginUninstall.\(plugin.name)")
            }

            // 备注区（用户备注 > manifest 描述 > 占位引导）
            if vm.editingNote == plugin.name {
                HStack(spacing: 6) {
                    TextField("如：给消息加时间戳前缀", text: $vm.noteDraft)
                        .textFieldStyle(.plain)
                        .font(VTheme.Typo.caption)
                        .vInputStyle()
                        .onSubmit { vm.saveNote(plugin.name) }   // Enter 保存
                        .accessibilityIdentifier("pluginNoteInput.\(plugin.name)")
                    Button("保存") { vm.saveNote(plugin.name) }
                        .buttonStyle(.vPrimary)
                        .controlSize(.small)
                        .accessibilityIdentifier("pluginNoteSave.\(plugin.name)")
                    Button("取消") { vm.cancelEditNote() }
                        .buttonStyle(.vSecondary)
                        .controlSize(.small)
                        .accessibilityIdentifier("pluginNoteCancel.\(plugin.name)")
                }
            } else {
                HStack(spacing: 8) {
                    Text(noteDisplay)
                        .font(VTheme.Typo.caption)
                        .foregroundStyle((plugin.note?.isEmpty == false) ? VTheme.textSecondary : VTheme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { vm.beginEditNote(plugin) } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "pencil")
                            Text("备注")
                        }
                        .font(VTheme.Typo.caption)
                    }
                    .buttonStyle(.vGhost)
                    .controlSize(.small)
                    .help(plugin.note?.isEmpty == false ? "修改备注" : "添加备注")
                    .accessibilityIdentifier("pluginNoteEdit.\(plugin.name)")
                }
            }

            // Hooks（checkpoint-049 手动触发）
            if let hooks = plugin.hooks, !hooks.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Button { vm.toggleHooksExpanded(plugin.name) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: vm.expandedHooks.contains(plugin.name) ? "chevron.up" : "chevron.down")
                            Text("Hooks (\(hooks.count))")
                        }
                        .font(VTheme.Typo.caption)
                        .foregroundStyle(VTheme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("pluginHooksToggle.\(plugin.name)")

                    if vm.expandedHooks.contains(plugin.name) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(hooks, id: \.self) { hook in
                                hookRow(plugin: plugin, hook: hook)
                            }
                            Text("Hook 触发方式：手动触发——点击每个钩子的\"触发\"，执行结果展示在下方。")
                                .font(VTheme.Typo.micro)
                                .foregroundStyle(VTheme.textTertiary)
                                .padding(.top, 6)
                        }
                        .padding(.leading, 8)
                        .padding(.top, 6)
                    }
                }
            } else {
                Text("（该插件未声明钩子）")
                    .font(VTheme.Typo.micro)
                    .foregroundStyle(VTheme.textTertiary)
            }
        }
        .padding(12)
        .opacity(plugin.isDisabled ? 0.7 : 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VTheme.bgCard, in: RoundedRectangle(cornerRadius: VTheme.Radius.m))
        .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.m).stroke(VTheme.borderDefault))
    }

    /// 备注显示文案（对齐 TSX 三态：note > description > 占位引导）。
    private var noteDisplay: String {
        if let note = plugin.note, !note.isEmpty { return note }
        if let desc = plugin.description, !desc.isEmpty { return desc }
        return "（无备注——点右侧\"备注\"补充这个插件是干什么的）"
    }

    private func hookRow(plugin: SidecarPlugin, hook: String) -> some View {
        let key = PluginsPanelViewModel.hookKey(plugin.name, hook)
        let out = vm.hookOutputs[key]
        let busy = vm.runningHook == key
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(hook)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(VTheme.textPrimary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(VTheme.bgHover, in: RoundedRectangle(cornerRadius: VTheme.Radius.s))
                Button { vm.triggerHook(plugin: plugin.name, hook: hook) } label: {
                    HStack(spacing: 4) {
                        if busy {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "play")
                        }
                        Text(busy ? "执行中…" : "触发")
                    }
                    .font(VTheme.Typo.caption)
                }
                .buttonStyle(.vSecondary)
                .controlSize(.small)
                .disabled(plugin.isDisabled || vm.runningHook != nil)
                .help(plugin.isDisabled ? "插件已禁用，无法触发" : "手动触发此钩子")
                .accessibilityIdentifier("pluginHookTrigger.\(key)")
            }
            if let out {
                Text(out.text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(out.ok ? VTheme.okText : VTheme.dangerText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(VTheme.bgHover, in: RoundedRectangle(cornerRadius: VTheme.Radius.s))
                    .accessibilityIdentifier("pluginHookOutput.\(key)")
            }
        }
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) {
            Rectangle().fill(VTheme.borderSubtle).frame(height: 1)
        }
    }
}
