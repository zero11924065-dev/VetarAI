/*
 * VetarAI - Local-first multi-agent orchestration application
 * Copyright (C) 2026 zero11924065-dev
 * GPL-3.0-or-later（见仓库 LICENSE）
 */
/**
 * F6（0.4.24，checkpoint-111）：图片 base64 移出 localStorage 会话缓存。
 *
 * ═══ 治什么（真机实测坐实，详见 `39-…执行计划.md` 第一节）═══
 * 会话缓存 `subagent_messages_v4` 实测 **47185498 字节，其中图片 base64 44973802 = 95.3%**（124 张）。
 * `syncSessionLocal` 每次写入都对整个 store 做 `JSON.parse` → 改一个字段 → `JSON.stringify` →
 * `setItem`，**全同步阻塞主线程**，真机单次约 **400ms**（M6 切会话独立实测 406ms、
 * 探针 longTaskMaxMs 439ms 互证）→ 主线程被占 803ms/秒（探针 longTaskTotalMs÷uptime）。
 * 止血（计时器不落盘）只治了"写入次数"，F6 治"单次写入成本"：47MB → 约 2MB。
 *
 * ═══ 为什么剥离是安全的（四个卡点已逐个代码核实，见计划 2.1 节）═══
 * · DB 才是权威源：`session_messages.images TEXT`（store.py:77），user 消息图片在
 *   `app.py:1134` 落库，**早于** `return StreamingResponse`(:1481) → 流开始前 DB 已有图，无窗口期。
 * · 恢复有保障：`mergeDbWithLocal` 返回 `[...dbMsgs, ...extra]`（ChatPanel.tsx:665），
 *   DB 消息是基底 → 缓存无图时 DB 的 images 自动补回。
 *
 * ═══ ⛔ 测试策略（0.4.23 的血泪教训）═══
 * 1. **指标＝写入 localStorage 的字节数**，⛔ 不是 DOM 表现。0.4.23 的 F2/F4 测试全绿
 *    （235 passed、变异 3/3）却真机毫无改善——因为 DOM 改前改后都正确，
 *    **只断言 DOM 永远测不出性能回归**。
 * 2. ⛔ **必须守护"不得原地修改传入数组"**：`syncSessionLocal(sid, messages)` 收的是 React state
 *    里的消息对象。若剥离时直接 `m.images = undefined`，**内存态的图片会跟着消失** →
 *    界面上正在显示的图片当场不见（比重写慢更糟）。P1 专门测这个。
 * 3. ⛔ **必须守护"整 store 迁移"**（计划 2.0 节的关键约束）：`syncSessionLocal` 每次 parse
 *    的是**整个 store**，若只剥离"当前会话"的图片，其他会话的 45MB 仍在 → parse/stringify
 *    照样慢，**F6 完全无效**。P2 专门测这个。
 * 4. ⛔ Node 基准不能给浏览器 API 成本定论（我曾据此误判"仅占 7%、非主犯"）→ 断言字节数与
 *    调用次数这类确定性事实，不断言耗时。
 *
 * 运行：node node_modules/vitest/vitest.mjs run src/__tests__/chatPanelF6ImageCache.test.tsx
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, waitFor, act } from '@testing-library/react';
import React from 'react';
import { syncSessionLocal, useSessionMessages } from '../hooks/useMessages';
import { ChatPanel } from '../panels/ChatPanel';
import { jsonRes } from './helpers/fetchMock';

const CACHE_KEY = 'subagent_messages_v4';

/** 单张图约 363KB base64（真机实测 44973802 ÷ 124 ≈ 362692） */
const PER_IMG = 362692;
function makeDataUri(): string { return 'data:image/png;base64,' + 'A'.repeat(PER_IMG); }

/** 造 n 条含图消息（与真机形态一致：user 消息带 images） */
function imgMsgs(n: number, sidPrefix = 'm'): any[] {
  return Array.from({ length: n }, (_, i) => ({
    id: i + 1, role: 'user', content: `正文内容 ${sidPrefix}${i}`,
    images: [makeDataUri()],
  }));
}

/** 读缓存原始字符串（未做解析，直接量字节） */
function rawCache(): string { return localStorage.getItem(CACHE_KEY) || ''; }

beforeEach(() => { vi.restoreAllMocks(); localStorage.clear(); });
afterEach(() => { vi.useRealTimers(); });

