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
"""0.4.29（P3）ASR 链路专项：parser 音频分支 / manifest sample_rate / asr_driver /
POST /api/asr/transcribe 端点。

隔离：顶部先钉 VETARAI_MODEL_PACKS_DIR + VETARAI_DATA_ROOT 到临时目录，
再桩 config.store.get_config_path（test_model_packs.py 同款）。

真实转写用例 skip-if-absent：仅当注入 VETARAI_ASR_TEST_PACK_DIR（含
model_quant.onnx/am.mvn/tokens.json 的 SenseVoiceSmall 包目录）与
VETARAI_ASR_TEST_WAV（真实语音 wav）才跑；本机/CI 常态跳过（打印 SKIP 不失败）。

数值正确性已在开发期对照真值源验证（非本套件职责，此处只留形状/语义回归）：
  fbank 对 kaldi-native-fbank 1.22.3：16123 采样随机波形，99 帧，max|Δ|=1.2e-4
  （float32 舍入级）；apply_lfr 对 funasr_onnx 0.4.3 WavFrontend.apply_lfr：逐元素全等。

变异机制（MUTATE=1|2|3 python -m sidecar.model_packs.test_asr_chain）：
变异模式下必须出现 FAIL；0 FAIL = 断言空转，需加强（不是"通过"）。
| 变异 | 撤掉的修复 | 应失败的断言 |
|---|---|---|
| 1 | parser.py 音频分支（audio 退回 binary） | A1a/A1b |
| 2 | asr_driver resolve_asr_pack 的启用态过滤 | C1c/C1d |
| 3 | app.py 端点的扩展名校验 | D1d |
"""
import asyncio
import json
import os
import sys
import tempfile
import wave
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

# ── 隔离（必须先于一切 sidecar 导入）──
TMP = Path(tempfile.mkdtemp(prefix="asr_test_"))
os.environ["VETARAI_MODEL_PACKS_DIR"] = str(TMP / "packs")
os.environ.setdefault("VETARAI_DATA_ROOT", str(TMP / "data"))

import sidecar.config.store as _cs  # noqa: E402
_cs.get_config_path = lambda: TMP / "config.json"
_cs._MEM = {}

import sidecar.model_packs.manifest as mpm  # noqa: E402
import sidecar.model_packs.store as mps  # noqa: E402
import sidecar.model_packs.asr_driver as asr  # noqa: E402
from sidecar.attachments import parser as att_parser  # noqa: E402

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


# ══════════ 变异机制（test_model_packs.py 同款：内存备份 + finally 还原 + reload）══════════
MUTATE = int(os.environ.get("MUTATE", "0"))
_BACKUP: dict[str, str] = {}


def _apply_mutation() -> None:
    if not MUTATE:
        return
    import importlib
    if MUTATE == 1:
        s = Path(att_parser.__file__).read_text(encoding="utf-8")
        _BACKUP["parser"] = s
        patched = s.replace(
            '    if ext in AUDIO_EXTS:\n        return None, "audio"',
            '    if ext in AUDIO_EXTS:\n        return None, "binary"  # MUTATED-1')
        assert patched != s, "变异 1 未命中 parser.py 源码，测试无效"
        Path(att_parser.__file__).write_text(patched, encoding="utf-8")
        importlib.reload(att_parser)
    elif MUTATE == 2:
        s = Path(asr.__file__).read_text(encoding="utf-8")
        _BACKUP["asr"] = s
        patched = s.replace(
            'candidates = sorted(pid for pid, e in reg.items()\n'
            '                        if e.get("task") == "asr" and e.get("status") == "installed")',
            'candidates = sorted(pid for pid, e in reg.items()\n'
            '                        if e.get("task") == "asr")  # MUTATED-2')
        assert patched != s, "变异 2 未命中 asr_driver.py 源码，测试无效"
        Path(asr.__file__).write_text(patched, encoding="utf-8")
        importlib.reload(asr)
    elif MUTATE == 3:
        from sidecar import app as _appmod
        s = Path(_appmod.__file__).read_text(encoding="utf-8")
        _BACKUP["app"] = s
        patched = s.replace("if ext not in _AUDIO_EXTS:",
                            "if False and ext not in _AUDIO_EXTS:  # MUTATED-3")
        assert patched != s, "变异 3 未命中 app.py 源码，测试无效"
        Path(_appmod.__file__).write_text(patched, encoding="utf-8")
        importlib.reload(_appmod)


