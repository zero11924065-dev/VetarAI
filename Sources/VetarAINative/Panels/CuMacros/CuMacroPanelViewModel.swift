//
//  CuMacroPanelViewModel.swift
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

//  CU 任务宏面板 ViewModel（逐段对标 subagent/renderer/src/panels/CuMacroPanel.tsx，
//  487 行；0.4.32 三期 P3 / 0.4.33 F2 空宏防护 / 0.4.34 R4 用户手动录制模式）：
//    · 宏列表：GET /api/cu-macros（名称/创建时间/步骤数 + 回放/删除）
//    · 双模式录制入口：「录制 Agent 操作」（body 只带 name，后端缺省 agent）/
//      「录制我的操作」（先 GET user-record/permission，已授权才 POST start {name, mode:"user"}）
//    · 未授权引导：granted:false 或 start 403（detail 以 input_monitoring_not_granted 开头）
//      → warn 引导 callout + 「请求授权」按钮（POST permission/request → GET 复查，
//      已授权则直接补发 user start）
//    · 录制中实时步数：轮询 GET /cu-macros 的 recording_steps（0.4.33 F2；
//      ⛔ 只同步步数——recording 开关态不随轮询翻面，防抖），recording_mode 双文案
//    · 停止：saved:false（0 步契约）→ warn callout 原文上屏不 refresh；saved:true → 刷新
//    · 回放：空宏（steps<=0）置灰 + 双保险拦截；run 进行中轮询 /replays/{run_id}；
//      409 互斥 / 422 空宏等冲突走 catch detail 原文上屏（可读提示）
//    · 命中率（回放口径）：最近一次回放 element vs pixel_fallback 统计
//
//  ⚠️ 「录制我的操作」授权主体：P3-W4 起 TCC 重归属——走原生内核（路由 .native）
//  时「输入监控」查/请的都是原生 app（ai.vetar.native）自身状态位，引导文案
//  逐字对齐 Python；仅当「原生内核（实验）」开关关闭走 HTTP 侧车时，授权主体
//  仍是侧车二进制（com.vetarai.sidecar）。
//

import Foundation

@MainActor
public final class CuMacroPanelViewModel: ObservableObject {

    /// 录制模式（GET /cu-macros 的 recording_mode 契约：nil|"agent"|"user"）
    public enum RecordingMode: String, Equatable {
        case agent, user
    }

    // ── 视图状态（对齐 CuMacroPanel.tsx useState 集）──
    @Published public private(set) var macros: [CuMacroSummary]?   // nil = 加载中
    @Published public private(set) var recording = false
    @Published public private(set) var recordingName = ""
    @Published public private(set) var recordingSteps = 0          // 0.4.33 F2：录制中实时已捕获步数
    @Published public private(set) var recordingMode: RecordingMode?
    @Published public var recName = ""
    @Published public private(set) var busy = false                // 录制起停/回放启动/删除的动作级防重
    @Published public private(set) var run: CuReplayRun?
    @Published public private(set) var error: String?
    @Published public private(set) var warn: String?               // 0.4.33 F2：0 步停止警告（saved:false）
    @Published public private(set) var permDenied = false          // R4：输入监控未授权引导
    @Published public private(set) var permBusy = false            // 「请求授权」按钮防重
    @Published public private(set) var selectedId: String?         // 选中宏（侧栏列表 ↔ 详情卡同源）
    /// 全程审计聚合（0.7.4 W5）：macroId → 回放/成功/元素命中/像素回落；
    /// 进程内运行记录口径（重启即空），refresh 成功时容错刷新（失败保留旧值）
    @Published public private(set) var audit: [String: CuMacroAuditEntry] = [:]

    /// 回放进行中（真实键鼠是独占资源；录制/回放按钮的门控）
    public var runActive: Bool { run?.status == "running" }

    /// 当前选中宏（列表重拉后不在列表中则视为未选中）
    public var selected: CuMacroSummary? { macros?.first { $0.id == selectedId } }

