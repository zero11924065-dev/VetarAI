//
//  TaskPanelViewModel.swift
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

//  委派任务面板 ViewModel（逐段对标 subagent/renderer/src/panels/TaskPanel.tsx）：
//    · 任务列表：GET /api/projects/{pid}/tasks?limit=30（手动刷新 + SSE 触发静默重拉）
//    · 实时进度：GET /api/projects/{pid}/tasks/stream（SSE），事件按原始名分发
//      （snapshot/status/tool_call/tool_result/progress/task_end/gap/stream_end/stream_error），
//      断流 3s 退避重连、卸载绝不重连（对齐 startResilientStream retryMs=3000）
//    · 重试（failed）/ 停止（running）：POST retry / stop，消息条 6s 自动消隐
//    · 进行中任务每秒计时（已耗时），无活跃任务时停表
//    · 「查看」跳转：写 AppState 当前 Agent/会话并导航到会话面板
//
//  纪律适配说明：本面板 SSE 事件均为小粒度 UI 状态（无 token/thinking 文本增量），
//  纪律①合帧不适用；纪律③保序 flush 针对增量缓冲器，此处无缓冲器，事件即来即分发，
//  与前端 applyEvent 同步派发同语义。
//

import Foundation
import Combine

/// 已耗时格式化与 created_at 解析（独立成纯函数便于单测；规则逐字对齐 TaskPanel.tsx fmtElapsed）。
public enum TaskElapsed {
    /// SQLite datetime('now') 存 UTC（checkpoint-067 N-3）：按 UTC 解析，
    /// 前端等价物为 `Date.parse(created_at.replace(' ', 'T') + 'Z')`。
    public static func parseCreatedAt(_ s: String) -> Date? {
        Self.sqliteUTC.date(from: s)
    }

    /// fmtElapsed：<60 → "Ns"；<3600 → "MmSs"；否则 "HhMm"。
    public static func format(seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m\(seconds % 60)s" }
        return "\(seconds / 3600)h\((seconds % 3600) / 60)m"
    }

    /// 进行中任务的已耗时；解析失败返回 nil（前端 Number.isNaN 分支）。
    public static func elapsed(createdAt: String?, now: Date = Date()) -> String? {
        guard let createdAt, let started = parseCreatedAt(createdAt) else { return nil }
        return format(seconds: max(0, Int(now.timeIntervalSince(started))))
    }

    private static let sqliteUTC: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}

@MainActor
public final class TaskPanelViewModel: ObservableObject {

    /// 某任务的实时进度（来自 SSE 增量，DB 无这些字段；对齐前端 LiveProgress）。
    public struct LiveProgress: Equatable {
        public var toolName: String?      // 最近一次 tool_call 的工具名
        public var toolOk: Bool?          // 该工具 tool_result 结果；未回来为 nil
        public var step: Int?             // 当前轮次
        public var max: Int?              // 轮次上限
        public var chars: Int?            // 已生成字数

        public init(toolName: String? = nil, toolOk: Bool? = nil,
                    step: Int? = nil, max: Int? = nil, chars: Int? = nil) {
            self.toolName = toolName
            self.toolOk = toolOk
            self.step = step
            self.max = max
            self.chars = chars
        }
    }

    // ── 视图状态（对齐 TaskPanel.tsx useState 集）──
    @Published public private(set) var tasks: [AgentTask] = []
    @Published public private(set) var loading = false
    @Published public private(set) var error: String?
    @Published public private(set) var retryingId: String?
    @Published public private(set) var retryMsg: String?
    @Published public private(set) var stoppingId: String?
    @Published public private(set) var stopMsg: String?
    @Published public private(set) var live: [String: LiveProgress] = [:]
    @Published public private(set) var streamOn = false
    /// 每秒计时器快照（仅展示用；有进行中任务时才走表）
    @Published public private(set) var now = Date()

    public var hasActive: Bool { tasks.contains { $0.isActive } }

    // ── 依赖与注入缝 ──
    private let appState: AppState
    private let clientOverride: SidecarClientProtocol?
    private let retryIntervalNanos: UInt64      // SSE 断流退避（现状 3000ms）
    private let tickIntervalNanos: UInt64       // 已耗时走表（现状 1000ms）
    private let messageTTLNanos: UInt64         // 重试/停止消息自动消隐（现状 6000ms）
    private var logger: AppLogger { appState.logger }
    private var client: SidecarClientProtocol? { clientOverride ?? appState.runtime.client }

