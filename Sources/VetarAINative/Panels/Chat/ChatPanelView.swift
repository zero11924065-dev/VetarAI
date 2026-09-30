//
//  ChatPanelView.swift
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

//  会话面板视图。结构对照现状 ChatPanel.tsx（A12 0.4.25 纸面工具布局）：
//    · U2 方案A：原 210pt 会话侧栏已移除——原版无会话侧栏（两级导航），
//      会话切换收进顶栏 Picker + 刷新/新建（逐字对齐 ChatPanel.tsx:2560-2582），
//      重命名/删除仍走 ⋯ 菜单（原版同）
//    · 顶栏：Agent 名 + 会话 Picker/刷新/新建 + 模型选择 + 上下文指示器（0.4.34 口径）
//      + 勾选/仓库开关 + ⋯ 菜单
//    · U3：知识仓库 300pt 窄栏嵌回对话区右端（结构对齐 ChatPanel.tsx:3152-3164，
//      默认收起；onInject 把勾选文本追加进输入框 + Toast「知识已注入输入框，确认后发送」）
//    · 消息区：思考行（单行钳制 + 悬浮全文，F3）/ 工具步骤组（B4 折叠）/ Markdown /
//      计时三件套 / 错误块（分析 + 重发 + 复制 + 模型降级卡）/ 视觉引导卡 / 等待横幅 /
//      已手动停止 / 归档占位
//    · M2 压缩警告条（三选一）+ M5 重连提示条 + 「回到底部」
//    · 暂存区（图片缩略 / 文档三态 chip）+ 输入卡片（附件 / 语音占位 / 发送·停止·注入）
//

import SwiftUI
import AppKit

/// 0.5.1 R2：会话顶条自适应规格常量（逐字对齐 0.4.x ChatPanel.tsx:2547-2657）。
/// 抽成枚举供视图与测试双端钉死——改动必须同步改测试。
enum ChatTopBarSpec {
    /// Agent 徽章最小宽（0.4.x 徽章 flexShrink:1 minWidth:48）
    static let badgeMinWidth: CGFloat = 48
    /// 会话 Picker 最小宽（0.4.x select minWidth:80）
    static let sessionMinWidth: CGFloat = 80
    /// 会话 Picker 最大宽（0.4.x 容器 maxWidth:180）
    static let sessionMaxWidth: CGFloat = 180
    /// 模型 Picker 最大宽（0.4.x 模型名文本 maxWidth:140）
    static let modelMaxWidth: CGFloat = 140
    /// 顶栏图标钮命中目标边长（0.7.14 ⋯ razor-thin 根治）：label 内扩 22×22
    /// + contentShape ⇒ 命中区=22×22；22 ≤ vGhost 布局高 28 不改行高；宽 +10/钮
    /// 由左组吸收（F1 结构加固兜底）；邻钮心距 44pt 不重叠。
    static let iconHitTarget: CGFloat = 22
}

/// 补充三（0.7.6 实测）：⋯ 更多菜单窗口内 overlay 下拉规格——下拉约束在应用
/// 窗口内（topTrailing 对齐，右缘 = 顶栏右内边距 12，永不越出窗口右缘）。
/// 抽成枚举供视图与测试双端钉死——改动必须同步改测试。
enum ChatMoreMenuSpec {
    /// 菜单宽（A12 既有 minWidth 190 口径）
    static let menuWidth: CGFloat = 190
    /// 距顶偏移（顶栏 vertical padding 8×2 + 内容 ~28 ≈ 44，菜单贴顶栏下缘展开）
    static let topOffset: CGFloat = 44
    /// 右内边距（= 顶栏 horizontal padding 12，菜单右缘与顶栏右组对齐）
    static let trailingInset: CGFloat = 12
}

public struct ChatPanelView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var vmBox = ChatViewModelBox()

    public init() {}

    public var body: some View {
        // ChatViewModel 依赖 appState，environmentObject 注入时机晚于 StateObject 构建，
        // 故用 Box 延迟构建一次。
        if let vm = vmBox.vm {
            ChatPanelBody(vm: vm)
        } else {
            VLoadingView("会话面板初始化…")
                .task { vmBox.attach(appState: appState) }
        }
    }
}

/// 延迟构建 ChatViewModel（需要已注入的 AppState）。
@MainActor
final class ChatViewModelBox: ObservableObject {
    @Published var vm: ChatViewModel?
    func attach(appState: AppState) {
        if vm == nil { vm = ChatViewModel(appState: appState) }
    }
}

// MARK: - 面板主体

private struct ChatPanelBody: View {
    @ObservedObject var vm: ChatViewModel

    var body: some View {
        // U2 方案A：210pt 会话栏移除（原版无会话侧栏，两级导航）——会话切换/新建/刷新
        // 收进 ChatDetailView 顶栏（对齐 ChatPanel.tsx:2560-2582），重命名/删除走 ⋯ 菜单。
        ChatDetailView(vm: vm)
    }
}

// MARK: - 对话区

