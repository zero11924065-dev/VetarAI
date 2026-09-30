//
//  NativeDeleteOrchestrationTests.swift
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
//    · DELETE /api/agents/{pid}/{aid}（app.py L380-397）：
//      取消 status∈(queued,running) 且 target_agent_id 或 parent_agent_id 命中的
//      委派任务（limit=200）→ 有停止等 1s → remove_agent_config；
//      stop 段失败不影响删除；removed=false 不 404；无 SSE notify（对照
//      independent-agents 删除有 A13——此端点逐字不发）
//    · DELETE /api/sessions/{sid}?project_id=（app.py L729-756）：
//      取消 session_id 或 parent_session_id 命中的在飞委派 → 等 1s →
//      delete_session（false → 404「会话不存在」，404 时不动任何附件文件）→
//      delete_session_attachments（store.py L715-736：单层清文件计数、
//      子目录保留、目录空才 rmdir）
//    · 规格偏差锚定：docstring（app.py L733）声称清 _auth_pending，端点体未做
//

import XCTest
@testable import VetarAINative

final class NativeDeleteOrchestrationTests: XCTestCase {

    private var base: URL!
    private var kernel: NativeKernel!
    private var client: NativeSidecarClient!

    override func setUpWithError() throws {
        try super.setUpWithError()
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3w1a_del_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        kernel = NativeKernel(dataRoot: base)
        client = NativeSidecarClient(kernel: kernel)
        NativeAppEvents.clearAll()
        NativeDelegationEngine.resetSharedState()
    }

    override func tearDownWithError() throws {
        NativeAppEvents.clearAll()
        NativeDelegationEngine.resetSharedState()
        client = nil
        kernel = nil
        try? FileManager.default.removeItem(at: base)
        try super.tearDownWithError()
    }

    private func makeProject() throws -> String {
        let wd = base.appendingPathComponent("wd")
        try FileManager.default.createDirectory(at: wd, withIntermediateDirectories: true)
        return try kernel.database.createProject(name: "p", workingDir: wd.path)
    }

    private func attachmentsDir(_ pid: String, _ sid: String) -> URL {
        kernel.database.projectsRoot.appendingPathComponent(pid)
            .appendingPathComponent("attachments").appendingPathComponent(sid)
    }

    // ══ 删 Agent 编排（app.py L380-397）══

    /// 命中规则：target 或 parent 命中且状态 queued/running → 置取消标志；
    /// 其他状态 / 不命中 → 不动。删后配置行消失；总线零事件（端点无 notify）。
    func testAgentDeleteCancelsMatchingDelegationTasks() async throws {
        let pid = try makeProject()
        let aMain = try kernel.database.addAgentConfig(projectId: pid, name: "主", type: "main")
        let aSub = try kernel.database.addAgentConfig(projectId: pid, name: "子", type: "sub")
        let aOther = try kernel.database.addAgentConfig(projectId: pid, name: "路人", type: "sub")

        let t1 = try kernel.database.createAgentTask(   // target 命中 + queued → 取消
            projectId: pid, parentAgentId: aMain, parentSessionId: "s0",
            targetAgentId: aSub, targetAgentName: "子", task: "t1", expect: "")
        let t2 = try kernel.database.createAgentTask(   // parent 命中 + running → 取消
            projectId: pid, parentAgentId: aSub, parentSessionId: "s0",
            targetAgentId: aOther, targetAgentName: "路人", task: "t2", expect: "")
        _ = try kernel.database.updateAgentTask(projectId: pid, taskId: t2, status: "running")
        let t3 = try kernel.database.createAgentTask(   // 不命中 → 不动
            projectId: pid, parentAgentId: aMain, parentSessionId: "s0",
            targetAgentId: aOther, targetAgentName: "路人", task: "t3", expect: "")
        let t4 = try kernel.database.createAgentTask(   // target 命中但 done → 不动
            projectId: pid, parentAgentId: aMain, parentSessionId: "s0",
            targetAgentId: aSub, targetAgentName: "子", task: "t4", expect: "")
        _ = try kernel.database.updateAgentTask(projectId: pid, taskId: t4, status: "done")

        let seq0 = NativeAppEvents.latestSeq()
        let t0 = Date()
        try await client.deleteAgent(projectId: pid, agentId: aSub)
        let elapsed = Date().timeIntervalSince(t0)

        XCTAssertNil(try kernel.database.getAgentConfig(projectId: pid, agentId: aSub),
                     "remove_agent_config 已执行")
        XCTAssertNotNil(try kernel.database.getAgentConfig(projectId: pid, agentId: aMain))
        XCTAssertNotNil(try kernel.database.getAgentConfig(projectId: pid, agentId: aOther))
        XCTAssertTrue(NativeDelegationEngine.isDelegationCancelled(t1), "target 命中 queued 应取消")
        XCTAssertTrue(NativeDelegationEngine.isDelegationCancelled(t2), "parent 命中 running 应取消")
        XCTAssertFalse(NativeDelegationEngine.isDelegationCancelled(t3), "不命中不动")
        XCTAssertFalse(NativeDelegationEngine.isDelegationCancelled(t4), "done 不在 (queued,running) 白名单")
        XCTAssertGreaterThanOrEqual(elapsed, 1.0,
                                    "stopped=2 → 端点等 1s 让执行循环检测取消标志（TS-115）")
        XCTAssertEqual(NativeAppEvents.latestSeq(), seq0,
                       "删 Agent 端点无 SSE notify（对照 independent-agents 删除有 A13）")
    }

