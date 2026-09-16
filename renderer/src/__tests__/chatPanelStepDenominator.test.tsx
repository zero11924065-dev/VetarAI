/*
 * VetarAI - Local-first multi-agent orchestration application
 * Copyright (C) 2026 zero11924065-dev
 * GPL-3.0-or-later（见仓库 LICENSE）
 */
/**
 * REQ-MSG-021 + REQ-MSG-022（0.4.28 修复批，WS2）前端专项。
 *
 * ═══ REQ-MSG-021：步骤分母消除占位 5 ═══
 * 旧缺陷（用户 0.4.27 实测）：气泡一出现就显示「步骤 0/5」，而真实轮次上限是配置
 *   max_tool_rounds（缺省 200）——后端 state 事件（d.max）只在**轮末**回传
 *   （loop.py 轮末统一发），第一轮期间分母停在占位 5，第一条回复全程显示错误上限。
 * 修法（双保险，两机制同源同值）：
 *   ① 后端流启动后、第一轮开始前多发一个初始 state 事件（step=0、max=配置真值、
 *      tokens_used=0），见 app.py gen() while 之前；本文件 S1/S3 模拟该事件。
 *   ② 前端建气泡与两处兜底改读配置（maxToolRoundsRef，回落 200，⛔ 不许再写 5）；
 *      S2 孤立验证建气泡路径（流全程无 state 事件，分母只能来自建气泡）。
 * ⛔ 测试值故意用 42 而非 200：若代码把 200 也写死，用缺省值做断言会假绿，
 *   42 只能来自 mock 的 /config 或初始 state 事件，证明真的读了配置/事件。
 *
 * ═══ REQ-MSG-022：插入分裂后段2「已等待 Ns」横幅复活 ═══
 * 旧缺陷：waitTimer 的"首个正文 token 到达即停表"是**流级**一次性门闩
 *   （gotFirstContent 按流置 true）。segment_break 切出段2 新气泡后，门闩已闭、
 *   计时器已停 → 段2 waitingSeconds 恒 0 → 横幅判据（waitingSeconds>=8 且 content
 *   为空）对段2 永不成立，段2 长时间无正文时用户看不到任何等待提示。
 * 修法：等待计时按 **segment 复位**——segment_break 落地（streamMsgId 已重指向段2）
 *   后重新放开门闩并重起计时器，段2 从 0 起计。W1 用 fake timers 验证段2 ≥8s 横幅出现。
 * ⛔ 止血纪律（0.4.24）不在本文件重复断言：tick 的 persist:false 由
 *   chatPanelCacheWriteThrottle W1/W2/W3 专职守护（本改动保持该通道不变）。
 *
 * ═══ 变异测试记录（改源码→跑本文件→必须红→还原→绿）═══
 *   M1 建气泡 maxStep 写回 5        → S2 红（显示 步骤 0/5，等不到 0/42）✅ 已实测命中
 *   M2 初始 state 事件不发（模拟）   → S3 红（分母停 200，等不到 0/42）✅ 已实测命中
 *   M3 去掉 segment_break 的重起计时 → W1 红（段2 横幅永不出现）✅ 已实测命中
 *
 * 流式夹具沿用 chatPanelCacheWriteThrottle 的成熟模式：fake timers +
 * sseResSlow（首事件同步 enqueue、随后靠 gap 悬挂），不用 sseResControllable
 * （本项目 jsdom 时序坑，见 segmentBreakRealInject 头注释）。
 *
 * 运行：node node_modules/vitest/vitest.mjs run src/__tests__/chatPanelStepDenominator.test.tsx
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, waitFor, act } from '@testing-library/react';
import React from 'react';
import { ChatPanel } from '../panels/ChatPanel';

import { jsonRes, sseEvent, tokenEvent, sseResSlow } from './helpers/fetchMock';

if (typeof (globalThis as any).localStorage === 'undefined') {
  (globalThis as any).localStorage = {
    _d: {} as Record<string, string>,
    getItem(k: string) { return this._d[k] ?? null; },
    setItem(k: string, v: string) { this._d[k] = String(v); },
    removeItem(k: string) { delete this._d[k]; },
    clear() { this._d = {}; },
  };
}

beforeEach(() => { vi.restoreAllMocks(); localStorage.clear(); });
afterEach(() => { vi.useRealTimers(); });

/** 初始 state 事件（0.4.28 后端新增，payload 与 app.py gen() 一致） */
const initialStateEvent = (max: number) =>
  sseEvent('state', { step: 0, max, tokens_used: 0 });

const segBreak = (injected: string, breakAt: number) =>
  sseEvent('segment_break', {
    injected_messages: [{ role: 'user', content: injected }],
    break_at: breakAt,
  });

/**
 * @param cfgMax   非空则给 /config 路由返回 { max_tool_rounds: cfgMax }；
 *                 null 则不配 /config 路由（fallback jsonRes([]) → 前端回落 200）。
 */
