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
"""第 2 批（0.4.15）A1-A4：推理参数与超时的统一取值层。

为什么单独成模块（而不是在 connector 里散着写）：
  A1（超时可配）/ A2（num_ctx）/ A4（temperature 等）三项都要"从 config 取值 → 注入请求"，
  且 **payload 构造点有 4 处**（ollama connector 的 chat / chat_stream，
  openai_compat 的 chat / chat_stream）、**超时常量被跨模块复用**
  （`openai_compat.py:39` 直接 import connector 的 CONNECT_TIMEOUT / STREAM_READ_TIMEOUT）。
  散着写必然出现"改了一处漏了三处"，故收敛到本模块作为唯一取值口径。

⛔ 两条硬性约束（违反任一条都会引入静默回归）：
  1. **未配置时必须完全不注入**。用户没设任何 model_options / 超时保持默认时，
     payload 里不得出现 `options` 键、超时必须等于原常量值 → 行为与改造前**逐字节一致**。
     否则现有全部测试与真机行为都会漂移，且难以定位。
  2. **两个后端的参数名不同，必须映射**（A4 的坑）：
     Ollama 用 `num_ctx` / `repeat_penalty` / `num_predict`；
     OpenAI 兼容端用 `frequency_penalty` / `max_tokens`，且**没有 num_ctx**
     （上下文长度由服务端自行决定，传了会被拒或忽略）。
     直接透传会导致 OpenAI 兼容后端 400 或静默忽略。

⚠️ num_ctx 与性能（B7 联动）：num_ctx 越大，prefill（首 token 前的提示词编码）越慢，
  30B/35B 本地模型上尤其明显。故本模块**不设 num_ctx 默认值**——不传即沿用模型自身默认，
  由用户在设置页显式决定，并在 UI 给出该权衡提示。
"""
from __future__ import annotations

from typing import Any

# ── A1：超时的原硬编码值（作为 config 未配置时的兜底，保证向后兼容）──
# ⛔ 这些常量**保留不删**：connector 的 `_client(reading=..., connect=...)` 默认参数
# 与多处测试仍引用它们；本模块只负责"config 有值则覆盖，无值则回落常量"。
DEFAULT_CONNECT_TIMEOUT = 10.0
DEFAULT_READING_TIMEOUT = 300.0
DEFAULT_STREAM_READ_TIMEOUT = 1800.0

# 超时配置键 → (兜底常量, 合法范围)。0 表示"不单独设置，用兜底值"。
_TIMEOUT_KEYS: dict[str, tuple[float, tuple[float, float]]] = {
    "timeout_connect": (DEFAULT_CONNECT_TIMEOUT, (1.0, 600.0)),
    "timeout_reading": (DEFAULT_READING_TIMEOUT, (10.0, 7200.0)),
    "timeout_stream_reading": (DEFAULT_STREAM_READ_TIMEOUT, (30.0, 21600.0)),
}

# ── A2/A4：推理参数的规范名 → 各后端实际参数名 ──
# 规范名用 Ollama 风格（用户主要用 Ollama，且 num_ctx 是本项目最关心的项）。
# 值为 None 表示"该后端不支持此参数"→ 注入时静默丢弃（不报错、不透传）。
_PARAM_MAP: dict[str, dict[str, str | None]] = {
    "ollama": {
        "num_ctx": "num_ctx",
        "temperature": "temperature",
        "top_p": "top_p",
        "top_k": "top_k",
        "repeat_penalty": "repeat_penalty",
        "num_predict": "num_predict",
        "seed": "seed",
        "stop": "stop",
    },
    "openai_compatible": {
        "num_ctx": None,                      # ⛔ OpenAI 兼容端无此参数
        "temperature": "temperature",
        "top_p": "top_p",
        "top_k": None,                        # 非 OpenAI 标准参数
        "repeat_penalty": "frequency_penalty",  # ⚠️ 参数名不同
        "num_predict": "max_tokens",            # ⚠️ 参数名不同
        "seed": "seed",
        "stop": "stop",
    },
}

