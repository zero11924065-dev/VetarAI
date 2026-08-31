import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, waitFor, act, fireEvent } from '@testing-library/react';
import React from 'react';
import { KnowledgePanel } from '../panels/KnowledgePanel';

// TS-110 M4：知识/记忆/技能管理面板测试（三标签渲染 + 列表加载 + 开关/保存控件）
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

describe('KnowledgePanel 知识记忆技能面板', () => {
  it('三标签渲染，默认知识库标签', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation((async () =>
      ({ ok: true, status: 200, json: async () => [] })) as any);
    const { unmount } = render(<KnowledgePanel projectId="p1" />);
    await waitFor(() => {
      expect(screen.getByText('知识库')).toBeTruthy();
      expect(screen.getByText('记忆')).toBeTruthy();
      expect(screen.getByText('技能')).toBeTruthy();
      expect(screen.getByText('新建')).toBeTruthy();
      expect(screen.getByText(/暂无知识文件/)).toBeTruthy();
    }, { timeout: 3000 });
    unmount();
  });

  it('知识库列表加载 + 启用状态徽标 + 操作按钮', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation((async (url: any) => {
      if (String(url).includes('/knowledge')) {
        return { ok: true, status: 200, json: async () => [
          { name: '规范.md', size: 10, enabled: true },
          { name: '_草稿.md', size: 5, enabled: false },
        ]};
      }
      return { ok: true, status: 200, json: async () => [] };
    }) as any);
    const { unmount } = render(<KnowledgePanel projectId="p1" />);
    await waitFor(() => {
      expect(screen.getByText('规范.md')).toBeTruthy();
      expect(screen.getByText('_草稿.md')).toBeTruthy();
      expect(screen.getAllByText('禁用').length).toBe(1);
      expect(screen.getAllByText('启用').length).toBe(1);
      expect(screen.getAllByText('编辑').length).toBe(2);
    }, { timeout: 3000 });
    unmount();
  });

  it('记忆标签：全局/项目两个编辑区 + 保存按钮', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation((async () =>
      ({ ok: true, status: 200, json: async () => ({ content: '' }) })) as any);
    const { unmount } = render(<KnowledgePanel projectId="p1" />);
    // 切到记忆标签
    // 切到记忆标签：用 getByRole 精确定位按钮
    const allButtons = await screen.findAllByRole('button');
    const memTab = allButtons.find(b => b.textContent === '记忆');
    expect(memTab).toBeTruthy();
    await act(async () => { fireEvent.click(memTab!); });
    await waitFor(() => {
      // "全局记忆"/"项目记忆"在描述文案和标题中均出现，用 getAllByText 确认至少存在
      expect(screen.getAllByText(/全局记忆/).length).toBeGreaterThan(0);
      expect(screen.getAllByText(/项目记忆/).length).toBeGreaterThan(0);
      expect(screen.getByText('保存全局记忆')).toBeTruthy();
      expect(screen.getByText('保存项目记忆')).toBeTruthy();
    }, { timeout: 3000 });
    unmount();
  });

  it('技能标签：列表 + 启用开关 + 安装/新建入口', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation((async (url: any) => {
      if (String(url).includes('/skills')) {
        return { ok: true, status: 200, json: async () => [
          { name: '周报助手', dir_name: '周报助手', description: '生成周报', enabled: true },
        ]};
      }
      return { ok: true, status: 200, json: async () => [] };
    }) as any);
    const { unmount } = render(<KnowledgePanel projectId="p1" />);
    const skTab = await screen.findByText('技能');
    await act(async () => { fireEvent.click(skTab); });
    await waitFor(() => {
      expect(screen.getByText('周报助手')).toBeTruthy();
      expect(screen.getByText('生成周报')).toBeTruthy();
      expect(screen.getByText('新建')).toBeTruthy();
      expect(screen.getByPlaceholderText(/从仓库\/本地路径安装/)).toBeTruthy();
    }, { timeout: 3000 });
    unmount();
  });
});
