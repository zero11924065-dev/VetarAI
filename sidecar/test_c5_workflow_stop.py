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
"""第 3 批（0.4.16）C5 专项：工作流停止的**响应延迟**与收尾正确性。

═══ 核实纠正：文档记的根因是错的 ═══

原记录为「`task.cancel()` 只取消 asyncio Task，**httpx stream 未 aclose** → Ollama
服务端继续生成；**无模型 unload**」。实测核查后两条都不成立：
  ① 工作流走的是 `connector.chat`（**非流式** `client.post`），压根没有 stream 可 aclose；
  ② `_release_model()` 在 WorkflowCancel / CancelledError / Exception **三个分支都已调用**，
     模型卸载早已实现（`unload_model` 用 `keep_alive=0`）。

**真实残留问题只有一个**：`_interruptible_chat` 用 `asyncio.wait({task}, timeout=2.0)`
**每 2 秒轮询一次**取消标志 → 用户点停止最坏要等 2 秒才生效，期间模型仍在烧算力。
这就是用户感知的"停止不立即"。

═══ 修法 ═══

取消标志 Event 化（`_CANCEL_EVENTS` + `cancel_event()`），`_interruptible_chat` 同时
await 取消 Event → 点停止**立即**唤醒并 cancel 底层 task。实测延迟 **0.000s**（原最坏 2s）。
保留 `_CANCEL_FLAGS` 的 bool 语义不变，`is_workflow_cancelled` 等既有调用方零改动。

⛔ 三个易错点（都已在实现中处理，本测试逐一锁住）：
  1. waiter task 必须**循环外创建一次**：`asyncio.wait()` 在 Python 3.11+ 禁止传协程
     （实测 3.14.7 抛 TypeError），循环内每轮新建又会遗弃泄漏
  2. `cancel_event()` 懒建时必须**补置**已存在的 bool 标志——用户可能先点停止、
     引擎后才开始 await，否则 Event 化白做（仍要等下次轮询）
  3. `clear_workflow_cancel` 必须**连 Event 一起丢弃**：残留已置位的 Event 会让该
     run_id 的下一次运行一开始就被取消（与 C2 聊天侧"停止按钮永久生效"同类缺陷）

隔离：钉死 config.store.get_config_path 到临时目录（第 0 批纪律）。
"""
from __future__ import annotations

import asyncio
import sys
import tempfile
import time
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


_TMP = Path(tempfile.mkdtemp(prefix="c5_"))
import sidecar.config.store as cs          # noqa: E402
cs.get_config_path = lambda: _TMP / "config.json"

import sidecar.workflow.engine as eng_mod   # noqa: E402
from sidecar.workflow.engine import (       # noqa: E402
    WorkflowEngine, request_workflow_cancel, clear_workflow_cancel,
    is_workflow_cancelled, cancel_event,
)


def _defn(nodes, edges):
    return {"nodes": nodes, "edges": edges}


def _n(i, t, **kw):
    return {"id": i, "type": t, **kw}


SLOW_SECONDS = 5.0      # 模拟本地大模型一次推理耗时（prefill 长）
MAX_DELAY = 1.0         # 停止延迟上限（旧实现轮询间隔是 2.0s，故 1.0 能区分新旧）


class SlowConn:
    """慢连接器：第 2 次推理耗时 SLOW_SECONDS，给"停止"留出可测窗口。"""

    def __init__(self):
        self.calls = 0
        self.unloads: list[str] = []
        self.cancelled_at: float | None = None

    async def chat(self, model, messages, images=None, **kw):
        self.calls += 1
        if self.calls == 1:
            return "第一段"
        try:
            await asyncio.sleep(SLOW_SECONDS)
        except asyncio.CancelledError:
            self.cancelled_at = time.monotonic()
            raise
        return "不该到达"

    async def unload_model(self, model):
        self.unloads.append(model)
        return True


