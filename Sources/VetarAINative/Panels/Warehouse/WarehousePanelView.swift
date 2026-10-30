//
//  WarehousePanelView.swift
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

//  知识仓库检索/注入面板（SwiftUI 移植，对标 WarehousePanel.tsx，252 行）：
//    · 300pt 右侧栏形态：头部（图标胶囊 + 标题 + 收起按钮）
//    · 作用域分段控件（本项目/全局；无项目时「本项目」禁用）
//    · 搜索框（Enter 触发）+ 搜索按钮（spinner 态）
//    · 检索模式胶囊三连（混合/关键词/语义，tooltip 逐字对齐）
//    · 结果列表：勾选框 + 标题 + 相关度得分徽标 + 分类 + 创建时间
//    · 底部：发送 N 条到会话（0 条禁用）+ 拉模式说明
//  文案逐字对齐现状实现；视觉用 VTheme 近似（接入指南 §3）。
//
//  U3（仓库归位）：与 TSX 同构——嵌在聊天右端 300pt 窄栏，由 ChatDetailView
//  控制展开/收起（onClose）与注入（onInject：文本追加进输入框 + Toast）。
//  原「系统组独立面板」形态已移除（独立页主区全空、注入只剩复制剪贴板）；
//  onInject 缺省的剪贴板兜底仅作防御保留，应用内不再有该入口。
//  原版无条目内容预览，原生同样不加。
//

import SwiftUI
import AppKit

public struct WarehousePanelView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var vmBox = WarehousePanelViewModelBox()
    private let initialScope: WarehouseScope?
    private let onClose: (() -> Void)?
    private let onInject: ((String) -> Void)?

    public init(initialScope: WarehouseScope? = nil,
                onClose: (() -> Void)? = nil,
                onInject: ((String) -> Void)? = nil) {
        self.initialScope = initialScope
        self.onClose = onClose
        self.onInject = onInject
    }

    public var body: some View {
        if let vm = vmBox.vm {
            WarehousePanelBody(vm: vm, runtime: appState.runtime,
                               projectId: appState.currentProjectId,
                               onClose: onClose)
        } else {
            VLoadingView("知识仓库初始化…")
                .frame(minHeight: 120)
                .task {
                    vmBox.attach(appState: appState, initialScope: initialScope,
                                 onInject: onInject)
                }
        }
    }
}

@MainActor
final class WarehousePanelViewModelBox: ObservableObject {
    @Published var vm: WarehousePanelViewModel?
    func attach(appState: AppState, initialScope: WarehouseScope?,
                onInject: ((String) -> Void)?) {
        guard vm == nil else { return }
        let m = WarehousePanelViewModel(appState: appState,
                                        initialScope: initialScope,
                                        onInject: onInject ?? Self.clipboardInject)
        vm = m
    }

    /// 注入兜底（U3 后仅防御保留：应用内唯一入口是 ChatDetailView 右端窄栏，
    /// 恒注入真回调；此分支 = 复制拼好的文本到剪贴板并 Toast 提示）。
    private static func clipboardInject(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        ToastCenter.shared.show("已复制知识内容，粘贴到会话输入框发送", kind: .success)
    }
}

private struct WarehousePanelBody: View {
    @ObservedObject var vm: WarehousePanelViewModel
    /// 直接观察 NativeRuntime（AppState 不转发子服务发布）
    @ObservedObject var runtime: NativeRuntime
    let projectId: String?
    let onClose: (() -> Void)?

    var body: some View {
        // U3：本体即 300pt 右侧窄栏（对齐 TSX 容器样式）——原独立页的
        // 「Spacer + 贴右」外壳已去，否则嵌进 ChatDetailView 的 HStack 会反向挤压会话区
        VStack(spacing: 0) {
            header
            scopePicker
            searchRow
            modePicker
            resultList
            footer
        }
        .frame(width: 300)
        .frame(maxHeight: .infinity)
        .background(VTheme.bgCard)
        .overlay(alignment: .leading) {
            Rectangle().fill(VTheme.borderSubtle).frame(width: 1)
        }
        .task { await vm.loadEntries() }   // 挂载列全量（对齐 TSX useEffect [scope, projectId]）
        .onChange(of: projectId) { _, _ in vm.onProjectChanged() }
        // 侧车就绪自愈：面板先于侧车打开时首拉静默失败，就绪后自动补拉
        // P3-W6⑤：nativeReady 于 runtime init 同步点亮、任何视图出现前恒 true，
        // 旧「就绪自愈」onChange（永不触发）随侧车归零删除——首拉在挂载链路上。
    }

