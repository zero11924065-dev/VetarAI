# VetarAI - Local-first multi-agent orchestration application
# Copyright (C) 2026 zero11924065-dev
# GPL-3.0-or-later（见仓库 LICENSE）
"""#3（0.4.19）专项：多轮工具调用时全程文本累积，done 不得只带最后一轮。

═══ 治的是什么（用户实测最致命的 bug）═══
用户原话：「他修改了回复我的内容…我都看到他输出了我需要的部分内容，参考的法条和其他一些
内容，但是最终会话全部消失」。

根因：`full_text = ""` 原本在 `for step in range(...)` **循环体内** → 每轮重置。
一个多轮工具调用流里：
  第1轮 text_A + 工具 → full_text=text_A → 继续下一轮
  第2轮 text_B + 工具 → full_text 被**清零**后 = text_B（text_A 永久丢失）
  第3轮 text_C 无工具 → done 只带 text_C
而前端在流式期间已用 token 事件把 A+B+C 逐字显示给用户了，done 一到又**整体替换**成只剩 C
（app.py `_state["text"] = d["content"]`、前端 `content = d.content` 都是替换语义）。
→ 用户看到的内容消失，且落库也只有 C。
DB 铁证：用户库 id=52（user 2705 字，第4步指令）→ id=53（assistant 仅 **211** 字）。

═══ 修法 ═══
full_text 提到**轮次循环外**累积；done 带全程完整文本。
⛔ 前端/app.py 的"done 为准覆盖"契约**不变**——覆盖的目标现在是完整文本而非残片，
   所以这两处不需要改（改了反而会双重拼接）。

运行：.venv/bin/python -m sidecar.agent_engine.test_p3_multiround_text
"""
import asyncio
import json
import sys
import tempfile
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


class MockConn:
    """按序返回预置脚本的假 connector（同 test_loop.py 的范式，不自造不可信环境）。
    每轮脚本 = (content_chunks, tool_calls)。"""

    def __init__(self, rounds):
        self.rounds = rounds
        self.calls = 0

    async def chat_stream(self, model, messages, tools=None):
        i = min(self.calls, len(self.rounds) - 1)
        self.calls += 1
        content, tcs = self.rounds[i]
        for ch in content:
            yield {"content_delta": ch}
        if tcs:
            yield {"tool_calls": [{"id": f"mock_{self.calls}",
                                   "function": {"name": n, "arguments": json.dumps(a)}}
                                  for n, a in tcs]}
        yield {"done": True, "counts": {"prompt_eval_count": 10, "eval_count": 5}}


async def collect(script, sandbox, max_rounds=6):
    from sidecar.agent_engine.loop import run_tool_loop
    from sidecar.agent_engine.loop import tools_spec
    evs = []
    async for ev in run_tool_loop("m", [{"role": "user", "content": "hi"}], tools_spec(),
                                 str(sandbox), max_rounds=max_rounds,
                                 connector=MockConn(script)):
        evs.append(ev)
    return evs


def done_content(evs):
    d = next((e for e in evs if e["event"] == "done"), None)
    return (d or {}).get("data", {}).get("content")


def token_stream(evs):
    """前端逐字显示给用户看的全部内容（token 事件的 delta 拼接）。"""
    return "".join(e["data"]["delta"] for e in evs
                   if e["event"] == "token" and e["data"].get("delta"))


