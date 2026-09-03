"""M7（TS-113）：统一导出目录解析 + 会话 Markdown 导出 + 交卷全文落盘。

导出目录策略（3.17 第二项）：
- 配置 `default_export_dir` 非空 → 展开 ~ 后使用（不存在则自动创建；创建失败回退）
- 配置为空 → 项目工作目录（建项目时选的文件夹）
- 项目工作目录也取不到 → 数据目录兜底（保证导出永不失败）

知识库/记忆不受此模块影响（保持项目目录内，用户 2026-08-29 拍板）。
"""
from __future__ import annotations

import json
from datetime import datetime
from pathlib import Path
from typing import Any

from sidecar.config import get_config


def resolve_export_dir(project_id: str) -> Path:
    """解析当前生效的导出目录（配置优先 → 项目工作目录 → 数据目录兜底）。"""
    from sidecar.storage.store import list_projects
    from sidecar.config import data_root

    # 1) 用户配置的默认导出目录
    cfg_dir = str(get_config().get("default_export_dir") or "").strip()
    if cfg_dir:
        try:
            p = Path(cfg_dir).expanduser()
            p.mkdir(parents=True, exist_ok=True)
            # 可写探测
            probe = p / ".subagent_export_probe"
            probe.write_text("ok", encoding="utf-8")
            probe.unlink()
            return p
        except Exception:
            pass  # 配置目录不可用 → 回退项目工作目录

    # 2) 项目工作目录
    try:
        for proj in list_projects():
            if proj.get("id") == project_id:
                wd = proj.get("working_dir")
                if wd:
                    return Path(str(wd)).expanduser()
                break
    except Exception:
        pass

    # 3) 兜底：数据目录（保证导出永不失败）
    return data_root() / "exports"


def export_session_md(project_id: str, session_id: str,
                      agent_id: str = "") -> dict[str, str]:
    """会话导出为 Markdown（3.17.1 建议包1：对齐圆桌导出）。

    内容：会话元信息 + 逐条消息（角色/时间/工具步骤摘要）。
    目录走 resolve_export_dir。返回 {"path": 绝对路径, "name": 文件名}。
    会话不存在抛 ValueError。
    """
    from sidecar.storage.store import load_messages, list_sessions

    sessions = list_sessions(project_id, agent_id) if agent_id else []
    title = ""
    if agent_id:
        for s in sessions:
            if s.get("id") == session_id:
                title = str(s.get("title") or "")
                break
    msgs = load_messages(project_id, session_id)
    if not msgs:
        raise ValueError("会话不存在或无消息")

    out_dir = resolve_export_dir(project_id) / "sessions"
    out_dir.mkdir(parents=True, exist_ok=True)
    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    fname = f"session-{session_id[:8]}-{ts}.md"
    path = out_dir / fname

    lines = ["# 会话导出",
             f"> 会话: {title or session_id}",
             f"> 导出时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}",
             ""]
    for m in msgs:
        role = m.get("role", "unknown")
        content = m.get("content", "") or ""
        created = m.get("created_at", "")
        if m.get("archived"):
            # TS-120：已移入知识仓库的消息导出时以占位提示替代，不带出原文
            lines.append(f"**{role}** ({created})")
            lines.append("（此内容已移入知识仓库）")
            lines.append("")
            continue
        tool_steps = m.get("tool_steps")
        if role == "assistant" and tool_steps:
            try:
                steps = json.loads(tool_steps) if isinstance(tool_steps, str) else tool_steps
                if isinstance(steps, list) and steps:
                    lines.append(f"**{role}** ({created})")
                    for st in steps:
                        lines.append(f"- 🔧 [{st.get('name', 'tool')}] {st.get('summary', '')}"
                                     f"（{'成功' if st.get('ok') else '失败'}）")
                    lines.append("")
                    lines.append(content)
                    lines.append("")
                    continue
            except Exception:
                pass
        lines.append(f"**{role}** ({created})")
        lines.append(content)
        lines.append("")
    path.write_text("\n".join(lines), encoding="utf-8")
    return {"path": str(path), "name": fname}


def save_delegation_report_md(project_id: str, task_id: str,
                              report: dict[str, Any], full_text: str) -> str | None:
    """交卷全文落盘（3.17 第一项：>1000 字自动保存）。

    保存到 <导出目录>/delegation_reports/<task_id>-<时间戳>.md。
    返回文件路径（相对导出目录的展示名由调用方标注）；写失败返回 None（不阻塞委派）。
    """
    try:
        out_dir = resolve_export_dir(project_id) / "delegation_reports"
        out_dir.mkdir(parents=True, exist_ok=True)
        ts = datetime.now().strftime("%Y%m%d-%H%M%S")
        safe_tid = "".join(c for c in str(task_id) if c.isalnum() or c in "-_")[:16]
        path = out_dir / f"{safe_tid}-{ts}.md"
        lines = ["# 委派交卷全文",
                 f"> 任务ID: {task_id}",
                 f"> 状态: {report.get('status', '')}",
                 f"> 落盘时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}",
                 "",
                 "## 交卷 summary（全文）",
                 "",
                 str(report.get("summary", "")),
                 "",
                 "## artifacts",
                 ""]
        for a in (report.get("artifacts") or []):
            lines.append(f"- {a}")
        lines += ["", "## 子 Agent 原始回复", "", str(full_text or "")]
        path.write_text("\n".join(lines), encoding="utf-8")
        return str(path)
    except Exception:
        return None
