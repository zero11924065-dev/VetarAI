//
//  NativeKnowledgeStoreTests.swift
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

//  翻译出处（subagent/sidecar/knowledge/，⛔ 只读行为规格；逐套件标注）：
//    · test_warehouse.py        → W1–W10（条目 CRUD/检索/删除/重建/对账/编排钳制）
//    · test_a11_import_files.py → T1–T8（导入两趟冲突链；docx 用例改 .txt——
//      OOXML 原生解析 W1 未覆盖，见 NativeDocParser 头注；T9 端点 executor 源码断言
//      不适用（原生无事件循环，客户端已用 Task.detached 等价口径））
//    · test_knowledge.py        → M4（知识文件/记忆/禁止事项/注入拼接）
//    · warehouse.py _ensure_schema → schema 逐字兼容 + 旧 CHECK 迁移用例
//
//  模型无关（embedder 恒不可用 → 语义静默降级关键词，降级路径也被断言）。
//  模型相关用例（H1–H9）在 NativeKnowledgeEmbedTests。
//

import XCTest
@testable import VetarAINative

final class NativeKnowledgeStoreTests: XCTestCase {

    private var tmp: URL!
    private var kernel: NativeKernel!
    private var store: NativeKnowledgeStore { kernel.knowledge }
    private var projWD: URL!
    private var pid: String!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("p2w1_ks_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        // modelDir 指向空目录 → 恒不可用（本套件不依赖模型，顺带覆盖降级路径）
        let emptyModels = tmp.appendingPathComponent("empty-models", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyModels, withIntermediateDirectories: true)
        kernel = NativeKernel(dataRoot: tmp, modelDir: emptyModels)
        projWD = tmp.appendingPathComponent("proj_work", isDirectory: true)
        try FileManager.default.createDirectory(at: projWD, withIntermediateDirectories: true)
        pid = try kernel.database.createProject(name: "测试项目", workingDir: projWD.path)
    }

    override func tearDown() {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
        kernel = nil
        super.tearDown()
    }

    // MARK: - schema 逐字兼容（warehouse.py _ensure_schema）

