/*
 * VetarAI - Local-first multi-agent orchestration application
 * Copyright (C) 2026 zero11924065-dev
 * GPL-3.0-or-later（见仓库 LICENSE）
 */
/**
 * A13（0.4.22）专项：6 面板收到广播后**真的重拉** + WorkflowPanel 的 dirty 守卫。
 *
 * 与 appEvents.test.ts 的分工：那边测「SSE 流 → 广播」（连接/字段映射/gap/重连/卸载不重连），
 * 这边测「广播 → 面板重拉」——两者拼起来才是完整的"Agent 改库 → 用户切回面板立即看到"链路。
 * 为聚焦面板侧契约，这里**直接 emit** APP_RESOURCE_CHANGED（不经真实 SSE），
 * 断言面板的数据端点被重新 fetch。
 *
 * 覆盖：
 *  P1 PluginPanel：收到 plugin 变更 → 重拉 /plugins
 *  P2 PluginPanel：收到**非** plugin 变更（workflow）→ 不重拉（按 resource 过滤）
 *  P3 PluginPanel：gap（resource:'*'）→ 重拉（无条件对账）
 *  P4 PluginPanel：卸载后 emit → 不再重拉（注销监听，无幽灵请求）
 *  P5 WorkflowPanel：非编辑态收到 workflow 变更 → 重拉 /workflows
 *  P6 ⛔ WorkflowPanel：编辑态（dirty）收到 workflow 变更 → **不重拉**（不冲掉未保存改动，
 *     计划验收第4条"WorkflowEditor 未保存改动不被冲掉"）
 */
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, waitFor, fireEvent, act } from '@testing-library/react';
import React from 'react';
import { PluginPanel } from '../panels/PluginPanel';
import { WorkflowPanel } from '../panels/WorkflowPanel';
import { installFetchMock, routeJson, route, jsonRes } from './helpers/fetchMock';
import { emit, __resetEventsForTest } from '../events';
import { APP_RESOURCE_CHANGED } from '../appEvents';

if (typeof (globalThis as any).localStorage === 'undefined') {
  (globalThis as any).localStorage = {
    _d: {} as Record<string, string>,
    getItem(k: string) { return this._d[k] ?? null; },
    setItem(k: string, v: string) { this._d[k] = String(v); },
    removeItem(k: string) { delete this._d[k]; },
    clear() { this._d = {}; },
  };
}

const PLUGINS = [{ name: 'demo-plugin', enabled: true, hooks: [] }];
const WORKFLOWS = [
  { id: 'wf1', name: '流程甲', description: '示例', definition: { nodes: [{ id: 'start', type: 'start', label: '开始' }], edges: [] } },
];

beforeEach(() => {
  vi.restoreAllMocks();
  __resetEventsForTest();
  localStorage.clear();
});

describe('A13 面板级：广播 → 重拉', () => {
  it('P1 PluginPanel 收到 plugin 变更 → 重拉 /plugins', async () => {
    const h = installFetchMock([routeJson('/plugins', PLUGINS)]);
    render(<PluginPanel />);
    await waitFor(() => expect(h.countOf('/plugins')).toBeGreaterThanOrEqual(1));
    const before = h.countOf('/plugins');

    await act(async () => {
      emit(APP_RESOURCE_CHANGED, { resource: 'plugin', action: 'update' });
      await new Promise(r => setTimeout(r, 30));
    });
    expect(h.countOf('/plugins')).toBeGreaterThan(before);
  });

  it('P2 PluginPanel 收到非 plugin 变更（workflow）→ 不重拉', async () => {
    const h = installFetchMock([routeJson('/plugins', PLUGINS)]);
    render(<PluginPanel />);
    await waitFor(() => expect(h.countOf('/plugins')).toBeGreaterThanOrEqual(1));
    const before = h.countOf('/plugins');

    await act(async () => {
      emit(APP_RESOURCE_CHANGED, { resource: 'workflow', action: 'update' });
      await new Promise(r => setTimeout(r, 30));
    });
    expect(h.countOf('/plugins')).toBe(before);   // ⛔ 按 resource 过滤，不误重拉
  });

  it('P3 PluginPanel 收到 gap(resource:"*") → 无条件重拉', async () => {
    const h = installFetchMock([routeJson('/plugins', PLUGINS)]);
    render(<PluginPanel />);
    await waitFor(() => expect(h.countOf('/plugins')).toBeGreaterThanOrEqual(1));
    const before = h.countOf('/plugins');

    await act(async () => {
      emit(APP_RESOURCE_CHANGED, { resource: '*', gap: true });
      await new Promise(r => setTimeout(r, 30));
    });
    expect(h.countOf('/plugins')).toBeGreaterThan(before);
  });

  it('P4 PluginPanel 卸载后 emit → 不再重拉（注销监听）', async () => {
    const h = installFetchMock([routeJson('/plugins', PLUGINS)]);
    const { unmount } = render(<PluginPanel />);
    await waitFor(() => expect(h.countOf('/plugins')).toBeGreaterThanOrEqual(1));
    unmount();
    const before = h.countOf('/plugins');

    await act(async () => {
      emit(APP_RESOURCE_CHANGED, { resource: 'plugin', action: 'update' });
      await new Promise(r => setTimeout(r, 30));
    });
    expect(h.countOf('/plugins')).toBe(before);   // ⛔ 卸载已注销，无幽灵重拉
  });
});

describe('A13 WorkflowPanel dirty 守卫（计划验收第4条）', () => {
  const wfRoutes = () => [
    routeJson('/workflows', WORKFLOWS),
    route('/inference/models', () => jsonRes([{ name: 'qwen3.8' }])),
  ];

  it('P5 非编辑态收到 workflow 变更 → 重拉 /workflows', async () => {
    const h = installFetchMock(wfRoutes());
    render(<WorkflowPanel />);
    await waitFor(() => expect(screen.getByText('流程甲')).toBeTruthy());
    const before = h.countOf('/workflows');

    await act(async () => {
      emit(APP_RESOURCE_CHANGED, { resource: 'workflow', action: 'update' });
      await new Promise(r => setTimeout(r, 30));
    });
    expect(h.countOf('/workflows')).toBeGreaterThan(before);
  });

  it('P6 ⛔ 编辑态(dirty)收到 workflow 变更 → 不重拉（不冲掉未保存改动）', async () => {
    const h = installFetchMock(wfRoutes());
    render(<WorkflowPanel />);
    await waitFor(() => expect(screen.getByText('流程甲')).toBeTruthy());

    // 选中工作流 → 编辑区出现（selectWorkflow 置 dirty=false）
    await act(async () => { fireEvent.click(screen.getByText('流程甲')); });
    const descInput = await screen.findByPlaceholderText('描述（可选）');
    // 改描述 → dirty=true（编辑态）
    await act(async () => { fireEvent.change(descInput, { target: { value: '我改了一半还没保存' } }); });
    const before = h.countOf('/workflows');

    // ⛔ 编辑态收到 Agent 的 workflow 变更 → 守卫生效，不重拉、不冲掉草稿
    await act(async () => {
      emit(APP_RESOURCE_CHANGED, { resource: 'workflow', action: 'update' });
      await new Promise(r => setTimeout(r, 30));
    });
    expect(h.countOf('/workflows')).toBe(before);
    // 草稿仍在（没被重拉覆盖）
    expect((descInput as HTMLInputElement).value).toBe('我改了一半还没保存');
  });
});
