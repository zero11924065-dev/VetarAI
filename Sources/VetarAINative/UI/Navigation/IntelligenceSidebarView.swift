//
//  IntelligenceSidebarView.swift
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

//  唯一基准 = 原版 subagent/renderer/src/App.tsx:217-294（侧栏单栏堆叠）：
//    1. 「独立 Agent」手风琴（App.tsx:233 → IndependentAgentsPanel.tsx:182-208）：
//       头 = bot 图标 + 标题 + 数量徽标 + chevron（高 36，hover/open 态换色）；
//       默认收起（:48 useState(false)）；展开区 = 创建表单 + 列表，限高 45vh（:208）；
//       尾边框 borderSubtle（:180）
//    2. 「项目」区（App.tsx:234 → ProjectPanel.tsx:262-326）：无折叠壳；
//       标题行 + 右上「+ 新建项目」；列表独立滚动限高 30vh（:326）；
//       尾边框 borderSubtle（:265），flexShrink:0
//    3. 项目内 Agent 区（App.tsx:236-243）：选中项目且非 ia- 命名空间时出现
//       （点项目、它的 Agent 同栏在下方出现，不是跳页）；整区 flex:1 自适应
//       独立滚动（AgentPanel.tsx:143-144）
//    4/5. 栏底「任务队列」「圆桌」手风琴（App.tsx:247-290）：选中项目才显示；
//       互斥（openPanel :48-50——点开一个自动收起其余，再点自己收起；默认皆收）；
//       头 = 图标 + 标题 + chevron（高 32，accordionHeadStyle :185-193）；
//       展开区限高 45vh（:260/:281），内容随折叠卸载（Accordion.tsx:66）
//  五块的面板内容实现复用既有 View 抽出的内容组件（ViewModel 全页版逻辑原样保留）：
//    IndependentAgentsPanelContentView / ProjectPanelContentView / AgentPanelContentView /
//    TaskPanelView（整用）/ RoundtableListContentView。
//  圆桌链路（原版 RoundtablePanel.tsx:130/245 + App.tsx:320-328）：列表点击/创建成功
//    → vm.select(rtId) → 内容区覆盖 RoundtableDetailView 大屏（聊天保活不销毁，
//    App.tsx:344-358）；共享 RoundtablePanelViewModel 由 IntelligenceCenterState
//    持有（手风琴列表 + 大屏双挂载点，attach/detach 计数生命周期）。
//

import SwiftUI

// MARK: - 智能中心共享态（圆桌 VM 单例：手风琴列表与内容区大屏共用）

/// 智能中心级共享状态。RootView 持有并注入环境；圆桌 ViewModel 在此单例化——
/// 手风琴「创建 + 列表」与内容区「详情大屏」读写同一 VM（对齐原版 App.tsx 的
/// viewingRtId 提升语义：RoundtablePanel 与 RoundtableView 经 App 状态联动）。
@MainActor
final class IntelligenceCenterState: ObservableObject {
    @Published private(set) var roundtableVM: RoundtablePanelViewModel?

    func attach(appState: AppState) {
        if roundtableVM == nil { roundtableVM = RoundtablePanelViewModel(appState: appState) }
    }
}

// MARK: - 智能中心侧栏（单栏堆叠）

struct IntelligenceSidebarView: View {
    @EnvironmentObject private var appState: AppState

    /// 栏底手风琴互斥（对齐 App.tsx:48-50 openPanel：点开一个自动收起其余，再点自己收起）
    @State private var openBottom: BottomAccordion?
    /// 波次7（业主拍板对齐 Kimi Work/Chat）：顶部双 tab 分离两个命名空间——
    /// 「项目」（含项目内 Agent / 任务队列 / 圆桌）与「独立 Agent」各占一 tab，
    /// 不再五块堆叠；tab 跟随 currentProjectId 命名空间自动切换。
    @State private var selectedTab: SidebarTab = .projects
    /// 波次7：创建表单撤出侧栏 → .sheet 模态弹窗（对齐竞品「导航归导航、创建归弹窗」；
    /// 局部 overlay 被窗口父链裁剪，回归修复为窗口级 sheet）
    @State private var showAgentCreate = false
    @State private var showIndependentCreate = false
    /// 波次7：两个命名空间 VM 提升到侧栏级——弹窗与列表共享同一实例，
    /// 弹窗创建成功后侧栏列表即时刷新（不依赖 8s 轮询）。
    @StateObject private var agentBox = AgentPanelViewModelBox()
    @StateObject private var indepBox = IndependentAgentsPanelViewModelBox()

    private enum BottomAccordion {
        case tasks, roundtable
    }

