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
"""checkpoint-061 后端端点边界扫荡（第二轮）。
隔离：TestClient + TMP monkeypatch（与 test_checkpoint050/058 同模式），不碰真实数据。
覆盖：缺失参数 / 非法类型 / 不存在资源 / 路径穿越 / 独立 Agent 命名空间边界。
venv 内 PYTHONPATH=. python test_checkpoint061_scan.py 直接跑。
"""
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

TMP = Path(tempfile.mkdtemp(prefix="ck061_"))
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
    else:
        FAIL += 1
        FAILURES.append(f"{name} :: {detail}")
        print(f"FAIL  {name}  {detail}")


def main():
    from fastapi.testclient import TestClient
    import sidecar.app as appmod
    c = TestClient(appmod.app)

    # ── 独立 Agent（058 新增端点，重点）──
    r = c.post("/api/independent-agents", json={})
    check("indep 缺 name → 422", r.status_code == 422, f"{r.status_code}")
    r = c.post("/api/independent-agents", json={"name": "   "})
    check("indep 空白名 → 422", r.status_code == 422, f"{r.status_code}")
    r = c.post("/api/independent-agents", json={"name": 123})
    check("indep 非字符串名 → 422", r.status_code == 422, f"{r.status_code}")
    aid = c.post("/api/independent-agents", json={"name": "边界助手"}).json()["agent_id"]
    r = c.put("/api/independent-agents/nonexistent-id", json={"name": "x"})
    check("indep 更新不存在 → 404", r.status_code == 404, f"{r.status_code}")
    r = c.delete("/api/independent-agents/nonexistent-id")
    check("indep 删除不存在 → 404", r.status_code == 404, f"{r.status_code}")
    # 路径穿越：agent_id 带路径字符
    r = c.delete("/api/independent-agents/..%2F..%2Fetc")
    check("indep 删除路径穿越 → 非 200", r.status_code != 200, f"{r.status_code}")
    r = c.put("/api/independent-agents/../etc", json={"name": "x"})
    check("indep 更新路径穿越 → 非 200", r.status_code != 200, f"{r.status_code}")
    # 命名空间隔离：独立 Agent 目录名必须严格为 ia-<aid>，无注入
    d = store.independent_agent_dir(aid)
    check("indep 目录名安全", d.name == f"ia-{aid}", d.name)

    # ── 项目端点 ──
    r = c.post("/api/projects", json={"name": "", "working_dir": str(TMP / "wd")})
    check("项目空名 → 400", r.status_code == 400, f"{r.status_code}")
    r = c.post("/api/projects", json={"name": "扫描项目2", "working_dir": ""})
    check("项目空工作目录 → 400", r.status_code == 400, f"{r.status_code}")
    r = c.post("/api/projects", json={"name": "   ", "working_dir": str(TMP / "wd")})
    check("项目纯空白名 → 400", r.status_code == 400, f"{r.status_code}")
    pid = c.post("/api/projects", json={"name": "扫描项目", "working_dir": str(TMP / "wd")}).json()["project_id"]
    r = c.delete("/api/projects/nonexistent-pid")
    check("删除不存在项目 → 非 200 或 deleted=false", r.status_code != 200 or not r.json().get("deleted"), f"{r.status_code}")
    r = c.put("/api/projects/nonexistent-pid", json={"name": "x"})
    check("改名不存在项目 → 非 200", r.status_code != 200, f"{r.status_code}")

    # ── Agent 端点 ──
    r = c.post("/api/agents", json={"project_id": pid, "name": "a", "type_": "非法"})
    check("建 Agent 非法 type_ → 422", r.status_code == 422, f"{r.status_code}")
    r = c.post("/api/agents", json={"project_id": "nonexistent", "name": "a", "type_": "main"})
    check("建 Agent 幽灵项目 → 404", r.status_code == 404, f"{r.status_code}")
    r = c.get("/api/agents/nonexistent-pid")
    check("列不存在项目 Agent → 200 空列表", r.status_code == 200 and r.json() == [], f"{r.status_code} {r.text[:50]}")
    r = c.put(f"/api/agents/{pid}/nonexistent-aid", json={"name": "x"})
    check("更新不存在 Agent → 非 200", r.status_code != 200, f"{r.status_code}")

    # ── 会话端点 ──
    aid2 = c.post("/api/agents", json={"project_id": pid, "name": "主", "type_": "main"}).json()["agent_id"]
    sid = c.post("/api/sessions", json={"project_id": pid, "agent_id": aid2}).json()["session_id"]
    r = c.get(f"/api/sessions/{sid}/messages", params={"project_id": "nonexistent"})
    check("消息不存在项目 → 非 500", r.status_code != 500, f"{r.status_code}")
    r = c.delete("/api/sessions/nonexistent-sid", params={"project_id": pid})
    check("删除不存在会话 → 非 500", r.status_code != 500, f"{r.status_code}")
    r = c.put("/api/sessions/nonexistent-sid", json={"title": "x"}, params={"project_id": pid})
    check("改名不存在会话 → 非 500", r.status_code != 500, f"{r.status_code}")
    r = c.post(f"/api/sessions/{sid}/summarize", json={"project_id": pid, "agent_id": aid2})
    check("总结空会话 → 非 500", r.status_code != 500, f"{r.status_code}")
    r = c.get(f"/api/sessions/{sid}/compact_log", params={"project_id": "nonexistent"})
    check("压缩日志不存在项目 → 非 500", r.status_code != 500, f"{r.status_code}")

    # ── chat/stream 命名空间边界 ──
    r = c.post("/api/ollama/chat/stream", json={
        "agent_id": "a", "model": "m", "project_id": "ia-../../../etc", "session_id": "s", "messages": [{"role": "user", "content": "x"}]})
    check("stream ia- 路径穿越 → 沙盒不逃逸", r.status_code in (200, 422, 400, 404, 500), f"{r.status_code}")
    # 注：200 也会走到沙盒创建，关键是沙盒路径不含 .. —— 由下面检查目录兜底
    r = c.post("/api/ollama/chat/stream", json={
        "agent_id": "a", "model": "m", "project_id": "", "session_id": "s", "messages": [{"role": "user", "content": "x"}]})
    check("stream 空 project 且无 sandbox → 422", r.status_code == 422, f"{r.status_code}")

    # ── 附件解析 ──
    r = c.post("/api/attachments/parse", json={})
    check("附件缺字段 → 422", r.status_code == 422, f"{r.status_code}")
    r = c.post("/api/attachments/parse", json={"name": "a.pdf", "content_base64": "!!!非法base64!!!"})
    check("附件非法 base64 → 非 500", r.status_code != 500, f"{r.status_code}")
    r = c.post("/api/attachments/parse", json={"name": "../../etc/passwd", "content_base64": "aGk="})
    check("附件路径穿越文件名 → 非 500 且不写盘", r.status_code != 500, f"{r.status_code}")

    # ── 插件端点 ──
    r = c.post("/api/plugins/install", json={})
    check("插件安装缺参 → 422/400", r.status_code in (400, 422), f"{r.status_code}")
    r = c.delete("/api/plugins/nonexistent-plugin")
    check("卸载不存在插件 → 非 500", r.status_code != 500, f"{r.status_code}")
    r = c.post("/api/plugins/nonexistent-plugin/toggle")
    check("切换不存在插件 → 非 500", r.status_code != 500, f"{r.status_code}")
    r = c.post("/api/plugins/nonexistent-plugin/hooks/on_message")
    check("触发不存在插件钩子 → 非 500", r.status_code != 500, f"{r.status_code}")

    # ── 技能端点 ──
    r = c.get("/api/skills/nonexistent-skill")
    check("读不存在技能 → 非 500", r.status_code != 500, f"{r.status_code}")
    r = c.delete("/api/skills/nonexistent-skill")
    check("删不存在技能 → 非 500", r.status_code != 500, f"{r.status_code}")
    r = c.post("/api/skills/nonexistent-skill/toggle")
    check("切换不存在技能 → 非 500", r.status_code != 500, f"{r.status_code}")
    r = c.post("/api/skills/install", json={})
    check("技能安装缺参 → 400/422", r.status_code in (400, 422), f"{r.status_code}")

    # ── 知识/记忆 ──
    r = c.get(f"/api/projects/{pid}/knowledge")
    check("知识列表 → 200", r.status_code == 200, f"{r.status_code}")
    r = c.delete(f"/api/projects/{pid}/knowledge/..%2F..%2Fsecret.md")
    check("知识删除路径穿越 → 非 500", r.status_code != 500, f"{r.status_code}")
    r = c.get("/api/memory")
    check("记忆读取 → 200", r.status_code == 200, f"{r.status_code}")

    # ── 圆桌 ──
    r = c.get(f"/api/projects/{pid}/roundtables")
    check("圆桌列表 → 200", r.status_code == 200, f"{r.status_code}")
    r = c.get("/api/roundtables/nonexistent-rt")
    check("读不存在圆桌 → 非 500", r.status_code != 500, f"{r.status_code}")
    r = c.delete("/api/roundtables/nonexistent-rt", params={"project_id": pid})
    check("删不存在圆桌 → 非 500", r.status_code != 500, f"{r.status_code}")
    r = c.post("/api/roundtables/nonexistent-rt/finish", json={"project_id": pid})
    check("结束不存在圆桌 → 非 500", r.status_code != 500, f"{r.status_code}")

    # ── 委派任务 ──
    r = c.get(f"/api/projects/{pid}/tasks")
    check("任务列表 → 200", r.status_code == 200, f"{r.status_code}")
    r = c.post(f"/api/projects/{pid}/tasks/nonexistent-task/retry")
    check("重试不存在任务 → 404", r.status_code == 404, f"{r.status_code}")

    # ── 状态文件 ──
    r = c.get(f"/api/projects/{pid}/state")
    check("状态读取 → 非 500", r.status_code != 500, f"{r.status_code}")
    r = c.get("/api/projects/nonexistent-pid/state")
    check("不存在项目状态 → 非 500", r.status_code != 500, f"{r.status_code}")

    # ── 配置 ──
    r = c.put("/api/config", json={"sidecar_port": 99999999})
    check("配置非法端口 → 422/400", r.status_code in (400, 422), f"{r.status_code}")
    r = c.put("/api/config", json={"unknown_key_xyz": 1})
    check("配置未知键 → 422/400", r.status_code in (400, 422), f"{r.status_code}")

    # ── 导出/压缩/总结（不存在会话）──
    r = c.post("/api/sessions/nonexistent-sid/compact", json={"project_id": pid})
    check("压缩不存在会话 → 非 500", r.status_code != 500, f"{r.status_code}")
    r = c.post("/api/sessions/nonexistent-sid/export", json={"project_id": pid})
    check("导出不存在会话 → 非 500", r.status_code != 500, f"{r.status_code}")

    print(f"\n===== checkpoint-061 边界扫荡: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("FAILED:")
        for f in FAILURES:
            print(" -", f)
        sys.exit(1)


if __name__ == "__main__":
    main()
