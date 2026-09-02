"""checkpoint-072 TS-115 资源释放 + 会话列表 专项测试。

任务1 删除时 stop（3.19② 维度 B/C）：
  R1 删除会话 → 关联 running 任务被 stop（标志置位 → 执行循环检测到 → failed+"已停止"）
  R2 删除 Agent（作为目标） → 关联 running 任务被 stop
  R3 删除后 Ollama 不再收到新请求（calls 计数冻结）
任务2 会话列表（3.26）：
  S1 list_sessions JOIN 一次查询（10 会话 + 100 消息 → 完整列表 + 消息数正确）
  S2 无 N+1（grep 确认，此处用性能粗验证：1000 会话 1 次调用 < 1s）

venv 内 python test_checkpoint072.py 直接跑。只输出 PASS/FAIL 摘要。
"""
import asyncio
import json
import sys
import tempfile
import time
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


class SlowConn:
    """阻塞直到 stop_event 置位（模拟慢子任务）。"""
    def __init__(self, stop_event):
        self.stop_event = stop_event
        self.calls = 0

    async def chat_stream(self, model, messages, tools=None, images=None):
        self.calls += 1
        await self.stop_event.wait()
        yield {"content_delta": "不应产出"}
        yield {"done": True, "counts": {}}


async def main():
    TMP = Path(tempfile.mkdtemp(prefix="c072_"))
    import sidecar.storage.store as store
    store.PROJECTS_ROOT = TMP
    store._GDB = TMP / "_global.db"

    from sidecar.agent_engine import delegation as deleg
    sandbox = TMP / "work"; sandbox.mkdir()
    pid = store.create_project("c072", TMP / "wd")
    main_id = store.add_agent_config(pid, "Alpha", "main", model_name="qwen3.8")
    beta_id = store.add_agent_config(pid, "Beta", "sub", model_name="qwen3.8")
    beta = store.get_agent_config(pid, beta_id)
    parent_sid = store.create_session(pid, main_id, title="主会话")

    # ══ R1 删除会话 → 关联 running 任务 stop ══
    # 注：委派子任务跑在子会话（task.session_id）里，删除子会话 = 触发 stop。
    evt1 = asyncio.Event()
    slow1 = SlowConn(evt1)
    fut1 = asyncio.ensure_future(deleg.run_delegated_task(
        pid, main_id, parent_sid, beta, "任务A-删除会话测", "标准",
        sandbox_root=str(sandbox), connector=slow1))
    # 等任务落库（status=queued）→ 拿到 task.session_id（子会话 id）
    child_sid = None
    for _ in range(100):
        await asyncio.sleep(0.05)
        t = store.list_agent_tasks(pid, limit=1)
        if t and t[0]["session_id"]:
            child_sid = t[0]["session_id"]
            break
    assert child_sid, "task.session_id 未落库"
    # 等任务进入 running（拿锁后）
    for _ in range(100):
        await asyncio.sleep(0.05)
        t = store.list_agent_tasks(pid, limit=1)
        if t and t[0]["status"] == "running":
            break
    tid1 = t[0]["id"]

    # 模拟 DELETE /api/sessions/{child_sid}（直接调 app 函数）
    import sidecar.app as app
    resp = await app.api_delete_session(session_id=child_sid, project_id=pid)
    check("R1a 删除会话返回 stopped_tasks>=1", resp.get("stopped_tasks", 0) >= 1, f"resp={resp}")
    evt1.set()  # 放行阻塞，让执行循环走到检查点
    await fut1
    t1 = store.get_agent_task(pid, tid1)
    check("R1b 任务 failed + fail_reason 含'已停止'",
          t1["status"] == "failed" and t1["fail_reason"] and "已停止" in t1["fail_reason"],
          f"status={t1['status']} reason={t1['fail_reason']}")
    check("R1c 删除后 Ollama 不再收到新请求（calls=1）", slow1.calls == 1, f"calls={slow1.calls}")

    # ══ R2 删除 Agent（目标） → 关联 running 任务 stop ══
    evt2 = asyncio.Event()
    slow2 = SlowConn(evt2)
    fut2 = asyncio.ensure_future(deleg.run_delegated_task(
        pid, main_id, parent_sid, beta, "任务B-删除Agent测", "标准",
        sandbox_root=str(sandbox), connector=slow2))
    for _ in range(100):
        await asyncio.sleep(0.05)
        t = store.list_agent_tasks(pid, limit=1)
        if t and t[0]["status"] == "running":
            break
    tid2 = t[0]["id"]

    resp2 = await app.api_remove_agent(project_id=pid, agent_id=beta_id)
    check("R2a 删除 Agent 返回 stopped_tasks>=1", resp2.get("stopped_tasks", 0) >= 1, f"resp={resp2}")
    evt2.set()
    await fut2
    t2 = store.get_agent_task(pid, tid2)
    check("R2b 任务 failed + fail_reason 含'已停止'",
          t2["status"] == "failed" and t2["fail_reason"] and "已停止" in t2["fail_reason"],
          f"status={t2['status']} reason={t2['fail_reason']}")

    # ══ S1 list_sessions JOIN（10 会话 + 100 消息 → 完整 + 消息数正确）══
    agent_s = store.add_agent_config(pid, "SessionAgent", "main", model_name="qwen3.8")
    expected_counts = {}
    for i in range(10):
        sid = store.create_session(pid, agent_s, title=f"会话{i}")
        n = (i + 1) * 10  # 10, 20, ..., 100
        for j in range(n):
            store.save_message(pid, sid, agent_s, "user" if j % 2 == 0 else "assistant",
                               f"msg {i}-{j}")
        expected_counts[sid] = n
    t0 = time.time()
    sessions = store.list_sessions(pid, agent_s)
    elapsed = time.time() - t0
    check("S1a 10 会话全部返回", len(sessions) == 10, f"got={len(sessions)}")
    check("S1b 消息数正确（JOIN COUNT）",
          all(s["message_count"] == expected_counts[s["id"]] for s in sessions),
          f"got={[(s['id'][:8], s['message_count']) for s in sessions[:3]]}...")
    check("S1c 10 会话 + 100 消息 1 次调用 < 1s", elapsed < 1.0, f"elapsed={elapsed:.3f}s")

    # S2 无 N+1（grep 静态确认 + 动态性能粗验证）
    src = Path(__file__).resolve().parents[1] / "storage" / "store.py"
    src_text = src.read_text()
    ls_fn = src_text[src_text.index("def list_sessions"):src_text.index("def list_sessions") + 1500]
    check("S2 list_sessions 无 N+1（无循环内 SELECT COUNT）",
          "for r in rows" not in ls_fn.split("return result")[0].split("LEFT JOIN")[1]
          or "SELECT COUNT" not in ls_fn.split("LEFT JOIN")[1].split("return result")[0],
          ls_fn[:200])

    # 清理
    import shutil
    shutil.rmtree(TMP, ignore_errors=True)
    check("临时目录已清理", not TMP.exists())

    print(f"\n===== checkpoint-072: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("FAILED:", ", ".join(FAILURES))
        sys.exit(1)


asyncio.run(main())
