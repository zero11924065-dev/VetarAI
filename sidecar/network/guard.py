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

网络模式（network_switch 两态；B11 / 0.4.13 起改为「需代理」名单制）：
  * auto（标准，默认）：本地/境内直连；境外域名【放行直连尝试】，由调用方实测；
    失败经 guard_report_failure 计入熔断，连续失败达阈值 → 秒拒（防无代理空转/死循环，
    本项目的立项红线）**并把该域名持久化写入 egress_proxy_required**；
    此后标准模式下命中名单直接拒绝并提示切「全量」。
  * proxy（全量）：境外域名一律走配置代理（用户已启动代理软件时使用）；
    「需代理」名单**不拦截**（名单只针对标准模式），但真不可达的站点仍受熔断保护。
  * off / on：遗留值，读时自动迁移为 auto / proxy（配置层处理）。

熔断器（进程级内存，sidecar 重启清零）：
  * 连续失败 CIRCUIT_THRESHOLD 次 → 熔断，CIRCUIT_WINDOW 秒内秒拒；
  * 窗口过期自动恢复重试；成功一次即清零。
  * 调用方职责：请求失败 → guard_report_failure(host)；成功 → guard_report_success(host)。
  * ⚠️ 熔断是**内存态**、名单是**持久态**：窗口过期后熔断放行，但若已入名单仍会被拦
    （这正是名单的价值——不必每 300 秒重新试错一遍）。
  * ⚠️ 切换 network_switch 会重置熔断器（见 config.store.reload_config）：熔断历史属
    "直连路径"，对"走代理路径"无参考价值；不重置会让切到全量后仍被秒拒，切换失去意义。

Design rules (硬性):
  * NO hardcoded hostnames / ports / paths — everything reads from
    get_config(). The ONLY literals are the *fixed private/loopback
    network segments* below, which are a protocol constant (RFC 1918 /
    IANA loopback) and are explicitly allowed.
