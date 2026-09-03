"""bge-m3-onnx-int8 嵌入可行性实测（TS-120 二期预研）。

验证三件事：
  1. onnxruntime 能加载 INT8 ONNX 模型（arm64 CPU）
  2. 单次前向同时输出三合一：dense / sparse(token_weights) / colbert
  3. 中文语义：相关句相似度 > 无关句相似度

用法：.venv/bin/python -m sidecar.knowledge.test_bge_m3_probe
"""
import sys
import time
from pathlib import Path

MODEL_DIR = Path.home() / ".subagent" / "models" / "bge-m3-onnx-int8"

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
    onnx_path = MODEL_DIR / "model_quantized.onnx"
    tok_path = MODEL_DIR / "tokenizer.json"
    if not onnx_path.is_file():
        print(f"FAIL  权重文件不存在：{onnx_path}")
        sys.exit(1)
    print(f"权重文件：{onnx_path}（{onnx_path.stat().st_size / 1e6:.0f} MB）")

    import onnxruntime as ort
    from tokenizers import Tokenizer

    # 1. 加载模型（记录耗时与内存前基线）
    t0 = time.perf_counter()
    sess_opts = ort.SessionOptions()
    sess_opts.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
    sess = ort.InferenceSession(str(onnx_path), sess_opts,
                                providers=["CPUExecutionProvider"])
    load_ms = (time.perf_counter() - t0) * 1000
    print(f"加载耗时：{load_ms:.0f} ms")
    check("E1 模型加载成功", True)
    in_names = [i.name for i in sess.get_inputs()]
    out_names = [o.name for o in sess.get_outputs()]
    print(f"输入：{in_names}")
    print(f"输出：{out_names}（期望 3 个：dense / sparse权重 / colbert）")
    check("E2 输出为三合一（3 个输出头）", len(out_names) == 3, str(out_names))

    # 2. 分词（tokenizers 轻量库，不需要 transformers）
    tokenizer = Tokenizer.from_file(str(tok_path))
    from tokenizers.models import WordPiece
    if isinstance(tokenizer.model, WordPiece):
        tokenizer.model.unk_token = "<unk>"
    texts = [
        "北京是中国的首都，位于华北平原",          # 锚点
        "中国的首都是北京",                        # 语义相近（换述）
        "今天晚饭吃了火锅和烤肉",                  # 无关
    ]
    enc = tokenizer.encode_batch(texts)
    max_len = max(len(e.ids) for e in enc)
    import array
    input_ids = []
    attention_mask = []
    for e in enc:
        pad_len = max_len - len(e.ids)
        input_ids.append(e.ids + [1] * pad_len)          # pad_token_id = 1
        attention_mask.append([1] * len(e.ids) + [0] * pad_len)

    # numpy 数组
    import numpy as np
    feed = {
        "input_ids": np.asarray(input_ids, dtype=np.int64),
        "attention_mask": np.asarray(attention_mask, dtype=np.int64),
    }
    # token_type_ids 仅在模型要求时提供（type_vocab_size=1 通常不需要）
    if "token_type_ids" in in_names:
        feed["token_type_ids"] = np.zeros_like(feed["input_ids"])

    t1 = time.perf_counter()
    outs = sess.run(None, feed)
    infer_ms = (time.perf_counter() - t1) * 1000
    print(f"前向耗时：{infer_ms:.0f} ms（{len(texts)} 句，max_len={max_len}）")
    check("E3 前向推理成功", True)

    dense = outs[0]            # (B, 1024)
    sparse = outs[1]           # token 权重
    colbert = outs[2]          # (B, L, 1024)
    print(f"dense shape: {dense.shape} | sparse shape: {sparse.shape} | colbert shape: {colbert.shape}")
    check("E4 dense 维度 1024", dense.shape[-1] == 1024, str(dense.shape))
    check("E5 sparse 权重非空", sparse.size > 0, str(sparse.shape))
    check("E6 colbert token 级向量", colbert.ndim == 3 and colbert.shape[-1] == 1024, str(colbert.shape))

    # 3. 语义验证：余弦相似度
    def cos(a, b):
        a = np.asarray(a, dtype=np.float64); b = np.asarray(b, dtype=np.float64)
        return float(np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-9))
    sim_related = cos(dense[0], dense[1])
    sim_unrelated = cos(dense[0], dense[2])
    print(f"相似度：锚点↔相关句 = {sim_related:.4f} | 锚点↔无关句 = {sim_unrelated:.4f}")
    check("E7 语义排序正确（相关 > 无关）", sim_related > sim_unrelated,
          f"{sim_related:.4f} vs {sim_unrelated:.4f}")
    # 区分度断言：INT8 量化 + 短句场景下同义句相似度约 0.7+（非 FP32 的 0.85+），
    # 真正重要的是与无关句拉开差距（>0.2），这是检索可用的判据
    check("E8 语义区分度足够（相关-无关 > 0.2）",
          sim_related - sim_unrelated > 0.2,
          f"差距 {sim_related - sim_unrelated:.4f}")

    print(f"\n===== 结果：{PASS} PASS / {FAIL} FAIL =====")
    if FAILURES:
        print("失败项：", "、".join(FAILURES))
        sys.exit(1)


if __name__ == "__main__":
    main()
