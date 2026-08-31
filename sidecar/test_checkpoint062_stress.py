#!/usr/bin/env python3
"""checkpoint-062 压力测试：长时间运行稳定性 + 多会话并发。

全程隔离：临时数据目录 + 独立端口 + 模拟 Ollama（不占真实模型、不碰真实数据）。

场景：
  A. 多会话并发聊天（8 路并行 SSE）——无 500 / 无 database is locked / 全部 done
  B. 读写混合风暴（聊天 + CRUD + 配置读写 50 操作并行）——无 500
  C. 故障注入（模型 500 / 流中途断开）——结构化错误不挂死，故障后服务自愈
  D. 独立 Agent 命名空间风暴（并发增删 + 聊天）——无残留无 500
  E. 长时间持续负载（3 分钟混合流量）+ 内存/连接采样——无泄漏无锁死

用法：.venv/bin/python3 test_checkpoint062_stress.py
"""
import asyncio
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

TMP = Path(tempfile.mkdtemp(prefix="ck062_stress_"))
os.environ["SUBAGENT_NO_FILE_LOG"] = "1"

import sidecar.config.store as cs
cs.DEFAULT_CONFIG["data_root"] = str(TMP)  # 必须在 sidecar.app 导入前

MOCK_PORT = 11499
SIDE_PORT = 8799
MOCK_URL = f"http://127.0.0.1:{MOCK_PORT}"
SIDE_URL = f"http://127.0.0.1:{SIDE_PORT}"
MODEL = "stress-model:latest"

PASS, FAIL = 0, 0
FAILURES = []


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"PASS  {name}")
    else:
        FAIL += 1
        FAILURES.append(f"{name} :: {detail}")
        print(f"FAIL  {name}  {detail}")


# ══════════════ 模拟 Ollama ══════════════
_fault_mode = {"mode": "none"}  # none / http500 / disconnect


def build_mock_app():
    from starlette.applications import Starlette
    from starlette.responses import JSONResponse
    from starlette.routing import Route

    async def api_tags(request):
        return JSONResponse({"models": [{"name": MODEL, "size": 1000}]})

    async def api_chat(request):
        mode = _fault_mode["mode"]
        if mode == "http500":
            return JSONResponse({"error": "stress: injected 500"}, status_code=500)
        body = await request.json()
        stream = body.get("stream", False)
        reply = "压力测试应答：一切正常。"

        if not stream:
            return JSONResponse({"message": {"role": "assistant", "content": reply},
                                 "done": True, "prompt_eval_count": 10, "eval_count": 5})

        from starlette.responses import StreamingResponse

        async def gen():
            if mode == "disconnect":
                # 吐两个 token 后中断连接（模拟模型进程崩溃/网络断流）
                for i in range(2):
                    yield json.dumps({"message": {"role": "assistant", "content": f"半截{i}"}}) + "\n"
                raise RuntimeError("stress: injected mid-stream disconnect")
            for i in range(6):
                yield json.dumps({"message": {"role": "assistant", "content": f"token{i} "}}) + "\n"
                await asyncio.sleep(0.02)  # 模拟生成间隙
            yield json.dumps({"done": True, "prompt_eval_count": 10, "eval_count": 6}) + "\n"

        return StreamingResponse(gen(), media_type="application/x-ndjson")

    async def set_fault(request):
        body = await request.json()
        _fault_mode["mode"] = body.get("mode", "none")
        return JSONResponse({"mode": _fault_mode["mode"]})

    return Starlette(routes=[
        Route("/api/tags", api_tags),
        Route("/api/chat", api_chat, methods=["POST"]),
        Route("/__fault", set_fault, methods=["POST"]),
    ])


def start_uvicorn_thread(app, port):
    import uvicorn
    config = uvicorn.Config(app, host="127.0.0.1", port=port, log_level="error")
    server = uvicorn.Server(config)
    t = threading.Thread(target=server.run, daemon=True)
    t.start()
    return server


async def wait_port(url, timeout=15):
    import httpx
    async with httpx.AsyncClient() as c:
        end = time.time() + timeout
        while time.time() < end:
            try:
                r = await c.get(url)
                if r.status_code < 500:
                    return True
            except Exception:
                pass
            await asyncio.sleep(0.2)
    return False


