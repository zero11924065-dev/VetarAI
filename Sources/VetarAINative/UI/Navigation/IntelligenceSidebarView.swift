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

    private enum BottomAccordion {
        case tasks, roundtable
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
            VStack(spacing: 0) {
                // 1. 独立 Agent 手风琴（App.tsx:233）
                IndependentAgentsAccordionSection(viewportHeight: geo.size.height)

                // 2. 项目区（App.tsx:234，无折叠壳）
                ProjectSection(viewportHeight: geo.size.height)

                // 3. 项目内 Agent 区（App.tsx:236-243；flex:1 吸收剩余空间——
                //    maxHeight:.infinity 默认优先级即够；⛔ 不得加 layoutPriority(1)：
                //    DBG-145，高优先级弹性区会抢光高度，把同栏限高 ScrollView 压成 0 高）
                if showAgentSection {
                    AgentSection()
                        .frame(maxHeight: .infinity)
                }

                // 4/5. 栏底 任务队列/圆桌 手风琴（App.tsx:247-290；选中项目才显示）
                if appState.currentProjectId != nil {
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

                if !showAgentSection {
                    // 无 Agent 区（未选项目 / ia- 命名空间）时各区自然顶堆
                    // （原版同款：无 flex 填充，手风琴顺序堆叠，下方留白；
                    //  ⛔ Spacer 不得带 layoutPriority(1)，DBG-145 同款塌缩）
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private func toggle(_ key: BottomAccordion) {
        openBottom = openBottom == key ? nil : key
    }
}

// MARK: - 1. 独立 Agent 手风琴（壳对齐 IndependentAgentsPanel.tsx:180-201）

private struct IndependentAgentsAccordionSection: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var box = IndependentAgentsPanelViewModelBox()
    let viewportHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            if let vm = box.vm {
                // 观察下沉：徽标计数/列表必须经 @ObservedObject 订阅 vm，
                // 否则 agents 拉取回来后头徽标与展开列表不刷新（只观察 box 不够——
                // box 只在 vm 挂载瞬间发布一次）
                IndependentAgentsAccordionLoaded(vm: vm, viewportHeight: viewportHeight)
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

    var body: some View {
        VStack(spacing: 0) {
            Button { open.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 13))
                    Text("独立 Agent")
                        .font(VTheme.Typo.body)
                    Spacer()
                    // 数量徽标（原版 :197-199；accentBg/accentText，fontSize 11）
                    if !vm.agents.isEmpty {
                        Text("\(vm.agents.count)")
                            .font(.system(size: 11))
                            .foregroundStyle(VTheme.accentText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(VTheme.accentBg, in: Capsule())
                    }
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
                // 展开区限高 45vh（原版 :208）；内容随折叠卸载（Accordion.tsx:66）
                ScrollView {
                    IndependentAgentsPanelContentView(vm: vm)
                }
                .frame(maxHeight: viewportHeight * 0.45)
            }
        }
    }
}

// MARK: - 2. 项目区（无折叠壳；ProjectPanel.tsx:262-265 外层语义）

private struct ProjectSection: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var box = ProjectPanelViewModelBox()
    let viewportHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            if let vm = box.vm {
                ProjectPanelContentView(vm: vm, viewportHeight: viewportHeight)
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
    @StateObject private var box = AgentPanelViewModelBox()

    var body: some View {
        Group {
            if let vm = box.vm {
                AgentPanelContentView(vm: vm)
                    .onAppear { vm.start() }
                    .onDisappear { vm.stop() }
            } else {
                Color.clear
                    .task { box.attach(appState: appState) }
            }
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
                        // 原版 fontSize 12.5、weight 500（:191）
                        .font(.system(size: 12.5, weight: .medium))
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
                .background(isOpen ? VTheme.bgActive : (hovering ? VTheme.bgHover : Color.clear),
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