# 各规范参数的合法范围（校验用；None 表示不校验数值范围）
_PARAM_RANGE: dict[str, tuple[float, float] | None] = {
    "num_ctx": (256, 1_048_576),
    "temperature": (0.0, 2.0),
    "top_p": (0.0, 1.0),
    "top_k": (1, 1000),
    "repeat_penalty": (0.0, 3.0),
    "num_predict": (-2, 1_048_576),   # Ollama 语义：-1=无限，-2=填满上下文
    "seed": None,
    "stop": None,                     # 字符串数组，不做数值校验
}


def _cfg() -> dict[str, Any]:
    from sidecar.config import get_config
    return get_config()


def _to_float(v: Any) -> float | None:
    """宽松转 float：bool 拒绝（True 会变 1.0，是常见误配），非数值返回 None。"""
    if isinstance(v, bool) or v is None:
        return None
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    if f != f or f in (float("inf"), float("-inf")):   # NaN / inf
        return None
    return f


def timeout_connect() -> float:
    """A1：连接超时（秒）。config 未配/非法 → 回落 DEFAULT_CONNECT_TIMEOUT。"""
    return _read_timeout("timeout_connect")


def timeout_reading() -> float:
    """A1：非流式读超时（秒）。"""
    return _read_timeout("timeout_reading")


def timeout_stream_reading() -> float:
    """A1：流式读超时（秒）。⚠️ 被 openai_compat 复用，改一处两边都生效。"""
    return _read_timeout("timeout_stream_reading")


def _read_timeout(key: str) -> float:
    fallback, (lo, hi) = _TIMEOUT_KEYS[key]
    raw = _cfg().get(key)
    f = _to_float(raw)
    if f is None or f <= 0:
        return fallback          # 未配置 / 0 / 非法 → 用原硬编码值（向后兼容）
    return min(max(f, lo), hi)   # 夹到合法范围，防止误配成天文数字


def model_options(model: str, backend: str | None = None) -> dict[str, Any]:
    """A2/A4：取该模型应注入的推理参数，并按后端映射成实际参数名。

    返回**可直接展开进 payload 的 dict**：
      Ollama          → {"options": {...}}     （空则返回 {}，即完全不注入）
      OpenAI 兼容     → {...}                   （参数是顶层字段，非嵌套 options）

    ⛔ 未配置时返回空 dict —— 调用方据此决定"要不要加这个键"，
      绝不能加一个空 `options: {}`，那会改变请求体（部分服务端会报 400）。
    """
    raw = _raw_model_options(model)
    if not raw:
        return {}
    be = (backend or str(_cfg().get("inference_backend", "ollama"))).strip().lower()
    mapping = _PARAM_MAP.get(be) or _PARAM_MAP["ollama"]

    out: dict[str, Any] = {}
    for canon, val in raw.items():
        target = mapping.get(canon, None)
        if target is None:
            continue                      # 该后端不支持此参数 → 静默丢弃
        coerced = _coerce(canon, val)
        if coerced is None:
            continue                      # 非法值 → 丢弃而非注入坏值
        out[target] = coerced

    if not out:
        return {}
    # Ollama 的参数必须包在 options 里；OpenAI 兼容端是顶层字段
    return {"options": out} if be == "ollama" else out


def configured_num_ctx(model: str) -> int | None:
    """A3：取用户为该模型显式配置的 num_ctx（未配置/非法 → None）。

    ⛔ 公开访问器，供 `/api/context/limit` 判断"指示器该按哪个上限算占比"。
    不让外部直接调私有的 `_raw_model_options`——那是实现细节，
    跨模块用私有函数会在重构时静默断裂。
    """
    v = _raw_model_options(model).get("num_ctx")
    if isinstance(v, bool):
        return None
    if isinstance(v, int) and v > 0:
        return v
    f = _to_float(v)
    if f is None or f <= 0:
        return None
    return int(f)


