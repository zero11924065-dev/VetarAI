//
//  WorkflowSidebarView.swift
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

//  用户拍板结构（图2 流程中心两板块单栏化）：「参考智能中心，左侧工作流和CU宏采用
//  和智能中心一致，点击工作流显示已有工作流或者可以点击新建，CU宏也同理。不需要
//  三个板块。用户的核心视觉是中心区域」：
//    1. 「工作流」手风琴：头 = square.stack.3d.up 图标 + 标题 + 数量徽标 +
//       新建「+」入口 + chevron（高 36，壳样式对齐智能中心独立 Agent 手风琴，
//       IntelligenceSidebarView.swift）；展开区高度随条目数自适应、上限 45vh
//       （行 = 名称+（内置）标记 + 描述，文案逐字沿用原左列列表）；空态引导文案同原版
//    2. 「CU 宏」手风琴：头 = desktopcomputer 图标 + 标题 + 数量徽标 + chevron；
//       展开区高度随条目数自适应、上限 45vh（行 = 名称 + 时间·步数）；加载中/空态文案同原版
//    3. 两区各自独立 open（对齐智能中心独立 Agent 手风琴的独立 open 状态）；
//       当前所属面板对应的区默认展开，另一区收起（首次挂载播种一次）
//    4. 数据同源：列表/选中/新建全部走 WorkflowCenterState 持有的共享 VM——
//       侧栏与内容区操作同一实例（对齐原版 App.tsx viewingRtId 提升语义；
//       共享态模式对齐 IntelligenceCenterState）
//    ⛔ 纪律沿用 DBG-145：弹性区不得加 .layoutPriority(1)；展开区限高
//    .frame(maxHeight: viewportHeight * 0.45)，Spacer 不带优先级
//

import SwiftUI

// MARK: - 流程中心共享态（工作流/CU 宏 VM 单例：侧栏手风琴与内容区面板共用）

/// 流程中心级共享状态。RootView 持有并注入环境；工作流与 CU 宏 ViewModel 在此
/// 单例化——侧栏「列表 + 新建」与内容区「画布/编辑器/详情卡」读写同一 VM
/// （对齐 IntelligenceCenterState/roundtableVM 的现有做法：VM 构造需要已注入的
/// AppState，attach 时一次性懒建）。
@MainActor
final class WorkflowCenterState: ObservableObject {
    @Published private(set) var workflowVM: WorkflowPanelViewModel?
    @Published private(set) var cuMacroVM: CuMacroPanelViewModel?

    /// attach 时留存（侧栏行点击/新建 → appState.selectPanel 联动要用；
    /// AppState 是根级单例，随 app 同寿，强引用无环）
    private var appState: AppState?

    func attach(appState: AppState) {
        self.appState = appState
        if workflowVM == nil { workflowVM = WorkflowPanelViewModel(appState: appState) }
        if cuMacroVM == nil {
            // 对齐原 CuMacroPanelViewModelBox 的构造口径（clientProvider 延迟取侧车客户端）
            cuMacroVM = CuMacroPanelViewModel(
                clientProvider: { [weak appState] in
                    appState?.runtime.client as? CuMacroPanelClient
                },
                logger: appState.logger)
        }
    }

    /// 侧栏点工作流行：切「工作流」面板 + 共享 VM 选中（内容区同源联动）
    func selectWorkflow(_ wf: WorkflowRecord) {
        if let panel = PanelRegistry.panel(forKey: "workflows") {
            appState?.selectPanel(panel)
        }
        workflowVM?.selectWorkflow(wf)
    }

    /// 侧栏「+」新建工作流：切「工作流」面板 + 共享 VM 新建（成功后 VM 内选中新项）
    func createWorkflow() {
        if let panel = PanelRegistry.panel(forKey: "workflows") {
            appState?.selectPanel(panel)
        }
        workflowVM?.createWorkflow()
    }

    /// 侧栏点宏行：切「CU 宏」面板 + 共享 CU VM 选中（内容区详情卡同源联动）
    func selectMacro(_ macro: CuMacroSummary) {
        if let panel = PanelRegistry.panel(forKey: "cu-macro") {
            appState?.selectPanel(panel)
        }
        cuMacroVM?.select(macro)
    }

    /// 侧栏 CU 宏「+」：切「CU 宏」面板（录制区=面板内名称输入+双入口；
    /// 零宏时无宏行可点，此为进面板的唯一入口——缺口修复见 P3-W4 收口）
    func openCuMacroPanel() {
        if let panel = PanelRegistry.panel(forKey: "cu-macro") {
            appState?.selectPanel(panel)
        }
    }
}

// MARK: - 流程中心侧栏（单栏堆叠：工作流手风琴 + CU 宏手风琴）