def _restore() -> None:
    """还原被变异的源文件（必须在 finally：用例 sys.exit 会抛 SystemExit）。"""
    if not MUTATE or not _BACKUP:
        return
    import importlib
    try:
        for key, mod in (("parser", att_parser), ("asr", asr)):
            if key in _BACKUP:
                Path(mod.__file__).write_text(_BACKUP[key], encoding="utf-8")
        if "app" in _BACKUP:
            from sidecar import app as _appmod
            Path(_appmod.__file__).write_text(_BACKUP["app"], encoding="utf-8")
    finally:
        _BACKUP.clear()
        if MUTATE == 1:
            importlib.reload(att_parser)
        if MUTATE == 2:
            importlib.reload(asr)
        if MUTATE == 3:
            from sidecar import app as _appmod
            importlib.reload(_appmod)


# ══════════ 测试数据构造 ═══════════

def _write_wav(path: Path, seconds: float = 1.0, sr: int = 16000) -> Path:
    """stdlib wave 造 PCM16 单声道正弦 WAV（真实解码链路用）。"""
    import math
    import struct
    n = int(seconds * sr)
    frames = b"".join(
        struct.pack("<h", int(12000 * math.sin(2 * math.pi * 440 * i / sr)))
        for i in range(n))
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(frames)
    return path


def _register_asr_pack(pack_id: str = "sensevoice-test", *, enabled: bool = True,
                       with_files: bool = True) -> None:
    """登记一个 ASR 包到注册表（with_files=True 时在磁盘造齐三件套占位文件）。"""
    pack = {
        "version": "1.0.0", "task": "asr", "format": "onnx", "driver": "onnxruntime",
        "files": [
            {"path": "model_quant.onnx", "size_bytes": 3, "sha256": "0" * 64},
            {"path": "am.mvn", "size_bytes": 3, "sha256": "0" * 64},
            {"path": "tokens.json", "size_bytes": 3, "sha256": "0" * 64},
        ],
    }
    mps.register_pack(pack_id, pack)
    if with_files:
        d = mps.pack_dir(pack_id)
        d.mkdir(parents=True, exist_ok=True)
        (d / "model_quant.onnx").write_bytes(b"onnx")
        (d / "am.mvn").write_bytes(b"mvn")
        (d / "tokens.json").write_bytes(b"tok")
    if not enabled:
        mps.set_enabled(pack_id, False)


# ══════════ A. parser 音频分支 ══════════

def test_parser_branch():
    check("A0a AUDIO_EXTS 入 SUPPORTED_EXTS",
          att_parser.AUDIO_EXTS <= att_parser.SUPPORTED_EXTS)
    check("A0b 音频与文本/图片族不相交",
          not (att_parser.AUDIO_EXTS & att_parser.TEXT_EXTS)
          and not (att_parser.AUDIO_EXTS & att_parser.IMAGE_EXTS))
    t, k = att_parser.parse_attachment("meeting.WAV", b"RIFF....")
    check("A1a wav → (None, audio)（大小写不敏感）", t is None and k == "audio", f"{t!r} {k!r}")
    t, k = att_parser.parse_attachment("memo.m4a", b"....")
    check("A1b m4a → (None, audio)", t is None and k == "audio", f"{t!r} {k!r}")
    t, k = att_parser.parse_attachment("clip.webm", b"....")
    check("A1c webm → (None, audio)（收录但解码端会如实报错）", t is None and k == "audio")
    t, k = att_parser.parse_attachment("pack.zip", b"....")
    check("A2 zip 仍 → binary（回归不破）", t is None and k == "binary", f"{t!r} {k!r}")
    t, k = att_parser.parse_attachment("doc.txt", b"hello")
    check("A3 txt 仍 → text（回归不破）", t == "hello" and k == "text", f"{t!r} {k!r}")


# ══════════ B. manifest sample_rate 可选键 ══════════

def _mk_asr_pack(**over):
    pack = {
        "pack_id": "sv-small", "name": "SenseVoiceSmall", "task": "asr",
        "format": "onnx", "driver": "onnxruntime", "version": "1.0.0",
        "description": "", "size_bytes": 6, "min_app_version": "",
        "homepage": "", "license": "",
        "files": [
            {"path": "model_quant.onnx", "size_bytes": 2, "sha256": "0" * 64,
             "sources": ["file:///x/model_quant.onnx"]},
            {"path": "am.mvn", "size_bytes": 2, "sha256": "1" * 64,
             "sources": ["file:///x/am.mvn"]},
            {"path": "tokens.json", "size_bytes": 2, "sha256": "2" * 64,
             "sources": ["file:///x/tokens.json"]},
        ],
    }
    pack.update(over)
    return pack


