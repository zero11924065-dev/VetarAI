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
"""M3 前置安全加固 L3：git clone 超时（mock 挂起 → 120s 后返回错误不永久阻塞）。
venv 内直接跑：python test_plugin_timeout.py。
"""
import sys, subprocess, asyncio
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

PASS, FAIL = 0, 0
FAILURES = []

def check(name, cond, detail=""):
    global PASS, FAIL
    if cond: PASS += 1; print(f"PASS  {name}")
    else: FAIL += 1; FAILURES.append(name); print(f"FAIL  {name}  {detail}")


async def run_case():
    import sidecar.plugin_loader.loader as ld
    real_run = subprocess.run
    def fake_run(cmd, **kw):
        if "clone" in cmd:
            raise subprocess.TimeoutExpired(cmd, timeout=120)
        return real_run(cmd, **kw)
    ld.subprocess.run = fake_run
    try:
        loader = ld.PluginLoader()
        # 非 github URL → 本地路径分支（第一处 subprocess.run）
        try:
            await loader.install_from_github("file:///nonexistent/repo")
            return ("no_exception", None)
        except ValueError as e:
            return ("value_error", str(e))
        except Exception as e:
            return (type(e).__name__, str(e))
    finally:
        ld.subprocess.run = real_run


def main():
    kind, msg = asyncio.run(run_case())
    check("L3 git clone 超时 → 返回错误（含超时提示）",
          kind == "value_error" and "超时" in (msg or ""), f"kind={kind} msg={msg}")

    print(f"\n===== L3 git clone 超时: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("FAILED:", ", ".join(FAILURES))
        sys.exit(1)


if __name__ == "__main__":
    main()
