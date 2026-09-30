//
//  NativeChatEndpoints.swift
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

//  逐行为移植（⛔ 只读行为规格源：subagent/sidecar/app.py）：
//    · api_ollama_chat_stream（L1069-1562）：请求校验 / _resolve_sandbox_root /
//      五 ctx 组装（knowledge/memory/skills + delegation + app_control + computer_use
//      + archive + model_strengths）/ build_system_prompt / B06 双落库 /
//      work/state.json 执行快照 / gen() SSE 主循环（心跳动态间隔 + 授权 SSE 驱动 +
//      取消硬停止 + compact_auto 服务端闭环 + 错误安全网 + finally 全清理）
//    · api_chat_stop（L1565-1584）/ api_chat_inject（L1593-1622）
//    · api_auth_respond（L781-797）+ _sse_authorizer（L180-225）+ R2 授权记忆
//    · compactor.py compact_session（流内 compact_auto 闭环 + 面板压缩端点共用）
//    · M5 compute_heartbeat_interval（L1009-1023）
//
//  SSE 行序列化（_sse_format L978-979）逐字节对齐：
//    "event: {event}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n"
//    json 序列化复用 NativeDatabase.dumpsUTF8（', '/': ' 分隔、ensure_ascii=False、
//    键序字典序——P2-W2 起 documented deviation：Python 保插入序，消费侧 json.loads
//    无序语义不受键序影响）。
//
//  偏差（汇报清单同步）：
//    ① 心跳 `: ping` 注释行无消费方——原生流进程内直通（无代理断连场景），心跳
//       触发仅作唤醒源（授权扫描/取消检查），不产出 SSEEvent；心跳竞争结构与动态
//       间隔公式原样保留（test 13 翻译锚点）。
//    ② openai_compatible 后端的 chatStream 已翻原生（P3-W2b：NativeSidecarClient
//       按 inference_backend 分流，经 connectorOverride 注入内核 openAI 连接器）；
//       model_package 后端仍走 HTTP 转发（P3-W3 排期）。
//    ③ safe_unload_model（0.4.9 换装编排）与 model_supports_vision 元数据探测
//       【0.7.4 W11 已接管】：kernel 装配注入 safeUnloadModel =
//       NativeWorkflowHTTPConnector.unloadModel（keep_alive:0 空消息，失败静默
//       false——「safe」语义同 Python）；visionProbe = /api/show capabilities
//       探测（非 ollama 后端 / 键缺失 / 异常 → true 不阻塞口径）。
//    ④ model_strengths 注入文本的 [:100] 截断按 Swift grapheme 计（Python 按
//       code point；仅 astral 平面字符有计数差异，配置校验已限 100 字，实际不可达）。
//

import Foundation

// ════════════════════════════════════════════════════════════
// MARK: - SSE 行序列化（_sse_format 逐字节 + 心跳常量 + M5 动态间隔）
// ════════════════════════════════════════════════════════════

public enum NativeSSEFormat {

    /// _sse_format(event, data)（app.py L978-979）：
    /// `event: {event}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n`。
    public static func sseFormat(_ event: String, data: [String: JSONValue]) -> String {
        "event: \(event)\ndata: \(NativeDatabase.dumpsUTF8(.object(data)))\n\n"
    }

    /// gen() 空闲心跳注释行（L1502）。进程内直通无消费方，仅作协议常量保留（测试锚点）。
    public static let pingLine = ": ping\n\n"
    /// tasks/stream 与 events/stream 的 keepalive 注释行（L1692 / L1753）。
    public static let keepaliveLine = ": keepalive\n\n"

    /// compute_heartbeat_interval（L1009-1023）：
    /// 间隔 = max(base, 近 10 次事件间隔均值 × 1.5)；事件 <2 个或均值 ≤0 → base。
    public static func computeHeartbeatInterval(eventTimes: [Double], base: Double) -> Double {
        if eventTimes.count < 2 { return base }
        let ts = Array(eventTimes.suffix(10))
        // 防御：suffix 结果退化（<2）同样回落 base，任何调用方时序下都不形成空区间
        if ts.count < 2 { return base }
        var deltas: [Double] = []
        for i in 0..<(ts.count - 1) { deltas.append(ts[i + 1] - ts[i]) }
        let avg = deltas.reduce(0, +) / Double(deltas.count)
        if avg <= 0 { return base }
        return max(base, avg * 1.5)
    }
}

// ════════════════════════════════════════════════════════════
// MARK: - 授权中心（_auth_pending + _sse_authorizer + R2 授权记忆）
// ════════════════════════════════════════════════════════════

/// 挂起的授权请求（_auth_pending entry 同构）。
public struct NativeAuthPendingEntry: Sendable, Equatable {
    public let requestId: String
    public let tool: String
    public let path: String
    public let action: String
    public let extra: [String: JSONValue]
    /// gen() 主循环「sent」标记：已发出 auth_request SSE 事件。
    public var sent: Bool

    public init(requestId: String, tool: String, path: String, action: String,
                extra: [String: JSONValue], sent: Bool = false) {
        self.requestId = requestId
        self.tool = tool
        self.path = path
        self.action = action
        self.extra = extra
        self.sent = sent
    }
}

/// _auth_pending 进程级登记处 + _sse_authorizer 语义（app.py L102-225 逐行为）。
/// 一条活流在 loop 内调 authorizer → 本中心挂起 → gen() 主循环扫到发 auth_request
/// SSE 事件 → 面板弹窗 → respondAuth 回传 → 本中心唤醒 authorizer 返回用户决定。
public final class NativeAuthCenter: @unchecked Sendable {

    private struct Pending {
        var entry: NativeAuthPendingEntry
        var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
        var result: Bool = false
        var enableNetwork: Bool = false
        /// 已决议（respond 置位、等待 authorizer pop）——gen() 建 watchers 时跳过
        /// （对齐 Python `if not entry["event"].is_set()` 过滤，防忙轮询空转）。
        var resolved: Bool = false
    }

    private let lock = NSLock()
    private var pending: [String: Pending] = [:]   // request_id → Pending
    /// _auth_grants_session：会话级记忆（进程生命周期，重启即清）。
    private var sessionGrants: Set<String> = []    // "tool\u{1}action" 拼键
    private let configProvider: @Sendable () -> [String: JSONValue]
    private let configWriter: @Sendable ([String: JSONValue]) -> Void

    public init(configProvider: @escaping @Sendable () -> [String: JSONValue],
                configWriter: @escaping @Sendable ([String: JSONValue]) -> Void = { _ in }) {
        self.configProvider = configProvider
        self.configWriter = configWriter
    }

    // MARK: 记忆键（_auth_grant_key L140-142：action 空时以 tool_name 补齐）

    public static func grantKey(tool: String, action: String) -> String {
        "\(tool)\u{1}\(action.isEmpty ? tool : action)"
    }

