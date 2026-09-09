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

/**
 * B4（0.4.12）回归：工具调用步骤完成后应折叠，不再常驻会话窗。
 *
 * ⛔ 三个必须锁死的语义（每个都对应一个"看起来修好了其实没有"的坑）：
 *   ① **运行中必须展开**：流还在跑时把步骤收起来 = 用户完全看不到 agent 在干什么。
 *   ② **失败不能被折叠藏起来**：收拢行必须标出失败数并用警示色。否则用户以为一切正常，
 *      排查线索被藏掉——这比"不折叠"更糟。
 *   ③ **用户手动展开后不得被自动行为覆盖**：自动收拢只在状态跃迁那一次生效。
 *
 * 另：done 判据**不能用 msg.stopped**——DB 加载的历史消息不带 stopped（只有缓存恢复才置位），
 * 而历史消息的工具步骤恰恰最该折叠。故本文件用"历史消息带 toolSteps"专门覆盖这一条。
 */

if (typeof (globalThis as any).localStorage === 'undefined') {
  (globalThis as any).localStorage = {
    _d: {} as Record<string, string>,
    getItem(k: string) { return this._d[k] ?? null; },
    setItem(k: string, v: string) { this._d[k] = String(v); },
    removeItem(k: string) { delete this._d[k]; },
    clear() { this._d = {}; },
  };
}

// 第 0 批（0.4.14）动作二：迁移到类型化 fetch mock —— helper 返回原生 Response，
// 去掉 `as any`，使桩与真实签名的分歧在 tsc 阶段暴露（而非运行时静默假绿）。
// 本地 ev 改用 helper 的 sseEvent 别名导入（本文件有 18 处调用，别名可让调用点零改动），
// 消除各测试文件重复实现的 SSE 行构造逻辑。
import { sseRes, jsonRes, sseEvent as ev } from './helpers/fetchMock';

/** 构造 SSE 流：tool_call → tool_result(ok/error) → token → done。 */
function mockStreamBody(events: string[]) {
  return sseRes(events);
}

function installFetchMock(sseBody: Response) {
  const impl: typeof fetch = async (url) => {
    const u = String(url);
    if (u.includes('/agents/')) return jsonRes([{ id: 'a1', name: '测试', role: 'x' }]);
    if (u.includes('/ollama/models')) return jsonRes([{ name: 'qwen3.8' }]);
    if (u.includes('/sessions?')) return jsonRes([{ id: 's1', title: '会话1', message_count: 1 }]);
    if (u.includes('/messages')) return jsonRes([]);
    if (u.includes('/ollama/chat/stream')) return sseBody;
    return jsonRes([]);
  };
  vi.spyOn(globalThis, 'fetch').mockImplementation(impl);
}

/**
 * ⛔ 必须 act() + 原生 setter 派发 input，不能用 fireEvent.change/click。
 * fireEvent 不在 act 里 → handleSend 的异步流消费产生的 setState 不会被 flush，
 * 症状是"用户气泡渲染了、assistant 气泡建出来但内容为空"，极易误判为产品缺陷。
 */
async function sendText(value: string) {
  const ta = document.querySelector('textarea') as HTMLTextAreaElement;
  if (!ta) throw new Error('未找到输入框');
  await act(async () => {
    const setter = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value')!.set!;
    setter.call(ta, value);
    ta.dispatchEvent(new Event('input', { bubbles: true }));
  });
  await act(async () => {
    const btn = Array.from(document.querySelectorAll('button'))
      .find(b => b.getAttribute('data-tip') === '发送') as HTMLElement;
    if (!btn) throw new Error('未找到发送按钮');
    btn.click();
  });
}

/** 收拢行判据：含"工具调用 N 步"且高度 28（展开态组头是 22 且文案不同）。 */
function findCollapsedBar(): HTMLElement | null {
  const all = Array.from(document.querySelectorAll('div')) as HTMLElement[];
  return all.find(d => d.style.height === '28px' && /工具调用 \d+ 步/.test(d.textContent || '')) || null;
}

beforeEach(() => {
  vi.restoreAllMocks();
  localStorage.clear();
});

