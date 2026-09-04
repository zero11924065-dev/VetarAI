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
"""M4（TS-110）：Skill 管理模块。

Skill = SKILL.md 式本地技能（3.14）：
- 位置：<数据目录>/skills/<name>/SKILL.md（跨项目复用，同 plugins 性质）
- frontmatter：name / description / enabled（简易解析，不引新依赖）
- Agent 按需引用：提示词注入技能清单（名称—描述），模型需要时调 read_skill 读正文
- 安装：本地路径复制 / git 仓库克隆（过 guard + 剥离代理变量，timeout=120）
"""
from __future__ import annotations

import re as _re
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Any


def skills_root() -> Path:
    import sidecar.config as _cfg
    root = _cfg.data_root() / "skills"
    root.mkdir(parents=True, exist_ok=True)
    return root


def _valid_skill_name(name: str) -> bool:
    """技能名清洗规则：字母/数字/中文/-/_，1-64 字符。"""
    if not name or not isinstance(name, str):
        return False
    if len(name) > 64:
        return False
    return bool(_re.fullmatch(r"[\w\u4e00-\u9fff-]+", name))


def _parse_frontmatter(text: str) -> tuple[dict[str, str], str]:
    """解析 `---` frontmatter。返回 (meta, body)。无 frontmatter → ({}, 原文)。"""
    text = text or ""
    if not text.startswith("---"):
        return {}, text
    lines = text.split("\n")
    if len(lines) < 2:
        return {}, text
    meta: dict[str, str] = {}
    end_idx = None
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            end_idx = i
            break
        m = _re.match(r"^([A-Za-z_][\w-]*)\s*:\s*(.*)$", lines[i].strip())
        if m:
            meta[m.group(1)] = m.group(2).strip().strip('"').strip("'")
    if end_idx is None:
        return {}, text
    body = "\n".join(lines[end_idx + 1:])
    return meta, body


def _build_frontmatter(meta: dict[str, str]) -> str:
    lines = ["---"]
    for k, v in meta.items():
        lines.append(f"{k}: {v}")
    lines.append("---")
    return "\n".join(lines)


def _skill_dir(name: str) -> Path:
    return skills_root() / name


def _read_skill_file(name: str) -> str | None:
    f = _skill_dir(name) / "SKILL.md"
    if not f.is_file():
        return None
    try:
        return f.read_text(encoding="utf-8")
    except Exception:
        return None


def list_skills() -> list[dict[str, Any]]:
    """技能列表：[{name, description, enabled, path}]。"""
    out = []
    try:
        for d in sorted(skills_root().iterdir()):
            if not d.is_dir():
                continue
            text = _read_skill_file(d.name)
            if text is None:
                continue
            meta, _body = _parse_frontmatter(text)
            enabled_raw = str(meta.get("enabled", "true")).strip().lower()
            out.append({
                "name": meta.get("name", d.name),
                "dir_name": d.name,
                "description": meta.get("description", ""),
                "enabled": enabled_raw not in ("false", "0", "no"),
                "path": str(d / "SKILL.md"),
            })
    except Exception:
        pass
    return out


def read_skill(name: str) -> dict[str, Any] | None:
    """读取技能：{name, description, enabled, content(正文)}。"""
    if not _valid_skill_name(name):
        return None
    text = _read_skill_file(name)
    if text is None:
        return None
    meta, body = _parse_frontmatter(text)
    enabled_raw = str(meta.get("enabled", "true")).strip().lower()
    return {
        "name": meta.get("name", name),
        "dir_name": name,
        "description": meta.get("description", ""),
        "enabled": enabled_raw not in ("false", "0", "no"),
        "content": body.strip(),
    }


def create_or_update_skill(name: str, description: str, body: str, enabled: bool = True) -> bool:
    if not _valid_skill_name(name):
        return False
    try:
        d = _skill_dir(name)
        d.mkdir(parents=True, exist_ok=True)
        meta = {
            "name": name,
            "description": str(description or "").replace("\n", " ")[:500],
            "enabled": "true" if enabled else "false",
        }
        (d / "SKILL.md").write_text(_build_frontmatter(meta) + "\n\n" + (body or ""),
                                    encoding="utf-8")
        return True
    except Exception:
        return False


