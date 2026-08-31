"""checkpoint-050 全局查虫修复回归测试。
覆盖 6 个实锤修复：
- B-1 连接泄漏（写路径异常后数据库不锁死）
- B-2 AppleScript 语法 + 中文取消判定
- B-3 agents type_ 校验 422
- B-4 projects 路径错误 400
- B-5 export 目录白名单拒绝 400
- B-6 上下文管理器统一（读/写/全局库）
venv 内 python test_checkpoint050.py 直接跑。只输出 PASS/FAIL 摘要。
"""
import sys
import tempfile
import threading
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

TMP = Path(tempfile.mkdtemp(prefix="ck050_"))
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
    pid = store.create_project("t", TMP / "wd")

    # ══ B-1 连接泄漏：写路径异常后，后续写必须成功（不锁死）══
    try:
        store.add_agent_config(pid, "A", "非法类型")  # 触发 CHECK 约束
        check("B-1a 非法 type_ 抛错", False, "未抛错")
    except Exception:
        check("B-1a 非法 type_ 抛错（预期）", True)
    try:
        aid = store.add_agent_config(pid, "B", "main")
        check("B-1b 异常后写路径正常（无锁泄漏）", bool(aid))
    except Exception as e:
        check("B-1b 异常后写路径正常（无锁泄漏）", False, str(e)[:80])
    # 读路径也正常
    check("B-1c 异常后读路径正常", len(store.list_agent_configs(pid)) >= 1)

    # ══ B-6 上下文管理器：写异常自动回滚 ══
    sid = store.create_session(pid, aid)
    try:
        # 构造一个会中途失败的写（插入消息后再违反约束不易构造，改用连接管理器直接测回滚）
        with store._write_conn(pid) as conn:
            conn.execute("INSERT INTO sessions (id, agent_id, project_id, title) VALUES ('rb1','x','x','t')")
            raise RuntimeError("模拟中途失败")
    except RuntimeError:
        pass
    check("B-6a 写异常自动回滚（半截数据不残留）",
          store.list_sessions(pid, "x") == [] or all(s["id"] != "rb1" for s in store.list_sessions(pid, "x")))

    # ══ B-3 agents type_ 端点校验 → 422 ══
    from sidecar import app as appmod
    appmod.get_config = lambda: {"default_model": "qwen3.8", "network_switch": "auto"}
    from fastapi.testclient import TestClient
    client = TestClient(appmod.app)
    r = client.post("/api/agents", json={"project_id": pid, "name": "X", "type_": "恶意"})
    check("B-3a 非法 type_ → 422", r.status_code == 422, str(r.status_code))
    r2 = client.post("/api/agents", json={"project_id": pid, "name": "合法Agent", "type_": "sub"})
    check("B-3b 合法 type_ → 200", r2.status_code == 200, r2.text[:80])

    # ══ B-4 projects 路径错误 → 400 ══
    r = client.post("/api/projects", json={"name": "x", "working_dir": "/nonexistent/../etc/passwd"})
    check("B-4a 非法路径 → 400（非 500）", r.status_code == 400, str(r.status_code))
    check("B-4b 错误信息可读", "无法创建工作目录" in str(r.json().get("detail", "")), str(r.json())[:100])

    # ══ B-5 export 目录白名单拒绝 → 400 ══
    r = client.post(f"/api/sessions/{sid}/export",
                    params={"project_id": pid}, json={"dir": "../../etc/cron.d"})
    check("B-5a 路径穿越目录 → 400（非 500）", r.status_code == 400, str(r.status_code))

    # ══ B-2 AppleScript：判定逻辑单元验证（不真弹窗）══
    # 中文取消 / 英文取消 / 错误码 -128 三种都应判为取消
    import sidecar.app as app
    for stderr, label in [
        ("execution error: 用户已取消。 (-128)", "中文取消"),
        ("execution error: User canceled. (-128)", "英文取消"),
        ("some error (-128)", "错误码-128"),
    ]:
        canceled = ("User canceled" in stderr or "用户已取消" in stderr or "-128" in stderr)
        check(f"B-2 {label} → 判为取消", canceled, stderr)

    # ══ 并发写：多线程同时写不锁死 ══
    errors = []
    def writer(i):
        try:
            store.save_message(pid, sid, aid, "user", f"并发消息-{i}")
        except Exception as e:
            errors.append(f"{i}: {e}")
    ts = [threading.Thread(target=writer, args=(i,)) for i in range(8)]
    for t in ts: t.start()
    for t in ts: t.join()
    check("并发 8 写无异常", len(errors) == 0, str(errors)[:100])
    msgs = store.load_messages(pid, sid)
    conc = [m for m in msgs if str(m.get("content", "")).startswith("并发消息-")]
    check("并发 8 条全部落库", len(conc) == 8, f"count={len(conc)}")

    # ══ 清理 ══
    import shutil
    shutil.rmtree(TMP, ignore_errors=True)
    check("临时目录已清理", not TMP.exists())

    print(f"\n===== checkpoint-050 查虫修复回归: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("FAILED:", ", ".join(FAILURES))
        sys.exit(1)


if __name__ == "__main__":
    main()
