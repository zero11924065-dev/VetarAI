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
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with VetarAI. If not, see <https://www.gnu.org/licenses/>.
"""0.4.20 #15：委派任务实时进度的「进程内事件总线」。

═══ 为什么需要这个模块 ═══

用户实测缺陷（0.4.19 清单 #15）：**子会话视图无实时更新**——委派任务跑起来后，
任务面板要等任务整个结束才看得到结果，中途看不到子 Agent 正在调哪个工具、跑到第几轮。

根因不是"没产生事件"，而是**事件产生后没有出口**：
  * `run_tool_loop` 本身就是 `AsyncIterator[dict]`，逐步 yield `token`/`tool_call`/`tool_result`；
  * `delegation._run_pass_with_timeout` 早已 `async for ev in run_tool_loop(...)` 消费它们；
  * 但消费完只累积进局部变量 `full_text` / `steps`，**用完即弃**，前端无从得知。
  * 现有 SSE 端点只有两个（`/api/ollama/chat/stream`、`/api/workflows/{wf_id}/run`），
    **没有委派的**；`TaskPanel.tsx` 也不消费任何流，只做 `fetch` 轮询。

═══ 为什么必须用进程内总线（不能直接 yield 给端点）═══

委派协程是被**主 Agent 的工具调用栈** `await` 的普通协程，**不在任何 HTTP 请求上下文里**。
而任务面板是另一条独立的 HTTP 连接。两者没有调用关系，只能靠一个按 key 路由的
进程内交接点解耦——与 `inject.py`（A5 待注入队列）、`cancel.py`（C2 取消标志）同一范式。

═══ 关键设计决策一：通道按 `project_id` 建，不按 `task_id` ═══

任务面板是"一个面板看整个项目的任务列表"：
  * 按 project 建通道 → **一条 SSE 连接覆盖该项目全部任务**，每个事件自带 `task_id`，
    前端按 id 更新对应行；
  * 若按 task_id 建，N 个并行任务（`task_concurrency` 开启时）就要 N 条连接，
    且新任务出现时前端还得动态开连接——复杂度与泄漏面都大得多。

═══ 关键设计决策二：用「每订阅者一个 asyncio.Queue」而不是共享 Event/Condition ═══

广播给 N 个订阅者，两种错误做法都踩过或差点踩：
  * **共享 `asyncio.Event`**：第一个醒来的订阅者 `clear()` 之后，其余订阅者
    要等下一次 `set()` 或超时才醒 → 多面板同开时延迟可达一个心跳周期（丢唤醒）。
  * **共享 `asyncio.Condition`**：`notify_all()` 语义正确，但**要求调用方持有其内部
    asyncio 锁**，而 `push()` 是同步函数、不能 `await`。试图 `lock.acquire()` 同步取锁
    是错的——`asyncio.Lock.acquire()` 是协程函数，同步调用只返回一个永不 await 的协程，
    锁并未取得，紧接着 `notify_all()` 会抛 `RuntimeError: cannot notify on un-acquired lock`。
  * ✅ **每订阅者独立 Queue**：`put_nowait()` 无需持锁、天然一对多广播，
    且每个订阅者有自己的游标，互不干扰。

✅ **跨事件循环安全**（2026-09-11 实测修正）：`push()` 现在可从**任意** loop 或同步上下文调用。
`_deliver()` 会判断当前是否就在订阅者所在的 loop 上——是则直接 `put_nowait()`（生产路径：
委派协程与 SSE 端点同 loop，零开销）；否则用 `loop.call_soon_threadsafe()` 排进目标 loop。
早先版本假设"push 必须与订阅者同 loop"，实测该假设不成立且失败方式是**静默的**：
跨 loop `put_nowait()` 不报错但订阅者不被唤醒，SSE 端点卡在心跳上，前端永远收不到事件
（表现为测试里 push 后 `iter_lines()` 死循环超时）。故改为显式判定 + 跨线程投递。

═══ 关键设计决策三：晚到订阅者不丢状态 ═══

订阅者可能在任务跑了一半才连上（面板是用户中途点开的），错过的 `tool_call` 无从补发。
两道防线：
  1. 通道保留**环形缓冲**（`deque(maxlen=200)`）+ 单调 `seq`，订阅时先补发
     `since_seq` 之后仍在缓冲里的事件；
  2. 若 `since_seq` 与缓冲最早事件之间有断档，发一条 `gap` 事件，
     订阅者据此重拉快照，而不是拿着半截状态继续渲染。
  端点侧另发 `snapshot`（从 DB 读当前任务列表）作为连上时的权威基线。

═══ 设计约束 ═══

* **总线失败绝不能影响委派本身**：所有 push 都吞异常并返回 False。
  进度可视化是旁路，不能因为一个面板没连上就让用户的委派任务失败。
* **通道必须回收**：`end_task` 在委派 `finally` 里调用；
  不放 finally 的后果：异常路径下订阅者永远等不到结束 → 前端转圈不停
  （与 0.4.16 C2 根因③「running 状态未收敛」同源缺陷）。
  回收条件：无活跃任务 **且** 无订阅者；另设通道数上限淘汰最旧空闲通道，防长期泄漏。
* **绝不淘汰有订阅者或有活跃任务的通道**：淘汰活跃通道会让正在跑的委派推进
  一个已删除的通道（事件静默丢失），淘汰有订阅者的通道会让面板永久收不到更新。
  宁可暂时超出上限，也不牺牲正确性。
* 进程级内存即可（与 inject/cancel 一致）：侧车重启后没有活任务，总线自然无意义。
"""
from __future__ import annotations