private struct ChatDetailView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var vm: ChatViewModel
    @State private var composerHeight: CGFloat = 38
    @State private var showMoreMenu = false
    @State private var showWarehouse = false
    @State private var autoFollow = true
    @State private var showBackToBottom = false
    /// P3-W3b 语音输入控制器（话筒按钮；缝在 onAppear 绑定）。
    @StateObject private var voice = VoiceInputController()

    var body: some View {
        // U3：外层 HStack 右端接知识仓库窄栏（结构对齐 ChatPanel.tsx:3152-3164——
        // 默认收起，顶栏数据库图标开关，收起不影响会话区布局）
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                topBar
                Divider()
                if let err = vm.lastError {
                    VCallout(.error, err)
                        .padding(.horizontal, 12).padding(.top, 8)
                }
                // M2 溢出预警警告条（§8.7）
                if let w = vm.compactWarning { compactBar(w) }
                // M5 断线重连提示条（§8.8）
                if let notice = vm.reconnectNotice {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(notice).font(VTheme.Typo.caption)
                    }
                    .padding(.horizontal, 12).padding(.top, 8)
                    .foregroundStyle(VTheme.warnText)
                }
                messageArea
                Divider()
                pendingArea
                composer
            }
            // 0.5.2 W7：minWidth:0 + clipped（0.4.x ChatPanel.tsx:2546 会话区
            // minWidth:0 + overflow:hidden 同构）——窄窗+仓库开时 HStack 可把
            // 会话区压到低于其内容最小宽（顶栏右组 ZStack+fixedSize 拒压，
            // 实测 960 档顶栏报 428 > 会话 348），仓库栏 300pt 恒完整
            // （0.4.x flexShrink:0）。alignment:.leading 是裁切方向关键：
            // frame 默认 .center 会把超宽内容左右各裁一半（「上下文」被切成
            // 「下文」的根因），.leading 左贴、溢出单向向右被 clipped 裁
            // （0.4.x flex 左排 + overflow:hidden 同构：裁 ⋯→⛁，指示器
            // 保到最后一刻）。
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity,
                   alignment: .leading)
            .clipped()
            if showWarehouse {
                WarehousePanelView(
                    onClose: { showWarehouse = false },
                    onInject: { text in vm.injectKnowledgeText(text) })
            }
        }
        // TS-120：转移弹窗
        .sheet(isPresented: $vm.showTransferModal) { transferModal }
        // 补充三：⋯ 下拉 = 窗口内 overlay（topTrailing 对齐顶栏右内边距，永不越出
        // 窗口）；全屏透明层点击任意处即关，层与菜单同 showMoreMenu 布尔驱动——
        // 渲染同帧共存亡，不存在 popover 式状态泄漏/拦截失焦窗口。
        .overlay(alignment: .topTrailing) {
            if showMoreMenu {
                ZStack(alignment: .topTrailing) {
                    Color.black.opacity(0.001)   // 透明关窗层（非 clear，保命中）
                        .contentShape(Rectangle())
                        .onTapGesture { showMoreMenu = false }
                    moreMenu
                        .background(VTheme.bgCard, in: RoundedRectangle(cornerRadius: VTheme.Radius.m))
                        .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.m).stroke(VTheme.borderDefault))
                        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
                        .padding(.top, ChatMoreMenuSpec.topOffset)
                        .padding(.trailing, ChatMoreMenuSpec.trailingInset)
                }
                .onExitCommand { showMoreMenu = false }
            }
        }
        .onAppear { bindVoice() }
    }

    /// P3-W3b：话筒控制器接线（client 经 runtime 解析——原生客户端已
    /// conform AsrPanelClient；ids/上屏回调捕获 vm 引用，永远取当前值）。
    private func bindVoice() {
        voice.clientProvider = { [appState] in appState.runtime.client as? any AsrPanelClient }
        voice.idsProvider = { [vm] in (vm.projectId ?? "", vm.currentSessionId ?? "") }
        voice.onText = { [vm] text in vm.insertTranscribedText(text) }
    }

    // MARK: 顶栏（A12：白底细线 + ⋯ 菜单收纳低频操作）

    /// 0.5.1 R2：顶条自适应（逐字对齐 0.4.x ChatPanel.tsx:2547-2657 的收缩策略）——
    /// 左组可压（minWidth:0）：Agent 徽章先截断（layoutPriority 最低，名字
    /// lineLimit(1)+省略号，截断时悬停出全名——有意偏差增强，0.4.x 无悬停）、
    /// 会话 Picker 80…180 弹性收缩、模型 Picker 上限 140（0.4.x 同值）；
    /// 右组永不压缩（.fixedSize()）：上下文指示器全文案不缩写（0.4.x 从不缩写）、
    /// 勾选/仓库/⋯ 三钮固定。红线：任何文字要么完整显示要么收进⋯菜单，不可截断看不见。
    private var topBar: some View {
        HStack(spacing: 10) {
            // ── 左组（可压：吸收全部裁切，0.4.x 左组 minWidth:0 同构）──
            HStack(spacing: 10) {
                // Agent 标识 + 对话上下文（问题1：用户要知道自己在跟谁聊——
                // 项目名/独立 Agent 作用域 · Agent 名；对照现状顶部 agentInfo 口径）
                HStack(spacing: 7) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(VTheme.accentBgSoft)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(VTheme.accentBorder))
                            .frame(width: 26, height: 26)
                        Image(systemName: "cpu")
                            .font(.system(size: 12))
                            .foregroundStyle(VTheme.accentText)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(vm.agentName.isEmpty ? "Agent" : vm.agentName)
                            .font(VTheme.Typo.body.weight(.semibold))
                            .lineLimit(1)
                        if !vm.contextScope.isEmpty {
                            Text(vm.contextScope)
                                .font(VTheme.Typo.micro)
                                .foregroundStyle(VTheme.textTertiary)
                                .lineLimit(1)
                        }
                    }
                }
                // R2：徽章是左组里最舍得让位的元素——先截断，悬停补全名
                .frame(minWidth: ChatTopBarSpec.badgeMinWidth)
                .layoutPriority(-1)
                .help(vm.agentName.isEmpty ? "Agent" : vm.agentName)
                .accessibilityIdentifier("chatContextBadge")

                // U2：会话切换收进顶栏（逐字对齐 ChatPanel.tsx:2560-2582 的 select + 刷新/新建；
                // 原版无会话侧栏——两级导航的关键一刀）
                Picker("会话", selection: Binding(
                    get: { vm.currentSessionId ?? "" },
                    set: { if !$0.isEmpty { vm.switchSession($0) } }
                )) {
                    if vm.sessions.isEmpty {
                        Text("无会话").tag("")
                    }
                    ForEach(vm.sessions) { s in
                        Text("\(s.title ?? s.id) (\(s.message_count ?? 0)条)").tag(s.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(minWidth: ChatTopBarSpec.sessionMinWidth, maxWidth: ChatTopBarSpec.sessionMaxWidth)
                .accessibilityIdentifier("sessionPicker")

                Button {
                    Task { _ = try? await vm.refreshSessions() }
                } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.vGhost).controlSize(.small)
                .help("刷新会话列表")
                .disabled(!appState.runtime.nativeReady)
                .accessibilityIdentifier("refreshSessionsButton")
                Button {
                    Task { _ = try? await vm.createSession() }
                } label: { Image(systemName: "plus") }
                .buttonStyle(.vGhost).controlSize(.small)
                .help("新建会话")
                .disabled(!appState.runtime.nativeReady)
                .accessibilityIdentifier("newSessionButton")

                // 模型选择（恒原生后 nativeReady 恒 true，「侧车未连接」文案分支消亡——
                // 空名单即后端无模型，P3-W6 起直显）
                if vm.models.isEmpty {
                    Text("无可用模型")
                        .font(VTheme.Typo.caption)
                        .foregroundStyle(VTheme.textSecondary)
                        .lineLimit(1)
                } else {
                    // F6（0.7.12 实测 A8）：原生 Picker(.menu) = NSPopUpButton——
                    // 弹出时把选中项对齐到按钮位（整单垂直平移），选中变化后
                    // 再打开各模型位置全变（「选中项置顶重排，要重新找一遍」）。
                    // 换 Menu 自定义行：恒从按钮下缘展开、行序恒 = vm.models
                    // 序（选择不回排数据源），选中项行内 ✓ 标记——位置肌肉记忆稳定。
                    Menu {
                        ForEach(vm.models, id: \.name) { m in
                            Button {
                                vm.selectedModel = m.name
                            } label: {
                                HStack {
                                    Text(m.name)
                                    if vm.selectedModel == m.name {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        Text(vm.selectedModel ?? "选择模型")
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(maxWidth: ChatTopBarSpec.modelMaxWidth)
                    .help("当前会话使用的模型")
                    .accessibilityIdentifier("modelPicker")
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .clipped()

            // ── 右组（按钮恒足额 + 指示器吸收压缩；0.4.x 右组 flexShrink:0 同构）──
            // F1（0.7.12 结构加固，保留有效）：旧 ZStack(alignment:.leading){ HStack
            // .fixedSize() } 整组零压缩、窄窗右溢的隐患消除——三按钮 fixedSize 恒足额
            // 永不溢出；指示器去 fixedSize 可截尾 + minWidth:0/clipped 吸收全部压缩，
            // tooltip 兜底全文。宽窗下零截断，像素与旧布局一致。
            // ⚠️ 但「⋯ 菜单点不开」的真凶并非溢出（0.7.13 业主实测复发后运行中应用
            // AX 命中取证）：1179pt 宽窗下 ⋯ 命中区仅 12×2.5——自定义 ButtonStyle 的
            // padding/frame 只进布局不进命中区，命中区=label 框架；ellipsis 字形
            // razor-thin，±3pt 瞄准误差即落空。0.7.14 根治=label 内扩命中目标
            //（vIconHitTarget，见 VButtons.swift / ChatTopBarHitTargetF1Tests）。
            // layoutPriority(1) 让顶栏 HStack 优先供宽（左组先被压到 0）。
            HStack(spacing: 10) {
                // 上下文指示器（0.4.34 口径：主数字=上限，括号当前档；全文案不缩写——
                // 宽窗恒全文；窄窗截尾宁可裁字也不缩写文案，.help 悬浮看全文）
                if vm.tokenIndicator.limit > 0 {
                    HStack(spacing: 6) {
                        Text(vm.tokenIndicator.displayText)
                            .font(VTheme.Typo.micro)
                            .foregroundStyle(VTheme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        ZStack(alignment: .leading) {
                            Capsule().fill(VTheme.borderSubtle).frame(width: 64, height: 4)
                            Capsule()
                                .fill(barColor)
                                .frame(width: max(2, 64 * min(1, vm.tokenIndicator.ratio)), height: 4)
                        }
                    }
                    .frame(minWidth: 0, alignment: .leading)
                    .clipped()
                    .help(vm.tokenIndicator.tooltip)
                    .accessibilityIdentifier("contextIndicator")
                } else if let failed = vm.tokenIndicator.failedText {
                    Text(failed)
                        .font(VTheme.Typo.micro)
                        .foregroundStyle(VTheme.dangerText)
                        .lineLimit(1)
                        .frame(minWidth: 0, alignment: .leading)
                        .clipped()
                }

                if vm.currentSessionId != nil {
                    HStack(spacing: 10) {
                    // TS-120：勾选消息 → 移入知识仓库
                    Button { vm.toggleSelectMode() } label: {
                        Image(systemName: "checkmark.circle")
                            .foregroundStyle(vm.selectMode ? VTheme.accentText : VTheme.textSecondary)
                            .vIconHitTarget(ChatTopBarSpec.iconHitTarget)
                    }
                    .buttonStyle(.vGhost).controlSize(.small)
                    .help("勾选消息 → 移入知识仓库")
                    .accessibilityIdentifier("selectModeButton")
                    // TS-120：知识仓库面板开关（U3：右端内嵌 300pt 窄栏，原版 ChatPanel.tsx:2619-2625 同位）
                    Button { showWarehouse.toggle() } label: {
                        Image(systemName: "cylinder")
                            .foregroundStyle(showWarehouse ? VTheme.accentText : VTheme.textSecondary)
                            .vIconHitTarget(ChatTopBarSpec.iconHitTarget)
                    }
                    .buttonStyle(.vGhost).controlSize(.small)
                    .help("知识仓库（检索/注入）")
                    .accessibilityIdentifier("warehouseToggle")
                    // A12：⋯ 更多操作（补充三 0.7.6 实测修复：下拉从 NSPopover 改为
                    // 窗口内 overlay——① NSPopover 只避让屏幕边界不避让窗口边界，
                    // 顶栏右缘展开时下拉会超出应用窗口；② popover isPresented 与
                    // 重渲偶发失步（状态泄漏 true → 下次点击变「关」无反应，
                    // 再点恢复）。overlay 单一布尔驱动无呈现层可失步；
                    // topTrailing 对齐 + 右内边距，下拉永不越出窗口）
                    Button { showMoreMenu.toggle() } label: {
                        Image(systemName: "ellipsis")
                            .vIconHitTarget(ChatTopBarSpec.iconHitTarget)
                    }
                    .buttonStyle(.vGhost).controlSize(.small)
                    .help("更多操作")
                    .accessibilityIdentifier("moreMenuButton")
                    }
                    .fixedSize()   // F1：三按钮恒足额——最小宽=理想宽，永不溢出命中界
                }
            }
            .layoutPriority(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var barColor: Color {
        switch vm.tokenIndicator.barLevel {
        case .ok: return VTheme.ok
        case .warn: return VTheme.warn
        case .danger: return VTheme.danger
        }
    }

    private var moreMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            menuItem("生成会话总结", icon: "doc.text",
                     tip: "生成会话总结并保存（Markdown + 记录）") {
                Task { await vm.summarizeSession() }
            }
            menuItem("导出会话", icon: "square.and.arrow.down", tip: "导出会话为 Markdown") {
                Task { await vm.exportSession() }
            }
            menuItem("单元归档", icon: "archivebox",
                     tip: "单元归档：开启后 Agent 每完成一个工作单元（批量任务）会把该段对话移入知识仓库，防止上下文膨胀。默认关闭，需手动开启",
                     active: vm.autoArchiveUnit) {
                vm.autoArchiveUnit.toggle()
            }
            Divider().padding(.vertical, 2)
            menuItem("重命名", icon: "pencil", tip: "重命名") {
                if let sid = vm.currentSessionId { Task { await vm.renameSession(sid) } }
            }
            menuItem("删除", icon: "trash", tip: "删除", danger: true) {
                if let sid = vm.currentSessionId { Task { await vm.deleteSession(sid) } }
            }
        }
        .padding(6)
        .frame(width: ChatMoreMenuSpec.menuWidth)
    }

    private func menuItem(_ label: String, icon: String, tip: String,
                          danger: Bool = false, active: Bool = false,
                          action: @escaping () -> Void) -> some View {
        Button {
            showMoreMenu = false
            action()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 14)
                    .foregroundStyle(danger ? VTheme.dangerText : VTheme.textTertiary)
                Text(label).font(VTheme.Typo.caption)
                Spacer()
                if active { Image(systemName: "checkmark").foregroundStyle(VTheme.accent) }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10).padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .foregroundStyle(danger ? VTheme.dangerText : VTheme.textPrimary)
        .help(tip)
    }

    // MARK: M2 压缩警告条（三选一，现状文案逐字）

    private func compactBar(_ w: ChatViewModel.CompactWarning) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("上下文已用 \(w.used)/\(w.limit)（\(w.limit > 0 ? Int((Double(w.used) / Double(w.limit) * 100).rounded()) : 0)%），预计还能约 \(w.est >= 0 ? "\(w.est)" : "未知") 轮。请选择处理方式：")
                    .font(VTheme.Typo.caption)
            }
            HStack(spacing: 8) {
                Button("智能压缩") { Task { await vm.compactSmart() } }
                    .buttonStyle(.vPrimary).controlSize(.small)
                Button("清空开新会话") { Task { await vm.compactNewSession() } }
                    .buttonStyle(.vSecondary).controlSize(.small)
                Button("导出后清空") { Task { await vm.compactExportThenNew() } }
                    // 对齐原版 ChatPanel.tsx:2704 ui-btn-danger-soft（危险操作红色）
                    .buttonStyle(.vDanger).controlSize(.small)
            }
        }
        .foregroundStyle(VTheme.warnText)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(VTheme.warnBg)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(VTheme.warnBorder), alignment: .bottom)
    }

    // MARK: 消息区

    private var messageArea: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(vm.messages) { msg in
                            MessageRow(
                                message: msg, vm: vm,
                                isStreamingThis: vm.sending && msg.isStreaming
                                    && msg.id == vm.messages.last?.id,
                                selectMode: vm.selectMode,
                                selected: msg.dbId.map { vm.selectedDbIds.contains($0) } ?? false
                            )
                            .id(msg.id)
                        }
                        // B15 距底探测锚点
                        Color.clear.frame(height: 1)
                            .id("bottom")
                            .background(GeometryReader { g in
                                Color.clear.preference(key: BottomOffsetKey.self,
                                    value: g.frame(in: .named("chatScroll")).maxY - geo.size.height)
                            })
                    }
                    .padding(.horizontal, 24).padding(.vertical, 16)
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .coordinateSpace(name: "chatScroll")
                .onPreferenceChange(BottomOffsetKey.self) { dist in
                    // 现状 B15：距底 ≤100px 才跟随；用户上滚停止跟随并出「回到底部」
                    let atBottom = dist <= 100
                    if !atBottom && autoFollow { autoFollow = false }
                    if atBottom && !autoFollow { autoFollow = true }
                    showBackToBottom = !atBottom
                }
                .onChange(of: vm.messages.last?.content) { _, _ in scrollToBottom(proxy) }
                .onChange(of: vm.messages.count) { _, _ in scrollToBottom(proxy) }
                .overlay(alignment: .bottom) {
                    if showBackToBottom {
                        Button {
                            autoFollow = true
                            showBackToBottom = false
                            proxy.scrollTo("bottom", anchor: .bottom)
                        } label: {
                            Image(systemName: "chevron.down")
                                .frame(width: 36, height: 36)
                                .background(VTheme.bgCard, in: Circle())
                                .overlay(Circle().stroke(VTheme.borderDefault))
                                .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                        }
                        .buttonStyle(.plain)
                        .help("回到底部")
                        .padding(.bottom, 8)
                        .accessibilityIdentifier("backToBottomButton")
                    }
                }
            }
        }
        .background(VTheme.bgApp)
        .overlay {
            if vm.projectMissingAgent {
                // 0.7.6 实测 Bug1 新口径：项目一个 Agent 都没有时不隐式创建，
                // 空态引导用户在左侧 Agent 区显式「+ 添加」，输入框禁用发送
                VEmptyStateView(
                    icon: "person.2",
                    title: "该项目还没有 Agent",
                    message: "请在左侧 Agent 区点「+ 添加」创建 Agent 后，再开始对话")
            } else if vm.messages.isEmpty && !vm.sending {
                VEmptyStateView(
                    icon: "message",
                    title: vm.currentSessionId != nil ? "新会话 — 开始对话吧" : "加载中...",
                    message: "在下方输入消息开始；会话与历史由应用本地持久化，重启后自动回读"
                )
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard autoFollow else { return }
        proxy.scrollTo("bottom", anchor: .bottom)
    }

    private struct BottomOffsetKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
    }

    // MARK: 暂存区（§8.11：图片缩略 + 文档三态 chip）

    @ViewBuilder
    private var pendingArea: some View {
        if !vm.pendingItems.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Text("暂存区:")
                    .font(VTheme.Typo.micro)
                    .foregroundStyle(VTheme.textTertiary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(vm.pendingItems) { item in
                            pendingChip(item)
                        }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(VTheme.bgSidebar)
        }
    }

    @ViewBuilder
    private func pendingChip(_ item: PendingAttachment) -> some View {
        HStack(spacing: 4) {
            if item.kind == .image,
               let data = Data(base64Encoded: String(item.dataURI.split(separator: ",").last ?? "")),
               let img = NSImage(data: data) {
                Image(nsImage: img)
                    .resizable().scaledToFit()
                    .frame(maxWidth: 48, maxHeight: 48)
                    .clipShape(RoundedRectangle(cornerRadius: VTheme.Radius.s))
                    .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.s).stroke(VTheme.borderDefault))
            } else {
                Image(systemName: "doc")
                    .foregroundStyle(VTheme.textTertiary)
                Text(item.name).font(VTheme.Typo.caption).lineLimit(1)
                // 解析三态（checkpoint-048）
                if item.parsing {
                    ProgressView().controlSize(.mini)
                    Text("解析中…").font(VTheme.Typo.micro).foregroundStyle(VTheme.warn)
                } else if item.parsedText != nil {
                    Image(systemName: "checkmark").font(VTheme.Typo.micro).foregroundStyle(VTheme.ok)
                    Text("已提取").font(VTheme.Typo.micro).foregroundStyle(VTheme.ok)
                } else if item.parseFailed {
                    Text("（仅文件名）").font(VTheme.Typo.micro).foregroundStyle(VTheme.textTertiary)
                }
            }
            Button { vm.removePending(item.id) } label: {
                Image(systemName: "xmark").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(VTheme.textTertiary)
            .help("移除该附件")
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(VTheme.bgCard, in: RoundedRectangle(cornerRadius: VTheme.Radius.s))
        .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.s).stroke(VTheme.borderDefault))
    }

    // MARK: 输入卡片（A12 悬浮 composer：左附件右发送/停止）

    private var composer: some View {
        VStack(spacing: 0) {
            ComposerTextView(
                text: $vm.input,
                height: $composerHeight,
                placeholder: vm.projectMissingAgent
                    ? "该项目还没有 Agent，请先在左侧 + 添加..."
                    : vm.pendingItems.isEmpty
                        ? "输入消息（可先上传附件，再输入文字，一起发送）..."
                        : "输入文字描述，或直接发送...",
                disabled: vm.inputDisabled || vm.projectMissingAgent || !appState.runtime.nativeReady,
                onSend: { vm.send() },
                onPasteImages: { vm.addPastedImages($0) },
                onPasteFiles: { vm.addFiles($0) }
            )
            .frame(height: composerHeight)
            .padding(.horizontal, 14).padding(.top, 10)
            .accessibilityIdentifier("messageInput")

            HStack(spacing: 4) {
                // 附件（checkpoint-003 验收：上传按钮必须在）
                Button { pickFiles() } label: {
                    Image(systemName: "paperclip")
                }
                .buttonStyle(.vGhost).controlSize(.small)
                .help("上传图片或文本文件（发送前可在暂存区删除）")
                .accessibilityIdentifier("attachButton")

                // 0.4.29 语音输入（P3-W3b 点亮）：点开始录音、再点停止 →
                // 转写 → 文本入输入框（对齐 ChatPanel.tsx toggleRecording；
                // 录音中红色 + 秒数，转写中转置态）
                Button { voice.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "mic")
                            .foregroundStyle(voice.isRecording ? VTheme.danger : VTheme.textSecondary)
                        if voice.isRecording {
                            Text("录音中 \(voice.recordSeconds)s")
                                .font(.system(size: 11))
                                .foregroundStyle(VTheme.danger)
                        } else if voice.isTranscribing {
                            Text("转写中…")
                                .font(.system(size: 11))
                                .foregroundStyle(VTheme.textSecondary)
                        }
                    }
                }
                .buttonStyle(.vGhost).controlSize(.small)
                .disabled(voice.isTranscribing || !appState.runtime.nativeReady)
                .help(voice.isRecording ? "停止录音" : "语音输入（录音后自动转文字）")
                .accessibilityIdentifier("micButton")

                Spacer()

                if vm.sending {
                    // A5：思考中也能发送——插入新消息（不打断当前轮，下一轮被读到）
                    Button { vm.send() } label: {
                        Image(systemName: "arrow.up").font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(.vPrimary)
                    .clipShape(Circle())
                    .disabled(!hasSendableText(vm.input))
                    .opacity(hasSendableText(vm.input) ? 1 : 0.5)
                    .help("发送新消息（模型完成当前这一步后会读到）")
                    .accessibilityIdentifier("injectSendButton")
                    Button { vm.stop() } label: {
                        Image(systemName: "stop.fill").font(.system(size: 11))
                    }
                    .buttonStyle(.vPrimary)
                    .clipShape(Circle())
                    .help("停止（先 POST 真停后端，再断本地流）")
                    .accessibilityIdentifier("stopButton")
                } else {
                    Button { vm.send() } label: {
                        Image(systemName: "arrow.up").font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(.vPrimary)
                    .clipShape(Circle())
                    .disabled(vm.inputDisabled || vm.projectMissingAgent
                              || !appState.runtime.nativeReady
                              || vm.selectedModel == nil
                              || (!hasSendableText(vm.input) && vm.pendingItems.isEmpty))
                    .opacity((!hasSendableText(vm.input) && vm.pendingItems.isEmpty) ? 0.5 : 1)
                    .help("发送")
                    .accessibilityIdentifier("sendButton")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .background(VTheme.bgCard)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(VTheme.borderDefault), alignment: .top)
        // TS-120：勾选模式浮动栏
        .overlay(alignment: .top) {
            if vm.selectMode {
                HStack(spacing: 10) {
                    Text("已勾选 \(vm.selectedDbIds.count) 条")
                        .font(VTheme.Typo.caption).foregroundStyle(VTheme.textSecondary)
                    Button { vm.showTransferModal = true } label: {
                        Text("移入知识仓库")
                    }
                    .buttonStyle(.vPrimary).controlSize(.small)
                    .disabled(vm.selectedDbIds.isEmpty || vm.transferring)
                    Button("取消") { vm.toggleSelectMode() }
                        .buttonStyle(.vGhost).controlSize(.small)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(VTheme.bgCard, in: RoundedRectangle(cornerRadius: VTheme.Radius.m))
                .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.m).stroke(VTheme.borderSubtle))
                .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
                .offset(y: -56)
            }
        }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        // 现状 accept：图片 + 文档族（音频链待 ASR 模型包移植，本波不提供）
        panel.allowedContentTypes = [.image, .text, .pdf, .commaSeparatedText, .json,
                                     .init(filenameExtension: "md")!,
                                     .init(filenameExtension: "doc")!,
                                     .init(filenameExtension: "docx")!,
                                     .init(filenameExtension: "xlsx")!,
                                     .init(filenameExtension: "xlsm")!,
                                     .init(filenameExtension: "pptx")!,
                                     .init(filenameExtension: "log")!,
                                     .init(filenameExtension: "yaml")!,
                                     .init(filenameExtension: "yml")!,
                                     .init(filenameExtension: "js")!,
                                     .init(filenameExtension: "ts")!,
                                     .init(filenameExtension: "py")!,
                                     .init(filenameExtension: "html")!,
                                     .init(filenameExtension: "css")!]
        panel.begin { resp in
            if resp == .OK { vm.addFiles(panel.urls) }
        }
    }

    // MARK: TS-120 转移弹窗（现状文案逐字）

    private var transferModal: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "cylinder").foregroundStyle(VTheme.accentText)
                Text("移入知识仓库").font(VTheme.Typo.sectionTitle)
                Text("（\(vm.selectedDbIds.count) 条）")
                    .font(VTheme.Typo.caption).foregroundStyle(VTheme.textTertiary)
            }
            Text("勾选的对话将保存为知识条目并脱离本会话上下文（不再发给模型）。内容以 .md 文件永久保存，你删除前一直在。")
                .font(VTheme.Typo.caption).foregroundStyle(VTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Text("保存范围").font(VTheme.Typo.caption).foregroundStyle(VTheme.textSecondary)
                HStack(spacing: 6) {
                    scopeButton("project", label: "本项目（项目文件夹/知识库）")
                    scopeButton("global", label: "全局（所有项目可用）")
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("标题（留空自动取首条前 20 字）").font(VTheme.Typo.caption).foregroundStyle(VTheme.textSecondary)
                TextField("留空自动生成", text: $vm.transferTitle).vInputStyle()
            }
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("分类（可选）").font(VTheme.Typo.caption).foregroundStyle(VTheme.textSecondary)
                    TextField("如：客户材料", text: $vm.transferCategory).vInputStyle()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("关键词（可选，逗号分隔）").font(VTheme.Typo.caption).foregroundStyle(VTheme.textSecondary)
                    TextField("如：聊天,证据", text: $vm.transferKeywords).vInputStyle()
                }
            }
            HStack {
                Spacer()
                Button("取消") { vm.showTransferModal = false }
                    .buttonStyle(.vGhost)
                Button {
                    Task { await vm.confirmTransfer() }
                } label: {
                    if vm.transferring { ProgressView().controlSize(.mini) }
                    Text("确认转移")
                }
                .buttonStyle(.vPrimary)
                .disabled(vm.transferring)
            }
        }
        .padding(22)
        .frame(width: 420)
    }

    private func scopeButton(_ value: String, label: String) -> some View {
        Button { vm.transferScope = value } label: {
            Text(label).font(VTheme.Typo.caption)
                .frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .background(vm.transferScope == value ? VTheme.accentBg : VTheme.bgCard,
                    in: RoundedRectangle(cornerRadius: VTheme.Radius.s))
        .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.s)
            .stroke(vm.transferScope == value ? VTheme.accentBorder : VTheme.borderStrong))
        .foregroundStyle(vm.transferScope == value ? VTheme.accentText : VTheme.textSecondary)
    }
}

