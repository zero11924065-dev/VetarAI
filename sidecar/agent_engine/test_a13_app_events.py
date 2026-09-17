# VetarAI - Local-first multi-agent orchestration application
# Copyright (C) 2026 zero11924065-dev
# GPL-3.0-or-later（见仓库 LICENSE）
"""A13（0.4.22）专项：应用级资源变更事件总线 + 全局 SSE 端点 + 写端点 notify 接线。

## 缺陷与修复

**缺陷（用户实测）**：Agent 改完工作流/项目等资源后，用户切回面板看到的还是旧数据，
**必须重启应用**才更新。根因：App.tsx 用 `display` 切换做保活（不卸载组件），各面板
`useEffect` 只在首次挂载拉一次；Agent 经 app_modules/registry.py 直接调 app.py 端点写库，
零事件通知前端。

**修复**：新增进程内总线 `app_events.py`（单一全局通道，资源变更跨项目）+ 全局 SSE 端点
`GET /api/events/stream` + 各资源写端点成功后 `_notify_change()`（端点级单点接入，
一处覆盖 Agent 与用户双路径）。

## 覆盖

- T1  多订阅者广播：两个订阅者都收到同一变更（⛔ 共享 Event 会丢唤醒，故用每订阅者 Queue）
- T2  晚到订阅者补发：缓冲区里 since_seq 之后的变更一次性补发
- T3  gap 断档检测：缓冲被挤掉后订阅者收到 gap 而非静默错乱
- T4  notify 异常安全：空 resource 返回 False 且不抛（总线是旁路，不得影响写库本身）
- T5  空闲产出 _idle（端点据此发 SSE 心跳注释行防代理断连）
- T6  订阅者断开（aclose）后注销，无泄漏
- T7  clear_all 通知全部订阅者结束（_bus_closed）并清空缓冲
- T8  SSE 端点：StreamingResponse + text/event-stream + 防缓冲头 + 首条 connected 握手
- T9  SSE 端点：_subscribed/_idle 不下发前端；notify 的 resource_changed 真实下发，
      payload 含 resource/action/project_id/seq（前端据此决定重拉哪个面板）
- T10 ⛔ 跨事件循环投递：另一 loop 上的订阅者必须被唤醒（撤 call_soon_threadsafe 即失败）
- T11 notify 接线（源码断言）：6 类资源的写端点体内都有 _notify_change 且 resource 正确
- T12 notify 接线（行为实测）：真调写端点后总线 seq 递增且事件字段正确
- T13 变异测试：三处关键修复被撤掉时必须失败（验证本测试真的有效）

运行：.venv/bin/python -m sidecar.agent_engine.test_a13_app_events
变异：MUTATE=1|2|3 .venv/bin/python -m sidecar.agent_engine.test_a13_app_events
（⛔ 勿裸跑：走 scripts/run_backend_tests.py 隔离 runner）
"""
from __future__ import annotations

import asyncio
import json
import os
import re
import sys
import tempfile
import threading
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from sidecar.agent_engine import app_events as ae

MUTATE = int(os.environ.get("MUTATE", "0"))
PASS, FAIL = 0, 0
FAILURES: list[str] = []
_BACKUP: dict[str, str] = {}


def check(name: str, cond: bool, detail: str = "") -> None:
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"PASS  {name}")
    else:
        FAIL += 1
        FAILURES.append(name)
        print(f"FAIL  {name}  {detail}")


async def _collect(agen, n: int, out: list) -> None:
    """消费异步生成器前 n 条**并关闭**（测注销/回收时用）。

    ⛔ 必须显式 aclose：异步生成器在 break 后**不会立即执行 finally**（要等 GC），
    不 aclose 就测不到订阅者注销——delegation_events 套件首轮即因此假失败。
    """
    i = 0
    try:
        async for e in agen:
            out.append(e)
            i += 1
            if i >= n:
                break
    finally:
        await agen.aclose()


async def _take(agen, n: int, out: list) -> None:
    """消费前 n 条但**不关闭**生成器（订阅者保持在线）。

    ⛔ 与 _collect 的区别：T1（多订阅者广播）、T7（clear_all 通知在线订阅者）都要求
    订阅者在取完握手后**仍注册**，用 _collect 会立即 aclose 注销 → subscriber_count 归零，
    断言变成假失败（本套件首轮即因此 T1a/T1b/T7a 三红）。用完必须自行 aclose。
    """
    i = 0
    async for e in agen:
        out.append(e)
        i += 1
        if i >= n:
            return


