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
"""TS-103 专项单测：B04 cancel await / B09 client 复用+指纹重建 / B12 SQL 显式分支 / B17 guard 判定。
venv 内直接跑：python test_ts103.py。数据写 /tmp，不碰 ~/.subagent。
"""
import asyncio, sys, tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))  # subagent/，使 sidecar.* 可导入

PASS, FAIL = 0, 0
FAILURES = []

def check(name, cond, detail=""):
    global PASS, FAIL
    if cond: PASS += 1; print(f"PASS  {name}")
    else: FAIL += 1; FAILURES.append(name); print(f"FAIL  {name}  {detail}")


FAKE_CFG_BASE = {
    "ollama_base_url": "http://localhost:11434",
    "network_switch": "off",
    "proxy_http_port": 21081,
    "egress_allowlist": [],
    "sidecar_host": "127.0.0.1",
}

def _patch_cfg(overrides=None):
    import sidecar.config as cfgmod
    cfg = dict(FAKE_CFG_BASE)
    if overrides: cfg.update(overrides)
    cfgmod.get_config = lambda: dict(cfg)


async def main():
    # ── B17/网络重构：三态模式 + 熔断器判定（2026-08-28 融合方案）──
    import sidecar.network.guard as guard
    guard.guard_reset_circuit()

    # auto 模式（旧 off 迁移）：境外域名未熔断 → 放行直连尝试
    _patch_cfg({"network_switch": "auto"})
    p, r = guard.guard_request("google.com")
    check("B17 auto 境外未熔断 → 放行直连尝试", p is None and r is None, str((p, r)))
    # 境内/本地始终直连
    p, r = guard.guard_request("example.cn")
    check("B17 auto 境内 .cn 直连", p is None and r is None, str((p, r)))
    p, r = guard.guard_request("www.example.com.cn")
    check("B17 auto *.com.cn 直连", p is None and r is None, str((p, r)))

    # 熔断：连续失败达阈值 → 秒拒（防无代理空转）
    guard.guard_report_failure("google.com")
    guard.guard_report_failure("google.com")
    p, r = guard.guard_request("google.com")
    check("B17 auto 连续失败后熔断秒拒", p is None and r is not None and "暂停自动重试" in r, str((p, r)))
    # 成功一次 → 清零恢复
    guard.guard_report_success("google.com")
    p, r = guard.guard_request("google.com")
    check("B17 auto 成功后熔断恢复放行", p is None and r is None, str((p, r)))

    # proxy 模式（旧 on 迁移）：境外走配置代理
    _patch_cfg({"network_switch": "proxy"})
    p, r = guard.guard_request("google.com")
    check("B17 proxy 境外走配置代理（端口 21081 读自配置）",
          p is not None and r is None and p["http"] == "http://127.0.0.1:21081", str((p, r)))
    p, r = guard.guard_request("example.cn")
    check("B17 proxy 境内仍直连（不走代理）", p is None and r is None, str((p, r)))
    # 旧值迁移语义：on→proxy / off→auto 由 _normalize_switch 处理
    check("B17 归一化 on→proxy", guard._normalize_switch("on") == "proxy")
    check("B17 归一化 off→auto", guard._normalize_switch("off") == "auto")
    guard.guard_reset_circuit()

    # ── B09：client 复用 + 配置指纹变化重建 ──
    from sidecar.ollama.connector import OllamaConnector
    _patch_cfg()
    c = OllamaConnector()
    cl1 = await c._client()
    cl2 = await c._client()
    check("B09 同配置指纹 → 复用同一 client", cl1 is cl2)
    cl2b = await c._client(reading=60.0)
    check("B09 不同超时参数 → 独立 client（不互相污染）", cl2b is not cl1 and not cl2b.is_closed)
    _patch_cfg({"network_switch": "on"})  # 指纹变化
    cl3 = await c._client()
    check("B09 配置指纹变化 → client 重建", cl3 is not cl1)
    check("B09 旧 client 已关闭", cl1.is_closed)
    await c.aclose_all()
    check("B09 aclose_all 清空连接池", len(c._clients) == 0)

    # ── B12：update_agent_config 显式分支（5 字段更新 + 非法字段拒绝）──
    import sidecar.storage.store as store
    TMP = Path(tempfile.mkdtemp(prefix="ts103_"))
    store.PROJECTS_ROOT = TMP
    store._GDB = TMP / "_global.db"
    pid = store.create_project("t12", TMP / "wd")
    aid = store.add_agent_config(pid, "A1", "main", model_name="m-old")
    aid2 = store.add_agent_config(pid, "parent", "main")
    ok = store.update_agent_config(pid, aid, name="N2", role="R2",
                                   system_prompt="SP2", model_name="m-new",
                                   parent_agent_id=aid2)
    got = store.get_agent_config(pid, aid)
    check("B12 五字段全部更新", ok is True and got["name"] == "N2" and got["role"] == "R2"
          and got["system_prompt"] == "SP2" and got["model_name"] == "m-new"
          and got["parent_agent_id"] == aid2, str(got))
    ok2 = store.update_agent_config(pid, aid, hack_field="x'; DROP TABLE agent_configs;--")
    got2 = store.get_agent_config(pid, aid)
    check("B12 非法字段被拒（返回 False 且不落库）", ok2 is False and got2["name"] == "N2")
    ok3 = store.update_agent_config(pid, "nonexistent", name="x")
    check("B12 不存在的 agent 返回 False", ok3 is False)
    # 表仍完好（注入防御）
    agents = store.list_agent_configs(pid)
    check("B12 注入尝试后表完好", len(agents) == 2)

    # ── B04：生成器关闭（客户端断开）→ next_task cancel+await，无残留 pending ──
    from sidecar import app as appmod
    appmod.get_config = lambda: {"network_switch": "off"}

    async def hanging_loop(model, msgs, spec, root, authorizer=None, max_rounds=5,
                           context_limit=0, delegation_ctx=None, first_round_images=None):
        yield {"event": "token", "data": {"delta": "x"}}
        await asyncio.Event().wait()  # 模拟模型长时间不产出（挂起）

    orig = appmod.run_tool_loop
    appmod.run_tool_loop = hanging_loop
    pid2 = store.create_project("t04", TMP / "wd2")
    aid3 = store.add_agent_config(pid2, "A", "main")
    sid = store.create_session(pid2, aid3)
    req = appmod.ChatStreamReq(agent_id=aid3, project_id=pid2, session_id=sid,
                               model="qwen3.8", sandbox_root=str(TMP / "wd2"),
                               messages=[{"role": "user", "content": "hi"}])
    resp = await appmod.api_ollama_chat_stream(req)
    it = resp.body_iterator
    chunk = await it.__anext__()  # 拿到首个 token
    check("B04 首事件已产出", "token" in chunk)
    await it.aclose()  # 模拟客户端断开 → 触发 gen() finally
    await asyncio.sleep(0.1)
    pending = [t for t in asyncio.all_tasks()
               if not t.done() and t is not asyncio.current_task()]
    check("B04 断开后无残留 pending 任务", len(pending) == 0, f"残留 {len(pending)} 个")
    # 截断消息已落盘（B06 路径联动不破）
    rows = store.load_messages(pid2, sid)
    check("B04 断开路径截断落盘仍生效", any(m.get("truncated") for m in rows), str(rows))
    appmod.run_tool_loop = orig

    # 高频断开 10 连发（任务单验收场景）
    appmod.run_tool_loop = hanging_loop
    for i in range(10):
        s = store.create_session(pid2, aid3)
        r = appmod.ChatStreamReq(agent_id=aid3, project_id=pid2, session_id=s,
                                 model="qwen3.8", sandbox_root=str(TMP / "wd2"),
                                 messages=[{"role": "user", "content": f"q{i}"}])
        resp = await appmod.api_ollama_chat_stream(r)
        it = resp.body_iterator
        await it.__anext__()
        await it.aclose()
    await asyncio.sleep(0.2)
    pending = [t for t in asyncio.all_tasks()
               if not t.done() and t is not asyncio.current_task()]
    check("B04 高频断开 10 连发无任务残留", len(pending) == 0, f"残留 {len(pending)} 个")
    appmod.run_tool_loop = orig

    import shutil
    shutil.rmtree(TMP, ignore_errors=True)
    check("测试临时目录已清理", not TMP.exists())

    print(f"\n===== TS-103 专项: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("FAILED:", ", ".join(FAILURES))
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
