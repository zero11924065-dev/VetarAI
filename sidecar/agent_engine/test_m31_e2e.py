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
"""TS-107 M3-1 审核实测：主-子委派端到端（真实 Ollama）。

混合策略（确定性 + 真实性）：
- 主 Agent 的"决定委派"用 mock（固定两轮：第一轮发 delegate_task，第二轮整合收尾）
- 子 Agent 走【真实 qwen3.8】：真实读任务书 → 真实调 write_file → 真实交卷
- delegation_ctx["connector"]=None → 子任务经 get_ollama_connector() 拿连接器，
  本脚本把单例替换为 HybridConn（按消息内容区分主/子会话，子会话代理到真实连接器）

前置：Ollama 在线且 qwen3.8 已加载（/api/ps 可见）。
数据：PROJECTS_ROOT 重定向临时目录，不碰 ~/.subagent 真实数据。
注意：本测试耗时较长（真实推理），不纳入自动回归基线。
"""
import asyncio
import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

PASS, FAIL = 0, 0
FAILURES = []


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"PASS  {name}")
    else:
        FAIL += 1
        FAILURES.append(name)
        print(f"FAIL  {name}  {detail}")


MAIN_MARKER = "主会话私密标记E2E"


class HybridConn:
    """主会话 mock 两轮；子会话（消息含【委派任务】）代理到真实连接器。"""

    def __init__(self, real):
        self.real = real
        self.main_calls = 0

    async def chat_stream(self, model, messages, tools=None):
        joined = " ".join(str(m.get("content", ""))[:200] for m in messages)
        if "【委派任务】" in joined:
            # 子会话 → 真实推理
            async for ev in self.real.chat_stream(model, messages, tools=tools):
                yield ev
            return
        self.main_calls += 1
        if self.main_calls == 1:
            args = {
                "target": "Beta",
                "task": "请在工作目录下创建文件 hello.txt，内容为：Hello M3",
                "expect": "写入完成后按交卷契约交卷，artifacts 中列出 hello.txt",
            }
            yield {"tool_calls": [{"id": "call_e2e", "function": {
                "name": "delegate_task", "arguments": json.dumps(args, ensure_ascii=False)}}]}
            yield {"done": True, "counts": {"prompt_eval_count": 10, "eval_count": 5}}
        else:
            yield {"content_delta": "委派已完成：子 Agent Beta 写入了 hello.txt（内容为 Hello M3）。"}
            yield {"done": True, "counts": {"prompt_eval_count": 10, "eval_count": 5}}