    /// 三表建表 SQL 与 Python DDL 逐字同构（列序/约束/默认值；FTS5 虚表存在）。
    func testSchemaParity() throws {
        _ = store.listEntries()   // 触发建库
        let conn = try SQLiteConnection(path: store.indexDBPath, busyTimeoutMs: 1000)
        defer { try? conn.close() }
        let keSQL = try XCTUnwrap(conn.tableSQL("knowledge_entries"))
        // 逐字段核对（对齐 Python CREATE TABLE 语句结构）
        for frag in ["id TEXT PRIMARY KEY", "title TEXT NOT NULL",
                     "scope TEXT NOT NULL CHECK(scope IN ('project','global'))",
                     "project_id TEXT", "category TEXT", "keywords TEXT",
                     "source TEXT NOT NULL DEFAULT 'chat' CHECK(source IN ('chat','manual','file'))",
                     "file_path TEXT NOT NULL", "created_at TEXT NOT NULL"] {
            XCTAssertTrue(keSQL.contains(frag), "knowledge_entries 缺片段: \(frag)")
        }
        let emSQL = try XCTUnwrap(conn.tableSQL("knowledge_embeddings"))
        for frag in ["entry_id TEXT PRIMARY KEY", "dense BLOB", "sparse TEXT",
                     "model TEXT NOT NULL DEFAULT 'bge-m3-onnx-int8'", "updated_at TEXT NOT NULL"] {
            XCTAssertTrue(emSQL.contains(frag), "knowledge_embeddings 缺片段: \(frag)")
        }
        // FTS5 虚表 + bm25 可用性（macOS 系统 libsqlite3 带 FTS5）
        let ftsTables = try conn.query(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='knowledge_fts'")
        XCTAssertEqual(ftsTables.count, 1)
        // 索引 idx_ke_scope
        let idx = try conn.query(
            "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_ke_scope'")
        XCTAssertEqual(idx.count, 1)
    }

    /// 旧 CHECK('chat','manual') 表的整表重建迁移（保留行 + 新 source='file' 可写）。
    func testLegacyCheckMigration() throws {
        // 手工造旧约束库（warehouse.py A10 迁移前形态）
        let dir = URL(fileURLWithPath: store.indexDBPath).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let conn = try SQLiteConnection(path: store.indexDBPath, busyTimeoutMs: 1000)
        try conn.execScript("""
            CREATE TABLE knowledge_entries (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                scope TEXT NOT NULL CHECK(scope IN ('project','global')),
                project_id TEXT,
                category TEXT,
                keywords TEXT,
                source TEXT NOT NULL DEFAULT 'chat' CHECK(source IN ('chat','manual')),
                file_path TEXT NOT NULL,
                created_at TEXT NOT NULL
            );
            INSERT INTO knowledge_entries VALUES ('old1', '旧条目', 'global', '', '', '[]', 'chat', '/tmp/x.md', '2026-01-01 00:00:00');
        """)
        try conn.close()
        // 触发迁移
        let entries = store.listEntries()
        XCTAssertEqual(entries.map(\.id), ["old1"], "迁移须保留现有行")
        // 迁移后 source='file' 可写（新 CHECK 含 'file'）
        let src = tmp.appendingPathComponent("导入.txt")
        try "迁移后导入可索引".write(to: src, atomically: false, encoding: .utf8)
        let r = store.importFiles(scope: "global", projectId: nil, sources: [src.path])
        XCTAssertEqual(r.imported, 1, "迁移后 source='file' 应可写入")
    }

    // MARK: - W1 全局条目（test_warehouse.py W1）

    func testW1GlobalEntry() throws {
        let e1 = try XCTUnwrap(store.addEntry(scope: "global", projectId: nil,
                                              title: "地球是圆的", body: "地球是圆的，这是常识。",
                                              category: "常识", keywords: ["地球", "常识"]))
        // W1b .md 生成
        XCTAssertTrue(FileManager.default.fileExists(atPath: e1.filePath))
        // W1c frontmatter 含 title/scope
        let md = try String(contentsOfFile: e1.filePath, encoding: .utf8)
        XCTAssertTrue(md.contains("title: 地球是圆的"))
        XCTAssertTrue(md.contains("scope: global"))
        // W1d 列表含该条目
        XCTAssertTrue(store.listEntries(scope: "global").contains { $0.id == e1.id })
        // W1e 读取正文
        let got = try XCTUnwrap(store.getEntry(e1.id))
        XCTAssertTrue(got.body?.contains("地球是圆的，这是常识") ?? false)
        XCTAssertEqual(got.keywords, ["地球", "常识"])
        XCTAssertEqual(got.category, "常识")
    }

    // MARK: - W2 项目条目（test_warehouse.py W2）

    func testW2ProjectEntry() throws {
        let e2 = try XCTUnwrap(store.addEntry(scope: "project", projectId: pid,
                                              title: "项目笔记", body: "这是项目内的知识。",
                                              keywords: ["项目"]))
        // W2b 文件在项目知识库目录（知识库/）
        XCTAssertTrue(e2.filePath.contains("知识库"))
        // Python create_project 对 working_dir 做 Path.resolve()（realpath）后才落库——
        // macOS 临时目录 /var→/private/var firmlink 会被解析，故前缀比对须先同口径解析。
        XCTAssertTrue(e2.filePath.hasPrefix(NativeConfigStore.resolvePath(projWD).path))
        // W2c 项目列表过滤
        let plst = store.listEntries(scope: "project", projectId: pid)
        XCTAssertTrue(plst.contains { $0.id == e2.id })
        XCTAssertTrue(plst.allSatisfy { $0.scope == "project" })
    }

    // MARK: - W3/W4 关键词检索与作用域（test_warehouse.py W3/W4）

    func testW3W4KeywordSearchAndScope() throws {
        let e1 = try XCTUnwrap(store.addEntry(scope: "global", projectId: nil,
                                              title: "地球是圆的", body: "地球是圆的，这是常识。",
                                              keywords: ["地球", "常识"]))
        let e2 = try XCTUnwrap(store.addEntry(scope: "project", projectId: pid,
                                              title: "项目笔记", body: "这是项目内的知识。",
                                              keywords: ["项目"]))
        // W3a 搜「地球」命中
        let r = store.searchEntries("地球", scope: "global")
        XCTAssertEqual(r.map(\.id), [e1.id])
        // W3b 搜「常识」命中（关键词字段）
        XCTAssertTrue(store.searchEntries("常识").contains { $0.id == e1.id })
        // W3c 无匹配 → 空
        XCTAssertTrue(store.searchEntries("不存在的词xyz").isEmpty)
        // W4a 全局作用域搜不到项目条目
        XCTAssertTrue(store.searchEntries("项目", scope: "global").allSatisfy { $0.scope == "global" })
        // W4b 项目作用域命中项目条目
        XCTAssertTrue(store.searchEntries("项目", scope: "project", projectId: pid).contains { $0.id == e2.id })
        // 空查询 → 空（对齐 `if not query.strip(): return []`）
        XCTAssertTrue(store.searchEntries("  ").isEmpty)
    }

    // MARK: - W9 frontmatter 往返（test_warehouse.py W9）

    func testW9FrontmatterRoundTrip() {
        let md = NativeKnowledgeStore.entryToMarkdown(
            id: "x1", title: "往返测试", scope: "global", projectId: "",
            category: "c", keywords: ["k1", "k2"], source: "chat",
            createdAt: "2026-01-01 00:00:00", body: "正文内容")
        let (meta, kw, body) = NativeKnowledgeStore.parseMarkdown(md)
        XCTAssertEqual(meta["title"], "往返测试")
        XCTAssertEqual(kw, ["k1", "k2"])
        XCTAssertEqual(body.trimmingCharacters(in: .whitespacesAndNewlines), "正文内容")
        // keywords 逗号切回退（非法 JSON）
        let (_, kw2, _) = NativeKnowledgeStore.parseMarkdown("---\nkeywords: a, b ,c\n---\n\n正文")
        XCTAssertEqual(kw2, ["a", "b", "c"])
        // 无 frontmatter → 全文
        let (meta3, _, body3) = NativeKnowledgeStore.parseMarkdown("纯文本无头部")
        XCTAssertTrue(meta3.isEmpty)
        XCTAssertEqual(body3, "纯文本无头部")
        // keywords JSON 在 md 里的精确格式（Python json.dumps ensure_ascii=False 默认分隔）
        XCTAssertTrue(md.contains("keywords: [\"k1\", \"k2\"]"))
    }

    // MARK: - W5 删除（test_warehouse.py W5）

    func testW5Delete() throws {
        let e1 = try XCTUnwrap(store.addEntry(scope: "global", projectId: nil,
                                              title: "待删条目", body: "将被删除的内容"))
        XCTAssertTrue(store.deleteEntry(e1.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: e1.filePath))
        XCTAssertFalse(store.listEntries(scope: "global").contains { $0.id == e1.id })
        // FTS 不再命中
        XCTAssertFalse(store.searchEntries("待删").contains { $0.id == e1.id })
        // 不存在 → false
        XCTAssertFalse(store.deleteEntry("ghost-id"))
    }

    // MARK: - W6 索引重建（test_warehouse.py W6）

    func testW6Rebuild() throws {
        let e3 = try XCTUnwrap(store.addEntry(scope: "global", projectId: nil,
                                              title: "重建测试", body: "这是用于索引重建的内容。",
                                              keywords: ["重建"]))
        XCTAssertFalse(store.searchEntries("重建").isEmpty)
        // 清空索引模拟损坏（直写库）
        let conn = try SQLiteConnection(path: store.indexDBPath, busyTimeoutMs: 1000)
        try conn.execScript("DELETE FROM knowledge_entries; DELETE FROM knowledge_fts;")
        try conn.close()
        XCTAssertTrue(store.searchEntries("重建").isEmpty, "索引清空后应为空")
        let n = store.rebuildIndex()
        XCTAssertGreaterThanOrEqual(n, 1)
        XCTAssertTrue(store.searchEntries("重建").contains { $0.id == e3.id },
                      "重建后检索命中（frontmatter id 保留）")
    }

    // MARK: - W9b 外部删除对账（test_warehouse.py 同名 W9）

    func testPruneMissing() throws {
        let e1 = try XCTUnwrap(store.addEntry(scope: "global", projectId: nil,
                                              title: "外部删除测试", body: "这是一条将被外部删除的测试条目"))
        try FileManager.default.removeItem(atPath: e1.filePath)   // 模拟 Finder 直接删除
        XCTAssertEqual(store.pruneMissing(), 1)
        XCTAssertFalse(store.listEntries(scope: "global").contains { $0.id == e1.id })
        XCTAssertFalse(store.searchEntries("外部删除测试", scope: "global").contains { $0.id == e1.id })
        XCTAssertEqual(store.pruneMissing(), 0, "二次对账幂等")
    }

    // MARK: - W10 search_scoped 编排（test_warehouse.py W10）

    func testW10SearchScoped() throws {
        // ① scope 隔离（真实条目 + keyword 模式）
        let pa = try XCTUnwrap(store.addEntry(scope: "project", projectId: pid,
                                              title: "边界奇点项目条目", body: "边界奇点只应出现在项目库"))
        let ga = try XCTUnwrap(store.addEntry(scope: "global", projectId: nil,
                                              title: "边界奇点全局条目", body: "边界奇点只应出现在全局库"))
        let rp = store.searchScoped("边界奇点", scope: "project", projectId: pid, limit: 10, mode: "keyword")
        XCTAssertTrue(rp.contains { $0.id == pa.id } && rp.allSatisfy { $0.scope == "project" })
        let rg = store.searchScoped("边界奇点", scope: "global", projectId: pid, limit: 10, mode: "keyword")
        XCTAssertTrue(rg.contains { $0.id == ga.id } && rg.allSatisfy { $0.scope == "global" })

        // ② limit 钳制（真实语料端到端；Python 侧桩 hybrid_search 断言中间调用，
        //    Swift 无 monkey-patch——改为断言可观察结果等价）
        for i in 0..<25 {
            _ = store.addEntry(scope: "global", projectId: nil,
                               title: "钳制条目\(i)", body: "钳制共用词 编号\(i)")
        }
        XCTAssertEqual(store.searchScoped("钳制共用词", scope: "global", projectId: nil,
                                          limit: -3, mode: "keyword").count, 1, "limit<1 钳到 1")
        XCTAssertEqual(store.searchScoped("钳制共用词", scope: "global", projectId: nil,
                                          limit: 99, mode: "keyword").count, 20, "limit>20 钳到 20")

        // ③ scope=all 合并截断到 limit
        let hall = store.searchScoped("钳制共用词", scope: "all", projectId: pid, limit: 5, mode: "keyword")
        XCTAssertEqual(hall.count, 5)

        // ④ prune_missing 生效：外部删 .md 后 search_scoped 不返回（内部已对账）
        let pe = try XCTUnwrap(store.addEntry(scope: "global", projectId: nil,
                                              title: "对账幽灵条目", body: "对账幽灵条目的正文内容"))
        XCTAssertTrue(store.searchScoped("对账幽灵", scope: "global", projectId: pid,
                                         limit: 10, mode: "keyword").contains { $0.id == pe.id })
        try FileManager.default.removeItem(atPath: pe.filePath)
        XCTAssertFalse(store.searchScoped("对账幽灵", scope: "global", projectId: pid,
                                          limit: 10, mode: "keyword").contains { $0.id == pe.id })
    }

    // MARK: - 语义降级（无模型：semantic → keyword 兜底；hybrid = keyword）

    func testSemanticDegradeWithoutModel() throws {
        let e = try XCTUnwrap(store.addEntry(scope: "global", projectId: nil,
                                             title: "咖啡冲泡方法", body: "手冲咖啡需要控制水温在92度左右"))
        // semantic 无向量 → 降级关键词（hybridSearch 内建降级链）
        let sem = store.hybridSearch("咖啡", scope: "global", mode: "semantic")
        XCTAssertEqual(sem.map(\.id), [e.id], "无模型时 semantic 应降级为关键词检索")
        XCTAssertNil(sem.first?.score, "降级结果不带 score（keyword 口径）")
        // hybrid 无向量 → 关键词路
        let hyb = store.hybridSearch("咖啡", scope: "global", mode: "hybrid")
        XCTAssertEqual(hyb.map(\.id), [e.id])
        // 嵌入状态：不可用 + 0 覆盖
        let st = store.embeddingStatus()
        XCTAssertFalse(st.available)
        XCTAssertEqual(st.entriesEmbedded, 0)
    }

    // MARK: - T1 正常导入（test_a11_import_files.py T1；docx 改 .txt——OOXML W1 未覆盖）

    func testT1ImportBasic() throws {
        let srcDir = tmp.appendingPathComponent("user_files", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        let txt = srcDir.appendingPathComponent("笔记.txt")
        try "这是一段纯文本笔记内容，用于检索测试。".write(to: txt, atomically: false, encoding: .utf8)
        let md = srcDir.appendingPathComponent("说明.md")
        try "# 说明\n导入的 md 走纯文本解析（import 恒 _reindex_doc）。".write(to: md, atomically: false, encoding: .utf8)
        let r = store.importFiles(scope: "global", projectId: nil, sources: [txt.path, md.path])
        // T1a/b
        XCTAssertEqual(r.imported, 2)
        XCTAssertEqual(r.failed, 0); XCTAssertEqual(r.skipped, 0)
        // T1c 副本进全局知识目录
        let gdir = store.globalKnowledgeDir()
        XCTAssertTrue(FileManager.default.fileExists(atPath: gdir.appendingPathComponent("笔记.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: gdir.appendingPathComponent("说明.md").path))
        // T1d 源文件仍在原位
        XCTAssertTrue(FileManager.default.fileExists(atPath: txt.path))
        // T1e 标题=文件名 stem
        let titles = Set(store.listEntries(scope: "global").map(\.title))
        XCTAssertTrue(titles.isSuperset(of: ["笔记", "说明"]))
        // T1f source=='file'
        XCTAssertEqual(store.listEntries(scope: "global").filter {
            $0.source == NativeKnowledgeStore.sourceImportedFile
        }.count, 2)
        // 导入的 .md 是 'file' 而非 frontmatter 条目（import 恒走 _reindex_doc——行为对齐点）
        let mdEntry = store.listEntries(scope: "global").first { $0.title == "说明" }
        XCTAssertEqual(mdEntry?.source, "file")
        XCTAssertEqual(mdEntry?.id, NativeKnowledgeStore.fileEntryID(gdir.appendingPathComponent("说明.md")),
                       "uuid5 稳定 id（路径派生）")
    }

    // MARK: - T2/T3/T5 失败与跳过路径（test_a11_import_files.py）

    func testT2T3T5ImportFailures() throws {
        let srcDir = tmp.appendingPathComponent("user_files", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        // T2 目录+不存在 → failed==2
        let r2 = store.importFiles(scope: "global", projectId: nil,
                                   sources: [srcDir.path, srcDir.appendingPathComponent("不存在.pdf").path])
        XCTAssertEqual(r2.failed, 2); XCTAssertEqual(r2.imported, 0)
        XCTAssertEqual(r2.details.map(\.reason), Array(repeating: "不是文件或不存在", count: 2))
        // T3 不支持/解析失败 → skipped + 删副本不留垃圾 + 源文件不动
        let bad = srcDir.appendingPathComponent("乱码.bin")
        try Data((0...255).map { UInt8($0) }).write(to: bad)
        let gdir = store.globalKnowledgeDir()
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: gdir.path)) ?? [])
        let r3 = store.importFiles(scope: "global", projectId: nil, sources: [bad.path])
        XCTAssertEqual(r3.skipped, 1); XCTAssertEqual(r3.imported, 0)
        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: gdir.path)) ?? [])
        XCTAssertEqual(after, before, "知识目录无残留")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bad.path), "源文件未被删")
        // T5 无效作用域 → 全 failed
        let txt = srcDir.appendingPathComponent("笔记.txt")
        try "内容".write(to: txt, atomically: false, encoding: .utf8)
        let r5 = store.importFiles(scope: "bogus", projectId: nil, sources: [txt.path])
        XCTAssertEqual(r5.failed, 1); XCTAssertEqual(r5.imported, 0)
        XCTAssertEqual(r5.details.first?.reason, "无效的作用域或项目")
        XCTAssertEqual(r5.details.first?.name, txt.path, "无效作用域 details.name 用完整源路径（Python 口径）")
    }

    // MARK: - T4 同名冲突两趟链（test_a11_import_files.py T4 全策略）

    func testT4ImportConflictChain() throws {
        let gdir = store.globalKnowledgeDir()
        let srcDir = tmp.appendingPathComponent("user_files", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        let v1 = srcDir.appendingPathComponent("覆盖测试.txt")
        try "旧版正文：苹果香蕉樱桃。".write(to: v1, atomically: false, encoding: .utf8)
        XCTAssertEqual(store.importFiles(scope: "global", projectId: nil, sources: [v1.path]).imported, 1)
        // 第二份同名（不同目录）
        let other = srcDir.appendingPathComponent("另一份", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let v2 = other.appendingPathComponent("覆盖测试.txt")
        try "新版正文：榴莲山竹菠萝蜜。".write(to: v2, atomically: false, encoding: .utf8)

        // T4-ask：默认不碰旧文件，列入 conflicts
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: gdir.path))
        let rAsk = store.importFiles(scope: "global", projectId: nil, sources: [v2.path])
        XCTAssertEqual(rAsk.conflicts, ["覆盖测试.txt"])
        XCTAssertEqual(rAsk.imported, 0)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: gdir.path)), before)
        XCTAssertEqual(try String(contentsOf: gdir.appendingPathComponent("覆盖测试.txt"), encoding: .utf8),
                       "旧版正文：苹果香蕉樱桃。", "ask 不动旧文件")
        XCTAssertEqual(try String(contentsOf: v2, encoding: .utf8), "新版正文：榴莲山竹菠萝蜜。",
                       "ask 不动用户原始文件")
        XCTAssertEqual(rAsk.details.first?.status, "conflict")

        // T4-rename：改名并存（旧文件保留）
        let rRename = store.importFiles(scope: "global", projectId: nil, sources: [v2.path], onConflict: "rename")
        XCTAssertEqual(rRename.imported, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: gdir.appendingPathComponent("覆盖测试_1.txt").path))
        XCTAssertEqual(try String(contentsOf: gdir.appendingPathComponent("覆盖测试.txt"), encoding: .utf8),
                       "旧版正文：苹果香蕉樱桃。", "rename 不覆盖旧文件")
        XCTAssertEqual(rRename.details.first?.conflictResolved, "rename")

        // T4-skip：跳过
        let rSkip = store.importFiles(scope: "global", projectId: nil, sources: [v2.path], onConflict: "skip")
        XCTAssertEqual(rSkip.skipped, 1); XCTAssertEqual(rSkip.imported, 0)
        XCTAssertEqual(rSkip.details.first?.reason, "同名文件已存在，按你的选择跳过")

        // T4-overwrite：覆盖 + 旧 FTS/向量清除（T4k 回归点）
        let rOw = store.importFiles(scope: "global", projectId: nil, sources: [v2.path], onConflict: "overwrite")
        XCTAssertEqual(rOw.imported, 1)
        XCTAssertEqual(try String(contentsOf: gdir.appendingPathComponent("覆盖测试.txt"), encoding: .utf8),
                       "新版正文：榴莲山竹菠萝蜜。")
        let oid = NativeKnowledgeStore.fileEntryID(gdir.appendingPathComponent("覆盖测试.txt"))
        // 旧词「苹果」不再命中该条目；新词「榴莲」命中；entries 恰好 1 行（OR REPLACE 不重复）
        XCTAssertFalse(store.searchEntries("苹果", scope: "global").contains { $0.id == oid },
                       "overwrite 后旧正文不得残留（_purge_file_index 回归点）")
        XCTAssertTrue(store.searchEntries("榴莲", scope: "global").contains { $0.id == oid })
        let conn = try SQLiteConnection(path: store.indexDBPath, busyTimeoutMs: 1000)
        let dup = try conn.queryOne("SELECT COUNT(*) FROM knowledge_entries WHERE id=?", [.text(oid)])?
            .first?.intValue
        let ftsRows = try conn.queryOne("SELECT COUNT(*) FROM knowledge_fts WHERE entry_id=?", [.text(oid)])?
            .first?.intValue
        try conn.close()
        XCTAssertEqual(dup, 1)
        XCTAssertEqual(ftsRows, 1, "FTS 不得有旧行残留")

        // T4n 非法策略 → failed
        let rBad = store.importFiles(scope: "global", projectId: nil, sources: [v2.path], onConflict: "nonsense")
        XCTAssertEqual(rBad.failed, 1); XCTAssertEqual(rBad.imported, 0)
        XCTAssertEqual(rBad.details.first?.reason, "未知的冲突策略: nonsense")
    }

    // MARK: - T6/T7/T8 项目作用域/拉模式/数据安全（test_a11_import_files.py）

    func testT6T7T8ImportProjectScopeAndSafety() throws {
        let pdir = try XCTUnwrap(store.projectKnowledgeDir(pid))
        let srcDir = tmp.appendingPathComponent("user_files", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        let p = srcDir.appendingPathComponent("项目文档.txt")
        try "项目级知识内容。".write(to: p, atomically: false, encoding: .utf8)
        // T6 项目作用域导入到项目知识目录（非全局）
        let r6 = store.importFiles(scope: "project", projectId: pid, sources: [p.path])
        XCTAssertEqual(r6.imported, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pdir.appendingPathComponent("项目文档.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: store.globalKnowledgeDir().appendingPathComponent("项目文档.txt").path))
        // T7 拉模式：导入内容可被 FTS 检索（只进检索库，无注入副作用字段——
        //    Swift 结构体键集合即契约：imported/failed/skipped/conflicts/details）
        XCTAssertTrue(store.searchEntries("项目级知识", scope: "project", projectId: pid)
            .contains { $0.title == "项目文档" })
        // T8 删导入条目不 unlink 副本（source='file' 数据安全守卫）
        let ent = try XCTUnwrap(store.listEntries(scope: "project", projectId: pid)
            .first { $0.title == "项目文档" })
        let copy = ent.filePath
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy))
        XCTAssertTrue(store.deleteEntry(ent.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy),
                      "source='file' 删条目不 unlink（文件属用户）")
    }

    // MARK: - mtime 保留（copy2 语义：created_at 用文件 mtime）

    func testImportPreservesMtime() throws {
        let srcDir = tmp.appendingPathComponent("user_files", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        let f = srcDir.appendingPathComponent("旧文件.txt")
        try "旧 mtime 内容".write(to: f, atomically: false, encoding: .utf8)
        let old = Date(timeIntervalSince1970: 1_600_000_000)   // 2020-09-13
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: f.path)
        let r = store.importFiles(scope: "global", projectId: nil, sources: [f.path])
        XCTAssertEqual(r.imported, 1)
        let ent = try XCTUnwrap(store.listEntries(scope: "global").first { $0.title == "旧文件" })
        XCTAssertEqual(ent.createdAt, NativeKnowledgeStore.nowString(old),
                       "created_at 用文件 mtime（新→旧排序有意义）")
    }

    // MARK: - uuid5 口径（Python uuid.uuid5(NAMESPACE_URL, …) 对照向量）

    func testUUID5Parity() {
        // 真值由 CPython 3.11 生成：
        //   python3 -c "import uuid; print(uuid.uuid5(uuid.NAMESPACE_URL, 'knowledge-file:///tmp/x.txt'))"
        //   python3 -c "import uuid; print(uuid.uuid5(uuid.NAMESPACE_URL, 'knowledge-file:///数据根/knowledge/global/报告.txt'))"
        XCTAssertEqual(NativeKnowledgeStore.uuid5URL("knowledge-file:///tmp/x.txt"),
                       "cbf89971-79ad-51dc-8d79-097dc6005708")
        XCTAssertEqual(NativeKnowledgeStore.uuid5URL("knowledge-file:///数据根/knowledge/global/报告.txt"),
                       "44bb4ebb-70e6-546b-a609-c7260cb81d2f")
    }
}