# ══════════════════ 一、事件总线单测 ══════════════════

async def t1_multi_subscriber_broadcast() -> None:
    """T1 多订阅者广播：⛔ 这是共享 Event/Condition 方案的回归点。"""
    ae.clear_all()
    a: list = []
    b: list = []
    g1 = ae.subscribe(since_seq=0, idle_timeout=0.2)
    g2 = ae.subscribe(since_seq=0, idle_timeout=0.2)
    try:
        # ⛔ 用 _take（不关闭）：两个订阅者取完握手后必须**仍在线**，才能验证一对多广播。
        # 首轮用 _collect 会立即 aclose 注销 → subscriber_count=0，断言假失败。
        await _take(g1, 1, a)
        await _take(g2, 1, b)
        check("T1a 两个订阅者都已注册", ae.subscriber_count() == 2, ae.subscriber_count())

        ae.notify(ae.RESOURCE_WORKFLOW, ae.ACTION_UPDATE, workflow_id="wf1")
        await _take(g1, 1, a)
        await _take(g2, 1, b)
        ok = (len(a) == 2 and len(b) == 2
              and a[1]["event"] == "resource_changed" == b[1]["event"]
              and a[1]["data"]["workflow_id"] == "wf1")
        check("T1b 两个订阅者都收到同一条变更（不丢唤醒）", ok, f"a={a} b={b}")
    finally:
        await g1.aclose()
        await g2.aclose()
    ae.clear_all()


async def t2_late_subscriber_backfill() -> None:
    """T2 晚到订阅者补发：面板中途连上也要能补齐缓冲区内错过的变更。"""
    ae.clear_all()
    ae.notify(ae.RESOURCE_PROJECT, ae.ACTION_CREATE, project_id="p1")
    ae.notify(ae.RESOURCE_PROJECT, ae.ACTION_DELETE, project_id="p2")
    ae.notify(ae.RESOURCE_PLUGIN, ae.ACTION_UPDATE, plugin_name="x")
    out: list = []
    # since_seq=1 → 只补发 seq 2、3
    await _collect(ae.subscribe(since_seq=1, idle_timeout=0.2), 3, out)
    evs = [e for e in out if e["event"] == "resource_changed"]
    seqs = [e["seq"] for e in evs]
    check("T2a 补发 seq>since_seq 的全部事件", seqs == [2, 3], seqs)
    check("T2b 补发内容正确（project delete + plugin update）",
          [e["data"]["resource"] for e in evs] == ["project", "plugin"], str(evs)[:200])
    ae.clear_all()


async def t3_gap_detection() -> None:
    """T3 gap 断档检测：缓冲被挤掉后必须发 gap（订阅者据此重拉，不拿半截状态渲染）。"""
    ae.clear_all()
    for i in range(ae._BUFFER_MAX + 10):        # 灌满并挤掉最旧
        ae.notify(ae.RESOURCE_KNOWLEDGE, ae.ACTION_UPDATE, n=i)
    out: list = []
    await _collect(ae.subscribe(since_seq=1, idle_timeout=0.2), 2, out)
    names = [e["event"] for e in out]
    check("T3a 断档时收到 gap 事件", "gap" in names, names)
    gap = next((e for e in out if e["event"] == "gap"), None)
    check("T3b gap 携带 from 与 oldest_available（供前端判断落后多少）",
          bool(gap) and gap["data"].get("from") == 1
          and isinstance(gap["data"].get("oldest_available"), int), str(gap)[:200])
    ae.clear_all()


async def t4_notify_exception_safety() -> None:
    """T4 notify 异常安全：⛔ 总线是旁路，任何非法入参都不得抛到写库主流程。"""
    ae.clear_all()
    r1 = ae.notify("", ae.ACTION_CREATE)          # 空 resource
    r2 = ae.notify(None, None)                    # 全 None
    r3 = ae.notify(ae.RESOURCE_WORKFLOW, "")      # 空 action（仍应入队，resource 才是必需）
    check("T4a 空 resource → False 且不抛", r1 is False, r1)
    check("T4b 全 None → False 且不抛", r2 is False, r2)
    check("T4c 合法 resource + 空 action → 仍投递（不抛）", r3 is True, r3)
    check("T4d 无订阅者时 notify 也返回 True（事件入缓冲供晚到者补发）",
          ae.latest_seq() >= 1 and ae.buffered_count() >= 1,
          f"seq={ae.latest_seq()} buf={ae.buffered_count()}")
    ae.clear_all()