    private var streamTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    private var msgClearTasks: [Task<Void, Never>] = []
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    public init(appState: AppState,
                clientOverride: SidecarClientProtocol? = nil,
                retryInterval: TimeInterval = 3,
                tickInterval: TimeInterval = 1,
                messageTTL: TimeInterval = 6) {
        self.appState = appState
        self.clientOverride = clientOverride
        self.retryIntervalNanos = UInt64(retryInterval * 1_000_000_000)
        self.tickIntervalNanos = UInt64(tickInterval * 1_000_000_000)
        self.messageTTLNanos = UInt64(messageTTL * 1_000_000_000)
    }

    // MARK: - 生命周期（View onAppear/onDisappear）

    /// 挂载：拉一次列表 + 起实时流；随后跟随项目切换重挂（对齐 useEffect [projectId]）。
    public func start() {
        guard !started else { return }
        started = true
        reload()
        startStream()
        appState.$currentProjectId
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, self.started else { return }
                self.tasks = []
                self.live = [:]
                self.reload()
                self.startStream()      // startStream 内先 cancel 旧流（换项目即换通道）
            }
            .store(in: &cancellables)
    }

    /// 卸载：cancelled=true + abort + 清退避定时器（对齐 startResilientStream 返回的 stop）。
    public func stop() {
        started = false
        streamTask?.cancel()
        streamTask = nil
        tickTask?.cancel()
        tickTask = nil
        reloadTask?.cancel()
        reloadTask = nil
        msgClearTasks.forEach { $0.cancel() }
        msgClearTasks.removeAll()
        streamOn = false
    }

    // MARK: - 列表加载（silent = 流事件触发的静默重拉，不动 loading 闪烁）

    public func reload() { reload(silent: false) }

    public func reload(silent: Bool) {
        reloadTask?.cancel()
        reloadTask = Task { await loadTasks(silent: silent) }
    }

    private func loadTasks(silent: Bool) async {
        guard let client, let pid = appState.currentProjectId else { return }
        if !silent { loading = true }
        if !silent { error = nil }
        do {
            let list = try await client.listTasks(projectId: pid, limit: 30)
            if Task.isCancelled { return }
            tasks = list
            updateTicker()
        } catch {
            if Task.isCancelled { return }
            if !silent { self.error = "加载失败: \(SidecarError.describe(error))" }
            logger.warn("任务列表加载失败：\(SidecarError.describe(error))")
        }
        if !silent { loading = false }
    }

    // MARK: - SSE 实时进度流（弹性重连壳：3s 退避，stop 后绝不重连）

    private func startStream() {
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let client = self.client, let pid = self.appState.currentProjectId else { return }
                var announced = false
                do {
                    for try await ev in client.tasksStream(projectId: pid) {
                        if Task.isCancelled { break }
                        if !announced {
                            announced = true
                            self.streamOn = true      // 对齐全前端 onConnect（连上首个事件即视为已连接）
                        }
                        self.apply(event: ev)
                    }
                } catch {
                    // 静默：流失败不弹错误条（手动刷新仍兜底），只在下方退避重连
                    if !Task.isCancelled {
                        self.logger.warn("任务进度流断开：\(SidecarError.describe(error))，3s 后重连")
                    }
                }
                if Task.isCancelled { break }
                self.streamOn = false
                try? await Task.sleep(nanoseconds: self.retryIntervalNanos)
            }
            self.streamOn = false
        }
    }

    /// 事件分发（对齐 TaskPanel.tsx applyEvent 逐分支；未知事件忽略，向前兼容）。
    public func apply(event ev: SSEEvent) {
        let d = ev.data
        let tid = (d["task_id"] as? String) ?? ""
        switch ev.event {
        case "snapshot":
            // DB 权威基线：整体替换，并清掉已不在列表里的实时进度
            let list = Self.decodeTasks(d["tasks"])
            tasks = list
            let ids = Set(list.map(\.id))
            var kept: [String: LiveProgress] = [:]
            for (k, v) in live where ids.contains(k) { kept[k] = v }
            live = kept
            updateTicker()
        case "status":
            guard !tid.isEmpty else { return }
            let state = (d["state"] as? String) ?? ""
            // 终态一律以 DB 为准（静默重拉拿 report/fail_reason 完整字段），
            // 避免流事件与 DB 两个真相源打架
            if state == "done" || state == "failed" { reload(silent: true) }
        case "tool_call":
            guard !tid.isEmpty else { return }
            var p = live[tid] ?? LiveProgress()
            p.toolName = (d["name"] as? String) ?? ""
            p.toolOk = nil
            live[tid] = p
        case "tool_result":
            guard !tid.isEmpty else { return }
            var p = live[tid] ?? LiveProgress()
            p.toolOk = ev.bool("ok")
            live[tid] = p
        case "progress":
            guard !tid.isEmpty else { return }
            var p = live[tid] ?? LiveProgress()
            if let n = ev.int("step") { p.step = n }
            if let n = ev.int("max") { p.max = n }
            if let n = ev.int("chars") { p.chars = n }
            live[tid] = p
        case "task_end":
            guard !tid.isEmpty else { return }
            // 收口：删除该任务的实时进度记录，防止反复委派累积（对齐前端 delete next[tid]）
            live.removeValue(forKey: tid)
            reload(silent: true)      // 重拉快照：failed 原因/摘要以 DB 为准
        case "gap", "stream_end", "stream_error":
            // 断档或流结束 → 重拉快照对齐（不静默错乱地拿半截状态渲染）
            reload(silent: true)
        default:
            break                     // 未知事件忽略，向前兼容
        }
    }

    /// snapshot 内嵌任务数组宽容解码（SSE data 经 JSONSerialization，回序列化走 Codable）。
    /// 纯函数，标 nonisolated 便于非隔离上下文（测试）直调。
    nonisolated static func decodeTasks(_ any: Any?) -> [AgentTask] {
        guard let arr = any as? [[String: Any]],
              let data = try? JSONSerialization.data(withJSONObject: arr) else { return [] }
        return (try? JSONDecoder().decode([AgentTask].self, from: data)) ?? []
    }

    // MARK: - 重试 / 停止（文案逐字对齐 TaskPanel.tsx）

    public func retry(taskId: String) {
        guard retryingId == nil else { return }
        retryingId = taskId
        retryMsg = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let client = self.client, let pid = self.appState.currentProjectId else { return }
                let result = try await client.retryTask(projectId: pid, taskId: taskId)
                self.retryMsg = result.ok
                    ? "重试完成：子任务成功交卷"
                    : "重试完成但未成功：\(result.error ?? "未知原因")"
                await self.loadTasks(silent: false)
            } catch {
                self.retryMsg = "重试失败: \(SidecarError.describe(error))"
            }
            self.retryingId = nil
            self.scheduleClearRetryMsg()
        }
    }

    public func stopTask(_ taskId: String) {
        guard stoppingId == nil else { return }
        stoppingId = taskId
        stopMsg = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let client = self.client, let pid = self.appState.currentProjectId else { return }
                try await client.stopTask(projectId: pid, taskId: taskId)
                self.stopMsg = "已请求停止，将在当前步骤完成后中止"
                // 立即刷新一次拿到最新状态（轮询/流之外的人工刷新）
                await self.loadTasks(silent: false)
            } catch {
                self.stopMsg = "停止失败: \(SidecarError.describe(error))"
            }
            self.stoppingId = nil
            self.scheduleClearStopMsg()
        }
    }

    private func scheduleClearRetryMsg() {
        let t = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.messageTTLNanos ?? 6_000_000_000)
            guard !Task.isCancelled else { return }
            self?.retryMsg = nil
        }
        msgClearTasks.append(t)
    }

    private func scheduleClearStopMsg() {
        let t = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.messageTTLNanos ?? 6_000_000_000)
            guard !Task.isCancelled else { return }
            self?.stopMsg = nil
        }
        msgClearTasks.append(t)
    }

    // MARK: - 每秒计时（有进行中任务时才走表，对齐 useEffect [hasActive]）

    private func updateTicker() {
        if hasActive {
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

    // MARK: - 跳转子 Agent 委派会话（对齐 onJumpToAgent(agentId, sessionId)）

    public func jumpToAgent(_ task: AgentTask) {
        guard let agentId = task.target_agent_id else { return }
        appState.currentAgentId = agentId
        appState.currentSessionId = task.session_id
        appState.selectPanel(PanelRegistry.chatHome)
        // U2：ChatViewModel 切上下文时经 pickInitialSession 消费 currentSessionId——
        // 目标会话在新列表则选中，否则回落首个（对齐 ChatPanel.tsx:1161-1176
        // jumpToSessionId 消费语义），跳转不再丢目标会话。
    }
}
