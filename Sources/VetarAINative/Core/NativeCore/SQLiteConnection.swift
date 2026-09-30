//
//  SQLiteConnection.swift
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

//  系统 libsqlite3 C API 薄封装（项目纪律：零外部依赖，不引 GRDB）。
//  语义逐条对齐 Python sqlite3（subagent/sidecar/storage/store.py 的用法面）：
//    · open 即设 busy_timeout（全局库 10s / 项目库 5s，checkpoint-050 / TS-115 口径）
//    · 值域四型：NULL / TEXT / INTEGER / REAL（Python None/str/int/float 一一对应）
//    · 写连接上下文：成功 commit / 异常 rollback / 必 close（checkpoint-050 B-1 修法）
//    · changes = sqlite3_changes（Python cursor.rowcount）
//    · executescript 用 sqlite3_exec（DDL 脚本整体下发，autocommit）
//
//  非线程安全设计：与 Python 一致——每次操作开/关连接，写路径由 NativeDatabase
//  的写锁串行化（对标 _WRITE_LOCK）。本类不在线程间共享同一连接。
//

import Foundation
import SQLite3

/// SQLite 值（Python sqlite3 绑定值域的 Swift 对应）。
public enum SQLiteValue: Equatable, Sendable {
    case null
    case text(String)
    case integer(Int64)
    case real(Double)
    /// P2-W1：BLOB 入域（knowledge_embeddings.dense 存 float32 LE 向量，
    /// 对齐 warehouse.py dense_to_blob 的 struct.pack("<Nf")）。
    case blob(Data)

    public var textValue: String? { if case .text(let s) = self { return s }; return nil }
    public var intValue: Int64? { if case .integer(let i) = self { return i }; return nil }
    public var realValue: Double? {
        if case .real(let d) = self { return d }
        if case .integer(let i) = self { return Double(i) }
        return nil
    }
    public var blobValue: Data? { if case .blob(let d) = self { return d }; return nil }
    public var isNull: Bool { self == .null }
}

public struct SQLiteError: Error, Equatable {
    public let code: Int32
    public let message: String
}

public final class SQLiteConnection {

    public private(set) var path: String
    private var handle: OpaquePointer?

    /// 打开（不存在则创建，对齐 sqlite3.connect 默认）并设忙等待。
    public init(path: String, busyTimeoutMs: Int32) throws {
        self.path = path
        var h: OpaquePointer?
        let rc = sqlite3_open_v2(path, &h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let h else {
            let msg = h.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "open failed"
            if let h { sqlite3_close(h) }
            throw SQLiteError(code: rc, message: msg)
        }
        self.handle = h
        sqlite3_busy_timeout(h, busyTimeoutMs)
    }

    deinit { try? close() }

    public func close() throws {
        guard let h = handle else { return }
        handle = nil
        // 未提交事务随 close 回滚（Python conn.close() 同语义——不隐式提交）
        let rc = sqlite3_close(h)
        if rc != SQLITE_OK { throw lastError(rc) }
    }

    // MARK: - 事务（显式 BEGIN/COMMIT/ROLLBACK；对标 Python 隐式事务 + commit/rollback）

    public func begin() throws { try execVoid("BEGIN") }
    public func commit() throws { try execVoid("COMMIT") }
    public func rollback() throws { try execVoid("ROLLBACK") }

    /// DDL / 多语句脚本（对齐 executescript：autocommit 逐句执行）。
    public func execScript(_ sql: String) throws {
        try sql.withCString { cstr in
            var errPtr: UnsafeMutablePointer<CChar>?
            let rc = sqlite3_exec(handle, cstr, nil, nil, &errPtr)
            if rc != SQLITE_OK {
                let msg = errPtr.map { String(cString: $0) } ?? "exec failed"
                sqlite3_free(errPtr)
                throw SQLiteError(code: rc, message: msg)
            }
        }
    }

    private func execVoid(_ sql: String) throws { try execScript(sql) }

    // MARK: - 参数化执行

    /// INSERT/UPDATE/DELETE：执行并返回 sqlite3_changes（= Python rowcount）。
    @discardableResult
    public func execute(_ sql: String, _ params: [SQLiteValue] = []) throws -> Int {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bind(stmt, params)
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW { rc = sqlite3_step(stmt) }   // 带 RETURNING 的保险
        guard rc == SQLITE_DONE else { throw lastError(rc) }
        return Int(sqlite3_changes(handle))
    }

    /// SELECT：返回全部行。
    public func query(_ sql: String, _ params: [SQLiteValue] = []) throws -> [[SQLiteValue]] {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bind(stmt, params)
        var rows: [[SQLiteValue]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw lastError(rc) }
            let n = sqlite3_column_count(stmt)
            var row: [SQLiteValue] = []
            row.reserveCapacity(Int(n))
            for i in 0..<n {
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_NULL:
                    row.append(.null)
                case SQLITE_INTEGER:
                    row.append(.integer(sqlite3_column_int64(stmt, i)))
                case SQLITE_FLOAT:
                    row.append(.real(sqlite3_column_double(stmt, i)))
                case SQLITE_TEXT:
                    row.append(.text(String(cString: sqlite3_column_text(stmt, i))))
                case SQLITE_BLOB:
                    // P2-W1：BLOB 读出（嵌入向量；bytes 可能是 NULL 指针当 0 字节）
                    let n = sqlite3_column_bytes(stmt, i)
                    if let ptr = sqlite3_column_blob(stmt, i), n > 0 {
                        row.append(.blob(Data(bytes: ptr, count: Int(n))))
                    } else {
                        row.append(.blob(Data()))
                    }
                default:
                    throw SQLiteError(code: SQLITE_MISMATCH, message: "未知列类型")
                }
            }
            rows.append(row)
        }
        return rows
    }

    public func queryOne(_ sql: String, _ params: [SQLiteValue] = []) throws -> [SQLiteValue]? {
        try query(sql, params).first
    }

    /// PRAGMA table_info 的列名集合（迁移判定用，对标 {r[1] for r in ...}）。
    public func columnNames(of table: String) throws -> Set<String> {
        // 表名只来自内部常量（外部输入永不进 PRAGMA），拼接安全。
        let rows = try query("PRAGMA table_info(\(table))")
        return Set(rows.compactMap { $0.count > 1 ? $0[1].textValue : nil })
    }

    /// sqlite_master 中指定表的建表 SQL（agent_tasks 重建迁移判定用）。
    public func tableSQL(_ name: String) throws -> String? {
        try queryOne("SELECT sql FROM sqlite_master WHERE type='table' AND name=?", [.text(name)])?
            .first?.textValue
    }

    // MARK: - 内部

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw lastError(rc)
        }
        return stmt
    }

    private func bind(_ stmt: OpaquePointer?, _ params: [SQLiteValue]) throws {
        for (idx, v) in params.enumerated() {
            let i = Int32(idx + 1)
            let rc: Int32
            switch v {
            case .null: rc = sqlite3_bind_null(stmt, i)
            case .integer(let x): rc = sqlite3_bind_int64(stmt, i, x)
            case .real(let x): rc = sqlite3_bind_double(stmt, i, x)
            case .text(let s):
                rc = sqlite3_bind_text(stmt, i, s, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case .blob(let d):
                rc = d.withUnsafeBytes { ptr in
                    sqlite3_bind_blob(stmt, i, ptr.baseAddress, Int32(d.count),
                                      unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            }
            guard rc == SQLITE_OK else { throw lastError(rc) }
        }
    }

    private func lastError(_ rc: Int32) -> SQLiteError {
        let msg = handle.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "sqlite error"
        return SQLiteError(code: rc, message: msg)
    }
}
