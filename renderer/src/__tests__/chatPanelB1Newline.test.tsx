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
import { render, screen, waitFor, fireEvent } from '@testing-library/react';
import React from 'react';
import { ChatPanel } from '../panels/ChatPanel';

/**
 * B1（0.4.12）回归：输入框换行在会话中保留，且发给模型的载荷不被剥空白。
 *
 * ⛔ 根因（本文件锁死的核心语义）：判空用的 cleanText ≠ 消息内容。
 *   `input.replace(/[\s\u00A0\u200B-\u200F\u2060\uFEFF\u00AD]/g,'')` 里的 `\s` 同时匹配
 *   **换行与普通空格**。此前该"判空值"被直接 push 进气泡 content，而 apiMessages 又派生自
 *   气泡 content，导致：
 *     ① 用户 Shift+Enter 打的换行在会话里丢失（用户报告的现象）；
 *     ② 更严重——发给后端 /ollama/chat/stream 的 messages 也被剥掉全部空白，
 *        英文 "please fix this bug" → "pleasefixthisbug"。
 *   修复后：判空仍严格（checkpoint-067 R-1 的原意，杜绝零宽/BOM 冒充有内容），
 *   内容改用 contentText（仅剔不可见字符、\u00A0 降级为空格、首尾 trim）。
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

// 第 0 批（0.4.14）动作二：迁移到类型化 fetch mock。
// ⛔ 旧写法手写 ReadableStream + 假 response 对象再 `as any` 收尾，tsc 完全不检查这个桩；
// 现改用 helper 的原生 Response 构造器 + `typeof fetch` 类型标注，脱节在编译期暴露。
import { sseRes, jsonRes, tokenEvent, doneEvent } from './helpers/fetchMock';

/** 最小 SSE 流：吐一个 token 再 done（载荷字段与后端 loop.py 权威结构一致）。 */
function mockStreamBody() {
  return sseRes([tokenEvent('ok'), doneEvent('ok')]);
}

/** 拦截所有 fetch，返回已选中 s1 会话的初始状态；把发送载荷记进 sent。 */
function installFetchMock(sent: any[]) {
  const impl: typeof fetch = async (url, init) => {
    const u = String(url);
    if (u.includes('/agents/')) return jsonRes([{ id: 'a1', name: '测试', role: 'x' }]);
    if (u.includes('/ollama/models')) return jsonRes([{ name: 'qwen3.8' }]);
    if (u.includes('/sessions?')) return jsonRes([{ id: 's1', title: '会话1', message_count: 1 }]);
    if (u.includes('/messages')) return jsonRes([]);
    if (u.includes('/ollama/chat/stream')) {
      // 捕获真实发给后端的载荷——B1 的关键断言对象
      try { sent.push(JSON.parse(String(init?.body ?? '{}'))); } catch { /* 忽略非法 body */ }
      return mockStreamBody();
    }
    return jsonRes([]);
  };
  vi.spyOn(globalThis, 'fetch').mockImplementation(impl);
}

function getTextarea(): HTMLTextAreaElement {
  const el = document.querySelector('textarea');
  if (!el) throw new Error('未找到输入框 textarea');
  return el as HTMLTextAreaElement;
}

function getSendButton(): HTMLElement {
  const btns = Array.from(document.querySelectorAll('button')) as HTMLElement[];
  const hit = btns.find(b => b.getAttribute('data-tip') === '发送');
  if (!hit) throw new Error('未找到发送按钮');
  return hit;
}

beforeEach(() => {
  vi.restoreAllMocks();
  localStorage.clear();
});

