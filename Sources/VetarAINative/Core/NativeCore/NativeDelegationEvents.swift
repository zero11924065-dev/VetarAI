//
//  NativeDelegationEvents.swift
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

//  逐行为移植 subagent/sidecar/agent_engine/delegation_events.py（355 行，
//  ⛔ 只读行为规格源；语义分歧以 Python 源码为准）：
//    · 通道按 project_id 建（一条连接覆盖整个项目的任务列表），每事件自带 task_id
//    · 每订阅者独立队列（⛔ 共享 Event/Condition 会丢唤醒——本文件用每订阅者
//      独立 NativeSubQueue，put 无需持订阅者锁，天然一对多广播）
//    · 环形缓冲 200 + 单调 seq：晚到订阅者先补发 since_seq 之后仍在缓冲的事件；
//      断档发 gap 事件让订阅者重拉快照，不拿半截状态渲染
//    · end_task 必发 task_end 并在【无活跃任务且无订阅者】时回收通道；
//      绝不淘汰有订阅者或有活跃任务的通道（宁可超上限 64）
//    · 总线是旁路：push 绝不抛异常，失败返回 false，绝不影响委派本身
//    · clear_all 投 _CLOSED 哨兵 → 订阅者收到 _channel_closed 结束订阅
//
//  偏差（汇报清单同步）：
//    ① Python 用「每订阅者 asyncio.Queue + _deliver 跨 loop 投递」；Swift 用
//       NSLock + CheckedContinuation 信箱（actor 语义天然跨上下文安全，无 loop 概念）。
//       满员丢最旧一条的慢消费者口径一致（seq 断档检测兜底）。
//    ② SSE 端点（app.py api_stream_agent_tasks / snapshot / keepalive）不在原生
//       内核——HTTP 面板仍走侧车（W4b 不翻路由）；端点层用例标注挂起。
//

import Foundation

/// 总线事件条目（push 进缓冲与投递给订阅者的最小单元）。
public struct NativeDelegationBusEvent: Sendable, Equatable {
    public let seq: Int
    public let event: String
    public let taskId: String
    public let data: [String: JSONValue]
    public init(seq: Int, event: String, taskId: String, data: [String: JSONValue]) {
        self.seq = seq
        self.event = event
        self.taskId = taskId
        self.data = data
    }
}

// ════════════════════════════════════════════════════════════
// MARK: - 每订阅者信箱（asyncio.Queue(maxsize=_QUEUE_MAX) 等价）
// ════════════════════════════════════════════════════════════

/// 每订阅者独立信箱：put 无需持锁等待（锁内 O(1)），满员丢最旧一条；
/// pop 带空闲超时（订阅循环据此产 _idle 心跳并检查通道是否已回收）。
/// nil 元素 = _CLOSED 哨兵（clear_all 投递，订阅者收到即结束）。
final class NativeSubQueue: @unchecked Sendable {

    enum PopResult: Sendable {
        case item(NativeDelegationBusEvent?)   // nil = _CLOSED 哨兵
        case timeout
    }

    private let lock = NSLock()
    private var items: [NativeDelegationBusEvent?] = []
    private var waiters: [Int: CheckedContinuation<NativeDelegationBusEvent?, Never>] = [:]
    private var nextId = 0
    private let maxSize: Int

    init(maxSize: Int) { self.maxSize = maxSize }

