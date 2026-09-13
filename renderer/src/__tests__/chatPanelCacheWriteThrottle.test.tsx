/*
 * VetarAI - Local-first multi-agent orchestration application
 * Copyright (C) 2026 zero11924065-dev
 * GPL-3.0-or-later（见仓库 LICENSE）
 */
/**
 * 止血（0.4.24，checkpoint-111）：计时器 tick 不得触发会话缓存全量重写。
 *
 * ═══ 真凶（2026-09-13 用户真机复测 + 我实测坐实，详见 39 号执行计划 第一节）═══
 * 0.4.23 的 F2/F4 真机**无感**（D 场景 fps 3.7→3.8、setState/秒 4.9→4.7）。重新归因后坐实真凶：
 *   `syncSessionLocal`（useMessages.ts）每次调用都 `JSON.parse` 47MB → 改一个字段 →
 *   `JSON.stringify` 47MB → `localStorage.setItem` 写回，**全同步阻塞主线程**。
 * 四个独立数字收敛到同一答案：
 *   · longTaskTotalMs ÷ uptime = 18473÷23s = **803ms/秒**主线程被长任务占满
 *   · longTaskCount ÷ uptime = 52÷23s = **2.26 次/秒**
 *   · 单次 longTaskMaxMs = **439ms**
 *   · M6 切会话（同样一次 47MB 缓存操作，上轮独立实测）= **406ms**
 *   → 2 次/秒 × ~400ms = 800ms/秒 ✅ 吻合。
 * 而"每秒 2 次"的来源正是**两个计时器**：流级计时器（写 runElapsed/thinkingElapsed）
 * 与等待计时器（写 waitingSeconds），各自每秒 patchStreamMsg 一次 → 各自引发一次缓存调度。
 *
 * ═══ 止血方案 ═══
 * 这三个字段**本就是瞬态显示值、不落库**（DB 表 session_messages 的 INSERT 列清单不含它们，
 * 已核实 store.py:736），缓存里存它们毫无意义：刷新后流已结束、计时器不会复活。
 * → 计时器改走**不落盘**的 patch 通道（patchStreamMsg 第二参 { persist:false }），
 *   只 setState、不调 scheduleStreamCacheSync。
 *
 * ═══ ⛔ 测试策略（0.4.23 的血泪教训，别改回去）═══
 * 1. **指标＝localStorage.setItem 的调用次数**，⛔ 不是 DOM 表现。
 *    0.4.23 的 F2/F4 测试全绿（235 passed、变异 3/3 命中）却真机无感——因为 DOM 改前改后都正确，
 *    **只断言 DOM 永远测不出性能回归**。本文件直接 spy setItem 数调用次数。
 * 2. ⛔ **Node 基准不能给浏览器 API 成本定论**：我曾用 Node 测 47MB parse+stringify+writeFileSync
 *    得 33.8ms，据此判"只占 7% 一个核、非主犯"——**这正是 36 号文档那个错误结论的来源**。
 *    Chromium 的 localStorage 是 SQLite 同步落盘 + UTF-16→UTF-8 转换，真机 M6 实测 406ms。
 *    故本文件断言**次数**（确定性、不依赖机器快慢），不断言耗时。
 * 3. ⛔ 必须同时守护"计时数字仍在跳"——止血不能把计时器搞坏（B12 语义底线）。
 * 4. ⛔ 必须防**过度修复**：正文 token 到达时缓存仍要落盘（W3），否则刷新会丢消息。
 *
 * 运行：node node_modules/vitest/vitest.mjs run src/__tests__/chatPanelCacheWriteThrottle.test.tsx
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, waitFor, act } from '@testing-library/react';
import React from 'react';
import { ChatPanel } from '../panels/ChatPanel';
import { jsonRes, sseRes, sseResSlow, tokenEvent, doneEvent, sseEvent } from './helpers/fetchMock';
import { readChatPanelSource } from './helpers/chatSource';

const CACHE_KEY = 'subagent_messages_v4';

let setItemSpy: ReturnType<typeof vi.spyOn>;

/** 安装 spy 并清零：只统计"测量区间"内的缓存写入，排除启动期的噪声。 */
function startCounting() {
  if (setItemSpy) setItemSpy.mockRestore();
  setItemSpy = vi.spyOn(localStorage, 'setItem');
  return {
    /** 缓存键的写入次数 */
    cacheWrites: () => setItemSpy.mock.calls.filter((c: unknown[]) => c[0] === CACHE_KEY).length,
    reset: () => setItemSpy.mockClear(),
  };
}

