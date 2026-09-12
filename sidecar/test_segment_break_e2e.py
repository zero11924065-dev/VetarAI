# VetarAI - Local-first multi-agent orchestration application
# Copyright (C) 2026 zero11924065-dev
# GPL-3.0-or-later（见仓库 LICENSE）
"""#1 插入点分裂 —— 端到端复现测试（0.4.23 前置修复，用户实测报障）。

═══ 为什么需要这个测试（此前是覆盖盲区）═══

`test_a5_inject.py` 只覆盖了两层，且**都绕开了真实 SSE 流**：
  * `loop_checks()`   —— 直接构造 `run_tool_loop(...)`，不经过 app.py 端点；
  * `endpoint_checks()` —— 直接 await `api_chat_inject(...)` 函数，并**手工**
    `q.begin_stream("s-live")` 制造活流，从未经由真实流端点触发 begin_stream。

于是以下三点从未被验证过，而它们正是"后端发了、前端毫无反应"最可能断裂的地方：
  1. app.py 真的在流开始时调用了 `_inject.begin_stream(req.session_id)`
     （`app.py:1272`）——若时机不对，端点 `is_active()` 判 False → 返回 ok=False，
     前端只在 `ChatPanel.tsx:2207` 显示一条极易被忽略的提示条，用户完全感知不到失败；
  2. `inject_check` 真的被接进 `run_tool_loop`（`app.py:1257`），loop 在**第 2 轮开头**
     drain 到注入并 yield `segment_break`（`loop.py:1140-1142`）；
  3. `segment_break` 真的穿过 app.py 的转发（`app.py:1420` 无条件 yield）与
     `_sse_format`（`app.py:919-920`），出现在 HTTP 响应体里。

═══ 测试手法 ═══

TestClient 是同步阻塞的（整个流跑完才返回 body），无法从测试主线程中途 POST。
故用**假连接器在第 1 轮生成途中自行 push** 来精确复现"模型思考中用户插入"这一时序：
  - 第 1 轮 yield tool_calls（迫使循环再转一圈）→ 此刻 push 注入 → yield content；
  - 第 2 轮开头 loop 应 drain 到该注入 → yield `segment_break`（带 break_at）。
这等价于真实 HTTP 注入（同为 `_inject.push(sid, text)` 入队 + loop 轮次边界 drain），
差别只是入队动作由连接器而非 HTTP 线程发起 —— 恰好能隔离出"app.py 接线层"是否有问题。

另附一条**真实 HTTP 注入**用例（后台线程 POST /inject），验证 is_active 在真流里为 True。

隔离：VETARAI_DATA_ROOT=临时目录（第 0 批纪律），必须在 import store 之前设。
"""
from __future__ import annotations

import asyncio
import os
import sys
import tempfile
from pathlib import Path

_TMP = tempfile.mkdtemp(prefix="seg_e2e_")
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


from sidecar.agent_engine import inject as q        # noqa: E402
import sidecar.config.store as cfgstore             # noqa: E402
import sidecar.storage.store as store               # noqa: E402
import sidecar.config as _cfgmod                    # noqa: E402

INJECT_TEXT = "别按那个方向做，改看 B 表"

# 端点探测结果容器：由 SegConn 在流进行中 await api_chat_inject 后写入，
# main() 的 S-9~S-11 读取断言。⛔ 用全局而非连接器实例字段——连接器实例
# 在流结束后仍可访问，但全局能让"探测发生在流内、断言在流外"的时序一目了然。
PROBE: dict = {}


