# VetarAI - Local-first multi-agent orchestration application
# Copyright (C) 2026 zero11924065-dev
# GPL-3.0-or-later（见仓库 LICENSE）
"""A11（0.4.22）专项：知识仓库「导入文件」——把用户选中的外部文件复制进知识目录并索引。

═══ 治的是什么 ═══
原先用户要把手里的 pdf/docx 拖进知识目录再点「重建索引」才能被检索；A11 加
warehouse.import_files + POST /api/knowledge/import-files + 面板「导入文件」按钮，
让用户在知识分组行直接选本机文件一步导入。

═══ 关键约束（勿凭直觉改）═══
1. ⛔ **拉模式铁律**：只复制+索引供 search_knowledge 检索，绝不自动注入上下文。
2. ⛔ **非递归**：sources 是 chooseInputFile 返回的文件路径列表（用户主动选），
   不遍历目录；传入目录/不存在路径 → 计入 failed，不递归进去。
3. ⛔ **不覆盖用户已有文件**：知识目录已有同名文件 → 加 _1/_2 序号，原文件不动。
4. ⛔ **不留垃圾**：复制成功但解析/索引失败（不支持类型/损坏/超大）→ 删除已复制文件，
   计入 skipped，不报错中断整批。
5. ⛔ **数据安全**：导入条目 source='file'，delete_entry 删条目时**不 unlink** 知识目录里
   的副本（副本是导入进来的资产，删索引条目不等于删文件——与 A10 一致）。
6. ⛔ **端点走 executor**：import_files 含文件 IO + 解析 + embedding，CPU/IO 密集，
   async 端点必须 run_in_executor，不能直接 await 阻塞事件循环。

运行：.venv/bin/python -m sidecar.knowledge.test_a11_import_files
（⛔ 勿裸跑：走 scripts/run_backend_tests.py 隔离 runner）
"""
import io
import re
import sqlite3
import sys
import tempfile
import uuid
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


def _mk_docx(marker: str) -> bytes:
    import docx
    d = docx.Document()
    d.add_paragraph(f"标记内容 {marker} 第一段")
    d.add_paragraph("第二段：关于知识仓库导入文档的说明。")
    buf = io.BytesIO(); d.save(buf)
    return buf.getvalue()


