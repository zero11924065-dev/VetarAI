//
//  AppState.swift
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

//  全局应用状态（根注入，environmentObject 贯穿所有面板）：
//    · 导航：当前模块组 / 当前面板（UserDefaults 记忆，重启恢复）
//    · 业务选择：当前项目 / Agent / 会话（后续波次面板共用，避免各自为政）
//    · 共享服务：NativeRuntime（原生内核运行时 + 客户端）、AuthCenter（授权）、AppLogger
//
//  面板接入约定见 docs/Phase1-面板接入指南.md。
//

import Foundation
import Combine
import MLXLMCommon

@MainActor
public final class AppState: ObservableObject {

    // ── 导航 ──
    @Published public var selectedModule: ModuleGroup {
        didSet { defaults.set(selectedModule.rawValue, forKey: Keys.module) }
    }
    @Published public var selectedPanel: PanelDescriptor {
        didSet { defaults.set(selectedPanel.key, forKey: Keys.panel) }
    }

    // ── 设置整页覆盖（V4，对标 App.tsx:201-206/371-381 showSettingsPage）──
    // 覆盖层盖住侧栏+内容区（rail 保留）；打开不改变 selectedModule/selectedPanel——
    // 关闭即回来源处（用户拍板口径，优于原版 onOpenSettings 强制切回智能中心）。
    // 不持久化（对齐原版 useState 内存态）。
    @Published public var showSettings = false
    /// 覆盖页当前内部分区（齿轮/菜单/深链可指定；对标 SettingsPage.tsx initialSection）
    @Published public var settingsSection: SettingsSection

    // ── 业务选择（面板间共享的「当前上下文」）──
    @Published public var currentProjectId: String?
    @Published public var currentAgentId: String?
    @Published public var currentSessionId: String?

    // ── 共享服务 ──
    public let runtime: NativeRuntime
    public let auth: AuthCenter
    public let logger: AppLogger
    /// ADR-0052 方案A：.vmodel MLX 引擎缓存 REQ-FUT-020（0.7.5 W1）起收口到
    /// NativeVModelChatRouter.shared（全局共享，见 chatViaVModelMLX）。
    /// 0.6 注册授权（W0/W1）：License 状态机（五态）+ 离线检测。
    /// 命名红线：勿用 Auth（Core/Auth 已是工具人审授权），本模块一律 License/Account。
    public let license: LicenseCenter
    public let network: NetworkMonitor
    /// v1.4（0.7.2）：协议签署状态机（launch 首启门 + purchase 付费门 +
    /// consent 上报/补报 + needReConsent 核对；契约 §2.9 / 任务书 B 组）。
    public let agreement: AgreementCenter
    /// v1.4（0.7.2）建 / 0.7.9 换 Sparkle（契约 v1.10 §2.15）：检查更新
    ///（日级静默自动查 + 手动检查；下载/验签/安装/重启全链 Sparkle 原生）。
    public let update: UpdateController
    /// v1.4：用户反馈中心（§2.11；keychain 显式传与 license 同 service 域——
    /// 冒烟隔离环境变量同域生效，见 LicenseTokenKeychain.init）。
    public let feedback: FeedbackCenter
    /// v1.8（0.7.8）：页面跳转链接中心（契约 §2.14；links 五键 + agreementVersion
    /// 一处拿全，内存缓存 5 分钟，静态清单兜底——协议 web 全文/购买入口数据源）。
    public let appConfig: AppConfigCenter
    /// v1.11（契约）：真强制更新启动阻断闸门（最低可用版本缓存双写双读 +
    /// 纯本地启动判定 + latest 联网刷新 + 426 钩子接管；RootView 最高优先级
    /// 全屏阻断页，见 MandatoryUpdateGate.swift 头注）。
    public let mandatoryUpdate: MandatoryUpdateGate
    /// 必备模型按需下载（REQ-FUT-015 / ADR-0051，W10）：清单内嵌 bundle +
    /// 状态机持久化于 dataRoot；首装登录后弹窗（maybePromptRequiredModels），
    /// 模型包面板（设置覆盖页）可随时手动下载。
    public let requiredModels: NativeRequiredModels
    /// W8（0.7.4）：reportBusy 关闭/切走确认闸——工作流运行中 / 圆桌讨论进行中
    /// 时模块切换与窗口关闭先弹 NSAlert 确认（面板 VM 翻转即上报，见 PanelBusyGuard）。
    public let busyGuard = PanelBusyGuard()
    /// W9（0.7.5）：kv.hit/miss 会话归因注册表——工作室各会话 metricsSink 按
    /// sessionID 注册，路由事件按【事件源头携带的 sessionID】归属（不再「最近
    /// 装配会话通吃」，跨会话连续跑不错记）。装配见 init 末尾与 makeStudioEngine。
    private let kvSinkRegistry = NativeKVSessionSinkRegistry()
    /// 首装必备模型下载弹窗（覆盖层口径同 showSettings；「以后再说」置标记不再骚扰）
    @Published public var showRequiredModelsPrompt = false
    /// S3-N2（2026-09-30）：必备模型清单缺失一次性明示弹窗注入缝（测试替换为免 UI
    /// 实现防 DialogCenter 挂起；生产 nil → 默认走 DialogCenter.alert——参照
    /// AgentPanelViewModel.alertPresenter 弹窗注入缝先例）。
    internal var manifestMissingHandler: (() -> Void)?

