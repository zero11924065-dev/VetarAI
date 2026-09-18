/*
 * VetarAI - Local-first multi-agent orchestration application
 * Copyright (C) 2026 zero11924065-dev
 * GPL-3.0-or-later（见仓库 LICENSE）
 */
/**
 * R2（0.4.33）授权记忆专项：「本会话不再询问 / 永久允许」。
 *
 * 两层覆盖：
 *   A. Dialog 单元层（confirmDialog 新选项）：
 *      - 配了 rememberSessionLabel/rememberAlwaysLabel → 渲染两枚附加按钮；
 *      - 点附加按钮 = 批准 + onRemember(mode) 回传级别，resolve(true)；
 *      - 点普通「允许」/「拒绝」/Esc → 不回传 onRemember（仅本次）。
 *   B. ChatPanel 集成层（auth_request SSE 分支）：
 *      - 敏感路径授权弹窗带两枚记忆按钮，点「永久允许」→ POST /auth/respond
 *        带 remember:"always"；点普通「允许」→ 不带 remember 字段（向后兼容）；
 *      - 联网安装（net_install）弹窗⛔不得出现记忆按钮（安全敏感，每次必问），
 *        响应体也不带 remember。
 *
 * ⛔ Dialog.tsx 是模块级单例（渲染进 document.body，跨用例不自动卸载）——
 *   每个用例必须自己收尾：点按钮关掉弹窗 + 清 [role="dialog"] 残留（dialogChoice 同纪律）。
 */
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, waitFor, act, fireEvent } from '@testing-library/react';
import React from 'react';
import { confirmDialog } from '../Dialog';
import { ChatPanel } from '../panels/ChatPanel';
import { jsonRes, sseEvent, tokenEvent, doneEvent, sseRes, installFetchMock, routeJson } from './helpers/fetchMock';

if (typeof (globalThis as any).localStorage === 'undefined') {
  (globalThis as any).localStorage = {
    _d: {} as Record<string, string>,
    getItem(k: string) { return this._d[k] ?? null; },
    setItem(k: string, v: string) { this._d[k] = String(v); },
    removeItem(k: string) { delete this._d[k]; },
    clear() { this._d = {}; },
  };
}

let unmountChat: (() => void) | null = null;

beforeEach(() => {
  vi.restoreAllMocks();
  localStorage.clear();
  if (unmountChat) { unmountChat(); unmountChat = null; }
  // 清掉上个用例可能残留的弹窗 DOM（模块级单例，不随 ChatPanel 卸载）
  document.querySelectorAll('[role="dialog"]').forEach(n => n.remove());
});

