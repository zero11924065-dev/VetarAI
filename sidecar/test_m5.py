"""TS-111 M5 稳定性与降级专项单测（TestClient，venv 内直接跑，需 PYTHONPATH）。
覆盖：心跳动态公式 / model-status 三态 / 配置校验 / 项目改名端点。
只输出 PASS/FAIL 摘要。
"""
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
    TMP = Path(tempfile.mkdtemp(prefix="m5_"))
    import sidecar.storage.store as store
    store.PROJECTS_ROOT = TMP
    store._GDB = TMP / "_global.db"
    from sidecar import app as appmod

    # ══ 1. 心跳动态公式（模块级可测）══
    from sidecar.app import compute_heartbeat_interval
    check("1a 事件少于2 → 回退 base",
          compute_heartbeat_interval([], 15.0) == 15.0
          and compute_heartbeat_interval([1.0], 15.0) == 15.0)
    check("1b 间隔均值×1.5 < base → 取 base",
          compute_heartbeat_interval([1, 3, 5, 7], 15.0) == 15.0)
    check("1c 间隔均值×1.5 > base → 取动态值",
          compute_heartbeat_interval([0, 20, 40], 15.0) == 30.0)
    check("1d 只取近 10 个时间戳",
          abs(compute_heartbeat_interval([i * 20 for i in range(12)], 15.0) - 30.0) < 1e-9)
    check("1e 零间隔防护 → 回退 base",
          compute_heartbeat_interval([5, 5, 5], 15.0) == 15.0)

    # ══ 2. model-status 三态（mock httpx）══
    import httpx
    orig_client = httpx.AsyncClient

    class TagsClient:
        def __init__(self, models=None, fail=False, **kw):
            self._models = models or []
            self._fail = fail

        async def __aenter__(self): return self

        async def __aexit__(self, *a): return False

        async def get(self, url, **kw):
            if self._fail:
                raise httpx.ConnectError("ollama down")

            class R:
                def raise_for_status(self): pass

                @staticmethod
                def json():
                    return {"models": [{"name": n} for n in models_holder["v"]]}
            return R()

    models_holder = {"v": ["qwen3.8:latest", "qwen2.5:7b"]}
    appmod.get_config = lambda: {"ollama_base_url": "http://localhost:11434",
                                 "network_switch": "auto", "reconnect_max_attempts": 3,
                                 "heartbeat_interval": 15.0}

    from fastapi.testclient import TestClient
    client = TestClient(appmod.app)

    httpx.AsyncClient = lambda **kw: TagsClient()
    r = client.get("/api/ollama/model-status", params={"model": "qwen3.8"})
    d = r.json()
    check("2a 模型在线 → online + 模型列表",
          r.status_code == 200 and d["status"] == "online" and "qwen3.8:latest" in d["models"], str(d))
    r = client.get("/api/ollama/model-status", params={"model": "ghost-model"})
    d = r.json()
    check("2b 模型缺失 → missing + 可用名单提示",
          d["status"] == "missing" and "ghost-model" in d["detail"] and "qwen2.5:7b" in d["detail"], str(d))
    r = client.get("/api/ollama/model-status")
    check("2c 不指定模型 → 仅探测可达性", r.json()["status"] == "online")

    httpx.AsyncClient = lambda **kw: TagsClient(fail=True)
    r = client.get("/api/ollama/model-status", params={"model": "qwen3.8"})
    d = r.json()
    check("2d Ollama 不可达 → error + 原因",
          d["status"] == "error" and d["detail"].startswith("Ollama 不可达"), str(d))
    httpx.AsyncClient = orig_client

    # ══ 3. 配置校验（越界拒绝）══
    from sidecar.config import reload_config, get_config
    ok_cfg = reload_config({"reconnect_max_attempts": 5, "heartbeat_interval": 20.0})
    check("3a 合法值可保存",
          ok_cfg.get("reconnect_max_attempts") == 5 and ok_cfg.get("heartbeat_interval") == 20.0)
    for label, patch in [
        ("3b 重连次数 0 拒绝", {"reconnect_max_attempts": 0}),
        ("3c 重连次数 11 拒绝", {"reconnect_max_attempts": 11}),
        ("3d 心跳 4 拒绝", {"heartbeat_interval": 4}),
        ("3e 心跳 61 拒绝", {"heartbeat_interval": 61}),
        ("3f bool 冒充整数拒绝", {"reconnect_max_attempts": True}),
    ]:
        try:
            reload_config(patch)
            check(label, False, "未抛错")
        except ValueError:
            check(label, True)
    reload_config({"reconnect_max_attempts": 3, "heartbeat_interval": 15.0})  # 恢复默认

    # ══ 4. 项目改名端点（后端已存在，回归断言）══
    pid = store.create_project("m5-proj", TMP / "wd")
    r = client.put(f"/api/projects/{pid}", json={"name": "新名字"})
    check("4a 改名 200", r.status_code == 200, str(r.status_code) + r.text[:100])
    names = [p["name"] for p in store.list_projects()]
    check("4b 改名生效", "新名字" in names, str(names))
    r = client.put("/api/projects/ghost-pid", json={"name": "x"})
    check("4c 不存在项目 → 404", r.status_code == 404, str(r.status_code))

    import shutil
    shutil.rmtree(TMP, ignore_errors=True)
    check("测试临时目录已清理", not TMP.exists())

    print(f"\n===== M5 稳定性与降级专项: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("FAILED:", ", ".join(FAILURES))
        sys.exit(1)


if __name__ == "__main__":
    main()
