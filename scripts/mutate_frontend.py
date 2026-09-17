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

    python3 scripts/mutate_frontend.py            # 跑全部变异档
    python3 scripts/mutate_frontend.py 1          # 只跑第 1 档
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
    # ── REQ-INFER-009（0.4.28）推理参数面板草稿模式 ─────────────────────
    {
        "id": 20,
        "name": "REQ-INFER-009 撤掉 blur 提交（改了不保存）",
        "why": "草稿模式的保存入口只有 blur 与 Enter 两条。撤掉 blur 提交后，用户改完点别处"
               "就丢修改——正是草稿模式要替代的旧体验之一。凡以 blur 收尾的用例都必须红。",
        "file": PANELS / "ModelOptionsEditor.tsx",
        "anchor": """                        onBlur={() => {
                          focusKeyRef.current = null;
                          void commitParam(name, def, val);
                        }}""",
        "mutant": """                        onBlur={() => {
                          focusKeyRef.current = null;
                          /* MUTATE-20：撤掉 blur 提交 */
                        }}""",
        "test": "src/__tests__/modelOptionsEditor.test.tsx",
        "expect_fail": ["编辑 num_ctx", "清空某项", "越界值", "D1", "D2"],
    },
    {
        "id": 21,
        "name": "REQ-INFER-009 提交时不校验（越界照存）",
        "why": "coerce 是注入前的最后一道闸：撤掉校验，越界值会直送 onSave → PUT /config，"
               "后端 _PARAM_RANGE 之外靠后端静默丢弃兜底 → 回到「设了不生效」的坑。"
               "越界值用例与 D2 的「不调用 onSave」必须红。",
        "file": PANELS / "ModelOptionsEditor.tsx",
        "anchor": "    if (!r.ok) { setErr(r.why); return; }          // ⛔ 草稿保留，不回弹（REQ-INFER-009）",
        "mutant": "    if (!r.ok) { /* MUTATE-21：越界照存 */ }",
        "test": "src/__tests__/modelOptionsEditor.test.tsx",
        "expect_fail": ["越界值", "D2"],
    },
    {
        "id": 22,
        "name": "REQ-INFER-009 校验失败时草稿回弹旧值（吞输入回归）",
        "why": "⛔ 新语义底线：非法值提示错误后**草稿必须保留**，用户接着改；回弹旧值就是"
               "REQ-INFER-009 原始缺陷的另一半（输入被吞）。D2/越界值用例的草稿保留断言必须红。",
        "file": PANELS / "ModelOptionsEditor.tsx",
        "anchor": "    if (!r.ok) { setErr(r.why); return; }          // ⛔ 草稿保留，不回弹（REQ-INFER-009）",
        "mutant": "    if (!r.ok) { setErr(r.why); setDrafts(d => ({ ...d, [fieldKey(model, def.key)]: valueToString(def, (mo[model] || {})[def.key]) })); return; }  // MUTATE-22：失败回弹旧值",
        "test": "src/__tests__/modelOptionsEditor.test.tsx",
        "expect_fail": ["越界值", "D2"],
    },
    {
        "id": 23,
        "name": "REQ-INFER-009 onChange 逐键提交（回到原始缺陷形态）",
        "why": "这就是 0.4.27 实测缺陷本身：onChange 直接校验提交 → num_ctx 第一个数字必越界"
               " → 逐键输入中间态报错/被拦。D1 的「未提交前不校验不保存」与"
               "「编辑 num_ctx / 清空某项 / D3」的「change 后不立即 onSave」断言必须红。",
        "file": PANELS / "ModelOptionsEditor.tsx",
        "anchor": "                        onChange={e => setDrafts(d => ({ ...d, [k]: e.target.value }))}",
        "mutant": "                        onChange={e => { setDrafts(d => ({ ...d, [k]: e.target.value })); void commitParam(name, def, e.target.value); /* MUTATE-23：逐键提交 */ }}",
        "test": "src/__tests__/modelOptionsEditor.test.tsx",
        "expect_fail": ["编辑 num_ctx", "清空某项", "D1", "D3"],
    },
    {
        "id": 24,
        "name": "REQ-INFER-009 撤掉 Enter 提交（键盘党丢保存入口）",
        "why": "Enter 是与 blur 并列的提交入口：表单习惯是回车即存。撤掉后按 Enter 毫无反应，"
               "只能靠移开焦点。D3（Enter 提交合法值）必须红。",
        "file": PANELS / "ModelOptionsEditor.tsx",
        "anchor": """                        onKeyDown={e => {
                          if (e.key !== 'Enter') return;
                          e.preventDefault();
                          void commitParam(name, def, val);
                        }} />""",
        "mutant": "                        onKeyDown={() => { /* MUTATE-24：撤掉 Enter 提交 */ }} />",
        "test": "src/__tests__/modelOptionsEditor.test.tsx",
        "expect_fail": ["D3"],
    },
    {
        "id": 25,
        "name": "REQ-INFER-009 撤掉草稿同步 effect（外部刷新不同步）",
        "why": "保存成功 / Agent 改配置后的重拉（A13）要把草稿同步回已存值，否则界面显示"
               "与持久化配置长期脱节。撤掉 effect 后外部刷新覆盖不了旧草稿，D4 必须红。",
        "file": PANELS / "ModelOptionsEditor.tsx",
        "anchor": """  React.useEffect(() => {
    setDrafts(prev => {
      const next: Record<string, string> = {};
      for (const name of Object.keys(mo)) {
        const params = mo[name] || {};
        for (const def of PARAMS) {
          const k = fieldKey(name, def.key);
          next[k] = (k === focusKeyRef.current && prev[k] !== undefined)
            ? prev[k]
            : valueToString(def, params[def.key]);
        }
      }
      return next;
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [cfg]);""",
        "mutant": "  // MUTATE-25：撤掉草稿同步 effect（外部刷新不再同步草稿）",
        "test": "src/__tests__/modelOptionsEditor.test.tsx",
        "expect_fail": ["D4"],
    },
    # ── REQ-AGT-020（0.4.28）ChatPanel 订阅 session 事件的三道过滤 + 重拉 ─────────
    {
        "id": 26,
        "name": "REQ-AGT-020 撤掉「仅当前打开的会话」过滤",
        "why": "事件总线是全局广播：每个委派中的子会话都在发 session 事件。不过滤 session_id "
               "会把别的委派子会话的 DB 内容重拉进用户当前打开的会话（串会话事故）。"
               "E3 的「其他会话事件 → 忽略」必须红。",
        "file": PANELS / "ChatPanel.tsx",
        "anchor": "      if (!sid || sid !== currentSessionIdRef.current) return;            // ② 仅当前打开的会话",
        "mutant": "      // MUTATE-26：撤掉「仅当前会话」过滤（任何会话的事件都重拉当前视图）",
        "test": "src/__tests__/chatPanelSessionEvents.test.tsx",
        "expect_fail": ["E3"],
    },
    {
        "id": 27,
        "name": "REQ-AGT-020 撤掉「流式中的会话绝不重拉」守卫",
        "why": "⛔ 计划明令底线：当前会话正在流式时重拉会以 DB 为准合并，冲掉进行中的"
               "乐观/流式气泡态（token 增量、工具步骤活态、计时器）。E2 必须红。",
        "file": PANELS / "ChatPanel.tsx",
        "anchor": "      if (activeStreamSidRef.current === sid) return;                     // ③ ⛔ 流式中的会话绝不重拉",
        "mutant": "      // MUTATE-27：撤掉流式守卫（流式中也重拉，冲掉流式气泡）",
        "test": "src/__tests__/chatPanelSessionEvents.test.tsx",
        "expect_fail": ["E2"],
    },
    {
        "id": 28,
        "name": "REQ-AGT-020 撤掉 resource/gap 过滤",
        "why": "总线广播全部资源变更（workflow/plugin/...）与 gap 对账事件。不按 resource 过滤，"
               "任何资源变更都会触发消息区重拉——无意义的全表请求风暴，且 gap 无 session_id "
               "无法定向。E3 的「非 session 资源（带 session_id）→ 忽略」必须红。",
        "file": PANELS / "ChatPanel.tsx",
        "anchor": "      if (ev.gap || ev.resource !== 'session') return;                    // ① 只处理 session 资源变更",
        "mutant": "      // MUTATE-28：撤掉 resource/gap 过滤（任何资源变更都重拉消息区）",
        "test": "src/__tests__/chatPanelSessionEvents.test.tsx",
        "expect_fail": ["E3"],
    },
    {
        "id": 29,
        "name": "REQ-AGT-020 撤掉重拉调用（订阅形同虚设）",
        "why": "这是本修复的核心动作：过滤通过后必须走既有 loadSessionMessages 重拉 DB 合并，"
               "否则子会话视图依旧不刷新（原始缺陷）。E1 的「新消息合并可见」必须红。",
        "file": PANELS / "ChatPanel.tsx",
        "anchor": "      void loadSessionMessages(sid);                                      // 走既有 DB 合并路径",
        "mutant": "      // MUTATE-29：撤掉重拉调用（收到事件但什么都不做）",
        "test": "src/__tests__/chatPanelSessionEvents.test.tsx",
        "expect_fail": ["E1"],
    },
    # ── 0.4.29 批 P1：模型包管理器面板 ─────────────────────────────────────
    {
        "id": 30,
        "name": "0.4.29 撤掉 download_progress 的字节进度更新（进度条恒 0%）",
        "why": "进度条的全部意义是让用户看到下载在走。若 received_bytes 不落进状态，"
               "进度条恒 0%、百分比恒 0——用户会以为下载卡死而反复取消重试。"
               "「驱动进度条」用例的 50% 宽度断言必须红。",
        "file": PANELS / "ModelPacksPanel.tsx",
        "anchor": """            [pid]: {
              received: Number(ev.received_bytes) || 0,
              total: Number(ev.total_bytes) || prev[pid]?.total || 0,
              file: ev.file ? String(ev.file) : prev[pid]?.file,
            },""",
        "mutant": """            [pid]: {
              received: 0, /* MUTATE-30：进度不更新，进度条恒 0% */
              total: Number(ev.total_bytes) || prev[pid]?.total || 0,
              file: ev.file ? String(ev.file) : prev[pid]?.file,
            },""",
        "test": "src/__tests__/modelPacksPanel.test.tsx",
        "expect_fail": ["驱动进度条"],
    },
    {
        "id": 31,
        "name": "0.4.29 撤掉安装前确认弹窗（不询问直接联网下载）",
        "why": "confirm_model_pack_download（默认开）是联网下载的告知闸：撤掉后点安装"
               "即静默联网，用户看不到包名/来源/大小，也失去境外来源切全量联网的入口——"
               "与 0.4.9 联网安装确认（任务152）同一事故哲学。三个确认流用例必须红。",
        "file": PANELS / "ModelPacksPanel.tsx",
        "anchor": "    const needConfirm = cfg?.confirm_model_pack_download !== false;   // 缺省视为开启",
        "mutant": "    const needConfirm = false; /* MUTATE-31：撤掉安装前确认（不弹窗直接装） */",
        "test": "src/__tests__/modelPacksPanel.test.tsx",
        "expect_fail": ["境外来源", "不发 install", "境内来源"],
    },
    # ── 0.4.29 批 P2：推理面板第三卡「模型包」─────────────────────────────
    {
        "id": 32,
        "name": "0.4.29 撤掉模型包后端第三卡（isMP 恒 false）",
        "why": "isMP 是模型包后端的全部 UI 分流依据：第三卡选中态、状态区标题、"
               "openai 地址表单的隐藏、「模型包面板管理」提示全挂在它上面。恒 false 后"
               "选了模型包的用户看到的是 OpenAI 兼容表单——后端已切换、前端却引导填地址，"
               "两头对不上。第三卡用例必须红。",
        "file": PANELS / "InferencePanel.tsx",
        "anchor": "  const isMP = backend === 'model_package';",
        "mutant": "  const isMP = false; /* MUTATE-32：撤掉模型包卡分流 */",
        "test": "src/__tests__/inferencePanel.test.tsx",
        "expect_fail": ["第三卡"],
    },
    # ── 0.4.29 批 P3：ASR 语音转写双场景（chatPanelAudio.test.tsx）─────────
    {
        "id": 33,
        "name": "0.4.29-P3 静默吞掉转写失败（catch 里不置 transcribeFailed）",
        "why": "转写失败若不置 transcribeFailed，暂存区 chip 永远停在「既非转写中也非失败」"
               "的空白态，重试按钮不出现——用户以为语音丢了且无任何补救入口。"
               "失败可见可重试是本批次底线，A3 必须红。",
        "file": PANELS / "ChatPanel.tsx",
        "anchor": """      setPendingItems(prev => prev.map(p => match(p)
        ? { ...p, transcribing: false, transcribeFailed: true,
            audioError: err instanceof Error ? err.message : String(err) } : p));""",
        "mutant": """      setPendingItems(prev => prev.map(p => match(p)
        ? { ...p, transcribing: false } : p));  /* MUTATE-33：静默吞掉转写失败 */""",
        "test": "src/__tests__/chatPanelAudio.test.tsx",
        "expect_fail": ["A3"],
    },
    {
        "id": 34,
        "name": "0.4.29-P3 撤掉语音附件的消息标记（parts 不推 [🎤]）",
        "why": "[🎤 文件名] 标记是用户消息气泡里语音附件的存在性证据——撤掉后气泡只剩"
               "用户原话，语音是否被发送无从辨认；且 agent 侧也少了定位锚。"
               "A2/A6 断言载荷含该标记，必须红。",
        "file": PANELS / "ChatPanel.tsx",
        "anchor": """    // 0.4.29（P3）：语音附件的消息标记（UI 文案允许 emoji）
    if (audioItems.length) parts.push(audioItems.map(f => `[🎤 ${f.name}]`).join(' '));""",
        "mutant": """    /* MUTATE-34：撤掉语音附件消息标记 */""",
        "test": "src/__tests__/chatPanelAudio.test.tsx",
        "expect_fail": ["A2", "A6"],
    },
    {
        "id": 35,
        "name": "0.4.29-P3 accept 去掉音频扩展名（入口不可达）",
        "why": "文件选择器 accept 不含音频扩展名时，macOS 文件对话框里音频文件直接灰掉"
               "——场景②（上传录音文件转文稿）入口级不可达。A1 逐一断言扩展名，必须红。",
        "file": PANELS / "ChatPanel.tsx",
        "anchor": '''accept="image/*,.txt,.md,.csv,.json,.js,.ts,.py,.html,.css,.yaml,.yml,.log,.ini,.pdf,.doc,.docx,.xlsx,.xlsm,.pptx,.wav,.mp3,.m4a,.aac,.aiff,.aif,.caf,.flac,.ogg,.opus,.webm"''',
        "mutant": '''accept="image/*,.txt,.md,.csv,.json,.js,.ts,.py,.html,.css,.yaml,.yml,.log,.ini,.pdf,.doc,.docx,.xlsx,.xlsm,.pptx" /* MUTATE-35：去掉音频扩展名 */''',
        "test": "src/__tests__/chatPanelAudio.test.tsx",
        "expect_fail": ["A1"],
    },
    # ── 0.4.30 批 W1/W3：麦克风权限链 + 静音检测 + ASR 守卫 ─────────────
    {
        "id": 36,
        "name": "0.4.30-W1 撤掉静音检测（全 0 PCM 直送转写）",
        "why": "静音检测是防「权限链断裂录出零流 → 模型幻听文本（0.4.29 实测\"그.\"）」"
               "的唯一闸门。撤掉后全 0 录音照常进转写链，用户再次收到幻听文稿且界面无提示。"
               "M1 的「标红 + 不发 transcribe」断言必须红。",
        "file": PANELS / "ChatPanel.tsx",
        "anchor": "      if (await wavPcm16Rms(wav) < SILENCE_RMS_THRESHOLD) item.silentAudio = true;",
        "mutant": "      /* MUTATE-36：撤掉静音检测（全 0 PCM 也进转写链） */",
        "test": "src/__tests__/chatPanelMicGuard.test.tsx",
        "expect_fail": ["M1"],
    },
    {
        "id": 37,
        "name": "0.4.30-W3 撤掉 ASR 可用性守卫（未安装也放行录音/上传）",
        "why": "未装 ASR 包时录音/上传音频必然转写失败，守卫的职责是事前弹窗引导安装/启用，"
               "而不是让用户白录一段再在暂存区撞失败。恒真后 S1（弹窗文案）与"
               "S4（上传拦截、不发 transcribe）必须红。",
        "file": PANELS / "ChatPanel.tsx",
        "anchor": """async function ensureAsrReady(): Promise<boolean> {
  const st = await fetchAsrStatus();
  if (!st || st.available !== false) return true;""",
        "mutant": """async function ensureAsrReady(): Promise<boolean> {
  return true; /* MUTATE-37：撤掉 ASR 可用性守卫（未安装也放行） */""",
        "test": "src/__tests__/chatPanelMicGuard.test.tsx",
        "expect_fail": ["S1", "S4"],
    },
    {
        "id": 38,
        "name": "0.4.30-W1 撤掉系统麦克风权限链（denied 也直接 getUserMedia）",
        "why": "macOS TCC 拒绝时直接 getUserMedia 拿到的是全零静音流——用户录完才发现没声。"
               "权限链的职责是 denied 给系统设置指引、not-determined 先触发系统弹窗。"
               "恒真后 P2（denied 指引弹窗、不调 getUserMedia）与 P4（拒绝后拦截）必须红。",
        "file": PANELS / "ChatPanel.tsx",
        "anchor": """async function ensureMicPermission(): Promise<boolean> {
  const bridge = (window as any).subagent;
  if (!bridge || typeof bridge.getMicPermissionStatus !== 'function') return true;""",
        "mutant": """async function ensureMicPermission(): Promise<boolean> {
  return true; /* MUTATE-38：撤掉系统麦克风权限链（denied 也直接 getUserMedia） */""",
        "test": "src/__tests__/chatPanelMicGuard.test.tsx",
        "expect_fail": ["P2", "P4"],
    },
    # ── 0.4.30 批 W2：推理面板并行化 ────────────────────────────────────
    {
        "id": 39,
        "name": "0.4.30-W2 选模型包连带切 inference_backend（排他语义回潮）",
        "why": "并行化的全部意义是选模型包只存 default_model=pack_id、不动 inference_backend"
               "（后端按 model 名自动路由）。连带切后端就退回 0.4.29 的排他语义——"
               "选个包就把用户的 Ollama/OpenAI 配置顶掉。L2 的「inference_backend 保持 ollama」必须红。",
        "file": PANELS / "InferencePanel.tsx",
        "anchor": "    await saveBackend({ default_model: m.name });",
        "mutant": "    await saveBackend({ default_model: m.name, inference_backend: m.source === 'model_pack' ? 'model_package' : cfg.inference_backend }); /* MUTATE-39：选包连带切后端（排他语义回潮） */",
        "test": "src/__tests__/inferencePanelParallel.test.tsx",
        "expect_fail": ["L2"],
    },
    {
        "id": 40,
        "name": "0.4.30-W2 撤掉模型包来源徽标（统一列表不可辨）",
        "why": "统一列表里模型包与后端模型同名共存，徽标是用户分辨「这个模型走模型包引擎"
               "（会换装）」的唯一视觉线索。撤掉后 L1 的「包行有徽标、普通行无徽标」必须红。",
        "file": PANELS / "InferencePanel.tsx",
        "anchor": "              {m.source === 'model_pack' && (",
        "mutant": "              {false && m.source === 'model_pack' && ( /* MUTATE-40：撤掉模型包来源徽标 */",
        "test": "src/__tests__/inferencePanelParallel.test.tsx",
        "expect_fail": ["L1"],
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
