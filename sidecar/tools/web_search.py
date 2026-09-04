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
"""联网搜索工具（TS-104 R01 → 2026-08-28 融合方案：多源自动降级）。

契约（与 M1-1 文件工具一致）：
- 入参：{"query": str (required), "max_results": int (optional, 默认 5, 上限 10)}
- 返回：{"ok": bool, "results": [{"title","url","snippet"}]} 或 {"ok": false, "error": ...}
- 出站 100% 过 guard（安全红线）：端点地址从 config 读取（零硬编码）

多源自动降级（2026-08-28 融合方案，确定性切换，不依赖模型判断）：
- 按网络模式决定源顺序：auto → 国内源优先；proxy → 国际源优先
- 某源失败（guard 拒绝/连接失败/解析 0 条）→ 自动切下一源，全程无需用户干预
- 境外源失败经 guard_report_failure 计入熔断（防无代理时空转——立项红线）
- 全部源失败 → 返回结构化错误，由 Agent 如实转述
只返回标题/链接/摘要（轻量形态），不抓正文。
"""
from __future__ import annotations

import html as _html
import re as _re
from typing import Any

import httpx

from sidecar.network.guard import (
    assert_guard, NetworkGuardError, guard_circuit_open, guard_report_failure,
    guard_report_success, CIRCUIT_WINDOW,
)

CONNECT_TIMEOUT = 5.0          # 融合方案：境外失败快速熔断，缩短到 5s（原 10s）
SEARCH_READ_TIMEOUT = 30.0
DEFAULT_MAX_RESULTS = 5
MAX_MAX_RESULTS = 10

WEB_SEARCH_RETURN = {
    "required": ["ok", "results"],
    "types": {"ok": bool, "results": list},
    "entry_keys": {"title", "url", "snippet"},
    "entry_field": "results",  # 条目字段名（registry._validate 默认 entries，此处为 results）
}


def _mode() -> str:
    """归一化网络模式（与 guard._normalize_switch 同语义）。"""
    from sidecar.config import get_config as _gc
    s = str(_gc().get("network_switch", "")).lower().strip()
    if s == "on":
        return "proxy"
    if s == "off":
        return "auto"
    return s if s in ("auto", "proxy") else "auto"


def _source_chain() -> list[tuple[str, str, bool]]:
    """按网络模式返回有序源链 [(端点, host, is_cn), ...]。

    auto  → 国内源优先（境内直连可靠），失败降级国际源
    proxy → 国际源优先（已挂代理），失败降级国内源
    延迟导入读最新 config，设置面板改配置即时生效。
    """
    from urllib.parse import urlparse
    from sidecar.config import get_config as _gc
    cfg = _gc()
    cn_url = str(cfg.get("web_search_url_cn") or "").strip()
    intl_url = str(cfg.get("web_search_url") or "").strip()
    chain: list[tuple[str, str, bool]] = []
    for url, is_cn in ((cn_url, True), (intl_url, False)):
        if url:
            chain.append((url, urlparse(url).hostname or "", is_cn))
    if _mode() == "proxy":
        chain = sorted(chain, key=lambda x: x[2])  # 国际源（is_cn=False）排前
    return chain


def _parse_duckduckgo_html(body: str, max_results: int) -> list[dict[str, str]]:
    """解析 DuckDuckGo HTML 结果页：提取标题/链接/摘要。"""
    results: list[dict[str, str]] = []
    anchors = _re.findall(
        r'class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>', body, _re.S)
    snippets = _re.findall(
        r'class="result__snippet"[^>]*>(.*?)</a>', body, _re.S)
    for i, (href, title_html) in enumerate(anchors):
        if i >= max_results:
            break
        url = _html.unescape(href)
        m = _re.search(r'uddg=([^&]+)', url)
        if m:
            from urllib.parse import unquote
            url = unquote(m.group(1))
        title = _html.unescape(_re.sub(r'<[^>]+>', '', title_html)).strip()
        snippet = ""
        if i < len(snippets):
            snippet = _html.unescape(_re.sub(r'<[^>]+>', '', snippets[i])).strip()
        if not title or not url:
            continue
        results.append({"title": title, "url": url, "snippet": snippet})
    return results


def _parse_baidu_html(body: str, max_results: int) -> list[dict[str, str]]:
    """解析百度搜索结果页：提取标题/链接/摘要。"""
    results: list[dict[str, str]] = []
    anchors = _re.findall(
        r'<h3[^>]*>\s*<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>', body, _re.S)
    snippets = _re.findall(
        r'class="[^"]*(?:content-right|c-abstract)[^"]*"[^>]*>(.*?)</(?:span|div)>', body, _re.S)
    for i, (href, title_html) in enumerate(anchors):
        if i >= max_results:
            break
        url = _html.unescape(href).strip()
        title = _html.unescape(_re.sub(r'<[^>]+>', '', title_html)).strip()
        snippet = ""
        if i < len(snippets):
            snippet = _html.unescape(_re.sub(r'<[^>]+>', '', snippets[i])).strip()
        if not title or not url:
            continue
        results.append({"title": title, "url": url, "snippet": snippet})
    return results


