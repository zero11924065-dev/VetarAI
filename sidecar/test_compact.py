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
"""M2 智能压缩单测（mock Ollama 摘要 + 临时目录）。
venv 内直接跑：python test_compact.py。
"""
import asyncio, sys, tempfile, os
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

PASS, FAIL = 0, 0
FAILURES = []

def check(name, cond, detail=""):
    global PASS, FAIL
    if cond: PASS += 1; print(f"PASS  {name}")
    else: FAIL += 1; FAILURES.append(name); print(f"FAIL  {name}  {detail}")


class MockSuccessClient:
    def __init__(self, **kw): pass
    async def __aenter__(self): return self
    async def __aexit__(self, *a): return False
    async def post(self, url, json=None, **kw):
        class R:
            status_code = 200
            def raise_for_status(self): pass
            def json(self): return {"message": {"content": "摘要：讨论了10个话题，结论X，待办Y。"}}
        return R()


class FailClient:
    def __init__(self, **kw): pass
    async def __aenter__(self): return self
    async def __aexit__(self, *a): return False
    async def post(self, *a, **kw):
        import httpx
        raise httpx.ConnectError("ollama down")


async def main():
    import httpx
    import sidecar.config.store as cfgstore
    import sidecar.storage.store as store
    import sidecar.compactor as comp

    tmpdir = Path(tempfile.mkdtemp(prefix="m2compact_"))
    archive_dir = tmpdir / "compressed"
    archive_dir.mkdir()

    # 隔离 config（必须在调用 compact 前设好）
    orig_mem = dict(cfgstore._MEM) if cfgstore._MEM else {}
    cfgstore._MEM = {
        "ollama_base_url": "http://localhost:11434",
        "compact_archive_dir": str(archive_dir),
        "allow_auto_compact": False,
        "compact_keep_recent": 3,
        "data_root": str(tmpdir),
    }
    # checkpoint-062 修复：仅 patch config 不够——store 模块导入时已把
    # PROJECTS_ROOT/_GDB 解析为真实 ~/.subagent，create_project 等会写真实库。
    # 必须重定向存储层路径到临时目录（与 test_checkpoint050 等保持一致）。
    store.PROJECTS_ROOT = tmpdir / "projects"
    store._GDB = tmpdir / "projects" / "_global.db"
    store.PROJECTS_ROOT.mkdir(parents=True, exist_ok=True)

    workdir = tmpdir / "work"
    workdir.mkdir()
    pid = store.create_project("M2 Test", workdir)
    aid = store.add_agent_config(pid, "Test Agent", "main")

    orig_httpx = httpx.AsyncClient
    # patch compactor 的 get_config，确保读到测试配置（get_config 会从磁盘重建 _MEM）
    import sidecar.config as _cfgmod
    orig_get_config = comp.get_config
    comp.get_config = lambda: {
        "ollama_base_url": "http://localhost:11434",
        "compact_archive_dir": str(archive_dir),
        "allow_auto_compact": False,
        "compact_keep_recent": 3,
        "data_root": str(tmpdir),
    }
    try:
        # ── 场景 1：压缩成功 ──
        sid1 = store.create_session(pid, aid, "S1")
        for i in range(10):
            store.save_message(pid, sid1, aid, "user" if i % 2 == 0 else "assistant", f"消息 {i+1}")

        httpx.AsyncClient = lambda **kw: MockSuccessClient()
        r1 = await comp.compact_session(pid, sid1, keep_recent=3, model="qwen3.8")
        check("1 压缩成功 ok=True", r1.get("ok") is True, str(r1))
        check("1 before_tokens > 0", r1.get("before_tokens", 0) > 0, str(r1))
        check("1 archive_path 存在", Path(r1.get("archive_path", "")).exists(), r1.get("archive_path", ""))
        if r1.get("archive_path") and Path(r1["archive_path"]).exists():
            content = Path(r1["archive_path"]).read_text()
            check("1 归档含全部待压缩消息（消息1~7）",
                  all(f"消息 {i}" in content for i in range(1, 8)), content[:200])
        logs1 = store.load_compact_log(pid, sid1)
        check("1 compact_log 有成功记录", len(logs1) >= 1 and logs1[0].get("error") is None, str(logs1))
        msgs1 = store.load_messages(pid, sid1)
        # 保留 3 条 + 摘要 1 条 = 4
        check("1 消息数 = 保留3 + 摘要1 = 4", len(msgs1) == 4, f"count={len(msgs1)} contents={[m['content'][:10] for m in msgs1]}")
        check("1 摘要消息 role=system", msgs1[-1]["role"] == "system" and "历史摘要" in msgs1[-1]["content"], msgs1[-1])

        # ── 场景 2：归档写失败（目录只读）→ ok=False，消息不删 ──
        sid2 = store.create_session(pid, aid, "S2")
        for i in range(6):
            store.save_message(pid, sid2, aid, "user", f"归档测试 {i}")
        os.chmod(archive_dir, 0o555)  # 只读
        try:
            httpx.AsyncClient = lambda **kw: MockSuccessClient()
            r2 = await comp.compact_session(pid, sid2, keep_recent=3, model="qwen3.8")
            check("2 归档失败 → ok=False", r2.get("ok") is False, str(r2))
            msgs2 = store.load_messages(pid, sid2)
            check("2 原消息一条不删（仍 6 条）", len(msgs2) == 6, f"count={len(msgs2)}")
            logs2 = store.load_compact_log(pid, sid2)
            check("2 compact_log 有归档失败 error", any("归档失败" in (l.get("error") or "") for l in logs2), str(logs2))
        finally:
            os.chmod(archive_dir, 0o755)

        # ── 场景 3：摘要失败 → ok=False，消息不删 ──
        sid3 = store.create_session(pid, aid, "S3")
        for i in range(6):
            store.save_message(pid, sid3, aid, "user", f"摘要测试 {i}")
        httpx.AsyncClient = lambda **kw: FailClient()
        r3 = await comp.compact_session(pid, sid3, keep_recent=3, model="qwen3.8")
        check("3 摘要失败 → ok=False", r3.get("ok") is False, str(r3))
        msgs3 = store.load_messages(pid, sid3)
        check("3 原消息一条不删（仍 6 条）", len(msgs3) == 6, f"count={len(msgs3)}")
        logs3 = store.load_compact_log(pid, sid3)
        check("3 compact_log 有摘要失败 error", any("摘要失败" in (l.get("error") or "") for l in logs3), str(logs3))

        # ── 场景 4：keep_recent 保护 ──
        sid4 = store.create_session(pid, aid, "S4")
        for i in range(8):
            store.save_message(pid, sid4, aid, "user", f"保护 {i+1}")
        httpx.AsyncClient = lambda **kw: MockSuccessClient()
        msgs_before = store.load_messages(pid, sid4)
        last3 = [m["content"] for m in msgs_before[-3:]]
        r4 = await comp.compact_session(pid, sid4, keep_recent=3, model="qwen3.8")
        check("4 压缩成功", r4.get("ok") is True, str(r4))
        msgs_after = store.load_messages(pid, sid4)
        # 最近 3 条原消息内容必须保留
        contents_after = [m["content"] for m in msgs_after]
        check("4 keep_recent 保护：最近 3 条原消息内容都在",
              all(c in contents_after for c in last3),
              f"last3={last3} after={contents_after}")
        check("4 归档只含待压缩区（保护1-5 在归档，6-8 不在）",
              r4.get("archived_count") == 5, str(r4))

        # ── M3 前置安全加固 L2：导出目录校验 ──
        sid_exp = store.create_session(pid, aid, "导出")
        store.save_message(pid, sid_exp, aid, "user", "hello")
        import sidecar.compactor as comp2
        try:
            comp2.export_session_md(pid, sid_exp, str(archive_dir))
            check("L2 合法导出目录 OK", True)
        except ValueError as e:
            check("L2 合法导出目录 OK", False, str(e))
        try:
            comp2.export_session_md(pid, sid_exp, "../../etc/cron.d")
            check("L2 非法导出目录 → ValueError", False, "未抛异常")
        except ValueError:
            check("L2 非法导出目录 → ValueError", True)
    finally:
        httpx.AsyncClient = orig_httpx
        comp.get_config = orig_get_config
        cfgstore._MEM = orig_mem
        import shutil
        shutil.rmtree(tmpdir, ignore_errors=True)

    check("临时目录已清理", not tmpdir.exists())
    print(f"\n===== M2 压缩: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("FAILED:", ", ".join(FAILURES))
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())


