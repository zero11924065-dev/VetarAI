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
"""0.4.29（P1）模型包存储：安装根解析 + registry.json 注册表（原子写持久化）。

目录布局（计划 D2）：
  <packs_root>/
    registry.json                 注册表（原子写，plugins_state.json 先例）
    <pack_id>/
      manifest.json               安装时写入的清单副本（驱动/面板据此读元数据）
      <files...>                  权重与 tokenizer 等（按 files[].path 相对布局）
      .partial/                   部分下载态：<path>.part（中断/取消后保留供续传）

安装根解析链（勿改优先级，env 供测试/打包隔离）：
  env VETARAI_MODEL_PACKS_DIR > config model_packs_dir > data_root()/models/packs
铁律：永不写 .app 内——解析结果落在 *.app/Contents/ 下直接拒绝（打包后
Resources 只读且重签失效，写进去等于静默丢模型）。
"""
from __future__ import annotations

import json
import os
import shutil
import threading
from datetime import datetime
from pathlib import Path
from typing import Any

from sidecar.model_packs.manifest import valid_pack_id

_LOCK = threading.RLock()

ENV_PACKS_DIR = "VETARAI_MODEL_PACKS_DIR"


def packs_root() -> Path:
    """解析模型包安装根（每次调用实时解析：设置页改 model_packs_dir 立即生效，
    与 connector 动态读 config 同理；模块级缓存会把测试隔离也一并坑掉）。

    优先级：env VETARAI_MODEL_PACKS_DIR > config model_packs_dir > data_root()/models/packs。
    """
    raw = os.environ.get(ENV_PACKS_DIR, "").strip()
    if not raw:
        try:
            from sidecar.config import get_config
            raw = str(get_config().get("model_packs_dir") or "").strip()
        except Exception:
            raw = ""
    if raw:
        p = Path(raw).expanduser()
    else:
        from sidecar.config import data_root
        p = Path(data_root()) / "models" / "packs"
    # 封印铁律：安装根永不落在 .app 包内（打包后 Resources 只读且重签会失效）
    parts = [str(x) for x in p.parts]
    if any(part.endswith(".app") for part in parts):
        raise RuntimeError(f"模型包安装根不允许位于 .app 包内: {p}")
    p.mkdir(parents=True, exist_ok=True)
    return p


def registry_path() -> Path:
    return packs_root() / "registry.json"


def pack_dir(pack_id: str) -> Path:
    if not valid_pack_id(pack_id):
        raise ValueError(f"非法 pack_id（须 slug 小写字母/数字/-/_，1~64 长）: {pack_id!r}")
    return packs_root() / pack_id


def partial_dir(pack_id: str) -> Path:
    return pack_dir(pack_id) / ".partial"


def read_registry() -> dict[str, dict[str, Any]]:
    """读注册表；文件缺失/损坏一律返回 {}（损坏不阻断列表，宁可当空装）。"""
    path = registry_path()
    try:
        if path.exists():
            data = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(data, dict):
                return {str(k): v for k, v in data.items() if isinstance(v, dict)}
    except Exception:
        pass
    return {}


def write_registry(reg: dict[str, dict[str, Any]]) -> None:
    """原子写注册表：tmp + os.replace（config/store.py:_save 与
    plugin_loader/loader.py:_write_state 先例）——写一半被 kill 不得留下半截注册表。"""
    with _LOCK:
        path = registry_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_name(path.name + ".tmp")
        tmp.write_text(json.dumps(reg, ensure_ascii=False, indent=2), encoding="utf-8")
        os.replace(str(tmp), str(path))  # 同目录原子替换


def is_installed(pack_id: str) -> bool:
    return pack_id in read_registry()


def get_entry(pack_id: str) -> dict[str, Any] | None:
    return read_registry().get(pack_id)