    /// 无关联任务 → 不 sleep 直接删（stopped=0 分支）。
    func testAgentDeleteWithoutMatchingTasksSkipsSleep() async throws {
        let pid = try makeProject()
        let aSub = try kernel.database.addAgentConfig(projectId: pid, name: "子", type: "sub")
        let t0 = Date()
        try await client.deleteAgent(projectId: pid, agentId: aSub)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.5, "stopped=0 → 不等 1s")
        XCTAssertNil(try kernel.database.getAgentConfig(projectId: pid, agentId: aSub))
    }

    /// 删不存在的 Agent：removed=false 不抛 404（端点恒 200 口径）。
    func testAgentDeleteMissingIsNotAnError() async throws {
        let pid = try makeProject()
        try await client.deleteAgent(projectId: pid, agentId: "ghost")
    }

    // ══ 删会话编排（app.py L729-756 + store.py L715-736）══

    /// 全链路：取消命中任务（session_id / parent_session_id）→ DB 删除 →
    /// 附件目录清理（文件计数删除、子目录保留、非空目录不 rmdir）。
    func testSessionDeleteOrchestration() async throws {
        let pid = try makeProject()
        let aid = try kernel.database.addAgentConfig(projectId: pid, name: "主", type: "main")
        let sid = try kernel.database.createSession(projectId: pid, agentId: aid, title: "s")
        try kernel.database.saveMessage(projectId: pid, sessionId: sid, agentId: aid,
                                        role: "user", content: "你好")
        try kernel.database.saveMessage(projectId: pid, sessionId: sid, agentId: aid,
                                        role: "assistant", content: "在")

        // 附件目录：2 个文件 + 1 个子目录（内含 1 文件——iterdir 单层口径应保留）
        let dir = attachmentsDir(pid, sid)
        let sub = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "a".write(to: dir.appendingPathComponent("f1.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: dir.appendingPathComponent("f2.txt"), atomically: true, encoding: .utf8)
        try "c".write(to: sub.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)

        let t1 = try kernel.database.createAgentTask(   // session_id 命中 → 取消
            projectId: pid, parentAgentId: aid, parentSessionId: "s0",
            targetAgentId: "x", targetAgentName: "x", task: "t1", expect: "")
        _ = try kernel.database.updateAgentTask(projectId: pid, taskId: t1, sessionId: sid)
        let t2 = try kernel.database.createAgentTask(   // parent_session_id 命中 + running → 取消
            projectId: pid, parentAgentId: aid, parentSessionId: sid,
            targetAgentId: "x", targetAgentName: "x", task: "t2", expect: "")
        _ = try kernel.database.updateAgentTask(projectId: pid, taskId: t2, status: "running")
        let t3 = try kernel.database.createAgentTask(   // 别的会话 → 不动
            projectId: pid, parentAgentId: aid, parentSessionId: "s9",
            targetAgentId: "x", targetAgentName: "x", task: "t3", expect: "")
        _ = try kernel.database.updateAgentTask(projectId: pid, taskId: t3, sessionId: "s9")

        let seq0 = NativeAppEvents.latestSeq()
        let ok = try await client.deleteSession(projectId: pid, sessionId: sid)
        XCTAssertTrue(ok)

        XCTAssertTrue(try kernel.database.listSessions(projectId: pid, agentId: aid).isEmpty,
                      "delete_session 已执行")
        XCTAssertTrue(try kernel.database.loadMessages(projectId: pid, sessionId: sid).isEmpty,
                      "消息连带删除")
        XCTAssertTrue(NativeDelegationEngine.isDelegationCancelled(t1), "session_id 命中应取消")
        XCTAssertTrue(NativeDelegationEngine.isDelegationCancelled(t2), "parent_session_id 命中应取消")
        XCTAssertFalse(NativeDelegationEngine.isDelegationCancelled(t3), "别的会话不动")

        // 附件：两个顶层文件删掉；子目录（非文件）保留 → 目录非空不 rmdir
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("f1.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("f2.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: sub.appendingPathComponent("keep.txt").path),
            "iterdir 单层口径：子目录不递归清理")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path),
                      "目录非空 → rmdir 跳过（Python OSError 保留分支）")
        XCTAssertEqual(NativeAppEvents.latestSeq(), seq0, "删会话端点无 SSE notify")
    }

    /// 404 语义：会话不存在 → 抛「会话不存在」，且不得删任何附件文件（清理在删除之后）。
    func testSessionDelete404SkipsAttachmentCleanup() async throws {
        let pid = try makeProject()
        let ghostDir = attachmentsDir(pid, "ghost")
        try FileManager.default.createDirectory(at: ghostDir, withIntermediateDirectories: true)
        try "x".write(to: ghostDir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)

        do {
            _ = try await client.deleteSession(projectId: pid, sessionId: "ghost")
            XCTFail("会话不存在应抛 404")
        } catch SidecarError.httpError(let status, let detail) {
            XCTAssertEqual(status, 404)
            XCTAssertEqual(detail, "会话不存在")
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: ghostDir.appendingPathComponent("f.txt").path),
            "404 时不得删任何附件文件（app.py L748-750 顺序语义）")
    }

    /// 纯文件附件目录：文件清空后目录本身也 rmdir；不存在的目录 → 0 不报错。
    func testDeleteSessionAttachmentsSemantics() throws {
        let pid = try makeProject()
        // 不存在 → 0
        XCTAssertEqual(kernel.database.deleteSessionAttachments(projectId: pid, sessionId: "nope"), 0)
        // 纯文件 → 计数 + 目录清空后 rmdir
        let dir = attachmentsDir(pid, "s1")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "a".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: dir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(kernel.database.deleteSessionAttachments(projectId: pid, sessionId: "s1"), 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path),
                       "目录清空后 rmdir（store.py L732-735）")
    }
}
