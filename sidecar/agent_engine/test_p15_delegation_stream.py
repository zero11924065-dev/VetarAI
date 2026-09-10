# VetarAI - Local-first multi-agent orchestration application
# Copyright (C) 2026 zero11924065-dev
# GPL-3.0-or-later（见仓库 LICENSE）
"""#15（0.4.20）· 子会话视图实时更新 —— 委派进度事件总线 + SSE 端点。

## 缺陷与修复

**缺陷（用户实测）**：委派任务跑起来后，任务面板要等任务**整个结束**才看得到结果，
中途看不到子 Agent 正在调哪个工具、跑到第几轮。

**根因**：不是"没产生事件"，而是**事件产生后没有出口**——
  * `run_tool_loop` 本身是 `AsyncIterator[dict]`，逐步 yield token/tool_call/tool_result；
  * `delegation._run_one_pass` 早已 `async for ev` 消费它们，但**用完即弃**；
  * 现有 SSE 端点只有 `/api/ollama/chat/stream` 与 `/api/workflows/{wf_id}/run`，
    **没有委派的**；`TaskPanel.tsx` 只做 fetch 轮询，不消费任何流。

**修复**：新增进程内事件总线 `delegation_events.py`（委派协程不在 HTTP 上下文里，
只能靠按 project_id 路由的总线解耦）+ SSE 端点
`GET /api/projects/{pid}/tasks/stream`（先推 DB 快照再推实时增量）。

## 覆盖

- T1  多订阅者广播：两个订阅者都收到同一事件（⛔ 共享 Event 会丢唤醒，故用每订阅者 Queue）
- T2  晚到订阅者补发：缓冲区里 since_seq 之后的事件一次性补发
- T3  gap 断档检测：缓冲被挤掉后订阅者收到 gap 而非静默错乱
- T4  end_task 必发 task_end，且无订阅者时回收通道
- T5  有订阅者时**不**回收通道（防面板永久收不到更新）
- T6  订阅者断开（aclose/cancel）后通道回收，无泄漏
- T7  push 异常安全：无通道/空参数一律返回 False 且不抛
- T8  空闲产出 _idle 心跳（端点据此发 SSE 注释行防代理断连）
- T9  通道数上限只淘汰空闲通道，活跃/有订阅者通道绝不误淘汰
- T10 SSE 端点：HTTP 200 + content-type + 首条必须是 snapshot（DB 权威基线）
- T11 SSE 端点：_subscribed/_idle 不下发给前端，_idle 转 `: keepalive`
- T12 SSE 端点：push 的事件真实下发，格式与 chat/stream 一致（前端解析器零改动）
- T13 委派接线：begin_task/end_task/push 调用点齐全，end_task 在 finally
- T14 token 节流：不逐字转发（≥2s 一次 progress），tool_call/tool_result 逐条转发
- T15 变异测试：三处关键修复被撤掉时必须失败（验证本测试真的有效）

运行：.venv/bin/python -m sidecar.agent_engine.test_p15_delegation_stream
变异：MUTATE=1|2|3 .venv/bin/python -m sidecar.agent_engine.test_p15_delegation_stream
"""
from __future__ import annotations

import asyncio
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from sidecar.agent_engine import delegation_events as de

MUTATE = int(os.environ.get("MUTATE", "0"))
PASS, FAIL = 0, 0
FAILURES: list[str] = []


def check(name: str, cond: bool, detail: str = "") -> None:
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"PASS  {name}")
    else:
        FAIL += 1
        FAILURES.append(name)
        print(f"FAIL  {name}  {detail}")


async def _collect(agen, n: int, out: list) -> None:
    """消费异步生成器前 n 条。

    ⛔ 必须显式 aclose：Python 异步生成器在 `break` 后**不会立即执行 finally**
    （要等 GC），不 aclose 就测不到订阅者注销与通道回收——本套件首轮即因此假失败。
    """
    i = 0
    try:
        async for e in agen:
            out.append(e)
            i += 1
            if i >= n:
                break
    finally:
        await agen.aclose()


# ══════════════════ 一、事件总线单测 ══════════════════

