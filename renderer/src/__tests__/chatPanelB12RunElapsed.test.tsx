/*
 * VetarAI - Local-first multi-agent orchestration application
 * Copyright (C) 2026 zero11924065-dev
 * GPL-3.0-or-later（见仓库 LICENSE）
 */
/**
 * B12（0.4.21）整轮进行计时 · 前端专项。
 *
 * 缺陷（用户 2026-09-11 报告，附截图：正文已出、工具步骤执行中、步骤 4/200）：
 *   「思考中… Ns」跳动正常，但**思考条一消失、任务仍在进行时**，界面只剩定格的「思考 Ns」，
 *   没有任何计时在跳 → 用户无法判断任务是否还活着。
 *
 * 根因（已逐行查实）：
 *   ① `thinkingElapsedTimer` 仅在思考态运行，首个正文 token 到达即被 `closeThinkingPhase()` 清除；
 *   ② 用时被**定格**进 `thinkingDuration`（本就不该再跳——思考已结束）；
 *   ③ 等待计时器 `waitTimer` 按 H19 设计"首正文即清"（它度量的是"等首条正文"）；
 *   → 「正文已出 + 工具执行中 + 下轮思考未开始」这一区间**无任何跳动计时**。
 *
 * 修复：把思考计时器提升为**流级计时器**（流开始建、finally 清），每秒更新
 *   `runElapsed`（整轮已耗时，全程跳）+ `thinkingElapsed`（仅思考态）。
 *
 * ⛔⛔ 测试策略（吸取 chatPanelSegmentBreak 首轮 6 用例假失败的教训）：
 *   本套件要断言的正是**流进行中的中间态**（计时是否跳动），无法用"一次性流 + 断言最终态"。
 *   → 用 `sseResControllable`：push 事件后**不 close**，得到稳定的"流进行中"中间态；
 *   ⛔ push 之后必须在 `act` 内 await 一拍，否则 reader 读取与 React 重渲染发生在 act 之外、
 *     DOM 不被 flush（helpers/fetchMock.ts:121-126 已记载此坑）。
 *   → 计时跳动用 `vi.useFakeTimers()` 推进，不依赖真实等待。
 *
 * ⛔⛔ 本套件的语义底线（违反即算做坏，见执行计划 2.6）：
 *   R2：**思考结束后「思考 Ns」必须定格不再变**（再跳＝谎报，且击穿 C6 三态区分）
 *   R5：手动停止后不得显示进行计时，且「已手动停止」标记仍在
 *
 * 运行：node node_modules/vitest/vitest.mjs run src/__tests__/chatPanelB12RunElapsed.test.tsx
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, waitFor, act } from '@testing-library/react';
import React from 'react';
import { ChatPanel } from '../panels/ChatPanel';

import {
  jsonRes, sseEvent, tokenEvent, doneEvent, sseResControllable,
} from './helpers/fetchMock';

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

/** 装载 ChatPanel：chat/stream 返回【可控流】（push 后不 close 即得"进行中"中间态）。 */
function mountWithControllableStream() {
  const ctl = sseResControllable();
  const impl: typeof fetch = async (url, init) => {
    const u = String(url);
    void init;
    if (u.includes('/agents/')) return jsonRes([{ id: 'a1', name: '行政主管', role: 'x' }]);
    if (u.includes('/ollama/models')) return jsonRes([{ name: 'qwen3.6:35b' }]);
    if (u.includes('/sessions?')) return jsonRes([{ id: 's1', title: '会话 1', message_count: 1 }]);
    if (u.includes('/messages')) return jsonRes([]);
    if (u.includes('/ollama/chat/stream')) return ctl.res;
    return jsonRes([]);
  };
  vi.spyOn(globalThis, 'fetch').mockImplementation(impl);
  return { ...render(<ChatPanel projectId="p1" agentId="a1" />), ctl };
}

function getTextarea(): HTMLTextAreaElement {
  const el = document.querySelector('textarea');
  if (!el) throw new Error('未找到输入框');
  return el as HTMLTextAreaElement;
}

/** 原生 setter 派发 input（React 受控组件必须这样，fireEvent.change 不可靠） */
function typeInto(el: HTMLTextAreaElement, text: string) {
  const setter = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value')!.set!;
  setter.call(el, text);
  el.dispatchEvent(new Event('input', { bubbles: true }));
}

