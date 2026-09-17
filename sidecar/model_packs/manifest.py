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
"""0.4.29（P1）模型包 manifest / catalog 规范与校验（纯函数，无 IO、无配置依赖）。

规范（docs/plans/0.4.29 计划 D2/D4）：

  catalog.json = {"version": 1, "packs": [PACK, ...]}
  PACK = {
    pack_id, name, task, format, driver, version, description, size_bytes,
    min_app_version, homepage, license,
    context_length（可选，P2 新增：正整数；llama.cpp 驱动启动时以 -c 注入，
                   /api/context/limit 也据此回答；缺省=不写，服务端用模型自身默认）,
    files: [{path, size_bytes, sha256, sources: [URL, ...]}, ...]
  }

硬约束：
  * 多文件是硬需求（ONNX 模型 = 模型本体 + tokenizer/tokens 多文件），files 不得为空；
  * files[].path 必须是相对路径——拒绝对路径 / ".." 段 / 分隔符开头 / 反斜杠
    （storage/store.py _sanitize_attachment_name 精神：两种分隔符都要挡；
    差异：附件名做净化回退，这里是**校验拒绝**——目录清单来自外部源，
    净化会静默改路径导致下载落点与声明不符，必须显式拒绝）；
  * 保留名：path 不得为 "manifest.json"（安装时写入的清单副本）或以 ".partial/"
    开头（下载暂存目录），防包文件覆盖管理文件。
"""
from __future__ import annotations

import re as _re
from typing import Any

# 枚举域（D4；新任务类型/格式/驱动随应用版本发布扩展，见计划 D7）
TASKS = ("asr", "chat", "embedding")
FORMATS = ("onnx", "gguf")
DRIVERS = ("onnxruntime", "llamacpp")

CATALOG_VERSION = 1

# pack_id slug：小写字母/数字/`-`/`_`，1~64 长（注册表键与目录名共用，
# 必须同时是安全的单层目录名——slug 字符集天然不含分隔符与点号）
_PACK_ID_RE = _re.compile(r"^[a-z0-9_-]{1,64}$")

# 相对路径长度上限（跨平台留余量；Windows MAX_PATH 260 的教训，
# 安装根已占一段，单文件相对路径不宜过长）
_REL_PATH_MAX = 240
# 控制字符（含 NUL）：终端/日志注入与 C  API 截断风险
_CTRL_CHARS = {chr(c) for c in range(0, 32)} | {chr(127)}

# 允许的来源 URL scheme（http(s) 走 guard 漏斗；file 供开发/测试/导入本地包）
_SOURCE_SCHEMES = ("http://", "https://", "file://")


def valid_pack_id(pack_id: Any) -> bool:
    """pack_id 是否为合法 slug（小写字母数字 `-` `_`，1~64 长）。"""
    return isinstance(pack_id, str) and bool(_PACK_ID_RE.match(pack_id))


def validate_rel_path(path: Any) -> str | None:
    """校验 files[].path 为安全的相对路径。合法返回 None，非法返回中文错误文案。

    拒绝清单（每条对应一类真实攻击/事故）：
      ① 非字符串 / 空串；
      ② 绝对路径（POSIX `/` 开头、Windows 盘符 `C:`、UNC `\\\\`）；
      ③ 反斜杠——跨平台时 Windows 会把它当分隔符，等于开后门（两种分隔符都要挡）；
      ④ `.` / `..` 段——路径穿越出包目录；
      ⑤ 空段（`a//b`）与首尾空白——不同文件系统归一化行为不一致；
      ⑥ 控制字符；
      ⑦ 保留名：manifest.json（安装时写入的清单副本）、.partial（下载暂存目录）。
    """
    if not isinstance(path, str) or not path:
        return "files[].path 必须是非空字符串（相对路径）"
    if len(path) > _REL_PATH_MAX:
        return f"files[].path 超过 {_REL_PATH_MAX} 字符上限: {path[:40]!r}..."
    if any(ch in _CTRL_CHARS for ch in path):
        return f"files[].path 含控制字符: {path!r}"
    if "\\" in path:
        return f"files[].path 含反斜杠（路径分隔符统一为 /）: {path!r}"
    if path.startswith("/"):
        return f"files[].path 不允许绝对路径: {path!r}"
    # Windows 盘符（C:/x）与 UNC 形态在POSIX字符串里不以 / 开头，单独挡
    if len(path) >= 2 and path[1] == ":" and path[0].isalpha():
        return f"files[].path 不允许 Windows 盘符绝对路径: {path!r}"
    if path != path.strip():
        return f"files[].path 首尾含空白字符: {path!r}"
    segs = path.split("/")
    for seg in segs:
        if seg == "":
            return f"files[].path 含空路径段（形如 a//b）: {path!r}"
        if seg in (".", ".."):
            return f"files[].path 含 {seg!r} 段（路径穿越风险）: {path!r}"
    if segs[0] == ".partial":
        return f"files[].path 占用保留目录 .partial/: {path!r}"
    if path == "manifest.json":
        return "files[].path 占用保留名 manifest.json（安装时写入的清单副本）"
    return None


def _is_pos_int(v: Any) -> bool:
    # bool 是 int 子类，尺寸/版本号语义上 True/False 不是合法数值
    return isinstance(v, int) and not isinstance(v, bool) and v > 0


_SHA256_RE = _re.compile(r"^[0-9a-fA-F]{64}$")