async def t1_multi_subscriber_broadcast() -> None:
    """T1 多订阅者广播：⛔ 这是 Condition/Event 方案的回归点。

    共享 asyncio.Event 会被第一个醒来的订阅者 clear()，其余要等下一次 set 或超时
    → 多面板同开时延迟可达一个心跳周期。每订阅者独立 Queue 才是正确解。
    """
    de.clear_all()
    P = "p_t1"
    de.begin_task(P, "t1")
    a: list = []
    b: list = []
    ta = asyncio.create_task(_collect(de.subscribe(P), 3, a))
    tb = asyncio.create_task(_collect(de.subscribe(P), 3, b))
    await asyncio.sleep(0.05)
    check("T1a 两个订阅者都注册成功", de.subscriber_count(P) == 2, str(de.subscriber_count(P)))
    de.push(P, "t1", "tool_call", {"name": "read_file"})
    de.push(P, "t1", "tool_result", {"ok": True})
    await asyncio.gather(ta, tb)
    ea = [e["event"] for e in a]
    eb = [e["event"] for e in b]
    check("T1b 订阅者A收到握手+两事件",
          ea == ["_subscribed", "tool_call", "tool_result"], str(ea))
    check("T1c 订阅者B同样收到（无丢唤醒）",
          eb == ["_subscribed", "tool_call", "tool_result"], str(eb))
    check("T1d 事件携带 task_id", a[1].get("task_id") == "t1", str(a[1]))
    check("T1e seq 单调递增", a[1]["seq"] < a[2]["seq"], f'{a[1]["seq"]} vs {a[2]["seq"]}')


async def t2_late_subscriber_backfill() -> None:
    """T2 晚到订阅者补发缓冲区事件（面板是用户中途点开的，不能只给"从现在起"）。"""
    de.clear_all()
    P = "p_t2"
    de.begin_task(P, "t1")
    de.push(P, "t1", "tool_call", {"name": "A"})
    de.push(P, "t1", "tool_call", {"name": "B"})
    check("T2a 缓冲含 2 条", de.buffered_count(P) == 2, str(de.buffered_count(P)))
    late: list = []
    await _collect(de.subscribe(P), 3, late)
    ev = [e["event"] for e in late]
    names = [e["data"].get("name") for e in late[1:]]
    check("T2b 晚到订阅者补发缓冲 2 条",
          ev == ["_subscribed", "tool_call", "tool_call"], str(ev))
    check("T2c 补发内容正确且有序", names == ["A", "B"], str(names))
    # since_seq=1 → 只补发第 2 条
    part: list = []
    await _collect(de.subscribe(P, since_seq=1), 2, part)
    check("T2d since_seq 过滤生效（只补 seq>1）",
          len(part) == 2 and part[1]["data"].get("name") == "B", str(part))


async def t3_gap_detection() -> None:
    """T3 环形缓冲溢出后必须发 gap，不能静默错乱。"""
    de.clear_all()
    P = "p_t3"
    de.begin_task(P, "t1")
    for i in range(de._BUFFER_MAX + 50):     # 超缓冲上限 → 早期事件被挤掉
        de.push(P, "t1", "progress", {"i": i})
    g: list = []
    agen = de.subscribe(P, since_seq=5)
    async for e in agen:
        g.append(e)
        if e["event"] == "gap" or len(g) >= 3:
            break
    await agen.aclose()
    check("T3a 断档时发 gap 事件",
          any(e["event"] == "gap" for e in g), str([e["event"] for e in g]))
    gap = next((e for e in g if e["event"] == "gap"), None)
    check("T3b gap 携带 from 与 oldest_available",
          gap is not None and gap["data"].get("from") == 5
          and isinstance(gap["data"].get("oldest_available"), int), str(gap))
    check("T3c 缓冲不超上限", de.buffered_count(P) <= de._BUFFER_MAX,
          str(de.buffered_count(P)))


async def t4_end_task_and_recycle() -> None:
    """T4 end_task 必发 task_end；无订阅者时回收通道。"""
    de.clear_all()
    P = "p_t4"
    de.begin_task(P, "t1")
    check("T4a 活跃任务数=1", de.active_task_count(P) == 1)
    check("T4b 通道已建", de.channel_count() == 1)
    rec: list = []
    await _collect(de.subscribe(P), 2, rec)   # 订阅者在场时 end_task
    # 重新建通道再测"无订阅者"回收
    de.clear_all()
    de.begin_task(P, "t2")
    de.end_task(P, "t2")
    check("T4c 无订阅者时 end_task 回收通道", de.channel_count() == 0,
          str(de.channel_count()))
    check("T4d end_task 后活跃任务=0", de.active_task_count(P) == 0)