    // ── 注册授权 UI 呈现（W1；对标 spec.md auth-03/04/05/07）──
    /// 激活页覆盖（auth-03 输入 → auth-04 成功态）
    @Published public var showActivation = false
    /// 登录页覆盖（0.7.7 登出态 UI 簇：证书锁定/未登录态从账号页、付费门唤出
    /// 登录——RootView 仅在 status==.loggedOut 时才整页挂 AuthFlowView，
    /// certLocked 主界面仍挂载，需独立呈现通道；登录成功自动关）
    @Published public var showAuth = false
    /// 付费门控弹窗（auth-05）
    @Published public var showPaywall = false
    /// 试用到期冻结弹窗（auth-07；每次启动至多弹一次，关闭后只读口径由付费模块落实）
    @Published public var showTrialExpired = false

    // ── 超级工作室（W3 阶段一 / W8 会话管理 REQ-FUT-012/013/014）──
    /// 当前会话引擎（RootView 工作室主页持有保活；切模块/开设置不销毁）。
    /// REQ-FUT-012③：新建/切换会话时整实例替换，RootView 以 .id(sessionId) 重建视图。
    /// 生产装配：执行通道 = kernel.chatConnector（Ollama chatStream 聚合）；主模型默认 =
    /// 智能中心 default_model（REQ-FUT-013 业主可改随会话落盘）；画布索引 = bge-m3
    /// （kernel.embedder 懒加载，不可用静默降级关键词）。
    @Published public private(set) var studioEngine: StudioEngine?
    /// W1（0.7.4，业主数据安全红线）：画布库建库失败（磁盘极端异常）→ 工作室优雅
    /// 不可用标记。旧版退化临时目录 + 强制 try 双雷（tmp 重启丢数据 + tmp 也不可写
    /// 时直接 crash）；现口径：不 crash、不落临时目录、记日志，
    /// 工作室入口显示 studioUnavailableMessage 中文提示。
    @Published public private(set) var studioUnavailable = false
    /// W1：画布库不可用中文提示（RootView 工作室入口占位视图逐字展示；测试断言存在）。
    public static let studioUnavailableMessage =
        "画布库不可用（磁盘异常），工作室暂不可用，请检查磁盘后重启应用"
    /// W1 失败注入缝（仅测试注入）：非 nil 时替代真实 StudioEngine 构造
    /// （含画布库建库）——模拟磁盘极端异常下建库失败链路。生产恒 nil。
    internal var studioEngineFactoryOverride: ((StudioSessionSnapshot?) throws -> StudioEngine)?

    /// 首访创建（RootView 工作室入口调用）。
    /// REQ-FUT-012① 启动恢复：有未完结会话快照（review/running/paused/failed）则恢复之，
    /// 否则开新会话。W1：建库失败返回 nil 并置 studioUnavailable（优雅不可用，不 crash）。
    @discardableResult
    public func ensureStudioEngine() -> StudioEngine? {
        if let e = studioEngine { return e }
        let snap = StudioSessionStore.latestUnfinished(dataRoot: runtime.kernel.dataRoot)
        do {
            let e = try makeStudioEngine(restoring: snap)
            studioEngine = e
            studioUnavailable = false
            return e
        } catch {
            studioUnavailable = true
            logger.error("画布库初始化失败（工作室暂不可用）：\(error.localizedDescription)")
            return nil
        }
    }

    /// W1：不可用占位页「重试」——磁盘恢复后免重启重建（失败则保持不可用态）。
    public func retryStudioEngine() {
        guard studioEngine == nil else { studioUnavailable = false; return }
        studioUnavailable = false
        _ = ensureStudioEngine()
    }

