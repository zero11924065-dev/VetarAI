import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, waitFor, act } from '@testing-library/react';
import React from 'react';
import { IndependentAgentsPanel, INDEP_NS_PREFIX } from '../panels/IndependentAgentsPanel';

// checkpoint-058：独立 Agent（与项目平级的一等公民）。
// 核心场景：① 展开后列出独立 Agent + 创建表单；② 创建成功后自动选中
// （onSelect(agentId)，父级映射 ia-<id> 命名空间）；③ 点击已有 Agent 触发选中；
// ④ 删除走确认弹窗 + DELETE 请求；⑤ 空态引导文案。
if (typeof (globalThis as any).localStorage === 'undefined') {
  (globalThis as any).localStorage = {
    _d: {} as Record<string, string>,
    getItem(k: string) { return this._d[k] ?? null; },
    setItem(k: string, v: string) { this._d[k] = String(v); },
    removeItem(k: string) { delete this._d[k]; },
    clear() { this._d = {}; },
  };
}

beforeEach(() => { vi.restoreAllMocks(); });

const INDEP = [{ id: 'ag1', name: '独立助手', model_name: 'glm-z1-9b' }, { id: 'ag2', name: '独立二号' }];

function mockFetch(agents: any[] = INDEP) {
  vi.spyOn(globalThis, 'fetch').mockImplementation((async (url: any) => {
    const u = String(url);
    if (u.includes('/independent-agents')) {
      return { ok: true, status: 200, json: async () => agents };
    }
    return { ok: true, status: 200, json: async () => [] };
  }) as any);
}

