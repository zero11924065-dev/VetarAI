//
//  Wave0InfrastructureTests.swift
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

//  基础设施单测：
//    · SSEEventKind 事件枚举映射（12 类契约事件 + 未知事件容错）
//    · StreamAccumulator 缓冲合帧（纪律①）与 flush 保序（纪律③）
//    · 授权记忆键 / AuthCenter 会话记忆表 / net_install 不记忆
//    · AuthRespondRequest 编码（remember 缺省省略）
//    （P3-W6 侧车归零：SidecarManager 状态机/端口认领两组测试随被测类型一同退役删除）
//

import XCTest
@testable import VetarAINative

// MARK: - SSEEventKind

final class SSEEventKindTests: XCTestCase {

    // 12 类契约事件逐字映射（对齐侧车实际发出与前端白名单）
    func testAllContractEventsMap() {
        let cases: [(String, SSEEventKind)] = [
            ("token", .token), ("thinking", .thinking),
            ("tool_call", .toolCall), ("tool_result", .toolResult),
            ("state", .state), ("done", .done), ("error", .error),
            ("cancelled", .cancelled), ("segment_break", .segmentBreak),
            ("auth_request", .authRequest),
            ("compact_required", .compactRequired), ("compact_auto", .compactAuto),
        ]
        for (raw, kind) in cases {
            XCTAssertEqual(SSEEventKind(rawValue: raw), kind, "事件 \(raw) 映射失败")
        }
        XCTAssertEqual(SSEEventKind.allCases.count, 13)   // 12 + message 缺省
    }

    // 未知事件 → kind 为 nil（容错，不崩）
    func testUnknownEventYieldsNilKind() {
        let ev = SSEEvent(event: "future_event", data: [:], rawData: "")
        XCTAssertNil(ev.kind)
    }

    // 增量/终态分类
    func testIncrementalAndTerminalClassification() {
        XCTAssertTrue(SSEEventKind.token.isIncremental)
        XCTAssertTrue(SSEEventKind.thinking.isIncremental)
        XCTAssertFalse(SSEEventKind.toolCall.isIncremental)
        XCTAssertTrue(SSEEventKind.done.isTerminal)
        XCTAssertTrue(SSEEventKind.error.isTerminal)
        XCTAssertTrue(SSEEventKind.cancelled.isTerminal)
        XCTAssertFalse(SSEEventKind.token.isTerminal)
        // [DONE] 哨兵也算终态
        let sentinel = SSEEvent(event: "message", data: ["raw": "[DONE]"], rawData: "[DONE]")
        XCTAssertTrue(sentinel.isTerminalEvent)
    }
}

// MARK: - StreamAccumulator（纪律①③）

@MainActor
final class StreamAccumulatorTests: XCTestCase {

    // 增量先入缓冲，flush 才落地（纪律①：不逐事件写 UI）
    func testIncrementsBufferUntilFlush() {
        let acc = StreamAccumulator()
        var flushed: [(String, String)] = []
        acc.onFlush = { c, t in flushed.append((c, t)) }
        acc.append(content: "你")
        acc.append(content: "好")
        acc.append(thinking: "思考中")
        XCTAssertTrue(acc.hasPending)
        acc.flush()
        XCTAssertEqual(flushed.count, 1)
        XCTAssertEqual(flushed[0].0, "你好")
        XCTAssertEqual(flushed[0].1, "思考中")
        XCTAssertFalse(acc.hasPending)
    }

    // 空 flush 为 no-op（保序点不产生空回调）
    func testEmptyFlushIsNoOp() {
        let acc = StreamAccumulator()
        var calls = 0
        acc.onFlush = { _, _ in calls += 1 }
        acc.flush()
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(acc.flushCount, 0)
    }

