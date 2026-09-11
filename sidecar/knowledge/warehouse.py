# VetarAI - Local-first multi-agent orchestration application
# Copyright (C) 2026 zero11924065-dev
#
# This file is part of VetarAI.
#
# VetarAI is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# VetarAI is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with VetarAI. If not, see <https://www.gnu.org/licenses/>.
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

# ---------- A10（0.4.18）：知识目录可索引的文档格式 ----------
# ⛔ **从 parser 推导，不另写一份清单**：C3 刚清理过"前端 PARSEABLE_EXTS 与后端
#    SUPPORTED_EXTS 双源漂移"（前端缺 .pptx 致其永不解析），此处不能重犯。
#    可索引 = 解析器支持的全部 − 图片（无语义文本可索引，走视觉链路）− .md
#    （.md 是本模块自己的条目格式，走 frontmatter 路径而非解析器）。
#    → parser 将来加格式（如 .odt），知识索引自动跟上，无需改这里。
try:
    from sidecar.attachments.parser import (SUPPORTED_EXTS as _P_SUPPORTED_EXTS,
                                            IMAGE_EXTS as _P_IMAGE_EXTS)
    INDEXABLE_DOC_EXTS = frozenset(_P_SUPPORTED_EXTS - _P_IMAGE_EXTS - {".md"})
except Exception:                                # pragma: no cover - 导入失败兜底
    INDEXABLE_DOC_EXTS = frozenset({".pdf", ".docx", ".doc", ".xlsx", ".xlsm",
                                    ".pptx", ".txt", ".csv", ".json"})

# ⛔ 源文件字节上限：解析必须**整读**（二进制容器截断即坏），需内存保护阈值。
#    与工作流 file_read 节点的 _FILE_READ_MAX_SOURCE_BYTES 同量级（同一理由）。
_KNOWLEDGE_MAX_SOURCE_BYTES = 20 * 1024 * 1024
# ⛔ 索引正文字符上限：超长正文进 FTS/向量既无检索收益（分词后噪声压过信号），
#    又拖慢重建与编码。与聊天附件 _CHAT_ATT_MAX_CHARS_EACH 同量级。
_KNOWLEDGE_MAX_INDEX_CHARS = 200_000

