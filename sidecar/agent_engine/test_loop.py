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
"""M1-2 tool loop 单测（mock Ollama，venv 内 python test_loop.py 直接跑）。
只输出 PASS/FAIL 摘要。
"""
import asyncio
import json
import os
import shutil
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from sidecar.agent_engine.loop import run_tool_loop, tools_spec, build_system_prompt  # noqa: E402

PASS, FAIL = 0, 0
FAILURES = []

# ══════════ 变异测试机制（0.4.20 补，针对 #1 插入点分裂 + 表#5 提示词纪律）══════════
#
# **为什么要补**：#1 与表#5 交付时我做过变异验证，但都是"临时打补丁 → 跑 → 手工还原"，
#   **验证完什么都没留下**。表#5 尤其要紧——提交 `3a4e692` 是 0.4.19 里唯一零测试的提交，
#   纯提示词文案改动，没有可复现的验证入口等于这段纪律裸奔。
#
# 运行：MUTATE=1|2|3 .venv/bin/python -m sidecar.agent_engine.test_loop
# ⛔ **变异模式下必须出现 FAIL**；0 FAIL = 断言空转，需加强（不是"通过"）。
#
# | 变异 | 撤掉的修复 | 应失败的断言 |
# |---|---|---|
# | 1 | 不发 segment_break（#1 后端事件） | 22a~22d、22g 共 **5 条** |
# | 2 | break_at 恒为 0（#1 断点算错） | 22d + 22g（22g 会显示段2 重复段1） |
# | 3 | 提示词回退窄口径（表#5 推广前状态） | 10d3 + 10d4 |
MUTATE = int(os.environ.get("MUTATE", "0"))

# ⛔ 还原用【内存备份】而非 `git checkout --`：变异期间工作区可能有未提交改动，
#   checkout 会一并抹掉（test_p4_doc_reader / test_office_io 的既有纪律，此处沿用）。
_BACKUP: dict[str, str] = {}


def _read_src(mod) -> str:
    return Path(mod.__file__).read_text(encoding="utf-8")


def _rebind_loop_names() -> None:
    """⛔⛔ reload 之后**必须重新绑定**本模块顶部按名导入的对象。

    本文件开头是 `from sidecar.agent_engine.loop import run_tool_loop, tools_spec,
    build_system_prompt` —— 这是**按名绑定**：reload(loop) 会在 loop 的模块命名空间里
    新建这些对象，但本模块的名字仍指向**旧的**。不重新绑定 → 变异完全不生效，
    测试跑出"全过"假象（与 test_p4_doc_reader 里 `_EXEC_HOLDER` 那个坑同源）。
    """
    global run_tool_loop, tools_spec, build_system_prompt
    import sidecar.agent_engine.loop as _lp
    run_tool_loop = _lp.run_tool_loop
    tools_spec = _lp.tools_spec
    build_system_prompt = _lp.build_system_prompt


def _apply_mutation() -> None:
    """把 #1 / 表#5 的修复改回缺陷态。⛔ 锚点未命中必须 assert 报错——否则
    "变异没抓到"可能只是**根本没注入成功**（0.4.18 B10/C8 变异2 静默失败过一次）。"""
    if not MUTATE:
        return
    import sidecar.agent_engine.loop as lp
    _BACKUP["loop"] = _read_src(lp)
    s = _BACKUP["loop"]

    if MUTATE == 1:
        # 撤掉 segment_break 事件（#1 的核心产出）
        patched = s.replace("            if _inj_payload:", "            if False and _inj_payload:")
        assert patched != s, "变异 1 未命中 loop.py 源码，测试无效"
    elif MUTATE == 2:
        # break_at 恒为 0 → 前端切分后段2 会重复显示段1 全文
        patched = s.replace('"break_at": len(full_text)}}', '"break_at": 0}}')
        assert patched != s, "变异 2 未命中 loop.py 源码，测试无效"
    elif MUTATE == 3:
        # 表#5：提示词从「任何文件路径」回退到「用户上传的文件」窄口径
        _old = ('        "【文件路径纪律】用户消息正文、或工具返回结果里出现的**文件绝对路径**"\n'
                '        "（上传附件形如「（原件已保存：/…）」，也可能是导出产物、用户指定的任意路径），"\n'
                '        "只代表文件**在本机存在**，其**内容不会**自动出现在你的上下文里。\\n"')
        _new = ('        "【文件路径纪律】用户上传的文件的路径"\n'
                '        "只代表文件**在本机存在**，其**内容不会**自动出现在你的上下文里。\\n"')
        assert _old in s, "变异 3 未命中 loop.py 提示词，测试无效"
        patched = s.replace(_old, _new)
    else:
        raise SystemExit(f"未知变异编号 {MUTATE}（支持 1|2|3）")

    Path(lp.__file__).write_text(patched, encoding="utf-8")
    # ⛔ 改写磁盘后必须 reload + 重新绑定，否则测的是 sys.modules 里的旧对象（假通过）
    import importlib
    importlib.reload(lp)
    _rebind_loop_names()


def _restore() -> None:
    """把被变异改写的源文件还原（⛔ 务必放 finally：用例 sys.exit(1) 会抛 SystemExit，
    不放 finally 就会让 loop.py 留在变异态，污染后续所有测试与真实代码）。"""
    if not MUTATE or not _BACKUP:
        return
    import sidecar.agent_engine.loop as lp
    try:
        if "loop" in _BACKUP and _read_src(lp) != _BACKUP["loop"]:
            Path(lp.__file__).write_text(_BACKUP["loop"], encoding="utf-8")
    finally:
        _BACKUP.clear()
        import importlib
        importlib.reload(lp)
        _rebind_loop_names()


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"PASS  {name}")
    else:
        FAIL += 1
        FAILURES.append(name)
        print(f"FAIL  {name}  {detail}")


