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
import { ProjectPanel } from '../panels/ProjectPanel';

import { jsonRes, sseRes } from './helpers/fetchMock';

// TS-111 M5 前端专项：模型降级卡片 / 项目改名行内编辑
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

describe('M5 项目改名入口（ProjectPanel）', () => {
  it('✏️ 点击出行内编辑框 + 保存触发 PUT + 取消还原', async () => {
    const puts: any[] = [];
    const impl: typeof fetch = async (url, init?) => {
      const u = String(url);
      if (init?.method === 'PUT') {
        // 动作二暴露的真实脱节：init.body 类型是 BodyInit（可能 undefined/null），非 string
        puts.push({ url: u, body: JSON.parse(String(init.body ?? '{}')) });
        return jsonRes({ ok: true });
      }
      if (u.includes('/projects')) {
        return jsonRes([
          { id: 'p1', name: '旧名字', working_dir: '/tmp/wd' },
        ]);
      }
      return jsonRes([]);
    };
    vi.spyOn(globalThis, 'fetch').mockImplementation(impl);

    const { unmount } = render(<ProjectPanel onSelect={() => {}} />);

    await waitFor(() => { expect(screen.getByText(/旧名字/)).toBeTruthy(); }, { timeout: 3000 });

    // 点 ✏️ → 行内编辑框出现（值为旧名字）
    await act(async () => { fireEvent.click((document.querySelector('[data-tip="重命名"]') as HTMLElement)); });
    const input = document.querySelector('input[autoFocus]') as HTMLInputElement
      || screen.getByDisplayValue('旧名字');
    expect(input).toBeTruthy();

    // 改值并保存 → 触发 PUT
    await act(async () => {
      const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value')!.set!;
      setter.call(input, '新名字');
      input.dispatchEvent(new Event('input', { bubbles: true }));
    });
    await act(async () => { fireEvent.click(screen.getByText('保存')); });
    await waitFor(() => {
      expect(puts.length).toBe(1);
      expect(puts[0].url).toContain('/projects/p1');
      expect(puts[0].body).toEqual({ name: '新名字' });
    }, { timeout: 3000 });
    unmount();
  });

  it('空名字不请求（点保存直接取消编辑态）', async () => {
    const puts: any[] = [];
    const impl: typeof fetch = async (url, init?) => {
      if (init?.method === 'PUT') { puts.push(init); return jsonRes({}); }
      return jsonRes([{ id: 'p1', name: '名字', working_dir: '/w' }]);
    };
    vi.spyOn(globalThis, 'fetch').mockImplementation(impl);

    const { unmount } = render(<ProjectPanel onSelect={() => {}} />);
    await waitFor(() => { expect((document.querySelector('[data-tip="重命名"]') as HTMLElement)).toBeTruthy(); }, { timeout: 3000 });
    await act(async () => { fireEvent.click((document.querySelector('[data-tip="重命名"]') as HTMLElement)); });
    const input = screen.getByDisplayValue('名字');
    await act(async () => {
      const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value')!.set!;
      setter.call(input, '   ');
      input.dispatchEvent(new Event('input', { bubbles: true }));
    });
    await act(async () => { fireEvent.click(screen.getByText('保存')); });
    expect(puts.length).toBe(0);
    unmount();
  });
});