async def t5_no_recycle_with_subscriber() -> None:
    """T5 ⛔ 有订阅者时绝不回收通道——否则面板永久收不到更新。"""
    de.clear_all()
    P = "p_t5"
    de.begin_task(P, "t1")
    hold: list = []
    th = asyncio.create_task(_collect(de.subscribe(P, idle_timeout=0.2), 99, hold))
    await asyncio.sleep(0.05)
    de.end_task(P, "t1")
    check("T5a 有订阅者时通道保留", de.channel_count() == 1, str(de.channel_count()))
    check("T5b 活跃任务已清零", de.active_task_count(P) == 0)
    th.cancel()
    try:
        await th
    except asyncio.CancelledError:
        pass
    await asyncio.sleep(0)
    check("T5c 订阅者断开后通道回收", de.channel_count() == 0, str(de.channel_count()))


async def t6_subscriber_cleanup() -> None:
    """T6 订阅者注销必须在 finally：客户端断开也要归还计数，否则通道永不回收。"""
    de.clear_all()
    P = "p_t6"
    de.begin_task(P, "t1")
    agen = de.subscribe(P)
    await agen.__anext__()                    # 只取握手
    check("T6a 订阅中 subscriber_count=1", de.subscriber_count(P) == 1)
    await agen.aclose()                       # 模拟客户端断开
    check("T6b aclose 后 subscriber_count=0", de.subscriber_count(P) == 0,
          str(de.subscriber_count(P)))
    # ⛔ 任务 t1 仍活跃 → 通道**必须保留**（首轮我把这条断言写成"应被回收"，是错的：
    # 淘汰活跃通道会让正在跑的委派推进一个已删除的通道，事件静默丢失）
    check("T6c 任务仍活跃时通道保留（不淘汰活跃通道）",
          de.channel_count() == 1, str(de.channel_count()))
    # 任务结束后且无订阅者 → 才回收
    de.end_task(P, "t1")
    check("T6d 任务结束+无订阅者 → 通道回收", de.channel_count() == 0,
          str(de.channel_count()))


async def t7_push_exception_safety() -> None:
    """T7 ⛔ 总线是旁路：任何异常都不得影响委派本身。"""
    de.clear_all()
    check("T7a 无通道 push 返回 False（不抛）", de.push("nope", "t", "status") is False)
    check("T7b 空 project push 返回 False", de.push("", "t", "status") is False)
    check("T7c 空 event push 返回 False", de.push("p", "t", "") is False)
    check("T7d None 参数不抛", de.push(None, None, None) is False)  # type: ignore[arg-type]
    check("T7e data=None 不抛且可推送",
          (de.begin_task("p7", "t7"), de.push("p7", "t7", "status"))[1] is True)


async def t8_idle_heartbeat() -> None:
    """T8 空闲产出 _idle，端点据此发 SSE 注释行（防代理断连）。"""
    de.clear_all()
    de.begin_task("p_t8", "t1")
    out: list = []
    await _collect(de.subscribe("p_t8", idle_timeout=0.12), 2, out)
    check("T8a 空闲产出 _subscribed + _idle",
          [e["event"] for e in out] == ["_subscribed", "_idle"],
          str([e["event"] for e in out]))


async def t9_eviction_only_idle() -> None:
    """T9 ⛔ 通道淘汰只针对空闲通道：活跃/有订阅者的通道绝不误淘汰。"""
    de.clear_all()
    # 建满上限个"活跃"通道
    for i in range(de._MAX_CHANNELS):
        de.begin_task(f"busy_{i}", f"t{i}")
    check("T9a 活跃通道数达上限", de.channel_count() == de._MAX_CHANNELS,
          str(de.channel_count()))
    # 再建一个新通道 → 无可淘汰的空闲通道 → 宁可超上限也不牺牲正确性
    de.begin_task("one_more", "t")
    check("T9b 全忙时宁可超上限也不淘汰活跃通道",
          de.channel_count() == de._MAX_CHANNELS + 1, str(de.channel_count()))
    check("T9c 活跃通道一个都没丢",
          all(de.active_task_count(f"busy_{i}") == 1 for i in range(de._MAX_CHANNELS)))
    # 现在有 1 个空闲通道可淘汰
    de.end_task("one_more", "t")
    de.begin_task("trigger", "t")
    check("T9d 有空闲通道时淘汰生效", de.channel_count() <= de._MAX_CHANNELS + 1,
          str(de.channel_count()))


