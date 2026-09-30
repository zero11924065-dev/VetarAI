//
//  NativeSessionOpsTests.swift
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
//    · POST compact（app.py L595-605 + compactor.py L76-142）：keep_recent 语义 /
//      归档文件命名（compact-<sid>-<ts>.md）/ 摘要插 system 消息 / compact_log 行 /
//      失败 422 + 消息原样保留
//    · POST export（app.py L608-633 + compactor.py L145-172 + exporter.py L71-131）：
//      dir 白名单 400 文案 / 统一目录解析（config → 项目工作目录 → 数据根兜底）/
//      文件名两种口径（全 sid vs 前 8 位）/ 工具步骤摘要段 / 归档占位 / 404
//    · POST summarize（app.py L641-693）：8000 字符截断 / archived+system+空白跳过 /
//      model 空串回落 config default_model / 404 / 422 / 502 / 500 /
//      save_session_summary（MD + session_summaries 行）
//    · compact_log 读端早已原生（SettingsPanelClient.compactLog，P2-W0），本文件
//      仅在压缩后顺带锚定；ChatViewModel 无 compact_log 调用点（面板不读）。
//
//  LLM 路径全走 stub connector（NativeChatConnector 注入缝）；mktemp 数据根隔离。
//

import XCTest
@testable import VetarAINative

// MARK: - 夹具：脚本化 chat 的假 connector

private final class StubChatConn: NativeChatConnector, @unchecked Sendable {
    var chatResult: Result<String, Error> = .success("摘要/总结输出")
    private(set) var chatCalls: [(model: String, messages: [[String: JSONValue]])] = []

    func chat(model: String, messages: [[String: JSONValue]]) async throws -> String {
        chatCalls.append((model, messages))
        return try chatResult.get()
    }

    func chatStream(model: String, messages: [[String: JSONValue]],
                    tools: [JSONValue]?, images: [String]?)
        -> AsyncThrowingStream<NativeChatStreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    var lastPrompt: String { chatCalls.last?.messages.first?["content"]?.string ?? "" }
    var lastModel: String? { chatCalls.last?.model }
}

final class NativeSessionOpsTests: XCTestCase {

    private var base: URL!
    private var kernel: NativeKernel!
    private var stub: StubChatConn!
    private var client: NativeSidecarClient!

    override func setUpWithError() throws {
        try super.setUpWithError()
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3w1a_ops_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        kernel = NativeKernel(dataRoot: base)
        stub = StubChatConn()
        client = NativeSidecarClient(kernel: kernel)
        NativeAppEvents.clearAll()
    }

    override func tearDownWithError() throws {
        NativeAppEvents.clearAll()
        client = nil
        stub = nil
        kernel = nil
        try? FileManager.default.removeItem(at: base)
        try super.tearDownWithError()
    }

    private var cfg: [String: JSONValue] {
        (try? kernel.config.getConfig()) ?? NativeConfigStore.defaultConfig
    }

    private func makeSession(title: String = "对照会话")
        throws -> (pid: String, aid: String, sid: String, wd: URL) {
        let wd = base.appendingPathComponent("wd")
        try FileManager.default.createDirectory(at: wd, withIntermediateDirectories: true)
        let pid = try kernel.database.createProject(name: "p", workingDir: wd.path)
        let aid = try kernel.database.addAgentConfig(projectId: pid, name: "主", type: "main")
        let sid = try kernel.database.createSession(projectId: pid, agentId: aid, title: title)
        return (pid, aid, sid, wd)
    }

    private func seedMessages(_ pid: String, _ aid: String, _ sid: String,
                              count: Int, prefix: String = "消息") throws {
        for i in 1...count {
            try kernel.database.saveMessage(projectId: pid, sessionId: sid, agentId: aid,
                                            role: i % 2 == 0 ? "assistant" : "user",
                                            content: "\(prefix)\(i)")
        }
    }

    // ══ compact（app.py L595-605；复用 NativeCompactor）══

