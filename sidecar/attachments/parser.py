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
"""M7（TS-113）：圆桌附件内置解析器（核心，非插件）。

支持格式（3.17 第三项）：
- PDF（pypdf 逐页）/ Word .docx（python-docx 段落+表格）/
  Excel .xlsx（openpyxl 逐 sheet 逐行）/ CSV（标准库）/ 纯文本族（utf-8/gbk）
- 图片（.png/.jpg/.jpeg/.gif/.webp）→ 可选视觉模型识别（vision_parse_attachments 开关）
- **老式 Word `.doc`（C3 / 0.4.18）** → macOS 自带 `textutil` 转纯文本，**零外部依赖**
- 其余格式 → 返回 None（调用方仅标注，与现状一致）

**C3 的能力边界（2026-09-10 实测坐实，不得夸大）**：
`textutil -help` 列出的转换目标只有 **Word 系/文本系**（txt rtf rtfd html doc docx odt
wordml webarchive），**不含 ppt/xls** → 老式 **`.ppt`/`.xls` 仍不支持**，需 LibreOffice 等
外部依赖，与"零依赖 + 本地优先"冲突，故不做、也不在 SUPPORTED_EXTS 里假称支持。

约定：解析失败一律返回 None（调用方标注，不阻塞圆桌创建）；
截断由调用方按单文件/总量限制处理。
"""
from __future__ import annotations

import csv
import io
import shutil
import subprocess
import sys

# 文本族扩展名（小写，含点）
TEXT_EXTS = {".txt", ".md", ".markdown", ".json", ".yaml", ".yml", ".ini",
             ".log", ".py", ".js", ".ts", ".tsx", ".jsx", ".html", ".htm",
             ".xml", ".toml", ".cfg", ".conf", ".sh", ".css", ".csv"}
IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".gif", ".webp"}
# C3（0.4.18）：老式 Word .doc 经 macOS 自带 textutil 支持（.ppt/.xls 不支持，见模块文档）
LEGACY_WORD_EXTS = {".doc"}
SUPPORTED_EXTS = (TEXT_EXTS | IMAGE_EXTS | LEGACY_WORD_EXTS
                  | {".pdf", ".docx", ".xlsx", ".xlsm", ".pptx"})

# Excel/CSV 防爆炸：单 sheet 最多行数 / 单元格截断
_XLSX_MAX_ROWS_PER_SHEET = 200
# 局部去重（0.4.18）：此常量原名 `_XLSX_MAX_CELL_LEN`，但 `_parse_csv` 也在用它，
#    名字带 XLSX 属**命名失真**（读代码的人会以为只作用于 Excel）→ 改为中性名。
_MAX_CELL_LEN = 200
# C3：textutil 是**外部进程**，必须设超时，否则畸形文件可能挂死侧车
_DOC_CONVERT_TIMEOUT = 30


def _ext_of(name: str) -> str:
    n = str(name or "").lower()
    return n[n.rfind("."):] if "." in n else ""


def _row_to_line(cells) -> str:
    """局部去重（0.4.18）：表格行 → "a | b | c" 一行。

    原 `_parse_docx` 与 `_parse_pptx` 各写了**完全相同的两行**
    （strip + 去换行 + " | " 拼接 + 过滤空单元格）→ 收敛到此处，
    将来加新表格型格式（如 .odt）不必再抄一遍。
    返回 "" 表示整行皆空（调用方据此跳过）。
    """
    parts = [(getattr(c, "text", "") or "").strip().replace("\n", " ") for c in cells]
    return " | ".join(p for p in parts if p)


def _parse_text(raw: bytes) -> str | None:
    for enc in ("utf-8", "gbk", "latin-1"):
        try:
            return raw.decode(enc)
        except (UnicodeDecodeError, ValueError):
            continue
    return None


def _parse_csv(raw: bytes) -> str | None:
    text = _parse_text(raw)
    if text is None:
        return None
    try:
        rows = list(csv.reader(io.StringIO(text)))[:500]
        lines = [" | ".join(str(c)[:_MAX_CELL_LEN] for c in row) for row in rows if row]
        return "\n".join(lines) if lines else None
    except Exception:
        return None


def _parse_doc(raw: bytes) -> str | None:
    """C3（0.4.18）：老式 Word `.doc` → 纯文本，用 **macOS 自带 `textutil`**，零外部依赖。

    实现方式的三个关键选择，全部由 2026-09-10 实测决定（**勿凭直觉改**）：

    1. **转 txt 而不是 docx**。记忆里曾记"推荐 `-convert docx` 后复用 python-docx 链"，
       实测证明**次优**：`.doc → docx` 会**丢表格结构**（`d.tables` 为空，单元格被拍平成
       段落），而 `.doc → txt` **保留全部文本含表格单元格内容**（逐行输出）。
       附件解析的目标是"给模型读全文"，不是还原排版 → txt 完胜。
    2. **不能用 exit code 判成败——textutil 失败时也返回 0**（实测：喂纯文本垃圾，
       stderr 报 "Error reading stdin. The file isn't in the correct format." 但 `exit=0`）。
       可靠判据是 **stdout 为空 → 失败**。
    3. **必须强制 `-format doc`**。若走"文件路径 + 自动检测格式"，textutil 会把纯文本
       垃圾**当 txt 原样吐回**（exit=0、stdout=输入内容）→ 乱码/伪内容被误判为"解析成功"，
       比解析失败更糟。强制声明输入格式后：损坏文件 stdout 为空 + stderr 报错（实测确认）。

    另：用 **stdin/stdout 流式**（`-stdin -stdout`），**不落临时文件**——附件可能含隐私，
    写盘会留下未清理副本（实测该路径 exit=0 且中文完好）。
    """
    if sys.platform != "darwin":
        return None                      # 非 macOS：无 textutil，如实返回不支持
    if shutil.which("textutil") is None:
        return None                      # 理论不该发生（系统自带），防御性降级
    try:
        proc = subprocess.run(
            ["textutil", "-stdin", "-format", "doc", "-convert", "txt", "-stdout"],
            input=raw, capture_output=True, timeout=_DOC_CONVERT_TIMEOUT,
        )
    except (subprocess.TimeoutExpired, OSError):
        return None                      # 超时/无法启动 → 按失败处理，不阻塞调用方
    out = proc.stdout.decode("utf-8", "replace").strip()
    # 判据见上：exit code 不可信；stdout 空 = 失败（损坏/空文件/非 doc）
    if not out:
        return None
    return out



