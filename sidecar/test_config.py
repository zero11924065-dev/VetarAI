"""M3 前置安全加固 L1：配置原子写。
venv 内直接跑：python test_config.py。
"""
import sys, json, os
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

PASS, FAIL = 0, 0
FAILURES = []

def check(name, cond, detail=""):
    global PASS, FAIL
    if cond: PASS += 1; print(f"PASS  {name}")
    else: FAIL += 1; FAILURES.append(name); print(f"FAIL  {name}  {detail}")


def main():
    import tempfile, shutil
    import sidecar.config.store as cfg
    import sidecar.config as cfgmod

    tmp = Path(tempfile.mkdtemp(prefix="l1cfg_"))
    orig_path = cfg.get_config_path()
    # 指向临时目录
    cfg._MEM = {"ollama_base_url": "http://localhost:11434", "data_root": str(tmp)}

    # 8. 写入中途模拟 os.replace 异常 → config.json 仍是完整 JSON
    cfg_path = cfg.get_config_path()
    # 先正常写一次，确保有完整文件
    good = {"ollama_base_url": "http://localhost:11434", "data_root": str(tmp)}
    cfg_path.parent.mkdir(parents=True, exist_ok=True)
    cfg_path.write_text(json.dumps(good), encoding="utf-8")

    # mock os.replace 抛异常（模拟写一半被 kill 后 replace 失败）
    import os as _os
    real_replace = _os.replace
    def boom(src, dst):
        raise OSError("simulated kill mid-write")
    _os.replace = boom
    try:
        try:
            cfg._save({"ollama_base_url": "http://x", "data_root": "y"})
            replaced = False
        except OSError:
            replaced = True
        # config.json 应仍是原来完整的 JSON（未被半截内容破坏）
        on_disk = json.loads(cfg_path.read_text(encoding="utf-8"))
        check("8 os.replace 异常时 config.json 仍完整 JSON", on_disk == good, str(on_disk))
    finally:
        _os.replace = real_replace

    # 正常原子写验证：写入后是完整 JSON
    cfg._save({"ollama_base_url": "http://localhost:11434", "data_root": str(tmp), "default_model": "qwen3.8"})
    final = json.loads(cfg_path.read_text(encoding="utf-8"))
    check("8 正常写入后 config.json 完整", final.get("default_model") == "qwen3.8", str(final))
    # 无残留 .tmp
    check("8 无残留 .tmp 文件", not cfg_path.with_name(cfg_path.name + ".tmp").exists(), str(list(tmp.iterdir())))

    shutil.rmtree(tmp, ignore_errors=True)
    print(f"\n===== L1 配置原子写: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("FAILED:", ", ".join(FAILURES))
        sys.exit(1)


if __name__ == "__main__":
    main()