// MARK: - 消息行

private struct MessageRow: View {
    let message: ChatMessage
    @ObservedObject var vm: ChatViewModel
    let isStreamingThis: Bool
    let selectMode: Bool
    let selected: Bool

    private var isUser: Bool { message.role == "user" }
    private var isSystem: Bool { message.role == "system" }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
            // 头部：图标 + 称谓 + 时间（+ 勾选框）
            HStack(spacing: 4) {
                if selectMode && !isSystem && !message.archived && message.dbId != nil {
                    Toggle("", isOn: Binding(get: { selected }, set: { _ in vm.toggleMessageSelect(message) }))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                }
                Image(systemName: isUser ? "person" : isSystem ? "info.circle" : "cpu")
                    .font(.system(size: 10))
                Text(isUser ? "你" : isSystem ? "系统" : (message.modelUsed ?? "AI"))
                if let t = message.createdAt, !t.isEmpty {
                    Text(formatChatTime(t)).opacity(0.7)
                }
            }
            .font(VTheme.Typo.micro)
            .foregroundStyle(VTheme.textTertiary)

            // 气泡
            VStack(alignment: .leading, spacing: 6) {
                if message.archived {
                    // TS-120：已移入知识仓库 → 占位提示
                    HStack(spacing: 6) {
                        Image(systemName: "cylinder").font(.system(size: 11))
                        Text("此内容已移入知识仓库，不再参与对话上下文")
                            .font(VTheme.Typo.caption).italic()
                    }
                    .foregroundStyle(VTheme.textTertiary)
                } else {
                    imagesBlock
                    thinkingBlock
                    toolStepsBlock
                    contentBlock
                    stepsCounter
                }
            }
            .padding(isUser || isSystem ? .init(top: 10, leading: 14, bottom: 10, trailing: 14)
                                        : .init(top: 2, leading: 0, bottom: 2, trailing: 0))
            .background(bubbleBackground)
            .clipShape(RoundedRectangle(cornerRadius: isUser ? VTheme.Radius.l : VTheme.Radius.m))
            .overlay {
                if isUser || isSystem {
                    RoundedRectangle(cornerRadius: isUser ? VTheme.Radius.l : VTheme.Radius.m)
                        .stroke(isSystem ? VTheme.okBorder : VTheme.borderDefault)
                }
            }
            // 气泡最大宽对齐原版 maxWidth:'78%'（ChatPanel.tsx:2841）×消息列 820 ≈ 640
            .frame(maxWidth: 640, alignment: isUser ? .trailing : .leading)

