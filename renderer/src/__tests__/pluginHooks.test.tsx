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
import { render, screen, waitFor, act, fireEvent } from '@testing-library/react';
import React from 'react';
import { PluginPanel } from '../panels/PluginPanel';

// checkpoint-049（3.7 手动触发方案）：插件钩子手动触发测试
describe('PluginPanel 钩子手动触发', () => {
  beforeEach(() => { vi.restoreAllMocks(); });

  function mockFetch(triggerResp?: any) {
    return vi.spyOn(globalThis, 'fetch').mockImplementation((async (url: any, opts: any) => {
      const u = String(url);
      if (u.includes('/hooks/on_message') && opts?.method === 'POST') {
        return { ok: true, status: 200, json: async () => triggerResp ?? { plugin: 'test-plugin', hook: 'on_message', result: { prefix: 'done' } } };
      }
      if (u.includes('/plugins')) {
        return { ok: true, status: 200, json: async () => [{ name: 'test-plugin', version: '0.1.0', hooks: ['on_message'], enabled: true }] };
      }
      return { ok: true, status: 200, json: async () => [] };
    }) as any);
  }

  it('展开 Hooks 后每个钩子有"▶ 触发"按钮，点击调端点并展示输出', async () => {
    const spy = mockFetch();
    const { unmount } = render(<PluginPanel />);
    await waitFor(() => expect(screen.getByText(/Hooks \(1\)/)).toBeTruthy(), { timeout: 3000 });

    // 展开钩子列表
    await act(async () => { screen.getByText(/Hooks \(1\)/).click(); });
    const triggerBtn = await screen.findByText('触发');
    // 手动触发方案说明文案（不再声称自动调用）
    expect(screen.getByText(/Hook 触发方式：手动触发/)).toBeTruthy();

    await act(async () => { triggerBtn.click(); });
    await waitFor(() => {
      const call = spy.mock.calls.find(c => String(c[0]).includes('/hooks/on_message') && (c[1] as any)?.method === 'POST');
      expect(call).toBeTruthy();
    }, { timeout: 3000 });
    await waitFor(() => {
      expect(screen.getByText(/"prefix": "done"/)).toBeTruthy();
    }, { timeout: 3000 });
    unmount();
  });

  it('钩子执行出错时展示错误输出', async () => {
    mockFetch({ plugin: 'test-plugin', hook: 'on_message', error: 'boom' });
    const { unmount } = render(<PluginPanel />);
    await waitFor(() => expect(screen.getByText(/Hooks \(1\)/)).toBeTruthy(), { timeout: 3000 });
    await act(async () => { screen.getByText(/Hooks \(1\)/).click(); });
    const triggerBtn = await screen.findByText('触发');
    await act(async () => { triggerBtn.click(); });
    await waitFor(() => {
      expect(screen.getByText(/执行出错：boom/)).toBeTruthy();
    }, { timeout: 3000 });
    unmount();
  });

  it('禁用的插件显示"启用"开关按钮', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation((async (url: any) => {
      const u = String(url);
      if (u.includes('/plugins')) {
        return { ok: true, status: 200, json: async () => [{ name: 'test-plugin', version: '0.1.0', hooks: ['on_message'], enabled: false }] };
      }
      return { ok: true, status: 200, json: async () => [] };
    }) as any);
    const { unmount } = render(<PluginPanel />);
    await waitFor(() => expect(screen.getByText('启用')).toBeTruthy(), { timeout: 3000 });
    unmount();
  });

  it('点击启用/禁用开关调用 toggle 端点并更新状态', async () => {
    const spy = vi.spyOn(globalThis, 'fetch').mockImplementation((async (url: any, opts: any) => {
      const u = String(url);
      if (u.includes('/toggle') && opts?.method === 'POST') {
        return { ok: true, status: 200, json: async () => ({}) };
      }
      if (u.includes('/plugins')) {
        return { ok: true, status: 200, json: async () => [{ name: 'test-plugin', version: '0.1.0', hooks: ['on_message'], enabled: true }] };
      }
      return { ok: true, status: 200, json: async () => [] };
    }) as any);
    const { unmount } = render(<PluginPanel />);
    // 初始为启用态，应显示"禁用"按钮
    const toggleBtn = await screen.findByText('禁用');
    await act(async () => { toggleBtn.click(); });
    await waitFor(() => {
      const call = spy.mock.calls.find(c => String(c[0]).includes('/toggle') && (c[1] as any)?.method === 'POST');
      expect(call).toBeTruthy();
      const body = JSON.parse((call![1] as any).body);
      expect(body.enabled).toBe(false);
    }, { timeout: 3000 });
    // 切换后应显示"启用"按钮
    await waitFor(() => expect(screen.getByText('启用')).toBeTruthy(), { timeout: 3000 });
    unmount();
  });
});
