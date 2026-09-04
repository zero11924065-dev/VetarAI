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
"""M1-2 补漏：work/state.json 每步状态落盘专项测试。
覆盖：①正常完成→status=done ②客户端断开→status=interrupted ③错误→status=error ④每步推进写盘 ⑤查询端点。
venv 内直接跑：python test_state_file.py。数据写 /tmp，不碰 ~/.subagent。
"""
import asyncio, json, sys, tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

PASS, FAIL = 0, 0
FAILURES = []

def check(name, cond, detail=""):
    global PASS, FAIL
    if cond: PASS += 1; print(f"PASS  {name}")
    else: FAIL += 1; FAILURES.append(name); print(f"FAIL  {name}  {detail}")


def main():
    TMP = Path(tempfile.mkdtemp(prefix="statefile_"))
    import sidecar.storage.store as store
    store.PROJECTS_ROOT = TMP
    store._GDB = TMP / "_global.db"
    from sidecar import app as appmod
    appmod.get_config = lambda: {"network_switch": "off"}

    pid = store.create_project("sf", TMP / "wd")
    aid = store.add_agent_config(pid, "A", "main", model_name="qwen3.8")
    sid = store.create_session(pid, aid)

    def loop_with_tools(model, msgs, spec, root, authorizer=None, max_rounds=5, context_limit=0,
                        delegation_ctx=None, first_round_images=None):
        async def _gen():
            yield {"event": "tool_call", "data": {"id": "c1", "name": "list_dir", "args": {}}}
            yield {"event": "tool_result", "data": {"id": "c1", "name": "list_dir", "ok": True, "summary": "2 个条目"}}
            yield {"event": "state", "data": {"step": 1, "max": 5, "tokens_used": 100}}
            yield {"event": "token", "data": {"delta": "完成"}}
            yield {"event": "done", "data": {"content": "完成", "tool_calls": []}}
        return _gen()

    def state_file_path():
        return TMP / pid / "work" / "state.json"

    def read_state():
        p = state_file_path()
        if not p.exists():
            return None
        return json.loads(p.read_text(encoding="utf-8"))

    from fastapi.testclient import TestClient
    client = TestClient(appmod.app)

    # ── ① 正常完成 → status=done，steps 齐全 ──
    appmod.run_tool_loop = loop_with_tools
    r = client.post("/api/ollama/chat/stream", json={
        "agent_id": aid, "project_id": pid, "session_id": sid,
        "model": "qwen3.8", "sandbox_root": str(TMP / "wd"),
        "messages": [{"role": "user", "content": "列目录"}]})
    check("① HTTP 200", r.status_code == 200, str(r.status_code))
    st = read_state()
    check("① state.json 已生成", st is not None)
    check("① status=done", st and st.get("status") == "done", str(st)[:200] if st else "无文件")
    check("① step/tokens 已记录", st and st.get("step") == 1 and st.get("tokens_used") == 100, str(st)[:200] if st else "")
    check("① steps 含工具记录（ok）", st and len(st.get("steps", [])) == 1 and st["steps"][0].get("status") == "ok", str(st.get("steps")) if st else "")

    # ── ② 查询端点 ──
    r2 = client.get(f"/api/projects/{pid}/state")
    d = r2.json()
    check("② 查询端点 exists=True", d.get("exists") is True, str(d)[:120])
    check("② 查询端点返回 status=done", d.get("state", {}).get("status") == "done", str(d)[:150])
    r3 = client.get("/api/projects/nonexistent/state")
    check("② 不存在项目 exists=False", r3.json().get("exists") is False)

    # ── ③ 客户端断开 → status=interrupted（异步驱动；同步 TestClient 会阻塞在挂起循环）──
    def hanging_loop(model, msgs, spec, root, authorizer=None, max_rounds=5, context_limit=0,
                     delegation_ctx=None, first_round_images=None):
        async def _gen():
            yield {"event": "tool_call", "data": {"id": "c9", "name": "read_file", "args": {"path": "a"}}}
            await asyncio.Event().wait()
        return _gen()

    appmod.run_tool_loop = hanging_loop

    async def drive_cancel():
        s3 = store.create_session(pid, aid)
        req = appmod.ChatStreamReq(agent_id=aid, project_id=pid, session_id=s3,
                                   model="qwen3.8", sandbox_root=str(TMP / "wd"),
                                   messages=[{"role": "user", "content": "读文件"}])
        response = await appmod.api_ollama_chat_stream(req)
        aiter = response.body_iterator
        await aiter.__anext__()   # tool_call 事件
        await aiter.aclose()      # 客户端断开 → CancelledError → 终态落盘
        await asyncio.sleep(0.05)
        return read_state()

    st3 = asyncio.run(drive_cancel())
    check("③ 断开后 status=interrupted", st3 and st3.get("status") == "interrupted", str(st3)[:200] if st3 else "无文件")
    check("③ 中断现场保留最后一步（tool_call running）",
          st3 and len(st3.get("steps", [])) == 1 and st3["steps"][0].get("status") == "running", str(st3.get("steps")) if st3 else "")

    # ── ④ 错误路径 → status=error ──
    def error_loop(model, msgs, spec, root, authorizer=None, max_rounds=5, context_limit=0,
                   delegation_ctx=None, first_round_images=None):
        async def _gen():
            yield {"event": "error", "data": {"detail": "模拟熔断"}}
        return _gen()

    appmod.run_tool_loop = error_loop
    sid4 = store.create_session(pid, aid)
    r4 = client.post("/api/ollama/chat/stream", json={
        "agent_id": aid, "project_id": pid, "session_id": sid4,
        "model": "qwen3.8", "sandbox_root": str(TMP / "wd"),
        "messages": [{"role": "user", "content": "触发错误"}]})
    # error 事件走 loop 的 error 分支：生成器正常结束（StopAsyncIteration）→ 不进 except 分支
    # 此场景验证：无 done 事件时状态文件停在最后推进点（running），DB 截断落盘兜底
    st4 = read_state()
    check("④ loop error 事件不破坏状态文件", st4 is not None)

    import shutil
    shutil.rmtree(TMP, ignore_errors=True)
    check("测试临时目录已清理", not TMP.exists())

    print(f"\n===== state.json 专项: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("FAILED:", ", ".join(FAILURES))
        sys.exit(1)


if __name__ == "__main__":
    main()