def test_manifest_sample_rate():
    check("B1 缺省不写 → 合法", mpm.validate_pack(_mk_asr_pack()) == [])
    check("B2 sample_rate=16000 → 合法",
          mpm.validate_pack(_mk_asr_pack(sample_rate=16000)) == [])
    errs = mpm.validate_pack(_mk_asr_pack(sample_rate="16000"))
    check("B3 sample_rate 字符串 → 拒", any("sample_rate" in e for e in errs), str(errs))
    errs = mpm.validate_pack(_mk_asr_pack(sample_rate=0))
    check("B4 sample_rate=0 → 拒", any("sample_rate" in e for e in errs), str(errs))
    errs = mpm.validate_pack(_mk_asr_pack(sample_rate=True))
    check("B5 sample_rate=True → 拒（bool 不是正整数）",
          any("sample_rate" in e for e in errs), str(errs))
    errs = mpm.validate_pack(_mk_asr_pack(task="chat"))
    check("B6 chat 包带 asr 文件也合法（task 与能力键不耦合）", errs == [], str(errs))


# ══════════ C. asr_driver 单元（无模型，mock 注入）══════════

def test_driver_resolve():
    for p in mps.list_installed():
        mps.remove_pack(p["pack_id"])
    try:
        asr.resolve_asr_pack()
        check("C1a 空注册表 → PackUnavailableError", False, "未抛错")
    except asr.PackUnavailableError as e:
        check("C1a 空注册表 → PackUnavailableError", "模型包" in str(e), str(e))
    # 只有 chat 包
    mps.register_pack("chat-only", {"version": "1", "task": "chat", "format": "gguf",
                                    "driver": "llamacpp", "files": []})
    try:
        asr.resolve_asr_pack()
        check("C1b 只有 chat 包 → 拒", False, "未抛错")
    except asr.PackUnavailableError:
        check("C1b 只有 chat 包 → 拒", True)
    # 禁用中的 asr 包不得入选
    _register_asr_pack("sv-disabled", enabled=False)
    try:
        asr.resolve_asr_pack()
        check("C1c 禁用的 asr 包 → 拒（启用态过滤在）", False, "未抛错")
    except asr.PackUnavailableError as e:
        check("C1c 禁用的 asr 包 → 拒（启用态过滤在）", "禁用" not in str(e), str(e))
    _register_asr_pack("sv-enabled")
    check("C1d 启用中的 asr 包被自动选中", asr.resolve_asr_pack() == "sv-enabled")
    check("C1e 显式指定启用包", asr.resolve_asr_pack("sv-enabled") == "sv-enabled")
    try:
        asr.resolve_asr_pack("chat-only")
        check("C1f 指定 chat 包 → 拒（task 校验）", False, "未抛错")
    except asr.PackUnavailableError as e:
        check("C1f 指定 chat 包 → 拒（task 校验）", "task" in str(e), str(e))
    try:
        asr.resolve_asr_pack("sv-disabled")
        check("C1g 指定禁用包 → 拒", False, "未抛错")
    except asr.PackUnavailableError as e:
        check("C1g 指定禁用包 → 拒", "禁用" in str(e), str(e))


def test_driver_pack_files():
    onnx, mvn, tok = asr._pack_files("sv-enabled")
    check("C2a 三件套路径解析", onnx.name == "model_quant.onnx"
          and mvn.name == "am.mvn" and tok.name == "tokens.json")
    mps.register_pack("sv-missing", {"version": "1", "task": "asr", "format": "onnx",
                                     "driver": "onnxruntime",
                                     "files": [{"path": "model_quant.onnx", "size_bytes": 1,
                                                "sha256": "0" * 64}]})
    d = mps.pack_dir("sv-missing")
    d.mkdir(parents=True, exist_ok=True)
    (d / "model_quant.onnx").write_bytes(b"x")
    try:
        asr._pack_files("sv-missing")
        check("C2b 清单缺 am.mvn/tokens.json → 拒", False, "未抛错")
    except asr.PackUnavailableError as e:
        check("C2b 清单缺 am.mvn/tokens.json → 拒", "tokens.json" in str(e), str(e))
    # 磁盘缺文件
    mps.register_pack("sv-disk-missing", {"version": "1", "task": "asr", "format": "onnx",
                                          "driver": "onnxruntime",
                                          "files": [
                                              {"path": "model_quant.onnx", "size_bytes": 1, "sha256": "0" * 64},
                                              {"path": "am.mvn", "size_bytes": 1, "sha256": "1" * 64},
                                              {"path": "tokens.json", "size_bytes": 1, "sha256": "2" * 64},
                                          ]})
    try:
        asr._pack_files("sv-disk-missing")
        check("C2c 磁盘缺文件 → 拒", False, "未抛错")
    except asr.PackUnavailableError as e:
        check("C2c 磁盘缺文件 → 拒", "缺失" in str(e), str(e))


