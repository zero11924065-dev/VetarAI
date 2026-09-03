"""TS-120 阶段二：嵌入层（embedder）单元测试。

覆盖：
  EB1 模型可用性判断
  EB2 单条编码：dense 1024 维 + 已归一化 + 稀疏权重非空
  EB3 批量编码对齐（含空文本占位）
  EB4 查询指令前缀不影响维度
  EB5 语义排序：相关句 > 无关句（混合文本）
  EB6 向量序列化往返（BLOB）
  EB7 稀疏点积：相同词有权重、无交集为 0
  EB8 模型缺失优雅降级（EmbedUnavailableError）

运行：.venv/bin/python -m sidecar.knowledge.test_embedder
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

    # EB1 模型可用性（真实模型目录，此前已下载）
    avail = emb.model_available()
    check("EB1 真实模型目录可用", avail, str(emb.default_model_dir()))
    if not avail:
        print("模型不可用，跳过依赖模型的测试")
    else:
        # EB2 单条编码
        r = emb.encode_one("地球是圆的")
        check("EB2a dense 维度 1024", len(r["dense"]) == 1024, str(len(r["dense"])))
        norm = sum(x * x for x in r["dense"]) ** 0.5
        check("EB2b dense 已归一化", abs(norm - 1.0) < 1e-3, f"norm={norm:.4f}")
        check("EB2c 稀疏权重非空", len(r["sparse"]) > 0, str(r["sparse"]))

        # EB3 批量编码 + 空文本占位
        rs = emb.encode(["你好", "", "世界"])
        check("EB3a 批量 3 条对齐", len(rs) == 3, str(len(rs)))
        check("EB3b 空文本 dense 全零", all(abs(x) < 1e-9 for x in rs[1]["dense"]))
        check("EB3c 空文本 sparse 为空", rs[1]["sparse"] == {})

        # EB4 查询指令前缀不影响维度
        rq = emb.encode_one("查询内容", with_query_instruction=True)
        check("EB4 查询前缀编码维度正常", len(rq["dense"]) == 1024, str(len(rq["dense"])))

        # EB5 语义排序（稠密余弦）
        anchor = emb.encode_one("Python 是一种编程语言")
        related = emb.encode_one("Python 是流行的编程语言")
        unrelated = emb.encode_one("今天天气很好")
        s_rel = emb.cosine(anchor["dense"], related["dense"])
        s_unrel = emb.cosine(anchor["dense"], unrelated["dense"])
        print(f"  相似度：相关 {s_rel:.4f} / 无关 {s_unrel:.4f}")
        check("EB5 语义排序正确（相关 > 无关）", s_rel > s_unrel, f"{s_rel:.4f} vs {s_unrel:.4f}")

        # EB6 序列化往返
        blob = emb.dense_to_blob(anchor["dense"])
        back = emb.blob_to_dense(blob)
        diff = max(abs(a - b) for a, b in zip(anchor["dense"], back))
        check("EB6 BLOB 往返误差 < 1e-4（float32）", diff < 1e-4, f"max diff={diff:.2e}")

        # EB7 稀疏点积
        d_same = emb.sparse_dot(anchor["sparse"], anchor["sparse"])
        d_none = emb.sparse_dot({"不存在的词xyz": 1.0}, anchor["sparse"])
        check("EB7a 自点积 > 0", d_same > 0, f"{d_same:.4f}")
        check("EB7b 无交集点积 = 0", d_none == 0.0, f"{d_none}")

    # EB8 模型缺失降级（指向空临时目录）
    tmp = Path(tempfile.mkdtemp(prefix="emb_missing_"))
    try:
        emb.encode(["测试"], model_dir=tmp)
        check("EB8 模型缺失抛 EmbedUnavailableError", False, "未抛错")
    except emb.EmbedUnavailableError:
        check("EB8 模型缺失抛 EmbedUnavailableError", True)
    except Exception as e:
        check("EB8 模型缺失抛 EmbedUnavailableError", False, f"{type(e).__name__}: {e}")

    import shutil
    shutil.rmtree(tmp, ignore_errors=True)

    print(f"\n===== 结果：{PASS} PASS / {FAIL} FAIL =====")
    if FAILURES:
        print("失败项：", "、".join(FAILURES))
        sys.exit(1)


if __name__ == "__main__":
    main()