describe('B4 工具步骤完成后折叠', () => {
  it('① 流结束后整组收拢为一行（步骤名不再逐条常驻）', async () => {
    localStorage.setItem('subagent_messages_v4', JSON.stringify({ s1: [] }));
    installFetchMock(mockStreamBody([
      ev('tool_call', { id: 'c1', name: 'list_dir', args: { path: '.' }, status: 'running' }),
      ev('tool_result', { id: 'c1', name: 'list_dir', ok: true, summary: '3 个条目' }),
      ev('tool_call', { id: 'c2', name: 'read_file', args: { path: 'a.py' }, status: 'running' }),
      ev('tool_result', { id: 'c2', name: 'read_file', ok: true, summary: '已读 120 行' }),
      ev('token', { delta: '正文回答' }),
      ev('done', { content: '正文回答', tool_calls: [] }),
    ]));

    render(<ChatPanel projectId="p1" agentId="a1" />);
    await waitFor(() => expect(document.querySelector('textarea')).toBeTruthy(), { timeout: 3000 });
    await sendText('列出并读取');
    await waitFor(() => expect(screen.getByText(/正文回答/)).toBeTruthy(), { timeout: 4000 });

    // 收拢为一行摘要
    const bar = findCollapsedBar();
    expect(bar).toBeTruthy();
    expect(bar!.textContent).toContain('工具调用 2 步');
    expect(bar!.textContent).toContain('已完成');
    // ⛔ 关键：逐条步骤条（"list_dir 完成（…）"）不再常驻
    expect(document.body.textContent).not.toContain('list_dir 完成');
    expect(document.body.textContent).not.toContain('read_file 完成');
  });

  it('② 收拢后点击可重新展开，展开后步骤逐条可见（信息不丢）', async () => {
    localStorage.setItem('subagent_messages_v4', JSON.stringify({ s1: [] }));
    installFetchMock(mockStreamBody([
      ev('tool_call', { id: 'c1', name: 'list_dir', args: { path: '.' }, status: 'running' }),
      ev('tool_result', { id: 'c1', name: 'list_dir', ok: true, summary: '3 个条目' }),
      ev('token', { delta: '正文' }),
      ev('done', { content: '正文', tool_calls: [] }),
    ]));

    render(<ChatPanel projectId="p1" agentId="a1" />);
    await waitFor(() => expect(document.querySelector('textarea')).toBeTruthy(), { timeout: 3000 });
    await sendText('列出目录');
    await waitFor(() => expect(screen.getByText(/正文/)).toBeTruthy(), { timeout: 4000 });

    const bar = findCollapsedBar();
    expect(bar).toBeTruthy();
    await act(async () => { bar!.click(); });

    // 展开后单条折叠条回来了
    await waitFor(() => expect(document.body.textContent).toContain('list_dir 完成'), { timeout: 2000 });
    // 收拢行消失
    expect(findCollapsedBar()).toBeNull();
  });

  it('③ ⛔ 失败步骤不得被折叠藏起来：收拢行标出失败数 + 警示色', async () => {
    localStorage.setItem('subagent_messages_v4', JSON.stringify({ s1: [] }));
    installFetchMock(mockStreamBody([
      ev('tool_call', { id: 'c1', name: 'read_file', args: { path: 'missing.py' }, status: 'running' }),
      ev('tool_result', { id: 'c1', name: 'read_file', ok: false, error: '文件不存在' }),
      ev('tool_call', { id: 'c2', name: 'list_dir', args: { path: '.' }, status: 'running' }),
      ev('tool_result', { id: 'c2', name: 'list_dir', ok: true, summary: '3 个条目' }),
      ev('token', { delta: '部分成功' }),
      ev('done', { content: '部分成功', tool_calls: [] }),
    ]));

    render(<ChatPanel projectId="p1" agentId="a1" />);
    await waitFor(() => expect(document.querySelector('textarea')).toBeTruthy(), { timeout: 3000 });
    await sendText('读文件并列目录');
    await waitFor(() => expect(screen.getByText(/部分成功/)).toBeTruthy(), { timeout: 4000 });

    const bar = findCollapsedBar();
    expect(bar).toBeTruthy();
    // 失败数必须显眼标出——不能只说"已完成"
    expect(bar!.textContent).toContain('1 失败');
    expect(bar!.textContent).toContain('1 成功');
    expect(bar!.textContent).not.toContain('已完成'); // 有失败时不得谎报全部完成
    // 警示色（warnBg #FFF7EC）与警示边框，区别于正常灰底。
    // ⛔ jsdom 会把 hex 归一化成 rgb()，故两种写法都接受——这里验的是"用了警示色"这个语义，
    // 不是特定字符串格式。#FFF7EC = rgb(255,247,236)；#F5DFB8 = rgb(245,223,184)。
    const bg = bar!.style.background.toLowerCase().replace(/\s+/g, '');
    const bd = bar!.style.border.toLowerCase().replace(/\s+/g, '');
    expect(bg === 'fff7ec' || bg.includes('rgb(255,247,236)')).toBe(true);
    expect(bd.includes('f5dfb8') || bd.includes('rgb(245,223,184)')).toBe(true);
  });

  it('④ 历史消息（DB 加载、不带 stopped）同样折叠——done 判据不得依赖 msg.stopped', async () => {
    // 历史 assistant 消息带 toolSteps，且**不含 stopped 字段**（DB 加载的真实形态）
    localStorage.setItem('subagent_messages_v4', JSON.stringify({
      s1: [
        { id: 'h1', role: 'user', content: '历史问题' },
        { id: 'h2', role: 'assistant', content: '历史回答', toolSteps: [
          { id: 'x1', name: 'list_dir', status: 'ok', summary: '3 个条目' },
          { id: 'x2', name: 'read_file', status: 'ok', summary: '已读' },
        ] },
      ],
    }));
    installFetchMock(mockStreamBody([ev('done', { content: '', tool_calls: [] })]));

    render(<ChatPanel projectId="p1" agentId="a1" />);
    await waitFor(() => expect(screen.getByText(/历史回答/)).toBeTruthy(), { timeout: 4000 });

    // 历史步骤必须已折叠（若 done 判据错用 msg.stopped，这里会保持展开）
    const bar = findCollapsedBar();
    expect(bar).toBeTruthy();
    expect(bar!.textContent).toContain('工具调用 2 步');
    expect(document.body.textContent).not.toContain('list_dir 完成');
  });

  it('⑤ 运行中必须保持展开（不得提前把正在执行的步骤藏起来）', async () => {
    // 只发 tool_call(running)，不发 tool_result / done → 模拟流仍在进行
    localStorage.setItem('subagent_messages_v4', JSON.stringify({ s1: [] }));
    installFetchMock(mockStreamBody([
      ev('tool_call', { id: 'c1', name: 'list_dir', args: { path: '.' }, status: 'running' }),
    ]));

    render(<ChatPanel projectId="p1" agentId="a1" />);
    await waitFor(() => expect(document.querySelector('textarea')).toBeTruthy(), { timeout: 3000 });
    await sendText('列出目录');

    // 运行中：步骤条可见，且**没有**收拢行
    await waitFor(() => expect(document.body.textContent).toContain('正在调用 list_dir'), { timeout: 4000 });
    expect(findCollapsedBar()).toBeNull();
  });
});