import asyncio
import threading
import time
from collections import deque
from typing import Any, AsyncIterator

from sidecar.agent_engine._bus_common import _deliver

# 单个通道保留的事件数上限（环形缓冲）。200 足够覆盖一次委派的工具调用序列；
# 超出后旧事件被挤掉，订阅者靠 seq 断档检测 + 重拉快照对齐，不会静默错乱。
_BUFFER_MAX = 200

# 单个订阅者队列上限。慢消费者（如前端卡顿）不会拖垮总线：满了就丢最旧的一条，
# 该订阅者随后靠 seq 断档检测发现自己落后，重拉快照对齐。
_QUEUE_MAX = 200

# 通道数上限：防长期运行下 project 通道无限累积（只淘汰空闲通道，见 _evict_locked）。
_MAX_CHANNELS = 64

# 订阅者空闲超时（秒）。即使无事件也定期醒来产出 `_idle`，
# 供 SSE 端点发心跳（防代理断连）并检查通道是否已被回收。
IDLE_TIMEOUT = 15.0

# 通道被清空/关闭时投给订阅者的哨兵，收到即结束订阅
_CLOSED = object()


class _Channel:
    """一个 project 的事件通道。"""

    __slots__ = ("buf", "seq", "active_tasks", "subs", "touched", "loop")

    def __init__(self) -> None:
        self.buf: deque[dict[str, Any]] = deque(maxlen=_BUFFER_MAX)
        self.seq = 0                          # 单调递增，订阅者据此检测断档
        self.active_tasks: set[str] = set()   # 该 project 下正在跑的 task_id
        self.subs: list[tuple[asyncio.Queue, asyncio.AbstractEventLoop]] = []
        self.touched = time.monotonic()       # 最近活动时间（淘汰最旧通道用）
        self.loop: asyncio.AbstractEventLoop | None = None   # 首个订阅者的 loop


# project_id → 通道
_CHANNELS: dict[str, _Channel] = {}
# 注册表本身的锁：begin/end/push 可能在同步上下文调用，与订阅协程并发访问 dict
_LOCK = threading.Lock()


def _get_channel(project_id: str, create: bool) -> _Channel | None:
    pid = str(project_id or "").strip()
    if not pid:
        return None
    with _LOCK:
        ch = _CHANNELS.get(pid)
        if ch is None and create:
            ch = _Channel()
            _CHANNELS[pid] = ch
            # 必须把刚建的通道排除在淘汰之外：调用方（begin_task / subscribe）
            # 还没给它打活跃标记或注册订阅者，此刻它看起来是"空闲"的 →
            # 会被淘汰掉自己（实测：64 个忙通道 + 1 个新通道 → 新通道被自己挤掉，
            # begin_task 拿到的是一个已不在注册表里的孤儿对象，事件全部静默丢失）。
            _evict_locked(protect=pid)
        if ch is not None:
            ch.touched = time.monotonic()
        return ch


