//
//  WorkflowPanelViewModel.swift
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

//  流程中心主面板 ViewModel（逐段对标 subagent/renderer/src/panels/WorkflowPanel.tsx）：
//    · 工作流列表 / 选择 / 新建 / 删除（内置不可删）/ 保存（422 detail 上屏）
//    · 运行：先保存再 POST run（SSE），事件流驱动节点状态 + 事件日志 + 审批卡片；
//      停止 = 先 POST /workflow-runs/{runId}/stop 再断本地流（顺序不可颠倒）
//    · A13 资源变更流：resource==workflow / gap → 重拉列表；dirty 守卫绝不冲掉编辑内容
//    · 运行记录查看（任务要求，TSX 无此区）：GET /workflow-runs 列表 + 详情节点事件
//    · 节点/连线编辑 mutation（patchNode/addNode/removeNode/addEdge/removeEdge）
//      全部置 dirty（对齐 onDefChange）
//
//  纪律适配说明：本面板 SSE 事件均为小粒度 UI 状态（无 token/thinking 文本增量），
//  纪律①合帧不适用；运行参数 JSON 校验在客户端先做（对齐 TSX JSON.parse 前置分支）。
//

import Foundation
import Combine

/// 画布节点运行状态（对齐 WorkflowCanvas.tsx NodeStatus）。
public enum WorkflowNodeStatus: String, Equatable, Sendable {
    case pending, running, done, error
}

@MainActor
public final class WorkflowPanelViewModel: ObservableObject {

    /// 一条运行事件（对齐 TSX RunEvent {event, data, ts}）。
    public struct RunEvent: Identifiable {
        public let id = UUID()
        public let event: String
        public let data: [String: Any]
        public let ts: Date

        public init(event: String, data: [String: Any], ts: Date = Date()) {
            self.event = event
            self.data = data
            self.ts = ts
        }

        /// 事件流行文本（对齐 TSX 事件行拼接规则）。
        public var lineText: String {
            var s = event
            if let nodeId = data["node_id"] as? String { s += " · \(nodeId)" }
            if let error = data["error"] as? String { s += " · \(error)" }
            if let preview = data["output_preview"] as? String {
                s += " · \(String(preview.prefix(80)))"
            }
            if event == "workflow_reply", let text = data["text"] as? String {
                s += " 💬 \(String(text.prefix(120)))"
            }
            return s
        }

        /// 错误系事件标红（对齐 TSX `event.includes('error') || event === 'workflow_failed'`）。
        public var isError: Bool { event.contains("error") || event == "workflow_failed" }
    }

    /// 审批卡片载荷（approval_required 事件）。
    public struct ApprovalCard: Equatable {
        public let nodeId: String
        public let label: String
        public let message: String
    }

    // ── 视图状态（对齐 WorkflowPanel.tsx useState 集）──
    @Published public private(set) var workflows: [WorkflowRecord] = []
    @Published public var selectedId: String?
    @Published public var selectedNodeId: String?
    @Published public private(set) var models: [String] = []
    @Published public var name = "" { didSet { if !suppressDirty { dirty = true } } }
    @Published public var desc = "" { didSet { if !suppressDirty { dirty = true } } }
    @Published public private(set) var definition = WorkflowDefinition.startOnly()
    @Published public private(set) var dirty = false
    @Published public private(set) var validateMsg = ""

    // 运行态
    // W8（0.7.4）：running 翻转即上报 busy 闸（切走模块/关闭窗口前弹确认，
    // 防误关；stopRunLocal 置 false 时自动撤报）
    @Published public private(set) var running = false {
        didSet { appState.busyGuard.report(.workflow, isBusy: running) }
    }
    @Published public private(set) var runId: String?
    @Published public private(set) var nodeStatus: [String: WorkflowNodeStatus] = [:]
    @Published public private(set) var events: [RunEvent] = []
    @Published public private(set) var approval: ApprovalCard?
    @Published public var paramsText = "{}"
    @Published public var showJson = false

    // 运行记录查看（任务要求；TSX 无此区，端点现状存在）
    @Published public private(set) var runs: [WorkflowRunRecord] = []
    @Published public private(set) var runsLoading = false
    @Published public private(set) var expandedRunId: String?
    @Published public private(set) var runDetail: WorkflowRunDetail?
    @Published public private(set) var runDetailLoading = false

