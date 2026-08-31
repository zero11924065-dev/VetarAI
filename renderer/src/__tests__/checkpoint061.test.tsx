import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, waitFor, act } from '@testing-library/react';
import React from 'react';
import { IndependentAgentsPanel } from '../panels/IndependentAgentsPanel';

// checkpoint-061 回归：删除当前选中的独立 Agent 后，面板必须调用 onAgentDeleted
// （App 据此清空选中态与保活面板，杜绝"幽灵聊天面板"继续向已删除的 ia- 命名空间发消息）。
if (typeof (globalThis as any).localStorage === 'undefined') {
  (globalThis as any).localStorage = {
    _d: {} as Record<string, string>,
    getItem(k: string) { return this._d[k] ?? null; },
    setItem(k: string, v: string) { this._d[k] = String(v); },
    removeItem(k: string) { delete this._d[k]; },
    clear() { this._d = {}; },
  };
}

// Dialog 模块级弹窗在 jsdom 中需要真实按钮交互——这里 mock confirmDialog 直接返回"确认删除"
vi.mock('../Dialog', () => ({
  confirmDialog: vi.fn(async () => true),
  alertDialog: vi.fn(async () => {}),
  promptDialog: vi.fn(async () => null),
}));

const AGENTS = [{ id: 'ag1', name: '独立助手', model_name: 'glm-z1-9b' }];

beforeEach(() => { vi.restoreAllMocks(); });

function mountFetch(deleted: { v: boolean }) {
  vi.spyOn(globalThis, 'fetch').mockImplementation((async (url: any, opts: any) => {
    const u = String(url);
    if (opts && opts.method === 'DELETE' && u.includes('/independent-agents/ag1')) {
      deleted.v = true;
      return { ok: true, status: 200, json: async () => ({ deleted: true }) };
    }
    if (u.includes('/independent-agents')) {
      return { ok: true, status: 200, json: async () => (deleted.v ? [] : AGENTS) };
    }
    return { ok: true, status: 200, json: async () => [] };
  }) as any);
}

describe('checkpoint-061 删除选中独立 Agent → onAgentDeleted 回调', () => {
  it('删除成功后调用 onAgentDeleted(agentId)', async () => {
    const deleted = { v: false };
    mountFetch(deleted);
    const onAgentDeleted = vi.fn();
    const { unmount } = render(
      <IndependentAgentsPanel selectedAgentId="ag1" onSelect={() => {}} onAgentDeleted={onAgentDeleted} />
    );

    await waitFor(() => { expect(screen.getByText('独立 Agent')).toBeTruthy(); }, { timeout: 3000 });
    await act(async () => { (screen.getByText('独立 Agent').closest('button') as HTMLElement).click(); });
    await waitFor(() => { expect(screen.getByText('独立助手')).toBeTruthy(); }, { timeout: 3000 });

    await act(async () => { screen.getByTitle('删除独立 Agent').click(); });
    await waitFor(() => { expect(deleted.v).toBe(true); }, { timeout: 3000 });
    await waitFor(() => { expect(onAgentDeleted).toHaveBeenCalledWith('ag1'); }, { timeout: 3000 });

    unmount();
  });

  it('展开区有高度限制（maxHeight 45vh + 独立滚动）', async () => {
    const deleted = { v: false };
    mountFetch(deleted);
    const { unmount } = render(
      <IndependentAgentsPanel selectedAgentId={null} onSelect={() => {}} />
    );
    await waitFor(() => { expect(screen.getByText('独立 Agent')).toBeTruthy(); }, { timeout: 3000 });
    await act(async () => { (screen.getByText('独立 Agent').closest('button') as HTMLElement).click(); });
    // 创建表单所在的展开容器必须限高可滚
    const formBox = screen.getByPlaceholderText('新独立 Agent 名称').closest('div[style*="max-height"]') as HTMLElement;
    expect(formBox).toBeTruthy();
    expect(formBox.style.maxHeight).toBe('45vh');
    expect(formBox.style.overflowY).toBe('auto');
    unmount();
  });
});