def _evict_locked(protect: str = "") -> None:
    """通道数超上限时淘汰最旧的**空闲**通道。调用方须持 `_LOCK`。

    只淘汰「无活跃任务且无订阅者」的通道（理由见模块文档"设计约束"）。
    `protect`：本次刚创建的通道 pid，必须跳过（其活跃标记尚未打上，见 _get_channel）。
    """
    over = len(_CHANNELS) - _MAX_CHANNELS
    if over <= 0:
        return
    idle = sorted((c.touched, p) for p, c in _CHANNELS.items()
                  if p != protect and not c.active_tasks and not c.subs)
    for _, p in idle[:over]:
        _CHANNELS.pop(p, None)


def _recycle_if_idle(ch: _Channel, pid: str) -> None:
    """无活跃任务且无订阅者 → 回收通道。调用方须持 `_LOCK`。"""
    if not ch.active_tasks and not ch.subs and _CHANNELS.get(pid) is ch:
        _CHANNELS.pop(pid, None)


def begin_task(project_id: str, task_id: str) -> None:
    """委派任务开始时调用：建通道并把 task_id 记为活跃。"""
    pid, tid = str(project_id or "").strip(), str(task_id or "").strip()
    if not pid or not tid:
        return
    ch = _get_channel(pid, create=True)
    if ch is None:
        return
    with _LOCK:
        ch.active_tasks.add(tid)


def end_task(project_id: str, task_id: str) -> None:
    """委派任务结束时调用（**必须放 finally**）。

    推一条 `task_end` 让订阅者知道该任务不会再有更新，再移除活跃标记并尝试回收通道。
    """
    pid, tid = str(project_id or "").strip(), str(task_id or "").strip()
    if not pid or not tid:
        return
    ch = _get_channel(pid, create=False)
    if ch is None:
        return
    push(pid, tid, "task_end", {"task_id": tid})
    with _LOCK:
        ch.active_tasks.discard(tid)
        _recycle_if_idle(ch, pid)


# _deliver 已收敛到 _bus_common.py（2026-09-11 跨 loop 踩坑留痕随函数整体搬迁，勿在此复制改写）


def push(project_id: str, task_id: str, event: str,
         data: dict[str, Any] | None = None) -> bool:
    """推一条事件给该 project 的全部订阅者。

    返回 True=已入缓冲并投递；False=通道不存在或参数非法。
    **绝不抛异常**：总线是进度可视化的旁路，任何失败都不得影响委派本身。
    """
    try:
        pid = str(project_id or "").strip()
        tid = str(task_id or "").strip()
        ev_name = str(event or "").strip()
        if not pid or not ev_name:
            return False
        ch = _get_channel(pid, create=False)
        if ch is None:
            return False
        with _LOCK:
            ch.seq += 1
            item = {"seq": ch.seq, "event": ev_name, "task_id": tid,
                    "data": dict(data or {})}
            ch.buf.append(item)
            targets = list(ch.subs)
        # 投递放在锁外：call_soon_threadsafe 可能阻塞，持锁会拖慢 begin/end_task
        for q, loop in targets:
            _deliver(q, loop, item)
        return True
    except Exception:
        return False


