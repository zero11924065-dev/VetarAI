//
//  NativeKnowledgeStore.swift
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

//  逐函数移植两个只读行为规格源（subagent 仓，⛔ 不修改）：
//    · sidecar/knowledge/warehouse.py  —— 拉模式知识仓库（条目 CRUD / FTS5 关键词 /
//      语义 / RRF 混合检索 / 导入两趟冲突链 / 嵌入状态 / 重建索引 / 外部删除对账）
//    · sidecar/knowledge/store_knowledge.py —— 推模式知识库（项目 knowledge/*.md）与记忆
//
//  数据兼容红线（接管 ~/.subagent）：
//    · 索引库 = {data_root}/knowledge/index.db，三张表 schema 逐字对齐 warehouse.py
//      _ensure_schema（含旧 CHECK('chat','manual') 的整表重建迁移），侧车引擎的
//      search_knowledge 工具与原生内核可交叉读写同一库文件。
//    · 条目 .md frontmatter 文本格式逐字对齐 _entry_to_md / _parse_md。
//    · 嵌入 BLOB = float32 小端 1024 维（dense_to_blob 等价），round(6, half-to-even)。
//
//  嵌入索引兼容策略（任务书裁定 + pilot §5 阈值语义）：
//    CoreML FP16 与侧车 int8 向量空间等价（cos 0.978+）但数值不完全一致——原生内核
//    首次启用时自动重建嵌入索引：reembedForeignModelEntriesIfNeeded() 把 model 列 ≠
//    'bge-m3-coreml-fp16' 的行全部用 CoreML 重编码（原生模型不可用时**不动**旧向量，
//    语义检索整体降级为关键词，绝不 wiping 后留空）。由 NativeSidecarClient 知识路径
//    首次命中时触发（后台线程），测试可同步直调。
//
//  稀疏通道说明：CoreML 转换产物只含 dense 头（pilot §6.4，sparse/ColBERT 未迁移）
//    → 原生 semantic 评分 = 0.7*cos + 0.3*sparse_dot（查询侧 sparse 恒为空字典，
//    公式保留以对齐评分口径，稀疏项恒 0）。sparse 列原生写入 "{}"。
//
//  拉模式铁律（逐字保留）：本模块只把文本索引进 FTS/向量供检索，绝不自动注入上下文。
//

import Foundation
import CryptoKit

// MARK: - 契约行类型

/// 知识条目（warehouse.py get_entry/list_entries 的 dict 等价物）。
public struct NativeKnowledgeEntry: Equatable, Sendable {
    public var id: String
    public var title: String
    public var scope: String
    public var projectId: String
    public var category: String
    public var keywords: [String]
    public var source: String
    public var filePath: String
    public var createdAt: String
    /// get_entry / 检索结果才填（list_entries 无 body——对齐 Python 列表无 body 键）。
    public var body: String?
    /// hybrid/semantic 检索得分（keyword 无——对齐 Python 仅在两路带 score）。
    public var score: Double?
}

/// import_files 逐文件明细（details[] 元素）。
public struct NativeImportDetail: Equatable, Sendable {
    public var name: String
    public var status: String            // imported / skipped / failed / conflict
    public var reason: String?
    public var conflictResolved: String? // 撞名且用户选定策略时非空
}

/// import_files 返回结构（键集合 = imported/failed/skipped/conflicts/details——A11 T7b 契约）。
public struct NativeImportResult: Equatable, Sendable {
    public var imported = 0
    public var failed = 0
    public var skipped = 0
    public var conflicts: [String] = []
    public var details: [NativeImportDetail] = []
}

/// 知识分组（/api/knowledge/groups 行）。
public struct NativeKnowledgeGroup: Equatable, Sendable {
    public var scope: String
    public var projectId: String?
    public var projectName: String
    public var count: Int
    public var dir: String
}

public final class NativeKnowledgeStore: @unchecked Sendable {

    // ── 常量（warehouse.py 逐字）──
    public static let globalScope = "global"
    public static let projectScope = "project"
    /// 项目知识目录名（用户拍板：明目录不隐藏）。
    public static let projectDirName = "知识库"
    /// source='file'：用户导入的外部文件——删条目绝不 unlink（数据安全守卫，A10）。
    public static let sourceImportedFile = "file"
    /// 源文件字节上限（_KNOWLEDGE_MAX_SOURCE_BYTES：解析整读需内存保护阈值）。
    public static let maxSourceBytes = 20 * 1024 * 1024
    /// 索引正文字符上限（_KNOWLEDGE_MAX_INDEX_CHARS）。
    public static let maxIndexChars = 200_000
    /// 推模式注入上限（store_knowledge.py _KNOWLEDGE_MAX_CHARS_EACH/TOTAL、_MEMORY_MAX_CHARS）。
    public static let knowledgeMaxCharsEach = 4000
    public static let knowledgeMaxCharsTotal = 12000
    public static let memoryMaxChars = 4000
    /// 禁止事项行首关键词（3.14：100% 拦截红线区）。
    public static let prohibitionPrefixes = ["禁止", "不得", "不允许", "严禁"]

    public let dataRoot: URL
    /// 项目清单来源（同一数据根的 _global.db；working_dir 解析依赖）。
    public let database: NativeDatabase
    public let embedder: NativeEmbedder
    public var log: (String) -> Void

    /// 写锁（对齐 Python 模块级无锁+连接随开随关——Swift 侧串行化 FTS/向量多表写入）。
    private let writeLock = NSLock()

    public init(dataRoot: URL, database: NativeDatabase, embedder: NativeEmbedder,
                log: @escaping (String) -> Void = { _ in }) {
        self.dataRoot = dataRoot
        self.database = database
        self.embedder = embedder
        self.log = log
    }

    // ════════════════════════════════════════════════════════════
    // MARK: - 目录（warehouse.py global_knowledge_dir / project_knowledge_dir / scope_dir）
    // ════════════════════════════════════════════════════════════

    /// 全局知识目录 {data_root}/knowledge/global/（mkdir 副作用对齐）。
    public func globalKnowledgeDir() -> URL {
        let p = dataRoot.appendingPathComponent("knowledge/global", isDirectory: true)
        try? FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
        return p
    }

    /// 项目知识目录 = 项目工作目录/知识库/；项目不存在 → nil。
    public func projectKnowledgeDir(_ projectId: String) -> URL? {
        guard let proj = try? database.getProject(projectId), !proj.workingDir.isEmpty else { return nil }
        let p = URL(fileURLWithPath: proj.workingDir).appendingPathComponent(Self.projectDirName, isDirectory: true)
        try? FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
        return p
    }

    public func scopeDir(_ scope: String, _ projectId: String?) -> URL? {
        if scope == Self.globalScope { return globalKnowledgeDir() }
        if scope == Self.projectScope, let projectId, !projectId.isEmpty {
            return projectKnowledgeDir(projectId)
        }
        return nil
    }

    // ════════════════════════════════════════════════════════════
    // MARK: - 索引库（_index_db_path / _ensure_schema / _iconn）
    // ════════════════════════════════════════════════════════════

    public var indexDBPath: String {
        dataRoot.appendingPathComponent("knowledge/index.db").path
    }