def test_driver_features():
    import numpy as np
    sr = 16000
    t = np.arange(sr, dtype=np.float64) / sr
    wave16k = (0.2 * np.sin(2 * np.pi * 440 * t)).astype(np.float32)
    f = asr.fbank(wave16k, fs=sr)
    expect_frames = 1 + (sr - 400) // 160
    check("C3a fbank 帧数=1+(N-400)//160（snip_edges）",
          f.shape == (expect_frames, 80) and f.dtype == np.float32, str(f.shape))
    check("C3b log-mel 值域有限（无 NaN/Inf）",
          bool(np.isfinite(f).all()))
    short = np.zeros(200, dtype=np.float32)   # 不足一帧（<400 采样）
    f2 = asr.fbank(short, fs=sr)
    check("C3c 短于 25ms → 0 帧", f2.shape == (0, 80), str(f2.shape))

    # LFR 精确语义（开发期已对 funasr_onnx 全等，此处留固定回归锚点）
    x = np.arange(31 * 2, dtype=np.float32).reshape(31, 2)
    lf = asr.apply_lfr(x)
    check("C4a LFR 输出帧数 ceil(31/6)=6", lf.shape == (6, 14), str(lf.shape))
    # 首帧 = [f0,f0,f0,f0,f1,f2,f3] 拼接（左端首帧复制 (7-1)//2=3 行）
    first = lf[0].reshape(7, 2)
    check("C4b LFR 首帧左填充=首行复制×3",
          bool((first[0] == x[0]).all() and (first[1] == x[0]).all()
               and (first[2] == x[0]).all() and (first[3] == x[0]).all()
               and (first[4] == x[1]).all()))
    cmvn = np.zeros((2, 14)); cmvn[0, :] = -1.0; cmvn[1, :] = 2.0
    c = asr.apply_cmvn(lf, cmvn)
    check("C4c CMVN (x+mean)*var 广播语义",
          bool(np.allclose(c[0], (lf[0] - 1.0) * 2.0)))

    # am.mvn 解析（kaldi 文本格式）
    mvn = TMP / "am_test.mvn"
    mvn.write_text("<Nnet>\n<AddShift> 2 3\n<LearnRateCoef> 0 -0.1 -0.2 -0.3 ]\n"
                   "<Rescale> 2 3\n<LearnRateCoef> 0 0.5 0.6 0.7 ]\n</Nnet>\n",
                   encoding="utf-8")
    cm = asr._load_cmvn(mvn)
    # [3:-1] 语义与官方 load_cmvn 逐字一致（开发期已对照：同一输入两处输出全等）——
    # 即跳过 <LearnRateCoef> 标记、学习率列与首列，取到倒数第二列。
    check("C4d am.mvn 解析（AddShift/Rescale，官方 load_cmvn 同款 [3:-1]）",
          cm.shape == (2, 2) and abs(cm[0, 0] + 0.2) < 1e-9 and abs(cm[1, 1] - 0.7) < 1e-9,
          str(cm))