// ────────────────────────────────────────────────────────────────────────────
// A. Dialog 单元层
// ────────────────────────────────────────────────────────────────────────────
describe('R2-A confirmDialog 授权记忆附加按钮', () => {
  it('A1 配了记忆 label → 渲染「本会话不再询问 / 永久允许」；点会话级 → onRemember("session") + resolve(true)', async () => {
    let p: Promise<boolean> | null = null;
    const modes: string[] = [];
    await act(async () => {
      p = confirmDialog({
        title: '操作授权', message: 'x', confirmText: '允许', cancelText: '拒绝',
        rememberSessionLabel: '本会话不再询问', rememberAlwaysLabel: '永久允许',
        onRemember: (m) => { modes.push(m); },
      });
    });
    await waitFor(() => expect(screen.getByRole('dialog')).toBeTruthy());
    expect(screen.getByText('本会话不再询问')).toBeTruthy();
    expect(screen.getByText('永久允许')).toBeTruthy();
    await act(async () => { fireEvent.click(screen.getByText('本会话不再询问')); });
    await expect(p).resolves.toBe(true);
    expect(modes).toEqual(['session']);
  });

  it('A2 点「永久允许」→ onRemember("always") + resolve(true)', async () => {
    let p: Promise<boolean> | null = null;
    const modes: string[] = [];
    await act(async () => {
      p = confirmDialog({
        title: '操作授权', message: 'x', confirmText: '允许', cancelText: '拒绝',
        rememberSessionLabel: '本会话不再询问', rememberAlwaysLabel: '永久允许',
        onRemember: (m) => { modes.push(m); },
      });
    });
    await waitFor(() => expect(screen.getByRole('dialog')).toBeTruthy());
    await act(async () => { fireEvent.click(screen.getByText('永久允许')); });
    await expect(p).resolves.toBe(true);
    expect(modes).toEqual(['always']);
  });

  it('A3 普通「允许」/「拒绝」/Esc 均不回传 onRemember（仅本次）', async () => {
    // 普通允许
    let p: Promise<boolean> | null = null;
    const modes: string[] = [];
    await act(async () => {
      p = confirmDialog({
        title: 't', message: 'x', confirmText: '允许', cancelText: '拒绝',
        rememberSessionLabel: '本会话不再询问', rememberAlwaysLabel: '永久允许',
        onRemember: (m) => { modes.push(m); },
      });
    });
    await waitFor(() => expect(screen.getByRole('dialog')).toBeTruthy());
    await act(async () => { fireEvent.click(screen.getByText('允许')); });
    await expect(p).resolves.toBe(true);
    expect(modes).toEqual([]);

    // 拒绝
    p = null;
    await act(async () => {
      p = confirmDialog({
        title: 't', message: 'x', confirmText: '允许', cancelText: '拒绝',
        rememberSessionLabel: '本会话不再询问', rememberAlwaysLabel: '永久允许',
        onRemember: (m) => { modes.push(m); },
      });
    });
    await waitFor(() => expect(screen.getByRole('dialog')).toBeTruthy());
    await act(async () => { fireEvent.click(screen.getByText('拒绝')); });
    await expect(p).resolves.toBe(false);
    expect(modes).toEqual([]);

    // Esc
    p = null;
    await act(async () => {
      p = confirmDialog({
        title: 't', message: 'x', confirmText: '允许', cancelText: '拒绝',
        rememberSessionLabel: '本会话不再询问', rememberAlwaysLabel: '永久允许',
        onRemember: (m) => { modes.push(m); },
      });
    });
    await waitFor(() => expect(screen.getByRole('dialog')).toBeTruthy());
    await act(async () => { window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' })); });
    await expect(p).resolves.toBe(false);
    expect(modes).toEqual([]);
  });

  it('A4 不配记忆 label → 不渲染附加按钮（联网安装等既有弹窗零变化）', async () => {
    let p: Promise<boolean> | null = null;
    await act(async () => {
      p = confirmDialog({ title: 't', message: 'x', confirmText: '允许安装', cancelText: '拒绝' });
    });
    await waitFor(() => expect(screen.getByRole('dialog')).toBeTruthy());
    expect(screen.queryByText('本会话不再询问')).toBeNull();
    expect(screen.queryByText('永久允许')).toBeNull();
    await act(async () => { fireEvent.click(screen.getByText('拒绝')); });
    await expect(p).resolves.toBe(false);
  });
});

// ────────────────────────────────────────────────────────────────────────────
// B. ChatPanel 集成层：auth_request → 弹窗 → /auth/respond 载荷
// ────────────────────────────────────────────────────────────────────────────
const authReq = (rid: string, action: string, extra: Record<string, unknown> = {}) =>
  sseEvent('auth_request', {
    request_id: rid,
    tool_name: action === 'net_install' ? 'install_skill' : 'write_file',
    target_path: action === 'net_install' ? 'https://github.com/x/y' : '/etc/hosts',
    action, extra,
  });

/** 挂载 ChatPanel 并发出一条消息触发 SSE 流（流内含一个 auth_request 事件）。 */
async function mountAndSend(events: string[]) {
  const handle = installFetchMock([
    routeJson('/agents/', [{ id: 'a1', name: '测试', role: 'x', model_name: 'm' }]),
    routeJson('/ollama/models', [{ name: 'm' }]),
    routeJson('/sessions?', [{ id: 's1', title: '会话1', message_count: 0 }]),
    routeJson('/context/limit', { context_length: 0, source: 'error' }),
    routeJson('/config', { reconnect_max_attempts: 3 }),
    routeJson('/messages', []),
    routeJson('/auth/respond', { ok: true }),
    (url) => (url.includes('/ollama/chat/stream') ? sseRes(events) : null),
  ]);
  const r = render(<ChatPanel projectId="p1" agentId="a1" />);
  unmountChat = r.unmount;

  // ⛔ 必须等 s1 的 <option> 真正渲染出来再选中：会话列表未加载时 select 只有
  // 「无会话」一项，原生 setter 赋 's1' 会因无匹配 option 落空为 ''（selectedIndex=-1），
  // onChange('') → currentSessionId='' → 发送时被当成"无会话"新建会话 2，流根本不会发出
  // （冷启动首用例必踩：初始 fetch 未完成时 change 已派发）。
  await waitFor(() => expect(document.querySelector('select option[value="s1"]')).toBeTruthy(), { timeout: 3000 });
  // 选中会话 s1
  await act(async () => {
    const sel = document.querySelector('select') as HTMLSelectElement;
    const setter = Object.getOwnPropertyDescriptor(window.HTMLSelectElement.prototype, 'value')!.set!;
    setter.call(sel, 's1');
    sel.dispatchEvent(new Event('change', { bubbles: true }));
  });
  const inputEl = document.querySelector('textarea[placeholder*="输入消息"]') as HTMLTextAreaElement;
  await act(async () => {
    const setter = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value')!.set!;
    setter.call(inputEl, '写个文件');
    inputEl.dispatchEvent(new Event('input', { bubbles: true }));
  });
  await act(async () => { (document.querySelector('button[data-tip="发送"]') as HTMLElement).click(); });
  return handle;
}

describe('R2-B ChatPanel auth_request 记忆按钮与 respond 载荷', () => {
  it('B1 敏感路径弹窗带记忆按钮；点「永久允许」→ respond 带 remember:"always"', async () => {
    const handle = await mountAndSend([
      authReq('r1', 'write'), tokenEvent('好'), doneEvent('好'),
    ]);
    await waitFor(() => expect(screen.getByText('操作授权')).toBeTruthy(), { timeout: 4000 });
    expect(screen.getByText('本会话不再询问')).toBeTruthy();
    expect(screen.getByText('永久允许')).toBeTruthy();
    await act(async () => { fireEvent.click(screen.getByText('永久允许')); });
    await waitFor(() => expect(handle.countOf('/auth/respond')).toBe(1), { timeout: 3000 });
    const body = handle.lastBodyOf('/auth/respond');
    expect(body).toMatchObject({ request_id: 'r1', allowed: true, remember: 'always' });
  });

  it('B2 点「本会话不再询问」→ respond 带 remember:"session"', async () => {
    const handle = await mountAndSend([
      authReq('r2', 'write'), tokenEvent('好'), doneEvent('好'),
    ]);
    await waitFor(() => expect(screen.getByText('操作授权')).toBeTruthy(), { timeout: 4000 });
    await act(async () => { fireEvent.click(screen.getByText('本会话不再询问')); });
    await waitFor(() => expect(handle.countOf('/auth/respond')).toBe(1), { timeout: 3000 });
    expect(handle.lastBodyOf('/auth/respond'))
      .toMatchObject({ request_id: 'r2', allowed: true, remember: 'session' });
  });

  it('B3 普通「允许」→ respond 不带 remember 字段（向后兼容旧语义）', async () => {
    const handle = await mountAndSend([
      authReq('r3', 'write'), tokenEvent('好'), doneEvent('好'),
    ]);
    await waitFor(() => expect(screen.getByText('操作授权')).toBeTruthy(), { timeout: 4000 });
    await act(async () => { fireEvent.click(screen.getByText('允许')); });
    await waitFor(() => expect(handle.countOf('/auth/respond')).toBe(1), { timeout: 3000 });
    const body = handle.lastBodyOf('/auth/respond');
    expect(body).toMatchObject({ request_id: 'r3', allowed: true });
    expect('remember' in body).toBe(false);
  });

  it('B4 ⛔ 联网安装弹窗不得出现记忆按钮（安全敏感每次必问），respond 不带 remember', async () => {
    const handle = await mountAndSend([
      authReq('r4', 'net_install', {
        kind: 'net_install', source_url: 'https://github.com/x/y',
        install_type: '技能（Skill）', current_mode: 'auto', need_enable_network: true,
      }),
      tokenEvent('好'), doneEvent('好'),
    ]);
    await waitFor(() => expect(screen.getByText('联网安装确认')).toBeTruthy(), { timeout: 4000 });
    // ⛔ 核心断言：记忆按钮不存在（每次必问）；勾选「同时开启全量联网」仍在
    expect(screen.queryByText('本会话不再询问')).toBeNull();
    expect(screen.queryByText('永久允许')).toBeNull();
    expect(screen.getByText(/同时开启全量联网/)).toBeTruthy();
    await act(async () => { fireEvent.click(screen.getByText('允许安装')); });
    await waitFor(() => expect(handle.countOf('/auth/respond')).toBe(1), { timeout: 3000 });
    const body = handle.lastBodyOf('/auth/respond');
    expect(body).toMatchObject({ request_id: 'r4', allowed: true, enable_network: true });
    expect('remember' in body).toBe(false);
  });

  it('B5 电脑操作（computer_use）弹窗同样带记忆按钮', async () => {
    const handle = await mountAndSend([
      sseEvent('auth_request', {
        request_id: 'r5', tool_name: 'computer_use:mouse_click',
        target_path: '{"x":100,"y":200}', action: 'computer_use',
        extra: { kind: 'computer_use', tool: 'mouse_click', desc: '点击屏幕',
                 args: { x: 100, y: 200 }, app: 'Finder' },
      }),
      tokenEvent('好'), doneEvent('好'),
    ]);
    await waitFor(() => expect(screen.getByText('电脑操作确认')).toBeTruthy(), { timeout: 4000 });
    expect(screen.getByText('本会话不再询问')).toBeTruthy();
    expect(screen.getByText('永久允许')).toBeTruthy();
    await act(async () => { fireEvent.click(screen.getByText('本会话不再询问')); });
    await waitFor(() => expect(handle.countOf('/auth/respond')).toBe(1), { timeout: 3000 });
    expect(handle.lastBodyOf('/auth/respond'))
      .toMatchObject({ request_id: 'r5', allowed: true, remember: 'session' });
  });
});