async def t5_idle_heartbeat() -> None:
    """T5 空闲产出 _idle：端点据此发心跳注释行（防代理断连）。"""
    ae.clear_all()
    out: list = []
    await _collect(ae.subscribe(since_seq=0, idle_timeout=0.05), 2, out)
    names = [e["event"] for e in out]
    check("T5a 无事件时空闲超时产出 _idle", "_idle" in names, names)
    ae.clear_all()


async def t6_subscriber_cleanup() -> None:
    """T6 订阅者断开后注销：⛔ finally 必须摘掉队列，否则计数泄漏。"""
    ae.clear_all()
    out: list = []
    await _collect(ae.subscribe(since_seq=0, idle_timeout=0.2), 1, out)   # 取握手后 aclose
    check("T6a aclose 后订阅者计数归零（无泄漏）", ae.subscriber_count() == 0,
          ae.subscriber_count())
    ae.clear_all()


async def t7_clear_all_closes() -> None:
    """T7 clear_all 通知订阅者结束（不静默挂死）并清空缓冲。"""
    ae.clear_all()
    ae.notify(ae.RESOURCE_AGENT, ae.ACTION_CREATE)
    agen = ae.subscribe(since_seq=0, idle_timeout=0.2)
    out: list = []
    await _take(agen, 1, out)          # 握手；⛔ 不关闭，订阅者须在线才能收到 clear_all 通知
    ae.clear_all()
    rest: list = []
    # clear_all 后订阅者应收到 _bus_closed（或缓冲已空 → 直接结束）
    try:
        async for e in agen:
            rest.append(e)
            if e["event"] == "_bus_closed":
                break
    finally:
        await agen.aclose()
    check("T7a clear_all 后订阅者收到 _bus_closed", any(e["event"] == "_bus_closed" for e in rest),
          str(rest)[:200])
    check("T7b clear_all 清空缓冲与 seq", ae.buffered_count() == 0 and ae.latest_seq() == 0,
          f"buf={ae.buffered_count()} seq={ae.latest_seq()}")


async def t10_cross_loop_delivery() -> None:
    """T10 ⛔ 跨事件循环投递（_deliver 的回归点，delegation_events 实测踩过）。

    订阅者跑在**另一个线程的另一个 loop** 上，notify 从当前 loop 调用。
    跨 loop 直接 put_nowait **不报错但订阅者不被唤醒**（静默失败：SSE 卡死在心跳上，
    前端永远收不到）→ 必须 call_soon_threadsafe。撤掉该分支本用例即红。
    """
    ae.clear_all()
    got: list = []
    ready = threading.Event()
    done = threading.Event()

    def worker() -> None:
        async def run() -> None:
            agen = ae.subscribe(since_seq=0, idle_timeout=1.0)
            try:
                async for ev in agen:
                    if ev["event"] == "_subscribed":
                        ready.set()
                        continue
                    got.append(ev)
                    break
            finally:
                await agen.aclose()
            done.set()
        asyncio.run(run())

    t = threading.Thread(target=worker, daemon=True)
    t.start()
    ok_ready = ready.wait(timeout=8)
    check("T10a 另一 loop 上的订阅者已注册", ok_ready and ae.subscriber_count() >= 1,
          f"ready={ok_ready} subs={ae.subscriber_count()}")
    # 从当前 loop 投递 → 跨 loop
    ae.notify(ae.RESOURCE_PLUGIN, ae.ACTION_CREATE, plugin_name="cross")
    ok_done = done.wait(timeout=8)
    check("T10b 跨 loop 投递唤醒订阅者（撤 call_soon_threadsafe 即失败）",
          ok_done and bool(got) and got[0]["data"].get("resource") == "plugin",
          f"done={ok_done} got={str(got)[:160]}")
    t.join(timeout=3)
    ae.clear_all()


# ══════════════════ 二、SSE 端点实测 ══════════════════

