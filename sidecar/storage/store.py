"""Project CRUD, Agent configs, Session management, and message persistence."""
from __future__ import annotations

import json
import sqlite3
import uuid
from datetime import datetime
from pathlib import Path
from typing import Any


from sidecar.config import projects_root
PROJECTS_ROOT = projects_root()
PROJECTS_ROOT.mkdir(parents=True, exist_ok=True)

_GDB = PROJECTS_ROOT / "_global.db"

# M3 前置安全加固 M2：SQLite 写锁。写操作统一加锁串行化，读操作不加锁。
import threading as _threading
_WRITE_LOCK = _threading.Lock()


def _ensure_schema(conn: sqlite3.Connection):
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS projects (
            id TEXT PRIMARY KEY, name TEXT NOT NULL, working_dir TEXT NOT NULL,
            created_at TEXT DEFAULT (datetime('now')), updated_at TEXT DEFAULT (datetime('now'))
        );
        -- checkpoint-058：独立 Agent 注册表（与项目平级的一等公民）。
        -- 不属于任何项目；数据目录 projects/ia-<id>/（复用 agents.db 机制）；
        -- 删除任何项目不影响独立 Agent。
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
        -- M2 上下文可视化：压缩日志独立表（与 session_messages 分离）
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
        -- M3-1（TS-107）：委派任务表（主 Agent 委派子 Agent，固定交卷契约）
        -- M3-2（TS-108）：状态扩展——落库即 queued（排队），拿到串行锁才改 running
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
        -- M3-3（TS-109）：圆桌讨论主表（议题/参与者/主持人/轮次/纪要/总结）
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
        -- M3-3：圆桌发言记录表
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
        -- 0.2.1（TS-119）：工作流模块（一级模块"流程中心"）
        -- 工作流定义：全局资源（不挂项目），definition 存完整 JSON（nodes/edges/params）
        CREATE TABLE IF NOT EXISTS workflows (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            description TEXT,
            definition TEXT NOT NULL,
            built_in INTEGER NOT NULL DEFAULT 0,
            created_at TEXT DEFAULT (datetime('now')),
            updated_at TEXT DEFAULT (datetime('now'))
        );
        -- 工作流运行实例：每次"运行"一条，variables 存运行时上下文快照
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
        -- 节点事件：每个节点执行一条（状态/输入/输出/耗时/重试），供运行监控回放
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
    """)
    # B06（TS-101）：旧 DB 缺 tool_steps/truncated 列 → 幂等迁移（禁止靠 CREATE TABLE IF NOT EXISTS 加列）
    cols = {r[1] for r in conn.execute("PRAGMA table_info(session_messages)").fetchall()}
    if "tool_steps" not in cols:
        conn.execute("ALTER TABLE session_messages ADD COLUMN tool_steps TEXT")
    if "truncated" not in cols:
        conn.execute("ALTER TABLE session_messages ADD COLUMN truncated INTEGER DEFAULT 0")
    # H17 问题3：持久化本轮 prompt_eval_count（上下文已用 token），历史/子会话加载时可恢复指示器
    if "prompt_eval_count" not in cols:
        conn.execute("ALTER TABLE session_messages ADD COLUMN prompt_eval_count INTEGER")
    # TS-120（0.3.0）：消息归档标记（已移入知识仓库的消息脱离模型上下文）
    if "archived" not in cols:
        conn.execute("ALTER TABLE session_messages ADD COLUMN archived INTEGER DEFAULT 0")
    # TS-109 增强（H18-3）：圆桌议题附件列（幂等迁移；旧库无此列时补齐）
    rt_cols = {r[1] for r in conn.execute("PRAGMA table_info(roundtables)").fetchall()}
    if rt_cols and "attachments" not in rt_cols:
        conn.execute("ALTER TABLE roundtables ADD COLUMN attachments TEXT")

    # TS-108 M3-2：agent_tasks 状态扩展迁移（027 版旧表 CHECK 无 'queued' → 重建）。
    # sqlite3 不支持修改 CHECK 约束，重建是唯一正路；数据逐列无损搬运。
    row = conn.execute(
        "SELECT sql FROM sqlite_master WHERE type='table' AND name='agent_tasks'"
    ).fetchone()
    if row and "'queued'" not in (row[0] or ""):
        conn.execute("""
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
        conn.execute("""
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
        conn.execute("DROP TABLE agent_tasks")
        conn.execute("ALTER TABLE agent_tasks_new RENAME TO agent_tasks")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_tasks_project ON agent_tasks(project_id)")
        # 迁移 DDL 在隐式事务中，必须显式提交：否则半成品状态对后续连接可见（建表重复/数据丢失）；
        # 进程中途崩溃则整体回滚，下次重连自动重迁，幂等。
        conn.commit()


def _gconn() -> sqlite3.Connection:
    # checkpoint-050：timeout=10 忙等待（锁竞争时重试而非立即报错）
    conn = sqlite3.connect(str(_GDB), timeout=10.0)
    _ensure_schema(conn)
    return conn


def _agent_conn(project_id: str) -> sqlite3.Connection:
    pdir = PROJECTS_ROOT / project_id
    pdir.mkdir(parents=True, exist_ok=True)
    db = pdir / "agents.db"
    # TS-115（3.26）：timeout 10→5s——读路径长时间忙等待会拖垮前端（会话选择器
    # 只显示部分会话），5s 内拿不到锁就快速失败，前端有超时+重试兜底。
    conn = sqlite3.connect(str(db), timeout=5.0)
    _ensure_schema(conn)
    return conn


# checkpoint-050 查虫修复 B-1（P0）：连接泄漏根治。
# 旧写法 `conn.commit(); conn.close()` 在 execute 抛异常（如 CHECK 约束违反）时
# 既不回滚也不关闭——泄漏的连接持有未提交事务的锁，后续读写全部
# "database is locked"，且异常回溯引用帧会延长泄漏连接存活时间（实测复现）。
# 统一改为上下文管理器：成功提交 / 异常回滚 / 任何情况都关闭。
from contextlib import contextmanager as _contextmanager


@_contextmanager
def _write_conn(project_id: str):
    """项目库写连接：_WRITE_LOCK 内，成功提交/异常回滚/必关闭。"""
    with _WRITE_LOCK:
        conn = _agent_conn(project_id)
        try:
            yield conn
            conn.commit()
        except Exception:
            try:
                conn.rollback()
            except Exception:
                pass
            raise
        finally:
            conn.close()


@_contextmanager
def _write_gconn():
    """全局库写连接：同 _write_conn（全局库）。"""
    with _WRITE_LOCK:
        conn = _gconn()
        try:
            yield conn
            conn.commit()
        except Exception:
            try:
                conn.rollback()
            except Exception:
                pass
            raise
        finally:
            conn.close()


@_contextmanager
def _read_conn(project_id: str):
    """项目库读连接：不加锁，必关闭。"""
    conn = _agent_conn(project_id)
    try:
        yield conn
    finally:
        conn.close()


@_contextmanager
def _read_gconn():
    """全局库读连接：不加锁，必关闭。"""
    conn = _gconn()
    try:
        yield conn
    finally:
        conn.close()


# ── Project CRUD ──────────────────────────────────────

def create_project(name: str, working_dir: Path | str) -> str:
    pid = str(uuid.uuid4())
    wd = Path(working_dir).expanduser().resolve()
    try:
        if not wd.exists():
            wd.mkdir(parents=True, exist_ok=True)
        # 验证可写
        test_file = wd / ".subagent_write_test"
        test_file.write_text("ok")
        test_file.unlink()
    except PermissionError:
        raise PermissionError(f"工作目录无写入权限: {wd}")
    except OSError as e:
        raise OSError(f"无法创建工作目录 {wd}: {e}")

    with _write_gconn() as conn:
        conn.execute("INSERT INTO projects (id, name, working_dir) VALUES (?, ?, ?)", (pid, name, str(wd)))
    return pid


def delete_project(pid: str) -> bool:
    import shutil as _shutil
    with _write_gconn() as conn:
        cur = conn.execute("DELETE FROM projects WHERE id = ?", (pid,))
        deleted = cur.rowcount > 0
    if deleted:
        pdir = PROJECTS_ROOT / pid
        if pdir.exists():
            _shutil.rmtree(str(pdir), ignore_errors=True)
    return deleted


def list_projects() -> list[dict[str, Any]]:
    with _read_gconn() as conn:
        rows = conn.execute("SELECT id, name, working_dir FROM projects ORDER BY created_at DESC").fetchall()
    return [{"id": r[0], "name": r[1], "working_dir": r[2]} for r in rows]


def get_project(pid: str) -> dict[str, Any] | None:
    """checkpoint-056：单项目查询（不存在返回 None），供端点校验项目存在性。"""
    with _read_gconn() as conn:
        row = conn.execute("SELECT id, name, working_dir FROM projects WHERE id = ?", (pid,)).fetchone()
    if not row:
        return None
    return {"id": row[0], "name": row[1], "working_dir": row[2]}


# ── checkpoint-058：独立 Agent（与项目平级的一等公民）─────────────────
# 注册在全局库 independent_agents 表；数据目录 PROJECTS_ROOT/ia-<id>/（与项目
# UUID 目录物理隔离，前缀 ia- 保证永不碰撞）。会话/消息/沙盒机制全部复用，
# 命名空间 project_id := "ia-<agent_id>"。删除任何项目都不会触碰 ia-* 目录。
INDEP_NS_PREFIX = "ia-"


def independent_agent_dir(agent_id: str) -> Path:
    return PROJECTS_ROOT / f"{INDEP_NS_PREFIX}{agent_id}"


def add_independent_agent(name: str, **kwargs) -> str:
    """创建独立 Agent：全局注册 + 命名空间 agents.db 注册 + 沙盒目录。"""
    aid = str(uuid.uuid4())
    with _write_gconn() as conn:
        conn.execute(
            "INSERT INTO independent_agents (id, name, role, system_prompt, model_name) VALUES (?, ?, ?, ?, ?)",
            (aid, name, kwargs.get("role"), kwargs.get("system_prompt"), kwargs.get("model_name")),
        )
    ns = f"{INDEP_NS_PREFIX}{aid}"
    with _write_conn(ns) as conn:
        conn.execute(
            "INSERT INTO agent_configs (id, project_id, name, type_, role, system_prompt, model_name) VALUES (?, ?, ?, 'main', ?, ?, ?)",
            (aid, ns, name, kwargs.get("role"), kwargs.get("system_prompt"), kwargs.get("model_name")),
        )
    sb = independent_agent_dir(aid) / "sandbox"
    sb.mkdir(parents=True, exist_ok=True)
    return aid


def list_independent_agents() -> list[dict[str, Any]]:
    with _read_gconn() as conn:
        rows = conn.execute(
            "SELECT id, name, role, system_prompt, model_name, created_at FROM independent_agents ORDER BY created_at"
        ).fetchall()
    return [{"id": r[0], "name": r[1], "role": r[2], "system_prompt": r[3],
             "model_name": r[4], "created_at": r[5]} for r in rows]


def get_independent_agent(agent_id: str) -> dict[str, Any] | None:
    with _read_gconn() as conn:
        row = conn.execute(
            "SELECT id, name, role, system_prompt, model_name FROM independent_agents WHERE id = ?",
            (agent_id,),
        ).fetchone()
    if not row:
        return None
    return {"id": row[0], "name": row[1], "role": row[2], "system_prompt": row[3], "model_name": row[4]}


def update_independent_agent(agent_id: str, **kwargs) -> bool:
    """更新独立 Agent（name/role/system_prompt/model_name）。显式分支，不拼字段名。

    全局注册表与命名空间 agent_configs 双写（后者供系统提示词注入读取）。
    """
    updated = False
    with _write_gconn() as conn:
        if kwargs.get("name") is not None:
            cur = conn.execute("UPDATE independent_agents SET name = ? WHERE id = ?", (kwargs["name"], agent_id))
            updated = updated or cur.rowcount > 0
        if kwargs.get("role") is not None:
            cur = conn.execute("UPDATE independent_agents SET role = ? WHERE id = ?", (kwargs["role"], agent_id))
            updated = updated or cur.rowcount > 0
        if kwargs.get("system_prompt") is not None:
            cur = conn.execute("UPDATE independent_agents SET system_prompt = ? WHERE id = ?", (kwargs["system_prompt"], agent_id))
            updated = updated or cur.rowcount > 0
        if kwargs.get("model_name") is not None:
            cur = conn.execute("UPDATE independent_agents SET model_name = ? WHERE id = ?", (kwargs["model_name"], agent_id))
            updated = updated or cur.rowcount > 0
    ns = f"{INDEP_NS_PREFIX}{agent_id}"
    try:
        with _write_conn(ns) as conn:
            if kwargs.get("name") is not None:
                conn.execute("UPDATE agent_configs SET name = ? WHERE id = ?", (kwargs["name"], agent_id))
            if kwargs.get("role") is not None:
                conn.execute("UPDATE agent_configs SET role = ? WHERE id = ?", (kwargs["role"], agent_id))
            if kwargs.get("system_prompt") is not None:
                conn.execute("UPDATE agent_configs SET system_prompt = ? WHERE id = ?", (kwargs["system_prompt"], agent_id))
            if kwargs.get("model_name") is not None:
                conn.execute("UPDATE agent_configs SET model_name = ? WHERE id = ?", (kwargs["model_name"], agent_id))
    except Exception:
        pass  # 命名空间同步失败不回滚全局表（下次读取以全局表为准）
    return updated


def delete_independent_agent(agent_id: str) -> bool:
    """删除独立 Agent：全局注册记录 + 命名空间数据目录（会话/消息/沙盒全清）。"""
    import shutil as _shutil
    with _write_gconn() as conn:
        cur = conn.execute("DELETE FROM independent_agents WHERE id = ?", (agent_id,))
        deleted = cur.rowcount > 0
    if deleted:
        d = independent_agent_dir(agent_id)
        if d.exists():
            _shutil.rmtree(str(d), ignore_errors=True)
    return deleted


def rename_project(pid: str, name: str) -> bool:
    with _write_gconn() as conn:
        cur = conn.execute("UPDATE projects SET name = ?, updated_at = datetime('now') WHERE id = ?", (name, pid))
        ok = cur.rowcount > 0
    return ok


# ── Agent config CRUD ─────────────────────────────────

def add_agent_config(project_id: str, name: str, type_: str, **kwargs) -> str:
    aid = str(uuid.uuid4())
    with _write_conn(project_id) as conn:
        conn.execute(
            "INSERT INTO agent_configs (id, project_id, name, type_, role, system_prompt, model_name, parent_agent_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (aid, project_id, name, type_, kwargs.get("role"), kwargs.get("system_prompt"), kwargs.get("model_name"), kwargs.get("parent_agent_id")),
        )
    return aid


def remove_agent_config(project_id: str, agent_id: str) -> bool:
    """删除 Agent 及其所有会话、消息、摘要（全清）。"""
    with _write_conn(project_id) as conn:
        # 先删关联数据
        conn.execute("DELETE FROM session_messages WHERE agent_id = ?", (agent_id,))
        conn.execute("DELETE FROM session_summaries WHERE agent_id = ?", (agent_id,))
        conn.execute("DELETE FROM sessions WHERE agent_id = ?", (agent_id,))
        # 再删 Agent 本身
        cur = conn.execute("DELETE FROM agent_configs WHERE id = ?", (agent_id,))
        deleted = cur.rowcount > 0
    return deleted


def update_agent_config(project_id: str, agent_id: str, **kwargs) -> bool:
    """更新 Agent 配置（name, role, system_prompt, model_name, parent_agent_id）。

    TS-103 B12：改为显式分支——每个允许字段一条静态 UPDATE 语句，
    不再把字段名拼进 SQL（原写法虽有白名单，但"拼接"本身是脆弱点）。
    传非白名单字段或全为 None → 返回 False（视为无有效更新）。
    """
    updated = False
    with _write_conn(project_id) as conn:
        if kwargs.get("name") is not None:
            cur = conn.execute("UPDATE agent_configs SET name = ? WHERE id = ? AND project_id = ?",
                               (kwargs["name"], agent_id, project_id))
            updated = updated or cur.rowcount > 0
        if kwargs.get("role") is not None:
            cur = conn.execute("UPDATE agent_configs SET role = ? WHERE id = ? AND project_id = ?",
                               (kwargs["role"], agent_id, project_id))
            updated = updated or cur.rowcount > 0
        if kwargs.get("system_prompt") is not None:
            cur = conn.execute("UPDATE agent_configs SET system_prompt = ? WHERE id = ? AND project_id = ?",
                               (kwargs["system_prompt"], agent_id, project_id))
            updated = updated or cur.rowcount > 0
        if kwargs.get("model_name") is not None:
            cur = conn.execute("UPDATE agent_configs SET model_name = ? WHERE id = ? AND project_id = ?",
                               (kwargs["model_name"], agent_id, project_id))
            updated = updated or cur.rowcount > 0
        if kwargs.get("parent_agent_id") is not None:
            cur = conn.execute("UPDATE agent_configs SET parent_agent_id = ? WHERE id = ? AND project_id = ?",
                               (kwargs["parent_agent_id"], agent_id, project_id))
            updated = updated or cur.rowcount > 0
    return updated


def list_agent_configs(project_id: str) -> list[dict[str, Any]]:
    with _read_conn(project_id) as conn:
        rows = conn.execute(
            "SELECT id, name, role, system_prompt, model_name, type_, parent_agent_id FROM agent_configs ORDER BY created_at"
        ).fetchall()
    return [
        {"id": r[0], "name": r[1], "role": r[2], "system_prompt": r[3],
         "model_name": r[4], "type_": r[5], "parent_agent_id": r[6]}
        for r in rows
    ]


def get_agent_config(project_id: str, agent_id: str) -> dict[str, Any] | None:
    with _read_conn(project_id) as conn:
        row = conn.execute(
            "SELECT id, name, role, system_prompt, model_name, type_, parent_agent_id FROM agent_configs WHERE id = ?",
            (agent_id,),
        ).fetchone()
    if not row:
        return None
    return {
        "id": row[0], "name": row[1], "role": row[2], "system_prompt": row[3],
        "model_name": row[4], "type_": row[5], "parent_agent_id": row[6],
    }


# ── Session CRUD ───────────────────────────────────────

def create_session(project_id: str, agent_id: str, title: str = "新会话") -> str:
    sid = str(uuid.uuid4())
    with _write_conn(project_id) as conn:
        conn.execute(
            "INSERT INTO sessions (id, agent_id, project_id, title) VALUES (?, ?, ?, ?)",
            (sid, agent_id, project_id, title),
        )
    return sid


def list_sessions(project_id: str, agent_id: str) -> list[dict[str, Any]]:
    # TS-115（3.26）：LEFT JOIN 一次查询消除 N+1。
    # 旧实现每个会话单独 SELECT COUNT(*)，会话多 + 写锁竞争（委派任务运行时
    # save_message/update_agent_task 频繁写）→ 读连接 10s 忙等待 → 前端拿不到完整列表。
    with _read_conn(project_id) as conn:
        rows = conn.execute("""
            SELECT s.id, s.title, s.created_at, s.updated_at,
                   COUNT(m.id) AS message_count
            FROM sessions s
            LEFT JOIN session_messages m ON m.session_id = s.id
            WHERE s.agent_id = ?
            GROUP BY s.id
            ORDER BY s.updated_at DESC
        """, (agent_id,)).fetchall()
        result = []
        for r in rows:
            result.append({
                "id": r[0], "title": r[1], "created_at": r[2],
                "updated_at": r[3], "message_count": r[4],
            })
    return result


def rename_session(project_id: str, session_id: str, title: str) -> bool:
    with _write_conn(project_id) as conn:
        cur = conn.execute(
            "UPDATE sessions SET title = ?, updated_at = datetime('now') WHERE id = ?",
            (title, session_id),
        )
        ok = cur.rowcount > 0
    return ok


def delete_session(project_id: str, session_id: str) -> bool:
    """删除会话及其所有消息和摘要（全清）。"""
    with _write_conn(project_id) as conn:
        conn.execute("DELETE FROM session_messages WHERE session_id = ?", (session_id,))
        conn.execute("DELETE FROM session_summaries WHERE session_id = ?", (session_id,))
        cur = conn.execute("DELETE FROM sessions WHERE id = ?", (session_id,))
        deleted = cur.rowcount > 0
    return deleted


# ── Message persistence ────────────────────────────────

def save_message(project_id: str, session_id: str, agent_id: str, role: str, content: str,
                 images: list[str] | None = None, model_used: str | None = None,
                 tool_steps: list[dict] | None = None, truncated: bool = False,
                 prompt_eval_count: int | None = None):
    with _write_conn(project_id) as conn:
        conn.execute(
            "INSERT INTO session_messages (session_id, agent_id, project_id, role, content, images, model_used, tool_steps, truncated, prompt_eval_count) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (session_id, agent_id, project_id, role, content,
             json.dumps(images) if images else None, model_used,
             json.dumps(tool_steps, ensure_ascii=False) if tool_steps else None,
             1 if truncated else 0, prompt_eval_count),
        )
        # 更新会话时间
        conn.execute("UPDATE sessions SET updated_at = datetime('now') WHERE id = ?", (session_id,))


def log_compact(project_id: str, session_id: str, before_tokens: int, after_tokens: int,
                archive_path: str | None, summary: str | None, error: str | None = None):
    """M2：写一条压缩日志（成功/失败都写）。"""
    with _write_conn(project_id) as conn:
        conn.execute(
            "INSERT INTO compact_log (session_id, project_id, before_tokens, after_tokens, archive_path, summary, error) VALUES (?, ?, ?, ?, ?, ?, ?)",
            (session_id, project_id, before_tokens, after_tokens, archive_path, summary, error),
        )


def load_compact_log(project_id: str, session_id: str, limit: int = 3) -> list[dict[str, Any]]:
    """M2：读最近 N 条压缩日志。"""
    with _read_conn(project_id) as conn:
        rows = conn.execute(
            "SELECT id, ts, before_tokens, after_tokens, archive_path, summary, error FROM compact_log WHERE session_id = ? ORDER BY id DESC LIMIT ?",
            (session_id, limit),
        ).fetchall()
    return [
        {"id": r[0], "ts": r[1], "before_tokens": r[2], "after_tokens": r[3],
         "archive_path": r[4], "summary": r[5], "error": r[6]}
        for r in rows
    ]


def delete_messages_before(project_id: str, session_id: str, keep_recent: int) -> int:
    """M2：删除待压缩区消息（保留最近 keep_recent 条），返回删除条数。"""
    with _write_conn(project_id) as conn:
        # 取最近 keep_recent 条的最小 id
        row = conn.execute(
            "SELECT id FROM session_messages WHERE session_id = ? ORDER BY id DESC LIMIT 1 OFFSET ?",
            (session_id, keep_recent - 1),
        ).fetchone()
        if not row:
            return 0
        cutoff_id = row[0]
        cur = conn.execute(
            "DELETE FROM session_messages WHERE session_id = ? AND id < ?",
            (session_id, cutoff_id),
        )
        deleted = cur.rowcount
    return deleted


def load_messages(project_id: str, session_id: str) -> list[dict[str, Any]]:
    with _read_conn(project_id) as conn:
        rows = conn.execute(
            "SELECT id, role, content, images, model_used, created_at, tool_steps, truncated, prompt_eval_count, COALESCE(archived, 0) FROM session_messages WHERE session_id = ? ORDER BY id",
            (session_id,),
        ).fetchall()
    result = []
    for r in rows:
        msg: dict[str, Any] = {"id": r[0], "role": r[1], "content": r[2], "model_used": r[4], "created_at": r[5]}
        if r[3]:
            try:
                msg["images"] = json.loads(r[3])
            except json.JSONDecodeError:
                pass
        if r[6]:
            try:
                msg["tool_steps"] = json.loads(r[6])
            except json.JSONDecodeError:
                pass
        if r[7]:
            msg["truncated"] = True
        if r[8] is not None:
            msg["prompt_eval_count"] = r[8]
        if r[9]:
            msg["archived"] = True  # TS-120：已移入知识仓库，脱离模型上下文
        result.append(msg)
    return result


def archive_messages(project_id: str, message_ids: list[int]) -> int:
    """TS-120（0.3.0）：把指定消息标记为已归档（移入知识仓库后脱离模型上下文）。
    消息内容仍保留在库中（前端占位显示），仅上下文构建时跳过。返回标记条数。"""
    if not message_ids:
        return 0
    placeholders = ",".join("?" for _ in message_ids)
    with _write_conn(project_id) as conn:
        cur = conn.execute(
            f"UPDATE session_messages SET archived = 1 WHERE id IN ({placeholders})",
            message_ids,
        )
        return cur.rowcount


# ── Summary ────────────────────────────────────────────

def save_session_summary(project_id: str, session_id: str, agent_id: str, summary_text: str) -> Path:
    with _WRITE_LOCK:
        work_dir = PROJECTS_ROOT / project_id / "work" / "summaries"
        work_dir.mkdir(parents=True, exist_ok=True)
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        fname = f"{agent_id[:8]}_{session_id[:8]}_{ts}.md"
        fpath = work_dir / fname
        fpath.write_text(f"# Session Summary\n\n{summary_text}", encoding="utf-8")

    with _write_conn(project_id) as conn:
        conn.execute(
            "INSERT INTO session_summaries (session_id, agent_id, project_id, summary_text) VALUES (?, ?, ?, ?)",
            (session_id, agent_id, project_id, summary_text),
        )
    return fpath


# ── M3-1（TS-107）：委派任务（agent_tasks）────────────

def create_agent_task(project_id: str, parent_agent_id: str, parent_session_id: str,
                      target_agent_id: str, target_agent_name: str,
                      task: str, expect: str) -> str:
    """创建一条委派任务（初始 status=running），返回 task_id。"""
    tid = str(uuid.uuid4())
    with _write_conn(project_id) as conn:
        conn.execute(
            "INSERT INTO agent_tasks (id, project_id, parent_agent_id, parent_session_id, "
            "target_agent_id, target_agent_name, task, expect) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (tid, project_id, parent_agent_id, parent_session_id,
             target_agent_id, target_agent_name, task, expect),
        )
    return tid


# 允许更新的字段白名单（显式分支，禁止 SET 拼接——B12 教训）
_TASK_UPDATABLE = ("status", "report", "fail_reason", "validation_failures", "session_id")


def update_agent_task(project_id: str, task_id: str, **fields) -> bool:
    """更新委派任务字段（白名单：status/report/fail_reason/validation_failures/session_id）。"""
    updated = False
    with _write_conn(project_id) as conn:
        if fields.get("status") is not None:
            cur = conn.execute("UPDATE agent_tasks SET status = ?, updated_at = datetime('now') "
                               "WHERE id = ? AND project_id = ?",
                               (fields["status"], task_id, project_id))
            updated = updated or cur.rowcount > 0
        if fields.get("report") is not None:
            cur = conn.execute("UPDATE agent_tasks SET report = ?, updated_at = datetime('now') "
                               "WHERE id = ? AND project_id = ?",
                               (fields["report"], task_id, project_id))
            updated = updated or cur.rowcount > 0
        if fields.get("fail_reason") is not None:
            cur = conn.execute("UPDATE agent_tasks SET fail_reason = ?, updated_at = datetime('now') "
                               "WHERE id = ? AND project_id = ?",
                               (fields["fail_reason"], task_id, project_id))
            updated = updated or cur.rowcount > 0
        if fields.get("validation_failures") is not None:
            cur = conn.execute("UPDATE agent_tasks SET validation_failures = ?, updated_at = datetime('now') "
                               "WHERE id = ? AND project_id = ?",
                               (fields["validation_failures"], task_id, project_id))
            updated = updated or cur.rowcount > 0
        if fields.get("session_id") is not None:
            cur = conn.execute("UPDATE agent_tasks SET session_id = ?, updated_at = datetime('now') "
                               "WHERE id = ? AND project_id = ?",
                               (fields["session_id"], task_id, project_id))
            updated = updated or cur.rowcount > 0
    return updated


def get_agent_task(project_id: str, task_id: str) -> dict[str, Any] | None:
    with _read_conn(project_id) as conn:
        row = conn.execute(
            "SELECT id, parent_agent_id, parent_session_id, target_agent_id, target_agent_name, "
            "task, expect, status, report, fail_reason, validation_failures, session_id, created_at, updated_at "
            "FROM agent_tasks WHERE id = ?",
            (task_id,),
        ).fetchone()
    if not row:
        return None
    report = None
    if row[8]:
        try:
            report = json.loads(row[8])
        except json.JSONDecodeError:
            report = {"raw": row[8]}
    return {
        "id": row[0], "parent_agent_id": row[1], "parent_session_id": row[2],
        "target_agent_id": row[3], "target_agent_name": row[4],
        "task": row[5], "expect": row[6], "status": row[7], "report": report,
        "fail_reason": row[9], "validation_failures": row[10], "session_id": row[11],
        "created_at": row[12], "updated_at": row[13],
    }


def list_agent_tasks(project_id: str, limit: int = 50) -> list[dict[str, Any]]:
    with _read_conn(project_id) as conn:
        rows = conn.execute(
            "SELECT id, parent_agent_id, parent_session_id, target_agent_id, target_agent_name, "
            "task, expect, status, report, fail_reason, validation_failures, session_id, created_at, updated_at "
            "FROM agent_tasks ORDER BY created_at DESC, rowid DESC LIMIT ?",
            (limit,),
        ).fetchall()
    out = []
    for row in rows:
        report = None
        if row[8]:
            try:
                report = json.loads(row[8])
            except json.JSONDecodeError:
                report = {"raw": row[8]}
        out.append({
            "id": row[0], "parent_agent_id": row[1], "parent_session_id": row[2],
            "target_agent_id": row[3], "target_agent_name": row[4],
            "task": row[5], "expect": row[6], "status": row[7], "report": report,
            "fail_reason": row[9], "validation_failures": row[10], "session_id": row[11],
            "created_at": row[12], "updated_at": row[13],
        })
    return out


def list_recent_delegations_to_target(project_id: str, target_agent_id: str,
                                      limit: int = 30) -> list[dict[str, Any]]:
    """checkpoint-068（3.22 D-8）：返回某主 Agent 对某目标最近的委派任务（新→旧）。
    供委派引擎按任务内容做去重与失败重试上限判断（内容匹配在引擎侧进行）。"""
    with _read_conn(project_id) as conn:
        rows = conn.execute(
            "SELECT id, status, task, created_at FROM agent_tasks "
            "WHERE project_id = ? AND target_agent_id = ? "
            "ORDER BY created_at DESC, rowid DESC LIMIT ?",
            (project_id, target_agent_id, limit)).fetchall()
    return [{"id": r[0], "status": r[1], "task": r[2], "created_at": r[3]} for r in rows]


# ── M3-3（TS-109）：圆桌讨论 ─────────────────────────

def create_roundtable(project_id: str, topic: str, participants: list[dict],
                      moderator: str, moderator_agent_id: str | None,
                      max_rounds: int, minutes: str,
                      attachments: list[dict] | None = None) -> str:
    rt_id = str(uuid.uuid4())
    with _write_conn(project_id) as conn:
        conn.execute(
            "INSERT INTO roundtables (id, project_id, topic, participants, moderator, "
            "moderator_agent_id, max_rounds, minutes, attachments) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (rt_id, project_id, topic, json.dumps(participants, ensure_ascii=False),
             moderator, moderator_agent_id, max_rounds, minutes,
             json.dumps(attachments or [], ensure_ascii=False)),
        )
    return rt_id


_RT_SELECT = ("SELECT id, project_id, topic, participants, moderator, moderator_agent_id, "
              "max_rounds, round, status, minutes, summary, created_at, updated_at, attachments FROM roundtables")


def _rt_row_to_dict(row) -> dict[str, Any]:
    try:
        participants = json.loads(row[3]) if row[3] else []
    except json.JSONDecodeError:
        participants = []
    try:
        attachments = json.loads(row[13]) if row[13] else []
    except (json.JSONDecodeError, IndexError):
        attachments = []
    return {
        "id": row[0], "project_id": row[1], "topic": row[2], "participants": participants,
        "moderator": row[4], "moderator_agent_id": row[5], "max_rounds": row[6],
        "round": row[7], "status": row[8], "minutes": row[9], "summary": row[10],
        "created_at": row[11], "updated_at": row[12], "attachments": attachments,
    }


def get_roundtable(project_id: str, rt_id: str) -> dict[str, Any] | None:
    with _read_conn(project_id) as conn:
        row = conn.execute(_RT_SELECT + " WHERE id = ? AND project_id = ?", (rt_id, project_id)).fetchone()
    return _rt_row_to_dict(row) if row else None


def list_roundtables(project_id: str, limit: int = 20) -> list[dict[str, Any]]:
    with _read_conn(project_id) as conn:
        rows = conn.execute(
            _RT_SELECT + " WHERE project_id = ? ORDER BY created_at DESC, rowid DESC LIMIT ?",
            (project_id, limit),
        ).fetchall()
    return [_rt_row_to_dict(r) for r in rows]


# 允许更新的字段白名单（显式分支，禁止 SET 拼接——B12 教训）
def update_roundtable(project_id: str, rt_id: str, **fields) -> bool:
    updated = False
    with _write_conn(project_id) as conn:
        if fields.get("round") is not None:
            cur = conn.execute("UPDATE roundtables SET round = ?, updated_at = datetime('now') "
                               "WHERE id = ? AND project_id = ?", (fields["round"], rt_id, project_id))
            updated = updated or cur.rowcount > 0
        if fields.get("status") is not None:
            cur = conn.execute("UPDATE roundtables SET status = ?, updated_at = datetime('now') "
                               "WHERE id = ? AND project_id = ?", (fields["status"], rt_id, project_id))
            updated = updated or cur.rowcount > 0
        if fields.get("minutes") is not None:
            cur = conn.execute("UPDATE roundtables SET minutes = ?, updated_at = datetime('now') "
                               "WHERE id = ? AND project_id = ?", (fields["minutes"], rt_id, project_id))
            updated = updated or cur.rowcount > 0
        if fields.get("summary") is not None:
            cur = conn.execute("UPDATE roundtables SET summary = ?, updated_at = datetime('now') "
                               "WHERE id = ? AND project_id = ?", (fields["summary"], rt_id, project_id))
            updated = updated or cur.rowcount > 0
    return updated


def add_roundtable_message(project_id: str, rt_id: str, round_no: int,
                           agent_id: str, agent_name: str, content: str, ok: bool = True):
    with _write_conn(project_id) as conn:
        conn.execute(
            "INSERT INTO roundtable_messages (rt_id, round, agent_id, agent_name, content, ok) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (rt_id, round_no, agent_id, agent_name, content, 1 if ok else 0),
        )


def list_roundtable_messages(project_id: str, rt_id: str) -> list[dict[str, Any]]:
    with _read_conn(project_id) as conn:
        rows = conn.execute(
            "SELECT id, rt_id, round, agent_id, agent_name, content, ok, created_at "
            "FROM roundtable_messages WHERE rt_id = ? ORDER BY id",
            (rt_id,),
        ).fetchall()
    return [
        {"id": r[0], "rt_id": r[1], "round": r[2], "agent_id": r[3], "agent_name": r[4],
         "content": r[5], "ok": bool(r[6]), "created_at": r[7]}
        for r in rows
    ]


def delete_roundtable(project_id: str, rt_id: str) -> bool:
    """删除圆桌及其全部发言记录（全清）。"""
    with _write_conn(project_id) as conn:
        conn.execute("DELETE FROM roundtable_messages WHERE rt_id = ?", (rt_id,))
        cur = conn.execute("DELETE FROM roundtables WHERE id = ? AND project_id = ?",
                           (rt_id, project_id))
        deleted = cur.rowcount > 0
    return deleted


# ---------- 0.2.1（TS-119）：工作流存储（全局库） ----------
# 写操作一律 _write_gconn()（锁内提交/回滚/必关闭），读操作 _read_gconn()（必关闭）
# ——禁止裸 _gconn()：with 只提交事务不关闭连接，会犯 checkpoint-050 修过的连接泄漏。
# UPDATE 一律显式分支（B12 教训：禁止 SET 拼接）。

def create_workflow(name: str, definition: dict, description: str = "",
                    built_in: bool = False) -> str:
    """创建工作流定义，返回 id。definition 为完整 JSON（nodes/edges/params）。"""
    wf_id = str(uuid.uuid4())
    with _write_gconn() as conn:
        conn.execute(
            "INSERT INTO workflows (id, name, description, definition, built_in) "
            "VALUES (?, ?, ?, ?, ?)",
            (wf_id, name, description or "", json.dumps(definition, ensure_ascii=False),
             1 if built_in else 0),
        )
    return wf_id


def update_workflow(wf_id: str, name: str | None = None, definition: dict | None = None,
                    description: str | None = None) -> bool:
    """更新工作流定义（部分更新；显式分支，禁止 SET 拼接——B12 教训）。"""
    updated = False
    with _write_gconn() as conn:
        if name is not None:
            cur = conn.execute("UPDATE workflows SET name = ?, updated_at = datetime('now') WHERE id = ?",
                               (name, wf_id))
            updated = updated or cur.rowcount > 0
        if description is not None:
            cur = conn.execute("UPDATE workflows SET description = ?, updated_at = datetime('now') WHERE id = ?",
                               (description, wf_id))
            updated = updated or cur.rowcount > 0
        if definition is not None:
            cur = conn.execute("UPDATE workflows SET definition = ?, updated_at = datetime('now') WHERE id = ?",
                               (json.dumps(definition, ensure_ascii=False), wf_id))
            updated = updated or cur.rowcount > 0
    return updated


def list_workflows() -> list[dict[str, Any]]:
    """列出全部工作流定义（新→旧）。"""
    with _read_gconn() as conn:
        rows = conn.execute(
            "SELECT id, name, description, definition, built_in, created_at, updated_at "
            "FROM workflows ORDER BY created_at DESC, rowid DESC"
        ).fetchall()
    result = []
    for r in rows:
        try:
            defn = json.loads(r[3])
        except json.JSONDecodeError:
            defn = {"nodes": [], "edges": []}
        result.append({"id": r[0], "name": r[1], "description": r[2],
                       "definition": defn, "built_in": bool(r[4]),
                       "created_at": r[5], "updated_at": r[6]})
    return result


def get_workflow(wf_id: str) -> dict[str, Any] | None:
    with _read_gconn() as conn:
        r = conn.execute(
            "SELECT id, name, description, definition, built_in, created_at, updated_at "
            "FROM workflows WHERE id = ?", (wf_id,)).fetchone()
    if not r:
        return None
    try:
        defn = json.loads(r[3])
    except json.JSONDecodeError:
        defn = {"nodes": [], "edges": []}
    return {"id": r[0], "name": r[1], "description": r[2], "definition": defn,
            "built_in": bool(r[4]), "created_at": r[5], "updated_at": r[6]}


def delete_workflow(wf_id: str) -> bool:
    """删除工作流定义（运行记录与节点事件保留作历史）。内置工作流不可删。"""
    wf = get_workflow(wf_id)
    if not wf or wf.get("built_in"):
        return False
    with _write_gconn() as conn:
        cur = conn.execute("DELETE FROM workflows WHERE id = ?", (wf_id,))
        return cur.rowcount > 0


def create_workflow_run(workflow_id: str, variables: dict | None = None) -> str:
    run_id = str(uuid.uuid4())
    with _write_gconn() as conn:
        conn.execute(
            "INSERT INTO workflow_runs (id, workflow_id, status, variables) VALUES (?, ?, 'running', ?)",
            (run_id, workflow_id, json.dumps(variables or {}, ensure_ascii=False)),
        )
    return run_id


def update_workflow_run(run_id: str, status: str | None = None, current_node: str | None = None,
                        variables: dict | None = None, result: str | None = None,
                        error: str | None = None) -> bool:
    """更新运行记录（显式分支，禁止 SET 拼接——B12 教训）。"""
    updated = False
    with _write_gconn() as conn:
        if status is not None:
            cur = conn.execute("UPDATE workflow_runs SET status = ?, updated_at = datetime('now') WHERE id = ?",
                               (status, run_id))
            updated = updated or cur.rowcount > 0
        if current_node is not None:
            cur = conn.execute("UPDATE workflow_runs SET current_node = ?, updated_at = datetime('now') WHERE id = ?",
                               (current_node, run_id))
            updated = updated or cur.rowcount > 0
        if variables is not None:
            cur = conn.execute("UPDATE workflow_runs SET variables = ?, updated_at = datetime('now') WHERE id = ?",
                               (json.dumps(variables, ensure_ascii=False), run_id))
            updated = updated or cur.rowcount > 0
        if result is not None:
            cur = conn.execute("UPDATE workflow_runs SET result = ?, updated_at = datetime('now') WHERE id = ?",
                               (result, run_id))
            updated = updated or cur.rowcount > 0
        if error is not None:
            cur = conn.execute("UPDATE workflow_runs SET error = ?, updated_at = datetime('now') WHERE id = ?",
                               (error, run_id))
            updated = updated or cur.rowcount > 0
    return updated


def get_workflow_run(run_id: str) -> dict[str, Any] | None:
    with _read_gconn() as conn:
        r = conn.execute(
            "SELECT id, workflow_id, status, current_node, variables, result, error, "
            "created_at, updated_at FROM workflow_runs WHERE id = ?", (run_id,)).fetchone()
    if not r:
        return None
    try:
        variables = json.loads(r[4]) if r[4] else {}
    except json.JSONDecodeError:
        variables = {}
    return {"id": r[0], "workflow_id": r[1], "status": r[2], "current_node": r[3],
            "variables": variables, "result": r[5], "error": r[6],
            "created_at": r[7], "updated_at": r[8]}


def list_workflow_runs(workflow_id: str | None = None, limit: int = 30) -> list[dict[str, Any]]:
    """列出运行记录（新→旧），可按工作流过滤。"""
    with _read_gconn() as conn:
        if workflow_id:
            rows = conn.execute(
                "SELECT id, workflow_id, status, current_node, result, error, created_at "
                "FROM workflow_runs WHERE workflow_id = ? ORDER BY created_at DESC LIMIT ?",
                (workflow_id, limit)).fetchall()
        else:
            rows = conn.execute(
                "SELECT id, workflow_id, status, current_node, result, error, created_at "
                "FROM workflow_runs ORDER BY created_at DESC LIMIT ?", (limit,)).fetchall()
    return [{"id": r[0], "workflow_id": r[1], "status": r[2], "current_node": r[3],
             "result": r[4], "error": r[5], "created_at": r[6]} for r in rows]


def append_workflow_node_event(run_id: str, node_id: str, node_type: str, status: str,
                               model_used: str | None = None, input_summary: str = "",
                               output_summary: str = "", error: str | None = None,
                               retry_count: int = 0, duration_ms: int | None = None) -> None:
    """追加一条节点事件（运行监控实时读）。"""
    with _write_gconn() as conn:
        conn.execute(
            "INSERT INTO workflow_node_events (run_id, node_id, node_type, status, model_used, "
            "input_summary, output_summary, error, retry_count, duration_ms) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (run_id, node_id, node_type, status, model_used,
             input_summary[:2000], output_summary[:2000], error, retry_count, duration_ms),
        )


def list_workflow_node_events(run_id: str) -> list[dict[str, Any]]:
    with _read_gconn() as conn:
        rows = conn.execute(
            "SELECT id, node_id, node_type, status, model_used, input_summary, "
            "output_summary, error, retry_count, duration_ms, created_at "
            "FROM workflow_node_events WHERE run_id = ? ORDER BY id",
            (run_id,)).fetchall()
    return [{"id": r[0], "node_id": r[1], "node_type": r[2], "status": r[3],
             "model_used": r[4], "input_summary": r[5], "output_summary": r[6],
             "error": r[7], "retry_count": r[8], "duration_ms": r[9],
             "created_at": r[10]} for r in rows]

