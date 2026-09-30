//
//  Bug4DelegationAuthorizerTests.swift
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

//  根因（文件：行号，修复前）：NativeKernel.swift delegationEngine 装配段
//  （原 L136-163）未传 `authorizer:` —— 缺省 nil → 子会话敏感路径写入走
//  NativeToolRegistry.swift L352-355 的「denied: 敏感路径写入需用户确认
//  （当前无授权通道）」分支，委派交卷必 failed（与业主截图交卷原文一致）。
//
//  修复：装配挂 `authorizer: authCenter.makeAuthorizer()`——进程级授权中心与
//  主会话同源：子会话请求经主流 gen() 心跳 drainUnsent 冒泡主 UI（委派期间主流
//  阻塞在 delegate_task 但心跳照常唤醒）；R2 授权记忆 isGranted 命中即放行；
//  主流停止时 cleanup() 的 auth.failAll() 保证挂起请求安全拒绝。
//
//  钉桩三条：
//    ① 装配断言——kernel.delegationEngine.authorizer 非 nil（防回退）；
//    ② 端到端放行——子 agent write_file 敏感路径 → 授权中心挂起 → respond 放行
//      → 文件真落盘 + 交卷 success（通道贯通，不再是「无授权通道」）；
//    ③ 端到端拒绝——respond 拒绝 → denied_by_user 回注、文件不落盘（不静默执行）。
//
//  隔离纪律：mktemp 数据根 + 假 connector；isSensitive 注入把沙盒子目录伪造成
//  敏感区（对齐 NativeToolRegistryTests 的 monkeypatch 等价手法），绝不碰真实
//  系统敏感路径。进程级串行锁各用例复位，不得并行化。
//

import XCTest
@testable import VetarAINative

/// 首轮 write_file（敏感路径）工具调用、次轮按交卷契约文本收尾的脚本 connector。
/// （ScriptConn/DelegScriptConn 混合范式：toolCalls 帧格式同 NativeChatEndpointsTests，
/// 交卷 task_id 动态取最新任务同 DelegScriptConn.currentTid。）
private final class DelegSensitiveWriteConn: NativeChatConnector, @unchecked Sendable {
    let writePath: String
    let writeContent: String
    let db: NativeDatabase
    let pid: String
    private(set) var calls = 0

    init(writePath: String, writeContent: String, db: NativeDatabase, pid: String) {
        self.writePath = writePath
        self.writeContent = writeContent
        self.db = db
        self.pid = pid
    }

    func chatStream(model: String, messages: [[String: JSONValue]],
                    tools: [JSONValue]?, images: [String]?)
        -> AsyncThrowingStream<NativeChatStreamEvent, Error> {
        let i = min(calls, 1)
        calls += 1
        let tid = (try? db.listAgentTasks(projectId: pid, limit: 1))?.first?.id ?? ""
        return AsyncThrowingStream { cont in
            if i == 0 {
                // 轮 1：write_file 工具调用（敏感路径）
                let args: [String: JSONValue] = ["path": .string(writePath),
                                                 "content": .string(writeContent)]
                cont.yield(.toolCalls([[
                    "id": .string("mock_sensitive_write"),
                    "function": .object([
                        "name": .string("write_file"),
                        "arguments": .string(NativeAgentLoop.dumps(.object(args))),
                    ])]]))
                cont.yield(.done(promptEvalCount: 10, evalCount: 5))
            } else {
                // 轮 2：合法交卷（契约 JSON 全文）
                cont.yield(.contentDelta(NativeDatabase.dumpsUTF8(.object([
                    "task_id": .string(tid), "status": .string("success"),
                    "summary": .string("敏感写入已完成"),
                    "artifacts": .array([.string(writePath)]),
                ]))))
                cont.yield(.done(promptEvalCount: 10, evalCount: 5))
            }
            cont.finish()
        }
    }

    func chat(model: String, messages: [[String: JSONValue]]) async throws -> String { "" }
}

final class Bug4DelegationAuthorizerTests: XCTestCase {

