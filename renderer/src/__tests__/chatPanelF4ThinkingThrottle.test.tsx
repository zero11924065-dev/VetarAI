/*
 * VetarAI - Local-first multi-agent orchestration application
 * Copyright (C) 2026 zero11924065-dev
 * GPL-3.0-or-later（见仓库 LICENSE）
 */
/**
 * F4（0.4.23 安全区，checkpoint-110）：thinking delta 按帧合并节流。
 *
 * ═══ 治什么（真机数据坐实，⛔ 不是推测）═══
 * `36-…测量操作卡.md` 5.7：模型运行时 **Electron 渲染进程 ~103%（烧满一核）**，而 ollama 仅 ~22%；
 * codex 跑同样模型前端进程 0% → 问题 100% 在 VetarAI 前端自己烧核。
 * 机制：ChatPanel 消息列表内联 `.map()`（93~95 条）无虚拟化，**每个 SSE 事件都 setLocalMessages
 * → 重渲染整个列表 + 重解析所有 Markdown**。
 * ⛔ D 场景（思考圆圈，实测 fps 3.7 / longtask 78%）的元凶正是 thinking 分支：
 * 每个 thinking delta 都单独 `patchStreamMsg` 更新 `thinkingPreview`（仅显示末 120 字），
 * 而 qwen3.8 是思考模型、思考增量高频到达 → 每个 delta 一次整列表重渲染。
 *
 * ═══ 修法 ═══
 * 仿正文 token 的 rAF 合并模式：thinkingPreview 增量也累积进 `accThinking`，
 * 与正文**共用同一次按帧 flush**（一帧内最多提交一次），不再每 delta 一次提交。
 * ⛔ 必须保住"思考阶段化"语义（startThinkingPhase / closeThinkingPhase 不动）：
 * 思考态照常开/关、计时照常、预览仍是末 120 字。
 *
 * ═══ 测法（⛔ 两处刻意选择，都是踩过坑之后定的，别改回去）═══
 * 1. **指标＝React `<Profiler>` 的 commit 次数**，不是"预览文本对不对"。
 *    预览文本改前改后都正确（只是更新频率不同）→ 只断言文本会**空转**（撤掉节流照样绿）。
 *    commit 次数才是"整列表重渲染"的可观测代理。
 * 2. ⛔⛔ **每个 delta 必须独占一个 act 边界**（本文件首轮翻车的真正原因，已实测坐实）：
 *    首轮我用"一次性排入 30 个事件（间隔 4ms）+ 事后 settle 480ms"喂 delta，
 *    结果改前 commit 只有 **15** 次（诊断实测 `usedDuringThinking:15 / rafRequested:0`）
 *    ——因为 settle 的 `await act(async()=>sleep(60))` 一轮就吞掉 ~15 个 delta，
 *    React 18 在**同一 act 边界内自动批处理**，把 30 次 setState 压成 ~15 次提交。
 *    这恰好卡在我的阈值 ≤15 上 → **改前也绿 = 假绿**（测不准比没测更危险）。
 *    ✅ 正解：改用**可控流逐个 push**，push 一个 delta → 一个独立 act → 数 commit。
 *    这才复现真机语义：SSE reader 每次 read() 回调是独立宏任务，React 无从批处理，
 *    于是"每 delta 一次整列表提交"如实暴露（改前 ≈ 1 commit/delta，改后 ≈ 0）。
 *    ⛔ 不用 helpers 的 `sseResControllable`（记载有三次踩坑），本文件自带 real-timers 版可控流。
 * 3. **手动帧调度（stub rAF）而非依赖 jsdom 真实帧时序**：真机 rAF ~16ms 而事件间隔不可控
 *    → "一帧内到了几个 delta"会变成时序赌博（本项目已在 chatPanelStream / B12 R1 翻车多次）。
 *    手动队列让"过一帧"完全确定；⛔ cancel 也必须 stub，否则已取消的 flush 仍会执行
 *    → 正文被重复追加（假失败）。
 *
 * 运行：node node_modules/vitest/vitest.mjs run src/__tests__/chatPanelF4ThinkingThrottle.test.tsx
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, waitFor, act } from '@testing-library/react';
import React, { Profiler } from 'react';
import { ChatPanel } from '../panels/ChatPanel';
import { jsonRes, sseEvent } from './helpers/fetchMock';

// ── 手动帧调度：把 rAF 回调收进队列，由测试决定何时"过一帧" ──────────────
let rafSeq = 0;
const rafMap = new Map<number, FrameRequestCallback>();

/** 过一帧：把当前挂起的全部 rAF 回调在 act 内跑掉（模拟浏览器的一次帧提交）。 */
function runFrame() {
  const pending = Array.from(rafMap.entries());
  rafMap.clear();
  act(() => { for (const [, cb] of pending) cb(Date.now()); });
}

