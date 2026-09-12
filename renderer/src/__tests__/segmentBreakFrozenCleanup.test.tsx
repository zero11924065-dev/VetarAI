/*
 * VetarAI - Local-first multi-agent orchestration application
 * Copyright (C) 2026 zero11924065-dev
 * GPL-3.0-or-later（见仓库 LICENSE）
 */
/**
 * #1 插入点分裂 · **定格气泡的运行态残留**复现测试（0.4.22 重打包修复二，checkpoint-109）。
 *
 * ═══ 用户实测报障（2026-09-12，四图）═══
 *
 * 插入分裂成功后，被定格的旧气泡**仍显示**：
 *   ① 「正在调用 web_search…」转圈（toolSteps 残留 running）；
 *   ② 「模型加载/推理中，较久属正常（本地模型）…已等待 26s」横幅（waitingSeconds 残留），
 *      而气泡上方思考已停止、显示「完成」——自相矛盾的半成品观感。
 *
 * ═══ 根因（落库 + 代码双重证据）═══
 *
 * 落库：该会话 session_messages 只有 2 条 assistant（首答 + 终答），**分裂出的段1
 * 气泡从未落库**，只活在内存/本地缓存；其折叠行却显示「工具调用 5 步」，而分裂点
 * 逻辑上只经过 1~2 轮工具轮 → 证明 **M5 重连导致 loop 整轮重跑**：attempt1 断连时
 * 段1 上残留 running 步骤（其 tool_result 随断连丢失），attempt2 重跑产生完整步骤。
 *
 * 前端三处缺口叠加：
 *   1. segment_break 定格 patch **只清 thinking，不清 waitingSeconds、不收敛 running**；
 *   2. 分裂后 streamMsgId 指向新气泡 → 流的 +1 计时 / 首 token 清零 / done 收尾
 *      **全部写新气泡**，旧气泡再无事件到达 → banner 判据 `!content && waitingSeconds>=8`
 *      永久成立、数值定格不再跳（两帧截图同为 26s 即此）；
 *   3. done 路径不收敛 toolSteps（正常流靠「tool_result 必先于 done」自洽，
 *      重连/断连打破该前提后无兜底）。
 *   ⛔ 历史注释断言「分裂点不可能有 running（tool_result 必同轮到达）」——
 *     该断言只在**单连接不重连**时成立，重连即破。本套件锁住收敛后的终态。
 *
 * ═══ 断言纪律：每条断言前先等「落地信号」═══
 *
 * 探针实测（_tmp_probe_steps，已删）：同一序列两次运行，一次 DOM 显示「步骤 0/5」、
 * 一次「步骤 1/200」——**state/工具事件的 commit 时机在 jsdom 下不稳定**。
 * 直接断言会因窗口错位假红/假绿。故每个用例先 waitFor 一个**只有目标事件落地后
 * 才可能出现**的信号（横幅出现 / 收拢行出现 / 步骤行变化），再断言终态：
 *   · 改前：落地信号出现后终态错误 → 红（真红）；或信号本身永不出现（收敛缺失）→ 红；
 *   · 改后：信号出现且终态正确 → 绿。
 * 流式夹具沿用 `sseResSlow`（一次性完整序列 + 事件间延时），不用 sseResControllable
 * （本项目 jsdom 时序坑，见 segmentBreakRealInject 头注释）。
 *
 * 运行：node node_modules/vitest/vitest.mjs run src/__tests__/segmentBreakFrozenCleanup.test.tsx
 */
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, waitFor, act } from '@testing-library/react';
import React from 'react';
import { ChatPanel } from '../panels/ChatPanel';

import { jsonRes, sseEvent, tokenEvent, doneEvent, sseResSlow } from './helpers/fetchMock';

/** state 事件（helpers 未导出，测试内构造；payload 与 loop.py 一致） */
const stateEvent = (d: { step: number; max: number; tokens_used: number; prompt_eval_count: number; ctx_chars: number }) =>
  sseEvent('state', d);

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

const INJECT_TEXT = '改看B表';
const SEG1_TEXT = '第一段正文';
const SEG2_TEXT = '针对插入的新回复';

const segBreak = (injected: string, breakAt: number) =>
  sseEvent('segment_break', {
    injected_messages: [{ role: 'user', content: injected }],
    break_at: breakAt,
  });
const toolCall = (id: string, name: string) =>
  sseEvent('tool_call', { id, name, args: {} });
const toolResult = (id: string, name: string) =>
  sseEvent('tool_result', { id, name, ok: true, summary: 'ok' });

