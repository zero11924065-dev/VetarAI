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
import { render, waitFor, act } from '@testing-library/react';
import React from 'react';
import { ChatPanel } from '../panels/ChatPanel';

import { jsonRes } from './helpers/fetchMock';

// 0.4.27：顶栏「⋯ 更多操作」菜单遮挡根治的回归锁。
// 事故：菜单 absolute 挂在顶栏内，被顶栏 overflow:hidden（0.4.0 为治原生 select
// 文字溢出所加）裁成约 6px 细条——用户实测看不到也无法点击。
// 修复 = createPortal 到 document.body + fixed 锚定按钮矩形（先例：TipPortal）。

if (typeof (globalThis as any).localStorage === 'undefined') {
  (globalThis as any).localStorage = {
    _d: {} as Record<string, string>,
    getItem(k: string) { return this._d[k] ?? null; },
    setItem(k: string, v: string) { this._d[k] = String(v); },
    removeItem(k: string) { delete this._d[k]; },
    clear() { this._d = {}; },
  };
}

beforeEach(() => {
  vi.restoreAllMocks();
  localStorage.clear();
});

function mockBase() {
  const impl: typeof fetch = async (url, opts) => {
    const u = String(url);
    if (u.includes('/agents/')) return jsonRes([{ id: 'a1', name: '测试Agent', role: '工程师' }]);
    if (u.includes('/ollama/models')) return jsonRes([{ name: 'qwen3.8' }]);
    if (u.includes('/sessions?')) return jsonRes([{ id: 's1', title: '会话1', message_count: 2 }]);
    if (u.includes('/messages')) return jsonRes([{ id: 1, role: 'user', content: '你好' }]);
    if (u.includes('/summarize') && opts?.method === 'POST') {
      return jsonRes({ ok: true, summary: '总结内容', saved_file: '/tmp/x/sum.md' });
    }
    return jsonRes([]);
  };
  return vi.spyOn(globalThis, 'fetch').mockImplementation(impl);
}

// 选中会话 s1 并打开「⋯ 更多操作」菜单，返回菜单卡片元素
async function openMoreMenu(): Promise<HTMLElement> {
  await waitFor(() => {
    const sel = document.querySelector('select') as HTMLSelectElement;
    expect(sel).toBeTruthy();
    expect(Array.from(sel.options).some(o => o.value === 's1')).toBe(true);
  }, { timeout: 3000 });
  await act(async () => {
    const sel = document.querySelector('select') as HTMLSelectElement;
    const setter = Object.getOwnPropertyDescriptor(window.HTMLSelectElement.prototype, 'value')!.set!;
    setter.call(sel, 's1');
    sel.dispatchEvent(new Event('change', { bubbles: true }));
  });
  await act(async () => {
    (document.querySelector('button[data-tip="更多操作"]') as HTMLElement).click();
  });
  let card: HTMLElement | null = null;
  await waitFor(() => {
    const item = document.querySelector('button[data-tip*="生成会话总结"]') as HTMLElement | null;
    expect(item).toBeTruthy();
    card = item!.closest('div.ui-pop-in') as HTMLElement | null;
    expect(card).toBeTruthy();
  }, { timeout: 3000 });
  return card!;
}

describe('0.4.27 更多菜单遮挡根治', () => {
  it('M1 菜单经 portal 渲染到 body：fixed 定位、脱离顶栏裁剪容器', async () => {
    mockBase();
    const { unmount } = render(<ChatPanel projectId="p1" agentId="a1" />);
    const card = await openMoreMenu();

    // fixed 定位 + 高层级：脱离顶栏 overflow:hidden 的裁剪（原缺陷核心）
    expect(card.style.position).toBe('fixed');
    expect(card.style.zIndex).toBe('1201');
    // 不得再挂在 .chat-topbar-scope 内（该容器 overflow:hidden + container-type，
    // 既是裁剪源，也是 fixed/absolute 的包含块陷阱）
    expect(card.closest('.chat-topbar-scope')).toBeNull();
    unmount();
  });

  it('M2 菜单项齐全；点击菜单项后菜单关闭且动作生效（portal 内事件正常）', async () => {
    const spy = mockBase();
    const { unmount } = render(<ChatPanel projectId="p1" agentId="a1" />);
    const card = await openMoreMenu();

    // 五个菜单项齐全（收纳清单：总结/导出/单元归档/重命名/删除）
    expect(card.querySelector('button[data-tip*="生成会话总结"]')).toBeTruthy();
    expect(card.querySelector('button[data-tip="导出会话为 Markdown"]')).toBeTruthy();
    expect(card.querySelector('button[data-tip*="单元归档"]')).toBeTruthy();
    expect(card.querySelector('button[data-tip="重命名"]')).toBeTruthy();
    expect(card.querySelector('button[data-tip="删除"]')).toBeTruthy();

    await act(async () => {
      (card.querySelector('button[data-tip*="生成会话总结"]') as HTMLElement).click();
    });
    // 点击后菜单关闭（portal 内 React 事件委派正常）
    await waitFor(() => {
      expect(document.querySelector('button[data-tip*="生成会话总结"]')).toBeNull();
    }, { timeout: 3000 });
    // 且动作真实生效
    await waitFor(() => {
      expect(spy.mock.calls.some(c => String(c[0]).includes('/summarize'))).toBe(true);
    }, { timeout: 3000 });
    unmount();
  });
});
