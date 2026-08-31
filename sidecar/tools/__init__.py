"""工具集统一入口（M1-1）。

用法：
    from sidecar.tools import execute, NoopAuthorizer
    result = await execute("list_dir", {}, sandbox_root)
"""
from .registry import execute, NoopAuthorizer, TOOLS

__all__ = ["execute", "NoopAuthorizer", "TOOLS"]