function mountWithSlowStream(evs: string[], gapMs = 150) {
  const impl: typeof fetch = async (url) => {
    const u = String(url);
    if (u.includes('/inject')) return jsonRes({ ok: true, detail: '已加入' });
    if (u.includes('/agents/')) return jsonRes([{ id: 'a1', name: '行政主管', role: 'x' }]);
    if (u.includes('/ollama/models')) return jsonRes([{ name: 'qwen3.6:35b' }]);
    if (u.includes('/sessions?')) return jsonRes([{ id: 's1', title: '会话 1', message_count: 1 }]);
    if (u.includes('/messages')) return jsonRes([]);
    // ⛔ 顶栏指示器渲染条件 contextLimit>0 → 必须给 /context/limit，否则指示器不渲染
    if (u.includes('/context/limit')) return jsonRes({ context_limit: 262144, source: 'test' });
    if (u.includes('/ollama/chat/stream')) return sseResSlow(evs, gapMs);
    return jsonRes([]);
  };
  vi.spyOn(globalThis, 'fetch').mockImplementation(impl);
  return render(<ChatPanel projectId="p1" agentId="a1" />);
}

function getTextarea(): HTMLTextAreaElement {
  const el = document.querySelector('textarea');
  if (!el) throw new Error('未找到输入框');
  return el as HTMLTextAreaElement;
}
function typeInto(el: HTMLTextAreaElement, text: string) {
  const setter = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value')!.set!;
  setter.call(el, text);
  el.dispatchEvent(new Event('input', { bubbles: true }));
}
async function sendFirstMessage(text = '第一个问题') {
  await waitFor(() => expect(getTextarea()).toBeTruthy(), { timeout: 3000 });
  await act(async () => {
    typeInto(getTextarea(), text);
    getTextarea().dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
  });
  await waitFor(() => expect(document.body.textContent).toContain(text), { timeout: 3000 });
}
async function injectWhileStreaming(text: string) {
  await act(async () => {
    typeInto(getTextarea(), text);
    getTextarea().dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
    await new Promise(r => setTimeout(r, 30));
  });
}
/** 收拢行判据（与 chatPanelB4Collapse 一致）：含「工具调用 N 步」。 */
const collapsedBarVisible = () => /工具调用 \d+ 步/.test(document.body.textContent || '');

