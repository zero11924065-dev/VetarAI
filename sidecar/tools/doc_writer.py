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
"""0.4.6：Office 文档生成器（内置，非插件）。

Agent 通过 create_document 工具调用本模块，按结构化内容契约生成真实的
Word(.docx) / Excel(.xlsx) / PowerPoint(.pptx) / Markdown(.md) 文件，
保存到项目工作目录。全部本地生成，不联网。

内容契约（模型填写，JSON 对象）：
- docx / md：{"title": str, "blocks": [Block, ...]}
- xlsx：     {"sheets": [{"name": str, "rows": [[cell, ...], ...]}, ...]}
- pptx：     {"slides": [{"title": str, "bullets": [str,...], "notes": str}, ...]}

Block 类型：
- {"type": "heading",   "level": 1~4, "text": str}
- {"type": "paragraph", "text": str}
- {"type": "bullets",   "items": [str, ...]}
- {"type": "table",     "rows": [[cell, ...], ...]}（首行为表头）
"""
from __future__ import annotations

from pathlib import Path
from typing import Any

SUPPORTED_DOC_TYPES = {"docx", "xlsx", "pptx", "md", "markdown"}


def _clean_text(v: Any) -> str:
    return str(v) if v is not None else ""


def _extract_blocks(content: dict) -> tuple[str, list[dict]]:
    title = _clean_text(content.get("title") or "")
    blocks = content.get("blocks") or []
    if not isinstance(blocks, list):
        blocks = []
    return title, [b for b in blocks if isinstance(b, dict)]


def _write_md(target: Path, content: dict) -> int:
    title, blocks = _extract_blocks(content)
    lines: list[str] = []
    if title:
        lines.append(f"# {title}\n")
    for b in blocks:
        t = b.get("type", "paragraph")
        if t == "heading":
            level = max(1, min(int(b.get("level") or 2), 6))
            lines.append(f"{'#' * level} {_clean_text(b.get('text'))}\n")
        elif t == "bullets":
            for it in (b.get("items") or []):
                lines.append(f"- {_clean_text(it)}")
            lines.append("")
        elif t == "table":
            rows = b.get("rows") or []
            if rows:
                header = [_clean_text(c) for c in rows[0]]
                lines.append("| " + " | ".join(header) + " |")
                lines.append("| " + " | ".join(["---"] * len(header)) + " |")
                for r in rows[1:]:
                    lines.append("| " + " | ".join(_clean_text(c) for c in r) + " |")
                lines.append("")
        else:
            lines.append(_clean_text(b.get("text")) + "\n")
    text = "\n".join(lines).strip() + "\n"
    target.write_text(text, encoding="utf-8")
    return len(text.encode("utf-8"))


def _write_docx(target: Path, content: dict) -> int:
    import docx
    title, blocks = _extract_blocks(content)
    d = docx.Document()
    if title:
        d.add_heading(title, level=0)
    for b in blocks:
        t = b.get("type", "paragraph")
        if t == "heading":
            level = max(1, min(int(b.get("level") or 2), 4))
            d.add_heading(_clean_text(b.get("text")), level=level)
        elif t == "bullets":
            for it in (b.get("items") or []):
                d.add_paragraph(_clean_text(it), style="List Bullet")
        elif t == "table":
            rows = b.get("rows") or []
            if rows:
                ncols = max(len(r) for r in rows)
                tbl = d.add_table(rows=len(rows), cols=ncols)
                tbl.style = "Light Grid Accent 1"
                for i, r in enumerate(rows):
                    for j in range(ncols):
                        tbl.rows[i].cells[j].text = _clean_text(r[j]) if j < len(r) else ""
        else:
            d.add_paragraph(_clean_text(b.get("text")))
    d.save(str(target))
    return target.stat().st_size


def _write_xlsx(target: Path, content: dict) -> int:
    import openpyxl
    sheets = content.get("sheets") or []
    wb = openpyxl.Workbook()
    wb.remove(wb.active)  # 移除默认空表
    if not sheets:
        wb.create_sheet("Sheet1")
    for idx, sh in enumerate(sheets):
        if not isinstance(sh, dict):
            continue
        name = _clean_text(sh.get("name") or f"Sheet{idx + 1}")[:31] or f"Sheet{idx + 1}"
        ws = wb.create_sheet(name)
        for r_idx, row in enumerate(sh.get("rows") or [], start=1):
            for c_idx, cell in enumerate(row, start=1):
                v = cell
                # 纯数字字符串转数字，便于 Excel 计算
                if isinstance(v, str):
                    s = v.strip()
                    if s.lstrip("-").isdigit():
                        v = int(s)
                    elif s.replace(".", "", 1).lstrip("-").isdigit() and s.count(".") == 1:
                        v = float(s)
                ws.cell(row=r_idx, column=c_idx, value=v)
    wb.save(str(target))
    return target.stat().st_size


def _write_pptx(target: Path, content: dict) -> int:
    from pptx import Presentation
    from pptx.util import Pt
    slides = content.get("slides") or []
    prs = Presentation()
    title_layout = prs.slide_layouts[0]   # 标题页
    bullet_layout = prs.slide_layouts[1]  # 标题+内容
    blank_title = prs.slide_layouts[5]    # 仅标题
    if not slides:
        slides = [{"title": _clean_text(content.get("title") or "演示文稿"), "bullets": []}]
    for idx, sl in enumerate(slides):
        if not isinstance(sl, dict):
            continue
        s_title = _clean_text(sl.get("title") or "")
        bullets = [b for b in (sl.get("bullets") or [])]
        notes = _clean_text(sl.get("notes") or "")
        layout = title_layout if idx == 0 and not bullets else (bullet_layout if bullets else blank_title)
        slide = prs.slides.add_slide(layout)
        if slide.shapes.title is not None:
            slide.shapes.title.text = s_title
        if bullets and layout in (bullet_layout,):
            tf = slide.placeholders[1].text_frame
            tf.text = _clean_text(bullets[0])
            for b in bullets[1:]:
                p = tf.add_paragraph()
                p.text = _clean_text(b)
                p.level = 0
        if notes and slide.has_notes_slide:
            slide.notes_slide.notes_text_frame.text = notes
        elif notes:
            try:
                slide.notes_slide.notes_text_frame.text = notes
            except Exception:
                pass
    prs.save(str(target))
    return target.stat().st_size


def write_document(doc_type: str, target: Path, content: dict) -> int:
    """按类型生成文档，返回写入字节数。不支持的类型抛 ValueError。"""
    if not isinstance(content, dict):
        raise ValueError("bad_arg: content 必须是结构化 JSON 对象（非纯文本）")
    dt = (doc_type or "").lower().strip()
    if dt in ("md", "markdown"):
        return _write_md(target, content)
    if dt == "docx":
        return _write_docx(target, content)
    if dt in ("xlsx", "xls"):
        return _write_xlsx(target, content)
    if dt in ("pptx", "ppt"):
        return _write_pptx(target, content)
    raise ValueError(f"bad_arg: doc_type '{doc_type}' 不支持（可选 docx/xlsx/pptx/md）")