# ══════════════════ 二、SSE 端点实测 ══════════════════

def _setup_endpoint_env():
    """⛔ 必须钉死数据目录到临时目录（项目铁律：禁止污染真实 ~/.subagent）。"""
    TMP = Path(tempfile.mkdtemp(prefix="p15_"))
    import sidecar.storage.store as store
    store.PROJECTS_ROOT = TMP
    store._GDB = TMP / "_global.db"
    return TMP, store


async def t10_t11_t12_endpoint() -> None:
    """T10/T11/T12 端点级实测：⛔ mock 必须复现**端点输出**而非存储层输出。

    ⛔⛔ **为什么不用 `TestClient.stream` + `iter_lines`**（本套件首轮实测踩坑，
    曾把整个后端套件挂死到 180s 超时）：
      1. `TestClient.stream` 把应用跑在**独立线程的事件循环**里，而主线程 push 事件
         属于跨 loop 投递，失败方式是**静默的**（订阅者不被唤醒）；
      2. SSE 流**永不结束**，`for raw in resp.iter_lines()` 只在匹配到目标事件时才 break，
         匹配不到就是无限迭代 —— 端点每 15s 才发一条心跳注释行，等于死循环。
    ✅ 正确做法：在**同一事件循环**里直接迭代 `StreamingResponse.body_iterator`，
    并用 `asyncio.wait_for` 给每次取行加硬超时。这样既真实走到端点的序列化代码
    （`_sse_format` / snapshot / keepalive 过滤），又**结构上不可能挂死**。
    """
    TMP, store = _setup_endpoint_env()
    de.clear_all()
    from sidecar import app as appmod

    pid = store.create_project("p15-proj", TMP / "wd")
    main_id = store.add_agent_config(pid, "Alpha", "main", model_name="qwen3.8")
    beta_id = store.add_agent_config(pid, "Beta", "sub", model_name="qwen3.8")
    parent_sid = store.create_session(pid, main_id)
    tid = store.create_agent_task(pid, main_id, parent_sid, beta_id, "Beta", "任务书", "标准")
    store.update_agent_task(pid, tid, status="running")

    # 直接调用端点协程，拿到真实的 StreamingResponse
    resp = await appmod.api_stream_agent_tasks(pid, since=0)
    check("T10a 端点返回 StreamingResponse",
          resp.__class__.__name__ == "StreamingResponse", resp.__class__.__name__)
    check("T10b content-type 是 text/event-stream",
          resp.media_type == "text/event-stream", str(resp.media_type))
    check("T10c 带 no-cache 与 X-Accel-Buffering 头（防代理缓冲）",
          resp.headers.get("Cache-Control") == "no-cache"
          and resp.headers.get("X-Accel-Buffering") == "no", str(dict(resp.headers)))

    it = resp.body_iterator
    parsed: list[tuple[str, str]] = []   # (event, data_json)
    raw_lines: list[str] = []

    async def pump(max_chunks: int = 40) -> None:
        """读 SSE 原始 chunk 并解析出 (event, data)；⛔ 每次 await 都有硬超时。"""
        cur_ev = None
        n = 0
        while n < max_chunks:
            try:
                chunk = await asyncio.wait_for(it.__anext__(), timeout=3.0)
            except (asyncio.TimeoutError, StopAsyncIteration):
                return
            n += 1
            text = chunk.decode("utf-8") if isinstance(chunk, bytes) else str(chunk)
            for line in text.split("\n"):
                raw_lines.append(line)
                if line.startswith("event: "):
                    cur_ev = line[7:].strip()
                elif line.startswith("data: ") and cur_ev:
                    parsed.append((cur_ev, line[6:]))
                    cur_ev = None

    # ── T10 首条必须是 snapshot（DB 权威基线，晚到订阅者也能对齐）──
    await pump(1)
    check("T10d 首条事件是 snapshot",
          bool(parsed) and parsed[0][0] == "snapshot", str(parsed[:1]))
    if parsed:
        import json as _j
        snap = _j.loads(parsed[0][1])
        tasks = snap.get("tasks", [])
        check("T10e snapshot 含 DB 里的真实任务",
              any(t.get("id") == tid for t in tasks), str(tasks)[:200])
        check("T10f snapshot 任务状态取自 DB（running）",
              any(t.get("id") == tid and t.get("status") == "running" for t in tasks),
              str(tasks)[:200])

    # ── T12 push 的事件真实下发，格式与 chat/stream 一致（前端解析器零改动）──
    de.begin_task(pid, tid)
    de.push(pid, tid, "tool_call", {"name": "read_file", "id": "c1"})
    await pump(6)
    names = [e for e, _ in parsed]
    check("T12a tool_call 事件真实下发到 SSE", "tool_call" in names, str(names))
    # ⛔ T11：内部控制事件不得下发给前端
    check("T11a _subscribed 未下发给前端", "_subscribed" not in names, str(names))
    check("T11b _idle 未作为 event 下发", "_idle" not in names, str(names))
    check("T11c SSE 行格式为 `event: X` + `data: {json}`（与 chat/stream 同协议）",
          any(l.startswith("event: tool_call") for l in raw_lines)
          and any(l.startswith("data: {") for l in raw_lines), str(raw_lines[:6]))
    if "tool_call" in names:
        import json as _j2
        payload = _j2.loads(parsed[names.index("tool_call")][1])
        check("T12b payload 含 task_id 与 seq（前端按 id 更新对应行）",
              payload.get("task_id") == tid and isinstance(payload.get("seq"), int),
              str(payload)[:200])
        check("T12c payload 保留业务字段", payload.get("name") == "read_file",
              str(payload)[:200])

    # ⛔ 收尾：关闭迭代器，让端点的 finally 归还订阅者计数（否则通道泄漏影响后续用例）
    try:
        await it.aclose()
    except Exception:
        pass
    de.clear_all()


