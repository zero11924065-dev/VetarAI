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
"""M2 智能压缩：先归档后摘要，禁止静默删消息。

流程：
1. 取会话全部消息，保留最近 keep_recent 条，其余为"待压缩区"
2. 归档：待压缩区写 MD 文件到 compact_archive_dir（写失败→中止）
3. 摘要：调 Ollama chat 生成 300 字摘要（失败→中止，消息原样保留）
4. 落库：写 compact_log → 删待压缩区消息 → 插 role=system 摘要消息
"""
from __future__ import annotations
import json
import os
from datetime import datetime
from pathlib import Path
from typing import Any

import httpx

from sidecar.config import get_config
from sidecar.storage.store import (
    load_messages, save_message, log_compact, delete_messages_before,
)


def _archive_md(session_id: str, messages: list[dict[str, Any]], archive_dir: Path) -> Path:
    """把待压缩区消息写成 MD 归档文件，返回文件路径。"""
    archive_dir.mkdir(parents=True, exist_ok=True)
    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    path = archive_dir / f"compact-{session_id}-{ts}.md"
    lines = ["# 历史消息归档", f"> 会话: {session_id}", f"> 时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}", ""]
    for m in messages:
        role = m.get("role", "unknown")
        content = m.get("content", "")
        ts_m = m.get("created_at", "")
        tool_steps = m.get("tool_steps")
        if role == "assistant" and tool_steps:
            try:
                steps = json.loads(tool_steps) if isinstance(tool_steps, str) else tool_steps
                for st in steps:
                    lines.append(f"  - [{st.get('name','tool')}] {st.get('summary','')}")
            except Exception:
                pass
        lines.append(f"**{role}** ({ts_m})\n{content}\n")
    path.write_text("\n".join(lines), encoding="utf-8")
    return path


def _estimate_tokens(messages: list[dict[str, Any]]) -> int:
    """估算 token 数（中文约 1 字 = 1 token，英文约 4 字符 = 1 token）。"""
    total = 0
    for m in messages:
        c = m.get("content", "")
        if not c:
            continue
        # 粗略估算：中文字符数 + 英文单词数
        cjk = sum(1 for ch in c if '\u4e00' <= ch <= '\u9fff')
        latin = sum(1 for ch in c if ch.isascii() and ch.isalpha())
        total += cjk + latin // 4
    return total


async def compact_session(project_id: str, session_id: str, keep_recent: int | None = None,
                          model: str = "qwen3.8") -> dict[str, Any]:
    """执行智能压缩。返回结果 dict。"""
    cfg = get_config()
    if keep_recent is None:
        keep_recent = int(cfg.get("compact_keep_recent", 10))
    archive_dir = Path(os.path.expanduser(cfg.get("compact_archive_dir", "~/.subagent/compressed")))
    base_url = cfg.get("ollama_base_url", "http://localhost:11434").rstrip("/")

    # 1. 取全部消息
    all_msgs = load_messages(project_id, session_id)
    if len(all_msgs) <= keep_recent:
        return {"ok": False, "error": f"消息数 {len(all_msgs)} ≤ keep_recent {keep_recent}，无需压缩"}

    to_compress = all_msgs[:-keep_recent]  # 待压缩区
    before_tokens = _estimate_tokens(all_msgs)

    # 2. 归档（写失败→中止）
    try:
        archive_path = _archive_md(session_id, to_compress, archive_dir)
    except Exception as e:
        log_compact(project_id, session_id, before_tokens, before_tokens, None, None, f"归档失败: {e}")
        return {"ok": False, "error": f"归档失败: {e}"}

    # 3. 摘要（失败→中止，消息原样保留）
    summary_text = ""
    try:
        prompt_parts = []
        for m in to_compress:
            prompt_parts.append(f"[{m.get('role','?')}] {m.get('content','')}")
        prompt_text = "\n".join(prompt_parts)
        payload = {
            "model": model,
            "messages": [{"role": "user", "content": "请将以下对话历史压缩为 300 字以内的摘要，保留关键决策、结论、待办，去掉寒暄和过程细节：\n\n" + prompt_text}],
            "stream": False,
        }
        async with httpx.AsyncClient(timeout=httpx.Timeout(120.0, connect=10.0), trust_env=False) as client:
            r = await client.post(f"{base_url}/api/chat", json=payload)
            r.raise_for_status()
            data = r.json()
            summary_text = data.get("message", {}).get("content", "")
            if not summary_text:
                raise ValueError("Ollama 返回空摘要")
    except Exception as e:
        log_compact(project_id, session_id, before_tokens, before_tokens, str(archive_path), None, f"摘要失败: {e}")
        return {"ok": False, "error": f"摘要失败: {e}"}

    # 4. 落库：写 compact_log → 删待压缩区 → 插摘要消息
    kept_msgs = all_msgs[-keep_recent:]
    after_tokens = _estimate_tokens(kept_msgs) + len(summary_text)

    log_compact(project_id, session_id, before_tokens, after_tokens, str(archive_path), summary_text[:200])
    deleted = delete_messages_before(project_id, session_id, keep_recent)
    # 取 agent_id（从保留区第一条消息）
    # 从 sessions 表取 agent_id
    # checkpoint-050 查虫修复：改用统一读上下文管理器（防连接泄漏）
    from sidecar.storage.store import _read_conn
    with _read_conn(project_id) as _conn:
        _row = _conn.execute("SELECT agent_id FROM sessions WHERE id = ?", (session_id,)).fetchone()
    agent_id = _row[0] if _row else ""
    save_message(project_id, session_id, agent_id, "system", f"【历史摘要】{summary_text}")

    return {
        "ok": True,
        "before_tokens": before_tokens,
        "after_tokens": after_tokens,
        "archive_path": str(archive_path),
        "archived_count": deleted,
    }


def export_session_md(project_id: str, session_id: str, export_dir: str) -> Path:
    """导出会话全部消息为 MD 文件。

    M3 前置安全加固 L2：导出目录必须落在 compact_archive_dir 或系统临时目录内，
    否则 raise ValueError（防 API 传 ../../etc/cron.d 写任意位置）。
    """
    import tempfile
    cfg = get_config()
    allowed_roots = [
        Path(os.path.expanduser(cfg.get("compact_archive_dir", "~/.subagent/compressed"))).resolve(),
        Path(tempfile.gettempdir()).resolve(),
        Path("/tmp").resolve(),
    ]
    out_dir = Path(os.path.expanduser(export_dir)).resolve()
    if not any(
        out_dir == r or out_dir.is_relative_to(r)
        for r in allowed_roots
    ):
        raise ValueError(f"导出目录不在允许范围内（须在归档目录或系统临时目录内）: {export_dir}")
    msgs = load_messages(project_id, session_id)
    out_dir.mkdir(parents=True, exist_ok=True)
    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    path = out_dir / f"session-{session_id}-{ts}.md"
    lines = [f"# 会话导出 {session_id}", f"> 时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}", ""]
    for m in msgs:
        lines.append(f"**{m.get('role','?')}** ({m.get('created_at','')})\n{m.get('content','')}\n")
    path.write_text("\n".join(lines), encoding="utf-8")
    return path
