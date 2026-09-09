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
"""B11（0.4.13）专项：网络访问「白名单制」→「需代理」名单制。

覆盖（每条对应用户拍板的一条语义）：
  ① auto（标准）：境内/本地直连；境外不在名单且未熔断 → 直连尝试（现状不变）
  ② auto：命中「需代理」名单 → 拒绝直连，提示切全量
  ③ auto：连续失败触发熔断 → 域名**持久化**写入名单（此后不必等熔断窗口）
  ④ proxy（全量）：命中名单**仍走代理放行**（名单不拦截全量）
  ⑤ proxy：已熔断 → 拒绝（真不可达的站点仍受保护）
  ⑥ legacy 清理：磁盘残留 egress_allowlist 被 get_config 主动 pop（不迁移、不报错）
  ⑦ 切换 network_switch → 熔断器重置（否则 auto 熔断的站切到全量仍被秒拒，切换失去意义）
  ⑧ 熔断写入的三条防护：境内域名不入名单 / 仅 auto 模式入名单 / 不重复写已有条目

⛔ 本文件必须自隔离：guard_report_failure 会真写 config.json。
   模块级钉死 config.store.get_config_path 到临时目录（项目既有纪律），
   绝不触碰用户真实 ~/.subagent/config.json（0.4.13 曾实测污染一次，已逐字节还原）。
"""
from __future__ import annotations

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


# ── 模块级隔离（必须在任何 config/guard 调用之前）──────────────────────
_TMP = Path(tempfile.mkdtemp(prefix="b11_"))
import sidecar.config.store as cs          # noqa: E402
cs.get_config_path = lambda: _TMP / "config.json"
import sidecar.network.guard as guard      # noqa: E402
import sidecar.config as cfgmod            # noqa: E402


def _write_disk_cfg(d: dict) -> None:
    """直接写"磁盘"config.json（绕过 reload_config 的迁移逻辑，模拟用户旧配置）。"""
    import json
    p = cs.get_config_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(d, ensure_ascii=False), encoding="utf-8")


def _reset() -> None:
    guard.guard_reset_circuit()
    _write_disk_cfg({
        "ollama_base_url": "http://localhost:11434",
        "proxy_http_port": 21081,
        "network_switch": "auto",
        "egress_proxy_required": [],
    })


