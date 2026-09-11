# VetarAI - Local-first multi-agent orchestration application
# Copyright (C) 2026 zero11924065-dev
# GPL-3.0-or-later（见仓库 LICENSE）
"""0.4.6：Office 输入/输出集成测试。

覆盖：
  D1 四种输入解析（docx/xlsx/pptx/pdf）真实构造文件后解析
  D2 pptx 解析含标题/正文/备注
  D3 create_document 四种类型端到端生成 + 反例
  D4 docx/xlsx/pptx 生成的文件可被对应解析器读回（闭环验证）
  D5 page_break 分页块
  D6 image 块尺寸 width_cm/height_cm（0.4.12 A7）
  D7 **#14（0.4.20）写出端按参考文件格式套用**（字体/字号/对齐/缩进/行距/页边距）

运行：.venv/bin/python -m sidecar.tools.test_office_io
变异：MUTATE=1|2|3 .venv/bin/python -m sidecar.tools.test_office_io
"""
import asyncio
import io
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

PASS, FAIL = 0, 0
FAILURES = []

# ══════════ 变异测试机制（0.4.20 补，针对 #14 写出端格式）══════════
#
# **为什么要补这个入口**：#14 交付时我确实做过 3 项变异验证（全部精准命中），
#   但用的是「临时打补丁 → 跑测试 → 手工还原」的一次性做法，**验证完就没留下任何东西**。
#   后果很实际：下次会话想复核"D7 那 13 个断言到底有没有用"，只能重新发明一遍变异方法。
#   固化成 MUTATE 入口后，一条命令即可复现验证。
#
# 运行：MUTATE=1|2|3 .venv/bin/python -m sidecar.tools.test_office_io
# ⛔ **变异模式下必须出现 FAIL**。若 0 FAIL，说明对应断言是空转的，断言需加强
#   （这不是"测试通过"，是"测试无效"）。
#
# | 变异 | 撤掉的修复 | 应失败的断言 |
# |---|---|---|
# | 1 | 读参考文件格式（reference_path 形同虚设） | D7c~h 六项 |
# | 2 | 正文段落格式套用（_apply_body_fmt） | D7f/g/h 三项（D7c/d/e 仍 PASS） |
# | 3 | 字号套用（回退默认 12pt） | D7d 单项 |
MUTATE = int(os.environ.get("MUTATE", "0"))

# ⛔ 还原必须用【内存备份】而非 `git checkout --`：变异期间工作区可能有未提交改动，
#   checkout 会把它们一并抹掉（test_p4_doc_reader 的既有纪律，此处沿用）。
_BACKUP: dict[str, str] = {}


def _read_src(mod) -> str:
    return Path(mod.__file__).read_text(encoding="utf-8")


def _apply_mutation() -> None:
    """把 #14 的修复改回缺陷态。

    ⛔ 锚点未命中必须 `assert` 报错——否则"变异没抓到"可能只是**根本没注入成功**。
    （0.4.18 的 B10/C8 变异2 就因多行字符串语法错误静默失败，跑出"全过"假象，
    我一度以为那处没有测试保护。）
    """
    if not MUTATE:
        return
    import sidecar.tools.doc_writer as dw
    import sidecar.tools.doc_reader as dr
    _BACKUP["dw"] = _read_src(dw)
    _BACKUP["dr"] = _read_src(dr)

    if MUTATE == 1:
        # 撤掉"读参考文件格式" → reference_path 形同虚设（D7c~h 应全 FAIL）
        s = _BACKUP["dw"]
        patched = s.replace("        ref_style = None\n        if reference_path:",
                            "        ref_style = None\n        if False:")
        assert patched != s, "变异 1 未命中 doc_writer 源码，测试无效"
        Path(dw.__file__).write_text(patched, encoding="utf-8")
    elif MUTATE == 2:
        # 撤掉正文段落格式套用 → D7f/g/h FAIL，而 D7c/d/e（字体/字号/边距）仍 PASS
        s = _BACKUP["dw"]
        patched = s.replace("            _apply_body_fmt(para, _body)", "            pass  # MUTATE2")
        assert patched != s, "变异 2 未命中 doc_writer 源码，测试无效"
        Path(dw.__file__).write_text(patched, encoding="utf-8")
    elif MUTATE == 3:
        # 撤掉字号套用 → D7d 单独 FAIL
        s = _BACKUP["dw"]
        patched = s.replace("    _pt = size_pt if (size_pt is not None and size_pt > 0) else 12.0",
                            "    _pt = 12.0  # MUTATE3")
        assert patched != s, "变异 3 未命中 doc_writer 源码，测试无效"
        Path(dw.__file__).write_text(patched, encoding="utf-8")
    else:
        raise SystemExit(f"未知变异编号 {MUTATE}（支持 1|2|3）")

    # ⛔⛔ 改写磁盘后**必须 reload**：registry 的 create_document 分支里是函数内
    #   `from sidecar.tools.doc_writer import write_document`，若不 reload，
    #   它会从 **sys.modules 缓存**取到旧模块 → 变异完全无效却显示"全过"（假通过）。
    import importlib
    importlib.reload(dr)
    importlib.reload(dw)


