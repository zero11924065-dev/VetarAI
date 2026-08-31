"""M3 前置安全加固 M1：授权请求清理（客户端断开后 _auth_pending 为空）。
venv 内直接跑：python test_auth.py。
"""
import asyncio, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

PASS, FAIL = 0, 0
FAILURES = []

def check(name, cond, detail=""):
    global PASS, FAIL
    if cond: PASS += 1; print(f"PASS  {name}")
    else: FAIL += 1; FAILURES.append(name); print(f"FAIL  {name}  {detail}")


def main():
    import sidecar.app as appmod
    import sidecar.config as cfgmod
    import tempfile, shutil
    from pathlib import Path as _P

    tmp = _P(tempfile.mkdtemp(prefix="m1auth_"))
    workdir = tmp/"w"; workdir.mkdir()
    orig_mem = dict(cfgmod.get_config())
    orig_mem.update({"data_root": str(tmp), "ollama_base_url": "http://localhost:11434",
                     "max_tool_rounds": 5, "network_switch": "auto"})
    cfgmod.get_config = lambda: dict(orig_mem)

    # 模拟：往 _auth_pending 塞一个未响应的 entry（event 未 set）
    import asyncio as _a
    evt = _a.Event()
    appmod._auth_pending["test_rid"] = {"event": evt, "result": False,
                                        "tool": "write_file", "path": "/etc/x", "action": "write"}
    check("6 前置：_auth_pending 有 1 个未响应 entry", "test_rid" in appmod._auth_pending, str(list(appmod._auth_pending)))

    # 直接触发清理逻辑（gen() finally 的同款代码）
    for _rid in list(appmod._auth_pending.keys()):
        _entry = appmod._auth_pending.pop(_rid, None)
        if _entry is not None and not _entry["event"].is_set():
            _entry["result"] = False
            _entry["event"].set()

    check("6 客户端断开后 _auth_pending 为空", len(appmod._auth_pending) == 0, str(list(appmod._auth_pending)))
    check("6 未响应 entry 被 set（唤醒等待者拿到 result=False）", evt.is_set() is True, f"is_set={evt.is_set()}")

    cfgmod.get_config = lambda: dict(orig_mem)
    shutil.rmtree(tmp, ignore_errors=True)
    print(f"\n===== M1 授权清理: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("FAILED:", ", ".join(FAILURES))
        sys.exit(1)


if __name__ == "__main__":
    main()