    /// REQ-FUT-012③：新建工作室会话（既有会话快照全部保留——永不删除红线）
    public func newStudioSession() {
        pauseRunningStudioEngineForSwitch()
        do {
            studioEngine = try makeStudioEngine(restoring: nil)
            studioUnavailable = false
        } catch {
            // 旧会话已按暂停红线收尾落盘；建库失败 → 工作室不可用（不 crash 不丢数据）
            studioEngine = nil
            studioUnavailable = true
            logger.error("新建工作室会话失败（画布库不可用）：\(error.localizedDescription)")
        }
    }

    /// REQ-FUT-012③：切换到历史会话（快照载入重建引擎；在飞会话先按暂停红线收尾）
    public func switchStudioSession(to sessionId: String) {
        guard let cur = ensureStudioEngine() else { return }
        guard cur.sessionId != sessionId else { return }
        guard let snap = StudioSessionStore.load(dataRoot: runtime.kernel.dataRoot,
                                                 sessionId: sessionId) else { return }
        pauseRunningStudioEngineForSwitch()
        do {
            studioEngine = try makeStudioEngine(restoring: snap)
            studioUnavailable = false
        } catch {
            studioEngine = nil
            studioUnavailable = true
            logger.error("切换工作室会话失败（画布库不可用）：\(error.localizedDescription)")
        }
    }

    /// 会话列表（顶条会话菜单；lastActiveAt 倒序。永不删除故全量，超出 100 截尾保 UI 轻快）
    public func studioSessionList() -> [StudioSessionSnapshot] {
        Array(StudioSessionStore.list(dataRoot: runtime.kernel.dataRoot).prefix(100))
    }

    /// 空态卡「继续上次任务」：最近未完结会话（当前会话自身除外）
    public func latestResumableStudioSnapshot() -> StudioSessionSnapshot? {
        guard let snap = StudioSessionStore.latestUnfinished(dataRoot: runtime.kernel.dataRoot),
              snap.sessionId != studioEngine?.sessionId else { return nil }
        return snap
    }

    /// 切换/新建前收尾：在飞会话先暂停（在飞优雅取消 + 落盘 flush + 快照同步写）
    private func pauseRunningStudioEngineForSwitch() {
        guard let e = studioEngine, e.phase == .running else { return }
        e.pause()
    }

