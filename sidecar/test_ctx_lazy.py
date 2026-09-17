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
"""0.4.31（P0/P1）模型缓存懒加载专项（REQ-INFER-010，D1~D4）。

覆盖：
  档位数学    起始档 = min(ctx_lazy_start, ceiling)；升档 next = min(current×2, ceiling)；
              ceiling < 起始档时直接全量；只升不降；配置调低读侧钳制
  升档阈值    est = ctx_chars×0.6 ≥ 当前档×0.85 触发（D3，0.85 边界两侧）
  禁用直通    ctx_lazy_enabled=false → 配置 num_ctx 即全量（旧行为逐字节一致）
  未配置铁律  未配置 num_ctx → 懒加载不生效、payload 不注入（铁律不破）
  注入口径    model_options 注入当前档而非上限；其余参数原样
  端点口径    /api/context/limit 报当前档并**追加** ceiling/lazy（纯追加，D4）
  loop 联动   升档先于 90% 压缩预警：升档后用量低于新档 90% → 压缩不触发
  config      两键登记 + 校验（bool / 2048~1048576）

隔离：钉死 config.store.get_config_path 到临时目录（第 0 批纪律），
每个用例前 _reset_ctx_lazy_state() 清档位表（模块级运行时状态，跨用例必须隔离）。
"""
from __future__ import annotations

import asyncio
import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

PASS, FAIL = 0, 0
FAILURES: list[str] = []


def check(name: str, cond: bool, detail: str = "") -> None:
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"PASS  {name}")
    else:
        FAIL += 1
        FAILURES.append(name)
        print(f"FAIL  {name}  {detail}")


# ── 模块级隔离（第 0 批纪律：钉死写入路径）─────────────────────────────
_TMP = Path(tempfile.mkdtemp(prefix="ctxlazy_"))
import sidecar.config.store as cs          # noqa: E402
cs.get_config_path = lambda: _TMP / "config.json"


def setcfg(model_options=None, lazy_enabled=True, lazy_start=12288, **extra) -> None:
    base = {
        "ollama_base_url": "http://localhost:11434",
        "data_root": str(_TMP),
        "default_model": "qwen3.8",
        "proxy_http_port": 21081,
        "proxy_socks_port": 21080,
        "sidecar_port": 8765,
        "vite_port": 5173,
        "network_switch": "auto",
        "inference_backend": "ollama",
        "model_options": model_options or {},
        "ctx_lazy_enabled": lazy_enabled,
        "ctx_lazy_start": lazy_start,
    }
    base.update(extra)
    (_TMP / "config.json").write_text(json.dumps(base, ensure_ascii=False), encoding="utf-8")
    io._reset_ctx_lazy_state()


from sidecar.ollama import infer_options as io   # noqa: E402