struct WorkflowSidebarView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var center: WorkflowCenterState

    /// 两区各自独立 open（对齐智能中心独立 Agent 手风琴的独立 @State open）
    @State private var openWorkflows = true
    @State private var openCuMacro = false
    /// 首次挂载播种一次：当前所属面板对应的区默认展开，另一区收起
    @State private var seeded = false

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                // 1. 工作流手风琴（列表 + 新建「+」）
                if let wfVM = center.workflowVM {
                    WorkflowAccordionSection(
                        vm: wfVM, isOpen: $openWorkflows,
                        viewportHeight: geo.size.height)
                } else {
                    Color.clear.frame(height: 0)
                }

                // 2. CU 宏手风琴（列表；录制入口保留在内容区）
                if let cuVM = center.cuMacroVM {
                    CuMacroAccordionSection(
                        vm: cuVM, isOpen: $openCuMacro,
                        viewportHeight: geo.size.height)
                } else {
                    Color.clear.frame(height: 0)
                }

                // 各区自然顶堆，下方留白（对齐智能中心无 Agent 区时的同款处理；
                //  ⛔ Spacer 不得带 layoutPriority(1)，DBG-145 同款塌缩）
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            guard !seeded else { return }
            seeded = true
            // 当前所属面板对应的区默认展开，另一区收起
            let isCu = appState.selectedPanel.key == "cu-macro"
            openCuMacro = isCu
            openWorkflows = !isCu
        }
    }
}

// MARK: - 1. 工作流手风琴（壳对齐智能中心独立 Agent 手风琴）

private struct WorkflowAccordionSection: View {
    @EnvironmentObject private var center: WorkflowCenterState
    /// 观察下沉：徽标计数/列表必须经 @ObservedObject 订阅 vm（对齐智能中心口径）
    @ObservedObject var vm: WorkflowPanelViewModel
    @Binding var isOpen: Bool
    let viewportHeight: CGFloat
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            // 头：图标 + 标题 + 数量徽标 + 新建「+」入口 + chevron（高 36）
            // 「+」为独立按钮（不与折叠 toggle 嵌套——SwiftUI 按钮套按钮命中不可靠），
            // 顺序 = 徽标 → + → chevron，hover/open 底色整行一致
            HStack(spacing: 0) {
                Button { isOpen.toggle() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "square.stack.3d.up")
                            .font(.system(size: 13))
                        Text("工作流")
                            .font(VTheme.Typo.body)
                        Spacer()
                        // 数量徽标（对齐智能中心徽标样式：accentBg/accentText，fontSize 11）
                        if !vm.workflows.isEmpty {
                            Text("\(vm.workflows.count)")
                                .font(.system(size: 11))
                                .foregroundStyle(VTheme.accentText)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(VTheme.accentBg, in: Capsule())
                        }
                    }
                    .padding(.leading, 12)
                    .frame(height: 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // 0.7.5 W13：叶子按钮自带 id——否则继承容器 id，运行态 AX 树同 id 多元素
                .accessibilityIdentifier("workflowAccordionHeader.toggle")

                // 新建「+」入口（原左列列表头「新建」按钮的归位；点击切面板 + 共享 VM 新建）
                Button { center.createWorkflow() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11))
                        .foregroundStyle(VTheme.accentText)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("新建")
                .accessibilityIdentifier("workflowCreate")