    /// W1：改为 throws——画布库建库失败完整错误链上抛，由调用方转「工作室不可用」
    /// 优雅态；⛔ 用户数据永不落临时目录（旧版 tmp 退化 + 强制 try 双雷已拆除）。
    private func makeStudioEngine(restoring snapshot: StudioSessionSnapshot?) throws -> StudioEngine {
        // 失败注入缝（仅测试；见 studioEngineFactoryOverride 注）
        if let override = studioEngineFactoryOverride { return try override(snapshot) }
        let kernel = runtime.kernel
        let config = (try? kernel.config.getConfig()) ?? NativeConfigStore.defaultConfig
        let defaultModel = config["default_model"]?.string ?? "qwen3.8"
        // W4 §8.1：会话级观测汇流——执行层 llm.ttft/llm.done 埋点与引擎共用同一
        // sink（画布库旁 metrics/，⛔ 不落 tmp）；新会话先定 sessionId 供两边共用。
        let sessionId = snapshot?.sessionId ?? UUID().uuidString
        let metricsSink = StudioMetricsSink(
            directory: kernel.dataRoot.appendingPathComponent("studio/metrics", isDirectory: true),
            sessionID: sessionId)
        // W5 KV：.vmodel MLX 推理的 kv.hit/kv.miss 汇进工作室会话观测流（execution 层）。
        // W9 修复（0.7.5）：旧口径「全局共享 sink = 最近装配会话」，跨会话连续跑时
        // 前一会话在飞事件错记到后一会话名下——现按 sessionID 注册，事件源头
        // （router 逐调用绑定）带 sessionID → 按归属路由；全局 sink 在 init 装一次。
        kvSinkRegistry.register(sessionID: sessionId) { kind, attrs in
            Task { [metricsSink] in
                await metricsSink.record(layer: .execution, kind: kind,
                                         modelID: attrs["modelID"], attrs: attrs)
            }
        }
        kvSinkRegistry.setFallbackSessionID(sessionId)
        // 执行通道走 chatStream 聚合而非 chat：chat() 硬编码 60s 超时（Python
        // 报错分析场景口径），扛不住拆解/初审/汇总的长生成；流式读超时默认
        // 1800s 且边收边续（W3 冒烟实证：qwen3.8 长 JSON 两连超时后改此路）。
        let chatViaStream: StudioEngine.ChatFn = { model, messages in
            // .vmodel 条目：ADR-0052 方案A 正式化——MLX 推理真路径。任何一环失败
            // 抛 inferenceFailed 同款黑盒（绝不静默换模型，DBG-0030 红线）。
            if NativeVModelChat.isVModelName(model) {
                // REQ-INFER-011（0.7.5 W1主）：改走 router.chatStream 流式真路径——
                // 库 GenerateCompletionInfo 的 promptTokenCount/generationTokenCount
                // 真值接进 llm.done（与 ollama 路 tokensIn/Out 同口径，⛔ 不估算）；
                // llm.ttft 接首 content/thinking delta（旧聚合路无流缝记不到）；
                // W9：kv 事件逐调用绑定本会话 sessionID（跨会话不错记）。
                let t0 = Date()
                var firstTokenAt: Date? = nil
                var content = ""
                var thinking = ""
                var tokIn = 0
                var tokOut = 0
                let stream = NativeVModelChatRouter.shared.chatStream(
                    poolName: model, installer: kernel.vmodelInstaller, messages: messages,
                    tools: nil, maxTokens: 1024, kvSessionID: sessionId)
                for try await ev in stream {
                    switch ev {
                    case .contentDelta(let d):
                        if firstTokenAt == nil { firstTokenAt = Date() }
                        content += d
                    case .thinkingDelta(let d):
                        if firstTokenAt == nil { firstTokenAt = Date() }
                        thinking += d
                    case .done(let pe, let ec):
                        tokIn = pe
                        tokOut = ec
                    case .streamError(let m): throw NativeChatConnectorError.network(m)
                    default: break
                    }
                }
                let totalMs = Date().timeIntervalSince(t0) * 1000
                let ttftMs = firstTokenAt.map { $0.timeIntervalSince(t0) * 1000 }
                Task { [metricsSink] in
                    if let ttftMs {
                        await metricsSink.record(layer: .execution, kind: "llm.ttft",
                                                 modelID: model, durationMs: ttftMs)
                    }
                    await metricsSink.record(layer: .execution, kind: "llm.done",
                                             modelID: model, durationMs: totalMs,
                                             tokensIn: tokIn, tokensOut: tokOut,
                                             attrs: ["path": "vmodel-mlx"])
                }
                return content.isEmpty ? thinking : content
            }
            // W4 §8.1：llm.ttft（首 content/thinking delta）+ llm.done（整段
            // durationMs + tokensIn/Out）。taskNodeID 本缝拿不到——chatFn 签名
            // 无节点上下文（引擎逐节点调用不穿透装配层），诚实缺省不硬接。
            let t0 = Date()
            var firstTokenAt: Date? = nil
            let stream = kernel.chatConnector.chatStream(model: model, messages: messages,
                                                         tools: nil, images: nil)
            var content = ""
            var thinking = ""
            var tokIn = 0
            var tokOut = 0
            for try await ev in stream {
                switch ev {
                case .contentDelta(let d):
                    if firstTokenAt == nil { firstTokenAt = Date() }
                    content += d
                case .thinkingDelta(let d):
                    if firstTokenAt == nil { firstTokenAt = Date() }
                    thinking += d
                case .done(let pe, let ec):
                    tokIn = pe
                    tokOut = ec
                case .streamError(let m): throw NativeChatConnectorError.network(m)
                default: break
                }
            }
            let totalMs = Date().timeIntervalSince(t0) * 1000
            let ttftMs = firstTokenAt.map { $0.timeIntervalSince(t0) * 1000 }
            Task { [metricsSink] in
                if let ttftMs {
                    await metricsSink.record(layer: .execution, kind: "llm.ttft",
                                             modelID: model, durationMs: ttftMs)
                }
                await metricsSink.record(layer: .execution, kind: "llm.done",
                                         modelID: model, durationMs: totalMs,
                                         tokensIn: tokIn, tokensOut: tokOut)
            }
            // thinking 模型（qwen3 系）双通道兜底：content 为空时思考全文回传，
            // 由 StudioTaskGraphParser 的容错解析从中抠 JSON（冒烟实证：
            // qwen3.8 长思考后 content 偶发为空，纯 content 通道会误报拆解失败）
            return content.isEmpty ? thinking : content
        }
        if let snapshot {
            return try StudioEngine(
                dataRoot: kernel.dataRoot, restoring: snapshot,
                embedder: kernel.embedder,
                chatFn: chatViaStream,
                modelResolver: { _ in defaultModel },
                poolLoader: { await StudioPoolDiscovery.discover(kernel: kernel) },
                defaultMainModel: defaultModel,
                metrics: metricsSink,
                // 0.7.7 W6：discuss 发言 vmodel agentic 回路（埋点归本会话 sink，
                // 与 llm.done/kv 同流）
                agenticFn: kernel.makeVModelAgenticRunner(metricsSink: metricsSink))
        }
        return try StudioEngine(
            dataRoot: kernel.dataRoot,
            sessionId: sessionId,
            embedder: kernel.embedder,
            chatFn: chatViaStream,
            modelResolver: { _ in defaultModel },
            poolLoader: { await StudioPoolDiscovery.discover(kernel: kernel) },
            defaultMainModel: defaultModel,
            metrics: metricsSink,
            agenticFn: kernel.makeVModelAgenticRunner(metricsSink: metricsSink),
            // S1 根治（2026-09-30）：执行层付费硬校验——开工类动作入口卡闸。
            // 弱捕获防循环引用（引擎由本对象持有）；装配拆除后回落锁（安全侧）。
            studioGateCheck: { [weak self] in
                guard let self else { return true }
                return LicenseGateLogic.studioGated(status: self.license.status)
            })
    }

