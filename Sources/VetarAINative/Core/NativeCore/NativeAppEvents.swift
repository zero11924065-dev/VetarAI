//
//  NativeAppEvents.swift
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

//  逐行为移植 subagent/sidecar/agent_engine/app_events.py（252 行）+
//  _bus_common.py（68 行，⛔ 只读行为规格源；语义分歧以 Python 源码为准）：
//    · 单一全局通道（资源变更跨项目：插件/推理配置是全局的，工作流/项目/知识
//      虽属某项目但前端 App 级只需一条连接监听"任何资源变了"，再按 resource
//      字段决定重拉哪个面板——单通道 + 事件自带 resource/project_id 是最小可用解）
//    · 每订阅者独立信箱（⛔ 共享 Event/Condition 丢唤醒——delegation_events
//      实测踩过；put 无需持订阅者锁，天然一对多广播、各订阅者独立游标）
//    · 环形缓冲 100 + 单调 seq + gap 断档对账：晚到订阅者先补发 since_seq 之后
//      仍在缓冲的事件；断档发 gap，订阅者据此重拉快照而非拿半截状态渲染
//    · 总线失败绝不影响主流程：notify 吞异常返回 false（旁路，不能因前端没连上
//      就让 Agent 的写库操作失败）
//    · 订阅者注销放 onTermination（Python finally 等价）：客户端断开也摘掉
//      自己的队列，否则订阅者计数泄漏
//    · clear_all 投 _CLOSED 哨兵 → 订阅者收到 _bus_closed 结束订阅
//
//  REQ-AGT-020（0.4.28）：RESOURCE_SESSION 子会话变更——NativeDelegation 四处
//  写子会话点（任务书 user / 首轮 assistant / 追问 user / 追问 assistant）
//  经 notifyChildSessionChanged 接真总线（对齐 delegation.py
//  _notify_child_session_changed，payload 带 session_id/message_role）。
//  ⛔ 只在委派写路径发射，绝不挂全局 saveMessage（主聊天热路径防事件风暴）。
//
//  偏差（汇报清单同步）：
//    ① Python _deliver 的「跨事件循环安全投递」（同 loop put_nowait / 跨 loop
//       call_soon_threadsafe）在 Swift 无对应物：NSLock + CheckedContinuation
//       信箱天然跨上下文安全（与 W4b NativeDelegationEvents 同一形态适配）；
//       满员丢最旧一条的慢消费者口径一致（订阅者靠 seq 断档检测自行对齐）。
//    ② SSE 端点（app.py api_stream_app_events：StreamingResponse / connected
//       握手 / _subscribed·_idle 内部事件不下发 / text-event-stream 防缓冲头）
//       不在原生内核——HTTP 面板仍走侧车（本波不翻路由）；端点层用例
//       （Python T8/T9）与 19 个写端点 notify 接线断言（T11/T12 端点行为）
//       标注 ⚠️VERIFY 挂起，路由翻转波次覆盖。
//    ③ 「创建 600s 超时」是面板 HTTP 客户端口径（Phase 1 实测修复批已放宽至
//       流式同档 600s，原生侧 RoundtableCreateTimeoutTests 已锁定）；sidecar
//       现行 roundtable.py 内核本身不设超时（模块文档 L25 明示），本总线无
//       超时概念。
//

import Foundation

/// 总线事件条目（入缓冲与投递给订阅者的最小单元）。
/// 对齐 Python item：{"seq": int, "event": "resource_changed"|控制事件, "data": {...}}。
public struct NativeAppBusEvent: Sendable, Equatable {
    public let seq: Int
    public let event: String
    public let data: [String: JSONValue]
    public init(seq: Int, event: String, data: [String: JSONValue]) {
        self.seq = seq
        self.event = event
        self.data = data
    }
}

// ════════════════════════════════════════════════════════════
// MARK: - 每订阅者信箱（asyncio.Queue(maxsize=_QUEUE_MAX) 等价；_bus_common._deliver 的投递落点）
// ════════════════════════════════════════════════════════════

