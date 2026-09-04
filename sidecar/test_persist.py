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
"""TS-101 B06 持久化单测（补齐留痕；审核实测版固化）。
3 场景：① 正常完成落库（user+assistant+tool_steps）② 取消截断落盘（truncated=1）③ 旧 DB 幂等迁移。
venv 内直接跑：python test_persist.py。只输出 PASS/FAIL 摘要。
"""
import asyncio, json, sqlite3, sys, tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

PASS, FAIL = 0, 0
FAILURES = []

def check(name, cond, detail=""):
    global PASS, FAIL
    if cond: PASS += 1; print(f"PASS  {name}")
    else: FAIL += 1; FAILURES.append(name); print(f"FAIL  {name}  {detail}")


def main():
    # 隔离数据目录（不碰 ~/.subagent）：必须在 store 模块级常量生效前改写
    TMP = Path(tempfile.mkdtemp(prefix="persist_"))
    import sidecar.storage.store as store
    store.PROJECTS_ROOT = TMP
    store._GDB = TMP / "_global.db"
    from sidecar import app as appmod
    # 不碰真实 config：stream 端点只用到 network_switch
    appmod.get_config = lambda: {"network_switch": "off"}

    def fake_loop(events):
        async def loop(model, msgs, spec, root, authorizer=None, max_rounds=5, context_limit=0,
                       delegation_ctx=None, first_round_images=None):
            for e in events:
                yield e
        return loop

    pid = store.create_project("audit", TMP / "wd")
    aid = store.add_agent_config(pid, "A1", "main", model_name="qwen3.8")
    sid = store.create_session(pid, aid)

    def parse_sse(raw):
        evs = []
        for blk in raw.split("\n\n"):
            blk = blk.strip()
            if not blk or blk.startswith(":"):
                continue
            ev, data = None, ""
            for line in blk.split("\n"):
                if line.startswith("event:"):
                    ev = line[6:].strip()
                elif line.startswith("data:"):
                    data += line[5:].strip()
            if ev:
                evs.append((ev, json.loads(data) if data else {}))
        return evs

    def rows_of(session_id):
        conn = sqlite3.connect(str(TMP / pid / "agents.db"))
        r = conn.execute(
            "SELECT role, content, tool_steps, truncated FROM session_messages WHERE session_id=? ORDER BY id",
            (session_id,)).fetchall()
        conn.close()
        return r

    from fastapi.testclient import TestClient
    client = TestClient(appmod.app)

    # ── S1 正常完成：user + assistant 落库（含 tool_steps + status 归一）──
    appmod.run_tool_loop = fake_loop([
        {"event": "token", "data": {"delta": "正在"}},
        {"event": "tool_call", "data": {"id": "c1", "name": "list_dir", "args": {"path": "."}}},
        {"event": "tool_result", "data": {"id": "c1", "name": "list_dir", "ok": True, "summary": "2 个条目"}},
        {"event": "state", "data": {"step": 1, "max": 5, "tokens_used": 100}},
        {"event": "token", "data": {"delta": "看"}},
        {"event": "done", "data": {"content": "正在看", "tool_calls": []}},
    ])
    r = client.post("/api/ollama/chat/stream", json={
        "agent_id": aid, "project_id": pid, "session_id": sid,
        "model": "qwen3.8", "sandbox_root": str(TMP / "wd"),
        "messages": [{"role": "user", "content": "列目录"}]})
    check("S1 HTTP 200", r.status_code == 200, str(r.status_code))
    check("S1 done 事件到达", any(e == "done" for e, _ in parse_sse(r.text)))
    rows = rows_of(sid)
    check("S1 DB 恰 2 条（user+assistant）", len(rows) == 2, str(rows))
    check("S1 user 消息已落库", rows[0][0] == "user" and rows[0][1] == "列目录")
    check("S1 assistant 完整内容", rows[1][0] == "assistant" and rows[1][1] == "正在看")
    steps = json.loads(rows[1][2]) if rows[1][2] else None
    check("S1 tool_steps 落库且含 status=ok",
          isinstance(steps, list) and len(steps) == 1
          and steps[0].get("status") == "ok" and steps[0].get("summary") == "2 个条目", str(steps))
    check("S1 truncated=0", rows[1][3] == 0)
    reloaded = store.load_messages(pid, sid)
    check("S1 重启模拟：load_messages 恢复（含 tool_steps）",
          len(reloaded) == 2 and reloaded[1]["content"] == "正在看" and reloaded[1].get("tool_steps"))

    # ── S2 中途取消（注入 CancelledError，与客户端断开同路径）→ 截断落盘 ──
    sid2 = store.create_session(pid, aid)

    async def cancel_loop(model, msgs, spec, root, authorizer=None, max_rounds=5, context_limit=0,
                          delegation_ctx=None, first_round_images=None):
        yield {"event": "token", "data": {"delta": "前半段内容"}}
        raise asyncio.CancelledError()

    appmod.run_tool_loop = cancel_loop
    try:
        client.post("/api/ollama/chat/stream", json={
            "agent_id": aid, "project_id": pid, "session_id": sid2,
            "model": "qwen3.8", "sandbox_root": str(TMP / "wd"),
            "messages": [{"role": "user", "content": "说个长的"}]})
    except BaseException:
        pass  # 取消传播，预期内
    rows2 = rows_of(sid2)
    check("S2 user 落库", len(rows2) >= 1 and rows2[0][0] == "user" and rows2[0][1] == "说个长的", str(rows2))
    a2 = [x for x in rows2 if x[0] == "assistant"]
    check("S2 assistant 截断落盘（内容=已生成部分）", len(a2) == 1 and a2[0][1] == "前半段内容", str(a2))
    check("S2 truncated=1", len(a2) == 1 and a2[0][3] == 1)

    # ── S3 旧 DB（无 tool_steps/truncated 列）→ 幂等 ALTER 迁移，旧数据不丢 ──
    old_db = TMP / "oldproj" / "agents.db"
    old_db.parent.mkdir()
    conn = sqlite3.connect(str(old_db))
    conn.executescript("""
    CREATE TABLE projects (id TEXT PRIMARY KEY, name TEXT NOT NULL, working_dir TEXT NOT NULL,
        created_at TEXT DEFAULT (datetime('now')), updated_at TEXT DEFAULT (datetime('now')));
    CREATE TABLE agent_configs (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, name TEXT NOT NULL,
        role TEXT, system_prompt TEXT, model_name TEXT, type_ TEXT NOT NULL, parent_agent_id TEXT,
        created_at TEXT DEFAULT (datetime('now')));
    CREATE TABLE sessions (id TEXT PRIMARY KEY, agent_id TEXT NOT NULL, project_id TEXT NOT NULL,
        title TEXT DEFAULT '新会话', created_at TEXT DEFAULT (datetime('now')), updated_at TEXT DEFAULT (datetime('now')));
    CREATE TABLE session_messages (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL,
        agent_id TEXT NOT NULL, project_id TEXT NOT NULL, role TEXT NOT NULL, content TEXT,
        images TEXT, model_used TEXT, created_at TEXT DEFAULT (datetime('now')));
    CREATE TABLE session_summaries (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL,
        agent_id TEXT NOT NULL, project_id TEXT NOT NULL, summary_text TEXT, saved_at TEXT DEFAULT (datetime('now')));
    INSERT INTO session_messages (session_id, agent_id, project_id, role, content)
        VALUES ('s-old','a-old','oldproj','user','老消息');
    """)
    conn.commit(); conn.close()
    c = sqlite3.connect(str(old_db))
    store._ensure_schema(c)
    cols = {x[1] for x in c.execute("PRAGMA table_info(session_messages)").fetchall()}
    check("S3 旧库迁移出 tool_steps 列", "tool_steps" in cols, str(cols))
    check("S3 旧库迁移出 truncated 列", "truncated" in cols)
    check("S3 旧数据未丢失",
          c.execute("SELECT content FROM session_messages WHERE session_id='s-old'").fetchone()[0] == "老消息")
    c.close()
    try:
        c2 = sqlite3.connect(str(old_db))
        store._ensure_schema(c2)
        c2.close()
        check("S3 二次迁移幂等不报错", True)
    except Exception as e:
        check("S3 二次迁移幂等不报错", False, str(e))

    # ── M2（M3 前置安全加固）：两协程并发 save_message 同一 session → 无锁竞争 ──
    import asyncio, threading
    # 复用前面的 pid/aid/sid（若存在），否则新建
    if "sid" not in dir():
        sid_c = store.create_session(pid_c, aid_c, "并发")
    else:
        sid_c = sid
    pid_c_use = pid if "pid" in dir() else pid_c
    aid_c_use = aid if "aid" in dir() else aid_c
    sid_c_use = sid_c
    errors = []
    def do_save(tag):
        try:
            store.save_message(pid_c_use, sid_c_use, aid_c_use, "user", f"并发消息-{tag}")
        except Exception as e:
            errors.append(f"{tag}: {e}")
    ts = [threading.Thread(target=do_save, args=(i,)) for i in range(8)]
    for t in ts: t.start()
    for t in ts: t.join()
    check("M2 并发 save_message 无异常（无 database is locked）", len(errors) == 0, str(errors))
    msgs_c = store.load_messages(pid_c_use, sid_c_use)
    conc = [m for m in msgs_c if str(m.get("content","")).startswith("并发消息-")]
    check("M2 并发 8 条全部落库（无静默丢失）", len(conc) == 8, f"count={len(conc)}")

    import shutil
    shutil.rmtree(TMP, ignore_errors=True)
    check("测试临时目录已清理", not TMP.exists())

    print(f"\n===== SUMMARY: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("FAILED:", ", ".join(FAILURES))
        sys.exit(1)


if __name__ == "__main__":
    main()
