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
"""Config store — load/save/defaults for ~/.subagent/config.json.

Single source of truth for every address/port/path. No hardcoded values
elsewhere in the codebase.
"""
from __future__ import annotations

import json
import threading
from pathlib import Path
from typing import Any

# RLock: some public helpers re-enter each other (data_root -> ...), so the
# lock must be re-entrant.
_LOCK = threading.RLock()

DEFAULT_CONFIG: dict[str, Any] = {
    "ollama_base_url": "http://localhost:11434",
    "proxy_http_port": 21081,
    "proxy_socks_port": 21080,
    "data_root": "~/.subagent",
    "default_model": "qwen3.8",
    "plugin_repos": [],
    "egress_allowlist": [],
    # 本地服务（应用自身端口也可配置）
    "sidecar_host": "127.0.0.1",
    "sidecar_port": 8765,
    "vite_port": 5173,
    # 网络模式（2026-08-28 融合方案：开关→三态）
    # auto（默认）：境内/名单直连；境外放行直连尝试，连续失败自动熔断（防无代理空转）
    # proxy：境外走配置代理（用户已启动代理软件时使用）
    # 遗留值 on/off 读取时自动迁移为 proxy/auto
    "network_switch": "auto",
    # 联网搜索端点（TS-104 R01；零硬编码：工具只读本键，不写死地址）
    # 2026-08-28 融合方案：搜索工具多源自动降级（按网络模式决定优先顺序）
    "web_search_url": "https://html.duckduckgo.com/html/",
    "web_search_url_cn": "https://www.so.com/s",
    # 工具调用最大轮次（2026-08-28：原硬编码 5 轮不够用，改为可配置；
    # 防"无效空转"由连续失败熔断+重复搜索拦截兜底，故轮次上限可放大，支撑大型任务）
    "max_tool_rounds": 200,
    # M2 上下文可视化：智能压缩配置（2026-08-28）
    "compact_archive_dir": "~/.subagent/compressed",  # 压缩归档目录（展开 ~ 后用）
    "allow_auto_compact": False,                       # 未勾选时禁止一切自动压缩
    "compact_keep_recent": 10,                         # 压缩时保护最近 N 条消息不动
    # M3-2（TS-108）：多 Agent —— 允许主 Agent 委派时自动新建子 Agent（决策 9，默认开）
    "auto_create_sub_agents": True,
    # M5（TS-111）：稳定性与降级
    "reconnect_max_attempts": 3,   # 前端断线重连最大次数（1-10）
    "heartbeat_interval": 15.0,    # SSE 心跳基础间隔秒（5-60；实际取动态值，见 app.py）
    # M6（TS-112）：推理后端抽象层
    "inference_backend": "ollama",       # ollama / openai_compatible（LM Studio、llama.cpp server、vLLM 等）
    "inference_base_url": "",            # openai_compatible 时必填（如 http://localhost:1234/v1）；ollama 用 ollama_base_url
    "inference_api_key": "",             # 可选（远程中转服务才需要）
    "openai_compat_supports_tools": True,  # OpenAI 兼容后端是否支持工具调用（部分本地服务器不支持）
    # M7（TS-113）：体验与契约增强
    "default_export_dir": "",            # 默认导出目录（空=项目工作目录）；圆桌导出/交卷报告/会话导出统一走此配置
    "vision_parse_attachments": False,   # 圆桌图片附件是否走视觉模型识别（默认关）
    # checkpoint-068（3.22 委派健壮性 + 3.21 D-2/D-4）：
    "delegation_activity_timeout": 900,  # 委派活性超时（秒）：连续这么久无任何产出即判卡死中止；0=关闭
    "delegation_max_retries": 2,         # 同一任务委派同一目标失败后的最大重试次数；0=不限（不推荐）
    "delegation_auto_cleanup": False,    # 委派成功（success）后自动删除子 Agent 与会话（须用户授权；默认关）
    "model_parallel": False,             # D-4 大模型并行开关：关=串行队列+自动切换模型
    "task_concurrency": False,           # D-4 任务并发开关：关=委派串行排队；开=允许并行执行
    # checkpoint-047：插件/技能改为逐项启用开关（用户需求：针对单个插件和技能）。
    # 插件状态存 <plugins>/plugins_state.json；技能状态随技能自身元数据。
    # 原全局 plugins_enabled/skills_enabled 已废弃（get_config 幂等清理旧值）。
}

_MEM: dict[str, Any] = {}


def _expand(raw: str) -> Path:
    return Path(raw).expanduser()


def data_root() -> Path:
    """Resolve data_root (~ expanded) — root of all SubAgent data."""
    with _LOCK:
        raw = _MEM.get("data_root")
    if raw is None:
        raw = DEFAULT_CONFIG["data_root"]
    return _expand(raw)


