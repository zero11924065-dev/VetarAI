# VetarAI - Local-first multi-agent orchestration application
# Copyright (C) 2026 zero11924065-dev
# GPL-3.0-or-later（见仓库 LICENSE）
"""C4（0.4.18）专项：工作流 file_read 节点复用附件解析器（治"工作流不可读 pdf"）。

═══ 治的是什么 ═══
_run_file_read 原本 `read_bytes()[:max].decode('utf-8','replace')`，**不调任何解析器**
→ PDF/docx/xlsx/pptx/.doc 读出来是乱码。聊天附件解析器早有完整能力，但引擎未复用。

═══ 关键约束（勿凭直觉改）═══
1. ⛔ **两个上限必须分开**：`max_bytes` = 输出**文本**上限（上下文装的是文本）；
   `_FILE_READ_MAX_SOURCE_BYTES` = **源文件字节**上限（二进制格式必须整读才能解析）。
2. ⛔ **二进制格式不能"先截断字节再解析"**：截断破坏容器结构（PDF/ZIP 中央目录在
   文件尾部）→ 解析必然失败。必须整读→解析→再截断文本。
3. ⛔ **解析是 sync + CPU 密集，引擎是 async** → 必须 run_in_executor，否则阻塞事件
   循环（心跳/SSE/取消全卡住，用户点停止无响应）。_run_code 已有同一先例。
4. ⛔ **解析失败必须如实报错**，不能塞乱码/空串——乱码会让下游推理节点产出无意义结论，
   且用户无从察觉（这正是改造前的病症）。
5. ⛔ **格式清单从 parser 推导，不另写一份**：C3 刚清理过前端 PARSEABLE_EXTS 与后端
   SUPPORTED_EXTS 双源漂移（前端缺 .pptx 致其永不解析），不能重犯。
6. ⚠️ **.csv 有意走纯文本路径原样全读**（parser 的 _parse_csv 限 500 行是为聊天附件
   设计的）；工作流节点语义是"读文件内容"，原样更有用，总量仍由 max_bytes 限制。

运行：.venv/bin/python -m sidecar.workflow.test_c4_file_read_parse
"""
import asyncio
import io
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

PASS, FAIL = 0, 0
FAILURES = []


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"PASS  {name}")
    else:
        FAIL += 1
        FAILURES.append(name)
        print(f"FAIL  {name}  {detail}")


def _n(nid, ntype, **kw):
    return {"id": nid, "type": ntype, **kw}


def _defn(nodes):
    return {"nodes": nodes, "edges": [{"from": nodes[i]["id"], "to": nodes[i + 1]["id"]}
                                      for i in range(len(nodes) - 1)]}


class _DummyConn:
    """file_read 节点不碰模型，故连接器只需可构造。"""
    async def chat(self, *a, **kw):
        raise AssertionError("file_read 节点不应调用模型")


async def _read_node(node_kw, tmp):
    from sidecar.workflow.engine import WorkflowEngine
    d = _defn([_n("s", "start"), _n("fr", "file_read", **node_kw), _n("e", "end")])
    eng = WorkflowEngine("run-c4", d, _DummyConn(), str(tmp))
    return await eng._run_file_read(d["nodes"][1])