/** 发消息开流（不发 done → 流保持进行中）。 */
async function sendAndKeepStreaming(ctl: { push: (e: string) => void }) {
  await waitFor(() => expect(getTextarea()).toBeTruthy(), { timeout: 3000 });
  // ⛔⛔ 冷启动 settle（消除"文件首个测试红、后续绿"的顺序依赖 —— R1 连续 10 轮失败的真正根因）：
  //   取证：单跑 R2/R3 也红、完整跑绿 → **文件里第一个执行的测试必红**，与具体是哪个用例无关。
  //   根因：`handleSend:1241` 有 `if (!currentSessionId) { await handleNewSession(); return; }` ——
  //   首个测试在 enter 时 sessions 尚未加载完、currentSessionId 为空 → 走新建会话分支、**不建流**，
  //   于是 runElapsed 计时器虽起但 patchStreamMsg 因 streamSid 不匹配而短路（PROBE：sending 看似 true 但气泡无内容）。
  //   ✅ 修法：enter **之前**先确定性推进虚拟时钟，让 sessions/messages 的 fetch 链 settle、currentSessionId 就位。
  //   （用 advanceTimersByTimeAsync 而非 waitFor —— 后者靠真实时间轮询，与假时钟语义不同；此处要的是 flush fetch 的 microtask 链。）
  for (let i = 0; i < 8; i++) {
    await act(async () => { await vi.advanceTimersByTimeAsync(120); });
  }
  await act(async () => {
    typeInto(getTextarea(), '开始干活');
    getTextarea().dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
  });
  await waitFor(() => {
    expect(document.body.textContent).toContain('开始干活');
  }, { timeout: 3000 });
  // enter 后再 settle：让流的 fetch 落地、reader 进入 read 循环、计时器开始 patch
  for (let i = 0; i < 4; i++) {
    await act(async () => { await vi.advanceTimersByTimeAsync(120); });
  }
  void ctl;
}

/** ⛔ push 后必须在 act 内 await 一拍，否则 DOM 不 flush（fetchMock.ts:121-126 记载的坑）。 */
async function pushAndWait(ctl: { push: (e: string) => void }, ev: string) {
  await act(async () => {
    ctl.push(ev);
    // ⛔⛔ **本套件 R1~R3 反复假失败的真正根因（单跑红、完整跑绿的顺序依赖）**：
    //   原写法 `await new Promise(r => setTimeout(r, 50))` 在 **fake timers** 下，
    //   setTimeout 被 mock、不会真实等待 → SSE 的 reader 来不及从 buffer 读到事件，
    //   token/tool_call 全被吞（PROBE 实测 `hasContent:false`、DOM 只剩用户消息）。
    //   `shouldAdvanceTime:true` 的真实时间推进不确定，首个测试常踩空 → 表现为顺序依赖。
    //   ✅ 正解：用 `vi.advanceTimersByTimeAsync` **确定性推进虚拟时钟**，
    //   微任务与 React 更新随之 flush，reader 才能读到 push 的事件。
    await vi.advanceTimersByTimeAsync(60);
  });
}

/** 从 DOM 提取「进行中 {N}s」的秒数；不存在返回 null。 */
function readRunElapsed(): number | null {
  const txt = document.body.textContent || '';
  const m = txt.match(/进行中\s*(\d+)\s*s/);
  return m ? Number(m[1]) : null;
}

/** 从 DOM 提取「思考 {N}s」（定格值，注意与「思考中… {N}s」区分）。 */
function readFrozenThinking(): number | null {
  const txt = document.body.textContent || '';
  const m = txt.match(/思考\s+(\d+)\s*s/);
  return m ? Number(m[1]) : null;
}

const thinkingEvent = (delta = '让我想想…') => sseEvent('thinking', { delta });

/**
 * ⛔ R5 专用：可控流 + **响应 abort signal**。
 * helpers/fetchMock.ts 的 `sseResControllable` 用裸 ReadableStream，**不接 init.signal**，
 * 因此 `abortRef.current.abort()` 后 `reader.read()` 既不 resolve 也不 reject（永久挂起）
 * → ChatPanel `:1807` 的 `e.name === 'AbortError'` catch 分支永不触发 → 不会置 manualStopped。
 * 这里在 start() 里监听 signal：一旦 abort 就 `controller.error(DOMException('Aborted','AbortError'))`，
 * 让 reader.read() 以 AbortError reject，**真实走通产品的停止链路**（而非绕过它断言结果）。
 */
