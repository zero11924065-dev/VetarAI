//
//  NativeChatEndpointsTests.swift
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

//  逐条翻译/锚定（⛔ 行为规格源 Python，语义以源码为准）：
//    · test_loop.py test 8  —— SSE 行格式（_sse_format app.py L978-979）逐字节
//    · test_loop.py test 13 —— gen() 心跳竞争（0.3s 事件 vs 15s 定时器 → next 胜）
//      + compute_heartbeat_interval（L1009-1023）公式分支
//    · 五 ctx 注入条件（L1097-1130：delegation 主会话四件套 / knowledge=project_id /
//      archive=开关+project+session / app_control 开关 / computer_use 开关）
//    · 端点前置校验（L1072-1077：messages 空 / sandbox_root 缺失 → 422 原文案）
//    · api_chat_stop（L1565-1584）/ api_chat_inject（L1593-1622）专例
//    · api_auth_respond（L781-797）+ R2 授权记忆（L145-177）+ 超时按拒绝（L217-220）
//      + finally 授权清理 failAll（L1550-1554）
//    · gen() 主循环端到端（B06 双落库 / work/state.json / 初始 state 事件 / done 收敛）
//    · 授权 SSE 驱动（_sse_authorizer L180-225 + auth_request L1391-1401：
//      app_control 高成本动作 → auth_request 事件 → respondAuth 放行 → 动作生效）
//    · C2 取消硬停止（L1402-1423：stop 端点 → cancelled 事件 + stopped 落库）
//
//  不打真网络/真模型：connector 全假；mktemp 数据根隔离。
//  说明（非规格偏差）：buildPlan 的 modelStrengthsText 仅在 config 配了 model_strengths
//  时才拉 /api/tags（本文件一律不配 → 零网络，对齐 Python L1138-1144 未配置零开销口径）；
//  contextLimit 的 /api/ps 探测对 localhost:11434 连接拒绝即失败 → 0（跳过预警），
//  与 Python except → _ctx_limit=0 同口径。
//

import XCTest
@testable import VetarAINative

// MARK: - 夹具：按序脚本的假 connector（同 NativeAgentLoopTests.FakeConn 范式）

private final class ScriptConn: NativeChatConnector, @unchecked Sendable {
    typealias Round = (content: [String], tools: [(String, [String: JSONValue])])
    let rounds: [Round]
    private(set) var calls = 0
    init(_ rounds: [Round]) { self.rounds = rounds }

    func chatStream(model: String, messages: [[String: JSONValue]],
                    tools: [JSONValue]?, images: [String]?)
        -> AsyncThrowingStream<NativeChatStreamEvent, Error> {
        let i = min(calls, rounds.count - 1)
        calls += 1
        let round = rounds[i]
        let callNo = calls
        return AsyncThrowingStream { cont in
            for ch in round.content { cont.yield(.contentDelta(ch)) }
            if !round.tools.isEmpty {
                let tcs: [[String: JSONValue]] = round.tools.map { (n, a) in
                    ["id": .string("mock_\(callNo)"),
                     "function": .object([
                        "name": .string(n),
                        "arguments": .string(NativeAgentLoop.dumps(.object(a))),
                     ])]
                }
                cont.yield(.toolCalls(tcs))
            }
            cont.yield(.done(promptEvalCount: 10, evalCount: 5))
            cont.finish()
        }
    }

    func chat(model: String, messages: [[String: JSONValue]]) async throws -> String { "" }
}

/// 永不产出的 connector（取消硬停止专例：模拟 prefill 期间的在飞请求）。
private final class HangingConn: NativeChatConnector, @unchecked Sendable {
    func chatStream(model: String, messages: [[String: JSONValue]],
                    tools: [JSONValue]?, images: [String]?)
        -> AsyncThrowingStream<NativeChatStreamEvent, Error> {
        AsyncThrowingStream { cont in
            let t = Task { try? await Task.sleep(nanoseconds: 600_000_000_000) }
            cont.onTermination = { @Sendable _ in t.cancel() }
        }
    }

    func chat(model: String, messages: [[String: JSONValue]]) async throws -> String { "" }
}

final class NativeChatEndpointsTests: XCTestCase {

    private var base: URL!
    private var kernel: NativeKernel!

