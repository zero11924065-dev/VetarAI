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

// H16 回归：切换会话时进行中的流式内容不丢。
// checkpoint-055 新策略：DB 为权威源 + 本地未落盘气泡（local_* id / DB 缺失 id）合并保留——
// 既修"残缺缓存屏蔽 DB 历史"（切回丢消息），又保证进行中的流式内容不被旧历史覆盖。
if (typeof (globalThis as any).localStorage === 'undefined') {
  (globalThis as any).localStorage = {
    _d: {} as Record<string, string>,
    getItem(k: string) { return this._d[k] ?? null; },
    setItem(k: string, v: string) { this._d[k] = String(v); },
    removeItem(k: string) { delete this._d[k]; },
    clear() { this._d = {}; },
  };
}

function mockSSEBody(events: string[]) {
  const text = events.join('');
  const encoder = new TextEncoder();
  const stream = new ReadableStream({
    start(controller) {
      controller.enqueue(encoder.encode(text));
      controller.close();
    },
  });
  return { ok: true, status: 200, body: stream, text: async () => text };
}

const ev = (t: string, d: object) => `event: ${t}\ndata: ${JSON.stringify(d)}\n\n`;

beforeEach(() => {
  vi.restoreAllMocks();
  localStorage.clear();
});

describe('H16 切换会话缓存优先（防覆盖进行中流式内容）', () => {
  it('本地缓存有该会话消息时，切换不从 API 加载（不覆盖）', async () => {
    // 预置缓存：s2 已有一条进行中流式内容（模拟委派流进行中尚未落盘）
    localStorage.setItem('subagent_messages_v4', JSON.stringify({
      s1: [{ id: 'm1', role: 'user', content: '第一条' }],
      s2: [{ id: 'm2', role: 'assistant', content: '委派进行中…（流式）' }],
    }));

    let messagesApiCalled = 0;
    vi.spyOn(globalThis, 'fetch').mockImplementation((async (url: any) => {
      const u = String(url);
      if (u.includes('/agents/')) return { ok: true, status: 200, json: async () => [{ id: 'a1', name: '测试', role: 'x' }] };
      if (u.includes('/ollama/models')) return { ok: true, status: 200, json: async () => [{ name: 'qwen3.8' }] };
      if (u.includes('/sessions?')) return { ok: true, status: 200, json: async () => [
        { id: 's1', title: '会话1', message_count: 1 },
        { id: 's2', title: '会话2', message_count: 1 },
      ]};
      if (u.includes('/messages')) {
        messagesApiCalled += 1;
        // 后端旧数据（委派未落盘）——若被加载会覆盖进行中的流式内容
        return { ok: true, status: 200, json: async () => [{ id: 'old', role: 'user', content: '旧数据' }] };
      }
      return { ok: true, status: 200, json: async () => [] };
    }) as any);

    const { unmount } = render(<ChatPanel projectId="p1" agentId="a1" />);

    // 等初始化完成（默认选中第一个会话）
    await waitFor(() => {
      const sel = document.querySelector('select') as HTMLSelectElement;
      expect(sel).toBeTruthy();
    }, { timeout: 3000 });

    // 切换到 s2（缓存中有进行中内容）
    await act(async () => {
      const sel = document.querySelector('select') as HTMLSelectElement;
      const setter = Object.getOwnPropertyDescriptor(window.HTMLSelectElement.prototype, 'value')!.set!;
      setter.call(sel, 's2');
      sel.dispatchEvent(new Event('change', { bubbles: true }));
    });

    // 断言（新策略）：DB 历史（旧数据）与本地未落盘流式气泡（委派进行中）合并同屏，互不覆盖
    await waitFor(() => {
      expect(screen.getByText(/委派进行中…（流式）/)).toBeTruthy();
    }, { timeout: 3000 });
    expect(screen.getByText(/旧数据/)).toBeTruthy();
    // 新策略一律以 DB 为准合并加载，消息 API 必被调用
    expect(messagesApiCalled).toBeGreaterThan(0);

    unmount();
  });

  it('缓存为空时仍从 API 加载历史（正常路径不受影响）', async () => {
    localStorage.setItem('subagent_messages_v4', JSON.stringify({}));

    let messagesApiCalled = 0;
    vi.spyOn(globalThis, 'fetch').mockImplementation((async (url: any) => {
      const u = String(url);
      if (u.includes('/agents/')) return { ok: true, status: 200, json: async () => [{ id: 'a1', name: '测试', role: 'x' }] };
      if (u.includes('/ollama/models')) return { ok: true, status: 200, json: async () => [{ name: 'qwen3.8' }] };
      if (u.includes('/sessions?')) return { ok: true, status: 200, json: async () => [
        { id: 's1', title: '会话1', message_count: 1 },
        { id: 's2', title: '会话2', message_count: 2 },
      ]};
      if (u.includes('/messages')) {
        messagesApiCalled += 1;
        return { ok: true, status: 200, json: async () => [{ id: 'h1', role: 'user', content: '历史消息' }] };
      }
      return { ok: true, status: 200, json: async () => [] };
    }) as any);

    const { unmount } = render(<ChatPanel projectId="p1" agentId="a1" />);
    await waitFor(() => { expect(document.querySelector('select')).toBeTruthy(); }, { timeout: 3000 });

    await act(async () => {
      const sel = document.querySelector('select') as HTMLSelectElement;
      const setter = Object.getOwnPropertyDescriptor(window.HTMLSelectElement.prototype, 'value')!.set!;
      setter.call(sel, 's2');
      sel.dispatchEvent(new Event('change', { bubbles: true }));
    });

    await waitFor(() => { expect(screen.getByText('历史消息')).toBeTruthy(); }, { timeout: 3000 });
    expect(messagesApiCalled).toBeGreaterThan(0);
    unmount();
  });
});