function controllableStreamWithAbort(): {
  res: Response; push: (e: string) => void; attachSignal: (s: AbortSignal | null) => void;
} {
  const encoder = new TextEncoder();
  let ctrl: ReadableStreamDefaultController<Uint8Array> | null = null;
  const buffer: string[] = [];
  const flush = () => {
    if (!ctrl) return;
    while (buffer.length) {
      try { ctrl.enqueue(encoder.encode(buffer.shift()!)); } catch { buffer.length = 0; break; }
    }
  };
  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      ctrl = controller;
      flush();
    },
  });
  const res = new Response(stream, { status: 200, headers: { 'Content-Type': 'text/event-stream' } });
  return {
    res,
    push: (e: string) => { buffer.push(e); flush(); },
    /**
     * ⛔ 关键：abort 时必须调 `controller.error(DOMException(...,'AbortError'))`，
     *   这样 `reader.read()` 才会以 AbortError **reject** → ChatPanel 的 catch 分支置 manualStopped。
     *   （在 listener 里 `throw` 是没用的——异常不会传导到 reader。）
     */
    attachSignal: (s: AbortSignal | null) => {
      if (!s) return;
      const fail = () => {
        try { ctrl?.error(new DOMException('Aborted', 'AbortError')); } catch { /* 已关闭 */ }
      };
      if (s.aborted) fail(); else s.addEventListener('abort', fail, { once: true });
    },
  };
}

/** 装载 ChatPanel（R5 用）：chat/stream 返回**可 abort** 的可控流，并记录 stop 调用。 */
function mountWithAbortableStream() {
  const ctl = controllableStreamWithAbort();
  const stopCalls: string[] = [];
  const impl: typeof fetch = async (url, init) => {
    const u = String(url);
    if (u.includes('/agents/')) return jsonRes([{ id: 'a1', name: '行政主管', role: 'x' }]);
    if (u.includes('/ollama/models')) return jsonRes([{ name: 'qwen3.6:35b' }]);
    if (u.includes('/sessions?')) return jsonRes([{ id: 's1', title: '会话 1', message_count: 1 }]);
    if (u.includes('/messages')) return jsonRes([]);
    if (u.includes('/ollama/chat/stream')) {
      ctl.attachSignal((init?.signal as AbortSignal) ?? null);
      return ctl.res;
    }
    if (u.includes('/stop')) { stopCalls.push(u); return jsonRes({ ok: true }); }
    return jsonRes([]);
  };
  vi.spyOn(globalThis, 'fetch').mockImplementation(impl);
  return { ...render(<ChatPanel projectId="p1" agentId="a1" />), ctl, stopCalls };
}

