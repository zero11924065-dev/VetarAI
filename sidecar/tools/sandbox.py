"""沙盒校验：所有路径以 sandbox_root.resolve() 为基准，
target.resolve() 后 is_relative_to 判定。
- 防 ../ 与绝对路径逃逸
- 防符号链接指向外部（resolve 跟随 symlink）
- 防 "sandbox_evil/" 同前缀兄弟目录绕过（is_relative_to 是逐段比较，非字符串前缀）

2026-08-28 权限策略重构（用户授权宽松化）：
- 沙盒判定仅作为"工作目录锚点"，越界读写默认放行
- 新增敏感路径判定：仅"删除/覆盖敏感系统位置"需用户确认（走 authorizer）
"""
from __future__ import annotations

from pathlib import Path


class SandboxViolation(Exception):
    def __init__(self, path: str):
        self.path = path
        super().__init__(f"outside_sandbox: {path}")


def ensure_inside(sandbox_root: str | Path, target: str | Path) -> Path:
    """校验 target 在 sandbox_root 内（含自身）。越界 raise SandboxViolation。"""
    root = Path(sandbox_root).expanduser().resolve()
    t = Path(target).expanduser()
    # 相对路径视为相对 sandbox_root
    if not t.is_absolute():
        t = root / t
    t = t.resolve()
    if t == root:
        return t
    if not t.is_relative_to(root):
        raise SandboxViolation(str(target))
    return t


# ── 敏感路径清单（2026-08-28 权限重构）──────────────────────────────
# 仅对这些位置的"删除"需要用户确认；其余位置默认放行。
# 绝对路径目录（系统级）：
# 注意：不含 /private/var —— macOS 所有临时目录（/private/var/folders/...）
# 都解析到该前缀，若列入会把删除任何临时文件都误判为敏感，
# 且 /private/var 内含大量非系统关键数据，不符合"仅保护系统关键位置"意图。
_SENSITIVE_DIRS = (
    "/System", "/etc", "/private/etc", "/usr", "/bin", "/sbin",
    "/Applications", "/Library", "/boot", "/dev",
)


def _sensitive_home_entries() -> tuple[str, ...]:
    """用户主目录下的敏感条目（延迟求值，跟随真实 home）。"""
    home = Path.home()
    entries = [
        home / ".ssh", home / ".gnupg", home / ".aws",
        home / ".netrc", home / ".zshrc", home / ".zprofile",
        home / ".bashrc", home / ".bash_profile",
        home / "Library" / "Keychains",
        home / ".subagent",  # 应用自身数据（防止 Agent 破坏自己的配置/数据库）
    ]
    return tuple(str(p) for p in entries)


def is_sensitive_path(target: str | Path) -> bool:
    """target（解析后）是否落在敏感系统位置。

    判定：命中敏感目录（含子路径）或等于/位于敏感主目录条目之下。
    """
    try:
        t = Path(target).expanduser().resolve()
    except (OSError, RuntimeError):
        return True  # 解析异常按敏感处理（保守）
    s = str(t)
    for d in _SENSITIVE_DIRS:
        if s == d or s.startswith(d + "/"):
            return True
    for e in _sensitive_home_entries():
        if s == e or s.startswith(e + "/"):
            return True
    return False
