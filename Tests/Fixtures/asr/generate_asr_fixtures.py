#!/usr/bin/env python3
# VetarAI Native — Phase 3 Wave 3b（ASR 金样 fixture 生成器）
#
# 用途：用 Python 参考实现（⛔ 只读规格源 subagent/sidecar/model_packs/asr_driver.py，
# 以 stub 隔离加载、绝不修改）对一个自造 16kHz 样本波形导出逐阶段中间特征，
# 供 Swift 侧 NativeAsrFeatureGoldenTests 金样比对（max abs diff < 1e-4 严容差；
# 功率谱幅值 ~1e12 采用相对容差 1e-9，见测试文件注记）。
#
# 产物（同目录 asr_golden.json）：
#   waveform            输入波形 float32（0.35s 正弦 440Hz + 种子噪声）
#   dither_noise        (T,400) 行主序 float64——注入参考实现复现 numpy standard_normal
#   preemphasis_frames  (T,400) float64：dither+去直流+预加重完成态
#   windowed_frames     (T,400) float64：hamming 加窗完成态
#   power_spectrum      (T,257) float64：|rfft|²
#   fbank_log_mel       (T,80)  float32：log-mel fbank（= 参考 fbank() 出口）
#   lfr                 (T',560) float32：apply_lfr 出口
#   cmvn                {means, vars}：am.mvn 解析（560 维）
#   cmvn_output         (T',560) float64：apply_cmvn 出口
#   ctc_cases           合成 logits → 参考 _ctc_greedy_decode 的 raw + 后处理文本
#   postprocess_cases   原始标记串 → 参考 rich_transcription_postprocess 输出
#
# 交叉校验：生成器内手工分阶段复算 fbank 并与参考 fbank() 出口断言全等——
# 确保导出的中间阶段确实出自参考实现路径，不是生成器自己的平行实现。
#
# 运行：/Users/vetar/Desktop/beta/subagent/.venv/bin/python generate_asr_fixtures.py
from __future__ import annotations

import importlib.util
import json
import sys
import types
from pathlib import Path

import numpy as np

SUBAGENT = Path("/Users/vetar/Desktop/beta/subagent")
PACK_DIR = Path.home() / ".subagent/models/packs/sensevoice-small"
HERE = Path(__file__).resolve().parent
OUT = HERE / "asr_golden.json"