    /// _auth_grant_remembered（L145-158）：会话级命中或永久级（config auth_grants）命中。
    public func isGranted(tool: String, action: String) -> Bool {
        let key = Self.grantKey(tool: tool, action: action)
        lock.lock()
        let sessionHit = sessionGrants.contains(key)
        lock.unlock()
        if sessionHit { return true }
        // 永久级：配置读失败不阻断（回落"无记忆"照常弹窗）
        guard case .array(let grants)? = configProvider()["auth_grants"] else { return false }
        for g in grants {
            guard case .object(let o) = g else { continue }
            let k = Self.grantKey(tool: o["tool"]?.string ?? "", action: o["action"]?.string ?? "")
            if k == key { return true }
        }
        return false
    }

    /// _auth_grant_record（L161-177）：只记批准；session=内存集，always=落 config。
    public func recordGrant(tool: String, action: String, remember: String) {
        let key = Self.grantKey(tool: tool, action: action)
        lock.lock()
        sessionGrants.insert(key)
        lock.unlock()
        guard remember == "always" else { return }
        // 永久级写盘失败不阻断本次放行（会话级已记上）
        let cfg = configProvider()
        var grants: [JSONValue] = []
        if case .array(let arr)? = cfg["auth_grants"] { grants = arr }
        let exists = grants.contains { g in
            guard case .object(let o) = g else { return false }
            return Self.grantKey(tool: o["tool"]?.string ?? "",
                                 action: o["action"]?.string ?? "") == key
        }
        if !exists {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            grants.append(.object([
                "tool": .string(tool),
                "action": .string(action.isEmpty ? tool : action),
                "granted_at": .string(df.string(from: Date())),
            ]))
            configWriter(["auth_grants": .array(grants)])
        }
    }

    // MARK: _auth_timeout（L109-123）：config auth_confirm_timeout，0 = 无限等待

    public func authTimeout() -> Double {
        let def = 600.0   // _AUTH_TIMEOUT_DEFAULT
        guard let raw = configProvider()["auth_confirm_timeout"],
              let f = PySem.toFloat(raw) else { return def }
        return f >= 0 ? f : def
    }

    // MARK: pending 生命周期

    /// 生成 request_id 并挂起（_sse_authorizer L206-210）。返回 request_id。
    @discardableResult
    public func beginRequest(tool: String, path: String, action: String,
                             extra: [String: JSONValue]) -> String {
        let rid = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))
        lock.lock()
        pending[rid] = Pending(entry: NativeAuthPendingEntry(
            requestId: rid, tool: tool, path: path, action: action, extra: extra))
        lock.unlock()
        return rid
    }

    /// gen() 主循环扫描：未 sent 且未决议的挂起请求（L1391-1401 的
    /// `not entry.get("sent") and not entry["event"].is_set()` 双重过滤）。标记 sent 后返回。
    public func drainUnsent() -> [NativeAuthPendingEntry] {
        lock.lock()
        var out: [NativeAuthPendingEntry] = []
        for (rid, var p) in pending {
            if !p.entry.sent && !p.resolved {
                p.entry.sent = true
                pending[rid] = p
                out.append(p.entry)
            }
        }
        lock.unlock()
        // Python 保 dict 插入序；Swift 字典无序 → request_id 序（单调近似插入序，确定性）
        return out.sorted { $0.requestId < $1.requestId }
    }

    /// 当前未决议挂起清单（gen() 建 auth_watchers 用，L1377-1380 的
    /// `not entry["event"].is_set()` 过滤口径——已决议待 pop 的不watch）。
    public func pendingUnresolved() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return pending.filter { !$0.value.resolved }.map(\.key).sorted()
    }

    /// gen() auth watcher（entry["event"].wait() 等价）：等待决议但不消费（不 pop）。
    /// 已决议/已移除 → 立即返回。
    public func waitResolved(requestId rid: String) async {
        await waitEvent(requestId: rid)
    }

    /// 等待决议（evt.wait() 等价；超时 → pop 并返回 nil = 按拒绝处理，L217-220）。
    /// timeout ≤ 0 = 无限等待（0.4.12 B2：asyncio.wait_for timeout=0 是立即超时，
    /// 故 0 必须传 None——此处 timeout<=0 直接不设 deadline）。
    public func awaitResolution(requestId rid: String, timeout: Double) async -> (result: Bool, enableNetwork: Bool)? {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { [self] in
                await waitEvent(requestId: rid)
                return true
            }
            if timeout > 0 {
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    return false
                }
            }
            let first = await group.next()!
            group.cancelAll()
            if !first {   // 超时：pop 并按拒绝
                _ = pop(requestId: rid)
                return nil
            }
            let entry = pop(requestId: rid)
            return entry.map { ($0.result, $0.enableNetwork) }
        }
    }

    private func waitEvent(requestId rid: String) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                lock.lock()
                // 已被 respond（resolved）/pop → 立即返回
                if pending[rid] == nil || pending[rid]?.resolved == true {
                    lock.unlock()
                    cont.resume()
                    return
                }
                pending[rid]?.waiters[id] = cont
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let cont = pending[rid]?.waiters[id]
            pending[rid]?.waiters[id] = nil
            lock.unlock()
            cont?.resume()
        }
    }

    /// api_auth_respond（L781-797）：置结果 + 唤醒。false = 授权请求不存在或已过期（404）。
    @discardableResult
    public func respond(requestId rid: String, allowed: Bool, enableNetwork: Bool) -> Bool {
        lock.lock()
        guard var p = pending[rid] else {
            lock.unlock()
            return false
        }
        p.result = allowed
        p.enableNetwork = enableNetwork
        p.resolved = true
        let waiters = p.waiters
        p.waiters = [:]
        pending[rid] = p
        lock.unlock()
        for (_, cont) in waiters { cont.resume() }
        // R2 记忆由调用方（respondAuth 装配）在 allowed && remember 时调 recordGrant——
        // 端点语义：net_install 永不记忆（L790-793 双重把守）。
        return true
    }

    /// respond 的记忆判定数据（api_auth_respond 需要 entry 的 tool/action）。
    public func pendingEntry(_ rid: String) -> NativeAuthPendingEntry? {
        lock.lock()
        defer { lock.unlock() }
        return pending[rid]?.entry
    }

    /// pop（_auth_pending.pop 等价；返回被移除项）。
    @discardableResult
    public func pop(requestId rid: String) -> (result: Bool, enableNetwork: Bool)? {
        lock.lock()
        let p = pending[rid]
        pending[rid] = nil
        lock.unlock()
        guard let p else { return nil }
        for (_, cont) in p.waiters { cont.resume() }
        return (p.result, p.enableNetwork)
    }

    /// gen() finally 清理（L1550-1554）：全部 pop + result=false 唤醒等待者（安全拒绝）。
    public func failAll() {
        lock.lock()
        let all = pending
        pending = [:]
        lock.unlock()
        for (_, p) in all {
            for (_, cont) in p.waiters { cont.resume() }
        }
    }

    /// 诊断/测试用：当前挂起数。
    public var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }

    // MARK: authorizer 构造（_sse_authorizer L180-225）

    /// 构造注入 run_tool_loop 的 SSE 授权回调。
    /// R2：非 net_install 且记忆命中 → 直接 true（不再弹窗）；net_install 永不记忆。
    public func makeAuthorizer() -> any NativeToolAuthorizer {
        NativeSSEAuthorizer(center: self)
    }
}