    // MARK: - 头部

    private var header: some View {
        HStack {
            HStack(spacing: 7) {
                // 方向2 波次2：头部图标去 accentBgSoft+accentBorder 描边方块，
                // 裸图标 16pt textTertiary（原版 :112-120）
                Image(systemName: "cylinder")   // TSX: database 图标
                    .font(.system(size: 16))
                    .foregroundStyle(VTheme.textTertiary)
                Text("知识仓库")
                    // 方向2 波次2：13 semibold 手写归 Typo 档（原版 :122）
                    .font(VTheme.Typo.body.weight(.semibold))
                    .foregroundStyle(VTheme.textPrimary)
            }
            Spacer()
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12))
                        .foregroundStyle(VTheme.textSecondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("收起面板")
                // 方向2 波次4：AX 补账
                .accessibilityLabel("收起面板")
                .accessibilityIdentifier("warehouse.close")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(VTheme.borderSubtle).frame(height: 1)
        }
    }

    // MARK: - 作用域切换（分段控件）

    private var scopePicker: some View {
        HStack(spacing: 4) {
            ForEach(WarehouseScope.allCases, id: \.self) { s in
                let selected = vm.scope == s
                let disabled = s == .project && projectId == nil
                Button {
                    vm.setScope(s)
                } label: {
                    Text(s.label)
                        .font(VTheme.Typo.caption)
                        .fontWeight(selected ? .medium : .regular)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        // 方向2 波次2：分段控件圆角字面量 8 归 Radius.m2；选中态静止阴影
                        // 删除（阴影只给浮起物，原版 :162-167）
                        .background(selected ? VTheme.bgCard : Color.clear,
                                    in: RoundedRectangle(cornerRadius: VTheme.Radius.m2))
                        .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.m2)
                            .stroke(selected ? VTheme.borderDefault : Color.clear))
                        .foregroundStyle(disabled ? VTheme.textDisabled
                                         : (selected ? VTheme.textPrimary : VTheme.textSecondary))
                }
                .buttonStyle(.plain)
                .disabled(disabled)
                .accessibilityIdentifier("warehouse.scope.\(s.rawValue)")
            }
        }
        .padding(2)
        .background(VTheme.bgHover, in: RoundedRectangle(cornerRadius: VTheme.Radius.m))
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    // MARK: - 搜索框

    private var searchRow: some View {
        HStack(spacing: 6) {
            TextField("搜索（关键词/换述，留空=列出全部）", text: $vm.query)
                .textFieldStyle(.plain)
                // 方向2 波次2：手写输入框样式收编 vInputStyle（含焦点态边框；原版 :186-191）
                .vInputStyle()
                .onSubmit { vm.doSearch() }   // Enter 触发（对齐 TSX onKeyDown）
                .accessibilityIdentifier("warehouse.query")
            Button {
                vm.doSearch()
            } label: {
                Group {
                    if vm.searching {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12))
                            .foregroundStyle(VTheme.onInk)
                    }
                }
                .frame(width: 32, height: 32)
                .background(VTheme.ink, in: RoundedRectangle(cornerRadius: VTheme.Radius.m))
            }
            .buttonStyle(.plain)
            .disabled(vm.searching)
            .help("搜索")
            .accessibilityLabel("搜索")
            .accessibilityIdentifier("warehouse.search")
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: - 检索模式胶囊三连

    private var modePicker: some View {
        HStack(spacing: 6) {
            ForEach(WarehouseSearchMode.allCases, id: \.self) { m in
                let selected = vm.searchMode == m
                Button {
                    vm.searchMode = m
                } label: {
                    Text(m.label)
                        .font(VTheme.Typo.micro)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                        // 方向2 波次2：检索模式 Capsule 胶囊方角化 Radius.s（方向2 方系口径，原版 :232-234）
                        .background(selected ? VTheme.accentBg : VTheme.bgCard,
                                    in: RoundedRectangle(cornerRadius: VTheme.Radius.s))
                        .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.s)
                            .stroke(selected ? VTheme.accentBorder : VTheme.borderSubtle))
                        .foregroundStyle(selected ? VTheme.accentText : VTheme.textTertiary)
                }
                .buttonStyle(.plain)
                .help(m.help)
                .accessibilityIdentifier("warehouse.mode.\(m.rawValue)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    // MARK: - 结果列表

    private var resultList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                // 方向2 波次2：搜索失败 error 条上屏带重试（原版失败静默 results=[]
                // 伪装成空态；仿 Projects 错误条口径，VM 侧只加反馈通道不改判定）
                if let searchError = vm.searchError {
                    VCallout(.error, searchError) {
                        Button {
                            vm.doSearch()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.clockwise")
                                Text("重试")
                            }
                        }
                        .buttonStyle(.vSecondary)
                        .accessibilityIdentifier("warehouse.searchRetry")
                    }
                    .accessibilityIdentifier("warehouse.searchError")
                }
                // 有错误条时不再叠空态文案（错误≠无结果）
                if vm.results.isEmpty && vm.searchError == nil {
                    Text(vm.emptyHint)
                        .font(VTheme.Typo.caption)
                        .foregroundStyle(VTheme.textTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                }
                ForEach(vm.results) { e in
                    HStack(alignment: .top, spacing: 6) {
                        Toggle("", isOn: Binding(
                            get: { vm.checked.contains(e.id) },
                            set: { _ in vm.toggleCheck(e.id) }
                        ))
                        .toggleStyle(.checkbox)
                        .tint(VTheme.accent)
                        .labelsHidden()
                        .accessibilityLabel("选择该条目")
                        .padding(.top, 2)
                        .accessibilityIdentifier("warehouse.check.\(e.id)")

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(e.title)
                                    // 方向2 波次2：12 semibold 手写归 Typo 档（原版 :274）
                                    .font(VTheme.Typo.caption.weight(.semibold))
                                    .foregroundStyle(VTheme.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let score = e.score {
                                    Text("相关 \(WarehousePanelViewModel.scoreText(score))")
                                        // 方向2 波次2：10pt 归 Typo.micro（≥11pt 地板，原版 :279）
                                        .font(VTheme.Typo.micro)
                                        .foregroundStyle(VTheme.textTertiary)
                                }
                            }
                            if let category = e.category, !category.isEmpty {
                                Text("分类：\(category)")
                                    // 方向2 波次2：10pt 归 Typo.micro（原版 :285）
                                    .font(VTheme.Typo.micro)
                                    .foregroundStyle(VTheme.textTertiary)
                            }
                            if let created = e.created_at, !created.isEmpty {
                                Text(created)
                                    // 方向2 波次2：10pt 归 Typo.micro（原版 :290）
                                    .font(VTheme.Typo.micro)
                                    .foregroundStyle(VTheme.textTertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    // 方向2 波次2：结果行 bgCard 落 bgCard 零色阶——行去底留分隔线
                    // （跳过末行，原版 :298-299）
                    .overlay(alignment: .bottom) {
                        if e.id != vm.results.last?.id {
                            Rectangle().fill(VTheme.borderSubtle).frame(height: 1)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - 底部：发送到会话

    private var footer: some View {
        VStack(spacing: 6) {
            // 方向2 波次2：手写 ink 主钮收编 vPrimary——禁用降透明由样式库 0.45
            // 单通道承担，外层 opacity(0.7) 死代码删除（原版 :312-324）
            Button {
                vm.inject()
            } label: {
                Text("发送 \(vm.checked.count) 条到会话")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.vPrimary)
            .disabled(vm.checked.isEmpty)
            .accessibilityIdentifier("warehouse.inject")
            Text("注入的内容会作为你的消息进入对话（仅你勾选的条目）。知识内容默认不自动进入上下文。")
                // 方向2 波次2：10pt 归 Typo.micro（≥11pt 地板，原版 :327）
                .font(VTheme.Typo.micro)
                .foregroundStyle(VTheme.textTertiary)
                .lineSpacing(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .top) {
            Rectangle().fill(VTheme.borderSubtle).frame(height: 1)
        }
    }
}