# ══════════════ 客户端工具 ══════════════
async def sse_chat(client, project_id, agent_id, session_id, timeout=60):
    """发起一次流式聊天，返回 (ok, events, error)。"""
    events, error = [], None
    try:
        async with client.stream("POST", f"{SIDE_URL}/api/ollama/chat/stream", json={
            "agent_id": agent_id, "model": MODEL, "project_id": project_id,
            "session_id": session_id,
            "messages": [{"role": "user", "content": f"压测消息 {time.time():.3f}"}],
        }, timeout=timeout) as r:
            if r.status_code != 200:
                return False, [], f"HTTP {r.status_code}: {(await r.aread()).decode()[:200]}"
            buf = ""
            async for chunk in r.aiter_text():
                buf += chunk
                while "\n\n" in buf:
                    raw, buf = buf.split("\n\n", 1)
                    for line in raw.splitlines():
                        if line.startswith("event:"):
                            events.append(line[6:].strip())
                        elif line.startswith("data:"):
                            try:
                                d = json.loads(line[5:].strip())
                                if isinstance(d, dict) and "detail" in d:
                                    error = d["detail"]
                            except Exception:
                                pass
    except Exception as e:
        error = str(e)
    return ("done" in events), events, error


async def setup_world(client):
    """建项目/主 Agent/会话。返回 (pid, aid, sid)。"""
    wd = TMP / "workdir"
    r = await client.post(f"{SIDE_URL}/api/projects", json={"name": "压测项目", "working_dir": str(wd)})
    pid = r.json()["project_id"]
    r = await client.post(f"{SIDE_URL}/api/agents", json={"project_id": pid, "name": "压测主Agent", "type_": "main", "model_name": MODEL})
    aid = r.json()["agent_id"]
    r = await client.post(f"{SIDE_URL}/api/sessions", json={"project_id": pid, "agent_id": aid, "title": "压测会话"})
    sid = r.json()["session_id"]
    return pid, aid, sid


# ══════════════ 场景 ══════════════
async def scenario_a_concurrent(client, pid, aid):
    print("\n── 场景 A：8 路并发会话聊天 ──")
    # 每路独立会话
    sids = []
    for i in range(8):
        r = await client.post(f"{SIDE_URL}/api/sessions", json={"project_id": pid, "agent_id": aid, "title": f"并发{i}"})
        sids.append(r.json()["session_id"])
    t0 = time.time()
    results = await asyncio.gather(*[sse_chat(client, pid, aid, sid) for sid in sids])
    dt = time.time() - t0
    oks = [r[0] for r in results]
    errs = [r[2] for r in results if r[2]]
    check("A1 8 路并发全部收到 done", all(oks), f"oks={oks} errs={errs[:3]}")
    locked = [e for e in errs if e and "locked" in e.lower()]
    check("A2 无 database is locked", not locked, str(locked[:2]))
    check("A3 8 路并发总耗时合理（<60s）", dt < 60, f"{dt:.1f}s")
    print(f"    （8 路并发完成，总耗时 {dt:.1f}s，平均 {dt/8:.2f}s/路）")


async def scenario_b_mixed_storm(client, pid, aid, sid):
    print("\n── 场景 B：读写混合风暴（50 操作并行）──")
    ops = []

    async def op_chat():
        ok, ev, err = await sse_chat(client, pid, aid, sid)
        return "chat", ok, err

    async def op_agent_crud(i):
        try:
            r = await client.post(f"{SIDE_URL}/api/agents", json={"project_id": pid, "name": f"风暴{i}", "type_": "sub"})
            if r.status_code != 200:
                return "agent-create", False, f"HTTP {r.status_code}"
            new_aid = r.json()["agent_id"]
            r2 = await client.delete(f"{SIDE_URL}/api/agents/{pid}/{new_aid}")
            return "agent-crud", r2.status_code == 200, ""
        except Exception as e:
            return "agent-crud", False, str(e)

    async def op_session_crud(i):
        try:
            r = await client.post(f"{SIDE_URL}/api/sessions", json={"project_id": pid, "agent_id": aid, "title": f"风暴会话{i}"})
            if r.status_code != 200:
                return "session-create", False, f"HTTP {r.status_code}"
            new_sid = r.json()["session_id"]
            r2 = await client.delete(f"{SIDE_URL}/api/sessions/{new_sid}?project_id={pid}")
            return "session-crud", r2.status_code == 200, ""
        except Exception as e:
            return "session-crud", False, str(e)

    async def op_config(i):
        try:
            r = await client.get(f"{SIDE_URL}/api/config")
            if r.status_code != 200:
                return "config-get", False, f"HTTP {r.status_code}"
            return "config-get", True, ""
        except Exception as e:
            return "config-get", False, str(e)

    async def op_messages():
        try:
            r = await client.get(f"{SIDE_URL}/api/sessions/{sid}/messages?project_id={pid}")
            return "messages", r.status_code == 200, ""
        except Exception as e:
            return "messages", False, str(e)

    for i in range(5):
        ops.append(op_chat())
        ops.append(op_agent_crud(i))
        ops.append(op_session_crud(i))
    for i in range(10):
        ops.append(op_config(i))
        ops.append(op_messages())

    results = await asyncio.gather(*ops)
    bad = [(name, err) for name, ok, err in results if not ok]
    check("B1 50 个混合操作无失败", not bad, str(bad[:5]))
    locked = [(n, e) for n, e in bad if "locked" in (e or "").lower()]
    check("B2 混合风暴无 database is locked", not locked, str(locked[:2]))


