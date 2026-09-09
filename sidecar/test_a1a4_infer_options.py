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
"""第 2 批（0.4.15）A1-A4 专项：推理超时与每模型参数。

覆盖（每条对应一个用户拍板需求 + 其硬约束）：
  A1 超时可配：0/缺省→原硬编码值（10/300/1800）；配置值生效并夹到合法范围
  A2 num_ctx：注入 Ollama payload 的 options；模型名去 tag 匹配
  A4 参数映射：同一份配置，ollama→options 嵌套；openai_compatible→顶层字段
     且 num_ctx/top_k 丢弃、repeat_penalty→frequency_penalty、num_predict→max_tokens
  A3 上下文四级取值：config(num_ctx) > ps > show(model_info.*.context_length) > 262144
  ⛔ 向后兼容铁律：**未配置时 payload 逐字节不含 options 键、超时等于原常量**——
     违反这条，所有现有推理链路（聊天/工作流/圆桌/委派）的行为都会漂移。

隔离：钉死 config.store.get_config_path 到临时目录（第 0 批纪律），
不触碰真实 ~/.subagent/config.json。
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
_TMP = Path(tempfile.mkdtemp(prefix="a1a4_"))
import sidecar.config.store as cs          # noqa: E402
cs.get_config_path = lambda: _TMP / "config.json"


def setcfg(model_options=None, backend="ollama", **extra) -> None:
    base = {
        "ollama_base_url": "http://localhost:11434",
        "data_root": str(_TMP),
        "default_model": "qwen3.8",
        "proxy_http_port": 21081,
        "proxy_socks_port": 21080,
        "sidecar_port": 8765,
        "vite_port": 5173,
        "network_switch": "auto",
        "inference_backend": backend,
        "model_options": model_options or {},
    }
    base.update(extra)
    (_TMP / "config.json").write_text(json.dumps(base, ensure_ascii=False), encoding="utf-8")


from sidecar.ollama import infer_options as io   # noqa: E402


def main() -> None:
    # ═══════════ A1：超时可配 + 向后兼容 ═══════════
    setcfg()   # 全部默认（三个超时键不存在 → 回落常量）
    check("A1-1 未配置 → connect 回落 10.0", io.timeout_connect() == 10.0, str(io.timeout_connect()))
    check("A1-2 未配置 → reading 回落 300.0", io.timeout_reading() == 300.0, str(io.timeout_reading()))
    check("A1-3 未配置 → stream 回落 1800.0",
          io.timeout_stream_reading() == 1800.0, str(io.timeout_stream_reading()))

    setcfg(timeout_connect=5, timeout_reading=900, timeout_stream_reading=3600)
    check("A1-4 配置值生效", (io.timeout_connect(), io.timeout_reading(),
          io.timeout_stream_reading()) == (5.0, 900.0, 3600.0))

    setcfg(timeout_connect=0, timeout_reading=0, timeout_stream_reading=0)
    check("A1-5 显式 0 = 用默认（UI 语义「填 0 = 默认」）",
          (io.timeout_connect(), io.timeout_reading(), io.timeout_stream_reading()) == (10.0, 300.0, 1800.0))

    setcfg(timeout_reading=999999, timeout_connect=0.001)
    check("A1-6 越界夹取（上限 7200 / 下限 1）",
          io.timeout_reading() == 7200.0 and io.timeout_connect() == 1.0,
          f"{io.timeout_reading()}/{io.timeout_connect()}")

    setcfg(timeout_reading="abc", timeout_connect=True)
    check("A1-7 非法值（字符串/bool）→ 回落默认，不抛错",
          io.timeout_reading() == 300.0 and io.timeout_connect() == 10.0)

    # config 校验拒绝非法超时
    err = io.timeout_validate({"timeout_reading": -5})
    check("A1-8 timeout_validate 拒绝负数", err is not None and "timeout_reading" in err, str(err))
    check("A1-9 timeout_validate 放行 0 与合法值",
          io.timeout_validate({"timeout_reading": 0}) is None
          and io.timeout_validate({"timeout_reading": 600}) is None)

    # ═══════════ A2/A4：model_options 注入与后端映射 ═══════════
    setcfg()
    check("A2-1 ⛔ 未配置 → 返回空 dict（payload 不出现 options 键）",
          io.model_options("qwen3.8") == {}, str(io.model_options("qwen3.8")))
    check("A2-2 未配置 + openai 后端 → 同样空",
          io.model_options("qwen3.8", "openai_compatible") == {})

    full = {"qwen3.8": {"num_ctx": 8192, "temperature": 0.3, "top_p": 0.9, "top_k": 40,
                        "repeat_penalty": 1.1, "num_predict": 2048, "seed": 42}}
    setcfg(full, "ollama")
    o = io.model_options("qwen3.8")
    check("A2-3 ollama → 包在 options 键内", set(o.keys()) == {"options"}, str(o.keys()))
    check("A2-4 ollama → 参数原样透传",
          o.get("options") == {"num_ctx": 8192, "temperature": 0.3, "top_p": 0.9, "top_k": 40,
                               "repeat_penalty": 1.1, "num_predict": 2048, "seed": 42}, str(o))

    setcfg(full, "openai_compatible")
    c = io.model_options("qwen3.8")
    check("A4-1 openai → 顶层字段（无 options 嵌套）", "options" not in c, str(c))
    check("A4-2 openai → num_ctx/top_k 静默丢弃（该后端不支持）",
          "num_ctx" not in c and "top_k" not in c, str(c))
    check("A4-3 openai → repeat_penalty 映射为 frequency_penalty",
          c.get("frequency_penalty") == 1.1 and "repeat_penalty" not in c, str(c))
    check("A4-4 openai → num_predict 映射为 max_tokens",
          c.get("max_tokens") == 2048 and "num_predict" not in c, str(c))
    check("A4-5 openai → temperature/top_p/seed 原样",
          c.get("temperature") == 0.3 and c.get("top_p") == 0.9 and c.get("seed") == 42, str(c))

    # 去 tag 匹配（Ollama 模型名常带 :latest）
    setcfg({"qwen3.8": {"temperature": 0.5}})
    check("A2-5 去 tag 匹配：qwen3.8:latest 命中 qwen3.8 的配置",
          io.model_options("qwen3.8:latest") == {"options": {"temperature": 0.5}},
          str(io.model_options("qwen3.8:latest")))
    check("A2-6 configured_num_ctx 同样去 tag",
          io.configured_num_ctx("qwen3.8:latest") is None)  # 该配置无 num_ctx
    setcfg({"qwen3.8": {"num_ctx": 4096}})
    check("A2-7 configured_num_ctx 精确取值", io.configured_num_ctx("qwen3.8") == 4096)
    check("A2-8 configured_num_ctx 未配置 → None", io.configured_num_ctx("other-model") is None)

    # 非法值丢弃（宁可回落默认，不注入坏值）
    setcfg({"m1": {"temperature": 99, "num_ctx": -5, "top_p": "abc", "seed": True,
                   "stop": "你好", "num_predict": 100, "unknown_key": 1}})
    r = io.model_options("m1")
    check("A4-6 越界/非法值全部丢弃，仅合法项保留",
          r == {"options": {"stop": ["你好"], "num_predict": 100}}, str(r))
    check("A4-7 stop 字符串自动转数组", r["options"]["stop"] == ["你好"], str(r))

    # 全部非法 → 空 dict（不得注入空 options）
    setcfg({"m2": {"temperature": 99}})
    check("A4-8 ⛔ 全部值非法 → 返回空 dict（不注入空 options）",
          io.model_options("m2") == {}, str(io.model_options("m2")))

    # ═══════════ 配置校验（store._validate 经由此处）═══════════
    check("V-1 未知参数名 → 报错并列出可用参数",
          (lambda e: e is not None and "bad_key" in e and "num_ctx" in e)(
              io.validate_model_options({"m": {"bad_key": 1}})))
    check("V-2 越界值 → 报错并给范围",
          (lambda e: e is not None and "0.0~2.0" in e)(
              io.validate_model_options({"m": {"temperature": 99}})))
    check("V-3 合法配置 → 通过", io.validate_model_options(
        {"qwen3.8": {"num_ctx": 8192, "temperature": 0.3, "stop": ["</s>"]}}) is None)
    check("V-4 结构非法（非 dict）→ 报错", io.validate_model_options(["x"]) is not None)
    check("V-5 空模型名 → 报错", io.validate_model_options({"": {"num_ctx": 1024}}) is not None)
    check("V-6 num_predict=-1/-2 合法（Ollama 特殊语义）",
          io.validate_model_options({"m": {"num_predict": -1}}) is None
          and io.validate_model_options({"m": {"num_predict": -2}}) is None)
    check("V-7 num_predict=-3 非法", io.validate_model_options({"m": {"num_predict": -3}}) is not None)

    # ═══════════ 端到端：store 校验链真的接上了 ═══════════
    try:
        cs.reload_config({"model_options": {"m": {"temperature": 99}}})
        check("E-1 store._validate 拒绝非法 model_options", False, "未抛错")
    except ValueError as e:
        check("E-1 store._validate 拒绝非法 model_options", "temperature" in str(e), str(e))
    try:
        cs.reload_config({"timeout_reading": -1})
        check("E-2 store._validate 拒绝非法超时", False, "未抛错")
    except ValueError as e:
        check("E-2 store._validate 拒绝非法超时", "timeout_reading" in str(e), str(e))
    cfg = cs.reload_config({"model_options": {"qwen3.8": {"num_ctx": 8192}}, "timeout_reading": 600})
    check("E-3 合法配置可保存并读回",
          cfg.get("model_options", {}).get("qwen3.8", {}).get("num_ctx") == 8192
          and cfg.get("timeout_reading") == 600, str({k: cfg.get(k) for k in ("model_options", "timeout_reading")}))

    # ═══════════ connector payload 注入（不实际请求，只验构造）═══════════
    asyncio.run(_payload_checks())

    print(f"\n===== A1-A4 专项: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("失败项:", FAILURES)
        sys.exit(1)


async def _payload_checks() -> None:
    """直接调 connector 的 payload 构造路径（用假 httpx 拦截，不发真实请求）。"""
    import sidecar.ollama.connector as conn

    captured: list[dict] = []

    class FakeResp:
        status_code = 200
        def json(self): return {"message": {"role": "assistant", "content": "ok"}, "done": True}
        text = ""

    class FakeClient:
        def __init__(self, **kw): pass
        async def __aenter__(self): return self
        async def __aexit__(self, *a): return False
        async def post(self, url, json=None, **kw):
            captured.append({"url": url, "json": json})
            return FakeResp()
        is_closed = False
        async def aclose(self): pass

    c = conn.OllamaConnector()
    orig_client = c._client
    c._client = lambda *a, **kw: asyncio.sleep(0, result=FakeClient())  # type: ignore

    # ① 未配置 → payload 不含 options（向后兼容铁律）
    setcfg()
    captured.clear()
    await c.chat("qwen3.8", [{"role": "user", "content": "hi"}])
    body = captured[0]["json"] if captured else {}
    check("P-1 ⛔ 未配置 → payload 无 options 键", "options" not in body, str(list(body.keys())))
    check("P-2 未配置 → payload 基础键完整",
          set(body.keys()) == {"model", "messages", "stream"}, str(list(body.keys())))

    # ② 配置后 → options 注入且值正确
    setcfg({"qwen3.8": {"num_ctx": 8192, "temperature": 0.2}})
    captured.clear()
    await c.chat("qwen3.8", [{"role": "user", "content": "hi"}])
    body = captured[0]["json"] if captured else {}
    check("P-3 配置后 → options 注入", body.get("options") == {"num_ctx": 8192, "temperature": 0.2},
          str(body.get("options")))

    # ③ 超时动态生效：改配置后 _client 收到的 reading/connect 是新值
    setcfg(timeout_reading=123, timeout_connect=7)
    seen: dict = {}
    async def spy_client(reading=None, connect=None):
        seen["reading"] = reading if reading is not None else io.timeout_reading()
        seen["connect"] = connect if connect is not None else io.timeout_connect()
        return FakeClient()
    c._client = spy_client  # type: ignore
    captured.clear()
    await c.chat("qwen3.8", [{"role": "user", "content": "hi"}])
    check("P-4 A1 超时动态取值（非模块加载时冻结）",
          seen.get("reading") == 123.0 and seen.get("connect") == 7.0, str(seen))

    c._client = orig_client  # type: ignore
    await c.aclose_all()


if __name__ == "__main__":
    main()
