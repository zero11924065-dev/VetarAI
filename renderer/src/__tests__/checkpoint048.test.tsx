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

// checkpoint-048：会话总结按钮 + 上传格式扩容测试
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
  return vi.spyOn(globalThis, 'fetch').mockImplementation((async (url: any, opts: any) => {
    const u = String(url);
    if (u.includes('/agents/')) return { ok: true, status: 200, json: async () => [{ id: 'a1', name: '测试Agent', role: '工程师' }] };
    if (u.includes('/ollama/models')) return { ok: true, status: 200, json: async () => [{ name: 'qwen3.8' }] };
    if (u.includes('/sessions?')) return { ok: true, status: 200, json: async () => [{ id: 's1', title: '会话1', message_count: 2 }] };
    if (u.includes('/messages')) return { ok: true, status: 200, json: async () => [{ id: 1, role: 'user', content: '你好' }] };
    if (u.includes('/summarize')) {
      if (opts?.method === 'POST') {
        return { ok: true, status: 200, json: async () => ({ ok: true, summary: '总结内容', saved_file: '/tmp/x/sum.md' }) };
      }
    }
    if (u.includes('/attachments/parse')) {
      return { ok: true, status: 200, json: async () => ({ name: 'a.pdf', kind: 'pdf', text: '解析文本', truncated: false }) };
    }
    return { ok: true, status: 200, json: async () => [] };
  }) as any);
}

describe('checkpoint-048 会话总结与上传扩容', () => {
  it('选中会话后出现总结按钮（📝），点击调用 summarize 端点', async () => {
    const spy = mockBase();
    const { unmount } = render(<ChatPanel projectId="p1" agentId="a1" />);

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

    const sumBtn = await screen.findByTitle(/生成会话总结/);
    await act(async () => { sumBtn.click(); });
    await waitFor(() => {
      const call = spy.mock.calls.find(c => String(c[0]).includes('/summarize'));
      expect(call).toBeTruthy();
    }, { timeout: 3000 });
    unmount();
  });

  it('上传入口 accept 包含办公文档格式（.pdf/.docx/.xlsx）', () => {
    mockBase();
    render(<ChatPanel projectId="p1" agentId="a1" />);
    const fileInput = document.querySelector('input[type="file"]') as HTMLInputElement;
    expect(fileInput).toBeTruthy();
    expect(fileInput.accept).toContain('.pdf');
    expect(fileInput.accept).toContain('.docx');
    expect(fileInput.accept).toContain('.xlsx');
    expect(fileInput.accept).toContain('.csv');
  });

  it('上传可解析文档后调 /attachments/parse 并在暂存区显示"已提取"', async () => {
    const spy = mockBase();
    const { unmount } = render(<ChatPanel projectId="p1" agentId="a1" />);

    const fileInput = document.querySelector('input[type="file"]') as HTMLInputElement;
    expect(fileInput).toBeTruthy();

    // 构造一个小 PDF 文件对象并触发 change
    const file = new File([new Uint8Array([0x25, 0x50, 0x44, 0x46])], 'doc.pdf', { type: 'application/pdf' });
    await act(async () => {
      Object.defineProperty(fileInput, 'files', { value: [file], configurable: true });
      fileInput.dispatchEvent(new Event('change', { bubbles: true }));
      // 等待 FileReader onload + fetch 解析 + 状态更新落地
      await new Promise(r => setTimeout(r, 50));
    });

    await waitFor(() => {
      const call = spy.mock.calls.find(c => String(c[0]).includes('/attachments/parse'));
      expect(call).toBeTruthy();
    }, { timeout: 3000 });
    await waitFor(() => {
      expect(screen.getByText(/doc\.pdf/)).toBeTruthy();
    }, { timeout: 3000 });
    await waitFor(() => {
      expect(screen.getByText(/已提取/)).toBeTruthy();
    }, { timeout: 3000 });
    unmount();
  });
});
