//
//  RoundtablePanelViewModel.swift
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

//  圆桌面板 ViewModel（逐段对标 subagent/renderer/src/panels/RoundtablePanel.tsx 269 行
//  + RoundtableView.tsx 423 行）：
//    · 列表态：Agent 列表（GET /api/agents/{pid}）+ 圆桌列表 5s 轮询（limit=20）
//    · 创建表单：议题 / 参与者 chips（≥2）/ 用户主持·AI 主持（主持人限选已勾参与者）/
//      轮数（2~10，缺省 5）/ 议题附件（≤5 个、单个 ≤2MB，读为 base64）；
//      校验文案逐字对齐（请输入议题 / 至少选择 2 个参与者 / 请选择 AI 主持人）；
//      创建成功清空表单并直接打开详情（onSelect(data.id)）
//    · 详情态（右侧大屏）：5s 轮询详情（终态 done/failed 停轮询）+ 进行中每秒已耗时
//      （UTC 解析口径复用 TaskElapsed，checkpoint-067 N-3）+ 纪要折叠 + 按轮分组发言
//    · 运行控制（决策 6：结束权在用户）：waiting_user → 继续下一轮/结束并总结；
//      confirm_end → 确认结束/再讨论一轮；running → 停止（当前发言完成后中止本轮，
//      提示文案逐字）；导出 Markdown（8s 通知）；删除（danger 确认，running 禁删）
//    · 圆桌无 SSE 推送通道（前端注释「无事件推送通道」），全部状态以轮询为唯一真相源；
//      纪律①③（合帧/flush）对本面板不适用——无 token/thinking 增量
//

import Foundation
import Combine

// MARK: - 纯函数助手（独立成枚举便于单测；规则逐字对齐 TSX 同名函数/常量）

public enum RoundtableFormat {

    /// 状态文案（对齐 RoundtableView.tsx STATUS_LABEL；未知回落「讨论中」）。
    public static func statusLabel(_ status: String) -> String {
        switch status {
        case "running": return "讨论中"
        case "waiting_user": return "等待用户"
        case "confirm_end": return "待确认结束"
        case "done": return "已结束"
        case "failed": return "异常"
        default: return "讨论中"
        }
    }

    /// 头像稳定配色（§8.13 六色板，哈希算法逐字对齐 TSX avatarColor：
    /// h = (h * 31 + charCodeAt(i)) >>> 0——charCodeAt 取 UTF-16 码元）。
    public static func avatarColorIndex(_ agentId: String) -> Int {
        var h: UInt32 = 0
        for u in agentId.utf16 { h = h &* 31 &+ UInt32(u) }
        return Int(h % 6)
    }

    /// 六色板（bg, fg）hex 值，供 View 取 Color(hex:)——面板专属色板，不走 VTheme。
    public static let avatarPalette: [(bg: UInt32, fg: UInt32)] = [
        (0xDCF1FE, 0x075985),
        (0xDEF3E4, 0x1F7A3D),
        (0xFCEEDC, 0xA05A00),
        (0xEEE4FB, 0x6B3FA0),
        (0xFCE0E6, 0xB03052),
        (0xDFF2F6, 0x0F7490),
    ]

    public static func avatarColors(_ agentId: String) -> (bg: UInt32, fg: UInt32) {
        avatarPalette[avatarColorIndex(agentId)]
    }

    /// 列表议题截断：前 40 字 + "…"（对齐 RoundtablePanel.tsx slice(0, 40)）。
    public static func truncatedTopic(_ topic: String) -> String {
        topic.count > 40 ? String(topic.prefix(40)) + "…" : topic
    }

    /// 已耗时（进行中才显示）：复用 Wave 1 TaskElapsed 的 UTC 解析与三档格式化
    /// （与 RoundtableView.tsx elapsedLabel 规则一致：解析失败/无 created_at → nil）。
    public static func elapsed(createdAt: String?, now: Date = Date()) -> String? {
        TaskElapsed.elapsed(createdAt: createdAt, now: now)
    }

