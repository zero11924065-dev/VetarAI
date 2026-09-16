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
"""A13（0.4.22）：应用级「资源变更」事件总线（单一全局通道）。

═══ 为什么需要这个模块 ═══

用户实测缺陷（0.4.19/0.4.22 清单 A13）：**Agent 拉起/修改的资源，面板不实时刷新**——
Agent 在工作时直接写库（创建/修改工作流、项目、插件、知识、推理配置），但前端 6 个面板
（Workflow / Project / IndependentAgents / Knowledge / Plugin / Inference）没有刷新机制：
App.tsx 用 `display` 切换做保活（不卸载组件），各面板的 `useEffect` 只在首次挂载时拉一次，
Agent 改完库后用户切回面板看到的还是旧数据，**必须重启应用**才更新。

根因不是"没产生变更"，而是**变更没有出口推给前端**：Agent 经 `registry.py` / `app.py`
端点直接写库，零事件通知前端。本模块提供一个进程内的"资源变更"广播点，写库后 `notify()`，
前端经全局 SSE 端点（`GET /api/events/stream`）订阅，收到变更即按需重拉对应面板数据。

═══ 为什么是「单一全局通道」而不像 delegation_events 按 project_id 分通道 ═══

  * delegation_events 的通道按 project_id 建，因为委派进度是"一个面板看一个项目的任务"，
    天然按项目隔离；
  * 而**资源变更是跨项目的**：插件/推理配置是全局的，工作流/项目/知识虽属某项目但前端
    App 级只需**一条连接**监听"任何资源变了"，再按 `resource` 字段决定重拉哪个面板。
    若按 project_id 分通道，前端要为每个项目开一条连接、且新项目出现时还得动态开——
    复杂度与泄漏面都大。单通道 + 事件自带 resource/project_id 是最小可用解。

═══ 复用 delegation_events 验证过的架构（勿凭直觉改）═══

  1. **每订阅者独立 asyncio.Queue**（非共享 Event/Condition）：`put_nowait()` 无需持锁、
     天然一对多广播、各订阅者独立游标。共享 Event 会丢唤醒、共享 Condition 要求持锁而
     notify 是同步函数不能 await（详见 delegation_events 模块文档"设计决策二"）。
  2. **跨事件循环安全投递**（`_deliver`）：notify 可能来自另一个 loop（TestClient 把应用
     跑在独立线程的 loop；将来任何同步上下文调用也一样）。跨 loop 直接 put_nowait 不报错
     但**订阅者不被唤醒**（静默失败：SSE 卡在心跳，前端永远收不到）→ 必须先判断是否同
     loop，否则 `call_soon_threadsafe`。此坑 delegation_events 已实测踩过，原样复用。
  3. **环形缓冲 + 单调 seq + gap 对账**：晚到订阅者（面板中途连上）先补发 since_seq 之后
     仍在缓冲的事件；若断档发 `gap`，订阅者据此重拉快照而非拿半截状态渲染。
  4. **总线失败绝不影响主流程**：notify 吞异常返回 False。资源变更可视化是旁路，
     不能因为前端没连上就让 Agent 的写库操作失败。
  5. **订阅者注销必须放 finally**：客户端断开（GeneratorExit/CancelledError）也要摘掉
     自己的队列，否则订阅者计数泄漏。

═══ 与 delegation_events 的差异（单通道带来的简化）═══

  * 无通道注册表 dict、无淘汰逻辑、无通道回收：全局单例 `_BUS` 永久存在（进程级内存，
    与 delegation_events/inject/cancel 一致，侧车重启后无意义）。
  * idle 分支不需 stale 检查（通道永不被淘汰），直接发心跳。
  * `clear_all` 仅测试/侧车关闭时用：清空缓冲 + 通知全部订阅者结束。
"""
from __future__ import annotations

import asyncio
import threading
from collections import deque
from typing import Any, AsyncIterator

from sidecar.agent_engine._bus_common import _deliver

