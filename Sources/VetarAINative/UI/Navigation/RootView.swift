//
//  RootView.swift
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

//  应用骨架（对标现状布局，App.tsx + ModuleNav.tsx）：
//    ┌────────┬──────────────┬────────────────────────────┐
//    │ 模块竖条 │ 面板侧栏      │ 内容区                      │
//    │  52pt  │ 固定 260      │ （常驻聊天主页 / 已挂实现）    │
//    │        │ （0.5.2 B2） │                            │
//    └────────┴──────────────┴────────────────────────────┘
//  · V4（设置整页覆盖复刻）：一级模块竖条 = 智能中心 / 流程中心 + 底部「设置」齿轮
//    （ModuleNav.tsx:44-47/104-115，宽 52 :86）；「系统」组整体移除——低频模块收进
//    设置覆盖页内部导航（SettingsPageView）。点齿轮 → 覆盖层盖住（侧栏+内容区），
//    rail 保留；下层组件保活不卸载（对齐 App.tsx:370 注释：对话/圆桌/工作流
//    均保活不销毁，仅显示切换）；关闭回来源处（用户拍板，优于原版强制切回智能中心）
//  · V1（智能中心侧栏单栏堆叠复刻）：智能中心侧栏 = IntelligenceSidebarView
//    （独立 Agent 手风琴 + 项目区 + 项目内 Agent 区 + 栏底任务队列/圆桌手风琴，
//    对齐 App.tsx:233-290），不再是面板列表；宽度 0.5.2 B2 起固定 260（原版
//    clamp(260px, 24vw, 320px) 弹性是浏览器行为，SwiftUI 每帧重排不免费——
//    有意偏差见 sidebarWidth 注），窗口超载时保持侧栏宽度、压内容区（U1 口径保留）
//  · 智能中心内容区 = chatHome 常驻 + 圆桌详情大屏（打开时覆盖、聊天保活，
//    对齐 App.tsx:320-328/344-358）；圆桌 VM 共享于 IntelligenceCenterState
//  · U3：知识仓库窄栏嵌回聊天右端（ChatDetailView 内，原版 ChatPanel.tsx:3152 同构）
//  · V3：内容区 minWidth:0 + clipped（App.tsx:299）——固定列永不被内容顶出窗
//  · R3（0.5.1）+ B1a（0.5.2）：双侧栏窄宽自动折叠（SidebarCollapsePolicy：
//    920/1080 滞回带——<920 自动隐藏、>1080 复位、带内保持来向、把手手动唤出）
//    + 宽 0↔260 滑出动画（cubic-bezier(.2,.8,.3,1) .26s），
//    侧栏全程不卸载保活；把手在内容区左缘垂直居中（26×46 圆角右半钮，
//    chevron 双向）——口径对齐 App.tsx:58-73/215-230/300-318
//  · 顶层 overlay：全局授权弹窗 + 通用弹窗 + Toast + 崩溃提示
//

import SwiftUI

public struct RootView: View {
    @EnvironmentObject private var appState: AppState
    /// 智能中心共享态（圆桌 VM 单例：侧栏手风琴 + 内容区大屏共用）
    @StateObject private var intelCenter = IntelligenceCenterState()
    /// 流程中心共享态（工作流/CU 宏 VM 单例：侧栏手风琴 + 内容区面板共用）
    @StateObject private var workflowCenter = WorkflowCenterState()
    /// 0.5.1 R3 + 0.5.2 B1a：侧栏折叠——autoHidden 带外（<920 恒隐 / >1080 恒显）
    /// 由几何实时推导（不吃回调时序，见下），920~1080 滞回带内保持来向
    /// （@State 记忆，resolve 纯函数）；pinned（0.4.x sidebarPinned 手动唤出）
    /// 持 @State；shown = !autoHidden || pinned。
    /// 冒烟实证教训：@State+onAppear/onChange 喂窗口宽在「启动即窄窗」（frameAutosave
    /// 恢复与视图树安装竞态）下会漏首次宽度事件，三态机卡在初始 shown=true——
    /// 故带外仍由 body 内 geo.size.width 直接推导（SidebarCollapsePolicy.resolve
    /// 纯函数，仍是可测规格本体）；带内记忆每帧由几何驱动、随 autoHidden 翻牌
    /// 回写，竞态面归零。pinned 放宽复位走 onChange（漏事件最坏仅 pinned 不清零，
    /// shown 仍由实时 autoHidden 兜底，不错版）。
    @State private var sidebarPinned = false
    /// B1a 滞回带记忆（仅 920~1080 内生效；nil = 首帧。0.5.2 W7 首帧口径
    /// 对齐 0.4.x：≥920 展开、<920 恒折叠保 DBG-151——resolve nil 分支 =
    /// width < collapseLine；窗 minWidth 800 低于折叠线，折叠拖拽可达）。
    @State private var sidebarAutoHiddenMemory: Bool?

