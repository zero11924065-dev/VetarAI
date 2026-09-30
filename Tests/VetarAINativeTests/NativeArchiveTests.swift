//
//  NativeArchiveTests.swift
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

//  逐条对照 subagent/sidecar/agent_engine/loop.py L63-150 archive_work_unit
//  （⛔ 只读行为规格源）与 subagent/sidecar/test_checkpoint093.py::test_d_archive_work_unit：
//    · A 组：归档开关语义——toolsSpec 仅 withArchive=true 才附加 archive_work_unit
//      （关闭零开销；必填 title/summary）——Python A6a/A6b/A6c
//    · B 组：routeArchive 前置校验（缺 title / 未开启开关 / 执行器未装配）
//    · C 组：执行器参数校验（空 project/session、空 title、空会话）
//    · D 组：全真归档流（Python D1-D15 逐条）——首条用户消息保留 / 归档 6 条 /
//      防滥用拒绝 / 归档点自追踪二次归档 / 知识条目正文摘要 / source 合法 /
//      category 工作单元归档 / 拉模式闭环可搜回
//    · E 组：候选过滤（空内容不进仓库；恰好 4 条放行；3 条拒绝）+ 常量守护
//
//  隔离纪律：mktemp 全真 SQLite/文件（NativeKernel 指向临时 dataRoot，空 modelDir
//  令嵌入静默降级）；不起网络/模型；不触真实数据目录。
//

import XCTest
@testable import VetarAINative

final class NativeArchiveTests: XCTestCase {

    private var tmp: URL!
    private var kernel: NativeKernel!
    private var executor: NativeWorkUnitArchiveExecutor!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("p2w4c_archive_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let emptyModels = tmp.appendingPathComponent("empty-models", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyModels, withIntermediateDirectories: true)
        kernel = NativeKernel(dataRoot: tmp, modelDir: emptyModels)
        executor = NativeWorkUnitArchiveExecutor(database: kernel.database,
                                                 knowledge: kernel.knowledge)
    }

    override func tearDown() {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
        executor = nil; kernel = nil
        super.tearDown()
    }

    // MARK: 工具

    /// 建项目 + Agent + 会话，返回 (pid, aid, sid)。
    private func makeSession() throws -> (String, String, String) {
        let wd = tmp.appendingPathComponent("case-\(UUID().uuidString.prefix(6))", isDirectory: true)
        let pid = try kernel.database.createProject(name: "测试案件", workingDir: wd.path)
        let aid = try kernel.database.addAgentConfig(projectId: pid, name: "主Agent", type: "main",
                                                     role: "律师助理", modelName: "qwen3.8")
        let sid = try kernel.database.createSession(projectId: pid, agentId: aid, title: "会话1")
        return (pid, aid, sid)
    }

    private func save(_ pid: String, _ sid: String, _ aid: String,
                      _ role: String, _ content: String) throws {
        try kernel.database.saveMessage(projectId: pid, sessionId: sid, agentId: aid,
                                        role: role, content: content)
    }

    @discardableResult
    private func errString(_ r: [String: JSONValue],
                           file: StaticString = #filePath, line: UInt = #line) -> String {
        XCTAssertEqual(r["ok"], .bool(false), "应为失败：\(r)", file: file, line: line)
        guard case .string(let s)? = r["error"] else {
            XCTFail("缺 error 字段：\(r)", file: file, line: line); return ""
        }
        return s
    }

    // ════════════════════════ A 组：归档开关语义（toolsSpec）════════════════════════

    /// A1：关闭开关不暴露 archive_work_unit（Python A6a：零开销）；read_skill 两态均含。
    func testA1_archiveToolHiddenWhenSwitchOff() {
        let names = NativeAgentLoop.toolsSpec(withArchive: false).compactMap {
            $0.object?["function"]?.object?["name"]?.string
        }
        XCTAssertFalse(names.contains("archive_work_unit"), "\(names)")
        XCTAssertTrue(names.contains("read_skill"), "read_skill 两态均含（loop.py L188）")
    }