def main():
    TMP = Path(tempfile.mkdtemp(prefix="m31e2e_"))
    import sidecar.storage.store as store
    store.PROJECTS_ROOT = TMP
    store._GDB = TMP / "_global.db"
    from sidecar import app as appmod
    from sidecar.ollama.connector import get_ollama_connector

    # 0. 前置：Ollama 在线 + qwen3.8 已加载
    import httpx
    try:
        r = httpx.get("http://localhost:11434/api/ps", timeout=5, trust_env=False)
        names = [m.get("name", "") for m in r.json().get("models", [])]
    except Exception as e:
        print(f"SKIP  Ollama 不可达：{e}")
        sys.exit(2)
    if not any(n.startswith("qwen3.8") for n in names):
        print(f"SKIP  qwen3.8 未加载（/api/ps={names}）；请先发一次推理请求载入")
        sys.exit(2)
    print(f"前置 OK：qwen3.8 已加载（/api/ps={names}）")

    real_conn = get_ollama_connector()
    hybrid = HybridConn(real_conn)
    appmod.get_ollama_connector = lambda: hybrid
    # delegation 模块内部也从该模块导入 → 同步替换
    from sidecar.ollama import connector as connmod
    orig_singleton_fn = connmod.get_ollama_connector
    connmod.get_ollama_connector = lambda: hybrid

    pid = store.create_project("e2e-m31", TMP / "wd")
    main_id = store.add_agent_config(pid, "Alpha", "main", model_name="qwen3.8", role="总控")
    beta_id = store.add_agent_config(pid, "Beta", "sub", model_name="qwen3.8", role="执行者")
    sid = store.create_session(pid, main_id, title="主会话")
    store.save_message(pid, sid, main_id, "user", MAIN_MARKER)

    wd = TMP / "wd"
    wd.mkdir(exist_ok=True)

    from fastapi.testclient import TestClient
    client = TestClient(appmod.app)

    events = []
    with client.stream("POST", "/api/ollama/chat/stream", json={
        "agent_id": main_id, "project_id": pid, "session_id": sid,
        "model": "qwen3.8", "sandbox_root": str(wd),
        "messages": [{"role": "user", "content": "把写文件的任务委派给 Beta 去做"}],
    }, timeout=900) as resp:
        check("E1 HTTP 200", resp.status_code == 200, str(resp.status_code))
        buf_ev, buf_data = None, []
        for line in resp.iter_lines():
            if line.startswith("event:"):
                buf_ev = line[6:].strip()
            elif line.startswith("data:"):
                buf_data.append(line[5:].strip())
            elif line == "" and buf_ev:
                try:
                    events.append((buf_ev, json.loads("".join(buf_data)) if buf_data else {}))
                except json.JSONDecodeError:
                    events.append((buf_ev, {}))
                buf_ev, buf_data = None, []

    ev_names = [e for e, _ in events]
    print(f"事件序列：{ev_names}")

    # E2 委派工具调用与结果
    tc = next(((e, d) for e, d in events if e == "tool_call" and d.get("name") == "delegate_task"), None)
    tr = next(((e, d) for e, d in events if e == "tool_result" and d.get("name") == "delegate_task"), None)
    check("E2a delegate_task tool_call 已发出", tc is not None)
    check("E2b tool_result ok=True（子任务成功交卷）",
          tr is not None and tr[1].get("ok") is True, str(tr)[:300] if tr else "无")
    if tr:
        print(f"  tool_result summary: {tr[1].get('summary', '')[:150]}")

    # E3 主会话最终回复
    done = next(((e, d) for e, d in events if e == "done"), None)
    check("E3 主会话收到最终回复", done is not None and done[1].get("content"), str(done)[:200] if done else "无")

    # E4 文件真实落盘（子 Agent 真实执行了 write_file）
    hello = wd / "hello.txt"
    check("E4 hello.txt 已写入且内容含 Hello M3",
          hello.exists() and "Hello M3" in hello.read_text(encoding="utf-8"),
          f"exists={hello.exists()}")

    # E5 任务表落库（审核标准 9：只读端点实测）
    r_tasks = client.get(f"/api/projects/{pid}/tasks")
    tasks = r_tasks.json()
    check("E5a /tasks 端点返回 1 条任务", r_tasks.status_code == 200 and len(tasks) == 1, str(tasks)[:200])
    t = tasks[0] if tasks else {}
    check("E5b 任务 status=done + report 可解析",
          t.get("status") == "done" and isinstance(t.get("report"), dict)
          and t["report"].get("task_id") == t.get("id"), str(t)[:300])
    check("E5c report 契约字段齐全",
          isinstance(t.get("report"), dict)
          and t["report"].get("status") in ("success", "partial", "failed")
          and isinstance(t["report"].get("summary"), str)
          and isinstance(t["report"].get("artifacts"), list), str(t.get("report"))[:300])

    # E6 上下文隔离实测（审核标准 2）：子会话无主对话内容
    child_sid = t.get("session_id")
    check("E6a 任务关联子会话", bool(child_sid), str(t)[:150])
    child_msgs = store.load_messages(pid, child_sid) if child_sid else []
    check("E6b 子会话不含主对话标记",
          child_msgs and all(MAIN_MARKER not in (m["content"] or "") for m in child_msgs),
          str([(m["role"], (m["content"] or "")[:30]) for m in child_msgs])[:400])
    check("E6c 子会话首条 user 为任务书",
          child_msgs and child_msgs[0]["role"] == "user" and "【委派任务】" in child_msgs[0]["content"],
          str(child_msgs[0])[:150] if child_msgs else "无")
    child_asst = [m for m in child_msgs if m["role"] == "assistant"]
    check("E6d 子会话含 assistant 交卷回复（含 task_id）",
          child_asst and any(t.get("id", "") in (m["content"] or "") for m in child_asst),
          str([(m["content"] or "")[:80] for m in child_asst])[:300])
    if len(child_msgs) > 2:
        print(f"  （发生追问，子会话共 {len(child_msgs)} 条消息）")

    # E7 主会话持久化（含 delegate tool_steps）
    main_msgs = store.load_messages(pid, sid)
    last_asst = next((m for m in reversed(main_msgs) if m["role"] == "assistant"), None)
    check("E7 主会话 assistant 落库含 delegate tool_steps",
          last_asst is not None and any(s.get("name") == "delegate_task" for s in (last_asst.get("tool_steps") or [])),
          str(last_asst)[:250] if last_asst else "无")

    import shutil
    shutil.rmtree(TMP, ignore_errors=True)
    print(f"\n===== M3-1 E2E（真实 Ollama）: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("FAILED:", ", ".join(FAILURES))
        sys.exit(1)


if __name__ == "__main__":
    main()
