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
import { TaskPanel } from '../panels/TaskPanel';

// TS-108 M3-2：任务状态面板测试（四种状态徽标 + 失败任务重试按钮 + 重试请求）
if (typeof (globalThis as any).localStorage === 'undefined') {
  (globalThis as any).localStorage = {
    _d: {} as Record<string, string>,
    getItem(k: string) { return this._d[k] ?? null; },
    setItem(k: string, v: string) { this._d[k] = String(v); },
    removeItem(k: string) { delete this._d[k]; },
    clear() { this._d = {}; },
  };
}

const TASKS = [
  { id: 't1', target_agent_name: '文员', task: '整理会议纪要并写入 notes.md', status: 'done', report: { summary: '已整理' } },
  { id: 't2', target_agent_name: '研究员', task: '调研竞品', status: 'running' },
  { id: 't3', target_agent_name: '数据员', task: '清洗数据', status: 'queued' },
  { id: 't4', target_agent_name: '翻译员', task: '翻译文档', status: 'failed', fail_reason: '交卷格式两次校验未通过' },
];

beforeEach(() => {
  vi.restoreAllMocks();
  localStorage.clear();
});

describe('TaskPanel 任务状态面板', () => {
  it('渲染四种状态徽标 + 失败任务有重试按钮 + 摘要展示', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation((async (url: any, init?: any) => {
      const u = String(url);
      if (u.includes('/tasks')) return { ok: true, status: 200, json: async () => TASKS };
      return { ok: true, status: 200, json: async () => ({}) };
    }) as any);

    render(<TaskPanel projectId="p1" />);

    await waitFor(() => {
      // 状态徽标文字（emoji 已换为 SVG 图标，文字标签不变）
      expect(screen.getByText('完成')).toBeTruthy();
      expect(screen.getByText('进行中')).toBeTruthy();
      expect(screen.getByText('等待中')).toBeTruthy();
      expect(screen.getByText('异常')).toBeTruthy();
    }, { timeout: 3000 });

    // 目标与摘要
    expect(screen.getByText('文员')).toBeTruthy();
    expect(screen.getByText(/已整理/)).toBeTruthy();
    // 失败原因 + 仅失败任务有重试按钮
    expect(screen.getByText(/交卷格式两次校验未通过/)).toBeTruthy();
    const retryBtns = screen.getAllByText('重试');
    expect(retryBtns.length).toBe(1);
  });

  it('点击重试发起 POST 请求并刷新列表', async () => {
    const calls: string[] = [];
    vi.spyOn(globalThis, 'fetch').mockImplementation((async (url: any, init?: any) => {
      const u = String(url);
      calls.push(`${init?.method || 'GET'} ${u}`);
      if (init?.method === 'POST' && u.includes('/retry')) {
        return { ok: true, status: 200, json: async () => ({ new_task_id: 't5', result: { ok: true } }) };
      }
      if (u.includes('/tasks')) return { ok: true, status: 200, json: async () => TASKS };
      return { ok: true, status: 200, json: async () => ({}) };
    }) as any);

    render(<TaskPanel projectId="p1" />);

    await waitFor(() => {
      expect(screen.getAllByText('重试').length).toBe(1);
    }, { timeout: 3000 });

    await act(async () => {
      fireEvent.click(screen.getByText('重试'));
    });

    await waitFor(() => {
      expect(calls.some(c => c.startsWith('POST') && c.includes('/tasks/t4/retry'))).toBe(true);
    }, { timeout: 3000 });
    // 重试成功提示出现
    await waitFor(() => {
      expect(screen.getByText(/重试完成：子任务成功交卷/)).toBeTruthy();
    }, { timeout: 3000 });
  });

  it('空列表显示占位文案', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation((async () =>
      ({ ok: true, status: 200, json: async () => [] })) as any);

    render(<TaskPanel projectId="p1" />);
    await waitFor(() => {
      expect(screen.getByText('暂无委派任务')).toBeTruthy();
    }, { timeout: 3000 });
  });
});

// TS-114（3.25）：running 任务停止按钮
describe('TaskPanel 停止按钮（TS-114 3.25）', () => {
  const TASKS_WITH_RUNNING = [
    { id: 't1', target_agent_name: '文员', task: '整理会议纪要', status: 'done', report: { summary: '已整理' } },
    { id: 't2', target_agent_name: '研究员', task: '调研竞品', status: 'running' },
    { id: 't3', target_agent_name: '翻译员', task: '翻译文档', status: 'failed', fail_reason: '交卷格式两次校验未通过' },
  ];

  it('running 任务显示停止按钮（failed/done 不显示）', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation((async (url: any) => {
      const u = String(url);
      if (u.includes('/tasks')) return { ok: true, status: 200, json: async () => TASKS_WITH_RUNNING };
      return { ok: true, status: 200, json: async () => ({}) };
    }) as any);

    render(<TaskPanel projectId="p1" />);
    await waitFor(() => {
      expect(screen.getByText('进行中')).toBeTruthy();
    }, { timeout: 3000 });

    const stopBtns = screen.getAllByText('停止');
    expect(stopBtns.length).toBe(1); // 仅 running 任务
    // failed/done 没有停止按钮
    expect(screen.getAllByText('重试').length).toBe(1);
  });

  it('点击停止 → POST /tasks/{id}/stop → 刷新任务列表', async () => {
    const calls: string[] = [];
    let listCalls = 0;
    vi.spyOn(globalThis, 'fetch').mockImplementation((async (url: any, init?: any) => {
      const u = String(url);
      calls.push(`${init?.method || 'GET'} ${u}`);
      if (u.includes('/stop')) {
        return { ok: true, status: 200, json: async () => ({ ok: true, detail: '已请求停止' }) };
      }
      if (u.includes('/tasks')) {
        listCalls += 1;
        return { ok: true, status: 200, json: async () => TASKS_WITH_RUNNING };
      }
      return { ok: true, status: 200, json: async () => ({}) };
    }) as any);

    render(<TaskPanel projectId="p1" />);
    await waitFor(() => {
      expect(screen.getAllByText('停止').length).toBe(1);
    }, { timeout: 3000 });
    const before = listCalls;
    fireEvent.click(screen.getByText('停止'));
    await waitFor(() => {
      expect(calls.some(c => c.startsWith('POST') && c.includes('/tasks/t2/stop'))).toBe(true);
      expect(listCalls).toBeGreaterThan(before); // 点击后触发一次刷新
    }, { timeout: 3000 });
  });

  it('停止端点 400（任务已结束）→ 显示停止失败提示', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation((async (url: any, init?: any) => {
      const u = String(url);
      if (u.includes('/stop')) {
        return { ok: false, status: 400, json: async () => ({ detail: '任务已结束（done），无需停止' }) };
      }
      if (u.includes('/tasks')) {
        return { ok: true, status: 200, json: async () => TASKS_WITH_RUNNING };
      }
      return { ok: true, status: 200, json: async () => ({}) };
    }) as any);

    render(<TaskPanel projectId="p1" />);
    await waitFor(() => {
      expect(screen.getAllByText('停止').length).toBe(1);
    }, { timeout: 3000 });
    fireEvent.click(screen.getByText('停止'));
    await waitFor(() => {
      expect(screen.getByText(/停止失败/)).toBeTruthy();
    }, { timeout: 3000 });
  });
});