describe('F6 · 图片 base64 移出会话缓存', () => {
  it('P1 ⛔ 含图消息写缓存后字节数暴跌，且**不得原地修改传入数组**', () => {
    const msgs = imgMsgs(20);                    // 20 张图 ≈ 7.3MB
    const beforeBytes = JSON.stringify({ s1: msgs }).length;
    // ⛔ 关键：记下传入对象的引用与图片，改完必须原样还在（原地修改会让界面图片当场消失）
    const firstImg = msgs[0].images![0];

    syncSessionLocal('s1', msgs as any);

    const afterBytes = rawCache().length;
    // 改前：缓存约等于 beforeBytes（7.3MB）→ 红；改后：图片已剥离 → 只剩正文，应 <5%
    expect(afterBytes).toBeLessThan(beforeBytes * 0.05);
    // ⛔ 剥离不得误删正文与消息条数
    const parsed = JSON.parse(rawCache());
    expect(parsed.s1).toHaveLength(20);
    expect(parsed.s1[0].content).toBe('正文内容 m0');
    expect(parsed.s1[19].content).toBe('正文内容 m19');
    // ⛔⛔ 不得原地修改传入数组（内存态必须仍持有完整图片，否则界面图片消失）
    expect(msgs[0].images).toBeDefined();
    expect(msgs[0].images![0]).toBe(firstImg);
    expect(msgs[0].images![0].length).toBeGreaterThan(1000);
  });

  it('P2 ⛔ 整 store 迁移：写会话 A 时，**其他会话**的存量图片也必须一并剥离', () => {
    // 模拟老用户（含用户本人）：缓存里已有另一个会话的 45MB 存量 base64
    localStorage.setItem(CACHE_KEY, JSON.stringify({
      oldSession: imgMsgs(120),   // ≈ 43.5MB，正是真机量级
    }));
    expect(rawCache().length).toBeGreaterThan(40_000_000);

    // 只写一个**不含图**的新会话
    syncSessionLocal('newSession', [{ id: 1, role: 'user', content: '你好' }] as any);

    const after = rawCache().length;
    // ⛔ 改前：oldSession 的 43.5MB 原样留着 → after 仍 >40MB → 红。
    //   这正是计划 2.0 节的关键约束：只剥离当前会话 = F6 完全无效。
    expect(after).toBeLessThan(1_000_000);
    // 但其他会话的**消息与正文**必须完好（只剥图片，不得删消息）
    const parsed = JSON.parse(rawCache());
    expect(parsed.oldSession).toHaveLength(120);
    expect(parsed.oldSession[0].content).toBe('正文内容 m0');
    expect(parsed.newSession[0].content).toBe('你好');
  });

  it('P3 ⛔ 另一个写出口 persist() 同样剥离（addMessage 路径）', () => {
    function Probe() {
      const h = useSessionMessages('sX');
      (Probe as any).hook = h;
      return null;
    }
    render(<Probe />);
    const hook = (Probe as any).hook;
    hook.addMessage({ id: 1, role: 'user', content: '带图', images: [makeDataUri()] } as any);

    const raw = rawCache();
    // 改前：base64 整块进缓存（≈363KB）→ 红；改后：只剩正文
    expect(raw.length).toBeLessThan(2000);
    const parsed = JSON.parse(raw);
    expect(parsed.sX[0].content).toBe('带图');
  });

  it('P4 ⛔ 集成：图片从 DB 恢复 —— 界面显示图片，但缓存里不含 base64', async () => {
    // DB（权威源）返回带图消息：1px PNG 的真实 dataUri（小，够验证"图能显示"）
    const TINY = 'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7';
    const impl: typeof fetch = async (url) => {
      const u = String(url);
      if (u.includes('/agents/')) return jsonRes([{ id: 'a1', name: '行政主管', role: 'x' }]);
      if (u.includes('/ollama/models')) return jsonRes([{ name: 'qwen3.8' }]);
      if (u.includes('/sessions?')) return jsonRes([{ id: 's1', title: '会话 1', message_count: 2 }]);
      if (u.includes('/messages')) return jsonRes([
        { id: 1, role: 'user', content: '看看这张图', images: [TINY], created_at: '2026-09-13T10:00:00Z' },
        { id: 2, role: 'assistant', content: '图里是一只猫', created_at: '2026-09-13T10:00:05Z' },
      ]);
      return jsonRes([]);
    };
    vi.spyOn(globalThis, 'fetch').mockImplementation(impl);
    render(<ChatPanel projectId="p1" agentId="a1" />);

    // 落地信号：历史消息已渲染
    await waitFor(() => expect(document.body.textContent).toContain('图里是一只猫'), { timeout: 3000 });

    // ⛔ 图片必须真的显示出来（DB → 内存态 → <img src>）
    const imgs = Array.from(document.querySelectorAll('img')).filter(
      el => (el.getAttribute('src') || '').startsWith('data:image/'),
    );
    expect(imgs.length).toBeGreaterThan(0);

    // ⛔ 而缓存里不得含任何 base64 图片（loadSessionMessages 会 syncSessionLocal 回写）
    await act(async () => { await new Promise(r => setTimeout(r, 200)); });
    const raw = rawCache();
    expect(raw.length).toBeGreaterThan(0);          // 缓存确有写入（不是没走到这条路）
    expect(raw).not.toContain('data:image/');        // ⛔ 核心断言：base64 已剥离
    // 正文仍在（剥离只针对图片字段）
    expect(raw).toContain('看看这张图');
    expect(raw).toContain('图里是一只猫');
  });

  it('P5 ⛔ 源码契约：两个写出口都经同一个剥离函数，且只动图片字段', async () => {
    const src = await import('../hooks/useMessages?raw').then(m => (m as any).default as string);
    expect(src.length).toBeGreaterThan(1000);

    // ① 剥离函数存在且被 persist 与 syncSessionLocal 共用（⛔ 只改一处 = 另一个出口漏网）
    expect(/strip\w*Image\w*\(/.test(src)).toBe(true);
    const persistIdx = src.indexOf('function persist()');
    expect(persistIdx).toBeGreaterThan(0);
    expect(/strip\w*Image\w*\(/.test(src.slice(persistIdx, persistIdx + 200))).toBe(true);
    const syncIdx = src.indexOf('export function syncSessionLocal');
    expect(syncIdx).toBeGreaterThan(0);
    expect(/strip\w*Image\w*\(/.test(src.slice(syncIdx, syncIdx + 600))).toBe(true);

    // ② 剥离必须同时覆盖两个图片字段（pending_images=本地流式附着图、images=DB 落库图）
    expect(src).toContain('pending_images');
    expect(/images/.test(src)).toBe(true);
  });
});