    enum SidebarTab {
        case projects, independentAgents
    }

    /// ia- 命名空间（独立 Agent 选中态）不显示「项目内 Agent」区（App.tsx:236）
    private var isIndependentNamespace: Bool {
        appState.currentProjectId?.hasPrefix(IndependentAgentsPanelViewModel.namespacePrefix) ?? false
    }

    private var showAgentSection: Bool {
        appState.currentProjectId != nil && !isIndependentNamespace
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                VStack(spacing: 0) {
                    sidebarTabs

                    switch selectedTab {
                    case .projects:
                        // 2. 项目区（App.tsx:234，无折叠壳）
                        // 方向2 波次2：列表限高改固定行数，不再吃 viewportHeight
                        ProjectSection()

                        // 3. 项目内 Agent 区（选中真实项目时出现，App.tsx:236-243；
                        //    ⛔ 不得加 layoutPriority(1)：DBG-145，高优先级弹性区会
                        //    抢光高度，把同栏限高 ScrollView 压成 0 高）
                        if showAgentSection {
                            AgentSection(box: agentBox, onShowCreate: { showAgentCreate = true })
                                // 波次6：flex:1 强制撑满改「内容自适应 + 上限」——内容少时
                                // 收缩消除过度留白，内容多时到约 40vh 上限内部滚动
                                .frame(maxHeight: geo.size.height * 0.40, alignment: .top)
                        }

                        // 4/5. 栏底 任务队列/圆桌 手风琴（App.tsx:247-290）
                        // 波次7 修正显示条件：仅真实项目——旧条件 currentProjectId != nil
                        // 在 ia- 命名空间下也非 nil（currentProjectId="ia-<id>"），而后端
                        // 不认 "ia-<id>" 这个 projectId，任务队列与圆桌在独立 Agent 下
                        // 无效，误显示会误导用户（业主实测反馈）。
                        if showAgentSection {
                            BottomAccordionShell(
                                title: "任务队列", icon: "list.clipboard",
                                isOpen: openBottom == .tasks,
                                viewportHeight: geo.size.height,
                                toggle: { toggle(.tasks) }
                            ) {
                                // 原版展开区 = TaskPanel 整段（App.tsx:261；标题行/刷新/任务卡全在内）
                                TaskPanelView()
                            }
                            BottomAccordionShell(
                                title: "圆桌", icon: "mic",
                                isOpen: openBottom == .roundtable,
                                viewportHeight: geo.size.height,
                                toggle: { toggle(.roundtable) }
                            ) {
                                RoundtableAccordionContent(runtime: appState.runtime)
                            }
                        }

                    case .independentAgents:
                        // 1. 独立 Agent 手风琴（App.tsx:233；波次7：⊕ 唤起创建弹窗）
                        IndependentAgentsAccordionSection(
                            box: indepBox,
                            viewportHeight: geo.size.height,
                            onShowCreate: { showIndependentCreate = true })
                    }

                    // 波次6：统一底部 Spacer 吸收剩余——留白统一沉到底。
                    // ⛔ Spacer 不得带 layoutPriority(1)，DBG-145 同款塌缩
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        // 波次7 回归修复：创建弹窗 局部 overlay → .sheet 模态（窗口级呈现，
        // 卡片宽于侧栏时被父链裁剪的问题物理消除；同构先例 = ChatPanelView
        // transferModal 表单 sheet）
        .sheet(isPresented: $showAgentCreate) {
            if let vm = agentBox.vm {
                AgentCreateSheet(vm: vm, onClose: { showAgentCreate = false })
            }
        }
        .sheet(isPresented: $showIndependentCreate) {
            if let vm = indepBox.vm {
                IndependentAgentCreateSheet(vm: vm, onClose: { showIndependentCreate = false })
            }
        }
        .onAppear { syncTab() }
        .onChange(of: appState.currentProjectId) { _, _ in syncTab() }
    }

    /// tab 跟随命名空间：ia- 前缀 → 独立 Agent tab；真实项目 / 未选 → 项目 tab
    private func syncTab() {
        selectedTab = isIndependentNamespace ? .independentAgents : .projects
    }

    /// 顶部双 tab（对齐 Kimi Work/Chat 胶囊分段：选中 = 墨底白字，未选 = 透明灰字）
    private var sidebarTabs: some View {
        HStack(spacing: 6) {
            tabButton("项目", tab: .projects)
            tabButton("独立 Agent", tab: .independentAgents)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(VTheme.borderSubtle).frame(height: 1)
        }
    }

    private func tabButton(_ title: String, tab: SidebarTab) -> some View {
        let selected = selectedTab == tab
        return Button {
            selectedTab = tab
        } label: {
            Text(title)
                .font(VTheme.Typo.caption.weight(.medium))
                .foregroundStyle(selected ? VTheme.onInk : VTheme.textSecondary)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .frame(maxWidth: .infinity)
                .background(selected ? VTheme.ink : Color.clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebarTab.\(title)")
    }

    private func toggle(_ key: BottomAccordion) {
        openBottom = openBottom == key ? nil : key
    }
}

// MARK: - 1. 独立 Agent 手风琴（壳对齐 IndependentAgentsPanel.tsx:180-201）

private struct IndependentAgentsAccordionSection: View {
    @EnvironmentObject private var appState: AppState
    /// 波次7：box 由侧栏级持有（弹窗与列表共享同一 VM，创建后即时刷新）
    @ObservedObject var box: IndependentAgentsPanelViewModelBox
    let viewportHeight: CGFloat
    let onShowCreate: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let vm = box.vm {
                // 观察下沉：徽标计数/列表必须经 @ObservedObject 订阅 vm，
                // 否则 agents 拉取回来后头徽标与展开列表不刷新（只观察 box 不够——
                // box 只在 vm 挂载瞬间发布一次）
                IndependentAgentsAccordionLoaded(
                    vm: vm, viewportHeight: viewportHeight, onShowCreate: onShowCreate)
            } else {
                Color.clear
                    .frame(height: 0)
                    .task { box.attach(appState: appState) }
            }
        }
        // 原版尾边框 borderBottom borderSubtle（IndependentAgentsPanel.tsx:180）
        .overlay(alignment: .bottom) {
            Rectangle().fill(VTheme.borderSubtle).frame(height: 1)
        }
    }
}

/// 独立 Agent 手风琴已加载态（观察 VM：徽标/列表随数据刷新）
private struct IndependentAgentsAccordionLoaded: View {
    @ObservedObject var vm: IndependentAgentsPanelViewModel
    /// 默认收起（原版 IndependentAgentsPanel.tsx:48 useState(false)）
    @State private var open = false
    @State private var hovering = false
    let viewportHeight: CGFloat
    let onShowCreate: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button { open.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 13))
                    Text("独立 Agent")
                        .font(VTheme.Typo.body)
                    Spacer()
                    // 数量徽标（方向2 波次2：计数不是待处理队列，不配强调色——
                    // accentBg/accentText 蓝胶囊 → 中性 bgActive 底 + textSecondary 字）
                    if !vm.agents.isEmpty {
                        Text("\(vm.agents.count)")
                            .font(.system(size: 11))
                            .foregroundStyle(VTheme.textSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(VTheme.bgActive, in: Capsule())
                    }
                    // 波次7：⊕ 新建（唤起创建弹窗，表单撤出侧栏；嵌套 Button 内层优先命中）
                    Button {
                        onShowCreate()
                    } label: {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 14))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("indepAgentsCreateToggle")
                    // 展开箭头（原版 :200：chevron 向下→上旋转 180°）
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11))
                        .foregroundStyle(VTheme.textTertiary)
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                // 原版头高 36、padding '8px 12px'（:187）
                .padding(.horizontal, 12)
                .frame(height: 36)
                .frame(maxWidth: .infinity)
                .foregroundStyle(open || hovering ? VTheme.textPrimary : VTheme.textSecondary)
                .background(open || hovering ? VTheme.bgHover : Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityIdentifier("indepAgentsAccordionHeader")
            // VM 生命周期随分区挂载（收起也保活——徽标计数常新，对齐原版
            // 面板组件常驻、Accordion 只折展开区，IndependentAgentsPanel.tsx:80/207）
            .onAppear { vm.start() }
            .onDisappear { vm.stop() }

            if open {
                // 展开区限高（波次6：45vh→32vh；波次7 表单撤出后列表独占，更矮更清爽）
                ScrollView {
                    IndependentAgentsPanelContentView(vm: vm)
                }
                .frame(maxHeight: viewportHeight * 0.32)
            }
        }
    }
}

