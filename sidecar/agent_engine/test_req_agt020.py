# VetarAI - Local-first multi-agent orchestration application
# Copyright (C) 2026 zero11924065-dev
#
# This file is part of VetarAI.
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with VetarAI. If not, see <https://www.gnu.org/licenses/>.
"""REQ-AGT-020（0.4.28）委派写子会话消息 → A13 总线 session 事件 专项测试（直接跑）。

根因（0.4.27 实测）：子会话消息由 delegation.py 直写 DB（store.save_message 是纯存储、
无事件通知），A13 资源总线此前只有 workflow/project/plugin/knowledge/inference/agent
六类 → 前端 ChatPanel 不订阅也无从订阅，用户打开子会话看委派进度时视图不刷新，
只能切走再切回。

修法：app_events 增加 RESOURCE_SESSION；delegation.py 四处写子会话消息后
（任务书 user / 首轮 assistant / 追问 user / 追问 assistant）调
_notify_child_session_changed 发射变更（payload 带 session_id/message_role）。
⛔ 只在委派写路径发射，不挂全局 save_message（主聊天热路径防事件风暴）。

覆盖：
  S1 简单模式成功路径：缓冲区对账出 user+assistant 两条 session 事件，
     session_id==子会话、project_id 正确、seq 单调、字段齐全
  S2 在线订阅者实时收到（同 loop 队列直投，不靠缓冲补发），aclose 后无泄漏
  S3 追问路径（普通模式第一轮非 JSON）：四条事件，role 序 user/assistant/user/assistant
  S4 ⛔ 主热路径守卫：直接 store.save_message 不产生任何 session 事件
     （守护"不挂全局 save_message"，防事件风暴口径回归）

只输出 PASS/FAIL 摘要。退出码 0=全过，1=有失败。
（⛔ 勿裸跑全量：走 scripts/run_backend_tests.py 隔离 runner）
"""
from __future__ import annotations

import asyncio
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

PASS, FAIL = 0, 0
FAILURES: list[str] = []


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"PASS  {name}")
    else:
        FAIL += 1
        FAILURES.append(name)
        print(f"FAIL  {name}  {detail}")


def _setup_store(tag="agt020"):
    """隔离 store 到临时目录（与 test_checkpoint076 同一做法）。"""
    tmp = Path(tempfile.mkdtemp(prefix=f"{tag}_"))
    import sidecar.storage.store as store
    store.PROJECTS_ROOT = tmp
    store._GDB = tmp / "_global.db"
    pid = store.create_project(f"{tag} 测试项目", tmp / "work")
    main_id = store.add_agent_config(pid, "主 Agent", "main", model_name="qwen3.6:35b")
    return store, tmp, pid, main_id


class ScriptConn:
    """每次 chat_stream 按 scripts 顺序回吐一段文本（与 test_checkpoint076 同款）。"""
    def __init__(self, scripts):
        self.scripts = list(scripts)
        self.calls = 0

    async def chat_stream(self, model, messages, tools=None, images=None, **_kw):
        text = self.scripts[self.calls] if self.calls < len(self.scripts) else ""
        self.calls += 1
        yield {"content_delta": text}
        yield {"done": True, "counts": {"prompt_eval_count": 10, "eval_count": 8}}


async def _drain(gen, want: int, max_rounds: int = 30) -> list:
    """从在线订阅生成器收 want 条 resource_changed（忽略 _idle 等控制事件）。
    ⛔ max_rounds 兜底：_idle 心跳会让 __anext__ 持续有产出，不能只靠
    wait_for 超时退出（首版 _buffered 即因此挂死）。"""
    out: list = []
    for _ in range(max_rounds):
        if len(out) >= want:
            break
        try:
            item = await asyncio.wait_for(gen.__anext__(), timeout=1.0)
        except (asyncio.TimeoutError, StopAsyncIteration):
            break
        if item.get("event") == "resource_changed":
            out.append(item)
    return out


async def _buffered() -> list:
    """晚到订阅者对账：握手后同步补发缓冲区内全部事件（按 buffered_count 精确取，
    backlog 补发在 idle 循环之前，⛔ 不可用"等满 N 条"——_idle 心跳会喂着生成器
    永远等下去，本测试首版即因此挂死）。"""
    from sidecar.agent_engine import app_events as ae
    n = ae.buffered_count()
    gen = ae.subscribe(since_seq=0, idle_timeout=0.05)
    try:
        first = await gen.__anext__()
        assert first["event"] == "_subscribed", f"握手异常: {first}"
        out: list = []
        for _ in range(n):
            item = await gen.__anext__()          # backlog 同步补发，无等待
            if item.get("event") == "resource_changed":
                out.append(item)
        return out
    finally:
        await gen.aclose()


def _session_evs(events: list) -> list:
    return [e for e in events if (e.get("data") or {}).get("resource") == "session"]