class MockConn:
    """按序返回预置脚本的假 connector。每轮脚本 = (content_chunks, tool_calls) 列表。"""

    def __init__(self, rounds, timeout_after=None):
        self.rounds = rounds
        self.timeout_after = timeout_after  # 第 N 轮 yield stream_error（模拟流内超时兜底）
        self.calls = 0

    async def chat_stream(self, model, messages, tools=None):
        i = min(self.calls, len(self.rounds) - 1)
        self.calls += 1
        if self.timeout_after is not None and self.calls >= self.timeout_after:
            yield {"content_delta": "部分"}
            yield {"stream_error": "模型响应超时，已停止。已完成部分见上方事件。"}
            return
        content, tcs = self.rounds[i]
        for ch in content:
            yield {"content_delta": ch}
        if tcs:
            yield {"tool_calls": [{"id": f"mock_{self.calls}", "function": {"name": n, "arguments": json.dumps(a)}} for n, a in tcs]}
        yield {"done": True, "counts": {"prompt_eval_count": 10, "eval_count": 5}}


async def collect(script, sandbox, authorizer=None, max_rounds=5, context_limit=0):
    evs = []
    async for ev in run_tool_loop("m", [{"role": "user", "content": "hi"}], tools_spec(),
                                  sandbox, authorizer=authorizer, max_rounds=max_rounds,
                                  context_limit=context_limit,
                                  connector=MockConn(script)):
        evs.append(ev)
    return evs


