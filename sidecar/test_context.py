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
"""M2 上下文上限 API 单测。
venv 内直接跑：python test_context.py。
"""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

PASS, FAIL = 0, 0
FAILURES = []

def check(name, cond, detail=""):
    global PASS, FAIL
    if cond: PASS += 1; print(f"PASS  {name}")
    else: FAIL += 1; FAILURES.append(name); print(f"FAIL  {name}  {detail}")


def main():
    from fastapi.testclient import TestClient
    from sidecar.app import app
    client = TestClient(app)

    # 1. 模型已加载 → /api/ps 读 context_length
    r = client.get("/api/context/limit", params={"model": "qwen3.8"})
    d = r.json()
    check("1 已加载模型 context_length=262144", d.get("context_length") == 262144, str(d))
    check("1 source=ps", d.get("source") == "ps", str(d))

    # 2. 模型未加载 → default 兜底
    r2 = client.get("/api/context/limit", params={"model": "nonexistent_xyz_999"})
    d2 = r2.json()
    check("2 未加载 → source=default", d2.get("source") == "default", str(d2))
    check("2 兜底 262144", d2.get("context_length") == 262144, str(d2))

    # 3. Ollama 停掉 → source=error（mock httpx 抛异常）
    import httpx
    orig_client = httpx.AsyncClient
    class ErrClient:
        def __init__(self, **kw): pass
        async def __aenter__(self): return self
        async def __aexit__(self, *a): return False
        async def get(self, *a, **kw): raise httpx.ConnectError("ollama down")
    httpx.AsyncClient = lambda **kw: ErrClient()
    try:
        r3 = client.get("/api/context/limit", params={"model": "qwen3.8"})
        d3 = r3.json()
        check("3 Ollama 不可达 → source=error", d3.get("source") == "error", str(d3))
        check("3 context_length=0", d3.get("context_length") == 0, str(d3))
    finally:
        httpx.AsyncClient = orig_client

    print(f"\n===== M2 上下文 API: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("FAILED:", ", ".join(FAILURES))
        sys.exit(1)


if __name__ == "__main__":
    main()