def load_reference():
    """以 stub 隔离加载 asr_driver（只读 exec；store 依赖桩掉——特征函数用不到）。"""
    store = types.ModuleType("sidecar.model_packs.store")
    mp = types.ModuleType("sidecar.model_packs")
    sidecar = types.ModuleType("sidecar")
    sys.modules.setdefault("sidecar", sidecar)
    sys.modules.setdefault("sidecar.model_packs", mp)
    sys.modules.setdefault("sidecar.model_packs.store", store)
    spec = importlib.util.spec_from_file_location(
        "asr_driver_ref", SUBAGENT / "sidecar/model_packs/asr_driver.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main() -> None:
    ref = load_reference()

    # ── 输入波形：0.35s @16k 正弦 440Hz (0.1) + 种子噪声 (0.01) ──
    sr = 16000
    n = int(0.35 * sr)
    rng_wave = np.random.default_rng(20260917)
    t = np.arange(n, dtype=np.float64) / sr
    waveform = (0.1 * np.sin(2 * np.pi * 440.0 * t)
                + 0.01 * rng_wave.standard_normal(n)).astype(np.float32)

    # ── dither 噪声（注入参考实现复现；numpy standard_normal 数值不可跨语言复现）──
    n_frames = 1 + (n - 400) // 160
    noise = np.random.default_rng(424242).standard_normal((n_frames, 400))

    # ── 参考 fbank() 出口（噪声经 monkeypatch 注入，绝不动参考源码）──
    orig_std_normal = np.random.standard_normal
    np.random.standard_normal = lambda shape: noise
    try:
        ref_fbank = ref.fbank(waveform, fs=sr)
    finally:
        np.random.standard_normal = orig_std_normal

    # ── 手工分阶段复算（逐行照抄参考 fbank 实现；与参考出口断言全等）──
    wave_i16 = np.asarray(waveform, dtype=np.float64) * float(1 << 15)
    idx = (np.arange(400)[None, :] + np.arange(n_frames)[:, None] * 160)
    frames = wave_i16[idx]
    frames = frames + noise                                     # dither
    frames = frames - frames.mean(axis=1, keepdims=True)        # 去直流
    pre = frames.copy()
    pre[:, 1:] -= 0.97 * frames[:, :-1].copy()                  # 预加重（原值副本）
    pre[:, 0] = frames[:, 0] * (1.0 - 0.97)
    ham = 0.54 - 0.46 * np.cos(2.0 * np.pi * np.arange(400) / 399)
    windowed = pre * ham
    power = np.abs(np.fft.rfft(windowed, n=512, axis=1)) ** 2   # (T,257)
    mel = power[:, :256] @ ref._mel_filterbank(sr).T            # (T,80)
    logmel = np.log(np.maximum(mel, np.finfo(np.float32).eps)).astype(np.float32)
    assert np.array_equal(logmel, ref_fbank), "手工分阶段与参考 fbank 出口不一致"

    # ── LFR + CMVN（真包 am.mvn 560 维）──
    lfr = ref.apply_lfr(ref_fbank)
    cmvn = ref._load_cmvn(PACK_DIR / "am.mvn")
    cmvn_out = ref.apply_cmvn(lfr, cmvn)

    # ── CTC 合成 logits 对拍（argmax→去重→去 blank→查表→▁→空格；含越界/截断面）──
    tokens = ["<blk>", "▁你", "好", "▁世", "界", "<|zh|>", "<|HAPPY|>", "▁Hello"]

    def logits_for(seq: list[int], vocab: int = 8) -> list[list[float]]:
        out = []
        for i in seq:
            row = [0.0] * vocab
            row[i] = 1.0
            out.append(row)
        return out

    ctc_cases = []
    # case 1：重复 + blank 混合
    lg = np.array(logits_for([1, 1, 0, 2, 2, 2, 0, 3]), dtype=np.float32)
    raw = ref._ctc_greedy_decode(lg, lg.shape[0], tokens)
    ctc_cases.append({"logits": lg.ravel().tolist(), "frames": lg.shape[0], "vocab": 8,
                      "out_len": lg.shape[0], "tokens": tokens,
                      "expect_raw": raw,
                      "expect_post": ref.rich_transcription_postprocess(raw)})
    # case 2：语种 + 情感标记（后处理清理链）
    lg = np.array(logits_for([5, 1, 1, 2, 6]), dtype=np.float32)
    raw = ref._ctc_greedy_decode(lg, lg.shape[0], tokens)
    ctc_cases.append({"logits": lg.ravel().tolist(), "frames": lg.shape[0], "vocab": 8,
                      "out_len": lg.shape[0], "tokens": tokens,
                      "expect_raw": raw,
                      "expect_post": ref.rich_transcription_postprocess(raw)})
    # case 3：out_len 截断（只解前 3 帧）
    lg = np.array(logits_for([1, 2, 3, 4, 4, 4]), dtype=np.float32)
    raw = ref._ctc_greedy_decode(lg, 3, tokens)
    ctc_cases.append({"logits": lg.ravel().tolist(), "frames": lg.shape[0], "vocab": 8,
                      "out_len": 3, "tokens": tokens,
                      "expect_raw": raw,
                      "expect_post": ref.rich_transcription_postprocess(raw)})
    # case 4：tokens 表外 id（7 在表内，9 越界——logits vocab 10 > tokens 8）
    seq9 = []
    for i in [1, 9, 9, 2]:
        row = [0.0] * 10
        row[i] = 1.0
        seq9.append(row)
    lg = np.array(seq9, dtype=np.float32)
    raw = ref._ctc_greedy_decode(lg, lg.shape[0], tokens)
    ctc_cases.append({"logits": lg.ravel().tolist(), "frames": lg.shape[0], "vocab": 10,
                      "out_len": lg.shape[0], "tokens": tokens,
                      "expect_raw": raw,
                      "expect_post": ref.rich_transcription_postprocess(raw)})

    # ── 后处理专例（语种/情感/事件/多空格/空段/The. 怪癖）──
    post_inputs = [
        "<|zh|>▁你好 世界<|HAPPY|>",
        "<|en|>▁Hello world<|NEUTRAL|>",
        "<|zh|>▁开场<|BGM|>▁背景音乐<|Applause|><|SAD|>",
        "<|nospeech|><|Event_UNK|>",
        "<|zh|>▁The. quick<|en|>▁brown fox<|Laughter|>",
        "<|yue|>▁多  空格  文本<|FEARFUL|>",
        "",
        "<|zh|>",
    ]
    post_cases = [{"input": s, "expect": ref.rich_transcription_postprocess(s)}
                  for s in post_inputs]

    fixture = {
        "sample_rate": sr,
        "waveform": waveform.astype(np.float64).tolist(),
        "dither_noise": noise.ravel().tolist(),
        "preemphasis_frames": pre.ravel().tolist(),
        "windowed_frames": windowed.ravel().tolist(),
        "power_spectrum": power.ravel().tolist(),
        "fbank_log_mel": ref_fbank.astype(np.float64).ravel().tolist(),
        "lfr": lfr.astype(np.float64).ravel().tolist(),
        "cmvn": {"means": cmvn[0].tolist(), "vars": cmvn[1].tolist()},
        "cmvn_output": cmvn_out.ravel().tolist(),
        "ctc_cases": ctc_cases,
        "postprocess_cases": post_cases,
    }
    OUT.write_text(json.dumps(fixture, ensure_ascii=False, separators=(",", ":")),
                   encoding="utf-8")
    print(f"written {OUT} ({OUT.stat().st_size} bytes)")
    print(f"frames={n_frames} lfr_frames={lfr.shape[0]} cmvn_dim={cmvn.shape[1]}")


if __name__ == "__main__":
    main()
