"""checkpoint-071 TS-114 委派停止 + 委派图片传递 专项测试。

覆盖（任务单 TS-114 验收标准）：
任务1 委派停止：
  S1 request_delegation_cancel 后 run_delegated_task 在检查点中止 → failed + fail_reason 含"已停止"
  S2 停止后不再发起模型调用（connector 调用计数冻结）
  S3 未取消任务正常完成（不受标志影响；标志在任务结束后清理）
  S4 /stop 端点：running 任务 → 200 ok；done/failed 任务 → 400；不存在 → 404
任务2 委派图片：
  I1 委派任务书含"附图 X 张已随任务书发送"提示（X>0）
  I2 子 Agent connector.chat_stream 收到 images（base64）
  I3 无图委派：任务书无"附图"提示

venv 内 python test_checkpoint071.py 直接跑。只输出 PASS/FAIL 摘要。
"""
import asyncio
import json
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


class SlowConn:
    """每轮 chat_stream 阻塞到 stop_event 被置位才产出（模拟慢子任务）。"""
    def __init__(self, stop_event):
        self.stop_event = stop_event
        self.calls = 0
        self.seen_images = []

    async def chat_stream(self, model, messages, tools=None, images=None):
        self.calls += 1
        if images:
            self.seen_images.append(list(images))
        await self.stop_event.wait()  # 阻塞，直到测试侧取消或放行
        yield {"content_delta": "（不应产出）"}
        yield {"done": True, "counts": {"prompt_eval_count": 5, "eval_count": 5}}


class ImgReportConn:
    """记录收到的 images 参数，直接交卷成功。"""
    def __init__(self):
        self.seen_images = []

    def _report(self, tid):
        return json.dumps({"task_id": tid, "status": "success",
                           "summary": "看图完成", "artifacts": []}, ensure_ascii=False)

    async def chat_stream(self, model, messages, tools=None, images=None):
        if images:
            self.seen_images.append(list(images))
        # 取任务 ID：从最后一条 user 消息（任务书）里抓
        tid = ""
        for m in reversed(messages):
            if m.get("role") == "user" and "任务ID：" in (m.get("content") or ""):
                line = [l for l in m["content"].splitlines() if l.startswith("任务ID：")]
                if line:
                    tid = line[0].split("：", 1)[1].strip()
                break
        self.last_tid = tid
        yield {"content_delta": self._report(tid)}
        yield {"done": True, "counts": {"prompt_eval_count": 5, "eval_count": 5}}


