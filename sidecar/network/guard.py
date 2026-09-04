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
"""Network egress guard (P1-3 网络开关 → 2026-08-28 融合方案重构).

═══════════════════════════════════════════════════════════════════════
CONTRACT — 所有出站 HTTP 必须过此函数
═══════════════════════════════════════════════════════════════════════
Any code path that initiates an outbound HTTP(S) request on behalf of the
Agent — OllamaConnector, plugin hooks, future tools, etc. — MUST call
`guard_request(host)` before sending and act on the result:

  proxies = assert_guard(host)        # 推荐：被拒自动 raise NetworkGuardError
  # 等价于：
  #   proxies, reason = guard_request(host)
  #   if reason is not None: raise NetworkGuardError(reason, host)
  # 然后：proxies 为 None → 直连；否则把 proxies['http'] 挂到 httpx client

This is the single choke point. Do NOT open raw sockets / httpx clients
bypassing it.  The guard only controls *Agent* egress; it never touches
the user's own browsing.

网络模式（network_switch 三态，2026-08-28 融合方案）：
  * auto（默认）：本地/境内/放行名单直连；境外域名【放行直连尝试】，
    由调用方实测；失败经 guard_report_failure 计入熔断，连续失败达阈值后
    该域名后续请求秒拒（防无代理时空转/死循环——本项目的立项红线）。
  * proxy：境外域名走配置代理（用户已启动代理软件时使用）。
  * off / on：遗留值，读时自动迁移为 auto / proxy（配置层处理）。

熔断器（进程级内存，sidecar 重启清零）：
  * 连续失败 CIRCUIT_THRESHOLD 次 → 熔断，CIRCUIT_WINDOW 秒内秒拒；
  * 窗口过期自动恢复重试；成功一次即清零。
  * 调用方职责：请求失败 → guard_report_failure(host)；成功 → guard_report_success(host)。

Design rules (硬性):
  * NO hardcoded hostnames / ports / paths — everything reads from
    get_config(). The ONLY literals are the *fixed private/loopback
    network segments* below, which are a protocol constant (RFC 1918 /
    IANA loopback) and are explicitly allowed.
"""
from __future__ import annotations

import ipaddress
import threading
import time
from typing import Any
from urllib.parse import urlparse

# ── 白名单固定网段（协议常量，非配置；RFC1918 + IANA loopback）──────────
# 这些是"本地/内网"的判定依据，属网络层常量，允许硬编码。
_PRIVATE_NETS: list[ipaddress.IPv4Network] = [
    ipaddress.ip_network("127.0.0.0/8"),     # loopback
    ipaddress.ip_network("10.0.0.0/8"),      # RFC1918
    ipaddress.ip_network("172.16.0.0/12"),   # RFC1918
    ipaddress.ip_network("192.168.0.0/16"),  # RFC1918
]
_LOCAL_HOSTNAMES = {"localhost", ""}
# 境内域名后缀（.cn / .com.cn）。其余域名不在此列 = 视为境外。
_CN_SUFFIXES = (".cn", ".com.cn")

# ── 熔断器常量（协议常量：防死循环的行为边界，非环境配置）──────────────
CIRCUIT_THRESHOLD = 2      # 连续失败次数达到即熔断
CIRCUIT_WINDOW = 300.0     # 熔断持续秒数（过期自动恢复重试）


class NetworkGuardError(RuntimeError):
    """Raised when an outbound request is refused by the network guard."""
    def __init__(self, message: str, host: str) -> None:
        super().__init__(message)
        self.host = host
        self.message = message


def _cfg() -> dict[str, Any]:
    from sidecar.config import get_config
    return get_config()


def _normalize_switch(raw: Any) -> str:
    """归一化网络开关：on→proxy / off→auto（遗留值），其余原样；未知→auto。"""
    s = str(raw or "").lower().strip()
    if s == "on":
        return "proxy"
    if s == "off":
        return "auto"
    if s in ("auto", "proxy"):
        return s
    return "auto"


# ── 熔断器（进程级，线程安全）──────────────────────────────────────────
_circuit: dict[str, dict[str, float]] = {}
_circuit_lock = threading.Lock()


def _circuit_key(host: str) -> str:
    return (host or "").lower().strip(".")


def guard_circuit_open(host: str) -> bool:
    """该域名当前是否处于熔断状态（未过期）。"""
    key = _circuit_key(host)
    with _circuit_lock:
        entry = _circuit.get(key)
        if not entry:
            return False
        until = entry.get("until", 0.0)
        if until <= 0:
            return False  # 仅在累计失败计数、尚未熔断 → 不拦截
        if time.monotonic() >= until:
            _circuit.pop(key, None)  # 熔断窗口过期 → 自动恢复
            return False
        return True


def guard_report_failure(host: str) -> None:
    """调用方报告出站失败：累计失败次数，达阈值即熔断。"""
    key = _circuit_key(host)
    if not key:
        return
    with _circuit_lock:
        entry = _circuit.get(key) or {"fails": 0.0, "until": 0.0}
        entry["fails"] = entry.get("fails", 0) + 1
        if entry["fails"] >= CIRCUIT_THRESHOLD:
            entry["until"] = time.monotonic() + CIRCUIT_WINDOW
        _circuit[key] = entry