    override func setUpWithError() throws {
        try super.setUpWithError()
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("p2w4d2_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        kernel = NativeKernel(dataRoot: base)
        NativeAppEvents.clearAll()
    }

    override func tearDownWithError() throws {
        NativeAppEvents.clearAll()
        kernel = nil
        try? FileManager.default.removeItem(at: base)
        try super.tearDownWithError()
    }

    /// 造项目+Agent+会话（返回三元组）。
    private func makeProjectAgentSession() throws -> (pid: String, aid: String, sid: String) {
        let wd = base.appendingPathComponent("wd")
        try FileManager.default.createDirectory(at: wd, withIntermediateDirectories: true)
        let pid = try kernel.database.createProject(name: "p", workingDir: wd.path)
        let aid = try kernel.database.addAgentConfig(projectId: pid, name: "小助手", type: "main")
        let sid = try kernel.database.createSession(projectId: pid, agentId: aid)
        return (pid, aid, sid)
    }

    private func waitUntil(_ cond: @escaping () -> Bool,
                           timeoutMs: UInt64 = 3000) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return cond()
    }

    // ══ test_loop.py test 8：SSE 事件行格式（_sse_format 逐字节）══

    func testT8_sseLineFormatByteExact() throws {
        // Python: f"event: {event}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n"
        let line = NativeSSEFormat.sseFormat("token", data: ["delta": .string("x")])
        XCTAssertEqual(line, "event: token\ndata: {\"delta\": \"x\"}\n\n",
                       "8a 行格式逐字节（event:/data: 前缀 + 双换行收尾）")
        // ensure_ascii=False：中文原样不转义
        let zh = NativeSSEFormat.sseFormat("token", data: ["delta": .string("你好")])
        XCTAssertEqual(zh, "event: token\ndata: {\"delta\": \"你好\"}\n\n",
                       "8b ensure_ascii=False 逐字节")
        // json.loads 可解析回原文（Python 断言同构）
        let lines = line.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertTrue(lines[0].hasPrefix("event: ") && lines[1].hasPrefix("data: "))
        let payload = String(lines[1].dropFirst("data: ".count))
        let parsed = NativeJSONWriter.loads(Data(payload.utf8))
        XCTAssertEqual(parsed, .object(["delta": .string("x")]), "8c data 可解析回原文")
        // 多键：Python 保插入序 / Swift 字典序（documented deviation）——断言解析等价
        let multi = NativeSSEFormat.sseFormat("state", data: ["step": .int(1), "max": .int(200)])
        let mlines = multi.split(separator: "\n", omittingEmptySubsequences: true)
        let mparsed = NativeJSONWriter.loads(Data(String(mlines[1].dropFirst(6)).utf8))
        XCTAssertEqual(mparsed, .object(["step": .int(1), "max": .int(200)]),
                       "8d 多键解析等价（键序偏差不影响 json.loads 语义）")
        // 协议常量（偏差①锚点：心跳/保活注释行）
        XCTAssertEqual(NativeSSEFormat.pingLine, ": ping\n\n")
        XCTAssertEqual(NativeSSEFormat.keepaliveLine, ": keepalive\n\n")
    }

    // ══ test_loop.py test 13：心跳竞争（15s 定时器 vs 下一事件）+ M5 动态间隔公式 ══