# ── 资源类型常量（前端按此字段决定重拉哪个面板）──
RESOURCE_WORKFLOW = "workflow"      # → WorkflowPanel
RESOURCE_PROJECT = "project"        # → ProjectPanel
RESOURCE_PLUGIN = "plugin"          # → PluginPanel
RESOURCE_KNOWLEDGE = "knowledge"    # → KnowledgePanel / WarehouseManager
RESOURCE_INFERENCE = "inference"    # → InferencePanel（SettingsPage 内）
RESOURCE_AGENT = "agent"            # → IndependentAgentsPanel / AgentPanel
# REQ-AGT-020（0.4.28）：会话消息变更 → ChatPanel。只在委派写子会话路径发射
# （delegation.py 四处 save_message 后），⛔ 不挂全局 save_message——主聊天热路径
# 每条消息都过，挂上即事件风暴。payload 带 session_id，前端据此定向重拉。
RESOURCE_SESSION = "session"

# ── 动作类型常量 ──
ACTION_CREATE = "create"
ACTION_UPDATE = "update"
ACTION_DELETE = "delete"

# 单通道保留的事件数上限（环形缓冲）。资源变更频率远低于 token，
# 100 足够覆盖一次 Agent 跑批的多个写操作；超出后旧事件被挤掉，
# 订阅者靠 seq 断档检测 + 重拉对齐，不会静默错乱。
_BUFFER_MAX = 100

# 单个订阅者队列上限。慢消费者（前端卡顿）不拖垮总线：满了丢最旧一条，
# 该订阅者随后靠 seq 断档检测发现自己落后，重拉对齐。
_QUEUE_MAX = 100

# 订阅者空闲超时（秒）。即使无事件也定期醒来产出 `_idle`，
# 供 SSE 端点发心跳（防代理断连）。
IDLE_TIMEOUT = 15.0

# 总线被清空/关闭时投给订阅者的哨兵，收到即结束订阅
_CLOSED = object()


class _Bus:
    """单一全局资源变更通道。"""

    __slots__ = ("buf", "seq", "subs")

    def __init__(self) -> None:
        self.buf: deque[dict[str, Any]] = deque(maxlen=_BUFFER_MAX)
        self.seq = 0                          # 单调递增，订阅者据此检测断档
        # 订阅者列表：(queue, 该订阅者所在的 event loop)
        self.subs: list[tuple[asyncio.Queue, asyncio.AbstractEventLoop]] = []


# 全局单例总线（进程级内存，侧车重启后无意义）
_BUS = _Bus()
# 总线状态锁：notify 可能在同步上下文调用，与订阅协程并发访问 buf/seq/subs
_LOCK = threading.Lock()


# _deliver 已收敛到 _bus_common.py（2026-09-11 跨 loop 踩坑留痕随函数整体搬迁，勿在此复制改写）


def notify(resource: str, action: str, project_id: str | None = None,
           **extra: Any) -> bool:
    """推一条「资源变更」事件给全部订阅者。

    参数：
      * resource：资源类型（用 RESOURCE_* 常量），前端据此决定重拉哪个面板；
      * action：动作（ACTION_CREATE/UPDATE/DELETE）；
      * project_id：可选，项目级资源带上（前端可据此只刷新对应项目的面板）；
      * **extra：可选附加字段（如 workflow_id=... / plugin_name=...），并入 data 下发。
        用 kwargs 而非 dict 参数：调用方写 `notify(RES, ACT, workflow_id=w)` 更自然，
        且与 app.py 的 `_notify_change(**extra)` helper 两层 API 形态一致。

    返回 True=已入缓冲并投递；False=参数非法或总线异常。
    **绝不抛异常**：总线是变更可视化的旁路，任何失败都不得影响 Agent 的写库本身。
    """
    try:
        res = str(resource or "").strip()
        act = str(action or "").strip()
        if not res:
            return False
        data: dict[str, Any] = {"resource": res, "action": act,
                                "project_id": str(project_id or "")}
        if extra:
            data.update(extra)
        with _LOCK:
            _BUS.seq += 1
            item = {"seq": _BUS.seq, "event": "resource_changed", "data": data}
            _BUS.buf.append(item)
            targets = list(_BUS.subs)
        # 投递放在锁外：call_soon_threadsafe 可能阻塞，持锁会拖慢 notify
        for q, loop in targets:
            _deliver(q, loop, item)
        return True
    except Exception:
        return False