def guard_report_success(host: str) -> None:
    """调用方报告出站成功：清零该域名的失败计数与熔断。"""
    key = _circuit_key(host)
    with _circuit_lock:
        _circuit.pop(key, None)


def guard_reset_circuit() -> None:
    """清空全部熔断状态（测试/用户手动恢复用）。"""
    with _circuit_lock:
        _circuit.clear()


def _host_is_private_ip(host: str) -> bool:
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        return False
    if ip.version != 4:
        # IPv6 仅 loopback 视为本地（收紧：不再放行 unique-local/私网段）
        return ip.is_loopback
    return any(ip in net for net in _PRIVATE_NETS)


def _host_is_cn(host: str) -> bool:
    h = host.lower()
    for suf in _CN_SUFFIXES:
        if h == suf[1:] or h.endswith(suf):
            return True
    return False


def is_local_or_cn(host: str) -> bool:
    """True if host is local (loopback/RFC1918/link-local/localhost/
    configured sidecar or Ollama host) or a domestic (.cn/.com.cn) domain."""
    if not host:
        return True
    cfg = _cfg()
    h = host.lower().strip(".")
    if h in _LOCAL_HOSTNAMES:
        return True
    if _host_is_private_ip(h):
        return True
    # 配置中声明的本机出口（sidecar / Ollama）视为本地
    for key in ("sidecar_host",):
        v = cfg.get(key)
        if v and h == str(v).lower():
            return True
    try:
        ollama_host = (urlparse(cfg.get("ollama_base_url", "")).hostname or "").lower()
    except Exception:
        ollama_host = ""
    if ollama_host and h == ollama_host:
        return True
    return _host_is_cn(h)


def _allowlist_match(host: str, entries: list[str]) -> bool:
    """host 是否命中 egress_allowlist（精确匹配、*.xxx 通配、或裸域名匹配子域名）。

    2026-08-28 问题1修复：用户加 "so.com" 应同时放行 www.so.com / m.so.com 等子域名，
    否则搜索工具实际请求 www.so.com 时被拒，与用户预期不符。
    """
    h = (host or "").lower().strip(".")
    if not h:
        return False
    for e in entries:
        e = (e or "").strip().lower().rstrip(".")
        if not e:
            continue
        if e.startswith("*."):
            base = e[2:]
            # news.qq.com 命中 *.qq.com；qq.com 本身不命中
            if h.endswith("." + base) and len(h) > len(base) + 1:
                return True
        elif h == e:
            return True
        # 裸域名匹配子域名：so.com → www.so.com / m.so.com 均放行
        elif h.endswith("." + e) and len(h) > len(e) + 1:
            return True
    return False


def guard_request(host: str) -> tuple[dict[str, str] | None, str | None]:
    """Decide how to handle an outbound request to `host`.

    Returns:
        (proxies, reason)
        proxies: {"http": "http://127.0.0.1:<proxy_http_port>", "https": ...}
                 when mode=proxy and host is non-local; else None (= direct).
        reason:  a Chinese refusal message when the request must be BLOCKED;
                 else None (= allowed).

    Behavior（2026-08-28 三态融合方案）:
        local/CN/allowlist          -> (None, None)           # direct
        proxy + non-local           -> (proxy, None)          # via configured proxy
        auto  + non-local (未熔断)   -> (None, None)           # 直连尝试（由调用方实测）
        auto  + non-local (已熔断)   -> (None, "<refusal>")    # 秒拒，防无代理空转
        proxy 模式未配代理端口        -> (None, "<refusal>")
    """
    cfg = _cfg()
    mode = _normalize_switch(cfg.get("network_switch"))
    allowlist = cfg.get("egress_allowlist") or []

    # 1) 本地段 / 内网 / localhost / 配置 host / 境内 .cn → 放行（直连）
    if is_local_or_cn(host):
        return None, None
    # 2) 命中 egress_allowlist（精确或 *.xxx 通配）→ 放行，直连（不走代理）
    if _allowlist_match(host, allowlist):
        return None, None
    # 3) proxy 模式：境外域名走配置代理
    if mode == "proxy":
        proxy_port = int(cfg.get("proxy_http_port", 0))
        if not proxy_port:
            return None, (
                f"域名 {host} 不在放行名单内，且网络模式为「走代理」但未配置代理端口"
                f"（proxy_http_port），无法访问。"
            )
        proxy_base = f"http://127.0.0.1:{proxy_port}"
        return {"http": proxy_base, "https": proxy_base}, None
    # 4) auto 模式：检查熔断器——未熔断放行直连尝试；已熔断秒拒（防死循环红线）
    if guard_circuit_open(host):
        return None, (
            f"境外域名 {host} 近期连续 {CIRCUIT_THRESHOLD} 次访问失败（可能未开代理），"
            f"已暂停自动重试以避免空转（{int(CIRCUIT_WINDOW)} 秒后可再试）。"
            f"如需访问境外网站，请先启动代理软件，再把网络模式切为「走代理」。"
        )
    return None, None


def assert_guard(host: str) -> dict[str, str] | None:
    """便捷入口：调用 guard_request，若被拒则直接 raise NetworkGuardError。

    消灭"返回 (proxies, reason) 后忘记检查 reason"的陷阱。返回 proxies
    （None = 直连）。所有出站代码应优先使用本函数。
    """
    proxies, reason = guard_request(host)
    if reason is not None:
        raise NetworkGuardError(reason, host)
    return proxies