/// 每订阅者独立信箱：put 无需持锁等待（锁内 O(1)），满员丢最旧一条；
/// pop 带空闲超时（订阅循环据此产 _idle 心跳）。nil 元素 = _CLOSED 哨兵
/// （clear_all 投递，订阅者收到即结束）。与 W4b NativeSubQueue 同构
/// （Python 两侧共用 _bus_common._deliver，原生两侧各自随总线建信箱）。
final class NativeAppSubQueue: @unchecked Sendable {

    enum PopResult: Sendable {
        case item(NativeAppBusEvent?)   // nil = _CLOSED 哨兵
        case timeout
    }

    private let lock = NSLock()
    private var items: [NativeAppBusEvent?] = []
    private var waiters: [Int: CheckedContinuation<NativeAppBusEvent?, Never>] = [:]
    private var nextId = 0
    private let maxSize: Int

    init(maxSize: Int) { self.maxSize = maxSize }

    /// put_nowait：有等待者直接唤醒投递，否则入队（满员丢最旧一条）。
    func put(_ item: NativeAppBusEvent?) {
        lock.lock()
        if let first = waiters.min(by: { $0.key < $1.key }) {
            waiters[first.key] = nil
            lock.unlock()
            first.value.resume(returning: item)
            return
        }
        if items.count >= maxSize { items.removeFirst() }
        items.append(item)
        lock.unlock()
    }

    /// 取一条；timeout 秒无事件返回 .timeout（订阅循环发 _idle 心跳）。
    func pop(timeout: TimeInterval) async -> PopResult {
        if let it = takeItemNow() { return .item(it) }
        let wid = nextWaiterId()
        return await withTaskGroup(of: PopResult.self) { group in
            group.addTask { [self] in
                await withTaskCancellationHandler {
                    let v: NativeAppBusEvent? = await withCheckedContinuation { cont in
                        if let it = takeItemOrRegister(wid: wid, cont: cont) {
                            cont.resume(returning: it)
                        }
                    }
                    return .item(v)
                } onCancel: { [self] in
                    cancelWaiter(wid: wid)
                }
            }
            group.addTask {
                let ns = UInt64(max(0.01, timeout) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
                return PopResult.timeout
            }
            let first = await group.next() ?? .timeout
            group.cancelAll()
            return first
        }
    }

    private func takeItemNow() -> NativeAppBusEvent?? {
        lock.lock(); defer { lock.unlock() }
        guard !items.isEmpty else { return nil }
        return items.removeFirst()
    }

    private func nextWaiterId() -> Int {
        lock.lock(); defer { lock.unlock() }
        let wid = nextId
        nextId += 1
        return wid
    }

    private func takeItemOrRegister(
        wid: Int, cont: CheckedContinuation<NativeAppBusEvent?, Never>
    ) -> NativeAppBusEvent?? {
        lock.lock(); defer { lock.unlock() }
        if !items.isEmpty { return items.removeFirst() }
        waiters[wid] = cont
        return nil
    }

    private func cancelWaiter(wid: Int) {
        lock.lock()
        let w = waiters.removeValue(forKey: wid)
        lock.unlock()
        w?.resume(returning: nil)
    }
}

// ════════════════════════════════════════════════════════════
// MARK: - 全局单例总线（_Bus/_BUS/_LOCK 等价；单一全局通道，进程级内存）
// ════════════════════════════════════════════════════════════

public enum NativeAppEvents {

