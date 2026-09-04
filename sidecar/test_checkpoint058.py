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
"""checkpoint-058 独立 Agent（与项目平级）回归测试。
覆盖：
- CRUD：创建/列表/更新/删除（删除连数据目录一起清）
- 命名空间隔离：数据目录 ia-<id>/，与项目 UUID 目录零碰撞
- 删项目不影响独立 Agent（核心需求）
- 端点集成：TestClient 全链路（建 Agent → 建会话 → 聊天落盘 → 读消息）
- 沙盒解析：ia- 命名空间 → 专属沙盒目录
隔离：照 test_checkpoint050 的 monkeypatch 模式，全部落临时目录，不碰真实数据。
venv 内 PYTHONPATH=. python test_checkpoint058.py 直接跑。
"""
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

TMP = Path(tempfile.mkdtemp(prefix="ck058_"))
import sidecar.config as cfgmod
cfgmod.get_config_path = lambda: TMP / "config.json"
cfgmod._MEM = {}

import sidecar.storage.store as store
store.PROJECTS_ROOT = TMP / "projects"
store._GDB = TMP / "projects" / "_global.db"
store.PROJECTS_ROOT.mkdir(parents=True, exist_ok=True)

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
    # ══ 1. CRUD ══
    aid = store.add_independent_agent("独立助手", model_name="glm-z1-9b", system_prompt="你是测试助手")
    check("1a 创建返回 id", bool(aid))
    agents = store.list_independent_agents()
    check("1b 列表含新建", any(a["id"] == aid and a["name"] == "独立助手" for a in agents))
    one = store.get_independent_agent(aid)
    check("1c 单查字段完整", one and one["name"] == "独立助手" and one["model_name"] == "glm-z1-9b" and one["system_prompt"] == "你是测试助手")
    check("1d 更新名称", store.update_independent_agent(aid, name="独立助手2"))
    check("1e 更新后读取", store.get_independent_agent(aid)["name"] == "独立助手2")
    check("1f 更新不存在的 Agent 返回 False", not store.update_independent_agent("nonexistent", name="x"))

    # ══ 2. 命名空间隔离 ══
    ns = f"ia-{aid}"
    check("2a 数据目录用 ia- 前缀", store.independent_agent_dir(aid).name == ns)
    check("2b 命名空间 agents.db 已注册", any(a["id"] == aid for a in store.list_agent_configs(ns)))
    check("2c 沙盒目录已建", (store.independent_agent_dir(aid) / "sandbox").is_dir())

    # ══ 3. 删项目不影响独立 Agent（核心需求）══
    pid = store.create_project("临时项目", TMP / "wd")
    proj_agent = store.add_agent_config(pid, "项目Agent", "main")
    store.delete_project(pid)
    check("3a 项目删除成功", store.get_project(pid) is None)
    check("3b 删项目后独立 Agent 仍在", store.get_independent_agent(aid) is not None)
    check("3c 独立 Agent 数据目录完好", store.independent_agent_dir(aid).exists())
    # 反向：删独立 Agent 不影响项目
    pid2 = store.create_project("项目2", TMP / "wd2")
    store.delete_independent_agent(aid)
    check("3d 删独立 Agent 后项目仍在", store.get_project(pid2) is not None)
    check("3e 独立 Agent 记录已删", store.get_independent_agent(aid) is None)
    check("3f 独立 Agent 目录已清", not store.independent_agent_dir(aid).exists())

    # ══ 4. 会话/消息复用（命名空间内）══
    aid2 = store.add_independent_agent("二号", model_name="m")
    ns2 = f"ia-{aid2}"
    sid = store.create_session(ns2, aid2, "会话 1")
    store.save_message(ns2, sid, aid2, "user", "你好独立Agent")
    store.save_message(ns2, sid, aid2, "assistant", "你好！我独立于任何项目。")
    msgs = store.load_messages(ns2, sid)
    check("4a 命名空间会话消息落盘/读取", len(msgs) == 2 and msgs[0]["content"] == "你好独立Agent")
    # 删项目不会扫到 ia-* 目录（delete_project 只删 projects/<pid>）
    store.delete_project(pid2)
    check("4b 再删一个项目，独立 Agent 消息仍在", len(store.load_messages(ns2, sid)) == 2)

    # ══ 5. TestClient 端点集成 ══
    from fastapi.testclient import TestClient
    import sidecar.app as appmod
    client = TestClient(appmod.app)

    r = client.post("/api/independent-agents", json={"name": "三号", "model_name": "glm-z1-9b"})
    check("5a POST 创建", r.status_code == 200 and "agent_id" in r.json(), str(r.status_code))
    aid3 = r.json()["agent_id"]

    r = client.post("/api/independent-agents", json={"name": "  "})
    check("5b 空名 422", r.status_code == 422)

    r = client.get("/api/independent-agents")
    check("5c GET 列表含三号", r.status_code == 200 and any(a["id"] == aid3 for a in r.json()))

    r = client.put(f"/api/independent-agents/{aid3}", json={"name": "三号改"})
    check("5d PUT 更新", r.status_code == 200)
    r = client.put("/api/independent-agents/nonexistent", json={"name": "x"})
    check("5e PUT 不存在 404", r.status_code == 404)

    # 会话 + 聊天落盘全链路（命名空间）
    ns3 = f"ia-{aid3}"
    r = client.post("/api/sessions", json={"project_id": ns3, "agent_id": aid3, "title": "会话 1"})
    check("5f 命名空间建会话", r.status_code == 200, str(r.status_code))
    sid3 = r.json()["session_id"]

    r = client.post("/api/ollama/chat/stream", json={
        "agent_id": aid3, "model": "glm-z1-9b", "project_id": ns3, "session_id": sid3,
        "messages": [{"role": "user", "content": "你好"}],
    })
    # 不关心模型是否可达——只要沙盒解析通过就不是 422（sandbox_root 缺失错误）
    check("5g 命名空间聊天不被沙盒缺失拦截", r.status_code != 422 or "sandbox_root" not in r.text, f"{r.status_code} {r.text[:80]}")
    db_msgs = store.load_messages(ns3, sid3)
    check("5h user 消息已落盘", any(m["role"] == "user" for m in db_msgs))

    r = client.delete(f"/api/independent-agents/{aid3}")
    check("5i DELETE 删除", r.status_code == 200)
    r = client.delete(f"/api/independent-agents/{aid3}")
    check("5j 重复删除 404", r.status_code == 404)

    # ══ 6. 沙盒解析 ══
    from sidecar.app import _resolve_sandbox_root, ChatStreamReq
    req = ChatStreamReq(agent_id=aid2, model="m", project_id=ns2, session_id="", messages=[])
    sb = _resolve_sandbox_root(req)
    check("6a ia- 命名空间沙盒解析", sb is not None and f"ia-{aid2}" in sb and sb.endswith("sandbox"))

    print(f"\n===== checkpoint-058: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("FAILED:", ", ".join(FAILURES))
        sys.exit(1)


if __name__ == "__main__":
    main()
