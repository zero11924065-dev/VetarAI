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
"""REQ-MSG-021（0.4.28）：流启动初始 state 事件 + state.json 快照 max_rounds 读配置。

旧缺陷（用户 0.4.27 实测「步骤 0/5」）：state 事件只在轮末回传（loop.py 轮末统一发），
第一轮期间前端步骤分母停在占位 5；app.py 的 _exec_state 快照初始 max_rounds 同样写死 5，
与 gen() 内 _max_rounds（配置 max_tool_rounds，缺省 200）不一致。

本套件锁定三条新契约：
  ① 流启动后、第一轮开始前，后端先发一个初始 state 事件
     （step=0、max=配置真值、tokens_used=0），且是 SSE 第一个事件；
  ② 既有事件结构不变——只多发这一个 state，loop 的轮末 state/done 照旧；
  ③ state.json 初始快照的 max_rounds 与配置一致（不再是 5）。

⛔ 测试值用 42 而非缺省 200：若代码把 200 也写死，缺省值断言会假绿，
   42 只能来自本测试桩的配置，证明真的读了 get_config("max_tool_rounds")。

变异测试记录（改 app.py→跑本文件→必须红→还原→绿）：
  M1 删掉初始 state 事件的 yield      → ②红（首事件是 token，不是 state）✅ 已实测命中
  M2 快照 max_rounds 写回 5           → ④红（state.json max_rounds=5≠42）✅ 已实测命中

venv 内直接跑：python test_initial_state_event.py。数据写 /tmp，不碰 ~/.subagent。
"""
import json, sys, tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

PASS, FAIL = 0, 0
FAILURES = []

def check(name, cond, detail=""):
    global PASS, FAIL
    if cond: PASS += 1; print(f"PASS  {name}")
    else: FAIL += 1; FAILURES.append(name); print(f"FAIL  {name}  {detail}")


def main():
    TMP = Path(tempfile.mkdtemp(prefix="initstate_"))
    import sidecar.storage.store as store
    store.PROJECTS_ROOT = TMP
    store._GDB = TMP / "_global.db"
    from sidecar import app as appmod
    appmod.get_config = lambda: {"network_switch": "off", "max_tool_rounds": 42}

    pid = store.create_project("is", TMP / "wd")
    aid = store.add_agent_config(pid, "A", "main", model_name="qwen3.8")
    sid = store.create_session(pid, aid)

    # 桩 loop：一轮一事件，state 载荷仿 loop.py 轮末（max=max_rounds 透传配置值）
    def fake_loop(model, msgs, spec, root, **kw):
        async def _gen():
            yield {"event": "token", "data": {"delta": "完成"}}
            yield {"event": "state", "data": {"step": 1, "max": kw.get("max_rounds", 42),
                                              "tokens_used": 100, "prompt_eval_count": 50,
                                              "ctx_chars": 600}}
            yield {"event": "done", "data": {"content": "完成", "tool_calls": []}}
        return _gen()

    appmod.run_tool_loop = fake_loop

    from fastapi.testclient import TestClient
    client = TestClient(appmod.app)

    r = client.post("/api/ollama/chat/stream", json={
        "agent_id": aid, "project_id": pid, "session_id": sid,
        "model": "qwen3.8", "sandbox_root": str(TMP / "wd"),
        "messages": [{"role": "user", "content": "你好"}]})
    check("① HTTP 200", r.status_code == 200, str(r.status_code))

    # 解析 SSE（与 test_persist.py 同口径）
    evs = []
    for blk in r.text.split("\n\n"):
        blk = blk.strip()
        if not blk or blk.startswith(":"):
            continue
        ev, data = None, ""
        for line in blk.split("\n"):
            if line.startswith("event:"):
                ev = line[6:].strip()
            elif line.startswith("data:"):
                data += line[5:].strip()
        if ev:
            evs.append((ev, json.loads(data) if data else {}))

    # ── ② 初始 state 事件：SSE 第一个事件，携带配置真值 ──
    check("② 首事件是初始 state（先于一切 token/轮末 state）",
          len(evs) >= 1 and evs[0][0] == "state", str(evs[:2])[:200])
    if evs and evs[0][0] == "state":
        d0 = evs[0][1]
        check("② 初始 state 载荷 step=0 / max=42（配置）/ tokens_used=0",
              d0.get("step") == 0 and d0.get("max") == 42 and d0.get("tokens_used") == 0,
              str(d0))
    else:
        check("② 初始 state 载荷 step=0 / max=42（配置）/ tokens_used=0", False, "首事件非 state")

    # ── ③ 既有结构不变：初始 state 之外，loop 的轮末 state 与 done 照旧到达 ──
    names = [e for e, _ in evs]
    check("③ 恰好多一个 state（初始 + 轮末各一），done 仍在",
          names.count("state") == 2 and "done" in names and "token" in names, str(names))
    round_state = [d for e, d in evs if e == "state" and d.get("step") == 1]
    check("③ 轮末 state 字段结构未动（prompt_eval_count/ctx_chars 仍在）",
          bool(round_state) and round_state[0].get("prompt_eval_count") == 50
          and round_state[0].get("ctx_chars") == 600,
          str(round_state)[:200])

    # ── ④ state.json 快照 max_rounds 读配置（初始不再是硬编码 5）──
    # ⛔ 必须用【无轮末 state】的 loop 再跑一条：轮末 state 会把 d.max 盖进快照，
    #    若快照初始值写回 5（变异 M2），轮末一盖就假绿。B 场景 loop 只吐 token+done，
    #    快照里的 max_rounds 只能来自 _exec_state 初始化（:1124 读配置）。
    sid_b = store.create_session(pid, aid)
    def fake_loop_no_state(model, msgs, spec, root, **kw):
        async def _gen():
            yield {"event": "token", "data": {"delta": "好"}}
            yield {"event": "done", "data": {"content": "好", "tool_calls": []}}
        return _gen()
    appmod.run_tool_loop = fake_loop_no_state
    r_b = client.post("/api/ollama/chat/stream", json={
        "agent_id": aid, "project_id": pid, "session_id": sid_b,
        "model": "qwen3.8", "sandbox_root": str(TMP / "wd"),
        "messages": [{"role": "user", "content": "再来"}]})
    check("④ B 场景 HTTP 200", r_b.status_code == 200, str(r_b.status_code))
    st_path = TMP / pid / "work" / "state.json"
    st = json.loads(st_path.read_text(encoding="utf-8")) if st_path.exists() else None
    check("④ state.json 已生成且 status=done", st is not None and st.get("status") == "done",
          str(st)[:200] if st else "无文件")
    check("④ 快照 max_rounds=42（无轮末 state 覆盖，只能来自初始读配置）",
          st is not None and st.get("max_rounds") == 42, str(st)[:200] if st else "无文件")

    import shutil
    shutil.rmtree(TMP, ignore_errors=True)
    check("测试临时目录已清理", not TMP.exists())

    print(f"\n===== 初始 state 事件专项: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("FAILED:", ", ".join(FAILURES))
        sys.exit(1)


if __name__ == "__main__":
    main()
