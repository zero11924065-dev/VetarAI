"""TS-107 M3-1 主-子委派地基单测（mock connector，venv 内 python test_delegation.py 直接跑）。
覆盖：交卷契约解析 / 目标解析 / 委派执行（成功/追问/两次失败/执行抛错）/
上下文隔离 / 串行锁 / agent_tasks 存储层。只输出 PASS/FAIL 摘要。
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
    """按脚本返回文本的假 connector。每个脚本项是 str 或 callable(task_id)->str。
    task_id 取自 DB 最新一条任务（委派执行器在跑 loop 前已落库）。"""

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


class OrderConn(ScriptConn):
    """记录进入/离开区间（验证串行锁），固定输出无效交卷。"""

    def __init__(self, name, order, store_mod, project_id):
        super().__init__((["无效交卷"] * 4), store_mod, project_id)
        self.name = name
        self.order = order

    async def chat_stream(self, model, messages, tools=None):
        self.order.append(f"{self.name}_start")
        async for ev in super().chat_stream(model, messages, tools):
            yield ev
        self.order.append(f"{self.name}_end")


class RaisingConn:
    """首个 chunk 后抛错（模拟模型推理崩溃）。"""

    async def chat_stream(self, model, messages, tools=None):
        yield {"content_delta": "部分输出"}
        raise RuntimeError("模型推理崩溃(模拟)")


async def main():
    # 隔离数据目录（不碰 ~/.subagent）
    TMP = Path(tempfile.mkdtemp(prefix="m31deleg_"))
    import sidecar.storage.store as store
    store.PROJECTS_ROOT = TMP
    store._GDB = TMP / "_global.db"
    from sidecar.agent_engine.delegation import (
        parse_report, resolve_target, run_delegated_task,
    )
    from sidecar.agent_engine.loop import tools_spec

    sandbox = TMP / "work"
    sandbox.mkdir()

    pid = store.create_project("m31", TMP / "wd")
    main_id = store.add_agent_config(pid, "Alpha", "main", model_name="qwen3.8")
    beta_id = store.add_agent_config(pid, "Beta", "sub", model_name="qwen3.8",
                                     role="写手", system_prompt="简洁")
    bw_id = store.add_agent_config(pid, "Beta Writer", "sub", model_name="qwen3.8")
    store.add_agent_config(pid, "Gamma", "sub", model_name="qwen3.8")

    # ══ A. parse_report 交卷契约（任务单用例 1-5）══
    tid = "task-xyz"
    ok_json = json.dumps({"task_id": tid, "status": "success",
                          "summary": "完成了", "artifacts": ["a.md"]}, ensure_ascii=False)
    r = parse_report(ok_json, tid)
    check("A1 纯 JSON 合法", r is not None and r["status"] == "success"
          and r["summary"] == "完成了" and r["artifacts"] == ["a.md"], str(r))

    check("A2 ```json 围栏包裹合法", parse_report("```json\n" + ok_json + "\n```", tid) is not None)
    check("A2b JSON 前后混文字可解析", parse_report("好的，交卷：" + ok_json + "（完）", tid) is not None)

    # H17：宽容归一化——小错修正接收而非判不合格
    # M7（TS-113）：契约扩容 300→1000。≤1000 字全文接收不截断；
    # >1000 字也不在 parse_report 截断（保留全文，由 _finalize_summary 落盘+截断回传）
    r3 = parse_report(json.dumps({"task_id": tid, "status": "success",
                                  "summary": "字" * 301, "artifacts": []}, ensure_ascii=False), tid)
    check("A3 summary 301 字（≤1000）→ 全文接收不截断（无修正标记）",
          r3 is not None and len(r3["summary"]) == 301 and r3.get("format_corrected") is not True, str(r3)[:80] if r3 else "None")
    r3b = parse_report(json.dumps({"task_id": tid, "status": "success",
                                   "summary": "字" * 1001, "artifacts": []}, ensure_ascii=False), tid)
    check("A3b summary 1001 字（>1000）→ 保留全文并标记修正（截断在落盘环节）",
          r3b is not None and len(r3b["summary"]) == 1001 and r3b.get("format_corrected") is True, str(r3b)[:80] if r3b else "None")
    r4a = parse_report(ok_json, "other-id")
    check("A4a task_id 不一致 → 修正为实际 id（标记修正）",
          r4a is not None and r4a["task_id"] == "other-id" and r4a.get("format_corrected") is True, str(r4a)[:150] if r4a else "None")
    r4b = parse_report(json.dumps({"task_id": tid, "status": "finished",
                                   "summary": "x", "artifacts": []}), tid)
    check("A4b status 非法 → 归一 partial（标记修正）",
          r4b is not None and r4b["status"] == "partial" and r4b.get("format_corrected") is True, str(r4b)[:150] if r4b else "None")
    check("A4c 非 JSON 判不合法（走兜底打包路径）", parse_report("我完成了任务，没有 JSON", tid) is None)
    check("A4d 缺 summary 字段判不合法",
          parse_report(json.dumps({"task_id": tid, "status": "success"}), tid) is None)

    r5 = parse_report(json.dumps({"task_id": tid, "status": "partial", "summary": "部分完成"}), tid)
    check("A5 artifacts 缺失补 [] 后合法（无修正标记）",
          r5 is not None and r5["artifacts"] == [] and r5.get("format_corrected") is not True, str(r5))

    # H17：兜底打包（弱模型无 JSON 交卷但确有实质回复）
    from sidecar.agent_engine.delegation import build_fallback_report
    fb = build_fallback_report("重庆 2026 年养老最低基数 4359 元/月，数据来源市人社局公告。", tid)
    check("A6 兜底打包：实质回复 → partial 交卷 + 标注",
          fb is not None and fb["status"] == "partial" and fb.get("fallback") is True
          and "未按契约交卷" in fb["summary"] and "4359" in fb["summary"], str(fb)[:200] if fb else "None")
    check("A6b 兜底打包：空/过短回复 → None",
          build_fallback_report("", tid) is None and build_fallback_report("   ", tid) is None
          and build_fallback_report("短", tid) is None)

    # ══ B. resolve_target 目标解析（用例 10-12）══
    a, err = resolve_target(pid, "Beta", main_id)
    check("B10a 精确匹配 name", a is not None and a["id"] == beta_id and err == "", f"{a} {err}")
    a, err = resolve_target(pid, beta_id, main_id)
    check("B10b 精确匹配 id", a is not None and a["id"] == beta_id)
    a, err = resolve_target(pid, "  bEtA  ", main_id)
    check("B10c 忽略大小写+首尾空白", a is not None and a["id"] == beta_id)

    a, err = resolve_target(pid, "Writer", main_id)
    check("B11a 模糊子串命中", a is not None and a["id"] == bw_id, f"{a} {err}")
    a, err = resolve_target(pid, "e", main_id)
    check("B11b 多命中取 name 最短", a is not None and a["id"] == beta_id, f"{a} {err}")

    a, err = resolve_target(pid, "Omega", main_id)
    check("B12a 未命中返回错误+可用名单",
          a is None and "未找到" in err and "Beta" in err and "Gamma" in err, err)
    check("B12b 名单排除发起者自己", a is None and "Alpha" not in err, err)
    a, err = resolve_target(pid, "   ", main_id)
    check("B12c 空目标提示补全参数", a is None and "参数" in err, err)

    # ══ C. tools_spec 防递归（用例 13）══
    names_main = [s["function"]["name"] for s in tools_spec(with_delegation=True)]
    names_sub = [s["function"]["name"] for s in tools_spec(with_delegation=False)]
    check("C13a 主会话 spec 含 delegate_task", "delegate_task" in names_main, str(names_main))
    check("C13b 子会话 spec 剔除 delegate_task", "delegate_task" not in names_sub, str(names_sub))

    # ══ D. 委派执行器 ══
    parent_sid = store.create_session(pid, main_id, title="主会话")
    store.save_message(pid, parent_sid, main_id, "user", "MAIN_CONV_MARKER 主对话私密内容")
    beta = store.get_agent_config(pid, beta_id)

    def good_report(t):
        return json.dumps({"task_id": t, "status": "success",
                           "summary": "子任务完成", "artifacts": ["out.md"]}, ensure_ascii=False)

    # D6 首次不合法 → 追问 → 第二次合法（用例 6+9）
    bad_report = "我做完了，但没有按格式交卷。"
    res6 = await run_delegated_task(pid, main_id, parent_sid, beta,
                                    "写一首诗", "交一首五言绝句",
                                    sandbox_root=str(sandbox), max_rounds=5,
                                    connector=ScriptConn([bad_report, good_report], store, pid))
    check("D6a 追问后合法 → ok=True + 契约字段齐全",
          res6.get("ok") is True and res6.get("status") == "success"
          and res6.get("summary") == "子任务完成" and res6.get("artifacts") == ["out.md"],
          str(res6)[:200])
    task6 = store.get_agent_task(pid, res6["task_id"])
    check("D6b 任务落库 status=done + report 可解析",
          task6 is not None and task6["status"] == "done"
          and task6["report"].get("summary") == "子任务完成",
          str(task6)[:200] if task6 else "None")
    child_msgs = store.load_messages(pid, task6["session_id"])
    check("D6c 追问留痕：子会话 user×2 assistant×2",
          len(child_msgs) == 4 and [m["role"] for m in child_msgs] == ["user", "assistant", "user", "assistant"],
          str([(m["role"], (m["content"] or "")[:20]) for m in child_msgs]))
    check("D6d 追问文案含格式要求", "重新交卷" in child_msgs[2]["content"],
          child_msgs[2]["content"][:80])
    check("D9a 上下文隔离：子会话不含主对话内容",
          all("MAIN_CONV_MARKER" not in (m["content"] or "") for m in child_msgs))
    check("D9b 首条 user 为任务书（含任务ID与交卷标准）",
          "【委派任务】" in child_msgs[0]["content"] and res6["task_id"] in child_msgs[0]["content"]
          and "交一首五言绝句" in child_msgs[0]["content"], child_msgs[0]["content"][:120])
    sysm = [m for m in child_msgs if m["role"] == "system"]
    check("D9c 子会话无 system 消息落库（prompt 只在内存）", len(sysm) == 0)

    # D7 两次均不合法 → failed（用例 7）
    expect7 = "交付一份市场分析报告"
    res7 = await run_delegated_task(pid, main_id, parent_sid, beta,
                                    "做市场分析", expect7,
                                    sandbox_root=str(sandbox), max_rounds=5,
                                    connector=ScriptConn(["没按格式", "还是没按格式"], store, pid))
    check("D7a 两次不合法 → ok=False", res7.get("ok") is False, str(res7)[:200])
    check("D7b error 含子 Agent 名与缺失说明",
          "Beta" in res7["error"] and "两次交卷均未通过" in res7["error"] and expect7 in res7["error"],
          res7.get("error", ""))
    task7 = store.get_agent_task(pid, res7["task_id"])
    check("D7c DB failed + validation_failures=2 + fail_reason",
          task7["status"] == "failed" and task7["validation_failures"] == 2
          and "校验" in (task7["fail_reason"] or ""), str(task7)[:200])

    # D8 执行抛错 → 不穿透（用例 8）
    res8 = await run_delegated_task(pid, main_id, parent_sid, beta,
                                    "任意任务", "任意标准",
                                    sandbox_root=str(sandbox), max_rounds=5, connector=RaisingConn())
    check("D8a 执行抛错 → ok=False 不穿透",
          res8.get("ok") is False and "执行出错" in res8["error"], str(res8)[:200])
    task8 = store.get_agent_task(pid, res8["task_id"])
    check("D8b DB failed + fail_reason 非空",
          task8["status"] == "failed" and task8["fail_reason"], str(task8)[:150])

    # D13c 取消路径（验收标准 8：用户停止主会话 → 中断标记 + 锁正常释放，无泄漏）
    class HangingConn:
        async def chat_stream(self, model, messages, tools=None):
            yield {"content_delta": "部分"}
            await asyncio.Event().wait()  # 挂起模拟长时间推理

    n_before = len(store.list_agent_tasks(pid, limit=200))
    cancelled = False
    try:
        await asyncio.wait_for(
            run_delegated_task(pid, main_id, parent_sid, beta, "长任务", "标准",
                               sandbox_root=str(sandbox), max_rounds=5, connector=HangingConn()),
            timeout=0.5)
    except asyncio.TimeoutError:
        cancelled = True
    check("D13c 取消生效（wait_for 超时，执行被中断）", cancelled)
    new_tasks = store.list_agent_tasks(pid, limit=200)
    check("D13c 取消后 DB 恰新增 1 条任务", len(new_tasks) == n_before + 1,
          f"{n_before}→{len(new_tasks)}")
    t_new = new_tasks[0]
    check("D13c 任务标 failed + fail_reason 含中断",
          t_new["status"] == "failed" and "中断" in (t_new["fail_reason"] or ""),
          str(t_new)[:150])

    # D14 串行锁：并发 2 个委派 → 锁内区间无交叠（用例 14）
    order: list = []
    results = await asyncio.gather(
        run_delegated_task(pid, main_id, parent_sid, beta, "并发A", "标准",
                           sandbox_root=str(sandbox), max_rounds=5,
                           connector=OrderConn("A", order, store, pid)),
        run_delegated_task(pid, main_id, parent_sid, beta, "并发B", "标准",
                           sandbox_root=str(sandbox), max_rounds=5,
                           connector=OrderConn("B", order, store, pid)),
    )

    def _intervals(seq, name):
        starts = [i for i, x in enumerate(seq) if x == f"{name}_start"]
        ends = [i for i, x in enumerate(seq) if x == f"{name}_end"]
        return list(zip(starts, ends))

    ia, ib = _intervals(order, "A"), _intervals(order, "B")
    no_overlap = bool(ia and ib) and all(
        be[1] < as_[0] or as_[1] < be[0] for as_ in ia for be in ib)
    check("D14 并发委派串行执行（锁内区间无交叠）",
          len(ia) == 2 and len(ib) == 2 and no_overlap, str(order))
    check("D14b 两个并发委派都正常落结果（两次不合法→failed）",
          all(r.get("ok") is False and "两次交卷均未通过" in r.get("error", "") for r in results),
          str(results)[:200])

    # ══ E. agent_tasks 存储层（用例 15）══
    tid_e1 = store.create_agent_task(pid, main_id, parent_sid, beta_id, "Beta", "任务1", "标准1")
    tid_e2 = store.create_agent_task(pid, main_id, parent_sid, "gid", "Gamma", "任务2", "标准2")
    got = store.get_agent_task(pid, tid_e1)
    check("E15a create/get 字段完整",
          got is not None and got["target_agent_name"] == "Beta" and got["task"] == "任务1"
          and got["expect"] == "标准1" and got["status"] == "queued"  # TS-108：落库初始态改排队
          and got["validation_failures"] == 0, str(got)[:200] if got else "None")
    upd = store.update_agent_task(pid, tid_e1, status="done",
                                  report=json.dumps({"task_id": tid_e1, "status": "success",
                                                     "summary": "s", "artifacts": []}))
    got2 = store.get_agent_task(pid, tid_e1)
    check("E15b update 白名单字段生效 + report 反序列化",
          upd is True and got2["status"] == "done" and got2["report"]["summary"] == "s",
          str(got2)[:150])
    check("E15c 非白名单字段被拒",
          store.update_agent_task(pid, tid_e1, hack_field="x'; DROP TABLE agent_tasks;--") is False)
    lst = store.list_agent_tasks(pid)
    ids = [t["id"] for t in lst]
    check("E15d list 倒序（最新在前）", len(lst) >= 2 and ids[0] == tid_e2 and tid_e1 in ids,
          str(ids)[:150])
    check("E15e list limit 生效", len(store.list_agent_tasks(pid, limit=1)) == 1)

    import shutil
    shutil.rmtree(TMP, ignore_errors=True)
    check("测试临时目录已清理", not TMP.exists())

    print(f"\n===== M3-1 委派地基专项: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("FAILED:", ", ".join(FAILURES))
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