def test_driver_decode_and_postprocess():
    import numpy as np
    # CTC greedy：去连续重复 + 去 blank(0) + 查表 + ▁→空格
    tokens = ["<unk>", "<s>", "</s>", "你", "好", "▁world", "▁", "。", "<|zh|>"]
    V = len(tokens)
    seq = [0, 3, 3, 3, 4, 0, 0, 5, 5, 7, 0]
    T = len(seq)
    logits = np.full((1, T, V), -10.0, dtype=np.float32)
    for i, t in enumerate(seq):
        logits[0, i, t] = 10.0
    text = asr._ctc_greedy_decode(logits[0], T, tokens)
    check("C5a greedy 去重去 blank 拼接", text == "你好 world。", repr(text))
    logits2 = np.full((1, 5, V), -10.0, dtype=np.float32)
    logits2[0, :, 0] = 10.0   # 全 blank
    check("C5b 全 blank → 空串", asr._ctc_greedy_decode(logits2[0], 5, tokens) == "")

    s = asr.rich_transcription_postprocess("<|zh|>今天天气不错<|HAPPY|>")
    check("C6a 语种标记剥离", "<|" not in s and "今天天气不错" in s, repr(s))
    check("C6b 情感标记映射为用户可见文案（emoji 属 UI 文案）",
          s.endswith("😊"), repr(s))
    s2 = asr.rich_transcription_postprocess("<|en|>▁Hello ▁world")
    check("C6c 英文段清理（▁ 在 decode 层已转空格则原样保留）",
          "Hello" in s2 and "<|" not in s2, repr(s2))


def test_driver_transcribe_mocked():
    """transcribe 全链路：真 resolve + 真特征链 + 假 session/假 load_audio。"""
    import numpy as np
    captured: dict = {}

    class _FakeSession:
        def run(self, out_names, feed):
            captured["feed"] = feed
            captured["out_names"] = out_names
            T_lfr = int(feed["speech"].shape[1])
            V = 6
            logits = np.full((1, max(T_lfr, 1), V), -10.0, dtype=np.float32)
            # 前 3 帧输出 token 3/4/5（"你","好","。"），其余 blank
            for i, t in enumerate([3, 4, 5]):
                if i < logits.shape[1]:
                    logits[0, i, t] = 10.0
            return [logits, np.array([min(T_lfr, 3)], dtype=np.int64)]

    tokens = ["<unk>", "<s>", "</s>", "你", "好", "。"]
    cmvn = np.zeros((2, 560))
    cmvn[1, :] = 1.0
    orig_ensure, orig_load = asr._ensure_loaded, asr.load_audio
    asr._ensure_loaded = lambda pid: (_FakeSession(), tokens, cmvn, 16000)
    asr.load_audio = lambda p, target_sr=16000: (
        np.zeros(16000, dtype=np.float32), 1.0)   # 1s 静音波形
    try:
        out = asr.transcribe("/fake/a.wav", pack_id="sv-enabled", language="zh")
        check("C7a 全链路返回 text/duration/model_pack_id",
              out["text"] == "你好。" and out["duration_s"] == 1.0
              and out["model_pack_id"] == "sv-enabled", repr(out))
        feed = captured["feed"]
        check("C7b speech 形状 (1,T,560) 且 lengths/language/textnorm 码正确",
              feed["speech"].shape[2] == 560 and feed["speech"].dtype == np.float32
              and int(feed["language"][0]) == 3 and int(feed["textnorm"][0]) == 14
              and feed["speech_lengths"].dtype == np.int32,
              {k: str(v.shape) + str(v.dtype) for k, v in feed.items()})
        check("C7c 输出按名取 ctc_logits/encoder_out_lens",
              captured["out_names"] == ["ctc_logits", "encoder_out_lens"])
        try:
            asr.transcribe("/fake/a.wav", language="fr")
            check("C7d 非法 language → ValueError", False, "未抛错")
        except ValueError:
            check("C7d 非法 language → ValueError", True)
    finally:
        asr._ensure_loaded, asr.load_audio = orig_ensure, orig_load


def test_driver_audio_decode():
    """解码链路（macOS afconvert 实转；非 macOS 仅 WAV 直读）。"""
    import platform
    wav = _write_wav(TMP / "tone.wav", seconds=1.0)
    arr, dur = asr.load_audio(wav, target_sr=16000)
    import numpy as _np
    check("C8a wav 解码：16k 单声道 float32，时长≈1s",
          arr.dtype == _np.float32 and abs(dur - 1.0) < 0.01, f"{arr.dtype} {dur}")
    if platform.system() == "Darwin":
        # afconvert 实转 m4a 不易造（需编码器）；改测 8k wav 重采样到 16k（afconvert 路径）
        wav8 = _write_wav(TMP / "tone8k.wav", seconds=0.5, sr=8000)
        arr2, dur2 = asr.load_audio(wav8, target_sr=16000)
        check("C8b afconvert 重采样 8k→16k（时长保持）",
              abs(dur2 - 0.5) < 0.01 and abs(len(arr2) - 8000) < 40, f"{dur2} {len(arr2)}")
        bad = TMP / "bad.m4a"
        bad.write_bytes(b"not audio at all")
        try:
            asr.load_audio(bad, target_sr=16000)
            check("C8c 损坏音频 → AudioDecodeError（不静默）", False, "未抛错")
        except asr.AudioDecodeError as e:
            check("C8c 损坏音频 → AudioDecodeError（不静默）", "失败" in str(e), str(e))
    else:
        check("C8b/C8c 非 macOS 跳过（afconvert 链路不适用）", True)


