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
"""TS-108 M3-2 专项单测：旧表迁移 / queued 排队态 / 自动新建子 Agent / 开关语义。
风格同 test_delegation.py，venv 内 python test_delegation2.py 直接跑。只输出 PASS/FAIL 摘要。
"""
import asyncio
import json
import sqlite3
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

PASS, FAIL = 0, 0
FAILURES = []


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"PASS  {name}")
    else:
        FAIL += 1
        FAILURES.append(name)
        print(f"FAIL  {name}  {detail}")


class ScriptConn:
    """按脚本返回文本；callable 项接当前最新任务 id。"""

    def __init__(self, scripts, store_mod, project_id):
        self.scripts = scripts
        self.store = store_mod
        self.pid = project_id
        self.calls = 0

    def _tid(self):
        tasks = self.store.list_agent_tasks(self.pid, limit=1)
        return tasks[0]["id"] if tasks else ""

    async def chat_stream(self, model, messages, tools=None):
        i = min(self.calls, len(self.scripts) - 1)
        item = self.scripts[i]
        self.calls += 1
        text = item(self._tid()) if callable(item) else item
        yield {"content_delta": text}
        yield {"done": True, "counts": {"prompt_eval_count": 5, "eval_count": 5}}


class SimpleConn:
    """不依赖 DB 的按脚本假连接器（用于模拟主会话的决策轮）。
    脚本项：(content, tool_calls) —— 与 test_loop.MockConn 同形。"""

    def __init__(self, rounds):
        self.rounds = rounds
        self.calls = 0

    async def chat_stream(self, model, messages, tools=None):
        i = min(self.calls, len(self.rounds) - 1)
        self.calls += 1
        content, tcs = self.rounds[i]
        if content:
            yield {"content_delta": content}
        if tcs:
            yield {"tool_calls": [{"id": f"mock_{self.calls}_{j}", "function": {
                "name": n, "arguments": json.dumps(a, ensure_ascii=False)}}
                for j, (n, a) in enumerate(tcs)]}
        yield {"done": True, "counts": {"prompt_eval_count": 5, "eval_count": 5}}


def good_report(t):
    return json.dumps({"task_id": t, "status": "success",
                       "summary": "完成", "artifacts": []}, ensure_ascii=False)