    /// 问题5修复②（超时兜底判定）：创建请求超时后重拉列表，若出现
    /// 「创建前不存在 + 议题相同」的新圆桌 → 服务器实际已建成功，返回该圆桌；
    /// 否则返回 nil（维持报错）。列表后端按创建时间倒序（list_roundtables），
    /// first 命中即最新同议题条目；只认新 id 避免误判历史同议题圆桌。
    public static func recoveredAfterTimeout(before: [Roundtable], after: [Roundtable],
                                             topic: String) -> Roundtable? {
        let beforeIds = Set(before.map(\.id))
        return after.first { $0.topic == topic && !beforeIds.contains($0.id) }
    }
}

@MainActor
public final class RoundtablePanelViewModel: ObservableObject {

    // ── 列表态（对齐 RoundtablePanel.tsx useState 集）──
    @Published public private(set) var agents: [SidecarAgent] = []
    // W8（0.7.4）：列表/详情里出现 status=="running" 的讨论即上报 busy 闸
    // （waiting_user/confirm_end 非「在跑」不计）；stop() 撤报
    @Published public private(set) var roundtables: [Roundtable] = [] {
        didSet { reportBusyToGuard() }
    }
    // 创建表单
    @Published public var topic = ""
    @Published public private(set) var selectedAgentIds: [String] = []   // 保持勾选顺序
    @Published public var moderator: String = "user"    // "user" | "ai"
    @Published public var moderatorAgentId = ""
    @Published public var maxRounds = 5
    @Published public private(set) var pendingAttachments: [RTAttachmentInput] = []
    @Published public private(set) var creating = false
    @Published public private(set) var error: String?

    // ── 详情态（对齐 RoundtableView.tsx useState 集；selectedId = 右侧大屏打开中）──
    @Published public private(set) var selectedId: String?
    @Published public private(set) var detail: Roundtable? {
        didSet { reportBusyToGuard() }   // W8（0.7.4）：详情 running 翻转上报 busy 闸
    }
    @Published public private(set) var detailBusy = false
    @Published public private(set) var stopping = false
    @Published public private(set) var notice: String?
    @Published public var showMinutes = true
    /// 每秒计时快照（进行中才走表；对齐 useEffect [rtActive]）
    @Published public private(set) var now = Date()

    // ── 派生 ──
    /// 详情进行中（非 done/failed）：计时与轮询的门控（对齐 TSX rtActive）。
    public var detailActive: Bool { detail.map { !$0.isTerminal } ?? false }
    /// 按轮分组发言（对齐 TSX rounds 分组 + roundNos 升序）。
    public var groupedRounds: [(round: Int, messages: [RTMessage])] {
        var rounds: [Int: [RTMessage]] = [:]
        for m in detail?.messages ?? [] { rounds[m.round, default: []].append(m) }
        return rounds.keys.sorted().map { (round: $0, messages: rounds[$0] ?? []) }
    }
    /// 主持人展示文案（对齐 TSX moderatorLabel；AI 主持但找不到该参与者 →「（未知）」）。
    public var moderatorLabel: String {
        guard let detail else { return "" }
        if detail.moderator == "ai" {
            let name = detail.participants.first { $0.id == detail.moderator_agent_id }?.name
            return "AI 主持：\(name ?? "（未知）")"
        }
        return "用户主持（结束权在你）"
    }
    /// AI 主持人候选 = 已勾选参与者（对齐 TSX agents.filter(selectedAgents.includes)）。
    public var moderatorCandidates: [SidecarAgent] {
        agents.filter { selectedAgentIds.contains($0.id) }
    }
    /// 已耗时展示文案（进行中 + created_at 可解析时）。
    public var elapsedLabel: String? {
        guard detailActive else { return nil }
        return RoundtableFormat.elapsed(createdAt: detail?.created_at, now: now)
    }