/// _sse_authorizer 的 NativeToolAuthorizer 形态。
public struct NativeSSEAuthorizer: NativeToolAuthorizer {
    public let center: NativeAuthCenter
    public init(center: NativeAuthCenter) { self.center = center }

    public func authorize(tool: String, path: String, action: String) async -> Bool {
        // R2：记忆命中 → 直接放行（口径与"用户点允许"一致）
        if center.isGranted(tool: tool, action: action) { return true }
        let rid = center.beginRequest(tool: tool, path: path, action: action, extra: [:])
        let outcome = await center.awaitResolution(requestId: rid, timeout: center.authTimeout())
        return outcome?.result ?? false   // 超时/清理路径 → 拒绝
    }

    public func authorizeNetInstall(tool: String, source: String,
                                    extra: [String: JSONValue]) async -> (allowed: Bool, enableNetwork: Bool) {
        // net_install 永不记忆、每次必弹（入口与 respond 双重把守）
        let rid = center.beginRequest(tool: tool, path: source, action: "net_install", extra: extra)
        let outcome = await center.awaitResolution(requestId: rid, timeout: center.authTimeout())
        return (outcome?.result ?? false, outcome?.enableNetwork ?? false)
    }
}

// ════════════════════════════════════════════════════════════
// MARK: - 智能压缩器（compactor.py compact_session 逐行为；流内闭环与面板端点共用）
// ════════════════════════════════════════════════════════════

public enum NativeCompactor {

    public struct CompactResult: Sendable, Equatable {
        public let ok: Bool
        public let error: String?
        public let beforeTokens: Int
        public let afterTokens: Int
        public let archivePath: String?
        public let archivedCount: Int
    }

    /// _estimate_tokens（compactor.py L62-73）：中文字符数 + 英文单词数/4。
    public static func estimateTokens(_ contents: [String]) -> Int {
        var total = 0
        for c in contents {
            var cjk = 0, latin = 0
            for ch in c {
                if ch >= "\u{4e00}" && ch <= "\u{9fff}" { cjk += 1 }
                else if ch.isASCII && ch.isLetter { latin += 1 }
            }
            total += cjk + latin / 4
        }
        return total
    }

    /// _archive_md（L39-59）：待压缩区写 MD 归档文件，返回文件路径。
    /// tool_steps 列 JSON 数组 → 每条 "  - [name] summary" 先行（逐字对齐）。
    static func archiveMD(sessionId: String, messages: [NativeDatabase.MessageRow],
                          archiveDir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        let df2 = DateFormatter()
        df2.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let path = archiveDir.appendingPathComponent("compact-\(sessionId)-\(df.string(from: Date())).md")
        var lines = ["# 历史消息归档", "> 会话: \(sessionId)",
                     "> 时间: \(df2.string(from: Date()))", ""]
        for m in messages {
            let role = m.role
            let content = m.content ?? ""
            let tsM = m.createdAt ?? ""
            if role == "assistant", let steps = m.toolSteps {
                for st in steps {
                    guard case .object(let o) = st else { continue }
                    lines.append("  - [\(o["name"]?.string ?? "tool")] \(o["summary"]?.string ?? "")")
                }
            }
            lines.append("**\(role)** (\(tsM))\n\(content)\n")
        }
        try lines.joined(separator: "\n").write(to: path, atomically: false, encoding: .utf8)
        return path
    }

    /// compact_session（L76-142）：归档 → 摘要 → 落库。
    /// keepRecent=nil → config compact_keep_recent（默认 10）；
    /// archiveDir 缺省 → config compact_archive_dir（默认 ~/.subagent/compressed，~ 展开）。
    /// 摘要经 NativeChatConnector.chat（非流式；失败→中止，消息原样保留）。
    public static func compactSession(
        db: NativeDatabase, connector: any NativeChatConnector,
        config: @Sendable () -> [String: JSONValue],
        projectId: String, sessionId: String,
        keepRecent: Int? = nil, model: String = "qwen3.8"
    ) async -> CompactResult {
        func fail(_ error: String, before: Int = 0, archivePath: String? = nil,
                  logError: Bool = true) -> CompactResult {
            if logError {
                try? db.logCompact(projectId: projectId, sessionId: sessionId,
                                   beforeTokens: Int64(before), afterTokens: Int64(before),
                                   archivePath: archivePath, summary: nil, error: error)
            }
            return CompactResult(ok: false, error: error, beforeTokens: before,
                                 afterTokens: before, archivePath: archivePath, archivedCount: 0)
        }
        let cfg = config()
        let keep = keepRecent ?? Int(cfg["compact_keep_recent"].flatMap(PySem.toFloat) ?? 10)
        let archiveDirRaw = cfg["compact_archive_dir"]?.string ?? "~/.subagent/compressed"
        let archiveDir = URL(fileURLWithPath: (archiveDirRaw as NSString).expandingTildeInPath)

        // 1. 取全部消息
        let allMsgs: [NativeDatabase.MessageRow]
        do { allMsgs = try db.loadMessages(projectId: projectId, sessionId: sessionId) }
        catch { return fail("读取消息失败: \(error)", logError: false) }
        guard allMsgs.count > keep else {
            return CompactResult(ok: false,
                                 error: "消息数 \(allMsgs.count) ≤ keep_recent \(keep)，无需压缩",
                                 beforeTokens: 0, afterTokens: 0, archivePath: nil, archivedCount: 0)
        }
        let toCompress = Array(allMsgs.dropLast(keep))
        let beforeTokens = estimateTokens(allMsgs.map { $0.content ?? "" })

        // 2. 归档（写失败→中止）
        let archivePath: URL
        do { archivePath = try archiveMD(sessionId: sessionId, messages: toCompress,
                                         archiveDir: archiveDir) }
        catch { return fail("归档失败: \(error)", before: beforeTokens) }

        // 3. 摘要（失败→中止，消息原样保留）
        let promptText = toCompress.map { "[\($0.role)] \($0.content ?? "")" }.joined(separator: "\n")
        let summaryText: String
        do {
            let text = try await connector.chat(model: model, messages: [[
                "role": .string("user"),
                "content": .string("请将以下对话历史压缩为 300 字以内的摘要，保留关键决策、结论、待办，去掉寒暄和过程细节：\n\n" + promptText),
            ]])
            guard !text.isEmpty else { throw NativeRoundtableError("推理后端返回空摘要") }
            summaryText = text
        } catch {
            return fail("摘要失败: \(error)", before: beforeTokens, archivePath: archivePath.path)
        }

        // 4. 落库：写 compact_log → 删待压缩区 → 插 role=system 摘要消息
        let keptMsgs = allMsgs.suffix(keep)
        let afterTokens = estimateTokens(keptMsgs.map { $0.content ?? "" }) + summaryText.count
        do {
            try db.logCompact(projectId: projectId, sessionId: sessionId,
                              beforeTokens: Int64(beforeTokens), afterTokens: Int64(afterTokens),
                              archivePath: archivePath.path,
                              summary: String(summaryText.prefix(200)))
            let deleted = try db.deleteMessagesBefore(projectId: projectId,
                                                      sessionId: sessionId, keepRecent: keep)
            let agentId = (try? db.sessionAgentId(projectId: projectId,
                                                  sessionId: sessionId)) ?? ""
            try db.saveMessage(projectId: projectId, sessionId: sessionId, agentId: agentId,
                               role: "system", content: "【历史摘要】\(summaryText)")
            return CompactResult(ok: true, error: nil, beforeTokens: beforeTokens,
                                 afterTokens: afterTokens, archivePath: archivePath.path,
                                 archivedCount: deleted)
        } catch {
            return fail("落库失败: \(error)", before: beforeTokens,
                        archivePath: archivePath.path, logError: false)
        }
    }
}