    /// _ensure_schema 逐字（含 A10 旧 CHECK 约束整表重建迁移：保留现有行）。
    private func ensureSchema(_ conn: SQLiteConnection) throws {
        if let sql = try conn.tableSQL("knowledge_entries"),
           sql.replacingOccurrences(of: " ", with: "").contains("'chat','manual'") {
            try conn.execScript("""
                PRAGMA foreign_keys=off;
                BEGIN;
                CREATE TABLE knowledge_entries_new (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    scope TEXT NOT NULL CHECK(scope IN ('project','global')),
                    project_id TEXT,
                    category TEXT,
                    keywords TEXT,
                    source TEXT NOT NULL DEFAULT 'chat' CHECK(source IN ('chat','manual','file')),
                    file_path TEXT NOT NULL,
                    created_at TEXT NOT NULL
                );
                INSERT INTO knowledge_entries_new
                    SELECT id, title, scope, project_id, category, keywords, source,
                           file_path, created_at FROM knowledge_entries;
                DROP TABLE knowledge_entries;
                ALTER TABLE knowledge_entries_new RENAME TO knowledge_entries;
                CREATE INDEX IF NOT EXISTS idx_ke_scope ON knowledge_entries(scope, project_id);
                COMMIT;
                PRAGMA foreign_keys=on;
            """)
        }
        try conn.execScript("""
            CREATE TABLE IF NOT EXISTS knowledge_entries (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                scope TEXT NOT NULL CHECK(scope IN ('project','global')),
                project_id TEXT,
                category TEXT,
                keywords TEXT,
                source TEXT NOT NULL DEFAULT 'chat' CHECK(source IN ('chat','manual','file')),
                file_path TEXT NOT NULL,
                created_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_ke_scope ON knowledge_entries(scope, project_id);
            CREATE VIRTUAL TABLE IF NOT EXISTS knowledge_fts USING fts5(
                entry_id UNINDEXED, title, keywords, body
            );
            CREATE TABLE IF NOT EXISTS knowledge_embeddings (
                entry_id TEXT PRIMARY KEY,
                dense BLOB,
                sparse TEXT,
                model TEXT NOT NULL DEFAULT 'bge-m3-onnx-int8',
                updated_at TEXT NOT NULL
            );
        """)
    }

    /// _iconn：父目录 mkdir + open（busy 10s，对齐 sqlite3.connect(timeout=10.0)）。
    private func openIndex() throws -> SQLiteConnection {
        let path = indexDBPath
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let conn = try SQLiteConnection(path: path, busyTimeoutMs: 10_000)
        try ensureSchema(conn)
        return conn
    }

    /// 读连接：必关闭（Python try/finally conn.close()）。
    private func withReadConn<T>(_ body: (SQLiteConnection) throws -> T) throws -> T {
        let conn = try openIndex()
        defer { try? conn.close() }
        return try body(conn)
    }

    /// 写连接：锁内显式事务，成功 commit / 异常 rollback / 必 close。
    @discardableResult
    private func withWriteConn<T>(_ body: (SQLiteConnection) throws -> T) throws -> T {
        writeLock.lock()
        defer { writeLock.unlock() }
        let conn = try openIndex()
        do {
            try conn.begin()
            let result = try body(conn)
            try conn.commit()
            try? conn.close()
            return result
        } catch {
            try? conn.rollback()
            try? conn.close()
            throw error
        }
    }

    // MARK: - 小工具（Python 语义等价物）

    /// datetime.now().strftime("%Y-%m-%d %H:%M:%S")（本地时区）。
    static func nowString(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }

    /// json.dumps(keywords, ensure_ascii=False)（紧凑分隔含空格——Python 默认 separators）。
    static func dumpsKeywords(_ kw: [String]) -> String {
        NativeDatabase.dumpsUTF8(.array(kw.map { .string($0) }))
    }

    /// 宽容 json.loads → [String]（失败/非数组 → []，对齐 get_entry/list_entries）。
    static func loadKeywords(_ text: String?) -> [String] {
        guard let text, !text.isEmpty,
              case .array(let arr) = NativeDatabase.tolerantJSON(text) else { return [] }
        return arr.compactMap { $0.string }
    }

    /// str(uuid.uuid4())（小写连字符——UUID().uuidString 是大写，必须降格）。
    static func newUUID() -> String { UUID().uuidString.lowercased() }