def _restore() -> None:
    """把被变异改写的源文件还原为测试开始前的内容（⛔ 务必放 finally）。"""
    if not MUTATE or not _BACKUP:
        return
    import sidecar.tools.doc_writer as dw
    import sidecar.tools.doc_reader as dr
    try:
        if "dw" in _BACKUP and _read_src(dw) != _BACKUP["dw"]:
            Path(dw.__file__).write_text(_BACKUP["dw"], encoding="utf-8")
        if "dr" in _BACKUP and _read_src(dr) != _BACKUP["dr"]:
            Path(dr.__file__).write_text(_BACKUP["dr"], encoding="utf-8")
    finally:
        _BACKUP.clear()


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"PASS  {name}")
    else:
        FAIL += 1
        FAILURES.append(name)
        print(f"FAIL  {name}  {detail}")


def _mk_docx(text: str = "测试段落内容") -> bytes:
    import docx
    d = docx.Document()
    d.add_paragraph(text)
    buf = io.BytesIO()
    d.save(buf)
    return buf.getvalue()


def _mk_pptx(title: str = "测试标题", body: str = "测试正文") -> bytes:
    from pptx import Presentation
    p = Presentation()
    sl = p.slides.add_slide(p.slide_layouts[1])
    sl.shapes.title.text = title
    sl.placeholders[1].text = body
    buf = io.BytesIO()
    p.save(buf)
    return buf.getvalue()


def _mk_xlsx(cell: str = "数据单元格") -> bytes:
    import openpyxl
    wb = openpyxl.Workbook()
    wb.active["A1"] = cell
    buf = io.BytesIO()
    wb.save(buf)
    return buf.getvalue()


def _mk_pdf() -> bytes:
    from pypdf import PdfWriter
    w = PdfWriter()
    w.add_blank_page(width=200, height=200)
    buf = io.BytesIO()
    w.write(buf)
    return buf.getvalue()


