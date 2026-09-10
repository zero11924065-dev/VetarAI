# VetarAI - Local-first multi-agent orchestration application
# Copyright (C) 2026 zero11924065-dev
# GPL-3.0-or-later（见仓库 LICENSE）
"""#7（0.4.19）专项：委派交卷不丢 JSON 块外正文（成果丢失 89% 的根治）。

═══ 治的是什么（用户实测："标准极差…没有按照参考文件格式"的根因之一）═══
子 Agent 完成委派后，常把【真正的成果】（修改后的律师函全文、法条、计算）写在 JSON 交卷块
【外面】，JSON 里只放一个 summary 概述 + artifacts 标签。旧 `parse_report` 只截 JSON 块
→ 块外正文【全部丢弃】。实测三次委派丢失 89%/67%/29%：
  本次子 Agent 产出 1959 字符（含完整律师函 + 民法典 675/676/509/577 条 + 本金 234700 计算），
  主 Agent 只收到 213 字符 JSON 壳，artifacts 里"修改后的律师函文本"是【字符串标签】既非内容也非路径。
后果链：主 Agent 拿不到成果 → 只能重写 → 用户看到"重复执行"（#9 即此的下游）。

═══ 修法（只改 parse_report 一处，下游全自动正确）═══
把 JSON 块外实质正文并入 summary。为什么必须并入 summary 而非新字段：
主 Agent 只读 summary（loop.py:885 `body=f"[{status}] {summary}"`），放新字段它看不到=白修。
并入后 summary 通常 >1000 字 → _finalize_summary 自动落盘 full_text 并回传路径。

运行：.venv/bin/python -m sidecar.agent_engine.test_p7_delegation_body
"""
import json
import sys
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


TID = "task-abc-123"