    /// A2：开启开关暴露且必填 title/summary（Python A6b/A6c）。
    func testA2_archiveToolExposedWhenSwitchOn() throws {
        let spec = NativeAgentLoop.toolsSpec(withArchive: true)
        let tool = spec.first {
            $0.object?["function"]?.object?["name"]?.string == "archive_work_unit"
        }
        let fn = try XCTUnwrap(tool?.object?["function"]?.object, "开启后应含 archive_work_unit")
        let required = fn["parameters"]?.object?["required"]?.array?
            .compactMap { $0.string } ?? []
        XCTAssertEqual(Set(required), ["title", "summary"], "必填 title/summary")
    }

    // ════════════════════════ B 组：routeArchive 前置校验 ════════════════════════

    /// B1：缺 title → 拒绝并说明（loop.py L1780-1781）。
    func testB1_routeRejectsEmptyTitle() throws {
        let ctx = NativeArchiveContext(projectId: "p", sessionId: "s", archiver: executor)
        let r = NativeAgentLoop.routeArchive(args: ["title": .string("  "),
                                                    "summary": .string("x")], ctx: ctx)
        XCTAssertTrue(errString(r).contains("archive_work_unit 需要 title 参数"))
    }

    /// B2：归档开关未开启（ctx nil）→ 如实告知需开开关（L1782-1785）。
    func testB2_routeRejectsWhenSwitchOff() throws {
        let r = NativeAgentLoop.routeArchive(args: ["title": .string("T"),
                                                    "summary": .string("S")], ctx: nil)
        let e = errString(r)
        XCTAssertTrue(e.contains("未开启「单元归档」"), e)
        XCTAssertTrue(e.contains("开启该开关"), e)
    }

    /// B3：ctx 已开但执行器未装配 → 如实报错（不静默吞）。
    func testB3_routeRejectsWhenArchiverMissing() throws {
        let ctx = NativeArchiveContext(projectId: "p", sessionId: "s", archiver: nil)
        let r = NativeAgentLoop.routeArchive(args: ["title": .string("T"),
                                                    "summary": .string("S")], ctx: ctx)
        XCTAssertTrue(errString(r).contains("未装配"))
    }

    /// B4：路由直通执行器（scope 缺省 project；title/summary 透传去空白）。
    func testB4_routePassesThroughToExecutor() throws {
        let (pid, aid, sid) = try makeSession()
        try save(pid, sid, aid, "user", "总指令")
        for i in 0..<4 { try save(pid, sid, aid, "assistant", "步骤\(i)") }
        let ctx = NativeArchiveContext(projectId: pid, sessionId: sid, archiver: executor)
        let r = NativeAgentLoop.routeArchive(
            args: ["title": .string("  《案件A》  "), "summary": .string(" 完成 ")], ctx: ctx)
        XCTAssertEqual(r["ok"], .bool(true), "\(r)")
        XCTAssertEqual(r["title"], .string("《案件A》"), "title 应 strip 后透传")
        XCTAssertEqual(r["archived"], .int(4))
    }

    // ════════════════════════ C 组：执行器参数校验 ════════════════════════

    /// C1：空 project_id / session_id → 拒绝（loop.py L86-87；Python D14）。
    func testC1_emptyIdsRejected() {
        let r = executor.archiveWorkUnit(projectId: "", sessionId: "s",
                                         title: "T", summary: "S", scope: "project")
        XCTAssertTrue(errString(r).contains("缺少 project_id / session_id"))
        let r2 = executor.archiveWorkUnit(projectId: "p", sessionId: "",
                                          title: "T", summary: "S", scope: "project")
        XCTAssertTrue(errString(r2).contains("缺少 project_id / session_id"))
    }

    /// C2：空 title → 拒绝（L88-91；Python D13）。
    func testC2_emptyTitleRejected() {
        let r = executor.archiveWorkUnit(projectId: "p", sessionId: "s",
                                         title: "  ", summary: "x", scope: "project")
        XCTAssertTrue(errString(r).contains("需要 title"))
    }

    /// C3：会话无消息 → 「无需归档」（L93-95）。
    func testC3_emptySessionRejected() throws {
        let (pid, _, sid) = try makeSession()
        let r = executor.archiveWorkUnit(projectId: pid, sessionId: sid,
                                         title: "T", summary: "S", scope: "project")
        XCTAssertTrue(errString(r).contains("会话中还没有任何消息，无需归档"))
    }

    // ════════════════════════ D 组：全真归档流（Python D1-D15）════════════════════════

