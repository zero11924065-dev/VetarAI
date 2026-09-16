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

import { jsonRes, sseRes } from './helpers/fetchMock';

// 必须在 ChatPanel 模块求值前提供 localStorage（const API = getApiBase() 在导入时执行）
if (typeof (globalThis as any).localStorage === 'undefined') {
  (globalThis as any).localStorage = {
    _d: {} as Record<string,string>,
    getItem(k: string){ return this._d[k] ?? null; },
    setItem(k: string, v: string){ this._d[k] = String(v); },
    removeItem(k: string){ delete this._d[k]; },
    clear(){ this._d = {}; },
  };
}

// mock SSE 响应体（ReadableStream），模拟后端 /api/ollama/chat/stream
// 第 0 批（0.4.14）动作二：改用 helper 的原生 Response 构造器。
// 旧手写对象缺 headers/redirected/statusText/type 等 Response 成员，靠 `as any` 掩盖；
// impl 钉成 typeof fetch 后 tsc 如实报错（TS2322），故迁移到 sseRes（返回真实 Response）。
function mockSSEBody(events: string[]) {
  return sseRes(events);
}

const ev = (t: string, d: object) => `event: ${t}\ndata: ${JSON.stringify(d)}\n\n`;

beforeEach(() => {
  vi.restoreAllMocks();
  localStorage.clear();
  // getApiBase 依赖 window；测试里给个占位
  (globalThis as any).localStorage = (globalThis as any).localStorage || { getItem: () => null, setItem: () => {}, removeItem: () => {} };
});

