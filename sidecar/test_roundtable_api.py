"""TS-109 M3-3 圆桌 API 端点单测（TestClient + 打桩 roundtable 模块）。
venv 内 python test_roundtable_api.py 直接跑（需 PYTHONPATH）。只输出 PASS/FAIL 摘要。
"""
import asyncio
import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

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
    TMP = Path(tempfile.mkdtemp(prefix="m33api_"))
    import sidecar.storage.store as store
    store.PROJECTS_ROOT = TMP
    store._GDB = TMP / "_global.db"
    from sidecar import app as appmod

    appmod.get_config = lambda: {"network_switch": "auto", "max_tool_rounds": 5}

    # 打桩圆桌执行模块（不真实调模型）
    fake_rt_store: dict = {}

    async def fake_create(project_id, topic, agent_ids, moderator="user",
                          moderator_agent_id=None, max_rounds=5, connector=None,
                          attachments=None):
        if not topic.strip():
            raise ValueError("议题不能为空")
        if len(agent_ids) < 2:
            raise ValueError("圆桌至少需要 2 个参与者")
        rt_id = "rt-" + topic[:6]
        fake_rt_store[rt_id] = {
            "id": rt_id, "project_id": project_id, "topic": topic,
            "moderator": moderator, "moderator_agent_id": moderator_agent_id,
            "max_rounds": max_rounds, "round": 1, "status": "waiting_user",
            "minutes": "纪要", "summary": None, "participants": [],
            "attachments": attachments or [],
            "created_at": "now", "updated_at": "now",
        }
        return fake_rt_store[rt_id]

    async def fake_continue(project_id, rt_id, connector=None):
        rt = fake_rt_store.get(rt_id)
        rt["round"] += 1
        return rt

    async def fake_finish(project_id, rt_id, connector=None):
        rt = fake_rt_store.get(rt_id)
        rt["status"] = "done"
        rt["summary"] = "总结正文"
        return rt

    orig_create, orig_continue, orig_finish = (
        appmod.rt_mod.create_and_start, appmod.rt_mod.continue_roundtable, appmod.rt_mod.finish_roundtable)
    appmod.rt_mod.create_and_start = fake_create
    appmod.rt_mod.continue_roundtable = fake_continue
    appmod.rt_mod.finish_roundtable = fake_finish

    # 真实存储层：项目 + Agent
    pid = store.create_project("api-proj", TMP / "wd")
    a1 = store.add_agent_config(pid, "产品", "main", model_name="qwen3.8")
    a2 = store.add_agent_config(pid, "技术", "main", model_name="qwen3.8")

    # 用真实存储验证详情/列表端点：先手工插入一条圆桌记录
    rt_id_real = store.create_roundtable(pid, "真实议题", [{"id": a1, "name": "产品"}],
                                         "user", None, 5, "初始纪要")
    store.add_roundtable_message(pid, rt_id_real, 1, a1, "产品", "发言内容", ok=True)

    from fastapi.testclient import TestClient
    client = TestClient(appmod.app)

    # ── 9. 创建 → 返回列表与详情 ──
    r = client.post(f"/api/projects/{pid}/roundtables", json={
        "topic": "测试议题", "agent_ids": [a1, a2], "moderator": "user", "max_rounds": 3})
    check("9a 创建圆桌 200", r.status_code == 200, str(r.status_code) + r.text[:150])
    created = r.json()
    check("9b 返回字段齐全",
          created.get("id") and created["status"] == "waiting_user" and created["round"] == 1,
          str(created)[:200])

    r2 = client.get(f"/api/projects/{pid}/roundtables")
    lst = r2.json()
    check("9c 列表含真实圆桌", r2.status_code == 200 and any(t["id"] == rt_id_real for t in lst),
          str(lst)[:200])

    r3 = client.get(f"/api/roundtables/{rt_id_real}", params={"project_id": pid})
    d3 = r3.json()
    check("9d 详情含纪要+发言消息",
          r3.status_code == 200 and d3.get("minutes") == "初始纪要"
          and len(d3.get("messages", [])) == 1 and d3["messages"][0]["content"] == "发言内容",
          str(d3)[:250])

    # ── 10. 状态守卫 ──
    # continue：真实圆桌初始状态 running → 400
    r4 = client.post(f"/api/roundtables/{rt_id_real}/continue", params={"project_id": pid})
    check("10a running 状态 continue → 400", r4.status_code == 400, str(r4.status_code))
    # finish：running → 400
    r5 = client.post(f"/api/roundtables/{rt_id_real}/finish", params={"project_id": pid})
    check("10b running 状态 finish → 400", r5.status_code == 400, str(r5.status_code))
    # 不存在 → 404
    r6 = client.get("/api/roundtables/ghost", params={"project_id": pid})
    check("10c 不存在圆桌详情 → 404", r6.status_code == 404)
    r7 = client.post("/api/roundtables/ghost/continue", params={"project_id": pid})
    check("10d 不存在圆桌 continue → 404", r7.status_code == 404)
    # 校验：参与者不足 → 400
    r8 = client.post(f"/api/projects/{pid}/roundtables", json={
        "topic": "t", "agent_ids": [a1]})
    check("10e 参与者不足 → 400", r8.status_code == 400, str(r8.status_code))

    # ── 11. waiting_user 状态 continue/finish 放行（打桩）──
    # 真实存储造一条 waiting_user 圆桌；同时在打桩 store 里预置记录供 fake_continue/finish 使用
    rt_id_w = store.create_roundtable(pid, "等待中议题", [], "user", None, 5, "m")
    store.update_roundtable(pid, rt_id_w, status="waiting_user")
    fake_rt_store[rt_id_w] = {"id": rt_id_w, "round": 1, "status": "waiting_user", "summary": None}
    appmod.rt_mod.continue_roundtable = fake_continue
    r9 = client.post(f"/api/roundtables/{rt_id_w}/continue", params={"project_id": pid})
    check("11a waiting_user continue 放行", r9.status_code == 200, str(r9.status_code) + r9.text[:100])
    # finish 放行：先转 confirm_end
    store.update_roundtable(pid, rt_id_w, status="confirm_end")
    r10 = client.post(f"/api/roundtables/{rt_id_w}/finish", params={"project_id": pid})
    check("11b confirm_end finish 放行", r10.status_code == 200, str(r10.status_code) + r10.text[:100])

    # ── 12. TS-109 增强：删除守卫（running 禁删 / 非 running 可删）──
    rt_id_run = store.create_roundtable(pid, "进行中议题", [], "user", None, 5, "m")
    store.update_roundtable(pid, rt_id_run, status="running")
    r11 = client.delete(f"/api/roundtables/{rt_id_run}", params={"project_id": pid})
    check("12a running 状态删除 → 400", r11.status_code == 400, str(r11.status_code))
    store.update_roundtable(pid, rt_id_run, status="done")
    r12 = client.delete(f"/api/roundtables/{rt_id_run}", params={"project_id": pid})
    check("12b done 状态删除放行", r12.status_code == 200 and r12.json().get("deleted") is True,
          str(r12.status_code) + r12.text[:100])
    r13 = client.delete("/api/roundtables/ghost", params={"project_id": pid})
    check("12c 不存在圆桌删除 → 404", r13.status_code == 404)

    # ── 13. TS-109 增强：导出端点 ──
    rt_id_exp = store.create_roundtable(pid, "导出议题", [{"id": a1, "name": "产品"}],
                                        "user", None, 5, "纪要正文")
    store.add_roundtable_message(pid, rt_id_exp, 1, a1, "产品", "导出发言", ok=True)
    r14 = client.post(f"/api/roundtables/{rt_id_exp}/export", params={"project_id": pid})
    check("13a 导出返回路径且文件存在",
          r14.status_code == 200 and Path(r14.json().get("path", "")).exists(),
          str(r14.status_code) + r14.text[:150])
    if r14.status_code == 200:
        content = Path(r14.json()["path"]).read_text(encoding="utf-8")
        check("13b 导出文件含发言内容", "导出发言" in content and "纪要正文" in content, content[:150])
    r15 = client.post("/api/roundtables/ghost/export", params={"project_id": pid})
    check("13c 不存在圆桌导出 → 404", r15.status_code == 404)

    # ── 14. TS-109 增强：附件校验守卫 ──
    import base64 as _b64
    r16 = client.post(f"/api/projects/{pid}/roundtables", json={
        "topic": "附件超限", "agent_ids": [a1, a2],
        "attachments": [{"name": f"f{i}.txt", "content_base64": _b64.b64encode(b"x").decode()} for i in range(6)]})
    check("14a 超过 5 个附件 → 400", r16.status_code == 400, str(r16.status_code))
    big = _b64.b64encode(b"x" * (2 * 1024 * 1024 + 1)).decode()
    r17 = client.post(f"/api/projects/{pid}/roundtables", json={
        "topic": "附件过大", "agent_ids": [a1, a2],
        "attachments": [{"name": "big.txt", "content_base64": big}]})
    check("14b 单文件超 2MB → 400", r17.status_code == 400, str(r17.status_code))

    # ── 15. checkpoint-067 N-1：手动停止端点 ──
    rt_id_stop = store.create_roundtable(pid, "停止议题", [{"id": a1, "name": "产品"}],
                                         "user", None, 5, "m")
    store.update_roundtable(pid, rt_id_stop, status="running")
    r18 = client.post(f"/api/roundtables/{rt_id_stop}/stop", params={"project_id": pid})
    check("15a running 停止 → 200", r18.status_code == 200, str(r18.status_code) + r18.text[:100])
    check("15b 停止后置取消标志", appmod.rt_mod._is_cancelled(rt_id_stop) is True)
    # 已结束 → 400
    store.update_roundtable(pid, rt_id_stop, status="done")
    appmod.rt_mod.clear_cancel(rt_id_stop)
    r19 = client.post(f"/api/roundtables/{rt_id_stop}/stop", params={"project_id": pid})
    check("15c done 状态停止 → 400", r19.status_code == 400, str(r19.status_code))
    # 不存在 → 404
    r20 = client.post("/api/roundtables/ghost/stop", params={"project_id": pid})
    check("15d 不存在圆桌停止 → 404", r20.status_code == 404)

    # 取消标志往返：request_cancel/_is_cancelled/clear_cancel
    appmod.rt_mod.request_cancel("cancel-probe")
    check("15e request_cancel/_is_cancelled 往返",
          appmod.rt_mod._is_cancelled("cancel-probe") is True)
    appmod.rt_mod.clear_cancel("cancel-probe")
    check("15f clear_cancel 清除标志", appmod.rt_mod._is_cancelled("cancel-probe") is False)

    appmod.rt_mod.create_and_start = orig_create
    appmod.rt_mod.continue_roundtable = orig_continue
    appmod.rt_mod.finish_roundtable = orig_finish

    import shutil
    shutil.rmtree(TMP, ignore_errors=True)
    check("测试临时目录已清理", not TMP.exists())

    print(f"\n===== M3-3 圆桌 API 专项: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("FAILED:", ", ".join(FAILURES))
        sys.exit(1)


if __name__ == "__main__":
    main()