    /// D1-D15：首条保留 / 归档计数 / 防滥用 / 归档点自追踪 / 条目形态 / 可搜回。
    func testD_fullArchiveFlow() throws {
        let (pid, aid, sid) = try makeSession()
        try save(pid, sid, aid, "user", "这是任务总指令：处理3个案件")
        for i in 0..<6 {
            try save(pid, sid, aid, i % 2 == 0 ? "user" : "assistant", "案件A 步骤\(i) 内容")
        }

        let r = executor.archiveWorkUnit(projectId: pid, sessionId: sid,
                                         title: "《案件A》案情分析",
                                         summary: "已完成案情分析，产出 a.docx", scope: "project")
        // D1 归档成功
        XCTAssertEqual(r["ok"], .bool(true), "\(r)")
        // D2 首条用户消息被保留（任务总指令永不归档）
        XCTAssertEqual(r["kept_first_user_message"], .bool(true))
        // D3 归档条数=6（7条减去保留的首条）
        XCTAssertEqual(r["archived"], .int(6), "\(r)")
        XCTAssertNotNil(r["entry_id"]?.string)
        XCTAssertNotNil(r["file_path"]?.string)
        XCTAssertEqual(r["note"]?.string,
                       "本单元对话已移入知识仓库并脱离上下文；需要时可用 search_knowledge 搜回。")

        let after = try kernel.database.loadMessages(projectId: pid, sessionId: sid)
        XCTAssertEqual(after.count, 7)
        // D4 首条用户消息未标记 archived（Agent 仍能看到总任务）
        let first = after.first { $0.role == "user" }
        XCTAssertEqual(first?.content, "这是任务总指令：处理3个案件")
        XCTAssertEqual(first?.archived, false)
        // D5 其余消息已归档（脱离上下文）
        XCTAssertTrue(after.dropFirst().allSatisfy { $0.archived },
                      "\(after.map { $0.archived })")

        // D6 防滥用：紧接着再归档 → 候选不足 ARCHIVE_MIN_MESSAGES → 拒绝
        let r2 = executor.archiveWorkUnit(projectId: pid, sessionId: sid,
                                          title: "《案件B》", summary: "x", scope: "project")
        let e2 = errString(r2)
        XCTAssertTrue(e2.contains("不足 4 条"), e2)
        XCTAssertTrue(e2.contains("距上次归档点只有 0 条"), e2)

        // D7 归档点自追踪：新增 5 条后二次归档只归档新增
        for i in 0..<5 {
            try save(pid, sid, aid, i % 2 == 0 ? "assistant" : "user", "案件B 步骤\(i)")
        }
        let r3 = executor.archiveWorkUnit(projectId: pid, sessionId: sid,
                                          title: "《案件B》证据", summary: "已完成证据汇编",
                                          scope: "project")
        XCTAssertEqual(r3["ok"], .bool(true), "\(r3)")
        XCTAssertEqual(r3["archived"], .int(5), "\(r3)")

        // D8/D9 知识仓库生成 2 条工作单元条目且标题正确
        kernel.knowledge.pruneMissing()
        let entries = kernel.knowledge.listEntries(scope: "project", projectId: pid)
        let titles = entries.map { $0.title }
        XCTAssertEqual(entries.count, 2, "\(titles)")
        XCTAssertTrue(titles.contains("《案件A》案情分析"), "\(titles)")
        XCTAssertTrue(titles.contains("《案件B》证据"), "\(titles)")

        // D10 条目正文含单元摘要
        let bodyA = kernel.knowledge.getEntry(entries.first!.id)?.body ?? ""
        XCTAssertTrue(bodyA.contains("单元摘要"), bodyA)
        XCTAssertTrue(bodyA.contains("已完成"), bodyA)

        // D11 source 合法（CHECK 约束 chat/manual）
        XCTAssertTrue(Set(entries.map { $0.source }).isSubset(of: ["chat", "manual"]),
                      "\(entries.map { $0.source })")
        // D12 category 标记为工作单元归档（区分手动转移）
        XCTAssertTrue(entries.allSatisfy { $0.category == "工作单元归档" },
                      "\(entries.map { $0.category })")

        // D15 拉模式闭环：归档内容可被 search_knowledge 搜回
        let hits = kernel.knowledge.hybridSearch("案情分析", scope: "project", projectId: pid,
                                                 limit: 5)
        XCTAssertFalse(hits.isEmpty, "归档内容应可被搜回（拉模式闭环）")
    }