    // ── 依赖与注入缝 ──
    private let appState: AppState
    private let clientOverride: (any RoundtablePanelClient)?
    private let pollIntervalNanos: UInt64       // 列表/详情轮询（现状 5000ms）
    private let tickIntervalNanos: UInt64       // 已耗时走表（现状 1000ms）
    private let noticeTTL6sNanos: UInt64        // 停止提示消隐（现状 flash 6000ms）
    private let noticeTTL8sNanos: UInt64        // 导出提示消隐（现状 flash 8000ms）
    private var logger: AppLogger { appState.logger }
    private var client: (any RoundtablePanelClient)? {
        clientOverride ?? (appState.runtime.client as? any RoundtablePanelClient)
    }

    /// 删除确认弹窗注入缝（测试替换；默认走全局 DialogCenter，danger 确认）。
    public var confirmHandler: (String, String, String, Bool) async -> Bool = { title, message, confirmText, danger in
        await DialogCenter.shared.confirm(title: title, message: message,
                                          confirmText: confirmText, danger: danger)
    }

    private var listPollTask: Task<Void, Never>?
    private var detailPollTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var noticeClearTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    public init(appState: AppState,
                clientOverride: (any RoundtablePanelClient)? = nil,
                pollInterval: TimeInterval = 5,
                tickInterval: TimeInterval = 1) {
        self.appState = appState
        self.clientOverride = clientOverride
        self.pollIntervalNanos = UInt64(pollInterval * 1_000_000_000)
        self.tickIntervalNanos = UInt64(tickInterval * 1_000_000_000)
        self.noticeTTL6sNanos = 6_000_000_000
        self.noticeTTL8sNanos = 8_000_000_000
    }

    // MARK: - 生命周期（View onAppear/onDisappear）

