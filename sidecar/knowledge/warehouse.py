"""TS-120 一期（0.3.0）：知识仓库（拉模式）。

与 M4 知识（推模式，自动注入系统提示词）严格区分：
- 本模块 = 拉模式仓库：对话/知识转移进来成为独立 .md 文件，永久保存；
  只有用户显式搜索/勾选，或被指令的搜索才读取。Agent 永不自动读取。
- 存储：文件是本体（每条一个 .md），SQLite 索引可重建（容灾）。

作用域与路径（用户拍板）：
- 项目知识 → {项目工作目录}/知识库/   （Finder 可见，用户直接管理）
- 全局知识 → {data_root}/knowledge/global/  （应用数据深层，从设置页打开）

索引：统一存 {data_root}/knowledge/index.db 的 knowledge_entries 表
（FTS5 全文，jieba 中文分词）。全局/项目条目同表，scope 字段区分。
"""
from __future__ import annotations

import json
import sqlite3
import uuid
from datetime import datetime
from pathlib import Path
from typing import Any

from sidecar.config import data_root

# ---------- 目录 ----------
GLOBAL_SCOPE = "global"
PROJECT_SCOPE = "project"
PROJECT_DIR_NAME = "知识库"  # 用户拍板：明目录，不隐藏，方便直接找文件

# 测试钩子：覆盖数据根（生产环境为 None，走 data_root()）
_DATA_ROOT_OVERRIDE: Path | None = None


def _base_root() -> Path:
    return _DATA_ROOT_OVERRIDE if _DATA_ROOT_OVERRIDE is not None else data_root()


def global_knowledge_dir() -> Path:
    p = _base_root() / "knowledge" / "global"
    p.mkdir(parents=True, exist_ok=True)
    return p


def project_knowledge_dir(project_id: str) -> Path | None:
    """项目知识目录 = 项目工作目录/知识库/。项目不存在 → None。"""
    try:
        from sidecar.storage.store import list_projects
        for proj in list_projects():
            if proj.get("id") == project_id:
                wd = proj.get("working_dir")
                if wd:
                    p = Path(str(wd)).expanduser() / PROJECT_DIR_NAME
                    p.mkdir(parents=True, exist_ok=True)
                    return p
    except Exception:
        pass
    return None


def scope_dir(scope: str, project_id: str | None) -> Path | None:
    if scope == GLOBAL_SCOPE:
        return global_knowledge_dir()
    if scope == PROJECT_SCOPE and project_id:
        return project_knowledge_dir(project_id)
    return None


# ---------- 索引库 ----------
_INDEX_DB_PATH: Path | None = None  # 测试可改写


def _index_db_path() -> Path:
    if _INDEX_DB_PATH is not None:
        return _INDEX_DB_PATH
    return _base_root() / "knowledge" / "index.db"


