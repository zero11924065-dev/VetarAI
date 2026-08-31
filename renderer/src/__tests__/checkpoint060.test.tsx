import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, act } from '@testing-library/react';
import React from 'react';

// checkpoint-060：工具折叠条单行化回归。
// 事故：旧折叠条行高固定 30px 但标签可换行，长摘要（委派交卷数百字）上下对称溢出，
// 叠印到上下消息上。修复：折叠态单行省略（textOverflow:ellipsis + nowrap + overflow:hidden），
// 完整摘要/错误进展开区。注意：ellipsis 是视觉截断，DOM 文本仍存在，故用样式断言而非文本存在性。
import { ChatPanel } from '../panels/ChatPanel';

if (typeof (globalThis as any).localStorage === 'undefined') {
  (globalThis as any).localStorage = {
    _d: {} as Record<string, string>,
    getItem(k: string) { return this._d[k] ?? null; },
    setItem(k: string, v: string) { this._d[k] = String(v); },
    removeItem(k: string) { delete this._d[k]; },
    clear() { this._d = {}; },
  };
}

const LONG_SUMMARY = '（[success] 本次查询已明确中国税法下食品类开具发票适用的增值税税点及最新政策（含2026年《增值税法》实施背景）。具体核定如下：1. 一般纳税人适用税率：初级农产品9%，深加工13%，餐饮服务6%……'.repeat(3);

const DB_MSGS = [
  { id: 1, role: 'user', content: '财务在不在，让他帮我查一下食品类的开票税点', created_at: 't1' },
  { id: 2, role: 'assistant', content: '好的，已安排财务专员为您完成查询。', created_at: 't2',
    toolSteps: [{ id: 's1', name: 'delegate_task', status: 'ok', summary: LONG_SUMMARY, args: { task: '查税点' } }] },
];

beforeEach(() => { vi.restoreAllMocks(); localStorage.clear(); });

function mount() {
  vi.spyOn(globalThis, 'fetch').mockImplementation((async (url: any) => {
    const u = String(url);
    if (u.includes('/agents/')) return { ok: true, status: 200, json: async () => [{ id: 'a1', name: '行政主管', role: 'x' }] };
    if (u.includes('/ollama/models')) return { ok: true, status: 200, json: async () => [{ name: 'qwen3.6:35b' }] };
    if (u.includes('/sessions?')) return { ok: true, status: 200, json: async () => [{ id: 's1', title: '会话 1', message_count: 2 }] };
    if (u.includes('/sessions/s1/messages')) return { ok: true, status: 200, json: async () => DB_MSGS };
    return { ok: true, status: 200, json: async () => [] };
  }) as any);
  return render(<ChatPanel projectId="p1" agentId="a1" />);
}

describe('checkpoint-060 工具折叠条单行化', () => {
  it('折叠条标签单行省略（nowrap+ellipsis），不再换行溢出叠印', async () => {
    const { unmount } = mount();
    await new Promise(r => setTimeout(r, 100));
    const label = screen.getByText(/^delegate_task 完成/);
    const st = label.style;
    expect(st.whiteSpace).toBe('nowrap');
    expect(st.textOverflow).toBe('ellipsis');
    expect(st.overflow).toBe('hidden');
    unmount();
  });

  it('点击展开后完整摘要与参数在展开区渲染', async () => {
    const { unmount } = mount();
    await new Promise(r => setTimeout(r, 100));
    await act(async () => { screen.getByText(/^delegate_task 完成/).click(); });
    await new Promise(r => setTimeout(r, 50));
    // 展开后：完整摘要至少出现在展开区（折叠标签是视觉省略，DOM 文本仍在，故 ≥2 处匹配）
    expect(screen.getAllByText(/一般纳税人适用税率：初级农产品9%/).length).toBeGreaterThanOrEqual(2);
    // 参数 JSON 在展开区渲染
    expect(screen.getByText(/"task": "查税点"/)).toBeTruthy();
    unmount();
  });
});