describe('#1 插入点分裂 · 定格气泡运行态残留（checkpoint-109）', () => {
  it('F1 ⛔ 分裂后旧气泡不得残留「正在调用 …」（running 必须收敛为 interrupted）', async () => {
    // 复现重连场景的残留形态：段1 期间发起 c2 但**永不给 tool_result**
    // （= 断连丢失），随后 segment_break 定格 → 旧气泡应把 c2 收敛为 interrupted。
    mountWithSlowStream([
      tokenEvent(SEG1_TEXT),
      toolCall('c1', 'web_search'),
      toolResult('c1', 'web_search'),
      toolCall('c2', 'web_search'),          // ⛔ 无对应 tool_result（模拟断连丢失）
      segBreak(INJECT_TEXT, SEG1_TEXT.length),
      tokenEvent(SEG2_TEXT),
      doneEvent(SEG1_TEXT + SEG2_TEXT),
    ]);
    await sendFirstMessage();
    // 落地信号①：c2 的 running 已渲染（「正在调用 web_search」出现）——证明残留确实产生
    await waitFor(() => expect(document.body.textContent).toContain('正在调用 web_search'), { timeout: 5000 });
    await waitFor(() => expect(document.body.textContent).toContain(SEG1_TEXT), { timeout: 3000 });
    await injectWhileStreaming(INJECT_TEXT);
    await waitFor(() => expect(document.body.textContent).toContain(SEG2_TEXT), { timeout: 6000 });
    // 落地信号②：流已结束（done 落地）——以段2 正文出现为准
    const txt = document.body.textContent || '';
    // ⛔ 核心断言：定格后界面上不得再有任何「正在调用」字样（单步行标签 + 组头标签共用该前缀）
    expect(txt).not.toContain('正在调用');
    // 收敛后的中性标记应出现：步骤组在 done 后**收拢**，收拢行标签是「N 中断」
    // （单步行标签「（已中断，未完成）」只在展开态渲染，收拢态不可断言它）
    expect(txt).toContain('1 中断');
  });

  it('F2 ⛔ 分裂后旧气泡不得残留「模型加载/推理中…已等待 Ns」横幅（waitingSeconds 必须清 0）', async () => {
    // 横幅判据：assistant && !streamError && !content && waitingSeconds>=8。
    // 段1 **只调工具不吐正文**（content 为空）→ 判据前三项成立。
    // ⛔ gap=2000ms：让 +1 计时在分裂前**真的累过 8s**。时间线（9 事件 × 2s）：
    //   t≈8s 横幅出现（waitingSeconds≥8 且 content 为空）→ t≈12s segBreak 定格清 0
    //   → 横幅窗口 8~12s，足够 waitFor 抓到「出现过」，又保证定格后必须消失。
    mountWithSlowStream([
      toolCall('c1', 'web_search'),
      toolResult('c1', 'web_search'),
      toolCall('c2', 'web_search'),
      toolResult('c2', 'web_search'),
      toolCall('c3', 'web_search'),
      toolResult('c3', 'web_search'),
      segBreak(INJECT_TEXT, 0),              // 段1 无正文，break_at=0；第 6 个间隔后到达 ≈12s
      tokenEvent(SEG2_TEXT),
      doneEvent(SEG2_TEXT),
    ], 2000);
    await sendFirstMessage();
    // 落地信号①：横幅真的出现过（waitingSeconds 累过 8 且 content 为空）
    await waitFor(() => expect(document.body.textContent).toContain('模型加载/推理中'), { timeout: 15000 });
    await injectWhileStreaming(INJECT_TEXT);
    await waitFor(() => expect(document.body.textContent).toContain(SEG2_TEXT), { timeout: 15000 });
    // ⛔ 核心断言：定格后横幅必须消失（waitingSeconds 被清 0）
    expect(document.body.textContent || '').not.toContain('模型加载/推理中');
  }, 30000);   // ⛔ 用例超时放宽：gap=2000ms × 9 事件 ≈ 18s，默认 5s 不够

  it('F3 done 兜底收敛：tool_result 丢失的 done 到达后 running 也不得残留', async () => {
    // 不分裂的普通流：c2 的 tool_result 随断连丢失，done 直接到达。
    // 正常流靠「tool_result 必先于 done」自洽，重连打破前提后 done 必须兜底收敛。
    mountWithSlowStream([
      tokenEvent(SEG1_TEXT),
      toolCall('c1', 'web_search'),
      toolResult('c1', 'web_search'),
      toolCall('c2', 'web_search'),          // ⛔ 无对应 tool_result
      doneEvent(SEG1_TEXT),
    ]);
    await sendFirstMessage();
    // 落地信号①：running 已渲染
    await waitFor(() => expect(document.body.textContent).toContain('正在调用 web_search'), { timeout: 5000 });
    // 落地信号②：done 已落地 → B4 收拢行出现的前提是 running===0；
    //   改前 running 残留 → 收拢行永不出现 → 此处超时红（真红）。
    await waitFor(() => expect(collapsedBarVisible()).toBe(true), { timeout: 5000 });
    const txt = document.body.textContent || '';
    expect(txt).not.toContain('正在调用');
    // 收拢行标签：2 步里 1 成功 1 中断（单步行标签收拢态不渲染，见 F1 注释）
    expect(txt).toContain('1 中断');
  });

  it('F4 指示器单调守门：后到的更小 state 值不得覆盖当前显示值', async () => {
    // 复现重连重跑的覆盖形态：先 state(ctx=12695→7617 token)，后 state(ctx=10095→6057)。
    // 无守门时显示值从 7617 掉到 6057（用户实测「发第二条后指示器反降」）。
    mountWithSlowStream([
      tokenEvent(SEG1_TEXT),
      stateEvent({ step: 2, max: 200, tokens_used: 5870, prompt_eval_count: 100, ctx_chars: 12695 }),
      stateEvent({ step: 1, max: 200, tokens_used: 3000, prompt_eval_count: 80, ctx_chars: 10095 }),
      doneEvent(SEG1_TEXT),
    ], 150);
    await sendFirstMessage();
    await waitFor(() => expect(document.body.textContent).toContain('上下文 ≈7617'), { timeout: 5000 });
    // 落地信号：第二个 state 已 commit——它的 patchStreamMsg 把 msg.step 写成 1，
    //   步骤行随之变「步骤 1/200」。等不到即说明第二个 state 没落地，断言无意义。
    await waitFor(() => expect(document.body.textContent).toContain('步骤 1/200'), { timeout: 5000 });
    // ⛔ 核心断言：第二个（更小的）state 落地后，显示值不得回落到 6057
    const txt = document.body.textContent || '';
    expect(txt).not.toContain('上下文 ≈6057');
    expect(txt).toContain('上下文 ≈7617');
  });
});
