//
//  NativeDatabaseSchema.swift
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

//  ⛔ 数据兼容红线：DDL 逐字复制 subagent/sidecar/storage/store.py `_ensure_schema`
//  （L42-198 executescript 块 + L200-220 列迁移 + L224-263 agent_tasks 重建）。
//  13 表 / 130 列 / 9 索引——与真实 Python 代码生成的基线库逐字段核对
//  （核对脚本输出见本文件尾部 SchemaExpectation，双跑测试再验）。
//
//  移植保真点：
//    · CREATE TABLE IF NOT EXISTS 幂等（新建库与既有库同路径）
//    · 列迁移只加不改（tool_steps/truncated/prompt_eval_count/archived/stopped/attachments）
//    · agent_tasks 旧 CHECK 无 'queued' → 整表重建（sqlite 改不了 CHECK），数据逐列搬运
//    · datetime('now') 默认值由 SQLite 侧生成——与 Python 同库同语义（UTC 秒级文本）
//

import Foundation

public enum NativeDatabaseSchema {

    /// executescript 全文（逐字；缩进与 Python 三引号串一致——SQLite 不在意空白，
    /// 保持一致只为 diff 友好）。
    public static let ddl = """
        CREATE TABLE IF NOT EXISTS projects (
            id TEXT PRIMARY KEY, name TEXT NOT NULL, working_dir TEXT NOT NULL,
            created_at TEXT DEFAULT (datetime('now')), updated_at TEXT DEFAULT (datetime('now'))
        );
        CREATE TABLE IF NOT EXISTS independent_agents (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            role TEXT, system_prompt TEXT, model_name TEXT,
            created_at TEXT DEFAULT (datetime('now'))
        );
        CREATE TABLE IF NOT EXISTS agent_configs (
            id TEXT PRIMARY KEY, project_id TEXT NOT NULL,
            name TEXT NOT NULL, role TEXT, system_prompt TEXT, model_name TEXT,
            type_ TEXT NOT NULL CHECK(type_ IN ('main','sub')),
            parent_agent_id TEXT,
            created_at TEXT DEFAULT (datetime('now'))
        );
        CREATE TABLE IF NOT EXISTS sessions (
            id TEXT PRIMARY KEY,
            agent_id TEXT NOT NULL,
            project_id TEXT NOT NULL,
            title TEXT DEFAULT '新会话',
            created_at TEXT DEFAULT (datetime('now')),
            updated_at TEXT DEFAULT (datetime('now'))
        );
        CREATE TABLE IF NOT EXISTS session_messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL,
            agent_id TEXT NOT NULL,
            project_id TEXT NOT NULL,
            role TEXT NOT NULL CHECK(role IN ('user','assistant','system')),
            content TEXT,
            images TEXT,
            model_used TEXT,
            created_at TEXT DEFAULT (datetime('now'))
        );
        CREATE TABLE IF NOT EXISTS session_summaries (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL,
            agent_id TEXT NOT NULL,
            project_id TEXT NOT NULL,
            summary_text TEXT,
            saved_at TEXT DEFAULT (datetime('now'))
        );
        CREATE TABLE IF NOT EXISTS compact_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL,
            project_id TEXT NOT NULL,
            ts TEXT DEFAULT (datetime('now')),
            before_tokens INTEGER,
            after_tokens INTEGER,
            archive_path TEXT,
            summary TEXT,
            error TEXT
        );
        CREATE TABLE IF NOT EXISTS agent_tasks (
            id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            parent_agent_id TEXT NOT NULL,
            parent_session_id TEXT NOT NULL,
            target_agent_id TEXT NOT NULL,
            target_agent_name TEXT NOT NULL,
            task TEXT NOT NULL,
            expect TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'queued' CHECK(status IN ('queued','running','done','failed')),
            report TEXT,
            fail_reason TEXT,
            validation_failures INTEGER NOT NULL DEFAULT 0,
            session_id TEXT,
            created_at TEXT DEFAULT (datetime('now')),
            updated_at TEXT DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_tasks_project ON agent_tasks(project_id);
        CREATE TABLE IF NOT EXISTS roundtables (
            id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            topic TEXT NOT NULL,
            participants TEXT NOT NULL,
            moderator TEXT NOT NULL DEFAULT 'user' CHECK(moderator IN ('user','ai')),
            moderator_agent_id TEXT,
            max_rounds INTEGER NOT NULL DEFAULT 5,
            round INTEGER NOT NULL DEFAULT 0,
            status TEXT NOT NULL DEFAULT 'running'
                CHECK(status IN ('running','waiting_user','confirm_end','done','failed')),
            minutes TEXT,
            summary TEXT,
            attachments TEXT,
            created_at TEXT DEFAULT (datetime('now')),
            updated_at TEXT DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_rt_project ON roundtables(project_id);
        CREATE TABLE IF NOT EXISTS roundtable_messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            rt_id TEXT NOT NULL,
            round INTEGER NOT NULL,
            agent_id TEXT NOT NULL,
            agent_name TEXT NOT NULL,
            content TEXT,
            ok INTEGER NOT NULL DEFAULT 1,
            created_at TEXT DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_rtm_rt ON roundtable_messages(rt_id);
        CREATE INDEX IF NOT EXISTS idx_compact_session ON compact_log(session_id);
        CREATE INDEX IF NOT EXISTS idx_sessions_agent ON sessions(agent_id);
        CREATE INDEX IF NOT EXISTS idx_msgs_session ON session_messages(session_id);
        CREATE INDEX IF NOT EXISTS idx_msgs_agent ON session_messages(agent_id);
        CREATE TABLE IF NOT EXISTS workflows (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            description TEXT,
            definition TEXT NOT NULL,
            built_in INTEGER NOT NULL DEFAULT 0,
            created_at TEXT DEFAULT (datetime('now')),
            updated_at TEXT DEFAULT (datetime('now'))
        );
        CREATE TABLE IF NOT EXISTS workflow_runs (
            id TEXT PRIMARY KEY,
            workflow_id TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'running'
                CHECK(status IN ('running','awaiting_approval','done','failed','stopped')),
            current_node TEXT,
            variables TEXT,
            result TEXT,
            error TEXT,
            created_at TEXT DEFAULT (datetime('now')),
            updated_at TEXT DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_wf_runs_workflow ON workflow_runs(workflow_id);
        CREATE TABLE IF NOT EXISTS workflow_node_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            run_id TEXT NOT NULL,
            node_id TEXT NOT NULL,
            node_type TEXT,
            status TEXT NOT NULL,
            model_used TEXT,
            input_summary TEXT,
            output_summary TEXT,
            error TEXT,
            retry_count INTEGER NOT NULL DEFAULT 0,
            duration_ms INTEGER,
            created_at TEXT DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_wf_events_run ON workflow_node_events(run_id);
    """