beforeEach(() => {
  vi.restoreAllMocks();
  localStorage.clear();
  rafSeq = 0;
  rafMap.clear();
  // ⛔ 必须同时 stub cancel：产品代码在 done/cancelled/abort/分裂路径都会 cancelAnimationFrame，
  //   若 cancel 是空操作，已取消的 flush 仍会在 runFrame 里执行 → 正文被重复追加（假失败）。
  vi.stubGlobal('requestAnimationFrame', (cb: FrameRequestCallback) => {
    const id = ++rafSeq; rafMap.set(id, cb); return id;
  });
  vi.stubGlobal('cancelAnimationFrame', (id: number) => { rafMap.delete(id); });
});

afterEach(() => { vi.unstubAllGlobals(); vi.useRealTimers(); });

// ── 可控流（real timers 版）：push 不 close 即得稳定的"流进行中"中间态 ──────────
// ⛔ 刻意自己写而不用 helpers 的 sseResControllable（那边记载了三次踩坑、且面向 fake timers）。
function controllableStream() {
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
    start(controller) { ctrl = controller; flush(); },
  });
  return {
    res: new Response(stream, { status: 200, headers: { 'Content-Type': 'text/event-stream' } }),
    push: (e: string) => { buffer.push(e); flush(); },
    close: () => { if (ctrl) { try { ctrl.close(); } catch { /* 已关闭 */ } } },
  };
}

const thinkingEvent = (delta: string) => sseEvent('thinking', { delta });