def delete_skill(name: str) -> bool:
    if not _valid_skill_name(name):
        return False
    d = _skill_dir(name)
    if not d.is_dir():
        return False
    try:
        shutil.rmtree(str(d))
        return True
    except Exception:
        return False


def toggle_skill(name: str) -> bool | None:
    """启用/禁用（改 frontmatter enabled）。返回新状态，失败/不存在返回 None。"""
    if not _valid_skill_name(name):
        return None
    text = _read_skill_file(name)
    if text is None:
        return None
    meta, body = _parse_frontmatter(text)
    enabled_raw = str(meta.get("enabled", "true")).strip().lower()
    cur = enabled_raw not in ("false", "0", "no")
    meta["enabled"] = "false" if cur else "true"
    meta.setdefault("name", name)
    try:
        (_skill_dir(name) / "SKILL.md").write_text(
            _build_frontmatter(meta) + "\n\n" + body, encoding="utf-8")
        return not cur
    except Exception:
        return None


def install_skill_from_repo(url_or_path: str) -> dict[str, Any]:
    """安装技能：本地路径直接复制；其余按 git 仓库克隆。
    克隆过 guard 契约（剥离代理环境变量 + timeout=120，同 plugin_loader）。
    返回 {"ok": bool, "name"?, "error"?}。
    """
    src = str(url_or_path or "").strip()
    if not src:
        return {"ok": False, "error": "地址不能为空"}
    tmp = None
    try:
        local = Path(src).expanduser()
        if local.exists():
            skill_md = local / "SKILL.md"
            if not skill_md.is_file():
                # 本地路径下找子目录
                cands = list(local.rglob("SKILL.md"))
                if not cands:
                    return {"ok": False, "error": "该目录内未找到 SKILL.md"}
                skill_md = cands[0]
            meta, _b = _parse_frontmatter(skill_md.read_text(encoding="utf-8"))
            name = meta.get("name") or skill_md.parent.name
            if not _valid_skill_name(name):
                return {"ok": False, "error": f"技能名非法: {name}"}
            dest = _skill_dir(name)
            if dest.exists():
                return {"ok": False, "error": f"技能已存在: {name}"}
            shutil.copytree(str(skill_md.parent), str(dest))
            return {"ok": True, "name": name}
        # git 克隆
        tmp = tempfile.mkdtemp(prefix="skill_install_")
        env = _egress_env()
        try:
            subprocess.run(["git", "clone", "--depth", "1", src, tmp],
                           capture_output=True, text=True, timeout=120,
                           env=env, check=True)
        except subprocess.TimeoutExpired:
            return {"ok": False, "error": "git clone 超时（120s）"}
        except subprocess.CalledProcessError as e:
            return {"ok": False, "error": f"git clone 失败：{(e.stderr or '').strip()[:200]}"}
        tmp_path = Path(tmp)
        cands = list(tmp_path.rglob("SKILL.md"))
        if not cands:
            return {"ok": False, "error": "仓库内未找到 SKILL.md"}
        skill_md = cands[0]
        meta, _b = _parse_frontmatter(skill_md.read_text(encoding="utf-8"))
        name = meta.get("name") or skill_md.parent.name
        if not _valid_skill_name(name):
            return {"ok": False, "error": f"技能名非法: {name}"}
        dest = _skill_dir(name)
        if dest.exists():
            return {"ok": False, "error": f"技能已存在: {name}"}
        shutil.copytree(str(skill_md.parent), str(dest))
        return {"ok": True, "name": name}
    except Exception as e:
        return {"ok": False, "error": f"安装失败：{e}"}
    finally:
        if tmp:
            shutil.rmtree(tmp, ignore_errors=True)


def _egress_env() -> dict[str, str]:
    """剥离代理环境变量（guard 唯一漏斗契约，同 plugin_loader）。"""
    import os
    env = dict(os.environ)
    for k in ("HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy",
              "ALL_PROXY", "all_proxy"):
        env.pop(k, None)
    return env


def build_skills_list_text() -> str:
    """启用技能清单（名称 — 描述），供注入提示词；无启用项返回空串。"""
    try:
        items = [s for s in list_skills() if s["enabled"]]
        if not items:
            return ""
        return "\n".join(f"- {s['name']}：{s['description'] or '（无描述）'}" for s in items)
    except Exception:
        return ""