    public var body: some View {
        // W1（0.6/0.7 联动）：横幅区（离线 auth-09 / 试用中 auth-06）+ 首次启动强制登录门
        //（拍板①：未登录唯一入口 = AuthFlowView，主界面不挂载；登录后翻牌进主界面）
        // v1.4（0.7.2）：首启协议门挂在登录门**之前**——本地无 launch 同意记录时
        // 全屏协议，同意前不得进任何功能含登录（任务书 B1 / 验收标准 6）；
        // 门判定纯本地（AgreementCenter.boot），断网同样生效。
        VStack(spacing: 0) {
            if !appState.network.isOnline {
                OfflineBannerView()
            }
            if case .trialActive(let days) = appState.license.status {
                TrialBannerView(daysRemaining: days) { appState.showActivation = true }
            }
            // v1.11（契约）：真强制更新阻断页——最高优先级整页分支（协议门/登录门
            // 之前），无法关闭/无法进入任何功能；判定纯本地（缓存版本比较），断网
            // 同样阻断；426 拦截已登录会话时 isBlocked 翻转，本分支当场接管。
            if appState.mandatoryUpdate.isBlocked {
                MandatoryUpdateGateView(gate: appState.mandatoryUpdate,
                                        update: appState.update)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appState.agreement.launchGateRequired {
                LaunchAgreementGateView(center: appState.agreement,
                                        appConfig: appState.appConfig)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appState.license.status == .loggedOut {
                AuthFlowView(license: appState.license)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
        GeometryReader { geo in
            let sideWidth = Self.sidebarWidth(for: geo.size.width)
            // 0.5.2 W7③：布局未就绪守门——视图树安装首帧 geo 可能为 0/极小
            // （frameAutosave 恢复与视图树安装竞态，DBG-151 同族）：0 < 920
            // 经 resolve 恒折叠，onChange 把滞回记忆污染成「来向窄」，随后
            // autosave 恢复 960 落带内保持折叠（启动 960 侧栏不收起的实测
            // 回归）。<400 远低于窗 minWidth 800、不可能是真实窗口宽：按
            // 展开处理（0.4.x 无 0 宽概念，默认显示），且不回写记忆；稳定
            // 后的真实宽度帧再决定折叠（800 窗启动：0 帧守门展开 → 800 帧
            // <920 恒折叠并回写，DBG-151「启动即窄窗恒折叠」口径不丢）。
            let layoutReady = geo.size.width >= 400
            let sidebarAutoHidden = layoutReady
                ? SidebarCollapsePolicy.resolve(
                    width: geo.size.width, previous: sidebarAutoHiddenMemory)
                : false
            let sidebarShown = !sidebarAutoHidden || sidebarPinned
            HStack(spacing: 0) {
                // P0 红线（0.7.1 勘误，业主拍板 2026-09-22）：模块竖条无条件常驻——
                // 工作室态也不隐藏（studio/spec §1「模块竖条始终在、画布从竖条右缘起」），
                // 进出工作室随时可切回智能中心/流程中心。隐藏侧栏的只是面板侧栏壳
                // （下方 studioFullscreen 分支），竖条不在其列。
                ModuleRailView()
                ZStack {
                    HStack(spacing: 0) {
                        // R3：侧栏壳——宽 0↔260 动画（0.4.x App.tsx:300-318
                        // width .26s cubic-bezier(.2,.8,.3,1) 同构）；内壳固定宽 +
                        // 滑出偏移 + 透明度（滑出非压变形）；PanelSidebarView 全程不卸载保活
                        // （0.4.x 注释：侧栏收起不销毁，手风琴展开态/滚动位保留）
                        // W3：工作室为应用内全屏模块（总体规划 §一「进入模块即应用内
                        // 全屏状态」）——无面板侧栏，壳宽恒 0 不挂载。
                        let studioFullscreen = appState.selectedModule == .studio
                        HStack(spacing: 0) {
                            PanelSidebarView(width: sideWidth)
                            Divider()
                        }
                        .offset(x: sidebarShown ? 0 : -28)
                        .opacity(sidebarShown ? 1 : 0)
                        .frame(width: sidebarShown && !studioFullscreen ? sideWidth : 0, alignment: .leading)
                        .clipped()
                        contentView
                            // V3：内容区可压到近 0、越界裁切（对齐 App.tsx:299
                            // `minWidth:0 + overflow:hidden`）——固定列（rail/侧栏）
                            // 永不被内容顶出窗
                            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                            // R3：边缘把手（0.4.x App.tsx:58-73：内容区左缘 top:50%、
                            // 26×46 圆角右半钮、chevron-right 展开 / chevron-left 收起、
                            // zIndex 900、ui-pop-in .18s）——仅窄窗自动隐藏时出现，
                            // 设置覆盖页打开时不悬在设置页上
                            .overlay(alignment: .leading) {
                                if sidebarAutoHidden && !appState.showSettings && !studioFullscreen {
                                    Button {
                                        sidebarPinned.toggle()
                                    } label: {
                                        Image(systemName: sidebarPinned
                                              ? "chevron.left" : "chevron.right")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(VTheme.textSecondary)
                                            .frame(width: 26, height: 46)
                                            .background(VTheme.bgCard, in:
                                                UnevenRoundedRectangle(
                                                    topLeadingRadius: 0, bottomLeadingRadius: 0,
                                                    bottomTrailingRadius: 12, topTrailingRadius: 12))
                                            .overlay(alignment: .trailing) {
                                                UnevenRoundedRectangle(
                                                    topLeadingRadius: 0, bottomLeadingRadius: 0,
                                                    bottomTrailingRadius: 12, topTrailingRadius: 12)
                                                    .stroke(VTheme.borderSubtle, lineWidth: 1)
                                                    .frame(width: 26, height: 46)
                                            }
                                            .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
                                    }
                                    .buttonStyle(.plain)
                                    .help(sidebarPinned ? "收起侧栏" : "展开侧栏")
                                    .accessibilityIdentifier("sidebarEdgeHandle")
                                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                                    .zIndex(900)
                                }
                            }
                    }
                    // R3：折叠/展开双相动画（0.4.x width .26s cubic-bezier(.2,.8,.3,1)）
                    .animation(.timingCurve(0.2, 0.8, 0.3, 1, duration: 0.26),
                               value: sidebarShown)
                    .animation(.easeInOut(duration: 0.18), value: sidebarAutoHidden)
                    // V4：设置整页覆盖（App.tsx:371-381）——盖住侧栏+内容区（rail 保留）。
                    // 下层留在视图树中保活（聊天流式/工作流运行不中断）；
                    // 关闭 = 移除覆盖层，直接落回来源处
                    if appState.showSettings {
                        SettingsPageView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(VTheme.bgApp)
                            .transition(.opacity)
                        // DBG-160：容器不挂 id（覆盖层内有全部 settings.* 叶子 id）
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            }
            // R3+B1a：放宽复位 pinned 归零（0.4.x 同口径：宽窗无钉住概念）+
            // 滞回记忆回写（带内保持的来向随翻牌更新）。带外 autoHidden 由 body
            // 内几何实时推导（根治启动即窄窗时 frameAutosave 恢复与视图树安装
            // 竞态漏首次宽度事件——冒烟实证），此处只做收尾清理与记忆同步。
            .onChange(of: sidebarAutoHidden) { _, hidden in
                sidebarAutoHiddenMemory = hidden
                if !hidden { sidebarPinned = false }
            }
        }
            }
        }
        .background(VTheme.bgApp)
        .environmentObject(intelCenter)
        .environmentObject(workflowCenter)
        // ── 顶层 overlay（全局设施，面板无需自挂）──
        // 0.7.4 收口：8 层独立 .overlay 链超出 Swift 前端类型推导合理时限（编译超时），
        // 合并为单一 overlay + ViewBuilder 提取（视觉层级按声明序不变，后者居上）。
        .overlay { globalOverlays }
        // 账号级协议门（方案B 2026-09-28）：换账号登录后服务端说该账号未同意 →
        // 门重开。globalOverlays 画在门所在分支之上（激活卡/付费引导/试用冻结/
        // 必备模型弹窗不收会盖住门，VetarModel DBG-0043 同族教训）——门开即收，
        // 用户先在门上重签，再自行回到原入口继续。窗口内 sheet 无需处理：
        // 本仓门是整页分支替换（非 overlay），门开时主界面分支（含 ChatPanelView
        // 的 transfer sheet）不挂载，sheet 随宿主卸载自动收。
        .onChange(of: appState.agreement.launchGateRequired) { _, required in
            if required {
                appState.showActivation = false
                appState.showPaywall = false
                appState.showTrialExpired = false
                appState.showRequiredModelsPrompt = false
                // 协议门加固（2026-09-30）真因：showAuth 登录弹窗也是
                // globalOverlays 一员，漏收同样盖门；与下方强制更新门
                // （:218 起，已收 showAuth）两处口径对齐。
                appState.showAuth = false
            }
        }
        // v1.11：强制更新阻断页接管时收拢一切全局 overlay（globalOverlays 画在
        // 整页分支之上——激活卡/付费引导/登录弹窗不收会盖住阻断页，与协议门
        // 同族教训）；更新窗口由 Sparkle 原生呈现，不在收拢之列。
        .onChange(of: appState.mandatoryUpdate.isBlocked) { _, blocked in
            if blocked {
                appState.showActivation = false
                appState.showPaywall = false
                appState.showTrialExpired = false
                appState.showRequiredModelsPrompt = false
                appState.showAuth = false
                appState.closeSettings()
            }
        }
        .onChange(of: appState.license.status) { _, _ in
            appState.maybePromptRequiredModels()
        }
        // S2-② 2026-09-30：等值登录场景（certLocked(X)→certLocked(X)）status onChange
        // 被 Equatable 门吞掉、必备模型弹窗不触发——同源补一路 authRevision 事件通道。
        .onChange(of: appState.license.authRevision) { _, _ in
            appState.maybePromptRequiredModels()
        }
        // ── W1.5 恢复激活确认框（约定书 §2.8 红线：账号已付费+本机无有效证书时
        // 登录后自动探提案；⛔ 用户确认前绝不调领证端点——名额防误占）──
        .onChange(of: appState.license.restoreOffer) { _, offer in
            guard let offer else { return }
            Task {
                await Self.runRestoreFlow(license: appState.license, offer: offer,
                                          onRenew: { appState.showActivation = true })
            }
        }
        // P3-W6：侧车崩溃提示（crashNotice → Toast）随进程职责归零删除——
        // 原生内核是进程内对象，无「意外退出」可报。
        .background(WindowConfigurator())
        // W8（0.7.4）：窗口关闭 busy 确认闸（关闭按钮 / Cmd+W；NSAlert 模态）
        .background(WindowCloseGuard(busyGuard: appState.busyGuard))
        // W1：License 启动判定（证书→试用→token 判序）+ 网络监测；试用到期即时弹冻结窗
        .task {
            appState.license.boot()
            appState.network.start()
            // v1.11：强制更新闸门——本地判定先行（断网也阻断），随后联网刷新
            // 强制线缓存（误标取消自愈通道；失败静默保持本地判定）
            appState.mandatoryUpdate.boot()
            Task { await appState.mandatoryUpdate.refresh() }
            // v1.4：协议本地判定（门开闭）+ 启动联网核对（补报 + needReConsent）
            appState.agreement.boot()
            appState.syncAgreementIfPossible()
            // v1.4：日级静默自动检查更新（每天仅第一次打开且联网已登录时一次）
            appState.maybeAutoCheckUpdate()
            // v1.8：页面链接预取（§2.14；缓存 5 分钟，失败静默用静态兜底）
            appState.prefetchAppConfigIfNeeded()
            if case .trialExpired = appState.license.status {
                appState.showTrialExpired = true
            }
            // W10：已登录态启动直探必备模型（登录翻转路径由上方 onChange 覆盖）
            appState.maybePromptRequiredModels()
        }
        .task { intelCenter.attach(appState: appState) }
        .task { workflowCenter.attach(appState: appState) }
        // 调试：--debug-auth-mock 或 VETARAI_DEBUG_AUTH_MOCK=1 → 起窗后自动弹一条 mock 授权
        .task {
            if AuthCenter.debugMockEnabled {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                appState.auth.presentMock()
            }
        }
    }

    /// 全局 overlay 聚合（0.7.4 收口）：原 8 层独立 .overlay 链致 Swift 前端类型推导
    /// 超时；合并为单一 overlay，子视图按声明序叠放（后者居上），视觉层级不变。
    /// 层级序：授权对话 → 通用对话 → Toast → 激活 → 付费引导 → 试用到期 → 更新 → 必备模型。
    @ViewBuilder private var globalOverlays: some View {
        AuthDialogHostView(auth: appState.auth)
        DialogHostView(center: .shared)
        ToastHostView(center: .shared)
        // W1 注册授权（auth-03/04 激活、auth-05 付费引导、auth-07 到期冻结）
        if appState.showActivation {
            ActivationView(license: appState.license, agreement: appState.agreement)
        }
        // 0.7.7 登出态 UI 簇：certLocked 主界面仍挂载，账号页/付费门的「登录账号」
        // 走本通道唤出登录页（可关闭模式；登录成功 AuthFlowView 内自关）
        if appState.showAuth {
            AuthFlowView(license: appState.license, onClose: { appState.showAuth = false })
        }
        if appState.showPaywall {
            PaywallDialogView(onClose: { appState.showPaywall = false })
        }
        if appState.showTrialExpired {
            TrialExpiredDialog(
                onActivate: {
                    appState.showTrialExpired = false
                    appState.showActivation = true
                },
                onReadonly: { appState.showTrialExpired = false })
        }
        // 0.7.9 起更新弹窗由 Sparkle 原生呈现（契约 v1.10 §2.15；
        // 旧 UpdateDialogView 自研链已退役删除，此处不再挂 overlay）
        // W10 必备模型首装弹窗（REQ-FUT-015 / ADR-0051）：登录后 + 未提示过
        // + 任一未就绪 → 弹；「以后再说」置标记不骚扰，模型包面板可手动下
        if appState.showRequiredModelsPrompt {
            RequiredModelsPromptView()
        }
    }

    /// 侧栏宽固定 260（0.5.2 B2 有意偏差，登记：原版是 clamp(260px, 24vw, 320px)
    /// 弹性——App.tsx:218。24vw 弹性是浏览器行为：CSS 重算合成免费；SwiftUI
    /// 下窗口拖拽每帧按新宽重排整条侧栏视图树不免费（0.5.1 实测 resize 卡顿
    /// 来源之一）。固定 260 后 resize 期间侧栏零重排；弹性带宽让位内容区，
    /// 观感对齐原版 960~1083 窗宽段（230~260 → 恒取下限）。
    static func sidebarWidth(for windowWidth: CGFloat) -> CGFloat {
        260
    }

    /// W1.5 恢复激活确认流（约定书 §2.8 建议流程：status 探名额 → 确认框 →
    /// 用户明确同意才调 fetchCertificate）。确认=领证落盘翻激活；取消=清提案
    /// （账号页「恢复本机授权」入口可再发起）；失败=message 直展并清提案。
    /// v1.6 §2.8：SUBSCRIPTION_EXPIRED（订阅到期）与从未付费（无 code）分清——
    /// 到期弹「去续费」引导（开激活页输新码，续费后自动恢复），不再笼统报失败。
    static func runRestoreFlow(license: LicenseCenter,
                               offer: LicenseCenter.RestoreOffer,
                               onRenew: @MainActor @escaping () -> Void = {}) async {
        let ok = await DialogCenter.shared.confirm(
            title: offer.dialogTitle, message: offer.dialogMessage,
            confirmText: offer.dialogConfirmText, cancelText: "稍后再说")
        guard ok else { license.dismissRestoreOffer(); return }
        do {
            _ = try await license.restoreCertificate()
            await DialogCenter.shared.alert(
                title: "已恢复激活",
                message: "本机已恢复付费授权，工作室等付费模块已解锁。")
        } catch let e as LicenseAPIError where e.isSubscriptionExpired {
            // v1.6 §2.8：订阅已到期（无买断）——引导走 §2.3 续费（输新码），
            // message 用服务端原文（"订阅已到期，续费后自动恢复"）
            license.dismissRestoreOffer()
            let renew = await DialogCenter.shared.confirm(
                title: "订阅已到期",
                message: "\(e.message)\n在激活页输入新的激活码即可续费，续费后自动恢复。",
                confirmText: "去续费", cancelText: "稍后再说")
            if renew { onRenew() }
        } catch let e as LicenseAPIError {
            // 400 未付费引导激活码 / 403 名额满引导解绑 / 401 重新登录——message 直展
            await DialogCenter.shared.alert(title: "恢复失败", message: e.message)
            license.dismissRestoreOffer()
        } catch {
            await DialogCenter.shared.alert(title: "恢复失败", message: "请稍后重试")
            license.dismissRestoreOffer()
        }
    }

    /// 内容区分发：已挂实现的面板走实现，其余占位。
    /// 问题6收口：工作流只保留「workflows」一个入口——编辑器（右列）与画布（中列）
    /// 已内嵌于 WorkflowPanelView（W4 notes 建议方案），原 editor/canvas 注册位移除。
    /// V1 收口：智能中心五面板不再走面板分发——智能中心内容区 = chatHome 常驻 +
    /// 圆桌详情大屏（IntelligenceSidebarView 承担侧栏五块）。
    /// U3 收口：「仓库」不再走面板分发——WarehousePanelView 嵌在 ChatDetailView 右端。
    /// V4 收口：设置/知识记忆/推理后端/模型包/模型选项/插件/仓库管理/日志/诊断/关于
    /// 不再走面板分发——全部收进设置整页覆盖（SettingsPageView 内部导航）。
    @ViewBuilder
    private var contentView: some View {
        switch appState.selectedPanel.key {
        case "chat":
            intelligenceHome
        case "workflows":
            WorkflowPanelView()
        case "cu-macro":
            CuMacroPanelView()
        case "studio":
            // W3：超级工作室常驻主页；W8（REQ-FUT-012③）：新建/切换会话整实例
            // 重建——.id(sessionId) 保证 StateObject 随会话替换（旧引擎在切换前
            // 已按暂停红线收尾落盘）
            // W1（0.7.4）：画布库建库失败（磁盘极端异常）→ 优雅不可用占位，
            // 不 crash、用户数据不落临时目录（业主数据安全红线）
            // S1 根治（2026-09-30，业主实测「付费门关了就能白用工作室」）：
            // 门控此前只挂模块竖条按钮，运行期内授权态翻转（解绑/证书锁定/试用
            // 到期）时 selectedPanel 停在 studio，内容层零校验照常渲染可用。
            // 内容层补闸：gated 时整面置灰（业主红线：置灰不遮挡、可见内容）+
            // 透明拦截层，任何点击弹付费引导。执行层另有引擎硬校验双保险
            // （StudioEngine.studioGateCheck）。
            if let engine = appState.ensureStudioEngine() {
                StudioPanelView(engine: engine)
                    .id(engine.sessionId)
                    .paywallGated(LicenseGateLogic.studioGated(status: appState.license.status)) {
                        appState.showPaywall = true
                    }
            } else {
                StudioUnavailableView()
            }
        default:
            PlaceholderPanel(panel: appState.selectedPanel)
        }
    }

    /// 智能中心内容区（V1）：chatHome 常驻 + 圆桌详情大屏（打开时覆盖）。
    /// 已选上下文（项目 / ia- 命名空间）→ ChatPanelView；未选 → 引导空态
    /// （文案逐字对齐 App.tsx:329-343）。只选项目未选 Agent 也进聊天——
    /// ChatViewModel 落主 Agent/首个 Agent；项目无 Agent 则空态提示 +
    /// 输入禁用（0.7.6 实测 Bug1 新口径：不隐式创建，见 adoptContext）。
    /// 圆桌详情打开时覆盖其上（App.tsx:320-328 与对话互斥显示；对话保活不销毁
    /// :344-358——ZStack 中 ChatPanelView 不卸载，流式继续写入）。
    @ViewBuilder
    private var intelligenceHome: some View {
        ZStack {
            if appState.currentProjectId != nil {
                ChatPanelView()
            } else {
                VEmptyStateView(
                    icon: "message",
                    title: "开始对话",
                    message: "在左侧选择一个项目和 Agent，或点击顶部「独立 Agent」创建一个不属于任何项目的 Agent。")
            }
            if let rtVM = intelCenter.roundtableVM {
                RoundtableDetailHostView(vm: rtVM, runtime: appState.runtime)
            }
        }
    }
}

// MARK: - 一级模块竖条（对标 ModuleNav：52pt 图标 + 微标签，选中态左侧指示条）
//  V4：只留 智能中心/流程中心 两个模块图标 + 底部「设置」齿轮（ModuleNav.tsx:44-47
//  两模块 + :104-115 设置固定底部 marginTop:auto）；「系统」组移除。

struct ModuleRailView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 4) {
            ForEach(ModuleGroup.allCases) { group in
                // W3：工作室为付费门控模块——未激活且非试用中 → 纯置灰（不遮挡，
                // 业主红线 2026-09-26）+ 点击弹付费引导（auth-05，spec §3.5/总体规划 §六）；
                // 其余模块直通。门控判定纯逻辑见 LicenseGateLogic（W1 已测）。
                let gated = group == .studio
                    && LicenseGateLogic.studioGated(status: appState.license.status)
                ModuleRailButton(
                    group: group,
                    // 设置打开时模块图标不高亮（ModuleNav.tsx:96 !settingsActive）
                    isActive: !appState.showSettings && appState.selectedModule == group
                ) {
                    if gated {
                        appState.showPaywall = true
                        return
                    }
                    // W8（0.7.4）：busy 确认闸——工作流在跑/圆桌讨论进行中时
                    // 切走模块先弹 NSAlert 确认（防误关；空闲直通）
                    guard BusyGuardAlert.gate(appState.busyGuard, context: .switchAway) else { return }
                    // 切模块 → 落到该组上次/默认面板；设置打开时先关覆盖页
                    //（App.tsx:203 onSelect: setShowSettingsPage(false)）
                    appState.closeSettings()
                    if appState.selectedPanel.group != group {
                        appState.selectPanel(PanelRegistry.defaultPanel(in: group))
                    } else {
                        appState.selectedModule = group
                    }
                }
                .paywallGated(gated) { appState.showPaywall = true }
                .help(gated ? "工作室（未解锁）" : group.title)
            }
            Spacer()
            // V4：底部「设置」齿轮（ModuleNav.tsx:104-115 marginTop:auto + marginBottom:8）——
            // 开关设置整页覆盖，智能/流程两中心共用入口
            SettingsGearButton(isActive: appState.showSettings) {
                appState.toggleSettings()
            }
            .padding(.bottom, 8)
        }
        .padding(.top, 8)
        // V4：宽对齐原版 52（ModuleNav.tsx:86 width:52 + flexShrink:0）
        .frame(width: 52)
        // U1 防挤压（对齐 ModuleNav flexShrink:0）：超宽内容出现时拒绝被压窄
        .fixedSize(horizontal: true, vertical: false)
        .background(VTheme.bgCard)
        .overlay(alignment: .trailing) { Divider() }
    }
}

private struct ModuleRailButton: View {
    let group: ModuleGroup
    let isActive: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        RailButtonBody(icon: group.icon, title: group.title,
                       isActive: isActive, hovering: hovering, action: action)
            .onHover { hovering = $0 }
            .help(group.title)
            .accessibilityIdentifier("moduleRail.\(group.rawValue)")
    }
}

