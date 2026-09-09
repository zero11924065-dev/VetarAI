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
"""第 3 批（0.4.16）C2 专项：聊天停止链路。

锁住四条**必须成立否则就是假修复**的语义：
  ① stop 端点存在且只对**有活流**的会话返回 ok=True（无活流如实告知"无需停止"）
  ② 取消**立即生效**：Event 置位后 gen() 无需等心跳就能察觉
     （⛔ 若用心跳轮询，基础值 15s 且会动态放大到 60s，等于"点停止后等一分钟"）
  ③ **无残留**：流结束后该会话再注册必须拿到全新未置位 Event
     （残留会让下次发送刚进循环就被取消 = "停止按钮永久生效"）
  ④ loop 的 cancel_check 已真正接线（此前 app.py 从未传该参数 → 死代码）

隔离：钉死 config.store.get_config_path 到临时目录（第 0 批纪律）。
"""
from __future__ import annotations

import asyncio
import inspect
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

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


_TMP = Path(tempfile.mkdtemp(prefix="c2_"))
import sidecar.config.store as cs          # noqa: E402
cs.get_config_path = lambda: _TMP / "config.json"

from sidecar.agent_engine import cancel as c   # noqa: E402


def main() -> None:
    asyncio.run(_async_checks())

    # ── ④ 静态接线核查：app.py 必须真的传 cancel_check 给 run_tool_loop ──
    app_src = Path(__file__).resolve().parents[1] / "sidecar" / "app.py"
    src = app_src.read_text(encoding="utf-8")
    check("④ app.py 已传 cancel_check 给 run_tool_loop（此前从未传 → 死代码）",
          "cancel_check=_cancel.make_cancel_check" in src)
    check("④ app.py 注册流（register_stream）", "_cancel.register_stream(" in src)
    check("④ app.py 在 finally 注销流（unregister_stream）",
          "_cancel.unregister_stream(" in src)
    # ⛔ 注销必须在 finally 内，否则异常路径漏清理 → 残留标志
    fin = src.find("finally:")
    unreg = src.find("_cancel.unregister_stream(")
    check("④ unregister_stream 位于 finally 块内（覆盖所有退出路径）",
          fin > 0 and unreg > fin, f"finally@{fin} unregister@{unreg}")
    # ⛔ 不得用心跳轮询做取消（太慢）
    check("④ 取消走 Event 而非心跳轮询（立即响应）",
          "_cancel_waiter" in src and "wait_set.add(_cancel_waiter)" in src)

    print(f"\n===== C2 专项: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("失败项:", FAILURES)
        sys.exit(1)


async def _async_checks() -> None:
    # ── ① stop 端点语义：只对活流返回 ok ──
    from sidecar.app import api_chat_stop

    c.clear_all()
    r = await api_chat_stop("idle-session")
    check("① 无活流 → ok=False 且如实告知无需停止",
          r.get("ok") is False and "没有进行中" in str(r.get("detail", "")), str(r))

    ev = c.register_stream("s-live")
    r = await api_chat_stop("s-live")
    check("① 有活流 → ok=True", r.get("ok") is True, str(r))
    check("① 置位后 Event 确实被 set", ev is not None and ev.is_set())

    r2 = await api_chat_stop("s-live")
    check("① 重复停止 → ok=False（幂等，不谎称又停了一次）", r2.get("ok") is False, str(r2))

    try:
        await api_chat_stop("")
        check("① 空 session_id → 422", False, "未抛错")
    except Exception as e:
        check("① 空 session_id → 422", "422" in str(getattr(e, "status_code", ""))
              or e.__class__.__name__ == "HTTPException", str(e))

    # ── ② 立即生效：Event 置位后无需等心跳 ──
    c.clear_all()
    ev2 = c.register_stream("s-fast")
    waiter = asyncio.ensure_future(ev2.wait())
    # 模拟 gen() 的 wait：同时等一个"很慢的模型"（5s）和取消 waiter
    slow_model = asyncio.ensure_future(asyncio.sleep(5.0))
    await asyncio.sleep(0)                      # 让两个 task 起跑
    c.request_chat_cancel("s-fast")             # 用户点停止
    done, _pending = await asyncio.wait({slow_model, waiter},
                                        return_when=asyncio.FIRST_COMPLETED, timeout=1.0)
    check("② 点停止后立即被唤醒（1s 内，远快于 15s 心跳）", waiter in done, str(done))
    check("② 慢模型任务此时仍未完成（说明确实是被取消唤醒，不是它自己结束）",
          not slow_model.done())
    slow_model.cancel()
    try:
        await slow_model
    except BaseException:
        pass
    if not waiter.done():
        waiter.cancel()

    # ── ③ 无残留：流结束后再注册必须是全新未置位 Event ──
    c.register_stream("s-res")
    c.request_chat_cancel("s-res")
    check("③ 前置：已置位", c.is_chat_cancelled("s-res") is True)
    c.unregister_stream("s-res")                # 模拟 finally 清理
    check("③ 注销后 is_chat_cancelled 立刻为 False", c.is_chat_cancelled("s-res") is False)
    check("③ 注销后 request 返回 False（无活流）", c.request_chat_cancel("s-res") is False)
    ev3 = c.register_stream("s-res")            # 下一次发送
    check("③ ⛔ 重新注册拿到**未置位**的新 Event（否则停止按钮永久生效）",
          ev3 is not None and not ev3.is_set())
    check("③ 重新注册后 cancel_check 读到 False", c.make_cancel_check("s-res")() is False)

    # ── ④b 并发注册：同会话新流覆盖旧流，旧 Event 不再被读到 ──
    old = c.register_stream("s-dup")
    new = c.register_stream("s-dup")
    check("④b 同会话重复注册 → 以最新为准", old is not new)
    c.request_chat_cancel("s-dup")
    check("④b 取消作用于最新 Event", new.is_set() and not old.is_set())
    c.clear_all()


if __name__ == "__main__":
    main()