"""
from __future__ import annotations

import ipaddress
import logging
import threading
import time
from typing import Any
from urllib.parse import urlparse

# D1（0.4.18）：模块级 logger。名单写入告警此前用 print（走 stdout 被丢弃）→ 改走 logging。
# ⛔ logging.getLogger 是标准库、不导入项目模块；本模块对 config 的依赖仍是函数内延迟导入，
#    故加 logger 不引入循环依赖。
_log = logging.getLogger("sidecar.guard")

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
    """调用方报告出站失败：累计失败次数，达阈值即熔断。

    B11（0.4.13）：熔断触发的那一刻，把该域名持久化写入「需代理」名单
    （egress_proxy_required），此后标准（auto）模式直接拒绝直连并提示切全量，
    不必每次都等熔断窗口。

    ⛔ 三条硬性约束（每条都对应一个真实陷阱）：
      ① **不得在持有 _circuit_lock 时写 config**——guard_request 的锁顺序是
         _LOCK(config) → _circuit_lock，若此处反向 _circuit_lock → _LOCK 会造成
         锁顺序反转死锁。故先在锁内算出结果、**释放锁后**再写。
      ② **境内/本地域名不入名单**——本函数由调用方直接调用、不经 guard_request，
         可能传入 .cn 域名；境内站走代理没有意义，写进去只会污染名单
         （is_local_or_cn 判定）。
      ③ **仅 auto（标准）模式下的失败才入名单**——proxy 模式下已经在走代理，
         失败说明该站"真不可达"，不代表"需代理"，写进去是错误结论。
    写入失败一律静默跳过：这是优化（提前拒绝），不该让调用方的请求流程崩溃。
    """
    key = _circuit_key(host)
    if not key:
        return
    newly_tripped = False
    with _circuit_lock:
        entry = _circuit.get(key) or {"fails": 0.0, "until": 0.0}
        entry["fails"] = entry.get("fails", 0) + 1
        if entry["fails"] >= CIRCUIT_THRESHOLD:
            already = entry.get("until", 0) > 0 and time.monotonic() < entry["until"]
            entry["until"] = time.monotonic() + CIRCUIT_WINDOW
            # 只在"本次刚跨入熔断"时入名单一次，避免每次失败都写盘
            newly_tripped = not already
        _circuit[key] = entry
    # ── 锁已释放，以下才碰 config（约束①）──
    if not newly_tripped:
        return
    try:
        if is_local_or_cn(key):          # 约束②：境内/本地不入名单
            return
        cfg = _cfg()
        if _normalize_switch(cfg.get("network_switch")) != "auto":  # 约束③
            return
        cur = list(cfg.get("egress_proxy_required") or [])
        if any(_domain_match(key, [e]) for e in cur):
            return                       # 已被现有条目覆盖（含通配），无需重复写
        cur.append(key)
        # 延迟导入避免模块级循环（config 的 reload_config 也会反向导入本模块）
        from sidecar.config import reload_config
        reload_config({"egress_proxy_required": cur})
    except Exception as e:
        # 名单写入是优化项，失败不得影响调用方的降级/重试流程
        _log.warning("写入「需代理」名单失败（%s）: %s", key, e)


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


def _domain_match(host: str, entries: list[str]) -> bool:
    """host 是否命中域名名单（精确匹配、*.xxx 通配、或裸域名匹配子域名）。

    2026-08-28 问题1修复：用户加 "so.com" 应同时覆盖 www.so.com / m.so.com 等子域名。
    B11（0.4.13）：原 `_allowlist_match`，随白名单→「需代理」名单改造更名。
    匹配算法未变——它判定的是"host 是否落在这些域名条目内"，与名单语义（放行/拦截）无关，
    语义由调用方（guard_request 的分支）决定，故可直接复用。
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

    Behavior（B11 / 0.4.13：白名单制 → 「需代理」名单制）:
        local/CN                          -> (None, None)        # 直连（境内/本地始终可达）
        proxy（全量）+ 已熔断             -> (None, "<refusal>") # 真不可达，停止空转
        proxy（全量）+ 其余境外           -> (proxy, None)       # 一律走代理，名单不拦截
        proxy 模式未配代理端口            -> (None, "<refusal>")
        auto（标准）+ 命中「需代理」名单  -> (None, "<refusal>") # 已知需代理，直接拒并提示切全量
        auto（标准）+ 已熔断              -> (None, "<refusal>") # 秒拒，防无代理空转
        auto（标准）+ 其余境外            -> (None, None)        # 直连尝试（由调用方实测）

    ⛔ 名单**只在 auto 分支检查**：全量模式下命中名单仍走代理放行（用户拍板），
      否则名单会反过来破坏全量模式；但全量模式仍受熔断保护——某些站点是真无法访问。
    ⛔ auto 分支顺序为「名单 → 熔断」：名单是跨重启的持久记忆（熔断窗口只有 300s，
      过期后名单仍拦住），且能给出"该切全量"的明确指引；熔断兜住尚未入名单的新站点。
    """
    cfg = _cfg()
    mode = _normalize_switch(cfg.get("network_switch"))

    # 1) 本地段 / 内网 / localhost / 配置 host / 境内 .cn → 放行（直连）
    if is_local_or_cn(host):
        return None, None

    # 2) proxy（全量）模式：境外域名一律走配置代理；「需代理」名单不拦截
    if mode == "proxy":
        # 真不可达的站点仍受熔断保护（用户拍板：全量下"也要注意熔断"）。
        # 注意切换网络模式会重置熔断器（store.reload_config），故刚切过来必有干净起点。
        if guard_circuit_open(host):
            return None, (
                f"境外域名 {host} 在全量模式下仍连续 {CIRCUIT_THRESHOLD} 次访问失败，"
                f"已暂停自动重试以避免空转（{int(CIRCUIT_WINDOW)} 秒后可再试）。"
                f"该站点可能确实无法访问，或代理软件未正常运行。"
            )
        proxy_port = int(cfg.get("proxy_http_port", 0))
        if not proxy_port:
            return None, (
                f"域名 {host} 需经代理访问，但网络模式为「全量」却未配置代理端口"
                f"（proxy_http_port），无法访问。"
            )
        proxy_base = f"http://127.0.0.1:{proxy_port}"
        return {"http": proxy_base, "https": proxy_base}, None

    # 3) auto（标准）模式：先查「需代理」名单，再查熔断
    proxy_required = cfg.get("egress_proxy_required") or []
    if _domain_match(host, proxy_required):
        return None, (
            f"域名 {host} 在「需代理」名单内，标准模式下无法直连。"
            f"如需访问，请先启动代理软件，再把网络模式切为「全量」；"
            f"或在 设置→网络 中把它移出「需代理」名单。"
        )
    if guard_circuit_open(host):
        return None, (
            f"境外域名 {host} 近期连续 {CIRCUIT_THRESHOLD} 次访问失败（可能未开代理），"
            f"已暂停自动重试以避免空转（{int(CIRCUIT_WINDOW)} 秒后可再试），"
            f"并已记入「需代理」名单。如需访问境外网站，请先启动代理软件，"
            f"再把网络模式切为「全量」。"
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
