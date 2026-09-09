/*
 * VetarAI - Local-first multi-agent orchestration application
 * Copyright (C) 2026 zero11924065-dev
 *
 * This file is part of VetarAI.
 *
 * VetarAI is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * VetarAI is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with VetarAI. If not, see <https://www.gnu.org/licenses/>.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, waitFor, act } from '@testing-library/react';
import React from 'react';
import { ChatPanel } from '../panels/ChatPanel';

/**
 * 0.4.12 附带修复回归：组件卸载后不得再"幽灵写入"消息缓存。
 *
 * ⛔⛔ 本文件是**两次定位纠错**的产物，改前务必读懂，否则会退回无效测试：
 *
 * 【第一次纠错】最初怀疑泄漏来自节流 timer（`cacheSyncTimer`），加了卸载 clearTimeout，
 *   并断言"卸载后越过 500ms 窗口缓存不变"——**变异测试证伪**：删掉卸载清理，测试照样全绿。
 *   原因：那条路径的写缓存动作在 `setLocalMessages(prev => { syncSessionLocal(...); return prev; })`
 *   的 updater 内部，React 18 卸载后 updater **根本不会被调用** → 本就安全，不是泄漏源。
 *
 * 【第二次纠错】插桩 localStorage.setItem 抓到真实调用栈后，改断言"卸载后缓存内容不变 +
 *   不含 done 的新内容"——**仍然无效**：变异（守卫失效）后测试照样全绿。原因是 done 分支写入的
 *   finalMsg 取自 `localMessagesRef.current`（卸载前的快照），内容恰好与卸载瞬间一致，
 *   于是"内容不变"这个断言在**有幽灵写入时也成立**。
 *
 * ✅ 最终有效观测：**卸载后 localStorage.setItem 的调用次数必须为 0**。
 *   插桩实测：守卫失效时卸载后确有 1 次写入（phase=done-after-unmount），
 *   守卫生效时为 0 次——这个观测量能区分两种实现，变异测试已验证。
 *
 * 真实根因是两处**直接**调用 syncSessionLocal 的异步回调（都不经 updater，故卸载后仍会执行）：
 *   ① applyEvent 的 done 分支——reader.read() 循环在卸载后仍继续推进；
 *   ② alignLocalIdsWithDb——finally 里发起的 fetch，回来时组件已卸载。
 * 正解是 mountedRef 守卫这两处（清 timer 保留，属无害卫生）。
 */

if (typeof (globalThis as any).localStorage === 'undefined') {
  (globalThis as any).localStorage = {
    _d: {} as Record<string, string>,
    getItem(k: string) { return this._d[k] ?? null; },
    setItem(k: string, v: string) { this._d[k] = String(v); },
    removeItem(k: string) { delete this._d[k]; },
    clear() { this._d = {}; },
  };
}

const CACHE_KEY = 'subagent_messages_v4';
const ev = (t: string, d: object) => `event: ${t}\ndata: ${JSON.stringify(d)}\n\n`;

/**
 * 写入观测器：包装 localStorage.setItem，按「卸载前 / 卸载后」分桶计数。
 * ⛔ 只统计对缓存键的写入——其他键（如设置项）与本缺陷无关，混进来会稀释信号。
 */
const writes: { beforeUnmount: number; afterUnmount: number } = { beforeUnmount: 0, afterUnmount: 0 };
let unmounted = false;
let realSetItem: ((k: string, v: string) => void) | null = null;

function installWriteSpy() {
  const ls = (globalThis as any).localStorage;
  realSetItem = ls.setItem.bind(ls);
  ls.setItem = (k: string, v: string) => {
    if (k === CACHE_KEY) {
      if (unmounted) writes.afterUnmount += 1; else writes.beforeUnmount += 1;
    }
    realSetItem!(k, v);
  };
}
function restoreWriteSpy() {
  if (realSetItem) { (globalThis as any).localStorage.setItem = realSetItem; realSetItem = null; }
}
function markUnmounted() { unmounted = true; }