def _validate_file_entry(f: Any, idx: int, errors: list[str]) -> None:
    tag = f"files[{idx}]"
    if not isinstance(f, dict):
        errors.append(f"{tag} 必须是对象")
        return
    p_err = validate_rel_path(f.get("path"))
    if p_err:
        errors.append(p_err.replace("files[]", tag, 1))
    if not _is_pos_int(f.get("size_bytes")):
        errors.append(f"{tag}.size_bytes 必须是正整数（得到 {f.get('size_bytes')!r}）")
    sha = f.get("sha256")
    if not (isinstance(sha, str) and _SHA256_RE.match(sha)):
        errors.append(f"{tag}.sha256 必须是 64 位十六进制字符串（得到 {str(sha)[:40]!r}）")
    sources = f.get("sources")
    if not (isinstance(sources, list) and sources):
        errors.append(f"{tag}.sources 必须是非空 URL 数组（多源按序回退）")
    else:
        for si, s in enumerate(sources):
            if not (isinstance(s, str) and s.startswith(_SOURCE_SCHEMES)):
                errors.append(
                    f"{tag}.sources[{si}] 必须是 http(s):// 或 file:// URL（得到 {str(s)[:60]!r}）")


def validate_pack(pack: Any) -> list[str]:
    """校验单个 PACK 条目，返回错误文案列表（空列表 = 合法）。

    错误文案要"明确"：指出字段、期望值、实际值——catalog 由第三方仓库托管，
    打包者拿到模糊错误无法定位是哪一行哪一个字段。
    """
    errors: list[str] = []
    if not isinstance(pack, dict):
        return ["pack 条目必须是对象"]
    if not valid_pack_id(pack.get("pack_id")):
        errors.append(
            f"pack_id 必须是 slug（小写字母/数字/-/_，1~64 长），得到 {str(pack.get('pack_id'))[:40]!r}")
    if not (isinstance(pack.get("name"), str) and pack["name"].strip()):
        errors.append("name 必须是非空字符串")
    task = pack.get("task")
    if task not in TASKS:
        errors.append(f"task 必须是 {('/'.join(TASKS))} 之一，得到 {task!r}")
    fmt = pack.get("format")
    if fmt not in FORMATS:
        errors.append(f"format 必须是 {('/'.join(FORMATS))} 之一，得到 {fmt!r}")
    drv = pack.get("driver")
    if drv not in DRIVERS:
        errors.append(f"driver 必须是 {('/'.join(DRIVERS))} 之一，得到 {drv!r}")
    if not (isinstance(pack.get("version"), str) and pack["version"].strip()):
        errors.append("version 必须是非空字符串（语义化版本，如 1.0.0）")
    for opt in ("description", "min_app_version", "homepage", "license"):
        v = pack.get(opt, "")
        if not isinstance(v, str):
            errors.append(f"{opt} 必须是字符串（可空），得到 {type(v).__name__}")
    if not _is_pos_int(pack.get("size_bytes")):
        errors.append(f"size_bytes 必须是正整数（包总字节数），得到 {pack.get('size_bytes')!r}")
    # context_length：可选键（P2）。写了就必须是正整数——它会被驱动拼进 llama-server
    # 的 -c 启动参数并被 /api/context/limit 采用，非法值（0/负数/字符串/布尔）
    # 要么让 llama-server 拒启动，要么让上下文指示器按错误上限算占比，入口拒掉最省事。
    cl = pack.get("context_length")
    if cl is not None and not _is_pos_int(cl):
        errors.append(f"context_length 必须是正整数（可选键，不需要请整键省略），得到 {cl!r}")
    files = pack.get("files")
    if not (isinstance(files, list) and files):
        errors.append("files 必须是非空数组（多文件是硬需求：模型本体+tokenizer 等）")
    else:
        seen_paths: set[str] = set()
        for i, f in enumerate(files):
            _validate_file_entry(f, i, errors)
            if isinstance(f, dict) and isinstance(f.get("path"), str):
                if f["path"] in seen_paths:
                    errors.append(f"files[{i}].path 重复: {f['path']!r}")
                seen_paths.add(f["path"])
        # 一致性：pack.size_bytes 应等于 files 之和（不一致多半意味着清单写错，
        # 进度条与磁盘预留都会跟着错——宁可在入口拒掉；各字段错误各自独立报告）
        if _is_pos_int(pack.get("size_bytes")) and all(
                isinstance(f, dict) and _is_pos_int(f.get("size_bytes")) for f in files):
            total = sum(f["size_bytes"] for f in files)
            if total != pack["size_bytes"]:
                errors.append(
                    f"size_bytes({pack['size_bytes']}) 与 files 之和({total}) 不一致")
    return errors


def validate_catalog(data: Any) -> list[str]:
    """校验整个 catalog.json，返回错误文案列表（空列表 = 合法）。"""
    errors: list[str] = []
    if not isinstance(data, dict):
        return ["catalog 必须是 JSON 对象"]
    if data.get("version") != CATALOG_VERSION:
        errors.append(
            f"catalog.version 必须是 {CATALOG_VERSION}，得到 {data.get('version')!r}")
    packs = data.get("packs")
    if not isinstance(packs, list):
        errors.append("catalog.packs 必须是数组")
        return errors
    seen_ids: set[str] = set()
    for i, p in enumerate(packs):
        for e in validate_pack(p):
            errors.append(f"packs[{i}]: {e}")
        if isinstance(p, dict):
            pid = p.get("pack_id")
            if isinstance(pid, str):
                if pid in seen_ids:
                    errors.append(f"packs[{i}]: pack_id 重复: {pid!r}")
                seen_ids.add(pid)
    return errors