    /// 幂等迁移（_ensure_schema 后段逐条对齐）。在 ddl 执行后调用。
    public static func migrate(on conn: SQLiteConnection) throws {
        // B06/H17/TS-120/C8：session_messages 列补齐（禁止靠 CREATE IF NOT EXISTS 加列）
        let msgCols = try conn.columnNames(of: "session_messages")
        if !msgCols.contains("tool_steps") {
            try conn.execScript("ALTER TABLE session_messages ADD COLUMN tool_steps TEXT")
        }
        if !msgCols.contains("truncated") {
            try conn.execScript("ALTER TABLE session_messages ADD COLUMN truncated INTEGER DEFAULT 0")
        }
        if !msgCols.contains("prompt_eval_count") {
            try conn.execScript("ALTER TABLE session_messages ADD COLUMN prompt_eval_count INTEGER")
        }
        if !msgCols.contains("archived") {
            try conn.execScript("ALTER TABLE session_messages ADD COLUMN archived INTEGER DEFAULT 0")
        }
        if !msgCols.contains("stopped") {
            try conn.execScript("ALTER TABLE session_messages ADD COLUMN stopped INTEGER DEFAULT 0")
        }
        // H18-3：圆桌附件列（旧库补齐；rt_cols 空集 = 表不存在时不动作——对齐 Python `if rt_cols`）
        let rtCols = try conn.columnNames(of: "roundtables")
        if !rtCols.isEmpty && !rtCols.contains("attachments") {
            try conn.execScript("ALTER TABLE roundtables ADD COLUMN attachments TEXT")
        }
        // TS-108 M3-2：agent_tasks CHECK 扩展（027 版旧表无 'queued' → 整表重建）
        if let sql = try conn.tableSQL("agent_tasks"), !sql.contains("'queued'") {
            try conn.begin()
            do {
                try conn.execScript("""
                    CREATE TABLE agent_tasks_new (
                        id TEXT PRIMARY KEY,
                        project_id TEXT NOT NULL,
                        parent_agent_id TEXT NOT NULL,
                        parent_session_id TEXT NOT NULL,
                        target_agent_id TEXT NOT NULL,
                        target_agent_name TEXT NOT NULL,
                        task TEXT NOT NULL,
                        expect TEXT NOT NULL,
                        status TEXT NOT NULL DEFAULT 'queued' CHECK(status IN ('queued','running','done','failed')),
                        report TEXT,
                        fail_reason TEXT,
                        validation_failures INTEGER NOT NULL DEFAULT 0,
                        session_id TEXT,
                        created_at TEXT DEFAULT (datetime('now')),
                        updated_at TEXT DEFAULT (datetime('now'))
                    )
                """)
                try conn.execScript("""
                    INSERT INTO agent_tasks_new (
                        id, project_id, parent_agent_id, parent_session_id, target_agent_id,
                        target_agent_name, task, expect, status, report, fail_reason,
                        validation_failures, session_id, created_at, updated_at
                    ) SELECT
                        id, project_id, parent_agent_id, parent_session_id, target_agent_id,
                        target_agent_name, task, expect, status, report, fail_reason,
                        validation_failures, session_id, created_at, updated_at
                    FROM agent_tasks
                """)
                try conn.execScript("DROP TABLE agent_tasks")
                try conn.execScript("ALTER TABLE agent_tasks_new RENAME TO agent_tasks")
                try conn.execScript("CREATE INDEX IF NOT EXISTS idx_tasks_project ON agent_tasks(project_id)")
                try conn.commit()
            } catch {
                try? conn.rollback()   // 崩溃/失败整体回滚，下次重连自动重迁（幂等）
                throw error
            }
        }
    }