def projects_root() -> Path:
    p = data_root() / "projects"
    p.mkdir(parents=True, exist_ok=True)
    return p


def plugins_root() -> Path:
    p = data_root() / "plugins"
    p.mkdir(parents=True, exist_ok=True)
    return p


def get_config_path() -> Path:
    return data_root() / "config.json"


def _load_from_disk() -> dict[str, Any]:
    """Read config.json if present. Caller holds _LOCK (RLock, re-entrant)."""
    path = get_config_path()
    if path.exists():
        try:
            on_disk = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(on_disk, dict):
                return on_disk
        except Exception as e:
            print(f"[config] WARN: failed to read {path}: {e}", flush=True)
    return {}


def _save(cfg: dict[str, Any]) -> None:
    """Write config.json 原子写. Caller holds _LOCK.

    M3 前置安全加固 L1：先写临时文件 + os.replace 原子替换，
    避免写一半被 kill 导致 config.json 半截、重启丢配置。
    """
    import os
    path = get_config_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    data = json.dumps(cfg, ensure_ascii=False, indent=2)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(data, encoding="utf-8")
    os.replace(str(tmp), str(path))  # 同目录原子替换


import re as _re

def _valid_allowlist_entry(e: str) -> bool:
    """合法放行名单项：普通域名（baidu.com）或 *.xxx 通配（*.qq.com）。

    不接受：空串、单标签、IP（1.2.3.4 / 999.999.999）、URL、含下划线。
    """
    e = e.strip().lower().rstrip(".")
    if not e:
        return False
    if e.startswith("*."):
        rest = e[2:]
    else:
        rest = e
    labels = rest.split(".")
    if len(labels) < 2:
        return False
    label_pat = _re.compile(r"^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$")
    if not all(label_pat.match(lb) for lb in labels):
        return False
    # 排除纯数字标签（IP / 999.999.999 形态）：至少有一个标签含字母
    if not any(_re.search(r"[a-z]", lb) for lb in labels):
        return False
    return True


def _validate(cur: dict[str, Any]) -> None:
    u = cur.get("ollama_base_url", "")
    if not (isinstance(u, str) and u.startswith(("http://", "https://"))):
        raise ValueError("ollama_base_url 必须是 http(s):// 地址")
    for k in ("sidecar_port", "vite_port", "proxy_http_port", "proxy_socks_port"):
        v = cur.get(k)
        if not isinstance(v, int) or not (1 <= v <= 65535):
            raise ValueError(f"{k} 必须是 1-65535 的整数")
    dr = cur.get("data_root", "")
    if not isinstance(dr, str) or not dr.strip():
        raise ValueError("data_root 不能为空")
    pr = cur.get("plugin_repos")
    if pr is not None and not (isinstance(pr, list) and all(isinstance(x, str) for x in pr)):
        raise ValueError("plugin_repos 必须是字符串数组")
    dm = cur.get("default_model", "")
    if not isinstance(dm, str) or not dm.strip():
        raise ValueError("default_model 不能为空")
    if cur.get("network_switch") not in ("on", "off", "auto", "proxy"):
        raise ValueError("network_switch 必须是 auto/proxy（遗留值 on/off 会自动迁移）")
    al = cur.get("egress_allowlist")
    if al is not None:
        if not (isinstance(al, list) and all(isinstance(x, str) for x in al)):
            raise ValueError("egress_allowlist 必须是字符串数组")
        for entry in al:
            if not _valid_allowlist_entry(entry):
                raise ValueError(f"egress_allowlist 含非法域名: {entry!r}（需为合法域名，支持 *.xxx 通配）")
    mtr = cur.get("max_tool_rounds")
    if not isinstance(mtr, int) or not (1 <= mtr <= 1000):
        raise ValueError("max_tool_rounds 必须是 1-1000 的整数")
    # M2 上下文可视化：压缩配置校验
    cad = cur.get("compact_archive_dir")
    if cad is not None:
        if not (isinstance(cad, str) and cad.strip() and (cad.startswith("/") or cad.startswith("~"))):
            raise ValueError("compact_archive_dir 必须是绝对路径或含 ~ 的合法路径")
    aac = cur.get("allow_auto_compact")
    if aac is not None and not isinstance(aac, bool):
        raise ValueError("allow_auto_compact 必须是 bool")
    ckr = cur.get("compact_keep_recent")
    if ckr is not None and (not isinstance(ckr, int) or not (2 <= ckr <= 100)):
        raise ValueError("compact_keep_recent 必须是 2-100 的整数")
    # M3-2（TS-108）：多 Agent 配置校验
    acsa = cur.get("auto_create_sub_agents")
    if acsa is not None and not isinstance(acsa, bool):
        raise ValueError("auto_create_sub_agents 必须是 bool")
    # M5（TS-111）：稳定性配置校验
    rma = cur.get("reconnect_max_attempts")
    if rma is not None and (not isinstance(rma, int) or isinstance(rma, bool) or not (1 <= rma <= 10)):
        raise ValueError("reconnect_max_attempts 必须是 1-10 的整数")
    hbi = cur.get("heartbeat_interval")
    if hbi is not None and (not isinstance(hbi, (int, float)) or isinstance(hbi, bool)
                            or not (5.0 <= float(hbi) <= 60.0)):
        raise ValueError("heartbeat_interval 必须是 5-60 的秒数")
    # M6（TS-112）：推理后端配置校验
    ib = cur.get("inference_backend")
    if ib is not None and ib not in ("ollama", "openai_compatible"):
        raise ValueError("inference_backend 必须是 ollama 或 openai_compatible")
    if cur.get("inference_backend") == "openai_compatible" and not str(cur.get("inference_base_url") or "").strip():
        raise ValueError("openai_compatible 后端必须填写 inference_base_url（如 http://localhost:1234/v1）")
    ocs = cur.get("openai_compat_supports_tools")
    if ocs is not None and not isinstance(ocs, bool):
        raise ValueError("openai_compat_supports_tools 必须是 bool")
    # M7（TS-113）：导出目录与附件视觉解析校验
    ded = cur.get("default_export_dir")
    if ded is not None and not isinstance(ded, str):
        raise ValueError("default_export_dir 必须是字符串（空=项目工作目录）")
    vpa = cur.get("vision_parse_attachments")
    if vpa is not None and not isinstance(vpa, bool):
        raise ValueError("vision_parse_attachments 必须是 bool")
    # checkpoint-068：委派健壮性与并发开关校验
    dat = cur.get("delegation_activity_timeout")
    if dat is not None and (not isinstance(dat, (int, float)) or isinstance(dat, bool) or not (0 <= float(dat) <= 86400)):
        raise ValueError("delegation_activity_timeout 必须是 0-86400 的秒数（0=关闭）")
    dmr = cur.get("delegation_max_retries")
    if dmr is not None and (not isinstance(dmr, int) or isinstance(dmr, bool) or not (0 <= dmr <= 10)):
        raise ValueError("delegation_max_retries 必须是 0-10 的整数（0=不限）")
    for k in ("delegation_auto_cleanup", "model_parallel", "task_concurrency"):
        v = cur.get(k)
        if v is not None and not isinstance(v, bool):
            raise ValueError(f"{k} 必须是 bool")


