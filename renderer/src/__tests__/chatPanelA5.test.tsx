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
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, waitFor, act } from '@testing-library/react';
import React from 'react';
import { ChatPanel } from '../panels/ChatPanel';

import { jsonRes, sseRes, sseResControllable, tokenEvent, doneEvent } from './helpers/fetchMock';

/**
 * 第 3 批（0.4.16）A5 专项 · 前端：思考中插入新消息。
 *
 * 用户拍板：思考中**直接回车发送**即可（插入新消息），且**停止按钮依然保留**。
 * 语义 = 不打断当前轮，消息进后端队列，模型下一轮读到后自行纠偏或补充。
 *
 * ⛔ 用可控流（sseResControllable）保持"思考中"状态，避免用瞬间结束的流去断言
 * 中间态——那是时序赌博（chatPanelStream 长期 flaky 的根源）。
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

beforeEach(() => { vi.restoreAllMocks(); localStorage.clear(); });

const calls: Array<{ method: string; url: string; body?: any }> = [];

/** 安装桩：返回可控 SSE 流（不自动 close），让 sending 保持 true。 */
function mountStreaming(opts: { injectOk?: boolean } = {}) {
  calls.length = 0;
  const ctl = sseResControllable();
  const impl: typeof fetch = async (url, init) => {
    const u = String(url);
    const method = String(init?.method || 'GET');
    calls.push({ method, url: u, body: init?.body ? JSON.parse(String(init.body)) : undefined });
    if (u.includes('/agents/')) return jsonRes([{ id: 'a1', name: '行政主管', role: 'x' }]);
    if (u.includes('/ollama/models')) return jsonRes([{ name: 'qwen3.6:35b' }]);
    if (u.includes('/sessions?')) return jsonRes([{ id: 's1', title: '会话 1', message_count: 1 }]);
    if (u.includes('/messages')) return jsonRes([]);
    if (u.includes('/inject')) return jsonRes({ ok: opts.injectOk !== false, detail: '已加入' });
    if (u.includes('/ollama/chat/stream')) return ctl.res;
    return jsonRes([]);
  };
  vi.spyOn(globalThis, 'fetch').mockImplementation(impl);
  const r = render(<ChatPanel projectId="p1" agentId="a1" />);
  return { ...r, ctl };
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

async function sendFirstMessage() {
  await waitFor(() => expect(getTextarea()).toBeTruthy(), { timeout: 3000 });
  await act(async () => {
    typeInto(getTextarea(), '第一个问题');
    getTextarea().dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
  });
  // 等流真正开始（thinking 阶段）
  await waitFor(() => expect(calls.some(c => c.url.includes('/ollama/chat/stream'))).toBe(true), { timeout: 3000 });
}

describe('A5 思考中插入新消息 · 前端', () => {
  it('思考中按回车 → 调 /inject 端点，而非新开一条流', async () => {
    const { unmount, ctl } = mountStreaming();
    await sendFirstMessage();
    ctl.push(tokenEvent('正在思考中'));   // 让流处于"进行中"

    const streamCallsBefore = calls.filter(c => c.url.includes('/ollama/chat/stream')).length;

    await act(async () => {
      typeInto(getTextarea(), '请改为关注性能');
      getTextarea().dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
    });

    await waitFor(() => {
      expect(calls.some(c => c.url.includes('/inject') && c.method === 'POST')).toBe(true);
    }, { timeout: 3000 });

    // ⛔ 关键：不得新开第二条流（A5 是"插入"不是"打断重发"）
    const streamCallsAfter = calls.filter(c => c.url.includes('/ollama/chat/stream')).length;
    expect(streamCallsAfter).toBe(streamCallsBefore);

    // inject 载荷带上新消息内容
    const inj = calls.find(c => c.url.includes('/inject'));
    expect(inj?.body?.content).toBe('请改为关注性能');

    // 输入框已清空（乐观反馈）
    expect(getTextarea().value).toBe('');
    ctl.close();
    unmount();
  });

  it('思考中发送后，用户气泡立即出现在会话里（乐观显示）', async () => {
    const { unmount, ctl } = mountStreaming();
    await sendFirstMessage();
    ctl.push(tokenEvent('思考中'));

    await act(async () => {
      typeInto(getTextarea(), '补充一点要求');
      getTextarea().dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
    });
    await waitFor(() => {
      expect(document.body.textContent).toContain('补充一点要求');
    }, { timeout: 3000 });
    ctl.close();
    unmount();
  });

  it('思考中同时存在「发送」与「停止」两个按钮（用户要求停止按钮保留）', async () => {
    const { unmount, ctl } = mountStreaming();
    await sendFirstMessage();
    ctl.push(tokenEvent('思考中'));

    // ⛔ 两个按钮都是**纯图标**（无文字节点），只能用 data-tip 选择器定位；
    // 初版用 screen.getByText('停止') 必然找不到（按钮里没有"停止"两个字）。
    await waitFor(() => {
      expect(document.querySelector('[data-tip="停止"]')).toBeTruthy();
      expect(document.querySelector('[data-tip*="发送新消息"]')).toBeTruthy();
    }, { timeout: 3000 });
    // 两者必须**同时存在**（用户要求：思考中也能发送，且停止按钮保留）
    const sendBtn = document.querySelector('[data-tip*="发送新消息"]');
    const stopBtn = document.querySelector('[data-tip="停止"]');
    expect(sendBtn).toBeTruthy();
    expect(stopBtn).toBeTruthy();
    expect(sendBtn).not.toBe(stopBtn);
    ctl.close();
    unmount();
  });

  it('思考中无文本时发送按钮禁用（与正常发送同一判据）', async () => {
    const { unmount, ctl } = mountStreaming();
    await sendFirstMessage();
    ctl.push(tokenEvent('思考中'));

    await waitFor(() => {
      const b = document.querySelector('[data-tip*="发送新消息"]') as HTMLButtonElement | null;
      return expect(b && b.disabled).toBe(true);
    }, { timeout: 3000 });

    await act(async () => { typeInto(getTextarea(), '有内容了'); });
    await waitFor(() => {
      const b = document.querySelector('[data-tip*="发送新消息"]') as HTMLButtonElement | null;
      return expect(b && b.disabled).toBe(false);
    }, { timeout: 3000 });
    ctl.close();
    unmount();
  });

  it('非思考中（正常态）回车仍是普通发送，不调 inject', async () => {
    const { unmount } = mountStreaming();
    await waitFor(() => expect(getTextarea()).toBeTruthy(), { timeout: 3000 });
    // 尚未发送任何消息 → sending=false
    await act(async () => {
      typeInto(getTextarea(), '普通一条消息');
      getTextarea().dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
    });
    await waitFor(() => {
      expect(calls.some(c => c.url.includes('/ollama/chat/stream'))).toBe(true);
    }, { timeout: 3000 });
    expect(calls.some(c => c.url.includes('/inject'))).toBe(false);
    unmount();
  });
});
