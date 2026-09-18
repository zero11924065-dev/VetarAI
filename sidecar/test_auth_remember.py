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
"""R2（0.4.33）授权记忆专项：同 agent 同工具只需授权一次。

覆盖（每条对应需求硬约束）：
  1. 同 (tool, action) 第二次调用不再弹窗（_auth_pending 不再产生新 entry，直接放行）
  2. 记忆键不含路径/参数 detail——同 tool 不同 target_path/参数 JSON 命中同一键
  3. remember="always" 落 config.json 的 auth_grants；清掉会话级记忆后仍命中（永久级）
  4. 联网安装（net_install）永不记忆——即使前端伪造 remember=always，也不落表、下次照弹
  5. 拒绝不记忆；不同 action 不共享记忆（write 的授权不覆盖 delete）
  6. config 校验：auth_grants 默认值存在；非法元素（缺 action）被 _validate 拦下

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
_TMP = Path(tempfile.mkdtemp(prefix="r2auth_"))
import sidecar.config.store as cs          # noqa: E402
cs.get_config_path = lambda: _TMP / "config.json"

import sidecar.app as appmod               # noqa: E402
import sidecar.config as cfgmod            # noqa: E402


def _reset() -> None:
    """每个用例前清空授权协调器状态（内存记忆 + 待响应表 + 磁盘配置）。"""
    appmod._auth_grants_session.clear()
    appmod._auth_pending.clear()
    (_TMP / "config.json").unlink(missing_ok=True)


async def _first_call(tool: str, path: str, action: str, *,
                      allowed: bool = True, remember: str | None = None,
                      extra: dict | None = None):
    """跑一次 authorizer 并模拟前端响应；返回 (authorizer 返回值, request_id)。"""
    task = asyncio.create_task(appmod._sse_authorizer(tool, path, action, extra))
    rid = None
    for _ in range(100):                       # 等它把请求挂进 _auth_pending
        await asyncio.sleep(0.01)
        if appmod._auth_pending:
            rid = next(iter(appmod._auth_pending))
            break
    assert rid is not None, "authorizer 未产生待响应授权请求"
    await appmod.api_auth_respond(appmod.AuthRespondReq(
        request_id=rid, allowed=allowed, remember=remember))
    return await task, rid


async def _pending_count_after(tool: str, path: str, action: str,
                               extra: dict | None = None):
    """再调一次 authorizer：返回 (是否产生了新弹窗, authorizer 返回值)。"""
    task = asyncio.create_task(appmod._sse_authorizer(tool, path, action, extra))
    await asyncio.sleep(0.05)                  # 给足它注册 pending 的时间片
    popped = bool(appmod._auth_pending)
    if popped:                                 # 弹了 → 批准掉，别让它挂到超时
        rid = next(iter(appmod._auth_pending))
        await appmod.api_auth_respond(appmod.AuthRespondReq(request_id=rid, allowed=True))
    return popped, await task


async def run() -> None:
    # ── 0 config 默认值与校验 ─────────────────────────────────────────
    _reset()
    cfg = cfgmod.get_config()
    check("0-1 DEFAULT 含 auth_grants 且默认为空 list", cfg.get("auth_grants") == [],
          repr(cfg.get("auth_grants")))
    try:
        cfgmod.reload_config({"auth_grants": [{"tool": "write_file"}]})   # 缺 action
        check("0-2 非法 auth_grants（缺 action）被校验拦下", False, "未抛 ValueError")
    except ValueError:
        check("0-2 非法 auth_grants（缺 action）被校验拦下", True)
    try:
        cfgmod.reload_config({"auth_grants": [{"tool": "write_file", "action": "write",
                                               "granted_at": "2026-01-01T00:00:00"}]})
        check("0-3 合法 auth_grants 可写", True)
    except ValueError as e:
        check("0-3 合法 auth_grants 可写", False, str(e))

    # ── 1 同 (tool, action) 第二次不弹 + 键不含路径 ──────────────────
    _reset()
    r1, _ = await _first_call("write_file", "/etc/a.conf", "write", remember="session")
    check("1-1 首次调用正常弹窗并返回用户批准", r1 is True, repr(r1))
    check("1-2 会话级记忆已写入", ("write_file", "write") in appmod._auth_grants_session,
          str(appmod._auth_grants_session))
    popped, r2 = await _pending_count_after("write_file", "/etc/another.conf", "write")
    check("1-3 ⛳ 同 (tool,action) 第二次调用不再弹窗", popped is False)
    check("1-4 第二次直接放行（True）", r2 is True, repr(r2))
    check("1-5 记忆键不含路径：/etc/a.conf 与 /etc/another.conf 命中同一键",
          len(appmod._auth_grants_session) == 1, str(appmod._auth_grants_session))

    # ── 2 记忆键不含参数 JSON（app_control 形态：detail 是 json.dumps(params)）──
    _reset()
    await _first_call("app_control:workflow.run", '{"wf":"a","x":1}', "app_module",
                      remember="session")
    popped, r = await _pending_count_after(
        "app_control:workflow.run", '{"wf":"a","x":999,"extra":"完全不同的参数"}', "app_module")
    check("2-1 ⛳ 参数 detail 不同仍命中同一键（不弹窗）", popped is False and r is True,
          f"popped={popped} r={r!r}")

    # ── 3 remember=always 落 config；清会话级后仍命中（永久级）─────────
    _reset()
    await _first_call("delete_file", "/usr/local/x", "delete", remember="always")
    grants = cfgmod.get_config().get("auth_grants") or []
    hit = [g for g in grants if g.get("tool") == "delete_file" and g.get("action") == "delete"]
    check("3-1 ⛳ remember=always 落 config auth_grants", len(hit) == 1, repr(grants))
    check("3-2 落表元素含 granted_at", bool(hit and hit[0].get("granted_at")), repr(hit))
    appmod._auth_grants_session.clear()       # 模拟进程重启：会话级清空
    popped, r = await _pending_count_after("delete_file", "/usr/local/y", "delete")
    check("3-3 ⛳ 永久级跨「重启」仍生效（不弹窗、直接放行）", popped is False and r is True,
          f"popped={popped} r={r!r}")
    # 重复永久授权不重复落条（此时永久级已命中，弹窗路径走不到 → 直接调记录函数）
    appmod._auth_grant_record("delete_file", "delete", "always")
    grants2 = [g for g in (cfgmod.get_config().get("auth_grants") or [])
               if g.get("tool") == "delete_file" and g.get("action") == "delete"]
    check("3-4 重复永久授权不产生重复条目", len(grants2) == 1, repr(grants2))

    # ── 4 联网安装永不记忆（安全敏感，每次必弹）──────────────────────
    _reset()
    _extra = {"kind": "net_install", "source_url": "https://github.com/x/y",
              "install_type": "技能（Skill）", "current_mode": "auto",
              "need_enable_network": True}
    # 模拟前端被绕过：直接带 remember=always 响应 net_install
    task = asyncio.create_task(appmod._sse_authorizer(
        "install_skill", "https://github.com/x/y", "net_install", dict(_extra)))
    rid = None
    for _ in range(100):
        await asyncio.sleep(0.01)
        if appmod._auth_pending:
            rid = next(iter(appmod._auth_pending))
            break
    await appmod.api_auth_respond(appmod.AuthRespondReq(
        request_id=rid, allowed=True, enable_network=True, remember="always"))
    r_net = await task
    check("4-1 net_install 返回 dict 口径不变",
          isinstance(r_net, dict) and r_net.get("allowed") is True
          and r_net.get("enable_network") is True, repr(r_net))
    check("4-2 ⛳ net_install 不落永久级（config auth_grants 仍为空）",
          (cfgmod.get_config().get("auth_grants") or []) == [],
          repr(cfgmod.get_config().get("auth_grants")))
    check("4-3 ⛳ net_install 不落会话级",
          len(appmod._auth_grants_session) == 0, str(appmod._auth_grants_session))
    popped, r_net2 = await _pending_count_after(
        "install_skill", "https://github.com/x/y", "net_install", dict(_extra))
    check("4-4 ⛳ 同一来源第二次联网安装照弹不误", popped is True)
    check("4-5 第二次 net_install 返回口径不变",
          isinstance(r_net2, dict) and r_net2.get("allowed") is True, repr(r_net2))

    # ── 5 拒绝不记忆；不同 action 不共享 ─────────────────────────────
    _reset()
    await _first_call("write_file", "/etc/a", "write", allowed=False, remember="session")
    check("5-1 拒绝不写入会话级记忆", len(appmod._auth_grants_session) == 0,
          str(appmod._auth_grants_session))
    popped, _ = await _pending_count_after("write_file", "/etc/a", "write")
    check("5-2 拒绝后第二次照弹", popped is True)
    _reset()
    await _first_call("write_file", "/etc/a", "write", remember="session")
    popped, _ = await _pending_count_after("write_file", "/etc/a", "delete")
    check("5-3 不同 action 不共享记忆（write 的授权不覆盖 delete）", popped is True)

    # ── 6 缺省 remember（旧前端不带字段）→ 不记忆，行为与旧版一致 ─────
    _reset()
    await _first_call("write_file", "/etc/a", "write")     # remember=None
    popped, _ = await _pending_count_after("write_file", "/etc/a", "write")
    check("6-1 不带 remember 字段 → 不记忆，第二次照弹（向后兼容）", popped is True)


def main() -> None:
    asyncio.run(run())
    _reset()
    print(f"\n===== R2 授权记忆: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("FAILED:", ", ".join(FAILURES))
        sys.exit(1)


if __name__ == "__main__":
    main()
