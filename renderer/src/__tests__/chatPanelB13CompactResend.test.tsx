/*
 * VetarAI - GPL-3.0-or-later（见仓库 LICENSE）
 *
 * B13（0.4.22）：智能压缩后多出一条一模一样的用户消息 —— 专项测试。
 *
 * 根因（2026-09-11 查实，两条路径）：
 *   压缩回调 `ChatPanel.tsx:2053-2055`：`setInput(lastUser.content); setTimeout(()=>handleSend(),500)`。
 *   ① **流未结束时**点压缩：`handleSend` 开头 `if (sending) { handleInject(); return; }` →
 *      走 **inject 分支** → POST /inject → 后端把该消息当注入消息回显（segment_break）→
 *      界面出现**第二条一模一样的用户气泡**（用户截图现象：思考中还出现重复用户消息）。
 *      而后端压缩**保留最近 keep_recent 条**（默认10），最后一条本就在保留区、历史里已有它 → 纯属重复。
 *   ② **流已结束**时点压缩：setTimeout 捕获的是**点击瞬间的空 input 闭包** →
 *      `hasSendableText('')` 为 false → 重发**静默无效**（原设计意图"压缩后继续任务"实际没生效）。
 *
 * ⛔ 判"是否重发/注入"用两个计数：/ollama/chat/stream 的 fetch 次数 + /inject 的 POST 次数。
 *   "发生了重复发送" = 任计数 +1。
 *
 * 两场景（修复后的期望）：
 *   ① 流未结束 + 最后一条 user 仍在保留区 → ⛔ 不得 inject、不得开新流（bug 在则 inject+1 → 红）
 *   ② 流已结束 + 最后一条 user 已被压缩掉 → 应重发开新流（+1）（bug 在则闭包空 input 静默无效 → 红）
 *
 * 运行：node node_modules/vitest/vitest.mjs run src/__tests__/chatPanelB13CompactResend.test.tsx
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, waitFor, act } from '@testing-library/react';
import React from 'react';
import { ChatPanel } from '../panels/ChatPanel';
import { jsonRes, sseResControllable, sseEvent } from './helpers/fetchMock';

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

/**
 * 挂载并计数：stream 请求数 + inject POST 数。
 * @param dbMsgsAfterCompact 压缩后 GET /messages 返回（决定最后一条 user 是否"仍在保留区"）
 * @param closeStreamBeforeCompact 点压缩前是否关闭首条流（true=流已结束场景）
 */