    /// ADR-0052 方案A：vmodel MLX 推理统一走全局共享路由 NativeVModelChatRouter
    /// （REQ-FUT-020 0.7.5 W1 收口）——工作室会话经 makeStudioEngine 的
    /// chatViaStream vmodel 分支调 router.chatStream（流式+真值计量+kv 逐调用
    /// 归因），主会话/委派/圆桌经 kernel.vmodelRoutingConnector 同路由。
    /// 任一环失败抛 inferenceFailed 黑盒（诚信红线不静默换模型）。

    private let defaults: UserDefaults
    /// W1：License/Network 子对象变化转发（冒烟实证：EnvironmentObject 只听 AppState
    /// 自身 @Published，license.status 翻转不会触发 RootView 重渲染——门不开。
    /// 这里把两个子对象的 @Published 桥接到 AppState.objectWillChange）。
    private var licenseCancellables: Set<AnyCancellable> = []

    private enum Keys {
        static let module = "ui.module"
        static let panel = "ui.panel"
        /// 设置分区深链（对标 tsx `-ui.settingsSection`，0.4.30；非法值回退 general）
        static let settingsSection = "ui.settingsSection"
        /// 必备模型首装弹窗已提示（REQ-FUT-015：「以后再说」也置位——不反复骚扰，
        /// 模型包面板可随时手动下载）
        static let requiredModelsPrompted = "requiredModels.prompted"
        /// S3-N2（2026-09-30）：必备模型清单缺失一次性明示已弹。⛔ 不复用
        /// requiredModelsPrompted——清单恢复后首装弹窗流程须能再走。
        static let requiredModelsManifestAlerted = "requiredModels.manifestAlerted"
    }

    /// V4 前已移除的旧面板键（UserDefaults 记忆/深链兜底口径）
    private enum LegacyKey {
        /// 旧「基础设置」面板键 → 启动直达设置整页覆盖（对齐 V4 前 `-ui.panel settings` 口径）
        static let settings = "settings"
    }