def test_real_model_skip_if_absent():
    """真实 SenseVoiceSmall 转写（skip-if-absent：注入两个环境变量才跑）。

    VETARAI_ASR_TEST_PACK_DIR = 含 model_quant.onnx/am.mvn/tokens.json 的包目录
    VETARAI_ASR_TEST_WAV      = 真实语音 wav（16k 任意内容）
    """
    pack_dir = os.environ.get("VETARAI_ASR_TEST_PACK_DIR", "").strip()
    wav_path = os.environ.get("VETARAI_ASR_TEST_WAV", "").strip()
    if not pack_dir or not wav_path:
        print("SKIP  真实模型转写（需 VETARAI_ASR_TEST_PACK_DIR + VETARAI_ASR_TEST_WAV）")
        return
    pd = Path(pack_dir)
    pid = "sensevoice-real"
    files = []
    for name, sha_i in (("model_quant.onnx", "0"), ("am.mvn", "1"), ("tokens.json", "2")):
        fp = pd / name
        if not fp.is_file():
            print(f"SKIP  包目录缺 {name}：{pd}")
            return
        files.append({"path": name, "size_bytes": fp.stat().st_size,
                      "sha256": sha_i * 64})
    # 把真实包目录登记进注册表：符号链接进测试安装根（注册表语义要求包在 packs_root 下）
    target = mps.pack_dir(pid)
    target.mkdir(parents=True, exist_ok=True)
    for name in ("model_quant.onnx", "am.mvn", "tokens.json"):
        link = target / name
        if not link.exists():
            os.symlink(pd / name, link)
    mps.register_pack(pid, {"version": "1.0.0", "task": "asr", "format": "onnx",
                            "driver": "onnxruntime", "files": files})
    asr.unload()  # 防前序用例残留单例
    out = asr.transcribe(wav_path, pack_id=pid)
    print(f"真实转写结果：{out['text']!r}（{out['duration_s']}s）")
    check("R1 真实转写返回非空文本", bool(out["text"].strip()), repr(out))


# ══════════ D. 端点层（TestClient）══════════

def test_endpoints():
    from sidecar import app as appmod
    from fastapi.testclient import TestClient

    # 桩 get_config 并入完整 DEFAULT_CONFIG（startup 钩子要读 ollama_base_url，实测踩过）
    appmod.get_config = lambda: {
        **_cs.DEFAULT_CONFIG,
        "network_switch": "auto", "egress_proxy_required": [],
    }
    with TestClient(appmod.app) as client:
        _run_endpoint_checks(client, appmod)