async def subscribe(since_seq: int = 0,
                    idle_timeout: float = IDLE_TIMEOUT) -> AsyncIterator[dict[str, Any]]:
    """订阅全局资源变更事件（异步生成器）。

    产出顺序：
      1. `{"event": "_subscribed", "seq": 当前seq}` —— 握手，告知起点
      2. `{"event": "gap", ...}` —— 仅当 since_seq 与缓冲最早事件之间断档时
      3. 缓冲里 since_seq 之后的补发事件
      4. 实时事件（`resource_changed`）
      5. `{"event": "_idle"}` —— 每 idle_timeout 秒无事件时一次（端点据此发心跳）
      6. `{"event": "_bus_closed"}` —— 总线被清空（仅 clear_all 时），订阅应结束

    订阅者注销必须放 finally：客户端断开（GeneratorExit / CancelledError）时
    也要摘掉自己的队列，否则订阅者计数泄漏。
    """
    q: asyncio.Queue = asyncio.Queue(maxsize=_QUEUE_MAX)
    # 记录**本订阅者所在的事件循环**：notify 可能来自另一个 loop（见 _deliver 注释），
    # 必须据此判断是同循环直投还是 call_soon_threadsafe，否则订阅者收不到唤醒。
    _my_loop = asyncio.get_running_loop()
    with _LOCK:
        _BUS.subs.append((q, _my_loop))
        start_seq = _BUS.seq
        backlog = [e for e in _BUS.buf if e["seq"] > since_seq]

    try:
        yield {"event": "_subscribed", "seq": start_seq, "data": {}}

        if since_seq > 0 and backlog and backlog[0]["seq"] > since_seq + 1:
            yield {"event": "gap", "seq": start_seq,
                   "data": {"from": since_seq, "oldest_available": backlog[0]["seq"]}}
        for e in backlog:
            yield e

        while True:
            try:
                item = await asyncio.wait_for(q.get(), timeout=idle_timeout)
            except asyncio.TimeoutError:
                # 空闲：通知端点发心跳。单通道永久存在，无需 stale 检查。
                yield {"event": "_idle", "seq": _BUS.seq, "data": {}}
                continue
            if item is _CLOSED:
                yield {"event": "_bus_closed", "seq": _BUS.seq, "data": {}}
                return
            yield item
    finally:
        with _LOCK:
            # subs 是 (queue, loop) 元组列表，须按队列对象匹配移除，
            # 直接 remove(q) 会因类型不符抛 ValueError（delegation_events 已踩过）
            _BUS.subs[:] = [s for s in _BUS.subs if s[0] is not q]


def latest_seq() -> int:
    """诊断/测试用：总线当前 seq。"""
    with _LOCK:
        return _BUS.seq


def subscriber_count() -> int:
    """诊断/测试用：当前订阅者数。"""
    with _LOCK:
        return len(_BUS.subs)


def buffered_count() -> int:
    """诊断/测试用：缓冲区里的事件数。"""
    with _LOCK:
        return len(_BUS.buf)


def clear_all() -> None:
    """测试用 / 侧车关闭时：通知全部订阅者结束并清空总线。"""
    with _LOCK:
        targets = list(_BUS.subs)
        _BUS.subs.clear()
        _BUS.buf.clear()
        _BUS.seq = 0
    # 投递放锁外，并走 _deliver（跨事件循环安全）：
    # clear_all 常在测试的同步上下文里调用，直接 put_nowait 不会唤醒别的 loop 上的订阅者
    for q, loop in targets:
        _deliver(q, loop, _CLOSED)