def main() -> None:
    # ═══════════ 1. 档位数学（D2）═══════════
    setcfg({"m": {"num_ctx": 65536}})
    check("1-1 起始档 = min(start 12288, ceiling 65536) = 12288",
          io.current_ctx_for("m") == 12288, str(io.current_ctx_for("m")))
    check("1-2 lazy_ceiling = 配置的 num_ctx", io.lazy_ceiling("m") == 65536)

    setcfg({"m": {"num_ctx": 8192}})
    check("1-3 ceiling(8192) < 起始档(12288) → 直接全量 8192",
          io.current_ctx_for("m") == 8192, str(io.current_ctx_for("m")))

    setcfg({"m": {"num_ctx": 65536}}, lazy_start=4096)
    check("1-4 自定义起始档 4096 生效", io.current_ctx_for("m") == 4096,
          str(io.current_ctx_for("m")))

    # 翻倍阶梯 + 上限钳制
    setcfg({"m": {"num_ctx": 65536}})
    io.current_ctx_for("m")                      # 初始化 12288
    check("1-5 触档升 12288→24576",
          io.maybe_bump_ctx("m", 12288 * 0.85) is True and io.current_ctx_for("m") == 24576)
    check("1-6 再触档升 24576→49152",
          io.maybe_bump_ctx("m", 24576 * 0.85) is True and io.current_ctx_for("m") == 49152)
    check("1-7 再触档钳到上限 49152→65536（而非 98304）",
          io.maybe_bump_ctx("m", 49152 * 0.85) is True and io.current_ctx_for("m") == 65536)
    check("1-8 到达上限后不再升档", io.maybe_bump_ctx("m", 999999) is False
          and io.current_ctx_for("m") == 65536)

    # 只升不降（R4：多会话同模型并发取 max 的语义基础）
    setcfg({"m": {"num_ctx": 65536}})
    io.maybe_bump_ctx("m", 999999)               # 升到 24576
    check("1-9 只升不降：低 est 不降档",
          io.maybe_bump_ctx("m", 0) is False and io.current_ctx_for("m") == 24576)

    # 运行中调低配置上限 → 读侧钳制
    setcfg({"m": {"num_ctx": 65536}})
    io.maybe_bump_ctx("m", 999999)               # 24576
    io.maybe_bump_ctx("m", 999999)               # 49152
    cfg = json.loads((_TMP / "config.json").read_text(encoding="utf-8"))
    cfg["model_options"]["m"]["num_ctx"] = 32768
    (_TMP / "config.json").write_text(json.dumps(cfg, ensure_ascii=False), encoding="utf-8")
    check("1-10 配置调低到 32768 → 当前档读侧钳到 32768",
          io.current_ctx_for("m") == 32768, str(io.current_ctx_for("m")))

    # 起始档非法值的防御性读取（手改磁盘 config，绕过 reload 校验）
    setcfg({"m": {"num_ctx": 65536}}, lazy_start=100)
    check("1-11 ctx_lazy_start=100（越界）→ 读侧夹到 2048",
          io.lazy_start() == 2048 and io.current_ctx_for("m") == 2048,
          f"start={io.lazy_start()} cur={io.current_ctx_for('m')}")

    # ═══════════ 2. 升档阈值 0.85 边界（D3/R5）═══════════
    setcfg({"m": {"num_ctx": 65536}})
    io.current_ctx_for("m")                      # 12288
    check("2-1 est = 档×0.85 - 0.1 → 不升档",
          io.maybe_bump_ctx("m", 12288 * 0.85 - 0.1) is False
          and io.current_ctx_for("m") == 12288)
    check("2-2 est = 档×0.85 → 升档",
          io.maybe_bump_ctx("m", 12288 * 0.85) is True and io.current_ctx_for("m") == 24576)

    # ═══════════ 3. 禁用直通（旧行为逐字节一致）═══════════
    setcfg({"m": {"num_ctx": 65536, "temperature": 0.3}}, lazy_enabled=False)
    check("3-1 禁用 → lazy_ceiling/current/maybe_bump 全部短路",
          io.lazy_ceiling("m") is None and io.current_ctx_for("m") is None
          and io.maybe_bump_ctx("m", 999999) is False)
    o = io.model_options("m")
    check("3-2 禁用 → model_options 注入上限全量（旧行为）",
          o == {"options": {"num_ctx": 65536, "temperature": 0.3}}, str(o))

    # ═══════════ 4. 未配置铁律（逐字节不注入）═══════════
    setcfg()
    check("4-1 未配置 → model_options 空 dict（payload 不出现 options 键）",
          io.model_options("m") == {})
    check("4-2 未配置 → 懒加载三函数全部短路",
          io.lazy_ceiling("m") is None and io.current_ctx_for("m") is None
          and io.maybe_bump_ctx("m", 999999) is False)
    setcfg({"m": {"temperature": 0.5}})
    check("4-3 配了其他参数但没配 num_ctx → 懒加载不生效、不捏造 num_ctx",
          io.model_options("m") == {"options": {"temperature": 0.5}}
          and io.current_ctx_for("m") is None, str(io.model_options("m")))

    # ═══════════ 5. model_options 注入当前档（P0 核心）═══════════
    setcfg({"m": {"num_ctx": 65536, "temperature": 0.3}})
    o = io.model_options("m")
    check("5-1 懒加载开启 → num_ctx 注入起始档 12288 而非上限 65536",
          o == {"options": {"num_ctx": 12288, "temperature": 0.3}}, str(o))
    io.maybe_bump_ctx("m", 999999)
    o = io.model_options("m")
    check("5-2 升档后 → num_ctx 注入新档 24576",
          o == {"options": {"num_ctx": 24576, "temperature": 0.3}}, str(o))
    setcfg({"m": {"num_ctx": 8192}})
    check("5-3 ceiling < 起始档 → 注入值与旧行为一致（直接全量 8192）",
          io.model_options("m") == {"options": {"num_ctx": 8192}}, str(io.model_options("m")))
    # 非 Ollama 后端：懒加载不生效（本期范围），num_ctx 依旧按映射丢弃
    setcfg({"m": {"num_ctx": 65536, "temperature": 0.3}}, inference_backend="openai_compatible",
           inference_base_url="http://localhost:1234/v1")
    c = io.model_options("m")
    check("5-4 openai_compatible → num_ctx 依旧丢弃（懒加载不介入）",
          c == {"temperature": 0.3}, str(c))

    # ═══════════ 6. config 两键登记与校验（store 范式）═══════════
    import sidecar.config.store as _cs
    check("6-1 默认值登记：enabled=True / start=12288",
          _cs.DEFAULT_CONFIG.get("ctx_lazy_enabled") is True
          and _cs.DEFAULT_CONFIG.get("ctx_lazy_start") == 12288)
    for bad, key in (("yes", "ctx_lazy_enabled"), (1000, "ctx_lazy_start"),
                     (True, "ctx_lazy_start"), (2097152, "ctx_lazy_start")):
        try:
            _cs.reload_config({key: bad})
            check(f"6-2 store._validate 拒绝 {key}={bad!r}", False, "未抛错")
        except ValueError as e:
            check(f"6-2 store._validate 拒绝 {key}={bad!r}", key in str(e), str(e))
        finally:
            setcfg()   # 恢复干净配置（reload 拒绝时不落盘，这里只是复位档位表）
    cfg = _cs.reload_config({"ctx_lazy_enabled": False, "ctx_lazy_start": 4096})
    check("6-3 合法值可保存并读回",
          cfg.get("ctx_lazy_enabled") is False and cfg.get("ctx_lazy_start") == 4096,
          str({k: cfg.get(k) for k in ("ctx_lazy_enabled", "ctx_lazy_start")}))
    setcfg()

    # ═══════════ 7. /api/context/limit 追加字段（D4）═══════════
    asyncio.run(_endpoint_checks())

    # ═══════════ 8. loop 升档先于压缩（P1 核心）═══════════
    asyncio.run(_loop_checks())

    # ═══════════ 9. model_package 档位分支（P2，D5）═══════════
    setcfg({"m": {"num_ctx": 65536}}, inference_backend="model_package",
           inference_base_url="")
    check("9-1 model_package → lazy_ceiling 生效（上限=配置 num_ctx，去 tag 匹配同源）",
          io.lazy_ceiling("m", "model_package") == 65536)
    check("9-2 model_package → 起始档 12288（档位语义与 Ollama 完全一致）",
          io.current_ctx_for("m", "model_package") == 12288,
          str(io.current_ctx_for("m", "model_package")))
    check("9-3 model_package → 触档升 12288→24576",
          io.maybe_bump_ctx("m", 12288 * 0.85, "model_package") is True
          and io.current_ctx_for("m", "model_package") == 24576)
    o = io.model_options("m", "model_package")
    check("9-4 model_package → num_ctx 不进 payload（档位经驱动 -c，不靠请求级参数）",
          "num_ctx" not in o and "options" not in o, str(o))
    setcfg({"m": {"num_ctx": 65536, "temperature": 0.3, "repeat_penalty": 1.1}},
           inference_backend="model_package", inference_base_url="")
    o = io.model_options("m", "model_package")
    check("9-5 model_package → 其余参数映射照常（顶层字段 + repeat_penalty 映射）",
          o == {"temperature": 0.3, "frequency_penalty": 1.1}, str(o))
    check("9-6 全局后端=model_package 时不传 backend 同样生效",
          io.current_ctx_for("m") == 12288, str(io.current_ctx_for("m")))
    setcfg({"m": {"num_ctx": 65536}}, inference_backend="openai_compatible",
           inference_base_url="http://localhost:1234/v1")
    check("9-7 openai_compatible → 懒加载不生效（服务端自管上下文）",
          io.lazy_ceiling("m", "openai_compatible") is None
          and io.current_ctx_for("m", "openai_compatible") is None)
    setcfg({"m": {"num_ctx": 65536}}, lazy_enabled=False,
           inference_backend="model_package", inference_base_url="")
    check("9-8 model_package + 懒加载关闭 → 全部短路（走 manifest/默认）",
          io.lazy_ceiling("m", "model_package") is None
          and io.current_ctx_for("m", "model_package") is None
          and io.maybe_bump_ctx("m", 999999, "model_package") is False)

    # ═══════════ 10. openai_compat 显式 backend 回归（P2 语义漂移修复）═══════════
    asyncio.run(_openai_compat_payload_checks())

    print(f"\n===== 0.4.31 懒加载专项: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("失败项:", FAILURES)
        sys.exit(1)


async def _endpoint_checks() -> None:
    from fastapi.testclient import TestClient
    from sidecar.app import app
    client = TestClient(app)

    setcfg({"m": {"num_ctx": 65536}})
    d = client.get("/api/context/limit", params={"model": "m"}).json()
    check("7-1 懒加载生效 → limit 报当前档 12288",
          d.get("context_length") == 12288 and d.get("source") == "config", str(d))
    check("7-2 追加 ceiling=65536 与 lazy=true（旧字段不动）",
          d.get("ceiling") == 65536 and d.get("lazy") is True, str(d))
    io.maybe_bump_ctx("m", 999999)
    d = client.get("/api/context/limit", params={"model": "m"}).json()
    check("7-3 升档后端点同步报新档 24576",
          d.get("context_length") == 24576 and d.get("ceiling") == 65536, str(d))

    setcfg({"m": {"num_ctx": 65536}}, lazy_enabled=False)
    d = client.get("/api/context/limit", params={"model": "m"}).json()
    check("7-4 懒加载关闭 → 原逻辑报全量 65536，无追加字段",
          d.get("context_length") == 65536 and "ceiling" not in d and "lazy" not in d, str(d))

    setcfg({"m": {"num_ctx": 8192}})
    d = client.get("/api/context/limit", params={"model": "m"}).json()
    check("7-5 ceiling < 起始档 → 报 8192 且仍带 ceiling/lazy",
          d.get("context_length") == 8192 and d.get("ceiling") == 8192
          and d.get("lazy") is True, str(d))

    # ── 0.4.31（P2，D4/D5）：model_package 分支与 Ollama 同口径 ──
    setcfg({"m": {"num_ctx": 65536}}, inference_backend="model_package",
           inference_base_url="")
    d = client.get("/api/context/limit", params={"model": "m"}).json()
    check("7-6 model_package → 配了上限且懒加载开启：报当前档 + ceiling/lazy",
          d.get("context_length") == 12288 and d.get("source") == "config"
          and d.get("ceiling") == 65536 and d.get("lazy") is True, str(d))
    io.maybe_bump_ctx("m", 999999, "model_package")
    d = client.get("/api/context/limit", params={"model": "m"}).json()
    check("7-7 model_package 升档后端点同步报新档 24576",
          d.get("context_length") == 24576 and d.get("ceiling") == 65536, str(d))
    setcfg({"m": {"num_ctx": 65536}}, lazy_enabled=False,
           inference_backend="model_package", inference_base_url="")
    d = client.get("/api/context/limit", params={"model": "m"}).json()
    check("7-8 model_package 懒加载关闭 → 回 manifest 原逻辑（无此包 → unsupported），无追加字段",
          d.get("source") == "unsupported" and "ceiling" not in d and "lazy" not in d, str(d))


async def _loop_checks() -> None:
    """升档先于 90% 压缩预警：升档后用量低于新档 90% → 压缩不触发（D3）。

    场景：起始档 12288，首轮 est = 20000 字符×0.6 = 12000 ≥ 12288×0.85=10444.8
      → 升到 24576；第 1 轮模型报 prompt_eval_count=20000。
      第 2 轮预警判定：20000/24576 ≈ 81% < 90% → 不压缩，loop 继续到 done。
      对照组（懒加载关闭）：20000/12288 ≈ 163% ≥ 90% → compact_required。
    """
    from sidecar.agent_engine.loop import run_tool_loop

    sandbox = _TMP / "sandbox"
    sandbox.mkdir(exist_ok=True)

    class BigConn:
        """第 1 轮返回工具调用 + 高 prompt_eval；第 2 轮正文收尾。"""
        def __init__(self):
            self.calls = 0

        async def chat_stream(self, model, messages, tools=None):
            self.calls += 1
            if self.calls == 1:
                yield {"tool_calls": [{"id": "t1",
                                       "function": {"name": "list_dir", "arguments": "{}"}}]}
                yield {"done": True, "counts": {"prompt_eval_count": 20000, "eval_count": 1}}
            else:
                yield {"content_delta": "收尾"}
                yield {"done": True, "counts": {"prompt_eval_count": 20000, "eval_count": 1}}

    # ── 懒加载开启：升档先于压缩 ──
    setcfg({"m": {"num_ctx": 65536}})
    conn = BigConn()
    evs = []
    async for ev in run_tool_loop("m", [{"role": "user", "content": "x" * 20000}], [],
                                  str(sandbox), max_rounds=5, context_limit=12288,
                                  connector=conn):
        evs.append(ev)
    names = [e["event"] for e in evs]
    check("8-1 升档后用量低于新档 90% → 压缩不触发",
          "compact_required" not in names and "compact_auto" not in names, str(names))
    check("8-2 loop 走到 done（模型真被调了 2 轮）",
          conn.calls == 2 and "done" in names, f"calls={conn.calls} events={names}")
    check("8-3 档位表已升到 24576（model_options 同步注新档）",
          io.current_ctx_for("m") == 24576
          and io.model_options("m")["options"]["num_ctx"] == 24576,
          f"cur={io.current_ctx_for('m')} opts={io.model_options('m')}")

    # ── 对照组：懒加载关闭 → 同一用量触发 compact_required ──
    setcfg({"m": {"num_ctx": 65536}}, lazy_enabled=False)
    conn2 = BigConn()
    evs2 = []
    async for ev in run_tool_loop("m", [{"role": "user", "content": "x" * 20000}], [],
                                  str(sandbox), max_rounds=5, context_limit=12288,
                                  connector=conn2):
        evs2.append(ev)
    names2 = [e["event"] for e in evs2]
    cr = next((e for e in evs2 if e["event"] == "compact_required"), None)
    check("8-4 对照组（关闭懒加载）→ compact_required 触发且只调了 1 轮模型",
          cr is not None and conn2.calls == 1, f"calls={conn2.calls} events={names2}")

    # ── 委派语义：context_limit=0 → 跳过升档判定（D6 零特殊处理）──
    setcfg({"m": {"num_ctx": 65536}})
    conn3 = BigConn()
    async for _ev in run_tool_loop("m", [{"role": "user", "content": "x" * 20000}], [],
                                   str(sandbox), max_rounds=5, context_limit=0,
                                   connector=conn3):
        pass
    check("8-5 context_limit=0（委派子会话）→ 不做升档判定，档位仍是起始档",
          io.current_ctx_for("m") == 12288, str(io.current_ctx_for("m")))


async def _openai_compat_payload_checks() -> None:
    """P2 语义漂移修复回归：openai_compat 的 payload 必须按**显式后端**映射，
    不再按全局 config inference_backend。

    漂移场景：全局后端是 ollama（0.4.30 并行路由下完全可能），旧代码
    `model_options(model)` 不传 backend → 按 ollama 映射 → payload 被包上
    {"options": {...}} 并注入 num_ctx（OpenAI 兼容端无此协议字段）。
    修复后（_INFER_BACKEND 类属性）：顶层字段、num_ctx 丢弃、其余映射照常。
    """
    from sidecar.ollama.openai_compat import OpenAICompatConnector

    # 全局后端故意钉 ollama + 该模型配了 num_ctx（旧缺陷的触发条件）
    setcfg({"m": {"num_ctx": 65536, "temperature": 0.3, "repeat_penalty": 1.1}},
           inference_base_url="http://localhost:1234/v1")
    captured: list[dict] = []

    class FakeResp:
        status_code = 200
        text = ""

        def json(self):
            return {"choices": [{"message": {"content": "ok"}}]}

    class FakeClient:
        is_closed = False

        async def post(self, url, json=None, **kw):
            captured.append(json or {})
            return FakeResp()

    c = OpenAICompatConnector()
    c._client = lambda *a, **kw: asyncio.sleep(0, result=FakeClient())  # type: ignore
    await c.chat("m", [{"role": "user", "content": "hi"}])
    body = captured[0] if captured else {}
    check("10-1 全局 ollama 下 openai 连接器 payload 不包 options 键（漂移修复）",
          "options" not in body, str(list(body.keys())))
    check("10-2 num_ctx 被丢弃（openai 兼容无此参数，即便懒加载生效）",
          "num_ctx" not in body, str(body))
    check("10-3 其余参数按 openai 行映射照常（顶层字段 + frequency_penalty）",
          body.get("temperature") == 0.3 and body.get("frequency_penalty") == 1.1, str(body))
    # ModelPackageConnector 子类：_INFER_BACKEND 覆盖为 model_package（同样不进 payload）
    from sidecar.model_packs.mp_connector import ModelPackageConnector
    check("10-4 ModelPackageConnector._INFER_BACKEND = model_package",
          ModelPackageConnector._INFER_BACKEND == "model_package"
          and OpenAICompatConnector._INFER_BACKEND == "openai_compatible")


if __name__ == "__main__":
    main()