    // 定频合帧：高频频度追加 → 实际 flush 次数远小于追加次数（异步等待一个帧周期）
    func testCoalescingAtFixedRate() async throws {
        let acc = StreamAccumulator(fps: 50)   // 20ms 一帧，测试提速
        var flushTexts: [String] = []
        acc.onFlush = { c, _ in flushTexts.append(c) }
        for i in 0..<50 {
            acc.append(content: "\(i)")
        }
        // 等两个帧周期，让所有调度 flush 完成
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertFalse(flushTexts.isEmpty)
        XCTAssertLessThan(flushTexts.count, 10, "50 次追加应被合帧为少数几次 flush，实际 \(flushTexts.count)")
        XCTAssertEqual(flushTexts.joined(), (0..<50).map(String.init).joined(), "合帧不得丢字")
    }
}

// MARK: - 授权记忆键与 AuthCenter

@MainActor
final class AuthCenterTests: XCTestCase {

    private func makePrompt(action: String = "delete", tool: String = "fs_delete",
                            path: String = "~/x.txt", extra: [String: Any] = [:]) -> AuthPrompt {
        AuthPrompt(id: "r1", action: action, toolName: tool, targetPath: path, extra: extra)
    }

    // 记忆键 = 动作 × 工具（不含路径：同类别操作不再重问）
    func testMemoryKeyIgnoresTargetPath() {
        let a = makePrompt(path: "~/a.txt").memoryKey
        let b = makePrompt(path: "~/b.txt").memoryKey
        XCTAssertEqual(a, b)
        let c = makePrompt(tool: "fs_write").memoryKey
        XCTAssertNotEqual(a, c)
    }

    // 联网安装不显示记忆按钮（安全敏感，每次必问）
    func testNetInstallHasNoRememberButtons() {
        let net = makePrompt(action: "net_install", tool: "install_skill")
        XCTAssertFalse(net.showsRememberButtons)
        XCTAssertTrue(net.isNetInstall)
        let del = makePrompt()
        XCTAssertTrue(del.showsRememberButtons)
    }

    // 「本会话不再询问」落会话记忆表；后续同类请求自动允许、不弹窗
    func testSessionMemoryAutoApproves() async {
        var posted: [AuthRespondRequest] = []
        let client = MockSidecarClient()
        client.onRespondAuth = { posted.append($0) }
        let auth = AuthCenter(logger: AppLogger(logDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("vetarai-test-logs-\(UUID().uuidString)")),
                              clientProvider: { client })

        auth.present(makePrompt())
        XCTAssertNotNil(auth.pending)
        await auth.decide(allowed: true, remember: .session)
        XCTAssertNil(auth.pending)
        XCTAssertTrue(auth.isRemembered(makePrompt().memoryKey))
        XCTAssertEqual(posted.last?.remember, "session")

        // 第二条同类请求：自动允许，不弹窗
        auth.handle(event: SSEEvent(event: "auth_request", data: [
            "request_id": "r2", "action": "delete", "tool_name": "fs_delete",
            "target_path": "~/other.txt",
        ], rawData: ""))
        XCTAssertNil(auth.pending)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(posted.last?.request_id, "r2")
        XCTAssertEqual(posted.last?.allowed, true)
        XCTAssertNil(posted.last?.remember)   // 自动允许为「仅本次」口径，不重复写记忆
    }

    // 「永久允许」只回传 remember=always，不落入 app 会话表（后端 config 管）
    func testAlwaysRememberNotInSessionTable() async {
        var posted: [AuthRespondRequest] = []
        let client = MockSidecarClient()
        client.onRespondAuth = { posted.append($0) }
        let auth = AuthCenter(logger: AppLogger(logDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("vetarai-test-logs-\(UUID().uuidString)")),
                              clientProvider: { client })

        auth.present(makePrompt())
        await auth.decide(allowed: true, remember: .always)
        XCTAssertEqual(posted.last?.remember, "always")
        XCTAssertFalse(auth.isRemembered(makePrompt().memoryKey))
    }

    // 拒绝不写记忆
    func testDenyDoesNotRemember() async {
        let client = MockSidecarClient()
        let auth = AuthCenter(logger: AppLogger(logDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("vetarai-test-logs-\(UUID().uuidString)")),
                              clientProvider: { client })
        auth.present(makePrompt())
        await auth.decide(allowed: false)
        XCTAssertFalse(auth.isRemembered(makePrompt().memoryKey))
    }