    public var selected: WorkflowRecord? { workflows.first { $0.id == selectedId } }

    // ── 依赖与注入缝 ──
    private let appState: AppState
    private let clientOverride: SidecarClientProtocol?
    private let retryIntervalNanos: UInt64      // 资源变更流断连退避（现状 3000ms）
    /// 确认弹窗 / 提示弹窗注入缝（测试替换为免 UI 实现；默认走全局 DialogCenter）。
    var confirmDelete: (String) async -> Bool
    var alertPresenter: (String, String) async -> Void

    private var logger: AppLogger { appState.logger }
    private var client: WorkflowPanelClient? {
        (clientOverride ?? appState.runtime.client) as? WorkflowPanelClient
    }

    private var suppressDirty = false           // selectWorkflow/create 回填表单时不置脏
    private var runTask: Task<Void, Never>?
    private var eventsStreamTask: Task<Void, Never>?
    private var lastSeq = 0                     // 资源变更流游标（断连重连带 since 补发）
    private var started = false

    public init(appState: AppState,
                clientOverride: SidecarClientProtocol? = nil,
                retryInterval: TimeInterval = 3) {
        self.appState = appState
        self.clientOverride = clientOverride
        self.retryIntervalNanos = UInt64(retryInterval * 1_000_000_000)
        self.confirmDelete = { name in
            await DialogCenter.shared.confirm(
                title: "删除工作流",
                message: "确定删除「\(name)」？运行记录会保留。",
                confirmText: "删除", cancelText: "取消", danger: true)
        }
        self.alertPresenter = { title, message in
            await DialogCenter.shared.alert(title: title, message: message)
        }
    }

    // MARK: - 生命周期（View onAppear/onDisappear）

    /// 挂载：拉列表 + 拉模型 + 起资源变更流（对齐 useEffect [loadWorkflows, loadModels] + A13 订阅）。
    public func start() {
        guard !started else { return }
        started = true
        Task { await loadWorkflows() }
        Task { await loadModels() }
        startEventsStream()
    }

    /// 卸载：断资源变更流 + 停运行（对齐 stopRun + 事件订阅 off）。
    public func stop() {
        started = false
        eventsStreamTask?.cancel()
        eventsStreamTask = nil
        stopRunLocal()
    }

    // MARK: - 流程中心共享 VM 生命周期（侧栏手风琴列表与内容区两个挂载点共用同一 VM）

    /// 活跃挂载点数（流程中心侧栏「工作流」手风琴 + 内容区面板；对齐圆桌
    /// RoundtablePanelViewModel attach/detach 口径——任一存活则 VM 不 stop）。
    private var attachCount = 0

    /// 挂载点出现：首个挂载点启动（start 幂等）。
    public func attach() {
        attachCount += 1
        start()
    }

    /// 挂载点消失：归零才真正 stop（另一挂载点仍打开时资源变更流不中断）。
    public func detach() {
        attachCount = max(0, attachCount - 1)
        if attachCount == 0 { stop() }
    }

    // MARK: - 列表 / 模型加载（client 恒在——nativeReady 于 runtime init 同步点亮，
    // 任何视图出现前已就绪；nil 仅可能为协议 cast 异常，记 warn 不再静默）

    /// 首拉是否成功过（A13 流 connected 握手时的补拉判据——P3-W6⑤：
    /// 历史上「侧车就绪 → 补拉」自愈随归零消亡，改为流握手补拉一次）。
    private var didLoadWorkflows = false
    /// 在飞守卫：start() 首拉与流 connected 握手补拉并发时去重（同一份数据）。
    private var loadingWorkflows = false

    public func loadWorkflows() async {
        guard let client else {
            logger.warn("工作流列表加载跳过：client 缺席（WorkflowPanelClient cast 失败）")
            return
        }
        guard !loadingWorkflows else { return }
        loadingWorkflows = true
        defer { loadingWorkflows = false }
        do {
            let list = try await client.listWorkflows()
            if Task.isCancelled { return }
            workflows = list
            didLoadWorkflows = true
            logger.info("工作流列表已加载：\(list.count) 条")
        } catch {
            logger.warn("工作流列表加载失败：\(SidecarError.describe(error))")
        }
    }

