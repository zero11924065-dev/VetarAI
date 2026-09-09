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
"""第 3 批（0.4.16）A5 专项：思考中插入新消息（不打断当前轮）。

用户拍板语义：模型正在生成时用户发来的新消息**不急刹车**，而是让当前轮做完，
**下一轮开始前**模型读到它，再自行纠偏或补充。与 C2 停止共用同一检查点
（每轮开始前）：停止=读到取消就退出，A5=读到新消息就并入继续。

覆盖：
  队列（inject.py）：活流判定 / 取出即清空 / 清残留 / 拒空 / 会话隔离
  loop 注入：msgs 在下一轮**开头**被追加（不打断当前轮）、多条按序、取出即清空不重复
  端点接线：inject 端点存在、先落库再入队、无活流返回 ok=False

隔离：VETARAI_DATA_ROOT=临时目录（第 0 批纪律），必须在 import store 之前设。
"""
from __future__ import annotations

import asyncio
import os
import sys
import tempfile
from pathlib import Path

_TMP = tempfile.mkdtemp(prefix="a5_")
os.environ["VETARAI_DATA_ROOT"] = _TMP
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


from sidecar.agent_engine import inject as q          # noqa: E402
import sidecar.config.store as cs                      # noqa: E402


def queue_checks() -> None:
    q.clear_all()
    check("Q-1 无活流 push → False（应走正常发送）", q.push("s1", "你好") is False)
    check("Q-2 无活流 pending → 0", q.pending("s1") == 0)

    q.begin_stream("s1")
    check("Q-3 begin_stream 后 is_active", q.is_active("s1") is True)
    check("Q-4 活流 push → True", q.push("s1", "换个方向") is True)
    q.push("s1", "再补充一点")
    check("Q-5 两条 pending → 2", q.pending("s1") == 2, str(q.pending("s1")))
    got = q.drain("s1")
    check("Q-6 drain 按 FIFO 取出两条", got == ["换个方向", "再补充一点"], str(got))
    check("Q-7 ⛔ drain 后清空（取出即清空，不重复注入）", q.pending("s1") == 0)
    check("Q-8 再次 drain → 空", q.drain("s1") == [])

    q.push("s1", "残留消息")
    q.end_stream("s1")
    check("Q-9 end_stream 后 is_active → False", q.is_active("s1") is False)
    q.begin_stream("s1")
    check("Q-10 ⛔ 重新 begin 后残留已清（防旧消息串进下一轮流）", q.pending("s1") == 0)

    q.begin_stream("s2")
    check("Q-11 空白内容 push → False", q.push("s2", "   ") is False)
    check("Q-12 空串 push → False", q.push("s2", "") is False)

    q.begin_stream("s3")
    q.push("s3", "只属于 s3")
    check("Q-13 会话隔离：s1 drain 不到 s3 的消息", q.drain("s1") == [])
    check("Q-14 会话隔离：s3 取到自己的", q.drain("s3") == ["只属于 s3"])
    q.clear_all()


class FakeConn:
    """假连接器：每次 chat_stream 先吐一个 token 再 done。
    通过记录每轮收到的 msgs 长度，验证注入发生在**下一轮开头**。"""

    def __init__(self, rounds: int):
        self.rounds = rounds          # 计划轮数（用 tool_calls 触发多轮）
        self.seen_msgs_len: list[int] = []
        self.seen_last_user: list[str] = []
        self._n = 0

    def capabilities(self):
        return {"backend": "ollama", "tools": True, "vision": True, "pull": True, "delete": True}

    async def chat_stream(self, model, msgs, **kw):
        self._n += 1
        self.seen_msgs_len.append(len(msgs))
        last_user = next((m.get("content") for m in reversed(msgs)
                          if m.get("role") == "user"), "")
        self.seen_last_user.append(str(last_user))
        if self._n <= self.rounds:
            # 还有下一轮 → 发一个工具调用，迫使循环再转一圈
            yield {"tool_calls": [{"id": f"c{self._n}", "name": "read_file",
                                   "arguments": {"path": f"f{self._n}.txt"}}]}
        yield {"content": f"第{self._n}轮回复"}


