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
"""M4（TS-110）：知识库与本地记忆加载模块。

目录约定（用户拍板：用户可见产出文件一律存项目工作目录）：
- 知识库：<项目工作目录>/knowledge/*.md（文件名以 _ 开头 = 禁用）
- 项目记忆：<项目工作目录>/memory.md
- 全局记忆：<数据目录>/memory/global.md（跨项目，唯一例外）

注入优先级（3.14）：本地记忆 > 通用知识；禁止事项 100% 拦截（红线区）。
降级原则：任何加载失败 → 空内容/空列表，绝不抛错阻塞对话。
"""
from __future__ import annotations

import re as _re
from pathlib import Path
from typing import Any

# 单文件/单份记忆的注入字符上限（防上下文爆炸）
_KNOWLEDGE_MAX_CHARS_EACH = 4000
_KNOWLEDGE_MAX_CHARS_TOTAL = 12000
_MEMORY_MAX_CHARS = 4000

# 禁止事项行首关键词（3.14：禁止事项 100% 拦截 → 注入红线区）
_PROHIBITION_PREFIXES = ("禁止", "不得", "不允许", "严禁")


def _project_working_dir(project_id: str) -> str | None:
    """项目工作目录（建项目时用户选的文件夹）。"""
    try:
        from sidecar.storage.store import list_projects
        for proj in list_projects():
            if proj.get("id") == project_id:
                wd = proj.get("working_dir")
                return wd or None
    except Exception:
        pass
    return None


def knowledge_dir(project_id: str) -> Path | None:
    wd = _project_working_dir(project_id)
    if not wd:
        return None
    return Path(str(wd)).expanduser() / "knowledge"


def _valid_filename(name: str) -> bool:
    """文件名校验：非空、无路径分隔符、.md 后缀。"""
    if not name or not isinstance(name, str):
        return False
    if "/" in name or "\\" in name or ".." in name:
        return False
    return name.endswith(".md")


def list_knowledge(project_id: str) -> list[dict[str, Any]]:
    """知识文件列表：[{name, size, enabled}]。目录不存在 → []。"""
    kdir = knowledge_dir(project_id)
    if kdir is None or not kdir.is_dir():
        return []
    out = []
    try:
        for f in sorted(kdir.iterdir()):
            if f.is_file() and f.suffix == ".md":
                out.append({
                    "name": f.name,
                    "size": f.stat().st_size,
                    "enabled": not f.name.startswith("_"),
                })
    except Exception:
        pass
    return out


def read_knowledge(project_id: str, filename: str) -> str | None:
    if not _valid_filename(filename):
        return None
    kdir = knowledge_dir(project_id)
    if kdir is None:
        return None
    f = kdir / filename
    if not f.is_file():
        return None
    try:
        return f.read_text(encoding="utf-8")
    except Exception:
        return None


def write_knowledge(project_id: str, filename: str, content: str) -> bool:
    if not _valid_filename(filename):
        return False
    kdir = knowledge_dir(project_id)
    if kdir is None:
        return False
    try:
        kdir.mkdir(parents=True, exist_ok=True)
        (kdir / filename).write_text(content or "", encoding="utf-8")
        return True
    except Exception:
        return False


def delete_knowledge(project_id: str, filename: str) -> bool:
    if not _valid_filename(filename):
        return False
    kdir = knowledge_dir(project_id)
    if kdir is None:
        return False
    f = kdir / filename
    if not f.is_file():
        return False
    try:
        f.unlink()
        return True
    except Exception:
        return False


def toggle_knowledge(project_id: str, filename: str) -> str | None:
    """启用/禁用（改名加/去 `_` 前缀）。返回新文件名，失败返回 None。"""
    if not _valid_filename(filename):
        return None
    kdir = knowledge_dir(project_id)
    if kdir is None:
        return None
    f = kdir / filename
    if not f.is_file():
        return None
    if filename.startswith("_"):
        new_name = filename.lstrip("_") or "unnamed.md"
    else:
        new_name = "_" + filename
    if not _valid_filename(new_name):
        return None
    new_f = kdir / new_name
    if new_f.exists():
        return None
    try:
        f.rename(new_f)
        return new_name
    except Exception:
        return None