extension NativeDatabase {
    /// compactor 取 sessions.agent_id（compactor.py L130-133；查无 → ""）。
    public func sessionAgentId(projectId: String, sessionId: String) throws -> String {
        try withReadConn(global: false, projectId: projectId) { conn in
            guard let row = try conn.queryOne(
                "SELECT agent_id FROM sessions WHERE id = ?", [.text(sessionId)]),
                  case .text(let a) = row[0] else { return "" }
            return a
        }
    }
}

// ════════════════════════════════════════════════════════════
// MARK: - chat 端点装配体（api_ollama_chat_stream / stop / inject / auth respond）
// ════════════════════════════════════════════════════════════

/// chatStream 前置上下文（gen() 启动前的全部组装产物；拆出来便于单测锚定）。
public struct NativeChatStreamPlan {
    public var sandboxRoot: String = ""
    public var agent: NativeDatabase.AgentConfigRow?
    public var systemPrompt: String = ""
    public var messages: [[String: JSONValue]] = []     // system + req.messages
    public var canDelegate = false
    public var appControlOn = false
    public var computerUseOn = false
    public var archiveOn = false
    public var knowledgeOn = false
    public var maxRounds = 200
    public var heartbeatBase = 15.0
    public var projectId = ""
    public var sessionId = ""
    public var agentId = ""
    public var model = ""
    public var images: [String]?
    public var skipUserPersist = false
    /// M6（TS-112）工具能力降级标记（app.py L1259-1264）：后端能力表 tools=false →
    /// 降级系统消息已追加到 messages 末尾，streamMain 据此把 toolsSpec 置空。
    public var toolsEnabled = true
}

public final class NativeChatEndpointAssembly: @unchecked Sendable {

    public let kernel: NativeKernel
    public init(kernel: NativeKernel) { self.kernel = kernel }

    private var db: NativeDatabase { kernel.database }
    private var cfg: [String: JSONValue] {
        (try? kernel.config.getConfig()) ?? NativeConfigStore.defaultConfig
    }

    // MARK: 请求校验（L1072-1077）

    /// messages 空 → 422「messages 不能为空」；sandbox_root 解析失败 → 422 原文案。
    private func validate(_ req: ChatStreamRequest) throws {
        if req.messages.isEmpty {
            throw SidecarError.httpError(status: 422, detail: "messages 不能为空")
        }
    }

    // MARK: _resolve_sandbox_root（L1026-1045）

    /// nil → 端点 422（"sandbox_root 缺失：请传 sandbox_root 或 project_id+agent_id"）。
    func resolveSandboxRoot(_ req: ChatStreamRequest) -> String? {
        if let sb = req.sandbox_root, !sb.isEmpty { return sb }
        // checkpoint-058/061：独立 Agent 命名空间——目录一律从已注册 agent_id 推导
        if req.project_id.hasPrefix(NativeDatabase.independentNSPrefix) {
            guard (try? db.getIndependentAgent(req.agent_id)) != nil else { return nil }
            let sb = db.independentAgentDir(req.agent_id).appendingPathComponent("sandbox")
            try? FileManager.default.createDirectory(at: sb, withIntermediateDirectories: true)
            return sb.path
        }
        if !req.project_id.isEmpty, !req.agent_id.isEmpty,
           (try? db.getAgentConfig(projectId: req.project_id, agentId: req.agent_id)) != nil {
            // working_dir 存于 projects 表；agent 归属项目，取该项目 working_dir
            // 0.7.8 Bug3 加固：空串不得作为解析结果上返（落空 → 422 诚实报错，
            // 而不是把工具锚点静默绑到 ""/cwd）。
            if let proj = try? db.getProject(req.project_id),
               !NativeDelegation.pyTrim(proj.workingDir).isEmpty { return proj.workingDir }
        }
        return nil
    }

    // MARK: model_strengths 注入文本（L1123-1155）

    /// 仅当可委派且配置了画像时生成；与可用模型取交集（list_models 失败 → 空名单 →
    /// 不过滤，对齐 Python `_avail` 空跳过交集逻辑）。
    func modelStrengthsText(canDelegate: Bool) async -> String {
        guard canDelegate else { return "" }
        guard case .object(let raw)? = cfg["model_strengths"] else { return "" }
        var ms: [(String, String)] = []
        for (k, v) in raw {
            let key = NativeRoundtable.pyTrim(k)
            let val = NativeRoundtable.pyTrim(v.string ?? "")
            if !key.isEmpty && !val.isEmpty { ms.append((key, val)) }
        }
        if ms.isEmpty { return "" }
        let avail = await Self.fetchOllamaModelNames(config: cfg)
        if !avail.isEmpty {
            let availBases = Set(avail.map { $0.split(separator: ":").first.map(String.init) ?? $0 })
            ms = ms.filter { k, _ in
                avail.contains(k) || availBases.contains(k.split(separator: ":").first.map(String.init) ?? k)
            }
        }
        if ms.isEmpty { return "" }
        return ms.prefix(20).map { "- \($0.0)：\(String($0.1.prefix(100)))" }.joined(separator: "\n")
    }

    // MARK: 上下文上限（gen() M2 段 L1266-1289）

