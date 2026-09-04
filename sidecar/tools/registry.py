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
"""工具集 + 统一入口 execute()（M1-1）。

契约：
- 每个工具声明 RETURN_SCHEMA（dict），execute 出口统一校验，
  校验失败 → {ok:False, error:"schema_violation: ..."}，不返回裸字符串。
- 沙盒（工作目录）仅作默认读写锚点：任何位置的读/写/建目录/列目录默认放行（2026-08-28 权限宽松化）。
- 唯一需要用户确认的操作：对"敏感系统位置"（系统目录 /etc /System /Applications、
  用户关键资产 ~/.ssh 等、应用自身数据）的【删除】；写入/修改（含修改配置）一律放行。
  删除时若 authorizer 存在 → 调用询问，False → denied_by_user；无 authorizer → 拒绝。
- 本模块零硬编码：不出现任何地址/端口常量（沙盒根与敏感清单见 sandbox 模块）。
"""
from __future__ import annotations

import shutil
from pathlib import Path

from .sandbox import is_sensitive_path
from .web_search import web_search as _web_search, WEB_SEARCH_RETURN
from sidecar.network.guard import NetworkGuardError

MAX_READ_BYTES = 1 * 1024 * 1024  # read_file 截断阈值（协议常量，非环境路径）

# checkpoint-067 R-4：read_file 识别图片扩展名 → 不读字节成乱码，
# 改返回图片标记+base64，由 loop 注入视觉输入，让多模态模型真正读图（而非看到乱码说"没 OCR"）。
IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".heic", ".heif", ".tiff", ".svg"}


def resolve_sandboxed_path(rel: str, sandbox_root: str) -> Path | None:
    """把相对/绝对路径解析为沙盒根下的绝对路径，含双前缀自纠正（checkpoint-069 F-1）。

    返回解析后的 Path；路径不存在时仍返回解析结果（调用方自行判断存在性），
    但若首层 == 沙盒根目录名且去首层后存在，则用去首层结果。
    供 execute() 与委派图片加载（delegate_task image_paths）共用，避免重复实现。
    """
    root = Path(sandbox_root).expanduser().resolve()
    if not isinstance(rel, str) or not rel:
        return None
    p = Path(rel).expanduser()
    if not p.is_absolute():
        p = root / p
    try:
        resolved = p.resolve()
    except (OSError, RuntimeError):
        return None
    # 双前缀自纠正：模型常把"沙盒根目录名"当相对路径前缀再叠一层
    # （如 root=~/Desktop/测试材料 时传 "测试材料/测试存档/..."），导致必然找不到。
    # 相对路径首层 == 根目录名且解析结果不存在 → 去掉首层重试。
    if not resolved.exists() and not Path(rel).is_absolute():
        _parts = Path(rel).parts
        if _parts and _parts[0] == root.name:
            _alt = root.joinpath(*_parts[1:]) if len(_parts) > 1 else root
            if _alt.exists():
                resolved = _alt.resolve()
    return resolved

# ---------- RETURN_SCHEMA 声明 ----------
LIST_DIR_RETURN = {
    "required": ["ok", "entries"],
    "types": {"ok": bool, "entries": list},
    "entry_keys": {"name", "type", "size"},
}
READ_FILE_RETURN = {
    "required": ["ok", "content", "size"],
    "types": {"ok": bool, "content": str, "size": int},
}
WRITE_FILE_RETURN = {
    "required": ["ok", "path", "bytes"],
    "types": {"ok": bool, "path": str, "bytes": int},
}
CREATE_DIR_RETURN = {
    "required": ["ok", "path"],
    "types": {"ok": bool, "path": str},
}
DELETE_PATH_RETURN = {
    "required": ["ok", "path"],
    "types": {"ok": bool, "path": str},
}