// MARK: - 2. 项目区（无折叠壳；ProjectPanel.tsx:262-265 外层语义）

private struct ProjectSection: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var box = ProjectPanelViewModelBox()

    var body: some View {
        VStack(spacing: 0) {
            if let vm = box.vm {
                ProjectPanelContentView(vm: vm)
                    .onAppear { vm.start() }
                    .onDisappear { vm.stop() }
            } else {
                Color.clear
                    .frame(height: 0)
                    .task { box.attach(appState: appState) }
            }
        }
        // 原版尾边框 borderBottom borderSubtle（ProjectPanel.tsx:265）
        .overlay(alignment: .bottom) {
            Rectangle().fill(VTheme.borderSubtle).frame(height: 1)
        }
    }
}

// MARK: - 3. 项目内 Agent 区（选中项目时出现，App.tsx:236-243）

private struct AgentSection: View {
    @EnvironmentObject private var appState: AppState
    /// 波次7：box 由侧栏级持有（弹窗与列表共享同一 VM，创建后即时刷新）
    @ObservedObject var box: AgentPanelViewModelBox
    let onShowCreate: () -> Void

    var body: some View {
        Group {
            if let vm = box.vm {
                AgentPanelContentView(vm: vm, onShowCreate: onShowCreate)
                    .onAppear { vm.start() }
                    .onDisappear { vm.stop() }
            } else {
                Color.clear
                    .task { box.attach(appState: appState) }
            }
        }
    }
}