    // ── 依赖与注入缝 ──
    private let clientProvider: () -> CuMacroPanelClient?
    private let pollNanos: UInt64                  // 现状 500ms
    private let logger: AppLogger
    /// 删除确认弹窗注入缝（测试替换为免 UI 实现；默认走全局 DialogCenter）
    var confirmDelete: (CuMacroSummary) async -> Bool

    private var pollTask: Task<Void, Never>?
    private var started = false

    public init(clientProvider: @escaping () -> CuMacroPanelClient?,
                pollInterval: TimeInterval = 0.5,
                logger: AppLogger = .shared) {
        self.clientProvider = clientProvider
        self.pollNanos = UInt64(pollInterval * 1_000_000_000)
        self.logger = logger
        self.confirmDelete = { macro in
            await DialogCenter.shared.confirm(
                title: "删除任务宏",
                message: "确定删除宏「\(macro.name)」？删除后无法恢复。",
                confirmText: "删除", danger: true)
        }
    }

    // MARK: - 生命周期

    /// 挂载：拉一次列表 + 起轮询循环（录制步数 / 回放进度共用一拍，互不互斥时各自生效）。
    public func start() {
        guard !started else { return }
        started = true
        Task { await refresh() }
        pollTask = Task { [weak self] in await self?.pollLoop() }
    }

    public func stop() {
        started = false
        pollTask?.cancel()
        pollTask = nil
    }

    /// 侧车就绪自愈（收口阶段补齐，对齐 ModelPacks/Roundtable 口径）：
    /// 面板先于侧车打开时挂载首拉「读取宏列表失败」，就绪后自动补拉一次。
    public func reloadAfterSidecarReady() {
        guard started else { return }
        Task { await refresh() }
    }

    // MARK: - 流程中心共享 VM 生命周期（侧栏手风琴列表与内容区两个挂载点共用同一 VM）

    /// 活跃挂载点数（流程中心侧栏「CU 宏」手风琴 + 内容区面板；对齐圆桌
    /// RoundtablePanelViewModel attach/detach 口径——任一存活则轮询不停）。
    private var attachCount = 0

    /// 挂载点出现：首个挂载点启动（start 幂等）。
    public func attach() {
        attachCount += 1
        start()
    }

    /// 挂载点消失：归零才真正 stop（另一挂载点仍打开时轮询不中断）。
    public func detach() {
        attachCount = max(0, attachCount - 1)
        if attachCount == 0 { stop() }
    }

    // MARK: - 选中宏（流程中心侧栏列表 ↔ 内容区详情卡 同源选中态）

    /// 选中：侧栏行点击 / 内容区详情卡共用（对齐工作流 selectedId 语义）。
    public func select(_ macro: CuMacroSummary) {
        selectedId = macro.id
    }

    // MARK: - 拉取（GET /cu-macros：列表 + 录制态快照）

    public func refresh() async {
        guard let client = clientProvider() else {
            error = "读取宏列表失败: 内核不可用"
            return
        }
        do {
            let s = try await client.listCuMacros()
            macros = s.macros
            recording = s.recording
            // 收口修正：成功后清除陈旧错误条（否则首拉失败留下的 error 永远挂屏，
            // 即便就绪自愈/手动刷新已成功）
            error = nil
            // recording_steps（0.4.33 契约字段，缺键客户端已按 0 兜底）
            recordingSteps = s.recordingSteps
            // recording_mode（R4 契约字段）：未录制为 nil；录制中缺键按 agent 兜底
            // （旧后端无该键时只有 agent 录制）
            recordingMode = s.recording ? (s.recordingMode == "user" ? .user : .agent) : nil
            if !s.recording { recordingName = "" }
            // 0.7.4 W5：全程审计聚合容错拉取——失败静默保留旧值，不阻塞列表刷新
            if let entries = try? await client.cuMacroAuditSummary() {
                audit = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
            }
        } catch {
            self.error = "读取宏列表失败: \(SidecarError.detailText(error))"
        }
    }

