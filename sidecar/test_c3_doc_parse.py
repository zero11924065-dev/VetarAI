# VetarAI - Local-first multi-agent orchestration application
# Copyright (C) 2026 zero11924065-dev
# GPL-3.0-or-later（见仓库 LICENSE）
"""C3（0.4.18）专项：老式 Word `.doc` 解析 + parser 局部去重回归。

═══ 为什么这些断言长这样（全部由 2026-09-10 真机实测决定，勿凭直觉改）═══

1. **exit code 恒为 0**：textutil 失败时也返回 0（实测：喂纯文本垃圾，stderr 报
   "Error reading stdin. The file isn't in the correct format." 但 exit=0）。
   → 所以判据必须是「stdout 为空 = 失败」，用 returncode 判会把失败当成功。
2. **必须强制 `-format doc`**：若走"文件路径 + 自动检测格式"，textutil 会把纯文本垃圾
   **当 txt 原样吐回**（exit=0、stdout=输入内容）→ 伪内容被当成解析成功，比失败更糟。
3. **转 txt 而不是 docx**：实测 `.doc → docx` 会**丢表格结构**（`d.tables` 为空，
   单元格被拍平成段落），而 `.doc → txt` 保留全部文本含表格单元格内容。
4. **.ppt/.xls 不支持**：`textutil -help` 的转换目标只有 Word 系/文本系
   （txt rtf rtfd html doc docx odt wordml webarchive），**不含 ppt/xls**。
   ⛔ 故断言它们**不在** SUPPORTED_EXTS —— 宁可如实不支持，也不假称支持。

运行：.venv/bin/python -m sidecar.test_c3_doc_parse
（⛔ 勿裸跑：本项目纪律是走 scripts/run_backend_tests.py 隔离 runner）
"""
import io
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

PASS, FAIL = 0, 0
FAILURES = []

IS_MAC = sys.platform == "darwin"
HAS_TEXTUTIL = IS_MAC and shutil.which("textutil") is not None


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"PASS  {name}")
    else:
        FAIL += 1
        FAILURES.append(name)
        print(f"FAIL  {name}  {detail}")


def _mk_doc(paragraphs=("会议纪要", "第一段：关于第三季度的安排。"),
            table=(("项目", "负责人"), ("停止链路", "张三"))) -> bytes:
    """用 macOS 自带 textutil 造一个**真实的老式 .doc**（含中文 + 表格）。

    ⛔ html 源必须带 `<meta charset="utf-8">`：实测不带时 textutil 会按系统默认编码
       读入 → 造出的 .doc 里中文就是乱码（这是**测试文件的构造缺陷**，不是产品缺陷；
       本轮核对时曾因此误判 textutil 中文能力有问题）。
    """
    rows = "".join("<tr>" + "".join(f"<td>{c}</td>" for c in r) + "</tr>" for r in table)
    body = "".join(f"<p>{p}</p>" for p in paragraphs)
    html = (f'<html><head><meta charset="utf-8"></head><body>'
            f'<h1>{paragraphs[0]}</h1>{body}'
            f'<table>{rows}</table><p>结尾段落：以上。</p></body></html>')
    out = subprocess.run(
        ["textutil", "-stdin", "-format", "html", "-convert", "doc", "-stdout"],
        input=html.encode("utf-8"), capture_output=True, timeout=30)
    data = out.stdout
    if not data:
        raise RuntimeError(f"造 .doc 失败（测试前置条件）：{out.stderr.decode('utf-8','replace')}")
    return data