async def main():
    from sidecar.agent_engine import app_events as ae
    from sidecar.agent_engine import delegation as D

    imgs = ["data:image/png;base64,QUJD"]

    # ---------- S1 简单模式成功路径：缓冲对账出 user+assistant 两条 ----------
    store, tmp, pid, main_id = _setup_store("agt020a")
    sub_id = store.add_agent_config(pid, "ocr专员", "sub", model_name="glm-ocr:latest")
    ae.clear_all()
    res = await D.run_delegated_task(
        pid, main_id, "sess-main", store.get_agent_config(pid, sub_id),
        "识别附图文字", "输出纯文字", sandbox_root=str(tmp / "work"),
        authorizer=None, max_rounds=10,
        connector=ScriptConn(["识别结果：ABC"]), images=imgs)
    check("S1a 委派本身成功", res.get("ok") is True, str(res)[:150])
    task_rec = store.get_agent_task(pid, res["task_id"])
    child_sid = task_rec.get("session_id") if task_rec else None
    evs = _session_evs(await _buffered())
    roles = [(e["data"]).get("message_role") for e in evs]
    check("S1b 缓冲里有 user+assistant 两条 session 事件",
          roles == ["user", "assistant"], f"roles={roles}")
    check("S1c 事件 session_id 全部指向子会话",
          bool(child_sid) and all((e["data"]).get("session_id") == child_sid for e in evs),
          f"child_sid={child_sid} sids={[ (e['data']).get('session_id') for e in evs]}")
    check("S1d payload 字段齐全（action=create / project_id 正确）",
          all((e["data"]).get("action") == "create"
              and (e["data"]).get("project_id") == pid for e in evs),
          str([e.get("data") for e in evs])[:200])
    seqs = [e.get("seq") for e in evs]
    check("S1e seq 单调递增", seqs == sorted(seqs) and len(set(seqs)) == len(seqs), str(seqs))

    # ---------- S2 在线订阅者实时收到（队列直投，不靠缓冲补发） ----------
    store2, tmp2, pid2, main2 = _setup_store("agt020b")
    sub2 = store2.add_agent_config(pid2, "ocr专员", "sub", model_name="glm-ocr:latest")
    ae.clear_all()
    gen = ae.subscribe(since_seq=0, idle_timeout=0.2)
    try:
        handshake = await gen.__anext__()
        check("S2a 订阅握手", handshake.get("event") == "_subscribed", str(handshake))
        check("S2b 订阅者已注册", ae.subscriber_count() == 1, str(ae.subscriber_count()))
        res2 = await D.run_delegated_task(
            pid2, main2, "sess-main", store2.get_agent_config(pid2, sub2),
            "识别附图文字", "输出纯文字", sandbox_root=str(tmp2 / "work"),
            authorizer=None, max_rounds=10,
            connector=ScriptConn(["识别结果：XYZ"]), images=imgs)
        check("S2c 委派本身成功", res2.get("ok") is True, str(res2)[:150])
        child2 = (store2.get_agent_task(pid2, res2["task_id"]) or {}).get("session_id")
        live = _session_evs(await _drain(gen, 2))
        check("S2d 在线订阅者实时收到 user+assistant 两条",
              [(e["data"]).get("message_role") for e in live] == ["user", "assistant"],
              str([e.get("data") for e in live])[:200])
        check("S2e 实时事件 session_id 指向子会话",
              bool(child2) and all((e["data"]).get("session_id") == child2 for e in live),
              f"child2={child2}")
    finally:
        await gen.aclose()
    check("S2f aclose 后订阅者注销无泄漏", ae.subscriber_count() == 0,
          str(ae.subscriber_count()))

    # ---------- S3 追问路径：四条事件，role 序 user/assistant/user/assistant ----------
    store3, tmp3, pid3, main3 = _setup_store("agt020c")
    sub3 = store3.add_agent_config(pid3, "文本专员", "sub", model_name="qwen3.6:35b")
    ae.clear_all()
    res3 = await D.run_delegated_task(
        pid3, main3, "sess-main", store3.get_agent_config(pid3, sub3),
        "写一段文字", "输出文字", sandbox_root=str(tmp3 / "work"),
        authorizer=None, max_rounds=10,
        connector=ScriptConn(["这是纯文字回复不是JSON",
                              '{"task_id":"x","status":"success","summary":"补交","artifacts":[]}']))
    check("S3a 追问后委派成功", res3.get("ok") is True, str(res3)[:150])
    evs3 = _session_evs(await _buffered())
    roles3 = [(e["data"]).get("message_role") for e in evs3]
    check("S3b 四条事件 role 序 user/assistant/user/assistant",
          roles3 == ["user", "assistant", "user", "assistant"], f"roles={roles3}")

    # ---------- S4 ⛔ 主热路径守卫：直接 save_message 不产生 session 事件 ----------
    ae.clear_all()
    store3.save_message(pid3, "sess-main", main3, "user", "主会话热路径消息")
    check("S4 直接 save_message（主聊天热路径）→ 总线零事件（不挂全局，防事件风暴）",
          ae.latest_seq() == 0 and ae.buffered_count() == 0,
          f"seq={ae.latest_seq()} buf={ae.buffered_count()}")

    # 清理
    import shutil
    for t in (tmp, tmp2, tmp3):
        shutil.rmtree(t, ignore_errors=True)

    print(f"\n===== 结果：{PASS} PASS / {FAIL} FAIL =====")
    if FAILURES:
        print("失败项：", "、".join(FAILURES))
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
