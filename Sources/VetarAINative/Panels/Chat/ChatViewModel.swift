//
//  ChatViewModel.swift
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

//  会话面板 ViewModel。行为逐段对照 subagent/renderer/src/panels/ChatPanel.tsx（3167 行）：
//    · 会话管理：列表/新建/重命名/删除/切换/刷新（DB 为权威源）
//    · 发送链路：附件组装（ATTACH_MARK 拉模式）/ A5 思考中注入 / B13 显式文本重发
//    · SSE 事件分发：token/thinking（纪律①合帧）/ tool_call/tool_result（步骤条配对）/
//      state（步骤计数 + ctx_chars 单调守门）/ segment_break（#1 插入点分裂）/
//      done（全文覆盖 + break_at 切段）/ error（报错分析）/ cancelled（=手动停止）/
//      compact_required（三选一警告条）/ compact_auto（toast，见契约差异记录）/
//      auth_request（→ 全局 AuthCenter）
//    · M5 断线重连：业务错误（400/404/422）不重试；网络错误指数退避 + 提示条
//    · 计时三件套：思考阶段计时（B12 流级计时器）/ 等待横幅（REQ-MSG-022 按段复位）/
//      完成用时定格
//    · 上下文指示器：0.4.34 口径（主数字=上限，括号当前档；done 后重拉）
//    · 知识仓库转移（TS-120）/ 单元归档开关（0.4.9）/ 导出 / 自动总结
//
//  ═══ Phase 1 三条纪律（全员必读，README 同载）═══
//  ① 流式渲染必经 StreamAccumulator 缓冲 + 定频合帧 flush（15fps，DBG-138）。
//  ② 停止 = 先 POST /chat/{sid}/stop 再断本地流（顺序不可颠倒）。
//  ③ SSE 事件处理：非增量事件分发前先 flush 保序，再分发。
//  ═══════════════════════════════════════════════
//

import Foundation
import Combine
import AppKit

@MainActor
public final class ChatViewModel: ObservableObject {

    // ── 会话数据 ──
    @Published public private(set) var sessions: [ChatSession] = []
    @Published public var currentSessionId: String? { didSet { currentSessionIdChanged(from: oldValue) } }
    @Published public private(set) var messages: [ChatMessage] = []
    @Published public private(set) var models: [OllamaModel] = []
    @Published public var selectedModel: String? { didSet {
        if oldValue != selectedModel, selectedModel != nil { Task { await self.fetchContextLimit() } }
    } }
    @Published public var input: String = ""
    @Published public private(set) var sending = false {
        didSet { refreshChatBusyGuard() }
    }
    @Published public private(set) var bootstrapped = false
    @Published public private(set) var lastError: String?
    @Published public private(set) var agentName: String = ""
    /// 问题1联动：当前对话的归属上下文名（项目名 /「独立 Agent」），顶栏显示用，
    /// 让用户知道自己在跟谁聊（对照现状左栏选中态 + 右栏顶部 agentInfo）。
    @Published public private(set) var contextScope: String = ""
    /// 顶栏上下文全称：「项目名 · Agent名」/「独立 Agent · 名」
    public var contextTitle: String {
        contextScope.isEmpty ? agentName : "\(contextScope) · \(agentName)"
    }

    /// 0.7.6 实测 Bug1 新口径：选中的项目一个 Agent 都没有 —— 不隐式创建；
    /// 会话区空态提示（请在左侧 + 添加）+ 输入禁用（发送链 guard agentId 兜底）。
    public var projectMissingAgent: Bool {
        guard agentId == nil, let pid = projectId else { return false }
        return !pid.hasPrefix(IndependentAgentsPanelViewModel.namespacePrefix)
    }

    // ── 附件暂存区 ──
    @Published public private(set) var pendingItems: [PendingAttachment] = []

    // ── 上下文指示器（M2 / 0.4.34）──
    @Published public private(set) var tokenIndicator = TokenIndicatorState()
    /// B3：后端每轮 state 回传的真实上下文字数（单调守门，checkpoint-109）
    public private(set) var backendCtxChars: Int = 0

    // ── 压缩预警（M2 §8.7）──
    public struct CompactWarning: Equatable { public var used: Int; public var limit: Int; public var est: Int }
    @Published public private(set) var compactWarning: CompactWarning?
    /// 警告条未处理前禁止发送（现状 inputDisabled）
    public var inputDisabled: Bool { compactWarning != nil }

    // ── 断线重连提示条（M5 §8.8）──
    @Published public private(set) var reconnectNotice: String?

    // ── 单元归档开关（0.4.9 3.47.1）──
    @Published public var autoArchiveUnit: Bool = false

    // ── 知识仓库勾选转移（TS-120）──
    @Published public var selectMode: Bool = false
    @Published public private(set) var selectedDbIds: Set<Int> = []
    @Published public var showTransferModal = false
    @Published public var transferScope: String = "project"
    @Published public var transferTitle = ""
    @Published public var transferCategory = ""
    @Published public var transferKeywords = ""
    @Published public private(set) var transferring = false

    // ── 共享服务 ──
    let appState: AppState   // internal：集成测试可读 auth/runtime（@testable）
    private var runtime: NativeRuntime { appState.runtime }
    private var auth: AuthCenter { appState.auth }
    private var logger: AppLogger { appState.logger }
    /// 会话面板扩展端点（Wave 0 协议未含；真实客户端经扩展 conform，测试注入 mock）
    private var chatClient: ChatPanelClient? { runtime.client as? ChatPanelClient }

    public private(set) var projectId: String?
    private var agentId: String?
    private var streamTask: Task<Void, Never>?
    private var runTimerTask: Task<Void, Never>?
    private var waitTimerTask: Task<Void, Never>?
    /// W10（0.7.4，REQ-FUT-003）：等待横幅阶段机——真实信号二阶段
    ///（装载/装填 → 生成；chat SSE 首 token 前无任何事件，无 prefill 细分信号，勿拆）
    @Published public private(set) var waitStage: ChatWaitStage = .loading
    /// W10：首 token 均值预估（秒；nil = 无样本不显示预估，绝不编造）
    @Published public private(set) var waitEstimate: Int?
    /// W10：首 token 耗时样本库（生产 .standard；测试注入隔离 suite）
    private let firstTokenStats: FirstTokenStats
    /// W10：每条流只记一次首 token 耗时（segment 段2 不重复采样防拉偏均值）
    private var firstTokenRecorded = false
    /// 问题1联动：上下文切换防抖任务（select 连写三字段合并为一次切换）
    private var contextSwitchTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var lastDataRoot: String?

    /// REQ-MSG-021：步骤分母真实上限（读配置 max_tool_rounds，回落 200）
    public private(set) var maxToolRounds = 200
    /// M5：重连最大次数（读配置 reconnect_max_attempts，回落 3，校验域 1-10）
    public private(set) var reconnectMaxAttempts = 3
    /// 视觉引导卡：推理后端（ollama 才给「一键拉取 qwen2.5-vl」）
    public private(set) var inferenceBackend = "ollama"

