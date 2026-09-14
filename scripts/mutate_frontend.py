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
        "anchor": "      if (cancelled) return;                       // 卸载后不再写任何状态",
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
        "anchor": "      onConnect: () => setStreamOn(true),",
        "mutant": "      onConnect: () => {},  // MUTATE-4：不标记已连接",
        "test": "src/__tests__/taskPanel.test.tsx",
        "expect_fail": ["S8"],
    },
    # ── B12（0.4.21）整轮进行计时 ──────────────────────────────────────────
    {
        "id": 5,
        "name": "B12 撤掉 runElapsed 每秒更新（核心功能）",
        "why": "runElapsed 是 B12 的全部意义——思考结束后任务仍进行时，界面靠它显示跳动的"
               "「进行中 Ns」。撤掉更新则它恒为 undefined，渲染判据 runElapsed!=null 不成立，"
               "用户回到「时间不跳」的原始缺陷。",
        "file": PANELS / "ChatPanel.tsx",
        "anchor": "          runElapsed: mm.startedAt ? Math.round((now - mm.startedAt) / 1000) : mm.runElapsed,",
        "mutant": "          runElapsed: mm.runElapsed,  // MUTATE-5：不更新整轮进行计时",
        "test": "src/__tests__/chatPanelB12RunElapsed.test.tsx",
        "expect_fail": ["R1", "R3", "R7"],
    },
    {
        "id": 6,
        "name": "B12 让定格的「思考 Ns」继续跳（语义谎报）",
        "why": "⛔ B12 语义底线：思考结束后 thinkingDuration 必须定格（思考确实结束了，再跳＝谎报，"
               "且会击穿 C6「正常完成/手动停止/异常中断」三态区分）。本变异在流级计时器里额外更新"
               "thinkingDuration，模拟「手滑把定格值也接进每秒跳动」的错误实现。",
        "file": PANELS / "ChatPanel.tsx",
        "anchor": """          thinkingElapsed: (mm.thinking && thinkingStartedAt)
            ? Math.round((now - thinkingStartedAt) / 1000) : mm.thinkingElapsed,""",
        "mutant": """          thinkingElapsed: (mm.thinking && thinkingStartedAt)
            ? Math.round((now - thinkingStartedAt) / 1000) : mm.thinkingElapsed,
          thinkingDuration: thinkingStartedAt ? Math.round((now - thinkingStartedAt) / 1000) : mm.thinkingDuration,  // MUTATE-6：谎报，定格值也跳""",
        "test": "src/__tests__/chatPanelB12RunElapsed.test.tsx",
        "expect_fail": ["R2"],
    },
    {
        "id": 7,
        "name": "B12 撤掉卸载 cleanup 的计时器清理",
        "why": "⛔ 卸载 cleanup 不 abort 流 → handleSend 的 finally 不执行；若这里不清计时器，"
               "卸载后它每秒空转（幽灵计时器）。R8 同时用运行时 clearInterval 计数 + 源码契约断言守护。",
        "file": PANELS / "ChatPanel.tsx",
        "anchor": """      // B12（0.4.21）：卸载 cleanup **不 abort 流**，所以 handleSend 的 finally 不会执行
      //   → 流级计时器必须在这里也清一次，否则卸载后它每秒空转（无害但白耗）。
      if (runElapsedTimerRef.current) { clearInterval(runElapsedTimerRef.current); runElapsedTimerRef.current = null; }""",
        "mutant": "      // MUTATE-7：撤掉卸载 cleanup 的计时器清理",
        "test": "src/__tests__/chatPanelB12RunElapsed.test.tsx",
        "expect_fail": ["R8", "finally"],
    },
    {
        "id": 8,
        "name": "B12 撤掉 finally 的计时器清理",
        "why": "finally 是流的正常结束出口（done/error/abort/重连耗尽都经此）。撤掉清理则流结束后"
               "计时器仍空转。由源码契约断言守护（运行时 R3 因 isStreamingThis 已转 false 不渲染，"
               "故本变异主要靠源码契约那条 it 抓住）。",
        "file": PANELS / "ChatPanel.tsx",
        "anchor": """      // B12（0.4.21）：流结束（done/error/abort/重连耗尽都经此出口）→ 清流级计时器，
      //   runElapsed 停止跳动，界面改由 completedDuration 的「完成 Ns」接管。
      if (runElapsedTimerRef.current) { clearInterval(runElapsedTimerRef.current); runElapsedTimerRef.current = null; }""",
        "mutant": "      // MUTATE-8：撤掉 finally 的计时器清理",
        "test": "src/__tests__/chatPanelB12RunElapsed.test.tsx",
        "expect_fail": ["finally"],
    },
    # ── F2（0.4.23 安全区）StreamingMarkdown memo 化 ───────────────────────
    {
        "id": 9,
        "name": "F2 撤掉 StreamingMarkdown 的 React.memo",
        "why": "真机数据（36 号测量卡 5.7）坐实：流式/思考期每个 SSE 事件都 setLocalMessages → "
               "重渲染整个消息列表（93~95 条），每条 assistant 都重新走 ReactMarkdown 完整解析，"
               "而其中 94 条 text 一个字没变 → 重解析是 Electron 渲染进程烧满一核（~103%）的主成本。"
               "撤掉 memo 即回到「每帧重解析全部 Markdown」的原始缺陷。"
               "⛔ 变异手法：把 React.memo(...) 换成 identity 包裹（`(f => f)(...)`），"
               "这样只改一处锚点、结尾 `});` 不动即语法仍正确，语义上等价于「没有 memo」。",
        "file": PANELS / "ChatPanel.tsx",
        "anchor": "export const StreamingMarkdown = React.memo(function StreamingMarkdown({ text }: { text: string }) {",
        "mutant": "export const StreamingMarkdown = ((f: any) => f)(function StreamingMarkdown({ text }: { text: string }) {  // MUTATE-9：撤掉 memo",
        "test": "src/__tests__/streamingMarkdownMemo.test.tsx",
        "expect_fail": ["M2"],
    },
    # ── F4（0.4.23 安全区）thinking delta 按帧合并节流 ──────────────────────
    {
        "id": 10,
        "name": "F4 撤掉 thinking 节流，回到「每 delta 一次 patchStreamMsg」",
        "why": "真机数据（36 号测量卡 5.7）：D 场景（思考圆圈，fps 3.7 / longtask 78%）的元凶是 "
               "thinking 分支每个 delta 都单独 patchStreamMsg → 每次都重渲染整个消息列表（93~95 条）。"
               "F4 把思考增量累积进 accThinking、与正文共用同一次 rAF 提交。本变异把 thinking 分支"
               "改回「每 delta 直接 patch」的旧形态，同时命中运行时断言 T1（提交数飙升）与源码契约"
               "（oldForm 正则重新匹配）。",
        "file": PANELS / "ChatPanel.tsx",
        "anchor": """        if (delta) {
          accThinking += delta;
          if (!rafId) rafId = requestAnimationFrame(flushAcc);
        }""",
        "mutant": """        if (delta) {
          patchStreamMsg(m => ({ ...m, thinkingPreview: ((m.thinkingPreview || '') + delta).slice(-120) }));  // MUTATE-10：每 delta 一次提交
        }""",
        "test": "src/__tests__/chatPanelF4ThinkingThrottle.test.tsx",
        "expect_fail": ["T1", "thinking 分支"],
    },
    {
        "id": 11,
        "name": "F4 漏清 accThinking（分裂路径不清空 → 跨段串味）",
        "why": "F4 要求每条终结路径都清 accThinking（与 accContent 同生同灭）。插入点分裂路径若漏清，"
               "段1 挂起的思考缓冲会在 streamMsgId 重指向段2 后、被后续帧 flush 写进段2 气泡（跨段串味）。"
               "本变异删掉分裂路径的 accThinking 清空，命中源码契约「清零次数不得少于 accContent」那条。",
        "file": PANELS / "ChatPanel.tsx",
        "anchor": """        //   段1 定格时显式置 thinkingPreview: undefined；而 streamMsgId 下面会重指向段2 →
        //   若不清空，挂起的帧 flush 会把**段1 的思考预览写进段2 气泡**（跨段串味）。
        accThinking = '';
        const frozenId = streamMsgId;       // 定格前捕获旧 id（updater 闭包用）""",
        "mutant": """        // MUTATE-11：漏清 accThinking
        const frozenId = streamMsgId;       // 定格前捕获旧 id（updater 闭包用）""",
        "test": "src/__tests__/chatPanelF4ThinkingThrottle.test.tsx",
        "expect_fail": ["每条终结路径"],
    },
    # ── 止血（0.4.24）计时器 tick 不得触发 47MB 缓存全量重写 ───────────────
    {
        "id": 12,
        "name": "止血 撤掉 persist 短路（机制层）",
        "why": "真凶＝syncSessionLocal 每次对 47MB 缓存做 parse+stringify+setItem 全同步阻塞（真机单次约 400ms）；"
               "两个计时器每秒各 patch 一次 → 每秒 2 次重写 → 主线程被占 803ms/秒（探针实测）。"
               "止血＝patchStreamMsg 新增 persist 选项，计时器传 false 跳过缓存调度。"
               "本变异删掉短路判断 → 两个计时器恢复每秒各写一次 47MB → W1+W2 都红。",
        "file": PANELS / "ChatPanel.tsx",
        "anchor": "      if (opts?.persist === false) return;   // 瞬态字段：只更新内存态，不写缓存",
        "mutant": "      // MUTATE-12：撤掉 persist 短路，计时器 tick 恢复触发缓存全量重写",
        "test": "src/__tests__/chatPanelCacheWriteThrottle.test.tsx",
        "expect_fail": ["W1", "W2"],
    },
    {
        "id": 13,
        "name": "止血 撤掉流级计时器的 persist:false（调用点）",
        "why": "流级计时器每秒写 runElapsed/thinkingElapsed（均为瞬态显示值、DB 无对应列）。"
               "撤掉 persist:false → 每秒 1 次 47MB 重写回来 → W1 红。",
        "file": PANELS / "ChatPanel.tsx",
        "anchor": """        }), { persist: false });
      }, 1000);
    };""",
        "mutant": """        }));  // MUTATE-13：流级计时器恢复落盘
      }, 1000);
    };""",
        "test": "src/__tests__/chatPanelCacheWriteThrottle.test.tsx",
        "expect_fail": ["W1"],
    },
    {
        "id": 14,
        "name": "止血 撤掉等待计时器的 persist:false（调用点）",
        "why": "等待计时器每秒写 waitingSeconds（瞬态；横幅判据 >=8）。撤掉 persist:false → 每秒 1 次 47MB 重写回来 → W2 红。"
               "⛔ W2 实测改前是 20 次/10 秒（＝每秒 2 次），因为 state 事件不触发 stopWaitTimer，"
               "两个计时器同时在跑——这正是真机探针 2.26 次/秒的代码级来源。",
        "file": PANELS / "ChatPanel.tsx",
        "anchor": "          patchStreamMsg(m => ({ ...m, waitingSeconds: (m.waitingSeconds || 0) + 1 }), { persist: false });",
        "mutant": "          patchStreamMsg(m => ({ ...m, waitingSeconds: (m.waitingSeconds || 0) + 1 }));  // MUTATE-14",
        "test": "src/__tests__/chatPanelCacheWriteThrottle.test.tsx",
        "expect_fail": ["W2"],
    },
    # ── F6（0.4.24）图片 base64 移出会话缓存 ──────────────────────────────
    {
        "id": 15,
        "name": "F6 撤掉 syncSessionLocal 的图片剥离（写出口层）",
        "why": "真凶＝会话缓存 47MB（图片 base64 占 95.3%），syncSessionLocal 每次写入都 parse+stringify"
               " 整个 store 全同步阻塞主线程（真机单次约 400ms → 803ms/秒）。撤掉剥离 → 47MB 回来 → P1/P2/P4 红。",
        "file": RENDERER / "src" / "hooks" / "useMessages.ts",
        "anchor": """    store[sessionId] = stripMsgImages(messages);
    localStorage.setItem(key, JSON.stringify(stripStoreImages(store)));""",
        "mutant": """    store[sessionId] = messages;  // MUTATE-15：撤掉剥离
    localStorage.setItem(key, JSON.stringify(store));""",
        "test": "src/__tests__/chatPanelF6ImageCache.test.tsx",
        "expect_fail": ["P1", "P2", "P4", "P5"],
    },
    {
        "id": 16,
        "name": "F6 只剥当前会话（漏掉整 store 迁移 = F6 无效）",
        "why": "⛔ 计划 2.0 节的关键约束：syncSessionLocal parse 的是整个 store，只剥当前会话时"
               "其他会话的 45MB 仍在 → parse/stringify 照样约 400ms → F6 完全无效。P2 专门测这个。",
        "file": RENDERER / "src" / "hooks" / "useMessages.ts",
        "anchor": "    localStorage.setItem(key, JSON.stringify(stripStoreImages(store)));",
        "mutant": "    localStorage.setItem(key, JSON.stringify(store));  // MUTATE-16：只剥当前会话",
        "test": "src/__tests__/chatPanelF6ImageCache.test.tsx",
        # ⛔ P5 源码契约不该列入：本变异只删调用点，`stripMsgImages` 仍在 syncSessionLocal 内，
        #   故 P5 的正则仍命中（P5 绿是正确的）。真正守护"整 store 迁移"的是 P2。
        "expect_fail": ["P2"],
    },
    {
        "id": 17,
        "name": "F6 撤掉 persist() 的剥离（另一个写出口漏网）",
        "why": "persist() 是 addMessage/clear/loadFromAPI/purge 共用的写出口。只改 syncSessionLocal"
               "会让这条路径把 45MB base64 原样写回。P3 专门测 addMessage 路径。",
        "file": RENDERER / "src" / "hooks" / "useMessages.ts",
        "anchor": "function persist() { localStorage.setItem(STORAGE_KEY, JSON.stringify(stripStoreImages(_store))); }",
        "mutant": "function persist() { localStorage.setItem(STORAGE_KEY, JSON.stringify(_store)); }  // MUTATE-17",
        "test": "src/__tests__/chatPanelF6ImageCache.test.tsx",
        "expect_fail": ["P3", "P5"],
    },
    {
        "id": 18,
        "name": "F6 改成原地修改传入数组（界面图片会当场消失）",
        "why": "⛔ syncSessionLocal 收的是 React state 里的消息对象；原地 `m.images=undefined` 会让"
               "**界面上正在显示的图片当场消失**（比重写慢更糟）。P1 专门守护传入数组不被改。",
        "file": RENDERER / "src" / "hooks" / "useMessages.ts",
        "anchor": """    if (!hasHeavyImg && !hasHeavyPending) return m;      // 原样返回引用，不造新对象
    changed = true;
    const next: Message = { ...m };""",
        "mutant": """    if (!hasHeavyImg && !hasHeavyPending) return m;
    changed = true;
    if (hasHeavyImg) m.images = keepLight(m.images!);            // MUTATE-18：原地修改
    if (hasHeavyPending) delete (m as any).pending_images;
    const next: Message = m;""",
        "test": "src/__tests__/chatPanelF6ImageCache.test.tsx",
        "expect_fail": ["P1"],
    },
    # ── 0.4.27 更多菜单遮挡根治：portal + fixed 锚定 ─────────────────────
    {
        "id": 19,
        "name": "0.4.27 把更多菜单从 fixed 锚定改回顶栏内 absolute（遮挡回归）",
        "why": "顶栏 overflow:hidden（0.4.0 为治原生 select 溢出所加）会把 absolute 菜单裁成约 6px "
               "细条——用户实测看不到也无法点击。修复 = portal 到 body + fixed 锚定按钮矩形。"
               "本变异把 fixed 改回 absolute（原缺陷形态），M1 的 fixed 断言必须红。",
        "file": PANELS / "ChatPanel.tsx",
        "anchor": "position:'fixed', top:moreMenuPos.top, right:moreMenuPos.right, zIndex:1201",
        "mutant": "position:'absolute', top:34, right:0, zIndex:1201 /* MUTATE-19：改回顶栏内 absolute */",
        "test": "src/__tests__/chatMoreMenuPortal.test.tsx",
        "expect_fail": ["M1"],
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