beforeEach(() => { vi.restoreAllMocks(); localStorage.clear(); });
afterEach(() => { if (setItemSpy) setItemSpy.mockRestore(); vi.useRealTimers(); });

/**
 * ⛔ 用 sseResSlow 造"流保持打开但静默"的中间态（纪律：不用 sseResControllable，踩过三次坑）。
 * sseResSlow 的 async start 会**同步 enqueue 第一个事件**，然后 await gapMs —— 在 fake timers 下
 * 该 await 不推进就不 resolve，于是流既不 close 也不再吐事件，正是"只有计时器在跑"的纯净场景。
 * gapMs 给 120s，远超测试需要。
 */
function mountWithSilentStream(firstEvents: string[]) {
  const impl: typeof fetch = async (url) => {
    const u = String(url);
    if (u.includes('/agents/')) return jsonRes([{ id: 'a1', name: '行政主管', role: 'x' }]);
    if (u.includes('/ollama/models')) return jsonRes([{ name: 'qwen3.8' }]);
    if (u.includes('/sessions?')) return jsonRes([{ id: 's1', title: '会话 1', message_count: 1 }]);
    if (u.includes('/messages')) return jsonRes([]);
    if (u.includes('/ollama/chat/stream')) return sseResSlow(firstEvents, 120000);
    return jsonRes([]);
  };
  vi.spyOn(globalThis, 'fetch').mockImplementation(impl);
  return render(<ChatPanel projectId="p1" agentId="a1" />);
}

function getTextarea(): HTMLTextAreaElement {
  const el = document.querySelector('textarea');
  if (!el) throw new Error('未找到输入框 textarea');
  return el as HTMLTextAreaElement;
}

/** 原生 setter 派发 input（React 受控组件必须这样，fireEvent.change 不可靠）。 */
function typeInto(el: HTMLTextAreaElement, text: string) {
  const setter = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value')!.set!;
  setter.call(el, text);
  el.dispatchEvent(new Event('input', { bubbles: true }));
}

/**
 * 发消息开流。⛔ 冷启动 settle 用 advanceTimersByTimeAsync（不用 waitFor——后者靠真实时间轮询，
 * 与假时钟语义不同）：让 sessions/messages 的 fetch 链 settle、currentSessionId 就位，
 * 否则 handleSend 会走"新建会话"分支、不建流（B12 测试 R1 连续 7 轮失败的真因，别再踩）。
 */
async function send(text: string) {
  await waitFor(() => expect(getTextarea()).toBeTruthy(), { timeout: 3000 });
  for (let i = 0; i < 8; i++) await act(async () => { await vi.advanceTimersByTimeAsync(120); });
  await act(async () => {
    typeInto(getTextarea(), text);
    getTextarea().dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
  });
  await waitFor(() => expect(document.body.textContent).toContain(text), { timeout: 3000 });
  for (let i = 0; i < 4; i++) await act(async () => { await vi.advanceTimersByTimeAsync(120); });
}

/** 从 DOM 提取「进行中 {N}s」；不存在返回 null。 */
function readRunElapsed(): number | null {
  const m = (document.body.textContent || '').match(/进行中\s*(\d+)\s*s/);
  return m ? Number(m[1]) : null;
}

/** 从 DOM 提取「已等待 {N}s」；不存在返回 null。 */
function readWaiting(): number | null {
  const m = (document.body.textContent || '').match(/已等待\s*(\d+)\s*s/);
  return m ? Number(m[1]) : null;
}