describe('ChatPanel 流式渲染（mock SSE）', () => {
  it('折叠条出现 + content 累加 + 停止按钮可点', async () => {
    const sse = mockSSEBody([
      ev('token', { delta: '目录' }),
      ev('tool_call', { id: 'c1', name: 'list_dir', args: { path: '.' }, status: 'running' }),
      ev('tool_result', { id: 'c1', name: 'list_dir', ok: true, summary: '2 个条目' }),
      // REQ-MSG-021（0.4.28）：真实后端的 state.max 来自配置 max_tool_rounds（缺省 200），
      // 不再有硬编码 5；mock 载荷同步对齐真实协议（断言随之改 步骤 1/200）。
      ev('state', { step: 1, max: 200, tokens_used: 673 }),
      ev('token', { delta: '里有 2 个文件' }),
      ev('done', { content: '目录里有 2 个文件', tool_calls: [] }),
    ]);

    const impl: typeof fetch = async (url) => {
      const u = String(url);
      if (u.includes('/agents/')) return jsonRes([ { id:'a1', name:'测试Agent', role:'工程师' } ]);
      if (u.includes('/ollama/models')) return jsonRes([{name:'qwen3.8'}]);
      if (u.includes('/sessions?')) return jsonRes([{ id:'s1', title:'会话1', message_count:0 }]);
      if (u.includes('/sessions/s1/messages') || (u.includes('/sessions/') && u.includes('/messages'))) return jsonRes([]);
      if (u.includes('/chat/stream')) return sse;
      return jsonRes([]);
    };
    vi.spyOn(globalThis, 'fetch').mockImplementation(impl);

    const { unmount } = render(<ChatPanel projectId="p1" agentId="a1" />);

    // 已有会话（store 预置）→ 切换到它，使 currentSessionId 非空
    await waitFor(() => {
      const sel = document.querySelector('select') as HTMLSelectElement;
      expect(sel).toBeTruthy();
      expect(Array.from((sel as HTMLSelectElement).options).some(o => o.value === 's1')).toBe(true);
    }, { timeout: 3000 });
    await act(async () => {
      const sel = document.querySelector('select') as HTMLSelectElement;
      const setter = Object.getOwnPropertyDescriptor(window.HTMLSelectElement.prototype, 'value')!.set!;
      setter.call(sel, 's1');
      sel.dispatchEvent(new Event('change', { bubbles: true }));
    });

    // 输入并发送（测试侧记录发送时 currentSessionId 是否非空）
    const inputEl = document.querySelector('textarea[placeholder*="输入消息"]') as HTMLTextAreaElement;
    expect(inputEl).toBeTruthy();
    await act(async () => {
      const setter = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value')!.set!;
      setter.call(inputEl, '列出目录');
      inputEl.dispatchEvent(new Event('input', { bubbles: true }));
    });
    await act(async () => {
      (document.querySelector('button[data-tip="发送"]') as HTMLElement).click();
    });

    // ⛔ 此处**原有**一条"tool_call 后出现『正在调用 list_dir』"的中间态断言，已删除——
    // 它依赖时序：本 mock 流是瞬间读完的（enqueue 后立即 close），done 一到整组工具步骤即
    // 折叠（B4），"正在调用 …"这个运行中态根本来不及被观察到 → 这正是本文件长期 flaky 的根源。
    // 「运行中必须保持展开」的语义改由 chatPanelB4Collapse.test.tsx 用例⑤ 覆盖
    // （它用**不发 tool_result/done** 的流，让运行态稳定停留，不再赌时序）。
    // 这里只断言最终稳定态：工具步骤确实产生了（下方折叠摘要 + 展开后的 list_dir 完成）。

    // content 累加（done 后完整）
    await waitFor(() => {
      expect(screen.getByText(/目录里有 2 个文件/)).toBeTruthy();
    }, { timeout: 3000 });

    // 折叠条最终状态：✅ list_dir 完成
    // B4（0.4.12）适配：流结束后工具步骤**整组**收拢为一行摘要（不再逐条常驻），
    // 故先断言收拢摘要，再展开验证单条状态仍为"完成"——原语义保留，未被折叠吃掉。
    // ⛔ 这是 B4 的预期新行为，不是产品回归。
    await waitFor(() => {
      const bar = Array.from(document.querySelectorAll('div')).find(
        d => d.style.height === '28px' && /工具调用 \d+ 步/.test(d.textContent || '')) as HTMLElement | undefined;
      expect(bar).toBeTruthy();
      expect(bar!.textContent).toContain('工具调用 1 步');
      expect(bar!.textContent).toContain('已完成');
    }, { timeout: 3000 });
    await act(async () => {
      const bar = Array.from(document.querySelectorAll('div')).find(
        d => d.style.height === '28px' && /工具调用 \d+ 步/.test(d.textContent || '')) as HTMLElement;
      bar.click();
    });
    await waitFor(() => {
      expect(screen.getAllByText(/list_dir 完成/).length).toBeGreaterThan(0);
    }, { timeout: 3000 });

    // state 计数显示（REQ-MSG-021：分母与 0.4.28 真实后端协议对齐，max=配置缺省 200）
    await waitFor(() => {
      expect(screen.getByText(/步骤 1\/200/)).toBeTruthy();
    }, { timeout: 3000 });

    // 停止按钮：生成中应出现；生成结束后消失（这里验证按钮逻辑存在且可点——用发送中状态）
    // 由于 mock 流瞬间结束，直接验证 handleStop 不抛：找停止按钮或在 sending 时存在
    // 这里断言发送按钮（非发送中态）存在，说明 UI 渲染正常
    expect(document.querySelector('button[data-tip="发送"]')).toBeTruthy();
    // 验收修复：上传按钮必须存在（checkpoint-003 重写时丢失，防回归）
    // 0.4.6：提示属性统一为 data-tip（即时提示），查询同步更新
    expect(document.querySelector('button[data-tip*="上传"]')).toBeTruthy();

    unmount();
  }, 8000);
});