                Button { isOpen.toggle() } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11))
                        .foregroundStyle(VTheme.textTertiary)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                        .padding(.trailing, 12)
                        .frame(height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // 0.7.5 W13：同上，chevron 叶子加后缀
                .accessibilityIdentifier("workflowAccordionHeader.chevron")
            }
            .foregroundStyle(isOpen || hovering ? VTheme.textPrimary : VTheme.textSecondary)
            .background(isOpen || hovering ? VTheme.bgHover : Color.clear)
            .onHover { hovering = $0 }
            // 头容器 id 保持不变（既有断言锚点）；多实例区分由叶子的 .toggle/.chevron 后缀承担
            .accessibilityIdentifier("workflowAccordionHeader")

            if isOpen {
                // 展开区高度随条目数自适应、上限 45vh：fixedSize 取内容理想高，
                // frame maxHeight 截顶——条目少不锁死空白，条目多截顶滚动
                // （上限口径对齐智能中心手风琴展开区）；⛔ 不得加 layoutPriority(1)（DBG-145）
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if vm.workflows.isEmpty {
                            // 空态引导文案逐字沿用原左列列表空态
                            Text("还没有工作流。点「新建」创建你的第一个流程：拖入节点、连线、设定模型与提示词，即可重复执行。")
                                .font(VTheme.Typo.caption)
                                .foregroundStyle(VTheme.textTertiary)
                                .lineSpacing(4)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 16)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(vm.workflows) { wf in
                            workflowRow(wf)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: viewportHeight * 0.45)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        // 双挂载点计数生命周期：侧栏列表与内容区面板任一存活则 VM 不停
        .onAppear { vm.attach() }
        .onDisappear { vm.detach() }
        // 尾边框 borderSubtle（对齐智能中心分区尾边框）
        .overlay(alignment: .bottom) {
            Rectangle().fill(VTheme.borderSubtle).frame(height: 1)
        }
    }

    /// 工作流行（内容逐字沿用原左列 workflowRow：名称+（内置）+ 可选描述；点击选中）
    private func workflowRow(_ wf: WorkflowRecord) -> some View {
        let sel = vm.selectedId == wf.id
        return Button { center.selectWorkflow(wf) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(wf.name + (wf.builtIn ? "（内置）" : ""))
                    .font(VTheme.Typo.body.weight(.medium))
                    .foregroundStyle(sel ? VTheme.textPrimary : VTheme.textSecondary)
                if !wf.description.isEmpty {
                    Text(wf.description)
                        .font(VTheme.Typo.micro)
                        .foregroundStyle(VTheme.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(sel ? VTheme.bgSelected : Color.clear,
                        in: RoundedRectangle(cornerRadius: VTheme.Radius.s))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("workflowRow.\(wf.id)")
    }
}

// MARK: - 2. CU 宏手风琴（壳同工作流区；行 = 名称 + 时间·步数）

private struct CuMacroAccordionSection: View {
    @EnvironmentObject private var center: WorkflowCenterState
    @ObservedObject var vm: CuMacroPanelViewModel
    @Binding var isOpen: Bool
    let viewportHeight: CGFloat
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            // 头三段式（同工作流区：折叠 | 录制新宏「+」 | chevron；按钮不嵌套——SwiftUI 按钮套按钮命中不可靠）
            HStack(spacing: 0) {
                Button { isOpen.toggle() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 13))
                        Text("CU 宏")
                            .font(VTheme.Typo.body)
                        Spacer()
                        // 数量徽标（列表未拉回时不显示）
                        if let count = vm.macros?.count, count > 0 {
                            Text("\(count)")
                                .font(.system(size: 11))
                                .foregroundStyle(VTheme.accentText)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(VTheme.accentBg, in: Capsule())
                        }
                    }
                    .padding(.leading, 12)
                    .frame(height: 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // 0.7.5 W13：叶子按钮自带 id——否则继承容器 id，运行态 AX 树同 id 多元素
                .accessibilityIdentifier("cuMacroAccordionHeader.toggle")

                // 录制新宏「+」入口（零宏时进 CU 宏面板的唯一入口；录制区在面板内）
                Button { center.openCuMacroPanel() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11))
                        .foregroundStyle(VTheme.accentText)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("录制新宏")
                .accessibilityIdentifier("cuMacroCreate")

                Button { isOpen.toggle() } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11))
                        .foregroundStyle(VTheme.textTertiary)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                        .padding(.trailing, 12)
                        .frame(height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // 0.7.5 W13：同上，chevron 叶子加后缀
                .accessibilityIdentifier("cuMacroAccordionHeader.chevron")
            }
            .foregroundStyle(isOpen || hovering ? VTheme.textPrimary : VTheme.textSecondary)
            .background(isOpen || hovering ? VTheme.bgHover : Color.clear)
            .onHover { hovering = $0 }
            // 头容器 id 保持不变（既有断言锚点）；多实例区分由叶子的 .toggle/.chevron 后缀承担
            .accessibilityIdentifier("cuMacroAccordionHeader")

            if isOpen {
                // 展开区高度随条目数自适应、上限 45vh（同工作流区：fixedSize 取内容
                // 理想高、frame maxHeight 截顶，条目少不锁死空白）；
                // ⛔ 不得加 layoutPriority(1)（DBG-145）
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if vm.macros == nil {
                            Text("加载宏列表…")
                                .font(VTheme.Typo.micro)
                                .foregroundStyle(VTheme.textTertiary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 16)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else if vm.macros!.isEmpty {
                            // 空态文案逐字沿用原内容区宏列表空态
                            Text("暂无宏——输入名称开始录制第一个。")
                                .font(VTheme.Typo.micro)
                                .foregroundStyle(VTheme.textTertiary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 16)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            ForEach(vm.macros!) { macro in
                                macroRow(macro)
                            }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: viewportHeight * 0.45)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        // 双挂载点计数生命周期：侧栏列表与内容区面板任一存活则轮询不停
        .onAppear { vm.attach() }
        .onDisappear { vm.detach() }
        .overlay(alignment: .bottom) {
            Rectangle().fill(VTheme.borderSubtle).frame(height: 1)
        }
    }

    /// 宏行（名称 + 时间·步数，行内容沿用原 MacroRowView 文本；点击选中）
    private func macroRow(_ macro: CuMacroSummary) -> some View {
        let sel = vm.selectedId == macro.id
        return Button { center.selectMacro(macro) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(macro.name)
                    .font(VTheme.Typo.body)
                    .foregroundStyle(sel ? VTheme.textPrimary : VTheme.textSecondary)
                Text("\(macro.created_at) · \(macro.steps) 步")
                    .font(VTheme.Typo.micro)
                    .foregroundStyle(VTheme.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(sel ? VTheme.bgSelected : Color.clear,
                        in: RoundedRectangle(cornerRadius: VTheme.Radius.s))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("cuMacroRow.\(macro.id)")
    }
}