    private var tmp: URL!
    private var db: NativeDatabase!
    private var sandbox: URL!
    private var sensitiveDir: URL!
    private var pid: String!
    private var mainId: String!
    private var betaId: String!
    private var parentSid: String!
    private var beta: NativeDatabase.AgentConfigRow!
    private var center: NativeAuthCenter!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bug4_deleg_auth_\(UUID().uuidString)")
        sandbox = tmp.appendingPathComponent("work")
        sensitiveDir = sandbox.appendingPathComponent("secret")
        try FileManager.default.createDirectory(at: sensitiveDir, withIntermediateDirectories: true)
        db = NativeDatabase(projectsRoot: tmp.appendingPathComponent("projects"))
        pid = try db.createProject(name: "bug4", workingDir: tmp.appendingPathComponent("wd").path)
        mainId = try db.addAgentConfig(projectId: pid, name: "Alpha", type: "main",
                                       modelName: "qwen3.8")
        betaId = try db.addAgentConfig(projectId: pid, name: "Beta", type: "sub",
                                       role: "写手", systemPrompt: "简洁", modelName: "qwen3.8")
        parentSid = try db.createSession(projectId: pid, agentId: mainId, title: "主会话")
        beta = try db.getAgentConfig(projectId: pid, agentId: betaId)
        center = NativeAuthCenter(configProvider: { [:] })
        NativeDelegationEngine.resetSharedState()
        NativeDelegationEvents.clearAll()
    }

    override func tearDownWithError() throws {
        NativeDelegationEvents.clearAll()
        NativeDelegationEngine.resetSharedState()
        try? FileManager.default.removeItem(at: tmp)
        try super.tearDownWithError()
    }

    private func makeEngine(_ conn: any NativeChatConnector) -> NativeDelegationEngine {
        // 与生产装配同形：authorizer = 授权中心 SSE 形态；toolContext 的 isSensitive
        // 注入伪造敏感区（仅本用例沙盒内 secret/ 子目录判定为敏感）。
        let sensitivePrefix = sensitiveDir.path
        return NativeDelegationEngine(
            db: db, connector: conn,
            authorizer: NativeSSEAuthorizer(center: center),
            toolContext: NativeToolTestSupport.makeContext(
                dataRoot: tmp, isSensitive: { $0.hasPrefix(sensitivePrefix) }))
    }

    private func req() -> NativeDelegationTaskRequest {
        NativeDelegationTaskRequest(projectId: pid, parentAgentId: mainId,
                                    parentSessionId: parentSid, targetAgent: beta,
                                    task: "把机密笔记写入 secret 区", expect: "写入并交卷",
                                    sandboxRoot: sandbox.path, maxRounds: 5)
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

    // ══ 钉桩①：装配断言（根因直连——缺省 nil 即 Bug4 复发）══

    func testKernelDelegationEngineAssemblyHasAuthorizer() throws {
        let dataRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("bug4_kernel_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let kernel = NativeKernel(dataRoot: dataRoot)
        XCTAssertNotNil(kernel.delegationEngine.authorizer,
                        "Bug4 装配钉桩：委派引擎必须挂授权通道（子会话敏感路径写入"
                        + "要能冒泡主 UI 授权弹窗，而非直接「当前无授权通道」拒绝）")
    }

    // ══ 钉桩②：端到端放行——挂起 → respond(true) → 文件落盘 + 交卷成功 ══

    func testDelegatedSensitiveWriteBubblesToAuthCenterAndSucceeds() async throws {
        let target = "secret/note.txt"
        let conn = DelegSensitiveWriteConn(writePath: target, writeContent: "机密笔记正文",
                                           db: db, pid: pid)
        let engine = makeEngine(conn)
        let run = Task { try await engine.runDelegatedTask(req()) }

        // 子 agent 的 write_file 触发敏感判定 → authorizer 挂起到授权中心
        let pendOk = await waitUntil { self.center.pendingCount == 1 }
        XCTAssertTrue(pendOk, "Bug4：敏感路径写入必须在授权中心挂起请求（修复前直接拒绝）")

        let rid = try XCTUnwrap(center.pendingUnresolved().first)
        let entry = try XCTUnwrap(center.pendingEntry(rid))
        XCTAssertEqual(entry.tool, "write_file")
        XCTAssertEqual(entry.action, "write")
        XCTAssertTrue(entry.path.hasPrefix(sensitiveDir.path),
                      "挂起请求的路径应为解析后的敏感区绝对路径")

        // 用户在主 UI 点「允许」
        XCTAssertTrue(center.respond(requestId: rid, allowed: true, enableNetwork: false))

        let res = try await run.value
        XCTAssertEqual(res["ok"], .bool(true), "放行后委派应交卷成功（修复前必 failed）")
        XCTAssertEqual(res["status"]?.string, "success")
        let written = try String(contentsOf: sensitiveDir.appendingPathComponent("note.txt"),
                                 encoding: .utf8)
        XCTAssertEqual(written, "机密笔记正文", "放行后文件必须真落盘（授权通道端到端贯通）")
    }

    // ══ 钉桩③：端到端拒绝——respond(false) → denied_by_user + 文件不落盘 ══

    func testDelegatedSensitiveWriteDeniedByUserDoesNotExecute() async throws {
        let target = "secret/denied.txt"
        let conn = DelegSensitiveWriteConn(writePath: target, writeContent: "不应落盘",
                                           db: db, pid: pid)
        let engine = makeEngine(conn)
        let run = Task { try await engine.runDelegatedTask(req()) }

        let pendOk = await waitUntil { self.center.pendingCount == 1 }
        XCTAssertTrue(pendOk)
        let rid = try XCTUnwrap(center.pendingUnresolved().first)

        // 用户在主 UI 点「拒绝」
        XCTAssertTrue(center.respond(requestId: rid, allowed: false, enableNetwork: false))

        let res = try await run.value
        XCTAssertEqual(res["ok"], .bool(true),
                       "拒绝单条工具不等于委派失败（ denied 回注后模型照常交卷）")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: sensitiveDir.appendingPathComponent("denied.txt").path),
            "拒绝后文件绝不落盘（授权通道不静默执行）")
    }
}
