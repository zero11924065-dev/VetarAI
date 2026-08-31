"""TS-108 M3-2 重试端点单测（TestClient + 打桩 run_delegated_task）。
venv 内 python test_retry.py 直接跑（需 PYTHONPATH=subagent/）。只输出 PASS/FAIL 摘要。
"""
import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

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


def main():
    TMP = Path(tempfile.mkdtemp(prefix="m32retry_"))
    import sidecar.storage.store as store
    store.PROJECTS_ROOT = TMP
    store._GDB = TMP / "_global.db"
    from sidecar import app as appmod
    appmod.get_config = lambda: {"network_switch": "auto", "max_tool_rounds": 5,
                                 "auto_create_sub_agents": True}

    calls = []

    async def fake_delegated(project_id, parent_agent_id, parent_session_id,
                             target_agent, task, expect, sandbox_root=None,
                             authorizer=None, max_rounds=200, connector=None):
        calls.append({"project_id": project_id, "target": target_agent.get("name"),
                      "task": task, "expect": expect, "sandbox_root": sandbox_root,
                      "authorizer": authorizer})
        return {"ok": True, "task_id": "new-task-id", "status": "success",
                "summary": "重试成功", "artifacts": []}

    orig_run = appmod.run_delegated_task
    appmod.run_delegated_task = fake_delegated

    pid = store.create_project("retry-proj", TMP / "wd")
    main_id = store.add_agent_config(pid, "Alpha", "main", model_name="qwen3.8")
    beta_id = store.add_agent_config(pid, "Beta", "sub", model_name="qwen3.8")
    parent_sid = store.create_session(pid, main_id)

    from fastapi.testclient import TestClient
    client = TestClient(appmod.app)

    # ── 1. failed 任务重试 → 新任务执行 ──
    tid_fail = store.create_agent_task(pid, main_id, parent_sid, beta_id, "Beta", "原任务书", "原标准")
    store.update_agent_task(pid, tid_fail, status="failed", fail_reason="交卷格式两次校验未通过")
    r = client.post(f"/api/projects/{pid}/tasks/{tid_fail}/retry")
    check("1a failed 重试 HTTP 200", r.status_code == 200, str(r.status_code) + r.text[:150])
    d = r.json()
    check("1b 返回 new_task_id + result.ok",
          d.get("new_task_id") == "new-task-id" and d.get("result", {}).get("ok") is True, str(d)[:200])
    check("1c 执行参数透传原任务书/标准/目标",
          calls and calls[-1]["task"] == "原任务书" and calls[-1]["expect"] == "原标准"
          and calls[-1]["target"] == "Beta" and calls[-1]["authorizer"] is None,
          str(calls[-1]) if calls else "未调用")
    check("1d sandbox_root 取自项目工作目录（与 projects 表存储值一致）",
          calls and calls[-1]["sandbox_root"] == str(Path(TMP / "wd").resolve()),
          str(calls[-1]) if calls else "")
    old = store.get_agent_task(pid, tid_fail)
    check("1e 旧任务保持 failed 不被改动", old["status"] == "failed", str(old)[:120])

    # ── 2. 状态守卫 ──
    tid_done = store.create_agent_task(pid, main_id, parent_sid, beta_id, "Beta", "t", "e")
    store.update_agent_task(pid, tid_done, status="done")
    r2 = client.post(f"/api/projects/{pid}/tasks/{tid_done}/retry")
    check("2a done 任务重试 → 400", r2.status_code == 400, str(r2.status_code))
    tid_q = store.create_agent_task(pid, main_id, parent_sid, beta_id, "Beta", "t2", "e2")
    r3 = client.post(f"/api/projects/{pid}/tasks/{tid_q}/retry")
    check("2b queued 任务重试 → 400", r3.status_code == 400, str(r3.status_code))
    r4 = client.post(f"/api/projects/{pid}/tasks/nonexistent/retry")
    check("2c 不存在任务 → 404", r4.status_code == 404, str(r4.status_code))

    # ── 3. 目标 Agent 已删除 → 400 ──
    tid_orphan = store.create_agent_task(pid, main_id, parent_sid, beta_id, "Beta", "t3", "e3")
    store.update_agent_task(pid, tid_orphan, status="failed")
    store.remove_agent_config(pid, beta_id)  # 删目标（会清其会话/消息，任务记录保留）
    r5 = client.post(f"/api/projects/{pid}/tasks/{tid_orphan}/retry")
    check("3 目标 Agent 已删 → 400", r5.status_code == 400 and "Agent" in r5.json().get("detail", ""),
          str(r5.status_code) + r5.text[:100])

    # ── 4. /tasks 列表可见 ──
    lst = client.get(f"/api/projects/{pid}/tasks").json()
    ids = [t["id"] for t in lst]
    check("4 任务列表含 failed 记录（倒序齐全）",
          tid_fail in ids and tid_done in ids and len(lst) >= 3, str(ids)[:200])

    appmod.run_delegated_task = orig_run
    import shutil
    shutil.rmtree(TMP, ignore_errors=True)
    check("测试临时目录已清理", not TMP.exists())

    print(f"\n===== M3-2 重试端点专项: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("FAILED:", ", ".join(FAILURES))
        sys.exit(1)


if __name__ == "__main__":
    main()
