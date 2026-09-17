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
"""0.4.29（P3）ASR 驱动：SenseVoiceSmall ONNX（onnxruntime CPU，懒加载单例）。

计划锚点：D5（ASR 两段式）/ D6（驱动形态）。「模型可更换，像 ollama 模型一样」——
ASR 模型走 P1 模型包体系安装（manifest task="asr"、format="onnx"、driver="onnxruntime"），
本驱动只认模型包注册表，不内置任何权重路径。

包内文件契约（官方 FunASR ONNX 导出物，缺一即 PackUnavailableError）：
  model_quant.onnx（首选，INT8）或 model.onnx（FP32）/ am.mvn（CMVN 统计）/ tokens.json（词表）

官方源核实（2026-09-17 联网实测，计划 R1 项销账）：
  ModelScope 官方仓 iic/SenseVoiceSmall-onnx（FunASR 团队维护）直连可达：
    HEAD  https://modelscope.cn/models/iic/SenseVoiceSmall-onnx/resolve/master/model_quant.onnx → 200
    Range bytes=0-1023（跟随 302 到 CDN）→ 206（断点续传可用，P1 下载器兼容）
  文件清单与 SHA256（ModelScope repo/files API 返回，catalog 制作者照抄即可）：
    model_quant.onnx  241216270 B  sha256 21dc965f689a78d1604717bf561e40d5a236087c85a95584567835750549e822
    am.mvn            11203 B      sha256 29b3c740a2c0cfc6b308126d31d7f265fa2be74f3bb095cd2f143ea970896ae5
    tokens.json       352064 B     sha256 a2594fc1474e78973149cba8cd1f603ebed8c39c7decb470631f66e70ce58e97
    config.yaml       1855 B       sha256 f71e239ba36705564b5bf2d2ffd07eece07b8e3f2bbf6d2c99d8df856339ac19
  本仓只含 INT8 量化模型（无 fp32 model.onnx）；config.yaml frontend_conf：
    fs=16000 / window=hamming / n_mels=80 / frame_length=25 / frame_shift=10 / lfr_m=7 / lfr_n=6。
  huggingface.co 本机直连实测不可达（curl HTTP 000）→ catalog 多源顺序：
    ModelScope（.cn 直连）优先，HF 镜像仅作备用（计划 R5 同款策略）。

推理链（全部本地 CPU，零新增依赖——onnxruntime/numpy 随嵌入层已引入）：
  ① 解码：macOS 走系统自带 afconvert（textutil 同款零依赖先例）统一转 16kHz 单声道
     PCM16 WAV（CoreAudio 支持 mp3/m4a/aac/aiff/caf/flac/wav；webm/ogg/opus
     CoreAudio 不支持 → AudioDecodeError 如实报错，不静默）；非 macOS 退 stdlib wave
     仅读 PCM WAV + numpy 线性重采样。
  ② fbank：kaldi_native_fbank（WavFrontend 实际依赖）的**纯 numpy 精确移植**——
     本仓不能引 knf（C++ 扩展，违反零依赖红线），故逐行对照其 csrc 移植：
     dither(高斯×1.0) → 去直流 → 预加重 0.97 → hamming 窗(400) → 补零 512 →
     rfft 功率谱 → 80 维 HTK 三角 mel（1127·ln(1+f/700)，low=20Hz，high=Nyquist）→
     log(max(·, FLT_EPSILON))。帧数 snip_edges 语义：1+(N-400)//160。
  ③ LFR(7,6) + CMVN（am.mvn 的 AddShift/Rescale 两行，funasr load_cmvn 解析格式）；
     560 维 = 80×7 即 ONNX 图 speech 输入的最后一维。
  ④ ONNX 图契约（funasr/models/sense_voice/export_meta.py 核实）：
     输入 speech(B,T,560)f32 / speech_lengths(B,)i32 / language(B,)i32 / textnorm(B,)i32；
     输出 ctc_logits(B,T',V) / encoder_out_lens(B,)i32。
     language 码表 {"auto":0,"zh":3,"en":4,"yue":7,"ja":11,"ko":12,"nospeech":13}，
     textnorm 码表 {"withitn":14,"woitn":15}（funasr_onnx/sensevoice_bin.py 核实）。
  ⑤ CTC greedy：argmax → 去连续重复 → 去 blank(0) → tokens.json 查表拼接，
     "▁"→" "（sentencepiece DecodeIds 等价物），再经 rich_transcription_postprocess
     （FunASR 官方后处理的忠实移植：语种/情感/事件标记清理）。

懒加载：首次 transcribe 才加载（embedder.py 范式）；单例按 pack_id 键控，
换包即重载；进程锁防并发重复加载；session.run 串行化（用户节奏的转写请求，
串行足够且规避 ORT 并发不确定性）。卸载＝释放 session（D6）。
缺包/缺文件 → PackUnavailableError，端点转 409/503 中文明细（EmbedUnavailableError 先例）。
"""
from __future__ import annotations

