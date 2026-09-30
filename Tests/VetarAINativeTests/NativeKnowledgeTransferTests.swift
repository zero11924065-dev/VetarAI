//
//  NativeKnowledgeTransferTests.swift
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

//  逐条对照 app.py L2384-2417（⛔ 只读行为规格源）：
//    · scope 白名单 400「scope 必须是 project 或 global」
//    · 两阶段冲突语义（查虫K-2）：已归档消息跳过不参与转移；全跳过 →
//      404「未找到指定消息（或消息已在知识仓库中）」
//    · 正文 **role**：content 拼接（空白内容跳过；全文空 → 422「勾选的消息无文本内容」）
//    · 标题回落：用户指定（strip）> 首条前 20 字 > 「未命名」
//    · add_entry 成功 → .md 落盘 + 索引行（project scope 带 project_id；global 不带）；
//      嵌入可用即触发、不可用静默（P2-W1 CoreML 内生化口径，不阻塞）
//    · archive_messages 按请求**全量** id 标记（rowcount 含已归档幂等重标）
//    · 响应 {ok, title, archived}；端点无 SSE notify
//
//  隔离纪律：mktemp 数据根；历史上 fallback 未实现 ChatPanelClient，HTTP 回落即显形。
//

import XCTest
@testable import VetarAINative

final class NativeKnowledgeTransferTests: XCTestCase {

    private var base: URL!
    private var kernel: NativeKernel!
    private var client: NativeSidecarClient!

    override func setUpWithError() throws {
        try super.setUpWithError()
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3w1b_transfer_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        kernel = NativeKernel(dataRoot: base)
        client = NativeSidecarClient(kernel: kernel)
        NativeAppEvents.clearAll()
    }

    override func tearDownWithError() throws {
        NativeAppEvents.clearAll()
        client = nil
        kernel = nil
        try? FileManager.default.removeItem(at: base)
        try super.tearDownWithError()
    }

    private var pid: String!
    private var aid: String!
    private var sid: String!

    /// 建项目/Agent/会话；wd 为可写工作目录（project scope 条目落在其 knowledge/ 下）。
    private func seedSession() throws {
        let wd = base.appendingPathComponent("wd")
        try FileManager.default.createDirectory(at: wd, withIntermediateDirectories: true)
        pid = try kernel.database.createProject(name: "p", workingDir: wd.path)
        aid = try kernel.database.addAgentConfig(projectId: pid, name: "a", type: "main")
        sid = try kernel.database.createSession(projectId: pid, agentId: aid, title: "s")
    }

    @discardableResult
    private func say(_ role: String, _ content: String) throws -> Int {
        try kernel.database.saveMessage(projectId: pid, sessionId: sid, agentId: aid,
                                        role: role, content: content)
        return try kernel.database.loadMessages(projectId: pid, sessionId: sid).last.map { Int($0.id) }!
    }

    private func req(ids: [Int], scope: String = "project", title: String? = nil,
                     category: String = "", keywords: [String] = []) -> KnowledgeTransferRequest {
        KnowledgeTransferRequest(projectId: pid, sessionId: sid, messageIds: ids,
                                 scope: scope, title: title, category: category,
                                 keywords: keywords)
    }