async def amain():
    from sidecar.agent_engine.loop import run_tool_loop, tools_spec  # noqa: F401
    base = Path(tempfile.mkdtemp(prefix="p3_"))
    sandbox = base / "ws"
    sandbox.mkdir()
    (sandbox / "a.txt").write_text("hello", encoding="utf-8")

    TOOL = ("list_dir", {"path": str(sandbox)})

    # ── T1 核心：三轮各有文本，末轮无工具 → done 必须含全部三轮 ──
    evs = await collect([
        (["律师函", "（第一轮）"], [TOOL]),
        (["法条引用", "（第二轮）"], [TOOL]),
        (["结语", "（第三轮）"], None),
    ], sandbox)
    dc = done_content(evs)
    check("T1a done 存在", dc is not None, str([e["event"] for e in evs])[:200])
    check("T1b ⛔ done 含第1轮文本（旧实现会丢失）", dc is not None and "律师函（第一轮）" in dc, repr(dc))
    check("T1c ⛔ done 含第2轮文本（旧实现会丢失）", dc is not None and "法条引用（第二轮）" in dc, repr(dc))
    check("T1d done 含第3轮文本", dc is not None and "结语（第三轮）" in dc, repr(dc))
    # ⛔ 最关键的一致性断言：用户看到的 == 最终留下的
    check("T1e ⛔ done 内容 == token 流全部内容（用户看到的就是留下的，不缩水）",
          dc == token_stream(evs), f"done={len(dc or '')}字 vs token={len(token_stream(evs))}字")
    # ⛔ 崩溃安全（本批教训）：不得用 str.index()——变异态下子串缺失会抛 ValueError，
    #    导致【整个套件崩溃】、T2~T8 全部不执行（看不到它们是否也能抓住变异）。
    #    用 find()（缺失返回 -1，不抛）+ 显式判 -1，失败时是干净的 check FAIL 而非崩溃。
    _i1, _i2, _i3 = (dc or "").find("第一轮"), (dc or "").find("第二轮"), (dc or "").find("第三轮")
    check("T1f 三轮文本按发生顺序拼接（不是乱序）",
          -1 not in (_i1, _i2, _i3) and _i1 < _i2 < _i3,
          f"位置={_i1},{_i2},{_i3} content={dc!r}")

    # ── T2 用户实测场景：前几轮长篇正文 + 末轮一句短话 ──
    long_body = "根据《中华人民共和国民法典》第六百七十五条，借款人应当按照约定的期限返还借款。" * 3
    evs2 = await collect([
        ([long_body], [TOOL]),
        (["我停止执行，不再动。"], None),
    ], sandbox)
    dc2 = done_content(evs2)
    check("T2a ⛔ 长篇正文未被末轮短句覆盖（复现用户 bug 场景）",
          dc2 is not None and "民法典" in dc2 and "第六百七十五条" in dc2, repr(dc2)[:160])
    check("T2b 末轮短句也在", dc2 is not None and "我停止执行" in dc2, repr(dc2)[-80:])
    check("T2c ⛔ done 长度 ≈ 全文长度（不是只剩末轮 9 字）",
          dc2 is not None and len(dc2) >= len(long_body), f"{len(dc2 or '')} vs {len(long_body)}")

    # ── T3 行为改进：中间轮有文本、末轮空文本+无工具 → 不再误报"模型未返回任何内容" ──
    # 旧实现：full_text 被重置为空 → 走 error 分支报"模型未返回任何内容"，前面轮次的成果全废。
    # 新实现：累积非空 → 正常 done 带出已有成果。
    evs3 = await collect([
        (["这是有价值的成果"], [TOOL]),
        ([], None),
    ], sandbox)
    dc3 = done_content(evs3)
    check("T3a 末轮空文本时不再误判为「模型未返回任何内容」",
          dc3 is not None and "这是有价值的成果" in dc3,
          str([e["event"] for e in evs3])[:160])
    check("T3b 无 error 事件（不浪费用户已得到的成果）",
          not any(e["event"] == "error" for e in evs3), str([e["event"] for e in evs3])[:160])

    # ── T4 回归：单轮无工具（最常见路径）行为不变 ──
    evs4 = await collect([(["一次性回答"], None)], sandbox)
    dc4 = done_content(evs4)
    check("T4a 单轮回答行为不变", dc4 == "一次性回答", repr(dc4))
    check("T4b 单轮 token 与 done 一致", dc4 == token_stream(evs4))

    # ── T5 回归：全程无文本（纯工具流）仍按既有语义报"模型未返回任何内容" ──
    evs5 = await collect([([], [TOOL]), ([], None)], sandbox)
    check("T5 全程无文本 → 仍走 error 分支（既有语义不变，不得因累积而静默成功）",
          any(e["event"] == "error" for e in evs5) and done_content(evs5) is None,
          str([e["event"] for e in evs5])[:160])

    # ── T6 回归：多轮工具都执行了（累积没改变轮次推进）──
    evs6 = await collect([
        (["一"], [TOOL]), (["二"], [TOOL]), (["三"], [TOOL]), (["四"], None),
    ], sandbox)
    n_tool = sum(1 for e in evs6 if e["event"] == "tool_result")
    check("T6a 四轮脚本的工具都执行了", n_tool == 3, f"tool_result={n_tool}")
    dc6 = done_content(evs6)
    check("T6b 四轮文本全在", dc6 == "一二三四", repr(dc6))

    # ── T7 源码断言：累积变量在循环外、循环内不得重置 ──
    # ⛔ 锚定代码形态（本批已多次踩"断言被注释污染"的坑）：用正则确认
    #    `full_text = ""` 只出现在 for 循环【之前】，且循环体内没有重新赋值。
    import re as _re
    src = (Path(__file__).resolve().parents[1] / "agent_engine" / "loop.py").read_text(encoding="utf-8")
    fn_src = src.split("async def run_tool_loop")[1].split("\nasync def ")[0]
    loop_start = fn_src.index("for step in range(1, max_rounds + 1):")
    before, inside = fn_src[:loop_start], fn_src[loop_start:]
    # 循环外恰好一次初始化
    check("T7a full_text 在轮次循环【外】初始化（恰好一次）",
          len(_re.findall(r"^\s{4}full_text = \"\"", before, _re.M)) == 1,
          str(_re.findall(r"^\s{4}full_text = .*", before, _re.M)))
    # ⛔ 循环体内不得有任何 full_text 重新赋值（注释里提到不算：只匹配行首赋值语句）
    resets = _re.findall(r"^\s+full_text\s*=\s*\"\"", inside, _re.M)
    check("T7b ⛔ 循环体内无 full_text 重置（重置=丢失前几轮内容）",
          len(resets) == 0, f"命中 {len(resets)} 处重置")
    # 累积语句仍在（token 分支）
    check("T7c token 分支仍累积 full_text", "full_text += ev[\"content_delta\"]" in inside)
    # done 带完整累积文本
    check("T7d done 事件带 full_text（完整累积）",
          _re.search(r'"done",\s*"data":\s*\{"content":\s*full_text', inside) is not None)

    # ── T8 下游契约：app.py / 前端"done 为准覆盖"仍成立（覆盖目标已是完整文本）──
    app_src = (Path(__file__).resolve().parents[1] / "app.py").read_text(encoding="utf-8")
    check("T8a app.py 落库用 done 的完整 content（覆盖语义无需改，因内容已完整）",
          '_state["text"] = _d["content"]' in app_src)
    fe = (Path(__file__).resolve().parents[2] / "renderer" / "src" / "panels" / "ChatPanel.tsx").read_text(encoding="utf-8")
    check("T8b 前端 done 分支仍以 d.content 为准（内容已完整，不双重拼接）",
          "if (typeof d.content === 'string') content = d.content;" in fe)

    print(f"\n===== #3 多轮文本累积专项: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        for f in FAILURES:
            print("  ✗", f)
    return 1 if FAIL else 0


def main():
    return asyncio.run(amain())


if __name__ == "__main__":
    sys.exit(main())