# checkpoint-066：Agent 可在对话中安装插件/技能（安装后设置面板自动可见）
INSTALL_PLUGIN_RETURN = {
    "required": ["ok", "name"],
    "types": {"ok": bool, "name": str},
}
INSTALL_SKILL_RETURN = {
    "required": ["ok", "name"],
    "types": {"ok": bool, "name": str},
}

TOOLS = {
    "list_dir": {
        "params": {"path": "str (optional, 默认 working_dir)"},
        "return_schema": LIST_DIR_RETURN,
    },
    "read_file": {
        "params": {"path": "str"},
        "return_schema": READ_FILE_RETURN,
    },
    "write_file": {
        "params": {"path": "str", "content": "str"},
        "return_schema": WRITE_FILE_RETURN,
    },
    "create_dir": {
        "params": {"path": "str"},
        "return_schema": CREATE_DIR_RETURN,
    },
    # 2026-08-28 权限重构：删除工具（敏感路径删除/覆盖需用户确认）
    "delete_path": {
        "params": {"path": "str"},
        "return_schema": DELETE_PATH_RETURN,
    },
    # TS-104 R01：联网搜索（网络工具，不走沙盒；出站过 guard）
    "web_search": {
        "params": {"query": "str (required)", "max_results": "int (optional, 默认5 上限10)"},
        "return_schema": WEB_SEARCH_RETURN,
    },
    # checkpoint-066：对话内安装插件/技能（装完设置面板自动可见；出站过 guard）
    "install_plugin": {
        "params": {"source": "str (required，GitHub 仓库 URL 或本地插件目录绝对路径)"},
        "return_schema": INSTALL_PLUGIN_RETURN,
    },
    "install_skill": {
        "params": {"source": "str (required，git 仓库 URL 或含 SKILL.md 的本地目录绝对路径)"},
        "return_schema": INSTALL_SKILL_RETURN,
    },
}


class NoopAuthorizer:
    """无真实授权器时的默认语义：敏感操作一律拒绝（安全优先）。

    2026-08-28 权限宽松化后，沙盒不再拦截普通越界读写；
    authorizer 仅在"敏感系统位置的删除/覆盖"时被调用。
    无真实用户交互通道时，这类敏感操作直接拒绝（返回 False），
    避免静默执行高危动作。普通读写操作不经过本回调，不受影响。
    """
    async def __call__(self, tool_name: str, path: str, action: str) -> bool:
        return False


# ---------- 有效工具名集合（执行统一走 _exec_on_path；此处仅做存在性判定）----------
_TOOL_NAMES = set(TOOLS.keys())

# 工具 → 动作类型（敏感判定：仅 delete / 覆盖已存在的敏感目标 需确认）
_ACTION = {"list_dir": "list", "read_file": "read", "write_file": "write",
           "create_dir": "mkdir", "delete_path": "delete"}


# ---------- RETURN_SCHEMA 校验 ----------
def _validate(result: dict, schema: dict) -> list[str]:
    problems = []
    for key in schema.get("required", []):
        if key not in result:
            problems.append(f"missing:{key}")
    for key, typ in schema.get("types", {}).items():
        if key in result and not isinstance(result[key], typ):
            problems.append(f"bad_type:{key}")
    ek = schema.get("entry_keys")
    # TS-104：entry 字段名可由 schema 指定（默认 entries；web_search 用 results）
    entry_field = schema.get("entry_field", "entries")
    if ek and isinstance(result.get(entry_field), list):
        for e in result[entry_field]:
            if not (isinstance(e, dict) and ek.issubset(e.keys())):
                problems.append("bad_entry")
                break
    return problems


