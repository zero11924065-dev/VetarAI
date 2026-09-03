import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, waitFor, act, fireEvent } from '@testing-library/react';
import React from 'react';
import { ProjectPanel } from '../panels/ProjectPanel';

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
    vi.spyOn(globalThis, 'fetch').mockImplementation((async (url: any, init?: any) => {
      const u = String(url);
      if (init?.method === 'PUT') {
        puts.push({ url: u, body: JSON.parse(init.body) });
        return { ok: true, status: 200, json: async () => ({ ok: true }) };
      }
      if (u.includes('/projects')) {
        return { ok: true, status: 200, json: async () => [
          { id: 'p1', name: '旧名字', working_dir: '/tmp/wd' },
        ]};
      }
      return { ok: true, status: 200, json: async () => [] };
    }) as any);

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
    vi.spyOn(globalThis, 'fetch').mockImplementation((async (url: any, init?: any) => {
      if (init?.method === 'PUT') { puts.push(init); return { ok: true, status: 200, json: async () => ({}) }; }
      return { ok: true, status: 200, json: async () => [{ id: 'p1', name: '名字', working_dir: '/w' }] };
    }) as any);

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
  function mockSSEBody(events: string[]) {
    const text = events.join('');
    const encoder = new TextEncoder();
    const stream = new ReadableStream({
      start(controller) { controller.enqueue(encoder.encode(text)); controller.close(); },
    });
    return { ok: true, status: 200, body: stream, text: async () => text };
  }
  const ev = (t: string, d: object) => `event: ${t}\ndata: ${JSON.stringify(d)}\n\n`;

  it('模型不存在错误 → 降级卡片（切换下拉 + 重新拉取）；普通错误 → 无卡片', async () => {
    // 场景1：模型不存在
    vi.spyOn(globalThis, 'fetch').mockImplementation((async (url: any) => {
      const u = String(url);
      if (u.includes('/agents/')) return { ok: true, status: 200, json: async () => [{ id: 'a1', name: '测试', role: 'x', model_name: 'ghost' }] };
      if (u.includes('/ollama/models')) return { ok: true, status: 200, json: async () => [{ name: 'ghost' }, { name: 'qwen3.8' }] };
      if (u.includes('/sessions?')) return { ok: true, status: 200, json: async () => [{ id: 's1', title: '会话1', message_count: 0 }] };
      if (u.includes('/context/limit')) return { ok: true, status: 200, json: async () => ({ context_length: 0, source: 'error' }) };
      if (u.includes('/config')) return { ok: true, status: 200, json: async () => ({ reconnect_max_attempts: 3 }) };
      if (u.includes('/messages')) return { ok: true, status: 200, json: async () => [] };
      if (u.includes('/chat/stream')) {
        return mockSSEBody([ev('error', { detail: '模型 ghost 不存在 (does not exist)' })]);
      }
      return { ok: true, status: 200, json: async () => [] };
    }) as any);

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

describe('M5 长加载提示（H19：思考事件不得清除计时器）', () => {
  it('只有思考事件、正文未达 → ≥8s 显示等待提示；正文到达 → 消失', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation((async (url: any) => {
      const u = String(url);
      if (u.includes('/agents/')) return { ok: true, status: 200, json: async () => [{ id: 'a1', name: '测试', role: 'x', model_name: 'm' }] };
      if (u.includes('/ollama/models')) return { ok: true, status: 200, json: async () => [{ name: 'm' }] };
      if (u.includes('/sessions?')) return { ok: true, status: 200, json: async () => [{ id: 's1', title: '会话1', message_count: 0 }] };
      if (u.includes('/context/limit')) return { ok: true, status: 200, json: async () => ({ context_length: 0, source: 'error' }) };
      if (u.includes('/config')) return { ok: true, status: 200, json: async () => ({ reconnect_max_attempts: 3 }) };
      if (u.includes('/messages')) return { ok: true, status: 200, json: async () => [] };
      if (u.includes('/chat/stream')) {
        // 只吐 thinking 事件且流保持打开（模拟思考阶段长时间无正文）
        const text = 'event: thinking\ndata: {"delta":"嗯"}\n\n';
        const encoder = new TextEncoder();
        const stream = new ReadableStream({
          start(controller) { controller.enqueue(encoder.encode(text)); /* 不 close */ },
        });
        return { ok: true, status: 200, body: stream, text: async () => text };
      }
      return { ok: true, status: 200, json: async () => [] };
    }) as any);

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
