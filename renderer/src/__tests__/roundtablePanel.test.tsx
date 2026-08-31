import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, waitFor, act, fireEvent } from '@testing-library/react';
import React from 'react';
import { RoundtablePanel } from '../panels/RoundtablePanel';
import { RoundtableView } from '../panels/RoundtableView';

// TS-109 M3-3 + 改进（右侧大屏）：左栏面板（创建区+列表）与右侧大屏（主持人显示+按状态按钮）
if (typeof (globalThis as any).localStorage === 'undefined') {
  (globalThis as any).localStorage = {
    _d: {} as Record<string, string>,
    getItem(k: string) { return this._d[k] ?? null; },
    setItem(k: string, v: string) { this._d[k] = String(v); },
    removeItem(k: string) { delete this._d[k]; },
    clear() { this._d = {}; },
  };
}

const AGENTS = [
  { id: 'a1', name: '产品', role: '产品经理', model_name: 'qwen3.8' },
  { id: 'a2', name: '技术', role: '技术负责人', model_name: 'qwen3.8' },
];

const RT_WAITING = {
  id: 'rt1', topic: '要不要做 X 功能', participants: AGENTS,
  moderator: 'user', moderator_agent_id: null, max_rounds: 5, round: 1,
  status: 'waiting_user', minutes: '【共识】无', summary: null,
};
const RT_CONFIRM_AI = { ...RT_WAITING, id: 'rt2', status: 'confirm_end', moderator: 'ai', moderator_agent_id: 'a1' };

function mockPanelFetch(rts: any[]) {
  vi.spyOn(globalThis, 'fetch').mockImplementation((async (url: any) => {
    const u = String(url);
    if (u.includes('/agents/')) return { ok: true, status: 200, json: async () => AGENTS };
    if (u.includes('/roundtables')) return { ok: true, status: 200, json: async () => rts };
    return { ok: true, status: 200, json: async () => [] };
  }) as any);
}

beforeEach(() => {
  vi.restoreAllMocks();
  localStorage.clear();
});

describe('RoundtablePanel 左栏面板（创建+列表）', () => {
  it('创建区渲染：议题输入 + 参与者多选 + 主持人单选 + 轮数', async () => {
    mockPanelFetch([]);
    const { unmount } = render(<RoundtablePanel projectId="p1" selectedId={null} onSelect={() => {}} />);

    await waitFor(() => {
      expect(screen.getByPlaceholderText('输入讨论议题…')).toBeTruthy();
      expect(screen.getByText(/参与者（至少 2 个）/)).toBeTruthy();
      expect(screen.getByText('产品（产品经理）')).toBeTruthy();
      expect(screen.getByText('用户主持')).toBeTruthy();
      expect(screen.getByText(/AI 主持/)).toBeTruthy();
      expect(screen.getByText('开始讨论')).toBeTruthy();
      expect(screen.getByText('暂无圆桌讨论')).toBeTruthy();
    }, { timeout: 3000 });
    unmount();
  });

  it('列表状态徽标 + 点击触发 onSelect', async () => {
    mockPanelFetch([RT_WAITING, RT_CONFIRM_AI]);
    const selected: string[] = [];
    const { unmount } = render(<RoundtablePanel projectId="p1" selectedId={null} onSelect={id => selected.push(id)} />);

    await waitFor(() => {
      expect(screen.getAllByText(/等待用户/).length).toBeGreaterThanOrEqual(1);
      expect(screen.getAllByText(/待确认结束/).length).toBeGreaterThanOrEqual(1);
    }, { timeout: 3000 });

    await act(async () => {
      fireEvent.click(screen.getByTestId('rt-item-rt1'));
    });
    expect(selected).toEqual(['rt1']);
    unmount();
  });
});

describe('RoundtableView 右侧大屏', () => {
  function mockViewFetch(detail: any) {
    vi.spyOn(globalThis, 'fetch').mockImplementation((async (url: any, init?: any) => {
      const u = String(url);
      if (init?.method === 'POST') return { ok: true, status: 200, json: async () => detail };
      return { ok: true, status: 200, json: async () => detail };
    }) as any);
  }

  it('用户主持显示 + waiting_user 双按钮 + 发言气泡', async () => {
    mockViewFetch({ ...RT_WAITING, messages: [
      { id: 1, rt_id: 'rt1', round: 1, agent_id: 'a1', agent_name: '产品', content: '产品发言', ok: true },
      { id: 2, rt_id: 'rt1', round: 1, agent_id: 'a2', agent_name: '技术', content: '技术发言', ok: false },
    ] });
    const { unmount } = render(<RoundtableView projectId="p1" roundtableId="rt1" onExit={() => {}} />);

    await waitFor(() => {
      // 主持人显示（用户验收反馈：主持人应在右侧可见）
      expect(screen.getByText(/用户主持（结束权在你）/)).toBeTruthy();
      // 参与者名单
      expect(screen.getByText(/参与者：产品、技术/)).toBeTruthy();
      // 状态按钮
      expect(screen.getByText('继续下一轮')).toBeTruthy();
      expect(screen.getByText('结束并总结')).toBeTruthy();
      // 发言气泡 + 失败标注
      expect(screen.getByText('产品发言')).toBeTruthy();
      expect(screen.getByText(/发言失败/)).toBeTruthy();
      // 轮次分组
      expect(screen.getByText(/第 1 轮/)).toBeTruthy();
    }, { timeout: 3000 });
    unmount();
  });

  it('AI 主持显示主持人姓名 + confirm_end 确认结束按钮', async () => {
    mockViewFetch({ ...RT_CONFIRM_AI, messages: [] });
    const { unmount } = render(<RoundtableView projectId="p1" roundtableId="rt2" onExit={() => {}} />);

    await waitFor(() => {
      expect(screen.getByText(/AI 主持：产品/)).toBeTruthy();
      expect(screen.getByText('确认结束')).toBeTruthy();
      expect(screen.getByText('再讨论一轮')).toBeTruthy();
    }, { timeout: 3000 });
    unmount();
  });

  it('H18 增强：保存为文件 + 删除按钮 + 附件展示', async () => {
    mockViewFetch({
      ...RT_WAITING, status: 'done', summary: '【共识】总结正文',
      attachments: [{ name: '材料.pdf', is_text: false }, { name: '数据.txt', is_text: true }],
      messages: [],
    });
    const { unmount } = render(<RoundtableView projectId="p1" roundtableId="rt1" onExit={() => {}} />);

    await waitFor(() => {
      // 保存与删除按钮（顶栏常驻）
      expect(screen.getByText('保存为文件')).toBeTruthy();
      // "删除"文本在多个按钮中可能出现，用 getAllByText
      expect(screen.getAllByText('删除').length).toBeGreaterThan(0);
      // 附件展示（非文本标注）
      expect(screen.getByText(/材料\.pdf/)).toBeTruthy();
      expect(screen.getByText(/数据\.txt/)).toBeTruthy();
      expect(screen.getByText(/（非文本）/)).toBeTruthy();
    }, { timeout: 3000 });
    unmount();
  });
});

describe('RoundtablePanel 附件上传（H18-3）', () => {
  it('左栏创建区含"添加参考材料"入口', async () => {
    mockPanelFetch([]);
    const { unmount } = render(<RoundtablePanel projectId="p1" selectedId={null} onSelect={() => {}} />);
    await waitFor(() => {
      expect(screen.getByText(/添加参考材料（可选）/)).toBeTruthy();
    }, { timeout: 3000 });
    unmount();
  });
});
