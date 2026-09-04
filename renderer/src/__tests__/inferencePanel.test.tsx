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
import { InferencePanel } from '../panels/InferencePanel';
import { ProjectPanel } from '../panels/ProjectPanel';
import { ChatPanel } from '../panels/ChatPanel';

// TS-112 M6：推理面板（后端切换/测试连接/模型列表）+ 视觉引导卡片 + B8 删除项目确认
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

// 按 URL 片段分发 mock 响应；未命中走兜底
function mockFetch(handlers: Record<string, unknown>) {
  return vi.spyOn(globalThis, 'fetch').mockImplementation((async (url: any, opts: any) => {
    const u = String(url);
    for (const [k, v] of Object.entries(handlers)) {
      if (u.includes(k)) {
        return { ok: true, status: 200, json: async () => v };
      }
    }
    void opts;
    return { ok: true, status: 200, json: async () => [] };
  }) as any);
}

describe('TS-112 M6 推理面板', () => {
  it('ollama 后端：状态区 + 测试连接 + 模型列表 + 拉取/删除入口', async () => {
    mockFetch({
      '/inference/status': { backend: 'ollama', base_url: 'http://localhost:11434', online: true, detail: '', capabilities: { tools: true, vision: true, pull: true, delete: true } },
      '/inference/models': [{ name: 'qwen3.8', size: 16_000_000_000, context_length: 262144 }],
      '/config': { inference_backend: 'ollama' },
    });
    const { unmount } = render(<InferencePanel />);
    await waitFor(() => {
      expect(screen.getByText(/Ollama · 在线/)).toBeTruthy();
      expect(screen.getByText('测试连接')).toBeTruthy();
      expect(screen.getByText('qwen3.8')).toBeTruthy();
      expect(screen.getByText(/ctx 262144/)).toBeTruthy();
      expect(screen.getByText('删除')).toBeTruthy();
      expect(screen.getByPlaceholderText(/拉取模型，如 qwen2\.5-vl/)).toBeTruthy();
    }, { timeout: 3000 });
    unmount();
  });

  it('openai_compatible 后端：隐藏拉取/删除，显示提示文案', async () => {
    mockFetch({
      '/inference/status': { backend: 'openai_compatible', base_url: 'http://localhost:1234/v1', online: true, detail: '', capabilities: { tools: true, vision: true, pull: false, delete: false } },
      '/inference/models': [{ name: 'my-model' }],
      '/config': { inference_backend: 'openai_compatible', inference_base_url: 'http://localhost:1234/v1', inference_api_key: '', openai_compat_supports_tools: true },
    });
    const { unmount } = render(<InferencePanel />);
    await waitFor(() => {
      expect(screen.getByText(/OpenAI 兼容后端 · 在线/)).toBeTruthy();
      expect(screen.getByText('my-model')).toBeTruthy();
    }, { timeout: 3000 });
    expect(screen.queryByPlaceholderText(/拉取模型/)).toBeFalsy();
    expect(screen.queryByText('删除')).toBeFalsy();
    expect(screen.getByText(/拉取\/删除模型仅 Ollama 后端支持/)).toBeTruthy();
    unmount();
  });

  it('视觉引导卡片：消息含多模态降级文案 → 卡片出现（切换下拉 + 一键拉取 + 知道了）', async () => {
    mockFetch({
      '/agents/': [{ id: 'a1', name: '测试Agent', role: '工程师' }],
      '/sessions?': [{ id: 's1', title: '会话1', message_count: 1 }],
      '/sessions/s1/messages': [{
        id: 1, role: 'assistant', model_used: 'qwen3.8', created_at: '2026-08-29 22:00',
        content: '[⚠️ 当前模型不支持多模态] 已按纯文本处理',
      }],
      '/ollama/models': [{ name: 'qwen3.8' }, { name: 'qwen2.5-vl:latest' }],
      '/inference/status': { backend: 'ollama', base_url: '', online: true, detail: '', capabilities: { tools: true, vision: true, pull: true, delete: true } },
    });
    const { unmount } = render(<ChatPanel projectId="p1" agentId="a1" />);

    // 等会话选择器出现并切到 s1，触发历史消息加载
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

    await waitFor(() => {
      expect(screen.getByText(/当前模型不支持图片分析/)).toBeTruthy();
      expect(screen.getByText('一键拉取 qwen2.5-vl')).toBeTruthy();
      expect(screen.getByText('知道了')).toBeTruthy();
    }, { timeout: 3000 });
    unmount();
  });

  it('点击"测试连接"有可见反馈（检测中…），完成后显示在线状态', async () => {
    let resolveFetch: (v: unknown) => void = () => {};
    const gate = new Promise(r => { resolveFetch = r as (v: unknown) => void; });
    vi.spyOn(globalThis, 'fetch').mockImplementation((async (url: any) => {
      const u = String(url);
      if (u.includes('/inference/status')) {
        await gate;  // 挂起，模拟探测耗时
        return { ok: true, status: 200, json: async () => ({ backend: 'ollama', base_url: '', online: true, detail: '', capabilities: { tools: true, vision: true, pull: true, delete: true } }) };
      }
      if (u.includes('/inference/models')) return { ok: true, status: 200, json: async () => [] };
      return { ok: true, status: 200, json: async () => ({ inference_backend: 'ollama' }) };
    }) as any);
    const { unmount } = render(<InferencePanel />);
    const btn = await screen.findByText('测试连接');
    await act(async () => { btn.click(); });
    // 点击后立即出现忙态反馈（不再"没有反应"）
    expect(screen.getByText('检测中…')).toBeTruthy();
    expect(screen.getByText('正在测试连接…')).toBeTruthy();
    await act(async () => { resolveFetch(null); });
    await waitFor(() => { expect(screen.getByText(/Ollama · 在线/)).toBeTruthy(); }, { timeout: 3000 });
    unmount();
  });

  it('B8：删除项目先弹 confirm——文案含"工作目录文件不受影响"；取消不发 DELETE，确认才发', async () => {
    const deleteCalls: string[] = [];
    vi.spyOn(globalThis, 'fetch').mockImplementation((async (url: any, opts: any) => {
      const u = String(url);
      if (opts?.method === 'DELETE') deleteCalls.push(u);
      if (u.includes('/projects')) {
        return { ok: true, status: 200, json: async () => [{ id: 'p1', name: '测试项目', working_dir: '/tmp/wd' }] };
      }
      return { ok: true, status: 200, json: async () => [] };
    }) as any);

    const { unmount } = render(<ProjectPanel onSelect={() => {}} />);
    await waitFor(() => { expect(screen.getByText(/测试项目/)).toBeTruthy(); }, { timeout: 3000 });

    // 点击删除按钮 → 自定义弹窗出现
    await act(async () => { (document.querySelector('[data-tip="删除"]') as HTMLElement).click(); });
    await waitFor(() => {
      expect(document.body.textContent).toContain('工作目录中的文件不受影响');
    }, { timeout: 3000 });

    // 点取消 → 不发 DELETE
    await act(async () => { screen.getByText('取消').click(); });
    expect(deleteCalls.length).toBe(0);

    // 再次点击删除 → 点确认（"删除"按钮）→ 发 DELETE /projects/p1
    await act(async () => { (document.querySelector('[data-tip="删除"]') as HTMLElement).click(); });
    await waitFor(() => {
      expect(document.querySelector('[role="dialog"]')).toBeTruthy();
    }, { timeout: 3000 });
    // 弹窗中确认按钮文案为"删除"（confirmText）
    const dialog = document.querySelector('[role="dialog"]')!;
    const confirmBtn = Array.from(dialog.querySelectorAll('button')).find(b => b.textContent === '删除');
    expect(confirmBtn).toBeTruthy();
    await act(async () => { confirmBtn!.click(); });
    await waitFor(() => { expect(deleteCalls.length).toBe(1); }, { timeout: 3000 });
    expect(deleteCalls[0]).toContain('/projects/p1');
    unmount();
  });
});
