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
"""H15 审核实测：qwen3.6:35b（用户同款弱模型）+ 原话场景 → 是否真实委派。

场景：主 Agent 用 qwen3.6:35b；用户消息为验收原话"让人事专员帮我查一下今年重庆的最低社保缴纳基数"；
项目内无"人事专员"。断言：
1. 主模型发出 delegate_task tool_call（不再自己搜后代答）
2. 自动新建"人事专员"落库（sub）
3. 任务表出现该委派记录（状态不限：done/failed 均可——本测只验"委派发生"，交卷能力另案）
全部真实推理，不入自动回归。
"""
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


def main():
    TMP = Path(tempfile.mkdtemp(prefix="h15e2e_"))
    import sidecar.storage.store as store
    store.PROJECTS_ROOT = TMP
    store._GDB = TMP / "_global.db"
    from sidecar import app as appmod
    from sidecar.ollama.connector import get_ollama_connector

    import httpx
    try:
        r = httpx.get("http://localhost:11434/api/tags", timeout=5, trust_env=False)
        names = [m.get("name", "") for m in r.json().get("models", [])]
    except Exception as e:
        print(f"SKIP  Ollama 不可达：{e}")
        sys.exit(2)
    if not any(n.startswith("qwen3.6") for n in names):
        print(f"SKIP  qwen3.6:35b 未安装：{names}")
        sys.exit(2)

    appmod.get_config = lambda: {"network_switch": "auto", "max_tool_rounds": 30,
                                 "auto_create_sub_agents": True}

    pid = store.create_project("h15", TMP / "wd")
    main_id = store.add_agent_config(pid, "行政主管", "main", model_name="qwen3.6:35b",
                                     role="行政主管")
    sid = store.create_session(pid, main_id, title="主会话")
    wd = TMP / "wd"
    wd.mkdir(exist_ok=True)

    real_conn = get_ollama_connector()

    from fastapi.testclient import TestClient
    client = TestClient(appmod.app)

    events = []
    with client.stream("POST", "/api/ollama/chat/stream", json={
        "agent_id": main_id, "project_id": pid, "session_id": sid,
        "model": "qwen3.6:35b", "sandbox_root": str(wd),
        "messages": [{"role": "user",
                      "content": "让人事专员帮我查一下今年重庆的最低社保缴纳基数"}],
    }, timeout=1200) as resp:
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
    tool_calls = [(e, d) for e, d in events if e == "tool_call"]
    print(f"工具调用：{[d.get('name') for _, d in tool_calls]}")

    # 1 主模型是否发出 delegate_task
    dcall = next(((e, d) for e, d in tool_calls if d.get("name") == "delegate_task"), None)
    check("1 主模型(qwen3.6:35b)发出 delegate_task", dcall is not None,
          f"实际工具：{[d.get('name') for _, d in tool_calls]}")

    # 2 自动新建落库
    agents = store.list_agent_configs(pid)
    hr = next((a for a in agents if a["name"] == "人事专员"), None)
    check("2 自动新建人事专员落库（sub）",
          hr is not None and hr["type_"] == "sub", str([a['name'] for a in agents]))

    # 3 任务表有委派记录（状态不限）
    tasks = client.get(f"/api/projects/{pid}/tasks").json()
    check("3 任务表出现委派记录",
          len(tasks) >= 1 and tasks[0]["target_agent_name"] == "人事专员",
          str(tasks)[:250])

    # 4 主 Agent 未"冒充已派"：若有 web_search，也必须在 delegate 之后（或直接无搜索）
    idx_search = next((i for i, (e, d) in enumerate(events)
                       if e == "tool_call" and d.get("name") == "web_search"), -1)
    idx_dele = next((i for i, (e, d) in enumerate(events)
                     if e == "tool_call" and d.get("name") == "delegate_task"), -1)
    check("4 未跳过委派直接自搜代答（搜索若在，须晚于委派或无搜索）",
          idx_search == -1 or (idx_dele != -1 and idx_search > idx_dele),
          f"search@{idx_search} delegate@{idx_dele}")

    import shutil
    shutil.rmtree(TMP, ignore_errors=True)
    print(f"\n===== H15 弱模型委派实测: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("FAILED:", ", ".join(FAILURES))
        sys.exit(1)


if __name__ == "__main__":
    main()