function mountWithSlowStream(evs: string[], gapMs: number, cfgMax: number | null) {
  const impl: typeof fetch = async (url) => {
    const u = String(url);
    if (cfgMax !== null && u.includes('/config')) return jsonRes({ max_tool_rounds: cfgMax });
    if (u.includes('/agents/')) return jsonRes([{ id: 'a1', name: '行政主管', role: 'x' }]);
    if (u.includes('/ollama/models')) return jsonRes([{ name: 'qwen3.8' }]);
    if (u.includes('/sessions?')) return jsonRes([{ id: 's1', title: '会话 1', message_count: 1 }]);
    if (u.includes('/messages')) return jsonRes([]);
    if (u.includes('/ollama/chat/stream')) return sseResSlow(evs, gapMs);
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
function typeInto(el: HTMLTextAreaElement, text: string) {
  const setter = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value')!.set!;
  setter.call(el, text);
  el.dispatchEvent(new Event('input', { bubbles: true }));
}
/** 发消息开流（与 chatPanelCacheWriteThrottle.send 同一纪律：先 settle 会话链再发送）。 */
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
/** 从 DOM 提取「已等待 {N}s」；不存在返回 null。 */
function readWaiting(): number | null {
  const m = (document.body.textContent || '').match(/已等待\s*(\d+)\s*s/);
  return m ? Number(m[1]) : null;
}

describe('REQ-MSG-021 · 步骤分母自第一轮起显示真实上限（消除占位 5）', () => {
  it('S1 端到端口径：配置 42 + 初始 state 事件 → 气泡显示「步骤 0/42」（不再是 0/5）', async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    // 流在初始 state 事件后悬挂（gap 120s）：断言窗口内没有任何轮末 state，
    // 分母只能来自【建气泡读配置】与【初始 state 事件】这两条新路径。
    mountWithSlowStream([initialStateEvent(42)], 120000, 42);
    await send('第一个问题');
    await waitFor(() => expect(document.body.textContent).toContain('步骤 0/42'), { timeout: 3000 });
    expect(document.body.textContent || '').not.toContain('步骤 0/5');
  });

  it('S2 ⛔ 建气泡即读配置：流全程无 state 事件（只吐 thinking），分母仍是 42', async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    // 孤立验证建气泡路径：thinking 事件不触碰 step/maxStep（也不停等待计时器，H19），
    // 若建气泡写回 5（变异 M1）→ 永远等不到「步骤 0/42」→ 红。
    mountWithSlowStream([sseEvent('thinking', { delta: '嗯' })], 120000, 42);
    await send('第一个问题');
    await waitFor(() => expect(document.body.textContent).toContain('步骤 0/42'), { timeout: 3000 });
    expect(document.body.textContent || '').not.toContain('步骤 0/5');
  });

  it('S3 ⛔ 初始 state 事件路径：无配置路由（回落 200）时，事件 max=42 照样覆盖分母', async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    // 孤立验证事件路径：建气泡只能给回落值 200，「步骤 0/42」只能由初始 state 事件写入。
    // 若后端不发该事件（变异 M2，本测试以"流无首事件"模拟的对照形态）→ 停在 0/200 → 红。
    mountWithSlowStream([initialStateEvent(42)], 120000, null);
    await send('第一个问题');
    // 落地信号前置：事件未应用前分母是 200（建气泡回落值），两值不同 → 断言有区分度
    await waitFor(() => expect(document.body.textContent).toContain('步骤 0/42'), { timeout: 3000 });
    expect(document.body.textContent || '').not.toContain('步骤 0/5');
  });
});

describe('REQ-MSG-022 · segment_break 后段2 等待计时复位', () => {
  it('W1 ⛔ 段1 已出正文后分裂：段2 ≥8s 无正文 →「已等待 Ns」横幅在段2 复活（从 0 起计）', async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    const SEG1 = '段1正文';
    const INJECT = '改看B表';
    // 时间线：t0 段1 首 token（流级门闩闭合、旧实现从此停表）→ t0+120s segment_break
    //   → 段2 新气泡（content 为空）重新起计 → 再 ~8s 横幅必须出现。
    mountWithSlowStream([
      tokenEvent(SEG1),
      segBreak(INJECT, SEG1.length),
    ], 120000, null);
    await send('第一个问题');
    // 落地信号①：段1 正文已渲染（首 token 已到达，流级门闩已闭、旧实现从此停表）
    await waitFor(() => expect(document.body.textContent).toContain(SEG1), { timeout: 3000 });
    // ⛔ 一次性推进正好 120s（gap 锚定在流启动时刻）：segment_break 在本次推进的**末尾**
    //   才到达，段2 重起的计时器在本次推进内几乎不走字——后面 +8.5s 的读数才有判别力。
    //   （此前分两段 9s+120s=129s，gap 在 ~120s 处提前到达，尾巴白走 ~10 个 tick，
    //     探针实测 w 直接变 10，教训：sseResSlow 的 gap 从 start() 起算，不是从推进起算。）
    await act(async () => { await vi.advanceTimersByTimeAsync(120000); });
    for (let i = 0; i < 4; i++) await act(async () => { await vi.advanceTimersByTimeAsync(120); });
    // 分裂已渲染：注入用户气泡出现、段1 定格完好（分裂语义本体不动）
    expect(document.body.textContent).toContain(INJECT);
    expect(document.body.textContent).toContain(SEG1);
    // 从 0 起计的直接证据：此刻段2 的等待秒数尚未过阈值，横幅不可见
    expect(readWaiting()).toBeNull();
    // ⛔ 核心：段2 重新起计，~8s 后横幅出现（改前：门闩已闭、计时器已停，恒为 null → 红）
    await act(async () => { await vi.advanceTimersByTimeAsync(8500); });
    const w = readWaiting();
    expect(w).not.toBeNull();
    // 下界 8 = 横幅阈值；上界 12 容忍 act/shouldAdvanceTime 的真实耗时漂移（探针实测 8~10）
    expect(w!).toBeGreaterThanOrEqual(8);
    expect(w!).toBeLessThanOrEqual(12);
    expect(document.body.textContent).toContain('模型加载/推理中');
  }, 20000);
});