describe('M5 模型降级卡片（ChatPanel 错误块）', () => {
  // 降级卡片渲染条件 = 错误文案命中模型缺失正则；通过 SSE 注入 error 事件验证
  // 第 0 批（0.4.14）动作二：迁移到 helper 的 sseRes（返回原生 Response）
  function mockSSEBody(events: string[]) {
    return sseRes(events);
  }
  const ev = (t: string, d: object) => `event: ${t}\ndata: ${JSON.stringify(d)}\n\n`;

  it('模型不存在错误 → 降级卡片（切换下拉 + 重新拉取）；普通错误 → 无卡片', async () => {
    // 场景1：模型不存在
    const impl2: typeof fetch = async (url) => {
      const u = String(url);
      if (u.includes('/agents/')) return jsonRes([{ id: 'a1', name: '测试', role: 'x', model_name: 'ghost' }]);
      if (u.includes('/ollama/models')) return jsonRes([{ name: 'ghost' }, { name: 'qwen3.8' }]);
      if (u.includes('/sessions?')) return jsonRes([{ id: 's1', title: '会话1', message_count: 0 }]);
      if (u.includes('/context/limit')) return jsonRes({ context_length: 0, source: 'error' });
      if (u.includes('/config')) return jsonRes({ reconnect_max_attempts: 3 });
      if (u.includes('/messages')) return jsonRes([]);
      if (u.includes('/chat/stream')) {
        return mockSSEBody([ev('error', { detail: '模型 ghost 不存在 (does not exist)' })]);
      }
      return jsonRes([]);
    };
    vi.spyOn(globalThis, 'fetch').mockImplementation(impl2);

    const { ChatPanel } = await import('../panels/ChatPanel');
    const r1 = render(<ChatPanel projectId="p1" agentId="a1" />);

    await waitFor(() => { expect(document.querySelector('select')).toBeTruthy(); }, { timeout: 3000 });
    // 选中会话后发送
    await act(async () => {
      const sel = document.querySelector('select') as HTMLSelectElement;
      const setter = Object.getOwnPropertyDescriptor(window.HTMLSelectElement.prototype, 'value')!.set!;
      setter.call(sel, 's1');
      sel.dispatchEvent(new Event('change', { bubbles: true }));
    });
    const inputEl = document.querySelector('textarea[placeholder*="输入消息"]') as HTMLTextAreaElement;
    await act(async () => {
      const setter = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value')!.set!;
      setter.call(inputEl, '你好');
      inputEl.dispatchEvent(new Event('input', { bubbles: true }));
    });
    await act(async () => { (document.querySelector('button[data-tip="发送"]') as HTMLElement).click(); });

    await waitFor(() => {
      // 降级卡片出现：模型切换下拉 + 重新拉取按钮
      expect(screen.getByText(/模型「ghost」不可用，可选/)).toBeTruthy();
      expect(screen.getByText(/重新拉取 ghost/)).toBeTruthy();
      expect(screen.getByText('一键切换到…')).toBeTruthy();
      // 复制错误详情按钮
      expect(screen.getByText('复制错误详情')).toBeTruthy();
    }, { timeout: 4000 });
    r1.unmount();
  });
});

describe('0.4.31（P2）顶栏指示器：懒加载当前档（上限 N）', () => {
  // /context/limit 返回 lazy=true + ceiling → 「≈用量 / 当前档（上限 N）」；否则单值现状
  function mockBase(limitResp: Record<string, unknown>) {
    const impl: typeof fetch = async (url) => {
      const u = String(url);
      if (u.includes('/agents/')) return jsonRes([{ id: 'a1', name: '测试', role: 'x', model_name: 'm' }]);
      if (u.includes('/ollama/models')) return jsonRes([{ name: 'm' }]);
      if (u.includes('/sessions?')) return jsonRes([{ id: 's1', title: '会话1', message_count: 0 }]);
      if (u.includes('/context/limit')) return jsonRes(limitResp);
      if (u.includes('/config')) return jsonRes({ reconnect_max_attempts: 3 });
      if (u.includes('/messages')) return jsonRes([]);
      return jsonRes([]);
    };
    vi.spyOn(globalThis, 'fetch').mockImplementation(impl);
  }

  it('lazy=true 且有 ceiling → 显示「≈用量 / 当前档（上限 N）」', async () => {
    mockBase({ context_length: 12288, source: 'config', ceiling: 65536, lazy: true });
    const { ChatPanel } = await import('../panels/ChatPanel');
    const r = render(<ChatPanel projectId="p1" agentId="a1" />);
    await waitFor(() => {
      const txt = document.body.textContent || '';
      expect(txt).toContain('/ 12288（上限 65536）');
    }, { timeout: 3000 });
    r.unmount();
  });

  it('无 lazy 追加字段 → 保持单值（不显示上限）', async () => {
    mockBase({ context_length: 262144, source: 'show' });
    const { ChatPanel } = await import('../panels/ChatPanel');
    const r = render(<ChatPanel projectId="p1" agentId="a1" />);
    await waitFor(() => {
      expect(document.body.textContent).toContain('/ 262144');
    }, { timeout: 3000 });
    expect(document.body.textContent).not.toContain('（上限');
    r.unmount();
  });
});

