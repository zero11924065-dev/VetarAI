//
//  NativeDatabaseTests.swift
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

//  逐条对照 subagent/sidecar/storage/store.py（注释标行号）。覆盖：
//    · schema 期望（13 表 / 130 列有序 / 9 索引；基线来自真实 Python 侧车生成库）
//    · 项目 / Agent / 会话 / 消息 CRUD 与怪癖保留（ia- 命名空间、NULL≠空串、falsy 不装配）
//    · 旧库幂等迁移（缺列补齐 + agent_tasks CHECK 重建，数据无损）
//    · 写锁串行 / 事务回滚（checkpoint-050 B-1 语义）
//  另有 NativeStateStore（app.py L1053/L1625）与 NativeRouting 表完整性测试。
//

import XCTest
@testable import VetarAINative

final class NativeDatabaseTests: XCTestCase {

    private var tmp: URL!
    private var db: NativeDatabase!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("w0db_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        db = NativeDatabase(projectsRoot: tmp.appendingPathComponent("projects"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    // MARK: - schema 期望（对基线库逐字段核对结果；store.py L42-198）

    func testSchemaMatchesBaseline() throws {
        // 触发建库
        _ = try db.listProjects()
        let conn = try SQLiteConnection(path: db.globalDBPath, busyTimeoutMs: 1000)
        defer { try? conn.close() }
        // 表集合
        let tables = Set(try conn.query(
            "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
            .compactMap { $0[0].textValue })
        XCTAssertEqual(tables, Set(NativeDatabaseSchema.expectedColumns.keys))
        XCTAssertEqual(tables.count, 13)
        // 列有序核对（PRAGMA table_info 顺序 = cid 序）
        for (table, expected) in NativeDatabaseSchema.expectedColumns {
            let cols = try conn.query("PRAGMA table_info(\(table))").compactMap { $0[1].textValue }
            XCTAssertEqual(cols, expected, "表 \(table) 列不一致")
        }
        // 索引
        let indexes = Set(try conn.query(
            "SELECT name FROM sqlite_master WHERE type='index' AND name NOT LIKE 'sqlite_%'")
            .compactMap { $0[0].textValue })
        XCTAssertEqual(indexes, NativeDatabaseSchema.expectedIndexes)
    }

    /// 默认值与约束抽查（PRAGMA table_info 的 dflt_value / notnull）。
    func testSchemaDefaultsAndChecks() throws {
        _ = try db.listProjects()
        let conn = try SQLiteConnection(path: db.globalDBPath, busyTimeoutMs: 1000)
        defer { try? conn.close() }
        let sess = try conn.query("PRAGMA table_info(sessions)")
        // title DEFAULT '新会话'
        let titleCol = sess.first { $0[1].textValue == "title" }
        XCTAssertEqual(titleCol?[4].textValue, "'新会话'")
        // created_at DEFAULT datetime('now')
        let createdCol = sess.first { $0[1].textValue == "created_at" }
        XCTAssertEqual(createdCol?[4].textValue, "datetime('now')")
        // CHECK 约束：非法 type_ / role / status 必须报错（CHECK 在库里真生效）
        XCTAssertThrowsError(try conn.execute(
            "INSERT INTO agent_configs (id, project_id, name, type_) VALUES ('a', 'p', 'n', 'bogus')"))
        XCTAssertThrowsError(try conn.execute(
            "INSERT INTO session_messages (session_id, agent_id, project_id, role) VALUES ('s','a','p','ghost')"))
        XCTAssertThrowsError(try conn.execute(
            "INSERT INTO agent_tasks (id, project_id, parent_agent_id, parent_session_id, target_agent_id, target_agent_name, task, expect, status) VALUES ('t','p','pa','ps','ta','tn','k','e','bogus')"))
    }

    /// 项目库与全局库同 schema（_ensure_schema 对两者同跑——agents.db 也含 projects 表）。
    func testProjectDBSharesSchema() throws {
        let pid = try db.createProject(name: "p1", workingDir: tmp.appendingPathComponent("wd").path)
        _ = try db.listAgentConfigs(projectId: pid)
        let conn = try SQLiteConnection(
            path: tmp.appendingPathComponent("projects/\(pid)/agents.db").path, busyTimeoutMs: 1000)
        defer { try? conn.close() }
        let tables = Set(try conn.query(
            "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
            .compactMap { $0[0].textValue })
        XCTAssertEqual(tables.count, 13)
    }

    // MARK: - Project CRUD（store.py L350-394 / L495-499）

    func testProjectCRUD() throws {
        let wd = tmp.appendingPathComponent("wd")
        let pid = try db.createProject(name: "项目甲", workingDir: wd.path)
        // uuid 形态（str(uuid.uuid4()) 小写带连字符）
        XCTAssertTrue(pid.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#,
                                options: .regularExpression) != nil)
        // 工作目录已建 + resolve（/tmp 符号链接展开）
        XCTAssertTrue(FileManager.default.fileExists(atPath: wd.path))
        let row = try db.getProject(pid)
        XCTAssertEqual(row?.name, "项目甲")
        XCTAssertTrue(row?.workingDir.hasPrefix("/") ?? false)
        // Path.resolve() 口径：realpath 展开（macOS /var→/private/var firmlink；
        // /tmp→/private/tmp）——与 Python 逐字一致由双跑测试 diff 断言，
        // 此处用同一 realpath helper 钉住存储值。
        XCTAssertEqual(row?.workingDir, NativeConfigStore.resolvePath(wd).path)

        let list = try db.listProjects()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].id, pid)
        XCTAssertEqual(list[0].name, "项目甲")

        XCTAssertTrue(try db.renameProject(pid, name: "项目乙"))
        XCTAssertEqual(try db.getProject(pid)?.name, "项目乙")
        XCTAssertFalse(try db.renameProject("nonexistent", name: "x"))

        // 删除连带清项目目录（L375-378）。⚠️ 口径核对：Python create_project
        // **不建** projects/<pid>（L350-367 只建工作目录+写全局库）；项目目录由
        // 首个项目库连接 _agent_conn 惰性建（L273-276）。先钉住惰性语义再验删除。
        let pdir = tmp.appendingPathComponent("projects/\(pid)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pdir.path))
        _ = try db.createSession(projectId: pid, agentId: "agent-x")   // 触发项目库 → 建目录
        XCTAssertTrue(FileManager.default.fileExists(atPath: pdir.path))
        XCTAssertTrue(try db.deleteProject(pid))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pdir.path))
        XCTAssertFalse(try db.deleteProject(pid))
        XCTAssertNil(try db.getProject(pid))
    }

    /// 工作目录校验：写测试文件失败 → 报错（L353-363）。
    func testCreateProjectUnwritableDir() {
        // 指向文件而非目录 → 建子目录失败
        let f = tmp.appendingPathComponent("afile")
        try! "x".write(to: f, atomically: false, encoding: .utf8)
        XCTAssertThrowsError(try db.createProject(name: "p", workingDir: f.appendingPathComponent("sub").path))
    }

    // MARK: - Agent config CRUD（L504-582）

    func testAgentConfigCRUD() throws {
        let pid = try db.createProject(name: "p", workingDir: tmp.appendingPathComponent("wd").path)
        let aid = try db.addAgentConfig(projectId: pid, name: "主Agent", type: "main",
                                        role: "代码专家", modelName: "qwen3.8")
        let sub = try db.addAgentConfig(projectId: pid, name: "子Agent", type: "sub",
                                        parentAgentId: aid)
        var rows = try db.listAgentConfigs(projectId: pid)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].id, aid)   // ORDER BY created_at（同秒下按 rowid——用例内序稳定）
        XCTAssertEqual(rows[0].role, "代码专家")
        XCTAssertEqual(rows[1].parentAgentId, aid)

        // NULL 语义（W5b）：未传 = NULL，读回 nil
        XCTAssertNil(rows[1].role)
        XCTAssertNil(rows[1].systemPrompt)

        // 显式分支更新（B12）：只改 model_name，其他不动
        XCTAssertTrue(try db.updateAgentConfig(projectId: pid, agentId: aid, modelName: "qwen3.14"))
        let got = try db.getAgentConfig(projectId: pid, agentId: aid)
        XCTAssertEqual(got?.modelName, "qwen3.14")
        XCTAssertEqual(got?.role, "代码专家")
        // 全 None → false（无有效更新，L533）
        XCTAssertFalse(try db.updateAgentConfig(projectId: pid, agentId: aid))
        // 空串是有效值（清除语义）——与 NULL 区分（W5b 发现的口径差异，必须保留）
        XCTAssertTrue(try db.updateAgentConfig(projectId: pid, agentId: aid, role: ""))
        XCTAssertEqual(try db.getAgentConfig(projectId: pid, agentId: aid)?.role, "")
        XCTAssertNotNil(try db.getAgentConfig(projectId: pid, agentId: aid)?.role)

        // 删除级联（L514-524）：会话/消息/摘要全清
        let sid = try db.createSession(projectId: pid, agentId: aid)
        try db.saveMessage(projectId: pid, sessionId: sid, agentId: aid, role: "user", content: "hi")
        XCTAssertTrue(try db.removeAgentConfig(projectId: pid, agentId: aid))
        XCTAssertTrue(try db.listSessions(projectId: pid, agentId: aid).isEmpty)
        XCTAssertTrue(try db.loadMessages(projectId: pid, sessionId: sid).isEmpty)
        XCTAssertNil(try db.getAgentConfig(projectId: pid, agentId: aid))
        XCTAssertEqual(try db.listAgentConfigs(projectId: pid).count, 1)
        _ = sub
    }

    // MARK: - Session CRUD（L587-627）

    func testSessionCRUD() throws {
        let pid = try db.createProject(name: "p", workingDir: tmp.appendingPathComponent("wd").path)
        let aid = try db.addAgentConfig(projectId: pid, name: "a", type: "main")
        let sid = try db.createSession(projectId: pid, agentId: aid)   // 默认标题「新会话」
        let rows = try db.listSessions(projectId: pid, agentId: aid)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].title, "新会话")
        XCTAssertEqual(rows[0].messageCount, 0)

        try db.saveMessage(projectId: pid, sessionId: sid, agentId: aid, role: "user", content: "问")
        let rows2 = try db.listSessions(projectId: pid, agentId: aid)
        XCTAssertEqual(rows2[0].messageCount, 1)   // LEFT JOIN 计数（TS-115）

        XCTAssertTrue(try db.renameSession(projectId: pid, sessionId: sid, title: "改名"))
        XCTAssertEqual(try db.listSessions(projectId: pid, agentId: aid)[0].title, "改名")
        XCTAssertFalse(try db.renameSession(projectId: pid, sessionId: "nope", title: "x"))

        // 删除级联（L739-746）
        XCTAssertTrue(try db.deleteSession(projectId: pid, sessionId: sid))
        XCTAssertTrue(try db.loadMessages(projectId: pid, sessionId: sid).isEmpty)
        XCTAssertFalse(try db.deleteSession(projectId: pid, sessionId: sid))
    }

    // MARK: - Message persistence（L751-853）

    func testMessageRoundtrip() throws {
        let pid = try db.createProject(name: "p", workingDir: tmp.appendingPathComponent("wd").path)
        let aid = try db.addAgentConfig(projectId: pid, name: "a", type: "main")
        let sid = try db.createSession(projectId: pid, agentId: aid)

        // 全字段消息（C8 stopped / H17 prompt_eval_count / TS-120 archived 前的基准态）
        try db.saveMessage(projectId: pid, sessionId: sid, agentId: aid, role: "user",
                           content: "你好", images: ["data:image/png;base64,AAA"],
                           modelUsed: "qwen3.8",
                           toolSteps: .array([.object(["id": .string("c1"), "name": .string("list_dir"),
                                                       "status": .string("ok"), "summary": .string("2 个条目")])]),
                           truncated: false, promptEvalCount: 1234, stopped: false)
        // 最小消息：images/model_used/tool_steps NULL；truncated/stopped 0；prompt_eval_count NULL
        try db.saveMessage(projectId: pid, sessionId: sid, agentId: aid, role: "assistant",
                           content: "答复")

        let msgs = try db.loadMessages(projectId: pid, sessionId: sid)
        XCTAssertEqual(msgs.count, 2)
        let m0 = msgs[0]
        XCTAssertEqual(m0.role, "user")
        XCTAssertEqual(m0.content, "你好")
        XCTAssertEqual(m0.images, [.string("data:image/png;base64,AAA")])
        XCTAssertEqual(m0.toolSteps?.first?.object?["summary"], .string("2 个条目"))
        XCTAssertEqual(m0.promptEvalCount, 1234)
        XCTAssertFalse(m0.truncated)
        XCTAssertFalse(m0.stopped)
        XCTAssertFalse(m0.archived)
        XCTAssertNotNil(m0.createdAt)
        // created_at 形态 = SQLite datetime('now')（UTC "YYYY-MM-DD HH:MM:SS"）
        XCTAssertTrue((m0.createdAt ?? "").range(
            of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$"#, options: .regularExpression) != nil)

        let m1 = msgs[1]
        XCTAssertNil(m1.images)          // falsy 不装配（L820-824）
        XCTAssertNil(m1.toolSteps)
        XCTAssertNil(m1.promptEvalCount) // NULL ≠ 0（W5b 口径保留）
        XCTAssertEqual(m1.id, m0.id + 1) // AUTOINCREMENT 单调
    }

    /// 损坏 JSON 列宽容读（load_messages try/except JSONDecodeError: pass，L822-828）。
    func testLoadMessagesToleratesCorruptJSONColumns() throws {
        let pid = try db.createProject(name: "p", workingDir: tmp.appendingPathComponent("wd").path)
        let aid = try db.addAgentConfig(projectId: pid, name: "a", type: "main")
        let sid = try db.createSession(projectId: pid, agentId: aid)
        try db.saveMessage(projectId: pid, sessionId: sid, agentId: aid, role: "user", content: "x")
        // 手工写坏列（绕过 save_message）
        let conn = try SQLiteConnection(
            path: tmp.appendingPathComponent("projects/\(pid)/agents.db").path, busyTimeoutMs: 1000)
        try conn.execScript("UPDATE session_messages SET images = '{bad json', tool_steps = '[oops' WHERE session_id = '\(sid)'")
        try conn.close()
        let msgs = try db.loadMessages(projectId: pid, sessionId: sid)
        XCTAssertEqual(msgs.count, 1)
        XCTAssertNil(msgs[0].images)
        XCTAssertNil(msgs[0].toolSteps)
    }

    func testArchiveAndDeleteBefore() throws {
        let pid = try db.createProject(name: "p", workingDir: tmp.appendingPathComponent("wd").path)
        let aid = try db.addAgentConfig(projectId: pid, name: "a", type: "main")
        let sid = try db.createSession(projectId: pid, agentId: aid)
        for i in 0..<5 {
            try db.saveMessage(projectId: pid, sessionId: sid, agentId: aid,
                               role: i % 2 == 0 ? "user" : "assistant", content: "m\(i)")
        }
        // archive（TS-120 L842-853）
        let ids = try db.loadMessages(projectId: pid, sessionId: sid).map(\.id)
        XCTAssertEqual(try db.archiveMessages(projectId: pid, messageIds: [ids[0], ids[2]]), 2)
        XCTAssertEqual(try db.archiveMessages(projectId: pid, messageIds: []), 0)   // 空列表短路
        let archived = try db.loadMessages(projectId: pid, sessionId: sid).map(\.archived)
        XCTAssertEqual(archived, [true, false, true, false, false])
        // deleteMessagesBefore 保最近 2 条（M2 L792-808）
        XCTAssertEqual(try db.deleteMessagesBefore(projectId: pid, sessionId: sid, keepRecent: 2), 3)
        XCTAssertEqual(try db.loadMessages(projectId: pid, sessionId: sid).count, 2)
        // 不足 keepRecent → 0
        XCTAssertEqual(try db.deleteMessagesBefore(projectId: pid, sessionId: sid, keepRecent: 10), 0)
    }

    // MARK: - compact_log（L768-789）

    func testCompactLogRoundtrip() throws {
        let pid = try db.createProject(name: "p", workingDir: tmp.appendingPathComponent("wd").path)
        let aid = try db.addAgentConfig(projectId: pid, name: "a", type: "main")
        let sid = try db.createSession(projectId: pid, agentId: aid)
        try db.logCompact(projectId: pid, sessionId: sid, beforeTokens: 1000, afterTokens: 300,
                          archivePath: "/tmp/a.md", summary: "摘要", error: nil)
        try db.logCompact(projectId: pid, sessionId: sid, beforeTokens: 900, afterTokens: 0,
                          archivePath: nil, summary: nil, error: "压缩失败原因")
        let logs = try db.loadCompactLog(projectId: pid, sessionId: sid)
        XCTAssertEqual(logs.count, 2)
        // ORDER BY id DESC：新→旧
        XCTAssertEqual(logs[0].beforeTokens, 900)
        XCTAssertEqual(logs[0].error, "压缩失败原因")
        XCTAssertNil(logs[0].archivePath)
        XCTAssertEqual(logs[1].summary, "摘要")
        // limit 生效
        XCTAssertEqual(try db.loadCompactLog(projectId: pid, sessionId: sid, limit: 1).count, 1)
    }

    // MARK: - 独立 Agent（checkpoint-058，L397-492）

    func testIndependentAgents() throws {
        let aid = try db.addIndependentAgent(name: "独立甲", systemPrompt: "你是助手", modelName: "qwen3.8")
        // 命名空间目录 + 沙盒（L422-424）
        let dir = tmp.appendingPathComponent("projects/ia-\(aid)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("sandbox").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("agents.db").path))

        // 双写：全局表 + 命名空间 agent_configs（L411-421）
        let rows = try db.listIndependentAgents()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].systemPrompt, "你是助手")
        XCTAssertNil(rows[0].role)   // 未传 = NULL
        let nsAgent = try db.getAgentConfig(projectId: "ia-\(aid)", agentId: aid)
        XCTAssertEqual(nsAgent?.name, "独立甲")
        XCTAssertEqual(nsAgent?.type_, "main")

        // 更新双写（L447-479）；空串清除语义保留
        XCTAssertTrue(try db.updateIndependentAgent(aid, name: "独立甲改", systemPrompt: ""))
        XCTAssertEqual(try db.getIndependentAgent(aid)?.name, "独立甲改")
        XCTAssertEqual(try db.getAgentConfig(projectId: "ia-\(aid)", agentId: aid)?.name, "独立甲改")
        XCTAssertEqual(try db.getIndependentAgent(aid)?.systemPrompt, "")
        // 全 None → false（L454 起无有效更新）
        XCTAssertFalse(try db.updateIndependentAgent(aid))
        XCTAssertFalse(try db.updateIndependentAgent("nonexistent", name: "x"))

        // 删除：注册记录 + 命名空间目录全清（L482-492）
        XCTAssertTrue(try db.deleteIndependentAgent(aid))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertFalse(try db.deleteIndependentAgent(aid))
        XCTAssertTrue(try db.listIndependentAgents().isEmpty)
    }

    /// 删除项目不触碰 ia-* 目录（checkpoint-058 隔离承诺）。
    func testDeleteProjectNeverTouchesIndependentNamespace() throws {
        let pid = try db.createProject(name: "p", workingDir: tmp.appendingPathComponent("wd").path)
        let aid = try db.addIndependentAgent(name: "独立")
        XCTAssertTrue(try db.deleteProject(pid))
        XCTAssertNotNil(try db.getIndependentAgent(aid))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tmp.appendingPathComponent("projects/ia-\(aid)").path))
    }

    // MARK: - 旧库迁移（store.py L199-263）

    /// 手工造 0.2 时代旧库（缺新列 + agent_tasks 旧 CHECK），走一遍连接即迁移。
    func testLegacyDBMigration() throws {
        let pid = "legacy-proj"
        let pdir = tmp.appendingPathComponent("projects/\(pid)")
        try FileManager.default.createDirectory(at: pdir, withIntermediateDirectories: true)
        let dbPath = pdir.appendingPathComponent("agents.db").path
        let conn = try SQLiteConnection(path: dbPath, busyTimeoutMs: 1000)
        // 旧版 session_messages（无 tool_steps/truncated/prompt_eval_count/archived/stopped）
        try conn.execScript("""
            CREATE TABLE session_messages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL, agent_id TEXT NOT NULL, project_id TEXT NOT NULL,
                role TEXT NOT NULL CHECK(role IN ('user','assistant','system')),
                content TEXT, images TEXT, model_used TEXT,
                created_at TEXT DEFAULT (datetime('now'))
            );
        """)
        // 旧版 agent_tasks（CHECK 无 'queued'，0.27 形态；store.py L222-227 的迁移触发条件）
        try conn.execScript("""
            CREATE TABLE agent_tasks (
                id TEXT PRIMARY KEY, project_id TEXT NOT NULL,
                parent_agent_id TEXT NOT NULL, parent_session_id TEXT NOT NULL,
                target_agent_id TEXT NOT NULL, target_agent_name TEXT NOT NULL,
                task TEXT NOT NULL, expect TEXT NOT NULL,
                status TEXT NOT NULL DEFAULT 'running' CHECK(status IN ('running','done','failed')),
                report TEXT, fail_reason TEXT,
                validation_failures INTEGER NOT NULL DEFAULT 0, session_id TEXT,
                created_at TEXT DEFAULT (datetime('now')), updated_at TEXT DEFAULT (datetime('now'))
            );
        """)
        try conn.begin()
        try conn.execute(
            "INSERT INTO session_messages (session_id, agent_id, project_id, role, content) VALUES ('s','a','p','user','旧消息')")
        try conn.execute(
            "INSERT INTO agent_tasks (id, project_id, parent_agent_id, parent_session_id, target_agent_id, target_agent_name, task, expect, status) VALUES ('t1','p','pa','ps','ta','tn','旧任务','期望','running')")
        try conn.commit()
        try conn.close()

        // 原生层打开 → 迁移
        _ = try db.loadMessages(projectId: pid, sessionId: "s")

        let conn2 = try SQLiteConnection(path: dbPath, busyTimeoutMs: 1000)
        defer { try? conn2.close() }
        let cols = try conn2.columnNames(of: "session_messages")
        for c in ["tool_steps", "truncated", "prompt_eval_count", "archived", "stopped"] {
            XCTAssertTrue(cols.contains(c), "缺迁移列 \(c)")
        }
        // agent_tasks 已重建（CHECK 含 'queued'）
        let sql = try conn2.tableSQL("agent_tasks") ?? ""
        XCTAssertTrue(sql.contains("'queued'"))
        // 数据无损（L223 逐列搬运）
        let msgs = try conn2.query("SELECT content FROM session_messages")
        XCTAssertEqual(msgs.first?[0].textValue, "旧消息")
        let tasks = try conn2.query("SELECT id, status FROM agent_tasks")
        XCTAssertEqual(tasks.first?[0].textValue, "t1")
        XCTAssertEqual(tasks.first?[1].textValue, "running")
        // 重建后 queued 可写（新 CHECK 生效）
        XCTAssertNoThrow(try conn2.execute(
            "INSERT INTO agent_tasks (id, project_id, parent_agent_id, parent_session_id, target_agent_id, target_agent_name, task, expect, status) VALUES ('t2','p','pa','ps','ta','tn','新','e','queued')"))
    }

    // MARK: - 事务语义（checkpoint-050 B-1：异常回滚 + 必关闭）

    func testWriteFailureRollsBack() throws {
        let pid = try db.createProject(name: "p", workingDir: tmp.appendingPathComponent("wd").path)
        // 非法 type_ 触发 CHECK → 整批回滚，连接不泄漏（后续写不 locked）
        XCTAssertThrowsError(try db.addAgentConfig(projectId: pid, name: "bad", type: "bogus"))
        XCTAssertTrue(try db.listAgentConfigs(projectId: pid).isEmpty)
        // 后续写照常（无连接泄漏/锁残留）
        XCTAssertNoThrow(try db.addAgentConfig(projectId: pid, name: "good", type: "main"))
        XCTAssertEqual(try db.listAgentConfigs(projectId: pid).count, 1)
    }
}