describe('止血 · 计时器 tick 不得触发缓存全量重写', () => {
  it('W1 ⛔ 流级计时器每秒 tick，但不得写缓存（改前每秒 1 次 47MB 重写）', async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    // 首个 token 到达 → stopWaitTimer，此后只有流级计时器在跑（纯净场景）
    mountWithSilentStream([tokenEvent('正文')]);
    await send('开始干活');

    // 落地信号：正文已渲染 + 计时器已在跳
    await waitFor(() => expect(document.body.textContent).toContain('正文'), { timeout: 3000 });
    await act(async () => { await vi.advanceTimersByTimeAsync(1500); });
    expect(readRunElapsed()).not.toBeNull();

    const c = startCounting();
    // ⛔ 核心：推进 5 秒（流级计时器 tick 5 次），期间**无任何 SSE 事件**
    await act(async () => { await vi.advanceTimersByTimeAsync(5000); });

    // 改前：每次 tick → patchStreamMsg → scheduleStreamCacheSync → elapsed>=500 立即 doSync
    //       → 每秒 1 次 setItem(47MB) ≈ 5 次 → 红。
    // 改后：计时器走不落盘通道 → **0 次**。
    expect(c.cacheWrites()).toBe(0);

    // ⛔ 止血不得把计时器搞坏：数字必须仍在跳（B12 语义底线）
    const t0 = readRunElapsed();
    await act(async () => { await vi.advanceTimersByTimeAsync(3000); });
    const t1 = readRunElapsed();
    expect(t0).not.toBeNull();
    expect(t1).not.toBeNull();
    expect(t1!).toBeGreaterThan(t0!);
    // 且这 3 秒同样不得写缓存
    expect(c.cacheWrites()).toBe(0);
  });

  it('W2 ⛔ 等待计时器每秒 tick，但不得写缓存', async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    // ⛔ 只推 state 事件（非 token）→ gotFirstContent 仍为 false → waitTimer 持续每秒 tick
    mountWithSilentStream([sseEvent('state', { step: 1, max: 5, tokens_used: 100 })]);
    await send('等模型思考');

    const c = startCounting();
    // 推进 10 秒：等待计时器 tick 10 次（横幅判据是 waitingSeconds>=8，需要真累过阈值）
    await act(async () => { await vi.advanceTimersByTimeAsync(10000); });

    // 改前：10 次 tick → 10 次缓存调度 → 约 10 次 setItem → 红；改后 0 次
    expect(c.cacheWrites()).toBe(0);

    // ⛔ 等待横幅仍要正常显示且数字在累加（H19 语义：度量"等首条正文"）
    const w = readWaiting();
    expect(w).not.toBeNull();
    expect(w!).toBeGreaterThanOrEqual(8);
  });

  it('W3 ⛔ 防过度修复：patchStreamMsg/flushAcc 内仍保留缓存调度（默认落盘语义未被动过）', async () => {
    // ⛔ 本用例是**纯源码契约**，不做运行时计数。
    //   理由：① 时序敏感的行为断言在本项目已多次踩坑（0.4.23 F4 首轮假绿、本文件 W3 三轮时序错误）；
    //         ② "流式写穿仍在"的语义已被 B12 R3/R5/R7/R8 + chatPanelStream/segmentBreak 系列覆盖，
    //            若我过度修复删掉写穿，那些测试会先红；
    //         ③ 源码契约直接钉死"过度修复的形态"——只要这两个函数里还有 scheduleStreamCacheSync，
    //            正文/工具步骤/收尾的写穿就在，计时器只是显式选择不走它。
    const src = await readChatPanelSource();
    expect(src.length).toBeGreaterThan(10000);

    const patchIdx = src.indexOf('const patchStreamMsg');
    expect(patchIdx).toBeGreaterThan(0);
    expect(src.slice(patchIdx, patchIdx + 800)).toContain('scheduleStreamCacheSync');

    const flushIdx = src.indexOf('const flushAcc');
    expect(flushIdx).toBeGreaterThan(0);
    expect(src.slice(flushIdx, flushIdx + 1200)).toContain('scheduleStreamCacheSync');
  });
});