def build_knowledge_text(project_id: str) -> str:
    """拼接启用知识文件为注入文本（单文件截断 + 总量上限）。异常返回空串。"""
    try:
        kdir = knowledge_dir(project_id)
        if kdir is None or not kdir.is_dir():
            return ""
        parts: list[str] = []
        total = 0
        for entry in list_knowledge(project_id):
            if not entry["enabled"]:
                continue
            if total >= _KNOWLEDGE_MAX_CHARS_TOTAL:
                break
            try:
                text = (kdir / entry["name"]).read_text(encoding="utf-8").strip()
            except Exception:
                continue
            if not text:
                continue
            if len(text) > _KNOWLEDGE_MAX_CHARS_EACH:
                text = text[:_KNOWLEDGE_MAX_CHARS_EACH] + "\n（该文件超长已截断）"
            if total + len(text) > _KNOWLEDGE_MAX_CHARS_TOTAL:
                remain = _KNOWLEDGE_MAX_CHARS_TOTAL - total
                if remain > 200:
                    parts.append(f"【{entry['name']}】\n{text[:remain]}\n（已达总量上限，后续文件未注入）")
                break
            parts.append(f"【{entry['name']}】\n{text}")
            total += len(text)
        return "\n\n".join(parts)
    except Exception:
        return ""


# ── 记忆 ──────────────────────────────────────────────

def _memory_path(scope: str, project_id: str | None = None) -> Path | None:
    """scope: 'global' → 数据目录；'project' → 项目工作目录。"""
    if scope == "global":
        try:
            import sidecar.config as _cfg
            return _cfg.data_root() / "memory" / "global.md"
        except Exception:
            return None
    if scope == "project":
        if not project_id:
            return None
        wd = _project_working_dir(project_id)
        if not wd:
            return None
        return Path(str(wd)).expanduser() / "memory.md"
    return None


def read_memory(scope: str, project_id: str | None = None) -> str:
    p = _memory_path(scope, project_id)
    if p is None or not p.is_file():
        return ""
    try:
        return p.read_text(encoding="utf-8")
    except Exception:
        return ""


def write_memory(scope: str, content: str, project_id: str | None = None) -> bool:
    p = _memory_path(scope, project_id)
    if p is None:
        return False
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        text = content or ""
        truncated = False
        if len(text) > _MEMORY_MAX_CHARS:
            text = text[:_MEMORY_MAX_CHARS] + "\n（超长已截断）"
            truncated = True
        p.write_text(text, encoding="utf-8")
        return True
    except Exception:
        return False


def extract_prohibitions(memory_text: str) -> list[str]:
    """从记忆文本提取禁止事项行（行首关键词匹配）。"""
    out = []
    for line in str(memory_text or "").splitlines():
        s = line.strip()
        # 去掉常见列表符号前缀
        s2 = _re.sub(r"^[-*•\d.\s]+", "", s)
        if any(s2.startswith(p) for p in _PROHIBITION_PREFIXES):
            out.append(s2)
    return out


def build_memory_injection(project_id: str | None = None) -> tuple[str, list[str]]:
    """返回 (记忆正文段, 禁止事项列表)。任何异常 → ('', [])。

    优先级（3.14）：本地记忆 > 通用知识；项目记忆与全局记忆冲突时以项目记忆为准。
    """
    try:
        g = read_memory("global").strip()
        p = read_memory("project", project_id).strip() if project_id else ""
        prohibitions: list[str] = []
        for item in extract_prohibitions(g) + extract_prohibitions(p):
            if item not in prohibitions:
                prohibitions.append(item)
        parts: list[str] = []
        if g:
            parts.append("【全局记忆】\n" + g)
        if p:
            parts.append("【本项目记忆】（与全局记忆/知识库冲突时，以本项目记忆为准）\n" + p)
        return ("\n\n".join(parts), prohibitions)
    except Exception:
        return ("", [])