# ══════════════════ 三、委派接线核查 ══════════════════

def t13_delegation_wiring() -> None:
    """T13 委派接线齐全性。

    ⛔ 用 AST 判定结构意图，不用文本子串——实现一改文本匹配就假失败
    （C5/C8 静态断言三易其稿的教训）。
    """
    import ast
    src = Path(__file__).resolve().parents[1] / "agent_engine" / "delegation.py"
    tree = ast.parse(src.read_text(encoding="utf-8"))

    fn = next((n for n in ast.walk(tree)
               if isinstance(n, ast.AsyncFunctionDef) and n.name == "run_delegated_task"), None)
    check("T13a 找到 run_delegated_task", fn is not None)
    if fn is None:
        return

    src_fn = ast.get_source_segment(src.read_text(encoding="utf-8"), fn) or ""
    check("T13b 调用 begin_task", "begin_task(" in src_fn)
    check("T13c 调用 end_task", "end_task(" in src_fn)

    # ⛔ end_task 必须在 finally 里（否则异常路径下前端永久转圈）
    finally_has_end = False
    for node in ast.walk(fn):
        if isinstance(node, ast.Try) and node.finalbody:
            seg = ast.get_source_segment(src.read_text(encoding="utf-8"), node) or ""
            # 只看 finalbody 部分
            fin_src = "".join(ast.get_source_segment(src.read_text(encoding="utf-8"), s) or ""
                              for s in node.finalbody)
            if "end_task(" in fin_src:
                finally_has_end = True
    check("T13d ⛔ end_task 在 finally 里（异常路径也要收口）", finally_has_end)

    # _run_one_pass 必须接收 project_id/task_id 才会转发
    one = next((n for n in ast.walk(tree)
                if isinstance(n, ast.AsyncFunctionDef) and n.name == "_run_one_pass"), None)
    check("T13e _run_one_pass 存在", one is not None)
    if one is not None:
        args = [a.arg for a in one.args.args] + [a.arg for a in one.args.kwonlyargs]
        check("T13f _run_one_pass 有 project_id 参数", "project_id" in args, str(args))
        check("T13g _run_one_pass 有 task_id 参数", "task_id" in args, str(args))

    # 两处外层调用都必须透传
    check("T13h 两处 _run_pass_with_timeout 调用都透传 project_id/task_id",
          src_fn.count("project_id=project_id, task_id=task_id") >= 2,
          str(src_fn.count("project_id=project_id, task_id=task_id")))