def _ensure_schema(conn: sqlite3.Connection) -> None:
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS knowledge_entries (
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
        CREATE INDEX IF NOT EXISTS idx_ke_scope ON knowledge_entries(scope, project_id);
        -- FTS5 全文（分词后的内容），external content 简化：独立表存分词文本
        CREATE VIRTUAL TABLE IF NOT EXISTS knowledge_fts USING fts5(
            entry_id UNINDEXED, title, keywords, body
        );
    """)


def _iconn(write: bool = False) -> sqlite3.Connection:
    path = _index_db_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(path), timeout=10.0)
    _ensure_schema(conn)
    return conn


# ---------- 分词 ----------
# 中文高频停用词：这些词在正文中普遍存在，若参与 OR 检索会污染结果
# （搜任意词都命中"的/了/是"所在的全部条目）。分词时过滤。
_STOPWORDS = {
    "的", "了", "是", "在", "和", "与", "及", "或", "也", "都", "就", "而", "及",
    "我", "你", "他", "她", "它", "我们", "你们", "他们", "这", "那", "这个",
    "那个", "这些", "那些", "有", "没有", "不", "很", "最", "更", "把", "被",
    "着", "过", "吗", "呢", "啊", "吧", "呀", "哦", "嗯", "一", "个", "为",
    "以", "对", "从", "到", "向", "于", "之", "其", "此", "该", "等", "并",
    "但", "但是", "如果", "因为", "所以", "虽然", "可以", "能", "会", "要",
    "需要", "让", "请", "将", "已", "还", "再", "只", "才", "便", "即",
}


def _tokenize(text: str) -> str:
    """jieba 分词 → 过滤停用词 → 空格连接（供 FTS5 索引与查询）。"""
    if not text:
        return ""
    try:
        import jieba
        return " ".join(w for w in jieba.cut(text) if w.strip() and w not in _STOPWORDS)
    except Exception:
        # jieba 不可用（理论不会，已装）→ 退化为逐字符空格分隔（仍过滤停用词）
        return " ".join(ch for ch in text if ch.strip() and ch not in _STOPWORDS)


# ---------- .md 条目读写 ----------
def _entry_to_md(entry: dict[str, Any], body: str) -> str:
    """生成带 frontmatter 的 .md 文本。"""
    kw = entry.get("keywords") or []
    if isinstance(kw, str):
        kw = [k.strip() for k in kw.split(",") if k.strip()]
    lines = [
        "---",
        f"id: {entry['id']}",
        f"title: {entry.get('title', '')}",
        f"scope: {entry.get('scope', PROJECT_SCOPE)}",
        f"project_id: {entry.get('project_id') or ''}",
        f"category: {entry.get('category') or ''}",
        f"keywords: {json.dumps(kw, ensure_ascii=False)}",
        f"source: {entry.get('source', 'chat')}",
        f"created_at: {entry.get('created_at', '')}",
        "---",
        "",
        body,
    ]
    return "\n".join(lines)


def _parse_md(text: str) -> tuple[dict[str, Any], str]:
    """解析 .md：返回 (frontmatter dict, 正文)。无 frontmatter → ({}, 全文)。"""
    if not text.startswith("---"):
        return {}, text
    lines = text.split("\n")
    end = -1
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            end = i
            break
    if end < 0:
        return {}, text
    meta: dict[str, Any] = {}
    for line in lines[1:end]:
        if ":" not in line:
            continue
        k, _, v = line.partition(":")
        k, v = k.strip(), v.strip()
        if k == "keywords":
            try:
                meta[k] = json.loads(v)
            except json.JSONDecodeError:
                meta[k] = [x.strip() for x in v.split(",") if x.strip()]
        else:
            meta[k] = v
    body = "\n".join(lines[end + 1:]).lstrip("\n")
    return meta, body


# ---------- CRUD ----------
def add_entry(scope: str, project_id: str | None, title: str, body: str,
              category: str = "", keywords: list[str] | None = None,
              source: str = "chat") -> dict[str, Any] | None:
    """新增知识条目：写 .md 文件 + 写索引。文件写失败 → None。"""
    kdir = scope_dir(scope, project_id)
    if kdir is None:
        return None
    entry_id = str(uuid.uuid4())
    created_at = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    entry = {
        "id": entry_id, "title": title or "未命名", "scope": scope,
        "project_id": project_id or "", "category": category or "",
        "keywords": keywords or [], "source": source, "created_at": created_at,
    }
    # 文件名：标题安全化 + id 前 8 位防重名
    safe_title = "".join(c for c in (title or "") if c.isalnum() or c in " _-（）()").strip()[:20] or "条目"
    fname = f"{safe_title}-{entry_id[:8]}.md"
    fpath = kdir / fname
    try:
        fpath.write_text(_entry_to_md(entry, body), encoding="utf-8")
    except OSError:
        return None
    conn = _iconn()
    try:
        kw_str = " ".join(keywords or [])
        conn.execute(
            "INSERT INTO knowledge_entries (id, title, scope, project_id, category, "
            "keywords, source, file_path, created_at) VALUES (?,?,?,?,?,?,?,?,?)",
            (entry_id, entry["title"], scope, project_id or "", category or "",
             json.dumps(keywords or [], ensure_ascii=False), source, str(fpath), created_at))
        # FTS5：标题/关键词/正文分词后入库
        conn.execute(
            "INSERT INTO knowledge_fts (entry_id, title, keywords, body) VALUES (?,?,?,?)",
            (entry_id, _tokenize(entry["title"]), _tokenize(kw_str), _tokenize(body)))
        conn.commit()
    finally:
        conn.close()
    return {**entry, "file_path": str(fpath), "body": body}


def get_entry(entry_id: str) -> dict[str, Any] | None:
    conn = _iconn()
    try:
        row = conn.execute(
            "SELECT id, title, scope, project_id, category, keywords, source, "
            "file_path, created_at FROM knowledge_entries WHERE id = ?", (entry_id,)).fetchone()
    finally:
        conn.close()
    if not row:
        return None
    entry = {"id": row[0], "title": row[1], "scope": row[2], "project_id": row[3],
             "category": row[4], "source": row[6], "file_path": row[7], "created_at": row[8]}
    try:
        entry["keywords"] = json.loads(row[5]) if row[5] else []
    except json.JSONDecodeError:
        entry["keywords"] = []
    # 读正文
    try:
        _, body = _parse_md(Path(row[7]).read_text(encoding="utf-8"))
        entry["body"] = body
    except OSError:
        entry["body"] = ""
    return entry


def list_entries(scope: str | None = None, project_id: str | None = None) -> list[dict[str, Any]]:
    """列出条目（可按作用域/项目过滤），新→旧。"""
    conn = _iconn()
    try:
        if scope and project_id:
            rows = conn.execute(
                "SELECT id, title, scope, project_id, category, keywords, source, file_path, created_at "
                "FROM knowledge_entries WHERE scope=? AND project_id=? ORDER BY created_at DESC, rowid DESC",
                (scope, project_id)).fetchall()
        elif scope:
            rows = conn.execute(
                "SELECT id, title, scope, project_id, category, keywords, source, file_path, created_at "
                "FROM knowledge_entries WHERE scope=? ORDER BY created_at DESC, rowid DESC",
                (scope,)).fetchall()
        else:
            rows = conn.execute(
                "SELECT id, title, scope, project_id, category, keywords, source, file_path, created_at "
                "FROM knowledge_entries ORDER BY created_at DESC, rowid DESC").fetchall()
    finally:
        conn.close()
    out = []
    for r in rows:
        try:
            kw = json.loads(r[5]) if r[5] else []
        except json.JSONDecodeError:
            kw = []
        out.append({"id": r[0], "title": r[1], "scope": r[2], "project_id": r[3],
                    "category": r[4], "keywords": kw, "source": r[6],
                    "file_path": r[7], "created_at": r[8]})
    return out


def delete_entry(entry_id: str) -> bool:
    """删除条目：删 .md 文件 + 索引 + FTS。"""
    entry = get_entry(entry_id)
    conn = _iconn()
    try:
        conn.execute("DELETE FROM knowledge_entries WHERE id = ?", (entry_id,))
        conn.execute("DELETE FROM knowledge_fts WHERE entry_id = ?", (entry_id,))
        conn.commit()
    finally:
        conn.close()
    if entry and entry.get("file_path"):
        try:
            Path(entry["file_path"]).unlink(missing_ok=True)
        except OSError:
            pass
    return entry is not None


def search_entries(query: str, scope: str | None = None,
                   project_id: str | None = None, limit: int = 20) -> list[dict[str, Any]]:
    """关键词检索（FTS5）。返回条目（含正文预览），按相关度。"""
    if not query or not query.strip():
        return []
    q_tok = _tokenize(query.strip())
    # FTS5 MATCH 用分词后的词做 OR 查询（任一命中即返回）
    terms = [f'"{t}"' for t in q_tok.split() if t]
    if not terms:
        return []
    match_expr = " OR ".join(terms)
    conn = _iconn()
    try:
        sql = ("SELECT f.entry_id, bm25(knowledge_fts) AS score "
               "FROM knowledge_fts f WHERE knowledge_fts MATCH ? ")
        params: list[Any] = [match_expr]
        if scope:
            sql += "AND f.entry_id IN (SELECT id FROM knowledge_entries WHERE scope=? "
            params.append(scope)
            if project_id:
                sql += "AND project_id=? "
                params.append(project_id)
            sql += ") "
        sql += "ORDER BY score LIMIT ?"
        params.append(limit)
        try:
            rows = conn.execute(sql, params).fetchall()
        except sqlite3.OperationalError:
            return []  # FTS 查询语法异常（如全是标点）→ 空结果
    finally:
        conn.close()
    results = []
    for entry_id, _score in rows:
        e = get_entry(entry_id)
        if e:
            results.append(e)
    return results


def prune_missing() -> int:
    """索引与磁盘对账：索引中 .md 文件已不存在（用户在 Finder 外部删除）→
    从索引表与 FTS 中清除。文件是本体（source of truth），索引单向跟随。
    返回清除的条目数。"""
    conn = _iconn()
    try:
        rows = conn.execute("SELECT id, file_path FROM knowledge_entries").fetchall()
        missing = [rid for rid, fp in rows if not Path(str(fp)).is_file()]
        for rid in missing:
            conn.execute("DELETE FROM knowledge_entries WHERE id = ?", (rid,))
            conn.execute("DELETE FROM knowledge_fts WHERE entry_id = ?", (rid,))
        conn.commit()
    finally:
        conn.close()
    return len(missing)


def rebuild_index() -> int:
    """重建索引：扫描作用域目录内全部 .md，清空索引后重新写入。返回条目数。"""
    from sidecar.storage.store import list_projects
    conn = _iconn()
    try:
        conn.execute("DELETE FROM knowledge_entries")
        conn.execute("DELETE FROM knowledge_fts")
        conn.commit()
    finally:
        conn.close()
    count = 0
    # 全局
    for f in global_knowledge_dir().glob("*.md"):
        if _reindex_file(f, GLOBAL_SCOPE, ""):
            count += 1
    # 各项目
    try:
        projects = list_projects()
    except Exception:
        projects = []
    for proj in projects:
        wd = proj.get("working_dir")
        if not wd:
            continue
        kdir = Path(str(wd)).expanduser() / PROJECT_DIR_NAME
        if not kdir.is_dir():
            continue
        for f in kdir.glob("*.md"):
            if _reindex_file(f, PROJECT_SCOPE, proj.get("id")):
                count += 1
    return count


def _reindex_file(fpath: Path, scope: str, project_id: str) -> bool:
    try:
        text = fpath.read_text(encoding="utf-8")
    except OSError:
        return False
    meta, body = _parse_md(text)
    entry_id = str(meta.get("id") or uuid.uuid4())
    kw = meta.get("keywords") or []
    if isinstance(kw, str):
        kw = [k.strip() for k in kw.split(",") if k.strip()]
    conn = _iconn()
    try:
        conn.execute(
            "INSERT OR REPLACE INTO knowledge_entries (id, title, scope, project_id, category, "
            "keywords, source, file_path, created_at) VALUES (?,?,?,?,?,?,?,?,?)",
            (entry_id, str(meta.get("title") or fpath.stem), scope,
             str(meta.get("project_id") or project_id or ""), str(meta.get("category") or ""),
             json.dumps(kw, ensure_ascii=False), str(meta.get("source") or "manual"),
             str(fpath), str(meta.get("created_at") or "")))
        conn.execute(
            "INSERT INTO knowledge_fts (entry_id, title, keywords, body) VALUES (?,?,?,?)",
            (entry_id, _tokenize(str(meta.get("title") or "")),
             _tokenize(" ".join(kw)), _tokenize(body)))
        conn.commit()
    finally:
        conn.close()
    return True