            errorBlock
            waitingBanner
            stoppedNote
            interruptedNote
            visionRescue
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private var bubbleBackground: Color {
        isUser ? VTheme.bgCard : isSystem ? VTheme.okBg : Color.clear
    }

    // 图片附件（pending_images 与 DB images 归一；0.1.71）
    @ViewBuilder
    private var imagesBlock: some View {
        if !message.images.isEmpty {
            HStack(spacing: 4) {
                ForEach(Array(message.images.enumerated()), id: \.offset) { _, uri in
                    if let data = Data(base64Encoded: String(uri.split(separator: ",").last ?? "")),
                       let img = NSImage(data: data) {
                        Image(nsImage: img)
                            .resizable().scaledToFit()
                            .frame(maxWidth: 150, maxHeight: 150)
                            .clipShape(RoundedRectangle(cornerRadius: VTheme.Radius.s))
                            .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.s).stroke(VTheme.borderDefault))
                    }
                }
            }
        }
    }

    // 思考指示（阶段化：脉动点 + 「思考中… Ns」+ 单行钳制预览悬浮看全文，0.4.33 F3 纪律）
    @ViewBuilder
    private var thinkingBlock: some View {
        if message.role == "assistant" && message.thinkingActive {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Circle().fill(VTheme.accent).frame(width: 6, height: 6)
                    Text("思考中… \(message.thinkingElapsed.map { "\($0)s" } ?? "")")
                        .font(VTheme.Typo.caption)
                }
                .foregroundStyle(VTheme.accentText)
                if !message.thinkingPreview.isEmpty {
                    Text(message.thinkingPreview)
                        .font(VTheme.Typo.micro)
                        .foregroundStyle(VTheme.textTertiary)
                        .lineLimit(1)          // F3：单行钳制，防 1↔2 行跳动抖动
                        .truncationMode(.tail)
                        .padding(.leading, 13)
                        .help(message.thinkingPreview)   // 悬浮看全文
                }
            }
        }
        if message.role == "assistant" && !message.thinkingActive {
            HStack(spacing: 8) {
                if let d = message.thinkingDuration, d > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "clock").font(.system(size: 10))
                        Text("思考 \(d)s")
                    }
                }
                // B12：整轮进行计时（思考已结束但任务仍在进行的空白区间）
                // F5（0.7.12 实测修复）：首 token 未到（正文仍空）即追加
                // 「预计还需约 Xs」——chip 第 1 秒可见，不再等 ≥8s 横幅
                if isStreamingThis, let r = message.runElapsed, r > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "clock").font(.system(size: 10))
                        Text("进行中 \(r)s"
                             + ChatWaitStage.chipSuffix(estimate: vm.waitEstimate,
                                                        waitedSeconds: r,
                                                        contentEmpty: message.content.isEmpty))
                    }
                }
                if let d = message.completedDuration, d > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle").font(.system(size: 10))
                        Text("完成 \(d)s")
                    }
                }
            }
            .font(VTheme.Typo.micro)
            .foregroundStyle(VTheme.textTertiary)
        }
    }

    // 工具步骤组（B4 折叠：运行中展开、全部终结收拢为一行摘要；失败数警示色）
    @ViewBuilder
    private var toolStepsBlock: some View {
        if !message.toolSteps.isEmpty {
            ToolStepsGroupView(steps: message.toolSteps, done: !isStreamingThis)
        }
    }

    // 正文（user 纯文本 pre-wrap / assistant Markdown 流式；流式中打字机光标）
    @ViewBuilder
    private var contentBlock: some View {
        if !message.content.isEmpty || isStreamingThis {
            HStack(alignment: .bottom, spacing: 0) {
                if isUser {
                    Text(message.content)
                        .font(VTheme.Typo.msgBody)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ChatMarkdownView(text: message.content)
                }
                if message.role == "assistant" && isStreamingThis {
                    Text(" ▍")
                        .font(VTheme.Typo.msgBody)
                        .foregroundStyle(VTheme.textTertiary)
                }
            }
            .accessibilityIdentifier("assistantContent")
        }
    }

    // M1-4：state 计数（步骤 x/max · 已用 N tokens）
    @ViewBuilder
    private var stepsCounter: some View {
        if message.role == "assistant",
           message.tokensUsed != nil || (message.step ?? 0) > 0 {
            Text("步骤 \(message.step ?? 0)/\(message.maxStep ?? vm.maxToolRounds) · 已用 \(message.tokensUsed ?? 0) tokens")
                .font(VTheme.Typo.micro)
                .foregroundStyle(VTheme.textTertiary)
        }
    }

    // 错误块（红色块 + 报错分析 + 已完成部分提示 + 重发/复制 + 模型降级卡）
    @ViewBuilder
    private var errorBlock: some View {
        if message.role == "assistant", let err = message.streamError {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(err)
                        .font(VTheme.Typo.caption)
                        .textSelection(.enabled)
                }
                if let analysis = message.errorAnalysis {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("报错分析\(message.errorAnalysisModel.map { "（\($0)）" } ?? "")")
                            .font(VTheme.Typo.micro).foregroundStyle(VTheme.textTertiary)
                        Text(analysis)
                            .font(VTheme.Typo.caption).foregroundStyle(VTheme.textSecondary)
                            .textSelection(.enabled)
                    }
                    .padding(8)
                    .background(VTheme.bgSidebar, in: RoundedRectangle(cornerRadius: VTheme.Radius.s))
                    .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.s).stroke(VTheme.borderDefault))
                }
                HStack(spacing: 8) {
                    Text("已完成部分见上方").font(VTheme.Typo.caption).foregroundStyle(VTheme.dangerText)
                    Button { vm.resendLast() } label: {
                        Label("重新发送", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.vSecondary).controlSize(.small)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(err, forType: .string)
                    } label: {
                        Label("复制错误详情", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.vGhost).controlSize(.small)
                }
                // M5：模型降级引导（「模型不存在」类错误）
                if RescueRules.isModelMissingError(err) {
                    ModelRescueBarView(vm: vm, currentModel: message.modelUsed ?? vm.selectedModel ?? "")
                }
            }
            .foregroundStyle(VTheme.dangerText)
            .padding(10)
            .frame(maxWidth: 560, alignment: .leading)
            .background(VTheme.dangerBg, in: RoundedRectangle(cornerRadius: VTheme.Radius.m))
            .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.m).stroke(VTheme.dangerBorder))
        }
    }

    // M5：长加载横幅（发送后 ≥8s 无正文）
    // W10（0.7.4，REQ-FUT-003）：阶段文案随真实信号切换（装载/装填 → 生成）+
    // 首 token 均值预估「预计还需约 Xs」（有样本且剩余>0 才显示，绝不编造）
    @ViewBuilder
    private var waitingBanner: some View {
        if message.role == "assistant" && message.streamError == nil
            && message.content.isEmpty && message.waitingSeconds >= 8 {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(vm.waitStage.bannerText(waitedSeconds: message.waitingSeconds)
                     + ChatWaitStage.estimateSuffix(estimate: vm.waitEstimate,
                                                    waitedSeconds: message.waitingSeconds))
                    .font(VTheme.Typo.caption)
            }
            .foregroundStyle(VTheme.accentTextDeep)
            .padding(8)
            .frame(maxWidth: 560, alignment: .leading)
            .background(VTheme.accentBgSoft, in: RoundedRectangle(cornerRadius: VTheme.Radius.m))
            .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.m).stroke(VTheme.accentBorder))
        }
    }

    // C6：仅用户手动停止显示
    @ViewBuilder
    private var stoppedNote: some View {
        if message.role == "assistant" && message.manuallyStopped {
            HStack(spacing: 8) {
                Image(systemName: "stop.circle").foregroundStyle(VTheme.textTertiary)
                Text("已手动停止").font(VTheme.Typo.caption).foregroundStyle(VTheme.textTertiary)
                Button { vm.resendLast() } label: {
                    Label("重新发送", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.vSecondary).controlSize(.small)
            }
        }
    }

    // #13：异常中断半成品标记（与「已手动停止」互斥）
    // R1（0.7.12 实测 A5）：挂「重新发送」出口（回填上一条 user 消息进输入框，
    // 与 stoppedNote 同一语义）——强退后悬空轮次不再只给一句死话。
    @ViewBuilder
    private var interruptedNote: some View {
        if message.role == "assistant" && !message.manuallyStopped,
           let note = message.interruptedNote {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(VTheme.textTertiary)
                Text(note).font(VTheme.Typo.caption).foregroundStyle(VTheme.textTertiary)
                Button { vm.resendLast() } label: {
                    Label("重新发送", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.vSecondary).controlSize(.small)
            }
        }
    }

    // M6：视觉引导卡（正文命中多模态降级文案）
    @ViewBuilder
    private var visionRescue: some View {
        if message.role == "assistant",
           message.content.contains(RescueRules.visionDegradedMark) {
            VisionRescueCardView(vm: vm, currentModel: message.modelUsed ?? vm.selectedModel ?? "")
        }
    }
}