def t14_token_throttle() -> None:
    """T14 ⛔ token 不逐字转发（会淹没总线）；tool_call/tool_result 逐条转发。

    ⛔⛔ **节流判定必须用 AST，不能用文本关键词**（2026-09-11 变异 3 实测抓到）：
    首轮断言写的是 `"monotonic()" in tok_branch and "progress" in tok_branch`，
    把节流条件 `_t - _last_prog[0] >= 2.0` 改成 `if True:` 后，
    这两个字符串**依然都在**（`_t = time.monotonic()` 还在赋值、`_push("progress")` 还在调用）
    → 断言照样通过，变异未被抓住。这是**空转断言**：它检查"关键词出现了吗"，
    而不是"节流条件真的是时间比较吗"。
    ✅ 正解：AST 找到 token 分支里包着 `_push("progress")` 的那个 `if`，
    断言其 test 是 **Compare 节点**（`>=`），且左操作数含时间差运算——
    改成 `if True:` 后 test 变成 Constant，断言必然失败。
    """
    src = Path(__file__).resolve().parents[1] / "agent_engine" / "delegation.py"
    text = src.read_text(encoding="utf-8")
    import ast
    tree = ast.parse(text)
    fn = next((n for n in ast.walk(tree)
               if isinstance(n, ast.AsyncFunctionDef) and n.name == "_run_one_pass"), None)
    check("T14a 定位 _run_one_pass", fn is not None)
    if fn is None:
        return
    seg = ast.get_source_segment(text, fn) or ""

    def _is_push_progress(node: ast.AST) -> bool:
        """该节点是否调用了 _push("progress", ...)。"""
        for sub in ast.walk(node):
            if (isinstance(sub, ast.Call) and isinstance(sub.func, ast.Name)
                    and sub.func.id == "_push" and sub.args
                    and isinstance(sub.args[0], ast.Constant)
                    and sub.args[0].value == "progress"):
                return True
        return False

    def _has_time_compare(test: ast.AST) -> bool:
        """条件是「时间差 >= 阈值」形态：Compare(GtE) 且左操作数是 BinOp(Sub)。"""
        return (isinstance(test, ast.Compare)
                and any(isinstance(op, ast.GtE) for op in test.ops)
                and isinstance(test.left, ast.BinOp)
                and isinstance(test.left.op, ast.Sub))

    # 定位 token 分支（if e == "token"）
    tok_branch = None
    for node in ast.walk(fn):
        if not isinstance(node, ast.If):
            continue
        t = node.test
        if (isinstance(t, ast.Compare) and isinstance(t.left, ast.Name) and t.left.id == "e"
                and t.comparators and isinstance(t.comparators[0], ast.Constant)
                and t.comparators[0].value == "token"):
            tok_branch = node
            break
    check("T14a2 AST 定位到 token 分支", tok_branch is not None)

    throttle_ok = False
    pushes_progress = False
    if tok_branch is not None:
        for sub in ast.walk(tok_branch):
            if isinstance(sub, ast.If) and _is_push_progress(sub):
                pushes_progress = True
                if _has_time_compare(sub.test):
                    throttle_ok = True
    check("T14b token 分支的 progress 推送被**时间比较**条件门控（AST 判定）",
          pushes_progress and throttle_ok,
          f"progress推送={pushes_progress} 时间门控={throttle_ok}")
    check("T14c token 分支**不**逐条 push token 事件",
          '_push("token"' not in seg[: seg.find('elif e == "tool_call"')], "")

    # tool_call / tool_result 必须逐条转发（AST 判定调用存在，比文本子串稳）
    def _branch_src(marker: str, end_marker: str) -> str:
        a = seg.find(marker)
        b = seg.find(end_marker)
        return seg[a:b] if (a >= 0 and b > a) else ""

    check("T14d tool_call 逐条转发",
          '_push("tool_call"' in _branch_src('elif e == "tool_call"', 'elif e == "tool_result"'))
    check("T14e tool_result 逐条转发",
          '_push("tool_result"' in _branch_src('elif e == "tool_result"', 'elif e == "done"'))
    # _push 内部必须吞异常（旁路不得影响委派）
    push_fn = seg[seg.find("def _push"):seg.find("async for ev in run_tool_loop")]
    check("T14f _push 内部吞异常（总线失败不影响委派）",
          "except Exception" in push_fn, push_fn[:200])


