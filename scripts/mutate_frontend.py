#!/usr/bin/env python3
"""前端变异测试驱动（0.4.20 新建；前端此前无任何变异机制先例）。

## 为什么需要这个脚本

后端各专项测试都内置了 `MUTATE=1|2|3` 环境变量入口（test_p4_doc_reader /
test_p15_delegation_stream / test_office_io / test_loop），一条命令即可复现
"故意破坏修复 → 确认测试真的会失败"。

前端做不到：vitest 是独立进程，无法在同一进程里"改写源文件 → 重载 → 跑用例 → 还原"。
所以 0.4.20 的 #1 与 #15 前端变异测试，我都是**手工打补丁 → 跑 → 手工还原**，
验证完什么都没留下。后果：下次会话想复核"S1~S7 / S1~S8 那些断言到底有没有用"，
只能重新发明一遍。本脚本把这套动作固化下来。

## 用法

    python3 scripts/mutate_frontend.py            # 跑全部 4 项变异
    python3 scripts/mutate_frontend.py 1          # 只跑第 1 项
    python3 scripts/mutate_frontend.py --list     # 只列清单不执行

## ⛔ 判定规则（与后端 MUTATE 一致）

**变异模式下必须出现 FAIL**。若某项变异跑出 0 FAIL，脚本会以非 0 退出并打印
「未被抓住」——那不是"测试通过"，是**断言空转**，需要加强断言。

本脚本 0.4.20 首建时即抓到过一处空转断言：#15 的 S4 原断言是
"console.error 里没有 unmounted 告警"，但 **React 18 已移除该告警** →
撤掉卸载守卫测试照样全绿。现改为锚定可观测行为（卸载后的 fetch 计数）。

## ⛔ 安全保证

- 源文件改写前**先读进内存**，`finally` 里无条件还原（含 Ctrl-C / 异常 / 断言失败）
- 锚点未命中一律 `assert` 报错退出，**绝不静默跳过**——否则"没抓到"可能只是
  "根本没注入成功"（0.4.18 的 B10/C8 变异2 就因多行字符串语法错误静默失败过）
- 跑完核对文件字节与备份一致，不一致则报错（防止把变异态留在工作区）
"""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
RENDERER = REPO / "renderer"
PANELS = RENDERER / "src" / "panels"

# vitest 需要 node 在 PATH 里（本机 node 装在 /opt/homebrew/bin）
_ENV = dict(os.environ)
if "/opt/homebrew/bin" not in _ENV.get("PATH", ""):
    _ENV["PATH"] = "/opt/homebrew/bin:" + _ENV.get("PATH", "")

# ── 变异清单：每项 = (编号, 说明, 目标文件, 原文锚点, 变异后文本, 对应测试文件, 期望失败的用例前缀) ──
#
# ⛔ 锚点必须带足够上下文以唯一定位：TaskPanel 里 `if (cancelled) return;` 出现**两次**
#   （applyEvent 内的守卫 与 连接成功后的 setStreamOn），只写这一句会命中错误位置。
MUTATIONS: list[dict] = [
    {
        "id": 1,
        "name": "#1 撤掉 done 按 break_at 切分段2",
        "why": "done 的 content 是【全文】（loop.py full_text 跨轮累加 = 段1+段2）。"
               "不按 break_at 切分，段2 气泡会重复显示段1 全部内容。",
        "file": PANELS / "ChatPanel.tsx",
        "anchor": "            content = (lastBreakAt >= 0) ? d.content.slice(lastBreakAt) : d.content;",
        "mutant": "            content = d.content;  // MUTATE-1",
        "test": "src/__tests__/chatPanelSegmentBreak.test.tsx",
        "expect_fail": ["S1", "S2", "S5", "S6"],
    },
    {
        "id": 2,
        "name": "#1 撤掉 streamMsgId 重指向",
        "why": "分裂后若不把 streamMsgId 指向新气泡，段2 的 token 仍写进已定格的段1。"
               "（闭包捕获的是变量绑定，故 const→let + 重新赋值即可生效。）",
        "file": PANELS / "ChatPanel.tsx",
        "anchor": "        streamMsgId = newId;                 // 重指向：后续事件写入新气泡",
        "mutant": "        void newId;  // MUTATE-2",
        "test": "src/__tests__/chatPanelSegmentBreak.test.tsx",
        "expect_fail": ["S1", "S2", "S5", "S6"],
    },
    {
        "id": 3,
        "name": "#15 撤掉 applyEvent 的卸载守卫",
        "why": "卸载后到达的 status=done / task_end 会触发 loadTasks → 一次卸载后的 fetch，"
               "并写已卸载组件的状态。⛔ 锚点含尾随注释以区分 TaskPanel 里另一处同名守卫。",
        "file": PANELS / "TaskPanel.tsx",
        "anchor": "      if (cancelled) return;                       // ⛔ 卸载后不再写任何状态",
        "mutant": "      // MUTATE-3：撤掉卸载守卫",
        "test": "src/__tests__/taskPanel.test.tsx",
        "expect_fail": ["S4"],
    },
    {
        "id": 4,
        "name": "#15 撤掉连接成功的 setStreamOn(true)",
        "why": "streamOn 驱动标题行的实时连接指示点（绿=已连 / 灰=需手动刷新）。"
               "撤掉后指示器恒为灰，用户无法分辨是'没进展'还是'没连上'。",
        "file": PANELS / "TaskPanel.tsx",
        "anchor": "        setStreamOn(true);",
        "mutant": "        // MUTATE-4：不标记已连接",
        "test": "src/__tests__/taskPanel.test.tsx",
        "expect_fail": ["S8"],
    },
]