# ──────────────────────────────────────────────────────────────────────
# M2 打回修复：compact_auto 服务端闭环（app.py SSE 转发循环）
# ──────────────────────────────────────────────────────────────────────
async def main_server_side():
    """测 app.py 对 compact_auto 的服务端闭环（真调 compact_session / 失败降级）。"""
    import tempfile, asyncio
    from pathlib import Path as _P
    import httpx
    import sidecar.config as _cfgmod
    import sidecar.config.store as cfgstore
    import sidecar.compactor as comp
    import sidecar.app as appmod
    from fastapi.testclient import TestClient

    tmp = _P(tempfile.mkdtemp(prefix="m2autoc_"))
    workdir = tmp / "work"; workdir.mkdir()
    archive = tmp / "compressed"; archive.mkdir()

    # 配置：allow_auto_compact=True
    orig_mem = dict(cfgstore._MEM) if cfgstore._MEM else {}
    test_cfg = {
        "ollama_base_url": "http://localhost:11434",
        "compact_archive_dir": str(archive),
        "allow_auto_compact": True,
        "compact_keep_recent": 3,
        "data_root": str(tmp),
        "max_tool_rounds": 50,
        "network_switch": "auto",
    }
    orig_get_cfg = _cfgmod.get_config
    _cfgmod.get_config = lambda: dict(test_cfg)

    # 建项目/agent/session
    import sidecar.storage.store as store
    # checkpoint-062 修复：与第一阶段同理，必须重定向存储层到本阶段临时目录
    # （main() 已删除自己的 tmp，store 旧指针失效；且不得写真实库）。
    store.PROJECTS_ROOT = tmp / "projects"
    store._GDB = tmp / "projects" / "_global.db"
    store.PROJECTS_ROOT.mkdir(parents=True, exist_ok=True)
    pid = store.create_project("AutoC", workdir)
    aid = store.add_agent_config(pid, "A", "main")
    sid = store.create_session(pid, aid, "S")
    store.save_message(pid, sid, aid, "user", "初始消息")

    # mock connector：每轮返回工具调用 + 高 prompt_eval_count（触发 ≥90%）
    # 真实 Ollama qwen3.8 context_length=262144，用 pe=250000（≥90%）触发预警
    class HighConn:
        def __init__(self): self.calls = 0
        async def chat_stream(self, model, messages, tools=None):
            self.calls += 1
            yield {"tool_calls": [{"id": f"t{self.calls}", "function": {"name": "list_dir", "arguments": "{}"}}]}
            yield {"done": True, "counts": {"prompt_eval_count": 250000, "eval_count": 1}}

    # patch appmod.get_ollama_connector → 返回 HighConn
    class FakeConnFactory:
        def __init__(self): self._c = HighConn()
        def __call__(self): return self._c
        async def aclose_all(self): pass
    high_factory = FakeConnFactory()
    import sidecar.ollama.connector as _connmod
    orig_goc = _connmod.get_ollama_connector
    # loop.py 内部 from sidecar.ollama.connector import get_ollama_connector → 必须 patch 源头模块
    _connmod.get_ollama_connector = lambda: high_factory._c

    # mock compact_session 并计数
    call_count = {"n": 0}
    orig_compact = comp.compact_session
    async def mock_compact_ok(pid_, sid_, keep_recent=None, model="qwen3.8"):
        call_count["n"] += 1
        return {"ok": True, "before_tokens": 950, "after_tokens": 100,
                "archive_path": str(archive / "x.md"), "archived_count": 5}
    comp.compact_session = mock_compact_ok
    # app.py 内是 from sidecar.compactor import compact_session as _compact（函数内导入）
    import sidecar.compactor as _comp2
    _comp2.compact_session = mock_compact_ok

    client = TestClient(appmod.app)
    try:
        # ── 用例 22：compact_auto 成功 → 事件含 compact_auto，无死循环 ──
        high_factory._c = HighConn()
        r = client.post("/api/ollama/chat/stream", json={
            "agent_id": aid, "model": "qwen3.8",
            "messages": [{"role": "user", "content": "长任务"}],
            "project_id": pid, "session_id": sid, "sandbox_root": str(workdir),
        })
        body = r.text
        events = [ln for ln in body.split("\n") if ln.startswith("event: ")]
        ev_names = [ln.split("event: ")[1] for ln in events]
        check("22a compact_auto 成功 → 事件流含 compact_auto", "compact_auto" in ev_names, str(ev_names))
        check("22b 无死循环（事件数 < 30）", len(ev_names) < 30, f"events={len(ev_names)}")
        check("22c compact_session 被调用 1 次", call_count["n"] == 1, f"calls={call_count['n']}")

        # ── 用例 23：compact_session 失败 → 降级 compact_required ──
        call_count["n"] = 0
        high_factory._c = HighConn()
        async def mock_compact_fail(pid_, sid_, keep_recent=None, model="qwen3.8"):
            call_count["n"] += 1
            return {"ok": False, "error": "归档目录只读"}
        _comp2.compact_session = mock_compact_fail
        r2 = client.post("/api/ollama/chat/stream", json={
            "agent_id": aid, "model": "qwen3.8",
            "messages": [{"role": "user", "content": "长任务2"}],
            "project_id": pid, "session_id": sid, "sandbox_root": str(workdir),
        })
        events2 = [ln for ln in r2.text.split("\n") if ln.startswith("event: ")]
        ev2 = [ln.split("event: ")[1] for ln in events2]
        check("23a 压缩失败 → 出现 compact_required（前端三选一可用）", "compact_required" in ev2, str(ev2))
        check("23b 失败也调用了 compact_session 1 次", call_count["n"] == 1, f"calls={call_count['n']}")
    finally:
        _comp2.compact_session = orig_compact
        _connmod.get_ollama_connector = orig_goc
        _cfgmod.get_config = orig_get_cfg
        cfgstore._MEM = orig_mem
        import shutil
        shutil.rmtree(tmp, ignore_errors=True)

    check("服务端闭环：临时目录已清理", not tmp.exists())
    print(f"\n===== M2 自动压缩闭环: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("FAILED:", ", ".join(FAILURES))
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
    asyncio.run(main_server_side())