    /// 挂载：拉 Agent + 圆桌列表 + 起 5s 轮询；随后跟随项目切换重挂（对齐 useEffect [projectId]）。
    public func start() {
        guard !started else { return }
        started = true
        Task { await fetchAgents() }
        Task { await fetchRoundtables() }
        startListPolling()
        appState.$currentProjectId
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, self.started else { return }
                self.agents = []
                self.roundtables = []
                self.exitDetail()
                Task { await self.fetchAgents() }
                Task { await self.fetchRoundtables() }
            }
            .store(in: &cancellables)
        // V1（对齐 App.tsx:152-154 selectAgent → setViewingRtId(null)）：
        // 选中/清空 Agent（单击 Agent 直达聊天 / 删除当前 Agent / 任务跳转 jumpToAgent）
        // → 退出圆桌大屏回对话视图。仅响应外部写入；自身开/退详情不动 currentAgentId。
        appState.$currentAgentId
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, self.started, self.selectedId != nil else { return }
                self.exitDetail()
            }
            .store(in: &cancellables)
    }

    public func stop() {
        started = false
        listPollTask?.cancel()
        listPollTask = nil
        detailPollTask?.cancel()
        detailPollTask = nil
        tickTask?.cancel()
        tickTask = nil
        noticeClearTask?.cancel()
        noticeClearTask = nil
        // W8：视图全部卸载后列表不再刷新（状态可能已变）——撤报 busy，
        // 避免陈旧「进行中」卡在确认闸上（闸判定只在挂载/轮询期间为新鲜口径）
        appState.busyGuard.report(.roundtable, isBusy: false)
    }

    /// W8（0.7.4）：busy 上报——仅 status=="running" 的讨论计「在跑」
    /// （waiting_user/confirm_end 是等用户，不弹防误关确认）。
    private func reportBusyToGuard() {
        let active = roundtables.contains { $0.status == "running" }
            || (detail.map { $0.status == "running" } ?? false)
        appState.busyGuard.report(.roundtable, isBusy: active)
    }

    /// W8（0.7.4）：「返回列表」确认闸——讨论进行中先弹确认（讨论跑在内核，
    /// 退出详情只停本地轮询不中断讨论，文案如实告知后台继续；NSAlert 模态）。
    public func requestExitDetail() {
        if let c = PanelBusyGuard.roundtableDetailCloseConfirmation(
            running: detail.map { $0.status == "running" } ?? false),
           !BusyGuardAlert.confirm(c) { return }
        exitDetail()
    }

    // MARK: - V1 共享 VM 生命周期（手风琴列表与内容区大屏两个挂载点共用同一 VM）

    /// 活跃挂载点数（圆桌手风琴展开区 + 内容区详情大屏；align 原版 RoundtablePanel /
    /// RoundtableView 两组件并存语义——任一存活则 VM 不stop）。
    private var attachCount = 0

    /// 挂载点出现：首个挂载点启动（start 幂等）。
    public func attach() {
        attachCount += 1
        start()
    }

    /// 挂载点消失：归零才真正 stop（另一挂载点仍打开时轮询/详情不中断）。
    public func detach() {
        attachCount = max(0, attachCount - 1)
        if attachCount == 0 { stop() }
    }

    /// 侧车就绪自愈（面板先于侧车打开时补拉；对齐 ModelPacks reloadAfterSidecarReady 口径）。
    public func reloadAfterSidecarReady() {
        guard started else { return }
        Task { await fetchAgents() }
        Task { await fetchRoundtables() }
        if selectedId != nil { Task { await fetchDetail() } }
    }

    // MARK: - 列表加载

    public func fetchAgents() async {
        guard let client, let pid = appState.currentProjectId else { return }
        do {
            agents = try await client.listAgents(projectId: pid)
        } catch {
            // 对齐 TSX：失败只记日志不弹条（console.error('rt agents:', e)）
            logger.warn("圆桌 Agent 列表加载失败：\(SidecarError.describe(error))")
        }
    }

    public func fetchRoundtables() async {
        guard let client, let pid = appState.currentProjectId else { return }
        do {
            roundtables = try await client.listRoundtables(projectId: pid, limit: 20)
        } catch {
            // 对齐 TSX：轮询失败静默（console.error('rt list:', e)）
            logger.warn("圆桌列表加载失败：\(SidecarError.describe(error))")
        }
    }

    private func startListPolling() {
        listPollTask?.cancel()
        listPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self?.pollIntervalNanos ?? 5_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.fetchRoundtables()
            }
        }
    }

    // MARK: - 创建表单

    /// 勾选/取消参与者（对齐 toggleAgent）。
    public func toggleAgent(_ id: String) {
        if let i = selectedAgentIds.firstIndex(of: id) {
            selectedAgentIds.remove(at: i)
        } else {
            selectedAgentIds.append(id)
        }
    }

    /// 议题附件加入（对齐 handleFileChange：最多 5 个、单个 ≤2MB 跳过并提示）。
    public func addAttachments(_ files: [(name: String, data: Data)]) {
        let room = 5 - pendingAttachments.count
        if room <= 0 {
            error = "最多上传 5 个附件"
            return
        }
        for f in files.prefix(room) {
            if f.data.count > 2 * 1024 * 1024 {
                error = "文件 \(f.name) 超过 2MB，已跳过"
                continue
            }
            pendingAttachments.append(RTAttachmentInput(
                name: f.name, content_base64: f.data.base64EncodedString()))
        }
    }

    public func removeAttachment(at index: Int) {
        guard pendingAttachments.indices.contains(index) else { return }
        pendingAttachments.remove(at: index)
    }

    /// 创建校验（逐字对齐 handleCreate 的三条前置校验）。
    public var createValidationError: String? {
        if topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请输入议题" }
        if selectedAgentIds.count < 2 { return "至少选择 2 个参与者" }
        if moderator == "ai" && moderatorAgentId.isEmpty { return "请选择 AI 主持人" }
        return nil
    }

    /// 开始讨论（busy 防连点；成功清空表单 → 重拉列表 → 直接打开详情）。
    public func create() {
        guard !creating else { return }
        if let msg = createValidationError {
            error = msg
            return
        }
        guard let client, let pid = appState.currentProjectId else { return }
        creating = true
        error = nil
        let request = RoundtableCreateRequest(
            topic: topic.trimmingCharacters(in: .whitespacesAndNewlines),
            agent_ids: selectedAgentIds,
            moderator: moderator,
            moderator_agent_id: moderator == "ai" ? moderatorAgentId : nil,
            max_rounds: maxRounds,
            attachments: pendingAttachments
        )
        Task { [weak self] in
            guard let self else { return }
            do {
                let rt = try await client.createRoundtable(projectId: pid, request: request)
                self.resetCreateForm()
                await self.fetchRoundtables()
                self.select(rt.id)          // 创建成功 → 右侧直接打开详情
            } catch {
                // 问题5修复②（超时兜底）：创建端点同步执行第一轮（app.py L1855），
                // 客户端超时≠服务器失败——重拉列表，若已有该议题新圆桌则视为成功进详情，
                // 不弹「创建失败」（对齐 Electron 现状：apiJson 裸 fetch 无超时，
                // 用户感受是一直等到第一轮跑完返回）。
                if let recovered = await self.recoverTimedOutCreate(
                    error: error, topic: request.topic, client: client, projectId: pid) {
                    self.resetCreateForm()
                    self.select(recovered.id)
                } else {
                    self.error = "创建失败: \(SidecarError.describe(error))"
                }
            }
            self.creating = false
        }
    }

    /// 创建成功（含超时兜底认成功）后清空表单（对齐 handleCreate 成功分支五项重置）。
    private func resetCreateForm() {
        topic = ""
        selectedAgentIds = []
        moderator = "user"
        moderatorAgentId = ""
        pendingAttachments = []
    }

    /// 超时兜底：仅 SidecarError.timeout 触发；重拉列表并判定「新圆桌已落库」。
    private func recoverTimedOutCreate(error: Error, topic: String,
                                       client: any RoundtablePanelClient,
                                       projectId: String) async -> Roundtable? {
        guard case SidecarError.timeout = error else { return nil }
        let before = roundtables
        do {
            let after = try await client.listRoundtables(projectId: projectId, limit: 20)
            roundtables = after
            let recovered = RoundtableFormat.recoveredAfterTimeout(before: before, after: after, topic: topic)
            if recovered != nil {
                logger.info("圆桌创建超时但已落库，按成功处理：\(recovered!.id)")
            }
            return recovered
        } catch {
            return nil
        }
    }

    // MARK: - 详情（右侧大屏）

    /// 列表项点击 → 打开详情（对齐 onSelect(rtId)）。
    public func select(_ rtId: String) {
        guard selectedId != rtId else { return }
        selectedId = rtId
        detail = nil
        notice = nil
        error = nil
        showMinutes = true
        Task { await fetchDetail() }
        startDetailPolling()
    }

    /// 返回列表（对齐 onExit）。
    public func exitDetail() {
        selectedId = nil
        detail = nil
        detailPollTask?.cancel()
        detailPollTask = nil
        tickTask?.cancel()
        tickTask = nil
    }

    public func fetchDetail() async {
        guard let client, let pid = appState.currentProjectId, let rtId = selectedId else { return }
        do {
            let rt = try await client.getRoundtable(projectId: pid, rtId: rtId)
            if Task.isCancelled { return }
            detail = rt
            updateTicker()
            if rt.isTerminal {
                // 终态停止轮询（对齐 useEffect 早退分支）
                detailPollTask?.cancel()
                detailPollTask = nil
            }
        } catch {
            if Task.isCancelled { return }
            logger.warn("圆桌详情加载失败：\(SidecarError.describe(error))")
        }
    }

    private func startDetailPolling() {
        detailPollTask?.cancel()
        detailPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self?.pollIntervalNanos ?? 5_000_000_000)
                guard !Task.isCancelled else { return }
                guard let self, self.detailActive || self.detail == nil else { return }  // 终态不再轮询
                await self.fetchDetail()
            }
        }
    }

    /// 每秒走表（进行中才开；对齐 useEffect [rtActive] 的 setInterval 1000）。
    private func updateTicker() {
        if detailActive {
            guard tickTask == nil else { return }
            now = Date()
            tickTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: self?.tickIntervalNanos ?? 1_000_000_000)
                    guard !Task.isCancelled else { return }
                    self?.now = Date()
                }
            }
        } else {
            tickTask?.cancel()
            tickTask = nil
        }
    }

    // MARK: - 运行控制（决策 6：结束权在用户；文案逐字对齐 RoundtableView.tsx）

    /// 继续下一轮（waiting_user / confirm_end 的「再讨论一轮」）。
    public func continueDiscussion() {
        guard !detailBusy else { return }
        detailBusy = true
        error = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let client, let pid = self.appState.currentProjectId, let rtId = self.selectedId else { return }
                try await client.continueRoundtable(projectId: pid, rtId: rtId)
                await self.fetchDetail()
            } catch {
                self.error = "继续失败: \(SidecarError.describe(error))"
            }
            self.detailBusy = false
        }
    }

    /// 结束并总结（waiting_user）/ 确认结束（confirm_end）。
    public func finishDiscussion() {
        guard !detailBusy else { return }
        detailBusy = true
        error = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let client, let pid = self.appState.currentProjectId, let rtId = self.selectedId else { return }
                try await client.finishRoundtable(projectId: pid, rtId: rtId)
                await self.fetchDetail()
            } catch {
                self.error = "结束失败: \(SidecarError.describe(error))"
            }
            self.detailBusy = false
        }
    }

    /// 手动停止（checkpoint-067 N-1：当前发言完成后中止本轮，已完成发言保留）。
    public func stopDiscussion() {
        guard !stopping else { return }
        stopping = true
        error = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let client, let pid = self.appState.currentProjectId, let rtId = self.selectedId else { return }
                try await client.stopRoundtable(projectId: pid, rtId: rtId)
                self.flashNotice("已请求停止，将在当前发言完成后中止", ttlNanos: self.noticeTTL6sNanos)
                await self.fetchDetail()
            } catch {
                self.error = "停止失败: \(SidecarError.describe(error))"
            }
            self.stopping = false
        }
    }

    /// 导出为 Markdown 文件（H18-2）；成功提示「已保存：<path|name|未知路径>」8s 消隐。
    public func exportDiscussion() {
        guard !detailBusy else { return }
        detailBusy = true
        error = nil
        notice = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let client, let pid = self.appState.currentProjectId, let rtId = self.selectedId else { return }
                let result = try await client.exportRoundtable(projectId: pid, rtId: rtId)
                self.flashNotice("已保存：\(result.path ?? result.name ?? "未知路径")",
                                 ttlNanos: self.noticeTTL8sNanos)
            } catch {
                self.error = "保存失败: \(SidecarError.describe(error))"
            }
            self.detailBusy = false
        }
    }

    /// 删除讨论（H18-1；danger 确认；running 由 UI 禁用 + 后端 400 双把守）。
    /// 成功 → 退出大屏 + 重拉列表（对齐 onExit()）。
    public func deleteDiscussion() {
        guard !detailBusy else { return }
        Task { [weak self] in
            guard let self else { return }
            let ok = await self.confirmHandler(
                "删除圆桌讨论",
                "确定删除这场圆桌讨论吗？全部发言记录将被清除，不可恢复。",
                "删除",
                true)
            guard ok else { return }
            self.detailBusy = true
            self.error = nil
            do {
                guard let client, let pid = self.appState.currentProjectId, let rtId = self.selectedId else { return }
                try await client.deleteRoundtable(projectId: pid, rtId: rtId)
                self.detailBusy = false
                self.exitDetail()
                await self.fetchRoundtables()
            } catch {
                self.error = "删除失败: \(SidecarError.describe(error))"
                self.detailBusy = false
            }
        }
    }

    // MARK: - 通知条自动消隐（对齐前端 flash(setNotice, …, ttl)）

    private func flashNotice(_ text: String, ttlNanos: UInt64) {
        notice = text
        noticeClearTask?.cancel()
        noticeClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: ttlNanos)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
}