// MARK: - 工具步骤组（B4/C8/checkpoint-060/A12 时间线样式）

private struct ToolStepsGroupView: View {
    let steps: [ToolStep]
    let done: Bool
    @State private var userToggled = false
    @State private var open = false

    private var shouldCollapse: Bool { ToolStepsCopy.shouldCollapse(steps: steps, streamDone: done) }
    private var collapsed: Bool { shouldCollapse && !open }
    private var failed: Int { steps.filter { $0.status == .error }.count }

    // W9（0.7.4）：收拢/展开 210ms 高度动画（壳应用 .21s 等效；偏差④核销）。
    // DBG-151/153 教训：动画闭包内只翻 Bool 状态，不做重活（测量/滚动不受影响）。
    private static let toggleAnimation = Animation.easeInOut(duration: 0.21)

    var body: some View {
        if collapsed {
            // 收拢态：整组一行，点击展开
            Button {
                withAnimation(Self.toggleAnimation) {
                    userToggled = true
                    open = true
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: failed > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(failed > 0 ? VTheme.warnText : VTheme.ok)
                    Text(ToolStepsCopy.groupLabel(steps: steps, collapsed: true))
                        .font(VTheme.Typo.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10))
                        .foregroundStyle(VTheme.textTertiary)
                }
                .padding(.horizontal, 10).frame(height: 28)
                .background(failed > 0 ? VTheme.warnBg : VTheme.bgHover,
                            in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .stroke(failed > 0 ? VTheme.warnBorder : VTheme.borderSubtle))
                .foregroundStyle(failed > 0 ? VTheme.warnText : VTheme.textSecondary)
            }
            .buttonStyle(.plain)
            .help(ToolStepsCopy.groupLabel(steps: steps, collapsed: true))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if steps.count > 1 {
                    // 展开态组头（可点收起）
                    Button {
                        withAnimation(Self.toggleAnimation) {
                            userToggled = true
                            open = false
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "square.stack").font(.system(size: 10))
                            Text(ToolStepsCopy.groupLabel(steps: steps, collapsed: false))
                                .font(VTheme.Typo.micro)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.up").font(.system(size: 10))
                        }
                        .foregroundStyle(VTheme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
                ForEach(steps) { step in
                    ToolStepRow(step: step)
                }
            }
            .onAppear {
                // 状态跃迁同步一次：运行中展开、完成后收拢；用户点过就不再自动改
                if !userToggled { open = !shouldCollapse }
            }
            .onChange(of: shouldCollapse) { _, now in
                // W9：状态跃迁（运行完自动收拢）同走 210ms 动画
                if !userToggled {
                    withAnimation(Self.toggleAnimation) { open = !now }
                }
            }
        }
    }
}