describe('checkpoint-058 独立 Agent 面板', () => {
  it('表头展开后列出独立 Agent 与创建表单；点击 Agent 触发 onSelect', async () => {
    mockFetch();
    const onSelect = vi.fn();
    const { unmount } = render(<IndependentAgentsPanel selectedAgentId={null} onSelect={onSelect} />);

    // 表头出现（含"独立 Agent"文案）
    await waitFor(() => { expect(screen.getByText('独立 Agent')).toBeTruthy(); }, { timeout: 3000 });
    // 收起态：列表不可见
    expect(screen.queryByText('独立助手')).toBeFalsy();

    // 点表头展开
    await act(async () => { (screen.getByText('独立 Agent').closest('button') as HTMLElement).click(); });
    await waitFor(() => {
      expect(screen.getByText('独立助手')).toBeTruthy();
      expect(screen.getByText('独立二号')).toBeTruthy();
      expect(screen.getByPlaceholderText('新独立 Agent 名称')).toBeTruthy(); // 创建表单
    }, { timeout: 3000 });

    // 点击某个独立 Agent → onSelect(agentId)（父级映射 ia- 命名空间）
    await act(async () => { screen.getByText('独立助手').click(); });
    expect(onSelect).toHaveBeenCalledWith('ag1');

    unmount();
  });

  it('创建：提交后调 POST /independent-agents 并自动选中新 Agent', async () => {
    let created: any[] = [];
    vi.spyOn(globalThis, 'fetch').mockImplementation((async (url: any, opts: any) => {
      const u = String(url);
      if (opts && opts.method === 'POST' && u.includes('/independent-agents')) {
        const body = JSON.parse(opts.body);
        created.push(body);
        return { ok: true, status: 200, json: async () => ({ agent_id: 'new-id-1' }) };
      }
      if (u.includes('/independent-agents')) return { ok: true, status: 200, json: async () => [] };
      return { ok: true, status: 200, json: async () => [] };
    }) as any);

    const onSelect = vi.fn();
    const { unmount } = render(<IndependentAgentsPanel selectedAgentId={null} onSelect={onSelect} />);
    await waitFor(() => { expect(screen.getByText('独立 Agent')).toBeTruthy(); }, { timeout: 3000 });
    await act(async () => { (screen.getByText('独立 Agent').closest('button') as HTMLElement).click(); });

    const inputEl = screen.getByPlaceholderText('新独立 Agent 名称') as HTMLInputElement;
    await act(async () => {
      const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value')!.set!;
      setter.call(inputEl, '我的独立助手');
      inputEl.dispatchEvent(new Event('input', { bubbles: true }));
    });
    await act(async () => { screen.getByText('创建').click(); });

    await waitFor(() => { expect(created.length).toBe(1); }, { timeout: 3000 });
    expect(created[0].name).toBe('我的独立助手');
    // 创建后自动选中
    await waitFor(() => { expect(onSelect).toHaveBeenCalledWith('new-id-1'); }, { timeout: 3000 });
    unmount();
  });

  it('空态：展示引导文案（不属于任何项目，删项目不影响）', async () => {
    mockFetch([]);
    const { unmount } = render(<IndependentAgentsPanel selectedAgentId={null} onSelect={() => {}} />);
    await waitFor(() => { expect(screen.getByText('独立 Agent')).toBeTruthy(); }, { timeout: 3000 });
    await act(async () => { (screen.getByText('独立 Agent').closest('button') as HTMLElement).click(); });
    await waitFor(() => {
      expect(screen.getByText(/不属于任何项目/)).toBeTruthy();
    }, { timeout: 3000 });
    unmount();
  });

  it('命名空间前缀导出为 ia-（与后端 INDEP_NS_PREFIX 一致）', () => {
    expect(INDEP_NS_PREFIX).toBe('ia-');
  });

  it('checkpoint-058b：创建表单提交模型与角色设定；列表项可编辑角色设定', async () => {
    const created: any[] = [];
    const updated: { id: string; body: any }[] = [];
    vi.spyOn(globalThis, 'fetch').mockImplementation((async (url: any, opts: any) => {
      const u = String(url);
      if (opts && opts.method === 'POST' && u.includes('/independent-agents')) {
        created.push(JSON.parse(opts.body));
        return { ok: true, status: 200, json: async () => ({ agent_id: 'n1' }) };
      }
      if (opts && opts.method === 'PUT' && u.includes('/independent-agents/')) {
        updated.push({ id: u.split('/').pop()!, body: JSON.parse(opts.body) });
        return { ok: true, status: 200, json: async () => ({ updated: true }) };
      }
      if (u.includes('/independent-agents')) {
        return { ok: true, status: 200, json: async () => (updated.length ? INDEP : [{ id: 'ag1', name: '独立助手', model_name: 'glm-z1-9b' }]) };
      }
      if (u.includes('/ollama/models')) return { ok: true, status: 200, json: async () => [{ name: 'glm-z1-9b' }, { name: 'qwen3.6:35b' }] };
      return { ok: true, status: 200, json: async () => [] };
    }) as any);

    const { unmount } = render(<IndependentAgentsPanel selectedAgentId={null} onSelect={() => {}} />);
    await waitFor(() => { expect(screen.getByText('独立 Agent')).toBeTruthy(); }, { timeout: 3000 });
    await act(async () => { (screen.getByText('独立 Agent').closest('button') as HTMLElement).click(); });

    // 创建表单：填名称 + 选模型 + 填角色设定 → 提交
    const setVal = (el: HTMLElement, v: string, proto: any) => {
      const setter = Object.getOwnPropertyDescriptor(proto, 'value')!.set!;
      setter.call(el, v);
      el.dispatchEvent(new Event(proto === window.HTMLTextAreaElement.prototype ? 'input' : 'change', { bubbles: true }));
    };
    await act(async () => { setVal(screen.getByPlaceholderText('新独立 Agent 名称'), '审校员', window.HTMLInputElement.prototype); });
    await act(async () => {
      const sel = document.querySelectorAll('select')[0] as HTMLSelectElement;
      setVal(sel, 'qwen3.6:35b', window.HTMLSelectElement.prototype);
    });
    await act(async () => { setVal(screen.getByPlaceholderText(/角色设定（可选）/), '你是严谨的文档审校员', window.HTMLTextAreaElement.prototype); });
    await act(async () => { screen.getByText('创建').click(); });

    await waitFor(() => { expect(created.length).toBe(1); }, { timeout: 3000 });
    expect(created[0].name).toBe('审校员');
    expect(created[0].model_name).toBe('qwen3.6:35b');
    expect(created[0].system_prompt).toBe('你是严谨的文档审校员');

    // 列表项：点铅笔 → 行内编辑角色设定 → 保存 → PUT
    await waitFor(() => { expect((document.querySelector('[data-tip="编辑角色设定"]') as HTMLElement)).toBeTruthy(); }, { timeout: 3000 });
    await act(async () => { (document.querySelector('[data-tip="编辑角色设定"]') as HTMLElement).click(); });
    await act(async () => { setVal(screen.getByPlaceholderText(/留空保存则清除/), '新角色', window.HTMLTextAreaElement.prototype); });
    await act(async () => { screen.getByText('保存').click(); });
    await waitFor(() => { expect(updated.length).toBe(1); }, { timeout: 3000 });
    expect(updated[0].body.system_prompt).toBe('新角色');

    unmount();
  });
});