    public init(defaults: UserDefaults = .standard,
                logger: AppLogger = .shared,
                runtime: NativeRuntime? = nil,
                license: LicenseCenter? = nil,
                agreement: AgreementCenter? = nil,
                update: UpdateController? = nil,
                feedback: FeedbackCenter? = nil,
                appConfig: AppConfigCenter? = nil,
                mandatoryUpdate: MandatoryUpdateGate? = nil) {
        self.defaults = defaults
        self.logger = logger
        let rt = runtime ?? NativeRuntime(defaults: defaults, logger: logger)
        self.runtime = rt
        self.auth = AuthCenter(logger: logger, clientProvider: { [weak rt] in rt?.client })
        // W1：License 地基装配——Keychain token + license.json + Ed25519 离线验签
        //（Core/License/，W0 交付）。启动离线判定 boot() 由 RootView task 触发一次。
        // 0.7.1 实测修复批：license 可注入（测试隔离 store/keychain/api 桩；
        // 生产 nil → 默认构造，冒烟隔离走 VETARAI_LICENSE_SMOKE_* 环境变量，
        // 见 LicenseStore.defaultBaseDir）。
        self.license = license ?? LicenseCenter()
        self.network = NetworkMonitor()
        // v1.4：协议中心装配（显式 LicenseStore.defaultBaseDir + 默认 Keychain
        // service——冒烟隔离环境变量与 License 三件套同域生效；⛔ 此处勿图省事
        // 给默认参数，测试必须显式注入隔离实例，见 AgreementCenter.init 注）。
        // 首帧前完成本地判定，协议门不闪屏。文案缺失记日志（门显安装损坏提示）。
        self.agreement = agreement ?? AgreementCenter(baseDir: LicenseStore.defaultBaseDir,
                                                      keychain: LicenseTokenKeychain())
        self.agreement.boot()
        if self.agreement.texts == nil {
            logger.error("协议文案加载失败（Resources/agreements 三份 txt 缺失或为空）")
        }
        // v1.4 建 / 0.7.9 换 Sparkle：检查更新控制器（defaults 注入随调用方——
        // 测试隔离 suite；checker 懒加载，生产首次真正检查时才启动 Sparkle）
        self.update = update ?? UpdateController(defaults: defaults)
        // v1.4：用户反馈中心（§2.11；keychain 显式传与 AgreementCenter 同纪律——
        // ⛔ 勿给默认构造，测试必须注入 UUID service 隔离实例，防摸真实 Keychain）
        self.feedback = feedback ?? FeedbackCenter(defaults: defaults,
                                                   keychain: LicenseTokenKeychain())
        // v1.8：页面链接中心（§2.14；纯内存缓存 5 分钟 + 静态清单兜底，
        // 无 Keychain/文件依赖，测试可直接默认构造或注入 mock apiProvider）
        self.appConfig = appConfig ?? AppConfigCenter()
        // v1.11：真强制更新闸门（契约 v1.11）——生产显式传 LicenseStore
        // .defaultBaseDir + 注入 defaults（冒烟隔离环境变量同域生效；测试注入
        // tmp 目录 + 隔离 suite）。init 内同步读缓存完成首帧判定，不闪屏。
        let gate = mandatoryUpdate ?? MandatoryUpdateGate(defaults: defaults,
                                                          baseDir: LicenseStore.defaultBaseDir)
        self.mandatoryUpdate = gate
        // v1.11：426/UPGRADE_REQUIRED 全局钩子装配——任何业务接口被拦即写缓存
        // + 阻断页接管（已登录会话当场生效；weak 防静态钩子持有 AppState 漂移）
        LicenseAPIClient.onUpgradeRequired = { [weak gate] min in
            Task { @MainActor in gate?.handleUpgradeRequired(minRequiredVersion: min) }
        }
        // W10（REQ-FUT-015 / ADR-0051）：必备模型编排装配——清单加载失败仅记日志
        // （弹窗触发处对 manifest==nil 静默不弹）；embedder_dir 就绪 → 清装载失败
        // 记忆化热生效（正常路径无需重启；重启为 ADR 兜底分支，见 restartApp）。
        let reqModels = NativeRequiredModels(dataRoot: rt.kernel.dataRoot,
                                             packStore: rt.kernel.modelPackStore)
        // S3-N1（2026-09-30）：把 AppState 自己的 logger 传给 reqModels——其默认
        // .shared 在 xctest 宿主虽已改向 tmp，但 AppState 显式注入的隔离 logger 口径
        // 更准（与 NativeRuntime(defaults:logger:) 同纪律）。属性本是 public var，
        // 直接赋值即最小侵入（不动 init 签名）。
        reqModels.logger = logger
        reqModels.onModelReady = { [weak rt] modelId in
            MainActor.assumeIsolated {   // 钩子契约：MainActor 回调（就绪分支内触发）
                if modelId == NativeEmbedder.modelDirName {
                    rt?.kernel.embedder.resetForRetry()
                }
            }
        }
        self.requiredModels = reqModels
        do {
            try reqModels.loadManifest()
        } catch {
            logger.error("必备模型清单加载失败：\(error.localizedDescription)")
        }

        // V4：旧「系统」组模块键恢复落空 → 智能中心（ModuleGroup(rawValue:) 为 nil）
        let module = ModuleGroup(rawValue: defaults.string(forKey: Keys.module) ?? "") ?? .intelligence
        let rawPanelKey = defaults.string(forKey: Keys.panel) ?? ""
        if rawPanelKey == LegacyKey.settings {
            // 旧设置记忆键/深链 → 打开设置覆盖页，落聊天主页兜底（不崩）
            self.selectedModule = .intelligence
            self.selectedPanel = PanelRegistry.chatHome
            self.showSettings = true
        } else {
            let restored = PanelRegistry.panel(forKey: rawPanelKey)
                ?? PanelRegistry.defaultPanel(in: module)
            // 0.7.1 勘误 P0（业主拍板 2026-09-22：「启动直进工作室且回不去，默认页
            // 应为智能中心」）：启动恢复集合排除工作室——上次退出停在工作室也恒落
            // 智能中心聊天主页；其余模块记忆恢复口径不变。
            let panel = restored.group == .studio ? PanelRegistry.chatHome : restored
            if panel != restored {
                // didSet 在 init 内不触发——显式回写自愈，下次启动不再命中 studio 键
                defaults.set(panel.group.rawValue, forKey: Keys.module)
                defaults.set(panel.key, forKey: Keys.panel)
            }
            // 深链/记忆恢复时模块竖条跟随面板所属组（对齐 selectPanel 联动语义，
            // 避免 -ui.panel workflows 直达时竖条停在默认「智能中心」）
            self.selectedModule = panel.group
            self.selectedPanel = panel
        }
        // 设置分区深链（非法值回退 general；SettingsPage.tsx:55 validInitial 同口径）
        self.settingsSection = SettingsSection(
            rawValue: defaults.string(forKey: Keys.settingsSection) ?? "") ?? .general
        // W1：子对象变化桥接（见 licenseCancellables 注）——登录/激活/试用翻转
        // 与离线状态变化必须驱动 RootView 门控与横幅重渲染。
        self.license.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] st in
                guard let self else { return }
                self.objectWillChange.send()
                // v1.4：登录翻转即核对协议（补报待上传 consent + needReConsent 重签）
                if st != .loggedOut { self.syncAgreementIfPossible() }
                // v1.4：登录翻转补一次自动更新检查（日级门控防重复——
                // 启动时未登录、当日首次登录的场景也覆盖到「每天一次」口径）
                if st != .loggedOut { self.maybeAutoCheckUpdate() }
            }
            .store(in: &licenseCancellables)
        // 0.7.1 实测修复（Bug 5）：restoreOffer 桥接漏网根治——W1 只桥了 $status，
        // RootView `.onChange(of: appState.license.restoreOffer)` 在 body 不重跑时
        // 永不求值：账号页点「恢复本机授权」probe 置上提案却无反应，直到别的
        // @Published 变化带动重渲染确认框才迟弹（业主实测实锤）。补上桥。
        self.license.$restoreOffer
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &licenseCancellables)
        network.$isOnline
            .receive(on: RunLoop.main)
            .sink { [weak self] online in
                guard let self else { return }
                self.objectWillChange.send()
                // v1.4：网络恢复即核对协议（断网期间待补报的 consent 随路补报）
                if online { self.syncAgreementIfPossible() }
            }
            .store(in: &licenseCancellables)
        // v1.4：协议状态桥接（门开闭/付费守卫翻转驱动 RootView 与激活页重渲染，
        // 与 license 桥接同因——EnvironmentObject 只听 AppState 自身 @Published）
        self.agreement.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &licenseCancellables)
        // v1.4：更新状态桥接（pendingUpdate 置位弹对话框、下载进度驱动重渲染）
        self.update.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &licenseCancellables)
        // v1.4：反馈状态桥接（提交中/结果条/我的反馈列表驱动设置页重渲染）
        self.feedback.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &licenseCancellables)
        // v1.8：页面链接桥接（config 下发到位后购买入口/协议 web 链即时刷新）
        self.appConfig.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &licenseCancellables)
        // v1.11：强制更新闸门桥接（isBlocked 翻转驱动 RootView 整页阻断接管，
        // 与 license 桥接同因——EnvironmentObject 只听 AppState 自身 @Published）
        self.mandatoryUpdate.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &licenseCancellables)
        // W10：必备模型状态桥接（下载进度/就绪翻转驱动弹窗与模型包面板重渲染，
        // 与 license 桥接同因——EnvironmentObject 只听 AppState 自身 @Published）
        reqModels.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &licenseCancellables)
        // W9（0.7.5）：kv.hit/miss 全局出口装一次——按事件源头 sessionID 路由到
        // 各工作室会话 metricsSink（注册见 makeStudioEngine）；无 sessionID 的事件
        // 归 fallback（最近工作室会话），未知 sessionID 丢弃（宁可不记不错记）。
        let kvRegistry = kvSinkRegistry
        Task {
            await NativeVModelChatRouter.shared.setKVEventSink(kvRegistry.handler())
        }
        logger.info("AppState 就绪：module=\(selectedModule.rawValue) panel=\(selectedPanel.key) settings=\(showSettings ? settingsSection.rawValue : "off") version=\(AppVersion.current)")
    }

    /// 选择面板（自动切到其所属模块组）。
    public func selectPanel(_ panel: PanelDescriptor) {
        selectedModule = panel.group
        selectedPanel = panel
    }

    /// 打开设置整页覆盖（可指定分区；未指定保持当前分区）。
    public func openSettings(_ section: SettingsSection? = nil) {
        if let section { settingsSection = section }
        showSettings = true
    }

    /// 关闭设置覆盖——回来源处（selectedModule/selectedPanel 未动，直接落回）。
    public func closeSettings() {
        showSettings = false
    }

    /// rail 底部齿轮：开关切换（对标 App.tsx:204 setShowSettingsPage(v => !v)）。
    public func toggleSettings() {
        showSettings.toggle()
    }

    // MARK: - v1.4 协议同意联网核对

    /// 启动/登录翻转/网络恢复各调一次：补报待上传 consent + 拉 status 核对
    /// needReConsent（未登录/断网静默跳过，不打扰——契约约定 4 断网以本地为准）。
    public func syncAgreementIfPossible() {
        Task { await agreement.syncIfPossible(isOnline: network.isOnline) }
    }

    // MARK: - v1.4 建 / 0.7.9 Sparkle 检查更新（日级静默自动查）

    /// 业主拍板口径：每天仅第一次打开且联网已登录时静默查一次
    ///（RootView 启动 task 与登录翻转各调一次；日级门控在 UpdateController 内，
    /// 断网/未登录/今日已查全部不触碰 Sparkle，零打扰——任务书 C 边界；
    /// 有更新时由 Sparkle 原生弹窗呈现）。
    public func maybeAutoCheckUpdate() {
        update.autoCheckIfDue(isOnline: network.isOnline,
                              isLoggedIn: license.status != .loggedOut)
    }

    // MARK: - v1.8 页面链接预取（§2.14；5 分钟内存缓存）

    /// 启动/登录翻转各调一次：缓存新鲜（<300s）跳过，过期静默拉取——
    /// 断网/失败保留兜底值不打扰（§2.14 兜底约定）。
    public func prefetchAppConfigIfNeeded() {
        Task { await appConfig.refreshIfNeeded() }
    }

    // MARK: - 必备模型首装弹窗与重启兜底（REQ-FUT-015 / ADR-0051，W10）

    /// 首装弹窗触发（RootView .task 与 license.status onChange 各调一次）：
    /// 已登录 + 未提示过 + 任一模型未就绪 → 弹。清单缺失时补一次性明示弹窗
    /// （S3-N2 2026-09-30：原静默 return 零用户信号，不开设置页永远不知道）；
    /// 全就绪置标记以后不再探（用户手删文件的场景由模型包面板兜底呈现）。
    public func maybePromptRequiredModels() {
        guard !defaults.bool(forKey: Keys.requiredModelsPrompted) else { return }
        guard license.status != .loggedOut else { return }
        guard requiredModels.manifest != nil else {
            // S3-N2 2026-09-30 真因：manifest==nil 原静默 return（init 仅 logger.error，
            // 设置-模型包页横幅要用户主动开设置才可见）；补一次性明示。独立键
            // 不复用 requiredModelsPrompted——清单恢复后首装弹窗流程须能再走。
            if !defaults.bool(forKey: Keys.requiredModelsManifestAlerted) {
                defaults.set(true, forKey: Keys.requiredModelsManifestAlerted)
                if let handler = manifestMissingHandler {
                    handler()
                } else {
                    Task { await DialogCenter.shared.alert(
                        title: "安装包不完整",
                        message: "必备模型清单缺失，索引与语音功能不可用。请重新安装或联系支持（可在设置-更新与反馈一键上传日志）。") }
                }
            }
            return
        }
        guard requiredModels.needsDownload else {
            defaults.set(true, forKey: Keys.requiredModelsPrompted)
            return
        }
        showRequiredModelsPrompt = true
    }

    /// 「以后再说」/完成关闭：置标记不再骚扰；模型包面板随时可手动下载。
    public func dismissRequiredModelsPrompt() {
        defaults.set(true, forKey: Keys.requiredModelsPrompted)
        showRequiredModelsPrompt = false
    }

    /// 重启兜底（ADR-0051「需重启才生效」分支——两必备模型正常均热生效，此路径
    /// 仅 manifest 标记 restart_required 或状态污染等异常才走）：
    /// 先按 W8 红线暂停在飞工作室会话（在飞优雅取消 + 落盘 flush + 快照同步写，
    /// 重启不丢数据），再延迟重生新实例并退出本进程。
    public func restartApp() {
        pauseRunningStudioEngineForSwitch()
        AppRelauncher.relaunchPreservingArguments()
    }
}