def run_vitest(test_path: str) -> tuple[int, str]:
    """跑单个测试文件，返回 (退出码, 合并输出)。"""
    proc = subprocess.run(
        ["node", "node_modules/vitest/vitest.mjs", "run", test_path],
        cwd=str(RENDERER), env=_ENV, capture_output=True, text=True, timeout=600,
    )
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")


def strip_ansi(s: str) -> str:
    import re
    return re.sub(r"\x1b\[[0-9;]*m", "", s)


def apply_one(m: dict) -> bool:
    """执行一项变异。返回 True = 变异被抓住（符合预期）。"""
    path: Path = m["file"]
    original = path.read_text(encoding="utf-8")

    print(f"\n{'='*74}")
    print(f"变异 {m['id']}：{m['name']}")
    print(f"  目标：{path.relative_to(REPO)}")
    print(f"  原理：{m['why']}")

    # ⛔ 锚点必须唯一命中。0 次 = 源码已变（锚点失效）；>1 次 = 会误改多处。
    #   两种情况都必须报错退出，绝不能"差不多就改"——静默改错位置会得出假结论。
    hits = original.count(m["anchor"])
    if hits == 0:
        print(f"  ⛔ 锚点未命中（0 处）——源码已变或锚点写错，本项**无效**，不作结论")
        print(f"     锚点：{m['anchor'][:90]}")
        return False
    if hits > 1:
        print(f"  ⛔ 锚点命中 {hits} 处（不唯一）——会误改多处，请先加上下文使其唯一")
        return False

    try:
        path.write_text(original.replace(m["anchor"], m["mutant"], 1), encoding="utf-8")
        print(f"  ✅ 已注入（锚点唯一命中 1 处）")

        rc, out = run_vitest(m["test"])
        out = strip_ansi(out)

        failed_lines = [ln.strip() for ln in out.split("\n")
                        if ("×" in ln or "FAIL " in ln) and ln.strip()]
        summary = next((ln.strip() for ln in out.split("\n")
                        if "Tests " in ln and ("passed" in ln or "failed" in ln)), "")
        print(f"  测试：{m['test']}")
        print(f"  结果：退出码 {rc} ｜ {summary}")

        caught = rc != 0
        if caught:
            print(f"  ✅ **变异被抓住**（测试如预期失败）")
            for ln in failed_lines[:8]:
                print(f"     {ln[:150]}")
            # 交叉核对：期望失败的用例是否真的在失败列表里
            missing = [c for c in m["expect_fail"]
                       if not any(c in ln for ln in failed_lines)]
            if missing:
                print(f"  ⚠️ 期望失败的用例未出现在失败列表：{missing}")
                print(f"     （可能是整体崩在更早的断言上，或用例名变了——需人工确认）")
        else:
            print(f"  ⛔⛔ **变异未被抓住** —— 对应断言是空转的，必须加强！")
            print(f"     期望失败：{m['expect_fail']}")
        return caught
    finally:
        # ⛔ 无条件还原（含 Ctrl-C / 超时 / 异常）：把变异态留在工作区
        #   等于把产品代码改坏，且后续所有测试都会基于错误代码跑。
        path.write_text(original, encoding="utf-8")
        now = path.read_text(encoding="utf-8")
        if now != original:
            print(f"  ⛔⛔ 还原校验失败：{path.name} 与备份不一致，请立刻手工检查！")
        else:
            print(f"  ✅ 已还原并校验字节一致")


def main() -> int:
    args = sys.argv[1:]

    if "--list" in args:
        print("前端变异清单：")
        for m in MUTATIONS:
            print(f"  {m['id']}. {m['name']}")
            print(f"     → {m['test']}  期望失败：{'/'.join(m['expect_fail'])}")
        return 0

    selected = MUTATIONS
    if args:
        try:
            ids = {int(a) for a in args}
        except ValueError:
            print(f"⛔ 参数须是变异编号（1~{len(MUTATIONS)}）或 --list")
            return 2
        selected = [m for m in MUTATIONS if m["id"] in ids]
        if not selected:
            print(f"⛔ 没有编号为 {sorted(ids)} 的变异")
            return 2

    print("=" * 74)
    print("前端变异测试（0.4.20 新建）")
    print("⛔ 判定规则：变异模式下**必须**有测试失败。0 FAIL = 断言空转，不是通过。")
    print("=" * 74)

    results = []
    try:
        for m in selected:
            results.append((m["id"], m["name"], apply_one(m)))
    finally:
        # 兜底：即使中途异常，也确认所有目标文件都无变异残留
        print(f"\n{'='*74}")
        print("收尾核查：工作区是否有变异残留")
        leftover = []
        for m in MUTATIONS:
            txt = m["file"].read_text(encoding="utf-8")
            if "MUTATE-" in txt:
                leftover.append(m["file"].name)
        if leftover:
            print(f"  ⛔⛔ 以下文件仍有变异残留，请立刻还原：{leftover}")
        else:
            print("  ✅ 无变异残留")

    print(f"\n{'='*74}")
    caught = sum(1 for _, _, ok in results if ok)
    print(f"汇总：{caught}/{len(results)} 项变异被抓住")
    for mid, name, ok in results:
        print(f"  {'✅' if ok else '⛔'} 变异 {mid}：{name}")
    if leftover:
        print("⛔ 存在变异残留，退出码 2")
        return 2
    if caught != len(results):
        print("⛔ 有变异未被抓住 —— 对应断言空转，必须加强后再交付")
        return 1
    print("✅ 全部变异被抓住：这些断言确实绑定了修复，不是空转的")
    print("=" * 74)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