    // MARK: - schema 期望（双跑/自验用；来源：真实 Python 侧车生成的基线库 dump）

    /// 表 → 列名有序清单（PRAGMA table_info 顺序）。
    public static let expectedColumns: [String: [String]] = [
        "projects": ["id", "name", "working_dir", "created_at", "updated_at"],
        "independent_agents": ["id", "name", "role", "system_prompt", "model_name", "created_at"],
        "agent_configs": ["id", "project_id", "name", "role", "system_prompt", "model_name",
                          "type_", "parent_agent_id", "created_at"],
        "sessions": ["id", "agent_id", "project_id", "title", "created_at", "updated_at"],
        "session_messages": ["id", "session_id", "agent_id", "project_id", "role", "content",
                             "images", "model_used", "created_at",
                             "tool_steps", "truncated", "prompt_eval_count", "archived", "stopped"],
        "session_summaries": ["id", "session_id", "agent_id", "project_id", "summary_text", "saved_at"],
        "compact_log": ["id", "session_id", "project_id", "ts", "before_tokens",
                        "after_tokens", "archive_path", "summary", "error"],
        "agent_tasks": ["id", "project_id", "parent_agent_id", "parent_session_id", "target_agent_id",
                        "target_agent_name", "task", "expect", "status", "report", "fail_reason",
                        "validation_failures", "session_id", "created_at", "updated_at"],
        "roundtables": ["id", "project_id", "topic", "participants", "moderator", "moderator_agent_id",
                        "max_rounds", "round", "status", "minutes", "summary", "attachments",
                        "created_at", "updated_at"],
        "roundtable_messages": ["id", "rt_id", "round", "agent_id", "agent_name", "content", "ok", "created_at"],
        "workflows": ["id", "name", "description", "definition", "built_in", "created_at", "updated_at"],
        "workflow_runs": ["id", "workflow_id", "status", "current_node", "variables", "result",
                          "error", "created_at", "updated_at"],
        "workflow_node_events": ["id", "run_id", "node_id", "node_type", "status", "model_used",
                                 "input_summary", "output_summary", "error", "retry_count",
                                 "duration_ms", "created_at"],
    ]

    public static let expectedIndexes: Set<String> = [
        "idx_tasks_project", "idx_rt_project", "idx_rtm_rt", "idx_compact_session",
        "idx_sessions_agent", "idx_msgs_session", "idx_msgs_agent",
        "idx_wf_runs_workflow", "idx_wf_events_run",
    ]
}