    // ── 资源类型常量（前端按此字段决定重拉哪个面板）──
    public static let resourceWorkflow = "workflow"      // → WorkflowPanel
    public static let resourceProject = "project"        // → ProjectPanel
    public static let resourcePlugin = "plugin"          // → PluginPanel
    public static let resourceKnowledge = "knowledge"    // → KnowledgePanel / WarehouseManager
    public static let resourceInference = "inference"    // → InferencePanel（SettingsPage 内）
    public static let resourceAgent = "agent"            // → IndependentAgentsPanel / AgentPanel
    /// REQ-AGT-020（0.4.28）：会话消息变更 → ChatPanel。只在委派写子会话路径发射
    /// （⛔ 不挂全局 saveMessage——主聊天热路径每条消息都过，挂上即事件风暴）。
    public static let resourceSession = "session"
    /// 0.4.29（P1 可扩展模型包）：模型包安装/卸载/启停/下载进度 → 模型管理器面板。
    public static let resourceModelPack = "model_pack"
    /// 0.7.16（批次7 修复②）：.vmodel 安装/移除/启停 → 模型包面板 + 聊天/Agent
    /// 模型选择列表实时刷新（修复「装完要重启才可选」）。
    public static let resourceVModel = "vmodel"
    /// 0.4.32（CU 三期 P2，REQ-FUT-006）：CU 任务宏录制/删除/回放进度。
    public static let resourceCuMacro = "cu_macro"

    // ── 动作类型常量 ──
    public static let actionCreate = "create"
    public static let actionUpdate = "update"
    public static let actionDelete = "delete"

    /// _BUFFER_MAX：单通道保留的事件数上限（环形缓冲）。资源变更频率远低于 token，
    /// 100 足够覆盖一次 Agent 跑批的多个写操作；超出挤掉最旧，订阅者靠 seq 断档
    /// 检测 + 重拉对齐，不会静默错乱。
    public static let bufferMax = 100
    /// _QUEUE_MAX：单个订阅者队列上限（慢消费者不拖垮总线：满了丢最旧一条）。
    public static let queueMax = 100
    /// IDLE_TIMEOUT：订阅者空闲超时（秒）。即使无事件也定期醒来产 _idle，
    /// 供 SSE 端点发心跳（防代理断连）。
    public static let idleTimeout = 15.0

    private static let lock = NSLock()
    private static var buf: [NativeAppBusEvent] = []   // deque(maxlen=_BUFFER_MAX) 等价
    private static var seq = 0                          // 单调递增，订阅者据此检测断档
    private static var subs: [ObjectIdentifier: NativeAppSubQueue] = [:]

    // MARK: notify