async def t8_t9_endpoint() -> None:
    """T8/T9 端点级实测：⛔ 不用 TestClient.stream（会把套件挂死到超时）。

    原因同 delegation_events 套件：① TestClient.stream 把应用跑在独立线程的 loop 里，
    跨 loop 投递失败是静默的；② SSE 流永不结束，iter_lines 匹配不到目标事件就是死循环。
    ✅ 正确做法：同一 loop 里直接迭代 StreamingResponse.body_iterator + 每次取块加硬超时。
    """
    ae.clear_all()
    from sidecar import app as appmod

    resp = await appmod.api_stream_app_events(since=0)
    check("T8a 端点返回 StreamingResponse",
          resp.__class__.__name__ == "StreamingResponse", resp.__class__.__name__)
    check("T8b content-type 是 text/event-stream",
          resp.media_type == "text/event-stream", str(resp.media_type))
    check("T8c 带 no-cache 与 X-Accel-Buffering 头（防代理缓冲）",
          resp.headers.get("Cache-Control") == "no-cache"
          and resp.headers.get("X-Accel-Buffering") == "no", str(dict(resp.headers)))

    it = resp.body_iterator
    parsed: list[tuple[str, str]] = []
    raw_lines: list[str] = []

    async def pump(max_chunks: int = 40) -> None:
        cur_ev = None
        n = 0
        while n < max_chunks:
            try:
                chunk = await asyncio.wait_for(it.__anext__(), timeout=3.0)
            except (asyncio.TimeoutError, StopAsyncIteration):
                return
            n += 1
            text = chunk.decode("utf-8") if isinstance(chunk, bytes) else str(chunk)
            for line in text.split("\n"):
                raw_lines.append(line)
                if line.startswith("event: "):
                    cur_ev = line[7:].strip()
                elif line.startswith("data: ") and cur_ev:
                    parsed.append((cur_ev, line[6:]))
                    cur_ev = None

    # ── T8d 首条是 connected 握手（带当前 seq，前端据此初始化游标）──
    await pump(1)
    check("T8d 首条事件是 connected 握手",
          bool(parsed) and parsed[0][0] == "connected", str(parsed[:1]))
    if parsed:
        d = json.loads(parsed[0][1])
        check("T8e connected 携带 seq（int）", isinstance(d.get("seq"), int), str(d)[:200])

    # ── T9 notify 的变更真实下发，字段齐全 ──
    ae.notify(ae.RESOURCE_WORKFLOW, ae.ACTION_CREATE, project_id="p9", workflow_id="wf9")
    await pump(6)
    names = [e for e, _ in parsed]
    check("T9a resource_changed 真实下发到 SSE", "resource_changed" in names, str(names))
    check("T9b _subscribed 未下发给前端（内部控制事件）", "_subscribed" not in names, str(names))
    check("T9c _idle 未作为 event 下发（只转成心跳注释行）", "_idle" not in names, str(names))
    check("T9d SSE 行格式 `event: X` + `data: {json}`（与 tasks/stream 同协议，解析器零改动）",
          any(l.startswith("event: resource_changed") for l in raw_lines)
          and any(l.startswith("data: {") for l in raw_lines), str(raw_lines[:6]))
    if "resource_changed" in names:
        payload = json.loads(parsed[names.index("resource_changed")][1])
        check("T9e payload 含 resource/action（前端据此决定重拉哪个面板）",
              payload.get("resource") == "workflow" and payload.get("action") == "create",
              str(payload)[:200])
        check("T9f payload 含 seq 与业务字段（workflow_id/project_id）",
              isinstance(payload.get("seq"), int) and payload.get("workflow_id") == "wf9"
              and payload.get("project_id") == "p9", str(payload)[:200])

    try:
        await it.aclose()
    except Exception:
        pass
    check("T9g 客户端断开后订阅者注销（无幽灵连接）", ae.subscriber_count() == 0,
          ae.subscriber_count())
    ae.clear_all()


# ══════════════════ 三、notify 接线 ══════════════════