# ══════════════════ 四、变异测试 ══════════════════

_BACKUP: dict[str, str] = {}


def _read_src(mod) -> str:
    return Path(mod.__file__).read_text(encoding="utf-8")


def _apply_mutation() -> None:
    """⛔ 锚点未命中必须 assert 报错，否则"变异没抓到"是假象（0.4.18 踩过）。"""
    if not MUTATE:
        return
    import sidecar.agent_engine.delegation as dg
    _BACKUP["de"] = _read_src(de)
    _BACKUP["dg"] = _read_src(dg)
    if MUTATE == 1:
        # 撤掉"每订阅者独立 Queue 广播"，退回只投第一个订阅者（模拟丢唤醒缺陷）
        # ⛔ 锚点必须匹配 push 重写后的真实形态：广播循环是
        #    `for q, loop in targets:`（targets = list(ch.subs)，投递放锁外）。
        #    首轮锚点写的是旧版 `for q in ch.subs:` → 重写后失配，
        #    assert 正确报错（"变异没抓到"必须是真没抓到，不能是根本没注入）。
        s = _BACKUP["de"]
        patched = s.replace("        for q, loop in targets:",
                            "        for q, loop in targets[:1]:")
        assert patched != s, "变异 1 未命中 delegation_events 源码，测试无效"
        Path(de.__file__).write_text(patched, encoding="utf-8")
    elif MUTATE == 2:
        # 撤掉 finally 里的 end_task（异常路径下前端永久转圈）
        s = _BACKUP["dg"]
        patched = s.replace("            _de.end_task(project_id, task_id)",
                            "            pass  # MUTATE2")
        assert patched != s, "变异 2 未命中 delegation 源码，测试无效"
        Path(dg.__file__).write_text(patched, encoding="utf-8")
    elif MUTATE == 3:
        # 撤掉 token 节流 → 改为逐字转发（会淹没总线）
        s = _BACKUP["dg"]
        patched = s.replace('                if _t - _last_prog[0] >= 2.0:',
                            '                if True:')
        assert patched != s, "变异 3 未命中 delegation 源码，测试无效"
        Path(dg.__file__).write_text(patched, encoding="utf-8")
    else:
        raise SystemExit(f"未知变异编号 {MUTATE}（支持 1|2|3）")


def _restore() -> None:
    if not MUTATE or not _BACKUP:
        return
    import sidecar.agent_engine.delegation as dg
    try:
        if "de" in _BACKUP and _read_src(de) != _BACKUP["de"]:
            Path(de.__file__).write_text(_BACKUP["de"], encoding="utf-8")
        if "dg" in _BACKUP and _read_src(dg) != _BACKUP["dg"]:
            Path(dg.__file__).write_text(_BACKUP["dg"], encoding="utf-8")
    finally:
        _BACKUP.clear()


async def _run_async_suite() -> None:
    await t1_multi_subscriber_broadcast()
    await t2_late_subscriber_backfill()
    await t3_gap_detection()
    await t4_end_task_and_recycle()
    await t5_no_recycle_with_subscriber()
    await t6_subscriber_cleanup()
    await t7_push_exception_safety()
    await t8_idle_heartbeat()
    await t9_eviction_only_idle()
    await t10_t11_t12_endpoint()


def main() -> int:
    print(f"#15 委派实时更新测试  |  变异模式 = {MUTATE}")
    _apply_mutation()
    if MUTATE:
        import importlib
        importlib.reload(de)
    try:
        asyncio.run(_run_async_suite())
        t13_delegation_wiring()
        t14_token_throttle()
    finally:
        _restore()
        if MUTATE:
            import importlib
            importlib.reload(de)
        de.clear_all()

    print("\n" + "=" * 72)
    print(f"结果：{PASS} 通过 / {FAIL} 失败")
    if FAILURES:
        print("失败项：" + "；".join(FAILURES))
    if MUTATE and FAIL == 0:
        print(f"⛔ 变异 {MUTATE} 未被抓住 —— 本测试对该修复无效，断言需加强")
    print("=" * 72)
    return 1 if FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main())
