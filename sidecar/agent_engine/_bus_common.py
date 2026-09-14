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
"""进程内事件总线的共享私有件（R4-S2 收敛）。

`app_events`（A13 资源变更总线，单通道）与 `delegation_events`（0.4.20 #15 委派进度
总线，按 project_id 分通道）原本各持有一份逐字相同的 `_deliver`。本模块存放这份
共用实现，两个总线模块一律从这里 import，勿再各自复制改写。
"""
from __future__ import annotations

import asyncio
from typing import Any


def _deliver(q: asyncio.Queue, loop: asyncio.AbstractEventLoop | None,
             item: Any) -> None:
    """把一条事件投进某个订阅者的队列。

    **必须跨事件循环安全**（2026-09-11 实测踩坑）：`asyncio.Queue` 绑定创建它的
    loop，而 `push()` 可能来自**另一个** loop（TestClient.stream 把应用跑在独立线程的
    loop 里；将来若有任何同步上下文调用也一样）。跨 loop 直接 `put_nowait()` 不会报错，
    但**订阅者不会被唤醒** → SSE 端点静默卡在心跳上，前端永远收不到事件。
    实测表现：测试里 push 之后 `iter_lines()` 死循环 180s 超时。

    做法：先判断当前是否就在目标 loop 上——
      * 是 → 直接 `put_nowait()`（零开销，生产路径：委派协程与 SSE 端点同 loop）
      * 否 → `call_soon_threadsafe()` 把投递动作排进目标 loop
    队列满时丢最旧一条：慢消费者不拖垮总线，该订阅者随后靠 seq 断档检测自行对齐。
    """
    def _put() -> None:
        if q.full():
            try:
                q.get_nowait()
            except asyncio.QueueEmpty:
                pass
        try:
            q.put_nowait(item)
        except asyncio.QueueFull:
            pass

    if loop is None or loop.is_closed():
        return
    try:
        running = asyncio.get_running_loop()
    except RuntimeError:
        running = None
    if running is loop:
        _put()
    else:
        try:
            loop.call_soon_threadsafe(_put)
        except RuntimeError:
            pass          # 目标 loop 正在关闭：事件已入 buf，重连可补发