import json
import logging
import math
import os
import platform
import shutil
import subprocess
import tempfile
import threading
import wave
from pathlib import Path
from typing import Any

from sidecar.model_packs import store as _store

_log = logging.getLogger("sidecar.model_packs.asr")


class PackUnavailableError(RuntimeError):
    """ASR 模型包不可用（未安装/已禁用/缺文件/依赖缺失）——调用方转中文明细给用户。"""


class AudioDecodeError(RuntimeError):
    """音频解码失败（格式不支持/文件损坏/解码工具不可用），message 一律中文。"""


# ── SenseVoiceSmall 固定参数（config.yaml frontend_conf 与 export_meta 核实，勿凭直觉改）──
_SAMPLE_RATE_DEFAULT = 16000
_FRAME_LEN = 400            # 25ms @16k
_FRAME_SHIFT = 160          # 10ms @16k
_NFFT = 512                 # 补零到 2 的幂（knf round_to_power_of_two）
_N_MELS = 80
_PREEMPH = 0.97
_DITHER = 1.0               # WavFrontend 缺省（config.yaml 未覆盖）；knf 语义：高斯噪声×系数
_MEL_LOW_FREQ = 20.0        # knf MelBanksOptions 缺省
_LFR_M = 7
_LFR_N = 6
_BLANK_ID = 0
_LANG_IDS = {"auto": 0, "zh": 3, "en": 4, "yue": 7, "ja": 11, "ko": 12, "nospeech": 13}
_TEXTNORM_IDS = {"withitn": 14, "woitn": 15}

# 懒加载单例（embedder.py _state 范式）：按 pack_id 键控，换包重载
_lock = threading.Lock()
_state: dict[str, Any] = {"pack_id": None, "session": None, "tokens": None,
                          "cmvn": None, "sample_rate": _SAMPLE_RATE_DEFAULT}


# ══════════════ 包解析与懒加载 ══════════════

def resolve_asr_pack(pack_id: str | None = None) -> str:
    """解析本次转写使用的 ASR 包 id。

    pack_id 缺省 → 取注册表中**首个启用中的 task=asr 包**（按 id 排序，确定性选择；
    「像 ollama 一样可更换」= 用户在模型包面板装/禁哪个，这里就用哪个，无需配置键）。
    未装/全禁用/指定包非 asr → PackUnavailableError（中文明细，指引去模型包面板）。
    """
    reg = _store.read_registry()
    if pack_id:
        entry = reg.get(pack_id)
        if entry is None:
            raise PackUnavailableError(
                f"模型包 {pack_id!r} 未安装。请到「模型包」面板安装语音识别模型包。")
        if entry.get("task") != "asr":
            raise PackUnavailableError(
                f"模型包 {pack_id!r} 不是语音识别包（task={entry.get('task')!r}），"
                "请检查 catalog 清单。")
        if entry.get("status") != "installed":
            raise PackUnavailableError(
                f"模型包 {pack_id!r} 已禁用。请到「模型包」面板启用后再转写。")
        return pack_id
    candidates = sorted(pid for pid, e in reg.items()
                        if e.get("task") == "asr" and e.get("status") == "installed")
    if not candidates:
        raise PackUnavailableError(
            "尚未安装语音识别模型包。请到「模型包」面板安装一个 ASR 模型包"
            "（如 SenseVoiceSmall）后再试。")
    return candidates[0]