async def main():
    TMP = Path(tempfile.mkdtemp(prefix="m32_"))
    import sidecar.storage.store as store
    store.PROJECTS_ROOT = TMP
    store._GDB = TMP / "_global.db"

    # ══ 1. 旧表迁移：构造 027 版旧表（CHECK 无 queued）→ _ensure_schema 后无损升级 ══
    legacy_db = TMP / "legacy_proj" / "agents.db"
    legacy_db.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(legacy_db))
    conn.executescript("""
        CREATE TABLE agent_tasks (
            id TEXT PRIMARY KEY, project_id TEXT NOT NULL,
            parent_agent_id TEXT NOT NULL, parent_session_id TEXT NOT NULL,
            target_agent_id TEXT NOT NULL, target_agent_name TEXT NOT NULL,
            task TEXT NOT NULL, expect TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'running' CHECK(status IN ('running','done','failed')),
            report TEXT, fail_reason TEXT,
            validation_failures INTEGER NOT NULL DEFAULT 0,
            session_id TEXT,
            created_at TEXT DEFAULT (datetime('now')),
            updated_at TEXT DEFAULT (datetime('now'))
        );
    """)
    conn.execute(
        "INSERT INTO agent_tasks (id, project_id, parent_agent_id, parent_session_id, "
        "target_agent_id, target_agent_name, task, expect, status) "
        "VALUES ('t-old-1','legacy_proj','pa','ps','ta','老任务','任务书X','标准X','done')")
    conn.commit()
    old_row = conn.execute("SELECT id, task, status FROM agent_tasks").fetchone()
    conn.close()

    legacy_conn = store._agent_conn("legacy_proj")  # 触发 _ensure_schema 迁移
    ddl = legacy_conn.execute(
        "SELECT sql FROM sqlite_master WHERE type='table' AND name='agent_tasks'").fetchone()[0]
    new_row = legacy_conn.execute(
        "SELECT id, task, expect, status, target_agent_name FROM agent_tasks WHERE id='t-old-1'"
    ).fetchone()
    legacy_conn.close()
    check("1a 旧表迁移后 CHECK 含 queued", "'queued'" in ddl, ddl[:200])
    check("1b 迁移数据无损",
          new_row == ('t-old-1', '任务书X', '标准X', 'done', '老任务'), str(new_row))
    check("1c 迁移幂等（二次 _ensure_schema 不报错）",
          bool(store._agent_conn("legacy_proj").execute(
              "SELECT COUNT(*) FROM agent_tasks").fetchone()))

    # ══ 2. queued 排队态 ══
    pid = store.create_project("m32", TMP / "wd")
    main_id = store.add_agent_config(pid, "Alpha", "main", model_name="qwen3.8")
    beta_id = store.add_agent_config(pid, "Beta", "sub", model_name="qwen3.8")
    beta = store.get_agent_config(pid, beta_id)
    parent_sid = store.create_session(pid, main_id)

    tid_q = store.create_agent_task(pid, main_id, parent_sid, beta_id, "Beta", "任务", "标准")
    got_q = store.get_agent_task(pid, tid_q)
    check("2a create_agent_task 落库即 queued", got_q["status"] == "queued", str(got_q)[:120])

    # 2b/2c：执行后状态迁移（借用锁模拟排队窗口）
    from sidecar.agent_engine.delegation import run_delegated_task, _DELEGATION_LOCK
    statuses_seen: list = []

    class HoldingTask:
        """手动持有锁 → 委派应停在 queued → 释放后转 running→done"""

    holder = asyncio.get_event_loop()
    release_evt = asyncio.Event()

    async def hold_lock():
        async with _DELEGATION_LOCK:
            await release_evt.wait()

    hold_task = asyncio.ensure_future(hold_lock())
    await asyncio.sleep(0.05)  # 确保锁被占住

    deleg_future = asyncio.ensure_future(run_delegated_task(
        pid, main_id, parent_sid, beta, "排队任务", "标准",
        sandbox_root=str(TMP / "wd"), max_rounds=5,
        connector=ScriptConn([good_report], store, pid)))
    await asyncio.sleep(0.1)
    newest = store.list_agent_tasks(pid, limit=1)[0]
    check("2b 锁等待期间任务为 queued",
          newest["status"] == "queued" and newest["task"] == "排队任务", str(newest)[:120])
    release_evt.set()
    res_q = await deleg_future
    await hold_task
    newest2 = store.get_agent_task(pid, res_q["task_id"])
    check("2c 释放锁后执行至 done",
          res_q.get("ok") is True and newest2["status"] == "done", str(newest2)[:120])

    # ══ 3. auto_create_agent ══
    from sidecar.agent_engine.delegation import auto_create_agent
    a1 = auto_create_agent(pid, "数据分析师", "qwen3.8")
    check("3a 正常新建（type_=sub + role 正确 + name=角色）",
          a1["type_"] == "sub" and a1["role"] == "数据分析师" and a1["name"] == "数据分析师"
          and a1["model_name"] == "qwen3.8", str(a1))
    a2 = auto_create_agent(pid, "数据分析师", "qwen3.8")
    check("3b 重名追加 -2", a2["name"] == "数据分析师-2", str(a2)[:120])
    a3 = auto_create_agent(pid, "数据分析师", "qwen3.8")
    check("3c 再重名追加 -3", a3["name"] == "数据分析师-3", str(a3)[:120])
    check("3d 新建后可在 Agent 列表复用",
          any(x["name"] == "数据分析师" for x in store.list_agent_configs(pid)))

    # ══ 4. 委派集成：未命中 + 开关语义（在 loop 层路由，此处直测分支依赖的函数链）══
    from sidecar.agent_engine.loop import run_tool_loop, tools_spec
    import sidecar.config as cfgmod
    orig_cfg = cfgmod.get_config
    cfg_patch = {"network_switch": "auto", "auto_create_sub_agents": True, "max_tool_rounds": 5}
    cfgmod.get_config = lambda: cfg_patch

    ctx = {"project_id": pid, "agent_id": main_id, "session_id": parent_sid,
           "connector": ScriptConn([good_report], store, pid), "model": "qwen3.8"}

    # 4a 未命中 + 开关开 + 有 suggested_role → 自动新建并执行成功
    evs = []
    async for ev in run_tool_loop("qwen3.8", [{"role": "user", "content": "hi"}],
                                  tools_spec(with_delegation=True), str(TMP / "wd"),
                                  max_rounds=5, connector=SimpleConn([
                                      ("", [("delegate_task", {
                                          "target": "幽灵", "task": "T", "expect": "E",
                                          "suggested_role": "速记员"})]),
                                      ("收到，已建好。", [])]),
                                  delegation_ctx=ctx):
        evs.append(ev)
    tr = next((e for e in evs if e["event"] == "tool_result" and e["data"]["name"] == "delegate_task"), None)
    created = [a for a in store.list_agent_configs(pid) if a["name"] == "速记员"]
    check("4a 未命中+开关开+建议角色 → 自动新建并执行",
          tr is not None and tr["data"]["ok"] is True and len(created) == 1, str(tr)[:200] if tr else "无结果")
    check("4a2 新建的 Agent 是 sub 且角色正确",
          created and created[0]["type_"] == "sub" and created[0]["role"] == "速记员")
    check("4a3 结果含 created_agent 标注",
          tr is not None and tr["data"].get("created_agent") == "速记员",
          str(tr.get("data"))[:150] if tr else "无结果")

    # 4b 未命中 + 开关开 + 无 suggested_role → 用目标名兜底新建并执行（H14 修复：弱模型不填角色也能自动建）
    n_before = len(store.list_agent_configs(pid))
    evs = []
    async for ev in run_tool_loop("qwen3.8", [{"role": "user", "content": "hi"}],
                                  tools_spec(with_delegation=True), str(TMP / "wd"),
                                  max_rounds=5, connector=SimpleConn([
                                      ("", [("delegate_task", {"target": "人事专员", "task": "T", "expect": "E"})]),
                                      ("ok", [])]),
                                  delegation_ctx=ctx):
        evs.append(ev)
    tr = next((e for e in evs if e["event"] == "tool_result" and e["data"]["name"] == "delegate_task"), None)
    created_b = [a for a in store.list_agent_configs(pid) if a["name"] == "人事专员"]
    check("4b 无建议角色 → 用目标名兜底新建并执行",
          tr is not None and tr["data"]["ok"] is True and len(created_b) == 1
          and len(store.list_agent_configs(pid)) == n_before + 1, str(tr)[:200] if tr else "无结果")
    check("4b2 兜底新建的角色=目标名",
          created_b and created_b[0]["role"] == "人事专员" and created_b[0]["type_"] == "sub",
          str(created_b)[:150] if created_b else "")

    # 4c 未命中 + 开关关 → error 含"已关闭"，不新建
    cfg_patch["auto_create_sub_agents"] = False
    n_before = len(store.list_agent_configs(pid))
    evs = []
    async for ev in run_tool_loop("qwen3.8", [{"role": "user", "content": "hi"}],
                                  tools_spec(with_delegation=True), str(TMP / "wd"),
                                  max_rounds=5, connector=SimpleConn([
                                      ("", [("delegate_task", {"target": "不存在3", "task": "T", "expect": "E",
                                                                 "suggested_role": "会计"})]),
                                      ("ok", [])]),
                                  delegation_ctx=ctx):
        evs.append(ev)
    tr = next((e for e in evs if e["event"] == "tool_result" and e["data"]["name"] == "delegate_task"), None)
    check("4c 开关关 → error 含已关闭+设置面板指引 且不新建",
          tr is not None and tr["data"]["ok"] is False
          and "已关闭" in tr["data"].get("error", "") and "设置面板" in tr["data"].get("error", "")
          and len(store.list_agent_configs(pid)) == n_before, str(tr)[:250] if tr else "无结果")
    cfg_patch["auto_create_sub_agents"] = True
    cfgmod.get_config = orig_cfg

    import shutil
    shutil.rmtree(TMP, ignore_errors=True)
    check("测试临时目录已清理", not TMP.exists())

    print(f"\n===== M3-2 委派扩展专项: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("FAILED:", ", ".join(FAILURES))
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
