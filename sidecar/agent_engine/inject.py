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
"""第 3 批（0.4.16）A5：思考中插入新消息的「待注入队列」。

═══ 语义（用户拍板，类比"助手如何处理用户在其工作时发来的新消息"）═══

模型正在生成时，用户插入的新消息**不打断当前这一轮**，而是排队等待；
当前轮结束、**下一轮开始前**，模型读到这条新消息并据此反应：
  - 若助手方向错了 → 模型据新消息纠偏；
  - 若用户只是补充 → 模型自行决定先做哪个、后做哪个。
这与 C2「停止」共用同一个检查点（每轮开始前），区别只是：
  停止 = 读到取消信号就退出；A5 = 读到新消息就并进上下文继续。

═══ 为什么用"队列 + 每轮 drain"而不是直接改 msgs ═══

loop 的 `msgs` 是单次请求内的局部状态，外部 HTTP 端点无法直接触达。
用一个按 session_id 索引的进程内队列做交接：端点 push、loop drain，二者解耦。

═══ 设计约束 ═══

* ⛔ **不丢消息**：push 由 app 端点在 save_message 落库**之后**才调用（本模块只管
  内存交接），故即使流意外结束，消息仍在 DB，刷新可见。
* ⛔ **只在有活流时接受 push**：无活流说明当前没在生成，这条消息应当走正常发送
  （前端据 sending 判断）；push 返回 False 让端点如实告知，而不是塞进一个没人
  drain 的队列里烂掉。
* ⛔ **end_stream 清理残留**：流结束时清空该会话队列，杜绝"上一轮的残留消息被
  下一轮流 drain 到"——那会让新会话莫名其妙多出旧消息（与 C2/C5 的"残留标志"同类缺陷）。
* 进程级内存即可（与 cancel.py 一致）：侧车重启后没有活流，队列自然无意义。
"""
from __future__ import annotations

import threading
from typing import Callable

# session_id → 待注入的消息文本列表（FIFO）
_QUEUES: dict[str, list[str]] = {}
# 当前有活流的 session_id 集合（begin/end_stream 维护）
_ACTIVE: set[str] = set()
_LOCK = threading.Lock()


def begin_stream(session_id: str) -> None:
    """流开始时调用（与 cancel.register_stream 同一处）。标记该会话有活流。"""
    sid = str(session_id or "").strip()
    if not sid:
        return
    with _LOCK:
        _ACTIVE.add(sid)
        _QUEUES.setdefault(sid, [])


def end_stream(session_id: str) -> None:
    """流结束时调用（放 finally，与 cancel.unregister_stream 同一处）。

    ⛔ 必须清空残留队列：否则上一轮没被 drain 的消息会被同会话的下一轮流读到，
    表现为"新回复莫名其妙混进了旧消息"。
    """
    sid = str(session_id or "").strip()
    if not sid:
        return
    with _LOCK:
        _ACTIVE.discard(sid)
        _QUEUES.pop(sid, None)


def push(session_id: str, content: str) -> bool:
    """用户插入一条新消息。返回 True=已入队（有活流）；False=当前无活流，应走正常发送。

    ⛔ 调用方（app 端点）须**先 save_message 落库再 push**，保证不丢。
    """
    sid = str(session_id or "").strip()
    text = str(content or "")
    if not sid or not text.strip():
        return False
    with _LOCK:
        if sid not in _ACTIVE:
            return False              # 无活流：这条消息不该进队列
        _QUEUES.setdefault(sid, []).append(text)
        return True


def drain(session_id: str) -> list[str]:
    """取出并清空该会话的待注入消息（loop 每轮开始前调）。

    取出即清空：同一条消息只会被并入一次，不会每轮重复注入。
    """
    sid = str(session_id or "").strip()
    if not sid:
        return []
    with _LOCK:
        q = _QUEUES.get(sid)
        if not q:
            return []
        out = list(q)
        q.clear()
        return out


def pending(session_id: str) -> int:
    """诊断/测试用：该会话当前待注入消息条数。"""
    sid = str(session_id or "").strip()
    with _LOCK:
        return len(_QUEUES.get(sid, []))


def is_active(session_id: str) -> bool:
    """该会话当前是否有活流。"""
    sid = str(session_id or "").strip()
    with _LOCK:
        return sid in _ACTIVE


def make_inject_check(session_id: str) -> Callable[[], list[str]]:
    """构造传给 `run_tool_loop(inject_check=...)` 的回调（每轮 drain 一次）。"""
    return lambda: drain(session_id)


def clear_all() -> None:
    """测试用：清空全部队列与活跃集合。"""
    with _LOCK:
        _QUEUES.clear()
        _ACTIVE.clear()