    /// 懒加载生效且已配档 → 当前档；否则 /api/ps + 兜底 262144；失败 → 0（跳过预警）。
    func contextLimit(model: String, tiers: NativeLazyCtxTiers) async -> Int {
        if let tier = tiers.currentCtxFor(model) { return tier }
        let base = (cfg["ollama_base_url"]?.string ?? "")
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard !base.isEmpty, let url = URL(string: "\(base)/api/ps") else { return 262144 }
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 5.0
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let v = NativeJSONWriter.loads(data), case .object(let o) = v,
                  case .array(let models)? = o["models"] else { return 262144 }
            for m in models {
                guard case .object(let mo) = m, let n = mo["name"]?.string else { continue }
                if n == model || n.hasPrefix(model + ":") || n.hasPrefix(model) {
                    let cl = mo["context_length"].flatMap(PySem.toFloat)
                        ?? mo["details"]?.object?["context_length"].flatMap(PySem.toFloat) ?? 0
                    if cl > 0 { return Int(cl) }
                    break
                }
            }
            return 262144   // 协议常量：qwen 系默认上限
        } catch {
            return 0
        }
    }

    /// /api/tags 模型名单（list_models 等价；失败 → 空名单，调用方各自降级）。
    public static func fetchOllamaModelNames(config: [String: JSONValue]) async -> [String] {
        let base = (config["ollama_base_url"]?.string ?? "http://localhost:11434")
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard let url = URL(string: "\(base)/api/tags") else { return [] }
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 5.0
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let v = NativeJSONWriter.loads(data), case .object(let o) = v,
                  case .array(let models)? = o["models"] else { return [] }
            return models.compactMap { $0.object?["name"]?.string }
        } catch { return [] }
    }

    // MARK: 五 ctx + system prompt 组装（L1078-1173）

    /// connectorOverride：测试缝（生产 = kernel.chatConnector）。
    func buildPlan(_ req: ChatStreamRequest) async throws -> NativeChatStreamPlan {
        try validate(req)
        guard let sandbox = resolveSandboxRoot(req) else {
            throw SidecarError.httpError(
                status: 422, detail: "sandbox_root 缺失：请传 sandbox_root 或 project_id+agent_id")
        }
        var plan = NativeChatStreamPlan()
        plan.sandboxRoot = sandbox
        plan.projectId = req.project_id
        plan.sessionId = req.session_id
        plan.agentId = req.agent_id
        plan.model = req.model
        plan.images = req.images
        plan.skipUserPersist = req.skip_user_persist
        if !req.project_id.isEmpty, !req.agent_id.isEmpty {
            plan.agent = try? db.getAgentConfig(projectId: req.project_id, agentId: req.agent_id)
        }
        let netSwitch = cfg["network_switch"]?.string ?? "off"

        // TS-110 M4：知识/记忆/技能注入（加载失败一律降级为空，不阻塞对话）
        // REQ-KNW-007（0.7.5 W3）：知识注入按需化——模式取 config `knowledge_inject_mode`，
        // 缺省 full（现行全量内联逐字保持）；on_demand 时正文不内联、改注按需指引段
        // （记忆与禁止事项红线不按需，两模式均全量——口径见 KnowledgeInjectionPolicy）。
        let knwMode = KnowledgeInjectionPolicy.mode(raw: cfg["knowledge_inject_mode"]?.string)
        var knowledgeText = ""
        var memoryText = ""
        var prohibitions: [String] = []
        if !req.project_id.isEmpty {
            knowledgeText = KnowledgeInjectionPolicy.knowledgeSection(
                mode: knwMode, knowledgeText: kernel.knowledge.buildKnowledgeText(req.project_id))
            let m = kernel.knowledge.buildMemoryInjection(req.project_id)
            memoryText = m.text
            prohibitions = m.prohibitions
        } else {
            let m = kernel.knowledge.buildMemoryInjection(nil)
            memoryText = m.text
            prohibitions = m.prohibitions
        }
        let skillsListText = kernel.skillsManager.buildSkillsListText()

        // TS-107 M3-1：委派上下文（仅主会话齐备时可委派）
        plan.canDelegate = !req.project_id.isEmpty && !req.agent_id.isEmpty && !req.session_id.isEmpty

        // 0.4.9（3.48.2 应用内模块控制）：设置开关（默认关），开启才注入动作清单
        plan.appControlOn = cfg["app_control_enabled"]?.bool ?? false
        let moduleCatalogText = plan.appControlOn ? NativeAppModuleRegistry.buildModuleCatalogText() : ""

        // 0.4.9（3.48.1 Computer Use）：总开关（默认关）
        plan.computerUseOn = cfg["computer_use_enabled"]?.bool ?? false

        plan.archiveOn = req.auto_archive_unit && !req.project_id.isEmpty && !req.session_id.isEmpty
        plan.knowledgeOn = !req.project_id.isEmpty

        let strengths = await modelStrengthsText(canDelegate: plan.canDelegate)

        plan.systemPrompt = NativeAgentLoop.buildSystemPrompt(
            agentName: plan.agent?.name ?? "SubAgent",
            agentRole: plan.agent?.role ?? nil,
            sandboxRoot: sandbox,
            networkSwitch: netSwitch,
            systemPrompt: plan.agent?.systemPrompt ?? nil,
            canDelegate: plan.canDelegate,
            knowledgeText: knowledgeText,
            memoryText: memoryText,
            prohibitions: prohibitions,
            skillsListText: skillsListText,
            modelStrengthsText: strengths,
            archiveEnabled: plan.archiveOn,
            moduleCatalogText: moduleCatalogText,
            computerUseEnabled: plan.computerUseOn)
        plan.messages = [["role": .string("system"), "content": .string(plan.systemPrompt)]]
            + req.messages.map { ["role": .string($0.role), "content": .string($0.content)] }

        // M6（TS-112）工具能力降级（app.py L1259-1264）：后端能力表 tools=false →
        // 降级系统消息追加到 msgs【末尾】+ toolsSpec 置空（确定性降级）。
        // 能力表唯一事实源 = NativeInferenceEndpointAssembly.capabilities（P3-W2a 逐字
        // 移植：ollama 恒真；openai_compatible 读 openai_compat_supports_tools 缺省 true）。
        let backend = NativeInferenceEndpointAssembly.backendStripped(cfg)
        plan.toolsEnabled = NativeInferenceEndpointAssembly.capabilities(
            backend: backend, cfg: cfg).tools
        if !plan.toolsEnabled {
            plan.messages.append([
                "role": .string("system"),
                "content": .string("当前推理后端不支持工具调用，本轮仅直接对话，不可读写文件或搜索。"),
            ])
        }

        // M5（TS-111）：心跳基础值 = clamp(config heartbeat_interval, 5, 60)，默认 15
        if let f = cfg["heartbeat_interval"].flatMap(PySem.toFloat) {
            plan.heartbeatBase = max(5.0, min(f, 60.0))
        }
        plan.maxRounds = Int(cfg["max_tool_rounds"].flatMap(PySem.toFloat) ?? 200)
        return plan
    }
}

// ════════════════════════════════════════════════════════════
// MARK: - gen() 主循环（app.py L1256-1562 逐行为）
// ════════════════════════════════════════════════════════════

extension NativeChatEndpointAssembly {

    /// 唤醒源（asyncio.wait(FIRST_COMPLETED) 的等价产物）。
    enum ChatWake {
        case event(NativeAgentLoopEvent?)
        case timer
        case cancelled
        case auth
    }