def t11_wiring_source_assertion() -> None:
    """T11 notify 接线（源码断言）：⛔ mock 必须复现端点输出，注释里的词不算数。

    做法：切出每个写端点的函数体，断言体内出现 `_notify_change(RESOURCE_X, ACTION_Y`
    的**实际调用形态**——docstring/注释里的中文说明不含这个精确形态，故不会被污染。
    """
    app_src = (Path(__file__).resolve().parents[1] / "app.py").read_text(encoding="utf-8")

    # (端点函数名, 期望的 resource 常量, 期望的 action 常量)
    CASES = [
        ("api_create_workflow", "RESOURCE_WORKFLOW", "ACTION_CREATE"),
        ("api_update_workflow", "RESOURCE_WORKFLOW", "ACTION_UPDATE"),
        ("api_delete_workflow", "RESOURCE_WORKFLOW", "ACTION_DELETE"),
        ("api_create_project", "RESOURCE_PROJECT", "ACTION_CREATE"),
        ("api_delete_project", "RESOURCE_PROJECT", "ACTION_DELETE"),
        ("api_rename_project", "RESOURCE_PROJECT", "ACTION_UPDATE"),
        ("api_add_independent_agent", "RESOURCE_AGENT", "ACTION_CREATE"),
        ("api_update_independent_agent", "RESOURCE_AGENT", "ACTION_UPDATE"),
        ("api_delete_independent_agent", "RESOURCE_AGENT", "ACTION_DELETE"),
        ("api_update_agent", "RESOURCE_AGENT", "ACTION_UPDATE"),
        ("api_plugin_install", "RESOURCE_PLUGIN", "ACTION_CREATE"),
        ("api_plugin_uninstall", "RESOURCE_PLUGIN", "ACTION_DELETE"),
        ("api_plugin_toggle", "RESOURCE_PLUGIN", "ACTION_UPDATE"),
        ("api_plugin_note_set", "RESOURCE_PLUGIN", "ACTION_UPDATE"),
        ("api_write_knowledge", "RESOURCE_KNOWLEDGE", "ACTION_UPDATE"),
        ("api_delete_knowledge", "RESOURCE_KNOWLEDGE", "ACTION_DELETE"),
        ("api_toggle_knowledge", "RESOURCE_KNOWLEDGE", "ACTION_UPDATE"),
        ("api_write_memory", "RESOURCE_KNOWLEDGE", "ACTION_UPDATE"),
        ("api_update_config", "RESOURCE_INFERENCE", "ACTION_UPDATE"),
    ]
    missing = []
    for fn, res, act in CASES:
        m = re.search(rf"async def {fn}\(", app_src)
        if not m:
            missing.append(f"{fn}(未找到端点)")
            continue
        # 函数体 = 从 def 到下一个顶层 @app. 装饰器
        seg = app_src[m.start():].split("\n@app.")[0]
        if f"_notify_change({res}, {act}" not in seg:
            missing.append(f"{fn}(缺 {res}/{act})")
    check(f"T11a 19 个资源写端点体内都有 _notify_change 实际调用（缺：{missing}）",
          not missing, str(missing))

    # ⛔ 关键：Agent 写工作流走的 registry handler 必须调到这些端点（否则 notify 覆盖不到 Agent 路径）
    reg_src = (Path(__file__).resolve().parents[1] / "app_modules" / "registry.py").read_text(
        encoding="utf-8")
    wired = all(f"_app.{fn}" in reg_src for fn in
                ("api_create_workflow", "api_update_workflow", "api_delete_workflow"))
    check("T11b Agent 的 workflow 写 handler 调的正是带 notify 的 app 端点（双路径同覆盖）",
          wired, "registry.py 未调 _app.api_*_workflow")

    # ⛔ 端点必须存在且 media_type 正确（源码层面确认路由已注册）
    check("T11c 全局 SSE 路由 /api/events/stream 已注册",
          '@app.get("/api/events/stream")' in app_src)


async def t12_wiring_behavior() -> None:
    """T12 notify 接线（行为实测）：真调写端点 → 总线 seq 递增且事件字段正确。

    ⛔ 钉死数据目录到临时目录（项目铁律：禁止污染真实 ~/.subagent）。
    """
    TMP = Path(tempfile.mkdtemp(prefix="a13_"))
    import sidecar.storage.store as store
    store.PROJECTS_ROOT = TMP
    store._GDB = TMP / "_global.db"
    ae.clear_all()
    from sidecar import app as appmod

    seq0 = ae.latest_seq()
    req = appmod.ProjectCreateReq(name="a13-proj", working_dir=str(TMP / "wd"))
    out = await appmod.api_create_project(req)
    seq1 = ae.latest_seq()
    check("T12a 真调写端点后总线 seq 递增（notify 已接线）", seq1 == seq0 + 1,
          f"{seq0} → {seq1}")
    # 缓冲里最后一条应是 project/create，且带上新建的 project_id
    evs = [e for e in list(ae._BUS.buf) if e["event"] == "resource_changed"]
    last = evs[-1]["data"] if evs else {}
    check("T12b 事件 resource=project action=create 且带 project_id",
          last.get("resource") == "project" and last.get("action") == "create"
          and last.get("project_id") == out.get("project_id"), str(last)[:200])
    ae.clear_all()


# ══════════════════ 四、变异测试 ══════════════════

def _read_src(mod) -> str:
    return Path(mod.__file__).read_text(encoding="utf-8")


