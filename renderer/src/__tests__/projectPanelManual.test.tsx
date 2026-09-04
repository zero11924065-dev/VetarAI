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
import { ProjectPanel } from '../panels/ProjectPanel';

// localStorage 兜底（模块顶层 getApiBase 会在导入时执行）
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
  delete (window as any).subagent; // 模拟 preload 未注入（旧 Electron 主进程场景）
});

describe('B03 回归：非 Electron 环境创建项目走内联输入（2026-08-28 修复 prompt() 报错）', () => {
  it('点击新建 → 展开内联目录输入框，不调用 prompt()', async () => {
    const promptSpy = vi.spyOn(window, 'prompt').mockImplementation(() => {
      throw new Error('prompt() should never be called');
    });
    vi.spyOn(globalThis, 'fetch').mockImplementation((async (url: any) => {
      const u = String(url);
      if (u.includes('/projects')) return { ok: true, status: 200, json: async () => [] };
      return { ok: true, status: 200, json: async () => [] };
    }) as any);

    render(<ProjectPanel onSelect={() => {}} />);
    await act(async () => { screen.getByText(/新建项目/).click(); });

    // 内联输入框出现（手动目录输入模式）
    await waitFor(() => {
      expect(screen.getByPlaceholderText(/Users\/you\/projects\/demo/)).toBeTruthy();
    }, { timeout: 2000 });
    expect(promptSpy).not.toHaveBeenCalled();
  });

  it('内联输入留空点取消 → 收起输入框', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation((async () => ({
      ok: true, status: 200, json: async () => [],
    })) as any);

    render(<ProjectPanel onSelect={() => {}} />);
    await act(async () => { screen.getByText(/新建项目/).click(); });
    await waitFor(() => expect(screen.getByText('取消')).toBeTruthy(), { timeout: 2000 });
    await act(async () => { screen.getByText('取消').click(); });
    await waitFor(() => {
      expect(screen.queryByPlaceholderText(/Users\/you\/projects\/demo/)).toBeFalsy();
    }, { timeout: 2000 });
  });
});