    /// asyncio.wait 一次性竞速盒：首个 fire 胜出，其余忽略（调用方负责取消落选任务）。
    final class FirstWinner: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<ChatWake, Never>?
        private var early: ChatWake?
        func fire(_ w: ChatWake) {
            lock.lock()
            if let c = cont {
                cont = nil
                lock.unlock()
                c.resume(returning: w)
            } else if early == nil {
                early = w
                lock.unlock()
            } else {
                lock.unlock()
            }
        }
        func await() async -> ChatWake {
            await withCheckedContinuation { c in
                lock.lock()
                if let w = early {
                    early = nil
                    lock.unlock()
                    c.resume(returning: w)
                } else {
                    cont = c
                    lock.unlock()
                }
            }
        }
    }

    /// 跨 Task 持有 loop 迭代器的盒（任一时刻仅一个 nextTask 访问，结构排他）。
    final class LoopIterBox: @unchecked Sendable {
        var it: AsyncStream<NativeAgentLoopEvent>.Iterator
        init(_ s: AsyncStream<NativeAgentLoopEvent>) { it = s.makeAsyncIterator() }
        func next() async -> NativeAgentLoopEvent? { await it.next() }
    }

    static func isoNow() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return df.string(from: Date())
    }

    /// POST /api/ollama/chat/stream 等价。校验错误（422）在首事件前 finish(throwing:)
    /// （对齐 HTTP 层在首个字节前返回错误状态；同 runWorkflow 先例）。
    /// connectorOverride / toolExecutorOverride：测试缝（生产 nil = 内核真实现）。
    /// tiersOverride：P3-W3a MP 分流缝——MP 路由下传内核共享档位表
    /// （kernel.lazyCtxTiers），loop 升档与 MP 连接器 ensure 异档重启读同一份
    /// 状态（Python 模块级 _CTX_LAZY_STATE 同款）；nil = 每流自建（W4a 偏差②不动）。
    public func chatStream(
        _ body: ChatStreamRequest,
        connectorOverride: (any NativeChatConnector)? = nil,
        toolExecutorOverride: (any NativeLoopToolExecutor)? = nil,
        tiersOverride: NativeLazyCtxTiers? = nil
    ) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.streamMain(body,
                                      connectorOverride: connectorOverride,
                                      toolExecutorOverride: toolExecutorOverride,
                                      tiersOverride: tiersOverride,
                                      continuation: continuation)
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func yield(_ continuation: AsyncThrowingStream<SSEEvent, Error>.Continuation,
                       _ event: String, _ data: [String: JSONValue]) {
        continuation.yield(SSEEvent(
            event: event,
            data: data.mapValues { $0.anyValue },
            rawData: NativeDatabase.dumpsUTF8(.object(data))))
    }

    // swiftlint:disable:next function_body_length
    private func streamMain(
        _ body: ChatStreamRequest,
        connectorOverride: (any NativeChatConnector)?,
        toolExecutorOverride: (any NativeLoopToolExecutor)?,
        tiersOverride: NativeLazyCtxTiers?,
        continuation: AsyncThrowingStream<SSEEvent, Error>.Continuation
    ) async {
        let connector = connectorOverride ?? kernel.chatConnector
        do {
            let plan = try await buildPlan(body)
            let pid = plan.projectId, sid = plan.sessionId, aid = plan.agentId
            let stateStore = kernel.state
            let runtime = kernel.chatRuntime
            let auth = kernel.authCenter

            // B06（TS-101）：请求入口先落 user 消息（失败同 Python 上抛 → 500 等价）
            if !pid.isEmpty && !sid.isEmpty && !plan.skipUserPersist, let last = body.messages.last {
                try db.saveMessage(projectId: pid, sessionId: sid, agentId: aid,
                                   role: "user", content: last.content, images: plan.images)
            }

            // ── 双落库状态（_state / _exec_state 同构）──
            var stateText = ""
            var stateSteps: [JSONValue] = []
            var stateSaved = false
            var statePromptEval: Int64?
            var execState: [String: JSONValue] = [
                "session_id": .string(sid), "agent_id": .string(aid), "model": .string(plan.model),
                "status": .string("running"), "step": .int(0),
                "max_rounds": .int(Int64(plan.maxRounds)), "tokens_used": .int(0),
                "started_at": .string(Self.isoNow()), "updated_at": .string(Self.isoNow()),
                "text_chars": .int(0), "steps": .array([]),
            ]
            func flushExecState(status: String? = nil, detail: String? = nil) {
                if let status { execState["status"] = .string(status) }
                if let detail { execState["detail"] = .string(detail) }
                execState["updated_at"] = .string(Self.isoNow())
                execState["text_chars"] = .int(Int64(stateText.count))
                execState["steps"] = .array(stateSteps)
                guard !pid.isEmpty else { return }   // _write_state_file L1055-1056
                stateStore.write(projectId: pid, state: execState)
            }
            // _persist_assistant（L1199-1229）：saved 门闩 + running→interrupted 收敛副本
            func persistAssistant(truncated: Bool, stopped: Bool = false) {
                guard !pid.isEmpty, !sid.isEmpty, !stateSaved else { return }
                stateSaved = true
                // C2 根因③：DB 存定稿态（interrupted），诊断快照保留现场态（running）
                let stepsFinal: [JSONValue] = stateSteps.map { st in
                    guard case .object(var o) = st, o["status"]?.string == "running" else { return st }
                    o["status"] = .string("interrupted")
                    return .object(o)
                }
                try? db.saveMessage(
                    projectId: pid, sessionId: sid, agentId: aid,
                    role: "assistant", content: stateText, modelUsed: plan.model,
                    toolSteps: stepsFinal.isEmpty ? nil : .array(stepsFinal),
                    truncated: truncated, promptEvalCount: statePromptEval, stopped: stopped)
            }

            flushExecState()   // 流开始即写初始状态（running）

            // M6（TS-112）：能力表 tools 门控在 buildPlan 完成（app.py L1259-1264；
            // openai_compatible 后端 P3-W2b 起走原生，tools=false → toolsSpec 置空）。
            // P3-W3a：MP 分流时 tiersOverride=内核共享档位表（loop 升档与驱动异档
            // 重启同一份状态）；其余分支每流自建（W4a 偏差②不动）。
            let tiers = tiersOverride ?? NativeLazyCtxTiers(configProvider: { [kernel] in
                (try? kernel.config.getConfig()) ?? NativeConfigStore.defaultConfig
            })
            let ctxLimit = await contextLimit(model: plan.model, tiers: tiers)

            // ── 五 ctx 装配（run_tool_loop 入参面 L1290-1329）──
            let authorizer = auth.makeAuthorizer()
            let delegationCtx: NativeDelegationContext? = plan.canDelegate
                ? NativeDelegationContext(projectId: pid, agentId: aid, sessionId: sid,
                                          model: plan.model, runner: kernel.delegationEngine)
                : nil
            let knowledgeCtx: NativeKnowledgeContext? = plan.knowledgeOn
                ? NativeKnowledgeContext(projectId: pid, searcher: kernel.knowledgeSearcher)
                : nil
            let archiveCtx: NativeArchiveContext? = plan.archiveOn
                ? NativeArchiveContext(projectId: pid, sessionId: sid,
                                       archiver: kernel.archiveExecutor)
                : nil
            let appControlCtx: NativeAppControlContext? = plan.appControlOn
                ? NativeAppControlContext(projectId: pid, sessionId: sid,
                                          sandboxRoot: plan.sandboxRoot,
                                          authorizer: authorizer,
                                          dispatcher: kernel.appModuleRegistry)
                : nil
            let cuCtx: NativeComputerUseContext? = plan.computerUseOn
                ? NativeComputerUseContext(authorizer: authorizer,
                                           executor: kernel.computerUseEngine)
                : nil
            let toolsSpec = plan.toolsEnabled
                ? NativeAgentLoop.toolsSpec(
                    withDelegation: true,
                    withKnowledge: plan.knowledgeOn,
                    withArchive: plan.archiveOn,
                    withAppControl: plan.appControlOn,
                    withComputerUse: plan.computerUseOn)
                : []   // M6 能力降级：后端 tools=false → 不传工具（app.py L1296）

            let loopStream = NativeAgentLoop.runToolLoop(
                model: plan.model, messages: plan.messages,
                toolsSpecList: toolsSpec,
                sandboxRoot: plan.sandboxRoot,
                connector: connector,
                authorizer: authorizer,
                maxRounds: plan.maxRounds,
                contextLimit: ctxLimit,
                firstRoundImages: plan.images,
                cancelCheck: runtime.makeCancelCheck(sid),
                injectCheck: runtime.makeInjectCheck(sid),
                knowledgeCtx: knowledgeCtx,
                archiveCtx: archiveCtx,
                appControlCtx: appControlCtx,
                computerUseCtx: cuCtx,
                delegationCtx: delegationCtx,
                skillReader: kernel.skillsManager,
                toolContext: toolExecutorOverride == nil
                    ? .live(config: kernel.config, guard: kernel.networkGuard) : nil,
                toolExecutor: toolExecutorOverride,
                configProvider: { [kernel] in
                    (try? kernel.config.getConfig()) ?? NativeConfigStore.defaultConfig
                },
                lazyTiers: tiers)

            var autoCompactDone = false
            var autoCompactFailed = false
            // C2：注册本流（取消 Event）；A5：标记活流（注入只对活流生效）
            let cancelRegistered = runtime.registerStream(sid)
            runtime.beginStream(sid)
            let iterBox = LoopIterBox(loopStream)
            var nextTask: Task<NativeAgentLoopEvent?, Never>?
            var eventTimes: [Double] = []   // 近 ≤10 个事件到达时间戳（环形）

            // finally（L1524-1559）：任一路径退出都走全清理。defer 无法 await，
            // nextTask 的取消吃结果放 cleanup() 显式调用（TS-103 B04 纪律）。
            func cleanup() async {
                if !sid.isEmpty {
                    runtime.unregisterStream(sid)
                    runtime.endStream(sid)
                }
                if let nt = nextTask {
                    nt.cancel()
                    _ = await nt.value   // 吃掉取消结果，确保底层流/连接真正释放
                }
                nextTask = nil
                // M3 前置安全加固 M1：清理未响应授权（pop + result=false 唤醒 → 安全拒绝）
                auth.failAll()
                persistAssistant(truncated: true)   // saved 门闩幂等
                if execState["status"]?.string == "running" {
                    flushExecState(status: "interrupted",
                                   detail: "流未正常结束（客户端断开或迭代器关闭）")
                }
            }

            // REQ-MSG-021：流启动后、第一轮开始前先发初始 state（放注册之后：
            // 此刻断开也能走 cleanup 的完整 interrupted 落盘）
            yield(continuation, "state",
                  ["step": .int(0), "max": .int(Int64(plan.maxRounds)), "tokens_used": .int(0)])

            // gen() try 块等价（L1355-1523）：错误分支各自 persist + flush 后再收尾
            do {
                mainLoop: while true {
                    if nextTask == nil { nextTask = Task { await iterBox.next() } }
                    let nt = nextTask!
                    let winner = FirstWinner()
                    // 快照后建任务：timerTask 在全局并发域执行，直接读主循环可变 eventTimes
                    // 是数据竞争（撕裂读曾致 Range 下溢崩 runner，P3-W4 收口修复）
                    let eventTimesSnapshot = eventTimes
                    let timerTask = Task {
                        let interval = NativeSSEFormat.computeHeartbeatInterval(
                            eventTimes: eventTimesSnapshot, base: plan.heartbeatBase)
                        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                        winner.fire(.timer)
                    }
                    let cancelTask: Task<Void, Never>? = cancelRegistered ? Task {
                        await runtime.awaitChatCancel(sid)
                        winner.fire(.cancelled)
                    } : nil
                    let authTasks = auth.pendingUnresolved().map { rid in
                        Task { await auth.waitResolved(requestId: rid); winner.fire(.auth) }
                    }
                    let eventWatcher = Task { winner.fire(.event(await nt.value)) }
                    let wake = await winner.await()
                    timerTask.cancel()
                    cancelTask?.cancel()
                    authTasks.forEach { $0.cancel() }
                    eventWatcher.cancel()

                    // 授权扫描（每次唤醒都跑；sent 标记防重发，L1391-1401）
                    for entry in auth.drainUnsent() {
                        yield(continuation, "auth_request", [
                            "request_id": .string(entry.requestId),
                            "tool_name": .string(entry.tool),
                            "target_path": .string(entry.path),
                            "action": .string(entry.action),
                            "extra": .object(entry.extra),
                        ])
                    }

                    // C2：用户点停止 → 硬取消在飞请求并收尾（必须在事件分支之前）
                    if case .cancelled = wake {
                        nt.cancel()
                        _ = await nt.value   // 吃掉取消结果，确保底层连接真正释放
                        nextTask = nil
                        persistAssistant(truncated: true, stopped: true)   // C8：用户主动停止
                        if execState["status"]?.string == "running" {
                            flushExecState(status: "interrupted", detail: "用户已停止生成")
                        }
                        yield(continuation, "cancelled", ["detail": .string("已停止生成")])
                        break
                    }

                    switch wake {
                    case .event(let maybeEv):
                        guard let ev = maybeEv else {
                            // 生成器耗尽未收到 done → 状态兜底 error（L1427-1432）
                            if execState["status"]?.string == "running" {
                                flushExecState(status: "error",
                                               detail: "流异常结束（未收到 done 事件）")
                            }
                            break mainLoop
                        }
                        nextTask = nil
                        // M5：记录事件到达时间戳（环形 ≤10）
                        eventTimes.append(ProcessInfo.processInfo.systemUptime)
                        if eventTimes.count > 10 { eventTimes.removeFirst() }
                        let e = ev.event, d = ev.data
                        switch e {
                        case "token":
                            stateText += d["delta"]?.string ?? ""
                        case "tool_call":
                            stateSteps.append(.object([
                                "id": .string(d["id"]?.string ?? ""),
                                "name": .string(d["name"]?.string ?? ""),
                                "args": d["args"] ?? .object([:]),
                                "status": .string("running"),
                            ]))
                            flushExecState()
                        case "tool_result":
                            // B06 收尾：补 status，并保留对应 tool_call 的 args
                            var entry: [String: JSONValue] = [
                                "name": .string(d["name"]?.string ?? ""),
                                "ok": .bool(d["ok"]?.bool ?? true),
                                "error": d["error"] ?? .null,
                                "summary": d["summary"] ?? .null,
                                "status": .string((d["ok"]?.bool ?? false) ? "ok" : "error"),
                            ]
                            if case .object(let lastSt)? = stateSteps.last,
                               lastSt["name"]?.string == entry["name"]?.string,
                               lastSt["status"]?.string == "running" {
                                entry["id"] = lastSt["id"] ?? .string("")
                                entry["args"] = lastSt["args"] ?? .null
                                stateSteps[stateSteps.count - 1] = .object(entry)
                            } else {
                                stateSteps.append(.object(entry))
                            }
                            flushExecState()
                        case "compact_auto":
                            // M2 自动压缩闭环：loop 通知"该压缩了" → 服务端真正执行压缩
                            if autoCompactDone || autoCompactFailed {
                                // 第二次触发：降级 compact_required 让用户三选一
                                yield(continuation, "compact_required", d)
                                break mainLoop
                            }
                            autoCompactDone = true
                            do {
                                let cr = await NativeCompactor.compactSession(
                                    db: db, connector: connector,
                                    config: { [kernel] in
                                        (try? kernel.config.getConfig())
                                            ?? NativeConfigStore.defaultConfig
                                    },
                                    projectId: pid, sessionId: sid, model: plan.model)
                                if !cr.ok { throw NativeRoundtableError(cr.error ?? "压缩失败") }
                            } catch {
                                // 压缩失败 → 不能装没事发生：降级 compact_required
                                autoCompactFailed = true
                                yield(continuation, "compact_required", d)
                                break mainLoop
                            }
                            // 压缩成功 → 继续消费 loop 后续事件（compact_auto 本身照常转发）
                        case "compact_required":
                            flushExecState(status: "paused",
                                           detail: "上下文接近上限，等待用户处理")
                        case "state":
                            if let s = d["step"] { execState["step"] = s }
                            if let m = d["max"] { execState["max_rounds"] = m }
                            if let t = d["tokens_used"] { execState["tokens_used"] = t }
                            // H17 问题3：记录最新 prompt_eval_count（落库供恢复指示器）
                            if case .int(let pec)? = d["prompt_eval_count"] {
                                statePromptEval = pec
                            }
                            flushExecState()
                        case "error":
                            flushExecState(status: "error",
                                           detail: d["detail"]?.string ?? "")
                        case "done":
                            if let c = d["content"]?.string { stateText = c }
                            persistAssistant(truncated: false)
                            flushExecState(status: "done")
                        default:
                            break   // thinking / segment_break / cancelled 等：直通转发
                        }
                        yield(continuation, e, d)
                    case .timer:
                        // 偏差①：进程内直通无代理断连场景，`: ping` 注释行无消费方，
                        // 心跳仅作唤醒源（授权扫描/取消检查），不产出 SSEEvent。
                        continue
                    case .cancelled:
                        break   // 已在上方统一处理（不可达，穷举占位）
                    case .auth:
                        continue   // 授权扫描已在每次唤醒时执行
                    }
                }
                await cleanup()
                continuation.finish()
            } catch let e as NativeChatConnectorError {
                // NetworkGuardError / OllamaAPIError 口径（L1503-1506）
                persistAssistant(truncated: true)
                flushExecState(status: "error", detail: e.message)
                yield(continuation, "error", ["detail": .string(e.message)])
                await cleanup()
                continuation.finish()
            } catch is CancellationError {
                // B06：客户端断开 → 已生成部分落盘（truncated + stopped）后静默结束
                persistAssistant(truncated: true, stopped: true)
                flushExecState(status: "interrupted", detail: "客户端断开")
                await cleanup()
                continuation.finish()
            } catch {
                // 最终安全网（L1520-1523）：任何异常都转 error 事件，不裸抛堆栈
                let detail = "内部错误: \(error)"
                persistAssistant(truncated: true)
                flushExecState(status: "error", detail: detail)
                yield(continuation, "error", ["detail": .string(detail)])
                await cleanup()
                continuation.finish()
            }
        } catch let e as SidecarError {
            // 端点前置校验（422 messages/sandbox_root）与入口落库失败 → 首字节前抛错
            continuation.finish(throwing: e)
        } catch {
            continuation.finish(throwing: SidecarError.httpError(
                status: 500, detail: String(describing: error)))
        }
    }

    // MARK: - api_chat_stop / api_chat_inject / api_auth_respond

    /// POST /api/chat/{sid}/stop（L1565-1584）。协议方法返回 Void：
    /// ok:false（无活流）也是 200 语义——HTTP 客户端本就不读 body，原生如实不抛错。
    public func stopChat(sessionId: String) async throws {
        let sid = sessionId.trimmingCharacters(in: .whitespaces)
        guard !sid.isEmpty else {
            throw SidecarError.httpError(status: 422, detail: "session_id 不能为空")
        }
        kernel.chatRuntime.requestChatCancel(sid)
    }

    /// POST /api/chat/{sid}/inject（L1593-1622）：
    /// 先落库（不丢，失败静默）再入队；仅活流接受（ok:false 原文案）。
    public func injectMessage(projectId: String, agentId: String,
                              sessionId: String, content: String) async throws -> InjectResult {
        let sid = sessionId.trimmingCharacters(in: .whitespaces)
        guard !sid.isEmpty else {
            throw SidecarError.httpError(status: 422, detail: "session_id 不能为空")
        }
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw SidecarError.httpError(status: 422, detail: "消息内容不能为空")
        }
        guard kernel.chatRuntime.isActive(sid) else {
            return InjectResult(ok: false, detail: "该会话当前没有进行中的生成，请直接发送")
        }
        // 先落库（不丢），再入队（交接给 loop）；落库失败不阻塞注入
        try? db.saveMessage(projectId: projectId.isEmpty ? sid : projectId,
                            sessionId: sid, agentId: agentId, role: "user", content: text)
        guard kernel.chatRuntime.push(sid, content: text) else {
            return InjectResult(ok: false, detail: "该会话当前没有进行中的生成，请直接发送")
        }
        return InjectResult(ok: true, detail: "已加入：模型完成当前这一步后会读到你的新消息")
    }

    /// POST /api/auth/respond（L781-797）：未知 request_id → 404；
    /// R2：批准 + remember ∈ session/always 且非 net_install → 记对应级别。
    public func respondAuth(_ body: AuthRespondRequest) async throws {
        let rid = body.request_id
        guard let entry = kernel.authCenter.pendingEntry(rid) else {
            throw SidecarError.httpError(status: 404, detail: "授权请求不存在或已过期")
        }
        _ = kernel.authCenter.respond(requestId: rid, allowed: body.allowed,
                                      enableNetwork: body.enable_network)
        if body.allowed, let remember = body.remember,
           (remember == "session" || remember == "always"),
           entry.action != "net_install" {
            kernel.authCenter.recordGrant(tool: entry.tool, action: entry.action,
                                          remember: remember)
        }
    }
}