    /// 轮询循环：录制中同步步数（⛔ 只同步步数不翻面录制态，0.4.33 F2 防抖）；
    /// 回放进行中拉 run 状态。单拍失败静默，下一拍重试（轮询语义）。
    private func pollLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: pollNanos)
            guard !Task.isCancelled else { return }
            if recording {
                await pollRecordingSteps()
            }
            if let currentRun = run, currentRun.status == "running" {
                await pollRunStatus(runId: currentRun.run_id)
            }
        }
    }

    private func pollRecordingSteps() async {
        guard let client = clientProvider() else { return }
        do {
            let s = try await client.listCuMacros()
            recordingSteps = s.recordingSteps
        } catch { /* 单拍失败静默，下一拍重试（轮询语义） */ }
    }

    private func pollRunStatus(runId: String) async {
        guard let client = clientProvider() else { return }
        do {
            let r = try await client.cuMacroReplayStatus(runId: runId)
            // 防抖：轮询在飞期间 run 已被替换/清空 → 过期结果不得覆盖
            guard run?.run_id == runId else { return }
            run = r
        } catch { /* 单拍失败静默，下一拍重试（轮询语义） */ }
    }

    // MARK: - 开始录制（双模式）

    /// 「录制 Agent 操作」：body 只带 name（后端缺省 mode=agent，现状零变化）。
    public func startRecord() {
        let name = recName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !busy, !runActive else { return }
        guard let client = clientProvider() else { return }
        busy = true
        error = nil
        warn = nil
        permDenied = false
        Task { [weak self] in
            guard let self else { return }
            do {
                let serverName = try await client.startCuMacroRecording(name: name, mode: nil)
                self.applyStartOk(serverName: serverName, fallback: name, mode: .agent)
            } catch {
                self.handleStartError(error)
            }
            self.busy = false
        }
    }

    /// 「录制我的操作」：先 GET permission → 未授权落引导 callout（不发 start）；
    /// 已授权才 POST start {name, mode:"user"}；start 403（权限被收回等）同样落引导。
    public func startUserRecord() {
        let name = recName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !busy, !runActive else { return }
        guard let client = clientProvider() else { return }
        busy = true
        error = nil
        warn = nil
        permDenied = false
        Task { [weak self] in
            guard let self else { return }
            do {
                let p = try await client.cuUserRecordPermission()
                if !p.granted {
                    self.permDenied = true
                    self.busy = false
                    return
                }
                try await self.startUserPost(client: client, name: name)
            } catch {
                self.handleStartError(error)
            }
            self.busy = false
        }
    }

    /// R4：已授权后的 user 模式 start（permission 前置通过与「请求授权」复查通过共用）。
    private func startUserPost(client: CuMacroPanelClient, name: String) async throws {
        let serverName = try await client.startCuMacroRecording(name: name, mode: "user")
        applyStartOk(serverName: serverName, fallback: name, mode: .user)
    }

    /// R4：start 成功后的本地录制态落位（两种模式共用）。
    private func applyStartOk(serverName: String, fallback: String, mode: RecordingMode) {
        recording = true
        recordingName = serverName.isEmpty ? fallback : serverName
        recordingMode = mode
        recordingSteps = 0
        recName = ""
        permDenied = false
    }

    /// R4：start 失败的归一——403 未授权落引导 callout，其余（含 409 互斥）走错误 callout。
    private func handleStartError(_ error: Error) {
        if case SidecarError.httpError(_, let detail) = error,
           detail.hasPrefix("input_monitoring_not_granted") {
            permDenied = true
        } else {
            self.error = "开始录制失败: \(SidecarError.detailText(error))"
        }
    }

    // MARK: - 权限引导（R4：「请求授权」触发系统授权流程 → 复查 → 已授权直接补发 start）

    public func requestPermission() {
        guard !permBusy else { return }
        guard let client = clientProvider() else { return }
        permBusy = true
        error = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await client.requestCuUserRecordPermission()
                // 授权结果以复查为准——用户也可能在系统设置里手动改
                let p = try await client.cuUserRecordPermission()
                if p.granted {
                    self.permDenied = false
                    let name = self.recName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty {
                        try await self.startUserPost(client: client, name: name)
                    }
                }
            } catch {
                if case SidecarError.httpError(_, let detail) = error,
                           detail.hasPrefix("input_monitoring_not_granted") {
                    self.permDenied = true
                } else {
                    self.error = "请求授权失败: \(SidecarError.detailText(error))"
                }
            }
            self.permBusy = false
        }
    }

    // MARK: - 停止录制（0.4.33 F2：0 步 saved:false → 警告原文上屏，不 refresh）

    public func stopRecord() {
        guard !busy else { return }
        guard let client = clientProvider() else { return }
        busy = true
        error = nil
        warn = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let r = try await client.stopCuMacroRecording()
                self.recording = false
                self.recordingName = ""
                self.recordingMode = nil
                self.recordingSteps = 0
                if !r.saved {
                    // 0 步契约：HTTP 200 {ok:true, saved:false, steps:0, message}
                    // → 警告原文上屏，⛔ 不 refresh（宏没落盘，列表无新项可刷）
                    self.warn = r.message ?? "未捕获到任何动作，宏未保存"
                } else {
                    await self.refresh()
                }
            } catch {
                self.error = "停止录制失败: \(SidecarError.detailText(error))"
            }
            self.busy = false
        }
    }

    // MARK: - 回放（空宏置灰 + 双保险；启动后由轮询循环推 run 状态）

    public func startReplay(_ macro: CuMacroSummary) {
        // 回放忙防重：真实键鼠是独占资源，后端另有 422 兜底（replay_busy）
        // 0.4.33 F2 空宏防护：steps==0 的宏（含历史遗留）不回放，按钮已置灰，此处双保险；
        // 若仍触发到后端 422「宏没有可回放的步骤」，走 catch 把 detail 如实上屏。
        guard !busy, !runActive, macro.steps > 0 else { return }
        guard let client = clientProvider() else { return }
        busy = true
        error = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let runId = try await client.replayCuMacro(macroId: macro.id)
                self.run = CuReplayRun(run_id: runId, macro_id: macro.id, macro_name: macro.name,
                                       status: "running", total: macro.steps, completed: 0,
                                       failed_seq: nil, error: "", steps: [])
            } catch {
                self.error = "回放启动失败: \(SidecarError.detailText(error))"
            }
            self.busy = false
        }
    }

    // MARK: - 删除（确认弹窗 → DELETE；删正在回放的宏清 run；删选中宏清选中态）

    public func delete(_ macro: CuMacroSummary) {
        Task { [weak self] in
            guard let self else { return }
            let ok = await self.confirmDelete(macro)
            guard ok else { return }
            guard let client = clientProvider() else { return }
            self.busy = true
            self.error = nil
            do {
                try await client.deleteCuMacro(macroId: macro.id)
                if self.run?.macro_id == macro.id { self.run = nil }
                // 删除选中宏 → 清选中态（内容区详情卡回落引导空态）
                if self.selectedId == macro.id { self.selectedId = nil }
                await self.refresh()
            } catch {
                self.error = "删除失败: \(SidecarError.detailText(error))"
            }
            self.busy = false
        }
    }

    // MARK: - 展示层纯函数（单测覆盖；口径逐字对齐 TSX）

    /// 命中方式 → 人话标签（method 值与后端契约一致：element/pixel_fallback/abort/payload）。
    public static let methodLabels: [String: String] = [
        "element": "元素定位",
        "pixel_fallback": "像素回落",
        "payload": "按键/输入",
        "abort": "中止",
    ]

    /// 命中率（回放口径）：最近一次回放的点击步骤里 element vs pixel_fallback。
    /// percent = nil 表示暂无回放样本（样本 0）。
    public static func hitRate(steps: [CuReplayStep]) -> (element: Int, pixelFallback: Int, percent: Int?) {
        let elem = steps.filter { $0.method == "element" }.count
        let pix = steps.filter { $0.method == "pixel_fallback" }.count
        let sample = elem + pix
        // JS Math.round == 四舍五入（正数域与 rounded() 一致）
        return (elem, pix, sample > 0 ? Int((Double(elem) / Double(sample) * 100).rounded()) : nil)
    }

    /// 回放进度百分比（total 0 → 0；上限钳 100）。
    public static func progressPercent(run: CuReplayRun?) -> Int {
        guard let run, run.total > 0 else { return 0 }
        return min(100, Int((Double(run.completed) / Double(run.total) * 100).rounded()))
    }
}