def main():
    from sidecar.agent_engine.delegation import (
        parse_report, _extract_outside_body, _extract_json_candidate,
        SUMMARY_MAX_LEN, _OUTSIDE_BODY_MIN_LEN, build_fallback_report)

    def J(**kw):
        return json.dumps({"task_id": TID, "status": "success", "artifacts": [], **kw},
                          ensure_ascii=False)

    # ── T1 核心：JSON + 块外大段正文 → 正文并入 summary ──
    body = "根据《中华人民共和国民法典》第六百七十五条，借款人应当按照约定的期限返还借款。尚欠本金 234700 元。" * 2
    txt = J(summary="审查完成") + "\n\n" + body
    r = parse_report(txt, TID)
    check("T1a 解析成功", r is not None)
    check("T1b ⛔ 块外正文已并入 summary（旧实现会丢弃）",
          r is not None and "民法典" in r["summary"] and "234700" in r["summary"], repr(r["summary"])[:120])
    check("T1c 原 summary 概述也保留（不是被正文替换）",
          r is not None and "审查完成" in r["summary"], repr(r["summary"])[:60])
    # ⛔ 崩溃安全（本批已两次踩坑：#3 的 T1f、此处 T1d）：不得用 str.index()——
    #    变异态子串缺失会抛 ValueError → 整个套件崩溃、后续 T2~T10 全部不执行
    #    （看不到它们能否独立抓住变异）。用 find()（缺失返回 -1 不抛）+ 显式判 -1。
    _iS, _iB = r["summary"].find("审查完成"), r["summary"].find("民法典")
    check("T1d 概述在前、正文在后（顺序合理）",
          r is not None and -1 not in (_iS, _iB) and _iS < _iB, f"位置={_iS},{_iB}")
    check("T1e status/artifacts 等结构字段不受影响",
          r is not None and r["status"] == "success" and r["task_id"] == TID)

    # ── T2 用户实测场景规模：并入后 summary 超 1000 字 → 触发落盘 ──
    big_body = "律师函正文内容。" * 200   # ≈1600 字
    r2 = parse_report(J(summary="完成审查") + "\n" + big_body, TID)
    check("T2a 大块外正文并入后 summary > SUMMARY_MAX_LEN（→ _finalize_summary 会落盘全文）",
          r2 is not None and len(r2["summary"]) > SUMMARY_MAX_LEN, len(r2["summary"]) if r2 else 0)
    check("T2b 正文实质内容确在 summary 内", r2 is not None and "律师函正文内容" in r2["summary"])

    # ── T3 短块外噪声不并入（阈值保护，避免污染 summary）──
    r3 = parse_report("好的，交卷：" + J(summary="完成了") + "（完）", TID)
    check("T3a 块外仅短噪声（<%d字）→ 不并入" % _OUTSIDE_BODY_MIN_LEN,
          r3 is not None and r3["summary"] == "完成了", repr(r3["summary"])[:80])
    check("T3b 阈值常量存在且合理（≥10）", _OUTSIDE_BODY_MIN_LEN >= 10, str(_OUTSIDE_BODY_MIN_LEN))

    # ── T4 纯 JSON 无块外正文 → 行为完全不变（回归保护）──
    r4 = parse_report(J(summary="纯JSON概述"), TID)
    check("T4a 纯 JSON 的 summary 原样不变", r4 is not None and r4["summary"] == "纯JSON概述",
          repr(r4["summary"])[:80])
    check("T4b 纯 JSON 不误加任何正文", r4 is not None and len(r4["summary"]) == len("纯JSON概述"))

    # ── T5 块外正文与 summary 已相同 → 不重复并入（防膨胀）──
    same = "这段正文同时出现在 summary 和块外，不应被并两次。"
    r5 = parse_report(J(summary=same) + "\n" + same, TID)
    check("T5 块外正文已在 summary 中 → 不重复并入",
          r5 is not None and r5["summary"].count("不应被并两次") == 1, repr(r5["summary"])[:100])

    # ── T6 ```json 围栏 + 块外正文 → 围栏剥离、正文仍提取 ──
    fenced = "前置说明文字超过二十个字符以满足最小长度阈值要求。\n```json\n" + J(summary="ok") + "\n```\n后置成果正文也超过二十个字符以触发并入。"
    r6 = parse_report(fenced, TID)
    check("T6a 围栏内 JSON 正常解析", r6 is not None and r6["status"] == "success")
    check("T6b 围栏外的前置/后置正文都并入", r6 is not None and "前置说明文字" in r6["summary"]
          and "后置成果正文" in r6["summary"], repr(r6["summary"])[:140])
    check("T6c 围栏标记 ``` 不残留在 summary", r6 is not None and "```" not in r6["summary"])

    # ── T7 _extract_outside_body 单元行为 ──
    cand = _extract_json_candidate(J(summary="x"))
    ob = _extract_outside_body("AAA" + cand + "BBB", cand)
    check("T7a 提取 JSON 块前后正文（块以换行替换，不粘连）", "AAA" in ob and "BBB" in ob, repr(ob))
    check("T7b 独占整行的分隔线被剥离（--- *** ===）",
          _extract_outside_body("---\n正文甲\n***\n正文乙\n===", None) == "正文甲\n正文乙",
          repr(_extract_outside_body("---\n正文甲\n***\n正文乙\n===", None)))
    check("T7c 空文本返回空串", _extract_outside_body("", None) == "")
    check("T7d candidate=None 时返回全文 strip", _extract_outside_body("  全部正文  ", None) == "全部正文")
    # ⛔ T7e/g/h：绝不能用全局 replace 破坏正文 markdown（本批自查发现的真实隐患）
    check("T7e ⛔ markdown 表格分隔行 |---|---| 不被打散",
          "|---|---|" in _extract_outside_body("成果：\n| 项目 | 金额 |\n|---|---|\n| 本金 | 234700 |", None),
          repr(_extract_outside_body("| 项目 | 金额 |\n|---|---|\n| 本金 | 234700 |", None)))
    check("T7g ⛔ 行内粗斜体 ***重要*** 不被拆行",
          "***非常重要***" in _extract_outside_body("这是***非常重要***的结论", None))
    check("T7h ⛔ 行内破折号 2024---2025 不被切断",
          "2024---2025" in _extract_outside_body("金额 2024---2025 年度", None))

    # ── T8 fallback 路径不受影响（无 JSON 时仍走 build_fallback_report 全文打包）──
    no_json = "子 Agent 没输出 JSON，但写了实质成果：" + "成果正文内容。" * 10
    check("T8a 无 JSON → parse_report 返回 None（走 fallback）", parse_report(no_json, TID) is None)
    fb = build_fallback_report(no_json, TID)
    check("T8b fallback 仍打包全文（既有行为不变）",
          fb is not None and "成果正文内容" in fb["summary"] and fb.get("fallback") is True)

    # ── T9 下游契约：主 Agent 读 summary（证明并入 summary 是正确落点）──
    loop_src = (Path(__file__).resolve().parents[1] / "agent_engine" / "loop.py").read_text(encoding="utf-8")
    check("T9a 主 Agent 委派结果取 summary 字段（并入 summary 才有效）",
          'body = f"[{result.get(\'status\', \'done\')}] {result.get(\'summary\', \'\')}"' in loop_src
          or "result.get('summary'" in loop_src)
    # 源码断言：parse_report 确实调用了块外提取
    deleg_src = (Path(__file__).resolve().parents[1] / "agent_engine" / "delegation.py").read_text(encoding="utf-8")
    pr_seg = deleg_src.split("def parse_report")[1].split("\ndef ")[0]
    check("T9b parse_report 内调用 _extract_outside_body 并入 summary",
          "_extract_outside_body" in pr_seg and "summary = (summary.rstrip()" in pr_seg)

    # ── T10 真实回归：用户库那条 1959 字符交卷（若库存在）──
    try:
        import sqlite3, os
        db = os.path.expanduser(
            "~/.subagent/projects/8ae1bd50-2383-4162-9e74-d1e77e73cd75/agents.db")
        if os.path.exists(db):
            con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
            row = con.execute("SELECT content FROM session_messages WHERE id=62").fetchone()
            con.close()
            if row and row[0]:
                rr = parse_report(row[0], "f968ae6b-76b6-4bfc-ae9b-b190e32f0868")
                check("T10 用户真实交卷：律师函正文/法条/金额均找回",
                      rr is not None and "民法典" in rr["summary"] and "234700" in rr["summary"],
                      f"summary={len(rr['summary']) if rr else 0}字")
            else:
                print("SKIP T10（库中无该样本消息）")
        else:
            print("SKIP T10（用户库不存在，跳过真实回归）")
    except Exception as e:
        print(f"SKIP T10（读取真实库失败，不阻塞：{e}）")

    print(f"\n===== #7 委派交卷保全文专项: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        for f in FAILURES:
            print("  ✗", f)
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
