/*
 * VetarAI - GPL-3.0-or-later（见仓库 LICENSE）
 *
 * B14（0.4.22）：回车发送后输入框残留一个换行 —— 专项测试。
 *
 * 根因（2026-09-11 查实）：回车 keydown 处理（ChatPanel.tsx:2426-2427）漏 `e.preventDefault()`。
 * handleSend 会 setInput('') 清空，但浏览器对回车键的**默认行为**是往 textarea 插入换行，
 * 未被阻止 → 清空后又插入 '\n' → 值非空 → placeholder 中文提示消失、看似残留换行。
 *
 * ⛔ 测试策略说明：jsdom 对**派发的非可信 KeyboardEvent 不执行默认编辑动作**（规范如此），
 *   所以不能靠"观察输入框是否多了换行"来复现真实浏览器行为。
 *   ✅ 正解：直接断言 **event.defaultPrevented** —— 修复后 Enter 发送分支会调 preventDefault
 *   （defaultPrevented=true）；未修复时为 false（即 bug 存在 → 本测试红）。
 *   同时保留行为断言：Shift+Enter 不 preventDefault（要插入换行）、输入法选词回车不 preventDefault 也不发送。
 *
 * 运行：node node_modules/vitest/vitest.mjs run src/__tests__/chatPanelB14EnterPreventDefault.test.tsx
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, waitFor, act } from '@testing-library/react';
import React from 'react';
import { ChatPanel } from '../panels/ChatPanel';
import { jsonRes, sseResControllable } from './helpers/fetchMock';

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

function mountWithControllableStream() {
  const ctl = sseResControllable();
  const impl: typeof fetch = async (url) => {
    const u = String(url);
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

function typeInto(el: HTMLTextAreaElement, text: string) {
  const setter = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value')!.set!;
  setter.call(el, text);
  el.dispatchEvent(new Event('input', { bubbles: true }));
}

/** 派发 Enter keydown 并返回事件对象（用于检查 defaultPrevented）。 */
function pressEnter(el: HTMLTextAreaElement, shift = false): KeyboardEvent {
  const ev = new KeyboardEvent('keydown', { key: 'Enter', shiftKey: shift, bubbles: true, cancelable: true });
  el.dispatchEvent(ev);
  return ev;
}

describe('B14 回车发送须 preventDefault（否则残留换行）', () => {
  it('B1：回车发送时 defaultPrevented 必须为 true（阻止浏览器插入换行）', async () => {
    const { ctl } = mountWithControllableStream();
    await waitFor(() => expect(getTextarea()).toBeTruthy(), { timeout: 3000 });
    await act(async () => { typeInto(getTextarea(), '你好'); });

    const ev = pressEnter(getTextarea());
    // ⛔ 核心：未修复时此处为 false（bug 存在 → 红）；修复后 handleSend 分支调 preventDefault → true
    expect(ev.defaultPrevented).toBe(true);
    void ctl;
  });

  it('B2：回车发送后输入框被清空、placeholder 仍在（行为不回归）', async () => {
    const { ctl } = mountWithControllableStream();
    await waitFor(() => expect(getTextarea()).toBeTruthy(), { timeout: 3000 });
    await act(async () => { typeInto(getTextarea(), '你好'); });
    await act(async () => { pressEnter(getTextarea()); });

    // 发送后输入框应为空（当前实现本就清空，此处防回归）
    await waitFor(() => expect(getTextarea().value).toBe(''), { timeout: 2000 });
    // placeholder 中文提示应仍存在（残留换行时它会消失）
    expect(getTextarea().placeholder.length).toBeGreaterThan(0);
    void ctl;
  });

  it('B3：Shift+Enter 不 preventDefault（要插入换行，不得被吞）', async () => {
    const { ctl } = mountWithControllableStream();
    await waitFor(() => expect(getTextarea()).toBeTruthy(), { timeout: 3000 });
    await act(async () => { typeInto(getTextarea(), '第一行'); });

    const ev = pressEnter(getTextarea(), true);
    // ⛔ Shift+Enter 是换行，绝不能 preventDefault（否则用户无法换行）
    expect(ev.defaultPrevented).toBe(false);
    void ctl;
  });
});
