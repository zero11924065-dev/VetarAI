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
"""第 3 批（0.4.16）C8 专项 · 后端：停止态落库链路。

C8 三个根因（已核实）：
  ② 停止时前端把「（已停止）」拼进 content → 缓存副本与 DB 定稿内容不一致 → 去重失配
    → 副本被追加到会话末尾且重复
  ③ 停止态不落库（session_messages 无 stopped 列）→ 刷新/切回后丢失"已手动停止"标记
  ① mergeDbWithLocal `[...dbMsgs, ...extra]` 不按时间序（②消除后此前提基本消失，
    前端再用"前缀去重"兜底 abort 少收 token 的情形）

本文件测**后端落库链路**（store schema 迁移 + save/load 往返 + app.py 接线）；
前端 merge 去重与 stopped→manualStopped 映射由 chatPanelC8.test.tsx 覆盖。

隔离：VETARAI_DATA_ROOT=临时目录（**必须在 import store 之前设**，data_root() 读它），
不碰真实 ~/.subagent。
"""
from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

# ⛔ 必须在 import sidecar.storage.store 之前设：data_root() 在连接时读该环境变量
_TMP = tempfile.mkdtemp(prefix="c8_")
os.environ["VETARAI_DATA_ROOT"] = _TMP

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

PASS, FAIL = 0, 0
FAILURES: list[str] = []


def check(name: str, cond: bool, detail: str = "") -> None:
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"PASS  {name}")
    else:
        FAIL += 1
        FAILURES.append(name)
        print(f"FAIL  {name}  {detail}")


from sidecar.storage import store   # noqa: E402

PID, SID, AID = "p-c8", "s-c8", "a1"


def main() -> None:
    # 触发建表 + 幂等迁移（_ensure_schema 在每次连接时跑）
    store.save_message(PID, SID, AID, "user", "你好")

    # ── M：schema 迁移 ──
    with store._read_conn(PID) as conn:
        info = conn.execute("PRAGMA table_info(session_messages)").fetchall()
    cols = {r[1]: r for r in info}
    check("M-1 session_messages 迁移出 stopped 列", "stopped" in cols, str(sorted(cols)))
    # PRAGMA 行：(cid, name, type, notnull, dflt_value, pk) → [4] 是默认值
    check("M-1 stopped 列 DEFAULT 0（旧消息默认非停止）",
          "stopped" in cols and str(cols["stopped"][4]) == "0", str(cols.get("stopped")))

    # ── R：save/load 往返 ──
    store.save_message(PID, SID, AID, "assistant", "部分回答被中断", stopped=True)
    msgs = store.load_messages(PID, SID)
    stopped_msgs = [m for m in msgs if m.get("stopped")]
    check("R-1 stopped=True 落库后 load 返回 stopped=True",
          len(stopped_msgs) == 1 and stopped_msgs[0]["content"] == "部分回答被中断", str(msgs))

    normal = [m for m in msgs if m["content"] == "你好"]
    check("R-2 默认 save（未传 stopped）的消息不含 stopped 键",
          bool(normal) and "stopped" not in normal[0], str(normal))

    store.save_message(PID, SID, AID, "assistant", "完整回答")   # 默认 stopped=False
    msgs2 = store.load_messages(PID, SID)
    contents = [m["content"] for m in msgs2]
    check("R-3 load 按 id（插入序）返回", contents == ["你好", "部分回答被中断", "完整回答"], str(contents))
    check("R-3 仅中断那条 stopped=True，其余无该键",
          [bool(m.get("stopped")) for m in msgs2] == [False, True, False],
          str([m.get("stopped") for m in msgs2]))
    check("R-4 stopped=False 显式 → load 不含 stopped 键",
          "stopped" not in msgs2[2], str(msgs2[2]))

    # ── A：app.py 接线静态核查 ──
    app_src = (Path(__file__).resolve().parents[1] / "sidecar" / "app.py").read_text(encoding="utf-8")
    check("A-1 _persist_assistant 定义加 stopped 参数并透传 save_message",
          "def _persist_assistant(truncated: bool = False, stopped: bool = False)" in app_src
          and "truncated=truncated, stopped=stopped" in app_src)
    n_st = app_src.count("_persist_assistant(truncated=True, stopped=True)")
    check("A-2 恰两处用户停止路径传 stopped=True（C2取消分支 + CancelledError）",
          n_st == 2, str(n_st))
    check("A-3 done 路径（truncated=False）不传 stopped（正常完成不标停止）",
          "_persist_assistant(truncated=False)" in app_src
          and "_persist_assistant(truncated=False, stopped" not in app_src)
    # 错误路径（业务异常/网络/安全网）仍是 truncated=True 不带 stopped
    n_err = app_src.count("_persist_assistant(truncated=True)\n")
    check("A-4 错误路径（非用户停止）保持 stopped 默认 False",
          n_err >= 3, f"裸 truncated=True 调用数={n_err}（应≥3：业务/网络/安全网/finally）")

    print(f"\n===== C8 后端专项: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("失败项:", FAILURES)
        sys.exit(1)


if __name__ == "__main__":
    main()