def main():
    from sidecar.attachments import parser as P

    # ── T1 能力边界如实声明（不需要 macOS，跨平台可跑）──
    check("T1a .doc 已纳入 SUPPORTED_EXTS", ".doc" in P.SUPPORTED_EXTS)
    check("T1b .doc 在 LEGACY_WORD_EXTS", ".doc" in P.LEGACY_WORD_EXTS)
    # ⛔ 关键：不假称支持 .ppt/.xls（textutil 无此能力，见模块文档）
    check("T1c .ppt 不在 SUPPORTED_EXTS（如实不支持）", ".ppt" not in P.SUPPORTED_EXTS)
    check("T1d .xls 不在 SUPPORTED_EXTS（如实不支持）", ".xls" not in P.SUPPORTED_EXTS)
    # 既有格式不得因本次改动被挤掉
    for ext in (".pdf", ".docx", ".xlsx", ".xlsm", ".pptx", ".txt", ".csv", ".png"):
        check(f"T1e 既有格式 {ext} 仍受支持", ext in P.SUPPORTED_EXTS)

    # ── T2 kind 分发（不依赖真实 textutil：非 macOS/无工具时应返回 None+doc）──
    t, k = P.parse_attachment("无扩展名", b"x")
    check("T2a 无扩展名 → binary", k == "binary" and t is None, f"{k}|{t}")
    t, k = P.parse_attachment("x.unknown", b"x")
    check("T2b 未知扩展名 → binary", k == "binary", f"{k}")
    # .doc 的 kind 必须是 "doc"（即便解析失败也要如实标注格式，与 pdf 失败时一致）
    t, k = P.parse_attachment("损坏.doc", b"definitely not a doc")
    check("T2c .doc 的 kind 恒为 'doc'", k == "doc", f"{k}")

    # ── T3 去重回归：_row_to_line 与去重前逐字节等价 ──
    class C:
        def __init__(self, t): self.text = t
    check("T3a 正常行拼接", P._row_to_line([C("a"), C("b")]) == "a | b",
          repr(P._row_to_line([C("a"), C("b")])))
    check("T3b 全空行返回空串（调用方据此跳过）", P._row_to_line([C(""), C("   ")]) == "")
    check("T3c 单元格内换行被压平", P._row_to_line([C("x\ny"), C("z")]) == "x y | z",
          repr(P._row_to_line([C("x\ny"), C("z")])))
    check("T3d None.text 不抛错", P._row_to_line([C(None), C("b")]) == "b")

    # docx 真实文件走一遍（证明去重没破坏 docx 表格解析）
    import docx as _docx
    d = _docx.Document()
    d.add_paragraph("段落一")
    tb = d.add_table(rows=1, cols=2)
    tb.cell(0, 0).text = "列A"
    tb.cell(0, 1).text = "列B"
    buf = io.BytesIO(); d.save(buf)
    t, k = P.parse_attachment("去重后.docx", buf.getvalue())
    check("T3e docx 段落仍解析", k == "docx" and t and "段落一" in t, f"{k}|{t}")
    check("T3f docx 表格仍解析为 'a | b'（去重未破坏）",
          t is not None and "列A | 列B" in t, f"{t}")

    # pptx 表格同样走 _row_to_line（证明第二处去重也没破坏）
    try:
        from pptx import Presentation
        prs = Presentation()
        sl = prs.slides.add_slide(prs.slide_layouts[5])   # 空白版式
        tb2 = sl.shapes.add_table(1, 2, 0, 0, 100000, 50000).table
        tb2.cell(0, 0).text = "P列1"
        tb2.cell(0, 1).text = "P列2"
        b2 = io.BytesIO(); prs.save(b2)
        t2, k2 = P.parse_attachment("去重后.pptx", b2.getvalue())
        check("T3g pptx 表格仍解析（第二处去重未破坏）",
              k2 == "pptx" and t2 is not None and "P列1 | P列2" in t2, f"{k2}|{t2}")
    except Exception as e:
        print(f"SKIP T3g（pptx 表格构造失败：{e}）")

    # 常量改名的连带核查：xlsx 解析必须仍可用（曾因改名残留旧名致 NameError）
    import openpyxl
    wb = openpyxl.Workbook(); wb.active["A1"] = "单元格值"
    b3 = io.BytesIO(); wb.save(b3)
    t3, k3 = P.parse_attachment("改名后.xlsx", b3.getvalue())
    check("T3h xlsx 仍解析（_MAX_CELL_LEN 改名无残留 NameError）",
          k3 == "xlsx" and t3 is not None and "单元格值" in t3, f"{k3}|{t3}")
    t4, k4 = P.parse_attachment("改名后.csv", "甲,乙\n1,2".encode("utf-8"))
    check("T3i csv 仍解析（共用同一常量）", k4 == "csv" and t4 is not None and "甲 | 乙" in t4,
          f"{k4}|{t4}")

    # ── T4 真实 .doc 端到端（仅 macOS + textutil；否则优雅 SKIP）──
    if not HAS_TEXTUTIL:
        print("SKIP T4*（非 macOS 或无 textutil；.doc 端到端不可跑）")
        # 但「不支持时如实返回 None」必须验证 —— 这是非 macOS 用户的行为契约
        t, k = P.parse_attachment("a.doc", b"anything")
        check("T4z 非 macOS/无工具 → 如实返回 (None,'doc') 不抛错",
              k == "doc" and t is None, f"{k}|{t}")
    else:
        doc_bytes = _mk_doc()
        check("T4a 测试前置：已造出真实 .doc（OLE 复合文档）",
              len(doc_bytes) > 1000 and doc_bytes[:4] == b"\xd0\xcf\x11\xe0",
              f"len={len(doc_bytes)} head={doc_bytes[:4]!r}")

        t, k = P.parse_attachment("会议纪要.doc", doc_bytes)
        check("T4b 真 .doc 解析出 kind='doc'", k == "doc", f"{k}")
        check("T4c 真 .doc 中文完好（不出现 GBK 误解码乱码）",
              t is not None and "会议纪要" in t, repr(t))
        check("T4d 表格单元格内容保留（txt 路径不丢文本）",
              t is not None and "停止链路" in t and "张三" in t, repr(t))
        check("T4e 正文段落保留", t is not None and "结尾段落：以上。" in t, repr(t))

        # ⛔ T5 判据健壮性（对应实测陷阱 1/2）——损坏文件不得被当成成功
        for name, bad in (("纯文本垃圾", b"definitely not a doc file"),
                          ("OLE头+乱数据", b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1" + bytes(range(256)) * 4),
                          ("空文件", b""),
                          ("UTF-16 BOM 非 doc", "文本".encode("utf-16"))):
            tb_, kb_ = P.parse_attachment(f"{name}.doc", bad)
            check(f"T5 {name} → None（不把伪内容当成功）",
                  kb_ == "doc" and tb_ is None, f"{kb_}|{tb_!r}")

        # ⛔ T6 实现方式核查：必须强制 -format doc + 转 txt + 流式（不落临时文件）
        #    用「读源码断言」而非 monkeypatch —— 这三点是实测出来的硬约束，
        #    改动会静默退化（自动检测格式会让垃圾文件"解析成功"）。
        src = Path(P.__file__).read_text(encoding="utf-8")
        check("T6a 强制 -format doc（防自动检测把垃圾当 txt 吐回）",
              '"-format", "doc"' in src or "'-format', 'doc'" in src)
        check("T6b 转 txt 而非 docx（docx 会丢表格结构，实测）",
              '"-convert", "txt"' in src or "'-convert', 'txt'" in src)
        check("T6c 流式 stdin/stdout（不落临时文件，附件含隐私）",
              "-stdin" in src and "-stdout" in src)
        check("T6d 判据不依赖 returncode（textutil 失败也返回 0）",
              "returncode" not in src.split("def _parse_doc")[1].split("\ndef ")[0],
              "_parse_doc 内出现 returncode")
        check("T6e 外部进程设超时（防畸形文件挂死侧车）", "timeout=" in src)

    print(f"\n===== C3 专项: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        for f in FAILURES:
            print("  ✗", f)
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