// MARK: - NativeStateStore（app.py L1053-1066 写 / L1625-1639 读）

final class NativeStateStoreTests: XCTestCase {

    private var tmp: URL!
    private var store: NativeStateStore!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("w0state_\(UUID().uuidString)")
        store = NativeStateStore(projectsRoot: tmp)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    /// 写读往返（对标 test_state_file.py L59-66 的 read_state 口径；json.dumps indent=2 落盘）。
    func testWriteReadRoundtrip() {
        let state: [String: JSONValue] = [
            "status": .string("done"), "step": .int(1), "tokens_used": .int(100),
            "steps": .array([.object(["id": .string("c1"), "status": .string("ok")])]),
        ]
        store.write(projectId: "p1", state: state)
        // 原子写产物：无 .tmp 残留（对齐 test_config.py L70-71 的同型断言）
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tmp.appendingPathComponent("p1/work/state.json.tmp").path))
        let (exists, readBack) = store.read(projectId: "p1")
        XCTAssertTrue(exists)
        XCTAssertEqual(readBack?["status"], .string("done"))
        XCTAssertEqual(readBack?["step"], .int(1))
        // 中断态语义（app.py L1630：status != done 即中断可查）
        store.write(projectId: "p1", state: ["status": .string("interrupted")])
        XCTAssertEqual(store.read(projectId: "p1").state?["status"], .string("interrupted"))
    }

    /// 查询端点语义：不存在 → exists=false（test_state_file.py L89-90 用例②尾部）。
    func testReadMissing() {
        XCTAssertFalse(store.read(projectId: "nonexistent").exists)
        XCTAssertNil(store.read(projectId: "nonexistent").state)
    }

    /// 损坏文件 → exists=false（app.py L1638-1639 except 口径）。
    func testReadCorrupt() throws {
        let dir = tmp.appendingPathComponent("p2/work")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{ bad".write(to: dir.appendingPathComponent("state.json"), atomically: false, encoding: .utf8)
        XCTAssertFalse(store.read(projectId: "p2").exists)
    }

    /// 空 projectId 不写（app.py L1055-1056）。
    func testWriteEmptyProjectIdNoop() {
        store.write(projectId: "", state: ["status": .string("done")])
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("/work").path))
    }
}