    public func loadModels() async {
        guard let client else {
            logger.warn("模型列表加载跳过：client 缺席（WorkflowPanelClient cast 失败）")
            return
        }
        do {
            // 对齐 TSX `list.map(m => m.name || m).filter(Boolean)`
            let list = try await client.fetchInferenceModels()
            if Task.isCancelled { return }
            models = list.map(\.name).filter { !$0.isEmpty }
        } catch {
            logger.warn("模型列表加载失败：\(SidecarError.describe(error))")
        }
    }

    // MARK: - A13 资源变更流（resource==workflow / gap → 重拉；dirty 守卫）

    private func startEventsStream() {
        eventsStreamTask?.cancel()
        eventsStreamTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let client = self.client else {
                    try? await Task.sleep(nanoseconds: self.retryIntervalNanos)
                    continue
                }
                do {
                    for try await ev in client.appEventsStream(since: self.lastSeq) {
                        if Task.isCancelled { break }
                        self.apply(appEvent: ev)
                    }
                } catch {
                    if !Task.isCancelled {
                        self.logger.warn("资源变更流断开：\(SidecarError.describe(error))，3s 后重连")
                    }
                }
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: self.retryIntervalNanos)
            }
        }
    }

    /// 资源变更分发（对齐 APP_RESOURCE_CHANGED 订阅分支）。
    /// dirty 守卫：用户正在编辑时跳过重拉，绝不冲掉未保存改动（A13 dirtyRef 口径）。
    public func apply(appEvent ev: SSEEvent) {
        if let seq = ev.int("seq"), seq > lastSeq { lastSeq = seq }
        switch ev.event {
        case "connected":
            // P3-W6⑤ 自愈承接：首拉未成功过时借流握手补拉一次（历史上
            // 「侧车就绪 → 补拉」经 status onChange 触发，归零后 nativeReady
            // 恒 true 于任何订阅前，onChange 永不触发——改由流握手兜底）；
            // dirty 守卫同 resource_changed——绝不冲掉未保存改动。
            if !didLoadWorkflows, !dirty {
                Task { await self.loadWorkflows() }
            }
        case "resource_changed":
            let resource = ev.string("resource") ?? ""
            guard resource == "workflow" else { return }
            guard !dirty else { return }
            Task { await self.loadWorkflows() }
        case "gap":
            guard !dirty else { return }
            Task { await self.loadWorkflows() }
        default:
            break    // stream_end / stream_error / 未知：忽略（重连壳兜底）
        }
    }

    // MARK: - 选择 / 新建 / 删除 / 保存

    /// 选中工作流：回填表单 + 清运行态（对齐 selectWorkflow：stopRun + 清节点选择/校验信息）。
    public func selectWorkflow(_ wf: WorkflowRecord) {
        suppressDirty = true
        defer { suppressDirty = false }
        selectedId = wf.id
        name = wf.name
        desc = wf.description
        definition = wf.definition
        selectedNodeId = nil
        validateMsg = ""
        dirty = false
        stopRunLocal()
        runs = []
        expandedRunId = nil
        runDetail = nil
        Task { await loadRuns() }
    }

    /// 新建（对齐 createWorkflow：默认定义仅开始节点；失败弹「创建失败」）。
    public func createWorkflow() {
        guard let client else { return }
        let def = WorkflowDefinition.startOnly()
        Task {
            do {
                let newId = try await client.createWorkflow(
                    name: "新工作流", description: "", definition: def)
                await loadWorkflows()
                suppressDirty = true
                defer { suppressDirty = false }
                selectedId = newId
                name = "新工作流"
                desc = ""
                definition = def
                selectedNodeId = nil
                dirty = false
                validateMsg = ""
                runs = []
                expandedRunId = nil
                runDetail = nil
            } catch {
                await alertPresenter("创建失败", SidecarError.describe(error))
            }
        }
    }

    /// 删除（内置不可删；确认文案逐字对齐；运行记录保留）。
    public func deleteWorkflow() {
        guard let sel = selected, !sel.builtIn else { return }
        Task {
            let ok = await confirmDelete(sel.name)
            guard ok else { return }
            do {
                try await client?.deleteWorkflow(id: sel.id)
                selectedId = nil
                await loadWorkflows()
            } catch {
                await alertPresenter("删除失败", SidecarError.describe(error))
            }
        }
    }

    /// 保存（对齐 saveWorkflow：422 detail 落 validateMsg + 弹窗；成功清脏重拉）。
    /// 返回是否成功——runWorkflow 前置保存用（TSX 不据结果中断运行，此处仅透出供测试断言）。
    @discardableResult
    public func saveWorkflow() async -> Bool {
        guard let client, let selectedId else { return false }
        do {
            try await client.updateWorkflow(id: selectedId, update: WorkflowUpdateRequest(
                name: name, description: desc, definition: definition))
            validateMsg = ""
            dirty = false
            await loadWorkflows()
            return true
        } catch {
            let detail = SidecarError.describe(error)
            validateMsg = detail.isEmpty ? "保存失败" : detail
            await alertPresenter("保存失败", detail)
            return false
        }
    }

    // MARK: - 运行（SSE）

    /// 解析运行参数（对齐 `JSON.parse(paramsText || '{}')` 前置校验）。
    /// 成功返回参数字典；失败弹「运行参数不是合法 JSON」并返回 nil。
    public func parseRunParams() async -> [String: JSONValue]? {
        let text = paramsText.isEmpty ? "{}" : paramsText
        guard let data = text.data(using: .utf8),
              let obj = try? JSONDecoder().decode([String: JSONValue].self, from: data) else {
            await alertPresenter("提示", "运行参数不是合法 JSON")
            return nil
        }
        return obj
    }

    /// 运行工作流（对齐 runWorkflow）：先保存 → 校验参数 → POST run 消费 SSE。
    /// 事件驱动 nodeStatus / events / approval / runId（首条带 run_id 的事件捕获）。
    public func runWorkflow() {
        guard let client, let selectedId else { return }
        runTask?.cancel()
        runTask = Task {
            // 运行前先保存（保证服务端定义是最新的）；TSX 不据保存结果中断——
            // 服务端 run 走严格校验（422），定义不完整会在启动失败分支上屏。
            await saveWorkflow()
            guard !Task.isCancelled else { return }
            guard let params = await parseRunParams() else { return }

            running = true
            events = []
            nodeStatus = [:]
            approval = nil
            runId = nil

            var capturedRunId: String?
            var sawAnyEvent = false
            do {
                for try await ev in client.runWorkflow(id: selectedId, params: params) {
                    if Task.isCancelled { break }
                    sawAnyEvent = true
                    if capturedRunId == nil, let rid = ev.string("run_id") {
                        capturedRunId = rid
                        runId = rid
                    }
                    apply(runEvent: ev)
                }
            } catch {
                if !Task.isCancelled {
                    // 对齐 TSX：启动失败（res 非 2xx，如 422 严格校验）与运行中断分流；
                    // 启动失败时 running 复位（TSX setRunning(false) 分支）
                    if !sawAnyEvent, case SidecarError.httpError = error {
                        running = false
                        await alertPresenter("启动失败", SidecarError.describe(error))
                    } else {
                        await alertPresenter("运行中断", SidecarError.describe(error))
                    }
                }
            }
            if !Task.isCancelled {
                running = false
            }
            // 终态后重拉运行记录（列表口径以 DB 为准）
            await loadRuns()
        }
    }

    /// 运行事件分发（对齐 SSE 消费循环逐分支；未知事件仅入日志流，向前兼容）。
    public func apply(runEvent ev: SSEEvent) {
        events.append(RunEvent(event: ev.event, data: ev.data))
        switch ev.event {
        case "node_start":
            if let nid = ev.string("node_id") { nodeStatus[nid] = .running }
        case "node_done":
            if let nid = ev.string("node_id") { nodeStatus[nid] = .done }
        case "node_error":
            if let nid = ev.string("node_id") { nodeStatus[nid] = .error }
        case "approval_required":
            approval = ApprovalCard(nodeId: ev.string("node_id") ?? "",
                                    label: ev.string("label") ?? "",
                                    message: ev.string("message") ?? "")
        case "workflow_done", "workflow_failed", "workflow_stopped":
            running = false
            approval = nil
        default:
            break   // heartbeat / workflow_reply / images_dropped / loop_batch_skipped 等：仅入事件流
        }
    }

    /// 本地断流（对齐 stopRun：abort + 清运行态；不发服务端请求）。
    private func stopRunLocal() {
        runTask?.cancel()
        runTask = nil
        running = false
        approval = nil
    }

    /// 停止运行（对齐 stopRunServer：先 POST stop 再断本地流，顺序不可颠倒）。
    public func stopRunServer() {
        guard let rid = runId else { return }
        Task {
            try? await client?.stopWorkflowRun(runId: rid)
            stopRunLocal()
        }
    }

    /// 审批决议（对齐 respondApproval：成功清卡片；失败弹「审批失败」）。
    public func respondApproval(approved: Bool, comment: String = "") {
        guard let rid = runId else { return }
        Task {
            do {
                try await client?.approveWorkflowRun(runId: rid, approved: approved, comment: comment)
                approval = nil
            } catch {
                await alertPresenter("审批失败", SidecarError.describe(error))
            }
        }
    }

    // MARK: - 运行记录查看（list + 详情展开）

    public func loadRuns() async {
        guard let client, let selectedId else { return }
        runsLoading = true
        do {
            let list = try await client.listWorkflowRuns(workflowId: selectedId, limit: 30)
            if Task.isCancelled { return }
            runs = list
        } catch {
            logger.warn("运行记录加载失败：\(SidecarError.describe(error))")
        }
        runsLoading = false
    }

    /// 展开/收起运行详情（再点同一行收起；展开时拉详情含节点事件）。
    public func toggleRunDetail(_ runId: String) {
        if expandedRunId == runId {
            expandedRunId = nil
            runDetail = nil
            return
        }
        expandedRunId = runId
        runDetail = nil
        runDetailLoading = true
        Task {
            do {
                let detail = try await client?.getWorkflowRun(id: runId)
                guard expandedRunId == runId, !Task.isCancelled else { return }
                runDetail = detail
            } catch {
                logger.warn("运行详情加载失败：\(SidecarError.describe(error))")
            }
            if expandedRunId == runId { runDetailLoading = false }
        }
    }

    // MARK: - 定义编辑 mutation（对齐 WorkflowEditor.tsx onChange 语义：一律置 dirty）

    /// 编辑入口统一收口：改定义 + 置脏（对齐 onDefChange）。
    public func mutateDefinition(_ body: (inout WorkflowDefinition) -> Void) {
        body(&definition)
        dirty = true
    }

    /// patchNode(id, patch)：键值补丁（value nil = 删除该键，对齐 TSX `{images: undefined}`）。
    public func patchNode(id: String, patch: [String: JSONValue?]) {
        mutateDefinition { def in
            guard let idx = def.nodes.firstIndex(where: { $0.id == id }) else { return }
            for (k, v) in patch {
                if let v { def.nodes[idx].props[k] = v }
                else { def.nodes[idx].props.removeValue(forKey: k) }
            }
        }
    }

    /// 新增节点（对齐 addNode：id 生成 + 缺省字段链 + 选中新节点）。
    public func addNode(type: String) {
        let newId = WorkflowNodeFactory.generateID(existing: definition.nodes)
        let node = WorkflowNodeFactory.makeNode(type: type, id: newId, models: models)
        mutateDefinition { $0.nodes.append(node) }
        selectedNodeId = newId
    }

    /// 删除节点（对齐 removeNode：级联删关联连线；start 不可删由视图层把关）。
    public func removeNode(id: String) {
        mutateDefinition { def in
            def.nodes.removeAll { $0.id == id }
            def.edges.removeAll { $0.from == id || $0.to == id }
        }
        if selectedNodeId == id { selectedNodeId = nil }
    }

    /// 新增连线（对齐 addEdge 守卫：空端点/自环/完全重复（含 when）一律拒绝）。
    /// 返回是否真正添加（供单测断言守卫分支）。
    @discardableResult
    public func addEdge(from: String, to: String, when: String) -> Bool {
        guard !from.isEmpty, !to.isEmpty, from != to else { return false }
        let exists = definition.edges.contains {
            $0.from == from && $0.to == to && ($0.when ?? "") == when
        }
        guard !exists else { return false }
        let edge = WorkflowEdge(from: from, to: to, when: when.isEmpty ? nil : when)
        mutateDefinition { $0.edges.append(edge) }
        return true
    }

    /// 按索引删连线（对齐 removeEdge(idx)）。
    public func removeEdge(at index: Int) {
        guard definition.edges.indices.contains(index) else { return }
        mutateDefinition { $0.edges.remove(at: index) }
    }
}
