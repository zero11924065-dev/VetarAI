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
"""checkpoint-073 TS-116 P2 体验优化 后端专项测试。

任务1 token 计数：委派交卷报告含 prompt_eval_count
任务2 多模型切换：system prompt 含"同一时间只委派一个子任务"串行约束
任务3 model_parallel 消费：
  P1 model_parallel=false + 模型切换 → 等待 5s
  P2 model_parallel=true + 模型切换 → 不等待

venv 内 python test_checkpoint073.py 直接跑。只输出 PASS/FAIL 摘要。
"""
import asyncio
import json
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

PASS, FAIL = 0, 0
FAILURES = []


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"PASS  {name}")
    else:
        FAIL += 1
        FAILURES.append(name)
        print(f"FAIL  {name}  {detail}")


class ReportConn:
    """直接交卷成功，记录收到的 messages 用于检查 system prompt。"""
    def __init__(self):
        self.last_system_prompt = ""
        self.calls = 0

    async def chat_stream(self, model, messages, tools=None, images=None):
        self.calls += 1
        for m in messages:
            if m.get("role") == "system":
                self.last_system_prompt = m.get("content", "")
        tid = ""
        for m in reversed(messages):
            if m.get("role") == "user" and "任务ID：" in (m.get("content") or ""):
                line = [l for l in m["content"].splitlines() if l.startswith("任务ID：")]
                if line:
                    tid = line[0].split("：", 1)[1].strip()
                break
        yield {"content_delta": json.dumps(
            {"task_id": tid, "status": "success", "summary": "OK", "artifacts": []},
            ensure_ascii=False)}
        yield {"done": True, "counts": {"prompt_eval_count": 12345, "eval_count": 3}}


async def main():
    TMP = Path(tempfile.mkdtemp(prefix="c073_"))
    import sidecar.storage.store as store
    store.PROJECTS_ROOT = TMP
    store._GDB = TMP / "_global.db"

    from sidecar.agent_engine import delegation as deleg
    from sidecar.agent_engine.loop import build_system_prompt

    sandbox = TMP / "work"; sandbox.mkdir()
    pid = store.create_project("c073", TMP / "wd")
    main_id = store.add_agent_config(pid, "Alpha", "main", model_name="qwen3.8")
    beta_id = store.add_agent_config(pid, "Beta", "sub", model_name="qwen3.8")
    beta = store.get_agent_config(pid, beta_id)
    parent_sid = store.create_session(pid, main_id, title="主会话")

    # ══ 任务1：委派交卷报告含 prompt_eval_count ══
    rc = ReportConn()
    res = await deleg.run_delegated_task(
        pid, main_id, parent_sid, beta, "任务T1", "标准",
        sandbox_root=str(sandbox), connector=rc)
    check("T1a 委派正常 done", res.get("ok") is True, str(res)[:120])
    t1 = store.list_agent_tasks(pid, limit=1)[0]
    report = t1.get("report") or {}
    check("T1b 交卷报告含 prompt_eval_count",
          isinstance(report.get("prompt_eval_count"), int) and report["prompt_eval_count"] > 0,
          f"report keys={list(report.keys())}")
    check("T1c prompt_eval_count 值正确（=12345）",
          report.get("prompt_eval_count") == 12345, f"got={report.get('prompt_eval_count')}")

    # ══ 任务2：system prompt 含串行约束 ══
    sp = build_system_prompt(
        agent_name="Alpha", agent_role=None, sandbox_root=str(sandbox),
        network_switch="auto", can_delegate=True)
    check("T2a system prompt 含『同一时间只委派一个子任务』",
          "同一时间只委派一个子任务" in sp, sp[-400:])
    check("T2b system prompt 含『等前一个交卷后再委派』",
          "等前一个交卷后再委派" in sp, sp[-400:])

    # ══ 任务3：model_parallel 消费 ══
    import sidecar.config as cfg
    from sidecar.agent_engine.delegation import _LAST_DELEGATED_MODEL

    # P1: model_parallel=false + 模型切换（A→B）→ 等待 5s
    cfg.reload_config({"model_parallel": False})
    _LAST_DELEGATED_MODEL.clear()  # 确保干净起点
    rc2 = ReportConn()
    await deleg.run_delegated_task(
        pid, main_id, parent_sid, beta, "任务P1a-模型A", "标准",
        sandbox_root=str(sandbox), connector=rc2)
    beta_b = dict(beta); beta_b["model_name"] = "glm-5.2"
    t0 = time.time()
    rc3 = ReportConn()
    await deleg.run_delegated_task(
        pid, main_id, parent_sid, beta_b, "任务P1b-模型B", "标准",
        sandbox_root=str(sandbox), connector=rc3)
    elapsed1 = time.time() - t0
    check("P1 model_parallel=false + 模型切换 → 等待 >= 4s",
          elapsed1 >= 4.0, f"elapsed={elapsed1:.2f}s")

    # P2: model_parallel=true + 模型切换（B→A）→ 不等待
    cfg.reload_config({"model_parallel": True})
    # _LAST_DELEGATED_MODEL 当前是 B（P1b），切回 A 触发切换检测
    t0 = time.time()
    rc5 = ReportConn()
    await deleg.run_delegated_task(
        pid, main_id, parent_sid, beta, "任务P2b-模型A", "标准",
        sandbox_root=str(sandbox), connector=rc5)
    elapsed2 = time.time() - t0
    check("P2 model_parallel=true + 模型切换 → 不等待 (< 2s)",
          elapsed2 < 2.0, f"elapsed={elapsed2:.2f}s")

    # 清理：复位 config + 清 _LAST_DELEGATED_MODEL
    cfg.reload_config({"model_parallel": False})
    _LAST_DELEGATED_MODEL.clear()

    import shutil
    shutil.rmtree(TMP, ignore_errors=True)
    check("临时目录已清理", not TMP.exists())

    print(f"\n===== checkpoint-073: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("FAILED:", ", ".join(FAILURES))
        sys.exit(1)


asyncio.run(main())
