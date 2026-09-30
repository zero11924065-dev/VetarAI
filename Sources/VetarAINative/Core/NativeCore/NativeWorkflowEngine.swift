//
//  NativeWorkflowEngine.swift
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

//  逐行为移植 subagent/sidecar/workflow/engine.py（⛔ 只读行为规格源，1212 行）：
//    · 15 类节点（start/end + 13 执行类）逐一对应 _run_* 方法
//    · 事件流：node_start / node_done / node_error / approval_required / heartbeat /
//      workflow_done / workflow_failed / workflow_stopped / workflow_reply /
//      images_dropped / loop_batch_skipped——全部注入 run_id（0.2.4 W1 契约）
//    · 模型驻留规则：切换即卸载（keep_alive:0），结束（含异常/取消）卸载驻留模型
//    · C5 取消语义：run_id → 取消事件（唯一真相源），停止立即唤醒无轮询延迟
//    · 审批挂起：awaiting_approval 落库 + approval_required 事件 + 15s 心跳
//    · REQ-WF-015：inference/条件裁判节点级 timeout_s（引擎侧 clamp 10~7200 兜底；
//      超时错误写**实际生效**秒数，缺省写全局 timeout_reading 动态值）
//
//  并发模型映射（Python asyncio → Swift）：
//    · 引擎为 actor——actor 重入语义与 asyncio 事件循环交错语义同构（并行分支
//      共享变量空间在 await 点交错，无数据竞争）
//    · 事件队列 asyncio.Queue → AsyncStream（无界缓冲一致）
//    · 客户端断开 = 消费方终止 → 生产者 Task 取消 → run 记 stopped「客户端断开」
//    · TaskGroup 竞速（chat vs 取消事件）= asyncio.wait(FIRST_COMPLETED)
//
//  偏差（汇报清单同步）：
//    ① tool 节点：P2-W3a 起内核装配处（runWorkflow）注入 NativeRegistryToolExecutor
//       （8 工具原生；create_document/doc_reader 留 W3b 如实报 not_ported）；
//       引擎未注入执行器时工具节点仍按原预留口径如实失败（文案明示待接管），不静默吞。
//    ② code 节点：经 /usr/bin/env python3 子进程执行（语义等价 + 超时可真杀进程，
//       优于侧车线程泄漏）；机器无 python3 时节点如实失败。result 需可 JSON 序列化
//       （进程边界 marshal；in-process exec 的任意对象形态不支持）。
//    ③ file_read 的 OOXML（docx/xlsx/xlsm/pptx）解析：P2-W3b 起经 NativeDocParser
//       → VetarOOXML 读取面接通（inflate + 结构化解析，同知识库链），偏差已消除。
//

import Foundation

// MARK: - 事件与结果

/// 一条引擎事件（Python {"event": ..., "data": ...} 同构）。
public struct WorkflowEngineEvent: Sendable, Equatable {
    public let event: String
    public let data: [String: JSONValue]
    public init(event: String, data: [String: JSONValue]) {
        self.event = event
        self.data = data
    }
}

/// NodeResult（engine.py L130-138）。
public struct NativeNodeResult: Sendable {
    public let nodeId: String
    public var ok: Bool = true
    /// 输出（.null = Python None）。
    public var output: JSONValue = .null
    public var error: String? = nil
    public var modelUsed: String? = nil
    public var durationMs: Int = 0
    public var retryCount: Int = 0

    public init(nodeId: String, ok: Bool = true, output: JSONValue = .null,
                error: String? = nil, modelUsed: String? = nil) {
        self.nodeId = nodeId
        self.ok = ok
        self.output = output
        self.error = error
        self.modelUsed = modelUsed
    }
}

/// WorkflowCancel（engine.py L126）：用户停止。
struct WorkflowCancel: Error {}
/// 客户端断开（Python asyncio.CancelledError 路径：run 记 stopped「客户端断开」）。
struct WorkflowClientDisconnect: Error {}

// MARK: - 工具节点执行器（P2-W3 接口预留）

/// tool 节点执行面（对齐 sidecar/tools/registry.py execute(tool, args, sandbox_root, _)）。
/// P2-W3 移植工具层后由内核注入实现；本波未注入时工具节点如实失败。
public protocol NativeWorkflowToolExecutor: Sendable {
    /// 返回 {"ok": bool, ...} 结果字典（Python execute_tool 同构）。
    func executeTool(_ tool: String, args: [String: JSONValue],
                     sandboxRoot: String) async throws -> [String: JSONValue]
}

// MARK: - 运行期注册表（engine.py 模块级 _CANCEL_EVENTS / _APPROVALS 等价物）

/// 取消事件 + 审批等待的中心注册表（内核单例，对标侧车进程全局字典）。
/// C5（0.4.16）：取消事件是「已取消」唯一真相源；点停止立即唤醒，无轮询延迟。
public final class NativeWorkflowRuntimeCenter: @unchecked Sendable {

    private let lock = NSLock()
    private var cancelSet: Set<String> = []
    private var cancelWaiters: [String: [UUID: CheckedContinuation<Void, Never>]] = [:]
    private struct Approval {
        var isSet = false
        var approved = false
        var comment = ""
        var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    }
    private var approvals: [String: Approval] = [:]

    public init() {}

    // MARK: 取消（cancel_event / request_workflow_cancel / clear_workflow_cancel / is_workflow_cancelled）

    /// request_workflow_cancel：置位 → 等待方立即唤醒。
    public func requestCancel(_ runId: String) {
        lock.lock()
        cancelSet.insert(runId)
        let waiters = cancelWaiters[runId] ?? [:]
        cancelWaiters[runId] = [:]
        lock.unlock()
        for (_, cont) in waiters { cont.resume() }
    }

    /// is_workflow_cancelled（轮询式 bool 语义）。
    public func isCancelled(_ runId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelSet.contains(runId)
    }

    /// clear_workflow_cancel：整体丢弃（残留已置位会让同 run_id 下次运行开场即取消）。
    public func clearCancel(_ runId: String) {
        lock.lock()
        cancelSet.remove(runId)
        let waiters = cancelWaiters[runId] ?? [:]
        cancelWaiters[runId] = [:]
        lock.unlock()
        for (_, cont) in waiters { cont.resume() }
    }

    /// await 取消事件（懒建语义由集合+等待表天然覆盖；Task 取消 → 解除登记并返回）。
    public func awaitCancel(_ runId: String) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                // 竞态修复：onCancel 可能先于本闭包运行（任务在登记前已被取消，
                // 如 TaskGroup cancelAll 先于子任务首次调度）——此时查不到等待者，
                // onCancel 空转；本闭包必须自查取消态兜底，否则永久悬挂（0% CPU 死等）。
                var resumeNow = false
                lock.lock()
                if cancelSet.contains(runId) || Task<Never, Never>.isCancelled { resumeNow = true }
                else { cancelWaiters[runId, default: [:]][id] = cont }
                lock.unlock()
                if resumeNow { cont.resume() }
            }
        } onCancel: {
            lock.lock()
            let cont = cancelWaiters[runId]?[id]
            cancelWaiters[runId]?[id] = nil
            lock.unlock()
            cont?.resume()
        }
    }

    // MARK: 审批（_APPROVALS / resolve_workflow_approval）

    /// 引擎进入审批节点时登记（覆盖同 run_id 旧条目——Python 赋值语义）。
    public func registerApproval(_ runId: String) {
        lock.lock()
        approvals[runId] = Approval()
        lock.unlock()
    }

    /// 引擎离开审批（finally 弹栈）。
    public func unregisterApproval(_ runId: String) {
        lock.lock()
        let entry = approvals[runId]
        approvals[runId] = nil
        lock.unlock()
        // 防御：残留等待者放行（正常路径 resolve 已唤醒）
        for (_, cont) in entry?.waiters ?? [:] { cont.resume() }
    }

    /// resolve_workflow_approval：无挂起条目 → false（端点 409「审批已失效」）。
    @discardableResult
    public func resolveApproval(_ runId: String, approved: Bool, comment: String) -> Bool {
        lock.lock()
        guard var entry = approvals[runId] else {
            lock.unlock()
            return false
        }
        entry.isSet = true
        entry.approved = approved
        entry.comment = comment
        let waiters = entry.waiters
        entry.waiters = [:]
        approvals[runId] = entry
        lock.unlock()
        for (_, cont) in waiters { cont.resume() }
        return true
    }

    /// 审批决议读面（引擎等待循环退出后取）。
    public func approvalDecision(_ runId: String) -> (approved: Bool, comment: String)? {
        lock.lock()
        defer { lock.unlock() }
        guard let e = approvals[runId], e.isSet else { return nil }
        return (e.approved, e.comment)
    }

    /// await 审批决议（已决议立即返回；Task 取消 → 解除登记并返回）。
    public func awaitApproval(_ runId: String) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                // 同 awaitCancel 竞态修复：登记前已取消 → 自查取消态兜底。
                var resumeNow = false
                lock.lock()
                if approvals[runId]?.isSet == true || Task<Never, Never>.isCancelled { resumeNow = true }
                else { approvals[runId]?.waiters[id] = cont }
                lock.unlock()
                if resumeNow { cont.resume() }
            }
        } onCancel: {
            lock.lock()
            let cont = approvals[runId]?.waiters[id]
            approvals[runId]?.waiters[id] = nil
            lock.unlock()
            cont?.resume()
        }
    }
}

