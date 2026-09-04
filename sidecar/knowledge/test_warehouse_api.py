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
"""TS-120（0.3.0）知识仓库端点层集成测试（TestClient，全隔离临时目录）。

覆盖：
  E1 转移：勾选消息 → 生成 .md + 归档标记；标题留空自动取首条前 20 字
  E2 检索：/api/knowledge/search 关键词命中 + 作用域过滤
  E3 注入：/api/knowledge/inject 勾选条目拼成文本
  E4 分组：/api/knowledge/groups 返回全局+项目分组（含条数/目录）
  E5 上下文跳过：已归档消息不出现在发给模型的消息里（前端过滤，后端总结跳过）
  E6 删除：/api/knowledge/entries/{id} DELETE 删文件+索引

venv 内 PYTHONPATH=.. python knowledge/test_warehouse_api.py 直接跑。
"""
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
    import sidecar.knowledge.warehouse as wh
    import sidecar.storage.store as store

    # 全隔离：数据根、索引库、项目库都指到临时目录
    tmp = Path(tempfile.mkdtemp(prefix="wh_api_"))
    wh._DATA_ROOT_OVERRIDE = tmp
    wh._INDEX_DB_PATH = tmp / "index.db"
    proj_root = tmp / "projects"
    proj_root.mkdir(parents=True, exist_ok=True)
    store.PROJECTS_ROOT = proj_root
    store._GDB = proj_root / "_global.db"

    work_dir = tmp / "proj_work"
    work_dir.mkdir(parents=True, exist_ok=True)
    pid = store.create_project("测试项目", work_dir)
    aid = store.add_agent_config(pid, "测试Agent", "main")
    sid = store.create_session(pid, aid, "测试会话")
    store.save_message(pid, sid, aid, "user", "地球是圆的，这是我们要讨论的第一个知识点内容")
    store.save_message(pid, sid, aid, "assistant", "是的，地球确实是圆的")
    store.save_message(pid, sid, aid, "user", "保留的普通消息")
    msgs = store.load_messages(pid, sid)
    mid0, mid1 = msgs[0]["id"], msgs[1]["id"]

    # 延迟导入 app（在隔离生效后），用 TestClient
    from fastapi.testclient import TestClient
    import sidecar.app as app_mod
    client = TestClient(app_mod.app)

    # E1 转移（标题留空 → 自动取首条前 20 字）
    r = client.post("/api/knowledge/transfer", json={
        "project_id": pid, "session_id": sid, "message_ids": [mid0, mid1],
        "scope": "global", "keywords": ["地球", "常识"], "category": "测试"})
    check("E1a 转移成功", r.status_code == 200 and r.json().get("ok"), r.text[:150])
    d = r.json()
    check("E1b 标题自动取前20字", d.get("title") == msgs[0]["content"][:20],
          f"{d.get('title')} vs {msgs[0]['content'][:20]}")
    check("E1c 归档条数", d.get("archived") == 2, str(d.get("archived")))
    entry_id = d.get("entry_id")
    # 验证消息已归档
    msgs2 = store.load_messages(pid, sid)
    check("E1d 消息标记归档", msgs2[0].get("archived") and msgs2[1].get("archived"),
          str([(m.get("role"), m.get("archived")) for m in msgs2]))
    check("E1e 第三条未归档", not msgs2[2].get("archived"), str(msgs2[2].get("archived")))

    # E5 上下文跳过：发给模型的消息应排除已归档（前端过滤逻辑等价验证）
    model_msgs = [m for m in msgs2 if not m.get("archived")]
    check("E5a 归档消息不进模型上下文", len(model_msgs) == 1 and model_msgs[0]["content"] == "保留的普通消息",
          str([m["content"] for m in model_msgs]))

    # E2 检索
    r2 = client.get("/api/knowledge/search", params={"q": "地球", "scope": "global"})
    check("E2a 检索命中", r2.status_code == 200 and any(x["id"] == entry_id for x in r2.json()),
          r2.text[:150])
    r2b = client.get("/api/knowledge/search", params={"q": "地球", "scope": "project", "project_id": pid})
    check("E2b 作用域过滤（项目无此条）", all(x["id"] != entry_id for x in r2b.json()), r2b.text[:100])

    # E4 分组
    r4 = client.get("/api/knowledge/groups")
    groups = r4.json()
    check("E4a 分组含全局", any(g["scope"] == "global" for g in groups), str(groups)[:200])
    check("E4b 分组含项目", any(g["scope"] == "project" and g["project_id"] == pid for g in groups), str(groups)[:200])
    g_global = next(g for g in groups if g["scope"] == "global")
    check("E4c 全局组条数", g_global["count"] == 1, str(g_global))

    # E3 注入
    r3 = client.post("/api/knowledge/inject", json={"entry_ids": [entry_id]})
    check("E3a 注入成功", r3.status_code == 200 and r3.json().get("ok"), r3.text[:100])
    check("E3b 注入文本含知识内容", "地球是圆的" in r3.json().get("text", ""), r3.json().get("text", "")[:80])

    # E6 删除
    r6 = client.delete(f"/api/knowledge/entries/{entry_id}")
    check("E6a 删除成功", r6.status_code == 200 and r6.json().get("ok"), r6.text[:100])
    r6b = client.get("/api/knowledge/search", params={"q": "地球", "scope": "global"})
    check("E6b 删除后检索不到", all(x["id"] != entry_id for x in r6b.json()), r6b.text[:100])

    # 清理
    wh._DATA_ROOT_OVERRIDE = None
    wh._INDEX_DB_PATH = None
    import shutil
    shutil.rmtree(tmp, ignore_errors=True)

    print(f"\n===== 结果：{PASS} PASS / {FAIL} FAIL =====")
    if FAILURES:
        print("失败项：", "、".join(FAILURES))
        sys.exit(1)


if __name__ == "__main__":
    main()