// MARK: - NativeRouting（路由表完整性 + 客户端路由分发）

final class NativeRoutingTests: XCTestCase {

    /// 路由表覆盖全部模块（CaseIterable 全覆盖，漏登记者编译期/本测试必被抓）。
    func testRoutingTableCoversAllModules() {
        XCTAssertEqual(NativeRoutingTable.entries.count, NativeModuleKind.allCases.count)
        for m in NativeModuleKind.allCases {
            XCTAssertEqual(NativeRoutingTable.entry(m).module, m)
        }
    }

    /// 已原生模块清单（后续波次翻转条目时本测试须同步——防漏改）。
    /// P2-W1 翻转：knowledge（知识/记忆）+ warehouse（知识仓库），见路由表 wave 列。
    /// P2-W2 翻转：workflows（工作流引擎内生化）。
    /// P3-W2a 翻转：inference（推理面板端点面）。
    /// P3-W3a 翻转：modelPacks（模型包管理面 + llama 驱动 + MP chat/inference 分支）。
    /// P3-W4 翻转：cuMacros（CU 宏八端点 + user 模式系统级录制 + TCC 重归属）。
    /// P3-W5 翻转：plugins（插件管理面八端点 + hook python3 子进程桥）——
    /// 路由表 httpFallback 清零。
    func testNativeModulesBaseline() {
        XCTAssertEqual(Set(NativeRoutingTable.nativeModules), [
            .config, .projects, .agents, .sessions, .messages, .independentAgents, .stateFile,
            .knowledge, .warehouse, .workflows,
            .chat, .tasks, .roundtables,   // P2-W4d2：chat 端点装配 + 委派/圆桌端点面翻转
            .attachments,                  // P3-W1b：附件解析/落盘翻转
            .inference,                    // P3-W2a：推理面板 status/models/pull/delete/context-limit 翻转
            .modelPacks,                   // P3-W3a：模型包管理面 + 驱动 + MP chat/inference 分支
            .cuMacros,                     // P3-W4：CU 宏八端点 + user 录制器 + TCC 重归属
            .plugins,                      // P3-W5：插件八端点 + hook python3 子进程桥（路由表全原生）
        ])
    }