def _run_all():
    from sidecar.attachments.parser import parse_attachment
    from sidecar.tools.registry import execute

    # D1 四种输入解析
    t, k = parse_attachment("a.docx", _mk_docx())
    check("D1a docx 解析", k == "docx" and t and "测试段落内容" in t, f"{k}|{t}")
    t, k = parse_attachment("c.xlsx", _mk_xlsx())
    check("D1b xlsx 解析", k == "xlsx" and t and "数据单元格" in t, f"{k}|{t}")
    t, k = parse_attachment("d.pdf", _mk_pdf())
    check("D1c pdf 解析（空白页无文本返回None不报错）", k == "pdf" and t is None, f"{k}|{t}")

    # D2 pptx 解析（含标题/正文）
    t, k = parse_attachment("b.pptx", _mk_pptx())
    check("D2a pptx 解析kind", k == "pptx", str(k))
    check("D2b pptx 含标题", t is not None and "测试标题" in t, str(t))
    check("D2c pptx 含正文", t is not None and "测试正文" in t, str(t))

    tmp = tempfile.mkdtemp(prefix="office_io_")

    async def run():
        # D3 create_document 四种类型 + 反例
        r = await execute("create_document", {
            "path": f"{tmp}/报告.docx",
            "content": {"title": "T", "blocks": [
                {"type": "paragraph", "text": "正文"},
                {"type": "table", "rows": [["a", "b"], ["1", "2"]]}]}}, tmp)
        check("D3a docx 生成", r.get("ok") is True, str(r))

        r = await execute("create_document", {
            "path": f"{tmp}/数据.xlsx",
            "content": {"sheets": [{"name": "S", "rows": [["月份", "金额"], ["1月", "100"]]}]}}, tmp)
        check("D3b xlsx 生成", r.get("ok") is True, str(r))

        r = await execute("create_document", {
            "path": f"{tmp}/幻灯片.pptx",
            "content": {"slides": [{"title": "封面"}, {"title": "页2", "bullets": ["要点"]}]}}, tmp)
        check("D3c pptx 生成", r.get("ok") is True, str(r))

        r = await execute("create_document", {
            "path": f"{tmp}/总结.md",
            "content": {"title": "总结", "blocks": [{"type": "paragraph", "text": "正文"}]}}, tmp)
        check("D3d md 生成", r.get("ok") is True, str(r))

        r = await execute("create_document", {"path": f"{tmp}/x.docx", "content": "纯文本"}, tmp)
        check("D3e content非对象报错", r.get("ok") is False, str(r))

        r = await execute("create_document", {"path": f"{tmp}/y.xyz", "content": {"title": "t"}}, tmp)
        check("D3f 未知类型报错", r.get("ok") is False, str(r))

        # D4 闭环：生成的文件可被解析器读回
        docx_bytes = Path(f"{tmp}/报告.docx").read_bytes()
        t, k = parse_attachment("报告.docx", docx_bytes)
        check("D4a 生成的docx可解析", k == "docx" and t and "正文" in t, f"{k}|{t}")

        xlsx_bytes = Path(f"{tmp}/数据.xlsx").read_bytes()
        t, k = parse_attachment("数据.xlsx", xlsx_bytes)
        check("D4b 生成的xlsx可解析", k == "xlsx" and t and "100" in t, f"{k}|{t}")

        pptx_bytes = Path(f"{tmp}/幻灯片.pptx").read_bytes()
        t, k = parse_attachment("幻灯片.pptx", pptx_bytes)
        check("D4c 生成的pptx可解析", k == "pptx" and t and "要点" in t, f"{k}|{t}")

        # D5 page_break 分页块（案件证据文档每份证据独立起页的核心能力）
        r = await execute("create_document", {
            "path": f"{tmp}/证据.docx",
            "content": {"title": "证据", "blocks": [
                {"type": "heading", "level": 2, "text": "证据一 借据"},
                {"type": "paragraph", "text": "借据内容"},
                {"type": "page_break"},
                {"type": "heading", "level": 2, "text": "证据二 转账记录"},
                {"type": "paragraph", "text": "转账内容"},
            ]}}, tmp)
        check("D5a docx 分页块生成成功", r.get("ok") is True, str(r))
        import docx as _docx
        _d = _docx.Document(r["path"])
        _breaks = sum(1 for p in _d.paragraphs for run in p.runs
                      if "page" in run._element.xml and "w:br" in run._element.xml)
        check("D5b docx 含分页符", _breaks >= 1, f"breaks={_breaks}")

        r = await execute("create_document", {
            "path": f"{tmp}/证据.md",
            "content": {"blocks": [
                {"type": "paragraph", "text": "证据一"},
                {"type": "page_break"},
                {"type": "paragraph", "text": "证据二"}]}}, tmp)
        _md = Path(r["path"]).read_text(encoding="utf-8")
        check("D5c md 分页标记存在", "---" in _md, _md[:60])

        # ---------- D6（0.4.12 A7）：image 块尺寸 width_cm / height_cm ----------
        # ⛔ 关键语义：add_picture 同时传 width+height 会【强制拉伸不保比例】，
        #    只传其一则另一维按原图比例自动推算。用例覆盖：默认 / 只宽 / 只高 / 都给 / 带单位字符串。
        _img = Path(tmp) / "_probe_2to1.png"
        from PIL import Image
        Image.new("RGB", (800, 400), (200, 220, 240)).save(_img)   # 宽高比恒 2.00

        import docx as _docx2

        async def _img_docx(name, size_fields):
            r = await execute("create_document", {
                "path": f"{tmp}/img_{name}.docx",
                "content": {"title": "T", "blocks": [
                    {"type": "image", "path": str(_img), **size_fields}]}}, tmp)
            assert r.get("ok") is True, f"{name} 生成失败: {r}"
            sh = _docx2.Document(r["path"]).inline_shapes[0]
            return sh.width / 360000, sh.height / 360000   # EMU → cm

        w, h = await _img_docx("default", {})
        check("D6a 默认（都不给）→ width=13 且按比例算出 height=6.5",
              abs(w - 13.0) < 0.02 and abs(h - 6.5) < 0.02, f"{w:.2f}x{h:.2f}")

        w, h = await _img_docx("onlyw", {"width_cm": 10})
        check("D6b 只给 width=10 → height 按比例自动=5（不变形）",
              abs(w - 10.0) < 0.02 and abs(h - 5.0) < 0.02, f"{w:.2f}x{h:.2f}")

        w, h = await _img_docx("onlyh", {"height_cm": 5})
        check("D6c ⭐只给 height=5 → width 按比例自动=10（本次新增能力）",
              abs(w - 10.0) < 0.02 and abs(h - 5.0) < 0.02, f"{w:.2f}x{h:.2f}")

        w, h = await _img_docx("both", {"width_cm": 8, "height_cm": 6})
        check("D6d 两者都给 → 按显式尺寸（拉伸，属用户指定意图）",
              abs(w - 8.0) < 0.02 and abs(h - 6.0) < 0.02, f"{w:.2f}x{h:.2f}")

        w, h = await _img_docx("unitstr", {"width_cm": "12cm"})
        check("D6e 带单位字符串 '12cm' 可解析 → width=12 height=6",
              abs(w - 12.0) < 0.02 and abs(h - 6.0) < 0.02, f"{w:.2f}x{h:.2f}")

        w, h = await _img_docx("invalid", {"width_cm": "abc", "height_cm": -3})
        check("D6f 非法值（'abc' / 负数）安全忽略 → 回落默认 13x6.5",
              abs(w - 13.0) < 0.02 and abs(h - 6.5) < 0.02, f"{w:.2f}x{h:.2f}")

        w, h = await _img_docx("grid_h", {"layout": "grid", "paths": [str(_img)] * 2,
                                          "height_cm": 4})
        check("D6g grid 布局也接受 height_cm（列宽固定 4.4，高度受约束）",
              abs(h - 4.0) < 0.02, f"{w:.2f}x{h:.2f}")

        from sidecar.tools.doc_writer import _to_pos_float
        check("D6h _to_pos_float 区分「未指定」与「指定 0」（0→None 非 0.0）",
              _to_pos_float(0) is None and _to_pos_float(None) is None
              and _to_pos_float(True) is None and _to_pos_float("7.5") == 7.5,
              f"0→{_to_pos_float(0)} None→{_to_pos_float(None)}")

        # ---------- D7（0.4.20 #14）：写出端按参考文件格式套用 ----------
        # 需求：「读参考文件字体/字号/对齐/页边距 → 写出来」。读取端（doc_reader）已提取，
        #   本组验证写出端（doc_writer.write_document(reference_path=...)）真的把格式套上去。
        # ⛔ 用户拍板「通用能力非模板」：不内置任何固定模板，只按用户给的参考文件复刻。
        import docx as _docx3
        from docx.shared import Pt as _Pt, Cm as _Cm
        from docx.enum.text import WD_ALIGN_PARAGRAPH as _AL
        from docx.oxml.ns import qn as _qn
        from sidecar.tools import doc_reader as _dr

        def _set_cjk(run, font):
            rpr = run._element.get_or_add_rPr()
            rf = rpr.find(_qn("w:rFonts"))
            if rf is None:
                from docx.oxml import OxmlElement
                rf = OxmlElement("w:rFonts"); rpr.append(rf)
            rf.set(_qn("w:eastAsia"), font)

        # 构造参考 docx：正文=楷体 16pt 右对齐 首行缩进1.5cm 行距1.5倍；页边距全 5cm
        ref = Path(tmp) / "ref_fmt.docx"
        rd = _docx3.Document()
        rs = rd.sections[0]
        rs.top_margin = rs.bottom_margin = rs.left_margin = rs.right_margin = _Cm(5.0)
        for txt in ["参考正文一", "参考正文二", "参考正文三"]:
            p = rd.add_paragraph(txt)
            p.alignment = _AL.RIGHT
            p.paragraph_format.first_line_indent = _Cm(1.5)
            p.paragraph_format.line_spacing = 1.5
            for r in p.runs:
                r.font.size = _Pt(16)
                _set_cjk(r, "楷体")
        rd.save(str(ref))

        # D7a 提取端：extract_docx_style 返回结构化 dict（非字符串）
        st = _dr.extract_docx_style(ref)
        check("D7a extract_docx_style 返回结构化 dict",
              isinstance(st, dict) and st.get("body", {}).get("font") == "楷体"
              and st["body"].get("size_pt") == 16.0
              and st["body"].get("align_value") == 2
              and abs(st["body"].get("first_line_indent_cm", 0) - 1.5) < 0.01
              and st["body"].get("line_spacing") == 1.5
              and abs(st["page"].get("top_cm", 0) - 5.0) < 0.01, str(st))

        # D7b 写出端端到端：reference_path 套用 → 读回核对六项格式
        r = await execute("create_document", {
            "path": f"{tmp}/out_fmt.docx",
            "reference_path": str(ref),
            "content": {"title": "标题", "blocks": [
                {"type": "paragraph", "text": "新文档正文段落"}]}}, tmp)
        check("D7b 带 reference_path 生成成功", r.get("ok") is True, str(r))

        od = _docx3.Document(r["path"])
        os_ = od.sections[0]
        nrpr = od.styles["Normal"].element.find(_qn("w:rPr"))
        nrf = nrpr.find(_qn("w:rFonts")) if nrpr is not None else None
        nsz = nrpr.find(_qn("w:sz")) if nrpr is not None else None
        _bp = [p for p in od.paragraphs if p.text == "新文档正文段落"]
        bp = _bp[0] if _bp else None
        pf = bp.paragraph_format if bp else None
        check("D7c 字体套用（Normal eastAsia=楷体）",
              nrf is not None and nrf.get(_qn("w:eastAsia")) == "楷体",
              nrf.get(_qn("w:eastAsia")) if nrf is not None else "None")
        check("D7d 字号套用（Normal sz=32 半磅=16pt）",
              nsz is not None and nsz.get(_qn("w:val")) == "32",
              nsz.get(_qn("w:val")) if nsz is not None else "None")
        check("D7e 页边距套用（上下左右=5cm）",
              abs(os_.top_margin.cm - 5.0) < 0.01 and abs(os_.left_margin.cm - 5.0) < 0.01,
              f"上{round(os_.top_margin.cm,2)} 左{round(os_.left_margin.cm,2)}")
        check("D7f 正文对齐套用（RIGHT）",
              bp is not None and bp.alignment == _AL.RIGHT,
              str(bp.alignment) if bp else "无正文段")
        check("D7g 正文首行缩进套用（1.5cm）",
              pf is not None and pf.first_line_indent is not None
              and abs(pf.first_line_indent.cm - 1.5) < 0.01,
              f"{round(pf.first_line_indent.cm,2) if pf and pf.first_line_indent else None}")
        check("D7h 正文行距套用（1.5 倍）",
              pf is not None and pf.line_spacing == 1.5,
              str(pf.line_spacing) if pf else "无正文段")

        # D7i 缺省回退：不给 reference_path → 仍是默认（宋体/12pt/A4 边距3.18）
        r2 = await execute("create_document", {
            "path": f"{tmp}/out_default.docx",
            "content": {"title": "标题", "blocks": [
                {"type": "paragraph", "text": "默认正文"}]}}, tmp)
        dd = _docx3.Document(r2["path"])
        dnrpr = dd.styles["Normal"].element.find(_qn("w:rPr"))
        drf = dnrpr.find(_qn("w:rFonts")) if dnrpr is not None else None
        dsz = dnrpr.find(_qn("w:sz")) if dnrpr is not None else None
        check("D7i 不给 reference_path → 默认宋体/12pt（向后兼容）",
              drf is not None and drf.get(_qn("w:eastAsia")) == "宋体"
              and dsz is not None and dsz.get(_qn("w:val")) == "24",
              f"{drf.get(_qn('w:eastAsia')) if drf is not None else None}/"
              f"{dsz.get(_qn('w:val')) if dsz is not None else None}")

        # D7j 异常容错：reference_path 指向不存在文件 → 静默回退默认、不报错、仍产出
        r3 = await execute("create_document", {
            "path": f"{tmp}/out_badref.docx",
            "reference_path": f"{tmp}/不存在.docx",
            "content": {"title": "标题", "blocks": [
                {"type": "paragraph", "text": "正文"}]}}, tmp)
        check("D7j reference 文件不存在 → 仍成功生成（回退默认）",
              r3.get("ok") is True and Path(r3["path"]).is_file(), str(r3))

        # D7k 异常容错：reference_path 指向非 docx（.xlsx）→ 忽略参考、仍产出 docx
        r4 = await execute("create_document", {
            "path": f"{tmp}/out_xlsxref.docx",
            "reference_path": f"{tmp}/数据.xlsx",
            "content": {"title": "标题", "blocks": [
                {"type": "paragraph", "text": "正文"}]}}, tmp)
        check("D7k reference 非 docx（.xlsx）→ 忽略参考、仍生成 docx",
              r4.get("ok") is True and Path(r4["path"]).is_file(), str(r4))

        # D7l 仅 docx 生效：md 给 reference_path 不报错（md 无段落排版，安全忽略）
        r5 = await execute("create_document", {
            "path": f"{tmp}/out_ref.md",
            "reference_path": str(ref),
            "content": {"title": "标题", "blocks": [
                {"type": "paragraph", "text": "正文"}]}}, tmp)
        check("D7l md + reference_path → 安全忽略、正常生成",
              r5.get("ok") is True and Path(r5["path"]).is_file(), str(r5))

    asyncio.run(run())

    import shutil
    shutil.rmtree(tmp, ignore_errors=True)

    print(f"\n===== 结果：{PASS} PASS / {FAIL} FAIL =====")
    if FAILURES:
        print("失败项：", "、".join(FAILURES))
    if MUTATE and FAIL == 0:
        # ⛔ 变异模式下 0 FAIL 不是"通过"，是"测试无效"——说明断言没真正绑定这个修复
        print(f"⛔ 变异 {MUTATE} 未被抓住 —— 本测试对该修复无效，断言需加强")
    if FAIL or (MUTATE and FAIL == 0):
        sys.exit(1)


def main() -> None:
    """薄包装：注入变异 → 跑用例 → **无论成败都还原源码**。

    ⛔ _restore() 必须放 finally：用例失败时会 sys.exit(1) 抛 SystemExit，
    若不放在 finally，被改写的 doc_writer.py / doc_reader.py 会**留在变异态**，
    污染后续所有测试与真实代码。
    """
    print(f"#14 Office 输入/输出集成测试  |  变异模式 = {MUTATE}")
    _apply_mutation()
    try:
        _run_all()
    finally:
        _restore()


if __name__ == "__main__":
    main()