def _parse_pdf(raw: bytes) -> str | None:
    try:
        from pypdf import PdfReader
        reader = PdfReader(io.BytesIO(raw))
        parts = []
        for i, page in enumerate(reader.pages):
            t = (page.extract_text() or "").strip()
            if t:
                parts.append(f"[第{i + 1}页]\n{t}")
        return "\n\n".join(parts) if parts else None
    except Exception:
        return None


def _parse_docx(raw: bytes) -> str | None:
    try:
        import docx
        d = docx.Document(io.BytesIO(raw))
        parts: list[str] = []
        for para in d.paragraphs:
            t = (para.text or "").strip()
            if t:
                parts.append(t)
        for table in d.tables:
            for row in table.rows:
                # 局部去重（0.4.18）：原此处与 _parse_pptx 各写了完全相同的两行，
                #    现统一走 _row_to_line。⚠️ 不能把 _parse_xlsx 也并进来——xlsx 的单元格
                #    是裸值（str/int/None）而非带 .text 属性的对象，套用会得到全空串。
                line = _row_to_line(row.cells)
                if line:
                    parts.append(line)
        return "\n".join(parts) if parts else None
    except Exception:
        return None


def _parse_xlsx(raw: bytes) -> str | None:
    try:
        import openpyxl
        wb = openpyxl.load_workbook(io.BytesIO(raw), read_only=True, data_only=True)
        parts: list[str] = []
        for ws in wb.worksheets:
            lines = [f"[工作表: {ws.title}]"]
            for i, row in enumerate(ws.iter_rows(values_only=True)):
                if i >= _XLSX_MAX_ROWS_PER_SHEET:
                    lines.append(f"（后续行已省略，共超 {i} 行）")
                    break
                vals = [str(c)[:_MAX_CELL_LEN] if c is not None else "" for c in row]
                line = " | ".join(v for v in vals if v != "")
                if line.strip():
                    lines.append(line)
            if len(lines) > 1:
                parts.append("\n".join(lines))
        wb.close()
        return "\n\n".join(parts) if parts else None
    except Exception:
        return None


def _parse_pptx(raw: bytes) -> str | None:
    """0.4.6：PowerPoint .pptx 解析（python-pptx 逐页：标题+正文+表格+备注）。"""
    try:
        from pptx import Presentation
        prs = Presentation(io.BytesIO(raw))
        parts: list[str] = []
        for i, slide in enumerate(prs.slides):
            lines = [f"[第{i + 1}页]"]
            if slide.shapes.title is not None and (slide.shapes.title.text or "").strip():
                lines.append(f"标题: {(slide.shapes.title.text or '').strip()}")
            for shape in slide.shapes:
                if shape is slide.shapes.title:
                    continue
                if shape.has_text_frame:
                    t = (shape.text_frame.text or "").strip()
                    if t:
                        lines.append(t)
                elif shape.has_table:
                    for row in shape.table.rows:
                        # 局部去重（0.4.18）：与 _parse_docx 原为完全相同的两行 → 统一走 _row_to_line
                        line = _row_to_line(row.cells)
                        if line:
                            lines.append(line)
            # 演讲者备注（常含关键信息）
            try:
                if slide.has_notes_slide and slide.notes_slide.notes_text_frame:
                    note = (slide.notes_slide.notes_text_frame.text or "").strip()
                    if note:
                        lines.append(f"备注: {note}")
            except Exception:
                pass
            if len(lines) > 1:
                parts.append("\n".join(lines))
        return "\n\n".join(parts) if parts else None
    except Exception:
        return None


def parse_attachment(name: str, raw: bytes) -> tuple[str | None, str]:
    """解析附件内容为文本。

    返回 (text, kind)：
    - text: 解析出的文本；无法解析/失败 → None
    - kind: "text"/"pdf"/"docx"/"doc"/"xlsx"/"csv"/"pptx"/"image"/"binary"（标注用）

    图片：本函数不识别（返回 (None, "image")）；视觉识别由异步调用方
    （app.py，因连接器 chat 为异步）在配置开关开启时单独完成。
    """
    ext = _ext_of(name)
    if ext == ".pdf":
        return _parse_pdf(raw), "pdf"
    if ext == ".docx":
        return _parse_docx(raw), "docx"
    if ext in LEGACY_WORD_EXTS:
        # C3（0.4.18）：老式 .doc → textutil 转 txt。
        # 非 macOS 或转换失败 → (None, "doc")，调用方按既有约定"仅标注文件名"，
        #    与 .pdf 解析失败时行为一致，不会抛错阻塞圆桌创建/聊天上传。
        return _parse_doc(raw), "doc"
    if ext in (".xlsx", ".xlsm"):
        return _parse_xlsx(raw), "xlsx"
    if ext == ".pptx":
        return _parse_pptx(raw), "pptx"
    if ext == ".csv":
        return _parse_csv(raw), "csv"
    if ext in TEXT_EXTS:
        return _parse_text(raw), "text"
    if ext in IMAGE_EXTS:
        return None, "image"
    return None, "binary"