async def _run_and_stop(run_id: str) -> tuple[str, float | None, SlowConn]:
    """跑到第 2 个节点开始时点停止，返回 (终止事件, 取消延迟秒, 连接器)。"""
    conn = SlowConn()
    defn = _defn(
        [_n("s", "start"), _n("n1", "inference", model="m", prompt="a"),
         _n("n2", "inference", model="m", prompt="b"), _n("e", "end")],
        [{"from": "s", "to": "n1"}, {"from": "n1", "to": "n2"},
         {"from": "n2", "to": "e"}])
    engine = WorkflowEngine(run_id, defn, conn, tempfile.mkdtemp())

    stopped_at: list[float] = []
    final = ""

    async def consume():
        nonlocal final
        async for ev in engine.run():
            if ev["event"] == "node_done" and ev["data"].get("node_id") == "n1":
                await asyncio.sleep(0.05)          # 确保 n2 的推理已在飞
                stopped_at.append(time.monotonic())
                request_workflow_cancel(run_id)
            if ev["event"] in ("workflow_done", "workflow_failed", "workflow_stopped"):
                final = ev["event"]
                break

    await asyncio.wait_for(consume(), timeout=SLOW_SECONDS + 10)
    delay = (conn.cancelled_at - stopped_at[0]) if (conn.cancelled_at and stopped_at) else None
    return final, delay, conn


