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
"""PluginLoader — download from GitHub, parse manifest, dynamically load (internal)."""
from __future__ import annotations

import importlib.util
import json
import os as _os
import subprocess
import re as _re
from urllib.parse import urlparse as _urlparse
from sidecar.network.guard import NetworkGuardError
from pathlib import Path
from typing import Any


from sidecar.config import plugins_root
PLUGINS_ROOT = plugins_root()
PLUGINS_ROOT.mkdir(parents=True, exist_ok=True)

# 2026-08-28 修复：环境变量代理绕过守卫的漏洞。
# git 会读取 HTTP_PROXY/HTTPS_PROXY 等环境变量；若继承，则境内/直连请求也会被
# 劫持到未监听的代理端口，且绕过了守卫的"唯一漏斗"契约。出站代理必须 100% 由
# 守卫返回的 -c http.proxy 参数决定，故子进程环境须剥离代理变量。
_PROXY_ENV_KEYS = ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY",
                   "http_proxy", "https_proxy", "all_proxy")


def _egress_env() -> dict:
    """返回剥离了代理变量的子进程环境。"""
    return {k: v for k, v in _os.environ.items() if k not in _PROXY_ENV_KEYS}


class PluginLoader:
    def __init__(self) -> None:
        self._loaded_plugins: dict[str, dict[str, Any]] = {}
        # checkpoint-047：逐项启用状态（用户需求：针对单个插件开关）。
        # 默认启用；状态持久化在 plugins_state.json（卸载时清理条目）。
        self._state_path = PLUGINS_ROOT / "plugins_state.json"

    # ---- 启用状态（checkpoint-047）----

    def _read_state(self) -> dict[str, bool]:
        try:
            if self._state_path.exists():
                data = json.loads(self._state_path.read_text(encoding="utf-8"))
                return {k: bool(v) for k, v in data.items()}
        except Exception:
            pass
        return {}

    def _write_state(self, state: dict[str, bool]) -> None:
        import os as _os2
        tmp = self._state_path.with_name(self._state_path.name + ".tmp")
        tmp.write_text(json.dumps(state, ensure_ascii=False, indent=2), encoding="utf-8")
        _os2.replace(str(tmp), str(self._state_path))

    def is_enabled(self, plugin_name: str) -> bool:
        """插件是否启用（默认 True）。"""
        return self._read_state().get(plugin_name, True)

    def toggle_enabled(self, plugin_name: str) -> bool | None:
        """切换插件启用状态，返回新状态；插件不存在返回 None。"""
        installed = {p["name"] for p in self.list_installed()}
        if plugin_name not in installed:
            return None
        state = self._read_state()
        state[plugin_name] = not state.get(plugin_name, True)
        self._write_state(state)
        return state[plugin_name]

    # ---- 插件备注（问题5，0.4.1）----
    # 独立文件存储（不动 plugins_state.json 结构），{插件名: 备注文本}。
    # 卸载时同步清理；备注仅用户可见说明，不参与任何执行逻辑。

    @property
    def _notes_path(self) -> Path:
        return PLUGINS_ROOT / "plugins_notes.json"

    def _read_notes(self) -> dict[str, str]:
        try:
            if self._notes_path.exists():
                data = json.loads(self._notes_path.read_text(encoding="utf-8"))
                return {k: str(v) for k, v in data.items()}
        except Exception:
            pass
        return {}

    def _write_notes(self, notes: dict[str, str]) -> None:
        import os as _os2
        tmp = self._notes_path.with_name(self._notes_path.name + ".tmp")
        tmp.write_text(json.dumps(notes, ensure_ascii=False, indent=2), encoding="utf-8")
        _os2.replace(str(tmp), str(self._notes_path))

    def get_note(self, plugin_name: str) -> str:
        return self._read_notes().get(plugin_name, "")

    def set_note(self, plugin_name: str, note: str) -> str:
        """设置插件备注（空串=清除），返回最终备注。"""
        notes = self._read_notes()
        note = (note or "").strip()
        if note:
            notes[plugin_name] = note
        else:
            notes.pop(plugin_name, None)
        self._write_notes(notes)
        return notes.get(plugin_name, "")

    # ---- Manifest ----

    def _egress(self, repo_url: str) -> list[str]:
        """对插件仓库域名做出站 guard，返回 git 代理参数（-c http.proxy=... 等）。

        - 本地路径 / 本地 host → 无代理
        - allowlist 命中 → 无代理（直连）
        - switch=off 且被拒 → 抛 NetworkGuardError（安装前拒绝）
        - switch=on 且非名单 → 返回 ["-c http.proxy=<配置代理>", "-c https.proxy=<配置代理>"]
        """
        from sidecar.network.guard import assert_guard, guard_request
        from sidecar.config import get_config
        # 取 host：URL 取 hostname；本地路径取不到 → 视为本地
        host = ""
        if not repo_url.startswith("/"):
            u = _urlparse(repo_url if "://" in repo_url else "https://" + repo_url)
            host = u.hostname or ""
        if not host:
            return []   # 本地路径，无需 guard
        proxies, reason = guard_request(host)
        if reason is not None:
            raise NetworkGuardError(reason, host)
        if not proxies:
            return []   # 本地 / allowlist 命中 → 直连
        base = proxies["http"]
        return ["-c", f"http.proxy={base}", "-c", f"https.proxy={base}"]

    async def install_from_github(self, repo_url: str) -> dict[str, Any]:
        """Clone a plugin repo into ~/.subagent/plugins/<repo-name>/."""
        import re
        # P1-4：出站必须过 guard（本地路径/allowlist 直连，走代理挂配置代理，熔断秒拒）
        git_proxy_args = self._egress(repo_url)
        # 2026-08-28 融合方案：提取 host 用于熔断上报（失败计入，防无代理空转）
        from sidecar.network.guard import guard_report_failure, guard_report_success
        egress_host = ""
        if not repo_url.startswith("/"):
            u = _urlparse(repo_url if "://" in repo_url else "https://" + repo_url)
            egress_host = u.hostname or ""
        # 支持本地路径和 GitHub URL
        if repo_url.startswith("/"):
            # 本地 git 仓库
            name = repo_url.rstrip("/").split("/")[-1]
            plugin_dir = PLUGINS_ROOT / name
            if plugin_dir.exists():
                import shutil as _shutil
                _shutil.rmtree(str(plugin_dir))
            plugin_dir.mkdir(parents=True, exist_ok=True)
            # M3 前置安全加固 L3：git clone 加超时（慢网络防永久阻塞）
            try:
                subprocess.run(
                    ["git", "clone"] + git_proxy_args + [repo_url, str(plugin_dir)],
                    capture_output=True, text=True, check=True, env=_egress_env(),
                    timeout=120,
                )
            except subprocess.TimeoutExpired:
                raise ValueError("git clone 超时（120s），请检查网络或仓库地址")
        else:
            match = _re.search(r'/([^/]+)/([^/.]+?)(?:\.git)?$', repo_url)
            if not match:
                raise ValueError(f"Invalid GitHub URL: {repo_url}")
            owner, name = match.group(1), match.group(2)
            plugin_dir = PLUGINS_ROOT / name
            if plugin_dir.exists():
                import shutil as _shutil
                _shutil.rmtree(str(plugin_dir))
            plugin_dir.mkdir(parents=True, exist_ok=True)
            try:
                # M3 前置安全加固 L3：git clone 加超时（慢网络防永久阻塞）
                subprocess.run(
                    ["git", "clone"] + git_proxy_args + [repo_url, str(plugin_dir)],
                    capture_output=True, text=True, check=True, env=_egress_env(),
                    timeout=120,
                )
                if egress_host:
                    guard_report_success(egress_host)
            except subprocess.TimeoutExpired:
                if egress_host:
                    guard_report_failure(egress_host)
                raise ValueError("git clone 超时（120s），请检查网络或仓库地址")
            except subprocess.CalledProcessError:
                if egress_host:
                    guard_report_failure(egress_host)  # 熔断上报：连续失败后该域名秒拒
                raise

        # Read manifest
        manifest_path = plugin_dir / "manifest.json"
        if not manifest_path.exists():
            manifest = {
                "name": name,
                "version": "0.1.0",
                "entry_point": "plugin.py",
                "api_version": "1.0",
                "hooks": ["on_message"],
                "dependencies": [],
            }
            manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
        else:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

        return {
            "name": manifest.get("name", name),
            "version": manifest.get("version", "0.1.0"),
            "path": str(plugin_dir),
            "entry_point": manifest.get("entry_point", "plugin.py"),
            "hooks": manifest.get("hooks", []),
            "description": manifest.get("description", ""),
        }

    # ---- List / Uninstall ----

    def list_installed(self) -> list[dict[str, Any]]:
        results = []
        state = self._read_state()
        for p in sorted(PLUGINS_ROOT.iterdir()):
            if not p.is_dir():
                continue
            mf = p / "manifest.json"
            if mf.exists():
                data = json.loads(mf.read_text(encoding="utf-8"))
                data["path"] = str(p)
                results.append(data)
            else:
                results.append({"name": p.name, "path": str(p)})
        # checkpoint-047：附逐项启用状态（默认启用）
        for item in results:
            item["enabled"] = state.get(str(item.get("name", "")), True)
        # 问题5（0.4.1）：附用户备注（无备注为空串）
        notes = self._read_notes()
        for item in results:
            item["note"] = notes.get(str(item.get("name", "")), "")
        return results

    def uninstall(self, plugin_name: str) -> bool:
        import shutil as _shutil
        p = PLUGINS_ROOT / plugin_name
        if not p.exists():
            return False
        _shutil.rmtree(str(p))
        # checkpoint-047：卸载时清理启用状态条目
        state = self._read_state()
        if plugin_name in state:
            state.pop(plugin_name, None)
            try:
                self._write_state(state)
            except Exception:
                pass
        # 问题5（0.4.1）：卸载时同步清理备注
        notes = self._read_notes()
        if plugin_name in notes:
            notes.pop(plugin_name, None)
            try:
                self._write_notes(notes)
            except Exception:
                pass
        return True

    # ---- Hook execution (internal load) ----

    def _load_plugin_module(self, plugin_name: str) -> Any | None:
        """Load a plugin's entry_point module via importlib (no sys.path pollution)."""
        pdir = PLUGINS_ROOT / plugin_name
        if not pdir.exists():
            return None

        # 读取 manifest 获取 entry_point
        mf = pdir / "manifest.json"
        entry = "plugin.py"
        if mf.exists():
            try:
                entry = json.loads(mf.read_text(encoding="utf-8")).get("entry_point", "plugin.py")
            except Exception:
                pass

        entry_path = pdir / entry
        if not entry_path.exists():
            return None

        # 用 importlib 从文件路径加载，不污染 sys.path
        module_name = f"subagent_plugin_{plugin_name.replace('-', '_')}"
        spec = importlib.util.spec_from_file_location(module_name, str(entry_path))
        if spec is None:
            return None
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod

    async def execute_hook(
        self,
        hook_name: str,
        agent_context: dict[str, Any],
        plugin_name: str | None = None,
    ) -> dict[str, Any] | None:
        """Execute a hook on a plugin (or all installed plugins if plugin_name is None)."""
        targets = [plugin_name] if plugin_name else [p["name"] for p in self.list_installed()]

        for pname in targets:
            # checkpoint-047：逐项开关——禁用的插件不执行任何 hook
            if not self.is_enabled(pname):
                continue
            mod = self._load_plugin_module(pname)
            if mod is None:
                continue

            hook_fn = getattr(mod, hook_name, None)
            if hook_fn is None:
                continue

            try:
                result = hook_fn(agent_context)
                # Handle async
                if hasattr(result, '__await__'):
                    result = await result
                return {"plugin": pname, "hook": hook_name, "result": result}
            except Exception as e:
                return {"plugin": pname, "hook": hook_name, "error": str(e)}

        return None