# ---------- 统一入口（2026-08-28 权限宽松化重构）----------
async def execute(tool_name: str, args: dict, sandbox_root: str | Path, authorizer=None) -> dict:
    """工具统一入口。

    权限策略（用户授权宽松化，2026-08-28）：
    - 工作目录（sandbox_root）仅作默认读写锚点，不作围栏——任何位置的读/写/建目录/列目录默认放行
    - 唯一需用户确认的操作：对"敏感系统位置"（系统目录/用户关键资产/应用自身数据）的【删除】；
      写入/修改（含覆盖已有文件、修改配置）一律直接放行。
    - 删除确认走 authorizer（前端弹窗）；无 authorizer 时敏感删除直接拒绝（不静默执行）。
    """
    args = args or {}

    # TS-104 R01：网络工具不走文件路径，独立分支（出站仍 100% 过 guard，见 web_search.py）
    if tool_name == "web_search":
        try:
            result = await _web_search(args)
        except NetworkGuardError as e:
            # guard 拒绝 → 结构化工具错误（Agent 据此如实告知用户，禁止绕过）
            return {"ok": False, "error": f"network_guard_denied: {e.message}"}
        except Exception as e:  # 超时/连接失败等 → 不裸抛
            return {"ok": False, "error": f"search_failed: {e}"}
        # 错误结果直接返回（与文件工具一致：error 路径不走 schema 校验，避免覆盖原始错误）
        if not result.get("ok"):
            return result
        problems = _validate(result, WEB_SEARCH_RETURN)
        if problems:
            return {"ok": False, "error": f"schema_violation: {', '.join(problems)}"}
        return result

    # checkpoint-066：对话内安装插件/技能。复用与设置面板相同的安装接口，
    # 因此安装结果立即出现在设置 → 插件管理 / 技能列表中（无需重启）。
    if tool_name in ("install_plugin", "install_skill"):
        src = args.get("source")
        if not isinstance(src, str) or not src.strip():
            return {"ok": False, "error": "bad_arg: source（需要 GitHub 仓库 URL 或本地目录绝对路径）"}
        src = src.strip()
        try:
            if tool_name == "install_plugin":
                from sidecar.plugin_loader.loader import PluginLoader
                info = await PluginLoader().install_from_github(src)
            else:
                import asyncio as _asyncio
                from sidecar.skills_mgr.manager import install_skill_from_repo
                # 同步函数（内含 120s git clone）→ 放线程池，避免阻塞事件循环
                res = await _asyncio.to_thread(install_skill_from_repo, src)
                if not res.get("ok"):
                    return {"ok": False, "error": f"install_failed: {res.get('error', '未知错误')}"}
                info = {"name": res.get("name", "")}
        except (ValueError, Exception) as e:  # clone 失败/路径非法/超时
            return {"ok": False, "error": f"install_failed: {e}"}
        result = {"ok": True, "name": info.get("name", "")}
        problems = _validate(result, TOOLS[tool_name]["return_schema"])
        if problems:
            return {"ok": False, "error": f"schema_violation: {', '.join(problems)}"}
        return result

    if tool_name not in _TOOL_NAMES:
        return {"ok": False, "error": f"unknown_tool: {tool_name}"}
    root = Path(sandbox_root).expanduser().resolve()
    action = _ACTION[tool_name]

    # 解析目标路径（相对路径基于工作目录；绝对路径原样；符号链接跟随；双前缀自纠正）
    rel = args.get("path")
    if rel is None and tool_name == "list_dir":
        resolved = root
    else:
        if not isinstance(rel, str) or not rel:
            return {"ok": False, "error": "bad_arg: path"}
        resolved = resolve_sandboxed_path(rel, sandbox_root)
        if resolved is None:
            return {"ok": False, "error": f"bad_path: {rel}"}

    # 敏感判定（用户 2026-08-29 方案 B 定稿，M3 前置安全加固 S1）：
    # 仅【系统敏感位置】的 删除/写入/建目录 需要用户确认；
    # 非敏感越界（~/Desktop、其他项目目录）全部放行；读取任何位置都不拦截。
    # 敏感清单复用 sandbox.is_sensitive_path()（/System、/etc、/usr、~/.ssh、~/.subagent 等）。
    needs_confirm = action in ("delete", "write", "mkdir")
    if needs_confirm and is_sensitive_path(resolved):
        if authorizer is None:
            return {"ok": False,
                    "error": f"denied: 敏感路径{ {'delete':'删除','write':'写入','mkdir':'建目录'}[action] }需用户确认（当前无授权通道）: {resolved}"}
        allowed = await authorizer(tool_name, str(resolved), action)
        if allowed is False:
            return {"ok": False, "error": "denied_by_user"}

    # 执行（无沙盒拦截；路径校验已在上面完成）
    try:
        result = await _exec_on_path(tool_name, args, resolved, root)
    except ValueError as e:
        return {"ok": False, "error": str(e)}
    problems = _validate(result, TOOLS[tool_name]["return_schema"])
    if problems:
        return {"ok": False, "error": f"schema_violation: {', '.join(problems)}"}
    return result