def _parse_so_html(body: str, max_results: int) -> list[dict[str, str]]:
    """解析 360 搜索（so.com）结果页：服务端渲染，结构稳定。"""
    results: list[dict[str, str]] = []
    anchors = _re.findall(
        r'<h3[^>]*class="[^"]*(?:res-title|title)[^"]*"[^>]*>\s*<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>',
        body, _re.S)
    snippets = _re.findall(
        r'class="[^"]*res-desc[^"]*"[^>]*>(.*?)</p>', body, _re.S)
    for i, (href, title_html) in enumerate(anchors):
        if i >= max_results:
            break
        url = _html.unescape(href).strip()
        title = _html.unescape(_re.sub(r'<[^>]+>', '', title_html)).strip()
        snippet = ""
        if i < len(snippets):
            snippet = _html.unescape(_re.sub(r'<[^>]+>', '', snippets[i])).strip()
        if not title or not url:
            continue
        results.append({"title": title, "url": url, "snippet": snippet})
    return results


def _parser_for(host: str):
    """按域名选解析器。"""
    hn = (host or "").lower()
    if "so.com" in hn:
        return _parse_so_html
    if "baidu" in hn:
        return _parse_baidu_html
    return _parse_duckduckgo_html


async def web_search(args: dict) -> dict[str, Any]:
    """联网搜索（唯一出站口，必经 guard；多源自动降级）。"""
    query = args.get("query")
    if not isinstance(query, str) or not query.strip():
        return {"ok": False, "error": "bad_arg: query"}
    max_results = args.get("max_results", DEFAULT_MAX_RESULTS)
    if not isinstance(max_results, int) or max_results < 1:
        max_results = DEFAULT_MAX_RESULTS
    max_results = min(max_results, MAX_MAX_RESULTS)

    chain = _source_chain()
    if not chain:
        return {"ok": False, "error": "search_failed: 搜索端点未配置（web_search_url / web_search_url_cn）"}

    # TS-105：循环前预检——若国际源已熔断，直接返回（不浪费时间再试）
    # 这解决了"第 1 次搜索后熔断才打开，web_search 第 1 次返回时 circuit_open 还是 False"的时序问题
    _pre_circuit = any(not is_cn and guard_circuit_open(h) for (_u, h, is_cn) in chain)
    if _pre_circuit:
        _detail = "（熔断器已开启，未发起真实请求）"
        err = "search_failed: 境外搜索源已熔断（连续失败触发熔断器，300 秒内重试无效）" + _detail
        if _mode() == "auto":
            err += ("；请停止尝试境外源；如用户需要境外信息，请告知用户先启动代理软件"
                    '并把网络模式切为"走代理"，然后我会自动恢复。')
        return {"ok": False, "error": err,
                "circuit_open": True,
                "retry_after_seconds": int(CIRCUIT_WINDOW)}

    errors: list[str] = []
    for url, host, is_cn in chain:
        # 安全红线：出站必过 guard（熔断后秒拒 / 未配代理 → NetworkGuardError）
        try:
            proxies = assert_guard(host)
        except NetworkGuardError as e:
            errors.append(f"{host}: {e.message}")
            continue  # 自动降级：切下一源
        kwargs: dict[str, Any] = {"timeout": httpx.Timeout(SEARCH_READ_TIMEOUT, connect=CONNECT_TIMEOUT),
                                  "trust_env": False}
        if proxies:
            kwargs["proxy"] = proxies["http"]
        try:
            async with httpx.AsyncClient(**kwargs) as client:
                if is_cn:
                    params_key = "wd" if "baidu" in host else "q"
                    r = await client.get(url, params={params_key: query},
                                         headers={"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 SubAgent"})
                else:
                    r = await client.post(url, data={"q": query},
                                          headers={"User-Agent": "Mozilla/5.0 (SubAgent local tool)"})
                if r.status_code != 200:
                    guard_report_failure(host)
                    errors.append(f"{host}: HTTP {r.status_code}")
                    continue  # 自动降级
                results = _parser_for(host)(r.text, max_results)
                if not results:
                    # 解析 0 条（反爬/验证码/结构变更）→ 视为该源不可用，降级
                    errors.append(f"{host}: 无可用结果")
                    continue
                guard_report_success(host)
                return {"ok": True, "results": results, "query": query, "source": host}
        except (httpx.ConnectError, httpx.TimeoutException, httpx.HTTPError) as e:
            # 连接级失败 → 计入熔断（防无代理空转），自动降级下一源
            guard_report_failure(host)
            errors.append(f"{host}: 连接失败/超时（{type(e).__name__}）")
            continue
        except Exception as e:  # 其余异常不裸抛，降级
            errors.append(f"{host}: {type(e).__name__}")
            continue

    # TS-105 搜索熔断感知停止：全源失败时若熔断器已开启（含本次搜索导致打开），
    # error 必须表达"已熔断"（不得说"所有搜索源均不可用"——会误导模型换近义词无限重试）
    # 注意：guard_circuit_open 只在 fails >= CIRCUIT_THRESHOLD 且 until > 0 时返回 True，
    # 所以"本次搜索导致熔断打开"的场景也会被捕获（循环内 guard_report_failure 已更新 _circuit）
    circuit_hosts = [h for (_u, h, is_cn) in chain if not is_cn and guard_circuit_open(h)]
    circuit_open = bool(circuit_hosts)
    detail = "；".join(errors[:3])
    if circuit_open:
        err = ("search_failed: 境外搜索源已熔断（连续失败触发熔断器，300 秒内重试无效）—— " + detail)
        if _mode() == "auto":
            err += ("；请停止尝试境外源；如用户需要境外信息，请告知用户先启动代理软件"
                    '并把网络模式切为“走代理”，然后我会自动恢复。')
    else:
        err = "search_failed: 所有搜索源均不可用 —— " + detail
    return {"ok": False, "error": err,
            "circuit_open": circuit_open,
            "retry_after_seconds": int(CIRCUIT_WINDOW) if circuit_open else 0}