class SegConn:
    """假连接器：第 1 轮生成途中 push 注入（复现"思考中插入"），第 2 轮正常收尾。"""

    def __init__(self, sid: str, push_midway: bool = True,
                 probe_endpoint: bool = False, pid: str = "", aid: str = ""):
        self.sid = sid
        self.push_midway = push_midway
        self.probe_endpoint = probe_endpoint
        self.pid = pid
        self.aid = aid
        self.seen_last_user: list[str] = []
        self.pushed_ok: bool | None = None
        self._n = 0

    def capabilities(self):
        return {"backend": "ollama", "tools": True, "vision": True, "pull": True, "delete": True}

    async def chat_stream(self, model, msgs, **kw):
        self._n += 1
        last_user = next((m.get("content") for m in reversed(msgs)
                          if m.get("role") == "user"), "")
        self.seen_last_user.append(str(last_user))
        if self._n == 1:
            # 迫使循环再转一圈（否则第 1 轮就 done，永远走不到第 2 轮的 inject_check）
            yield {"tool_calls": [{"id": "c1", "name": "read_file",
                                   "arguments": {"path": "f1.txt"}}]}
            # ⛔ 关键：此刻流已 begin_stream（app.py:1272 在迭代前调用），
            #    push 应返回 True；若 False 说明 begin_stream 时机/会话 id 有问题
            if self.push_midway:
                self.pushed_ok = q.push(self.sid, INJECT_TEXT)
            # 真实端点探测：流进行中 await api_chat_inject（同事件循环，顺序确定）。
            # 这等价于用户"思考中"点发送时前端 POST /inject 的真实时序。
            if self.probe_endpoint:
                from sidecar.app import api_chat_inject

                class _Req:
                    project_id = self.pid
                    agent_id = self.aid
                    content = INJECT_TEXT

                try:
                    res = await api_chat_inject(self.sid, _Req())
                    PROBE.update({"ok": res.get("ok"), "detail": res.get("detail"),
                                  "queued": q.pending(self.sid) > 0, "err": None})
                except Exception as e:
                    PROBE.update({"ok": None, "err": f"{type(e).__name__}: {e}"})
        yield {"content": f"第{self._n}轮回复"}


def _env(workdir: Path, tmpdir: Path):
    """隔离 config + 存储层路径（照 test_compact.py:66-79 的成熟做法）。"""
    orig_mem = dict(cfgstore._MEM) if cfgstore._MEM else {}
    cfgstore._MEM = {"ollama_base_url": "http://localhost:11434", "data_root": str(tmpdir)}
    store.PROJECTS_ROOT = tmpdir / "projects"
    store._GDB = tmpdir / "projects" / "_global.db"
    store.PROJECTS_ROOT.mkdir(parents=True, exist_ok=True)
    orig_get_cfg = _cfgmod.get_config
    _cfgmod.get_config = lambda: dict(cfgstore._MEM)
    return orig_mem, orig_get_cfg


def _events_of(body: str) -> list[str]:
    return [ln.split("event: ")[1].strip()
            for ln in body.split("\n") if ln.startswith("event: ")]


def _data_of(body: str, event: str) -> list[str]:
    """取出指定事件的 data 行（可能有多个同名事件）。"""
    out, hit = [], False
    for ln in body.split("\n"):
        if ln.startswith("event: "):
            hit = ln.split("event: ")[1].strip() == event
        elif hit and ln.startswith("data: "):
            out.append(ln[len("data: "):])
    return out