def _raw_model_options(model: str) -> dict[str, Any]:
    """从 config 的 model_options 里取该模型的原始配置（未做后端映射）。

    匹配规则：先精确匹配，再试 `模型名:tag` 去 tag 匹配。
    理由：Ollama 模型名常带 tag（`qwen3.8:latest`），而用户配置时通常写 `qwen3.8`；
    若只精确匹配，用户配的项会静默失效——这类"设了不生效"的缺陷极难排查。
    """
    mo = _cfg().get("model_options")
    if not isinstance(mo, dict) or not mo:
        return {}
    name = str(model or "").strip()
    if not name:
        return {}
    hit = mo.get(name)
    if not isinstance(hit, dict):
        base = name.split(":", 1)[0]
        hit = mo.get(base)
    return dict(hit) if isinstance(hit, dict) else {}


def _coerce(canon: str, val: Any) -> Any:
    """按参数类型收窄；非法 → None（调用方丢弃）。"""
    if canon == "stop":
        if isinstance(val, str):
            return [val] if val else None
        if isinstance(val, list) and all(isinstance(x, str) for x in val):
            return val or None
        return None
    if canon == "seed":
        if isinstance(val, bool):
            return None
        try:
            return int(val)
        except (TypeError, ValueError):
            return None
    if canon in ("num_ctx", "top_k", "num_predict"):
        f = _to_float(val)
        if f is None:
            return None
        iv = int(f)
        rng = _PARAM_RANGE.get(canon)
        if rng and not (rng[0] <= iv <= rng[1]):
            return None
        return iv
    # 其余为浮点参数（temperature / top_p / repeat_penalty）
    f = _to_float(val)
    if f is None:
        return None
    rng = _PARAM_RANGE.get(canon)
    if rng and not (rng[0] <= f <= rng[1]):
        return None
    return f


def validate_model_options(mo: Any) -> str | None:
    """配置校验（供 store._validate 调用）。返回错误信息，合法则 None。

    ⛔ 只校验**结构与类型**，不因"某后端不支持某参数"而报错——
      用户可能先配好参数再切后端，报错会让他无法保存；不支持的参数在注入时静默丢弃即可。
    """
    if mo is None:
        return None
    if not isinstance(mo, dict):
        return "model_options 必须是 {模型名: {参数名: 值}} 的字典"
    for model, params in mo.items():
        if not isinstance(model, str) or not model.strip():
            return "model_options 的键必须是非空模型名"
        if not isinstance(params, dict):
            return f"model_options[{model!r}] 必须是参数字典"
        for k, v in params.items():
            if k not in _PARAM_MAP["ollama"]:
                allowed = ", ".join(sorted(_PARAM_MAP["ollama"]))
                return (f"model_options[{model!r}] 含未知参数 {k!r}"
                        f"（可用：{allowed}）")
            if _coerce(k, v) is None:
                rng = _PARAM_RANGE.get(k)
                hint = f"，合法范围 {rng[0]}~{rng[1]}" if rng else "（须为字符串或字符串数组）"
                return f"model_options[{model!r}].{k} 的值非法：{v!r}{hint}"
    return None


def timeout_validate(cfg: dict[str, Any]) -> str | None:
    """超时配置校验（供 store._validate 调用）。返回错误信息，合法则 None。"""
    for key, (_fb, (lo, hi)) in _TIMEOUT_KEYS.items():
        raw = cfg.get(key)
        if raw is None:
            continue
        f = _to_float(raw)
        if f is None:
            return f"{key} 必须是数值（秒）"
        if f != 0 and not (lo <= f <= hi):
            return f"{key} 必须在 {lo:g}~{hi:g} 秒之间（0=用默认值 {lo and _fb:g}）"
    return None
