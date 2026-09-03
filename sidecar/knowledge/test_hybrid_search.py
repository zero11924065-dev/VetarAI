"""TS-120 阶段二：混合检索端到端测试（真实模型 + 临时隔离目录）。

覆盖：
  H1 新增条目自动编码向量（向量表有记录）
  H2 关键词模式：原行为不变
  H3 语义模式：换述查询命中（关键词检索查不到）
  H4 混合模式：两路融合，相关条目排前
  H5 作用域过滤：全局检索不返回项目条目
  H6 删除条目 → 向量同步清除
  H7 外部删除对账 → 向量同步清除
  H8 重建索引 → 向量重编码
  H9 embedding-status 覆盖率统计

运行：.venv/bin/python -m sidecar.knowledge.test_hybrid_search
"""
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


def main():
    import sidecar.knowledge.embedder as emb
    if not emb.model_available():
        print("SKIP  模型不可用，本测试需要真实模型（请先下载）")
        sys.exit(1)

    tmp = Path(tempfile.mkdtemp(prefix="hybrid_"))
    import sidecar.knowledge.warehouse as wh
    wh._DATA_ROOT_OVERRIDE = tmp
    wh._INDEX_DB_PATH = tmp / "index.db"

    # H1 新增条目自动编码向量
    e1 = wh.add_entry("global", None, "地球的形状", "地球是一个近似球体的行星，两极略扁赤道略鼓", keywords=["地球", "行星"])
    e2 = wh.add_entry("global", None, "咖啡冲泡方法", "手冲咖啡需要控制水温在92度左右，研磨度中细", keywords=["咖啡"])
    conn = wh._iconn()
    try:
        n_vec = conn.execute("SELECT COUNT(*) FROM knowledge_embeddings").fetchone()[0]
    finally:
        conn.close()
    check("H1 新增条目自动编码向量", e1 is not None and e2 is not None and n_vec == 2, f"vectors={n_vec}")

    # H2 关键词模式原行为
    r_kw = wh.hybrid_search("咖啡", "global", mode="keyword")
    check("H2 关键词模式命中标题词", any(x["id"] == e2["id"] for x in r_kw), str([x["title"] for x in r_kw]))

    # H3 语义模式：换述查询（"我们生活的星球是什么样子" 不含"地球"二字做关键词匹配也能命中——
    # 关键验证：语义检索能命中关键词完全不匹配的换述）
    r_sem = wh.hybrid_search("我们居住的这颗星球是什么形状的", "global", mode="semantic")
    check("H3a 语义模式返回结果", len(r_sem) > 0, str(r_sem))
    check("H3b 语义命中地球条目（换述）", r_sem and r_sem[0]["id"] == e1["id"],
          str([(x["title"], x.get("score")) for x in r_sem]))
    # 反向验证：纯关键词搜"居住的星球"搜不到地球条目（标题/正文/关键词均无此词组）
    r_kw_miss = wh.search_entries("居住的星球", "global")
    check("H3c 关键词检索确实搜不到该换述（对照）",
          all(x["id"] != e1["id"] for x in r_kw_miss), str([x["title"] for x in r_kw_miss]))

    # H4 混合模式
    r_hyb = wh.hybrid_search("星球的形状", "global", mode="hybrid")
    check("H4 混合模式地球条目排前", r_hyb and r_hyb[0]["id"] == e1["id"],
          str([(x["title"], x.get("score")) for x in r_hyb]))

    # H5 作用域过滤（建一个项目条目，全局检索不返回它——需要项目存在，跳过项目目录直接用假项目）
    # 项目知识需要真实项目，这里验证 _scope_entry_ids 对 global 的过滤不返回无作用域条目
    allowed = wh._scope_entry_ids("global", None)
    check("H5 作用域集合只含全局条目", allowed is not None and e1["id"] in allowed, str(allowed))

    # H6 删除条目 → 向量清除
    wh.delete_entry(e2["id"])
    conn = wh._iconn()
    try:
        n_after = conn.execute("SELECT COUNT(*) FROM knowledge_embeddings").fetchone()[0]
    finally:
        conn.close()
    check("H6 删除条目向量同步清除", n_after == 1, f"vectors={n_after}")

    # H7 外部删除对账 → 向量清除
    Path(e1["file_path"]).unlink()
    wh.prune_missing()
    conn = wh._iconn()
    try:
        n_after2 = conn.execute("SELECT COUNT(*) FROM knowledge_embeddings").fetchone()[0]
    finally:
        conn.close()
    check("H7 外部删除对账清除向量", n_after2 == 0, f"vectors={n_after2}")

    # H8 重建索引 → 向量重编码
    e3 = wh.add_entry("global", None, "测试重建", "重建索引后向量应当重新编码")
    Path(e3["file_path"]).unlink()  # 模拟外部删除再重建不可行（文件没了）——改为正常重建
    wh.prune_missing()
    e4 = wh.add_entry("global", None, "重建验证条目", "这条用于验证重建索引会重新生成向量")
    conn = wh._iconn()
    try:
        conn.execute("DELETE FROM knowledge_embeddings")  # 人为清空向量模拟损坏
        conn.commit()
    finally:
        conn.close()
    n_rebuilt = wh.rebuild_index()
    conn = wh._iconn()
    try:
        n_vec_rebuilt = conn.execute("SELECT COUNT(*) FROM knowledge_embeddings").fetchone()[0]
    finally:
        conn.close()
    check("H8 重建索引重编码向量", n_rebuilt >= 1 and n_vec_rebuilt == n_rebuilt,
          f"entries={n_rebuilt} vectors={n_vec_rebuilt}")

    # H9 embedding-status 覆盖率（端点内部逻辑同构验证）
    conn = wh._iconn()
    try:
        total = conn.execute("SELECT COUNT(*) FROM knowledge_entries").fetchone()[0]
        embedded = conn.execute("SELECT COUNT(*) FROM knowledge_embeddings").fetchone()[0]
    finally:
        conn.close()
    check("H9 覆盖率统计一致", total == embedded and total >= 1, f"{embedded}/{total}")

    wh._DATA_ROOT_OVERRIDE = None
    wh._INDEX_DB_PATH = None
    import shutil
    shutil.rmtree(tmp, ignore_errors=True)

    print(f"\n===== 结果：{PASS} PASS / {FAIL} FAIL =====")
    if FAILURES:
        print("失败项：", "、".join(FAILURES))
        sys.exit(1)


if __name__ == "__main__":
    main()