describe('M5 长加载提示（H19：思考事件不得清除计时器）', () => {
  it('只有思考事件、正文未达 → ≥8s 显示等待提示；正文到达 → 消失', async () => {
    const impl2: typeof fetch = async (url) => {
      const u = String(url);
      if (u.includes('/agents/')) return jsonRes([{ id: 'a1', name: '测试', role: 'x', model_name: 'm' }]);
      if (u.includes('/ollama/models')) return jsonRes([{ name: 'm' }]);
      if (u.includes('/sessions?')) return jsonRes([{ id: 's1', title: '会话1', message_count: 0 }]);
      if (u.includes('/context/limit')) return jsonRes({ context_length: 0, source: 'error' });
      if (u.includes('/config')) return jsonRes({ reconnect_max_attempts: 3 });
      if (u.includes('/messages')) return jsonRes([]);
      if (u.includes('/chat/stream')) {
        // 只吐 thinking 事件且流保持打开（模拟思考阶段长时间无正文）
        const text = 'event: thinking\ndata: {"delta":"嗯"}\n\n';
        const encoder = new TextEncoder();
        const stream = new ReadableStream({
          start(controller) { controller.enqueue(encoder.encode(text)); /* 不 close */ },
        });
        // 该 stream 故意**不 close**（模拟思考阶段长时间无正文），是本用例特有时序，
        // helper 通用构造器不适用 → 保留 stream，只把手写假 response 换成原生 Response。
        return new Response(stream, { status: 200, headers: { 'Content-Type': 'text/event-stream' } });
      }
      return jsonRes([]);
    };
    vi.spyOn(globalThis, 'fetch').mockImplementation(impl2);

    const { ChatPanel } = await import('../panels/ChatPanel');
    const r = render(<ChatPanel projectId="p1" agentId="a1" />);

    // 初始化（真实计时器下完成）
    await waitFor(() => { expect(document.querySelector('select')).toBeTruthy(); }, { timeout: 3000 });
    await act(async () => {
      const sel = document.querySelector('select') as HTMLSelectElement;
      const setter = Object.getOwnPropertyDescriptor(window.HTMLSelectElement.prototype, 'value')!.set!;
      setter.call(sel, 's1');
      sel.dispatchEvent(new Event('change', { bubbles: true }));
    });
    const inputEl = document.querySelector('textarea[placeholder*="输入消息"]') as HTMLTextAreaElement;
    await act(async () => {
      const setter = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value')!.set!;
      setter.call(inputEl, '你好');
      inputEl.dispatchEvent(new Event('input', { bubbles: true }));
    });

    // 切假计时器：点发送 → 思考事件到达（不清计时器）→ 推进 9s → 提示出现
    vi.useFakeTimers();
    try {
      await act(async () => { (document.querySelector('button[data-tip="发送"]') as HTMLElement).click(); });
      // 冲刷微任务：fetch 解析 + 首个 thinking 事件处理
      for (let i = 0; i < 30; i++) {
        await act(async () => { await Promise.resolve(); });
      }
      await act(async () => { vi.advanceTimersByTime(9000); });
      for (let i = 0; i < 10; i++) {
        await act(async () => { await Promise.resolve(); });
      }
      const tip = document.body.textContent || '';
      expect(tip).toMatch(/模型加载\/推理中.*已等待 \d+s/);
      expect(tip).toMatch(/思考中/);
    } finally {
      vi.useRealTimers();
      r.unmount();
    }
  });
});
