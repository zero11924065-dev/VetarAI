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
    # ⛔ 0.4.11 改造：此前硬编码断言 context_length == 262144，但 Ollama 返回的真实值
    #    取决于模型载入时的 num_ctx（实测 num_ctx=1024 → 返回 2048；载入方式不同值就不同），
    #    硬编码必然假失败。改为【先读 /api/ps 真实值，再断言端点返回同一值】——
    #    验证"端点如实透传 ps 的值"这一真实契约，与具体数值解耦。
    #    模型未加载时优雅 SKIP（与 m31/m32 E2E 同一约定），不判失败。
    import json
    import urllib.request
    import urllib.error
    base_url = "http://localhost:11434"
    ps_cl = None
    try:
        with urllib.request.urlopen(f"{base_url}/api/ps", timeout=8) as resp:
            for m in json.loads(resp.read().decode("utf-8")).get("models", []):
                if str(m.get("name", "")).startswith("qwen3.8"):
                    ps_cl = m.get("context_length")
                    break
    except (urllib.error.URLError, OSError, ValueError) as e:
        print(f"  SKIP  /api/ps 不可达（{type(e).__name__}），跳过用例 1")
    if ps_cl is None:
        print("  SKIP  qwen3.8 未加载（/api/ps 无该模型），跳过用例 1。"
              "请先发一次推理请求载入（curl -X POST localhost:11434/api/chat ...）")
    else:
        r = client.get("/api/context/limit", params={"model": "qwen3.8"})
        d = r.json()
        check("1 端点如实透传 /api/ps 的 context_length（不硬编码具体数值）",
              d.get("context_length") == int(ps_cl), f"ps={ps_cl} 端点={d}")
        check("1 source=ps", d.get("source") == "ps", str(d))
        check("1 返回真实模型名（含 tag）", str(d.get("model", "")).startswith("qwen3.8"), str(d))

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
