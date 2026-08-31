"""M1-2 tool loop 单测（mock Ollama，venv 内 python test_loop.py 直接跑）。
只输出 PASS/FAIL 摘要。
"""
import asyncio
import json
import shutil
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from sidecar.agent_engine.loop import run_tool_loop, tools_spec, build_system_prompt  # noqa: E402

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
    import sidecar.config.store as _cfg
    orig_cfg_mem = dict(_cfg._MEM) if _cfg._MEM else {}
    _cfg._MEM = {**(_cfg._MEM or {}), "allow_auto_compact": False}
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
        _cfg._MEM = orig_cfg_mem

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
        _cfg._MEM = orig_cfg_mem

    # 21. M2 est_rounds_left：增量 100/轮、距上限剩 20 → est=0
    class IncrConn:
        """每轮 prompt_eval_count 递增 100：100, 200, 300...（不 done，返回工具调用）"""
        def __init__(self): self.calls = 0
        async def chat_stream(self, model, messages, tools=None):
            self.calls += 1
            yield {"tool_calls": [{"id": f"t{self.calls}", "function": {"name": "list_dir", "arguments": "{}"}}]}
            yield {"done": True, "counts": {"prompt_eval_count": self.calls * 100, "eval_count": 1}}
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

    # 清理
    shutil.rmtree(base, ignore_errors=True)
    check("临时目录已清理", not base.exists())

    print(f"\n===== SUMMARY: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("FAILED:", ", ".join(FAILURES))
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