describe('B02/B05/B07（TS-101）串话防护 + 缓存同步', () => {
  function setupFetch(sseBody: Response) {
    const impl2: typeof fetch = async (url) => {
      const u = String(url);
      if (u.includes('/agents/')) return jsonRes([ { id:'a1', name:'测试Agent', role:'工程师' } ]);
      if (u.includes('/ollama/models')) return jsonRes([{name:'qwen3.8'}]);
      if (u.includes('/sessions?')) return jsonRes([
        { id:'s1', title:'会话A', message_count:0 },
        { id:'s2', title:'会话B', message_count:0 },
      ]);
      if (u.includes('/messages')) return jsonRes([]);
      if (u.includes('/chat/stream')) return sseBody;
      return jsonRes([]);
    };
    return vi.spyOn(globalThis, 'fetch').mockImplementation(impl2);
  }

  it('流式中切换会话：旧流 token 不串入新会话；done 后原会话缓存有完整内容', async () => {
    // sse 流：先慢速吐 token（用 Promise 控节奏），再 done
    let release: (v: void) => void;
    const gate = new Promise<void>(r => { release = r; });
    const stream = new ReadableStream({
      async start(controller) {
        const enc = new TextEncoder();
        controller.enqueue(enc.encode('event: token\ndata: {"delta":"旧流文字"}\n\n'));
        await gate; // 等测试切会话
        controller.enqueue(enc.encode('event: token\ndata: {"delta":"继续串话?"}\n\n'));
        controller.enqueue(enc.encode('event: done\ndata: {"content":"旧流文字继续串话?"}\n\n'));
        controller.close();
      },
    });
    // 第 0 批（0.4.14）动作二：该 stream 用 gate(Promise) 控节奏（先吐 token → 等测试切会话 →
    // 再吐 done），是本用例特有的时序构造，helper 通用构造器不适用；故保留 stream，
    // 只把手写假 response 换成**原生 Response**，让 typeof fetch 约束成立。
    const sseBody = new Response(stream, { status: 200, headers: { 'Content-Type': 'text/event-stream' } });
    setupFetch(sseBody);
    localStorage.clear();

    const { unmount } = render(<ChatPanel projectId="p1" agentId="a1" />);

    const sel = () => document.querySelector('select') as HTMLSelectElement;
    await waitFor(() => expect(Array.from(sel().options).some(o => o.value === 's2')).toBe(true), { timeout: 3000 });

    // 切到 s1 并发送
    await act(async () => {
      const setter = Object.getOwnPropertyDescriptor(window.HTMLSelectElement.prototype, 'value')!.set!;
      setter.call(sel(), 's1');
      sel().dispatchEvent(new Event('change', { bubbles: true }));
    });
    const inputEl = document.querySelector('textarea[placeholder*="输入消息"]') as HTMLTextAreaElement;
    await act(async () => {
      const setter = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value')!.set!;
      setter.call(inputEl, '触发流');
      inputEl.dispatchEvent(new Event('input', { bubbles: true }));
    });
    await act(async () => { (document.querySelector('button[data-tip="发送"]') as HTMLElement).click(); });

    // 第一个 token 应已进入 s1 的流式气泡
    await waitFor(() => expect(screen.getByText(/旧流文字/)).toBeTruthy(), { timeout: 3000 });

    // 流未结束时切到 s2（B02 场景）
    await act(async () => {
      const setter = Object.getOwnPropertyDescriptor(window.HTMLSelectElement.prototype, 'value')!.set!;
      setter.call(sel(), 's2');
      sel().dispatchEvent(new Event('change', { bubbles: true }));
    });
    // 切走后 s2 的本地消息列表为空（新会话）
    expect(screen.queryByText(/旧流文字/)).toBeFalsy();

    // 放行旧流继续吐 token + done → 这些事件必须只写 s1，不串 s2
    release!();
    await new Promise(r => setTimeout(r, 300)); // 等 reader 循环消费完 + 缓存同步
    const dbgCache = JSON.parse(localStorage.getItem('subagent_messages_v4') || '{}');
    expect(dbgCache['s1']).toBeTruthy();

    // B07：s1 缓存含完整 done 内容；s2 缓存无旧流内容（无串话）。
    // checkpoint-055：切换会话会做一次 DB 合并加载并回写缓存，s2 可能为空数组——
    // 串话防护的本质是"旧流内容不进 s2"，而非"s2 键不存在"。
    const cache = JSON.parse(localStorage.getItem('subagent_messages_v4') || '{}');
    const s1asst = (cache['s1'] || []).filter((m: any) => m.role === 'assistant');
    expect(s1asst.length).toBe(1);
    expect(s1asst[0].content).toContain('旧流文字继续串话?');
    const s2msgs = cache['s2'] || [];
    expect(s2msgs.every((m: any) => !(m.content || '').includes('旧流文字'))).toBe(true);
    expect(s2msgs.filter((m: any) => m.role === 'assistant').length).toBe(0);

    unmount();
  }, 10000);
});