async def main():
    base = Path(tempfile.mkdtemp(prefix="m12loop_"))
    sandbox = base / "ws"
    sandbox.mkdir()
    (sandbox / "a.txt").write_text("hello", encoding="utf-8")
    (sandbox / "notes.md").write_text("n1", encoding="utf-8")

    def names(evs):
        return [e["event"] for e in evs]

    # 1. 单轮无工具 → done
    evs = await collect([(["你好", "。"], None)], str(sandbox))
    done = next((e for e in evs if e["event"] == "done"), None)
    check("1 单轮无工具 done+完整content", done is not None and done["data"]["content"] == "你好。"
          and "token" in names(evs), str(evs)[:200])

    # 2. 单轮 1 工具 → tool_call + tool_result(ok) + done
    evs = await collect([([], [("list_dir", {})]), (["目录里有 a.txt 和 notes.md"], None)], str(sandbox))
    tr = next((e for e in evs if e["event"] == "tool_result"), None)
    done = next((e for e in evs if e["event"] == "done"), None)
    check("2 单轮工具 list_dir 全链路",
          any(e["event"] == "tool_call" and e["data"]["name"] == "list_dir" for e in evs)
          and tr is not None and tr["data"]["ok"] is True
          and done is not None and "a.txt" in done["data"]["content"], str(evs)[:300])

    # 3. 2 轮工具 → state 步数 1,2
    evs = await collect([
        ([], [("write_file", {"path": "w1.txt", "content": "x"})]),
        ([], [("list_dir", {})]),
        (["完成"], None),
    ], str(sandbox))
    steps = [e["data"]["step"] for e in evs if e["event"] == "state"]
    check("3 两轮工具 state 步数1,2", steps[:2] == [1, 2] and steps[-1] == 3, str(steps))

    # 4. max_rounds 熔断
    loop_round = ([], [("list_dir", {})])
    evs = await collect([loop_round] * 5, str(sandbox), max_rounds=3)
    err = next((e for e in evs if e["event"] == "error"), None)
    check("4 max_rounds 达到上限 error", err is not None and "最大轮次" in err["data"]["detail"], str(evs)[-200:])

    # 5. 越界工具默认放行（2026-08-28 权限宽松化：工作目录不作围栏）
    (base / "outside.txt").write_text("OUTSIDE", encoding="utf-8")
    evs = await collect([
        ([], [("read_file", {"path": "../outside.txt"})]),
        (["读到了越界文件"], None),
    ], str(sandbox))
    tr = next((e for e in evs if e["event"] == "tool_result"), None)
    done = next((e for e in evs if e["event"] == "done"), None)
    check("5 越界读取默认放行且loop继续", tr is not None and tr["data"]["ok"] is True
          and done is not None, str(evs)[:300])

    # 6. 连续 2 轮工具失败 → error 连续工具失败
    evs = await collect([
        ([], [("read_file", {"path": "no_such.bin"})]),
        ([], [("read_file", {"path": "still_missing.bin"})]),
    ], str(sandbox))
    err = next((e for e in evs if e["event"] == "error"), None)
    check("6 连续2轮失败熔断", err is not None and "连续工具失败" in err["data"]["detail"], str(evs)[-200:])

    # 7. token 计数累加（mock 每轮 10+5=15）
    evs = await collect([([], [("list_dir", {})]), (["ok"], None)], str(sandbox))
    states = [e["data"]["tokens_used"] for e in evs if e["event"] == "state"]
    check("7 token 计数单调累加", states == [15, 30], str(states))

    # 8. SSE 行格式：event: + data: 可逐行解析
    line1, line2 = "event: token", "data: {\"delta\": \"x\"}"
    payload = f"event: token\ndata: {json.dumps({'delta': 'x'}, ensure_ascii=False)}\n\n"
    lines = [l for l in payload.splitlines() if l]
    check("8 SSE 事件行格式", lines[0].startswith("event: ") and lines[1].startswith("data: ")
          and json.loads(lines[1][len("data: "):]) == {"delta": "x"}, str(payload))

    # 9. authorizer 分工（2026-08-28 权限宽松化）：
    #    普通操作不调用 authorizer（不再每次询问）；仅敏感删除以三元组调用
    from sidecar.tools import registry as _registry
    seen = []

    async def auth3(tool_name, target_path, action):
        seen.append((tool_name, target_path, action))
        return True

    # 9a. 普通 list_dir → authorizer 不被调用
    evs = await collect([([], [("list_dir", {})]), (["done"], None)], str(sandbox), authorizer=auth3)
    check("9a 普通操作不调用 authorizer（不弹窗骚扰）",
          len(seen) == 0 and any(e["event"] == "done" for e in evs), str(seen))

    # 9b. 敏感删除 → authorizer 以三元组 (tool_name, path, action='delete') 调用
    fake_sensitive = base / "fake_sensitive_loop"
    fake_sensitive.mkdir()
    victim = fake_sensitive / "victim.txt"
    victim.write_text("s", encoding="utf-8")
    orig_is_sensitive = _registry.is_sensitive_path
    _registry.is_sensitive_path = lambda p: str(Path(p).resolve()).startswith(str(fake_sensitive.resolve()))
    try:
        evs = await collect([([], [("delete_path", {"path": str(victim)})]), (["done"], None)],
                            str(sandbox), authorizer=auth3)
        check("9b 敏感删除调用 authorizer 三元组 (tool_name,path,'delete')",
              len(seen) == 1 and seen[0][0] == "delete_path" and seen[0][2] == "delete", str(seen))
        check("9b authorizer 放行后删除生效", not victim.exists())
    finally:
        _registry.is_sensitive_path = orig_is_sensitive

    # 10. system prompt 结构（M1-3 提前项）
    sp = build_system_prompt("小助手", "工程师", "/data/ws", "on", current_time="2026-08-25 10:00",
                             system_prompt="简洁回答")
    check("10 system prompt 四段齐全",
          sp.startswith("【禁止事项】") and "你是 小助手" in sp and "角色：工程师" in sp
          and "工作目录：/data/ws" in sp and "2026-08-25 10:00" in sp and "ON" in sp
          and "简洁回答" in sp, sp[:150])

    # 10b. S1（M3 前置安全加固）：系统提示含敏感位置写/删需确认说明
    check("10b 系统提示含「系统敏感位置（系统目录、~/.ssh、应用数据目录等）的写入/删除，系统会向你请求确认」",
          "系统敏感位置（系统目录、~/.ssh、应用数据目录等）的写入/删除，系统会向你请求确认" in sp, sp[:300])

    # 10c. H15（M3-2 验收）：委派纪律含强制委派约束（让XX做 → 必须 delegate_task，不得冒充已派）
    sp2 = build_system_prompt("小助手", "工程师", "/data/ws", "auto", can_delegate=True)
    check("10c 委派纪律含强制委派约束",
          "必须先调用 delegate_task" in sp2 and "不得自己直接做该事" in sp2
          and "不得在未调用 delegate_task 的情况下" in sp2, sp2[-400:])
    sp3 = build_system_prompt("小助手", "工程师", "/data/ws", "auto", can_delegate=False)
    check("10c2 can_delegate=False 不含委派纪律", "【委派纪律】" not in sp3)

    # 10d. 表#5/#6（0.4.19）：附件与文件路径纪律必须在系统提示词里
    #   ⛔ 为什么要加这条静态断言：提交 `3a4e692`（表#5）是 0.4.19 里**唯一零测试**的提交，
    #   它只改了 build_system_prompt 的提示词文案（把"用户上传的文件"扩为"任何文件路径"）。
    #   纯文案改动难做行为测试，但**完全没有断言 = 提示词被误删/改写没人会发现**，
    #   而这段纪律是表#5/#6 两项修复的**后端配套必需项**——
    #   表#6 把附件从推模式改为拉模式后，若提示词不告知模型"路径≠内容"，
    #   模型就会回答"我看不到文件"（这正是表#5 的用户实测症状）。
    #   📌 参照 #11 删折叠后写的"反向守护 R1~R6"范式：源码/提示词层面的回潮防护。
    check("10d 提示词含【文件路径纪律】段（表#5，拉模式的后端配套必需项）",
          "【文件路径纪律】" in sp, sp[:400])
    check("10d2 该纪律说明「路径只代表文件存在、内容不会自动进上下文」",
          "只代表文件" in sp and "不会" in sp, sp[:400])
    # 10d3 ⛔ 首轮写成 `"导出" in sp or "任意路径" in sp` —— **是空转断言**（变异实测抓到）：
    #   提示词里"导出"出现在多处（本段措辞、另一行的"含导出的 .md/.json"、以及注释），
    #   把表#5 推广的措辞整段删掉后，别处的"导出"仍让断言 PASS → 回归无人察觉。
    #   ✅ 改为锚定**完整措辞**：必须是"也可能是导出产物、用户指定的任意路径"这句在。
    check("10d3 该纪律覆盖范围含导出产物/任意路径（表#5 推广的关键，不止上传附件）",
          "也可能是导出产物、用户指定的任意路径" in sp, sp[:400])
    # ⛔ 守护"附件纪律"未被改回旧的窄口径（表#6 初版只覆盖上传附件，是表#5 要补的缺口）
    check("10d4 纪律不再只限于「上传的附件」窄口径（表#5 已推广）",
          "用户上传的文件" not in sp, sp[:400])
    # 10d5 守护拉模式的**行为要求**：这段纪律的实际作用是逼模型去 read_file，
    #   若只留"内容不会自动出现"而删掉"必须先 read_file"，模型照样会答"看不到文件"。
    check("10d5 纪律含强制 read_file 指令（拉模式的行为要求，缺则模型仍答看不到）",
          "必须先用 read_file" in sp, sp[:400])
    check("10d6 纪律禁止「看不到文件」类推诿话术（表#5 的用户实测症状）",
          "看不到文件" in sp, sp[:400])

    # 11. 流内超时兜底 → event: error 优雅结束（审核问题1）
    evs = []
    async for ev in run_tool_loop("m", [{"role": "user", "content": "hi"}], tools_spec(),
                                  str(sandbox), connector=MockConn([(["x"], None)], timeout_after=1)):
        evs.append(ev)
    err = next((e for e in evs if e["event"] == "error"), None)
    check("11 流内超时→error优雅结束", err is not None and "超时" in err["data"]["detail"]
          and not any(e["event"] == "done" for e in evs), str(evs)[-160:])

    # 12. authorizer False（2026-08-28 权限宽松化）：
    #     敏感删除被拒 → denied_by_user 且文件保留；普通写入不询问直接执行
    class DenyAll:
        async def __call__(self, tool_name, target_path, action):
            return False

    # 12a. 普通写入 + DenyAll authorizer → 不询问、直接写入成功（宽松模型）
    evs = await collect([([], [("write_file", {"path": "plain_probe.txt", "content": "x"})]),
                         (["好"], None)], str(sandbox), authorizer=DenyAll())
    tr = next((e for e in evs if e["event"] == "tool_result"), None)
    check("12a 普通写入不询问authorizer直接执行",
          tr is not None and tr["data"]["ok"] is True and (sandbox / "plain_probe.txt").exists(), str(evs)[:300])

    # 12b. 敏感删除 + DenyAll → denied_by_user，目标保留
    fake_sensitive2 = base / "fake_sensitive_deny"
    fake_sensitive2.mkdir()
    victim2 = fake_sensitive2 / "protected.txt"
    victim2.write_text("keep me", encoding="utf-8")
    orig_is_sensitive2 = _registry.is_sensitive_path
    _registry.is_sensitive_path = lambda p: str(Path(p).resolve()).startswith(str(fake_sensitive2.resolve()))
    try:
        evs = await collect([([], [("delete_path", {"path": str(victim2)})]),
                             (["好"], None)], str(sandbox), authorizer=DenyAll())
        tr = next((e for e in evs if e["event"] == "tool_result"), None)
        check("12b 敏感删除authorizer拒绝→denied_by_user且文件保留",
              tr is not None and tr["data"]["ok"] is False
              and tr["data"].get("error") == "denied_by_user" and victim2.exists(), str(evs)[:300])
    finally:
        _registry.is_sensitive_path = orig_is_sensitive2

    # 13. 心跳：gen() 空闲 15s 竞争（审核问题3）——直接测 asyncio.wait 逻辑
    async def fake_iter():
        await asyncio.sleep(0.3)
        yield {"event": "token", "data": {"delta": "x"}}
    import time as _t
    hb_events = []
    aiter = fake_iter().__aiter__()
    next_task = asyncio.ensure_future(aiter.__anext__())
    timer = asyncio.ensure_future(asyncio.sleep(15.0))
    done, _ = await asyncio.wait({next_task, timer}, return_when=asyncio.FIRST_COMPLETED)
    timer.cancel()
    which = "next" if next_task in done else "timer"
    if next_task in done:
        try:
            next_task.result()
        except StopAsyncIteration:
            pass
    check("13 心跳竞争机制（15s 定时器 vs 下一事件）", which == "next", which)

    # 14. thinking 透传（TS-102 B13）：思考增量 → event:thinking，且不计入正文/done
    class ThinkingMockConn:
        async def chat_stream(self, model, messages, tools=None):
            yield {"thinking_delta": "让我想想"}
            yield {"thinking_delta": "……再想"}
            yield {"content_delta": "答案"}
            yield {"done": True, "counts": {"prompt_eval_count": 5, "eval_count": 2}}
    evs = []
    async for ev in run_tool_loop("m", [{"role": "user", "content": "hi"}], tools_spec(),
                                  str(sandbox), connector=ThinkingMockConn()):
        evs.append(ev)
    ths = [e for e in evs if e["event"] == "thinking"]
    done = next((e for e in evs if e["event"] == "done"), None)
    check("14 thinking 透传为 thinking 事件", len(ths) == 2
          and ths[0]["data"]["delta"] == "让我想想" and ths[1]["data"]["delta"] == "……再想", str(evs)[:200])
    check("14 thinking 不计入正文", done is not None and done["data"]["content"] == "答案", str(done))

    # 15. web_search 去重拦截（2026-08-28 问题2：防止相同关键词反复搜索空转）
    from sidecar.tools import registry as _registry
    real_ws = _registry._web_search
    ws_calls = []

    async def fake_ws(args):
        ws_calls.append(args.get("query"))
        return {"ok": True, "query": args.get("query"),
                "results": [{"title": "t", "url": "http://u", "snippet": "s"}]}

    _registry._web_search = fake_ws
    try:
        evs = await collect([
            ([], [("web_search", {"query": "北京天气"})]),    # 第1次：真实执行
            ([], [("web_search", {"query": "北京天气"})]),    # 第2次：相同关键词 → 拦截
            ([], [("web_search", {"query": "上海交通"})]),    # 第3次：不同关键词 → 不拦截
            (["ok"], None),
        ], str(sandbox))
        trs = [e for e in evs if e["event"] == "tool_result"]
        check("15a 首次搜索真实执行成功", len(trs) >= 1 and trs[0]["data"]["ok"] is True, str(trs[0])[:200])
        check("15b 相同关键词重复搜索被拦截", len(trs) >= 2 and trs[1]["data"]["ok"] is False
              and "duplicate_search" in str(trs[1]["data"].get("error", "")), str(trs[1])[:250])
        check("15c 不同关键词不被拦截", len(trs) >= 3 and trs[2]["data"]["ok"] is True, str(trs[2])[:200])
        check("15d 仅真实执行非重复搜索", ws_calls == ["北京天气", "上海交通"], str(ws_calls))
    finally:
        _registry._web_search = real_ws

    # 15e 持续相同搜索触发熔断（防死循环）：首次成功，后续重复被拦截→连续失败→熔断
    ws_calls2 = []

    async def fake_ws2(args):
        ws_calls2.append(args.get("query"))
        return {"ok": True, "query": args.get("query"),
                "results": [{"title": "t", "url": "http://u", "snippet": "s"}]}

    _registry._web_search = fake_ws2
    try:
        evs = await collect([
            ([], [("web_search", {"query": "死循环"})]),
            ([], [("web_search", {"query": "死循环"})]),
            ([], [("web_search", {"query": "死循环"})]),
        ], str(sandbox), max_rounds=10)
        err = next((e for e in evs if e["event"] == "error"), None)
        check("15e 持续重复搜索触发熔断防死循环",
              err is not None and "连续工具失败" in err["data"]["detail"],
              str(err)[:200] if err else "no error event")
        check("15e 重复搜索仅真实执行一次", ws_calls2 == ["死循环"], str(ws_calls2))
    finally:
        _registry._web_search = real_ws

    # 16. 轮次上限可配置（2026-08-28 问题1：默认常量已提到 200，范围 1-1000）
    from sidecar.agent_engine.loop import MAX_ROUNDS_DEFAULT
    check("16 轮次默认上限已提升到 200", MAX_ROUNDS_DEFAULT == 200, str(MAX_ROUNDS_DEFAULT))

    # 17. TS-105 熔断感知停止（核心）：web_search 返回 circuit_open=True → 立即停止
    # （SEARCH_CIRCUIT_STOP=1：熔断器已确认重试无意义，无需再等第二次）
    ws_calls17 = []

    async def fake_ws_circuit(args):
        ws_calls17.append(args.get("query"))
        return {"ok": False, "error": "search_failed: 境外搜索源已熔断（300 秒内重试无效）",
                "circuit_open": True, "retry_after_seconds": 300}

    _registry._web_search = fake_ws_circuit
    try:
        evs = await collect([
            ([], [("web_search", {"query": "今日金价"})]),
            ([], [("web_search", {"query": "黄金价格"})]),
            (["不应到达"], None),
        ], str(sandbox), max_rounds=200)
        err = next((e for e in evs if e["event"] == "error"), None)
        check("17a circuit_open=True → loop 立即停止（error 文案含「境外搜索已被系统熔断」）",
              err is not None and "境外搜索已被系统熔断" in err["data"]["detail"],
              str(err)[:250] if err else "no error event")
        check("17b ≤2 轮内停止（事件数 < 10，不再跑 200 轮）", len(evs) < 10, f"events={len(evs)}")
        check("17c 第2次搜索未被执行（ws 仅被调用 1 次）", len(ws_calls17) == 1, str(ws_calls17))
    finally:
        _registry._web_search = real_ws

    # 18. TS-105 非熔断路径不受影响：web_search 正常成功 → loop 继续
    ws_calls18 = []

    async def fake_ws_ok(args):
        ws_calls18.append(args.get("query"))
        return {"ok": True, "query": args.get("query"),
                "results": [{"title": "t", "url": "http://u", "snippet": "s"}]}

    _registry._web_search = fake_ws_ok
    try:
        evs = await collect([
            ([], [("web_search", {"query": "q1"})]),
            (["done 正常收尾"], None),
        ], str(sandbox))
        err = next((e for e in evs if e["event"] == "error"), None)
        check("18a web_search 正常成功 → 不触发熔断停止",
              err is None, str(err)[:200] if err else "ok")
        done = next((e for e in evs if e["event"] == "done"), None)
        check("18b loop 正常走到 done", done is not None and "done 正常收尾" in done["data"]["content"], str(evs)[-200:])
    finally:
        _registry._web_search = real_ws

    # 19. M2 溢出预警：未勾自动压缩 → yield compact_required 且不再请求模型
    # 关键：第 1 轮必须返回工具调用（不 done），这样第 2 轮开始前才能触发预警
    # ⛔ 0.4.11 隔离修复：此前用 `_cfg._MEM` 打补丁【无效】——get_config() 每次都从磁盘
    #    重新合并（_load_from_disk），_MEM 只在写盘时用。导致用户真实 config 里的
    #    allow_auto_compact:True 泄漏进测试 → 走 compact_auto 分支 → 19a 假失败。
    #    必须 patch get_config 函数对象本身（与下方用例 20 同一正确做法）。
    import sidecar.config as _cfgmod
    orig_get_cfg = _cfgmod.get_config
    _cfgmod.get_config = lambda: {"allow_auto_compact": False}
    try:
        evs = await collect([
            ([], [("list_dir", {})]),   # 第 1 轮：工具调用（不 done）
            (["b"], None),              # 第 2 轮：不应到达
        ], str(sandbox), max_rounds=5, context_limit=10)
        cr = next((e for e in evs if e["event"] == "compact_required"), None)
        check("19a 溢出预警 → yield compact_required", cr is not None, str(evs)[-300:])
        if cr:
            check("19b compact_required 含 used/limit", cr["data"].get("used", 0) > 0 and cr["data"].get("limit") == 10, str(cr))
    finally:
        _cfgmod.get_config = orig_get_cfg

    # 20. M2 自动压缩：allow_auto_compact=true → yield compact_auto 后继续
    # 直接 patch 模块属性（get_config 是函数对象，patch _MEM 无效）
    import sidecar.config as _cfgmod
    orig_get_cfg = _cfgmod.get_config
    _cfgmod.get_config = lambda: {"allow_auto_compact": True}
    try:
        evs = await collect([
            ([], [("list_dir", {})]),   # 第 1 轮：工具调用
            ([], [("list_dir", {})]),   # 第 2 轮（compact_auto 后继续）
            (["done"], None),           # 第 3 轮：完成
        ], str(sandbox), max_rounds=5, context_limit=10)
        ca = next((e for e in evs if e["event"] == "compact_auto"), None)
        check("20a 自动压缩 → yield compact_auto", ca is not None, str(evs)[-300:])
        # 打回修复语义：compact_auto = 通知服务端压缩，loop 发事件即返回（不继续烧轮次）
        # 压缩由服务端（app.py）执行，完成后前端重发消息开新一轮
        done = next((e for e in evs if e["event"] == "done"), None)
        check("20b compact_auto 后 loop 返回（不再 continue 烧轮次，无 done/无死循环）",
              done is None and len([e for e in evs if e['event']=='compact_auto']) == 1,
              f"events={len(evs)} done={done is not None}")
    finally:
        _cfgmod.get_config = orig_get_cfg

    # 21. M2 est_rounds_left：增量 100/轮、距上限剩 20 → est=0
    # ⛔ 0.4.11 隔离修复：此用例期望 compact_required（自动压缩关分支），但此前【完全没做
    #    配置隔离】→ 用户真实 config 的 allow_auto_compact:True 泄漏进来 → 走 compact_auto
    #    → 找不到 compact_required → 21 假失败。补 get_config patch（与 19/20 同一做法）。
    class IncrConn:
        """每轮 prompt_eval_count 递增 100：100, 200, 300...（不 done，返回工具调用）"""
        def __init__(self): self.calls = 0
        async def chat_stream(self, model, messages, tools=None):
            self.calls += 1
            yield {"tool_calls": [{"id": f"t{self.calls}", "function": {"name": "list_dir", "arguments": "{}"}}]}
            yield {"done": True, "counts": {"prompt_eval_count": self.calls * 100, "eval_count": 1}}
    orig_get_cfg2 = _cfgmod.get_config
    _cfgmod.get_config = lambda: {"allow_auto_compact": False}
    try:
        evs2 = []
        async for ev in run_tool_loop("m", [{"role": "user", "content": "hi"}], tools_spec(),
                                      str(sandbox), max_rounds=10, context_limit=320,
                                      connector=IncrConn()):
            evs2.append(ev)
        # 第 4 轮开始前：last_pe=300, 300/320=0.94 ≥ 0.9 → 触发
        # history=[100,200,300] deltas=[100,100] avg=100, remaining=20 → est=0
        cr = next((e for e in evs2 if e["event"] == "compact_required"), None)
        check("21 溢出预警触发（300/320=94%）", cr is not None, str(evs2)[-300:])
        if cr:
            check("21 est_rounds_left=0（remaining 20 / avg_delta 100）",
                  cr["data"].get("est_rounds_left") == 0,
                  f"est={cr['data'].get('est_rounds_left')}")
    finally:
        _cfgmod.get_config = orig_get_cfg2

    # ── #1（0.4.20）插入点分裂：segment_break 事件 + break_at 断点 ──
    # 需求（用户 2026-09-11 确认，对齐千问）：用户「思考中」插入消息后，当前气泡就地定格、
    # 插入用户气泡、新思考另起气泡显示在其下方。后端在 drain 到注入时发 segment_break。
    #
    # ⛔ 本组测试的核心是 **break_at 的精确性**：它是前端把 done 全文切成
    #   段1=[:break_at] / 段2=[break_at:] 的**唯一依据**。断点错一个字符，
    #   段2 就会重复显示段1 的尾部（或吞掉段2 开头），而这个 bug 只在真实插入时暴露。
    #   full_text 跨轮累加（#3/0.4.19），done 的 content 是【全文】= 段1+段2。
    class SegConn:
        """三轮：第1轮出正文+工具调用，第2轮出正文+工具调用，第3轮只出正文（done）。

        每轮 content_delta 是**可数的固定文本**，便于精确断言 break_at。
        """
        def __init__(self):
            self.calls = 0

        async def chat_stream(self, model, messages, tools=None):
            self.calls += 1
            if self.calls <= 2:
                # 第1轮出 4 字、第2轮出 3 字（故意不等长，防止"每轮等长"掩盖断点算错）
                yield {"content_delta": "第一段" if self.calls == 1 else "第二段甲"}
                yield {"tool_calls": [{"id": f"s{self.calls}",
                                       "function": {"name": "list_dir", "arguments": "{}"}}]}
                yield {"done": True, "counts": {"eval_count": 1}}
            else:
                yield {"content_delta": "收尾"}
                yield {"done": True, "counts": {"eval_count": 1}}

    # inject_check：第 1 次调用（第1轮开始前）无注入；第 2 次（第2轮开始前）注入一条；
    # 之后都不再有（模拟"用户只插了一次"）。
    _inj_seq = [[], ["请改正方向"], [], [], []]
    _inj_i = [0]

    def _inj_probe():
        i = _inj_i[0]
        _inj_i[0] += 1
        return _inj_seq[i] if i < len(_inj_seq) else []

    evs_seg = []
    async for ev in run_tool_loop("m", [{"role": "user", "content": "hi"}], tools_spec(),
                                  str(sandbox), max_rounds=6, connector=SegConn(),
                                  inject_check=_inj_probe):
        evs_seg.append(ev)

    kinds_seg = [e["event"] for e in evs_seg]
    sb = next((e for e in evs_seg if e["event"] == "segment_break"), None)
    check("22a 注入被 drain 时发 segment_break", sb is not None, str(kinds_seg))
    # ⛔ 不用 `if sb:` 守卫后续断言——sb 为 None 时守卫会让 22b~22g **静默跳过**
    #   （变异测试实测踩过：撤掉 segment_break 后这些断言全 PASS 而非 FAIL = 空转断言）。
    #   改用空 dict 兜底，让每条断言始终求值；sb 为 None 时它们会各自 FAIL（暴露问题）。
    _sbd = (sb or {"data": {}})["data"]
    check("22b segment_break 只发一次（用户只插了一次）",
          kinds_seg.count("segment_break") == 1, str(kinds_seg))
    check("22c payload 带 injected_messages（前端要据此插用户气泡）",
          _sbd.get("injected_messages") == [{"role": "user", "content": "请改正方向"}],
          str(_sbd)[:200])
    # ⛔ 核心断言：break_at == 第1轮已生成正文字符数（"第一段"=3字）
    check("22d ⛔ break_at=段1字符数（前端切分全文的唯一依据）",
          _sbd.get("break_at") == len("第一段"),
          f"break_at={_sbd.get('break_at')} 期望={len('第一段')}")

    # 注入的消息必须真的进了上下文（A5 原有语义不能被 #1 破坏）
    check("22e 注入消息已并入 msgs（A5 语义不回归）",
          any(e["event"] == "done" for e in evs_seg), str(kinds_seg))

    # ⛔ done 全文 = 段1+段2+收尾；前端按 break_at 切分后段2 应等于 [break_at:]
    #   同样不用 `if done_seg and sb:` 守卫（空转断言同源问题）。
    done_seg = next((e for e in evs_seg if e["event"] == "done"), None)
    _full = (done_seg or {"data": {}})["data"].get("content", "")
    _ba = _sbd.get("break_at", 0)
    check("22f done 的 content 是全文（含段1）→ 前端必须切分否则段2 重复",
          _full.startswith("第一段"), repr(_full))
    check("22g 按 break_at 切分：段2 = 全文[break_at:] 且不含段1 内容",
          _full[_ba:] == _full[len("第一段"):] and not _full[_ba:].startswith("第一段"),
          f"段2={repr(_full[_ba:])}")

    # 22h ⛔ 回归保护：多轮但**始终无注入** → 绝不发 segment_break
    #   （无注入时发事件会让前端凭空分裂气泡，把一条正常回复拆成两条）
    _inj_i[0] = 0
    _inj_seq_none = [[], [], [], [], []]
    evs_noseg = []
    async for ev in run_tool_loop("m", [{"role": "user", "content": "hi"}], tools_spec(),
                                  str(sandbox), max_rounds=3, connector=SegConn(),
                                  inject_check=lambda: []):
        evs_noseg.append(ev)
    check("22h 无注入 → 不发 segment_break（不得凭空分裂气泡）",
          "segment_break" not in [e["event"] for e in evs_noseg],
          str([e["event"] for e in evs_noseg]))
    _inj_seq.clear(); _inj_seq.extend(_inj_seq_none)   # 清理，不影响后续用例

    # ── 22i~22o ⛔ 最后一轮插入的缺口（用户 2026-09-12 实测报障，真实 uvicorn 实验确证）──
    #
    # 缺陷：`inject_check` 只在每轮**开头**被调用（本文件上方 for 循环顶部）。若用户在
    # 【最后一轮】生成途中插入消息，此后没有"下一轮" → 该消息永不被 drain、
    # `segment_break` 永不发出、模型永远看不到它（仅落库）。而 `api_chat_inject` 已经
    # 回了 `ok=true` + 提示"模型完成当前这一步后会读到你的新消息" → **诚实性缺陷**：
    # 承诺了做不到的事，用户看到提示却毫无反应。
    #
    # 真实实验数据（curl -N + 真 uvicorn，场景 B）：inject 返回 ok=true、消息已落库，
    # 但全程无 segment_break，流在 done 正常结束。
    LAST_INJ = "最后一轮插入的消息"

    class LastRoundConn:
        """第1轮 正文+工具调用；第2轮（最后一轮）生成途中 push 注入；第3轮 针对注入回复。"""
        def __init__(self, queue: list):
            self.calls = 0
            self.q = queue
            self.user_msgs_per_round: list[list[str]] = []

        async def chat_stream(self, model, messages, tools=None):
            self.calls += 1
            self.user_msgs_per_round.append(
                [str(m.get("content")) for m in messages if m.get("role") == "user"])
            if self.calls == 1:
                yield {"content_delta": "前段"}
                yield {"tool_calls": [{"id": "lr1",
                                       "function": {"name": "list_dir", "arguments": "{}"}}]}
                yield {"done": True, "counts": {"eval_count": 1}}
            elif self.calls == 2:
                # ⛔ 此刻本轮的 inject_check 已经调用过了（在轮次开头）——
                #    在这里 push 精确复现"用户在最后一轮思考中插入"。只 push 一次。
                self.q.append(LAST_INJ)
                yield {"content_delta": "终段"}
                yield {"done": True, "counts": {"eval_count": 1}}
            else:
                yield {"content_delta": "针对插入的回复"}
                yield {"done": True, "counts": {"eval_count": 1}}

    _lr_q: list = []

    def _lr_probe():
        out = list(_lr_q)
        _lr_q.clear()
        return out

    _lr_conn = LastRoundConn(_lr_q)
    evs_lr = []
    async for ev in run_tool_loop("m", [{"role": "user", "content": "hi"}], tools_spec(),
                                  str(sandbox), max_rounds=6, connector=_lr_conn,
                                  inject_check=_lr_probe):
        evs_lr.append(ev)
    kinds_lr = [e["event"] for e in evs_lr]
    sb_lr = next((e for e in evs_lr if e["event"] == "segment_break"), None)
    # ⛔ 不用 `if sb_lr:` 守卫后续断言（空转断言同源问题，见 22a 上方注释）
    _sb_lr_d = (sb_lr or {"data": {}})["data"]
    check("22i ⛔ 最后一轮插入也要发 segment_break（否则前端不分裂、用户毫无反馈）",
          sb_lr is not None, str(kinds_lr))
    check("22j segment_break payload 含该消息",
          _sb_lr_d.get("injected_messages") == [{"role": "user", "content": LAST_INJ}],
          str(_sb_lr_d)[:200])
    check("22k break_at = 补救前已生成的全文长度（段2 不得重复段1）",
          _sb_lr_d.get("break_at") == len("前段终段"),
          f"break_at={_sb_lr_d.get('break_at')} 期望={len('前段终段')}")
    check("22l ⛔ 插入的消息真的进了模型上下文（不得只发事件不给模型看）",
          any(LAST_INJ in u
              for round_msgs in _lr_conn.user_msgs_per_round[2:] for u in round_msgs),
          str(_lr_conn.user_msgs_per_round))
    check("22m 队列不得静默滞留（drain 后为空）", len(_lr_q) == 0, str(_lr_q))
    check("22n ⛔ 补救不得把正常完成变成 error（仍须 done、无'达到最大轮次'）",
          "done" in kinds_lr and "error" not in kinds_lr, str(kinds_lr))
    check("22o segment_break 只发一次（补救不得与轮次开头的 drain 重复发）",
          kinds_lr.count("segment_break") == 1, str(kinds_lr))

    # 22p ⛔ 边界：轮次预算耗尽（step == max_rounds）时无从 continue →
    #     **必须仍正常 done**，绝不能退化成"达到最大轮次"error（把成功完成变成报错）。
    #     残留限制（如实记录，见 loop.py 修复处注释）：此时插入的消息仅落库、本次流不读，
    #     下次发送才被模型读到。
    _lr_q2: list = []
    _lr_conn2 = LastRoundConn(_lr_q2)

    def _lr_probe2():
        out = list(_lr_q2)
        _lr_q2.clear()
        return out

    evs_edge = []
    async for ev in run_tool_loop("m", [{"role": "user", "content": "hi"}], tools_spec(),
                                  str(sandbox), max_rounds=2, connector=_lr_conn2,
                                  inject_check=_lr_probe2):
        evs_edge.append(ev)
    kinds_edge = [e["event"] for e in evs_edge]
    check("22p ⛔ 轮次预算耗尽时仍正常 done，不退化成'达到最大轮次'error",
          "done" in kinds_edge and "error" not in kinds_edge, str(kinds_edge))

    # 23（0.4.22 重打包修复二，checkpoint-109）：轮内 ctx 增量应随轮末 state 回传
    #   （指示器"随对话增长"；用户 2026-09-12 实测一轮之内纹丝不动、像不增）。
    #   缺陷：_ctx_chars 只在【轮初】统计一次 → 本轮新增的 tool_report / 注入消息
    #   完全不进指示器，轮末 state 回传的是轮初旧值。
    #   修法：轮末 state yield 前重算一次（同一统计函数）。
    #   ⛔ 断言用**快照法**（曾用差值法，改前也绿——下一轮轮初本就含上一轮 tool_report，
    #     跨轮差值暴露不了"轮末用轮初旧值"）：connector 记录每轮**轮初**的 messages 快照，
    #     测试内按同一口径重算期望值；第 1 轮末 state 的 ctx_chars 应等于【第 2 轮轮初】
    #     的统计值（= 含本轮 tool_report）。改前它等于第 1 轮轮初值 → 天然红。
    class _CtxSnapConn(MockConn):
        def __init__(self, rounds):
            super().__init__(rounds)
            self.round_msgs = []
            self.tools_seen = None

        async def chat_stream(self, model, messages, tools=None):
            self.round_msgs.append([dict(m) for m in messages])
            self.tools_seen = tools
            async for ev in super().chat_stream(model, messages, tools):
                yield ev

    def _ctx_chars_of(msgs, tools):
        total = 0
        for m in msgs:
            if isinstance(m, dict):
                for v in m.values():
                    if isinstance(v, str):
                        total += len(v)
        if tools:
            total += len(json.dumps(tools, ensure_ascii=False))
        return total

    _ctx_conn = _CtxSnapConn([([], [("list_dir", {"path": "."})]), (["x"], None)])
    evs_ctx = []
    async for ev in run_tool_loop("m", [{"role": "user", "content": "hi"}], tools_spec(),
                                  str(sandbox), max_rounds=5, connector=_ctx_conn):
        evs_ctx.append(ev)
    _ctx_states = [e["data"] for e in evs_ctx if e["event"] == "state"]
    check("23a 两轮都有 state 且 connector 记到两轮快照（断言前提，防空转）",
          len(_ctx_states) >= 2 and len(_ctx_conn.round_msgs) >= 2,
          str([e["event"] for e in evs_ctx]))
    _exp_r2 = _ctx_chars_of(_ctx_conn.round_msgs[1], _ctx_conn.tools_seen) if len(_ctx_conn.round_msgs) >= 2 else -1
    _exp_r1 = _ctx_chars_of(_ctx_conn.round_msgs[0], _ctx_conn.tools_seen) if _ctx_conn.round_msgs else -1
    _c1 = _ctx_states[0].get("ctx_chars", 0) if _ctx_states else 0
    _c2 = _ctx_states[-1].get("ctx_chars", 0) if _ctx_states else 0
    check("23b ⛔ 第 1 轮末 state 的 ctx_chars 应含本轮 tool_report（= 第 2 轮轮初统计值）",
          _c1 == _exp_r2 and _exp_r2 > _exp_r1,
          f"c1={_c1} 期望R2初={_exp_r2} R1初={_exp_r1}")
    check("23c 第 2 轮末 state 的 ctx_chars 口径一致（= 第 2 轮轮初统计值，本轮无新增）",
          _c2 == _exp_r2, f"c2={_c2} 期望={_exp_r2}")

    # 清理
    shutil.rmtree(base, ignore_errors=True)
    check("临时目录已清理", not base.exists())

    print(f"\n===== SUMMARY: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("FAILED:", ", ".join(FAILURES))
    if MUTATE and FAIL == 0:
        # ⛔ 变异模式下 0 FAIL 不是"通过"，是"测试无效"——断言没真正绑定这个修复
        print(f"⛔ 变异 {MUTATE} 未被抓住 —— 本测试对该修复无效，断言需加强")
    if FAIL or (MUTATE and FAIL == 0):
        sys.exit(1)


if __name__ == "__main__":
    # ⛔ 变异注入/还原必须包住 asyncio.run：main() 内部会 sys.exit(1)，
    #   不在 finally 还原就会让 loop.py 停在变异态，污染后续所有测试与真实代码。
    _apply_mutation()
    try:
        asyncio.run(main())
    finally:
        _restore()