async def loop_checks() -> None:
    """用假连接器 + 真 loop，验证注入时机：第 2 轮 msgs 里出现插入的消息。"""
    from sidecar.agent_engine.loop import run_tool_loop
    from sidecar.tools import TOOLS   # 提供 read_file 工具（假调用会失败，但不影响轮次推进）

    q.clear_all()
    sid = "s-loop"
    q.begin_stream(sid)

    conn = FakeConn(rounds=2)          # 计划跑 2 轮工具调用 + 最终回复
    msgs = [{"role": "user", "content": "最初的问题"}]
    specs = [{"type": "function", "function": {"name": "read_file",
              "description": "read", "parameters": {"type": "object", "properties": {}}}}]

    events: list[str] = []
    aiter = run_tool_loop("m", msgs, specs, _TMP, connector=conn,
                          max_rounds=5, inject_check=q.make_inject_check(sid)).__aiter__()

    # 手动推进：第一轮 chat_stream 被调用后（模型开始"思考"），插入新消息
    injected = False
    while True:
        try:
            ev = await asyncio.wait_for(aiter.__anext__(), timeout=5)
        except StopAsyncIteration:
            break
        except asyncio.TimeoutError:
            check("L-x loop 未在 5s 内推进（疑似卡死）", False)
            break
        events.append(ev.get("event", "?"))
        # 第一次收到 tool_result（第一轮工具执行完）后插入消息 → 应在第 2 轮开头被读到
        if not injected and ev.get("event") == "tool_result":
            q.push(sid, "请改为关注性能问题")
            injected = True
        if ev.get("event") == "done":
            break

    check("L-1 注入确实发生过（第一轮工具结果后 push）", injected is True)
    # ⛔ L-2 不要求 done：FakeConn 发的 read_file 读不存在的文件 → 连续工具失败 →
    # loop **正确熔断**为 error（这是 loop 自己的熔断行为，与 A5 无关）。
    # A5 要测的是"注入时机"，只要 loop 推进了多轮并正常终止（done 或熔断 error，
    # 不是超时卡死）即可——多轮推进正是 L-3~L-6 注入时机断言成立的前提。
    check("L-2 loop 正常终止（done 或熔断 error，非卡死；A5 不测 loop 终态）",
          ("done" in events) or ("error" in events), str(events[:8]))
    check("L-2b loop 确实推进了≥2 轮（注入时机断言的前提）",
          len(conn.seen_msgs_len) >= 2, str(conn.seen_msgs_len))
    # 第 1 轮 msgs 不含插入消息；第 2 轮 msgs 含（长度 +1，且最后一条 user 是插入内容）
    check("L-3 第 1 轮 msgs 不含插入消息（不打断当前轮）",
          len(conn.seen_msgs_len) >= 1 and "请改为关注性能问题" not in conn.seen_last_user[0],
          str(conn.seen_last_user[:2]))
    check("L-4 ⛔ 第 2 轮 msgs 读到插入消息（下一轮开头并入）",
          len(conn.seen_last_user) >= 2 and any("请改为关注性能问题" in u for u in conn.seen_last_user[1:]),
          str(conn.seen_last_user))
    check("L-5 msgs 长度在注入后增加（确实 append 了 user 消息）",
          len(conn.seen_msgs_len) >= 2 and conn.seen_msgs_len[1] > conn.seen_msgs_len[0],
          str(conn.seen_msgs_len))
    # 取出即清空：第 3 轮不应再次出现同一条（除非模型自己又加）
    check("L-6 注入只并入一次（drain 后队列已空）", q.pending(sid) == 0, str(q.pending(sid)))
    q.end_stream(sid)
    q.clear_all()


def endpoint_checks() -> None:
    from sidecar.app import app, api_chat_inject
    rs = [r.path for r in app.routes if hasattr(r, "path")]
    check("E-1 inject 端点已注册", "/api/chat/{session_id}/inject" in rs, str([r for r in rs if "chat" in r]))

    # 无活流 → ok=False（端点如实告知，不谎称已插入）
    q.clear_all()
    r = asyncio.run(api_chat_inject("s-none", type("R", (), {"project_id": "p", "agent_id": "a", "content": "hi"})()))
    check("E-2 无活流 inject → ok=False", r.get("ok") is False, str(r))

    # 空内容 → 422
    try:
        asyncio.run(api_chat_inject("s-x", type("R", (), {"project_id": "p", "agent_id": "a", "content": "  "})()))
        check("E-3 空内容 inject → 422", False, "未抛错")
    except Exception as e:
        check("E-3 空内容 inject → 422",
              getattr(e, "status_code", None) == 422 or e.__class__.__name__ == "HTTPException", str(e))

    # 有活流 → ok=True 且入队 + 落库
    q.clear_all()
    q.begin_stream("s-live")
    cs._reset_cache() if hasattr(cs, "_reset_cache") else None
    r = asyncio.run(api_chat_inject("s-live", type("R", (), {
        "project_id": "p-a5", "agent_id": "a1", "content": "插入的消息内容"})()))
    check("E-4 活流 inject → ok=True", r.get("ok") is True, str(r))
    check("E-5 消息已入队（loop 下一轮可 drain）", q.pending("s-live") == 1, str(q.pending("s-live")))
    # 落库验证：从 DB 读回应含这条 user 消息
    from sidecar.storage.store import load_messages
    msgs = load_messages("p-a5", "s-live")
    check("E-6 ⛔ 消息已落库（不丢，刷新可见）",
          any(m.get("role") == "user" and m.get("content") == "插入的消息内容" for m in msgs),
          str([(m.get("role"), m.get("content")) for m in msgs][-3:]))
    q.end_stream("s-live")
    q.clear_all()


def main() -> None:
    queue_checks()
    asyncio.run(loop_checks())
    endpoint_checks()
    print(f"\n===== A5 专项: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("失败项:", FAILURES)
        sys.exit(1)


if __name__ == "__main__":
    main()