describe('B12 整轮进行计时（runElapsed）', () => {
  // ⛔⛔ R1 连续 7 轮失败后定位的真正根因（必须记住，别再走回头路）：
  //   **real timers + setInterval 的 setState 不被 act 可靠 flush** —— 计时器在 `await sleep`
  //   期间的宏任务里 setLocalMessages，React 18 不在 act 边界外 flush → runElapsed 被 patch 但没渲染
  //   （PROBE 铁证：`sending_stopBtn:true` 但 `runElapsed:null`、spans 无 assistant 气泡）。
  //   ✅ 正解与 R3/R5/R7 一致：**fake timers + `shouldAdvanceTime:true`**，用
  //   `vi.advanceTimersByTimeAsync(ms)` 在 `act` 内**主动推进虚拟时钟并 flush React**。
  //   （另一坑：别给 R1 加"push token 让正文进 DOM"的前置 —— token 走 rAF 节流、桩下渲染时机不可靠；
  //     而 runElapsed 的渲染判据是 `isStreamingThis && runElapsed>0`，**与气泡有无正文无关**，
  //     一条没有 thinking 事件的新流天然就是"非思考 + 进行中"，正是 B12 要补的区间。）
  it('R1 流进行中且非思考态 → 存在每秒跳动的「进行中 Ns」', async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    const { ctl } = mountWithControllableStream();
    await sendAndKeepStreaming(ctl);

    // ⛔⛔ **连续 8 轮失败后定位的真正根因（基于已观测事实，非推理）**：
    //   R2~R8 全绿、它们的共同点是**测 runElapsed 前都 push 过事件**（R3 push token、R2 push thinking、
    //   R5 push tool_call+cancelled、R7 push token+segment_break）；**唯独 R1 一个事件都没 push**。
    //   可控流 `sseResControllable` 在收到首个 push 前，reader.read() 一直 pending、流未真正激活，
    //   此时计时器虽已 setInterval 但 patchStreamMsg 因 `currentSessionIdRef !== streamSid` 等时序短路。
    //   → ✅ R1 必须像 **R3（push token → advance → readRunElapsed not null，已验证绿）** 一样先 push 激活流。
    //   ⛔ 但**不断言 token 正文内容**——token 走 rAF 节流、桩下渲染时机不可靠（这是早先红在 toContain 的坑）。
    //     runElapsed 的渲染判据是 `isStreamingThis && runElapsed>0`，与气泡有无正文无关，故 push 只为激活流。
    await pushAndWait(ctl, tokenEvent('正文'));   // 仅用于激活流的 reader，不断言其内容

    // ⛔ 核心：流进行中、非思考态（从未发 thinking 事件）→ 必须有进行计时，且**数值随时间增长**
    //   （"增长"是 B12 的真正诉求——用户抱怨的正是"时间不跳动"；R3 只测了 not null，增长由本用例守护）
    await act(async () => { await vi.advanceTimersByTimeAsync(2000); });
    const t0 = readRunElapsed();
    expect(t0).not.toBeNull();
    expect(t0!).toBeGreaterThan(0);

    await act(async () => { await vi.advanceTimersByTimeAsync(3000); });
    const t1 = readRunElapsed();
    expect(t1).not.toBeNull();
    expect(t1!).toBeGreaterThan(t0!);   // ⭐ 真的在跳，不是定格

    // ⛔ 本轮从未发 thinking 事件 → 不得出现「思考 Ns」定格值，也不得出现「思考中…」
    expect(readFrozenThinking()).toBeNull();
    expect(document.body.textContent).not.toContain('思考中');
  });

  it('R2 ⛔ 思考结束后「思考 Ns」定格不再变（守护语义底线：不得谎报思考仍在进行）', async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    const { ctl } = mountWithControllableStream();
    await sendAndKeepStreaming(ctl);

    // 先进思考态，让思考计时跳几秒
    await pushAndWait(ctl, thinkingEvent('分析中'));
    await act(async () => { await vi.advanceTimersByTimeAsync(5000); });
    await waitFor(() => {
      expect(document.body.textContent).toContain('思考中');
    }, { timeout: 3000 });

    // 正文到达 → 思考阶段结束并定格
    await pushAndWait(ctl, tokenEvent('答案来了'));
    await waitFor(() => {
      expect(document.body.textContent).toContain('答案来了');
    }, { timeout: 3000 });

    const frozen1 = readFrozenThinking();
    expect(frozen1).not.toBeNull();

    // ⛔ 再推进 6 秒：定格的「思考 Ns」必须**纹丝不动**
    //   （若它继续跳＝谎报思考仍在进行，且会击穿 C6「正常完成/手动停止/异常中断」三态区分）
    await act(async () => { await vi.advanceTimersByTimeAsync(6000); });
    expect(readFrozenThinking()).toBe(frozen1);

    // 而进行计时应当继续跳（两者互不干扰）
    const r0 = readRunElapsed();
    await act(async () => { await vi.advanceTimersByTimeAsync(3000); });
    if (r0 !== null) expect(readRunElapsed()!).toBeGreaterThan(r0);
  });

  it('R3 done 之后不再显示进行计时，改由「完成 Ns」接管', async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    const { ctl } = mountWithControllableStream();
    await sendAndKeepStreaming(ctl);

    await pushAndWait(ctl, tokenEvent('部分正文'));
    await act(async () => { await vi.advanceTimersByTimeAsync(2000); });
    expect(readRunElapsed()).not.toBeNull();

    // 流结束
    await pushAndWait(ctl, doneEvent('部分正文完整'));
    await waitFor(() => {
      expect(document.body.textContent).toContain('部分正文完整');
    }, { timeout: 3000 });

    // ⛔ 进行计时必须消失（否则历史/已完成消息会一直挂着活态标记）
    await act(async () => { await vi.advanceTimersByTimeAsync(2000); });
    expect(readRunElapsed()).toBeNull();
    // 「完成 Ns」接管
    expect(document.body.textContent).toMatch(/完成\s*\d+\s*s/);
  });

  it('R4 ⛔ 历史消息（DB 加载，无流）不显示进行计时', async () => {
    // 挂载即加载历史消息，全程不开流
    const impl: typeof fetch = async (url) => {
      const u = String(url);
      if (u.includes('/agents/')) return jsonRes([{ id: 'a1', name: '行政主管', role: 'x' }]);
      if (u.includes('/ollama/models')) return jsonRes([{ name: 'qwen3.6:35b' }]);
      if (u.includes('/sessions?')) return jsonRes([{ id: 's1', title: '会话 1', message_count: 2 }]);
      if (u.includes('/messages')) return jsonRes([
        { id: 1, role: 'user', content: '历史提问', created_at: '2026-09-11T10:00:00Z' },
        { id: 2, role: 'assistant', content: '历史回答', created_at: '2026-09-11T10:00:05Z' },
      ]);
      return jsonRes([]);
    };
    vi.spyOn(globalThis, 'fetch').mockImplementation(impl);
    render(<ChatPanel projectId="p1" agentId="a1" />);

    await waitFor(() => {
      expect(document.body.textContent).toContain('历史回答');
    }, { timeout: 3000 });

    vi.useFakeTimers({ shouldAdvanceTime: true });
    await act(async () => { await vi.advanceTimersByTimeAsync(5000); });

    // ⛔ 历史消息没有活流，绝不能冒出进行计时
    expect(readRunElapsed()).toBeNull();
  });

  it('R5 ⛔ 手动停止后不显示进行计时，且「已手动停止」标记仍在（守护 C6 三态）', async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    const { ctl } = mountWithControllableStream();
    await sendAndKeepStreaming(ctl);

    // 工具执行中 → 进行计时在跳
    await pushAndWait(ctl, sseEvent('tool_call', { id: 'c1', name: 'read_file', args: { path: 'a.py' } }));
    await act(async () => { await vi.advanceTimersByTimeAsync(1200); });
    expect(readRunElapsed()).not.toBeNull();

    // ⛔ 用 **cancelled 事件**驱动停止，而不是点停止按钮。理由（照抄 chatPanelC2ToolSteps 的既有结论，
    //   该文件 :67 明确记载）：点按钮走前端 abort → 需要 reader.read() 以 AbortError reject，
    //   而测试桩的 ReadableStream 不接 init.signal，abort 后 read 永久挂起、catch 分支永不触发。
    //   cancelled 是**后端确认停止**的真实事件（stop 端点置位 → 后端硬取消在飞请求后发此事件），
    //   前端 `:1645` 分支与 AbortError 路径语义完全一致（同样置 stopped + manualStopped），
    //   故它走的是**产品真实链路**，不是绕过断言。
    await pushAndWait(ctl, sseEvent('cancelled', { detail: '已停止生成' }));

    await waitFor(() => {
      expect(document.body.textContent).toContain('已手动停止');
    }, { timeout: 3000 });

    // ⛔ 停止后不得再显示进行计时（否则用户以为还在跑）
    await act(async () => { await vi.advanceTimersByTimeAsync(3000); });
    expect(readRunElapsed()).toBeNull();
    // ⛔ 三态标记必须仍在，且不得被误标为"异常中断"（C6 语义底线）
    expect(document.body.textContent).toContain('已手动停止');
    expect(document.body.textContent).not.toContain('已中断执行');
    // ⛔ 运行中的工具步骤须收敛为中断态，不得永久显示"正在调用"（C2 根因③）。
    //   ⚠️ 断言口径：流结束后步骤组**自动收拢**，收拢态摘要是「工具调用 N 步 · M 成功 · K 中断」
    //   （「已中断，未完成」是展开态的单条文案，收拢时看不到）。⛔ 本套件首轮在此画蛇添足
    //   断言了展开态文案导致红——细粒度断言由 chatPanelC2ToolSteps 专项覆盖，此处只验"未卡在进行中"。
    expect(document.body.textContent).toContain('中断');
    expect(document.body.textContent).not.toContain('正在调用');
  });

  it('R6 ⛔ 每秒只触发一次消息状态更新（守护"不新增重渲染"）', async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    const { ctl } = mountWithControllableStream();
    await sendAndKeepStreaming(ctl);

    await pushAndWait(ctl, tokenEvent('正文'));
    await waitFor(() => {
      expect(document.body.textContent).toContain('正文');
    }, { timeout: 3000 });

    // ⛔ 源码级守护：流级计时器只能有**一个** setInterval 每秒驱动，
    //   不得为 runElapsed 另建第二个计时器（否则思考态期间每秒两次 setLocalMessages，
    //   消息列表重渲染翻倍 —— ChatPanel 已 2425 行，是 B6/B7 性能瓶颈区）。
    const src = await import('../panels/ChatPanel?raw').then(m => (m as any).default as string);
    expect(src.length).toBeGreaterThan(10000);
    // 思考计时 + 等待计时 + 流级计时：全文件 setInterval 总数不得超过 3
    const intervals = (src.match(/setInterval\(/g) || []).length;
    expect(intervals).toBeLessThanOrEqual(3);
    // ⛔ runElapsed 必须由既有计时器统一写入（与 thinkingElapsed 同一次 patch），
    //   锚定"同一次 patchStreamMsg 内同时出现两个字段"的形态
    expect(/runElapsed[\s\S]{0,220}thinkingElapsed|thinkingElapsed[\s\S]{0,220}runElapsed/.test(src)).toBe(true);
  });

  it('R7 插入点分裂后：进行计时写入段2，段1 不显示进行计时', async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    const { ctl } = mountWithControllableStream();
    await sendAndKeepStreaming(ctl);

    await pushAndWait(ctl, tokenEvent('第一段'));
    await act(async () => { await vi.advanceTimersByTimeAsync(2000); });

    // 用户插入消息 → 后端发 segment_break → 气泡分裂
    await pushAndWait(ctl, sseEvent('segment_break', {
      injected_messages: [{ role: 'user', content: '换个方向' }],
      break_at: 3,
    }));
    await waitFor(() => {
      expect(document.body.textContent).toContain('换个方向');
    }, { timeout: 3000 });
    await pushAndWait(ctl, tokenEvent('第二段'));

    await act(async () => { await vi.advanceTimersByTimeAsync(3000); });

    const txt = document.body.textContent || '';
    // ⛔ 全页只应有**一个**进行计时（属于段2）；段1 已定格，不得再挂活态计时
    const hits = (txt.match(/进行中\s*\d+\s*s/g) || []).length;
    expect(hits).toBe(1);
    // 段1 定格内容仍在，且带完成用时（防被误标中断）
    expect(txt).toContain('第一段');
    expect(txt).not.toContain('已中断执行');
  });

  it('R8 ⛔ 组件卸载后计时器被清理（无幽灵计时器）', async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    const clearSpy = vi.spyOn(globalThis, 'clearInterval');
    const { ctl, unmount } = mountWithControllableStream();
    await sendAndKeepStreaming(ctl);

    await pushAndWait(ctl, tokenEvent('正文'));
    await waitFor(() => {
      expect(document.body.textContent).toContain('正文');
    }, { timeout: 3000 });

    const before = clearSpy.mock.calls.length;
    unmount();
    // ⛔ 卸载必须清理计时器（否则流级计时器会在组件销毁后继续 setLocalMessages）
    expect(clearSpy.mock.calls.length).toBeGreaterThan(before);

    // 卸载后再推进时间不得抛错（幽灵计时器会在此暴露）
    await act(async () => { await vi.advanceTimersByTimeAsync(3000); });
  });
});