/** 装载 ChatPanel（外面套 Profiler 数 commit）。返回可控流的 push/close 句柄。 */
function mount() {
  const commits = { n: 0 };
  const ctl = controllableStream();
  const impl: typeof fetch = async (url, init) => {
    const u = String(url);
    void init;
    if (u.includes('/agents/')) return jsonRes([{ id: 'a1', name: '行政主管', role: 'x' }]);
    if (u.includes('/ollama/models')) return jsonRes([{ name: 'qwen3.8' }]);
    if (u.includes('/sessions?')) return jsonRes([{ id: 's1', title: '会话 1', message_count: 1 }]);
    if (u.includes('/messages')) return jsonRes([]);
    if (u.includes('/ollama/chat/stream')) return ctl.res;
    return jsonRes([]);
  };
  vi.spyOn(globalThis, 'fetch').mockImplementation(impl);
  const view = render(
    <Profiler id="chat" onRender={() => { commits.n += 1; }}>
      <ChatPanel projectId="p1" agentId="a1" />
    </Profiler>,
  );
  return { ...view, commits, ctl };
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

/** 真实时间 settle（⛔ 断言前必须先等"落地信号"，见 05-快照 的 jsdom 时序教训）。 */
async function settle(ms = 60, rounds = 6) {
  for (let i = 0; i < rounds; i++) await act(async () => { await new Promise(r => setTimeout(r, ms)); });
}

/**
 * ⛔ push **一个**事件 + 独占一个 act 边界（本文件的核心纪律，见顶部说明 2）。
 * real timers 下 await 真实 sleep，让 SSE reader 从缓冲读到该事件、React 提交一次。
 * 一个 delta 一个边界 → React 无从批处理 → "每 delta 一次提交"如实暴露。
 */
async function pushOne(ctl: { push: (e: string) => void }, ev: string) {
  await act(async () => {
    ctl.push(ev);
    await new Promise(r => setTimeout(r, 12));
  });
}

/** 发消息开流（流不关闭 → 保持进行中）。 */
async function send(text: string) {
  await waitFor(() => expect(getTextarea()).toBeTruthy(), { timeout: 3000 });
  await settle(40, 5);   // 让 sessions/messages 的 fetch 链 settle，currentSessionId 就位
  await act(async () => {
    typeInto(getTextarea(), text);
    getTextarea().dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
  });
  await waitFor(() => expect(document.body.textContent).toContain(text), { timeout: 3000 });
}

/** 30 个可辨识的思考增量标记（每个 7 字符，共 210 > 120 → 用于验证"只留末 120 字"）。 */
const FRAG = (i: number) => `思考片段${String(i).padStart(2, '0')}，`;
const FRAGS = Array.from({ length: 30 }, (_, i) => FRAG(i));

describe('F4 thinking delta 按帧合并（不再每 delta 触发整列表重渲染）', () => {
  it('T1 ⛔ 30 个思考增量只触发极少量提交，且预览仍是末 120 字', async () => {
    const { commits, ctl } = mount();
    await send('开始思考');

    // 落地信号：首个 delta 开思考态（startThinkingPhase 已生效）
    await pushOne(ctl, thinkingEvent(FRAGS[0]));
    await waitFor(() => expect(document.body.textContent).toContain('思考中'), { timeout: 3000 });

    // ⛔ 关键：本用例的度量区间从这里开始（不含挂载/发送/首个思考态开启的提交）
    const base = commits.n;
    // 逐个推送剩余 29 个 delta，**每个独占一个 act 边界**（见顶部说明 2）
    for (let i = 1; i < FRAGS.length; i++) await pushOne(ctl, thinkingEvent(FRAGS[i]));

    // 过一帧：把挂起的合并 flush 跑掉（改前每 delta 各自提交，与此帧无关）
    runFrame();

    const used = commits.n - base;
    // 改后：29 个 delta 只在帧 flush 时合并提交 ≈ 1~3 次（+ 少量缓存同步）。
    // 改前：每个 delta 一次 patchStreamMsg = 一次提交 ≈ 29+ 次 → 红。
    // ⛔ 阈值取 10：远低于 29（能抓住回归），又给足噪声余量（不会 flaky）。
    //   （首轮用 15 且喂法有 React 批处理 → 改前实测 15 恰好卡线假绿，见顶部说明 2。）
    expect(used).toBeLessThanOrEqual(10);

    // ⛔ 节流不得丢内容：预览必须是**全部 delta 拼接后的末 120 字**
    //   → 末片段在、首片段被 slice(-120) 丢掉（证明累积没漏也没多）
    const body = document.body.textContent || '';
    expect(body).toContain('思考片段29');
    expect(body).not.toContain('思考片段00');
    // 思考态仍在（阶段语义未被节流破坏）
    expect(body).toContain('思考中');
  });

  it('T2 ⛔ 思考→正文的阶段切换不被节流破坏（思考态关闭 + 正文完整落地）', async () => {
    const { commits, ctl } = mount();
    await send('先思考再回答');

    await pushOne(ctl, thinkingEvent(FRAGS[0]));
    await waitFor(() => expect(document.body.textContent).toContain('思考中'), { timeout: 3000 });
    const base = commits.n;
    for (let i = 1; i < 6; i++) await pushOne(ctl, thinkingEvent(FRAGS[i]));
    // 正文到达 → closeThinkingPhase；再 done 收尾
    await pushOne(ctl, sseEvent('token', { delta: '正文来了' }));
    await pushOne(ctl, sseEvent('done', { content: '正文来了完整版', tool_calls: [] }));
    runFrame();
    await settle();
    runFrame();

    // ⛔ done 之后思考态必须关闭（closeThinkingPhase 照常生效）——
    //   若节流把 thinkingPreview 的 flush 拖到 done 之后且顺手复活了思考态，这里就会红。
    await waitFor(() => {
      expect(document.body.textContent).not.toContain('思考中');
    }, { timeout: 3000 });
    // 正文以 done 为权威（⛔ 不得因 rAF 合并被重复追加）
    expect(document.body.textContent).toContain('正文来了完整版');
    expect((document.body.textContent || '').split('正文来了完整版').length - 1).toBe(1);
    // 混合流下提交数同样受控（5 thinking + 1 token + 1 done，改前每 thinking 各一次）
    expect(commits.n - base).toBeLessThanOrEqual(12);
  });
});

describe('F4 源码契约（防回归到"每 delta 一次 patchStreamMsg"）', () => {
  it('⛔ thinking 分支不得再直接 patchStreamMsg 写 thinkingPreview（必须走累积 + rAF）', async () => {
    const src = await import('../panels/ChatPanel?raw').then(m => (m as any).default as string);
    expect(src.length).toBeGreaterThan(10000);

    // ① thinkingPreview 只允许在 flush（合并提交）里写入一次；
    //    ⛔ 锚定"每 delta 一次提交"的旧形态：patchStreamMsg 内直接拼 thinkingPreview + slice(-120)
    const oldForm = /patchStreamMsg\(\s*m\s*=>\s*\(\{\s*\.\.\.m,\s*thinkingPreview:/;
    expect(oldForm.test(src)).toBe(false);

    // ② 累积缓冲必须存在，且与正文共用同一次调度（rAF）
    expect(/accThinking\s*\+=/.test(src)).toBe(true);
    // ③ slice(-120) 的"末 120 字"语义必须保留（不能因节流把预览改成全量或更短）
    expect(/thinkingPreview:[\s\S]{0,120}?slice\(-120\)/.test(src)).toBe(true);
  });

  it('⛔ 每条终结路径都清 accThinking（不得把上一段的思考预览写进新气泡）', async () => {
    const src = await import('../panels/ChatPanel?raw').then(m => (m as any).default as string);
    // accContent 被清理的地方（切会话守卫 / 分裂定格 / cancelled / done / 两处 AbortError）
    // accThinking 必须同等对待：清零次数不得少于 accContent 的清零次数
    const clearContent = (src.match(/accContent = ''/g) || []).length;
    const clearThinking = (src.match(/accThinking = ''/g) || []).length;
    expect(clearContent).toBeGreaterThanOrEqual(5);   // 前置：确认锚点真的在数东西（防空转）
    expect(clearThinking).toBeGreaterThanOrEqual(clearContent);
  });
});