def main() -> None:
    asyncio.run(_async_checks())
    print(f"\n===== C5 专项: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("失败项:", FAILURES)
        sys.exit(1)


async def _async_checks() -> None:
    # ── ① 核心：停止延迟必须远小于旧实现的 2s 轮询间隔 ──
    final, delay, conn = await _run_and_stop("c5-delay")
    check("① 点停止后工作流走 workflow_stopped（非 done/failed）",
          final == "workflow_stopped", final)
    check(f"① ⛔ 停止延迟 < {MAX_DELAY}s（旧实现最坏 2s 轮询）",
          delay is not None and delay < MAX_DELAY,
          f"delay={delay}")
    check("① 底层在飞请求确实被取消（不是等它自己跑完）",
          conn.cancelled_at is not None and conn.calls == 2, str(conn.calls))
    check("① 停止后仍卸载驻留模型（_release_model 生效）",
          conn.unloads == ["m"], str(conn.unloads))
    clear_workflow_cancel("c5-delay")

    # ── ② 懒建补置：先点停止、引擎后才 await，仍须立即感知 ──
    clear_workflow_cancel("c5-early")
    request_workflow_cancel("c5-early")            # 用户手快：引擎还没开始等
    ev = cancel_event("c5-early")                  # 引擎随后才取 Event
    check("② 先取消后取 Event → Event 已置位（懒建补生效）", ev.is_set())
    check("② is_workflow_cancelled 同步为 True（bool 语义未变）",
          is_workflow_cancelled("c5-early") is True)
    clear_workflow_cancel("c5-early")

    # ── ③ 无残留：clear 后 Event 必须一并丢弃 ──
    request_workflow_cancel("c5-res")
    check("③ 前置：已置位", is_workflow_cancelled("c5-res") is True)
    clear_workflow_cancel("c5-res")
    check("③ clear 后 bool 标志清除", is_workflow_cancelled("c5-res") is False)
    fresh = cancel_event("c5-res")
    check("③ ⛔ clear 后重取 Event 是**未置位**的（否则下次运行一开始就被取消）",
          not fresh.is_set())
    clear_workflow_cancel("c5-res")

    # ── ④ 幂等与隔离：不同 run_id 互不干扰 ──
    request_workflow_cancel("c5-a")
    check("④ 取消 run A 不影响 run B",
          is_workflow_cancelled("c5-a") is True and is_workflow_cancelled("c5-b") is False)
    request_workflow_cancel("c5-a")                 # 重复取消不报错
    check("④ 重复取消幂等", is_workflow_cancelled("c5-a") is True)
    clear_workflow_cancel("c5-a")

    # ── ⑤ waiter 复用不泄漏：同一 run 连续两次运行 ──
    final2, delay2, _ = await _run_and_stop("c5-reuse")
    check("⑤ 同 run_id 二次运行仍能正常停止（无残留 Event 干扰）",
          final2 == "workflow_stopped" and delay2 is not None and delay2 < MAX_DELAY,
          f"{final2} delay={delay2}")
    clear_workflow_cancel("c5-reuse")

    # ── ⑥ 未取消的正常路径不受影响（Event 化不能拖慢正常执行）──
    conn_ok = SlowConn()
    conn_ok.calls = 1          # 让第二次也走快速路径
    class FastConn(SlowConn):
        async def chat(self, model, messages, images=None, **kw):
            self.calls += 1
            return f"段{self.calls}"
    fc = FastConn()
    defn = _defn(
        [_n("s", "start"), _n("n1", "inference", model="m", prompt="a"),
         _n("n2", "inference", model="m", prompt="b"), _n("e", "end")],
        [{"from": "s", "to": "n1"}, {"from": "n1", "to": "n2"},
         {"from": "n2", "to": "e"}])
    engine = WorkflowEngine("c5-normal", defn, fc, tempfile.mkdtemp())
    events = []
    async for ev in engine.run():
        events.append(ev["event"])
        if ev["event"] in ("workflow_done", "workflow_failed", "workflow_stopped"):
            break
    check("⑥ 未取消时正常跑完 workflow_done（Event 化不影响正常路径）",
          "workflow_done" in events, str(events))
    check("⑥ 正常路径两个推理节点都执行了", fc.calls == 2, str(fc.calls))
    clear_workflow_cancel("c5-normal")

    # ── ⑦ 实现层静态核查：不得退回 2s 轮询 ──
    src = (Path(__file__).resolve().parents[1] / "sidecar" / "workflow" / "engine.py").read_text(encoding="utf-8")
    check("⑦ _interruptible_chat 已 await 取消 Event（非纯轮询）",
          "asyncio.wait({task, cancel_waiter}" in src)
    check("⑦ waiter 在循环外创建（避免每轮遗弃泄漏）",
          src.count("cancel_waiter = asyncio.ensure_future(") == 1)
    # ⛔ 断言必须**先剥离注释再匹配代码**。本文件初版两次写错：
    #   v1 用裸子串 "timeout=2.0" not in src → 被自己写的历史说明注释误伤；
    #   v2 硬编码整条注释串做 replace 剥离 → 注释改一个字断言就失效，极脆。
    # 正解：用 tokenize 去掉全部注释与 docstring，只对**真实代码**断言。
    # ⛔ 用 AST 判定，而非文本/token 匹配。前两版都因文本匹配脆弱而误判：
    #   v1 裸子串被注释误伤；v2 tokenize 后 " ".join 使 "asyncio.wait" 变成
    #      "asyncio . wait" 匹配不上。AST 直接看语法结构，不受空格/注释影响。
    import ast as _ast
    tree = _ast.parse(src)
    # 找 _interruptible_chat 里的 asyncio.wait(...) 调用，收集其第一个参数（wait set）中的名字
    wait_names: set[str] = set()
    wait_has_timeout_2: bool = False
    for fn in _ast.walk(tree):
        if isinstance(fn, _ast.AsyncFunctionDef) and fn.name == "_interruptible_chat":
            for call in _ast.walk(fn):
                if (isinstance(call, _ast.Call)
                        and isinstance(call.func, _ast.Attribute)
                        and call.func.attr == "wait"):
                    # 第一个位置参数是 {task, cancel_waiter} 这样的集合字面量
                    if call.args:
                        first = call.args[0]
                        elts = first.elts if isinstance(first, (_ast.Set, _ast.List, _ast.Tuple)) else [first]
                        for e in elts:
                            if isinstance(e, _ast.Name):
                                wait_names.add(e.id)
                    for kw in call.keywords:
                        if kw.arg == "timeout" and isinstance(kw.value, _ast.Constant) \
                                and float(kw.value.value) == 2.0:
                            wait_has_timeout_2 = True
    check("⑦ _interruptible_chat 的 asyncio.wait 同时监听 task 与 cancel_waiter",
          {"task", "cancel_waiter"} <= wait_names, str(wait_names))
    check("⑦ 真实代码中 asyncio.wait 已无 timeout=2.0 轮询（注释里的历史说明不算）",
          wait_has_timeout_2 is False)
    check("⑦ docstring 不再把 2s 轮询描述成现状",
          "每 2 秒轮询取消标志，命中即取消" not in src)


if __name__ == "__main__":
    main()