def _pack_files(pack_id: str) -> tuple[Path, Path, Path]:
    """从注册表 files[] 解析 (onnx, am.mvn, tokens.json) 三个绝对路径；缺一即拒。"""
    entry = _store.get_entry(pack_id) or {}
    base = _store.pack_dir(pack_id)
    onnx_rel = ""
    for f in entry.get("files", []):
        p = str(f.get("path", ""))
        if p == "model_quant.onnx":      # INT8 首选（官方仓只发这个）
            onnx_rel = p
            break
        if p.lower().endswith(".onnx") and not onnx_rel:
            onnx_rel = p
    rels: dict[str, str] = {"onnx": onnx_rel}
    for want in ("am.mvn", "tokens.json"):
        rels[want] = ""
        for f in entry.get("files", []):
            p = str(f.get("path", ""))
            if p == want or p.endswith("/" + want):
                rels[want] = p
                break
    missing_keys = [k for k, v in rels.items() if not v]
    if missing_keys:
        raise PackUnavailableError(
            f"模型包 {pack_id!r} 清单缺文件（{', '.join(missing_keys)}），"
            "SenseVoiceSmall 包须含 model_quant.onnx（或 .onnx）/ am.mvn / tokens.json。")
    paths = tuple(base / rels[k] for k in ("onnx", "am.mvn", "tokens.json"))
    missing_disk = [p.name for p in paths if not p.is_file()]
    if missing_disk:
        raise PackUnavailableError(
            f"模型包 {pack_id!r} 的文件在磁盘上缺失: {', '.join(missing_disk)}"
            "（安装不完整或被手动删除），请到「模型包」面板重新安装。")
    return paths  # type: ignore[return-value]


def _load_cmvn(path: Path) -> "Any":
    """am.mvn → (2, dim) float64（funasr_onnx load_cmvn 同款解析：<AddShift>/<Rescale>
    各自的 <LearnRateCoef> 行，取第 3 列到倒数第 1 列）。"""
    import numpy as np
    lines = path.read_text(encoding="utf-8").splitlines()
    means: list[float] = []
    rescale: list[float] = []
    for i, line in enumerate(lines):
        item = line.split()
        if not item:
            continue
        if item[0] == "<AddShift>" and i + 1 < len(lines):
            nxt = lines[i + 1].split()
            if nxt and nxt[0] == "<LearnRateCoef>":
                means = [float(x) for x in nxt[3:-1]]
        elif item[0] == "<Rescale>" and i + 1 < len(lines):
            nxt = lines[i + 1].split()
            if nxt and nxt[0] == "<LearnRateCoef>":
                rescale = [float(x) for x in nxt[3:-1]]
    if not means or not rescale:
        raise PackUnavailableError(f"am.mvn 解析失败（缺 AddShift/Rescale 段）: {path}")
    return np.array([means, rescale], dtype=np.float64)