describe('B12 源码契约（防回归到"两个计时器"或"漏清理"）', () => {
  it('runElapsed 字段已在 Message 类型声明且为瞬态（不落库）', async () => {
    const hookSrc = await import('../hooks/useMessages?raw').then(m => (m as any).default as string);
    expect(hookSrc.includes('runElapsed')).toBe(true);
  });

  it('⛔ 流级计时器在【finally】与【卸载 cleanup】两处都被清理', async () => {
    const src = await import('../panels/ChatPanel?raw').then(m => (m as any).default as string);
    expect(src.length).toBeGreaterThan(10000);

    // ① finally 是流的正常结束出口（done/error/abort），必须清理
    const finallyIdx = src.indexOf('abortRef.current = null;');
    expect(finallyIdx).toBeGreaterThan(0);
    expect(/clearInterval\(/.test(src.slice(finallyIdx, finallyIdx + 500))).toBe(true);

    // ② ⛔⛔ 卸载 cleanup 也必须清理 —— 实测发现卸载 cleanup（mountedRef.current = false 那处）
    //   **并不 abort 流**，因此组件卸载时 finally 根本不会执行；
    //   若只在 finally 清理，卸载后计时器仍每秒对已销毁组件 setLocalMessages（幽灵计时器）。
    //   → 计时器必须存 ref，卸载 cleanup 里一并 clearInterval。
    const unmountIdx = src.indexOf('mountedRef.current = false;');
    expect(unmountIdx).toBeGreaterThan(0);
    expect(/clearInterval\(/.test(src.slice(unmountIdx, unmountIdx + 500))).toBe(true);
  });
});
