"""M1-1 工具集单测（2026-08-28 权限宽松化重构后版本）。

权限模型（用户授权宽松化）：
- 工作目录仅作默认读写锚点，任何位置的读/写/建目录/列目录/删除默认放行
- 唯一需用户确认：对"敏感系统位置"的【删除】；写入/修改一律放行
- 删除确认走 authorizer；无 authorizer 时敏感删除直接拒绝

覆盖：沙盒内 4 工具 / 越界放行 / 敏感删除授权 / delete_path / schema 校验。
只输出 PASS/FAIL 摘要。
"""
import asyncio
import shutil
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))  # sidecar/ 的上级，使 `sidecar.*` 可导入
from sidecar.tools import execute, NoopAuthorizer  # noqa: E402
from sidecar.tools import registry as _registry  # noqa: E402

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


def err_of(r):
    return r.get("error", "")


async def main():
    base = Path(tempfile.mkdtemp(prefix="m1tools_"))
    sandbox = base / "sandbox"
    (sandbox / "sub").mkdir(parents=True)
    (sandbox / "a.txt").write_text("hello m1", encoding="utf-8")
    big = sandbox / "big.bin"
    big.write_bytes(b"x" * (2 * 1024 * 1024))

    # ---------- 1. 工作目录内 4 工具 ----------
    r = await execute("list_dir", {}, str(sandbox))
    check("list_dir 合法", r.get("ok") is True and isinstance(r.get("entries"), list)
          and {"a.txt", "sub", "big.bin"} <= {e["name"] for e in r["entries"]}
          and all({"name", "type", "size"} <= set(e.keys()) for e in r["entries"]), str(r)[:200])

    r = await execute("read_file", {"path": "a.txt"}, str(sandbox))
    check("read_file 相对路径", r.get("ok") is True and r.get("content") == "hello m1" and r.get("size") == 8, str(r)[:200])

    r = await execute("write_file", {"path": "sub/nested/new.txt", "content": "abc"}, str(sandbox))
    check("write_file 新建子目录+新文件放行", r.get("ok") is True and (sandbox / "sub/nested/new.txt").read_text() == "abc", str(r)[:200])

    r = await execute("create_dir", {"path": "d1/d2"}, str(sandbox))
    check("create_dir 新建子目录放行", r.get("ok") is True and (sandbox / "d1/d2").is_dir(), str(r)[:200])

    # ---------- 2. 截断 ----------
    r = await execute("read_file", {"path": "big.bin"}, str(sandbox))
    check("read_file 2MB 截断", r.get("ok") is True and r.get("truncated") is True and len(r.get("content", "")) <= 1024 * 1024, str(r)[:120])

    # ---------- 3. 越界默认放行（2026-08-28 宽松化：工作目录不作围栏）----------
    outside = base / "outside"
    outside.mkdir()
    (outside / "secret.txt").write_text("TOPSECRET", encoding="utf-8")

    r = await execute("read_file", {"path": str(outside / "secret.txt")}, str(sandbox))
    check("越界读取 默认放行（读到内容）", r.get("ok") is True and r.get("content") == "TOPSECRET", str(r)[:200])

    r = await execute("write_file", {"path": str(outside / "new.txt"), "content": "out"}, str(sandbox))
    check("越界写入 默认放行（文件落盘）", r.get("ok") is True and (outside / "new.txt").read_text() == "out", str(r)[:200])

    r = await execute("delete_path", {"path": str(outside / "new.txt")}, str(sandbox))
    check("越界删除 非敏感位置 默认放行", r.get("ok") is True and not (outside / "new.txt").exists(), str(r)[:200])

    # ---------- 4. 敏感位置删除 需用户确认（用 monkeypatch 伪造敏感路径，不碰真实系统）----------
    fake_sensitive = base / "fake_sensitive"
    fake_sensitive.mkdir()
    victim = fake_sensitive / "victim.txt"
    victim.write_text("sensitive data", encoding="utf-8")

    orig_is_sensitive = _registry.is_sensitive_path
    _registry.is_sensitive_path = lambda p: str(Path(p).resolve()).startswith(str(fake_sensitive.resolve()))
    try:
        # 4a. 无 authorizer → 敏感删除拒绝（无授权通道）
        r = await execute("delete_path", {"path": str(victim)}, str(sandbox))
        check("敏感删除 无authorizer → 拒绝", r.get("ok") is False and "denied" in err_of(r) and victim.exists(), str(r)[:200])

        # 4b. authorizer 拒绝 → denied_by_user，文件仍在
        class Deny:
            async def __call__(self, tool_name, path, action):
                return False
        r = await execute("delete_path", {"path": str(victim)}, str(sandbox), authorizer=Deny())
        check("敏感删除 authorizer拒绝 → denied_by_user", err_of(r) == "denied_by_user" and victim.exists(), str(r)[:200])

        # 4c. authorizer 放行 → 删除成功
        class Allow:
            async def __call__(self, tool_name, path, action):
                return True
        r = await execute("delete_path", {"path": str(victim)}, str(sandbox), authorizer=Allow())
        check("敏感删除 authorizer放行 → 删除成功", r.get("ok") is True and not victim.exists(), str(r)[:200])

        # 4d. S1（M3 前置安全加固）：敏感位置的【写入/修改】需确认
        # 无 authorizer → 拒绝；authorizer 放行 → 写入成功
        cfg_file = fake_sensitive / "config.yaml"
        cfg_file.write_text("key: old", encoding="utf-8")
        r = await execute("write_file", {"path": str(cfg_file), "content": "key: new"}, str(sandbox))
        check("4d 敏感写入 无authorizer → 拒绝（需确认）", r.get("ok") is False and "需用户确认" in str(r.get("error","")), str(r)[:200])
        check("4d 敏感写入 未落盘", cfg_file.read_text() == "key: old", cfg_file.read_text())
        class AllowW:
            async def __call__(self, tool_name, path, action):
                return True
        r = await execute("write_file", {"path": str(cfg_file), "content": "key: new"}, str(sandbox), authorizer=AllowW())
        check("4d 敏感写入 authorizer放行 → 写入成功", r.get("ok") is True and cfg_file.read_text() == "key: new", str(r)[:200])

        # 4e. 敏感位置的读取 不需确认，直接放行（读任何位置都不拦截）
        r = await execute("read_file", {"path": str(cfg_file)}, str(sandbox))
        check("4e 敏感位置读取 不需确认直接放行", r.get("ok") is True and r.get("content") == "key: new", str(r)[:200])
    finally:
        _registry.is_sensitive_path = orig_is_sensitive

    # ---------- 4f. S1 方案 B：真实敏感目录写/建/读（M3 前置安全加固）----------
    # 用真实 is_sensitive_path（非 mock），验证 /etc、/usr 敏感，~/Desktop 非敏感
    from pathlib import Path as _P
    import tempfile as _tf
    # 1. write_file 写 /etc 敏感位置 → authorizer 被调用；拒绝 → denied_by_user
    class Recog:
        calls = []
        def __init__(self, allow=False): self.allow = allow
        async def __call__(self, tool_name, path, action):
            Recog.calls.append((tool_name, path, action))
            return self.allow
    rz = Recog(allow=False)
    Recog.calls = []
    r = await execute("write_file", {"path": "/etc/m3_test_s1.txt", "content": "x"}, "/tmp", authorizer=rz)
    check("4f1 write /etc → authorizer 被调用", len(Recog.calls) == 1 and Recog.calls[0][0] == "write_file", str(Recog.calls))
    check("4f1 write /etc 拒绝 → denied_by_user", err_of(r) == "denied_by_user", str(r)[:150])

    # 2. write_file 写 ~/Desktop（非敏感越界）→ 直接放行，authorizer 未被调用
    desktop = _P.home() / "Desktop"
    desktop.mkdir(exist_ok=True)
    target = desktop / "test_m3_s1.txt"
    rz2 = Recog(allow=False); Recog.calls = []
    r = await execute("write_file", {"path": str(target), "content": "ok"}, "/tmp", authorizer=rz2)
    check("4f2 write ~/Desktop 非敏感 → 直接放行", r.get("ok") is True, str(r)[:150])
    check("4f2 非敏感 authorizer 未被调用", len(Recog.calls) == 0, str(Recog.calls))
    if target.exists():
        target.unlink()

    # 3. create_dir 建 /usr/test_m3 → authorizer 被调用
    rz3 = Recog(allow=False); Recog.calls = []
    r = await execute("create_dir", {"path": "/usr/test_m3_s1"}, "/tmp", authorizer=rz3)
    check("4f3 create_dir /usr → authorizer 被调用", len(Recog.calls) == 1 and Recog.calls[0][0] == "create_dir", str(Recog.calls))
    check("4f3 create_dir /usr 拒绝 → denied_by_user", err_of(r) == "denied_by_user", str(r)[:150])

    # 4. read_file 读 /etc/hosts → ok=true（读不受限）
    if _P("/etc/hosts").exists():
        r = await execute("read_file", {"path": "/etc/hosts"}, "/tmp")
        check("4f4 read /etc/hosts → ok=true（读不受限）", r.get("ok") is True, str(r)[:150])
    else:
        # 无 /etc/hosts 的环境：读不存在的文件也会走路径解析，断言不是 denied_by_user
        r = await execute("read_file", {"path": "/etc/hosts"}, "/tmp")
        check("4f4 read 敏感位置 非 denied_by_user（读不受限）", err_of(r) != "denied_by_user", str(r)[:150])

    # ---------- 5. delete_path 基础语义 ----------
    (sandbox / "todel.txt").write_text("x", encoding="utf-8")
    r = await execute("delete_path", {"path": "todel.txt"}, str(sandbox))
    check("delete_path 相对路径删除文件", r.get("ok") is True and not (sandbox / "todel.txt").exists(), str(r)[:200])

    (sandbox / "todel_dir").mkdir()
    (sandbox / "todel_dir" / "inner.txt").write_text("y", encoding="utf-8")
    r = await execute("delete_path", {"path": "todel_dir"}, str(sandbox))
    check("delete_path 递归删除目录", r.get("ok") is True and not (sandbox / "todel_dir").exists(), str(r)[:200])

    r = await execute("delete_path", {"path": "no_such_thing"}, str(sandbox))
    check("delete_path 目标不存在 → not_found", r.get("ok") is False and "not_found" in err_of(r), str(r)[:200])

    # ---------- 6. schema / 入参契约 ----------
    r = await execute("read_file", {"path": "nope_missing.txt"}, str(sandbox))
    check("文件不存在 → error 非裸串", r.get("ok") is False and "not_a_file" in err_of(r), str(r)[:200])

    r = await execute("write_file", {"path": "x.txt"}, str(sandbox))  # 缺 content
    check("缺 content → bad_arg", r.get("ok") is False and "bad_arg" in err_of(r), str(r)[:200])

    r = await execute("nope_tool", {}, str(sandbox))
    check("未知工具 → unknown_tool", "unknown_tool" in err_of(r), str(r)[:200])

    # schema 校验器自校验
    from sidecar.tools.registry import _validate, TOOLS
    bad = {"ok": True, "entries": [{"name": "x"}]}  # 缺 type/size
    probs = _validate(bad, TOOLS["list_dir"]["return_schema"])
    check("RETURN_SCHEMA 校验缺字段", any(p.startswith("bad_entry") for p in probs), str(probs))

    # ---------- 7. NoopAuthorizer 语义 ----------
    n = await NoopAuthorizer()("delete_path", "/etc/passwd", "delete")
    check("NoopAuthorizer 敏感操作恒 False（安全优先）", n is False)

    # ---------- 清理 ----------
    shutil.rmtree(base, ignore_errors=True)
    check("测试临时目录已清理", not base.exists())

    print(f"\n===== SUMMARY: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("FAILED:", ", ".join(FAILURES))
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