async def subscribe(project_id: str, since_seq: int = 0,
                    idle_timeout: float = IDLE_TIMEOUT) -> AsyncIterator[dict[str, Any]]:
    """订阅某 project 的实时事件（异步生成器）。

    产出顺序：
      1. `{"event": "_subscribed", "seq": 当前seq}` —— 握手，告知起点
      2. `{"event": "gap", ...}` —— 仅当 since_seq 与缓冲最早事件之间断档时
      3. 缓冲里 since_seq 之后的补发事件
      4. 实时事件（`status` / `progress` / `tool_call` / `tool_result` / `task_end`）
      5. `{"event": "_idle"}` —— 每 idle_timeout 秒无事件时一次（端点据此发心跳）
      6. `{"event": "_channel_closed"}` —— 通道被回收（仅 clear_all 时），订阅应结束

    订阅者注销必须放 finally：客户端断开（GeneratorExit / CancelledError）时
    也要摘掉自己的队列，否则通道永远"有订阅者"而无法回收 → 内存泄漏。
    """
    pid = str(project_id or "").strip()
    if not pid:
        return
    ch = _get_channel(pid, create=True)
    if ch is None:
        return

    q: asyncio.Queue = asyncio.Queue(maxsize=_QUEUE_MAX)
    # 记录**本订阅者所在的事件循环**：push 可能来自另一个 loop（见 _deliver 注释），
    # 必须据此判断是同循环直投还是 call_soon_threadsafe，否则订阅者收不到唤醒。
    _my_loop = asyncio.get_running_loop()
    with _LOCK:
        ch.subs.append((q, _my_loop))
        start_seq = ch.seq
        backlog = [e for e in ch.buf if e["seq"] > since_seq]

    try:
        yield {"event": "_subscribed", "seq": start_seq, "task_id": "", "data": {}}

        if since_seq > 0 and backlog and backlog[0]["seq"] > since_seq + 1:
            yield {"event": "gap", "seq": start_seq, "task_id": "",
                   "data": {"from": since_seq, "oldest_available": backlog[0]["seq"]}}
        for e in backlog:
            yield e

        while True:
            try:
                item = await asyncio.wait_for(q.get(), timeout=idle_timeout)
            except asyncio.TimeoutError:
                # 空闲：通知端点发心跳，并检查通道是否已不是当前注册的那个
                with _LOCK:
                    stale = _CHANNELS.get(pid) is not ch
                if stale:
                    yield {"event": "_channel_closed", "seq": ch.seq,
                           "task_id": "", "data": {}}
                    return
                yield {"event": "_idle", "seq": ch.seq, "task_id": "", "data": {}}
                continue
            if item is _CLOSED:
                yield {"event": "_channel_closed", "seq": ch.seq,
                       "task_id": "", "data": {}}
                return
            yield item
    finally:
        with _LOCK:
            # subs 是 (queue, loop) 元组列表，须按队列对象匹配移除，
            # 直接 remove(q) 会因类型不符抛 ValueError（本套件首轮即因此泄漏计数）
            ch.subs[:] = [s for s in ch.subs if s[0] is not q]
            _recycle_if_idle(ch, pid)


def active_task_count(project_id: str) -> int:
    """诊断/测试用：该 project 当前活跃任务数。"""
    ch = _get_channel(str(project_id or "").strip(), create=False)
    if ch is None:
        return 0
    with _LOCK:
        return len(ch.active_tasks)


def subscriber_count(project_id: str) -> int:
    """诊断/测试用：该 project 当前订阅者数。"""
    ch = _get_channel(str(project_id or "").strip(), create=False)
    if ch is None:
        return 0
    with _LOCK:
        return len(ch.subs)


def channel_count() -> int:
    """诊断/测试用：当前通道总数。"""
    with _LOCK:
        return len(_CHANNELS)


def buffered_count(project_id: str) -> int:
    """诊断/测试用：该 project 缓冲区里的事件数。"""
    ch = _get_channel(str(project_id or "").strip(), create=False)
    if ch is None:
        return 0
    with _LOCK:
        return len(ch.buf)


def latest_seq(project_id: str) -> int:
    """诊断/测试用：该 project 通道当前 seq（无通道返回 0）。"""
    ch = _get_channel(str(project_id or "").strip(), create=False)
    if ch is None:
        return 0
    with _LOCK:
        return ch.seq


def clear_all() -> None:
    """测试用 / 侧车关闭时：通知全部订阅者结束并清空通道。"""
    with _LOCK:
        targets = [(q, loop) for ch in _CHANNELS.values() for q, loop in ch.subs]
        _CHANNELS.clear()
    # 投递放锁外，并走 _deliver（跨事件循环安全）：
    # clear_all 常在测试的同步上下文里调用，直接 put_nowait 不会唤醒别的 loop 上的订阅者
    for q, loop in targets:
        _deliver(q, loop, _CLOSED)