    private func assertHTTPError(_ status: Int, _ detail: String,
                                 _ work: () async throws -> some Any,
                                 file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await work()
            XCTFail("应抛 httpError(\(status))：\(detail)", file: file, line: line)
        } catch SidecarError.httpError(let s, let d) {
            XCTAssertEqual(s, status, file: file, line: line)
            XCTAssertEqual(d, detail, file: file, line: line)
        } catch {
            XCTFail("错误类型不符：\(error)", file: file, line: line)
        }
    }

    // MARK: 校验链（400/404/422）

    /// scope 白名单 400 逐字；无匹配 id 404 逐字；勾选全空白内容 422 逐字。
    func testValidationChain() async throws {
        try seedSession()
        let m1 = try say("user", "你好")
        await assertHTTPError(400, "scope 必须是 project 或 global") {
            try await client.transferToWarehouse(req(ids: [m1], scope: "bogus"))
        }
        await assertHTTPError(404, "未找到指定消息（或消息已在知识仓库中）") {
            try await client.transferToWarehouse(req(ids: [99999]))
        }
        let blank = try say("assistant", "   \n  ")
        await assertHTTPError(422, "勾选的消息无文本内容") {
            try await client.transferToWarehouse(req(ids: [blank]))
        }
    }

    // MARK: 两阶段冲突语义（查虫K-2）

    /// 已归档消息跳过：正文只含未归档勾选；archive 按全量 id 标记（rowcount=3 含
    /// 已归档行的幂等重标）；全部已归档 → 404。
    func testTwoPhaseArchivedSkip() async throws {
        try seedSession()
        let m1 = try say("user", "第一条问题")
        let m2 = try say("assistant", "第一条回答")
        let m3 = try say("user", "第二条问题")
        // m2 预归档（模拟上一轮已转移）
        _ = try kernel.database.archiveMessages(projectId: pid, messageIds: [Int64(m2)])

        let r = try await client.transferToWarehouse(req(ids: [m1, m2, m3], title: "单元A"))
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.title, "单元A")
        XCTAssertEqual(r.archived, 3, "按请求全量 id 标记，含已归档幂等重标")

        // 正文只含未归档的 m1/m3（**role**：content；\n\n 分隔）
        // （list_entries 列表形态不带 body——get_entry 取正文，对齐端点差异）
        let entries = kernel.knowledge.listEntries(scope: "project", projectId: pid)
        XCTAssertEqual(entries.count, 1)
        let body = kernel.knowledge.getEntry(entries[0].id)?.body ?? ""
        XCTAssertTrue(body.contains("**user**：第一条问题"))
        XCTAssertTrue(body.contains("**user**：第二条问题"))
        XCTAssertFalse(body.contains("第一条回答"), "已归档消息不参与转移（查虫K-2）")
        XCTAssertEqual(body, "**user**：第一条问题\n\n**user**：第二条问题")

        // 全部已归档 → 404
        await assertHTTPError(404, "未找到指定消息（或消息已在知识仓库中）") {
            try await client.transferToWarehouse(req(ids: [m1, m2, m3]))
        }
    }

    // MARK: 标题回落

    /// 标题：用户指定（strip）> 首条前 20 字（按未 strip 原文截）> 「未命名」兜底。
    func testTitleFallback() async throws {
        try seedSession()
        let longContent = String(repeating: "字", count: 30)
        let m1 = try say("user", longContent)
        let r1 = try await client.transferToWarehouse(req(ids: [m1]))
        XCTAssertEqual(r1.title, String(repeating: "字", count: 20), "首条前 20 字")

        let m2 = try say("user", "另一条")
        let r2 = try await client.transferToWarehouse(req(ids: [m2], title: "  指定标题  "))
        XCTAssertEqual(r2.title, "指定标题", "Python (req.title or '').strip()")
    }

    // MARK: 落盘 + scope 归属 + 响应形态

    /// project scope：.md 落在项目知识目录、索引带 project_id、file_path 真实存在、
    /// category/keywords 落库；global scope：落 knowledge/global、project_id 空。
    func testEntryPersistenceAndScope() async throws {
        try seedSession()
        let m1 = try say("user", "项目条目内容")
        let r = try await client.transferToWarehouse(
            req(ids: [m1], title: "项目条", category: "笔记", keywords: ["k1", "k2"]))
        XCTAssertTrue(r.ok)

        let pEntries = kernel.knowledge.listEntries(scope: "project", projectId: pid)
        XCTAssertEqual(pEntries.count, 1)
        XCTAssertEqual(pEntries[0].title, "项目条")
        XCTAssertEqual(pEntries[0].category, "笔记")
        XCTAssertEqual(pEntries[0].keywords, ["k1", "k2"])
        XCTAssertEqual(pEntries[0].source, "chat")
        XCTAssertTrue(FileManager.default.fileExists(atPath: pEntries[0].filePath))
        XCTAssertTrue(pEntries[0].filePath.contains("/知识库/"),
                      "项目知识目录（working_dir/知识库，warehouse.py PROJECT_DIR_NAME）")

        let m2 = try say("assistant", "全局条目内容")
        _ = try await client.transferToWarehouse(req(ids: [m2], scope: "global", title: "全局条"))
        let gEntries = kernel.knowledge.listEntries(scope: "global", projectId: nil)
        XCTAssertEqual(gEntries.count, 1)
        XCTAssertEqual(gEntries[0].projectId, "", "global scope → project_id None/空")
        XCTAssertTrue(gEntries[0].filePath.contains("knowledge/global"))
        // project 列表不混入 global 条目
        XCTAssertEqual(kernel.knowledge.listEntries(scope: "project", projectId: pid).count, 1)
    }

    // MARK: 消息归档标记

    /// 转移成功后消息 archived=1（loadMessages 读回），内容仍保留（占位显示口径）。
    func testMessagesArchivedAfterTransfer() async throws {
        try seedSession()
        let m1 = try say("user", "要归档")
        let m2 = try say("assistant", "不归档")
        let r = try await client.transferToWarehouse(req(ids: [m1], title: "t"))
        XCTAssertEqual(r.archived, 1)
        let msgs = try kernel.database.loadMessages(projectId: pid, sessionId: sid)
        XCTAssertTrue(msgs.first { Int($0.id) == m1 }!.archived)
        XCTAssertFalse(msgs.first { Int($0.id) == m2 }!.archived)
        XCTAssertEqual(msgs.first { Int($0.id) == m1 }!.content, "要归档",
                       "内容仍保留在库中（store.py docstring 口径）")
    }

    // MARK: 无 SSE notify（app.py 逐字：transfer 端点不调 _notify_change）

    func testTransferEmitsNoEvents() async throws {
        try seedSession()
        let m1 = try say("user", "hi")
        _ = try await client.transferToWarehouse(req(ids: [m1], title: "t"))
        XCTAssertEqual(NativeAppEvents.latestSeq(), 0, "transfer 端点不应产生资源变更事件")
    }
}
