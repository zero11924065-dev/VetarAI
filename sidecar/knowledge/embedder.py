"""TS-120 阶段二（0.4.0）：本地语义嵌入层（bge-m3 ONNX INT8）。

模型：gpahal/bge-m3-onnx-int8（原生三合一输出：dense 1024 维 / sparse token 权重 /
ColBERT token 级向量）。本模块只用 dense + sparse（混合检索两路），ColBERT
暂不索引（存储/计算开销大，知识条目体量下收益低），输出头仍保留。

本地优先铁律：模型文件在本机（默认 ~/.subagent/models/bge-m3-onnx-int8/），
onnxruntime 纯 CPU 推理，不联网。

懒加载：首次调用才加载（约 0.5s），之后单例复用；进程锁防并发重复加载。
缺失降级：模型文件不存在 → EmbedUnavailableError，调用方回退纯关键词检索。

分块策略：知识条目与查询通常短文本；超长文本按 512 token 分块编码，
dense 取均值、稀疏取各块最大值合并（简化且对中文知识条目够用）。
"""
from __future__ import annotations

import os
import struct
import sys
import threading
from pathlib import Path
from typing import Any


class EmbedUnavailableError(RuntimeError):
    """嵌入模型不可用（文件缺失/依赖缺失）——调用方应降级为关键词检索。"""


# 查询侧指令前缀（bge-m3 官方推荐：query 与 passage 不对称，提升检索质量）
QUERY_INSTRUCTION = "Represent this sentence for searching relevant passages: "

# 特殊 token（config.json：bos/cls=0, pad=1, eos=2, unk=3）——稀疏权重剔除
_SPECIAL_TOKEN_IDS = {0, 1, 2, 3}

# 默认模型目录：应用数据根下的 models/（与 Ollama 模型分开管理）
_MODEL_DIR_NAME = "bge-m3-onnx-int8"

# 单块编码上限（token）；bge-m3 支持 8192，取 512 平衡本地 CPU 速度
_CHUNK_TOKENS = 512

# 懒加载单例
_lock = threading.Lock()
_state: dict[str, Any] = {"session": None, "tokenizer": None, "model_dir": None}


def _bundled_model_dir() -> Path | None:
    """安装包内置模型目录（阶段二：随安装包一键部署，用户拍板≤1G）。
    侧车可执行文件位于 Contents/Resources/sidecar/vetarai-sidecar/vetarai-sidecar，
    模型在 Contents/Resources/models/bge-m3-onnx-int8/。"""
    env_dir = os.environ.get("VETARAI_MODELS_DIR")
    if env_dir:
        p = Path(env_dir).expanduser() / _MODEL_DIR_NAME
        if p.is_dir():
            return p
    if getattr(sys, "frozen", False):
        try:
            exe = Path(sys.executable).resolve()
            candidates = [exe.parents[2] / "models" / _MODEL_DIR_NAME]  # Resources/models/
            meipass = getattr(sys, "_MEIPASS", "")
            if meipass:
                candidates.append(Path(meipass) / "models" / _MODEL_DIR_NAME)
            for c in candidates:
                if c.is_dir():
                    return c
        except Exception:
            pass
    return None


def default_model_dir() -> Path:
    """模型目录解析（阶段二三级回退）：
    1. 用户数据目录 {data_root}/models/bge-m3-onnx-int8/（权重存在时优先——
       高级用户可自行替换/升级模型，不被安装包锁死）
    2. 安装包内置目录（一键部署，只读推理无问题）
    3. 兜底返回数据目录路径（文件缺失 → model_available 报 False，检索降级为关键词）"""
    local: Path | None = None
    try:
        from sidecar.config.store import data_root
        local = Path(data_root()) / "models" / _MODEL_DIR_NAME
    except Exception:
        pass
    if local is not None and (local / "model_quantized.onnx").is_file():
        return local
    bundled = _bundled_model_dir()
    if bundled is not None:
        return bundled
    if local is not None:
        return local
    return Path.home() / ".subagent" / "models" / _MODEL_DIR_NAME


def model_available(model_dir: Path | None = None) -> bool:
    """模型文件与权重是否齐备（供状态端点与降级判断）。"""
    d = Path(model_dir) if model_dir else default_model_dir()
    return (d / "model_quantized.onnx").is_file() and (d / "tokenizer.json").is_file()