async def _exec_on_path(tool_name: str, args: dict, target: Path, root: Path | None = None) -> dict:
    """在已解析的目标路径上执行工具（无沙盒限制；敏感判定由 execute 前置完成）。"""
    try:
        if tool_name == "list_dir":
            if not target.is_dir():
                hint = (f"not_a_dir: {args.get('path') or ''}（解析后: {target}，该目录尚不存在"
                        f"——可能还未创建；如需创建请用 create_dir/mkdir，或先 list_dir 其父目录确认结构；"
                        f"沙盒根: {root}）")
                if target.is_file():
                    hint = (f"not_a_dir: {args.get('path') or ''}（该路径是【文件】不是目录；"
                            f"请用 read_file 读取: {target}）")
                raise ValueError(hint)
            entries = []
            for p in sorted(target.iterdir(), key=lambda x: x.name):
                try:
                    if p.is_symlink():
                        ftype = "symlink"
                    elif p.is_dir():
                        ftype = "dir"
                    else:
                        ftype = "file"
                    size = p.stat().st_size if p.is_file() else 0
                except OSError:
                    ftype, size = "file", 0
                entries.append({"name": p.name, "type": ftype, "size": size})
            return {"ok": True, "entries": entries}
        if tool_name == "read_file":
            if not target.is_file():
                _root_hint = f"；沙盒根: {root}" if root is not None else ""
                raise ValueError(f"not_a_file: {target.name}（解析后: {target}，文件不存在{_root_hint}。"
                                 f"请先 list_dir 确认目录内容，或使用绝对路径）")
            size = target.stat().st_size
            # checkpoint-067 R-4：图片文件不读字节成乱码，改返回 base64 + 图片标记，
            # 由 loop 注入视觉输入，让多模态模型真正读图（修复"自称没 OCR 能力"）。
            if target.suffix.lower() in IMAGE_EXTS:
                import base64 as _b64
                b64 = _b64.b64encode(target.read_bytes()).decode("ascii")
                return {"ok": True, "_kind": "image", "path": str(target),
                        "image_base64": b64, "size": size,
                        "content": f"[图片文件 {target.name}，{size} 字节，已转为图像输入]"}
            content = target.read_bytes()[:MAX_READ_BYTES].decode("utf-8", errors="replace")
            return {"ok": True, "content": content, "size": size, "truncated": size > MAX_READ_BYTES}
        if tool_name == "write_file":
            content = args.get("content")
            if not isinstance(content, str):
                raise ValueError("bad_arg: content")
            data = content.encode("utf-8")
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            return {"ok": True, "path": str(target), "bytes": len(data)}
        if tool_name == "create_dir":
            target.mkdir(parents=True, exist_ok=True)
            return {"ok": True, "path": str(target)}
        if tool_name == "delete_path":
            if not target.exists():
                raise ValueError(f"not_found: {target}")
            if target.is_dir():
                shutil.rmtree(target)
            else:
                target.unlink()
            return {"ok": True, "path": str(target)}
        return {"ok": False, "error": f"unknown_tool: {tool_name}"}
    except OSError as e:
        return {"ok": False, "error": f"os_error: {e.strerror}"}