def _run_endpoint_checks(client, appmod):
    import threading
    wav = _write_wav(TMP / "upload.wav", seconds=0.5)

    r = client.post("/api/asr/transcribe", json={"path": ""})
    check("D1a 空 path → 400", r.status_code == 400, r.text[:120])
    r = client.post("/api/asr/transcribe", json={"path": "relative/x.wav"})
    check("D1b 相对路径 → 400", r.status_code == 400, r.text[:120])
    r = client.post("/api/asr/transcribe", json={"path": "/nonexistent/x.wav"})
    check("D1c 不存在 → 400", r.status_code == 400, r.text[:120])
    txt = TMP / "note.txt"
    txt.write_text("hello", encoding="utf-8")
    r = client.post("/api/asr/transcribe", json={"path": str(txt)})
    check("D1d 非音频扩展名 → 400（扩展名校验在）", r.status_code == 400, r.text[:200])
    big = TMP / "big.wav"
    big.write_bytes(b"x" * 128)
    orig_max = appmod._ASR_MAX_BYTES
    appmod._ASR_MAX_BYTES = 64
    try:
        r = client.post("/api/asr/transcribe", json={"path": str(big)})
        check("D1e 超大小上限 → 400", r.status_code == 400 and "上限" in r.text, r.text[:160])
    finally:
        appmod._ASR_MAX_BYTES = orig_max
    r = client.post("/api/asr/transcribe",
                    json={"path": str(wav), "pack_id": "Bad ID!!"})
    check("D1f 非法 pack_id → 400", r.status_code == 400, r.text[:120])

    # 无可用 ASR 包 → 409（先清空注册表里的 asr 包）
    for p in mps.list_installed():
        if p["task"] == "asr":
            mps.remove_pack(p["pack_id"])
    r = client.post("/api/asr/transcribe", json={"path": str(wav)})
    check("D2 未装 ASR 包 → 409 中文指引", r.status_code == 409 and "模型包" in r.text,
          f"{r.status_code} {r.text[:160]}")

    # 成功路径：注册 asr 包 + mock 驱动 transcribe，验证线程池与落盘复制
    _register_asr_pack("sv-e2e")
    called: dict = {}
    orig_transcribe = asr.transcribe

    def _fake_transcribe(p, pack_id=None, language="auto"):
        called["thread_is_main"] = threading.current_thread() is threading.main_thread()
        called["path"] = str(p)
        called["language"] = language
        return {"text": "开会纪要探针：周三下午三点评审", "duration_s": 0.5,
                "model_pack_id": pack_id or "sv-e2e"}

    asr.transcribe = _fake_transcribe
    try:
        r = client.post("/api/asr/transcribe",
                        json={"path": str(wav), "project_id": "p1", "session_id": "s1",
                              "language": "zh"})
        check("D3a 成功 → 200 + text/duration_s/model_pack_id",
              r.status_code == 200 and r.json()["text"].startswith("开会纪要探针")
              and r.json()["duration_s"] == 0.5 and r.json()["model_pack_id"] == "sv-e2e",
              r.text[:200])
        sp = r.json().get("saved_path")
        check("D3b 给了归属 → 原件复制进会话附件目录并回传 saved_path",
              bool(sp) and Path(sp).is_file()
              and Path(sp).read_bytes() == wav.read_bytes(), repr(sp))
        check("D3c 转写走线程池（不在主线程跑 CPU 密集活）",
              called.get("thread_is_main") is False, repr(called))
        check("D3d language 透传驱动", called.get("language") == "zh")

        # 不带归属：只转写不落盘
        r = client.post("/api/asr/transcribe", json={"path": str(wav)})
        check("D4 无归属 → saved_path=None 且仍 200",
              r.status_code == 200 and r.json()["saved_path"] is None, r.text[:160])

        # 解码失败 → 422
        def _raise_decode(p, pack_id=None, language="auto"):
            raise asr.AudioDecodeError("音频解码失败：该格式不受支持")
        asr.transcribe = _raise_decode
        r = client.post("/api/asr/transcribe", json={"path": str(wav)})
        check("D5 解码失败 → 422 中文明细", r.status_code == 422 and "解码" in r.text,
              f"{r.status_code} {r.text[:160]}")

        # 包不可用 → 409
        def _raise_pack(p, pack_id=None, language="auto"):
            raise asr.PackUnavailableError("尚未安装语音识别模型包")
        asr.transcribe = _raise_pack
        r = client.post("/api/asr/transcribe", json={"path": str(wav)})
        check("D6 包不可用 → 409", r.status_code == 409, f"{r.status_code}")
    finally:
        asr.transcribe = orig_transcribe


# ══════════ main ══════════

def main():
    test_parser_branch()
    test_manifest_sample_rate()
    test_driver_resolve()
    test_driver_pack_files()
    test_driver_features()
    test_driver_decode_and_postprocess()
    test_driver_transcribe_mocked()
    test_driver_audio_decode()
    test_real_model_skip_if_absent()
    test_endpoints()

    print(f"\n===== 0.4.29-P3 ASR 链路专项: PASS={PASS} FAIL={FAIL} =====")
    if MUTATE:
        # 变异模式下必须出现 FAIL；0 FAIL = 断言空转（测试对该修复无效）
        if FAIL == 0:
            print(f"变异 {MUTATE} 未被抓住 —— 本测试对该修复无效，断言需加强")
            sys.exit(1)
        print(f"变异 {MUTATE} 已命中（FAIL={FAIL}，符合预期）")
        return
    if FAILURES:
        print("FAILED:", ", ".join(FAILURES))
        sys.exit(1)


if __name__ == "__main__":
    _apply_mutation()
    try:
        main()
    finally:
        _restore()