/** 可控流：把 enqueue/close 交给测试，精确构造"卸载后才发 done"的时序。 */
function controllableStream() {
  const encoder = new TextEncoder();
  const ctl: { push: (s: string) => void; close: () => void } = { push: () => {}, close: () => {} };
  const body = new ReadableStream({
    start(controller) {
      ctl.push = (s: string) => controller.enqueue(encoder.encode(s));
      ctl.close = () => { try { controller.close(); } catch { /* 已关闭 */ } };
    },
  });
  return { res: { ok: true, status: 200, body, text: async () => '' }, ctl };
}

/** ⛔ 必须 act + 原生 setter，理由见 chatPanelB3Wrap.test.tsx 的 sendText 注释。 */
async function sendText(value: string) {
  const ta = document.querySelector('textarea') as HTMLTextAreaElement;
  if (!ta) throw new Error('未找到输入框');
  await act(async () => {
    const setter = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value')!.set!;
    setter.call(ta, value);
    ta.dispatchEvent(new Event('input', { bubbles: true }));
  });
  await act(async () => {
    const btn = Array.from(document.querySelectorAll('button'))
      .find(b => b.getAttribute('data-tip') === '发送') as HTMLElement;
    if (!btn) throw new Error('未找到发送按钮');
    btn.click();
  });
}

function cacheOf(sid: string): any[] {
  try { return JSON.parse((globalThis as any).localStorage.getItem(CACHE_KEY) || '{}')[sid] || []; } catch { return []; }
}

beforeEach(() => {
  vi.restoreAllMocks();
  (globalThis as any).localStorage.clear();
  writes.beforeUnmount = 0; writes.afterUnmount = 0; unmounted = false;
  installWriteSpy();
  vi.spyOn(console, 'error').mockImplementation(() => {}); // 静音 act 提示，聚焦真实断言
});

afterEach(() => { restoreWriteSpy(); });