def register_pack(pack_id: str, pack: dict[str, Any]) -> None:
    """下载全部完成后登记。注册表条目（计划 D2 定稿 schema）：
    {status, installed_at, version, task, format, driver, files, sha256_ok}
    status: "installed"（启用）| "disabled"（禁用，保留文件不删）。
    """
    if not valid_pack_id(pack_id):
        raise ValueError(f"非法 pack_id: {pack_id!r}")
    entry = {
        "status": "installed",  # 默认启用（plugins_state.json 先例）
        "installed_at": datetime.now().isoformat(timespec="seconds"),
        "version": str(pack.get("version", "")),
        "task": str(pack.get("task", "")),
        "format": str(pack.get("format", "")),
        "driver": str(pack.get("driver", "")),
        "files": [
            {"path": f["path"], "size_bytes": f["size_bytes"], "sha256": f["sha256"].lower()}
            for f in pack.get("files", [])
        ],
        "sha256_ok": True,
    }
    with _LOCK:
        reg = read_registry()
        reg[pack_id] = entry
        write_registry(reg)


def unregister_pack(pack_id: str) -> bool:
    """移除注册表条目（卸载清理，plugins_state.json 先例）。不存在返回 False。"""
    with _LOCK:
        reg = read_registry()
        if pack_id not in reg:
            return False
        reg.pop(pack_id)
        write_registry(reg)
    return True


def set_enabled(pack_id: str, enabled: bool) -> bool | None:
    """启用/禁用（toggle 持久化）。返回新状态；未安装返回 None。"""
    with _LOCK:
        reg = read_registry()
        entry = reg.get(pack_id)
        if entry is None:
            return None
        entry["status"] = "installed" if enabled else "disabled"
        write_registry(reg)
    return enabled


def _manifest_copy(pack_id: str) -> dict[str, Any]:
    """读包内 manifest.json 副本（name/description 等展示元数据以它为准，
    注册表只存运行必需字段，避免两处冗余漂移）。"""
    try:
        p = pack_dir(pack_id) / "manifest.json"
        if p.exists():
            data = json.loads(p.read_text(encoding="utf-8"))
            if isinstance(data, dict):
                return data
    except Exception:
        pass
    return {}


def list_installed() -> list[dict[str, Any]]:
    """已安装列表：注册表条目 + 磁盘探测（缺文件/实际占用/半截下载残留）。

    探测以磁盘为准而非盲信注册表——用户可能手动删过文件，
    缺文件的包必须能被前端标出来（否则推理时才发现，排查链路长）。
    """
    out: list[dict[str, Any]] = []
    for pack_id, entry in sorted(read_registry().items()):
        d = pack_dir(pack_id) if valid_pack_id(pack_id) else None
        missing: list[str] = []
        on_disk = 0
        for f in entry.get("files", []):
            fp = (d / f["path"]) if d is not None else None
            if fp is not None and fp.is_file():
                try:
                    on_disk += fp.stat().st_size
                except OSError:
                    pass
            else:
                missing.append(f.get("path", ""))
        has_partial = False
        try:
            pd = partial_dir(pack_id)
            has_partial = pd.is_dir() and any(pd.rglob("*.part"))
        except Exception:
            pass
        man = _manifest_copy(pack_id)
        out.append({
            "pack_id": pack_id,
            "name": str(man.get("name") or pack_id),
            "description": str(man.get("description") or ""),
            "version": entry.get("version", ""),
            "task": entry.get("task", ""),
            "format": entry.get("format", ""),
            "driver": entry.get("driver", ""),
            "status": entry.get("status", "installed"),
            "enabled": entry.get("status") == "installed",
            "installed_at": entry.get("installed_at", ""),
            "files": entry.get("files", []),
            "sha256_ok": bool(entry.get("sha256_ok")),
            "size_bytes": on_disk,
            "missing_files": missing,
            "has_partial": has_partial,
            "dir": str(d) if d is not None else "",
        })
    return out


def remove_pack(pack_id: str) -> bool:
    """卸载：删目录（含 .partial 残留）+ 注册表条目清理。两者都不存在返回 False。

    顺序：先删目录再清注册表——若删目录抛错，注册表条目还在，
    前端仍能显示这个包（标注缺文件），用户可重试卸载；反过来会留下无主的磁盘垃圾。
    """
    existed = is_installed(pack_id)
    try:
        d = pack_dir(pack_id)
    except ValueError:
        return False
    if d.exists():
        shutil.rmtree(d)
        existed = True
    unregister_pack(pack_id)
    return existed