def main() -> None:
    # ── ① auto 基准：境内直连 / 境外未熔断直连尝试 ──
    _reset()
    p, r = guard.guard_request("localhost")
    check("① auto 本地直连", p is None and r is None, str((p, r)))
    p, r = guard.guard_request("www.example.cn")
    check("① auto 境内 .cn 直连", p is None and r is None, str((p, r)))
    p, r = guard.guard_request("openai.com")
    check("① auto 境外不在名单且未熔断 → 直连尝试", p is None and r is None, str((p, r)))

    # ── ② auto + 命中名单 → 拒绝并提示切全量 ──
    _reset()
    _write_disk_cfg({
        "ollama_base_url": "http://localhost:11434",
        "proxy_http_port": 21081,
        "network_switch": "auto",
        "egress_proxy_required": ["openai.com", "*.github.com"],
    })
    p, r = guard.guard_request("openai.com")
    check("② auto 命中名单（精确）→ 拒绝+提示全量",
          p is None and r is not None and "全量" in r, str((p, r)))
    p, r = guard.guard_request("api.github.com")
    check("② auto 命中名单（*.xxx 通配子域）→ 拒绝",
          p is None and r is not None and "全量" in r, str((p, r)))
    p, r = guard.guard_request("other.com")
    check("② auto 不在名单 → 仍直连尝试", p is None and r is None, str((p, r)))

    # ── ③ auto 熔断 → 持久化写入名单 ──
    _reset()
    guard.guard_report_failure("blocked.example.org")
    guard.guard_report_failure("blocked.example.org")   # 2 次 = THRESHOLD → 熔断+入名单
    cfg = cs.get_config()
    check("③ 熔断触发 → 域名已持久化进名单",
          "blocked.example.org" in (cfg.get("egress_proxy_required") or []),
          str(cfg.get("egress_proxy_required")))
    # 熔断窗口过期后名单仍拦（名单是持久记忆，熔断是内存态）
    with guard._circuit_lock:
        guard._circuit.clear()   # 模拟熔断窗口过期（内存清零）
    p, r = guard.guard_request("blocked.example.org")
    check("③ 熔断清零后名单仍拦（持久记忆）", p is None and r is not None, str((p, r)))

    # ──  proxy + 命中名单 → 仍走代理放行 ──
    _reset()
    _write_disk_cfg({
        "ollama_base_url": "http://localhost:11434",
        "proxy_http_port": 21081,
        "network_switch": "proxy",
        "egress_proxy_required": ["openai.com"],
    })
    p, r = guard.guard_request("openai.com")
    check("④ proxy 命中名单 → 仍走代理（不拦截）",
          p is not None and r is None and p["http"] == "http://127.0.0.1:21081", str((p, r)))

    # ── ⑤ proxy + 已熔断 → 拒绝（真不可达仍受保护）──
    _reset()
    _write_disk_cfg({
        "ollama_base_url": "http://localhost:11434",
        "proxy_http_port": 21081,
        "network_switch": "proxy",
        "egress_proxy_required": [],
    })
    guard.guard_report_failure("dead.example.net")
    guard.guard_report_failure("dead.example.net")
    p, r = guard.guard_request("dead.example.net")
    check("⑤ proxy 已熔断 → 拒绝（防空转）", p is None and r is not None, str((p, r)))

    # ── ⑥ legacy 清理：磁盘残留 egress_allowlist 被 pop，且不迁移 ──
    _reset()
    _write_disk_cfg({
        "ollama_base_url": "http://localhost:11434",
        "proxy_http_port": 21081,
        "network_switch": "auto",
        "egress_allowlist": ["baidu.com"],        # 旧白名单残留
        "egress_proxy_required": [],
    })
    cfg = cs.get_config()
    check("⑥ get_config 主动 pop 磁盘残留 egress_allowlist", "egress_allowlist" not in cfg,
          str(list(cfg.keys())[-3:]))
    check("⑥ 旧白名单条目**不迁移**进需代理名单（语义相反）",
          cfg.get("egress_proxy_required") == [], str(cfg.get("egress_proxy_required")))
    import json
    on_disk = json.loads(cs.get_config_path().read_text(encoding="utf-8"))
    check("⑥ 清理已落盘（磁盘文件也不含旧键）", "egress_allowlist" not in on_disk,
          str(list(on_disk.keys())[-3:]))

    # ── ⑦ 切换 network_switch → 熔断器重置 ──
    _reset()
    guard.guard_report_failure("flip.example.com")
    guard.guard_report_failure("flip.example.com")
    check("⑦ 前置：auto 下已熔断", guard.guard_circuit_open("flip.example.com") is True)
    cs.reload_config({"network_switch": "proxy"})
    check("⑦ 切到 proxy → 熔断重置（切换不失去意义）",
          guard.guard_circuit_open("flip.example.com") is False)
    # 反向：proxy→auto 同样重置
    guard.guard_report_failure("flip2.example.com")
    guard.guard_report_failure("flip2.example.com")
    cs.reload_config({"network_switch": "auto"})
    check("⑦ 切回 auto → 熔断同样重置", guard.guard_circuit_open("flip2.example.com") is False)
    # 改其他键不应重置熔断
    guard.guard_report_failure("keep.example.com")
    guard.guard_report_failure("keep.example.com")
    cs.reload_config({"max_tool_rounds": 150})
    check("⑦ 改无关键**不**重置熔断（只认模式切换）",
          guard.guard_circuit_open("keep.example.com") is True)

    # ── ⑧ 熔断写入的三条防护 ──
    _reset()
    guard.guard_report_failure("www.example.cn")
    guard.guard_report_failure("www.example.cn")
    cfg = cs.get_config()
    check("⑧ 境内域名熔断**不**入名单（走代理无意义）",
          cfg.get("egress_proxy_required") == [], str(cfg.get("egress_proxy_required")))

    _reset()
    _write_disk_cfg({
        "ollama_base_url": "http://localhost:11434",
        "proxy_http_port": 21081,
        "network_switch": "proxy",
        "egress_proxy_required": [],
    })
    guard.guard_report_failure("proxyfail.example.com")
    guard.guard_report_failure("proxyfail.example.com")
    cfg = cs.get_config()
    check("⑧ proxy 模式下失败**不**入名单（失败=真不可达，非需代理）",
          cfg.get("egress_proxy_required") == [], str(cfg.get("egress_proxy_required")))

    _reset()
    _write_disk_cfg({
        "ollama_base_url": "http://localhost:11434",
        "proxy_http_port": 21081,
        "network_switch": "auto",
        "egress_proxy_required": ["*.example.com"],   # 已有通配覆盖
    })
    guard.guard_report_failure("sub.example.com")
    guard.guard_report_failure("sub.example.com")
    cfg = cs.get_config()
    check("⑧ 已被通配覆盖的域名不重复写",
          cfg.get("egress_proxy_required") == ["*.example.com"], str(cfg.get("egress_proxy_required")))

    print(f"\n===== B11 专项: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("失败项:", FAILURES)
        sys.exit(1)


if __name__ == "__main__":
    main()