    // 缺 request_id 的 auth_request 被忽略（无法回传）
    func testMissingRequestIdIgnored() {
        let auth = AuthCenter(logger: AppLogger(logDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("vetarai-test-logs-\(UUID().uuidString)")))
        auth.handle(event: SSEEvent(event: "auth_request", data: ["action": "delete"], rawData: ""))
        XCTAssertNil(auth.pending)
    }

    // 弹窗文案分支（对齐前端四类）
    func testDialogCopyPerAction() {
        XCTAssertEqual(makePrompt(action: "net_install").dialogTitle, "联网安装确认")
        XCTAssertEqual(makePrompt(action: "net_install").confirmLabel, "允许安装")
        XCTAssertEqual(makePrompt(action: "app_module").dialogTitle, "应用模块操作确认")
        XCTAssertEqual(makePrompt(action: "app_module").confirmLabel, "允许执行")
        XCTAssertEqual(makePrompt(action: "computer_use").dialogTitle, "电脑操作确认")
        XCTAssertEqual(makePrompt().dialogTitle, "操作授权")
        XCTAssertEqual(makePrompt().confirmLabel, "允许")
        XCTAssertEqual(makePrompt(action: "mkdir").actionLabel, "新建目录")
        // net_install 且需要开网 → 勾选框出现
        let net = makePrompt(action: "net_install", extra: ["need_enable_network": true])
        XCTAssertTrue(net.showsEnableNetworkCheckbox)
        XCTAssertFalse(makePrompt(action: "net_install").showsEnableNetworkCheckbox)
    }
}

// MARK: - 授权回传编码

final class AuthEncodingTests: XCTestCase {

    // remember 缺省（nil）→ 键省略（对齐前端「普通允许/拒绝不带 remember」）
    func testRememberOmittedWhenNil() throws {
        let body = AuthRespondRequest(request_id: "r1", allowed: true, enable_network: false)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(body)) as? [String: Any])
        XCTAssertEqual(obj["request_id"] as? String, "r1")
        XCTAssertEqual(obj["allowed"] as? Bool, true)
        XCTAssertEqual(obj["enable_network"] as? Bool, false)
        XCTAssertNil(obj["remember"])
    }

    func testRememberEncodedWhenSet() throws {
        let body = AuthRespondRequest(request_id: "r2", allowed: true,
                                      enable_network: true, remember: AuthRemember.always.rawValue)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(body)) as? [String: Any])
        XCTAssertEqual(obj["remember"] as? String, "always")
        XCTAssertEqual(obj["enable_network"] as? Bool, true)
    }
}

// MARK: - Mock 客户端（面板测试通用，后续波次可复用）

final class MockSidecarClient: SidecarClientProtocol {
    let baseURL = URL(string: "http://127.0.0.1:1/api")!
    var probeResult: Result<Bool, Error> = .success(true)
    var onRespondAuth: ((AuthRespondRequest) -> Void)?
    private(set) var stoppedSessions: [String] = []

    func probeReady() async throws -> Bool { try probeResult.get() }
    func listModels() async throws -> [OllamaModel] { [] }
    func listProjects() async throws -> [SidecarProject] { [] }
    func createProject(name: String, workingDir: String) async throws -> String { "p1" }
    func listAgents(projectId: String) async throws -> [SidecarAgent] { [] }
    func createAgent(projectId: String, name: String, type: String, modelName: String?) async throws -> String { "a1" }
    func listSessions(projectId: String, agentId: String) async throws -> [ChatSession] { [] }
    func createSession(projectId: String, agentId: String, title: String) async throws -> String { "s1" }
    func loadMessages(projectId: String, sessionId: String) async throws -> [ChatMessage] { [] }
    func stopChat(sessionId: String) async throws { stoppedSessions.append(sessionId) }
    func respondAuth(_ body: AuthRespondRequest) async throws { onRespondAuth?(body) }
    func chatStream(_ body: ChatStreamRequest) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
