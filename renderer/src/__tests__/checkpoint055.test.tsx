import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, waitFor, act } from '@testing-library/react';
import React from 'react';
import { ChatPanel } from '../panels/ChatPanel';

// checkpoint-055 回归：切回主 Agent 丢消息修复。
// 用户场景：主 Agent 派任务后去子 Agent 查看，切回主 Agent 只见第一条打招呼，
// 自己发的内容与任务汇报全丢。根因：① user 消息从不写缓存；② "缓存优先"用残缺
// 缓存屏蔽更完整的 DB 历史。修复：DB 为权威源 + 本地未落盘气泡合并；发送即写缓存。
if (typeof (globalThis as any).localStorage === 'undefined') {
  (globalThis as any).localStorage = {
    _d: {} as Record<string, string>,
    getItem(k: string) { return this._d[k] ?? null; },
    setItem(k: string, v: string) { this._d[k] = String(v); },
    removeItem(k: string) { delete this._d[k]; },
    clear() { this._d = {}; },
  };
}

const DB_S1 = [
  { id: 1, role: 'user', content: '你好', created_at: 't1' },
  { id: 2, role: 'assistant', content: '你好！我是你的行政主管。', created_at: 't2' },
  { id: 3, role: 'user', content: '帮我找一下人事，我想知道重庆的最低社保缴纳基数', created_at: 't3' },
  { id: 4, role: 'assistant', content: '老板，已安排人事专员查询，最低缴费基数为…', created_at: 't4' },
];

beforeEach(() => {
  vi.restoreAllMocks();
  localStorage.clear();
});

function mountWithDb() {
  vi.spyOn(globalThis, 'fetch').mockImplementation((async (url: any) => {
    const u = String(url);
    if (u.includes('/agents/')) return { ok: true, status: 200, json: async () => [{ id: 'a1', name: '行政主管', role: 'x' }] };
    if (u.includes('/ollama/models')) return { ok: true, status: 200, json: async () => [{ name: 'qwen3.6:35b' }] };
    if (u.includes('/sessions?')) return { ok: true, status: 200, json: async () => [
      { id: 's1', title: '会话 1', message_count: 4 },
      { id: 's2', title: '委派任务', message_count: 2 },
    ]};
    if (u.includes('/sessions/s1/messages')) return { ok: true, status: 200, json: async () => DB_S1 };
    if (u.includes('/messages')) return { ok: true, status: 200, json: async () => [] };
    return { ok: true, status: 200, json: async () => [] };
  }) as any);
  return render(<ChatPanel projectId="p1" agentId="a1" />);
}

async function switchSession(value: string) {
  await act(async () => {
    const sel = document.querySelector('select') as HTMLSelectElement;
    const setter = Object.getOwnPropertyDescriptor(window.HTMLSelectElement.prototype, 'value')!.set!;
    setter.call(sel, value);
    sel.dispatchEvent(new Event('change', { bubbles: true }));
  });
}

describe('checkpoint-055 切回丢消息修复', () => {
  it('残缺缓存不再屏蔽 DB：切走再切回，完整历史（含 user 消息）全部显示', async () => {
    // 预置"残缺缓存"：只有第一条打招呼（复现用户现场）
    localStorage.setItem('subagent_messages_v4', JSON.stringify({
      s1: [DB_S1[1]],
    }));

    const { unmount } = mountWithDb();
    await waitFor(() => { expect(document.querySelector('select')).toBeTruthy(); }, { timeout: 3000 });

    // 首次加载即应显示完整历史（DB 为准），而非残缺缓存
    await waitFor(() => {
      expect(screen.getByText(/帮我找一下人事/)).toBeTruthy();
    }, { timeout: 3000 });
    expect(screen.getByText(/最低缴费基数/)).toBeTruthy();

    // 切去委派会话再切回（用户去子 Agent 查看再回来的等价操作）
    await switchSession('s2');
    await switchSession('s1');

    await waitFor(() => {
      expect(screen.getByText(/帮我找一下人事/)).toBeTruthy();
      expect(screen.getByText(/最低缴费基数/)).toBeTruthy();
      expect(screen.getByText(/^你好$/)).toBeTruthy();
    }, { timeout: 3000 });

    unmount();
  }, 8000);

  it('发送消息立即写缓存：缓存不再只有 assistant 的半残状态', async () => {
    localStorage.clear();
    const { unmount } = mountWithDb();
    await waitFor(() => { expect(document.querySelector('select')).toBeTruthy(); }, { timeout: 3000 });
    // 首次从 DB 合并加载后回写缓存
    await waitFor(() => {
      const cache = JSON.parse(localStorage.getItem('subagent_messages_v4') || '{}');
      expect((cache['s1'] || []).length).toBe(4);
    }, { timeout: 3000 });
    const cache = JSON.parse(localStorage.getItem('subagent_messages_v4') || '{}');
    const roles = (cache['s1'] as any[]).map(m => m.role);
    expect(roles).toEqual(['user', 'assistant', 'user', 'assistant']);
    unmount();
  }, 8000);

  it('本地未落盘流式气泡（local_* id）在合并加载后保留不丢', async () => {
    // 缓存含一条 local_ 前缀的进行中气泡，DB 无它
    localStorage.setItem('subagent_messages_v4', JSON.stringify({
      s1: [...DB_S1, { id: 'local_99', role: 'assistant', content: '进行中的流式回复…' }],
    }));
    const { unmount } = mountWithDb();
    await waitFor(() => {
      expect(screen.getByText(/进行中的流式回复/)).toBeTruthy();
      expect(screen.getByText(/帮我找一下人事/)).toBeTruthy();
    }, { timeout: 3000 });
    unmount();
  }, 8000);
});