    /// keep_recent 缺省 10：15 条 → 归档 5 + 摘要 system 消息 + compact_log 行；
    /// 归档文件 compact-<sid>-<ts>.md 落 config compact_archive_dir。
    func testCompactHappyPath() async throws {
        let (pid, aid, sid, _) = try makeSession()
        let archiveDir = base.appendingPathComponent("compressed")
        _ = try kernel.config.reloadConfig(patch: ["compact_archive_dir": .string(archiveDir.path)])
        try seedMessages(pid, aid, sid, count: 15)

        // 面板端点固定 connector=kernel.chatConnector——直接打 NativeCompactor 同款注入缝
        // （端点层已由 compact_auto 双跑锚定；此处经 client 走 422 映射一并覆盖）
        let r = await NativeCompactor.compactSession(
            db: kernel.database, connector: stub, config: { self.cfg },
            projectId: pid, sessionId: sid)
        XCTAssertTrue(r.ok, r.error ?? "")
        XCTAssertEqual(r.archivedCount, 5, "15 - keep_recent 10 = 归档 5 条")

        let after = try kernel.database.loadMessages(projectId: pid, sessionId: sid)
        XCTAssertEqual(after.count, 11, "保留 10 + 摘要 system 1 条")
        XCTAssertEqual(after[0].content, "消息6", "保留最近 10 条（消息6…15）")
        XCTAssertEqual(after[9].content, "消息15")
        XCTAssertEqual(after[10].role, "system", "摘要消息插在最后（id 最大，ORDER BY id）")
        XCTAssertEqual(after[10].content, "【历史摘要】摘要/总结输出")
        XCTAssertEqual(stub.lastModel, "qwen3.8", "端点 model 缺省 qwen3.8")
        XCTAssertTrue(stub.lastPrompt.contains("[user] 消息1"), "摘要输入 = 待压缩区逐条 [role] content")

        // 归档文件：compact-<sid>-<yyyyMMdd-HHmmss>.md
        let files = try FileManager.default.contentsOfDirectory(atPath: archiveDir.path)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].hasPrefix("compact-\(sid)-"), "归档命名逐字")
        XCTAssertTrue(files[0].hasSuffix(".md"))
        let md = try String(contentsOf: archiveDir.appendingPathComponent(files[0]), encoding: .utf8)
        XCTAssertTrue(md.contains("# 历史消息归档"))
        XCTAssertTrue(md.contains("> 会话: \(sid)"))
        XCTAssertTrue(md.contains("**user**"), "归档正文含消息")
        XCTAssertTrue(md.contains("消息1") && md.contains("消息5"))
        XCTAssertFalse(md.contains("消息6"), "待压缩区以外不进归档")

        // compact_log 行（读端 = 已原生 SettingsPanelClient.compactLog）
        let logs = try await client.compactLog(projectId: pid, sessionId: sid)
        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(logs[0].archivePath, archiveDir.appendingPathComponent(files[0]).path)
        XCTAssertNil(logs[0].error)
        XCTAssertNotNil(logs[0].beforeTokens)
    }

    /// 消息数 ≤ keep_recent → 422「消息数 N ≤ keep_recent K，无需压缩」（端点映射）。
    func testCompactTooFewMessages422() async throws {
        let (pid, aid, sid, _) = try makeSession()
        try seedMessages(pid, aid, sid, count: 3)
        do {
            try await client.compactSession(projectId: pid, sessionId: sid)
            XCTFail("应抛 422")
        } catch SidecarError.httpError(let status, let detail) {
            XCTAssertEqual(status, 422)
            XCTAssertEqual(detail, "消息数 3 ≤ keep_recent 10，无需压缩")
        }
    }

    /// 摘要失败 → result.ok=false「摘要失败: …」（端点映射 422，已由
    /// testCompactTooFewMessages422 锚定 client 包装）；消息原样保留 + compact_log 记错误行。
    func testCompactSummaryFailureKeepsMessages() async throws {
        let (pid, aid, sid, _) = try makeSession()
        _ = try kernel.config.reloadConfig(patch: [
            "compact_archive_dir": .string(base.appendingPathComponent("compressed").path)])
        try seedMessages(pid, aid, sid, count: 12)
        stub.chatResult = .failure(NativeRoundtableError("模型超时"))
        let r = await NativeCompactor.compactSession(
            db: kernel.database, connector: stub, config: { self.cfg },
            projectId: pid, sessionId: sid)
        XCTAssertFalse(r.ok)
        XCTAssertTrue((r.error ?? "").hasPrefix("摘要失败: "), r.error ?? "")
        XCTAssertEqual(try kernel.database.loadMessages(projectId: pid, sessionId: sid).count, 12,
                       "摘要失败→中止，消息原样保留")
        let logs = try kernel.database.loadCompactLog(projectId: pid, sessionId: sid)
        XCTAssertEqual(logs.count, 1)
        XCTAssertNotNil(logs[0].error, "失败也写 compact_log")
    }

    /// keep_recent 语义：config compact_keep_recent=3，5 条 → 归档 2。
    func testCompactKeepRecentFromConfig() async throws {
        let (pid, aid, sid, _) = try makeSession()
        _ = try kernel.config.reloadConfig(patch: [
            "compact_archive_dir": .string(base.appendingPathComponent("compressed").path),
            "compact_keep_recent": .int(3)])
        try seedMessages(pid, aid, sid, count: 5)
        let r = await NativeCompactor.compactSession(
            db: kernel.database, connector: stub, config: { self.cfg },
            projectId: pid, sessionId: sid)
        XCTAssertTrue(r.ok, r.error ?? "")
        XCTAssertEqual(r.archivedCount, 2, "5 - keep_recent 3 = 归档 2 条")
        let after = try kernel.database.loadMessages(projectId: pid, sessionId: sid)
        XCTAssertEqual(after.count, 4, "保留 3 + 摘要 1")
        XCTAssertEqual(after[0].content, "消息3", "keep_recent=3 → 归档消息1-2")
        XCTAssertEqual(after[3].role, "system")
    }

    // ══ export：统一目录分支（exporter.py L71-131）══

    /// 缺省目录 = 项目工作目录/sessions/；文件名 session-<sid前8>-<ts>.md；
    /// 工具步骤摘要段 + 归档占位（不带出原文）。
    func testExportUnifiedToProjectWorkingDir() async throws {
        let (pid, aid, sid, wd) = try makeSession(title: "出货复盘")
        try kernel.database.saveMessage(projectId: pid, sessionId: sid, agentId: aid,
                                        role: "user", content: "开始")
        try kernel.database.saveMessage(
            projectId: pid, sessionId: sid, agentId: aid, role: "assistant", content: "读完了",
            toolSteps: .array([
                .object(["name": .string("read_file"), "ok": .bool(true),
                         "summary": .string("读了 3 行")]),
                .object(["name": .string("write_file"), "ok": .bool(false),
                         "summary": .string("写入被拒")]),
            ]))
        try kernel.database.saveMessage(projectId: pid, sessionId: sid, agentId: aid,
                                        role: "user", content: "机密原文")
        // 归档最后一条（TS-120 占位口径）
        let rows = try kernel.database.loadMessages(projectId: pid, sessionId: sid)
        _ = try kernel.database.archiveMessages(projectId: pid, messageIds: [rows[2].id])

        let r = try await client.exportSession(projectId: pid, agentId: aid,
                                               sessionId: sid, dir: nil)
        XCTAssertTrue(r.ok)
        XCTAssertTrue(r.name.hasPrefix("session-\(sid.prefix(8))-"), "统一目录文件名用 sid 前 8 位")
        XCTAssertTrue(r.name.hasSuffix(".md"))
        XCTAssertEqual(r.path,
                       NativeSessionOps.pyResolve(wd.appendingPathComponent("sessions/\(r.name)").path),
                       "default_export_dir 空 → 项目工作目录/sessions/（建项目时 working_dir 已 resolve）")
        let md = try String(contentsOfFile: r.path, encoding: .utf8)
        XCTAssertTrue(md.contains("# 会话导出"))
        XCTAssertTrue(md.contains("> 会话: 出货复盘"), "title 命中（agent_id 查询分支）")
        XCTAssertTrue(md.contains("- 🔧 [read_file] 读了 3 行（成功）"))
        XCTAssertTrue(md.contains("- 🔧 [write_file] 写入被拒（失败）"),
                      "ok 缺失/false → （失败）")
        XCTAssertTrue(md.contains("（此内容已移入知识仓库）"), "归档消息占位")
        XCTAssertFalse(md.contains("机密原文"), "归档消息不带出原文")
    }

    /// config default_export_dir 优先（mkdir + 可写探测通过）。
    func testExportUnifiedPrefersConfiguredDir() async throws {
        let (pid, aid, sid, _) = try makeSession()
        let expDir = base.appendingPathComponent("我的导出")
        _ = try kernel.config.reloadConfig(patch: ["default_export_dir": .string(expDir.path)])
        try seedMessages(pid, aid, sid, count: 1)
        let r = try await client.exportSession(projectId: pid, agentId: aid,
                                               sessionId: sid, dir: nil)
        XCTAssertEqual(r.path, expDir.appendingPathComponent("sessions/\(r.name)").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: r.path))
        // 可写探测不留痕
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: expDir.appendingPathComponent(".subagent_export_probe").path))
    }

    /// 空会话 → 404「会话不存在或无消息」（ValueError → 404 口径）。
    func testExportUnifiedNoMessages404() async throws {
        let (pid, _, sid, _) = try makeSession()
        do {
            _ = try await client.exportSession(projectId: pid, agentId: "",
                                               sessionId: sid, dir: nil)
            XCTFail("应抛 404")
        } catch SidecarError.httpError(let status, let detail) {
            XCTAssertEqual(status, 404)
            XCTAssertEqual(detail, "会话不存在或无消息")
        }
    }

    // ══ export：dir 白名单分支（compactor.py L145-172）══

    /// 系统临时目录内 → 放行；文件名 session-<完整 sid>-<ts>.md；无工具步骤段。
    func testExportToDirInsideTmpAllowed() async throws {
        let (pid, aid, sid, _) = try makeSession()
        try seedMessages(pid, aid, sid, count: 2, prefix: "tmp消息")
        let dir = NSTemporaryDirectory() + "exp-\(UUID().uuidString)"
        let r = try await client.exportSession(projectId: pid, agentId: aid,
                                               sessionId: sid, dir: dir)
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.name, "", "dir 分支端点不回 name 键（app.py L627）")
        let fname = URL(fileURLWithPath: r.path).lastPathComponent
        XCTAssertTrue(fname.hasPrefix("session-\(sid)-"), "compactor 文件名用完整 sid")
        let md = try String(contentsOfFile: r.path, encoding: .utf8)
        XCTAssertTrue(md.hasPrefix("# 会话导出 \(sid)\n"))
        XCTAssertTrue(md.contains("tmp消息1"))
    }

    /// compact_archive_dir 内（含其子目录）→ 放行。
    func testExportToDirInsideArchiveDirAllowed() async throws {
        let (pid, aid, sid, _) = try makeSession()
        try seedMessages(pid, aid, sid, count: 1)
        let archive = base.appendingPathComponent("compressed")
        _ = try kernel.config.reloadConfig(patch: ["compact_archive_dir": .string(archive.path)])
        let sub = archive.appendingPathComponent("nested/deeper")
        let r = try await client.exportSession(projectId: pid, agentId: aid,
                                               sessionId: sid, dir: sub.path)
        XCTAssertTrue(r.ok, "白名单根的子目录放行（is_relative_to 口径）")
        XCTAssertTrue(r.path.hasPrefix(NativeSessionOps.pyResolve(archive.path)))
    }

    /// 白名单外 + 路径穿越 → 400 文案逐字。
    func testExportToDirWhitelistRejects400() async throws {
        let (pid, aid, sid, _) = try makeSession()
        try seedMessages(pid, aid, sid, count: 1)
        _ = try kernel.config.reloadConfig(patch: [
            "compact_archive_dir": .string(base.appendingPathComponent("compressed").path)])
        let home = NSHomeDirectory()
        for bad in [home, "\(NSTemporaryDirectory())../\(UUID().uuidString)"] {
            do {
                _ = try await client.exportSession(projectId: pid, agentId: aid,
                                                   sessionId: sid, dir: bad)
                XCTFail("\(bad) 应被白名单拒绝")
            } catch SidecarError.httpError(let status, let detail) {
                XCTAssertEqual(status, 400)
                XCTAssertEqual(detail, "导出目录不在允许范围内（须在归档目录或系统临时目录内）: \(bad)")
            }
        }
    }

    // ══ summarize（app.py L641-693）══
    //
    //  LLM 路径全经 NativeSessionOps 注入缝打 stub（client 包装固定 kernel.chatConnector，
    //  不触真模型）；404/422 在 chat 调用之前抛出，走 client 包装一并锚定。

    /// 全链路：拼接（system/archived/空白跳过）→ chat → MD + DB 行；
    /// model 空串 → config default_model。
    func testSummarizeHappyPath() async throws {
        let (pid, aid, sid, _) = try makeSession()
        _ = try kernel.config.reloadConfig(patch: ["default_model": .string("cfg-model")])
        try kernel.database.saveMessage(projectId: pid, sessionId: sid, agentId: aid,
                                        role: "user", content: "问题一")
        try kernel.database.saveMessage(projectId: pid, sessionId: sid, agentId: aid,
                                        role: "assistant", content: "回答一")
        try kernel.database.saveMessage(projectId: pid, sessionId: sid, agentId: aid,
                                        role: "system", content: "系统提示不进总结")
        try kernel.database.saveMessage(projectId: pid, sessionId: sid, agentId: aid,
                                        role: "user", content: "   ")
        try kernel.database.saveMessage(projectId: pid, sessionId: sid, agentId: aid,
                                        role: "user", content: "归档原文")
        let rows = try kernel.database.loadMessages(projectId: pid, sessionId: sid)
        _ = try kernel.database.archiveMessages(projectId: pid, messageIds: [rows[4].id])
        stub.chatResult = .success("  总结：一切顺利。\n")

        let r = try await NativeSessionOps.summarizeSession(
            db: kernel.database, connector: stub, config: cfg,
            projectId: pid, sessionId: sid, agentId: aid, model: "")
        XCTAssertEqual(r.summary, "总结：一切顺利。", "首尾空白 strip")
        XCTAssertEqual(stub.lastModel, "cfg-model", "model 空串 → config default_model")
        XCTAssertTrue(stub.lastPrompt.hasPrefix(
            "请为以下对话写一份简明的中文总结（300 字以内）："), "prompt 逐字前缀")
        XCTAssertTrue(stub.lastPrompt.contains("\n\n---\nuser: 问题一\nassistant: 回答一"),
                      "拼接 seg = \"role: content\"")
        XCTAssertFalse(stub.lastPrompt.contains("系统提示不进总结"))
        XCTAssertFalse(stub.lastPrompt.contains("归档原文"), "archived 不参与总结")

        // MD 落盘：<pid>/work/summaries/<aid8>_<sid8>_<ts>.md
        let fname = URL(fileURLWithPath: r.savedFile).lastPathComponent
        XCTAssertTrue(fname.hasPrefix("\(aid.prefix(8))_\(sid.prefix(8))_"), "文件名命名逐字")
        XCTAssertTrue(fname.hasSuffix(".md"))
        XCTAssertTrue(r.savedFile.contains("/work/summaries/"))
        XCTAssertEqual(try String(contentsOfFile: r.savedFile, encoding: .utf8),
                       "# Session Summary\n\n总结：一切顺利。")
        // DB 行：session_summaries 有对应记录
        let dbRows = try kernel.database.withReadConn(global: false, projectId: pid) { conn in
            try conn.query(
                "SELECT agent_id, summary_text FROM session_summaries WHERE session_id = ?",
                [.text(sid)])
        }
        XCTAssertEqual(dbRows.count, 1)
        XCTAssertEqual(dbRows[0][0], .text(aid))
        XCTAssertEqual(dbRows[0][1], .text("总结：一切顺利。"))
    }

    /// 显式 model 优先于 config。
    func testSummarizeExplicitModelWins() async throws {
        let (pid, aid, sid, _) = try makeSession()
        try seedMessages(pid, aid, sid, count: 1)
        _ = try await NativeSessionOps.summarizeSession(
            db: kernel.database, connector: stub, config: cfg,
            projectId: pid, sessionId: sid, agentId: aid, model: "explicit-m")
        XCTAssertEqual(stub.lastModel, "explicit-m")
    }

    /// 超 8000 字符截断：追加「（更早内容已截断）」且停在截断点。
    func testSummarizeTruncatesAt8000Chars() async throws {
        let (pid, aid, sid, _) = try makeSession()
        // 两条 5000 字符消息：第一条进（total=5005），第二条超界 → 截断标记
        try kernel.database.saveMessage(projectId: pid, sessionId: sid, agentId: aid,
                                        role: "user", content: String(repeating: "甲", count: 5000))
        try kernel.database.saveMessage(projectId: pid, sessionId: sid, agentId: aid,
                                        role: "user", content: String(repeating: "乙", count: 5000))
        _ = try await NativeSessionOps.summarizeSession(
            db: kernel.database, connector: stub, config: cfg,
            projectId: pid, sessionId: sid, agentId: aid, model: "m")
        XCTAssertTrue(stub.lastPrompt.contains("（更早内容已截断）"))
        XCTAssertTrue(stub.lastPrompt.contains("甲"))
        XCTAssertFalse(stub.lastPrompt.contains("乙乙"), "超界消息不进源文")
    }

    /// 无消息 404 / 无可总结内容 422（chat 调用前抛出，经 client 包装锚定端点映射）。
    func testSummarize404And422ViaClient() async throws {
        let (pid, aid, sid, _) = try makeSession()
        // 404：无消息
        do {
            _ = try await client.summarizeSession(projectId: pid, agentId: aid,
                                                  sessionId: sid, model: "m")
            XCTFail("应抛 404")
        } catch SidecarError.httpError(let status, let detail) {
            XCTAssertEqual(status, 404)
            XCTAssertEqual(detail, "会话不存在或无消息，无法总结")
        }
        // 422：只有 system/空白
        try kernel.database.saveMessage(projectId: pid, sessionId: sid, agentId: aid,
                                        role: "system", content: "sys")
        try kernel.database.saveMessage(projectId: pid, sessionId: sid, agentId: aid,
                                        role: "user", content: "  ")
        do {
            _ = try await client.summarizeSession(projectId: pid, agentId: aid,
                                                  sessionId: sid, model: "m")
            XCTFail("应抛 422")
        } catch SidecarError.httpError(let status, let detail) {
            XCTAssertEqual(status, 422)
            XCTAssertEqual(detail, "会话无可总结的内容")
        }
    }

    /// 空回 502 / 一般异常 500 / connector 业务错误直通（400 api / 403 guard）。
    func testSummarizeErrorLadder() async throws {
        let (pid, aid, sid, _) = try makeSession()
        try kernel.database.saveMessage(projectId: pid, sessionId: sid, agentId: aid,
                                        role: "user", content: "有内容了")
        func expectHTTP(_ status: Int, _ detailPrefix: String,
                        _ result: Result<String, Error>,
                        file: StaticString = #filePath, line: UInt = #line) async {
            stub.chatResult = result
            do {
                _ = try await NativeSessionOps.summarizeSession(
                    db: kernel.database, connector: stub, config: cfg,
                    projectId: pid, sessionId: sid, agentId: aid, model: "m")
                XCTFail("应抛 \(status)", file: file, line: line)
            } catch SidecarError.httpError(let s, let d) {
                XCTAssertEqual(s, status, file: file, line: line)
                XCTAssertTrue(d.hasPrefix(detailPrefix), d, file: file, line: line)
            } catch {
                XCTFail("错误类型不符：\(error)", file: file, line: line)
            }
        }
        // 502：模型空回（逐字文案）
        stub.chatResult = .success("   ")
        do {
            _ = try await NativeSessionOps.summarizeSession(
                db: kernel.database, connector: stub, config: cfg,
                projectId: pid, sessionId: sid, agentId: aid, model: "m")
            XCTFail("应抛 502")
        } catch SidecarError.httpError(let s, let d) {
            XCTAssertEqual(s, 502)
            XCTAssertEqual(d, "模型未返回总结内容，请重试")
        }
        // 500：connector 业务外异常
        await expectHTTP(500, "总结生成失败：", .failure(NativeRoundtableError("连接被重置")))
        // OllamaAPIError 直通（app.py L233-237：exc.status_code + message）
        await expectHTTP(400, "model 'm' not found",
                         .failure(NativeChatConnectorError.api(status: 400, detail: "model 'm' not found")))
        // NetworkGuardError 直通（app.py L227-231：403 + message）
        await expectHTTP(403, "网络开关已关闭",
                         .failure(NativeChatConnectorError.guardDenied(status: 403, detail: "网络开关已关闭")))
    }
}