# ⛔ A10 新增 source 取值：**用户自己丢进知识目录的外部文件**。
#    与 'chat'（会话转移生成）/'manual'（面板手动创建）的关键区别 ——
#    文件本体属用户，⛔ **删条目时绝不能 unlink 它**（见 delete_entry 的守卫）。
SOURCE_IMPORTED_FILE = "file"

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
    # ⛔ A10（0.4.18）：source 的 CHECK 原为 IN ('chat','manual')，导入的外部文件需
    #    写入 'file'（语义不同：文件本体属用户，删条目时不得 unlink）。
    #    SQLite 的 CHECK 约束**不能 ALTER**，而真实用户库里已存在旧约束的表 →
    #    必须检测并重建表迁移（索引可从文件重建，但迁移时**保留现有行**更安全，
    #    免去用户重建索引的等待）。
    row = conn.execute(
        "SELECT sql FROM sqlite_master WHERE type='table' AND name='knowledge_entries'"
    ).fetchone()
    if row and row[0] and "'chat','manual'" in row[0].replace(" ", ""):
        # 旧表：重建迁移（事务内完成，失败回滚不留半截）
        conn.executescript("""
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

    conn.executescript("""
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
        -- FTS5 全文（分词后的内容），external content 简化：独立表存分词文本
        CREATE VIRTUAL TABLE IF NOT EXISTS knowledge_fts USING fts5(
            entry_id UNINDEXED, title, keywords, body
        );
        -- TS-120 阶段二：语义向量（bge-m3 ONNX INT8 三合一模型的 dense + sparse 两路）。
        -- dense = float32 BLOB（1024 维，已归一化）；sparse = JSON {token: weight}。
        -- 模型不可用时条目照常存在、向量留空（检索自动降级为纯关键词）。
        CREATE TABLE IF NOT EXISTS knowledge_embeddings (
            entry_id TEXT PRIMARY KEY,
            dense BLOB,
            sparse TEXT,
            model TEXT NOT NULL DEFAULT 'bge-m3-onnx-int8',
            updated_at TEXT NOT NULL
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
    # TS-120 阶段二：语义向量编码（模型不可用静默降级，不阻塞条目创建）
    _embed_entry(entry_id, entry["title"], body, keywords or [])
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
    # ⛔ A10（0.4.18）：source='file' 是用户导入的二进制文档（docx/pdf/xlsx…），
    #    不能走 read_text+_parse_md —— 对二进制会抛 UnicodeDecodeError（不是 OSError，
    #    原 except 捕不到 → get_entry 崩溃，用户点开导入条目详情即报错）。
    #    改按 source 分流：file 条目用 parse_attachment（与 _reindex_doc 索引时同源），
    #    md/manual/chat 仍走 _parse_md（行为不变）。
    fp = Path(row[7])
    if entry.get("source") == SOURCE_IMPORTED_FILE:
        try:
            from sidecar.attachments.parser import parse_attachment
            text, _kind = parse_attachment(fp.name, fp.read_bytes())
            entry["body"] = (text or "")[:_KNOWLEDGE_MAX_INDEX_CHARS]
        except Exception:
            entry["body"] = ""           # 文件已删/损坏 → 空正文，不崩溃
    else:
        try:
            _, body = _parse_md(fp.read_text(encoding="utf-8"))
            entry["body"] = body
        except (OSError, UnicodeDecodeError):
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
    """删除条目：删**本模块生成的** .md 文件 + 索引 + FTS + 向量（阶段二）。

    ⛔ A10（0.4.18）数据安全守卫：source='file' 的条目是**用户自己丢进知识目录的
    外部文件**（.docx/.pdf/.xlsx…），文件本体属用户、不是本模块的产物。
    若照旧 unlink，用户在面板删一条索引就会**永久删掉自己的原始文档**（不可恢复）。
    故这类条目只删索引记录，⛔ 绝不动磁盘文件 —— 用户想删文件请自己在 Finder 删
    （删后 prune_missing 会自动清掉失效索引，语义一致）。
    'chat'/'manual' 条目仍删文件（那是本模块生成的 .md，删条目=删本体，语义正确）。
    """
    entry = get_entry(entry_id)
    conn = _iconn()
    try:
        conn.execute("DELETE FROM knowledge_entries WHERE id = ?", (entry_id,))
        conn.execute("DELETE FROM knowledge_fts WHERE entry_id = ?", (entry_id,))
        conn.execute("DELETE FROM knowledge_embeddings WHERE entry_id = ?", (entry_id,))
        conn.commit()
    finally:
        conn.close()
    if entry and entry.get("file_path") and entry.get("source") != SOURCE_IMPORTED_FILE:
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


# ---------- TS-120 阶段二：语义/混合检索 ----------
def _scope_entry_ids(scope: str | None, project_id: str | None) -> set[str] | None:
    """作用域过滤的条目 id 集合；无过滤返回 None（不过滤）。"""
    if not scope:
        return None
    conn = _iconn()
    try:
        if project_id:
            rows = conn.execute(
                "SELECT id FROM knowledge_entries WHERE scope=? AND project_id=?",
                (scope, project_id)).fetchall()
        else:
            rows = conn.execute(
                "SELECT id FROM knowledge_entries WHERE scope=?", (scope,)).fetchall()
    finally:
        conn.close()
    return {r[0] for r in rows}


def semantic_search(query: str, scope: str | None = None,
                    project_id: str | None = None, limit: int = 20) -> list[dict[str, Any]]:
    """语义检索（bge-m3 稠密余弦 + 稀疏点积加权融合）。

    模型/向量不可用 → 抛 EmbedUnavailableError 之外的情况返回空列表，
    由上层决定降级。评分 = 0.7*余弦 + 0.3*稀疏点积（稀疏权重和通常远小于 1，
    自然被余弦主导，稀疏只做同义近义的补强）。
    """
    if not query or not query.strip():
        return []
    from sidecar.knowledge import embedder
    if not embedder.model_available():
        return []
    try:
        q = embedder.encode_one(query.strip(), with_query_instruction=True)
    except Exception:
        return []
    allowed = _scope_entry_ids(scope, project_id)
    conn = _iconn()
    try:
        rows = conn.execute("SELECT entry_id, dense, sparse FROM knowledge_embeddings").fetchall()
    finally:
        conn.close()
    scored: list[tuple[float, str]] = []
    for eid, dense_blob, sparse_json in rows:
        if allowed is not None and eid not in allowed:
            continue
        if not dense_blob:
            continue
        d_dense = embedder.blob_to_dense(dense_blob)
        cos = embedder.cosine(q["dense"], d_dense)
        try:
            d_sparse = json.loads(sparse_json) if sparse_json else {}
        except json.JSONDecodeError:
            d_sparse = {}
        sp = embedder.sparse_dot(q["sparse"], d_sparse)
        score = 0.7 * cos + 0.3 * min(sp, 1.0)
        scored.append((score, eid))
    scored.sort(key=lambda x: -x[0])
    results = []
    for score, eid in scored[:limit]:
        e = get_entry(eid)
        if e:
            e = {**e, "score": round(float(score), 4)}
            results.append(e)
    return results


def hybrid_search(query: str, scope: str | None = None,
                  project_id: str | None = None, limit: int = 20,
                  mode: str = "hybrid") -> list[dict[str, Any]]:
    """统一检索入口（阶段二）：
      mode="keyword"  → 纯关键词（FTS5，兼容旧行为）
      mode="semantic" → 纯语义（稠密+稀疏）；向量不可用自动降级为关键词
      mode="hybrid"   → 两路结果 RRF 融合（k=60）；任一路缺失即用另一路

    拉模式语义不变：检索只读取，结果由用户/Agent 显式决定是否使用。
    """
    if mode == "keyword":
        return search_entries(query, scope, project_id, limit)
    sem = semantic_search(query, scope, project_id, limit=limit * 2)
    if mode == "semantic":
        if sem:
            return sem
        return search_entries(query, scope, project_id, limit)  # 降级
    # hybrid：关键词 + 语义 RRF 融合
    kw = search_entries(query, scope, project_id, limit=limit * 2)
    if not sem:
        return kw[:limit]
    if not kw:
        return sem[:limit]
    rrf: dict[str, float] = {}
    for rank, e in enumerate(kw, start=1):
        rrf[e["id"]] = rrf.get(e["id"], 0.0) + 1.0 / (60 + rank)
    for rank, e in enumerate(sem, start=1):
        rrf[e["id"]] = rrf.get(e["id"], 0.0) + 1.0 / (60 + rank)
    order = sorted(rrf.items(), key=lambda x: -x[1])[:limit]
    results = []
    for eid, score in order:
        e = get_entry(eid)
        if e:
            e = {**e, "score": round(float(score), 6)}
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
            conn.execute("DELETE FROM knowledge_embeddings WHERE entry_id = ?", (rid,))  # 阶段二
        conn.commit()
    finally:
        conn.close()
    return len(missing)


# ---------- TS-120 阶段二：语义向量挂钩 ----------
def _embed_entry(entry_id: str, title: str, body: str, keywords: list[str]) -> bool:
    """给条目编码并写入向量表。模型不可用 → 静默跳过（检索降级为纯关键词）。
    编码文本 = 标题 + 关键词 + 正文（正文是知识主体，标题补语义锚点）。"""
    try:
        from sidecar.knowledge import embedder
    except ImportError:
        return False
    if not embedder.model_available():
        return False
    text_parts = [title.strip()] if title and title.strip() else []
    if keywords:
        text_parts.append(" ".join(k.strip() for k in keywords if k.strip()))
    if body and body.strip():
        text_parts.append(body.strip())
    text = "\n".join(text_parts)
    if not text.strip():
        return False
    try:
        vec = embedder.encode_one(text)
    except Exception:
        return False  # 编码失败不阻塞条目写入（降级）
    conn = _iconn()
    try:
        conn.execute(
            "INSERT OR REPLACE INTO knowledge_embeddings (entry_id, dense, sparse, model, updated_at) "
            "VALUES (?,?,?,?,?)",
            (entry_id, embedder.dense_to_blob(vec["dense"]),
             json.dumps(vec["sparse"], ensure_ascii=False), "bge-m3-onnx-int8",
             datetime.now().strftime("%Y-%m-%d %H:%M:%S")))
        conn.commit()
    finally:
        conn.close()
    return True


def _remove_embedding(entry_id: str) -> None:
    """删除条目的向量记录（条目删除时同步清理）。"""
    conn = _iconn()
    try:
        conn.execute("DELETE FROM knowledge_embeddings WHERE entry_id = ?", (entry_id,))
        conn.commit()
    finally:
        conn.close()


def _iter_indexable(kdir: Path):
    """⛔ A10 局部去重：rebuild_index 原本对全局/项目两处各写一遍 `.glob("*.md")` 循环，
    且现在要从"只 md"扩到"全部可索引文档"——两处必须同步改，否则漏一处。
    收敛为单一迭代器：列出目录内**顶层**可索引文件（.md + INDEXABLE_DOC_EXTS）。
    ⚠️ 保持非递归（与改造前 glob("*.md") 一致）：知识目录是用户明目录，约定平铺放置；
    递归会意外吞进用户自建子目录里的无关文件，属行为变更，不在 A10 范围。"""
    if not kdir.is_dir():
        return
    allowed = INDEXABLE_DOC_EXTS | {".md"}
    for f in sorted(kdir.iterdir()):
        if f.is_file() and f.suffix.lower() in allowed:
            yield f


def rebuild_index() -> int:
    """重建索引：扫描作用域目录内全部**可索引文档**（.md + docx/pdf/xlsx/pptx/.doc/txt/csv/json…），
    清空索引后重新写入。返回条目数。
    阶段二：同时清空并重建向量表（模型不可用时向量留空，检索降级）。

    ⛔ A10（0.4.18）：原本只 glob("*.md")，用户把 docx/pdf 丢进知识目录索引不到。
    现按扩展名分发：.md 走 frontmatter 路径（行为不变），其余走 attachments/parser.py
    解析（与聊天附件、工作流 file_read 同一解析链）。
    ⛔ **拉模式铁律**：本函数只是把文本索引进 FTS/向量供 search_knowledge **检索**，
    ⛔ 绝不自动注入任何上下文（防重蹈 0.4.8"主 Agent 自读 90KB PDF 跑 20 分钟"覆辙）。
    ⛔ 本函数现为 CPU 密集（解析多个文档）→ 调用方（app.py 端点）必须 run_in_executor，
    否则阻塞事件循环（与 C4 工作流节点同一个坑）。"""
    from sidecar.storage.store import list_projects
    conn = _iconn()
    try:
        conn.execute("DELETE FROM knowledge_entries")
        conn.execute("DELETE FROM knowledge_fts")
        conn.execute("DELETE FROM knowledge_embeddings")
        conn.commit()
    finally:
        conn.close()
    count = 0
    # 全局
    for f in _iter_indexable(global_knowledge_dir()):
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
        for f in _iter_indexable(kdir):
            if _reindex_file(f, PROJECT_SCOPE, proj.get("id")):
                count += 1
    return count


def _reindex_file(fpath: Path, scope: str, project_id: str) -> bool:
    """索引单个文件：.md 走 frontmatter 路径，其余文档走解析器路径（A10）。"""
    if fpath.suffix.lower() == ".md":
        return _reindex_md(fpath, scope, project_id)
    return _reindex_doc(fpath, scope, project_id)


def _reindex_md(fpath: Path, scope: str, project_id: str) -> bool:
    """索引本模块生成的 .md 条目（带 frontmatter）—— 行为与 A10 改造前逐字一致。"""
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
    # 阶段二：重建向量（模型不可用时 _embed_entry 内部静默降级）
    _embed_entry(entry_id, str(meta.get("title") or ""), body, kw)
    return True


def _reindex_doc(fpath: Path, scope: str, project_id: str) -> bool:
    """A10（0.4.18）：索引用户丢进知识目录的**外部文档**（非 .md）。

    ⛔ 与 .md 的三个关键区别（无 frontmatter 可依赖）：
      * 标题 = 文件名 stem；关键词 = 空（无 frontmatter）。
      * id 用**路径派生的稳定值**（uuid5），重建多次不漂移——.md 用 frontmatter id 或
        uuid4，而外部文件没有 id 字段，用 uuid4 会让每次重建都生成新 id（虽 rebuild 先
        清表不致堆积，但稳定 id 让增量/对账更可预期）。
      * source='file' —— ⛔ 删条目时 delete_entry 据此**不 unlink**（文件属用户，见守卫）。
    ⛔ 解析不出文本（损坏/加密/扫描件）→ 返回 False 不索引垃圾；超大文件跳过不阻塞整次重建。
    ⛔ 拉模式铁律同 rebuild_index：只索引供检索，不自动注入上下文。
    """
    try:
        size = fpath.stat().st_size
        if size == 0 or size > _KNOWLEDGE_MAX_SOURCE_BYTES:
            return False
        raw = fpath.read_bytes()
    except OSError:
        return False
    try:
        from sidecar.attachments.parser import parse_attachment
        text, _kind = parse_attachment(fpath.name, raw)
    except Exception:
        return False
    if not text or not text.strip():
        return False
    body = text[:_KNOWLEDGE_MAX_INDEX_CHARS]
    entry_id = str(uuid.uuid5(uuid.NAMESPACE_URL, f"knowledge-file://{fpath.resolve()}"))
    title = fpath.stem
    # created_at 用文件 mtime（外部文件无 frontmatter 时间）→ list_entries 的"新→旧"排序有意义
    try:
        created_at = datetime.fromtimestamp(fpath.stat().st_mtime).strftime("%Y-%m-%d %H:%M:%S")
    except OSError:
        created_at = ""
    conn = _iconn()
    try:
        conn.execute(
            "INSERT OR REPLACE INTO knowledge_entries (id, title, scope, project_id, category, "
            "keywords, source, file_path, created_at) VALUES (?,?,?,?,?,?,?,?,?)",
            (entry_id, title, scope, project_id or "", "",
             json.dumps([], ensure_ascii=False), SOURCE_IMPORTED_FILE,
             str(fpath), created_at))
        conn.execute(
            "INSERT INTO knowledge_fts (entry_id, title, keywords, body) VALUES (?,?,?,?)",
            (entry_id, _tokenize(title), _tokenize(""), _tokenize(body)))
        conn.commit()
    finally:
        conn.close()
    _embed_entry(entry_id, title, body, [])
    return True


def _purge_file_index(fpath: Path) -> None:
    """覆盖导入前清掉该路径的旧索引行（FTS + 向量）。

    ⛔ **为什么必须清 FTS**：`_reindex_doc` 对 `knowledge_entries` 用 `INSERT OR REPLACE`
    （同路径派生的 uuid5 相同 → 天然覆盖），但 `knowledge_fts` 是**普通 INSERT**——
    FTS5 虚表不支持 OR REPLACE。不清就会多留一行旧正文的分词，表现为：同一个文件
    检索时命中两份、且其中一份还是**覆盖前的旧内容**。向量表同理（会留旧向量）。
    """
    entry_id = str(uuid.uuid5(uuid.NAMESPACE_URL, f"knowledge-file://{fpath.resolve()}"))
    conn = _iconn()
    try:
        conn.execute("DELETE FROM knowledge_fts WHERE entry_id = ?", (entry_id,))
        conn.execute("DELETE FROM knowledge_embeddings WHERE entry_id = ?", (entry_id,))
        conn.commit()
    finally:
        conn.close()


def import_files(scope: str, project_id: str | None, sources: list[str],
                 on_conflict: str = "ask") -> dict:
    """A11（0.4.22）：把用户选中的外部文件复制进知识目录并索引。

    ⛔ 拉模式铁律同 rebuild_index/_reindex_doc：只复制+索引供检索，不自动注入上下文。
    ⛔ 非递归：sources 是文件路径列表（来自 chooseInputFile 文件对话框，用户主动选），
      不遍历目录。某 source 是目录/不存在 → 计入 failed。
    ⛔ 复制用 copy2 保留 mtime（_reindex_doc 用 mtime 做 created_at，"新→旧"排序有意义）。
    ⛔ **同名冲突由用户决定，后端不擅自处置**（用户 2026-09-12 拍板"改成弹窗问我"）：
      * `on_conflict="ask"`（默认）：**不碰**已存在的文件，把它列入 `conflicts` 返回，
        前端弹窗问用户 → 用户选完再用下面三种策略之一重新调用；
      * `"overwrite"`：覆盖知识目录里的旧副本（先清旧 FTS/向量行，见 _purge_file_index）；
      * `"rename"`：存成 `名_1.扩展名`（旧文件原样保留）；
      * `"skip"`：跳过该文件（旧文件原样保留）。
      ⛔ 三种策略都**绝不动用户原始文件**（sources 指向的本机文件只读不写）。
    ⛔ 大文件/不支持类型/解析失败：_reindex_doc 返回 False → 计入 skipped 并删除已复制的
      文件（不留垃圾），不报错中断整批（用户选一堆文件，个别不支持不应中断）。

    返回 {imported, failed, skipped, conflicts: [name…], details: [{name, status, reason?}]}。
    """
    import shutil
    kdir = scope_dir(scope, project_id)
    if kdir is None:
        return {"imported": 0, "failed": len(sources), "skipped": 0, "conflicts": [],
                "details": [{"name": s, "status": "failed", "reason": "无效的作用域或项目"}
                            for s in sources]}
    kdir.mkdir(parents=True, exist_ok=True)
    imported = failed = skipped = 0
    conflicts: list[str] = []
    details: list[dict] = []
    for src in sources:
        sp = Path(src)
        name = sp.name
        if not sp.exists() or not sp.is_file():
            failed += 1
            details.append({"name": name, "status": "failed", "reason": "不是文件或不存在"})
            continue

        dest = kdir / name
        existed = dest.exists()          # 本次是否真的撞上了同名文件（决定 details 里的处置记录）
        if existed:
            if on_conflict == "ask":
                # ⛔ 默认策略：不碰旧文件、不复制、不索引，交回前端弹窗问用户
                conflicts.append(name)
                details.append({"name": name, "status": "conflict",
                                "reason": "知识目录已有同名文件（等你决定怎么处理）"})
                continue
            if on_conflict == "skip":
                skipped += 1
                details.append({"name": name, "status": "skipped",
                                "reason": "同名文件已存在，按你的选择跳过"})
                continue
            if on_conflict == "rename":
                seq = 1
                while dest.exists():
                    dest = kdir / f"{sp.stem}_{seq}{sp.suffix}"
                    seq += 1
            elif on_conflict == "overwrite":
                _purge_file_index(dest)      # ⛔ 先清旧 FTS/向量，否则残留旧正文
            else:
                failed += 1
                details.append({"name": name, "status": "failed",
                                "reason": f"未知的冲突策略: {on_conflict}"})
                continue

        try:
            shutil.copy2(sp, dest)
        except OSError as e:
            failed += 1
            details.append({"name": name, "status": "failed", "reason": f"复制失败: {e}"})
            continue
        # 索引（_reindex_doc 内部处理大文件/类型/解析失败 → 返回 False）
        ok = _reindex_doc(dest, scope, project_id or "")
        if ok:
            imported += 1
            details.append({"name": dest.name, "status": "imported",
                            # 无冲突 → None；有冲突 → 记录用户选的处置方式（前端汇总提示用）
                            "conflict_resolved": on_conflict if existed else None})
        else:
            skipped += 1
            details.append({"name": dest.name, "status": "skipped",
                            "reason": "不支持的类型/解析失败/超大文件"})
            # 复制了但索引失败 → 删除复制的文件（知识目录不留没索引的垃圾）
            # ⛔ 仅删本次新复制的副本；overwrite 情况下旧副本已被覆盖，无从恢复，
            #    故 overwrite + 索引失败要如实告知用户（不能假装成功）。
            try:
                dest.unlink()
            except OSError:
                pass
            if on_conflict == "overwrite":
                details[-1]["reason"] = ("不支持的类型/解析失败/超大文件；"
                                         "⚠️ 且原同名文件已被本次覆盖删除")
    return {"imported": imported, "failed": failed, "skipped": skipped,
            "conflicts": conflicts, "details": details}