describe('卸载后不得幽灵写入消息缓存', () => {
  it('① done 在卸载之后到达 → 卸载后写入次数必须为 0', async () => {
    (globalThis as any).localStorage.setItem(CACHE_KEY, JSON.stringify({ s1: [] }));
    const { res, ctl } = controllableStream();
    vi.spyOn(globalThis, 'fetch').mockImplementation((async (url: any) => {
      const u = String(url);
      if (u.includes('/agents/')) return { ok: true, status: 200, json: async () => [{ id: 'a1', name: '测试', role: 'x' }] };
      if (u.includes('/ollama/models')) return { ok: true, status: 200, json: async () => [{ name: 'qwen3.8' }] };
      if (u.includes('/sessions?')) return { ok: true, status: 200, json: async () => [
        { id: 's1', title: '会话1', message_count: 1 },
      ]};
      if (u.includes('/messages')) return { ok: true, status: 200, json: async () => [] };
      if (u.includes('/ollama/chat/stream')) return res;
      return { ok: true, status: 200, json: async () => [] };
    }) as any);

    const { unmount } = render(<ChatPanel projectId="p1" agentId="a1" />);
    await waitFor(() => expect(document.querySelector('textarea')).toBeTruthy(), { timeout: 3000 });
    await sendText('触发一次流式回答');

    // 首个 token 到达，流仍在进行（尚未卸载）——确认卸载前确有正常写入，证明观测器在工作
    ctl.push(ev('token', { delta: '正在生成的内容' }));
    await waitFor(() => expect(cacheOf('s1').length).toBeGreaterThan(0), { timeout: 4000 });
    expect(writes.beforeUnmount).toBeGreaterThan(0);

    // ⛔ 关键时序：先卸载，再发 done
    unmount();
    markUnmounted();
    ctl.push(ev('done', { content: '卸载后才到达的完整回答', tool_calls: [] }));
    ctl.close();
    await new Promise(r => setTimeout(r, 800));

    // 有效观测：卸载后对缓存的写入必须为 0 次
    expect(writes.afterUnmount).toBe(0);
  }, 15000);

  it('② 卸载后 alignLocalIdsWithDb 的 fetch 才回来 → 卸载后写入次数必须为 0', async () => {
    (globalThis as any).localStorage.setItem(CACHE_KEY, JSON.stringify({ s1: [] }));
    const encoder = new TextEncoder();
    const fastBody = ev('token', { delta: '快速回答' }) + ev('done', { content: '快速回答', tool_calls: [] });
    let releaseMessages: (() => void) | null = null;
    vi.spyOn(globalThis, 'fetch').mockImplementation((async (url: any) => {
      const u = String(url);
      if (u.includes('/agents/')) return { ok: true, status: 200, json: async () => [{ id: 'a1', name: '测试', role: 'x' }] };
      if (u.includes('/ollama/models')) return { ok: true, status: 200, json: async () => [{ name: 'qwen3.8' }] };
      if (u.includes('/sessions?')) return { ok: true, status: 200, json: async () => [
        { id: 's1', title: '会话1', message_count: 1 },
      ]};
      if (u.includes('/messages')) {
        // ⛔ 挂起这个 fetch，直到测试放行——保证它在卸载之后才 resolve
        await new Promise<void>(r => { releaseMessages = r; });
        return { ok: true, status: 200, json: async () => [
          { id: 99, role: 'assistant', content: 'DB 侧定稿内容' },
        ]};
      }
      if (u.includes('/ollama/chat/stream')) {
        return { ok: true, status: 200,
          body: new ReadableStream({ start(c) { c.enqueue(encoder.encode(fastBody)); c.close(); } }),
          text: async () => fastBody };
      }
      return { ok: true, status: 200, json: async () => [] };
    }) as any);

    const { unmount } = render(<ChatPanel projectId="p1" agentId="a1" />);
    await waitFor(() => expect(document.querySelector('textarea')).toBeTruthy(), { timeout: 3000 });
    await sendText('触发对齐');
    await waitFor(() => expect(document.body.textContent).toContain('快速回答'), { timeout: 4000 });

    unmount();
    markUnmounted();
    const baseline = writes.afterUnmount;

    // 卸载之后才放行挂起的 messages fetch → alignLocalIdsWithDb 的 await 返回
    expect(releaseMessages).toBeTruthy();
    await act(async () => { releaseMessages!(); });
    await new Promise(r => setTimeout(r, 600));

    expect(writes.afterUnmount).toBe(baseline);
    expect(writes.afterUnmount).toBe(0);
  }, 15000);

  it('③ 反向：不卸载时 done 仍照常写缓存（守卫不得误伤正常路径）', async () => {
    (globalThis as any).localStorage.setItem(CACHE_KEY, JSON.stringify({ s1: [] }));
    const encoder = new TextEncoder();
    const body = ev('token', { delta: '正常回答' }) + ev('done', { content: '正常回答', tool_calls: [] });
    vi.spyOn(globalThis, 'fetch').mockImplementation((async (url: any) => {
      const u = String(url);
      if (u.includes('/agents/')) return { ok: true, status: 200, json: async () => [{ id: 'a1', name: '测试', role: 'x' }] };
      if (u.includes('/ollama/models')) return { ok: true, status: 200, json: async () => [{ name: 'qwen3.8' }] };
      if (u.includes('/sessions?')) return { ok: true, status: 200, json: async () => [
        { id: 's1', title: '会话1', message_count: 1 },
      ]};
      if (u.includes('/messages')) return { ok: true, status: 200, json: async () => [] };
      if (u.includes('/ollama/chat/stream')) {
        return { ok: true, status: 200,
          body: new ReadableStream({ start(c) { c.enqueue(encoder.encode(body)); c.close(); } }),
          text: async () => body };
      }
      return { ok: true, status: 200, json: async () => [] };
    }) as any);

    const { unmount } = render(<ChatPanel projectId="p1" agentId="a1" />);
    await waitFor(() => expect(document.querySelector('textarea')).toBeTruthy(), { timeout: 3000 });
    await sendText('正常一问');
    await waitFor(() => expect(document.body.textContent).toContain('正常回答'), { timeout: 4000 });

    // 未卸载 → 缓存必须含完整回答，且卸载前写入次数 > 0
    await waitFor(() => {
      expect(JSON.stringify(cacheOf('s1'))).toContain('正常回答');
    }, { timeout: 3000 });
    expect(writes.beforeUnmount).toBeGreaterThan(0);
    expect(writes.afterUnmount).toBe(0); // 全程未卸载
    unmount();
  }, 15000);
});