def _mk_pdf_with_text(marker: str) -> bytes:
    """造一个**含可提取文本**的真实 PDF —— ⛔ 零第三方依赖（手写最小 PDF 结构）。

    为什么要手写：项目 venv **没装 reportlab**，依赖它的版本会让 PDF 用例长期 SKIP，
    而 PDF 正是 C4 需求点名的核心症状（"工作流不可读 pdf"）——留 SKIP 等于核心路径无人守护。
    空白页也测不出来（pypdf 对无文本页返回空串，与"解析失败"无法区分），必须含真文本。
    已验证 pypdf 能从此结构提取出 marker。
    """
    content = f"BT /F1 24 Tf 72 720 Td ({marker}) Tj ET".encode("ascii")
    pdf = b"%PDF-1.4\n"
    offsets = []

    def add(num: int, body: bytes) -> None:
        nonlocal pdf
        offsets.append(len(pdf))
        pdf += f"{num} 0 obj\n".encode() + body + b"\nendobj\n"

    add(1, b"<< /Type /Catalog /Pages 2 0 R >>")
    add(2, b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
    add(3, b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
           b"/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>")
    add(4, b"<< /Length " + str(len(content)).encode() + b" >>\nstream\n" + content + b"\nendstream")
    add(5, b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    xref_pos = len(pdf)
    pdf += b"xref\n0 6\n0000000000 65535 f \n"
    for o in offsets:
        pdf += f"{o:010d} 00000 n \n".encode()
    pdf += (b"trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n"
            + str(xref_pos).encode() + b"\n%%EOF")
    return pdf


def main():
    tmp = Path(tempfile.mkdtemp(prefix="c4_"))
    from sidecar.workflow.engine import WorkflowEngine as W

    # ── T1 格式清单从 parser 推导（不双源） ──
    from sidecar.attachments import parser as P
    expect = frozenset(P.SUPPORTED_EXTS - P.TEXT_EXTS - P.IMAGE_EXTS)
    check("T1a _DOC_PARSE_EXTS == parser 推导值（无双源漂移）",
          W._DOC_PARSE_EXTS == expect, f"{sorted(W._DOC_PARSE_EXTS)} vs {sorted(expect)}")
    check("T1b 含 .pdf/.docx/.doc/.xlsx/.xlsm/.pptx",
          all(e in W._DOC_PARSE_EXTS for e in
              (".pdf", ".docx", ".doc", ".xlsx", ".xlsm", ".pptx")))
    check("T1c .csv/.txt/.md 走纯文本路径（不在解析清单）",
          not (W._DOC_PARSE_EXTS & {".csv", ".txt", ".md"}))
    check("T1d 图片不在解析清单（走视觉链路）", not (W._DOC_PARSE_EXTS & P.IMAGE_EXTS))
    check("T1e 源文件上限独立存在且 >0",
          W._FILE_READ_MAX_SOURCE_BYTES > 0 and W._FILE_READ_MAX_SOURCE_BYTES >= 1024 * 1024,
          str(W._FILE_READ_MAX_SOURCE_BYTES))

    # ── T2 纯文本行为不变（回归保护）──
    (tmp / "a.txt").write_text("纯文本内容甲", encoding="utf-8")
    r = asyncio.run(_read_node({"path": str(tmp / "a.txt")}, tmp))
    check("T2a 纯文本仍可读", r.ok and "纯文本内容甲" in str(r.output), r.error or "")
    check("T2b 默认分隔头仍带文件名", "=== a.txt ===" in str(r.output), str(r.output))

    # 编码回退行为不变（gbk 文件此前靠 errors='replace'，不应因改造变成报错）
    (tmp / "g.txt").write_bytes("中文GBK内容".encode("gbk"))
    r = asyncio.run(_read_node({"path": str(tmp / "g.txt")}, tmp))
    check("T2c 非 utf-8 纯文本不报错（沿用 replace 容错）", r.ok, r.error or "")

    # separator 模板仍可用
    r = asyncio.run(_read_node({"path": str(tmp / "a.txt"), "separator": "文件：{{filename}}"}, tmp))
    check("T2d separator 模板仍渲染 filename",
          r.ok and "文件：a.txt" in str(r.output), str(r.output))

    # ── T3 二进制文档格式：读出文本而非乱码 ──
    import docx as _docx
    d = _docx.Document()
    d.add_paragraph("DOCX标记内容乙")
    t = d.add_table(rows=1, cols=2)
    t.cell(0, 0).text = "列甲"
    t.cell(0, 1).text = "列乙"
    b = io.BytesIO(); d.save(b)
    (tmp / "b.docx").write_bytes(b.getvalue())
    r = asyncio.run(_read_node({"path": str(tmp / "b.docx")}, tmp))
    check("T3a docx 解析成功", r.ok, r.error or "")
    check("T3b docx 正文可读（非乱码）", "DOCX标记内容乙" in str(r.output), str(r.output)[:120])
    check("T3c docx 表格单元格可读", "列甲" in str(r.output) and "列乙" in str(r.output),
          str(r.output)[:200])

    import openpyxl
    wb = openpyxl.Workbook(); wb.active["A1"] = "XLSX标记内容丙"
    b2 = io.BytesIO(); wb.save(b2)
    (tmp / "c.xlsx").write_bytes(b2.getvalue())
    r = asyncio.run(_read_node({"path": str(tmp / "c.xlsx")}, tmp))
    check("T3d xlsx 解析成功且内容可读",
          r.ok and "XLSX标记内容丙" in str(r.output), r.error or str(r.output)[:120])

    from pptx import Presentation
    prs = Presentation(); sl = prs.slides.add_slide(prs.slide_layouts[1])
    sl.shapes.title.text = "PPTX标记标题丁"
    sl.placeholders[1].text = "PPTX标记正文丁"
    b3 = io.BytesIO(); prs.save(b3)
    (tmp / "d.pptx").write_bytes(b3.getvalue())
    r = asyncio.run(_read_node({"path": str(tmp / "d.pptx")}, tmp))
    check("T3e pptx 解析成功且标题正文可读",
          r.ok and "PPTX标记标题丁" in str(r.output) and "PPTX标记正文丁" in str(r.output),
          r.error or str(r.output)[:120])

    # PDF：reportlab 可选（项目未必装）→ 无则优雅 SKIP，不假称验证过
    try:
        pdf_bytes = _mk_pdf_with_text("PDFMARKERWU")
        (tmp / "e.pdf").write_bytes(pdf_bytes)
        r = asyncio.run(_read_node({"path": str(tmp / "e.pdf")}, tmp))
        check("T3f pdf 解析成功（含文本的真实 PDF）", r.ok, r.error or "")
        check("T3g pdf 文本可读", "PDFMARKERWU" in str(r.output), str(r.output)[:160])
        # ⛔ 关键：改造前这里必然是乱码/无内容
        check("T3h pdf 输出不含大量替换字符（证明不是 decode 乱码）",
              "\ufffd" not in str(r.output)[:400], "出现 U+FFFD 乱码")
    except ImportError:
        print("SKIP T3f~T3h（reportlab 未安装，无法造含文本 PDF；不以空白页冒充验证）")

    # .doc（macOS textutil；非 macOS 优雅 SKIP）
    import shutil as _sh
    if sys.platform == "darwin" and _sh.which("textutil"):
        html = ('<html><head><meta charset="utf-8"></head><body>'
                '<p>DOC标记内容己</p></body></html>')
        out = __import__("subprocess").run(
            ["textutil", "-stdin", "-format", "html", "-convert", "doc", "-stdout"],
            input=html.encode("utf-8"), capture_output=True, timeout=30)
        if out.stdout:
            (tmp / "f.doc").write_bytes(out.stdout)
            r = asyncio.run(_read_node({"path": str(tmp / "f.doc")}, tmp))
            check("T3i .doc 经 textutil 可读（C3 能力被工作流复用）",
                  r.ok and "DOC标记内容己" in str(r.output), r.error or str(r.output)[:120])
        else:
            print("SKIP T3i（造 .doc 失败）")
    else:
        print("SKIP T3i（非 macOS 或无 textutil）")

    # ── T4 批量 + 混合格式（文件夹场景）──
    mix = tmp / "mixdir"
    mix.mkdir(exist_ok=True)
    (mix / "1.txt").write_text("文本一", encoding="utf-8")
    (mix / "2.docx").write_bytes(b.getvalue())
    r = asyncio.run(_read_node({"path": str(mix)}, tmp))
    check("T4a 文件夹批量读取成功", r.ok, r.error or "")
    check("T4b 文本与 docx 内容都在（混合格式各走各路径）",
          "文本一" in str(r.output) and "DOCX标记内容乙" in str(r.output), str(r.output)[:200])
    # extensions 过滤仍生效
    r = asyncio.run(_read_node({"path": str(mix), "extensions": "txt"}, tmp))
    check("T4c extensions 过滤仍生效（只读 txt）",
          r.ok and "文本一" in str(r.output) and "DOCX标记内容乙" not in str(r.output),
          str(r.output)[:160])

    # ── T5 失败语义：如实报错，不塞乱码/空串 ──
    (tmp / "broken.pdf").write_bytes(b"this is not a pdf at all")
    r = asyncio.run(_read_node({"path": str(tmp / "broken.pdf")}, tmp))
    check("T5a 损坏 pdf → ok=False 如实报错", r.ok is False, f"ok={r.ok}")
    check("T5b 错误文案含文件名与原因线索",
          r.error is not None and "broken.pdf" in r.error and "无法解析" in r.error,
          str(r.error))
    check("T5c 不把乱码当成功输出",
          r.output is None or "this is not a pdf" not in str(r.output), str(r.output))

    # 超大源文件：必须在读取前拒绝（不能整读爆内存）
    big = tmp / "big.pdf"
    with open(big, "wb") as fh:
        fh.seek(W._FILE_READ_MAX_SOURCE_BYTES + 1024)   # 稀疏文件，不真占磁盘
        fh.write(b"\0")
    r = asyncio.run(_read_node({"path": str(big)}, tmp))
    check("T5d 超源上限 → 拒绝并说明为何不能截断",
          r.ok is False and r.error is not None and "过大" in r.error, str(r.error))

    # 路径不存在 / 未配置 path（既有语义不得回归）
    r = asyncio.run(_read_node({"path": str(tmp / "nope.txt")}, tmp))
    check("T5e 路径不存在仍报「路径不存在」",
          r.ok is False and "路径不存在" in str(r.error), str(r.error))
    r = asyncio.run(_read_node({"path": "  "}, tmp))
    check("T5f 未配置 path 仍报错", r.ok is False and "path" in str(r.error), str(r.error))

    # ── T6 输出文本截断（max_bytes 语义 = 文本上限）──
    (tmp / "long.txt").write_text("字" * 5000, encoding="utf-8")
    r = asyncio.run(_read_node({"path": str(tmp / "long.txt"), "max_bytes": 100}, tmp))
    check("T6a 纯文本按 max_bytes 截断", r.ok and len(str(r.output)) < 5000, len(str(r.output)))
    check("T6b 截断有明确标注（不静默丢内容）", "已截断" in str(r.output), str(r.output)[-60:])

    # T6c/T6d ⛔ 抓「两上限分离」的功能测试（变异测试证明必须有）：
    #   max_bytes 只是**输出文本**上限，绝不能用来截断**源文件字节**——docx/pdf/xlsx
    #   都是 ZIP/容器结构，截断字节后结构破坏 → 解析必然失败。
    #   正常实现：整读 docx → 解析全文 → 文本截到 10 字 + 标注 → ok=True。
    #   若源被字节截断（read_bytes()[:max_bytes]）：10 字节片段打不开 → ok=False。
    r = asyncio.run(_read_node({"path": str(tmp / "b.docx"), "max_bytes": 10}, tmp))
    check("T6c 极小 max_bytes 下 docx 仍解析成功（源文件未被字节截断）",
          r.ok is True, f"ok={r.ok} err={r.error}")
    check("T6d 输出按 max_bytes 截断且有标注", "已截断" in str(r.output), str(r.output)[-60:])

    # ── T7 不阻塞事件循环（run_in_executor 的硬约束）──
    # ⛔⛔ 原版是**无效断言**（变异测试暴露）：用 gather(heartbeat, read) 后查总 tick 数，
    #    但 gather 等两者都结束 —— 阻塞的解析跑完后心跳仍会补满 30 次 → 恒成立；
    #    把解析从 executor 里挪出来（真阻塞事件循环）测试照样全绿。
    # ✅ 正解：心跳只跑到**解析结束为止**，数解析期间的 tick。
    #    解析走 executor → 主循环空闲 → tick 持续增长；sync 阻塞 → 主循环被占死 → tick 停在个位数。
    #    用「多文件 × 大文档」放大解析耗时，使差异不依赖机器快慢。
    async def _blocking_probe():
        hbdir = tmp / "hbdir"
        hbdir.mkdir(exist_ok=True)
        for k in range(4):
            dd = _docx.Document()
            for i in range(900):
                dd.add_paragraph(f"心跳探测段落 {k}-{i}：填充内容以放大解析耗时，"
                                 f"使阻塞与非阻塞的差异远大于心跳间隔")
            bb = io.BytesIO(); dd.save(bb)
            (hbdir / f"hb{k}.docx").write_bytes(bb.getvalue())

        ticks: list[float] = []
        stop = asyncio.Event()

        async def heartbeat():
            while not stop.is_set():
                ticks.append(asyncio.get_running_loop().time())
                await asyncio.sleep(0.002)

        hb = asyncio.create_task(heartbeat())
        t0 = asyncio.get_running_loop().time()
        res = await _read_node({"path": str(hbdir)}, tmp)     # 等解析真正结束
        elapsed = asyncio.get_running_loop().time() - t0
        stop.set()
        await hb
        return res, len(ticks), elapsed

    r7, tick_count, elapsed7 = asyncio.run(_blocking_probe())
    check("T7a 大文档批量解析成功（探测前置）", r7.ok, r7.error or "")
    check("T7b 解析期间事件循环持续推进（tick 充足 → 解析未阻塞主协程）",
          tick_count >= 10, f"ticks={tick_count} elapsed={elapsed7:.3f}s")
    check("T7c 解析确有可观耗时（否则 T7b 无区分力）", elapsed7 >= 0.02,
          f"elapsed={elapsed7:.3f}s")

    # ── T8 源码断言（精确锚点，⛔ 不用宽松计数）──
    # ⛔ 原版 `seg.count("run_in_executor") >= 2` 太松：本函数有 3 处 executor，
    #    删掉解析那一处仍满足 >=2 → 变异1 全绿。改为**正则锚定"解析调用在 executor 内"**。
    import re as _re
    src = Path(__file__).resolve().parents[1] / "workflow" / "engine.py"
    s = src.read_text(encoding="utf-8")
    seg = s.split("async def _run_file_read")[1].split("\n    async def ")[0]
    check("T8a 解析调用在 run_in_executor 内（删 executor 即失败）",
          _re.search(r"run_in_executor\(\s*\n?\s*None,\s*\n?\s*parse_attachment", seg) is not None,
          "解析未走 executor")
    check("T8b 二进制分支整读 read_bytes（无 [:max_bytes] 字节截断）",
          "run_in_executor(None, f.read_bytes)" in seg
          and _re.search(r"f\.read_bytes\)\s*\[", seg) is None)
    check("T8c 解析失败返回 ok=False（不塞乱码/空串）", "无法解析" in seg)
    check("T8d 纯文本路径保留 [:max_bytes] 截断（行为不变）",
          "read_bytes()[:max_bytes]" in seg)
    check("T8e 格式清单从 parser 推导（不硬编码，防双源漂移）",
          "_P_SUPPORTED" in s and "_P_TEXT" in s and "_P_IMAGE" in s)

    print(f"\n===== C4 专项: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        for f in FAILURES:
            print("  ✗", f)
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