def _ensure_loaded(pack_id: str) -> tuple[Any, list[str], Any, int]:
    """懒加载 (session, tokens, cmvn, sample_rate)（线程安全单例，换包重载）。"""
    with _lock:
        if _state["session"] is not None and _state["pack_id"] == pack_id:
            return _state["session"], _state["tokens"], _state["cmvn"], _state["sample_rate"]
        onnx_path, cmvn_path, tokens_path = _pack_files(pack_id)
        try:
            import onnxruntime as ort
            import numpy as np  # noqa: F401（确认依赖在）
        except ImportError as e:
            raise PackUnavailableError(f"ASR 依赖缺失：{e}") from e
        opts = ort.SessionOptions()
        opts.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
        opts.intra_op_num_threads = max(2, (os.cpu_count() or 4) // 2)
        try:
            session = ort.InferenceSession(str(onnx_path), opts,
                                           providers=["CPUExecutionProvider"])
        except Exception as e:
            raise PackUnavailableError(f"ONNX 模型加载失败: {onnx_path.name}: {e}") from e
        try:
            tokens = json.loads(tokens_path.read_text(encoding="utf-8"))
        except Exception as e:
            raise PackUnavailableError(f"tokens.json 解析失败: {e}") from e
        if not (isinstance(tokens, list) and tokens and
                all(isinstance(t, str) for t in tokens)):
            raise PackUnavailableError("tokens.json 须为非空字符串数组（SenseVoice 词表）")
        cmvn = _load_cmvn(cmvn_path)
        # manifest 可选键 sample_rate（D 决策补的正整数可选键，缺省 16000）
        sr = _SAMPLE_RATE_DEFAULT
        man_sr = _store.read_manifest(pack_id).get("sample_rate")
        if isinstance(man_sr, int) and not isinstance(man_sr, bool) and man_sr > 0:
            sr = man_sr
        _state.update({"pack_id": pack_id, "session": session, "tokens": tokens,
                       "cmvn": cmvn, "sample_rate": sr})
        _log.info("ASR 模型已加载: pack=%s onnx=%s", pack_id, onnx_path.name)
        return session, tokens, cmvn, sr


def unload(pack_id: str | None = None) -> bool:
    """卸载＝释放 session（D6）。pack_id 不匹配时不动（防误卸正在用的包）。"""
    with _lock:
        if _state["session"] is None:
            return False
        if pack_id is not None and _state["pack_id"] != pack_id:
            return False
        _state.update({"pack_id": None, "session": None, "tokens": None, "cmvn": None})
        return True


# ══════════════ 音频解码（16kHz 单声道 float32[-1,1]）══════════════

def _read_wav_pcm(path: Path) -> tuple["Any", int]:
    """stdlib wave 读 PCM WAV → (float32[-1,1] 单声道, 采样率)。非 PCM/损坏 → AudioDecodeError。"""
    import numpy as np
    try:
        with wave.open(str(path), "rb") as w:
            ch, sw, sr, n = (w.getnchannels(), w.getsampwidth(),
                             w.getframerate(), w.getnframes())
            raw = w.readframes(n)
    except Exception as e:
        raise AudioDecodeError(f"WAV 读取失败（文件损坏或非 PCM 编码）: {e}") from e
    if sw == 2:
        arr = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
    elif sw == 4:
        arr = np.frombuffer(raw, dtype=np.int32).astype(np.float32) / 2147483648.0
    elif sw == 1:
        arr = (np.frombuffer(raw, dtype=np.uint8).astype(np.float32) - 128.0) / 128.0
    else:
        raise AudioDecodeError(f"不支持的 WAV 位深（{sw * 8}bit），请转 16bit PCM")
    if ch > 1:
        arr = arr.reshape(-1, ch).mean(axis=1)
    return arr, sr


def _resample_linear(arr: "Any", src_sr: int, dst_sr: int) -> "Any":
    """非 macOS 兜底重采样（线性插值，质量逊于 afconvert，仅兜底路径用）。"""
    import numpy as np
    if src_sr == dst_sr:
        return arr
    n_out = max(1, int(round(len(arr) * dst_sr / src_sr)))
    xp = np.linspace(0.0, 1.0, num=len(arr), endpoint=True)
    x = np.linspace(0.0, 1.0, num=n_out, endpoint=True)
    return np.interp(x, xp, arr).astype(np.float32)


def _decode_via_afconvert(path: Path, target_sr: int) -> "Any":
    """macOS 零依赖解码：系统 afconvert 统一转 PCM16 WAV（textutil 同款先例：
    外部系统进程 + 超时护栏；成败以产物文件为准，不轻信 exit code）。"""
    import numpy as np
    if shutil.which("afconvert") is None:
        raise AudioDecodeError("系统缺少 afconvert（非 macOS？），该音频格式无法解码")
    with tempfile.TemporaryDirectory(prefix="asr_dec_") as td:
        out = Path(td) / "out.wav"
        try:
            subprocess.run(
                ["afconvert", "-f", "WAVE", "-d", f"LEI16@{target_sr}", "-c", "1",
                 str(path), str(out)],
                capture_output=True, timeout=120)
        except subprocess.TimeoutExpired as e:
            raise AudioDecodeError("音频解码超时（120s）") from e
        except OSError as e:
            raise AudioDecodeError(f"无法启动 afconvert: {e}") from e
        if not out.is_file() or out.stat().st_size <= 44:
            raise AudioDecodeError(
                "音频解码失败：该格式不受支持或文件已损坏"
                "（支持 wav/mp3/m4a/aac/aiff/caf/flac；webm/ogg/opus 请先转 wav 或 m4a）")
        arr, _ = _read_wav_pcm(out)
        return np.asarray(arr, dtype=np.float32)


def load_audio(path: Path, target_sr: int = _SAMPLE_RATE_DEFAULT) -> tuple["Any", float]:
    """音频文件 → (float32[-1,1] 单声道波形 @ target_sr, 时长秒)。

    macOS：一律 afconvert（格式覆盖最广、重采样质量高）。
    非 macOS：仅 PCM WAV（stdlib wave + 线性重采样兜底），其余格式如实报错。
    """
    import numpy as np
    if platform.system() == "Darwin":
        arr = _decode_via_afconvert(path, target_sr)
    else:
        if path.suffix.lower() != ".wav":
            raise AudioDecodeError(
                "当前平台仅支持 PCM WAV 直读；mp3/m4a 等请转成 16kHz 单声道 WAV 后再试")
        arr, sr = _read_wav_pcm(path)
        arr = _resample_linear(arr, sr, target_sr)
    if arr.size == 0:
        raise AudioDecodeError("音频内容为空（0 采样点）")
    duration_s = float(arr.size) / float(target_sr)
    return np.asarray(arr, dtype=np.float32), duration_s


# ══════════════ 特征：kaldi fbank 纯 numpy 移植（knf csrc 逐行对照）══════════════

def _mel_scale(freq: float) -> float:
    """HTK mel（knf MelBanks::MelScale；is_librosa=false 的 kaldi 默认路径）。"""
    return 1127.0 * math.log(1.0 + freq / 700.0)


def _mel_filterbank(fs: int) -> "Any":
    """(n_mels, n_fft/2) 三角 mel 权重（knf InitKaldiMelBanks：mel 域线性、无归一化、
    low=20Hz、high=Nyquist；vtln_warp_factor=1 不走 warping）。"""
    import numpy as np
    n_bins = _NFFT // 2
    nyq = 0.5 * fs
    mel_lo, mel_hi = _mel_scale(_MEL_LOW_FREQ), _mel_scale(nyq)
    delta = (mel_hi - mel_lo) / (_N_MELS + 1)
    fft_bin_width = fs / _NFFT
    fb = np.zeros((_N_MELS, n_bins), dtype=np.float64)
    for b in range(_N_MELS):
        lm, cm, rm = mel_lo + b * delta, mel_lo + (b + 1) * delta, mel_lo + (b + 2) * delta
        for i in range(n_bins):
            mel = _mel_scale(fft_bin_width * i)
            if lm < mel < rm:
                fb[b, i] = ((mel - lm) / (cm - lm)) if mel <= cm else ((rm - mel) / (rm - cm))
    return fb


def fbank(waveform: "Any", fs: int = _SAMPLE_RATE_DEFAULT) -> "Any":
    """波形 → log-mel fbank (T, 80)。

    knf OnlineFbank 离线等价（WavFrontend 参数：hamming/dither=1.0/snip_edges=True/
    energy_floor=0/use_energy=False）。波形先 ×32768 到 int16 刻度（WavFrontend.fbank
    同款——knf 按 int16 幅值约定处理，dither=1.0 的高斯抖动在该刻度下才吻合）。
    """
    import numpy as np
    wave_i16 = np.asarray(waveform, dtype=np.float64) * float(1 << 15)
    n = wave_i16.shape[0]
    if n < _FRAME_LEN:
        return np.zeros((0, _N_MELS), dtype=np.float32)
    n_frames = 1 + (n - _FRAME_LEN) // _FRAME_SHIFT   # snip_edges=True 帧数公式
    idx = (np.arange(_FRAME_LEN)[None, :]
           + np.arange(n_frames)[:, None] * _FRAME_SHIFT)
    frames = wave_i16[idx]                                        # (T, 400)
    # knf ProcessWindow 顺序：dither → 去直流 → 预加重 → 加窗
    frames += np.random.standard_normal(frames.shape) * _DITHER   # RandGauss×dither
    frames -= frames.mean(axis=1, keepdims=True)                  # remove_dc_offset
    frames[:, 1:] -= _PREEMPH * frames[:, :-1].copy()             # 预加重（用原值，逆向等价）
    frames[:, 0] *= (1.0 - _PREEMPH)
    ham = 0.54 - 0.46 * np.cos(2.0 * np.pi * np.arange(_FRAME_LEN) / (_FRAME_LEN - 1))
    frames *= ham
    power = np.abs(np.fft.rfft(frames, n=_NFFT, axis=1)) ** 2     # (T, 257)
    mel = power[:, :_NFFT // 2] @ _mel_filterbank(fs).T           # (T, 80)
    mel = np.log(np.maximum(mel, np.finfo(np.float32).eps))       # use_log_fbank
    return mel.astype(np.float32)


def apply_lfr(feat: "Any") -> "Any":
    """低帧率堆叠 m=7/n=6（funasr_onnx WavFrontend.apply_lfr 逐行移植：
    左端以首帧复制 (m-1)//2 行，末帧不足以末帧补齐）。"""
    import numpy as np
    T = feat.shape[0]
    T_lfr = int(np.ceil(T / _LFR_N))
    left = np.tile(feat[0], ((_LFR_M - 1) // 2, 1))
    padded = np.vstack((left, feat))
    T_pad = T + (_LFR_M - 1) // 2
    out = []
    for i in range(T_lfr):
        if _LFR_M <= T_pad - i * _LFR_N:
            out.append(padded[i * _LFR_N: i * _LFR_N + _LFR_M].reshape(1, -1))
        else:
            num_padding = _LFR_M - (T_pad - i * _LFR_N)
            frame = padded[i * _LFR_N:].reshape(-1)
            for _ in range(num_padding):
                frame = np.hstack((frame, padded[-1]))
            out.append(frame)
    return np.vstack(out).astype(np.float32)


def apply_cmvn(feat: "Any", cmvn: "Any") -> "Any":
    """(x + means) × vars（funasr apply_cmvn 语义：am.mvn 的 AddShift 存的是负均值；
    numpy 广播天然等价于原实现的 np.tile）。"""
    dim = feat.shape[1]
    return (feat + cmvn[0:1, :dim]) * cmvn[1:2, :dim]


# ══════════════ 后处理（FunASR rich_transcription_postprocess 忠实移植）══════════════
# 官方实现：funasr/utils/postprocess_utils.py。情感/事件标记映射为 emoji 属
# 用户可见文案（UI 文案允许 emoji；注释/docstring 仍零 emoji 纪律不受影响）。

_LANG_TAGS = {"<|zh|>", "<|en|>", "<|yue|>", "<|ja|>", "<|ko|>", "<|nospeech|>"}
_EMOJI_DICT = {
    "<|nospeech|><|Event_UNK|>": "❓",
    "<|zh|>": "", "<|en|>": "", "<|yue|>": "", "<|ja|>": "", "<|ko|>": "",
    "<|nospeech|>": "",
    "<|HAPPY|>": "😊", "<|SAD|>": "😔", "<|ANGRY|>": "😡", "<|NEUTRAL|>": "",
    "<|BGM|>": "🎼", "<|Speech|>": "", "<|Applause|>": "👏", "<|Laughter|>": "😀",
    "<|FEARFUL|>": "😰", "<|DISGUSTED|>": "🤢", "<|SURPRISED|>": "😮",
    "<|Cry|>": "😭", "<|EMO_UNKNOWN|>": "", "<|Sneeze|>": "🤧", "<|Breath|>": "",
    "<|Cough|>": "😷", "<|Sing|>": "", "<|Speech_Noise|>": "",
    "<|withitn|>": "", "<|woitn|>": "", "<|GBG|>": "", "<|Event_UNK|>": "",
}
_EMO_DICT = {"<|HAPPY|>": "😊", "<|SAD|>": "😔", "<|ANGRY|>": "😡", "<|NEUTRAL|>": "",
             "<|FEARFUL|>": "😰", "<|DISGUSTED|>": "🤢", "<|SURPRISED|>": "😮",
             "<|EMO_UNKNOWN|>": ""}
_EVENT_DICT = {"<|BGM|>": "🎼", "<|Speech|>": "", "<|Applause|>": "👏",
               "<|Laughter|>": "😀", "<|Cry|>": "😭", "<|Sneeze|>": "🤧",
               "<|Breath|>": "", "<|Cough|>": "😷"}
_EMO_SET = {"😊", "😔", "😡", "😰", "🤢", "😮"}
_EVENT_SET = {"🎼", "👏", "😀", "😭", "🤧", "😷"}


def _format_str_v2(s: str) -> str:
    sptk_count: dict[str, int] = {}
    for sptk in _EMOJI_DICT:
        sptk_count[sptk] = s.count(sptk)
        s = s.replace(sptk, "")
    emo = "<|NEUTRAL|>"
    for e in _EMO_DICT:
        if sptk_count.get(e, 0) > sptk_count.get(emo, 0):
            emo = e
    for e, emoji in _EVENT_DICT.items():
        if sptk_count.get(e, 0) > 0:
            s = emoji + s
    s = s + _EMO_DICT[emo]
    for emoji in _EMO_SET | _EVENT_SET:
        s = s.replace(" " + emoji, emoji)
        s = s.replace(emoji + " ", emoji)
    return s.strip()


def rich_transcription_postprocess(s: str) -> str:
    """语种/情感/事件标记清理（FunASR 官方同名函数移植）。"""
    def get_emo(x: str) -> str | None:
        return x[-1] if x and x[-1] in _EMO_SET else None

    def get_event(x: str) -> str | None:
        return x[0] if x and x[0] in _EVENT_SET else None

    s = s.replace("<|nospeech|><|Event_UNK|>", "❓")
    for lang in _LANG_TAGS:
        s = s.replace(lang, "<|lang|>")
    s_list = [_format_str_v2(s_i).strip(" ") for s_i in s.split("<|lang|>")]
    new_s = " " + (s_list[0] if s_list else "")
    cur_ent_event = get_event(new_s)
    for i in range(1, len(s_list)):
        if len(s_list[i]) == 0:
            continue
        if get_event(s_list[i]) == cur_ent_event and get_event(s_list[i]) is not None:
            s_list[i] = s_list[i][1:]
        if len(s_list[i]) == 0:
            continue
        cur_ent_event = get_event(s_list[i])
        if get_emo(s_list[i]) is not None and get_emo(s_list[i]) == get_emo(new_s):
            new_s = new_s[:-1]
        new_s += s_list[i].strip().lstrip()
    new_s = new_s.replace("The.", " ")
    return new_s.strip()


def _ctc_greedy_decode(logits: "Any", out_len: int, tokens: list[str]) -> str:
    """argmax → 去连续重复 → 去 blank(0) → 查表拼接（▁→空格，等价 sentencepiece DecodeIds）。"""
    import numpy as np
    x = logits[:out_len, :]
    yseq = np.argmax(x, axis=-1)
    mask = np.concatenate(([True], np.diff(yseq) != 0))
    yseq = yseq[mask]
    ids = [int(t) for t in yseq.tolist() if int(t) != _BLANK_ID]
    pieces = [tokens[i] for i in ids if 0 <= i < len(tokens)]
    return "".join(pieces).replace("▁", " ")


# ══════════════ 对外 API ══════════════

def transcribe(path: str | Path, pack_id: str | None = None,
               language: str = "auto", textnorm: str = "withitn") -> dict[str, Any]:
    """转写音频文件 → {text, duration_s, model_pack_id}。

    同步、CPU 密集——调用方（app.py 端点）必须放线程池（run_in_executor），
    不得直接在事件循环里调。错误语义：PackUnavailableError（包不可用）/
    AudioDecodeError（音频问题）/ ValueError（参数问题）。
    """
    import numpy as np
    pid = resolve_asr_pack(pack_id)
    if language not in _LANG_IDS:
        raise ValueError(f"language 必须是 {'/'.join(_LANG_IDS)} 之一，得到 {language!r}")
    if textnorm not in _TEXTNORM_IDS:
        raise ValueError(f"textnorm 必须是 {'/'.join(_TEXTNORM_IDS)} 之一，得到 {textnorm!r}")
    session, tokens, cmvn, sr = _ensure_loaded(pid)
    waveform, duration_s = load_audio(Path(path), target_sr=sr)
    feat = fbank(waveform, fs=sr)
    if feat.shape[0] == 0:
        raise AudioDecodeError("音频过短（不足一帧 25ms），无法转写")
    feat = apply_cmvn(apply_lfr(feat), cmvn)
    speech = feat[None, :, :].astype(np.float32)                  # (1, T_lfr, 560)
    feed = {
        "speech": speech,
        "speech_lengths": np.array([speech.shape[1]], dtype=np.int32),
        "language": np.array([_LANG_IDS[language]], dtype=np.int32),
        "textnorm": np.array([_TEXTNORM_IDS[textnorm]], dtype=np.int32),
    }
    # ORT session.run 串行化：转写是用户节奏的低频请求，串行足够且规避并发不确定性
    with _lock:
        outputs = session.run(["ctc_logits", "encoder_out_lens"], feed)
    ctc_logits, out_lens = outputs[0], outputs[1]
    text = _ctc_greedy_decode(ctc_logits[0], int(out_lens[0]), tokens)
    text = rich_transcription_postprocess(text)
    return {"text": text, "duration_s": round(duration_s, 2), "model_pack_id": pid}