    /// put_nowait：有等待者直接唤醒投递，否则入队（满员丢最旧一条）。
    func put(_ item: NativeDelegationBusEvent?) {
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

    /// 取一条；timeout 秒无事件返回 .timeout（订阅循环发 _idle / 查通道存活）。
    func pop(timeout: TimeInterval) async -> PopResult {
        if let it = takeItemNow() { return .item(it) }
        let wid = nextWaiterId()
        return await withTaskGroup(of: PopResult.self) { group in
            group.addTask { [self] in
                await withTaskCancellationHandler {
                    let v: NativeDelegationBusEvent? = await withCheckedContinuation { cont in
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

    /// 非空则立即取队首（同步帮助函数：NSLock 只在同步上下文使用）。
    private func takeItemNow() -> NativeDelegationBusEvent?? {
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

    /// 登记等待者；若登记瞬间队列已有元素，返回该元素由调用方立即 resume。
    private func takeItemOrRegister(
        wid: Int, cont: CheckedContinuation<NativeDelegationBusEvent?, Never>
    ) -> NativeDelegationBusEvent?? {
        lock.lock(); defer { lock.unlock() }
        if !items.isEmpty { return items.removeFirst() }
        waiters[wid] = cont
        return nil
    }

    private func cancelWaiter(wid: Int) {
        lock.lock()
        let w = waiters.removeValue(forKey: wid)
        lock.unlock()
        // 超时分支已胜出：补一次 resume 防 continuation 泄漏（结果被丢弃）
        w?.resume(returning: nil)
    }
}

// ════════════════════════════════════════════════════════════
// MARK: - 通道与注册表（_Channel / _CHANNELS / _LOCK 等价）
// ════════════════════════════════════════════════════════════

/// 一个 project 的事件通道。
private final class NativeDelegationChannel {
    var buf: [NativeDelegationBusEvent] = []          // 环形缓冲（deque(maxlen=200)）
    var seq = 0                                        // 单调递增，订阅者据此检测断档
    var activeTasks: Set<String> = []                  // 该 project 下正在跑的 task_id
    var subs: [ObjectIdentifier: NativeSubQueue] = [:] // 每订阅者独立队列
    var touched = Date.timeIntervalSinceReferenceDate  // 最近活动时间（淘汰最旧通道用）
}

/// delegation_events 进程内事件总线（模块级注册表等价物）。
public enum NativeDelegationEvents {

    /// _BUFFER_MAX：单个通道保留的事件数上限（环形缓冲）。
    public static let bufferMax = 200
    /// _QUEUE_MAX：单个订阅者队列上限（慢消费者丢最旧，靠 seq 断档对齐）。
    public static let queueMax = 200
    /// _MAX_CHANNELS：通道数上限（只淘汰空闲通道，防长期泄漏）。
    public static let maxChannels = 64
    /// IDLE_TIMEOUT：订阅者空闲超时（秒；端点据此发心跳防代理断连）。
    public static let idleTimeout = 15.0

    private static let lock = NSLock()
    private static var channels: [String: NativeDelegationChannel] = [:]

    /// _get_channel(project_id, create)：取通道；create=true 不存在则建。
    /// 新建通道必须被 protect（调用方还没打活跃标记/注册订阅者，此刻它看起来
    /// 是空闲的 → 会被淘汰掉自己：begin_task 拿到孤儿对象，事件全部静默丢失）。
    private static func getChannel(_ projectId: String, create: Bool) -> NativeDelegationChannel? {
        let pid = projectId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pid.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let ch = channels[pid] {
            ch.touched = Date.timeIntervalSinceReferenceDate
            return ch
        }
        guard create else { return nil }
        let ch = NativeDelegationChannel()
        channels[pid] = ch
        evictLocked(protect: pid)
        ch.touched = Date.timeIntervalSinceReferenceDate
        return ch
    }

    /// _evict_locked：通道数超上限时淘汰最旧的【空闲】通道（无活跃任务且无订阅者）。
    /// 调用方须持 lock。protect：本次刚创建的通道 pid，必须跳过。
    private static func evictLocked(protect: String = "") {
        let over = channels.count - maxChannels
        guard over > 0 else { return }
        let idle = channels
            .filter { $0.key != protect && $0.value.activeTasks.isEmpty && $0.value.subs.isEmpty }
            .sorted { ($0.value.touched, $0.key) < ($1.value.touched, $1.key) }
        for (pid, _) in idle.prefix(over) { channels[pid] = nil }
    }

    /// _recycle_if_idle：无活跃任务且无订阅者 → 回收通道。调用方须持 lock。
    private static func recycleIfIdleLocked(_ ch: NativeDelegationChannel, pid: String) {
        if ch.activeTasks.isEmpty && ch.subs.isEmpty, channels[pid] === ch {
            channels[pid] = nil
        }
    }

    /// 订阅循环空闲时查通道存活（同步帮助函数：NSLock 只在同步上下文使用）。
    private static func staleCheck(pid: String, ch: NativeDelegationChannel) -> (Bool, Int) {
        lock.lock(); defer { lock.unlock() }
        return (channels[pid] !== ch, ch.seq)
    }

    // MARK: begin_task / end_task

    /// begin_task：委派任务开始时调用——建通道并把 task_id 记为活跃。
    public static func beginTask(_ projectId: String, _ taskId: String) {
        let pid = projectId.trimmingCharacters(in: .whitespacesAndNewlines)
        let tid = taskId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pid.isEmpty, !tid.isEmpty else { return }
        guard let ch = getChannel(pid, create: true) else { return }
        lock.lock()
        ch.activeTasks.insert(tid)
        lock.unlock()
    }

    /// end_task：委派任务结束时调用（⛔ 必须放 defer——任何返回/异常/取消路径
    /// 都要推 task_end 并回收通道，否则订阅者永远等不到结束信号，前端转圈不停）。
    public static func endTask(_ projectId: String, _ taskId: String) {
        let pid = projectId.trimmingCharacters(in: .whitespacesAndNewlines)
        let tid = taskId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pid.isEmpty, !tid.isEmpty else { return }
        guard let ch = getChannel(pid, create: false) else { return }
        _ = push(pid, tid, "task_end", ["task_id": .string(tid)])
        lock.lock()
        ch.activeTasks.remove(tid)
        recycleIfIdleLocked(ch, pid: pid)
        lock.unlock()
    }

    // MARK: push

    /// push：推一条事件给该 project 的全部订阅者。
    /// 返回 true=已入缓冲并投递；false=通道不存在或参数非法。⛔ 绝不抛异常。
    @discardableResult
    public static func push(_ projectId: String, _ taskId: String, _ event: String,
                            _ data: [String: JSONValue]? = nil) -> Bool {
        let pid = projectId.trimmingCharacters(in: .whitespacesAndNewlines)
        let tid = taskId.trimmingCharacters(in: .whitespacesAndNewlines)
        let evName = event.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pid.isEmpty, !evName.isEmpty else { return false }
        guard let ch = getChannel(pid, create: false) else { return false }
        lock.lock()
        ch.seq += 1
        let item = NativeDelegationBusEvent(seq: ch.seq, event: evName, taskId: tid,
                                            data: data ?? [:])
        ch.buf.append(item)
        if ch.buf.count > bufferMax { ch.buf.removeFirst(ch.buf.count - bufferMax) }
        let targets = Array(ch.subs.values)
        lock.unlock()
        // 投递放锁外（对齐 Python：call_soon_threadsafe 可能阻塞，持锁会拖慢 begin/end）
        for q in targets { q.put(item) }
        return true
    }

    // MARK: subscribe

    /// subscribe：订阅某 project 的实时事件（AsyncStream）。
    /// 产出顺序（对齐 Python 异步生成器）：
    ///   1. {"event":"_subscribed","seq":当前seq} —— 握手，告知起点
    ///   2. {"event":"gap",...} —— 仅当 since_seq 与缓冲最早事件之间断档
    ///   3. 缓冲里 since_seq 之后的补发事件
    ///   4. 实时事件（status/progress/tool_call/tool_result/task_end）
    ///   5. {"event":"_idle"} —— 每 idleTimeout 秒无事件时一次
    ///   6. {"event":"_channel_closed"} —— 通道被回收（仅 clearAll 时），订阅结束
    /// ⛔ 订阅者注销放 onTermination（等价 Python finally）：客户端断开也要摘掉
    ///    自己的队列，否则通道永远"有订阅者"而无法回收 → 内存泄漏。
    public static func subscribe(_ projectId: String, sinceSeq: Int = 0,
                                 idleTimeout: TimeInterval = idleTimeout)
        -> AsyncStream<NativeDelegationBusEvent> {
        AsyncStream { continuation in
            let pid = projectId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pid.isEmpty, let ch = getChannel(pid, create: true) else {
                continuation.finish()
                return
            }
            let q = NativeSubQueue(maxSize: queueMax)
            let qid = ObjectIdentifier(q)
            lock.lock()
            ch.subs[qid] = q
            let startSeq = ch.seq
            let backlog = ch.buf.filter { $0.seq > sinceSeq }
            lock.unlock()

            let task = Task {
                // 1) 握手
                continuation.yield(NativeDelegationBusEvent(
                    seq: startSeq, event: "_subscribed", taskId: "", data: [:]))
                // 2) 断档检测
                if sinceSeq > 0, let first = backlog.first, first.seq > sinceSeq + 1 {
                    continuation.yield(NativeDelegationBusEvent(
                        seq: startSeq, event: "gap", taskId: "",
                        data: ["from": .int(Int64(sinceSeq)),
                               "oldest_available": .int(Int64(first.seq))]))
                }
                // 3) 缓冲补发
                for e in backlog { continuation.yield(e) }
                // 4)-6) 实时循环
                while !Task.isCancelled {
                    switch await q.pop(timeout: idleTimeout) {
                    case .timeout:
                        // 空闲：查通道是否已不是当前注册的那个（被淘汰/清空）
                        let (stale, curSeq) = staleCheck(pid: pid, ch: ch)
                        if stale {
                            continuation.yield(NativeDelegationBusEvent(
                                seq: curSeq, event: "_channel_closed", taskId: "", data: [:]))
                            continuation.finish()
                            return
                        }
                        continuation.yield(NativeDelegationBusEvent(
                            seq: curSeq, event: "_idle", taskId: "", data: [:]))
                    case .item(let it):
                        if let it {
                            continuation.yield(it)
                        } else {
                            // _CLOSED 哨兵
                            continuation.yield(NativeDelegationBusEvent(
                                seq: ch.seq, event: "_channel_closed", taskId: "", data: [:]))
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
                ch.subs[qid] = nil
                recycleIfIdleLocked(ch, pid: pid)
                lock.unlock()
            }
        }
    }

    // MARK: 诊断/测试用计数器

    /// active_task_count：该 project 当前活跃任务数。
    public static func activeTaskCount(_ projectId: String) -> Int {
        guard let ch = getChannel(projectId, create: false) else { return 0 }
        lock.lock(); defer { lock.unlock() }
        return ch.activeTasks.count
    }

    /// subscriber_count：该 project 当前订阅者数。
    public static func subscriberCount(_ projectId: String) -> Int {
        guard let ch = getChannel(projectId, create: false) else { return 0 }
        lock.lock(); defer { lock.unlock() }
        return ch.subs.count
    }

    /// channel_count：当前通道总数。
    public static func channelCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return channels.count
    }

    /// buffered_count：该 project 缓冲区里的事件数。
    public static func bufferedCount(_ projectId: String) -> Int {
        guard let ch = getChannel(projectId, create: false) else { return 0 }
        lock.lock(); defer { lock.unlock() }
        return ch.buf.count
    }

    /// latest_seq：该 project 通道当前 seq（无通道返回 0）。
    public static func latestSeq(_ projectId: String) -> Int {
        guard let ch = getChannel(projectId, create: false) else { return 0 }
        lock.lock(); defer { lock.unlock() }
        return ch.seq
    }

    /// clear_all：测试用 / 关闭时——通知全部订阅者结束并清空通道。
    public static func clearAll() {
        lock.lock()
        let targets = channels.values.flatMap { Array($0.subs.values) }
        channels.removeAll()
        lock.unlock()
        // 投递放锁外（_deliver 跨上下文安全语义：Swift 信箱天然安全）
        for q in targets { q.put(nil) }
    }
}