def _apply_mutation() -> None:
    """⛔ 锚点未命中必须 assert 报错，否则"变异没抓到"是假象（0.4.18 踩过）。"""
    if not MUTATE:
        return
    from sidecar import app as appmod
    _BACKUP["ae"] = _read_src(ae)
    _BACKUP["app"] = _read_src(appmod)
    if MUTATE == 1:
        # 撤掉跨 loop 安全投递（else 分支改为 pass）→ T10 红
        # 投递实现 0.4.26 起收敛进共享模块 _bus_common._deliver（a133496），
        # app_events 经 from-import 复用，故变异打在共享模块上（对本总线同样生效），
        # 且 main() 里须先 reload _bus_common 再 reload ae，否则 ae 仍绑定旧函数对象。
        from sidecar.agent_engine import _bus_common as bc
        _BACKUP["bc"] = _read_src(bc)
        s = _BACKUP["bc"]
        old = ("    else:\n        try:\n            loop.call_soon_threadsafe(_put)\n"
               "        except RuntimeError:\n            pass")
        patched = s.replace(old, "    else:\n        pass  # MUTATE1")
        assert patched != s, "变异 1 未命中 _bus_common 源码，测试无效"
        Path(bc.__file__).write_text(patched, encoding="utf-8")
    elif MUTATE == 2:
        # 撤掉 workflow create 端点的 notify → T11a 红
        s = _BACKUP["app"]
        old = "    _notify_change(RESOURCE_WORKFLOW, ACTION_CREATE, workflow_id=wf_id)   # A13"
        patched = s.replace(old, "    pass  # MUTATE2")
        assert patched != s, "变异 2 未命中 app.py 源码，测试无效"
        Path(appmod.__file__).write_text(patched, encoding="utf-8")
    elif MUTATE == 3:
        # 撤掉 gap 断档检测 → T3 红（订阅者拿半截状态渲染而不被告知）
        s = _BACKUP["ae"]
        old = 'if since_seq > 0 and backlog and backlog[0]["seq"] > since_seq + 1:'
        patched = s.replace(old, "if False:  # MUTATE3")
        assert patched != s, "变异 3 未命中 app_events 源码，测试无效"
        Path(ae.__file__).write_text(patched, encoding="utf-8")
    else:
        raise SystemExit(f"未知变异编号 {MUTATE}（支持 1|2|3）")


def _restore() -> None:
    if not MUTATE or not _BACKUP:
        return
    from sidecar import app as appmod
    try:
        if "ae" in _BACKUP and _read_src(ae) != _BACKUP["ae"]:
            Path(ae.__file__).write_text(_BACKUP["ae"], encoding="utf-8")
        if "app" in _BACKUP and _read_src(appmod) != _BACKUP["app"]:
            Path(appmod.__file__).write_text(_BACKUP["app"], encoding="utf-8")
        if "bc" in _BACKUP:
            from sidecar.agent_engine import _bus_common as bc
            if _read_src(bc) != _BACKUP["bc"]:
                Path(bc.__file__).write_text(_BACKUP["bc"], encoding="utf-8")
    finally:
        _BACKUP.clear()


async def _run_async_suite() -> None:
    await t1_multi_subscriber_broadcast()
    await t2_late_subscriber_backfill()
    await t3_gap_detection()
    await t4_notify_exception_safety()
    await t5_idle_heartbeat()
    await t6_subscriber_cleanup()
    await t7_clear_all_closes()
    await t10_cross_loop_delivery()
    await t8_t9_endpoint()
    await t12_wiring_behavior()


def main() -> int:
    print(f"A13 应用级实时刷新测试  |  变异模式 = {MUTATE}")
    _apply_mutation()
    if MUTATE:
        import importlib
        # 先共享模块再 ae：变异 1 打在 _bus_common，ae 须后 reload 才能重新绑定 _deliver
        from sidecar.agent_engine import _bus_common as bc
        importlib.reload(bc)
        importlib.reload(ae)
    try:
        asyncio.run(_run_async_suite())
        t11_wiring_source_assertion()
    finally:
        _restore()
        if MUTATE:
            import importlib
            from sidecar.agent_engine import _bus_common as bc
            importlib.reload(bc)
            importlib.reload(ae)
        ae.clear_all()

    print("\n" + "=" * 72)
    print(f"结果：{PASS} 通过 / {FAIL} 失败")
    if FAILURES:
        print("失败项：" + "；".join(FAILURES))
    if MUTATE and FAIL == 0:
        print(f"⛔ 变异 {MUTATE} 未被抓住 —— 本测试对该修复无效，断言需加强")
    print("=" * 72)
    return 1 if FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main())