    func testT13_heartbeatRaceNextEventWins() async throws {
        // Python：fake_iter 0.3s 后出事件，timer=asyncio.sleep(15.0)，FIRST_COMPLETED → next
        let box = NativeChatEndpointAssembly.FirstWinner()
        let eventTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            box.fire(.event(NativeAgentLoopEvent(event: "token", data: ["delta": .string("x")])))
        }
        let timerTask = Task {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            box.fire(.timer)
        }
        let wake = await box.await()
        eventTask.cancel()
        timerTask.cancel()
        guard case .event(let ev?) = wake else {
            return XCTFail("13 心跳竞争：应为 next 事件胜出，实际 \(wake)")
        }
        XCTAssertEqual(ev.event, "token", "13 心跳竞争机制（next_task 胜出，不等 15s 心跳）")
    }

    func testComputeHeartbeatIntervalFormula() {
        // compute_heartbeat_interval（L1009-1023）：<2 事件 → base
        XCTAssertEqual(NativeSSEFormat.computeHeartbeatInterval(eventTimes: [], base: 15), 15)
        XCTAssertEqual(NativeSSEFormat.computeHeartbeatInterval(eventTimes: [1.0], base: 15), 15)
        // 均值 ×1.5 ≤ base → base（密集事件不缩小间隔）
        XCTAssertEqual(NativeSSEFormat.computeHeartbeatInterval(
            eventTimes: [0, 1, 2, 3], base: 15), 15)   // avg=1 → max(15, 1.5)=15
        // 稀疏事件放大：avg=20 → max(15, 30)=30
        XCTAssertEqual(NativeSSEFormat.computeHeartbeatInterval(
            eventTimes: [0, 20, 40], base: 15), 30)
        // avg ≤ 0 → base（时钟回拨防护）
        XCTAssertEqual(NativeSSEFormat.computeHeartbeatInterval(
            eventTimes: [5, 5, 5], base: 15), 15)
        // 环形：只取近 10 个（密集前缀须被挤出窗口——12 个事件 suffix(10) 后全为 20s 间隔）
        var ts: [Double] = [0, 0.1]
        ts.append(contentsOf: stride(from: 100.0, through: 280.0, by: 20.0))  // 10 个，间隔均 20
        let iv = NativeSSEFormat.computeHeartbeatInterval(eventTimes: ts, base: 15)
        XCTAssertEqual(iv, 30.0, accuracy: 0.001,
                       "近 10 个事件间隔均值 20 × 1.5 = 30")
    }

    // ══ 五 ctx 注入条件（buildPlan 组装产物锚定）══

    func testCtxInjectionConditions() async throws {
        let (pid, aid, sid) = try makeProjectAgentSession()
        let asm = kernel.chatEndpoints

        // ① 主会话四件套齐备 + auto_archive_unit → 五开关全量
        let full = ChatStreamRequest(
            agent_id: aid, model: "m",
            messages: [ChatStreamMessage(role: "user", content: "hi")],
            project_id: pid, session_id: sid,
            sandbox_root: base.path, auto_archive_unit: true)
        let plan1 = try await asm.buildPlan(full)
        XCTAssertTrue(plan1.canDelegate, "四件套齐备 → 可委派")
        XCTAssertTrue(plan1.knowledgeOn, "project_id 非空 → 知识上下文")
        XCTAssertTrue(plan1.archiveOn, "开关+project+session → 归档")
        XCTAssertTrue(plan1.systemPrompt.contains("【委派纪律】"), "可委派 → 提示词含委派纪律")

        // ② project_id 空 → 委派/知识/归档全关（即使 auto_archive_unit=true）
        let noProject = ChatStreamRequest(
            agent_id: "", model: "m",
            messages: [ChatStreamMessage(role: "user", content: "hi")],
            project_id: "", session_id: "",
            sandbox_root: base.path, auto_archive_unit: true)
        let plan2 = try await asm.buildPlan(noProject)
        XCTAssertFalse(plan2.canDelegate)
        XCTAssertFalse(plan2.knowledgeOn)
        XCTAssertFalse(plan2.archiveOn)
        XCTAssertFalse(plan2.systemPrompt.contains("【委派纪律】"), "不可委派 → 无委派纪律段")

        // ③ session_id 空（project+agent 在）→ 委派关/归档关，知识开
        let noSession = ChatStreamRequest(
            agent_id: aid, model: "m",
            messages: [ChatStreamMessage(role: "user", content: "hi")],
            project_id: pid, session_id: "",
            sandbox_root: base.path, auto_archive_unit: true)
        let plan3 = try await asm.buildPlan(noSession)
        XCTAssertFalse(plan3.canDelegate, "缺 session → 不可委派（TS-107 主会话限定）")
        XCTAssertFalse(plan3.archiveOn)
        XCTAssertTrue(plan3.knowledgeOn)

        // ④ app_control_enabled 开 → 模块目录注入；关 → 不注入
        _ = try kernel.config.reloadConfig(patch: ["app_control_enabled": .bool(true)])
        let plan4 = try await asm.buildPlan(full)
        XCTAssertTrue(plan4.appControlOn)
        XCTAssertTrue(plan4.systemPrompt.contains("【可用应用模块动作】"),
                      "开关开 → 注入模块动作清单（0.4.9 3.48.2）")
        _ = try kernel.config.reloadConfig(patch: ["app_control_enabled": .bool(false)])
        let plan5 = try await asm.buildPlan(full)
        XCTAssertFalse(plan5.appControlOn)
        XCTAssertFalse(plan5.systemPrompt.contains("【可用应用模块动作】"))

        // ⑤ computer_use_enabled 开 → CU 能力段
        _ = try kernel.config.reloadConfig(patch: ["computer_use_enabled": .bool(true)])
        let plan6 = try await asm.buildPlan(full)
        XCTAssertTrue(plan6.computerUseOn)
        XCTAssertTrue(plan6.systemPrompt.contains("【Computer Use】"),
                      "CU 总开关开 → 注入能力段（0.4.33 CU 三期 R1）")

        // ⑥ M5 心跳基础值：clamp(config, 5, 60)，缺省 15
        XCTAssertEqual(plan1.heartbeatBase, 15)
        // reload_config 越界按 store.py L339-342 校验拒绝（文案逐字；越界值只能经手工改磁盘进入）
        XCTAssertThrowsError(
            try kernel.config.reloadConfig(patch: ["heartbeat_interval": .double(120)])
        ) { XCTAssertTrue(String(describing: $0).contains("heartbeat_interval 必须是 5-60 的秒数"), "\($0)") }
        // 钳制路径：get_config 不校验磁盘值（store.py L461-489），app.py L1179 读取时钳
        var diskCfg = try kernel.config.getConfig()
        diskCfg["heartbeat_interval"] = .double(120)
        try NativeDatabase.dumpsUTF8(.object(diskCfg))
            .write(toFile: kernel.config.configPath().path, atomically: true, encoding: .utf8)
        let plan7 = try await asm.buildPlan(full)
        XCTAssertEqual(plan7.heartbeatBase, 60, "心跳上限钳 60（L1179）")
        diskCfg["heartbeat_interval"] = .double(1)
        try NativeDatabase.dumpsUTF8(.object(diskCfg))
            .write(toFile: kernel.config.configPath().path, atomically: true, encoding: .utf8)
        let plan8 = try await asm.buildPlan(full)
        XCTAssertEqual(plan8.heartbeatBase, 5, "心跳下限钳 5")
        // ⑦ max_tool_rounds 缺省 200
        XCTAssertEqual(plan1.maxRounds, 200)
    }

    // ══ 端点前置校验（422 原文案；首字节前 finish(throwing:)）══

    func testChatStreamValidation422() async throws {
        // messages 空 → 422「messages 不能为空」
        let empty = ChatStreamRequest(agent_id: "", model: "m", messages: [],
                                      project_id: "", session_id: "",
                                      sandbox_root: base.path)
        do {
            for try await _ in kernel.chatEndpoints.chatStream(empty) {}
            XCTFail("messages 空应抛 422")
        } catch let e as SidecarError {
            guard case .httpError(let status, let detail) = e else {
                return XCTFail("错误形态不对: \(e)")
            }
            XCTAssertEqual(status, 422)
            XCTAssertEqual(detail, "messages 不能为空")
        }
        // sandbox_root 缺失（无 sandbox_root 且 project/agent 未注册）→ 422 原文案
        let noSandbox = ChatStreamRequest(
            agent_id: "ghost", model: "m",
            messages: [ChatStreamMessage(role: "user", content: "hi")],
            project_id: "ghost-proj", session_id: "s")
        do {
            for try await _ in kernel.chatEndpoints.chatStream(noSandbox) {}
            XCTFail("sandbox_root 缺失应抛 422")
        } catch let e as SidecarError {
            guard case .httpError(let status, let detail) = e else {
                return XCTFail("错误形态不对: \(e)")
            }
            XCTAssertEqual(status, 422)
            XCTAssertEqual(detail, "sandbox_root 缺失：请传 sandbox_root 或 project_id+agent_id")
        }
    }

    // ══ api_chat_stop（L1565-1584）══

    func testStopChat() async throws {
        // 空 sid → 422 原文案
        do {
            try await kernel.chatEndpoints.stopChat(sessionId: "  ")
            XCTFail("空 sid 应抛 422")
        } catch let e as SidecarError {
            guard case .httpError(let status, let detail) = e else {
                return XCTFail("错误形态不对: \(e)")
            }
            XCTAssertEqual(status, 422)
            XCTAssertEqual(detail, "session_id 不能为空")
        }
        // 无活流 → 不抛错（Python ok:false 也是 200；Void 协议如实不抛）
        try await kernel.chatEndpoints.stopChat(sessionId: "no-such")
        // 活流：stop → 取消 waiter 立即唤醒（C2 即时停止）
        XCTAssertTrue(kernel.chatRuntime.registerStream("s-stop"))
        let waiter = Task { await self.kernel.chatRuntime.awaitChatCancel("s-stop") }
        try await kernel.chatEndpoints.stopChat(sessionId: "s-stop")
        // stop 后取消 waiter 须立即唤醒（C2 即时停止），2s 超时兜底
        try await withThrowingTaskGroup(of: Void.self) { g in
            g.addTask { try await waiter.value }
            g.addTask {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                throw SidecarError.decodeFailed("stop 后 2s 内未唤醒取消 waiter")
            }
            try await g.next()!
            g.cancelAll()
        }
        kernel.chatRuntime.unregisterStream("s-stop")
    }

    // ══ api_chat_inject（L1593-1622：先落库再入队，仅活流接受）══

    func testInjectMessage() async throws {
        let (pid, aid, sid) = try makeProjectAgentSession()
        // 空 sid → 422
        do {
            _ = try await kernel.chatEndpoints.injectMessage(
                projectId: pid, agentId: aid, sessionId: " ", content: "x")
            XCTFail("空 sid 应抛 422")
        } catch let e as SidecarError {
            guard case .httpError(let status, let detail) = e else {
                return XCTFail("错误形态不对: \(e)")
            }
            XCTAssertEqual(status, 422)
            XCTAssertEqual(detail, "session_id 不能为空")
        }
        // 空内容 → 422（strip 后）
        do {
            _ = try await kernel.chatEndpoints.injectMessage(
                projectId: pid, agentId: aid, sessionId: sid, content: " \n ")
            XCTFail("空内容应抛 422")
        } catch let e as SidecarError {
            guard case .httpError(let status, let detail) = e else {
                return XCTFail("错误形态不对: \(e)")
            }
            XCTAssertEqual(status, 422)
            XCTAssertEqual(detail, "消息内容不能为空")
        }
        // 无活流 → ok:false 原文案（不抛错）
        let r0 = try await kernel.chatEndpoints.injectMessage(
            projectId: pid, agentId: aid, sessionId: sid, content: "补充")
        XCTAssertFalse(r0.ok)
        XCTAssertEqual(r0.detail, "该会话当前没有进行中的生成，请直接发送")
        // 活流 → ok:true 原文案 + 先落库（strip 后）+ 入队可 drain
        kernel.chatRuntime.beginStream(sid)
        let r1 = try await kernel.chatEndpoints.injectMessage(
            projectId: pid, agentId: aid, sessionId: sid, content: "  补充材料  ")
        XCTAssertTrue(r1.ok)
        XCTAssertEqual(r1.detail, "已加入：模型完成当前这一步后会读到你的新消息")
        let msgs = try kernel.database.loadMessages(projectId: pid, sessionId: sid)
        XCTAssertEqual(msgs.last?.role, "user", "注入先落库（不丢）")
        XCTAssertEqual(msgs.last?.content, "补充材料", "落库为 strip 后文本")
        let drained = kernel.chatRuntime.makeInjectCheck(sid)()
        XCTAssertEqual(drained, ["补充材料"], "入队交接给 loop drain")
        kernel.chatRuntime.endStream(sid)
        // 活流结束后 → 回到 ok:false
        let r2 = try await kernel.chatEndpoints.injectMessage(
            projectId: pid, agentId: aid, sessionId: sid, content: "再来")
        XCTAssertFalse(r2.ok)
    }

    // ══ api_auth_respond + R2 授权记忆 + 超时按拒绝 + failAll ══

    func testRespondAuthAndGrantMemory() async throws {
        // 未知 rid → 404 原文案
        do {
            try await kernel.chatEndpoints.respondAuth(
                AuthRespondRequest(request_id: "deadbeef", allowed: true))
            XCTFail("未知 rid 应抛 404")
        } catch let e as SidecarError {
            guard case .httpError(let status, let detail) = e else {
                return XCTFail("错误形态不对: \(e)")
            }
            XCTAssertEqual(status, 404)
            XCTAssertEqual(detail, "授权请求不存在或已过期")
        }
        // session 记忆：批准 + remember=session → 同 (tool,action) 直放
        let auth = kernel.authCenter
        let rid = auth.beginRequest(tool: "delete_path", path: "/tmp/a", action: "delete", extra: [:])
        try await kernel.chatEndpoints.respondAuth(
            AuthRespondRequest(request_id: rid, allowed: true, remember: "session"))
        // app.py L221：pop 发生在 _sse_authorizer 被唤醒后（respond 端点不 pop）。
        // 本例直接 beginRequest 无等待者 → 手动模拟 authorizer 侧消费，恢复零挂起基线。
        _ = auth.pop(requestId: rid)
        XCTAssertTrue(auth.isGranted(tool: "delete_path", action: "delete"),
                      "R2：session 级记忆命中")
        let granted = await auth.makeAuthorizer().authorize(
            tool: "delete_path", path: "/tmp/b", action: "delete")
        XCTAssertTrue(granted, "记忆命中 → 不再弹窗直接放行（L202-205）")
        XCTAssertEqual(auth.pendingCount, 0, "记忆命中不产生新挂起")
        // net_install 永不记忆（双重把守：respond 端点侧）
        let rid2 = auth.beginRequest(tool: "install_plugin", path: "https://x",
                                     action: "net_install", extra: [:])
        try await kernel.chatEndpoints.respondAuth(
            AuthRespondRequest(request_id: rid2, allowed: true, remember: "always"))
        let cfg = try kernel.config.getConfig()
        // get_config() = defaults+disk 合并（store.py L467），默认键 auth_grants=[]
        // （store.py L172）恒存在——把守口径：清单仍为空（net_install 未写入任何记录）。
        XCTAssertEqual(cfg["auth_grants"], .array([]), "net_install 永不记忆（L790-793 端点把守）")
        // always 记忆落盘（非 net_install）
        let rid3 = auth.beginRequest(tool: "write_file", path: "/tmp/c", action: "write", extra: [:])
        try await kernel.chatEndpoints.respondAuth(
            AuthRespondRequest(request_id: rid3, allowed: true, remember: "always"))
        let cfg2 = try kernel.config.getConfig()
        guard case .array(let grants)? = cfg2["auth_grants"] else {
            return XCTFail("always 记忆应落 config auth_grants")
        }
        XCTAssertEqual(grants.count, 1)
        guard case .object(let grant) = grants[0] else {
            return XCTFail("grant 应为对象: \(grants[0])")
        }
        XCTAssertEqual(grant["tool"], .string("write_file"))
        XCTAssertEqual(grant["action"], .string("write"))
        // 拒绝不记忆（L164：只记批准）
        let rid4 = auth.beginRequest(tool: "web_search", path: "", action: "", extra: [:])
        try await kernel.chatEndpoints.respondAuth(
            AuthRespondRequest(request_id: rid4, allowed: false, remember: "always"))
        XCTAssertFalse(auth.isGranted(tool: "web_search", action: ""))
    }

    func testAuthTimeoutAndFailAll() async throws {
        // 超时按拒绝（L217-220）：auth_confirm_timeout=0.05 → authorize 返回 false 且挂起被 pop
        _ = try kernel.config.reloadConfig(patch: ["auth_confirm_timeout": .double(0.05)])
        let t0 = Date()
        let allowed = await kernel.authCenter.makeAuthorizer().authorize(
            tool: "delete_path", path: "/tmp/x", action: "delete")
        XCTAssertFalse(allowed, "超时按拒绝")
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2, "超时时长生效（非默认 600s）")
        XCTAssertEqual(kernel.authCenter.pendingCount, 0, "超时后 pop（不残留）")
        // failAll（gen() finally L1550-1554）：等待者被安全拒绝唤醒
        let auth = kernel.authCenter
        _ = auth.beginRequest(tool: "t", path: "p", action: "a", extra: [:])
        let waiter = Task {
            await auth.makeAuthorizer().authorize(tool: "t", path: "p", action: "a")
        }
        let registered = await waitUntil { auth.pendingCount >= 2 }
        XCTAssertTrue(registered, "beginRequest + authorize 各挂一笔")
        auth.failAll()
        let result = await waiter.value
        XCTAssertFalse(result, "failAll → result=false 安全拒绝")
        XCTAssertEqual(auth.pendingCount, 0)
    }

    // ══ gen() 主循环端到端（初始 state / token / done / B06 双落库 / state.json）══

    func testChatStreamMainLoopEndToEnd() async throws {
        let (pid, aid, sid) = try makeProjectAgentSession()
        let conn = ScriptConn([(content: ["你好", "世界"], tools: [])])
        let req = ChatStreamRequest(
            agent_id: aid, model: "m",
            messages: [ChatStreamMessage(role: "user", content: "问好")],
            project_id: pid, session_id: sid, sandbox_root: base.path)
        var events: [(String, [String: Any], String)] = []
        for try await ev in kernel.chatEndpoints.chatStream(req, connectorOverride: conn) {
            events.append((ev.event, ev.data, ev.rawData))
        }
        let names = events.map { $0.0 }
        // REQ-MSG-021：首个事件是初始 state（step 0 / max 200 / tokens 0）
        XCTAssertEqual(names.first, "state", "流启动后第一轮前先发初始 state（L1363）")
        XCTAssertEqual(events[0].1["step"] as? Int64, 0)
        XCTAssertEqual(events[0].1["max"] as? Int64, 200)
        // token 增量直通 + rawData 对齐 _sse_format
        let tokenIdx = try XCTUnwrap(names.firstIndex(of: "token"))
        XCTAssertEqual(events[tokenIdx].1["delta"] as? String, "你好")
        XCTAssertTrue(events[tokenIdx].2.hasPrefix("{\"delta\""),
                      "rawData = json.dumps(data)（消费侧拼 event: 行）")
        // done 收敛：content 全文
        let doneIdx = try XCTUnwrap(names.firstIndex(of: "done"))
        XCTAssertEqual(events[doneIdx].1["content"] as? String, "你好世界")
        // B06：user 消息入口落库 + assistant 定稿落库（非 truncated）
        let msgs = try kernel.database.loadMessages(projectId: pid, sessionId: sid)
        XCTAssertEqual(msgs.count, 2)
        XCTAssertEqual(msgs[0].role, "user")
        XCTAssertEqual(msgs[0].content, "问好")
        XCTAssertEqual(msgs[1].role, "assistant")
        XCTAssertEqual(msgs[1].content, "你好世界")
        XCTAssertEqual(msgs[1].modelUsed, "m")
        XCTAssertFalse(msgs[1].truncated, "done 路径非截断落库")
        XCTAssertFalse(msgs[1].stopped)
        // work/state.json：done 终态
        let st = kernel.state.read(projectId: pid)
        XCTAssertTrue(st.exists)
        XCTAssertEqual(st.state?["status"]?.string, "done")
        XCTAssertEqual(st.state?["text_chars"]?.int, 4)
    }

    // ══ 授权 SSE 驱动（_sse_authorizer + auth_request + respondAuth 全链路）══

    func testChatStreamAuthRequestSSEDriven() async throws {
        let (pid, aid, sid) = try makeProjectAgentSession()
        // 规格（registry.py L636-640）：配置 app_control_confirm 优先于注册表默认
        // needs_confirm；默认清单 ["workflow_run","roundtable_create"]（store.py L150）
        // 不含 workflow_delete → 默认配置下删除工作流按规格【不】弹确认。此处经设置页
        // 同路径把 workflow_delete 加入确认清单（用户可调项），使高成本动作走授权链。
        _ = try kernel.config.reloadConfig(patch: [
            "app_control_enabled": .bool(true),
            "app_control_confirm": .array([.string("workflow_run"),
                                           .string("roundtable_create"),
                                           .string("workflow_delete")]),
        ])
        // 造一个可删的工作流（app_control workflow.delete 注册表默认 needsConfirm=true）
        let wfId = try kernel.workflow.createWorkflow(
            name: "待删",
            definition: .object([
                "nodes": .array([
                    .object(["id": .string("s"), "type": .string("start")]),
                    .object(["id": .string("e"), "type": .string("end"), "output": .string("x")]),
                ]),
                "edges": .array([.object(["from": .string("s"), "to": .string("e")])]),
            ]),
            description: "")
        let conn = ScriptConn([
            (content: [], tools: [("app_control", [
                "module": .string("workflow"), "action": .string("delete"),
                "params": .object(["workflow_id": .string(wfId)]),
            ])]),
            (content: ["已删除"], tools: []),
        ])
        let req = ChatStreamRequest(
            agent_id: aid, model: "m",
            messages: [ChatStreamMessage(role: "user", content: "删掉它")],
            project_id: pid, session_id: sid, sandbox_root: base.path)
        var authSeen: [String: Any]?
        var toolResultOk: Bool?
        var names: [String] = []
        for try await ev in kernel.chatEndpoints.chatStream(req, connectorOverride: conn) {
            names.append(ev.event)
            if ev.event == "auth_request" {
                authSeen = ev.data
                // 面板等价：拿到 request_id 后回传批准（L784-797）
                let rid = try XCTUnwrap(ev.data["request_id"] as? String)
                try await kernel.chatEndpoints.respondAuth(
                    AuthRespondRequest(request_id: rid, allowed: true))
            }
            if ev.event == "tool_result" {
                toolResultOk = ev.data["ok"] as? Bool
            }
        }
        // auth_request 事件字段齐全（L1394-1400）
        let auth = try XCTUnwrap(authSeen, "高成本动作应触发 auth_request SSE 事件")
        XCTAssertEqual(auth["tool_name"] as? String, "app_control:workflow.delete")
        XCTAssertEqual(auth["action"] as? String, "app_module")
        XCTAssertNotNil(auth["target_path"] as? String, "detail 入 target_path")
        XCTAssertNotNil(auth["extra"])
        // 批准 → 动作真实生效
        XCTAssertEqual(toolResultOk, true, "批准 → dispatch 执行成功")
        XCTAssertNil(try kernel.workflow.getWorkflowRow(wfId), "工作流已被删除")
        XCTAssertTrue(names.contains("done"))
        // A13 Agent 路径 notify（registry handler 经真总线）
        let bufCount = NativeAppEvents.bufferedCount()
        XCTAssertGreaterThanOrEqual(bufCount, 1, "workflow/delete 已推 A13 总线")
    }

    // ══ C2 取消硬停止（stop 端点 → cancelled 事件 + stopped 落库 + interrupted 快照）══

    func testChatStreamUserCancel() async throws {
        let (pid, aid, sid) = try makeProjectAgentSession()
        let req = ChatStreamRequest(
            agent_id: aid, model: "m",
            messages: [ChatStreamMessage(role: "user", content: "长篇")],
            project_id: pid, session_id: sid, sandbox_root: base.path)
        // 等待活流注册后调 stop 端点（C2：点停止立即唤醒，不等心跳）
        let stopper = Task {
            let ok = await self.waitUntil { self.kernel.chatRuntime.isActive(sid) }
            XCTAssertTrue(ok, "活流应已注册（begin_stream）")
            try await self.kernel.chatEndpoints.stopChat(sessionId: sid)
        }
        var names: [String] = []
        var cancelledDetail: String?
        for try await ev in kernel.chatEndpoints.chatStream(req, connectorOverride: HangingConn()) {
            names.append(ev.event)
            if ev.event == "cancelled" { cancelledDetail = ev.data["detail"] as? String }
        }
        try await stopper.value
        XCTAssertEqual(names.first, "state")
        XCTAssertTrue(names.contains("cancelled"), "取消路径产出 cancelled 事件（L1422）")
        XCTAssertEqual(cancelledDetail, "已停止生成")
        XCTAssertFalse(names.contains("done"))
        // C8：stopped=true 落库（truncated；内容为已生成部分——此处为空）
        let msgs = try kernel.database.loadMessages(projectId: pid, sessionId: sid)
        XCTAssertEqual(msgs.count, 2)
        XCTAssertEqual(msgs[1].role, "assistant")
        XCTAssertTrue(msgs[1].truncated)
        XCTAssertTrue(msgs[1].stopped, "用户主动停止 → stopped 落库")
        // state.json interrupted 原文案
        let st = kernel.state.read(projectId: pid)
        XCTAssertEqual(st.state?["status"]?.string, "interrupted")
        XCTAssertEqual(st.state?["detail"]?.string, "用户已停止生成")
        // finally：取消标志已清理（停止按钮不永久生效，L1525-1535）
        XCTAssertFalse(kernel.chatRuntime.isActive(sid))
    }

    // ══ 0.7.8 实测 Bug3：sandbox_root 缺省 → 端点按 project_id+agent_id 解析
    //    projects.working_dir（修复前面板恒传 <数据根>/pilot-sandbox，委派落点错误
    //    且该目录位于敏感域内写入必触发授权）══

    func testChatStreamResolvesProjectWorkingDirWhenSandboxRootOmitted() throws {
        let (pid, aid, sid) = try makeProjectAgentSession()   // working_dir = base/wd
        // createProject 落库前 expanduser().resolve()（/var→/private/var firmlink 亦解），
        // 断言基准必须读 DB 存储真值，而不是测试侧未解析的拼接路径。
        let storedWd = try XCTUnwrap(try kernel.database.getProject(pid)?.workingDir)
        XCTAssertTrue(storedWd.hasSuffix("/wd"), "预置：项目工作目录即 base/wd 的解析形态")

        // ① 不传 sandbox_root（0.7.8 起面板口径）→ 解析到项目 working_dir
        let omitted = ChatStreamRequest(
            agent_id: aid, model: "m",
            messages: [ChatStreamMessage(role: "user", content: "hi")],
            project_id: pid, session_id: sid)
        let resolved = kernel.chatEndpoints.resolveSandboxRoot(omitted)
        XCTAssertEqual(resolved, storedWd,
                       "Bug3：前端不传 sandbox_root 时端点必须解析到项目工作目录")
        XCTAssertFalse(resolved?.contains("pilot-sandbox") ?? true,
                       "Bug3：绝不再落 <数据根>/pilot-sandbox（敏感域内，写入必触发授权）")

        // ② 显式传入优先（既有行为不回归）
        let explicit = ChatStreamRequest(
            agent_id: aid, model: "m",
            messages: [ChatStreamMessage(role: "user", content: "hi")],
            project_id: pid, session_id: sid, sandbox_root: base.path)
        XCTAssertEqual(kernel.chatEndpoints.resolveSandboxRoot(explicit), base.path,
                       "显式 sandbox_root 优先（旧客户端/重跑路径兼容）")

        // ③ DB 中 working_dir 为空串（legacy/手改数据，公开 API 已拦空值，只能直接改库
        //   构造）→ 落空 nil（0.7.8 加固：空串不得作为锚点上返，走 422 诚实报错）
        let pidEmpty = try kernel.database.createProject(name: "pe", workingDir: base.path)
        let aidEmpty = try kernel.database.addAgentConfig(projectId: pidEmpty, name: "a",
                                                          type: "main")
        let sidEmpty = try kernel.database.createSession(projectId: pidEmpty, agentId: aidEmpty)
        try kernel.database.withWriteConn(global: true) { conn in
            try conn.execute("UPDATE projects SET working_dir = '' WHERE id = ?",
                             [.text(pidEmpty)])
        }
        let emptyWd = ChatStreamRequest(
            agent_id: aidEmpty, model: "m",
            messages: [ChatStreamMessage(role: "user", content: "hi")],
            project_id: pidEmpty, session_id: sidEmpty)
        XCTAssertNil(kernel.chatEndpoints.resolveSandboxRoot(emptyWd),
                     "空 working_dir → nil（走 422 诚实报错，而非静默绑到空锚点）")
    }
}