/// V4：底部设置齿轮（ModuleNav.tsx:105-114：icon=settings、label=设置、选中态同模块钮）
private struct SettingsGearButton: View {
    let isActive: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        RailButtonBody(icon: "gearshape", title: "设置",
                       isActive: isActive, hovering: hovering, action: action)
            .onHover { hovering = $0 }
            .help("设置")
            .accessibilityIdentifier("moduleRail.settings")
    }
}

/// rail 按钮通用外观（ModuleNav.tsx:61-78：42×46 圆角 10、图标 18 + 10 号微标签、
/// 选中 = 浅底 + 强调字 + 左侧 3px 指示条）
private struct RailButtonBody: View {
    let icon: String
    let title: String
    let isActive: Bool
    let hovering: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 17))
                Text(title)
                    .font(.system(size: 9.5, weight: isActive ? .semibold : .regular))
            }
            .frame(width: 44, height: 46)
            .background(isActive ? VTheme.accentBg : (hovering ? VTheme.bgHover : Color.clear),
                        in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(isActive ? VTheme.accentText : VTheme.textSecondary)
            .overlay(alignment: .leading) {
                if isActive {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(VTheme.accent)
                        .frame(width: 3)
                        .padding(.vertical, 12)
                        .offset(x: -7)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 面板侧栏（智能中心 = 单栏堆叠；流程中心 = 单栏手风琴）
//  V2：底部全局侧车控制条移除（原版 ModuleNav.tsx:82-117 仅模块图标 + 底部齿轮，
//  无侧车常驻 UI）；连接状态与停止/重启/端口/数据根设置并入「关于」面板侧车区块
// （V4：「关于」= 设置覆盖页内部导航末项）。
//  图2：流程中心侧栏不再是通用面板 List——与智能中心一致的单栏手风琴
// （工作流 / CU 宏两区，WorkflowSidebarView），核心视觉让位中心内容区。

struct PanelSidebarView: View {
    @EnvironmentObject private var appState: AppState
    /// V1：固定宽（0.5.2 B2 起恒 260，RootView.sidebarWidth 算出——原版
    /// clamp(260, 24vw, 320) 弹性已撤，见该函数注）——
    /// 定宽 frame 本身不可压缩，U1 防挤压口径保留（超载时压内容区不压侧栏）
    let width: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            if appState.selectedModule == .intelligence {
                // V1：智能中心侧栏 = 单栏堆叠（App.tsx:233-290），不再是面板列表
                IntelligenceSidebarView()
            } else {
                // 图2：流程中心侧栏 = 单栏手风琴（工作流 / CU 宏），与智能中心一致
                WorkflowSidebarView()
            }
        }
        .frame(width: width)
        .background(VTheme.bgSidebar)
    }
}
