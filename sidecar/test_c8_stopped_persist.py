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

    # ── T：C2 根因③（0.4.16 补漏）落库的 tool_steps 不得残留 running ──
    # ⛔ 这是**用户可见症状的持久化侧**：工具步骤以 status="running" 加入 _state["steps"]，
    # 停止时若原样落库，刷新后该工具**永久显示"正在调用…"**，且前端折叠判据
    # `done && running===0` 永不满足 → 步骤组永远展开（正是 C8 的"不可折叠"）。
    # app.py 的 _persist_assistant 已在唯一落库出口统一收敛 running→interrupted，
    # 此处验证收敛后的形态落库/读回都正确，且 interrupted 不被误当 ok/error。
    SID2 = "s-c8-steps"
    steps_interrupted = [
        {"id": "c1", "name": "read_file", "args": {"path": "a.py"}, "status": "interrupted"},
        {"id": "c2", "name": "list_dir", "status": "ok"},
        {"id": "c3", "name": "write_file", "status": "error", "error": "权限不足"},
    ]
    store.save_message(PID, SID2, AID, "assistant", "部分回答",
                       tool_steps=steps_interrupted, truncated=True, stopped=True)
    got = store.load_messages(PID, SID2)[0]
    ts = got.get("tool_steps") or []
    check("T-1 落库的 tool_steps 无 running 残留（刷新后不会永久显示正在调用）",
          not any(st.get("status") == "running" for st in ts), str(ts))
    check("T-2 interrupted 状态被完整保留（三态并存不串味）",
          [st.get("status") for st in ts] == ["interrupted", "ok", "error"],
          str([st.get("status") for st in ts]))
    check("T-3 interrupted 不计入失败（error 仍单独标记，不污染失败计数）",
          sum(1 for st in ts if st.get("status") == "error") == 1, str(ts))

    # ── app.py 接线核查：⛔ 用 AST 而非文本子串 ──
    # 教训：第一版用文本匹配 '_st["status"] = "interrupted"'，当我把原地改修正为
    # "构造副本"后（为了不抹掉 state.json 的诊断现场），断言就失效了。
    # 文本匹配对实现细节过度耦合；AST 看结构，改写法不影响判定。
    import ast as _ast
    tree = _ast.parse(app_src)
    conv_ok = False       # _persist_assistant 内把 running 映射为 interrupted
    uses_copy = False     # 且不是原地改 _state["steps"]（保留诊断现场）
    save_uses_final = False
    for fn in _ast.walk(tree):
        if isinstance(fn, _ast.FunctionDef) and fn.name == "_persist_assistant":
            body_src = _ast.get_source_segment(app_src, fn) or ""
            conv_ok = ('"interrupted"' in body_src and '"running"' in body_src)
            uses_copy = "_steps_final" in body_src
            save_uses_final = "tool_steps=_steps_final" in body_src
    check("T-4 _persist_assistant 内做 running→interrupted 收敛（AST 判定）", conv_ok)
    check("T-5 ⛔ 收敛写入**副本**而非原地改 _state['steps']（否则抹掉 state.json 诊断现场）",
          uses_copy and save_uses_final,
          f"uses_copy={uses_copy} save_uses_final={save_uses_final}")

    # ── U：两种快照语义必须并存（这是 T-5 的行为后果，端到端验证）──
    # DB 存定稿态 interrupted；work/state.json 保留现场态 running（供中断续跑诊断）。
    # ⛔ 第一版原地改 _state 时两者被强行统一成 interrupted，test_state_file 断言③
    # 「中断现场保留最后一步（tool_call running）」抓住——那是真实回归，不是测试过时。
    import subprocess
    _r = subprocess.run([sys.executable, "-m", "sidecar.test_state_file"],
                        cwd=str(Path(__file__).resolve().parents[1]),
                        capture_output=True, text=True, timeout=180,
                        env={**os.environ, "VETARAI_DATA_ROOT": _TMP})
    check("U-1 state.json 专项通过（诊断现场未被落库收敛抹掉）",
          _r.returncode == 0, (_r.stdout or _r.stderr)[-300:])

    print(f"\n===== C8 后端专项: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("失败项:", FAILURES)
        sys.exit(1)


if __name__ == "__main__":
    main()