    /// uuid.uuid5(NAMESPACE_URL, name)（SHA-1 变体；uuid5 稳定 id 供 _reindex_doc/_purge_file_index）。
    public static func uuid5URL(_ name: String) -> String {
        // uuid.NAMESPACE_URL = 6ba7b811-9dad-11d1-80b4-00c04fd430c8
        let ns: [UInt8] = [0x6b, 0xa7, 0xb8, 0x11, 0x9d, 0xad, 0x11, 0xd1,
                           0x80, 0xb4, 0x00, 0xc0, 0x4f, 0xd4, 0x30, 0xc8]
        var bytes = Array(Insecure.SHA1.hash(data: Data(ns) + Data(name.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50   // version 5
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // RFC 4122 variant
        let h = bytes.map { String(format: "%02x", $0) }.joined()
        return "\(h.prefix(8))-\(h.dropFirst(8).prefix(4))-\(h.dropFirst(12).prefix(4))-\(h.dropFirst(16).prefix(4))-\(h.dropFirst(20))"
    }

    /// 导入文件条目的稳定 id（_reindex_doc/_purge_file_index 同源：
    /// uuid5(URL, "knowledge-file://" + fpath.resolve())）。
    static func fileEntryID(_ path: URL) -> String {
        uuid5URL("knowledge-file://" + NativeConfigStore.resolvePath(path).path)
    }

    /// Python str.isalnum()（Unicode 字母/数字各类别）近似：逐 scalar 判 L*/N*。
    private static func isPyAlnum(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { s in
            switch s.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter,
                 .otherLetter, .decimalNumber, .letterNumber, .otherNumber:
                return true
            default: return false
            }
        }
    }

    // ════════════════════════════════════════════════════════════
    // MARK: - .md 条目读写（_entry_to_md / _parse_md 逐字）
    // ════════════════════════════════════════════════════════════

    /// _entry_to_md：frontmatter + 正文（行序/键序逐字；keywords JSON ensure_ascii=False）。
    public static func entryToMarkdown(id: String, title: String, scope: String,
                                       projectId: String, category: String,
                                       keywords: [String], source: String,
                                       createdAt: String, body: String) -> String {
        let lines = [
            "---",
            "id: \(id)",
            "title: \(title)",
            "scope: \(scope)",
            "project_id: \(projectId)",
            "category: \(category)",
            "keywords: \(dumpsKeywords(keywords))",
            "source: \(source)",
            "created_at: \(createdAt)",
            "---",
            "",
            body,
        ]
        return lines.joined(separator: "\n")
    }

    /// _parse_md：返回 (frontmatter dict, 正文)。无 frontmatter → (空, 全文)。
    /// keywords 值先试 JSON 再逗号切（对齐 json.loads 失败回退）。
    public static func parseMarkdown(_ text: String) -> (meta: [String: String], keywords: [String], body: String) {
        guard text.hasPrefix("---") else { return ([:], [], text) }
        let lines = text.components(separatedBy: "\n")
        var end = -1
        for i in 1..<lines.count where lines[i].trimmingCharacters(in: .whitespaces) == "---" {
            end = i
            break
        }
        guard end >= 0 else { return ([:], [], text) }
        var meta: [String: String] = [:]
        var keywords: [String] = []
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let v = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if k == "keywords" {
                if case .array(let arr) = NativeDatabase.tolerantJSON(v) {
                    keywords = arr.compactMap { $0.string }
                } else {
                    keywords = v.split(separator: ",").map {
                        $0.trimmingCharacters(in: .whitespaces)
                    }.filter { !$0.isEmpty }
                }
            } else {
                meta[k] = v
            }
        }
        var body = lines[(end + 1)...].joined(separator: "\n")
        while body.hasPrefix("\n") { body.removeFirst() }   // lstrip("\n")（仅去换行，不去空格）
        return (meta, keywords, body)
    }

    // ════════════════════════════════════════════════════════════
    // MARK: - 条目 CRUD（add_entry / get_entry / list_entries / delete_entry）
    // ════════════════════════════════════════════════════════════

    /// add_entry：写 .md + 写索引 + 嵌入（模型不可用静默降级，不阻塞创建）。
    /// 文件写失败/作用域无效 → nil。
    @discardableResult
    public func addEntry(scope: String, projectId: String?, title: String, body: String,
                         category: String = "", keywords: [String] = [],
                         source: String = "chat") -> NativeKnowledgeEntry? {
        guard let kdir = scopeDir(scope, projectId) else { return nil }
        let entryId = Self.newUUID()
        let createdAt = Self.nowString()
        let entry = NativeKnowledgeEntry(
            id: entryId, title: title.isEmpty ? "未命名" : title, scope: scope,
            projectId: projectId ?? "", category: category, keywords: keywords,
            source: source, filePath: "", createdAt: createdAt, body: body)
        // 文件名：标题安全化（isalnum ∪ " _-（）()"）+ strip + 前 20 字符 + id 前 8 位
        let safeTitle = String((title).filter { Self.isPyAlnum($0) || " _-（）()".contains($0) }
            .trimmingCharacters(in: .whitespaces).prefix(20))
        let fname = "\(safeTitle.isEmpty ? "条目" : safeTitle)-\(entryId.prefix(8)).md"
        let fpath = kdir.appendingPathComponent(fname)
        let md = Self.entryToMarkdown(id: entryId, title: entry.title, scope: scope,
                                      projectId: projectId ?? "", category: category,
                                      keywords: keywords, source: source,
                                      createdAt: createdAt, body: body)
        do {
            try md.write(to: fpath, atomically: false, encoding: .utf8)
        } catch {
            return nil   // OSError 等价
        }
        do {
            try withWriteConn { conn in
                try conn.execute(
                    "INSERT INTO knowledge_entries (id, title, scope, project_id, category, keywords, source, file_path, created_at) VALUES (?,?,?,?,?,?,?,?,?)",
                    [.text(entryId), .text(entry.title), .text(scope), .text(projectId ?? ""),
                     .text(category), .text(Self.dumpsKeywords(keywords)), .text(source),
                     .text(fpath.path), .text(createdAt)])
                try conn.execute(
                    "INSERT INTO knowledge_fts (entry_id, title, keywords, body) VALUES (?,?,?,?)",
                    [.text(entryId), .text(NativeSearchTokenizer.tokenize(entry.title)),
                     .text(NativeSearchTokenizer.tokenize(keywords.joined(separator: " "))),
                     .text(NativeSearchTokenizer.tokenize(body))])
            }
        } catch {
            log("知识条目索引写入失败: \(error.localizedDescription)")
        }
        // 阶段二：语义向量编码（静默降级）
        embedEntry(entryId: entryId, title: entry.title, body: body, keywords: keywords)
        var out = entry
        out.filePath = fpath.path
        return out
    }

    /// get_entry：索引行 + 正文（source='file' 走解析器路径；损坏/已删 → 空正文不崩）。
    public func getEntry(_ entryId: String) -> NativeKnowledgeEntry? {
        let row: [SQLiteValue]?
        do {
            row = try withReadConn { conn in
                try conn.queryOne(
                    "SELECT id, title, scope, project_id, category, keywords, source, file_path, created_at FROM knowledge_entries WHERE id = ?",
                    [.text(entryId)])
            }
        } catch {
            log("知识条目读取失败: \(error.localizedDescription)")
            return nil
        }
        guard let row else { return nil }
        let filePath = row[7].textValue ?? ""
        var entry = NativeKnowledgeEntry(
            id: row[0].textValue ?? "", title: row[1].textValue ?? "",
            scope: row[2].textValue ?? "", projectId: row[3].textValue ?? "",
            category: row[4].textValue ?? "", keywords: Self.loadKeywords(row[5].textValue),
            source: row[6].textValue ?? "", filePath: filePath,
            createdAt: row[8].textValue ?? "")
        let fp = URL(fileURLWithPath: filePath)
        if entry.source == Self.sourceImportedFile {
            // A10 分流：导入的二进制/文档走解析器（同源于 _reindex_doc），损坏 → 空正文
            if let raw = try? Data(contentsOf: fp) {
                entry.body = NativeDocParser.parse(name: fp.lastPathComponent, raw: raw)
                    .map { String($0.prefix(Self.maxIndexChars)) } ?? ""
            } else {
                entry.body = ""
            }
        } else {
            if let text = try? String(contentsOf: fp, encoding: .utf8) {
                entry.body = Self.parseMarkdown(text).body
            } else {
                entry.body = ""   // OSError / UnicodeDecodeError 等价
            }
        }
        return entry
    }

    /// list_entries：新→旧（created_at DESC, rowid DESC）；scope/project 过滤。
    public func listEntries(scope: String? = nil, projectId: String? = nil) -> [NativeKnowledgeEntry] {
        do {
            return try withReadConn { conn in
                let cols = "id, title, scope, project_id, category, keywords, source, file_path, created_at"
                let rows: [[SQLiteValue]]
                if let scope, let projectId {
                    rows = try conn.query(
                        "SELECT \(cols) FROM knowledge_entries WHERE scope=? AND project_id=? ORDER BY created_at DESC, rowid DESC",
                        [.text(scope), .text(projectId)])
                } else if let scope {
                    rows = try conn.query(
                        "SELECT \(cols) FROM knowledge_entries WHERE scope=? ORDER BY created_at DESC, rowid DESC",
                        [.text(scope)])
                } else {
                    rows = try conn.query(
                        "SELECT \(cols) FROM knowledge_entries ORDER BY created_at DESC, rowid DESC")
                }
                return rows.map { r in
                    NativeKnowledgeEntry(
                        id: r[0].textValue ?? "", title: r[1].textValue ?? "",
                        scope: r[2].textValue ?? "", projectId: r[3].textValue ?? "",
                        category: r[4].textValue ?? "", keywords: Self.loadKeywords(r[5].textValue),
                        source: r[6].textValue ?? "", filePath: r[7].textValue ?? "",
                        createdAt: r[8].textValue ?? "")
                }
            }
        } catch {
            log("知识条目列表失败: \(error.localizedDescription)")
            return []
        }
    }

    /// delete_entry：删索引三表；source='file' 绝不 unlink（文件属用户，A10 数据安全守卫）。
    /// 'chat'/'manual' 条目删文件（本模块生成的 .md，删条目=删本体）。
    @discardableResult
    public func deleteEntry(_ entryId: String) -> Bool {
        let entry = getEntry(entryId)
        do {
            try withWriteConn { conn in
                try conn.execute("DELETE FROM knowledge_entries WHERE id = ?", [.text(entryId)])
                try conn.execute("DELETE FROM knowledge_fts WHERE entry_id = ?", [.text(entryId)])
                try conn.execute("DELETE FROM knowledge_embeddings WHERE entry_id = ?", [.text(entryId)])
            }
        } catch {
            log("知识条目删除失败: \(error.localizedDescription)")
        }
        if let entry, !entry.filePath.isEmpty, entry.source != Self.sourceImportedFile {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: entry.filePath))
        }
        return entry != nil
    }

    // ════════════════════════════════════════════════════════════
    // MARK: - 关键词检索（search_entries：FTS5 + bm25）
    // ════════════════════════════════════════════════════════════

    /// search_entries：分词后 OR 查询（任一命中即返回），bm25 升序（越小越相关）。
    /// FTS 语法异常（如全是标点）→ 空结果（OperationalError 等价）。
    public func searchEntries(_ query: String, scope: String? = nil,
                              projectId: String? = nil, limit: Int = 20) -> [NativeKnowledgeEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let qTok = NativeSearchTokenizer.tokenize(q)
        let terms = qTok.split(separator: " ").map { "\"\($0)\"" }
        guard !terms.isEmpty else { return [] }
        let matchExpr = terms.joined(separator: " OR ")
        do {
            let ids: [String] = try withReadConn { conn in
                var sql = "SELECT f.entry_id, bm25(knowledge_fts) AS score FROM knowledge_fts f WHERE knowledge_fts MATCH ? "
                var params: [SQLiteValue] = [.text(matchExpr)]
                if let scope {
                    sql += "AND f.entry_id IN (SELECT id FROM knowledge_entries WHERE scope=? "
                    params.append(.text(scope))
                    if let projectId {
                        sql += "AND project_id=? "
                        params.append(.text(projectId))
                    }
                    sql += ") "
                }
                sql += "ORDER BY score LIMIT ?"
                params.append(.integer(Int64(limit)))
                // FTS 语法异常 → SQLiteError（对齐 sqlite3.OperationalError → []）
                return try conn.query(sql, params).compactMap { $0[0].textValue }
            }
            return ids.compactMap { getEntry($0) }
        } catch {
            return []
        }
    }

    // ════════════════════════════════════════════════════════════
    // MARK: - 语义/混合检索（semantic_search / hybrid_search）
    // ════════════════════════════════════════════════════════════

    /// _scope_entry_ids：作用域过滤的 id 集合；无过滤 → nil。
    private func scopeEntryIDs(_ scope: String?, _ projectId: String?) -> Set<String>? {
        guard let scope else { return nil }
        do {
            return try withReadConn { conn in
                let rows: [[SQLiteValue]]
                if let projectId {
                    rows = try conn.query(
                        "SELECT id FROM knowledge_entries WHERE scope=? AND project_id=?",
                        [.text(scope), .text(projectId)])
                } else {
                    rows = try conn.query(
                        "SELECT id FROM knowledge_entries WHERE scope=?", [.text(scope)])
                }
                return Set(rows.compactMap { $0[0].textValue })
            }
        } catch {
            return []
        }
    }

    /// semantic_search：bge-m3 稠密余弦 + 稀疏点积加权融合。
    /// 模型/向量不可用 → 空列表（上层决定降级）。评分 = 0.7*cos + 0.3*min(sparse_dot,1)
    /// （原生查询侧 sparse 恒空 → 稀疏项恒 0，见文件头「稀疏通道说明」）。
    public func semanticSearch(_ query: String, scope: String? = nil,
                               projectId: String? = nil, limit: Int = 20) -> [NativeKnowledgeEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        guard embedder.modelAvailable() else { return [] }
        guard let qDense = embedder.encodeOneOrNil(q, withQueryInstruction: true) else { return [] }
        let qSparse: [String: Double] = [:]   // CoreML 未转 sparse 头（pilot §6.4）
        let allowed = scopeEntryIDs(scope, projectId)
        let rows: [[SQLiteValue]]
        do {
            rows = try withReadConn { conn in
                try conn.query("SELECT entry_id, dense, sparse FROM knowledge_embeddings")
            }
        } catch {
            return []
        }
        var scored: [(score: Double, eid: String, ord: Int)] = []
        for (ord, r) in rows.enumerated() {
            guard let eid = r[0].textValue else { continue }
            if let allowed, !allowed.contains(eid) { continue }
            guard let denseBlob = r[1].blobValue, !denseBlob.isEmpty else { continue }
            let dDense = NativeEmbedder.blobToDense(denseBlob)
            let cos = NativeEmbedder.cosine(qDense, dDense)
            var dSparse: [String: Double] = [:]
            if case .object(let obj) = NativeDatabase.tolerantJSON(r[2].textValue ?? "") {
                dSparse = obj.compactMapValues { v -> Double? in
                    switch v { case .double(let d): return d
                               case .int(let i): return Double(i)
                               default: return nil }
                }
            }
            let sp = NativeEmbedder.sparseDot(qSparse, dSparse)
            scored.append((0.7 * cos + 0.3 * min(sp, 1.0), eid, ord))
        }
        // Python scored.sort(key=-score) 稳定排序：同分保持 SELECT 行序（ord 决胜）
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.ord < $1.ord }
        return scored.prefix(limit).compactMap { item in
            guard var e = getEntry(item.eid) else { return nil }
            // Python round(float(score), 4)
            e.score = (item.score * 10000).rounded(.toNearestOrEven) / 10000
            return e
        }
    }

    /// hybrid_search 统一检索入口：
    ///   mode="keyword"  → 纯关键词（FTS5，兼容旧行为）
    ///   mode="semantic" → 纯语义；向量不可用自动降级为关键词
    ///   mode="hybrid"   → 两路 RRF 融合（k=60）；任一路缺失即用另一路
    public func hybridSearch(_ query: String, scope: String? = nil, projectId: String? = nil,
                             limit: Int = 20, mode: String = "hybrid") -> [NativeKnowledgeEntry] {
        if mode == "keyword" {
            return searchEntries(query, scope: scope, projectId: projectId, limit: limit)
        }
        let sem = semanticSearch(query, scope: scope, projectId: projectId, limit: limit * 2)
        if mode == "semantic" {
            if !sem.isEmpty { return sem }
            return searchEntries(query, scope: scope, projectId: projectId, limit: limit)  // 降级
        }
        let kw = searchEntries(query, scope: scope, projectId: projectId, limit: limit * 2)
        if sem.isEmpty { return Array(kw.prefix(limit)) }
        if kw.isEmpty { return Array(sem.prefix(limit)) }
        // RRF：Python dict 保插入序 + sort 稳定 → 同分先看关键词路（先插入者）
        var rrf: [String: (score: Double, ord: Int)] = [:]
        var nextOrd = 0
        for (rank, e) in kw.enumerated() {
            rrf[e.id] = ((rrf[e.id]?.score ?? 0.0) + 1.0 / (60.0 + Double(rank + 1)),
                         rrf[e.id]?.ord ?? { let o = nextOrd; nextOrd += 1; return o }())
        }
        for (rank, e) in sem.enumerated() {
            rrf[e.id] = ((rrf[e.id]?.score ?? 0.0) + 1.0 / (60.0 + Double(rank + 1)),
                         rrf[e.id]?.ord ?? { let o = nextOrd; nextOrd += 1; return o }())
        }
        let order = rrf.sorted { a, b in
            a.value.score != b.value.score ? a.value.score > b.value.score : a.value.ord < b.value.ord
        }.prefix(limit)
        return order.compactMap { (eid, v) in
            guard var e = getEntry(eid) else { return nil }
            // Python round(float(score), 6)
            e.score = (v.score * 1_000_000).rounded(.toNearestOrEven) / 1_000_000
            return e
        }
    }

    /// prune_missing：索引与磁盘对账（文件是本体，索引单向跟随）。返回清除条数。
    @discardableResult
    public func pruneMissing() -> Int {
        do {
            return try withWriteConn { conn in
                let rows = try conn.query("SELECT id, file_path FROM knowledge_entries")
                let missing = rows.filter { r in
                    guard let fp = r[1].textValue else { return true }
                    return !FileManager.default.fileExists(atPath: fp)
                }
                for r in missing {
                    let rid = r[0].textValue ?? ""
                    try conn.execute("DELETE FROM knowledge_entries WHERE id = ?", [.text(rid)])
                    try conn.execute("DELETE FROM knowledge_fts WHERE entry_id = ?", [.text(rid)])
                    try conn.execute("DELETE FROM knowledge_embeddings WHERE entry_id = ?", [.text(rid)])
                }
                return missing.count
            }
        } catch {
            log("知识索引对账失败: \(error.localizedDescription)")
            return 0
        }
    }

    /// search_scoped（B9-2/R4-S3 收敛的检索编排单一实现）：
    /// scope/mode 默认 → limit clamp(1,20) → prune_missing 对账 → 三分支 → all 合并按分降序截断。
    /// （引擎工具路径，非 HTTP 端点——面板端点走 hybridSearch + 1~100 clamp。）
    public func searchScoped(_ query: String, scope: String = "all", projectId: String? = nil,
                             limit: Int = 5, mode: String = "hybrid") -> [NativeKnowledgeEntry] {
        let scope = scope.trimmingCharacters(in: .whitespaces)
        let mode = mode.trimmingCharacters(in: .whitespaces)
        let limit = max(1, min(limit, 20))
        // K-1 外部删除对账：Finder 删 .md 后索引不留幽灵条目
        pruneMissing()
        let pid = projectId
        if scope == Self.projectScope {
            return hybridSearch(query, scope: Self.projectScope, projectId: pid, limit: limit, mode: mode)
        }
        if scope == Self.globalScope {
            return hybridSearch(query, scope: Self.globalScope, projectId: nil, limit: limit, mode: mode)
        }
        // all：两作用域合并取分高者（keyword 模式无 score 按 0——与原行为一致；
        // Python sorted 稳定 → 同分保持 h1 前 h2 后，Swift sorted 不保证稳定，显式决胜）
        let h1 = hybridSearch(query, scope: Self.projectScope, projectId: pid, limit: limit, mode: mode)
        let h2 = hybridSearch(query, scope: Self.globalScope, projectId: nil, limit: limit, mode: mode)
        return (h1 + h2).enumerated().sorted { a, b in
            let sa = a.element.score ?? 0, sb = b.element.score ?? 0
            return sa != sb ? sa > sb : a.offset < b.offset
        }.prefix(limit).map { $0.element }
    }

    // ════════════════════════════════════════════════════════════
    // MARK: - 嵌入挂钩与索引兼容策略（_embed_entry / reembedForeignModelEntriesIfNeeded）
    // ════════════════════════════════════════════════════════════

    /// _embed_entry：编码文本 = 标题 + 关键词 + 正文（正文是知识主体，标题补语义锚点）。
    /// 模型不可用/编码失败 → 静默跳过（检索降级为纯关键词）。返回是否写入向量。
    @discardableResult
    private func embedEntry(entryId: String, title: String, body: String, keywords: [String]) -> Bool {
        guard embedder.modelAvailable() else { return false }
        var parts: [String] = []
        if !title.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(title.trimmingCharacters(in: .whitespaces)) }
        if !keywords.isEmpty {
            parts.append(keywords.map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.joined(separator: " "))
        }
        if !body.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(body.trimmingCharacters(in: .whitespaces)) }
        let text = parts.joined(separator: "\n")
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard let dense = embedder.encodeOneOrNil(text) else { return false }
        do {
            try withWriteConn { conn in
                try conn.execute(
                    "INSERT OR REPLACE INTO knowledge_embeddings (entry_id, dense, sparse, model, updated_at) VALUES (?,?,?,?,?)",
                    [.text(entryId), .blob(NativeEmbedder.denseToBlob(dense)),
                     .text("{}"), .text(NativeEmbedder.modelID), .text(Self.nowString())])
            }
            return true
        } catch {
            log("嵌入向量写入失败: \(error.localizedDescription)")
            return false
        }
    }

    /// 嵌入索引兼容策略（任务书裁定：原生内核首次启用时自动重建嵌入索引）。
    /// 把 model ≠ 原生标识的行（侧车 int8 遗留）用 CoreML 重编码；原生模型不可用 → 不动旧向量。
    /// 返回重编码行数（0 = 已是原生向量或无需处理）。
    @discardableResult
    public func reembedForeignModelEntriesIfNeeded() -> Int {
        guard embedder.modelAvailable() else { return 0 }
        let stale: [String]
        do {
            stale = try withReadConn { conn in
                try conn.query(
                    "SELECT entry_id FROM knowledge_embeddings WHERE model != ?",
                    [.text(NativeEmbedder.modelID)]).compactMap { $0[0].textValue }
            }
        } catch {
            return 0
        }
        guard !stale.isEmpty else { return 0 }
        log("嵌入索引兼容：检测到 \(stale.count) 行侧车 int8 向量，用 CoreML 重编码（\(NativeEmbedder.modelID)）")
        var n = 0
        for eid in stale {
            guard let e = getEntry(eid) else { continue }
            if embedEntry(entryId: eid, title: e.title, body: e.body ?? "", keywords: e.keywords) {
                n += 1
            }
        }
        return n
    }

    // ════════════════════════════════════════════════════════════
    // MARK: - 重建索引（rebuild_index / _reindex_file / _reindex_md / _reindex_doc）
    // ════════════════════════════════════════════════════════════

    /// _iter_indexable：目录顶层可索引文件（.md + INDEXABLE_DOC_EXTS），非递归、按名排序
    /// （知识目录是用户明目录约定平铺；递归会吞用户子目录——对齐 A10 注释口径）。
    private func iterIndexable(_ kdir: URL) -> [URL] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: kdir, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        let allowed = NativeDocParser.indexableDocExts.union([".md"])
        return items.filter { url in
            let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
            return isFile && allowed.contains("." + url.pathExtension.lowercased())
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// rebuild_index：清空三表 → 全局 + 各项目目录全量重索引。返回条目数。
    /// 拉模式铁律：只索引供检索，绝不自动注入上下文。
    /// （CPU 密集：调用方须放后台线程——对齐 app.py run_in_executor 口径。）
    @discardableResult
    public func rebuildIndex() -> Int {
        do {
            try withWriteConn { conn in
                try conn.execute("DELETE FROM knowledge_entries")
                try conn.execute("DELETE FROM knowledge_fts")
                try conn.execute("DELETE FROM knowledge_embeddings")
            }
        } catch {
            log("重建索引清表失败: \(error.localizedDescription)")
        }
        var count = 0
        for f in iterIndexable(globalKnowledgeDir()) {
            if reindexFile(f, scope: Self.globalScope, projectId: "") { count += 1 }
        }
        let projects = (try? database.listProjectRows()) ?? []
        for proj in projects {
            let wd = proj["working_dir"] ?? ""
            guard !wd.isEmpty else { continue }
            let kdir = URL(fileURLWithPath: wd).appendingPathComponent(Self.projectDirName, isDirectory: true)
            for f in iterIndexable(kdir) {
                if reindexFile(f, scope: Self.projectScope, projectId: proj["id"] ?? "") { count += 1 }
            }
        }
        return count
    }

    /// _reindex_file：.md 走 frontmatter 路径，其余走解析器路径（A10）。
    private func reindexFile(_ fpath: URL, scope: String, projectId: String) -> Bool {
        if fpath.pathExtension.lowercased() == "md" {
            return reindexMd(fpath, scope: scope, projectId: projectId)
        }
        return reindexDoc(fpath, scope: scope, projectId: projectId)
    }

    /// _reindex_md：行为与 A10 改造前逐字一致（frontmatter id 或 uuid4；普通 INSERT FTS）。
    private func reindexMd(_ fpath: URL, scope: String, projectId: String) -> Bool {
        guard let text = try? String(contentsOf: fpath, encoding: .utf8) else { return false }
        let (meta, kw, body) = Self.parseMarkdown(text)
        let entryId = meta["id"].flatMap { $0.isEmpty ? nil : $0 } ?? Self.newUUID()
        let title = meta["title"].flatMap { $0.isEmpty ? nil : $0 } ?? fpath.deletingPathExtension().lastPathComponent
        do {
            try withWriteConn { conn in
                try conn.execute(
                    "INSERT OR REPLACE INTO knowledge_entries (id, title, scope, project_id, category, keywords, source, file_path, created_at) VALUES (?,?,?,?,?,?,?,?,?)",
                    [.text(entryId), .text(title), .text(scope),
                     // Python `meta.get("project_id") or project_id or ""`：空串同 nil 回退
                     .text(meta["project_id"].flatMap { $0.isEmpty ? nil : $0 } ?? projectId),
                     .text(meta["category"] ?? ""),
                     .text(Self.dumpsKeywords(kw)),
                     .text(meta["source"].flatMap { $0.isEmpty ? nil : $0 } ?? "manual"),
                     .text(fpath.path), .text(meta["created_at"] ?? "")])
                try conn.execute(
                    "INSERT INTO knowledge_fts (entry_id, title, keywords, body) VALUES (?,?,?,?)",
                    [.text(entryId), .text(NativeSearchTokenizer.tokenize(meta["title"] ?? "")),
                     .text(NativeSearchTokenizer.tokenize(kw.joined(separator: " "))),
                     .text(NativeSearchTokenizer.tokenize(body))])
            }
        } catch {
            log("md 重索引失败 \(fpath.lastPathComponent): \(error.localizedDescription)")
            return false
        }
        embedEntry(entryId: entryId, title: meta["title"] ?? "", body: body, keywords: kw)
        return true
    }

    /// _reindex_doc：外部文档索引（标题=文件名 stem；uuid5 稳定 id；source='file'；
    /// created_at=文件 mtime）。解析不出文本（损坏/加密/扫描件/OOXML-W1 未覆盖）→ false；
    /// 超大文件跳过不阻塞整次重建。
    private func reindexDoc(_ fpath: URL, scope: String, projectId: String) -> Bool {
        let size: Int
        do {
            size = Int(try FileManager.default.attributesOfItem(atPath: fpath.path)[.size] as? Int64 ?? 0)
        } catch {
            return false
        }
        guard size > 0 && size <= Self.maxSourceBytes else { return false }
        guard let raw = try? Data(contentsOf: fpath) else { return false }
        guard let text = NativeDocParser.parse(name: fpath.lastPathComponent, raw: raw),
              !text.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        let body = String(text.prefix(Self.maxIndexChars))
        let entryId = Self.fileEntryID(fpath)
        let title = fpath.deletingPathExtension().lastPathComponent
        // created_at 用文件 mtime（外部文件无 frontmatter 时间）→ "新→旧" 排序有意义
        var createdAt = ""
        if let mtime = try? FileManager.default.attributesOfItem(atPath: fpath.path)[.modificationDate] as? Date {
            createdAt = Self.nowString(mtime)
        }
        do {
            try withWriteConn { conn in
                try conn.execute(
                    "INSERT OR REPLACE INTO knowledge_entries (id, title, scope, project_id, category, keywords, source, file_path, created_at) VALUES (?,?,?,?,?,?,?,?,?)",
                    [.text(entryId), .text(title), .text(scope), .text(projectId),
                     .text(""), .text("[]"), .text(Self.sourceImportedFile),
                     .text(fpath.path), .text(createdAt)])
                try conn.execute(
                    "INSERT INTO knowledge_fts (entry_id, title, keywords, body) VALUES (?,?,?,?)",
                    [.text(entryId), .text(NativeSearchTokenizer.tokenize(title)),
                     .text(NativeSearchTokenizer.tokenize("")),
                     .text(NativeSearchTokenizer.tokenize(body))])
            }
        } catch {
            log("文档重索引失败 \(fpath.lastPathComponent): \(error.localizedDescription)")
            return false
        }
        embedEntry(entryId: entryId, title: title, body: body, keywords: [])
        return true
    }

    /// _purge_file_index：覆盖导入前清掉该路径的旧 FTS/向量行
    /// （FTS5 虚表不支持 OR REPLACE，不清会残留覆盖前的旧正文分词——T4k 回归点）。
    private func purgeFileIndex(_ fpath: URL) {
        let entryId = Self.fileEntryID(fpath)
        do {
            try withWriteConn { conn in
                try conn.execute("DELETE FROM knowledge_fts WHERE entry_id = ?", [.text(entryId)])
                try conn.execute("DELETE FROM knowledge_embeddings WHERE entry_id = ?", [.text(entryId)])
            }
        } catch {
            log("清旧索引失败 \(fpath.lastPathComponent): \(error.localizedDescription)")
        }
    }

    // ════════════════════════════════════════════════════════════
    // MARK: - 导入（import_files：两趟 ask 冲突链，用户拍板语义逐字）
    // ════════════════════════════════════════════════════════════

    /// import_files：把用户选中的外部文件复制进知识目录并索引。
    ///
    /// 拉模式铁律：只复制+索引供检索，不自动注入上下文。
    /// 非递归：sources 是文件路径列表；目录/不存在 → failed。
    /// 复制保留 mtime（copy2 等价：copyItem + 恢复 modificationDate；_reindex_doc 的 created_at 用 mtime）。
    /// 同名冲突由用户决定，后端不擅自处置（2026-09-12 拍板「改成弹窗问我」）：
    ///   ask（默认）：不碰已存在文件，列入 conflicts 返回，前端弹窗问完再带策略重调；
    ///   overwrite：覆盖旧副本（先 _purge_file_index 清旧 FTS/向量）；
    ///   rename：存成 `名_1.扩展名`（旧文件原样保留）；
    ///   skip：跳过（旧文件原样保留）。
    /// 三种策略都绝不动用户原始文件。索引失败 → 删副本不留垃圾 + 计 skipped；
    /// overwrite+索引失败要如实告知「且原同名文件已被本次覆盖删除」。
    public func importFiles(scope: String, projectId: String?, sources: [String],
                            onConflict: String = "ask") -> NativeImportResult {
        guard let kdir = scopeDir(scope, projectId) else {
            return NativeImportResult(imported: 0, failed: sources.count, skipped: 0, conflicts: [],
                                      details: sources.map {
                                          NativeImportDetail(name: $0, status: "failed", reason: "无效的作用域或项目")
                                      })
        }
        try? FileManager.default.createDirectory(at: kdir, withIntermediateDirectories: true)
        var result = NativeImportResult()
        let fm = FileManager.default
        for src in sources {
            let sp = URL(fileURLWithPath: src)
            let name = sp.lastPathComponent
            // 对齐 Python `if not sp.exists() or not sp.is_file()`：目录/不存在 → failed。
            // ⚠️ fileExists(atPath:isDirectory:) 的 out 参数语义是「是否目录」，
            // 必须为 !isDir（此前误当「是否文件」用反，普通文件全被误判为不存在）。
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: src, isDirectory: &isDir), !isDir.boolValue else {
                result.failed += 1
                result.details.append(NativeImportDetail(name: name, status: "failed",
                                                         reason: "不是文件或不存在"))
                continue
            }
            var dest = kdir.appendingPathComponent(name)
            let existed = fm.fileExists(atPath: dest.path)   // 本次是否真的撞上同名（决定 details 记录）
            if existed {
                switch onConflict {
                case "ask":
                    result.conflicts.append(name)
                    result.details.append(NativeImportDetail(
                        name: name, status: "conflict",
                        reason: "知识目录已有同名文件（等你决定怎么处理）"))
                    continue
                case "skip":
                    result.skipped += 1
                    result.details.append(NativeImportDetail(
                        name: name, status: "skipped", reason: "同名文件已存在，按你的选择跳过"))
                    continue
                case "rename":
                    var seq = 1
                    // Python f"{sp.stem}_{seq}{sp.suffix}"：suffix 含点；无扩展名 → 无点
                    let stem = sp.deletingPathExtension().lastPathComponent
                    let ext = sp.pathExtension.isEmpty ? "" : ".\(sp.pathExtension)"
                    while fm.fileExists(atPath: dest.path) {
                        dest = kdir.appendingPathComponent("\(stem)_\(seq)\(ext)")
                        seq += 1
                    }
                case "overwrite":
                    purgeFileIndex(dest)   // 先清旧 FTS/向量，否则残留旧正文
                    // shutil.copy2 静默覆盖既有目标；FileManager.copyItem 目标已存在会抛错，
                    // 须先删旧副本（删除失败则下面 copyItem 抛错走「复制失败」，与 OSError 等价）。
                    try? fm.removeItem(at: dest)
                default:
                    result.failed += 1
                    result.details.append(NativeImportDetail(
                        name: name, status: "failed", reason: "未知的冲突策略: \(onConflict)"))
                    continue
                }
            }
            // copy2 等价：复制 + 恢复 mtime
            do {
                let srcMtime = try fm.attributesOfItem(atPath: sp.path)[.modificationDate] as? Date
                try fm.copyItem(at: sp, to: dest)
                if let srcMtime {
                    try fm.setAttributes([.modificationDate: srcMtime], ofItemAtPath: dest.path)
                }
            } catch {
                result.failed += 1
                result.details.append(NativeImportDetail(
                    name: name, status: "failed", reason: "复制失败: \(error.localizedDescription)"))
                continue
            }
            let ok = reindexDoc(dest, scope: scope, projectId: projectId ?? "")
            if ok {
                result.imported += 1
                result.details.append(NativeImportDetail(
                    name: dest.lastPathComponent, status: "imported",
                    conflictResolved: existed ? onConflict : nil))
            } else {
                result.skipped += 1
                var reason = "不支持的类型/解析失败/超大文件"
                // 仅删本次新复制的副本；overwrite 策略下如实补告（逐字对齐 Python：
                // 条件只看 on_conflict=="overwrite"——即使本次并未真撞名也补后缀）
                try? fm.removeItem(at: dest)
                if onConflict == "overwrite" {
                    reason += "；⚠️ 且原同名文件已被本次覆盖删除"
                }
                result.details.append(NativeImportDetail(
                    name: dest.lastPathComponent, status: "skipped", reason: reason))
            }
        }
        return result
    }

    // ════════════════════════════════════════════════════════════
    // MARK: - 端点级语义（embedding-status / groups / inject / open-dir）
    // ════════════════════════════════════════════════════════════

    /// GET /api/knowledge/embedding-status 等价（app.py L2575-2588）。
    /// model/model_dir 字段如实反映原生 CoreML 模型（面板仅展示）。
    /// 0.5.2 A1：补 loadState（装载三态）——真懒加载后 UI 需区分「可用未装载/
    /// 装载中/装载失败」。
    public func embeddingStatus() -> (available: Bool, model: String, modelDir: String,
                                      entriesTotal: Int, entriesEmbedded: Int,
                                      loadState: String) {
        let counts = (try? withReadConn { conn in
            let total = try conn.queryOne("SELECT COUNT(*) FROM knowledge_entries")?.first?.intValue ?? 0
            let embedded = try conn.queryOne("SELECT COUNT(*) FROM knowledge_embeddings")?.first?.intValue ?? 0
            return (Int(total), Int(embedded))
        }) ?? (0, 0)
        return (embedder.modelAvailable(), NativeEmbedder.modelID,
                embedder.modelDirPath(), counts.0, counts.1,
                embedder.loadState.rawValue)
    }

    /// GET /api/knowledge/groups 等价（app.py L2623-2643）：读取前对账；全局组恒在首位。
    public func knowledgeGroups() -> [NativeKnowledgeGroup] {
        pruneMissing()
        var groups: [NativeKnowledgeGroup] = []
        let gEntries = listEntries(scope: Self.globalScope)
        groups.append(NativeKnowledgeGroup(scope: Self.globalScope, projectId: nil,
                                           projectName: "全局", count: gEntries.count,
                                           dir: globalKnowledgeDir().path))
        let projects = (try? database.listProjectRows()) ?? []
        for p in projects {
            let pid = p["id"] ?? ""
            let pEntries = listEntries(scope: Self.projectScope, projectId: pid)
            let kdir = projectKnowledgeDir(pid)
            groups.append(NativeKnowledgeGroup(scope: Self.projectScope, projectId: pid,
                                               projectName: p["name"].flatMap { $0.isEmpty ? nil : $0 } ?? pid,
                                               count: pEntries.count, dir: kdir?.path ?? ""))
        }
        return groups
    }

    /// POST /api/knowledge/inject 等价（app.py L2595-2606）：拼接勾选条目正文。
    /// 无有效条目 → nil（端点 404「未找到任何有效条目」，由调用方映射）。
    public func injectText(entryIds: [String]) -> String? {
        pruneMissing()   // 查虫K-1：外部删除的条目不参与注入
        var parts: [String] = []
        for eid in entryIds {
            if let e = getEntry(eid) {
                parts.append("【知识：\(e.title)】\n\(e.body ?? "")")
            }
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n\n---\n\n")
    }

    // ════════════════════════════════════════════════════════════
    // MARK: - 推模式知识库（store_knowledge.py：项目 knowledge/*.md）
    // ════════════════════════════════════════════════════════════

    /// knowledge_dir：项目工作目录/knowledge（无 mkdir 副作用——对齐 Python 纯路径拼接）。
    public func knowledgeDir(_ projectId: String) -> URL? {
        guard let proj = try? database.getProject(projectId), !proj.workingDir.isEmpty else { return nil }
        return URL(fileURLWithPath: proj.workingDir).appendingPathComponent("knowledge", isDirectory: true)
    }

    /// _valid_filename：非空、无路径分隔符/穿越、.md 后缀。
    public static func validKnowledgeFilename(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        if name.contains("/") || name.contains("\\") || name.contains("..") { return false }
        return name.hasSuffix(".md")
    }

    /// list_knowledge：[{name, size, enabled}]（_ 前缀 = 禁用）。目录不存在 → []。
    public func listKnowledge(_ projectId: String) -> [(name: String, size: Int, enabled: Bool)] {
        guard let kdir = knowledgeDir(projectId),
              let items = try? FileManager.default.contentsOfDirectory(
                  at: kdir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return [] }
        return items.filter { url in
            ((try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false)
                && url.pathExtension == "md"
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return (url.lastPathComponent, size, !url.lastPathComponent.hasPrefix("_"))
        }
    }

    /// read_knowledge：非法名/不存在/读失败 → nil。
    public func readKnowledge(_ projectId: String, _ filename: String) -> String? {
        guard Self.validKnowledgeFilename(filename),
              let kdir = knowledgeDir(projectId) else { return nil }
        let f = kdir.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: f.path) else { return nil }
        return try? String(contentsOf: f, encoding: .utf8)
    }

    /// write_knowledge：非法名/目录不可用/写失败 → false（kdir.mkdir 副作用对齐）。
    @discardableResult
    public func writeKnowledge(_ projectId: String, _ filename: String, _ content: String) -> Bool {
        guard Self.validKnowledgeFilename(filename),
              let kdir = knowledgeDir(projectId) else { return false }
        do {
            try FileManager.default.createDirectory(at: kdir, withIntermediateDirectories: true)
            try (content).write(to: kdir.appendingPathComponent(filename), atomically: false, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// delete_knowledge：非法名/不存在 → false。
    @discardableResult
    public func deleteKnowledge(_ projectId: String, _ filename: String) -> Bool {
        guard Self.validKnowledgeFilename(filename),
              let kdir = knowledgeDir(projectId) else { return false }
        let f = kdir.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: f.path) else { return false }
        return (try? FileManager.default.removeItem(at: f)) != nil
    }

    /// toggle_knowledge：_ 前缀切换；返回新文件名，失败（不存在/同名冲突/非法）→ nil。
    @discardableResult
    public func toggleKnowledge(_ projectId: String, _ filename: String) -> String? {
        guard Self.validKnowledgeFilename(filename),
              let kdir = knowledgeDir(projectId) else { return nil }
        let f = kdir.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: f.path) else { return nil }
        let newName: String
        if filename.hasPrefix("_") {
            // Python lstrip("_")（去全部前导下划线）或 "unnamed.md"
            let stripped = String(filename.drop(while: { $0 == "_" }))
            newName = stripped.isEmpty ? "unnamed.md" : stripped
        } else {
            newName = "_" + filename
        }
        guard Self.validKnowledgeFilename(newName) else { return nil }
        let newF = kdir.appendingPathComponent(newName)
        guard !FileManager.default.fileExists(atPath: newF.path) else { return nil }
        do {
            try FileManager.default.moveItem(at: f, to: newF)
            return newName
        } catch {
            return nil
        }
    }

    /// build_knowledge_text：拼接启用文件为注入文本（单文件 4000 截断 + 总量 12000 上限）。
    /// 任何异常 → 空串。
    public func buildKnowledgeText(_ projectId: String) -> String {
        guard let kdir = knowledgeDir(projectId) else { return "" }
        var parts: [String] = []
        var total = 0
        for entry in listKnowledge(projectId) {
            guard entry.enabled else { continue }
            if total >= Self.knowledgeMaxCharsTotal { break }
            guard var text = try? String(contentsOf: kdir.appendingPathComponent(entry.name),
                                         encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            if text.count > Self.knowledgeMaxCharsEach {
                text = String(text.prefix(Self.knowledgeMaxCharsEach)) + "\n（该文件超长已截断）"
            }
            if total + text.count > Self.knowledgeMaxCharsTotal {
                let remain = Self.knowledgeMaxCharsTotal - total
                if remain > 200 {
                    parts.append("【\(entry.name)】\n\(text.prefix(remain))\n（已达总量上限，后续文件未注入）")
                }
                break
            }
            parts.append("【\(entry.name)】\n\(text)")
            total += text.count
        }
        return parts.joined(separator: "\n\n")
    }

    // ════════════════════════════════════════════════════════════
    // MARK: - 记忆（store_knowledge.py read/write_memory + 禁止事项 + 注入）
    // ════════════════════════════════════════════════════════════

    /// _memory_path：global → {data_root}/memory/global.md；project → 工作目录/memory.md。
    private func memoryPath(_ scope: String, _ projectId: String?) -> URL? {
        if scope == Self.globalScope {
            return dataRoot.appendingPathComponent("memory/global.md")
        }
        if scope == Self.projectScope {
            guard let projectId, !projectId.isEmpty,
                  let proj = try? database.getProject(projectId), !proj.workingDir.isEmpty else { return nil }
            return URL(fileURLWithPath: proj.workingDir).appendingPathComponent("memory.md")
        }
        return nil
    }

    /// read_memory：路径无效/不存在/读失败 → ""。
    public func readMemory(_ scope: String, _ projectId: String?) -> String {
        guard let p = memoryPath(scope, projectId),
              FileManager.default.fileExists(atPath: p.path) else { return "" }
        return (try? String(contentsOf: p, encoding: .utf8)) ?? ""
    }

    /// write_memory：超 4000 截断「（超长已截断）」；父目录 mkdir；路径无效/写失败 → false。
    @discardableResult
    public func writeMemory(_ scope: String, _ content: String, _ projectId: String?) -> Bool {
        guard let p = memoryPath(scope, projectId) else { return false }
        do {
            try FileManager.default.createDirectory(at: p.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            var text = content
            if text.count > Self.memoryMaxChars {
                text = String(text.prefix(Self.memoryMaxChars)) + "\n（超长已截断）"
            }
            try text.write(to: p, atomically: false, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// extract_prohibitions：行首关键词匹配（先去常见列表符号前缀 `^[-*•\d.\s]+`）。
    public static func extractProhibitions(_ memoryText: String) -> [String] {
        var out: [String] = []
        for line in memoryText.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = line.trimmingCharacters(in: .whitespaces)
            // Python re.sub(r"^[-*•\d.\s]+", "", s)
            var s2 = s
            while let first = s2.first, "-*•. \t".contains(first) || first.isNumber {
                s2.removeFirst()
            }
            if prohibitionPrefixes.contains(where: { s2.hasPrefix($0) }) {
                out.append(s2)
            }
        }
        return out
    }

    /// build_memory_injection：返回 (记忆正文段, 禁止事项列表)。
    /// 优先级（3.14）：本地记忆 > 通用知识；项目记忆与全局冲突时以项目为准。
    public func buildMemoryInjection(_ projectId: String?) -> (text: String, prohibitions: [String]) {
        let g = readMemory(Self.globalScope, nil).trimmingCharacters(in: .whitespacesAndNewlines)
        let p = (projectId.map { readMemory(Self.projectScope, $0) } ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var prohibitions: [String] = []
        for item in Self.extractProhibitions(g) + Self.extractProhibitions(p) {
            if !prohibitions.contains(item) { prohibitions.append(item) }
        }
        var parts: [String] = []
        if !g.isEmpty { parts.append("【全局记忆】\n" + g) }
        if !p.isEmpty { parts.append("【本项目记忆】（与全局记忆/知识库冲突时，以本项目记忆为准）\n" + p) }
        return (parts.joined(separator: "\n\n"), prohibitions)
    }
}


// ════════════════════════════════════════════════════════════
// MARK: - REQ-KNW-007（0.7.5 W3）知识/记忆注入按需化
// ════════════════════════════════════════════════════════════

/// 知识注入按需化策略（纯逻辑，可测）。
///
/// 口径（REQ-KNW-007 为 draft、明言「不预设实现方案」；按业主「保守默认、不损既有能力」
/// 原则落地，待与业主细化验收标准时再调）：
///   · 默认 .full——逐字维持现行「每轮全量内联知识库正文」口径，不损既有能力；
///   · .onDemand——知识库正文不再逐轮内联进系统提示，改注入一段「按需指引」（告知
///     模型知识库存在、需要时经 search_knowledge 拉模式工具按当前消息相关性检索后
///     再引用）＝只在需要时检索注入；检索入口复用既有 search_knowledge 工具
///     （REQ-KNW-002 拉模式铁律通道），无新增面；
///   · 记忆（长期记忆 + 禁止事项红线）两种模式均保持全量注入——REQ-KNW-001 ② 钉死
///     「禁止事项 100% 拦截（注入 system prompt 头部红线区）」；记忆体量小、承载用户
///     持久偏好与红线，按需化会损既有能力，不在本条范围；
///   · 委派子会话（NativeKernel.knowledgeTextProvider）保持全量不动——子 Agent 任务
///     聚焦、轮次少，本批保守不动。
public enum KnowledgeInjectionPolicy {

    /// 配置键（config.json；缺省/空/未知值一律 .full，保守默认）。
    public static let configKey = "knowledge_inject_mode"

    public enum Mode: String {
        case full = "full"
        case onDemand = "on_demand"
    }

    /// 配置原文 → 模式（缺省/空/未知 → .full——不损既有能力）。
    public static func mode(raw: String?) -> Mode {
        Mode(rawValue: raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? .full
    }

    /// 按需指引段（替换正文内联；search_knowledge 工具名与 toolsSpec 登记名逐字一致）。
    public static let onDemandGuide =
        "（本项目知识库已启用按需注入：正文不自动内联，以节省上下文。"
        + "当任务需要引用项目知识时，先调用 search_knowledge 工具按当前消息相关性检索，"
        + "再依据命中内容作答；检索结果仅本轮使用。）"

    /// 按策略产出注入系统提示的知识段：
    ///   · full → 原文透传（含空串）；
    ///   · onDemand → 有内容则换指引段；知识库为空则空（不注入指引噪音）。
    public static func knowledgeSection(mode: Mode, knowledgeText: String) -> String {
        switch mode {
        case .full: return knowledgeText
        case .onDemand: return knowledgeText.isEmpty ? "" : onDemandGuide
        }
    }
}