/// 单条工具步骤（checkpoint-060：单行省略号截断；摘要在展开区，信息不丢）
private struct ToolStepRow: View {
    let step: ToolStep
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { open.toggle() } label: {
                HStack(spacing: 7) {
                    statusIcon
                    Text(ToolStepsCopy.stepLabel(step))
                        .font(VTheme.Typo.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundStyle(VTheme.textTertiary)
                }
                .padding(.horizontal, 10).frame(height: 30)
                .foregroundStyle(VTheme.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(ToolStepsCopy.stepLabel(step))
            if open {
                VStack(alignment: .leading, spacing: 6) {
                    if let detail = step.status == .error ? (step.error ?? "unknown") : step.summary {
                        Text(detail)
                            .font(VTheme.Typo.micro)
                            .foregroundStyle(step.status == .error ? VTheme.dangerText : VTheme.textSecondary)
                            .textSelection(.enabled)
                    }
                    if let args = step.argsText {
                        ScrollView {
                            Text(args)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(VTheme.textSecondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 160)
                        .padding(8)
                        .background(VTheme.bgHover, in: RoundedRectangle(cornerRadius: VTheme.Radius.s))
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 10)
            }
        }
        .overlay(alignment: .leading) {
            // A12 时间线：左侧 2px 竖线
            Rectangle().fill(VTheme.borderDefault).frame(width: 2)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch step.status {
        case .running:
            ProgressView().controlSize(.mini)
        case .ok:
            Image(systemName: "checkmark").font(.system(size: 11)).foregroundStyle(VTheme.ok)
        case .interrupted:
            // C2：中性 stop 图标，不谎称成功也不谎报失败
            Image(systemName: "stop.circle").font(.system(size: 11)).foregroundStyle(VTheme.textTertiary)
        case .error:
            Image(systemName: "xmark").font(.system(size: 11)).foregroundStyle(VTheme.danger)
        }
    }
}

// MARK: - M5 模型降级引导卡（现状 ModelRescueBar）

private struct ModelRescueBarView: View {
    @ObservedObject var vm: ChatViewModel
    let currentModel: String
    @State private var busy = false
    @State private var info: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver")
                Text("模型「\(currentModel)」不可用，可选：")
                    .font(VTheme.Typo.caption.weight(.medium))
            }
            HStack(spacing: 8) {
                let candidates = vm.models.filter { $0.name != currentModel }
                Picker("一键切换到…", selection: Binding(
                    get: { "" },
                    set: { name in
                        guard !name.isEmpty, !busy else { return }
                        busy = true
                        info = nil
                        Task {
                            do {
                                try await vm.switchModel(to: name)
                                info = "已切换到 \(name)，正在重新发送…"
                                try? await Task.sleep(nanoseconds: 400_000_000)
                                vm.resendLast()
                            } catch {
                                info = "切换失败: \(SidecarError.describe(error))"
                            }
                            busy = false
                        }
                    }
                )) {
                    Text(candidates.isEmpty ? "（无其他本地模型）" : "一键切换到…").tag("")
                    ForEach(candidates, id: \.name) { Text($0.name).tag($0.name) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 160)
                .disabled(busy || candidates.isEmpty)

                Button {
                    guard !busy else { return }
                    busy = true
                    info = "正在拉取 \(currentModel) …（首次拉取可能较久）"
                    Task {
                        do {
                            try await vm.pullModel(currentModel)
                            info = "拉取完成：\(currentModel)。请点击\"重新发送\"。"
                        } catch {
                            info = "拉取失败: \(SidecarError.describe(error))"
                        }
                        busy = false
                    }
                } label: {
                    Text(busy ? "拉取中…" : "重新拉取 \(currentModel)")
                }
                .buttonStyle(.vSecondary).controlSize(.small)
                .disabled(busy)
            }
            if let info {
                Text(info).font(VTheme.Typo.micro)
            }
        }
        .padding(8)
        .background(VTheme.warnBg, in: RoundedRectangle(cornerRadius: VTheme.Radius.s))
        .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.s).stroke(VTheme.warnBorder))
        .foregroundStyle(VTheme.warnText)
    }
}