    public init(appState: AppState, firstTokenStats: FirstTokenStats? = nil) {
        self.appState = appState
        self.firstTokenStats = firstTokenStats ?? FirstTokenStats()
        // 纪律①：合帧回调只绑一次，落地目标 = 当前流式消息
        accumulator.onFlush = { [weak self] content, thinking in
            guard let self, let id = self.streamingMessageId else { return }
            self.patchMessage(id) {
                if !content.isEmpty { $0.content += content }
                if !thinking.isEmpty { $0.thinkingPreview = appendThinkingPreview($0.thinkingPreview, delta: thinking) }
            }
        }
        // P3-W6：就绪门 = nativeReady 单信号（恒原生；历史上 status OR nativeReady
        // 双信号——内核接管后侧车失联不再阻塞原生模块，侧车归零后 nativeReady 承接；
        // runtime init 同步点亮，degraded/stopped 失联重置分支随之消亡）。
        appState.runtime.$nativeReady
            .removeDuplicates()
            .sink { [weak self] nativeReady in
                guard let self, nativeReady else { return }
                Task { await self.bootstrap() }
            }
            .store(in: &cancellables)
        // 问题1联动：上下文选择跟随 = AppState 共享态（currentProjectId/currentAgentId
        // 本就是面板间共享的「当前上下文」，这是其设计职责而非总线替身）；
        // agent:updated 资源变更广播已走 NativeAppEvents 总线（0.7.4 W6，见下方订阅）。
        // 独立 Agent / 项目组 / 项目内 Agent 面板写 currentProjectId/currentAgentId 后，
        // 会话面板跟随切换到该上下文（对照现状 App.tsx selectIndependentAgent/selectProject
        // → 右栏 ChatPanel 跟随 activeChatKey 切换的语义）。
        // 防抖 60ms：面板的 select 一次写 project/agent/session 三个字段会连发，
        // 合并成一次切换，避免用「新项目 + 旧 agent」的过渡态组合去拉会话。
        Publishers.CombineLatest(appState.$currentProjectId, appState.$currentAgentId)
            .removeDuplicates(by: { a, b in a.0 == b.0 && a.1 == b.1 })
            .sink { [weak self] _, _ in
                guard let self else { return }
                self.contextSwitchTask?.cancel()
                self.contextSwitchTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    guard let self, !Task.isCancelled else { return }
                    await self.externalContextChanged(projectId: self.appState.currentProjectId,
                                                      agentId: self.appState.currentAgentId)
                }
            }
            .store(in: &cancellables)
        // W6（0.7.4）：订阅 A13 资源总线 agent:updated（两面板行内编辑模型/角色设定
        // 后广播，对齐壳应用 emit('agent:updated') → ChatPanel 刷新 agentInfo 语义）。
        // 只刷新当前对话 Agent 的展示信息；⛔ 上下文切换不走总线（共享选择态留 AppState）。
        agentBusTask = Task { [weak self] in
            for await ev in NativeAppEvents.subscribe() {
                guard let self else { return }
                guard NativeAppEvents.isAgentUpdatedEvent(ev) else { continue }
                let aid = ev.data["agent_id"]?.string
                // 载荷指向别的 Agent → 跳过；载荷缺 agent_id（广播口径）→ 也刷一次（廉价不错过）
                if let aid, aid != self.agentId { continue }
                await self.refreshCurrentAgentInfo()
            }
        }
    }

    deinit { agentBusTask?.cancel(); contextLimitRetryTask?.cancel() }

    /// W6：agent:updated 总线订阅任务（随 VM 销毁取消，订阅者计数不泄漏）。
    private var agentBusTask: Task<Void, Never>?

    /// W6：刷新当前对话 Agent 展示信息（名称；对齐壳应用 agentInfo 重拉）。
    /// 模型/角色设定变更不影响当前流与所选模型（selectedModel 是用户聊天侧选择，不静默改）。
    private func refreshCurrentAgentInfo() async {
        guard let pid = projectId, let aid = agentId else { return }
        if pid.hasPrefix(IndependentAgentsPanelViewModel.namespacePrefix) {
            // 独立 Agent：名称查 /api/independent-agents（adoptContext 同口径）
            if let iaClient = runtime.client as? IndependentAgentsPanelClient,
               let names = try? await iaClient.listIndependentAgents(),
               let name = names.first(where: { $0.id == aid })?.name {
                agentName = name
            }
        } else if let agents = try? await runtime.client.listAgents(projectId: pid),
                  let name = agents.first(where: { $0.id == aid })?.name {
            agentName = name
        }
    }

    // MARK: - 引导：项目 / Agent / 模型 / 配置 / 会话

    private func bootstrap() async {
        guard !bootstrapped else { return }
        let client = runtime.client
        do {
            let modelList = try await client.listModels()
            self.models = modelList
            // 归一化口径（ollama ":latest" 互认，ModelIdentity）：用户的 "qwen3.8"
            // 命中列表 "qwen3.8:latest" → 保留原选择值（不改写配置、不静默换成列表名，
            // 后端可正常解析不带 tag 的名）；真不可用才回退列表第一个。
            // （selectedModel 为 nil/空串时 isAvailable 必为 false → 同样回退，口径不变）
            if !ModelIdentity.isAvailable(selectedModel ?? "", in: modelList.map(\.name)) {
                selectedModel = modelList.first?.name
            }

            // 数据根变更 = 内核实例切换（不同数据）→ 重置项目/Agent 上下文
            // （P3-W6 原生口径：历史上以侧车端口为实例标识——port 变更即换后端；
            // 侧车归零后实例标识 = 数据根路径，runtime 重建即变更）。
            let dataRoot = runtime.dataRootPath
            if lastDataRoot != dataRoot { projectId = nil; agentId = nil }
            lastDataRoot = dataRoot

            // 问题1联动：其他面板已选上下文（独立 Agent / 项目）→ 采纳。
            // 0.7.6 实测 Bug1 新口径：无任何选择时**不播种**——首次安装不预建
            // Pilot 项目组/Agent（项目管理操作不得隐式创建任何项目或 Agent）；
            // RootView 在 currentProjectId==nil 时有「开始对话」引导空态兜底。
            if let extPid = appState.currentProjectId {
                try await adoptContext(projectId: extPid, agentId: appState.currentAgentId)
            }

            // 配置项（REQ-MSG-021 / M5）：校验域与现状一致，非法一律保持回落值
            if let cfg = try? await chatClient?.fetchConfig() {
                if let n = (cfg["reconnect_max_attempts"] as? NSNumber)?.intValue, n >= 1, n <= 10 {
                    reconnectMaxAttempts = n
                }
                if let m = (cfg["max_tool_rounds"] as? NSNumber)?.intValue, m >= 1, m <= 1000 {
                    maxToolRounds = m
                }
            }
            inferenceBackend = (try? await chatClient?.fetchInferenceBackend()) ?? "ollama"
            await fetchContextLimit()

            try await refreshSessions()
            if currentSessionId == nil {
                try await pickInitialSession()
            }
            bootstrapped = true
            lastError = nil
            logger.info("会话面板引导完成：project=\(projectId ?? "-") agent=\(agentId ?? "-")")
        } catch {
            lastError = "初始化失败：\(SidecarError.describe(error))"
            logger.error("会话面板引导失败：\(SidecarError.describe(error))")
        }
    }

    // MARK: - 上下文联动（问题1：上下文选择 = AppState 共享态；agent:updated 资源
    //    变更 0.7.4 W6 起走 NativeAppEvents 总线，见 init 订阅与 refreshCurrentAgentInfo）

    /// 采纳外部选中的上下文（独立 Agent 命名空间 / 项目 [+ Agent]）。
    /// agentId 为 nil（只选了项目）时：优先主 Agent → 列表第一个——「选择」语义
    /// 保留（落已有 Agent 不是创建）。0.7.6 实测 Bug1 新口径：项目一个 Agent 都
    /// 没有时**不创建**——会话区空态提示（projectMissingAgent）+ 输入禁用，
    /// 由用户在左侧 Agent 区显式「+ 添加」（项目管理操作不得隐式创建 Agent）。
    private func adoptContext(projectId pid: String, agentId requestedAid: String?) async throws {
        let client = runtime.client
        var aid = requestedAid
        if pid.hasPrefix(IndependentAgentsPanelViewModel.namespacePrefix) {
            // 独立 Agent：命名空间 ia-<id> 即项目作用域，名称查 /api/independent-agents
            let targetId = aid ?? String(pid.dropFirst(IndependentAgentsPanelViewModel.namespacePrefix.count))
            aid = targetId
            var names: [IndependentAgent] = []
            if let iaClient = client as? IndependentAgentsPanelClient {
                names = (try? await iaClient.listIndependentAgents()) ?? []
            }
            agentName = names.first(where: { $0.id == targetId })?.name ?? ""
            contextScope = "独立 Agent"
        } else {
            let agents = try await client.listAgents(projectId: pid)
            if aid == nil {
                // 只选项目 → 落主 Agent / 列表第一个；空项目 aid 保持 nil（不创建）
                aid = (agents.first(where: { $0.type_ == "main" }) ?? agents.first)?.id
            }
            agentName = agents.first(where: { $0.id == aid })?.name ?? ""
            contextScope = (try? await client.listProjects())?
                .first(where: { $0.id == pid })?.name ?? ""
        }
        projectId = pid
        agentId = aid
        // 回写规范化后的 agentId（只选项目时补上的主 Agent）；等值 guard 防 sink 回环
        if let aid, appState.currentAgentId != aid { appState.currentAgentId = aid }
    }

    /// AppState 选中变化（其他面板写入）→ 跟随切换。等值 / 未引导 / 未就绪时不动作。
    private func externalContextChanged(projectId pid: String?, agentId aid: String?) async {
        guard bootstrapped, runtime.nativeReady else { return }
        if pid == nil {
            // 外部清空了选择（删除当前 agent/项目的「杜绝幽灵」收敛，
            // checkpoint-056/061）→ 只清会话上下文，绝不回落 pilot 播种复活
            //（0.7.6 实测 Bug1：删除后 ensurePilotContext 立刻复活「VetarAI」
            // 项目组 + Pilot Agent，业主判定为 bug 已拔除）；RootView 在
            // currentProjectId==nil 时有「开始对话」引导空态兜底。
            await switchContext(projectId: nil, agentId: nil)
            return
        }
        guard pid != projectId || aid != agentId else { return }
        await switchContext(projectId: pid, agentId: aid)
    }

    /// 切换对话上下文：复位会话/消息/指示器 → 采纳新上下文 → 拉会话列表
    /// （U2：优先选中 AppState 指定的目标会话，否则首个或新建，见 pickInitialSession）。
    /// 进行中的流不硬停（对齐现状保活语义）：只脱离 UI 落点，后续事件自然 no-op。
    private func switchContext(projectId pid: String?, agentId aid: String?) async {
        // 0.7.8 实测 Bug1：切走 ≠ 丢弃——带活流的会话整包 stash（气泡/流 id/后端真值/
        // 断点），流在后台继续推进（事件经 apply 分流进 stash），切回时瞬装回；
        // 无活流才走原复位。旧实现无条件清 streamingMessageId/streamingSessionId +
        // messages=[]，切回再被 DB 快照（assistant 回复 done 才落库，库里只有用户
        // 消息）整体覆盖 → 只剩 1 条消息（DBG-089 H16 + checkpoint-055 同症）。
        if sending, let oldSid = streamingSessionId {
            stashLiveStream(into: oldSid)
        } else {
            if sending { sending = false; stopTimers() }
            streamingMessageId = nil
            streamingSessionId = nil
        }
        reconnectNotice = nil
        compactWarning = nil
        messages = []
        sessions = []
        backendCtxChars = 0
        tokenIndicator = TokenIndicatorState()
        contextLimitRetryTask?.cancel()   // 补充二：失败重试随上下文复位重新计周期
        contextLimitRetryAttempt = 0
        currentSessionId = nil
        do {
            if let pid {
                try await adoptContext(projectId: pid, agentId: aid)
            } else {
                // 0.7.6 实测 Bug1：外部清空 → 只清上下文（不回落 pilot 默认上下文，
                // 不创建任何项目/Agent）
                projectId = nil
                agentId = nil
                agentName = ""
                contextScope = ""
            }
            try await refreshSessions()
            try await pickInitialSession()
            await fetchContextLimit()
            lastError = nil
            logger.info("会话上下文已切换：project=\(projectId ?? "-") agent=\(agentId ?? "-")")
        } catch {
            lastError = "切换上下文失败：\(SidecarError.describe(error))"
            logger.error("切换上下文失败：\(SidecarError.describe(error))")
        }
    }

    /// U2：切换/引导后的会话落点——优先采纳 AppState.currentSessionId 指定的目标会话。
    /// 任务队列跳转（TaskPanelViewModel.jumpToAgent 写入，对齐 ChatPanel.tsx:1161-1176
    /// jumpToSessionId 消费语义）与「返回应用恢复上次会话」都经此定位；
    /// 目标不在新列表（已删除 / 跨上下文残留）则回落列表首个，空列表新建「会话 1」。
    private func pickInitialSession() async throws {
        if let target = appState.currentSessionId,
           sessions.contains(where: { $0.id == target }) {
            currentSessionId = target
        } else if let first = sessions.first {
            currentSessionId = first.id
        } else {
            _ = try await createSession(title: "会话 1")
        }
    }

    // MARK: - 会话列表管理

    public func refreshSessions() async throws {
        guard let pid = projectId, let aid = agentId else { return }
        let client = runtime.client
        sessions = try await client.listSessions(projectId: pid, agentId: aid)
    }

    @discardableResult
    public func createSession(title: String? = nil) async throws -> String? {
        guard let pid = projectId, let aid = agentId else { return nil }
        let client = runtime.client
        let t = title ?? "会话 \(sessions.count + 1)"
        let sid = try await client.createSession(projectId: pid, agentId: aid, title: t)
        try await refreshSessions()
        currentSessionId = sid
        return sid
    }

    /// 删除会话（现状 handleDeleteSession：确认 → DELETE → 切剩余第一个）
    public func deleteSession(_ sid: String) async {
        let ok = await DialogCenter.shared.confirm(
            title: "删除会话", message: "确定删除此会话？所有消息将永久清除。",
            confirmText: "删除", danger: true)
        guard ok else { return }
        do {
            try await chatClient?.deleteSession(projectId: projectId ?? "", sessionId: sid)
            sessions.removeAll { $0.id == sid }
            if currentSessionId == sid {
                currentSessionId = nil
                messages = []
                if let first = sessions.first { currentSessionId = first.id }
            }
        } catch {
            logger.error("删除会话失败：\(SidecarError.describe(error))")
            ToastCenter.shared.show("删除失败：\(SidecarError.describe(error))", kind: .error)
        }
    }

    /// 重命名会话（现状 handleRenameSession：prompt 弹窗 → PUT）
    public func renameSession(_ sid: String) async {
        let newTitle = await DialogCenter.shared.prompt(
            title: "重命名会话", defaultValue: "未命名会话", confirmText: "保存", cancelText: "取消")
        guard let newTitle else { return }
        do {
            try await chatClient?.renameSession(projectId: projectId ?? "", sessionId: sid, title: newTitle)
            if let idx = sessions.firstIndex(where: { $0.id == sid }) {
                let s = sessions[idx]
                sessions[idx] = ChatSession(id: s.id, title: newTitle, message_count: s.message_count)
            }
        } catch {
            logger.error("重命名失败：\(SidecarError.describe(error))")
            ToastCenter.shared.show("重命名失败：\(SidecarError.describe(error))", kind: .error)
        }
    }

    /// 切换会话（checkpoint-055：DB 为权威源；B3：非活流切换复位后端真值）
    public func switchSession(_ sid: String) {
        guard sid != currentSessionId else { return }
        currentSessionId = sid
    }

    private func currentSessionIdChanged(from oldSid: String?) {
        // 0.7.8 实测 Bug1：离开带活流的旧会话 → 整包 stash（不丢进行中的气泡）。
        //（switchContext 已先 stash 再置 nil，走到这时 sending 已 false，不会二次 stash。）
        if let oldSid, oldSid != currentSessionId,
           sending, streamingSessionId == oldSid {
            stashLiveStream(into: oldSid)
        }
        guard let sid = currentSessionId, let pid = projectId else {
            if currentSessionId == nil { messages = [] }
            return
        }
        let client = runtime.client
        appState.currentSessionId = sid
        if let stash = backgroundStreams.removeValue(forKey: sid) {
            // 切回活流会话：瞬装回 stash（用户立刻看到进行中的气泡与真实进度），
            // 随后仍发一次 DB 权威合并加载对齐落库真值（见 reloadMessagesMerging）。
            messages = stash.messages
            streamingMessageId = stash.streamingMessageId
            streamingSessionId = sid
            backendCtxChars = stash.backendCtxChars
            lastBreakAt = stash.lastBreakAt
            sending = true
            startRunElapsedTimer()
            // 等待横幅：气泡仍空（无正文无步骤）→ 重新起等待计时，否则定「生成中」
            let cur = messages.first(where: { $0.id == stash.streamingMessageId })
            if (cur?.content.isEmpty ?? true) && (cur?.toolSteps.isEmpty ?? true) {
                waitStage = .loading
                startWaitTimer()
            } else {
                waitStage = .generating
            }
            restoreTokenIndicator()
        } else {
            messages = []
            // B3：切会话复位后端真值（活流会话除外——stash 分支已装回真值）
            if streamingSessionId != sid { backendCtxChars = 0 }
        }
        // 0.7.8 实测 Bug1：加载收口 = DB 权威 + 合并本地未落盘流式气泡
        //（checkpoint-055/H16 mergeDbWithLocal；旧实现 DB 快照整体覆盖丢进行中气泡）
        Task { await self.reloadMessagesMerging(sid: sid, pid: pid, client: client) }
    }

    /// 0.7.8 实测 Bug1：把当前活流整包收进后台暂存（切走当前会话/上下文时调用）。
    /// 先 flush 合帧缓冲（不丢挂起增量）再整包 stash；live 槽复位（sending=false +
    /// 停计时器 + 流 id/后端真值/断点清零）——此后该流的事件经 apply 分流进 stash，
    /// 不再触碰当前视图（Bug2a 指示器回写防护的同一条管道）。
    private func stashLiveStream(into sid: String) {
        accumulator.flush()
        if let mid = streamingMessageId {
            backgroundStreams[sid] = BackgroundStream(
                messages: messages, streamingMessageId: mid,
                backendCtxChars: backendCtxChars, lastBreakAt: lastBreakAt)
        }
        sending = false
        stopTimers()
        streamingMessageId = nil
        streamingSessionId = nil
        backendCtxChars = 0
        lastBreakAt = -1
    }

    /// F2（0.7.12 实测修复）：chat 流式登记 busy 源——Cmd+Q/关窗忙守此前对
    /// 「正在生成回复」完全失效（BusySource 只有 workflow/roundtable 两源，
    /// chat 从未登记，生成中退出无确认直接杀进程）。
    /// 登记口径 = 本进程仍有活流：当前视图在发（sending）或切走的后台 stash 流
    /// 非空（backgroundStreams——切走不拦但退出仍要拦，退出即杀所有活流）。
    /// report 幂等，重复调用无副作用。
    private func refreshChatBusyGuard() {
        appState.busyGuard.report(.chat, isBusy: sending || !backgroundStreams.isEmpty)
    }

    /// 0.7.8 实测 Bug1：加载收口——拉 DB 后按 mergeDbWithLocal 合并（live 会话原样
    /// 保留流式气泡；非 live 僵尸清理），过期结果不得覆盖新会话（查虫D 守门保留）。
    private func reloadMessagesMerging(sid: String, pid: String,
                                       client: SidecarClientProtocol) async {
        do {
            let loaded = try await client.loadMessages(projectId: pid, sessionId: sid)
            guard self.currentSessionId == sid else { return }
            let live = self.sending && self.streamingSessionId == sid
            self.messages = mergeDbWithLocal(db: loaded, local: self.messages, live: live)
            self.restoreTokenIndicator()
            // 后台流期间收到的 compact_required：切回时重放警告条（三选一不丢）
            if let cw = self.pendingCompactBySession.removeValue(forKey: sid) {
                self.compactWarning = cw
            }
        } catch {
            self.lastError = "加载消息失败：\(SidecarError.describe(error))"
        }
    }

    // MARK: - 上下文指示器

    /// M2：拉上下文上限（/api/context/limit；model 缺省取当前选中模型）
    public func fetchContextLimit() async {
        guard let model = selectedModel, let cc = chatClient else { return }
        if let info = try? await cc.fetchContextLimit(model: model) {
            if info.limit == 0 && info.source == "error" {
                // 补充二（0.7.6 实测）：活动后端暂不可达是启动早期暂态——不上屏
                // 「上下文：获取失败」红字（保前值/空态隐藏），静默有界重试，
                // 就绪后自然显示真值；错误态与成功态切换干净（失败永不落屏）。
                scheduleContextLimitRetry()
                return
            }
            contextLimitRetryTask?.cancel()
            contextLimitRetryAttempt = 0
            tokenIndicator.limit = info.limit
            tokenIndicator.source = info.source
            tokenIndicator.ceiling = info.ceiling
        }
    }

    /// 补充二：失败重试任务与计数（切换上下文时随 tokenIndicator 一并复位）。
    private var contextLimitRetryTask: Task<Void, Never>?
    private var contextLimitRetryAttempt = 0
    /// 重试间隔（生产 2s × 最多 5 次 ≈ 10s 窗口覆盖后端启动；测试注入缩短）
    internal var contextLimitRetryInterval: TimeInterval = 2
    private static let contextLimitRetryMaxAttempts = 5

    /// 静默重试：指数无必要（固定间隔即可），超上限停止——指示器保持隐藏，
    /// 与「unsupported 前端隐藏指示器」同口径（不瞎兜底、不上屏红字）。
    private func scheduleContextLimitRetry() {
        contextLimitRetryAttempt += 1
        guard contextLimitRetryAttempt <= Self.contextLimitRetryMaxAttempts else { return }
        let delay = contextLimitRetryInterval
        contextLimitRetryTask?.cancel()
        contextLimitRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            await self.fetchContextLimit()
        }
    }

    /// H17/问题4 + 0.7.8 实测 Bug2b：恢复指示器——取估算与 DB 已持久化
    /// prompt_eval_count 的**较大者**。二者皆下界：est 按消息文本 ×0.6 漏算系统
    /// 提示词/工具规格/注入段（偏低——Bug2 恢复态 246 即此）；pec 是上一轮真实
    /// prompt tokens 但含 KV 复用（亦可能偏低）。取大者不编造。
    /// pec 仅在无已归档消息时采用：归档后 pec 是归档前的旧真值（偏高），
    /// 而 est 已跳过 archived（归档扣减走 ctxTokensAfterArchive 显式路径）。
    private func restoreTokenIndicator() {
        let est = estimateContextTokens(messages: messages, backendCtxChars: backendCtxChars)
        let hasArchived = messages.contains { $0.archived }
        var pec = 0
        if !hasArchived {
            for m in messages.reversed() {
                if let v = m.promptEvalCount, v > 0 { pec = v; break }
            }
        }
        tokenIndicator.used = max(est, pec)
    }

    /// 消息变化后重估（发送/归档/切换/落盘）
    private func refreshTokenEstimate() {
        let est = estimateContextTokens(messages: messages, backendCtxChars: backendCtxChars)
        if est > 0 { tokenIndicator.used = est }
    }

    // MARK: - 附件暂存区

    /// P3-W3b 语音转写上屏（VoiceInputController 回调）：转写文本追加进输入框——
    /// 已有内容且末尾非空白则补一个空格拼接（说话→文字上屏→可编辑→发送）。
    public func insertTranscribedText(_ text: String) {
        if !input.isEmpty, let last = input.last, !last.isWhitespace {
            input += " "
        }
        input += text
    }

    /// 文件选择（NSOpenPanel 回调进来；图片读 dataURI，文档读 base64 后走解析端点）。
    public func addFiles(_ urls: [URL]) {
        for url in urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            let name = url.lastPathComponent
            let ext = url.pathExtension.lowercased()
            let isImage = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "heic"].contains(ext)
            let mime = isImage ? "image/\(ext == "jpg" ? "jpeg" : ext)" : "application/octet-stream"
            let dataURI = "data:\(mime);base64,\(data.base64EncodedString())"
            let item = PendingAttachment(name: name, kind: isImage ? .image : .file,
                                         size: data.count, dataURI: dataURI)
            pendingItems.append(item)
            if !isImage { Task { await parsePendingFile(item) } }
        }
    }

    /// 粘贴图片（截图/复制图片 → dataURI）
    public func addPastedImages(_ images: [NSImage]) {
        for (i, img) in images.enumerated() {
            guard let tiff = img.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { continue }
            let name = "粘贴图片-\(Int(Date().timeIntervalSince1970))-\(i + 1).png"
            pendingItems.append(PendingAttachment(
                name: name, kind: .image, size: png.count,
                dataURI: "data:image/png;base64,\(png.base64EncodedString())")
            )
        }
    }

    /// checkpoint-048 / C3：非图片一律交后端裁决（text=null →「（仅文件名）」）；
    /// C7：带 project/session 归属 → 落盘并回传 savedPath（拉模式正文注入用）。
    private func parsePendingFile(_ item: PendingAttachment) async {
        guard let cc = chatClient else { return }
        patchPending(item.id) { $0.parsing = true }
        let b64 = String(item.dataURI.split(separator: ",").last ?? "")
        do {
            let r = try await cc.parseAttachment(name: item.name, contentBase64: b64,
                                                 projectId: projectId ?? "",
                                                 sessionId: currentSessionId ?? "")
            patchPending(item.id) {
                $0.parsing = false
                $0.parsedText = r.text
                $0.parseFailed = r.text == nil
                $0.savedPath = r.savedPath
            }
        } catch {
            patchPending(item.id) { $0.parsing = false; $0.parseFailed = true }
            logger.warn("附件解析失败（\(item.name)）：\(SidecarError.describe(error))")
        }
    }

    public func removePending(_ id: String) {
        pendingItems.removeAll { $0.id == id }
    }

    private func patchPending(_ id: String, _ mutate: (inout PendingAttachment) -> Void) {
        guard let idx = pendingItems.firstIndex(where: { $0.id == id }) else { return }
        mutate(&pendingItems[idx])
    }

    // MARK: - 发送（A5 注入 / B13 显式文本 / 附件组装）

    /// 发送按钮 / 回车入口。explicitText 供程序化重发（压缩续发等）——
    /// 不依赖 input state（B13 0.4.22：异步回调闭包捕获的是旧 input）。
    public func send(explicitText: String? = nil) {
        // A5：思考中点发送 → 走「插入新消息」，不打断当前轮
        if sending { inject(); return }
        let src = explicitText ?? input
        let hasText = hasSendableText(src)
        let contentText = normalizeInputText(src).trimmingCharacters(in: .whitespacesAndNewlines)
        let imageItems = pendingItems.filter { $0.kind == .image }
        let fileItems = pendingItems.filter { $0.kind == .file }
        guard hasText || !pendingItems.isEmpty else { return }

        if currentSessionId == nil {
            Task { _ = try? await createSession() }
            return
        }
        guard runtime.nativeReady,
              let sid = currentSessionId, let pid = projectId, let aid = agentId,
              let model = selectedModel else { return }
        let client = runtime.client

        input = ""
        pendingItems = []

        // 用户气泡（现状 parts 组装口径）
        let bubbleText = AttachmentComposer.userBubbleText(
            text: contentText, hasText: hasText,
            imageCount: imageItems.count, fileNames: fileItems.map { $0.name })
        var userMsg = ChatMessage(id: LocalMessageID.next(), role: "user", content: bubbleText)
        userMsg.images = imageItems.map { $0.dataURI }
        messages.append(userMsg)

        // 占位 assistant 气泡（流式累加用；maxStep 直接用配置上限，REQ-MSG-021）
        let assistantId = LocalMessageID.next()
        var assistantMsg = ChatMessage(id: assistantId, role: "assistant", content: "",
                                       modelUsed: model)
        assistantMsg.step = 0
        assistantMsg.maxStep = maxToolRounds
        assistantMsg.startedAt = Date().timeIntervalSince1970
        assistantMsg.isStreaming = true
        messages.append(assistantMsg)
        streamingMessageId = assistantId
        streamingSessionId = sid
        sending = true
        lastError = nil

        // 历史（TS-120：已归档不进模型上下文；不含刚追加的占位气泡）
        var history = messages.dropLast()
            .filter { ($0.role == "user" || $0.role == "assistant") && !$0.archived }
            .map { ChatStreamMessage(role: $0.role, content: $0.content) }
        // 附件正文注入（表#6 拉模式 / R-2 退化全额注入；ATTACH_MARK 分隔）
        let sections = AttachmentComposer.injectionSections(files: fileItems)
        if !sections.isEmpty, !history.isEmpty {
            let last = history.removeLast()
            history.append(ChatStreamMessage(
                role: last.role,
                content: AttachmentComposer.appendInjection(toContent: last.content, sections: sections)))
        }

        startStream(client: client, request: ChatStreamRequest(
            agent_id: aid, model: model, messages: history,
            images: imageItems.isEmpty ? nil : imageItems.map { $0.dataURI },
            project_id: pid, session_id: sid,
            // 0.7.8 实测 Bug3：⛔ 不再前端硬编码 <数据根>/pilot-sandbox——面板模型
            // SidecarProject 无 working_dir，前端无权也无力解析工作目录；传 nil 交端点
            // _resolve_sandbox_root 按 project_id+agent_id 解析（项目 → projects.working_dir，
            // 独立 Agent → 其注册目录下 sandbox），委派子会话经 routeDelegate 继承同一锚点。
            // 旧 Electron 线前端本就不传该字段（ChatPanel.tsx 无 sandbox_root），
            // pilot-sandbox 恒真是原生线移植时引入的回归，且该目录位于 ~/.subagent
            // 敏感域内（is_sensitive_path），写入必触发授权拦截。
            sandbox_root: nil,
            auto_archive_unit: autoArchiveUnit
        ))
    }

    /// A5（0.4.16）：思考中插入新消息（乐观追加用户气泡 → POST /inject；无活流则 toast 如实告知）
    public func inject() {
        let text = normalizeInputText(input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasSendableText(input), let sid = streamingSessionId ?? currentSessionId else { return }
        messages.append(ChatMessage(id: LocalMessageID.next(), role: "user", content: text))
        input = ""
        Task {
            guard let cc = chatClient else { return }
            do {
                let r = try await cc.injectMessage(projectId: projectId ?? "", agentId: agentId ?? "",
                                                   sessionId: sid, content: text)
                if !r.ok {
                    // A-3（0.4.23）：toast 不归流生命周期管，能稳定显示
                    ToastCenter.shared.show(r.detail ?? "当前没有进行中的生成，请直接发送")
                }
            } catch {
                logger.error("注入失败：\(SidecarError.describe(error))")
            }
        }
    }

    /// M5/手动重发：回填上一条 user 消息到输入框（现状 resendLast）
    public func resendLast() {
        if let lastUser = messages.last(where: { $0.role == "user" }) {
            input = lastUser.content
        }
    }

    /// B13：显式 content 重发（压缩续发）；流在进行 → 注入，否则正常发送
    public func resendWithContent(_ content: String) {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if sending {
            let sid = streamingSessionId ?? currentSessionId
            guard let sid else { return }
            messages.append(ChatMessage(id: LocalMessageID.next(), role: "user", content: text))
            Task {
                _ = try? await chatClient?.injectMessage(projectId: projectId ?? "",
                                                         agentId: agentId ?? "",
                                                         sessionId: sid, content: text)
            }
        } else {
            send(explicitText: text)
        }
    }

    /// U3：知识仓库注入（对齐 ChatPanel.tsx:3158-3162 onInject）——
    /// 勾选条目拼好的文本追加进输入框（已有内容空两行拼接），Toast 提示确认后发送；
    /// 不直接发送（拉模式铁律：内容进不出上下文由用户把关）。
    public func injectKnowledgeText(_ text: String) {
        input = input.isEmpty ? text : input + "\n\n" + text
        ToastCenter.shared.show("知识已注入输入框，确认后发送", kind: .success)
    }

    // MARK: - 流式主循环（M5 重连退避）

    private var streamingSessionId: String?   // 活流归属会话（checkpoint-059）
    private var lastBreakAt = -1              // #1：最近 segment_break 断点（-1 = 未分裂）

    /// 0.7.8 实测 Bug1/Bug2：后台流暂存——切走带活流的会话时整包收下（气泡数组/
    /// 流式气泡 id/后端真值/segment 断点），流在后台继续推进；切回时瞬装回。
    private struct BackgroundStream {
        var messages: [ChatMessage]
        var streamingMessageId: String
        var backendCtxChars: Int
        var lastBreakAt: Int
    }
    private var backgroundStreams: [String: BackgroundStream] = [:]   // key = sessionId
    /// 后台流期间收到的 compact_required（切回该会话时重放警告条）
    private var pendingCompactBySession: [String: CompactWarning] = [:]

    private func startStream(client: SidecarClientProtocol, request: ChatStreamRequest) {
        let assistantId = streamingMessageId!
        let streamSid = request.session_id   // 0.7.8 Bug1：流归属会话冻结捕获——
        // 闭包内事件一律按 streamSid 分流（live 走 UI / 后台走 stash），绝不读时刻态
        lastBreakAt = -1
        startRunElapsedTimer()
        startWaitTimer()
        // W10（REQ-FUT-003）：等待阶段机复位 + 预估（有样本才显示，无样本 nil 不编造）
        waitStage = .loading
        waitEstimate = firstTokenStats.estimate(for: request.model)
        firstTokenRecorded = false

        streamTask = Task { [weak self] in
            guard let self else { return }
            var attempt = 0
            var usedSkipPersist = false
            var req = request
            streamLoop: while true {
                do {
                    if usedSkipPersist {
                        req = ChatStreamRequest(
                            agent_id: req.agent_id, model: req.model, messages: req.messages,
                            images: req.images, project_id: req.project_id, session_id: req.session_id,
                            skip_user_persist: true, sandbox_root: req.sandbox_root,
                            auto_archive_unit: req.auto_archive_unit)
                    }
                    for try await ev in client.chatStream(req) {
                        if Task.isCancelled { break streamLoop }
                        self.apply(ev, to: assistantId, streamSid: streamSid)
                        if ev.isTerminalEvent { break streamLoop }
                        // compact_required 现状口径：事件后流即结束（loop 已暂停，无 done）
                        if ev.kind == .compactRequired { break streamLoop }
                    }
                    break streamLoop
                } catch {
                    if Task.isCancelled { break streamLoop }
                    // M5 错误分类：业务错误立即终止；网络/5xx/流中断走重连
                    if ReconnectPolicy.isBusinessError(error) || attempt >= self.reconnectMaxAttempts {
                        let isBusiness = ReconnectPolicy.isBusinessError(error)
                        self.accumulator.flush()
                        // Bug1：错误落点按归属分流——后台流写 stash 气泡，不碰当前视图
                        self.patchMessage(assistantId, in: streamSid) {
                            $0.streamError = isBusiness
                                ? SidecarError.describe(error)
                                : ReconnectPolicy.exhaustedMessage(attempt: attempt,
                                                                   detail: SidecarError.describe(error))
                            $0.errorKind = isBusiness ? "business" : "network"
                            $0.thinkingActive = false
                        }
                        if self.streamingSessionId == streamSid { self.reconnectNotice = nil }
                        break streamLoop
                    }
                    attempt += 1
                    usedSkipPersist = true
                    let backoff = ReconnectPolicy.backoffNanos(attempt: attempt)
                    // 重连提示条只上 live 视图（后台流静默重连，不打扰当前看的会话）
                    if self.streamingSessionId == streamSid {
                        self.reconnectNotice = ReconnectPolicy.notice(attempt: attempt,
                                                                      maxAttempts: self.reconnectMaxAttempts)
                    }
                    try? await Task.sleep(nanoseconds: backoff)
                    if Task.isCancelled { break streamLoop }
                }
            }
            self.finishStream(assistantId, sid: streamSid)
        }
    }

    /// 停止按钮。
    /// 纪律②：先通知后端真停（POST /chat/{sid}/stop），再断本地流 —— 顺序不可颠倒，
    /// 否则后端 loop 空跑、在飞请求不被硬取消（对齐 ChatPanel.handleStop）。
    public func stop() {
        guard sending else { return }
        let sid = streamingSessionId ?? currentSessionId
        if let sid {
            let client = runtime.client
            Task.detached { try? await client.stopChat(sessionId: sid) }   // ① 先 POST 真停
        }
        streamTask?.cancel()                                                // ② 再断本地流
        applyUserStopped()
    }

    /// C2/C6：「用户手动停止」收敛（三处调用点共享：stop 按钮 / cancelled 事件 / 断流取消）。
    private func applyUserStopped() {
        accumulator.flush()
        guard let id = streamingMessageId ?? messages.last(where: { $0.isStreaming })?.id else {
            sending = false
            return
        }
        patchMessage(id) {
            $0.manuallyStopped = true
            $0.isStreaming = false
            $0.thinkingActive = false
            $0.thinkingElapsed = nil
            $0.waitingSeconds = 0
            // C2 根因③：停止时 running 工具收敛为 interrupted（不谎称成功/失败）
            $0.toolSteps = convergeRunningSteps($0.toolSteps)
        }
        sending = false
        stopTimers()
    }

    // MARK: - SSE 事件分发（对应 ChatPanel.tsx applyEvent）

    /// 纪律①载体：token/thinking 增量缓冲合帧器（15fps）。
    private let accumulator = StreamAccumulator(fps: 15)
    /// 当前流式消息 id（accumulator 合帧回调的落点；segment_break 分裂时重指向）。
    internal var streamingMessageId: String?

    /// 0.7.8 实测 Bug1/Bug2：事件按归属会话（streamSid，startStream 闭包冻结捕获）分流——
    /// live（正在看的会话）走原逻辑；后台流（切走的会话）写 stash 气泡，
    /// ⛔ 绝不碰 live 槽/计时器/指示器（Bug2a 孤儿流 ctx_chars 回写防护就在 state 分支）。
    internal func apply(_ ev: SSEEvent, to assistantId: String, streamSid: String) {
        let isLive = streamingSessionId == streamSid && streamingMessageId != nil
        // 事件落点跟随 sink 内的 streamingMessageId（segment_break 分裂后重指向段2，
        // 对齐现状 patchStreamMsg 捕获「变量绑定」而非值的语义）
        let targetId = isLive
            ? (streamingMessageId ?? assistantId)
            : (backgroundStreams[streamSid]?.streamingMessageId ?? assistantId)
        let sink = isLive ? nil : streamSid   // patchMessage 的 in: 参数（nil = live messages）
        switch ev.kind {
        case .token:
            if isLive {
                // H19：首个正文 token 到达 → 停等待计时（thinking/tool_call 不算正文）
                stopWaitTimer()
                // W10（REQ-FUT-003）：首个正文 token → 记「发起→首 token」耗时样本
                //（按模型分键；每条流只记一次，segment 段2 不重采样）
                if !firstTokenRecorded {
                    firstTokenRecorded = true
                    let msg = messages.first(where: { $0.id == targetId })
                    if let started = msg?.startedAt, let model = msg?.modelUsed ?? selectedModel {
                        firstTokenStats.record(
                            model: model, seconds: max(0, Int(Date().timeIntervalSince1970 - started)))
                    }
                }
                if let id = streamingMessageId,
                   messages.first(where: { $0.id == id })?.waitingSeconds ?? 0 > 0 {
                    patchMessage(id) { $0.waitingSeconds = 0 }
                }
                closeThinkingPhase()
                // 纪律①：增量不直接写 UI，入缓冲器等合帧
                accumulator.append(content: ev.string("delta") ?? "")
            } else {
                // 后台：直写 stash 气泡（不进 accumulator——其合帧落点是 live 气泡）；
                // 不采样首 token（样本库是 UI 等待预估口径，后台流不打扰）
                patchMessage(targetId, in: sink) { $0.content += ev.string("delta") ?? "" }
            }
        case .thinking:
            if isLive {
                // W10：thinking delta = prefill 完成、生成开始的真实信号 → 阶段翻「生成中」
                waitStage = .generating
                startThinkingPhase()
                accumulator.append(thinking: ev.string("delta") ?? "")
            } else {
                patchMessage(targetId, in: sink) {
                    $0.thinkingPreview = appendThinkingPreview($0.thinkingPreview,
                                                               delta: ev.string("delta") ?? "")
                }
            }
        case .toolCall:
            if isLive { accumulator.flush(); closeThinkingPhase() }   // 纪律③：先保序 flush，再分发
            patchMessage(targetId, in: sink) {
                $0.toolSteps.append(ToolStep(
                    id: ev.string("id") ?? UUID().uuidString,
                    name: ev.string("name") ?? "tool",
                    argsText: (ev.data["args"] as? [String: Any])
                        .flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.prettyPrinted]) }
                        .flatMap { String(data: $0, encoding: .utf8) }
                ))
            }
        case .toolResult:
            if isLive { accumulator.flush() }
            let stepId = ev.string("id") ?? ""
            patchMessage(targetId, in: sink) {
                guard let idx = $0.toolSteps.firstIndex(where: { $0.id == stepId }) else { return }
                $0.toolSteps[idx].status = (ev.bool("ok") ?? true) ? .ok : .error
                $0.toolSteps[idx].summary = ev.string("summary")
                $0.toolSteps[idx].error = ev.string("error")
            }
        case .state:
            // B3/checkpoint-109：ctx_chars 单调守门——重连会让旧值晚到，取大者；
            // 真实减少只走显式路径（归档扣减/压缩/切会话复位）
            if let chars = ev.int("ctx_chars"), chars > 0 {
                if isLive {
                    backendCtxChars = max(backendCtxChars, chars)
                    tokenIndicator.used = max(tokenIndicator.used,
                                              Int((Double(backendCtxChars) * 0.6).rounded()))
                } else if var stash = backgroundStreams[streamSid] {
                    // 0.7.8 实测 Bug2a：后台流的真值只进 stash（切回时恢复），
                    // 绝不回写当前视图指示器（消失态 5345 即孤儿流回写所致）
                    stash.backendCtxChars = max(stash.backendCtxChars, chars)
                    backgroundStreams[streamSid] = stash
                }
            }
            patchMessage(targetId, in: sink) {
                $0.step = ev.int("step")
                $0.maxStep = ev.int("max") ?? $0.maxStep
                $0.tokensUsed = ev.int("tokens_used")
                if let pec = ev.int("prompt_eval_count") { $0.promptEvalCount = pec }
            }
        case .done:
            // message_count +2（冻结归属会话 streamSid；后台流的会话多半不在当前列表 → no-op）
            if let idx = sessions.firstIndex(where: { $0.id == streamSid }) {
                let s = sessions[idx]
                sessions[idx] = ChatSession(id: s.id, title: s.title,
                                            message_count: (s.message_count ?? 0) + 2)
            }
            if isLive {
                accumulator.flush()
                closeThinkingPhase()
                patchMessage(targetId) {
                    if let full = ev.string("content") {
                        // #1：done.content 是全文；分裂后只取 [break_at:]
                        $0.content = SegmentBreakLogic.doneContent(full: full, breakAt: self.lastBreakAt)
                    }
                    $0.thinkingActive = false
                    $0.thinkingElapsed = nil
                    $0.isStreaming = false
                    // checkpoint-109：done 兜底收敛 running（重连丢 tool_result 的场景）
                    $0.toolSteps = convergeRunningSteps($0.toolSteps)
                    if let started = $0.startedAt {
                        $0.completedDuration = Int(Date().timeIntervalSince1970 - started)
                    }
                }
                // R3（0.4.33）：流式完成顺手重拉上限（懒加载升档后「当前档」才实时）
                Task { await self.fetchContextLimit() }
            }
            // 后台 done：DB 已持久化（persistAssistant 先于 done 发出），stash 由
            // finishStream 丢弃，切回走 DB 权威合并加载——气泡不必再修
        case .error:
            if isLive {
                accumulator.flush()
                closeThinkingPhase()
                patchMessage(targetId) {
                    $0.streamError = ev.string("detail") ?? "生成出错"
                    // 0.4.9 任务161：后端报错分析（人话诊断 + 用的哪个模型）
                    if let a = ev.string("analysis"), !a.isEmpty { $0.errorAnalysis = a }
                    if let am = ev.string("analysis_model"), !am.isEmpty { $0.errorAnalysisModel = am }
                    $0.thinkingActive = false
                    $0.thinkingElapsed = nil
                    $0.isStreaming = false
                    if let started = $0.startedAt {
                        $0.completedDuration = Int(Date().timeIntervalSince1970 - started)
                    }
                }
            }
            // 后台 error：终态 → finishStream 丢 stash，切回走 DB 权威（同 done 口径）
        case .cancelled:
            // C2（0.4.16）：后端确认已停止，语义与手动停止完全一致，复用同一收敛
            if isLive {
                accumulator.flush()
                applyUserStopped()
            }
            // 后台 cancelled：DB 已落 stopped 定稿，stash 由 finishStream 丢弃
        case .segmentBreak:
            applySegmentBreak(ev, frozenId: assistantId, in: streamSid)
        case .compactRequired:
            if isLive {
                accumulator.flush()
                closeThinkingPhase()
                // 现状口径：警告条三选一 + 输入禁用；流随之结束（无 done）
                compactWarning = CompactWarning(used: ev.int("used") ?? 0,
                                                limit: ev.int("limit") ?? 0,
                                                est: ev.int("est_rounds_left") ?? -1)
                patchMessage(targetId) {
                    $0.isStreaming = false
                    $0.toolSteps = convergeRunningSteps($0.toolSteps)
                }
            } else {
                // 后台：警告条记 pending（切回时经 reloadMessagesMerging 重放，不丢三选一）；
                // stash 气泡收敛；流随后终止 → finishStream 丢 stash
                pendingCompactBySession[streamSid] = CompactWarning(used: ev.int("used") ?? 0,
                                                                    limit: ev.int("limit") ?? 0,
                                                                    est: ev.int("est_rounds_left") ?? -1)
                patchMessage(targetId, in: sink) {
                    $0.isStreaming = false
                    $0.toolSteps = convergeRunningSteps($0.toolSteps)
                }
            }
        case .compactAuto:
            if isLive { accumulator.flush() }
            // 契约差异记录：现状前端对 compact_auto **无分支**（服务端 app.py 闭环压缩，
            // 事件转发给前端但被静默忽略）。此处保留 pilot 的最小可见表现（toast），
            // 并在汇报中标注该差异。
            logger.info("compact_auto：used=\(ev.int("used") ?? -1)")
            ToastCenter.shared.show("上下文已自动压缩", kind: .info)
        case .authRequest:
            // 无条件处理：委派子会话的授权请求也经此冒泡主 UI（0.7.8 Bug4 链路），
            // 与该事件是否属于当前看的会话无关
            if isLive { accumulator.flush() }
            auth.handle(event: ev)
        case .message, nil:
            break   // heartbeat / 未知事件：忽略
        }
    }

    /// #1（0.4.20）插入点分裂：定格段1 → 重插注入气泡 → 新开段2 气泡并重指向。
    /// 0.7.8 Bug1：sink 分流——live 分裂走 messages + 计时器/阶段机复位；
    /// 后台流分裂只作用于 stash（计时器/阶段机是 live UI 态，stash 时已停）。
    internal func applySegmentBreak(_ ev: SSEEvent, frozenId: String, in streamSid: String) {
        guard streamSid == streamingSessionId else {
            guard var stash = backgroundStreams[streamSid] else { return }
            var stashStreamId: String? = stash.streamingMessageId
            _ = spliceSegmentBreak(ev, frozenId: frozenId,
                                   msgs: &stash.messages, streamId: &stashStreamId)
            stash.streamingMessageId = stashStreamId ?? stash.streamingMessageId
            stash.lastBreakAt = ev.int("break_at") ?? -1
            backgroundStreams[streamSid] = stash
            return
        }
        accumulator.flush()          // ① 先把挂起的增量 flush 进当前段，避免定格丢尾部正文
        closeThinkingPhase()
        lastBreakAt = ev.int("break_at") ?? -1
        guard spliceSegmentBreak(ev, frozenId: frozenId,
                                 msgs: &messages, streamId: &streamingMessageId) else { return }
        // REQ-MSG-022：等待计时按 segment 复位，段2 从 0 起计
        startWaitTimer()
        // W10：段2 阶段机同步回「装载/装填」（新一轮等待从 0 起计；预估沿用同模型均值）
        waitStage = .loading
    }

    /// 段分裂的落点无关部分（live messages / 后台 stash 共用）：定格段1 → 重插注入气泡
    /// → 新开段2 气泡并把 streamId 重指向它。返回 false = 找不到定格气泡（已记日志，
    /// streamId 仍重指向新 id，对齐原 guard-else 行为）。
    @discardableResult
    private func spliceSegmentBreak(_ ev: SSEEvent, frozenId: String,
                                    msgs: inout [ChatMessage], streamId: inout String?) -> Bool {
        let injected = ev.data["injected_messages"] as? [[String: Any]] ?? []
        let newId = LocalMessageID.next()

        guard let idx = msgs.firstIndex(where: { $0.id == frozenId }) else {
            // A-3（0.4.23）：现状此路径完全静默 → 只加日志，不改行为
            logger.warn("segment_break：找不到要定格的气泡 \(frozenId)，分裂已跳过（后续正文可能丢失）")
            streamId = newId
            return false
        }
        // 定格段1（completedDuration 必须有——否则语义上会被误判为异常中断半成品；
        // 0.4.22 checkpoint-109：定格时收敛 running 步骤 + 清等待计时）
        var frozen = msgs[idx]
        frozen.isStreaming = false
        frozen.thinkingActive = false
        frozen.thinkingElapsed = nil
        frozen.thinkingPreview = ""
        frozen.waitingSeconds = 0
        frozen.toolSteps = convergeRunningSteps(frozen.toolSteps)
        if let started = frozen.startedAt {
            frozen.completedDuration = Int(Date().timeIntervalSince1970 - started)
        }
        msgs[idx] = frozen
        // ② 注入气泡：从尾部倒着找同内容的乐观气泡（handleInject 已追加在末尾）→ 摘出重插，
        //    复用其 id；未命中才新建（0.4.23 I1：否则同一条消息显示两次）
        var injectedBubbles: [ChatMessage] = []
        for im in injected {
            guard let content = im["content"] as? String,
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            var dupIdx: Int? = nil
            if msgs.count > idx + 1 {
                for i in stride(from: msgs.count - 1, through: idx + 1, by: -1) {
                    if msgs[i].role == "user" && msgs[i].content == content { dupIdx = i; break }
                }
            }
            if let dup = dupIdx {
                injectedBubbles.append(msgs.remove(at: dup))
            } else {
                injectedBubbles.append(ChatMessage(id: LocalMessageID.next(), role: "user", content: content))
            }
        }
        // ③ 新开段2 气泡
        let frozenMaxStep = msgs[idx].maxStep ?? maxToolRounds
        var newAssistant = ChatMessage(id: newId, role: "assistant", content: "",
                                       modelUsed: msgs[idx].modelUsed)
        newAssistant.step = 0
        newAssistant.maxStep = frozenMaxStep
        newAssistant.startedAt = Date().timeIntervalSince1970
        newAssistant.isStreaming = true
        let insertAt = idx + 1
        msgs.insert(contentsOf: injectedBubbles + [newAssistant], at: insertAt)
        streamId = newId      // 重指向：后续事件写入新气泡
        return true
    }

    // MARK: - 计时三件套（B12 流级计时器 / REQ-MSG-022 等待计时 / 阶段化思考）

    private var thinkingStartedAt: TimeInterval?
    private var thinkingPhaseOpen = false

    /// B12（0.4.21）：流级计时器——流一开始就跑，驱动 runElapsed/thinkingElapsed 每秒跳动。
    private func startRunElapsedTimer() {
        runTimerTask?.cancel()
        runTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, let id = self.streamingMessageId, !Task.isCancelled else { continue }
                let now = Date().timeIntervalSince1970
                self.patchMessage(id) {
                    if let started = $0.startedAt { $0.runElapsed = Int(now - started) }
                    if $0.thinkingActive, let ts = self.thinkingStartedAt {
                        $0.thinkingElapsed = Int(now - ts)
                    }
                }
            }
        }
    }

    /// 等待计时：发送后未收到正文 → 每秒 +1；≥8s 且正文为空时 UI 显示等待横幅。
    /// REQ-MSG-022：按 segment 复位（segment_break 后段2 重新起计）。
    private func startWaitTimer() {
        waitTimerTask?.cancel()
        waitTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, let id = self.streamingMessageId, !Task.isCancelled else { continue }
                self.patchMessage(id) { $0.waitingSeconds += 1 }
            }
        }
    }

    private func stopWaitTimer() {
        waitTimerTask?.cancel()
        waitTimerTask = nil
    }

    private func stopTimers() {
        runTimerTask?.cancel(); runTimerTask = nil
        stopWaitTimer()
    }

    /// 阶段化思考（B1 0.4.8：已在思考态则幂等；正文/工具到达即关闭当前阶段）
    private func startThinkingPhase() {
        guard !thinkingPhaseOpen else { return }
        thinkingPhaseOpen = true
        thinkingStartedAt = Date().timeIntervalSince1970
        if let id = streamingMessageId {
            patchMessage(id) { $0.thinkingActive = true; $0.thinkingElapsed = 0 }
        }
    }

    private func closeThinkingPhase() {
        guard thinkingPhaseOpen else { return }
        thinkingPhaseOpen = false
        let duration = thinkingStartedAt.map { Int(Date().timeIntervalSince1970 - $0) }
        thinkingStartedAt = nil
        if let id = streamingMessageId {
            patchMessage(id) {
                $0.thinkingActive = false
                $0.thinkingElapsed = nil
                if let duration { $0.thinkingDuration = duration }   // D-1：思考定格保留显示
            }
        }
    }

    // MARK: - 收尾与 DB 对齐

    private func finishStream(_ assistantId: String, sid streamSid: String) {
        // 0.7.8 实测 Bug1：后台流收尾——done/error/cancelled 前 DB 已持久化
        //（persistAssistant），stash 直接丢弃，切回走 DB 权威合并加载；
        // ⛔ 绝不碰 live 槽（sending/计时器/streamingMessageId/指示器都属当前看的会话）。
        guard streamingSessionId == streamSid else {
            backgroundStreams.removeValue(forKey: streamSid)
            refreshChatBusyGuard()   // F2：后台流终结可能清空最后一个 busy 依据
            return
        }
        accumulator.flush()
        stopTimers()
        patchMessage(assistantId) { $0.isStreaming = false }
        streamingMessageId = nil
        let sid = streamingSessionId
        streamingSessionId = nil
        sending = false
        reconnectNotice = nil
        refreshTokenEstimate()
        // TS-121：流结束后把 local_ 临时 id 对齐成 DB 数字 id（勾选转移即刻可用）
        if let sid { Task { await alignLocalIdsWithDb(sid) } }
    }

    /// TS-121（对齐 alignLocalIdsWithDb）：按内容排队取号命中 DB 行；查虫K-5 位置兜底。
    internal func alignLocalIdsWithDb(_ sid: String) async {
        guard let pid = projectId else { return }
        let client = runtime.client
        guard currentSessionId == sid else { return }   // 查虫D：过期结果不得覆盖新会话
        guard let dbMsgs = try? await client.loadMessages(projectId: pid, sessionId: sid) else { return }
        guard currentSessionId == sid else { return }
        guard messages.contains(where: { $0.id.hasPrefix("local_") }) else { return }

        // 查虫B：同内容消息按内容排队取号
        var dbByKey: [String: [ChatMessage]] = [:]
        for d in dbMsgs where !d.content.isEmpty {
            dbByKey["\(d.role)::\(d.content)", default: []].append(d)
        }
        var next = messages
        for i in next.indices {
            guard next[i].id.hasPrefix("local_") else { continue }
            let key = next[i].content.isEmpty ? "" : "\(next[i].role)::\(next[i].content)"
            guard !key.isEmpty, var arr = dbByKey[key], !arr.isEmpty else { continue }
            let hit = arr.removeFirst()
            dbByKey[key] = arr
            // 以 DB 数字 id 为准；本地展示扩展字段（思考/用时等）迁移过去不丢
            next[i].dbId = hit.dbId
            next[i].id = hit.id
            next[i].createdAt = hit.createdAt
        }
        // 查虫K-5：位置兜底——停止落盘内容可能被截断，按「同角色、时序」对齐剩余 DB 消息
        let consumed = Set(next.compactMap { $0.dbId })
        let dbLeft = dbMsgs.filter { d in d.dbId.map { !consumed.contains($0) } ?? false }
        var cursor = 0
        for i in next.indices where next[i].id.hasPrefix("local_") {
            while cursor < dbLeft.count {
                let d = dbLeft[cursor]
                cursor += 1
                if d.role == next[i].role {
                    next[i].dbId = d.dbId
                    next[i].id = d.id
                    next[i].createdAt = d.createdAt
                    break
                }
            }
        }
        messages = next
    }

    // MARK: - compact_required 三选一（M2 §8.7）

    /// 智能压缩：POST compact → 重拉消息 → 最后一条 user 已被压缩掉才显式重发（B13 语义）
    public func compactSmart() async {
        guard let sid = currentSessionId, let pid = projectId, let cc = chatClient else { return }
        do {
            try await cc.compactSession(projectId: pid, sessionId: sid)
            compactWarning = nil
            ToastCenter.shared.show("已压缩，继续任务中...")
            // B13 修复口径：重拉 DB，按 content+role 比较（local_ id 与 DB id 永不相等）；
            // 判断失败则不重发（保守：宁可少发不可重复）
            let lastUserContent = messages.last(where: { $0.role == "user" })?.content
            if let after = try? await runtime.client.loadMessages(projectId: pid, sessionId: sid) {
                messages = after
                backendCtxChars = 0   // 压缩是显式减少路径（不经单调守门）
                restoreTokenIndicator()
                if let lastUserContent, !lastUserContent.isEmpty {
                    let retained = after.contains { $0.role == "user" && $0.content == lastUserContent }
                    if !retained { resendWithContent(lastUserContent) }
                }
            }
        } catch {
            ToastCenter.shared.show("压缩失败：\(SidecarError.describe(error))", kind: .error)
        }
    }

    /// 清空开新会话
    public func compactNewSession() async {
        compactWarning = nil
        _ = try? await createSession()
        ToastCenter.shared.show("已开新会话，请重新描述任务")
    }

    /// 导出后清空（隔离红线偏离记录：config 未配 compact_archive_dir 时，
    /// 现状回落 ~/.subagent/compressed 会触碰真实 home 目录；原生版回落到隔离数据根下）
    public func compactExportThenNew() async {
        guard let sid = currentSessionId, let pid = projectId, let cc = chatClient else { return }
        do {
            let cfg = (try? await cc.fetchConfig()) ?? [:]
            let dir = (cfg["compact_archive_dir"] as? String)
                ?? URL(fileURLWithPath: runtime.dataRootPath).appendingPathComponent("compressed").path
            _ = try await cc.exportSession(projectId: pid, agentId: agentId ?? "",
                                           sessionId: sid, dir: dir)
            compactWarning = nil
            _ = try? await createSession()
            ToastCenter.shared.show("已导出并开新会话")
        } catch {
            ToastCenter.shared.show("导出失败：\(SidecarError.describe(error))", kind: .error)
        }
    }

    // MARK: - ⋯ 更多操作（A12 菜单）

    /// 导出会话（M7：统一默认导出目录）
    public func exportSession() async {
        guard let sid = currentSessionId, let pid = projectId, let cc = chatClient else { return }
        do {
            let r = try await cc.exportSession(projectId: pid, agentId: agentId ?? "",
                                               sessionId: sid, dir: nil)
            ToastCenter.shared.show("已导出：\(r.name)", kind: .success, duration: 4)
        } catch {
            ToastCenter.shared.show("导出失败：\(SidecarError.describe(error))", kind: .error, duration: 4)
        }
    }

    /// 生成会话总结（checkpoint-048：模型生成 → 落 MD+DB）
    public func summarizeSession() async {
        guard let sid = currentSessionId, let pid = projectId, let cc = chatClient else { return }
        ToastCenter.shared.show("正在生成总结…")
        do {
            let r = try await cc.summarizeSession(projectId: pid, agentId: agentId ?? "",
                                                  sessionId: sid, model: selectedModel ?? "")
            let fname = r.savedFile.split(separator: "/").last.map(String.init) ?? ""
            ToastCenter.shared.show("总结已保存 ✓（\(fname)）", kind: .success, duration: 5)
        } catch {
            ToastCenter.shared.show("总结失败：\(SidecarError.describe(error))", kind: .error, duration: 5)
        }
    }

    // MARK: - 知识仓库勾选转移（TS-120）

    public func toggleSelectMode() {
        selectMode.toggle()
        if !selectMode { selectedDbIds = [] }
    }

    public func toggleMessageSelect(_ msg: ChatMessage) {
        guard let dbId = msg.dbId, !msg.archived, msg.role != "system" else { return }
        if selectedDbIds.contains(dbId) { selectedDbIds.remove(dbId) } else { selectedDbIds.insert(dbId) }
    }

    public func confirmTransfer() async {
        guard let sid = currentSessionId, let pid = projectId, let cc = chatClient,
              !selectedDbIds.isEmpty else { return }
        transferring = true
        defer { transferring = false }
        let keywords = transferKeywords
            .split { ",，、 ".contains($0) }
            .map(String.init).filter { !$0.isEmpty }
        do {
            let r = try await cc.transferToWarehouse(KnowledgeTransferRequest(
                projectId: pid, sessionId: sid, messageIds: Array(selectedDbIds),
                scope: transferScope,
                title: transferTitle.trimmingCharacters(in: .whitespaces).isEmpty ? nil : transferTitle.trimmingCharacters(in: .whitespaces),
                category: transferCategory.trimmingCharacters(in: .whitespaces),
                keywords: keywords))
            // A/B-2（0.4.23）：归档扣减而非归零（保基线；null 时不硬写显示值）
            let arch = ctxTokensAfterArchive(backendCtxChars: backendCtxChars,
                                             messages: messages, archivedDbIds: selectedDbIds)
            backendCtxChars = arch.nextCtxChars
            if let used = arch.nextTokenUsed { tokenIndicator.used = used }
            for i in messages.indices {
                if let dbId = messages[i].dbId, selectedDbIds.contains(dbId) {
                    messages[i].archived = true
                }
            }
            ToastCenter.shared.show("已移入知识仓库 ✓（\(r.title)）", kind: .success, duration: 4)
            showTransferModal = false
            selectedDbIds = []
            selectMode = false
            transferTitle = ""; transferCategory = ""; transferKeywords = ""
        } catch {
            ToastCenter.shared.show("转移失败：\(SidecarError.describe(error))", kind: .error, duration: 4)
        }
    }

    // MARK: - 模型降级引导（M5 TS-111）/ 视觉引导（M6 TS-112）

    /// 一键切换模型（PUT agents → 更新本地选中 → 调用方负责重发）
    public func switchModel(to name: String) async throws {
        guard let pid = projectId, let aid = agentId, let cc = chatClient else { return }
        try await cc.updateAgentModel(projectId: pid, agentId: aid, modelName: name)
        selectedModel = name
    }

    /// 重新拉取模型（POST ollama/pull）
    public func pullModel(_ name: String) async throws {
        try await chatClient?.pullModel(name: name)
        let client = runtime.client
        if let list = try? await client.listModels() { models = list }
    }

    // MARK: - 私有工具

    /// 0.7.8 Bug1：sink 分流——`in:` 非 nil 且不是 live 流归属会话 → 写后台 stash
    /// （值语义字典：取出→改→写回）；否则写当前 messages（全部旧调用点不变）。
    private func patchMessage(_ id: String, in streamSid: String? = nil,
                              _ mutate: (inout ChatMessage) -> Void) {
        if let sid = streamSid, sid != streamingSessionId {
            guard var stash = backgroundStreams[sid],
                  let idx = stash.messages.firstIndex(where: { $0.id == id }) else { return }
            mutate(&stash.messages[idx])
            backgroundStreams[sid] = stash
            return
        }
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        mutate(&messages[idx])
    }
}