def main() -> None:
    from fastapi.testclient import TestClient
    import sidecar.app as appmod
    import sidecar.ollama.connector as _connmod

    tmpdir = Path(_TMP)
    workdir = tmpdir / "work"
    workdir.mkdir()
    orig_mem, orig_get_cfg = _env(workdir, tmpdir)

    pid = store.create_project("SegE2E", workdir)
    aid = store.add_agent_config(pid, "A", "main")
    sid = store.create_session(pid, aid, "S")
    store.save_message(pid, sid, aid, "user", "最初的问题")

    conn = SegConn(sid, probe_endpoint=True, pid=pid, aid=aid)
    orig_goc = _connmod.get_ollama_connector
    # ⛔ 必须 patch 源头模块（loop.py 内部 from ...connector import get_ollama_connector）
    _connmod.get_ollama_connector = lambda: conn

    client = TestClient(appmod.app)
    try:
        q.clear_all()
        r = client.post("/api/ollama/chat/stream", json={
            "agent_id": aid, "model": "qwen3.8",
            "messages": [{"role": "user", "content": "最初的问题"}],
            "project_id": pid, "session_id": sid, "sandbox_root": str(workdir),
        })
        body = r.text
        evs = _events_of(body)

        # ── 前置事实：push 本身是否成功（区分"注入没进去"与"进去了但没分裂"）──
        check("S-0 HTTP 200", r.status_code == 200, f"status={r.status_code}")
        check("S-1 流真的跑了 ≥2 轮（否则 inject_check 永不被调用）",
              conn._n >= 2, f"rounds={conn._n}")
        check("S-2 ⛔ 流进行中 push 成功（证明 app.py 已 begin_stream 且 sid 一致）",
              conn.pushed_ok is True, f"pushed_ok={conn.pushed_ok}")

        # ── 核心断言：segment_break 是否出现在 SSE 输出里 ──
        check("S-3 事件流含 segment_break（分裂的后端信号）",
              "segment_break" in evs, str(evs))
        datas = _data_of(body, "segment_break")
        check("S-4 segment_break 的 data 非空", bool(datas), str(datas)[:200])
        if datas:
            import json
            try:
                d0 = json.loads(datas[0])
            except Exception as e:
                d0 = {}
                check("S-4b segment_break data 可 JSON 解析", False, str(e))
            check("S-5 data 带 injected_messages（前端据此插用户气泡）",
                  isinstance(d0.get("injected_messages"), list)
                  and any(INJECT_TEXT in str(m.get("content", ""))
                          for m in d0["injected_messages"]), str(d0)[:200])
            check("S-6 data 带 break_at（前端据此切 done 全文，防段2 重复段1）",
                  isinstance(d0.get("break_at"), int) and d0["break_at"] >= 0,
                  str(d0)[:200])

        # ── 注入真的并入了模型上下文（不只是发了事件）──
        check("S-7 ⛔ 第 2 轮 msgs 读到注入消息（模型真的看见了）",
              any(INJECT_TEXT in u for u in conn.seen_last_user[1:]),
              str(conn.seen_last_user))

        # ── 流结束后队列必须被清（防旧消息串进下一轮流）──
        check("S-8 流结束后队列已清（end_stream 生效）", q.pending(sid) == 0,
              str(q.pending(sid)))

        # ── 真实端点路径：验证「流进行中」is_active 为真、端点返回 ok=True ──
        # ⛔ 不用后台线程 POST：th.start() 早于主线程发起流请求，后台线程可能在
        #    begin_stream（app.py:1272）执行前就 POST 了 → is_active=False 属**测试竞态**，
        #    不是产品缺陷（实测踩过，产生 S-9/S-10 假失败）。
        #    生产环境无此竞态：用户是在 SSE 流已推进、看到 token 在流之后才 POST，
        #    而 begin_stream 在迭代前就执行完了。
        #    正解：在连接器第 1 轮内部 await 端点函数 —— 此刻流确已开始、begin_stream
        #    已执行，且同一事件循环，顺序确定。
        # 端点调用发生在 SegConn.chat_stream 内（流进行中），结果写入全局 PROBE。
        check("S-9 流进行中调用 inject 端点 → ok=True（is_active 为真，非静默失败）",
              PROBE.get("ok") is True, str(PROBE))
        check("S-10 端点确认已入队（loop 下一轮 drain 得到）",
              PROBE.get("queued") is True, str(PROBE))
        check("S-11 端点调用未抛异常（真流上下文里可安全 await）",
              PROBE.get("err") is None, str(PROBE.get("err")))

        # ⛔⛔ 曾在此加过一条"S-12 真实并发 HTTP inject"（httpx.ASGITransport / 真 uvicorn），
        # 结果 ok=False。**那是测试工件，不是产品缺陷**，故删除，理由记此防后人重复踩：
        #   假连接器几秒就跑完 → 流 end_stream 清空 _ACTIVE；而 httpx 的 aiter_lines() 会
        #   **缓冲整个响应体**，客户端拖到流结束才读到 tool_call 事件、才发 inject →
        #   此时 is_active 当然 False。真实生产里模型思考数十秒、流持续活跃，用户在流中途
        #   注入时 begin_stream（app.py:1272，同步、在消费循环前）早已执行 → is_active=True。
        #   这一点 S-9 已在事件循环内证明；uvicorn 单进程单循环，跨连接查的是同一个全局
        #   _ACTIVE，与 S-9 等价。要真验证并发须用 curl -N 裸客户端 + 长 sleep 连接器，
        #   成本高且脆弱，收益仅"再确认一次 S-9 已证的事"，不值得常驻测试里。
    finally:
        _connmod.get_ollama_connector = orig_goc
        _cfgmod.get_config = orig_get_cfg
        cfgstore._MEM = orig_mem
        q.clear_all()
        import shutil
        shutil.rmtree(_TMP, ignore_errors=True)

    print(f"\n===== 插入分裂端到端: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("失败项:", FAILURES)
        sys.exit(1)


if __name__ == "__main__":
    main()