async def main():
    TMP = Path(tempfile.mkdtemp(prefix="c071_"))
    import sidecar.storage.store as store
    store.PROJECTS_ROOT = TMP
    store._GDB = TMP / "_global.db"

    from sidecar.agent_engine import delegation as deleg

    sandbox = TMP / "work"
    sandbox.mkdir()
    pid = store.create_project("c071", TMP / "wd")
    main_id = store.add_agent_config(pid, "Alpha", "main", model_name="qwen3.8")
    beta_id = store.add_agent_config(pid, "Beta", "sub", model_name="qwen3.8")
    beta = store.get_agent_config(pid, beta_id)
    parent_sid = store.create_session(pid, main_id, title="主会话")

    # ══ S1/S2 停止机制：慢任务 + 取消 → failed + 含"已停止" + 不再调模型 ══
    stop_evt = asyncio.Event()
    slow = SlowConn(stop_evt)
    fut = asyncio.ensure_future(deleg.run_delegated_task(
        pid, main_id, parent_sid, beta, "长任务A", "标准输出",
        sandbox_root=str(sandbox), connector=slow))
    # 等任务进入 running（落库后拿锁即置 running）
    for _ in range(100):
        await asyncio.sleep(0.05)
        tasks = store.list_agent_tasks(pid, limit=1)
        if tasks and tasks[0]["status"] == "running":
            break
    check("S0 任务进入 running", bool(tasks) and tasks[0]["status"] == "running",
          f"tasks={[(t['status']) for t in tasks]}")
    tid = tasks[0]["id"]

    # 置取消标志（模拟 /stop 端点）
    deleg.request_delegation_cancel(tid)
    # 放行阻塞的 chat_stream，让执行循环走到下一个检查点
    stop_evt.set()
    res = await fut

    t = store.get_agent_task(pid, tid)
    check("S1a 停止后任务 failed", t["status"] == "failed", f"status={t['status']} reason={t['fail_reason']}")
    check("S1b fail_reason 含『已停止』", bool(t["fail_reason"]) and "已停止" in t["fail_reason"],
          f"reason={t['fail_reason']}")
    check("S2 停止后未再产出模型调用（调用数=1）", slow.calls == 1, f"calls={slow.calls}")
    check("S3 任务结束后取消标志已清理",
          not deleg._is_delegation_cancelled(tid), "标志残留 → 会误伤后续重试")

    # ══ S3b 无取消任务正常完成 ══
    class OkConn:
        async def chat_stream(self, model, messages, tools=None, images=None):
            tid2 = ""
            for m in reversed(list(messages)):
                if m.get("role") == "user" and "任务ID：" in (m.get("content") or ""):
                    line = [l for l in m["content"].splitlines() if l.startswith("任务ID：")]
                    if line:
                        tid2 = line[0].split("：", 1)[1].strip()
                    break
            yield {"content_delta": json.dumps(
                {"task_id": tid2, "status": "success", "summary": "OK", "artifacts": []},
                ensure_ascii=False)}
            yield {"done": True, "counts": {}}
    res3 = await deleg.run_delegated_task(
        pid, main_id, parent_sid, beta, "正常任务B", "标准输出",
        sandbox_root=str(sandbox), connector=OkConn())
    check("S3b 未取消任务正常 done", res3.get("ok") is True, str(res3)[:120])

    # ══ S4 /stop 端点（TestClient）══
    from fastapi.testclient import TestClient
    import sidecar.app as app
    client = TestClient(app.app)
    # 造一个 running 任务
    trunning = store.create_agent_task(pid, main_id, parent_sid, beta_id, "Beta", "t", "e")
    store.update_agent_task(pid, trunning, status="running")
    r = client.post(f"/api/projects/{pid}/tasks/{trunning}/stop")
    check("S4a running 任务 stop → 200 ok", r.status_code == 200 and r.json().get("ok") is True,
          f"{r.status_code} {r.text[:80]}")
    # done 任务 → 400
    tdone = store.create_agent_task(pid, main_id, parent_sid, beta_id, "Beta", "t", "e")
    store.update_agent_task(pid, tdone, status="done")
    r2 = client.post(f"/api/projects/{pid}/tasks/{tdone}/stop")
    check("S4b done 任务 stop → 400", r2.status_code == 400, f"{r2.status_code} {r2.text[:80]}")
    # 不存在 → 404
    r3 = client.post(f"/api/projects/{pid}/tasks/no-such-task/stop")
    check("S4c 不存在任务 stop → 404", r3.status_code == 404, f"{r3.status_code}")
    # 清理标志
    deleg.clear_delegation_cancel(trunning)
    # 清掉 D-8 去重干扰（相同任务文本会命中失败计数）：后续 I 用例任务文本各不相同

    # ══ I1/I2/I3 委派图片传递 ══
    IMG = ["data:image/png;base64,QUJD", "data:image/jpeg;base64,REVG"]
    ic = ImgReportConn()
    resI = await deleg.run_delegated_task(
        pid, main_id, parent_sid, beta, "看图任务C", "标准输出",
        sandbox_root=str(sandbox), connector=ic, images=IMG)
    check("I0 带图委派正常 done", resI.get("ok") is True, str(resI)[:120])
    check("I2 子 Agent chat_stream 收到 images（2张 base64）",
          ic.seen_images and IMG[0] in ic.seen_images[0] and IMG[1] in ic.seen_images[0],
          f"seen={ic.seen_images}")

    # I1 任务书含"附图 X 张"提示：查子会话最后一条 user 消息
    ti = store.list_agent_tasks(pid, limit=1)[0]
    msgs = store.load_messages(pid, ti["session_id"]) if ti.get("session_id") else []
    user_msgs = [m for m in msgs if m.get("role") == "user"]
    task_book = user_msgs[0]["content"] if user_msgs else ""
    check("I1 任务书含『附图 2 张已随任务书发送』",
          "附图 2 张已随任务书发送" in task_book, task_book[:120])

    # I3 无图委派：任务书无"附图"提示
    ic2 = ImgReportConn()
    resI2 = await deleg.run_delegated_task(
        pid, main_id, parent_sid, beta, "无图任务D", "标准输出",
        sandbox_root=str(sandbox), connector=ic2)
    check("I3a 无图委派正常 done", resI2.get("ok") is True, str(resI2)[:120])
    t2 = store.list_agent_tasks(pid, limit=1)[0]
    msgs2 = store.load_messages(pid, t2["session_id"]) if t2.get("session_id") else []
    user2 = [m for m in msgs2 if m.get("role") == "user"][0]["content"] if any(m.get("role") == "user" for m in msgs2) else ""
    check("I3b 无图任务书无『附图』提示", "附图" not in user2, user2[:120])

    # 清理
    import shutil
    shutil.rmtree(TMP, ignore_errors=True)
    check("临时目录已清理", not TMP.exists())

    print(f"\n===== checkpoint-071: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("FAILED:", ", ".join(FAILURES))
        sys.exit(1)


asyncio.run(main())
