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
"""checkpoint-043 日志模块专项单测（用户需求二）。
覆盖：日志目录解析/可写、日志文件写入、全局异常中间件、/api/logs/info 端点、幂等。
venv 内直接跑：python test_logging.py。
"""
import asyncio
import logging
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

PASS, FAIL = 0, 0
FAILURES = []


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond: PASS += 1; print(f"PASS  {name}")
    else: FAIL += 1; FAILURES.append(name); print(f"FAIL  {name}  {detail}")


async def main():
    from sidecar.logging_setup import resolve_log_dir, setup_logging, reset_for_test

    # ══ 1. 日志目录解析与可写 ══
    d = resolve_log_dir()
    check("1a resolve_log_dir 返回目录存在", d.is_dir(), str(d))
    check("1b 目录名 = logs", d.name == "logs", d.name)
    probe = d / ".write_probe"
    try:
        probe.write_text("ok", encoding="utf-8")
        probe.unlink()
        check("1c 日志目录可写", True)
    except Exception as e:
        check("1c 日志目录可写", False, str(e))

    # ══ 2. setup_logging 幂等 + 文件写入 ══
    from fastapi.testclient import TestClient
    from sidecar.app import app, _LOG_PATH
    client = TestClient(app)

    check("2a app 导入时已初始化日志（_LOG_PATH 非空）",
          _LOG_PATH is not None and Path(_LOG_PATH).exists(), str(_LOG_PATH))
    check("2b 日志文件在 logs/ 目录下",
          _LOG_PATH is not None and Path(_LOG_PATH).parent == resolve_log_dir())

    # 写一条日志 → 文件可见（flush 后）
    marker = "CHECKPOINT_043_PROBE_MSG"
    logging.getLogger("sidecar.test_probe").error(marker)
    for h in logging.getLogger().handlers:
        h.flush()
    content = Path(_LOG_PATH).read_text(encoding="utf-8") if _LOG_PATH else ""
    check("2c error 日志落盘（含探针消息）", marker in content, content[-200:])

    # 幂等：重复调用不叠加文件 handler
    before = sum(1 for h in logging.getLogger().handlers
                 if h.__class__.__name__ == "RotatingFileHandler")
    setup_logging()
    setup_logging()
    after = sum(1 for h in logging.getLogger().handlers
                if h.__class__.__name__ == "RotatingFileHandler")
    check("2d setup_logging 幂等（不叠加 handler）", before == after and after >= 1,
          f"{before}→{after}")

    # ══ 3. /api/logs/info 端点 ══
    r = client.get("/api/logs/info")
    d_info = r.json()
    check("3a /api/logs/info 200", r.status_code == 200, str(r.status_code))
    check("3b 返回 log_dir 与 resolve_log_dir 一致",
          d_info.get("log_dir") == str(resolve_log_dir()), str(d_info))
    check("3c 返回 log_file 存在", bool(d_info.get("log_file"))
          and Path(d_info["log_file"]).exists(), str(d_info))

    # ══ 4. 全局异常中间件 ══
    from sidecar.app import _log_unhandled_errors

    class FakeRequest:
        method = "GET"
        class url:
            path = "/fake"

    async def bad_next(_req):
        raise RuntimeError("boom-043")

    resp = await _log_unhandled_errors(FakeRequest(), bad_next)
    check("4a 中间件捕获异常 → 500", resp.status_code == 500, str(resp.status_code))
    import json as _json
    body = _json.loads(resp.body)
    check("4b 响应含错误信息", "boom-043" in body.get("detail", ""), str(body))
    # 异常已落日志
    for h in logging.getLogger().handlers:
        h.flush()
    content2 = Path(_LOG_PATH).read_text(encoding="utf-8") if _LOG_PATH else ""
    check("4c 未处理异常已落盘（Traceback）",
          "boom-043" in content2 and "未处理异常" in content2, content2[-300:])

    # HTTPException 类业务错误不被中间件吞掉（FastAPI 默认处理先于中间件返回，
    # 这里验证中间件对正常响应透传）
    async def ok_next(_req):
        class R:
            status_code = 200
        return R()
    resp2 = await _log_unhandled_errors(FakeRequest(), ok_next)
    check("4d 正常响应透传不干扰", resp2.status_code == 200)

    # ══ 5. reset_for_test 清理 ══
    reset_for_test()
    remain = sum(1 for h in logging.getLogger().handlers
                 if h.__class__.__name__ == "RotatingFileHandler")
    check("5 reset_for_test 移除文件 handler", remain == 0, str(remain))

    print(f"\n===== checkpoint-043 日志专项: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("FAILED:", ", ".join(FAILURES))
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