// MARK: - 波次7：创建弹窗（表单撤出侧栏；字段与原内嵌表单逐字一致）
// 回归修复：局部 overlay → .sheet 模态（侧栏窄于卡片宽时 overlay 溢出部分
// 被窗口父链裁剪；sheet 独立窗口级呈现，无此问题）。容器对齐 ChatPanelView
// transferModal：padding 22 + 固定宽 + Esc=取消 + Enter=确认。

/// 项目内 Agent 创建 sheet（VM 与侧栏列表共享实例 → 创建后列表即时刷新）
private struct AgentCreateSheet: View {
    @ObservedObject var vm: AgentPanelViewModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("新建 Agent")
                .font(VTheme.Typo.dialogTitle)
                .foregroundStyle(VTheme.textPrimary)
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
            .accessibilityLabel("类型")
            .pickerStyle(.menu)
            .frame(width: 120)
            .accessibilityIdentifier("agentTypePicker")
            if vm.modelList.isEmpty {
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
                .accessibilityLabel("模型")
                .pickerStyle(.menu)
                .accessibilityIdentifier("agentModelPicker")
            }
            TextField("角色设定（可选）：如「你是严谨的代码审查员」，随对话注入模型",
                      text: $vm.newPrompt, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...4)
                .vInputStyle()
                .accessibilityIdentifier("agentPromptField")
            HStack {
                Spacer()
                Button("取消") { onClose() }
                    .buttonStyle(.vGhost)
                    .accessibilityIdentifier("agentCreateCancel")
                Button {
                    vm.create()
                } label: {
                    Text(vm.creating ? "创建中…" : "添加")
                }
                .buttonStyle(.vPrimary)
                .disabled(vm.creating)
                .accessibilityIdentifier("agentCreateButton")
                // sheet 主钮 Enter=确认（对齐 transferModal defaultAction 口径）
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 360)
        // sheet 补 Esc=取消（对齐 transferModal / VDialog Esc 口径）
        .onExitCommand { onClose() }
        .onChange(of: vm.creating) { was, now in
            // 创建结束（成功/失败）关弹窗；失败已由 VM 弹 alert
            if was && !now { onClose() }
        }
    }
}

/// 独立 Agent 创建 sheet（VM 与手风琴列表共享实例 → 创建后列表即时刷新）
private struct IndependentAgentCreateSheet: View {
    @ObservedObject var vm: IndependentAgentsPanelViewModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("新建独立 Agent")
                .font(VTheme.Typo.dialogTitle)
                .foregroundStyle(VTheme.textPrimary)
            TextField("新独立 Agent 名称", text: $vm.newName)
                .textFieldStyle(.plain)
                .vInputStyle()
                .onSubmit { vm.create() }
                .accessibilityIdentifier("indepAgentNameField")
            if vm.modelList.isEmpty {
                Text("模型加载中…")
                    .font(VTheme.Typo.body)
                    .foregroundStyle(VTheme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .vInputStyle()
            } else {
                Picker("", selection: $vm.newModel) {
                    Text("模型（默认）").tag("")
                    ForEach(vm.modelList, id: \.name) { m in
                        Text(m.name).tag(m.name)
                    }
                }
                .labelsHidden()
                .accessibilityLabel("模型")
                .pickerStyle(.menu)
                .accessibilityIdentifier("indepAgentModelPicker")
            }
            TextField("角色设定（可选）：如「你是严谨的文档审校员」，随对话注入模型",
                      text: $vm.newPrompt, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...4)
                .vInputStyle()
                .accessibilityIdentifier("indepAgentPromptField")
            HStack {
                Spacer()
                Button("取消") { onClose() }
                    .buttonStyle(.vGhost)
                    .accessibilityIdentifier("indepAgentCreateCancel")
                Button {
                    vm.create()
                } label: {
                    Text(vm.creating ? "创建中…" : "创建")
                }
                .buttonStyle(.vPrimary)
                .disabled(vm.creating)
                .accessibilityIdentifier("indepAgentCreateButton")
                // sheet 主钮 Enter=确认（对齐 transferModal defaultAction 口径）
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 360)
        // sheet 补 Esc=取消（对齐 transferModal / VDialog Esc 口径）
        .onExitCommand { onClose() }
        .onChange(of: vm.creating) { was, now in
            // 创建结束（成功/失败）关弹窗；失败已由 VM 弹 alert
            if was && !now { onClose() }
        }
    }
}

