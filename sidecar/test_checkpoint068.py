"""checkpoint-068 新机制专项测试（mock connector，venv 内 python test_checkpoint068.py 直接跑）。
覆盖：
- D-7 活性超时（挂起模型 + 小超时 → 判卡死中止）
- D-8 去重（相同任务文本已存在且未失败 → 拒绝重复委派）
- D-8 失败重试上限（相同任务文本失败数达上限 → 拒绝继续重试）
- D-2 自动清理（开关开 + 交卷 success → 删子 Agent 与会话）
- D-4 并发开关（task_concurrency=True 用不阻塞锁；默认串行锁）
只输出 PASS/FAIL 摘要。隔离数据目录（不碰 ~/.subagent）。
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


class ScriptConn:
    """按脚本返回文本的假 connector。"""
    def __init__(self, scripts, store_mod, project_id, delay=0.0):
        self.scripts = scripts
        self.store = store_mod
        self.pid = project_id
        self.calls = 0
        self.delay = delay

    def _current_tid(self):
        tasks = self.store.list_agent_tasks(self.pid, limit=1)
        return tasks[0]["id"] if tasks else ""

    async def chat_stream(self, model, messages, tools=None):
        i = min(self.calls, len(self.scripts) - 1)
        item = self.scripts[i]
        self.calls += 1
        if self.delay:
            await asyncio.sleep(self.delay)
        text = item(self._current_tid()) if callable(item) else item
        yield {"content_delta": text}
        yield {"done": True, "counts": {"prompt_eval_count": 10, "eval_count": 5}}


class HangingConn:
    """挂起模拟模型僵死（永不产出）。"""
    async def chat_stream(self, model, messages, tools=None):
        yield {"content_delta": "部分"}
        await asyncio.Event().wait()  # 永久挂起


async def main():
    TMP = Path(tempfile.mkdtemp(prefix="ck068_"))
    import sidecar.storage.store as store
    store.PROJECTS_ROOT = TMP
    store._GDB = TMP / "_global.db"

    # mock 配置（D-7/D-8/D-2/D-4 均读 sidecar.config.get_config）
    import sidecar.config as cfgmod
    _CFG = {
        "delegation_activity_timeout": 0,   # 默认关，D-7 单独用例再开
        "delegation_max_retries": 2,
        "delegation_auto_cleanup": False,
        "task_concurrency": False,
    }
    _orig_get_config = cfgmod.get_config
    cfgmod.get_config = lambda: dict(_CFG)

    from sidecar.agent_engine import delegation as dlg
    from sidecar.agent_engine.delegation import (
        run_delegated_task, _dup_or_over_retry_limit, _norm_task_text,
    )

    sandbox = TMP / "work"
    sandbox.mkdir()

    pid = store.create_project("ck068", TMP / "wd")
    main_id = store.add_agent_config(pid, "Main", "main", model_name="qwen3.8")
    sub_id = store.add_agent_config(pid, "Sub", "sub", model_name="qwen3.8",
                                    role="子", system_prompt="简洁")
    parent_sid = store.create_session(pid, main_id, title="主会话")

    def success_report(tid):
        # ScriptConn 调用 callable 时会传入当前任务 id（item(self._current_tid())）
        return json.dumps({"task_id": tid, "status": "success",
                           "summary": "完成了", "artifacts": []}, ensure_ascii=False)

    # ══ D-7 活性超时 ══
    # 开关：小超时 0.3 秒 + 挂起模型 → 判卡死
    _CFG["delegation_activity_timeout"] = 0.3
    r = await run_delegated_task(pid, main_id, parent_sid,
                                 {"id": sub_id, "name": "Sub", "model_name": "qwen3.8"},
                                 "活性测试任务", "标准",
                                 sandbox_root=str(sandbox), max_rounds=3,
                                 connector=HangingConn())
    check("D-7a 挂起模型超活性超时 → ok=False", r.get("ok") is False, str(r)[:120])
    check("D-7b 错误含'活性超时'", "活性超时" in (r.get("error") or ""), str(r)[:120])
    check("D-7c 错误含'请勿盲目重试'", "请勿盲目重试" in (r.get("error") or ""), str(r)[:120])
    # 任务状态标 failed + fail_reason 含活性超时
    t = store.get_agent_task(pid, r.get("task_id", ""))
    check("D-7d 任务标 failed + fail_reason 含活性超时",
          t and t["status"] == "failed" and "活性超时" in (t.get("fail_reason") or ""),
          str(t)[:120] if t else "None")
    _CFG["delegation_activity_timeout"] = 0  # 复位

    # ══ D-8 去重 ══
    # 先成功委派一个任务（用正常交卷），落库 done
    _CFG["delegation_max_retries"] = 2
    conn_ok = ScriptConn([success_report], store, pid)
    r1 = await run_delegated_task(pid, main_id, parent_sid,
                                  {"id": sub_id, "name": "Sub", "model_name": "qwen3.8"},
                                  "去重任务A", "标准",
                                  sandbox_root=str(sandbox), max_rounds=3, connector=conn_ok)
    check("D-8a 首次委派成功", r1.get("ok") is True, str(r1)[:120])
    # 再次委派相同任务文本 → 已存在 done → 拒绝（去重）
    dup, fails = _dup_or_over_retry_limit(pid, sub_id, "去重任务A")
    check("D-8b 相同任务文本（已 done）识别为重复", dup is not None, f"dup={dup} fails={fails}")
    r2 = await run_delegated_task(pid, main_id, parent_sid,
                                  {"id": sub_id, "name": "Sub", "model_name": "qwen3.8"},
                                  "去重任务A", "标准",
                                  sandbox_root=str(sandbox), max_rounds=3,
                                  connector=ScriptConn([success_report], store, pid))
    check("D-8c 重复委派被拒", r2.get("ok") is False and "请勿重复委派" in (r2.get("error") or ""),
          str(r2)[:120])
    # 归一化：空白差异视为相同任务
    check("D-8d 归一化空白差异识别为相同任务",
          _norm_task_text("  去重任务A  ") == _norm_task_text("去重任务A"))

    # ══ D-8 失败重试上限 ══
    # 制造 2 条相同任务文本的 failed（用无效交卷触发校验失败）
    conn_bad = ScriptConn(["无效交卷"] * 4, store, pid)
    for _ in range(2):
        await run_delegated_task(pid, main_id, parent_sid,
                                 {"id": sub_id, "name": "Sub", "model_name": "qwen3.8"},
                                 "重试上限任务B", "标准",
                                 sandbox_root=str(sandbox), max_rounds=3,
                                 connector=ScriptConn(["无效交卷"] * 4, store, pid))
    dup_b, fails_b = _dup_or_over_retry_limit(pid, sub_id, "重试上限任务B")
    check("D-8e 相同任务文本失败 2 次被计数", fails_b == 2, f"dup={dup_b} fails={fails_b}")
    r3 = await run_delegated_task(pid, main_id, parent_sid,
                                  {"id": sub_id, "name": "Sub", "model_name": "qwen3.8"},
                                  "重试上限任务B", "标准",
                                  sandbox_root=str(sandbox), max_rounds=3,
                                  connector=ScriptConn(["无效交卷"] * 4, store, pid))
    check("D-8f 失败达上限后拒绝继续重试",
          r3.get("ok") is False and "请勿继续重试" in (r3.get("error") or ""), str(r3)[:120])
    # 不同任务文本不受影响
    dup_c, fails_c = _dup_or_over_retry_limit(pid, sub_id, "全新任务C")
    check("D-8g 不同任务文本不计数", dup_c is None and fails_c == 0,
          f"dup={dup_c} fails={fails_c}")

    # ══ D-2 自动清理 ══
    # 开开关 + 交卷 success + sub 型 → 删子 Agent 与会话
    _CFG["delegation_auto_cleanup"] = True
    # 用一个全新子 Agent（避免被前面任务影响）
    cleanup_sub = store.add_agent_config(pid, "CleanupSub", "sub", model_name="qwen3.8")
    r4 = await run_delegated_task(pid, main_id, parent_sid,
                                  {"id": cleanup_sub, "name": "CleanupSub", "model_name": "qwen3.8"},
                                  "清理任务D", "标准",
                                  sandbox_root=str(sandbox), max_rounds=3,
                                  connector=ScriptConn([success_report], store, pid))
    check("D-2a 开关开+success 委派成功", r4.get("ok") is True, str(r4)[:120])
    check("D-2b 子 Agent 被清理",
          store.get_agent_config(pid, cleanup_sub) is None, "子 Agent 仍存在")
    # 主 Agent 未被误删
    check("D-2c 主 Agent 未被误删",
          store.get_agent_config(pid, main_id) is not None, "主 Agent 被误删")
    _CFG["delegation_auto_cleanup"] = False  # 复位

    # ══ D-4 并发开关 ══
    # 默认串行：并发 2 个委派 → 锁内区间无交叠
    order = []

    class OrderConn(ScriptConn):
        def __init__(self, name):
            super().__init__(["无效交卷"] * 4, store, pid)
            self.name = name

        async def chat_stream(self, model, messages, tools=None):
            order.append(f"{self.name}_start")
            async for ev in super().chat_stream(model, messages, tools):
                yield ev
            order.append(f"{self.name}_end")

    _CFG["task_concurrency"] = False
    await asyncio.gather(
        run_delegated_task(pid, main_id, parent_sid,
                           {"id": sub_id, "name": "Sub", "model_name": "qwen3.8"},
                           "并发串行A", "标准",
                           sandbox_root=str(sandbox), max_rounds=3, connector=OrderConn("A")),
        run_delegated_task(pid, main_id, parent_sid,
                           {"id": sub_id, "name": "Sub", "model_name": "qwen3.8"},
                           "并发串行B", "标准",
                           sandbox_root=str(sandbox), max_rounds=3, connector=OrderConn("B")),
    )

    def intervals(order, tag):
        starts = [i for i, x in enumerate(order) if x == f"{tag}_start"]
        ends = [i for i, x in enumerate(order) if x == f"{tag}_end"]
        return list(zip(starts, ends))

    ia, ib = intervals(order, "A"), intervals(order, "B")
    no_overlap = bool(ia and ib) and all(
        be[1] < as_[0] or as_[1] < be[0] for as_ in ia for be in ib)
    check("D-4a 串行开关：并发委派区间无交叠",
          len(ia) >= 1 and len(ib) >= 1 and no_overlap, str(order))

    # 并发开：用不阻塞锁（_NOOP_LOCK），区间可交叠
    _CFG["task_concurrency"] = True
    check("D-4b 并发开关开后用不阻塞锁",
          dlg._NOOP_LOCK is not None and type(dlg._NOOP_LOCK).__name__ == "_NoopAsyncLock",
          type(dlg._NOOP_LOCK).__name__)
    _CFG["task_concurrency"] = False  # 复位

    # 清理
    cfgmod.get_config = _orig_get_config
    import shutil
    shutil.rmtree(TMP, ignore_errors=True)
    check("临时目录已清理", not TMP.exists())

    print(f"\n===== checkpoint-068 新机制专项: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("FAILED:", ", ".join(FAILURES))
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