async def scenario_c_fault_injection(client, pid, aid):
    print("\n── 场景 C：故障注入与自愈 ──")
    import httpx

    # C1：模型 500
    async with httpx.AsyncClient() as mc:
        await mc.post(f"{MOCK_URL}/__fault", json={"mode": "http500"})
    sid = (await client.post(f"{SIDE_URL}/api/sessions", json={"project_id": pid, "agent_id": aid, "title": "故障会话"})).json()["session_id"]
    ok, ev, err = await sse_chat(client, pid, aid, sid)
    check("C1 模型 500 → 结构化错误事件（不裸挂）", (not ok) and ("error" in ev), f"ok={ok} events={ev} err={err}")

    # C2：流中途断开
    async with httpx.AsyncClient() as mc:
        await mc.post(f"{MOCK_URL}/__fault", json={"mode": "disconnect"})
    sid2 = (await client.post(f"{SIDE_URL}/api/sessions", json={"project_id": pid, "agent_id": aid, "title": "断流会话"})).json()["session_id"]
    t0 = time.time()
    ok2, ev2, err2 = await sse_chat(client, pid, aid, sid2, timeout=30)
    dt = time.time() - t0
    check("C2 流断开 → 30s 内给出终态（不无限挂起）", dt < 30, f"耗时 {dt:.1f}s ok={ok2} err={err2}")

    # C3：故障恢复后服务自愈
    async with httpx.AsyncClient() as mc:
        await mc.post(f"{MOCK_URL}/__fault", json={"mode": "none"})
    sid3 = (await client.post(f"{SIDE_URL}/api/sessions", json={"project_id": pid, "agent_id": aid, "title": "自愈会话"})).json()["session_id"]
    ok3, ev3, err3 = await sse_chat(client, pid, aid, sid3)
    check("C3 故障清除后正常请求成功（自愈）", ok3, f"err={err3}")


async def scenario_d_independent_storm(client):
    print("\n── 场景 D：独立 Agent 命名空间风暴 ──")

    async def one_round(i):
        try:
            r = await client.post(f"{SIDE_URL}/api/independent-agents", json={"name": f"风暴独立{i}", "model_name": MODEL})
            if r.status_code != 200:
                return False, f"create HTTP {r.status_code}"
            aid = r.json()["agent_id"]
            ns = f"ia-{aid}"
            ok, ev, err = await sse_chat(client, ns, aid, f"ind-session-{i}", timeout=30)
            if not ok:
                return False, f"chat err={err} events={ev}"
            r2 = await client.delete(f"{SIDE_URL}/api/independent-agents/{aid}")
            return r2.status_code == 200, "" if r2.status_code == 200 else f"delete HTTP {r2.status_code}"
        except Exception as e:
            return False, str(e)

    results = await asyncio.gather(*[one_round(i) for i in range(10)])
    bad = [(i, e) for i, (ok, e) in enumerate(results) if not ok]
    check("D1 10 轮独立 Agent 建→聊→删并发全部成功", not bad, str(bad[:3]))

    # D2：删除后聊天必须被拒（幽灵防线）
    r = await client.post(f"{SIDE_URL}/api/independent-agents", json={"name": "幽灵探针", "model_name": MODEL})
    aid = r.json()["agent_id"]
    await client.delete(f"{SIDE_URL}/api/independent-agents/{aid}")
    ok, ev, err = await sse_chat(client, f"ia-{aid}", aid, "ghost-session")
    check("D2 已删除独立 Agent 聊天被拒（不复活）", (not ok) and err and ("422" in err or "404" in err), f"ok={ok} err={err}")
    ghost_dir = Path(cs.projects_root()) / f"ia-{aid}"
    check("D3 拒绝后未重建数据目录", not ghost_dir.exists(), str(ghost_dir))