describe('B1 输入换行与空白保真（判空值不得当作消息内容）', () => {
  it('Shift+Enter 换行保留在会话气泡，且发给模型的 content 不被剥空白', async () => {
    // 预置缓存，使 s1 成为当前会话（否则 handleSend 会先去建新会话）
    localStorage.setItem('subagent_messages_v4', JSON.stringify({ s1: [] }));
    const sent: any[] = [];
    installFetchMock(sent);

    render(<ChatPanel projectId="p1" agentId="a1" />);
    await waitFor(() => expect(document.querySelector('textarea')).toBeTruthy(), { timeout: 3000 });

    // 含换行 + 词间空格的真实输入（英文空格是"剥空白"缺陷最敏感的探针）
    const raw = '第一行内容\nplease fix this bug\n第三行';
    fireEvent.change(getTextarea(), { target: { value: raw } });
    fireEvent.click(getSendButton());

    // ① 发给后端的载荷必须原样保留换行与空格
    await waitFor(() => expect(sent.length).toBeGreaterThan(0), { timeout: 3000 });
    const payload = sent[0];
    const userMsg = (payload.messages || []).find((m: any) => m.role === 'user');
    expect(userMsg).toBeTruthy();
    expect(userMsg.content).toBe(raw);
    expect(userMsg.content).toContain(' ');        // 词间空格未被剥
    expect(userMsg.content.split('\n')).toHaveLength(3); // 换行未被压成一行

    // ② 会话气泡同样保留换行（渲染层 whiteSpace:pre-wrap + content 原样）
    await waitFor(() => {
      expect(screen.getByText(/please fix this bug/)).toBeTruthy();
    }, { timeout: 3000 });
    const bubble = screen.getByText(/please fix this bug/);
    expect(bubble.textContent).toContain('第一行内容');
    expect(bubble.textContent).toContain('第三行');
    // pre-wrap 是换行可见的必要条件；若被改成 normal，\n 会塌成空格
    expect(String((bubble as HTMLElement).style.whiteSpace)).toBe('pre-wrap');
  });

  it('R-1 判空仍严格：纯零宽/BOM/不换行空格不发送（不得因修复而放行空白消息）', async () => {
    localStorage.setItem('subagent_messages_v4', JSON.stringify({ s1: [] }));
    const sent: any[] = [];
    installFetchMock(sent);

    render(<ChatPanel projectId="p1" agentId="a1" />);
    await waitFor(() => expect(document.querySelector('textarea')).toBeTruthy(), { timeout: 3000 });

    // 只有不可见字符 + 普通空白：必须被判定为"无内容"而不发送
    fireEvent.change(getTextarea(), { target: { value: '\u200B\uFEFF \n\u00A0\u00AD' } });
    fireEvent.click(getSendButton());

    // 等一拍确认没有发送（sent 为空）——发送按钮此时应处于 disabled
    await new Promise(r => setTimeout(r, 300));
    expect(sent).toHaveLength(0);
    expect((getSendButton() as HTMLButtonElement).disabled).toBe(true);
  });

  it('\u00A0 降级为普通空格而非删除：两侧单词不粘连', async () => {
    localStorage.setItem('subagent_messages_v4', JSON.stringify({ s1: [] }));
    const sent: any[] = [];
    installFetchMock(sent);

    render(<ChatPanel projectId="p1" agentId="a1" />);
    await waitFor(() => expect(document.querySelector('textarea')).toBeTruthy(), { timeout: 3000 });

    fireEvent.change(getTextarea(), { target: { value: 'foo\u00A0bar' } });
    fireEvent.click(getSendButton());

    await waitFor(() => expect(sent.length).toBeGreaterThan(0), { timeout: 3000 });
    const userMsg = (sent[0].messages || []).find((m: any) => m.role === 'user');
    expect(userMsg.content).toBe('foo bar'); // 不是 'foobar'
  });

  it('首尾空白仍被 trim（不改变既有整洁行为）', async () => {
    localStorage.setItem('subagent_messages_v4', JSON.stringify({ s1: [] }));
    const sent: any[] = [];
    installFetchMock(sent);

    render(<ChatPanel projectId="p1" agentId="a1" />);
    await waitFor(() => expect(document.querySelector('textarea')).toBeTruthy(), { timeout: 3000 });

    fireEvent.change(getTextarea(), { target: { value: '  \n hello \n  ' } });
    fireEvent.click(getSendButton());

    await waitFor(() => expect(sent.length).toBeGreaterThan(0), { timeout: 3000 });
    const userMsg = (sent[0].messages || []).find((m: any) => m.role === 'user');
    expect(userMsg.content).toBe('hello');
  });
});