    /// notify(resource, action, project_id=None, **extra)：推一条「资源变更」事件
    /// 给全部订阅者。返回 true=已入缓冲并投递；false=参数非法（空 resource）。
    /// ⛔ 绝不抛异常：总线是变更可视化的旁路，任何失败都不得影响写库本身。
    @discardableResult
    public static func notify(_ resource: String?, _ action: String?,
                              projectId: String? = nil,
                              extra: [String: JSONValue] = [:]) -> Bool {
        let res = (resource ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let act = (action ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !res.isEmpty else { return false }
        var data: [String: JSONValue] = ["resource": .string(res), "action": .string(act),
                                         "project_id": .string(projectId ?? "")]
        for (k, v) in extra { data[k] = v }   // Python data.update(extra)
        lock.lock()
        seq += 1
        let item = NativeAppBusEvent(seq: seq, event: "resource_changed", data: data)
        buf.append(item)
        if buf.count > bufferMax { buf.removeFirst(buf.count - bufferMax) }
        let targets = Array(subs.values)
        lock.unlock()
        // 投递放锁外（对齐 Python：call_soon_threadsafe 可能阻塞，持锁会拖慢 notify）
        for q in targets { q.put(item) }
        return true
    }

    /// delegation.py _notify_child_session_changed 等价（REQ-AGT-020，0.4.28）：
    /// 委派写子会话消息后广播 session 变更（payload 带 session_id/message_role，
    /// 前端 ChatPanel 据此定向重拉；DB 仍是权威源）。
    /// ⛔ 只在委派写路径调用，绝不挂全局 saveMessage；绝不抛异常（旁路）。
    public static func notifyChildSessionChanged(projectId: String, sessionId: String,
                                                 messageRole: String) {
        notify(resourceSession, actionCreate, projectId: projectId,
               extra: ["session_id": .string(sessionId),
                       "message_role": .string(messageRole)])
    }

    // MARK: subscribe

    /// subscribe(since_seq=0, idle_timeout=IDLE_TIMEOUT)：订阅全局资源变更事件
    /// （AsyncStream，对齐 Python 异步生成器）。产出顺序：
    ///   1. {"event":"_subscribed","seq":当前seq} —— 握手，告知起点
    ///   2. {"event":"gap",...} —— 仅当 since_seq 与缓冲最早事件之间断档
    ///   3. 缓冲里 since_seq 之后的补发事件
    ///   4. 实时事件（resource_changed）
    ///   5. {"event":"_idle"} —— 每 idleTimeout 秒无事件时一次（端点据此发心跳）
    ///   6. {"event":"_bus_closed"} —— 总线被清空（仅 clearAll 时），订阅结束
    /// ⛔ 订阅者注销放 onTermination（等价 Python finally 的 aclose 路径）：
    ///    客户端断开也要摘掉自己的队列，否则订阅者计数泄漏。
    public static func subscribe(sinceSeq: Int = 0,
                                 idleTimeout: TimeInterval = idleTimeout)
        -> AsyncStream<NativeAppBusEvent> {
        AsyncStream { continuation in
            let q = NativeAppSubQueue(maxSize: queueMax)
            let qid = ObjectIdentifier(q)
            lock.lock()
            subs[qid] = q
            let startSeq = seq
            let backlog = buf.filter { $0.seq > sinceSeq }
            lock.unlock()

            let task = Task {
                // 1) 握手
                continuation.yield(NativeAppBusEvent(seq: startSeq, event: "_subscribed",
                                                     data: [:]))
                // 2) 断档检测
                if sinceSeq > 0, let first = backlog.first, first.seq > sinceSeq + 1 {
                    continuation.yield(NativeAppBusEvent(
                        seq: startSeq, event: "gap",
                        data: ["from": .int(Int64(sinceSeq)),
                               "oldest_available": .int(Int64(first.seq))]))
                }
                // 3) 缓冲补发
                for e in backlog { continuation.yield(e) }
                // 4)-6) 实时循环
                while !Task.isCancelled {
                    switch await q.pop(timeout: idleTimeout) {
                    case .timeout:
                        // 空闲：通知端点发心跳。单通道永久存在，无需 stale 检查。
                        continuation.yield(NativeAppBusEvent(seq: latestSeq(),
                                                             event: "_idle", data: [:]))
                    case .item(let it):
                        if let it {
                            continuation.yield(it)
                        } else {
                            // _CLOSED 哨兵（clear_all）
                            continuation.yield(NativeAppBusEvent(seq: latestSeq(),
                                                                 event: "_bus_closed",
                                                                 data: [:]))
                            continuation.finish()
                            return
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
                lock.lock()
                subs[qid] = nil
                lock.unlock()
            }
        }
    }

    // MARK: 诊断/测试用计数器

    /// latest_seq：总线当前 seq。
    public static func latestSeq() -> Int {
        lock.lock(); defer { lock.unlock() }
        return seq
    }

    /// subscriber_count：当前订阅者数。
    public static func subscriberCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return subs.count
    }

    /// buffered_count：缓冲区里的事件数。
    public static func bufferedCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return buf.count
    }

    /// clear_all：测试用 / 关闭时——通知全部订阅者结束并清空总线。
    public static func clearAll() {
        lock.lock()
        let targets = Array(subs.values)
        subs.removeAll()
        buf.removeAll()
        seq = 0
        lock.unlock()
        // 投递放锁外（_deliver 跨上下文安全语义：Swift 信箱天然安全）
        for q in targets { q.put(nil) }
    }
}