    /// D13：正文组装与 0.3.0 手动转移同构——**角色**：内容、\\n\\n 分隔、摘要居首。
    func testD13_bodyAssemblyShape() throws {
        let (pid, aid, sid) = try makeSession()
        try save(pid, sid, aid, "user", "总指令")
        try save(pid, sid, aid, "user", "用户补充")
        try save(pid, sid, aid, "assistant", "助手回答")
        try save(pid, sid, aid, "user", "再次追问")
        try save(pid, sid, aid, "assistant", "最终产出说明")
        let r = executor.archiveWorkUnit(projectId: pid, sessionId: sid,
                                         title: "单元X", summary: "产出 x.md", scope: "project")
        XCTAssertEqual(r["ok"], .bool(true), "\(r)")
        let entryId = try XCTUnwrap(r["entry_id"]?.string)
        let body = try XCTUnwrap(kernel.knowledge.getEntry(entryId)?.body)
        let expected = """
        **单元摘要**：产出 x.md

        **user**：用户补充

        **assistant**：助手回答

        **user**：再次追问

        **assistant**：最终产出说明
        """
        XCTAssertEqual(body, expected)
    }

    /// D14：scope=global 时条目不挂项目（project_id=None 语义）。
    func testD14_globalScopeEntry() throws {
        let (pid, aid, sid) = try makeSession()
        try save(pid, sid, aid, "user", "总指令")
        for i in 0..<4 { try save(pid, sid, aid, "assistant", "步骤\(i)") }
        let r = executor.archiveWorkUnit(projectId: pid, sessionId: sid,
                                         title: "全局单元", summary: "s", scope: "global")
        XCTAssertEqual(r["ok"], .bool(true), "\(r)")
        let entryId = try XCTUnwrap(r["entry_id"]?.string)
        let entry = try XCTUnwrap(kernel.knowledge.getEntry(entryId))
        XCTAssertEqual(entry.scope, "global")
        XCTAssertEqual(entry.projectId, "")
    }

    // ════════════════════════ E 组：候选过滤与常量 ════════════════════════

    /// E1：空内容消息不进仓库（L113-114）；恰好 4 条候选放行。
    func testE1_blankContentSkippedExactFourAllowed() throws {
        let (pid, aid, sid) = try makeSession()
        try save(pid, sid, aid, "user", "总指令")
        try save(pid, sid, aid, "assistant", "步骤1")
        try save(pid, sid, aid, "assistant", "   ")   // 空内容（如仅工具步骤的气泡）不进仓库
        try save(pid, sid, aid, "assistant", "步骤2")
        try save(pid, sid, aid, "user", "步骤3")
        try save(pid, sid, aid, "assistant", "步骤4")
        let r = executor.archiveWorkUnit(projectId: pid, sessionId: sid,
                                         title: "T", summary: "S", scope: "project")
        XCTAssertEqual(r["ok"], .bool(true), "\(r)")
        XCTAssertEqual(r["archived"], .int(4), "空内容不计入候选")
        // 空内容消息不被标记归档
        let rows = try kernel.database.loadMessages(projectId: pid, sessionId: sid)
        let blank = rows.first { ($0.content ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        XCTAssertEqual(blank?.archived, false)
    }

    /// E2：3 条候选 < ARCHIVE_MIN_MESSAGES → 拒绝（防滥用切碎上下文）。
    func testE2_threeCandidatesRejected() throws {
        let (pid, aid, sid) = try makeSession()
        try save(pid, sid, aid, "user", "总指令")
        for i in 0..<3 { try save(pid, sid, aid, "assistant", "步骤\(i)") }
        let r = executor.archiveWorkUnit(projectId: pid, sessionId: sid,
                                         title: "T", summary: "S", scope: "project")
        let e = errString(r)
        XCTAssertTrue(e.contains("距上次归档点只有 3 条消息（不足 4 条）"), e)
        XCTAssertTrue(e.contains("已拒绝归档"), e)
    }

    /// E3：ARCHIVE_MIN_MESSAGES = 4 常量守护（loop.py L64）。
    func testE3_archiveMinMessagesConstant() {
        XCTAssertEqual(NativeWorkUnitArchiveExecutor.archiveMinMessages, 4)
    }
}
