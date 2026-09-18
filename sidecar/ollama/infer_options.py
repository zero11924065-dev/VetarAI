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

两条硬性约束（违反任一条都会引入静默回归）：
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

import threading
from typing import Any

# ── A1：超时的原硬编码值（作为 config 未配置时的兜底，保证向后兼容）──
# 这些常量**保留不删**：connector 的 `_client(reading=..., connect=...)` 默认参数
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
# OpenAI 兼容端参数行独立成具名对象：0.4.29（P2）起 model_package（内置 llama-server，
# 走的正是 OpenAI 兼容协议）与 openai_compatible 共用同一份映射——两处各写一遍必然漂移。
# 模型包的上下文长度不在请求级注入：由驱动在启动时以 -c 传给 llama-server
# （manifest 可选键 context_length），请求级 num_ctx 依旧丢弃。
_OPENAI_COMPAT_MAP: dict[str, str | None] = {
    "num_ctx": None,                      # OpenAI 兼容端无此参数
    "temperature": "temperature",
    "top_p": "top_p",
    "top_k": None,                        # 非 OpenAI 标准参数
    "repeat_penalty": "frequency_penalty",  # ⚠️ 参数名不同
    "num_predict": "max_tokens",            # ⚠️ 参数名不同
    "seed": "seed",
    "stop": "stop",
}

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
    "openai_compatible": _OPENAI_COMPAT_MAP,
    "model_package": _OPENAI_COMPAT_MAP,   # 0.4.29（P2）：复用 openai_compatible 行
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

    未配置时返回空 dict —— 调用方据此决定"要不要加这个键"，
      绝不能加一个空 `options: {}`，那会改变请求体（部分服务端会报 400）。
    """
    raw = _raw_model_options(model)
    if not raw:
        return {}
    be = (backend or str(_cfg().get("inference_backend", "ollama"))).strip().lower()
    # 0.4.31（P0 懒加载，D1）：Ollama 后端、懒加载开启、且该模型配了 num_ctx 时，
    # options.num_ctx 注入**当前档**而非上限（上限 = 用户配置值）。
    # 未配置 num_ctx / 懒加载关闭 / 非 Ollama 后端 → current_ctx_for 返回 None，
    # raw 原样走旧逻辑（「未配置逐字节不注入」铁律不破）。
    # 0.4.31（P2，D5）：model_package 的 num_ctx **不进 payload**（llama-server 不靠
    # 请求级参数调上下文，由驱动启动时以 -c 传档位）——映射表 num_ctx:None 原样丢弃，
    # 此处无需也不许为它注入档位；其余参数映射照常。
    if be == "ollama" and "num_ctx" in raw:
        _tier = current_ctx_for(model, backend=be)
        if _tier is not None:
            raw["num_ctx"] = _tier
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

    公开访问器，供 `/api/context/limit` 判断"指示器该按哪个上限算占比"。
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


# ── 0.4.31（P0/P1）模型缓存懒加载：num_ctx 档位表（REQ-INFER-010，D1~D3）──────
# 语义（D1）：用户配置的 num_ctx = **上限**；首次加载用起始档，上下文膨胀触档
# 自动翻倍升档，达上限后行为与旧版完全一致。仅在该模型已配置 num_ctx 时生效。
#
# 档位表是**模块级运行时状态**（D2）：
#   - 每模型一槽，**只升不降**（多会话同模型并发天然取 max，不会互相降档，R4）
#   - 不持久化，进程重启回起始档
#   - 线程安全用一把简单锁（run_tool_loop 单会话串行，并发度极低，无需复杂方案）
# 档位阶梯（D2）：起始档 = min(ctx_lazy_start, ceiling)；升档 next = min(current×2, ceiling)；
#   ceiling < 起始档时起始档即 ceiling（直接全量，与旧行为一致）。
# 触发阈值（D3/R5）：est = ctx_chars×0.6 ≥ 当前档×0.85 且档 < 上限 → 升档。
#   0.85 留余量是因为 ctx_chars×0.6 本身是估算——误判后果仅为提前/滞后一档，均可接受。
CTX_LAZY_START_DEFAULT = 12288
CTX_LAZY_START_RANGE = (2048, 1_048_576)
CTX_LAZY_BUMP_THRESHOLD = 0.85

_CTX_LAZY_LOCK = threading.Lock()
_CTX_LAZY_STATE: dict[str, int] = {}   # model → 当前档（只升不降）


def lazy_enabled() -> bool:
    """懒加载总开关（config `ctx_lazy_enabled`，默认 true；非法值按默认开处理）。"""
    v = _cfg().get("ctx_lazy_enabled", True)
    return v if isinstance(v, bool) else True


def lazy_start() -> int:
    """起始档配置值（config `ctx_lazy_start`，默认 12288；非法/越界夹到合法范围）。"""
    raw = _cfg().get("ctx_lazy_start", CTX_LAZY_START_DEFAULT)
    f = _to_float(raw)
    if f is None:
        return CTX_LAZY_START_DEFAULT
    lo, hi = CTX_LAZY_START_RANGE
    return int(min(max(f, lo), hi))


def lazy_ceiling(model: str, backend: str | None = None) -> int | None:
    """懒加载上限 = 用户为该模型配置的 num_ctx。

    返回 None 表示**懒加载不生效**（走旧逻辑）：总开关关闭 / 未配置 num_ctx /
    后端不支持懒加载。0.4.31（P2）起生效后端 = ollama 与 model_package
    （模型包的 num_ctx 上限经驱动 -c 档位重启生效，与 Ollama 同语义，D5）；
    openai_compatible 的上下文由服务端自行管理，懒加载不介入。
    """
    if not lazy_enabled():
        return None
    be = (backend or str(_cfg().get("inference_backend", "ollama"))).strip().lower()
    if be not in ("ollama", "model_package"):
        return None
    return configured_num_ctx(model)


def _tier_locked(model: str, ceiling: int) -> int:
    """取当前档（调用方须已持锁）。首次访问初始化起始档；配置调低时钳到上限。"""
    cur = _CTX_LAZY_STATE.get(model)
    if cur is None:
        cur = min(lazy_start(), ceiling)   # ceiling < 起始档 → 直接全量（D2）
        _CTX_LAZY_STATE[model] = cur
    elif cur > ceiling:
        # 用户运行中调低了配置上限：读侧钳制（不写回，保持「只升不降」的单向语义）
        cur = ceiling
    return cur


def current_ctx_for(model: str, backend: str | None = None) -> int | None:
    """该模型当前应使用的 num_ctx 档；懒加载不生效 → None（调用方走旧逻辑）。

    首次访问有副作用：初始化该模型的起始档。/api/context/limit 与 chat 端点
    据此报「当前档」，与下一次请求实际注入的值同口径（D4）。
    """
    ceiling = lazy_ceiling(model, backend)
    if ceiling is None:
        return None
    with _CTX_LAZY_LOCK:
        return _tier_locked(model, ceiling)


def maybe_bump_ctx(model: str, est_tokens: float, backend: str | None = None) -> bool:
    """用量估算触档则升一档（D3）。返回 True = 本轮发生了升档。

    触发条件：est_tokens ≥ 当前档 × 0.85 且当前档 < 上限。
    est 口径与 loop 一致：ctx_chars × 0.6（含历史消息，每轮现算）。
    """
    ceiling = lazy_ceiling(model, backend)
    if ceiling is None:
        return False
    with _CTX_LAZY_LOCK:
        cur = _tier_locked(model, ceiling)
        if cur >= ceiling:
            return False
        if est_tokens < cur * CTX_LAZY_BUMP_THRESHOLD:
            return False
        nxt = min(cur * 2, ceiling)
        if nxt <= cur:
            return False
        _CTX_LAZY_STATE[model] = nxt
        return True


def _reset_ctx_lazy_state() -> None:
    """测试专用：清空档位表（生产代码不得调用——档位只升不降是并发语义的一部分）。"""
    with _CTX_LAZY_LOCK:
        _CTX_LAZY_STATE.clear()


def _strip_tag(name: str) -> str:
    """模型名去 tag：`qwen3.8:latest` → `qwen3.8`。

    既有口径原本是 `_raw_model_options` 里内联的 `name.split(":", 1)[0]`；
    R3（0.4.33）配置键侧也要做同口径归一化，收敛成函数防止两处写法漂移。
    """
    return name.split(":", 1)[0]


def _raw_model_options(model: str) -> dict[str, Any]:
    """从 config 的 model_options 里取该模型的原始配置（未做后端映射）。

    匹配规则（三级，优先级从高到低）：
      1. 精确匹配：查询名原样命中配置键；
      2. 查询名去 tag：查询 `qwen3.8:latest` 命中配置键 `qwen3.8`
         （Ollama 模型名常带 tag，而用户配置时通常不写 tag）；
      3. **配置键去 tag**（R3，0.4.33）：配置键 `qwen3.8:latest` 命中查询 `qwen3.8`
         ——旧逻辑只给查询名去 tag、不给配置键去 tag，用户在设置页存了带 tag 的键
         （如下拉选中的 `qwen3.8:latest`）而会话模型名不带 tag 时 configured_num_ctx
         静默落空 → /api/context/limit 掉到 ps/show 级，指示器误显示模型默认值
         262144，用户以为 num_ctx 设置失效。两侧同口径归一后该形态必然命中。
    """
    mo = _cfg().get("model_options")
    if not isinstance(mo, dict) or not mo:
        return {}
    name = str(model or "").strip()
    if not name:
        return {}
    hit = mo.get(name)
    if not isinstance(hit, dict):
        base = _strip_tag(name)
        hit = mo.get(base)
        if not isinstance(hit, dict):
            # R3：配置键侧同样去 tag（第三级）。遍历顺序 = dict 插入序，先配先中；
            # 精确/查询去 tag 两级已在上方先行，不会改变既有命中的优先级。
            for k, v in mo.items():
                if isinstance(k, str) and _strip_tag(k) == base and isinstance(v, dict):
                    hit = v
                    break
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

    只校验**结构与类型**，不因"某后端不支持某参数"而报错——
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
