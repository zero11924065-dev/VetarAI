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
"""第 3 批（0.4.16）C2：聊天流的取消注册表。

═══ 为什么需要它（核实到的真实根因，三处断裂）═══

用户点「停止」后模型仍在跑。链条断了三处：
  1. 前端 `handleStop()` 只做 `abortRef.current?.abort()` —— **只关掉 SSE 连接，
     完全没通知后端**。
  2. 后端**没有 chat 的 stop 端点**（workflow / task / roundtable 三条链路都有，唯独聊天没有）。
  3. ⛔ 最隐蔽：`loop.py` **早就有**完整取消机制（`cancel_check` 参数在 :906、
     每轮开始前的检查在 :957），但 `app.py` 调 `run_tool_loop` 时**从未传该参数**
     （grep 命中 0 次）→ 对聊天路径是**死代码**，只服务委派（TS-114）。

⛔ 还有一处更深的：**光靠标志位不够**。客户端 abort 后，服务端只在尝试写下一个字节时
才发现断连；而本地大模型 prefill 阶段（首 token 前）**不产出任何字节** → 服务端察觉不到
→ 模型继续跑。而 `cancel_check` 只在**轮次边界**检查，prefill 期间同样够不着。
所以必须能**硬取消在飞的请求**，这需要"立即被唤醒"的能力，而非轮询。

═══ 为什么用 asyncio.Event 而不是 bool 标志 ═══

`gen()` 主循环已有 `asyncio.wait({next_task, timer}, FIRST_COMPLETED)` 结构（timer 是心跳）。
把取消 Event 一起放进 wait_set → **点停止后立刻被唤醒**，随即 `next_task.cancel()`，
可中断 prefill 期间的在飞请求。

⛔ 若改用"轮询 bool 标志"，最快也要等心跳醒来才察觉——而心跳基础值 15s，
且 `compute_heartbeat_interval` 会按事件稀疏度放大（上限 60s）。
用户点停止后要等十几秒才生效，那不叫停止。

═══ 为什么要"流注册表"而不是只存标志 ═══

⛔ 残留标志的危害远大于内存增长：**会让该会话下一次发送刚进循环就被取消**，
表现为"停止按钮永久生效"，用户再也无法正常对话。
故用显式的 register/unregister 配对：
  - 只有**已注册（确有活流）**的会话才接受取消请求 → stop 端点能如实回答
    "该会话当前没有进行中的生成"，而不是谎称"已停止"
  - unregister 时连 Event 一起丢弃 → 下一次发送注册的是**全新未置位**的 Event，
    结构上不可能残留（比"记得清零"更可靠）

═══ 为什么不复用 workflow 的 `_CANCEL_FLAGS` ═══

`engine.py` 那套是 `run_id → bool`，语义绑死工作流运行实例（还牵涉审批解锁）。
聊天没有 run_id，只有 session_id；混用会让"停工作流"与"停聊天"互相干扰。
"""
from __future__ import annotations

import asyncio
import threading
from typing import Callable

# session_id → 该会话当前活流的取消 Event。
# ⚠️ 只在"有活流"期间存在：register 时创建、unregister 时丢弃。
_EVENTS: dict[str, asyncio.Event] = {}
# 同一进程内注册表本身需要锁（多线程访问：SSE 协程 + stop 端点协程可能不同线程）
_LOCK = threading.Lock()


def register_stream(session_id: str) -> asyncio.Event | None:
    """流开始时注册，返回该流的取消 Event（供 gen() 放进 asyncio.wait）。

    session_id 为空（如非会话式调用）→ 返回 None，调用方据此跳过取消监听。
    ⛔ 每次注册都创建**全新未置位**的 Event，故结构上不可能继承上一次的取消状态。
    """
    sid = str(session_id or "").strip()
    if not sid:
        return None
    ev = asyncio.Event()
    with _LOCK:
        # 同一会话理论上同时只有一条活流（前端 sending 守卫已保证）；
        # 若真出现并发（如重连竞态），以最新注册为准，旧的直接丢弃。
        _EVENTS[sid] = ev
    return ev


def unregister_stream(session_id: str) -> None:
    """流结束时**必须**调用（放 finally）。丢弃 Event，杜绝残留。"""
    sid = str(session_id or "").strip()
    if not sid:
        return
    with _LOCK:
        _EVENTS.pop(sid, None)


def request_chat_cancel(session_id: str) -> bool:
    """置取消标志。返回 True=确有活流并已请求取消；False=该会话本无活流。

    ⛔ 只对**已注册**的会话生效：对空闲会话置标志毫无意义，且若真置了就会变成
    残留标志（见模块文档）。返回 False 让端点能如实告知用户"无需停止"。
    """
    sid = str(session_id or "").strip()
    if not sid:
        return False
    with _LOCK:
        ev = _EVENTS.get(sid)
        if ev is None:
            return False          # 无活流
        was_set = ev.is_set()
        ev.set()
        return not was_set


def is_chat_cancelled(session_id: str) -> bool:
    """供 `run_tool_loop(cancel_check=...)` 在轮次边界轮询（低成本兜底）。

    注意：这是**第二道**防线。第一道是 gen() 里 await Event → 立即硬取消 next_task，
    能覆盖 prefill 期间；本函数覆盖"本轮已正常结束、进入下一轮"的场景。
    """
    sid = str(session_id or "").strip()
    if not sid:
        return False
    with _LOCK:
        ev = _EVENTS.get(sid)
        return bool(ev is not None and ev.is_set())


def make_cancel_check(session_id: str) -> Callable[[], bool]:
    """构造传给 `run_tool_loop(cancel_check=...)` 的回调。"""
    return lambda: is_chat_cancelled(session_id)


def clear_all() -> None:
    """测试用：清空全部注册。"""
    with _LOCK:
        _EVENTS.clear()