// MARK: - M6 视觉引导卡（现状 VisionRescueCard）

private struct VisionRescueCardView: View {
    @ObservedObject var vm: ChatViewModel
    let currentModel: String
    @State private var busy = false
    @State private var info: String?
    @State private var dismissed = false

    var body: some View {
        if !dismissed {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "photo")
                    Text("当前模型不支持图片分析。可选：")
                        .font(VTheme.Typo.caption.weight(.medium))
                }
                HStack(spacing: 8) {
                    let candidates = vm.models.filter {
                        $0.name != currentModel && RescueRules.isVisionModel($0.name)
                    }
                    Picker("切换视觉模型…", selection: Binding(
                        get: { "" },
                        set: { name in
                            guard !name.isEmpty, !busy else { return }
                            busy = true
                            info = nil
                            Task {
                                do {
                                    try await vm.switchModel(to: name)
                                    info = "已切换到 \(name)，正在重新发送…"
                                    try? await Task.sleep(nanoseconds: 400_000_000)
                                    vm.resendLast()
                                } catch {
                                    info = "切换失败: \(SidecarError.describe(error))"
                                }
                                busy = false
                            }
                        }
                    )) {
                        Text(candidates.isEmpty ? "（无可用视觉模型）" : "切换视觉模型…").tag("")
                        ForEach(candidates, id: \.name) { Text($0.name).tag($0.name) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 160)
                    .disabled(busy || candidates.isEmpty)

                    if vm.inferenceBackend == "ollama" {
                        Button {
                            guard !busy else { return }
                            busy = true
                            info = "正在拉取 qwen2.5-vl …（首次拉取可能较久）"
                            Task {
                                do {
                                    try await vm.pullModel("qwen2.5-vl")
                                    info = "拉取完成：qwen2.5-vl。请从上方下拉框切换后自动重发，或点\"重新发送\"。"
                                } catch {
                                    info = "拉取失败: \(SidecarError.describe(error))"
                                }
                                busy = false
                            }
                        } label: {
                            Text(busy ? "拉取中…" : "一键拉取 qwen2.5-vl")
                        }
                        .buttonStyle(.vPrimary).controlSize(.small)
                        .disabled(busy)
                    }
                    Button("知道了") { dismissed = true }
                        .buttonStyle(.vGhost).controlSize(.small)
                }
                if let info {
                    Text(info).font(VTheme.Typo.micro)
                }
            }
            .padding(8)
            .frame(maxWidth: 560, alignment: .leading)
            .background(VTheme.okBg, in: RoundedRectangle(cornerRadius: VTheme.Radius.s))
            .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.s).stroke(VTheme.okBorder))
            .foregroundStyle(VTheme.okText)
        }
    }
}
