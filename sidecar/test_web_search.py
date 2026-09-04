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
"""TS-104 R01 联网搜索单测（mock 搜索响应，不真实出站）。
覆盖：入参契约 / 多源自动降级 / 熔断上报 / mock 结果解析 / RETURN_SCHEMA / tools_spec 注册。
2026-08-28 融合方案适配：旧"OFF 发起前拒绝"语义已改为"放行尝试+失败熔断+多源降级"。
venv 内直接跑：python test_web_search.py。
"""
import asyncio, sys
from pathlib import Path

import httpx

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

PASS, FAIL = 0, 0
FAILURES = []

def check(name, cond, detail=""):
    global PASS, FAIL
    if cond: PASS += 1; print(f"PASS  {name}")
    else: FAIL += 1; FAILURES.append(name); print(f"FAIL  {name}  {detail}")


MOCK_DDG_HTML = '''
<div class="result">
  <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fweather.example.com%2Fbeijing&amp;rut=abc">北京天气预报</a>
</div>
<div class="result">
  <a class="result__snippet" href="#">北京今天晴，气温 20-28°C，适合出行。</a>
</div>
<div class="result">
  <a rel="nofollow" class="result__a" href="https://news.example.cn/bj">北京新闻</a>
</div>
'''


async def main():
    import sidecar.config as cfgmod
    import sidecar.network.guard as guard
    from sidecar.tools import execute, TOOLS
    from sidecar.agent_engine.loop import tools_spec
    guard.guard_reset_circuit()

    # ── 1. 入参契约 ──
    cfgmod.get_config = lambda: {"network_switch": "auto",
                                 "web_search_url": "https://search.example.com/q",
                                 "egress_allowlist": []}
    r = await execute("web_search", {}, "/tmp")
    check("1 缺 query → bad_arg", r.get("ok") is False and "bad_arg" in r.get("error", ""), str(r))

    # ── 2. 全源连接失败 → 结构化错误 + 熔断秒拒（融合方案：不再发起前拒绝）──
    # 注意：两个端点域名都不在放行名单——名单命中的域名是用户明确放行，不走熔断
    import sidecar.tools.web_search as ws

    class FailClient:
        def __init__(self, **kw): pass
        async def __aenter__(self): return self
        async def __aexit__(self, *a): return False
        async def get(self, url, params=None, headers=None): raise httpx.ConnectError("conn fail")
        async def post(self, url, data=None, headers=None): raise httpx.ConnectError("conn fail")

    orig_client = ws.httpx.AsyncClient
    ws.httpx.AsyncClient = lambda **kw: FailClient()
    cfgmod.get_config = lambda: {"network_switch": "auto",
                                 "web_search_url": "https://search.example.com/q",
                                 "web_search_url_cn": "https://cn.example.com/s",
                                 "egress_allowlist": []}
    r = await execute("web_search", {"query": "北京天气"}, "/tmp")
    check("2 全源失败 → search_failed（不假装成功）",
          r.get("ok") is False and r.get("error", "").startswith("search_failed"), str(r)[:200])
    check("2 错误含各源失败明细", "search.example.com" in str(r.get("error", "")) or "cn.example.com" in str(r.get("error", "")), str(r)[:200])
    # 再搜一次 → 每源累计失败 2 次达到熔断阈值，第三次应被秒拒
    await execute("web_search", {"query": "再来一次"}, "/tmp")
    r3 = await execute("web_search", {"query": "第三次"}, "/tmp")
    # TS-105 后：熔断开启时 web_search 直接返回"已熔断"（预检短路），不再走 assert_guard 秒拒
    check("2 连续失败后熔断秒拒（错误含「已熔断」或「暂停自动重试」）",
          r3.get("ok") is False and ("已熔断" in str(r3.get("error", "")) or "暂停自动重试" in str(r3.get("error", ""))), str(r3)[:250])
    guard.guard_reset_circuit()
    ws.httpx.AsyncClient = orig_client

    # ── 3. 多源自动降级：首源失败 → 自动切次源成功（融合方案核心）──
    MOCK_SO_HTML = '''
<li class="res-list"><h3 class="res-title"><a href="https://weather.example.cn/bj">北京天气预报</a></h3><p class="res-desc">北京今日多云转晴，气温18-26°C。</p></li>
<li class="res-list"><h3 class="res-title"><a href="https://news.example.cn/bj">北京新闻</a></h3><p class="res-desc">北京市最新新闻动态。</p></li>
'''

    call_log = []

    class DegradeClient:
        """首源（cn.example.com）抛连接失败；次源（www.so.com）返回正常结果。"""
        def __init__(self, **kw): pass
        async def __aenter__(self): return self
        async def __aexit__(self, *a): return False
        async def get(self, url, params=None, headers=None):
            call_log.append(("GET", url))
            if "cn.example.com" in url:
                raise httpx.ConnectError("conn fail")
            return FakeResp()
        async def post(self, url, data=None, headers=None):
            call_log.append(("POST", url))
            if "cn.example.com" in url:
                raise httpx.ConnectError("conn fail")
            return FakeResp()

    class FakeResp:
        status_code = 200
        text = MOCK_SO_HTML

    ws.httpx.AsyncClient = lambda **kw: DegradeClient()
    cfgmod.get_config = lambda: {"network_switch": "auto",
                                 "web_search_url": "https://www.so.com/s",
                                 "web_search_url_cn": "https://cn.example.com/s",
                                 "egress_allowlist": ["so.com"]}
    r = await execute("web_search", {"query": "北京天气", "max_results": 5}, "/tmp")
    check("3 首源失败自动降级次源 → ok", r.get("ok") is True, str(r)[:200])
    check("3 确实先试了首源再切次源", len(call_log) >= 2 and "cn.example.com" in call_log[0][1] and "so.com" in call_log[1][1], str(call_log))
    res = r.get("results", [])
    check("3 解析出 2 条结果", len(res) == 2, str(res)[:200])
    check("3 标题/链接正确",
          res[0]["url"] == "https://weather.example.cn/bj" and res[0]["title"] == "北京天气预报", str(res[0]))
    check("3 摘要正确", "18-26°C" in res[0].get("snippet", ""), str(res[0]))
    check("3 次源成功已清零熔断计数", not guard.guard_circuit_open("www.so.com"))
    ws.httpx.AsyncClient = orig_client

    # ── 3b. proxy 模式源顺序：国际源优先 ──
    call_log.clear()
    ws.httpx.AsyncClient = lambda **kw: DegradeClient()
    cfgmod.get_config = lambda: {"network_switch": "proxy",
                                 "web_search_url": "https://www.so.com/s",
                                 "web_search_url_cn": "https://cn.example.com/s",
                                 "proxy_http_port": 21081,
                                 "egress_allowlist": ["so.com"]}
    r = await execute("web_search", {"query": "x"}, "/tmp")
    check("3b proxy 模式国际源排前（先请求 so.com）", len(call_log) >= 1 and "so.com" in call_log[0][1], str(call_log))
    ws.httpx.AsyncClient = orig_client
    guard.guard_reset_circuit()

    # ── 4. RETURN_SCHEMA 契约 ──
    check("4 web_search 已注册进 TOOLS", "web_search" in TOOLS)
    schema = TOOLS["web_search"]["return_schema"]
    from sidecar.tools.registry import _validate
    bad = {"ok": True, "results": [{"title": "x"}]}  # 缺 url/snippet
    probs = _validate(bad, schema)
    check("4 schema 校验缺字段报错", any(p.startswith("bad_entry") for p in probs), str(probs))
    good = {"ok": True, "results": [{"title": "t", "url": "u", "snippet": "s"}]}
    check("4 合法结构校验通过", _validate(good, schema) == [])

    # ── 5. tools_spec 注册（模型可调用）──
    spec = tools_spec()
    names = [s["function"]["name"] for s in spec]
    # TS-107 新增 delegate_task、TS-110 新增 read_skill、checkpoint-066 新增 install_plugin/install_skill 后共 10 工具；
    # with_delegation=False 剔除 delegate 为 9
    check("5 tools_spec 含 web_search（共 10 工具）", "web_search" in names and len(spec) == 10, str(names))
    check("5 tools_spec 含 delegate_task（主会话可委派）", "delegate_task" in names, str(names))
    check("5 tools_spec 含 install_plugin/install_skill（checkpoint-066）",
          "install_plugin" in names and "install_skill" in names, str(names))
    names_sub = [s["function"]["name"] for s in tools_spec(with_delegation=False)]
    check("5 子会话 spec 剔除 delegate_task（防递归）",
          "delegate_task" not in names_sub and len(names_sub) == 9, str(names_sub))
    ws_spec = next(s for s in spec if s["function"]["name"] == "web_search")
    check("5 web_search spec 必填 query",
          ws_spec["function"]["parameters"].get("required") == ["query"])

    # ── 6. 网络工具不受沙盒约束（不同 sandbox_root 结果一致）──
    class OkClient:
        def __init__(self, **kw): pass
        async def __aenter__(self): return self
        async def __aexit__(self, *a): return False
        async def get(self, url, params=None, headers=None): return FakeResp()
        async def post(self, url, data=None, headers=None): return FakeResp()

    ws.httpx.AsyncClient = lambda **kw: OkClient()
    cfgmod.get_config = lambda: {"network_switch": "auto",
                                 "web_search_url": "https://html.duckduckgo.com/html/",
                                 "web_search_url_cn": "https://www.so.com/s",
                                 "egress_allowlist": ["so.com"]}
    r1 = await execute("web_search", {"query": "x"}, "/tmp/any_sandbox_1")
    r2 = await execute("web_search", {"query": "x"}, "/tmp/any_sandbox_2")
    check("6 web_search 不走沙盒（任意 sandbox_root 均放行）",
          r1.get("ok") is True and r2.get("ok") is True)
    ws.httpx.AsyncClient = orig_client

    # ── 7. 零硬编码：端点从 config 读 ──
    import inspect
    src = inspect.getsource(ws)
    check("7 模块内无硬编码搜索域名（duckduckgo 仅默认值在 config）",
          "duckduckgo.com" not in src, "发现硬编码端点")

    # ── 8. 回归：禁止拾取环境变量代理（trust_env=False，2026-08-28 架构修复）──
    # 背景：HTTP_PROXY 环境变量会让 httpx 默认走代理，绕过守卫的唯一漏斗契约，
    # 把境内流量也劫持到未监听的代理端口（用户"查金价"全源失败的根因）。
    captured_kwargs = {}

    class SpyClient:
        def __init__(self, **kw): captured_kwargs.update(kw)
        async def __aenter__(self): return self
        async def __aexit__(self, *a): return False
        async def get(self, url, params=None, headers=None): return FakeResp()
        async def post(self, url, data=None, headers=None): return FakeResp()

    ws.httpx.AsyncClient = SpyClient
    await execute("web_search", {"query": "x"}, "/tmp")
    check("8 AsyncClient 显式 trust_env=False（不拾取环境变量代理）",
          captured_kwargs.get("trust_env") is False, str(captured_kwargs))
    ws.httpx.AsyncClient = orig_client

    # ── 9. 回归：插件加载器剥离子进程代理变量 ──
    from sidecar.plugin_loader import loader as ld
    import os as _os
    old_env = dict(_os.environ)
    _os.environ["HTTP_PROXY"] = "http://127.0.0.1:21081"
    _os.environ["https_proxy"] = "http://127.0.0.1:21081"
    cleaned = ld._egress_env()
    check("9 _egress_env 剥离全部代理变量",
          all(k not in cleaned for k in ld._PROXY_ENV_KEYS), str({k: cleaned.get(k) for k in ld._PROXY_ENV_KEYS}))
    check("9 其余环境变量保留", "PATH" in cleaned)
    # 恢复
    for k in ("HTTP_PROXY", "https_proxy"):
        _os.environ.pop(k, None)
    _os.environ.update(old_env)

    # ── 10. TS-105 搜索熔断感知停止：错误信息携带熔断状态 ──
    # 场景 A：熔断开启 + 全源失败 → error 含「已熔断」，circuit_open=True，retry_after_seconds=300
    guard.guard_reset_circuit()
    guard.guard_report_failure("intl.example.com")   # 1 次失败
    guard.guard_report_failure("intl.example.com")   # 2 次 → 熔断开启
    check("10A 前置：熔断器已开启", guard.guard_circuit_open("intl.example.com") is True)
    cfgmod.get_config = lambda: {"network_switch": "auto",
                                 "web_search_url": "https://intl.example.com/q",
                                 "egress_allowlist": []}
    ws.httpx.AsyncClient = lambda **kw: FailClient()
    r = await execute("web_search", {"query": "今日金价"}, "/tmp")
    check("10A 熔断开启+全源失败 → error 含「已熔断」",
          r.get("ok") is False and "已熔断" in str(r.get("error", "")), str(r)[:250])
    check("10A circuit_open=True", r.get("circuit_open") is True, str(r)[:200])
    check("10A retry_after_seconds=300", r.get("retry_after_seconds") == 300, str(r)[:200])
    check("10A error 不再描述为「所有搜索源均不可用」",
          "所有搜索源均不可用" not in str(r.get("error", "")), str(r.get("error", "")))

    # 场景 B：熔断关闭 + 全源失败 → error 保持原样，circuit_open=False，retry_after_seconds=0
    guard.guard_reset_circuit()
    cfgmod.get_config = lambda: {"network_switch": "auto",
                                 "web_search_url": "https://search.example.com/q",
                                 "egress_allowlist": []}
    r = await execute("web_search", {"query": "x"}, "/tmp")
    check("10B 熔断关闭+全源失败 → error 保持原样（所有搜索源均不可用）",
          r.get("ok") is False and "所有搜索源均不可用" in str(r.get("error", "")), str(r)[:250])
    check("10B circuit_open=False", r.get("circuit_open") is False, str(r)[:200])
    check("10B retry_after_seconds=0", r.get("retry_after_seconds") == 0, str(r)[:200])

    # 场景 C：auto 模式 + 熔断开启 → error 含「启动代理」可操作指引
    guard.guard_reset_circuit()
    guard.guard_report_failure("intl2.example.com")
    guard.guard_report_failure("intl2.example.com")
    cfgmod.get_config = lambda: {"network_switch": "auto",
                                 "web_search_url": "https://intl2.example.com/q",
                                 "egress_allowlist": []}
    r = await execute("web_search", {"query": "今日金价"}, "/tmp")
    check("10C auto+熔断开启 → error 含「启动代理」指引",
          r.get("ok") is False and "已熔断" in str(r.get("error", "")) and "启动代理" in str(r.get("error", "")),
          str(r.get("error", ""))[:300])
    guard.guard_reset_circuit()
    ws.httpx.AsyncClient = orig_client

    print(f"\n===== TS-104+TS-105 专项: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("FAILED:", ", ".join(FAILURES))
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