def get_config() -> dict[str, Any]:
    """Merged config (defaults + on-disk). Initializes config.json on first
    run (writes missing keys). Thread-safe."""
    global _MEM
    with _LOCK:
        on_disk = _load_from_disk()
        merged = {**DEFAULT_CONFIG, **on_disk}
        missing = [k for k in DEFAULT_CONFIG if k not in on_disk]
        # 2026-08-28 融合方案：网络开关旧值自动迁移（off→auto / on→proxy），幂等写回
        raw_switch = str(merged.get("network_switch", "")).lower()
        if raw_switch in ("on", "off"):
            merged["network_switch"] = "proxy" if raw_switch == "on" else "auto"
            missing.append("network_switch")  # 触发写盘
        # 2026-08-28 问题1修复：放行名单幂等自愈——
        # 用户现有 config 的 egress_allowlist 可能是空数组（磁盘值覆盖了默认值），
        # 导致搜索工具无法访问国内源。自动补入缺失的默认条目。
        default_al = DEFAULT_CONFIG.get("egress_allowlist") or []
        cur_al = merged.get("egress_allowlist") or []
        added = [e for e in default_al if e not in cur_al]
        if added:
            merged["egress_allowlist"] = cur_al + added
            missing.append("egress_allowlist")  # 触发写盘
        # checkpoint-047 幂等迁移：全局插件/技能开关已废弃（改逐项开关），清理旧值
        for legacy in ("plugins_enabled", "skills_enabled"):
            if legacy in merged:
                merged.pop(legacy)
                missing.append(legacy)  # 触发写盘（移除）
        if missing:
            _save(merged)
        _MEM = merged
        return dict(merged)


def reload_config(patch: dict[str, Any] | None = None) -> dict[str, Any]:
    """Merge a patch into config.json (with validation) and return the new
    config. Raises ValueError on unknown keys or bad values."""
    global _MEM
    with _LOCK:
        cur = {**DEFAULT_CONFIG, **_load_from_disk()}
        if patch:
            for k, v in patch.items():
                if k not in DEFAULT_CONFIG:
                    raise ValueError(f"未知配置项: {k}")
                cur[k] = v
        _validate(cur)
        _save(cur)
        _MEM = dict(cur)
        return dict(cur)
