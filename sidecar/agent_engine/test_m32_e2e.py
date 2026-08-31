"""TS-108 M3-2 审核实测：自动建子 Agent + 委派端到端（真实 Ollama）。

混合策略（同 test_m31_e2e.py）：
- 主会话 mock 两轮：第一轮发 delegate_task（目标"临时助手"——项目内不存在，
  suggested_role="速记员"）；第二轮整合收尾
- 子会话走真实 qwen3.8：读任务书 → 真实写文件 → 交卷
- 验证：自动新建的 Agent 落库（sub/角色正确）+ 委派执行成功 + 文件落盘 +
  任务表 done + created_agent 标注透出事件流

前置：Ollama 在线且 qwen3.8 已加载。数据重定向临时目录。不入自动回归基线。
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


class HybridConn:
    """主会话 mock；子会话（消息含【委派任务】）代理真实连接器。"""

    def __init__(self, real):
        self.real = real
        self.main_calls = 0

    async def chat_stream(self, model, messages, tools=None):
        joined = " ".join(str(m.get("content", ""))[:200] for m in messages)
        if "【委派任务】" in joined:
            async for ev in self.real.chat_stream(model, messages, tools=tools):
                yield ev
            return
        self.main_calls += 1
        if self.main_calls == 1:
            args = {
                "target": "临时助手",  # 不存在 → 触发自动新建
                "task": "请在工作目录下创建文件 memo.txt，内容为：auto-created ok",
                "expect": "写入完成后按交卷契约交卷，artifacts 列出 memo.txt",
                "suggested_role": "速记员",
            }
            yield {"tool_calls": [{"id": "call_m32", "function": {
                "name": "delegate_task", "arguments": json.dumps(args, ensure_ascii=False)}}]}
            yield {"done": True, "counts": {"prompt_eval_count": 10, "eval_count": 5}}
        else:
            yield {"content_delta": "自动新建的速记员已完成写入。"}
            yield {"done": True, "counts": {"prompt_eval_count": 10, "eval_count": 5}}


def main():
    TMP = Path(tempfile.mkdtemp(prefix="m32e2e_"))
    import sidecar.storage.store as store
    store.PROJECTS_ROOT = TMP
    store._GDB = TMP / "_global.db"
    from sidecar import app as appmod
    from sidecar.ollama.connector import get_ollama_connector

    import httpx
    try:
        r = httpx.get("http://localhost:11434/api/ps", timeout=5, trust_env=False)
        names = [m.get("name", "") for m in r.json().get("models", [])]
    except Exception as e:
        print(f"SKIP  Ollama 不可达：{e}")
        sys.exit(2)
    if not any(n.startswith("qwen3.8") for n in names):
        print(f"SKIP  qwen3.8 未加载：{names}")
        sys.exit(2)

    real_conn = get_ollama_connector()
    hybrid = HybridConn(real_conn)
    appmod.get_ollama_connector = lambda: hybrid
    from sidecar.ollama import connector as connmod
    connmod.get_ollama_connector = lambda: hybrid

    # 开关保持默认开（模拟用户默认配置）
    appmod.get_config = lambda: {"network_switch": "auto", "max_tool_rounds": 20,
                                 "auto_create_sub_agents": True}

    pid = store.create_project("e2e-m32", TMP / "wd")
    main_id = store.add_agent_config(pid, "Alpha", "main", model_name="qwen3.8", role="总控")
    sid = store.create_session(pid, main_id, title="主会话")
    wd = TMP / "wd"
    wd.mkdir(exist_ok=True)

    from fastapi.testclient import TestClient
    client = TestClient(appmod.app)

    events = []
    with client.stream("POST", "/api/ollama/chat/stream", json={
        "agent_id": main_id, "project_id": pid, "session_id": sid,
        "model": "qwen3.8", "sandbox_root": str(wd),
        "messages": [{"role": "user", "content": "建一个速记员帮我写备忘"}],
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

    print(f"事件序列：{[e for e, _ in events]}")
    tr = next(((e, d) for e, d in events if e == "tool_result" and d.get("name") == "delegate_task"), None)

    # E2 自动新建 + 执行成功
    check("E2a delegate_task tool_result ok=True",
          tr is not None and tr[1].get("ok") is True, str(tr)[:300] if tr else "无")
    check("E2b created_agent 标注透出（事件流）",
          tr is not None and tr[1].get("created_agent") == "速记员",
          str(tr[1])[:200] if tr else "无")

    # E3 新 Agent 落库
    agents = store.list_agent_configs(pid)
    new_agent = next((a for a in agents if a["name"] == "速记员"), None)
    check("E3a 自动新建的 Agent 落库", new_agent is not None, str([a["name"] for a in agents]))
    check("E3b 类型子 + 角色=建议角色 + 继承模型",
          new_agent and new_agent["type_"] == "sub" and new_agent["role"] == "速记员"
          and new_agent["model_name"] == "qwen3.8", str(new_agent)[:200] if new_agent else "")

    # E4 文件真实落盘
    memo = wd / "memo.txt"
    check("E4 memo.txt 已写入", memo.exists() and "auto-created ok" in memo.read_text(encoding="utf-8"),
          f"exists={memo.exists()}")

    # E5 任务表：目标指向新建的 Agent，status=done
    tasks = client.get(f"/api/projects/{pid}/tasks").json()
    check("E5a 任务表 1 条且指向新 Agent",
          len(tasks) == 1 and tasks[0]["target_agent_name"] == "速记员",
          str(tasks)[:200])
    check("E5b 任务 status=done + 交卷契约齐全",
          tasks and tasks[0]["status"] == "done"
          and isinstance(tasks[0].get("report"), dict)
          and tasks[0]["report"].get("status") in ("success", "partial", "failed"),
          str(tasks[0])[:250] if tasks else "")

    # E6 复用验证：再次解析同名目标应直接命中（resolve_target 精确匹配）
    from sidecar.agent_engine.delegation import resolve_target
    hit, err = resolve_target(pid, "速记员", main_id)
    check("E6 再次委派同名目标直接命中（不重复新建）",
          hit is not None and hit["id"] == new_agent["id"] and err == "", f"{hit} {err}")

    import shutil
    shutil.rmtree(TMP, ignore_errors=True)
    print(f"\n===== M3-2 E2E（真实 Ollama）: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("FAILED:", ", ".join(FAILURES))
        sys.exit(1)


if __name__ == "__main__":
    main()