async def scenario_e_soak(client, pid, aid, sidecar_pid):
    print("\n── 场景 E：3 分钟持续负载 + 泄漏采样 ──")
    stop = {"flag": False}
    errors = []
    chats_done = {"n": 0}

    async def worker(i):
        sid = (await client.post(f"{SIDE_URL}/api/sessions", json={"project_id": pid, "agent_id": aid, "title": f"浸泡{i}"})).json()["session_id"]
        while not stop["flag"]:
            ok, ev, err = await sse_chat(client, pid, aid, sid, timeout=30)
            if ok:
                chats_done["n"] += 1
            else:
                errors.append(err or str(ev))
            await asyncio.sleep(0.5)

    def sample():
        try:
            out = subprocess.check_output(["ps", "-o", "rss=", "-p", str(sidecar_pid)]).decode().strip()
            return int(out)
        except Exception:
            return None

    mem_samples = []
    lock_errors = []

    async def probe_db():
        # 周期性用独立只读连接查库，检验锁竞争
        try:
            from sidecar.storage.store import list_projects
            list_projects()
        except Exception as e:
            lock_errors.append(str(e))

    async def sampler():
        while not stop["flag"]:
            m = sample()
            if m:
                mem_samples.append(m)
            await probe_db()
            await asyncio.sleep(5)

    tasks = [asyncio.create_task(worker(0)), asyncio.create_task(worker(1)), asyncio.create_task(sampler())]
    await asyncio.sleep(180)
    stop["flag"] = True
    await asyncio.gather(*tasks)

    locked = [e for e in errors + lock_errors if "locked" in e.lower()]
    check("E1 浸泡期无 database is locked", not locked, str(locked[:2]))
    check("E2 浸泡期聊天错误率可接受（<5%）", chats_done["n"] > 0 and len(errors) <= max(1, chats_done["n"] * 0.05),
          f"成功={chats_done['n']} 错误={len(errors)} 样例={errors[:3]}")
    if len(mem_samples) >= 4:
        first_half = mem_samples[:len(mem_samples)//2]
        second_half = mem_samples[len(mem_samples)//2:]
        avg1, avg2 = sum(first_half)/len(first_half), sum(second_half)/len(second_half)
        growth_mb = (avg2 - avg1) / 1024
        check("E3 内存增长趋势可接受（后半段均值增幅 <50MB）", growth_mb < 50,
              f"前半 {avg1/1024:.1f}MB → 后半 {avg2/1024:.1f}MB（+{growth_mb:.1f}MB）")
        print(f"    （内存采样：{[f'{m/1024:.0f}MB' for m in mem_samples]}）")
    else:
        check("E3 内存采样足够", False, f"仅 {len(mem_samples)} 个样本")
    print(f"    （3 分钟完成 {chats_done['n']} 次对话，错误 {len(errors)} 次）")


# ══════════════ 主流程 ══════════════
async def main():
    import httpx

    # 1. 启动模拟 Ollama
    print(f"[1] 启动模拟 Ollama（端口 {MOCK_PORT}）...")
    start_uvicorn_thread(build_mock_app(), MOCK_PORT)
    if not await wait_port(f"{MOCK_URL}/api/tags"):
        print("FATAL: 模拟 Ollama 启动失败")
        sys.exit(1)

    # 2. 启动隔离侧车
    print(f"[2] 启动隔离侧车（端口 {SIDE_PORT}，数据目录 {TMP}）...")
    import sidecar.app as appmod
    from sidecar.config import reload_config
    reload_config({"sidecar_port": SIDE_PORT, "ollama_base_url": MOCK_URL})
    start_uvicorn_thread(appmod.app, SIDE_PORT)
    if not await wait_port(f"{SIDE_URL}/api/projects"):
        print("FATAL: 隔离侧车启动失败")
        sys.exit(1)

    # 找到侧车服务线程里的实际进程（同进程）
    sidecar_pid = os.getpid()

    async with httpx.AsyncClient() as client:
        pid, aid, sid = await setup_world(client)
        await scenario_a_concurrent(client, pid, aid)
        await scenario_b_mixed_storm(client, pid, aid, sid)
        await scenario_c_fault_injection(client, pid, aid)
        await scenario_d_independent_storm(client)
        await scenario_e_soak(client, pid, aid, sidecar_pid)

    print(f"\n===== checkpoint-062 压力测试: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("FAILED:")
        for f in FAILURES:
            print(" -", f)
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