// MARK: - 引擎（WorkflowEngine 逐行为移植；actor 隔离 = asyncio 单循环交错同构）

public actor NativeWorkflowEngine {

    /// 审批等待期间的心跳间隔（APPROVAL_HEARTBEAT_S）。
    public static let approvalHeartbeatS: Double = 15.0

    /// 图片扩展名（_IMAGE_EXTS，0.2.3 自动继承用）。
    public static let imageExts: Set<String> = [".jpg", ".jpeg", ".png", ".gif", ".bmp",
                                                ".webp", ".tiff", ".heic"]

    /// C4（0.4.18）：file_read 走解析器的格式 = SUPPORTED − TEXT − IMAGE（推导口径，
    /// 对齐 parser.py：音频族 + .doc + pdf/docx/xlsx/xlsm/pptx；.csv 有意走纯文本路径）。
    public static let docParseExts: Set<String> = [
        ".wav", ".mp3", ".m4a", ".aac", ".aiff", ".aif", ".caf", ".flac", ".ogg", ".opus", ".webm",
        ".doc", ".pdf", ".docx", ".xlsx", ".xlsm", ".pptx",
    ]

    /// 源文件字节上限（二进制格式整读后解析的内存保护，20MB）。
    public static let fileReadMaxSourceBytes = 20 * 1024 * 1024

    /// 变量赋值保留名（_RESERVED_VAR_NAMES；sorted 序固定）。
    public static let reservedVarNames = ["batch", "item", "item_index", "params"]

    // MARK: 状态

    public let runId: String
    /// 节点表（id → 原始节点 dict；Python self.nodes）。
    public let nodes: [String: [String: JSONValue]]
    /// 定义序节点 id 清单（Python dict 插入序；start 节点选择用）。
    public let nodeOrder: [String]
    /// 边表（原始 dict 清单）。
    public let edges: [[String: JSONValue]]
    private let connector: NativeWorkflowConnector
    private let store: NativeWorkflowStore
    private let runtime: NativeWorkflowRuntimeCenter
    private let sandboxRoot: String
    private let toolExecutor: NativeWorkflowToolExecutor?
    /// 0.7.7 W6：vmodel 推理节点 agentic 执行缝（nil = 0.7.6 口径单段聚合；
    /// 生产由端点装配层接 kernel.vmodelAgenticRunner）。
    private let vmodelAgentic: NativeVModelAgenticFn?
    /// 全局非流式读超时动态取值（infer_options.timeout_reading 等价；错误文案用）。
    private let globalReadTimeout: @Sendable () -> Double

    /// 运行时变量（{"params": ...} 起步；node_id → {"output": ...}）。
    public private(set) var variables: [String: JSONValue]
    private var currentModel: String? = nil   // 当前驻留模型（卸载判定用）
    private var cancelled = false
    private var continuation: AsyncStream<WorkflowEngineEvent>.Continuation?
    private var producerTask: Task<Void, Never>?
    private var producerDone = false

    /// - Parameters:
    ///   - definition: 原始定义对象（nodes/edges/params——WorkflowDefinition.asJSONValue
    ///     或 DB definition 文本解析结果；props 保真）。
    ///   - toolExecutor: P2-W3 预留（nil → tool 节点如实失败）。
    ///   - globalReadTimeout: infer_options.timeout_reading 等价（错误文案取实际生效值）。
    public init(runId: String, definition: JSONValue, connector: NativeWorkflowConnector,
                store: NativeWorkflowStore, runtime: NativeWorkflowRuntimeCenter,
                sandboxRoot: String, params: [String: JSONValue]? = nil,
                toolExecutor: NativeWorkflowToolExecutor? = nil,
                globalReadTimeout: @escaping @Sendable () -> Double = { 300.0 },
                vmodelAgentic: NativeVModelAgenticFn? = nil) {
        self.runId = runId
        var nodeMap: [String: [String: JSONValue]] = [:]
        var order: [String] = []
        if case .object(let def) = definition, case .array(let ns) = def["nodes"] {
            for n in ns {
                guard case .object(let o) = n else { continue }
                let nid = WFText.strOrEmpty(o["id"])
                guard !nid.isEmpty else { continue }
                if nodeMap[nid] == nil { order.append(nid) }
                nodeMap[nid] = o
            }
        }
        self.nodes = nodeMap
        self.nodeOrder = order
        if case .object(let def) = definition, case .array(let es) = def["edges"] {
            self.edges = es.compactMap { $0.object }
        } else {
            self.edges = []
        }
        self.connector = connector
        self.store = store
        self.runtime = runtime
        self.sandboxRoot = sandboxRoot
        self.toolExecutor = toolExecutor
        self.globalReadTimeout = globalReadTimeout
        self.vmodelAgentic = vmodelAgentic
        self.variables = ["params": .object(params ?? [:])]
    }

    // ════════════════════════════════════════════════════════════
    // MARK: - 事件流（run() 消费者 + _emit 生产者）
    // ════════════════════════════════════════════════════════════

    /// engine.run()：执行工作流，产出事件流；终态事件后流结束。
    /// 消费方提前终止（客户端断开）→ 生产者取消 → run 记 stopped「客户端断开」。
    public func run() -> AsyncStream<WorkflowEngineEvent> {
        AsyncStream { continuation in
            Task { await self.start(continuation: continuation) }
        }
    }

    private func start(continuation: AsyncStream<WorkflowEngineEvent>.Continuation) {
        self.continuation = continuation
        let task = Task { await self.runMain() }
        self.producerTask = task
        continuation.onTermination = { @Sendable _ in
            // 客户端断开（Python agen.aclose() → 生产者 CancelledError 同语义）
            task.cancel()
        }
    }

    /// _emit：事件入队 + 统一注入 run_id（0.2.4 W1——此前仅审批/终态带，
    /// 前端运行中捕获不到 run_id，停止按钮空转）。
    private func emit(_ event: String, _ data: [String: JSONValue]) {
        var d = data
        d["run_id"] = .string(runId)
        continuation?.yield(WorkflowEngineEvent(event: event, data: d))
    }

    private func finishStream() {
        producerDone = true
        continuation?.finish()
    }

    // ════════════════════════════════════════════════════════════
    // MARK: - 主执行（_run_main 生产者）
    // ════════════════════════════════════════════════════════════

    private func runMain() async {
        let startNodes = nodeOrder.compactMap { nodes[$0] }.filter { $0["type"] == .string("start") }
        guard !startNodes.isEmpty else {
            // Python 怪癖保留：此路径不落库（run 记录停留 running）——strict 校验保证不可达
            emit("workflow_failed", ["error": .string("缺少开始节点")])
            finishStream()
            return
        }
        var node: [String: JSONValue]? = startNodes[0]
        var finalResult: JSONValue = .null
        do {
            while let cur = node {
                try checkCancel()
                let nodeId = WFText.strOrEmpty(cur["id"])
                try store.updateWorkflowRun(runId, currentNode: nodeId,
                                            variables: snapshotVars())
                emit("node_start", ["node_id": .string(nodeId),
                                    "label": .string(labelOrId(cur)),
                                    "type": cur["type"] ?? .null])
                try store.appendWorkflowNodeEvent(runId: runId, nodeId: nodeId,
                                                  nodeType: WFText.strOrEmpty(cur["type"]),
                                                  status: "running")

                var when: String? = nil
                let res: NativeNodeResult
                if cur["type"] == .string("condition") {
                    (res, when) = try await runCondition(cur)
                } else {
                    res = try await executeNode(cur)
                }

                variables[nodeId] = .object(["output": res.output])
                if cur["type"] == .string("end") {
                    // `out_ref = node.get("output")`；truthy 才解析（空串 → 取自身输出）
                    if let outRef = cur["output"], WFText.truthy(outRef) {
                        finalResult = Self.resolveValue(outRef, variables)
                    } else {
                        finalResult = res.output
                    }
                }

                if res.ok {
                    try store.appendWorkflowNodeEvent(
                        runId: runId, nodeId: nodeId,
                        nodeType: WFText.strOrEmpty(cur["type"]), status: "done",
                        modelUsed: res.modelUsed,
                        outputSummary: res.output == .null ? "" : WFText.pyPrefix(WFText.pyStr(res.output), 2000),
                        retryCount: res.retryCount, durationMs: res.durationMs)
                    emit("node_done", ["node_id": .string(nodeId),
                                       "output_preview": .string(
                                        WFText.truthy(res.output)
                                            ? WFText.pyPrefix(WFText.pyStr(res.output), 300) : "")])
                } else {
                    try store.appendWorkflowNodeEvent(
                        runId: runId, nodeId: nodeId,
                        nodeType: WFText.strOrEmpty(cur["type"]), status: "error",
                        modelUsed: res.modelUsed, error: res.error,
                        retryCount: res.retryCount, durationMs: res.durationMs)
                    emit("node_error", ["node_id": .string(nodeId),
                                        "error": res.error.map { .string($0) } ?? .null])
                    try store.updateWorkflowRun(runId, status: "failed",
                                                variables: snapshotVars(), error: res.error)
                    await releaseModel()
                    emit("workflow_failed", ["node_id": .string(nodeId),
                                             "error": res.error.map { .string($0) } ?? .null])
                    finishStream()
                    return
                }

                if cur["type"] == .string("end") { break }
                node = pickNext(cur, when: when)
            }

            try store.updateWorkflowRun(
                runId, status: "done",
                variables: snapshotVars(),
                result: finalResult == .null ? nil : WFText.pyPrefix(WFText.pyStr(finalResult), 4000))
            await releaseModel()
            emit("workflow_done", ["run_id": .string(runId),
                                   "result_preview": .string(
                                    WFText.truthy(finalResult)
                                        ? WFText.pyPrefix(WFText.pyStr(finalResult), 300) : "")])
            finishStream()
        } catch is WorkflowCancel {
            try? store.updateWorkflowRun(runId, status: "stopped",
                                         variables: snapshotVars(), error: "用户已停止")
            await releaseModel()
            emit("workflow_stopped", ["run_id": .string(runId)])
            finishStream()
        } catch is WorkflowClientDisconnect {
            // 客户端断开 → 生产者任务被取消：卸载模型后收尾（流已被消费方弃置）
            try? store.updateWorkflowRun(runId, status: "stopped",
                                         variables: snapshotVars(), error: "客户端断开")
            await releaseModel()
            finishStream()
        } catch is CancellationError {
            try? store.updateWorkflowRun(runId, status: "stopped",
                                         variables: snapshotVars(), error: "客户端断开")
            await releaseModel()
            finishStream()
        } catch {
            try? store.updateWorkflowRun(runId, status: "failed",
                                         variables: snapshotVars(),
                                         error: String(describing: error))
            await releaseModel()
            emit("workflow_failed", ["error": .string(String(describing: error))])
            finishStream()
        }
    }

    // ════════════════════════════════════════════════════════════
    // MARK: - 取消 / 模型驻留 / 边与后继
    // ════════════════════════════════════════════════════════════

    /// _check_cancel：取消事件（唯一真相源）或本地标志 → WorkflowCancel；
    /// Task 取消（客户端断开）→ WorkflowClientDisconnect。
    private func checkCancel() throws {
        if runtime.isCancelled(runId) || cancelled {
            cancelled = true
            throw WorkflowCancel()
        }
        if Task.isCancelled { throw WorkflowClientDisconnect() }
    }

    /// _ensure_model：不同 → 先卸旧；相同 → 不动。
    private func ensureModel(_ model: String) async {
        if let cur = currentModel, cur != model {
            await connector.unloadModel(cur)
        }
        currentModel = model
    }

    /// _release_model：工作流结束（任何路径）卸载最后驻留模型。
    private func releaseModel() async {
        if let cur = currentModel {
            _ = await connector.unloadModel(cur)
            currentModel = nil
        }
    }

    private func outEdges(_ nodeId: String) -> [[String: JSONValue]] {
        edges.filter { WFText.strOrEmpty($0["from"]) == nodeId }
    }

    /// _pick_next：按 when 标签选下一条边；无条件取唯一（第一条）出边。
    /// 怪癖保留：`str(e.get("when",""))` —— when 缺省 ""、null 渲染 "None"。
    private func pickNext(_ node: [String: JSONValue], when: String? = nil) -> [String: JSONValue]? {
        let outs = outEdges(WFText.strOrEmpty(node["id"]))
        guard !outs.isEmpty else { return nil }
        if let when {
            for e in outs {
                let edgeWhen: String = {
                    guard let w = e["when"] else { return "" }
                    return WFText.pyStr(w)
                }()
                if edgeWhen == when { return nodes[WFText.strOrEmpty(e["to"])] }
            }
            return nil
        }
        return nodes[WFText.strOrEmpty(outs[0]["to"])]
    }

    private func labelOrId(_ node: [String: JSONValue]) -> String {
        // node.get("label") or node_id
        if let l = node["label"], WFText.truthy(l) { return WFText.pyStr(l) }
        return WFText.strOrEmpty(node["id"])
    }

    // ════════════════════════════════════════════════════════════
    // MARK: - 模板与求值（render_template / resolve_value / _eval_condition）
    // ════════════════════════════════════════════════════════════

    private static let tplRegex = try! NSRegularExpression(pattern: #"\{\{\s*([\w.\-]+)\s*\}\}"#)
    private static let tplFullRegex = try! NSRegularExpression(pattern: #"^\{\{\s*([\w.\-]+)\s*\}\}$"#)

    /// 变量路径查找（{{a.b.c}} 逐段下钻；任一段缺失 → nil）。
    static func lookupPath(_ path: String, _ variables: [String: JSONValue]) -> JSONValue? {
        var cur: JSONValue = .object(variables)
        for part in path.split(separator: ".").map(String.init) {
            guard case .object(let o) = cur, let next = o[part] else { return nil }
            cur = next
        }
        return cur
    }

    /// render_template：{{node.output}} / {{params.x}} / {{item}} 替换；
    /// 列表/字典 → 紧凑 JSON 文本；未定义占位符原样保留。
    public static func renderTemplate(_ text: String, _ variables: [String: JSONValue]) -> String {
        if text.isEmpty { return text }
        let ns = text as NSString
        let matches = tplRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return text }
        var out = ""
        var last = 0
        for m in matches {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let token = ns.substring(with: m.range(at: 1))
            if let v = lookupPath(token, variables) {
                switch v {
                case .array, .object:
                    out += NativeDatabase.dumpsUTF8(v)   // json.dumps(ensure_ascii=False)
                default:
                    out += WFText.pyStr(v)
                }
            } else {
                out += ns.substring(with: m.range)   // 未定义 → 原样保留
            }
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    /// resolve_value：整串 "{{...}}" → 原值（保持类型，缺失 → .null）；
    /// 含模板字符串 → 渲染；其他原样。
    public static func resolveValue(_ ref: JSONValue, _ variables: [String: JSONValue]) -> JSONValue {
        guard case .string(let s) = ref else { return ref }
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        let ns = trimmed as NSString
        if let m = tplFullRegex.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)) {
            let token = ns.substring(with: m.range(at: 1))
            return lookupPath(token, variables) ?? .null
        }
        return .string(renderTemplate(s, variables))
    }

    /// resolve_images：node.images（变量引用或列表）→ 字符串列表。
    static func resolveImages(_ node: [String: JSONValue], _ variables: [String: JSONValue]) -> [String] {
        guard let raw = node["images"], raw != .null else { return [] }
        let val = resolveValue(raw, variables)
        if case .array(let arr) = val {
            return arr.compactMap { WFText.truthy($0) ? WFText.pyStr($0) : nil }
        }
        if case .string(let s) = val, !s.isEmpty { return [s] }
        return []
    }

    /// _eval_condition（静态匹配七种算子）。
    static func evalCondition(_ node: [String: JSONValue], _ variables: [String: JSONValue]) -> Bool {
        let match = node["match"]?.object ?? [:]
        let target = resolveValue(match["variable"] ?? .string(""), variables)
        let op = WFText.strOrEmpty(match["operator"])
        let value: String = match["value"].map { WFText.pyStr($0) } ?? ""
        let text = target == .null ? "" : WFText.pyStr(target)
        switch op {
        case "contains": return text.contains(value)
        case "not_contains": return !text.contains(value)
        case "equals": return text == value
        case "starts_with": return text.hasPrefix(value)
        case "regex":
            guard let re = try? NSRegularExpression(pattern: value) else { return false }
            return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        case "empty": return text.trimmingCharacters(in: .whitespaces).isEmpty
        case "not_empty": return !text.trimmingCharacters(in: .whitespaces).isEmpty
        default: return false
        }
    }

    /// _node_timeout_s（REQ-WF-015）：读节点 timeout_s；无效/未配 → nil（全局默认）。
    /// bool 拒绝；NaN/inf 拒绝；clamp 10~7200。
    public static func nodeTimeoutS(_ node: [String: JSONValue]) -> Double? {
        guard let raw = node["timeout_s"], raw != .null else { return nil }
        if case .bool = raw { return nil }
        guard let f = PySem.toFloat(raw) else { return nil }   // 数值字符串宽松（Python float(raw)）
        return min(max(f, 10.0), 7200.0)
    }

    /// int(x or default)（try/except → default）：retry/max_failures/wait_ms/batch_size 共用。
    static func pyInt(_ v: JSONValue?, default def: Int) -> Int {
        guard let v, WFText.truthy(v) else { return def }
        switch v {
        case .bool(let b): return b ? 1 : 0
        case .int(let i): return Int(i)
        case .double(let d): return d.isFinite ? Int(d) : def
        case .string(let s):
            return Int(s.trimmingCharacters(in: .whitespaces)) ?? def
        default: return def
        }
    }

    /// _exc_text：异常 → 可诊断文本（永远带类型名；超时走专项提示）。
    static func excText(_ error: Error, timeoutHint: String = "") -> String {
        if let e = error as? WorkflowConnectorError {
            if e == .timeout {
                return timeoutHint.isEmpty ? "超时：TimeoutError（已等待超过上限仍未返回）" : timeoutHint
            }
            let msg = e.pyMessage
            return msg.isEmpty ? "\(e.pyTypeName)（无附加消息）" : "\(e.pyTypeName): \(msg)"
        }
        let msg = String(describing: error)
        let typeName = String(describing: type(of: error))
        return msg.isEmpty ? "\(typeName)（无附加消息）" : "\(typeName): \(msg)"
    }

    /// Python str[:n] 路径排序（码点序；排序键 str(f) 保真）。
    static func pySorted(_ items: [String]) -> [String] {
        items.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
    }

    /// Path(name).name（末段；去尾斜杠后取）。
    static func pyPathName(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return (p as NSString).lastPathComponent
    }

    /// Path(name).stem（name 去末扩展名；".hidden" stem=".hidden"）。
    static func pyPathStem(_ path: String) -> String {
        let name = pyPathName(path)
        guard let dot = name.lastIndex(of: "."), dot > name.startIndex else { return name }
        return String(name[name.startIndex..<dot])
    }

    /// Path.suffix 小写（无点/点前无名 → ""）。
    static func pySuffixLower(_ path: String) -> String {
        let name = pyPathName(path)
        guard let dot = name.lastIndex(of: "."), dot > name.startIndex else { return "" }
        return String(name[dot...]).lowercased()
    }

    /// _snapshot_vars：运行快照（长文本截 2000，保证可序列化）。
    func snapshotVars() -> JSONValue {
        var snap: [String: JSONValue] = [:]
        for (k, v) in variables {
            if case .object(let o) = v, let out = o["output"] {
                snap[k] = .object(["output": out == .null ? .null
                                   : .string(WFText.pyPrefix(WFText.pyStr(out), 2000))])
            } else {
                snap[k] = v
            }
        }
        return .object(snap)
    }

    // ════════════════════════════════════════════════════════════
    // MARK: - 可中断的模型调用（_interruptible_chat：chat 与取消事件竞速）
    // ════════════════════════════════════════════════════════════

    private func interruptibleChat(model: String, userContent: String, images: [String],
                                   readTimeoutS: Double?) async throws -> String {
        try checkCancel()
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await self.connector.chat(
                    model: model,
                    messages: [["role": .string("user"), "content": .string(userContent)]],
                    images: images.isEmpty ? nil : images,
                    readTimeoutS: readTimeoutS)
            }
            group.addTask {
                await self.runtime.awaitCancel(self.runId)
                throw WorkflowCancel()
            }
            do {
                let result = try await group.next()!
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    /// 0.7.7 W6：vmodel 推理节点的 agentic 执行（与 interruptibleChat 同取消
    /// 竞速纪律：awaitCancel 先到 → WorkflowCancel；回路内另经 cancelCheck
    /// 逐轮自查——点停即停，多轮场景不依赖单点）。CancellationError 归位：
    /// 用户停止 → WorkflowCancel；客户端断开（Task 取消）→ WorkflowClientDisconnect。
    private func interruptibleAgentic(agentic: @escaping NativeVModelAgenticFn, model: String,
                                      userContent: String) async throws
        -> NativeVModelAgenticOutcome {
        try checkCancel()
        let req = NativeVModelAgenticRequest(
            model: model,
            messages: [["role": .string("user"), "content": .string(userContent)]],
            surface: "workflow", projectId: "",   // 工作流无项目上下文（诚实缺省）
            sandboxRoot: sandboxRoot,
            maxRounds: NativeVModelAgentic.workflowNodeMaxRounds,
            cancelCheck: { [runtime, runId] in runtime.isCancelled(runId) })
        return try await withThrowingTaskGroup(of: NativeVModelAgenticOutcome.self) { group in
            group.addTask { try await agentic(req) }
            group.addTask {
                await self.runtime.awaitCancel(self.runId)
                throw WorkflowCancel()
            }
            do {
                let result = try await group.next()!
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    // ════════════════════════════════════════════════════════════
    // MARK: - 节点执行器（13 执行类 + start/end；_execute_node 含重试）
    // ════════════════════════════════════════════════════════════

    /// _execute_node：执行单个节点（含退避重试 min(2*attempt, 10)s）。
    func executeNode(_ node: [String: JSONValue]) async throws -> NativeNodeResult {
        let retryLimit = Self.pyInt(node["retry"], default: 0)
        var attempt = 0
        let t0 = Date()
        while true {
            try checkCancel()
            let ntype = WFText.strOrEmpty(node["type"])
            var res: NativeNodeResult
            switch ntype {
            case "inference": res = try await runInference(node)
            case "tool": res = await runTool(node)
            case "parallel": res = try await runParallel(node)
            case "loop": res = try await runLoop(node)
            case "approval": res = try await runApproval(node)
            case "file_input": res = runFileInput(node)
            case "file_output": res = runFileOutput(node)
            case "file_read": res = await runFileRead(node)
            case "text_output": res = runTextOutput(node)
            case "variable_set": res = runVariableSet(node)
            case "code": res = try await runCode(node)
            case "reply": res = runReply(node)
            case "start", "end": res = NativeNodeResult(nodeId: WFText.strOrEmpty(node["id"]))
            case "condition":
                // 0.2.4（W5）：条件节点在循环/并行体内作为求值器执行（不做分支跳转）
                let (r, _) = try await runCondition(node)
                res = r
            default:
                res = NativeNodeResult(nodeId: WFText.strOrEmpty(node["id"]), ok: false,
                                       error: "未知节点类型：\(ntype)")
            }
            res.durationMs = Int(Date().timeIntervalSince(t0) * 1000)
            res.retryCount = attempt
            if res.ok || attempt >= retryLimit { return res }
            attempt += 1
            do {
                try await Task.sleep(nanoseconds: UInt64(min(2 * attempt, 10)) * 1_000_000_000)
            } catch {
                throw WorkflowClientDisconnect()
            }
        }
    }

    // ---- inference（_run_inference：纯调用，无工具无系统提示词）----

    func runInference(_ node: [String: JSONValue]) async throws -> NativeNodeResult {
        let nodeId = WFText.strOrEmpty(node["id"])
        let model = WFText.strOrEmpty(node["model"]).trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else {
            return NativeNodeResult(nodeId: nodeId, ok: false, error: "推理节点未配置模型")
        }
        await ensureModel(model)
        let prompt = Self.renderTemplate(WFText.strOrEmpty(node["prompt"]), variables)
        var images = Self.resolveImages(node, variables)
        // 0.2.3：自动图片继承（未配 images 且上游 file_input / 循环上下文）
        if images.isEmpty { images = inheritUpstreamImages(node) }
        // 0.2.4（W8）：仅图片保护——剔除非图片扩展名本地文件，剔除发事件不静默
        let (kept, dropped) = Self.keepImageFiles(images)
        images = kept
        if !dropped.isEmpty {
            emit("images_dropped", [
                "node_id": .string(nodeId),
                "dropped": .array(dropped.prefix(10).map { .string($0) }),
                "reason": .string("非图片文件（如音频）不能作为图片输入，已剔除"),
            ])
        }
        let userContent = prompt.isEmpty ? "请处理输入。" : prompt
        let nodeTimeout = Self.nodeTimeoutS(node)
        // 0.7.7 W6：vmodel 节点且已装配 agentic 缝 → 工具调用回路（多步 +
        // 知识库/文件等既有工具集）；降级时回路返回单轮聚合文本 + 中文提示，
        // 提示以 [⚠️ …] 并入节点输出透出（与剥图降级注记同款先例，不静默）。
        // 图片不参与（.vmodel 契约当前纯文本，与 connector vmodel 分支同口径）。
        if NativeVModelChat.isVModelName(model), let agentic = vmodelAgentic {
            do {
                let outcome = try await interruptibleAgentic(agentic: agentic,
                                                             model: model,
                                                             userContent: userContent)
                var text = outcome.text
                if let notice = outcome.notice, !notice.isEmpty {
                    text += (text.isEmpty ? "" : "\n\n") + "[⚠️ \(notice)]"
                }
                return NativeNodeResult(nodeId: nodeId, output: .string(text),
                                        modelUsed: model)
            } catch let cancel as WorkflowCancel {
                throw cancel
            } catch is CancellationError {
                // 回路内取消归位：用户停止 / 客户端断开按既有语义分流
                try checkCancel()   // Task 取消 → WorkflowClientDisconnect；标志 → WorkflowCancel
                throw WorkflowCancel()
            } catch {
                // 降级聚合亦失败：错误如实落节点（不静默、不换模型）
                return NativeNodeResult(nodeId: nodeId, ok: false,
                                        error: "模型调用失败：\(Self.excText(error))",
                                        modelUsed: model)
            }
        }
        do {
            let text = try await interruptibleChat(model: model, userContent: userContent,
                                                   images: images, readTimeoutS: nodeTimeout)
            return NativeNodeResult(nodeId: nodeId, output: .string(text), modelUsed: model)
        } catch let cancel as WorkflowCancel {
            throw cancel
        } catch {
            // 0.4.11/0.4.28：超时专项提示写**实际生效**秒数（节点 timeout_s 优先于全局值）
            // ⚠️ Python f"{x:.0f}" 是 IEEE 半进偶（600.5→"600"）——String(format:) 同口径，
            //    不可用 Int(x.rounded())（半远离零 → 601，逐字漂移）。
            let effTimeout = nodeTimeout ?? globalReadTimeout()
            let hint = "模型调用超时：TimeoutError。已等待 \(String(format: "%.0f", effTimeout))s 仍未返回"
                + "（非流式调用的 reading 超时上限）。常见原因：本地大参数模型（如 35B）"
                + "处理超长文本推理耗时超过该上限。可尝试：① 减小单批输入（循环节点分批更小）"
                + "② 换更小的模型 ③ 给本节点配置更大的 timeout_s（秒，10~7200），"
                + "或在 设置→推理 调大「非流式读超时」。模型：\(model)"
            return NativeNodeResult(nodeId: nodeId, ok: false,
                                    error: "模型调用失败：\(Self.excText(error, timeoutHint: hint))",
                                    modelUsed: model)
        }
    }

    /// 0.2.3：推理节点未配置 images 时自动继承上游图片（file_input 上游 → 循环上下文）。
    private func inheritUpstreamImages(_ node: [String: JSONValue]) -> [String] {
        let nodeId = WFText.strOrEmpty(node["id"])
        let incoming = edges.filter { WFText.strOrEmpty($0["to"]) == nodeId }
        for e in incoming {
            guard let src = nodes[WFText.strOrEmpty(e["from"])],
                  src["type"] == .string("file_input") else { continue }
            let val: JSONValue? = {
                guard case .object(let o) = variables[WFText.strOrEmpty(src["id"])] else { return nil }
                return o["output"]
            }()
            guard let val, WFText.truthy(val) else { continue }
            let list: [JSONValue] = (val.array) ?? [val]
            let imgs = Self.filterImagePaths(list)
            if !imgs.isEmpty { return imgs }
        }
        // 循环上下文（batch / item）
        if let batch = variables["batch"] {
            let imgs = Self.filterImagePaths(batch.array ?? [batch])
            if !imgs.isEmpty { return imgs }
        }
        if let item = variables["item"] {
            let imgs = Self.filterImagePaths(item.array ?? [item])
            if !imgs.isEmpty { return imgs }
        }
        return []
    }

    /// _filter_image_paths：真实存在且扩展名为图片的文件路径。
    static func filterImagePaths(_ paths: [JSONValue]) -> [String] {
        paths.compactMap { v in
            let p = WFText.pyStr(v)
            guard FileManager.default.fileExists(atPath: p),
                  imageExts.contains(pySuffixLower(p)) else { return nil }
            return p
        }
    }

    /// _keep_image_files（0.2.4 W8）：仅图片保护。（保留, 剔除）两组。
    static func keepImageFiles(_ images: [String]) -> (kept: [String], dropped: [String]) {
        var kept: [String] = []
        var dropped: [String] = []
        for img in images {
            if img.isEmpty { dropped.append(img); continue }
            if img.hasPrefix("data:") { kept.append(img); continue }
            if FileManager.default.fileExists(atPath: img) {
                if imageExts.contains(pySuffixLower(img)) { kept.append(img) }
                else { dropped.append(img) }
                continue
            }
            if img.count > 50 { kept.append(img) }   // 视为已编码 base64
            else { dropped.append(img) }
        }
        return (kept, dropped)
    }

    // ---- tool（_run_tool；P2-W3 接口预留）----

    private func runTool(_ node: [String: JSONValue]) async -> NativeNodeResult {
        let nodeId = WFText.strOrEmpty(node["id"])
        let toolName = WFText.strOrEmpty(node["tool"]).trimmingCharacters(in: .whitespaces)
        guard !toolName.isEmpty else {
            return NativeNodeResult(nodeId: nodeId, ok: false, error: "工具节点未配置 tool")
        }
        guard let toolExecutor else {
            return NativeNodeResult(nodeId: nodeId, ok: false,
                                    error: "工具执行异常：RuntimeError: 工具注册表尚未原生接管"
                                        + "（P2-W3 排期；原生内核期工作流暂不支持 tool 节点）")
        }
        var args: [String: JSONValue] = [:]
        if case .object(let rawArgs) = node["args"] {
            for (k, v) in rawArgs { args[k] = Self.resolveValue(v, variables) }
        }
        do {
            let result = try await toolExecutor.executeTool(toolName, args: args,
                                                            sandboxRoot: sandboxRoot)
            guard result["ok"] == .bool(true) else {
                let err = (result["error"]?.string) ?? "工具执行失败"
                return NativeNodeResult(nodeId: nodeId, ok: false, error: err)
            }
            return NativeNodeResult(nodeId: nodeId, output: .object(result))
        } catch {
            return NativeNodeResult(nodeId: nodeId, ok: false,
                                    error: "工具执行异常：\(Self.excText(error))")
        }
    }

    // ---- condition（_run_condition：静态匹配 / 动态裁判）----

    /// 返回（结果, when 标签）。动态裁判输出首行即分支名；失败按 "false" 继续。
    func runCondition(_ node: [String: JSONValue]) async throws -> (NativeNodeResult, String) {
        let nodeId = WFText.strOrEmpty(node["id"])
        let model = WFText.strOrEmpty(node["model"]).trimmingCharacters(in: .whitespaces)
        if !model.isEmpty {
            await ensureModel(model)
            let promptRaw: String = {
                guard let p = node["prompt"], WFText.truthy(p) else { return "请判断并只输出分支名。" }
                return WFText.pyStr(p)
            }()
            let prompt = Self.renderTemplate(promptRaw, variables)
            let nodeTimeout = Self.nodeTimeoutS(node)
            do {
                let text = try await interruptibleChat(model: model, userContent: prompt,
                                                       images: [], readTimeoutS: nodeTimeout)
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                let branch = lines.first ?? ""
                return (NativeNodeResult(nodeId: nodeId, output: .string(branch),
                                         modelUsed: model), branch)
            } catch let cancel as WorkflowCancel {
                throw cancel
            } catch {
                let effTimeout = nodeTimeout ?? globalReadTimeout()
                let hint = "裁判模型调用超时：TimeoutError。已等待 "
                    + "\(String(format: "%.0f", effTimeout))s 仍未返回（条件分支的动态裁判无法判定，"
                    + "已按 false 分支继续）。模型：\(model)"
                return (NativeNodeResult(nodeId: nodeId, ok: false,
                                         error: "裁判模型调用失败：\(Self.excText(error, timeoutHint: hint))",
                                         modelUsed: model), "false")
            }
        }
        let hit = Self.evalCondition(node, variables)
        return (NativeNodeResult(nodeId: nodeId, output: .bool(hit)), hit ? "true" : "false")
    }

    // ---- parallel（_run_parallel：branches 并发，输出收集为列表）----

    private func runParallel(_ node: [String: JSONValue]) async throws -> NativeNodeResult {
        let nodeId = WFText.strOrEmpty(node["id"])
        let branches: [String] = (node["branches"]?.array ?? [])
            .map { WFText.pyStr($0) }
            .filter { nodes[$0] != nil }
        guard !branches.isEmpty else {
            return NativeNodeResult(nodeId: nodeId, ok: false, error: "并行节点未配置 branches")
        }
        // asyncio.gather 保序语义：结果按分支声明序（TaskGroup 完成序 → 按下标归位）
        let results: [NativeNodeResult] = try await withThrowingTaskGroup(
            of: (Int, NativeNodeResult).self
        ) { group in
            for (idx, b) in branches.enumerated() {
                group.addTask { [nodes] in
                    let r = try await self.executeNode(nodes[b]!)
                    return (idx, r)
                }
            }
            var collected: [Int: NativeNodeResult] = [:]
            while let (idx, r) = try await group.next() {
                collected[idx] = r
            }
            return (0..<branches.count).compactMap { collected[$0] }
        }
        let outputs = results.map { $0.output }
        let errors = results.filter { !$0.ok }
            .map { "\($0.nodeId): \($0.error ?? "")" }
        if !errors.isEmpty {
            return NativeNodeResult(nodeId: nodeId, ok: false,
                                    output: .array(outputs),
                                    error: errors.joined(separator: "；"))
        }
        return NativeNodeResult(nodeId: nodeId, output: .array(outputs))
    }

    // ---- loop（_run_loop：逐项/分批 + 顺序链 + 失败策略 + 批间等待）----

    private func runLoop(_ node: [String: JSONValue]) async throws -> NativeNodeResult {
        let nodeId = WFText.strOrEmpty(node["id"])
        let items = Self.resolveValue(node["items"] ?? .string(""), variables)
        guard case .array(let itemList) = items else {
            return NativeNodeResult(nodeId: nodeId, ok: false,
                                    error: "loop.items 不是列表：\(WFText.pyTypeName(items))")
        }
        let chainIds: [String]
        switch node["branch"] {
        case .string(let raw):
            // 0.2.3：逗号分隔顺序链（前端表单形态 "ocr,save"）
            let parts = raw.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            chainIds = parts.isEmpty ? (raw.isEmpty ? [] : [raw]) : parts
        case .array(let arr):
            chainIds = arr.map { WFText.pyStr($0) }
        default:
            chainIds = []
        }
        let chainNodes = chainIds.map { nodes[$0] }
        if chainNodes.isEmpty || chainNodes.contains(where: { $0 == nil }) {
            return NativeNodeResult(nodeId: nodeId, ok: false, error: "loop.branch 节点不存在")
        }
        let chains = chainNodes.compactMap { $0 }

        // 0.2.4（W2）：失败策略与容忍上限
        var failPolicy = WFText.strOrEmpty(node["fail_policy"]).trimmingCharacters(in: .whitespaces).lowercased()
        if failPolicy.isEmpty { failPolicy = "abort" }
        if failPolicy == "continue" { failPolicy = "skip" }   // 别名归一
        if failPolicy != "abort" && failPolicy != "skip" { failPolicy = "abort" }
        let maxFailures = Self.pyInt(node["max_failures"], default: 0)
        let waitMs = max(0, Self.pyInt(node["wait_ms"], default: 0))

        // 0.2.3：分批（batch_size>1 时每轮 {{item}} 是一批列表）
        let batchSize = Self.pyInt(node["batch_size"], default: 0)
        var batches: [[JSONValue]] = []
        if batchSize > 1 {
            var i = 0
            while i < itemList.count {
                batches.append(Array(itemList[i..<min(i + batchSize, itemList.count)]))
                i += batchSize
            }
        } else {
            batches = itemList.map { [$0] }
        }

        var outputs: [JSONValue] = []
        var failedBatches: [String] = []
        for (idx, batch) in batches.enumerated() {
            try checkCancel()
            // 单元素批保持旧行为（{{item}} 为单个元素），多元素批 {{item}} 为列表
            let first: JSONValue = batch.count == 1 ? batch[0] : .array(batch)
            variables["item"] = first
            variables["item_index"] = .int(Int64(idx))
            variables["batch"] = .array(batch)
            // 0.2.3：{{item_name}} / {{item_stem}}
            if case .string(let firstStr) = first {
                variables["item_name"] = .string(Self.pyPathName(firstStr))
                variables["item_stem"] = .string(Self.pyPathStem(firstStr))
            } else {
                variables.removeValue(forKey: "item_name")
                variables.removeValue(forKey: "item_stem")
            }
            var lastOutput: JSONValue = .null
            var batchOk = true
            var batchError: String? = nil
            for cnode in chains {
                let r = try await executeNode(cnode)
                if !r.ok {
                    batchOk = false
                    batchError = r.error
                    break
                }
                // 链内中间节点输出写入变量空间
                variables[WFText.strOrEmpty(cnode["id"])] = .object(["output": r.output])
                lastOutput = r.output
            }

            if batchOk {
                outputs.append(lastOutput)
            } else {
                let desc = "第 \(idx + 1) 批：\(batchError ?? "")"
                if failPolicy == "abort" {
                    return NativeNodeResult(nodeId: nodeId, ok: false,
                                            output: .array(outputs), error: desc)
                }
                failedBatches.append(desc)
                outputs.append(.null)
                emit("loop_batch_skipped", ["loop_id": .string(nodeId),
                                            "batch_index": .int(Int64(idx)),
                                            "error": .string(batchError ?? "")])
                if maxFailures > 0 && failedBatches.count >= maxFailures {
                    return NativeNodeResult(
                        nodeId: nodeId, ok: false, output: .array(outputs),
                        error: "失败批数达到上限（\(failedBatches.count)/\(maxFailures)）："
                            + failedBatches.prefix(3).joined(separator: "；"))
                }
            }

            // 0.2.4（W9）：批间等待（最后一批后不等；等待期间可被取消）
            if waitMs > 0 && idx < batches.count - 1 {
                var waited = 0.0
                let step = 0.5
                let total = Double(waitMs) / 1000.0
                while waited < total {
                    try checkCancel()
                    let slice = min(step, total - waited)
                    do {
                        try await Task.sleep(nanoseconds: UInt64(slice * 1_000_000_000))
                    } catch {
                        throw WorkflowClientDisconnect()
                    }
                    waited += step
                }
            }
        }

        variables.removeValue(forKey: "item")
        variables.removeValue(forKey: "item_index")
        variables.removeValue(forKey: "batch")
        variables.removeValue(forKey: "item_name")
        variables.removeValue(forKey: "item_stem")
        return NativeNodeResult(nodeId: nodeId, output: .array(outputs))
    }

    // ---- approval（_run_approval：挂起 + 15s 心跳 + 决议唤醒）----

    private func runApproval(_ node: [String: JSONValue]) async throws -> NativeNodeResult {
        let nodeId = WFText.strOrEmpty(node["id"])
        runtime.registerApproval(runId)
        try store.updateWorkflowRun(runId, status: "awaiting_approval",
                                    currentNode: nodeId, variables: snapshotVars())
        let messageRaw: String = {
            guard let m = node["message"], WFText.truthy(m) else { return "请确认是否继续。" }
            return WFText.pyStr(m)
        }()
        emit("approval_required", [
            "run_id": .string(runId),   // Python 显式带一份（_emit 再注入同键，幂等）
            "node_id": .string(nodeId),
            "label": .string(labelOrId(node, default: "人工审批")),
            "message": .string(Self.renderTemplate(messageRaw, variables)),
        ])
        // 等待决议；15s 心跳保活（审批可能等待很久）
        while true {
            let resolved = await withTaskGroup(of: Bool.self) { group in
                group.addTask { await self.runtime.awaitApproval(self.runId); return true }
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(Self.approvalHeartbeatS * 1_000_000_000))
                    return false
                }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            if resolved { break }
            // 心跳直发（Python 不经 _emit——但 data 同样只有 run_id）
            continuation?.yield(WorkflowEngineEvent(event: "heartbeat",
                                                    data: ["run_id": .string(runId)]))
        }
        // Python 是 pop 后本地持有 entry：先取决议再注销，顺序不可颠倒
        let decision = runtime.approvalDecision(runId)
        runtime.unregisterApproval(runId)
        // 被停止（驳回解锁）→ 优先走取消路径
        try checkCancel()
        if decision?.approved != true {
            return NativeNodeResult(nodeId: nodeId, ok: false,
                                    error: "审批被驳回：\(decision?.comment.isEmpty == false ? decision!.comment : "用户驳回")")
        }
        return NativeNodeResult(nodeId: nodeId,
                                output: .string(decision?.comment.isEmpty == false ? decision!.comment : "approved"))
    }

    /// label 或缺省文案（审批节点专用：node.get("label") or "人工审批"）。
    private func labelOrId(_ node: [String: JSONValue], default def: String) -> String {
        if let l = node["label"], WFText.truthy(l) { return WFText.pyStr(l) }
        return def
    }

    // ---- file_input（_run_file_input，0.2.2：纯本地不联网）----

    private func runFileInput(_ node: [String: JSONValue]) -> NativeNodeResult {
        let nodeId = WFText.strOrEmpty(node["id"])
        let rawPath = Self.renderTemplate(WFText.strOrEmpty(node["path"]), variables)
        guard !rawPath.trimmingCharacters(in: .whitespaces).isEmpty else {
            return NativeNodeResult(nodeId: nodeId, ok: false, error: "文件输入节点未配置 path")
        }
        let p = (rawPath as NSString).expandingTildeInPath
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: p, isDirectory: &isDir) else {
            return NativeNodeResult(nodeId: nodeId, ok: false, error: "路径不存在：\(p)")
        }

        let exts = Set(WFText.strOrEmpty(node["extensions"]).split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { $0.lowercased().trimmingPrefix(".") })
        let recursive = WFText.truthy(node["recursive"])

        var files: [String] = []
        if !isDir.boolValue {
            files = [p]
        } else if recursive {
            if let en = fm.enumerator(atPath: p) {
                for case let rel as String in en {
                    let full = (p as NSString).appendingPathComponent(rel)
                    var dirFlag: ObjCBool = false
                    if fm.fileExists(atPath: full, isDirectory: &dirFlag), !dirFlag.boolValue {
                        files.append(full)
                    }
                }
            }
        } else {
            if let items = try? fm.contentsOfDirectory(atPath: p) {
                for rel in items {
                    let full = (p as NSString).appendingPathComponent(rel)
                    var dirFlag: ObjCBool = false
                    if fm.fileExists(atPath: full, isDirectory: &dirFlag), !dirFlag.boolValue {
                        files.append(full)
                    }
                }
            }
        }
        if !exts.isEmpty {
            files = files.filter {
                exts.contains(Self.pySuffixLower($0).trimmingPrefix("."))
            }
        }
        files = Self.pySorted(files)
        guard !files.isEmpty else {
            let extDesc = exts.isEmpty ? "全部" : WFText.pyListRepr(Self.pySorted(exts.map { String($0) }))
            return NativeNodeResult(nodeId: nodeId, ok: false,
                                    error: "文件夹内没有匹配的文件：\(p)（extensions=\(extDesc)）")
        }
        return NativeNodeResult(nodeId: nodeId, output: .array(files.map { .string($0) }))
    }

    // ---- file_output（_run_file_output：防路径穿越 + 模板写入）----

    private func runFileOutput(_ node: [String: JSONValue]) -> NativeNodeResult {
        let nodeId = WFText.strOrEmpty(node["id"])
        let directory = Self.renderTemplate(WFText.strOrEmpty(node["dir"]), variables)
        let filename = Self.renderTemplate(WFText.strOrEmpty(node["filename"]), variables)
        let content = Self.renderTemplate(WFText.strOrEmpty(node["content"]), variables)
        let encoding = WFText.strOrEmpty(node["encoding"]).isEmpty
            ? "utf-8" : WFText.pyStr(node["encoding"] ?? .string("utf-8"))
        guard !directory.trimmingCharacters(in: .whitespaces).isEmpty,
              !filename.trimmingCharacters(in: .whitespaces).isEmpty else {
            return NativeNodeResult(nodeId: nodeId, ok: false,
                                    error: "文件输出节点需配置 dir 与 filename")
        }
        let targetDir = (directory as NSString).expandingTildeInPath
        // 防路径穿越：文件名不允许含分隔符/..
        let fname = Self.pyPathName(filename)
        if fname.isEmpty || fname != filename || filename.contains("..") {
            return NativeNodeResult(nodeId: nodeId, ok: false,
                                    error: "filename 不合法（不允许路径分隔符/..）：\(WFText.pyReprString(filename))")
        }
        guard let enc = Self.mapEncoding(encoding) else {
            return NativeNodeResult(nodeId: nodeId, ok: false,
                                    error: "写入失败：LookupError: unknown encoding: \(encoding)")
        }
        do {
            try FileManager.default.createDirectory(atPath: targetDir, withIntermediateDirectories: true)
            let target = (targetDir as NSString).appendingPathComponent(fname)
            try content.write(toFile: target, atomically: false, encoding: enc)
        } catch {
            return NativeNodeResult(nodeId: nodeId, ok: false,
                                    error: "写入失败：\(Self.excText(error))")
        }
        return NativeNodeResult(nodeId: nodeId,
                                output: .string((targetDir as NSString).appendingPathComponent(fname)))
    }

    /// Python encoding 名 → String.Encoding（常用映射；未知 → nil 走 LookupError 文案）。
    private static func mapEncoding(_ name: String) -> String.Encoding? {
        switch name.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "utf-8", "utf8", "u8": return .utf8
        case "utf-16", "utf16": return .utf16
        case "gbk", "gb2312", "gb18030", "gbk18030":
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        case "latin-1", "latin1", "iso-8859-1": return .isoLatin1
        case "ascii", "us-ascii": return .ascii
        default: return nil
        }
    }

    // ---- text_output / variable_set / code / reply（TS-121 0.3.1 补遗1）----

    private func runTextOutput(_ node: [String: JSONValue]) -> NativeNodeResult {
        let nodeId = WFText.strOrEmpty(node["id"])
        let tpl = WFText.strOrEmpty(node["template"])
        guard !tpl.trimmingCharacters(in: .whitespaces).isEmpty else {
            return NativeNodeResult(nodeId: nodeId, ok: false, error: "文本输出节点缺少 template")
        }
        return NativeNodeResult(nodeId: nodeId,
                                output: .string(Self.renderTemplate(tpl, variables)))
    }

    private func runVariableSet(_ node: [String: JSONValue]) -> NativeNodeResult {
        let nodeId = WFText.strOrEmpty(node["id"])
        let name = WFText.strOrEmpty(node["name"]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("."), !name.contains("/") else {
            return NativeNodeResult(nodeId: nodeId, ok: false,
                                    error: "变量名非法：\(WFText.pyReprString(name))（不能为空或含 . /）")
        }
        guard !Self.reservedVarNames.contains(name) else {
            return NativeNodeResult(nodeId: nodeId, ok: false,
                                    error: "变量名 \(WFText.pyReprString(name)) 是保留名"
                                        + "（\(Self.reservedVarNames.joined(separator: ", "))），请换一个")
        }
        let value = Self.resolveValue(node["value"] ?? .string(""), variables)
        variables[name] = value
        return NativeNodeResult(nodeId: nodeId, output: value)
    }

    /// _run_code：经 python3 子进程执行（见文件头偏差②）。
    /// variables JSON 落临时文件传入；result 经 JSON 传出；超时杀进程判失败。
    private func runCode(_ node: [String: JSONValue]) async throws -> NativeNodeResult {
        let nodeId = WFText.strOrEmpty(node["id"])
        let codeSrc = WFText.strOrEmpty(node["code"])
        guard !codeSrc.trimmingCharacters(in: .whitespaces).isEmpty else {
            return NativeNodeResult(nodeId: nodeId, ok: false, error: "代码执行节点缺少 code")
        }
        let timeoutS = min(max(Self.pyInt(node["timeout_s"], default: 30), 1), 300)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("wfcode_\(runId)_\(nodeId)_\(UUID().uuidString)")
        let varsFile = tmp.appendingPathComponent("vars.json")
        let outFile = tmp.appendingPathComponent("result.json")
        let errFile = tmp.appendingPathComponent("stderr.txt")
        let scriptFile = tmp.appendingPathComponent("script.py")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            try NativeDatabase.dumpsUTF8(.object(variables)).write(to: varsFile, atomically: false, encoding: .utf8)
            // 包装器：读 variables → 用户代码（顶层作用域含 variables/result）→ 落 result
            let harness = """
                import json as _json, sys as _sys
                with open(_sys.argv[1], "r", encoding="utf-8") as _f:
                    variables = _json.load(_f)
                result = None
                \(codeSrc)
                with open(_sys.argv[2], "w", encoding="utf-8") as _f:
                    _json.dump(result, _f, ensure_ascii=False)
                """
            try harness.write(to: scriptFile, atomically: false, encoding: .utf8)
        } catch {
            return NativeNodeResult(nodeId: nodeId, ok: false,
                                    error: "代码执行异常：\(Self.excText(error))")
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["python3", scriptFile.path, varsFile.path, outFile.path]
        FileManager.default.createFile(atPath: errFile.path, contents: nil)
        proc.standardError = (try? FileHandle(forWritingTo: errFile)) ?? FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return NativeNodeResult(nodeId: nodeId, ok: false,
                                    error: "代码执行异常：RuntimeError: 无法启动 python3（\(error.localizedDescription)）")
        }
        // 轮询退出 + 超时杀进程（子进程可强杀——优于侧车线程泄漏；文案逐字保留）。
        // ⚠️ 全程只用 isRunning 轮询、绝不调用 waitUntilExit()：Foundation 在
        // isRunning 已观察到子进程死亡后再 waitUntilExit 有死等竞态（终止事件已被
        // 消费，runloop 源不再触发），xctest 下可复现整套件挂死。isRunning==false
        // 时 terminationStatus 已可读，无需再 wait。
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutS))
        while proc.isRunning {
            if Date() >= deadline {
                proc.terminate()
                let killDeadline = Date().addingTimeInterval(1)
                while proc.isRunning && Date() < killDeadline {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                if proc.isRunning {
                    kill(proc.processIdentifier, SIGKILL)
                    let reapDeadline = Date().addingTimeInterval(1)
                    while proc.isRunning && Date() < reapDeadline {
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                }
                return NativeNodeResult(nodeId: nodeId, ok: false,
                                        error: "代码执行超时（\(timeoutS)s）：可能存在死循环。"
                                            + "工作流已继续，但失控线程会占用 CPU 直到其自行结束")
            }
            if Task.isCancelled {
                proc.terminate()
                throw WorkflowClientDisconnect()
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard proc.terminationStatus == 0 else {
            let errText = (try? String(contentsOf: errFile, encoding: .utf8)) ?? ""
            let lastLine = errText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .last { !$0.isEmpty } ?? "退出码 \(proc.terminationStatus)"
            return NativeNodeResult(nodeId: nodeId, ok: false,
                                    error: "代码执行异常：\(lastLine)")
        }
        guard let data = try? Data(contentsOf: outFile), let v = NativeJSONWriter.loadsFragment(data) else {
            return NativeNodeResult(nodeId: nodeId, ok: false,
                                    error: "代码执行异常：RuntimeError: result 未产出或不可 JSON 序列化")
        }
        return NativeNodeResult(nodeId: nodeId, output: v)
    }

    // ---- reply（_run_reply：workflow_reply 事件 + 输出写变量）----

    private func runReply(_ node: [String: JSONValue]) -> NativeNodeResult {
        let nodeId = WFText.strOrEmpty(node["id"])
        let text = Self.renderTemplate(WFText.strOrEmpty(node["text"]), variables)
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            return NativeNodeResult(nodeId: nodeId, ok: false, error: "消息回复节点缺少 text")
        }
        emit("workflow_reply", ["node_id": .string(nodeId), "text": .string(text)])
        return NativeNodeResult(nodeId: nodeId, output: .string(text))
    }

    // ---- file_read（_run_file_read + C4 解析链，0.4.18）----

    private func runFileRead(_ node: [String: JSONValue]) async -> NativeNodeResult {
        let nodeId = WFText.strOrEmpty(node["id"])
        let rawPath = Self.renderTemplate(WFText.strOrEmpty(node["path"]), variables)
        guard !rawPath.trimmingCharacters(in: .whitespaces).isEmpty else {
            return NativeNodeResult(nodeId: nodeId, ok: false, error: "文件读取节点未配置 path")
        }
        let p = (rawPath as NSString).expandingTildeInPath
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: p, isDirectory: &isDir) else {
            return NativeNodeResult(nodeId: nodeId, ok: false, error: "路径不存在：\(p)")
        }

        let exts = Set(WFText.strOrEmpty(node["extensions"]).split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { $0.lowercased().trimmingPrefix(".") })
        var files: [String] = []
        if !isDir.boolValue {
            files = [p]
        } else {
            if let items = try? fm.contentsOfDirectory(atPath: p) {
                for rel in items {
                    let full = (p as NSString).appendingPathComponent(rel)
                    var dirFlag: ObjCBool = false
                    if fm.fileExists(atPath: full, isDirectory: &dirFlag), !dirFlag.boolValue {
                        files.append(full)
                    }
                }
            }
            if !exts.isEmpty {
                files = files.filter { exts.contains(Self.pySuffixLower($0).trimmingPrefix(".")) }
            }
            files = Self.pySorted(files)
        }
        guard !files.isEmpty else {
            let extDesc = exts.isEmpty ? "全部" : WFText.pyListRepr(Self.pySorted(exts.map { String($0) }))
            return NativeNodeResult(nodeId: nodeId, ok: false,
                                    error: "没有可读的文件：\(p)（extensions=\(extDesc)）")
        }

        let maxBytes = Self.pyInt(node["max_bytes"], default: 200000)
        let sepTpl = node["separator"]

        var chunks: [String] = []
        for f in files {
            let name = Self.pyPathName(f)
            let suffix = Self.pySuffixLower(f)
            let srcSize: Int
            do {
                srcSize = Int(try fm.attributesOfItem(atPath: f)[.size] as? Int64 ?? 0)
            } catch {
                return NativeNodeResult(nodeId: nodeId, ok: false,
                                        error: "读取失败 \(name)：\(error.localizedDescription)")
            }
            var text: String
            var cut = false
            if Self.docParseExts.contains(suffix) {
                // C4：二进制文档格式走解析器——整读（截断会破坏容器结构）→ 解析 → 截断文本
                if srcSize > Self.fileReadMaxSourceBytes {
                    return NativeNodeResult(nodeId: nodeId, ok: false, error:
                        "\(name) 过大（\(srcSize) 字节 > 上限 \(Self.fileReadMaxSourceBytes) 字节）："
                        + "\(suffix) 需整读后解析，无法像纯文本那样只读前段（截断会破坏文件结构）")
                }
                guard let raw = try? Data(contentsOf: URL(fileURLWithPath: f)) else {
                    return NativeNodeResult(nodeId: nodeId, ok: false,
                                            error: "读取失败 \(name)：无法读取文件")
                }
                // 解析 sync + CPU 密集 → 丢全局队列（不阻塞 actor/事件流；对齐 run_in_executor）
                let parsed: String? = await Task.detached(priority: .userInitiated) {
                    NativeDocParser.parse(name: name, raw: raw)
                }.value
                guard let parsedText = parsed else {
                    // 如实报错而不是塞乱码/空串（含 OOXML 未覆盖的 .docx 等——偏差③）
                    return NativeNodeResult(nodeId: nodeId, ok: false, error:
                        "无法解析 \(name)（\(suffix.isEmpty ? "无扩展名" : suffix)）："
                        + "文件损坏、加密，或该格式不支持文本提取")
                }
                text = parsedText
            } else {
                // C4 补漏：记录源大小 → 回退尾部不完整字节 → 如实标注截断
                let raw: Data
                do {
                    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: f))
                    raw = (try handle.read(upToCount: maxBytes)) ?? Data()
                    try handle.close()
                } catch {
                    return NativeNodeResult(nodeId: nodeId, ok: false,
                                            error: "读取失败 \(name)：\(error.localizedDescription)")
                }
                cut = srcSize > raw.count
                // 回退最多 3 字节找可解码边界（UTF-8 单字符最长 4 字节）
                var decoded: String? = nil
                for back in 0..<4 {
                    let b = back == 0 ? raw : raw.prefix(raw.count - back)
                    if let s = String(data: b, encoding: .utf8) { decoded = s; break }
                }
                text = decoded ?? String(decoding: raw, as: UTF8.self)   // 非 UTF-8 → replace 容错
            }
            // 两类路径统一按**输出文本**上限截断
            if cut || text.unicodeScalars.count > maxBytes {
                if text.unicodeScalars.count > maxBytes {
                    text = WFText.pyPrefix(text, maxBytes)
                }
                text += "\n（已截断：源文件 \(srcSize) 字节，输出上限 \(maxBytes) 字）"
            }
            if let sepTpl, sepTpl != .null {
                let header = Self.renderTemplate(WFText.pyStr(sepTpl),
                                                 variables.merging(["filename": .string(name)]) { _, new in new })
                chunks.append("\(header)\n\(text)")
            } else {
                chunks.append("=== \(name) ===\n\(text)")
            }
        }
        return NativeNodeResult(nodeId: nodeId, output: .string(chunks.joined(separator: "\n\n")))
    }
}

// MARK: - （文件尾）