def _ensure_loaded(model_dir: Path | None = None) -> tuple[Any, Any]:
    """懒加载 session + tokenizer（线程安全单例）。缺失抛 EmbedUnavailableError。"""
    d = Path(model_dir) if model_dir else default_model_dir()
    with _lock:
        if _state["session"] is not None and _state["model_dir"] == str(d):
            return _state["session"], _state["tokenizer"]
        onnx_path = d / "model_quantized.onnx"
        tok_path = d / "tokenizer.json"
        if not onnx_path.is_file() or not tok_path.is_file():
            raise EmbedUnavailableError(
                f"嵌入模型文件缺失：{d}（需要 model_quantized.onnx 与 tokenizer.json）")
        try:
            import onnxruntime as ort
            from tokenizers import Tokenizer
        except ImportError as e:
            raise EmbedUnavailableError(f"嵌入依赖缺失：{e}") from e
        import os as _os
        opts = ort.SessionOptions()
        opts.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
        opts.intra_op_num_threads = max(2, (_os.cpu_count() or 4) // 2)
        session = ort.InferenceSession(str(onnx_path), opts,
                                       providers=["CPUExecutionProvider"])
        tokenizer = Tokenizer.from_file(str(tok_path))
        tokenizer.enable_truncation(max_length=_CHUNK_TOKENS)
        _state["session"] = session
        _state["tokenizer"] = tokenizer
        _state["model_dir"] = str(d)
        return session, tokenizer


def _chunk_texts(text: str) -> list[str]:
    """超长文本按 token 上限分块（短文本原样返回单块列表）。"""
    _, tokenizer = _ensure_loaded()
    enc = tokenizer.encode(text)
    if len(enc.ids) <= _CHUNK_TOKENS:
        return [text]
    # 按 token 数估算字符切点（中文约 1:1，保守按 0.8 系数回退到原文切片）
    chars_per_chunk = max(64, int(_CHUNK_TOKENS * 0.8))
    return [text[i:i + chars_per_chunk] for i in range(0, len(text), chars_per_chunk)]


def encode(texts: list[str], with_query_instruction: bool = False,
           model_dir: Path | None = None) -> list[dict[str, Any]]:
    """批量编码文本 → [{dense: list[float], sparse: {token: weight}}]。

    dense 已归一化（模型导出时即归一化）；稀疏权重按 token 文本聚合（跨块取最大值）。
    空文本返回零向量占位（不抛错，保持批对齐）。
    """
    if not texts:
        return []
    session, tokenizer = _ensure_loaded(model_dir)
    in_names = [i.name for i in session.get_inputs()]
    out = []
    for text in texts:
        text = (text or "").strip()
        if not text:
            out.append({"dense": [0.0] * 1024, "sparse": {}})
            continue
        chunks = _chunk_texts(text)
        if with_query_instruction:
            chunks = [QUERY_INSTRUCTION + c for c in chunks]
        encs = tokenizer.encode_batch(chunks)
        max_len = max(len(e.ids) for e in encs)
        input_ids = []
        attention = []
        for e in encs:
            pad_n = max_len - len(e.ids)
            input_ids.append(e.ids + [1] * pad_n)   # pad_token_id = 1
            attention.append([1] * len(e.ids) + [0] * pad_n)
        import numpy as np
        feed = {
            "input_ids": np.asarray(input_ids, dtype=np.int64),
            "attention_mask": np.asarray(attention, dtype=np.int64),
        }
        if "token_type_ids" in in_names:
            feed["token_type_ids"] = np.zeros_like(feed["input_ids"])
        results = session.run(None, feed)
        dense_arr = results[0]        # (B, 1024) 已归一化
        sparse_arr = results[1]       # (B, L, 1) token 权重
        # dense：多块取均值并重新归一化
        dense = dense_arr.mean(axis=0)
        norm = float(np.linalg.norm(dense))
        if norm > 1e-9:
            dense = dense / norm
        dense_list = [round(float(x), 6) for x in dense]
        # sparse：token_id → 权重；过滤特殊位与填充；token_id 转文本键
        merged: dict[str, float] = {}
        sw = sparse_arr.reshape(sparse_arr.shape[0], -1)
        for i, e in enumerate(encs):
            ids = list(e.ids)
            for tid, w in zip(ids, sw[i][: len(ids)]):
                if tid in _SPECIAL_TOKEN_IDS or float(w) <= 0:
                    continue
                tok = tokenizer.id_to_token(int(tid))
                if not tok:
                    continue
                if float(w) > merged.get(tok, 0.0):
                    merged[tok] = float(w)
        out.append({"dense": dense_list, "sparse": {k: round(v, 5) for k, v in merged.items()}})
    return out


def encode_one(text: str, with_query_instruction: bool = False,
               model_dir: Path | None = None) -> dict[str, Any]:
    """单条编码便捷封装。"""
    return encode([text], with_query_instruction=with_query_instruction,
                  model_dir=model_dir)[0]


# ---------- 向量序列化（SQLite BLOB 存 float32）----------
def dense_to_blob(vec: list[float]) -> bytes:
    return struct.pack(f"<{len(vec)}f", *vec)


def blob_to_dense(blob: bytes) -> list[float]:
    n = len(blob) // 4
    return list(struct.unpack(f"<{n}f", blob))


def cosine(a: list[float], b: list[float]) -> float:
    """余弦相似度（dense 已归一化，点积即余弦）。"""
    if not a or not b or len(a) != len(b):
        return 0.0
    return sum(x * y for x, y in zip(a, b))


def sparse_dot(q_sparse: dict[str, float], d_sparse: dict[str, float]) -> float:
    """稀疏点积（小字典一侧遍历）。"""
    if not q_sparse or not d_sparse:
        return 0.0
    small, big = (q_sparse, d_sparse) if len(q_sparse) <= len(d_sparse) else (d_sparse, q_sparse)
    return sum(w * big.get(tok, 0.0) for tok, w in small.items())