def main():
    import sidecar.knowledge.warehouse as wh
    import sidecar.storage.store as store

    # 隔离：数据根 + 索引库 + 项目库全部指向临时目录（同 A10）
    tmp = Path(tempfile.mkdtemp(prefix="a11_"))
    wh._DATA_ROOT_OVERRIDE = tmp
    wh._INDEX_DB_PATH = tmp / "index.db"
    proj_root = tmp / "projects"; proj_root.mkdir(parents=True, exist_ok=True)
    store.PROJECTS_ROOT = proj_root
    store._GDB = proj_root / "_global.db"
    work_dir = tmp / "proj_work"; work_dir.mkdir(parents=True, exist_ok=True)
    pid = store.create_project("A11测试项目", work_dir)
    gdir = wh.global_knowledge_dir()
    assert gdir is not None and gdir.is_dir(), f"全局知识库目录未就绪：{gdir}"

    # 用户「本机文件」放在一个独立源目录（模拟桌面/下载等，不在知识目录里）
    src_dir = tmp / "user_files"; src_dir.mkdir(parents=True, exist_ok=True)

    # ── T1 正常导入：复制进知识目录 + 索引 + source='file' ──
    docx_src = src_dir / "报告.docx"
    docx_src.write_bytes(_mk_docx("甲"))
    txt_src = src_dir / "笔记.txt"
    txt_src.write_text("这是一段纯文本笔记内容，用于检索测试。", encoding="utf-8")
    r = wh.import_files("global", None, [str(docx_src), str(txt_src)])
    check("T1a imported==2", r["imported"] == 2, r)
    check("T1b failed==0 skipped==0", r["failed"] == 0 and r["skipped"] == 0, r)
    check("T1c 副本已复制进全局知识目录", (gdir / "报告.docx").is_file() and (gdir / "笔记.txt").is_file())
    check("T1d 源文件仍在原位（复制非移动）", docx_src.is_file() and txt_src.is_file())
    ents = wh.list_entries(scope="global")
    titles = {e["title"] for e in ents}
    check("T1e 两条已入索引（标题=文件名 stem）", {"报告", "笔记"} <= titles, titles)
    file_ents = [e for e in ents if e["source"] == wh.SOURCE_IMPORTED_FILE]
    check("T1f source=='file'（数据安全标记）", len(file_ents) == 2, [e["source"] for e in ents])

    # ── T2 非递归：目录路径 / 不存在路径 → failed，不递归进去 ──
    r2 = wh.import_files("global", None, [str(src_dir), str(src_dir / "不存在.pdf")])
    check("T2a 目录+不存在 → failed==2 imported==0", r2["failed"] == 2 and r2["imported"] == 0, r2)
    check("T2b 未把目录里的文件递归导入（imported 仍 0）", r2["imported"] == 0, r2)

    # ── T3 不支持/解析失败 → skipped + 删副本不留垃圾 ──
    bad_src = src_dir / "乱码.bin"
    bad_src.write_bytes(bytes(range(256)) * 4)  # 不支持的扩展名 + 二进制垃圾
    before = {p.name for p in gdir.iterdir()}
    r3 = wh.import_files("global", None, [str(bad_src)])
    check("T3a 不支持文件 → skipped==1 imported==0", r3["skipped"] == 1 and r3["imported"] == 0, r3)
    after = {p.name for p in gdir.iterdir()}
    check("T3b 复制的垃圾文件已删除（知识目录无残留）", after == before, sorted(after - before))
    check("T3c 源文件未被删（只删副本）", bad_src.is_file())

    # ── T4 同名冲突：⛔ 默认 ask 不擅自处置，由用户选 rename/overwrite/skip ──
    #    （用户 2026-09-12 拍板"改成弹窗问我"；后端不替用户决定，前端弹窗后带策略重调）
    docx_src2 = src_dir / "另一份" / "报告.docx"
    docx_src2.parent.mkdir(parents=True, exist_ok=True)
    docx_src2.write_bytes(_mk_docx("乙"))

    # T4-ask：默认策略——不导入、不覆盖、不改名，只把冲突报回来
    before4 = {p.name for p in gdir.iterdir()}
    r4 = wh.import_files("global", None, [str(docx_src2)])          # on_conflict 默认 "ask"
    check("T4a 默认 ask：冲突文件列入 conflicts", r4["conflicts"] == ["报告.docx"], r4["conflicts"])
    check("T4b 默认 ask：不导入也不覆盖（imported==0，知识目录无新增）",
          r4["imported"] == 0 and {p.name for p in gdir.iterdir()} == before4, before4)
    check("T4c 默认 ask：原 报告.docx 内容未被改（仍是甲）",
          (gdir / "报告.docx").read_bytes() == docx_src.read_bytes())
    check("T4d 默认 ask：用户原始文件未被改动", docx_src2.read_bytes() == _mk_docx("乙"))

    # T4-rename：改名并存（旧文件保留，新文件带 _1）
    r4r = wh.import_files("global", None, [str(docx_src2)], "rename")
    check("T4e rename：imported==1 且生成 报告_1.docx",
          r4r["imported"] == 1 and (gdir / "报告_1.docx").is_file(), r4r)
    check("T4f rename：原 报告.docx 仍是甲（未覆盖）",
          (gdir / "报告.docx").read_bytes() == docx_src.read_bytes())

    # T4-skip：跳过（旧文件保留，不新增）
    before_skip = {p.name for p in gdir.iterdir()}
    r4s = wh.import_files("global", None, [str(docx_src2)], "skip")
    check("T4g skip：skipped==1 imported==0 且目录无新增",
          r4s["skipped"] == 1 and r4s["imported"] == 0
          and {p.name for p in gdir.iterdir()} == before_skip, r4s)

    # T4-overwrite：覆盖 + ⛔ 必须清掉旧 FTS（否则同一文件命中两份正文，其中一份是覆盖前的旧内容）
    note_src = src_dir / "覆盖测试.txt"
    note_src.write_text("旧版正文：苹果香蕉樱桃。", encoding="utf-8")
    r4o1 = wh.import_files("global", None, [str(note_src)])
    check("T4h overwrite 前置：首次导入成功", r4o1["imported"] == 1, r4o1)
    note_src.write_text("新版正文：榴莲山竹菠萝蜜。", encoding="utf-8")
    r4o2 = wh.import_files("global", None, [str(note_src)], "overwrite")
    check("T4i overwrite：imported==1", r4o2["imported"] == 1, r4o2)
    check("T4j overwrite：磁盘内容已是新版",
          (gdir / "覆盖测试.txt").read_text(encoding="utf-8").startswith("新版正文"))
    # ⛔ 关键：旧正文的分词不得残留（_purge_file_index 的回归点）
    _oid = str(uuid.uuid5(uuid.NAMESPACE_URL,
                          f"knowledge-file://{(gdir / '覆盖测试.txt').resolve()}"))
    conn4 = sqlite3.connect(str(wh._index_db_path()))
    try:
        old_hits = conn4.execute(
            "SELECT COUNT(*) FROM knowledge_fts WHERE entry_id=? AND knowledge_fts MATCH ?",
            (_oid, wh._tokenize("苹果"))).fetchone()[0]
        new_hits = conn4.execute(
            "SELECT COUNT(*) FROM knowledge_fts WHERE entry_id=? AND knowledge_fts MATCH ?",
            (_oid, wh._tokenize("榴莲"))).fetchone()[0]
        dup = conn4.execute(
            "SELECT COUNT(*) FROM knowledge_entries WHERE id=?", (_oid,)).fetchone()[0]
    finally:
        conn4.close()
    check("T4k ⛔ overwrite 后旧正文不再可检索（FTS 已清，否则命中覆盖前的旧内容）",
          old_hits == 0, f"旧词命中 {old_hits} 行")
    check("T4l overwrite 后新正文可检索", new_hits >= 1, f"新词命中 {new_hits} 行")
    check("T4m overwrite 不产生重复索引行（entries 表仍恰好 1 行）", dup == 1, dup)

    # T4n 非法策略：不得静默当成功，要如实计 failed（端点侧另有 400 校验）
    r4bad = wh.import_files("global", None, [str(docx_src2)], "nonsense")
    check("T4n 非法 on_conflict → failed==1 imported==0",
          r4bad["failed"] == 1 and r4bad["imported"] == 0, r4bad)

    # ── T5 无效作用域 → 全 failed，不崩 ──
    r5 = wh.import_files("bogus", None, [str(txt_src)])
    check("T5a 无效作用域 → failed==1 imported==0", r5["failed"] == 1 and r5["imported"] == 0, r5)
    check("T5b 未污染知识目录", not (gdir / "笔记_1.txt").exists())

    # ── T6 项目作用域导入到项目知识目录 ──
    pdir = wh.project_knowledge_dir(pid)
    assert pdir is not None and pdir.is_dir()
    p_src = src_dir / "项目文档.txt"
    p_src.write_text("项目级知识内容。", encoding="utf-8")
    r6 = wh.import_files("project", pid, [str(p_src)])
    check("T6a 项目作用域 imported==1", r6["imported"] == 1, r6)
    check("T6b 副本进项目知识目录（非全局）", (pdir / "项目文档.txt").is_file())
    check("T6c 未误入全局目录", not (gdir / "项目文档.txt").exists())

    # ── T7 拉模式铁律：导入只索引，不自动注入 ──
    #    import_files 返回结构里不应有任何"注入/inject/上下文"副作用字段；
    #    且 FTS 里能检索到（证明只进了检索库）。
    conn = sqlite3.connect(str(wh._index_db_path()))
    try:
        fts_hit = conn.execute(
            "SELECT COUNT(*) FROM knowledge_fts WHERE knowledge_fts MATCH ?",
            (wh._tokenize("笔记"),)).fetchone()[0]
    finally:
        conn.close()
    check("T7a 导入内容可被 FTS 检索（只进检索库）", fts_hit >= 1, fts_hit)
    check("T7b 返回值无注入类副作用字段（conflicts 是 A11 同名上报，非注入）",
          set(r.keys()) == {"imported", "failed", "skipped", "conflicts", "details"},
          sorted(r.keys()))

    # ── T8 数据安全：delete_entry 删导入条目不 unlink 知识目录副本 ──
    note_ent = next(e for e in wh.list_entries(scope="global") if e["title"] == "笔记")
    note_copy = Path(note_ent["file_path"])
    check("T8a 副本文件确实存在", note_copy.is_file())
    wh.delete_entry(note_ent["id"])
    check("T8b 删条目后副本文件仍在（source='file' 不 unlink）", note_copy.is_file())

    # ── T9 端点走 executor（源码断言，防注释污染：锚定实际调用形态）──
    app_src = (Path(__file__).resolve().parents[1] / "app.py").read_text(encoding="utf-8")
    eseg = app_src.split("async def api_knowledge_import_files")[1].split("\n@app.")[0]
    check("T9 import-files 端点用 run_in_executor 实际调用 import_files（删 executor 即失败）",
          re.search(r"run_in_executor\(\s*None\s*,\s*_wh\.import_files", eseg) is not None,
          eseg[:240])

    print(f"\n===== A11 专项: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        for f in FAILURES:
            print("  ✗", f)
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