    /// NativeSidecarClient 路由分发（P3-W6 翻纯原生：HTTP fallback 层已退役删除，
    /// 历史上经 RoutingMockClient 录证「原生方法不触网」——如今无网可触，直验行为）。
    func testClientRouting() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("w0route_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let kernel = NativeKernel(dataRoot: tmp)
        let client = NativeSidecarClient(kernel: kernel)

        // config 原生
        let cfg = try await client.getConfig()
        XCTAssertEqual(cfg.maxToolRounds, 200)

        _ = try await client.updateConfig(["max_tool_rounds": .int(300)])
        let cfgAfter = try await client.getConfig()
        XCTAssertEqual(cfgAfter.maxToolRounds, 300)

        // 项目原生
        let pid = try await client.createProject(name: "p", workingDir: tmp.appendingPathComponent("wd").path)
        let projects = try await client.listProjects()
        XCTAssertEqual(projects.map(\.id), [pid])

        // 推理模型列表：ollama 空名单直返空（P3-W6 与侧车代理同源——
        // 钉空 fetcher 保 deterministic；生产 = ollama /api/tags 直读优先）
        client.ollamaTagsFetcher = { _ in [] }
        let models = try await client.listModels()
        XCTAssertEqual(models, [])

        // 删 Agent 原生（P3-W1a 删除编排：取消在飞委派→删行），行真删
        let aid = try kernel.database.addAgentConfig(projectId: pid, name: "a", type: "sub")
        try await client.deleteAgent(projectId: pid, agentId: aid)
        XCTAssertNil(try kernel.database.getAgentConfig(projectId: pid, agentId: aid))

        // 校验错误映射：未知键 → 400（与 PUT /api/config 同口径）
        do {
            _ = try await client.updateConfig(["bogus_key": .int(1)])
            XCTFail("应抛 400")
        } catch SidecarError.httpError(let status, let detail) {
            XCTAssertEqual(status, 400)
            XCTAssertEqual(detail, "未知配置项: bogus_key")
        }
    }
}