function mount(dbMsgsAfterCompact: Array<{ id: number | string; role: string; content: string }>,
               closeStreamBeforeCompact: boolean) {
  const ctl = sseResControllable();
  let streamCalls = 0;
  let injectCalls = 0;
  const allCalls: string[] = [];
  const impl: typeof fetch = async (url, init) => {
    const u = String(url);
    const method = String(init?.method || 'GET');
    allCalls.push(`${method} ${u.replace(/^https?:\/\/[^/]+/, '')}`);
    if (u.includes('/agents/')) return jsonRes([{ id: 'a1', name: '行政主管', role: 'x' }]);
    if (u.includes('/ollama/models')) return jsonRes([{ name: 'qwen3.6:35b' }]);
    if (u.includes('/sessions?')) return jsonRes([{ id: 's1', title: '会话 1', message_count: 3 }]);
    if (u.includes('/compact') && method === 'POST') {
      // 压缩成功的瞬间按场景切换 /messages 的返回（模拟压缩已删/未删最后一条）
      return jsonRes({ ok: true });
    }
    if (u.includes('/inject') && method === 'POST') { injectCalls++; return jsonRes({ ok: true }); }
    if (u.includes('/messages')) return jsonRes(dbMsgsAfterCompact);
    if (u.includes('/ollama/chat/stream')) { streamCalls++; return ctl.res; }
    return jsonRes([]);
  };
  vi.spyOn(globalThis, 'fetch').mockImplementation(impl);
  const r = render(<ChatPanel projectId="p1" agentId="a1" />);
  return { ...r, ctl, closeStreamBeforeCompact,
    counts: () => ({ stream: streamCalls, inject: injectCalls }),
    calls: () => allCalls.slice() };
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
async function clickCompact() {
  const btn = Array.from(document.querySelectorAll('button')).find(b => b.textContent === '智能压缩');
  if (!btn) throw new Error('未找到智能压缩按钮');
  await act(async () => {
    (btn as HTMLButtonElement).dispatchEvent(new MouseEvent('click', { bubbles: true }));
    await new Promise(r => setTimeout(r, 900));   // 覆盖重发的 setTimeout 500ms + 余量
  });
}

describe('B13 智能压缩后的重发/注入判断', () => {
  it('① 流未结束 + 最后一条 user 仍在保留区 → ⛔ 不得 inject、不得开新流（bug 在则红）', async () => {
    const { ctl, counts } = mount([
      { id: 1, role: 'user', content: '我的问题' },
      { id: 2, role: 'assistant', content: '部分回答' },
      { id: 3, role: 'user', content: '我的问题' },   // ⛔ 同内容仍在保留区 → 内容判据下"模型看得到" → 不得重发
    ], false);
    await waitFor(() => expect(getTextarea()).toBeTruthy(), { timeout: 3000 });
    await act(async () => { typeInto(getTextarea(), '我的问题'); });
    // eslint-disable-next-line no-console
    console.log('PROBE-enter-pre', JSON.stringify(counts()));
    await act(async () => {
      getTextarea().dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
      await new Promise(r => setTimeout(r, 100));
    });
    // eslint-disable-next-line no-console
    console.log('PROBE-enter-post', JSON.stringify(counts()));
    const before = counts();
    expect(before.stream).toBe(1);

    // 触发压缩提示条（流保持打开 = 用户截图场景）
    await act(async () => { ctl.push(sseEvent('compact_required', { used: 90, limit: 100, est_rounds_left: 1 })); await new Promise(r => setTimeout(r, 100)); });
    await clickCompact();

    const after = counts();
    // ⛔ 核心：最后一条在保留区 → 不得重复发送（inject 或新流都不行）
    //   当前 bug：走 inject 分支 → inject+1 → 红
    expect(after.inject).toBe(before.inject);
    expect(after.stream).toBe(before.stream);
  });

  it('② 流已结束 + 最后一条 user 已被压缩掉 → 应重发开新流（bug 在则闭包空 input 静默无效 → 红）', async () => {
    const { ctl, counts, calls } = mount([
      { id: 1, role: 'system', content: '[摘要]' },
      { id: 2, role: 'assistant', content: '部分回答' },
      // ⛔ 没有最后一条 user → 视为已被压缩掉 → 应重发续任务
    ], true);
    await waitFor(() => expect(getTextarea()).toBeTruthy(), { timeout: 3000 });
    await act(async () => { typeInto(getTextarea(), '我的问题'); });
    await act(async () => {
      getTextarea().dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
      await new Promise(r => setTimeout(r, 100));
    });
    const before = counts();

    await act(async () => { ctl.push(sseEvent('compact_required', { used: 90, limit: 100, est_rounds_left: 1 })); await new Promise(r => setTimeout(r, 100)); });
    // ⛔ 先 push doneEvent 再 close：否则 close 无 done 会被应用视为**断流**触发 M5 重连
    //   （测试工件：重连开第二条流，污染流计数 = 场景②此前红绿反转的根因之一）。
    await act(async () => { ctl.push(sseEvent('done', { content: '部分回答', tool_calls: [] })); await new Promise(r => setTimeout(r, 150)); });
    await act(async () => { ctl.close(); await new Promise(r => setTimeout(r, 300)); });
    // eslint-disable-next-line no-console
    console.log('PROBE-pre', JSON.stringify({ counts: counts(), input: JSON.stringify(getTextarea().value) }));
    await clickCompact();
    // eslint-disable-next-line no-console
    console.log('PROBE-2', JSON.stringify({
      inputValue: JSON.stringify(getTextarea().value),
      counts: counts(),
      calls: calls(),
      compactBtnGone: !Array.from(document.querySelectorAll('button')).some(b => b.textContent === '智能压缩'),
    }));

    const after = counts();
    // ⛔ 被压缩掉 → 应重发（新流 +1，保原设计意图）
    //   当前 bug：setTimeout 捕获空 input 闭包 → 静默无效 → stream 不增 → 红
    expect(after.stream).toBe(before.stream + 1);
  });
});