// MARK: - 4/5. 栏底手风琴壳（accordionHeadStyle，App.tsx:185-193）

private struct BottomAccordionShell<Content: View>: View {
    let title: String
    let icon: String
    let isOpen: Bool
    let viewportHeight: CGFloat
    let toggle: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 7) {
                    Image(systemName: icon)
                        .font(.system(size: 13))
                    Text(title)
                        // 方向2 波次2：12.5pt 半号散数收档 Typo.caption(12)
                        .font(VTheme.Typo.caption.weight(.medium))
                    Spacer()
                    // 原版 chevron 向下→上旋转 180°（:257/:278）
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11))
                        .foregroundStyle(VTheme.textTertiary)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                // 原版头高 32、padding '0 8px'、圆角 8、margin '2px 8px 0'（:186-188）
                .padding(.horizontal, 8)
                .frame(height: 32)
                .frame(maxWidth: .infinity)
                // 方向2 波次2：展开态 = 常驻悬停态 bgHover + textPrimary——「展开」不是
                // 「选中」语义，不套 bgSelected/accentText（与本文件独立 Agent 头、
                // Workflow 侧手风琴头同口径；原 bgActive 灰底退役）
                .background(isOpen || hovering ? VTheme.bgHover : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(isOpen || hovering ? VTheme.textPrimary : VTheme.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .padding(.horizontal, 8)
            .padding(.top, 2)
            .accessibilityIdentifier("bottomAccordion.\(title)")

            if isOpen {
                // 展开区限高 45vh + 独立滚动（原版 :260/:281）；
                // 内容随折叠卸载（Accordion.tsx:66 关闭后卸载语义）
                content()
                    .frame(maxHeight: viewportHeight * 0.45)
            }
        }
    }
}

// MARK: - 圆桌手风琴展开区（共享 VM；原版 RoundtablePanel.tsx:137-268）

private struct RoundtableAccordionContent: View {
    @EnvironmentObject private var intelCenter: IntelligenceCenterState
    /// 直接观察 NativeRuntime：AppState 不转发子服务的 objectWillChange，
    /// 经 appState.runtime.nativeReady 的 onChange 不触发（沿用 RoundtablePanelBody 收口修正）。
    @ObservedObject var runtime: NativeRuntime

    var body: some View {
        if let vm = intelCenter.roundtableVM {
            ScrollView {
                RoundtableListContentView(vm: vm)
            }
            // 双挂载点计数生命周期：展开区与详情大屏任一存活则 VM 不停
            .onAppear { vm.attach() }
            .onDisappear { vm.detach() }
            // P3-W6⑤：nativeReady 于 runtime init 同步点亮、任何视图出现前恒 true，
            // 旧「就绪自愈」onChange（永不触发）随侧车归零删除——首拉在挂载链路上。
        } else {
            Color.clear.frame(height: 0)
        }
    }
}

// MARK: - 圆桌详情大屏宿主（内容区覆盖；原版 App.tsx:320-328）

/// 打开圆桌详情时覆盖智能中心内容区（与对话视图互斥显示；对话组件保活不销毁，
/// 原版 App.tsx:344-358——宿主以覆盖层形式叠在 ChatPanelView 之上，聊天流不中断）。
struct RoundtableDetailHostView: View {
    @ObservedObject var vm: RoundtablePanelViewModel
    /// 直接观察 NativeRuntime（同 RoundtableAccordionContent 注释）
    @ObservedObject var runtime: NativeRuntime

    var body: some View {
        if vm.selectedId != nil {
            RoundtableDetailView(vm: vm)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(VTheme.bgApp)
                .onAppear { vm.attach() }
                .onDisappear { vm.detach() }
                // P3-W6⑤：nativeReady 于 runtime init 同步点亮、任何视图出现前恒 true，
                // 旧「就绪自愈」onChange（永不触发）随侧车归零删除——首拉在挂载链路上。
        }
    }
}
