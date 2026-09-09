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
 * B3（0.4.12）回归：单条回复过长不换行、溢出聊天框。
 *
 * ⛔ 三个真实成因，本文件逐一锁死（缺一都会漏，且都可能"看起来修好了其实没有"）：
 *   ① `wordBreak:'break-word'` 是**已废弃别名**（word-break 规范值只有 normal|break-all|keep-all）。
 *      它只在"软换行机会"处生效，**无空格长串**（长 URL、base64、超长英文标识符）仍会撑破容器；
 *      标准写法是 `overflowWrap:'anywhere'`，它才把长串纳入断行计算。
 *   ② flex 子项默认 `min-width:auto`（不得小于内容宽度）→ 必须 `minWidth:0` 解开下限，
 *      否则再怎么写 overflow-wrap 也不会收缩。这是最隐蔽的一条：样式写了但**根本不生效**。
 *   ③ remarkGfm 已启用，但 components 此前只自定义了 code，`<table>` 是裸的 →
 *      宽表格直接撑破 maxWidth:78% 的气泡。表格**不能**断字（会打散单元格、破坏对齐），
 *      正解是包一层横向滚动容器。
 *
 * 断言取"样式属性"而非"像素宽度"——jsdom 不做布局，测不出真实换行；
 * 但属性值正是浏览器据以断行的输入，属性错则必然溢出。
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
// 本地 ev 改用 helper 的 sseEvent 别名导入，消除各测试文件重复实现的 SSE 行构造逻辑。
import { sseRes, jsonRes, sseEvent as ev } from './helpers/fetchMock';

/** 无空格长串：300 字符连续 URL，正是 break-word 抓不住、anywhere 才抓得住的场景。 */
const LONG_URL = 'https://example.com/' + 'a'.repeat(280);

/**
 * ⛔ 载荷必须与后端权威结构一致（sidecar/agent_engine/loop.py）：
 *   token → {"delta": ...}（:1036）
 *   done  → {"content": full_text, "tool_calls": [...]}（:1068）
 * done 带 content 尤其关键：前端"最终 content 以 done 为准"，若 done 不带 content，
 * 气泡内容就只能靠 requestAnimationFrame 增量 flush——而 jsdom 默认不提供 raf，
 * 测试会因"内容没渲染"失败，看起来像产品缺陷，实为 mock 失真。
 */
function mockStreamBody(assistantText: string) {
  return sseRes([ev('token', { delta: assistantText }), ev('done', { content: assistantText, tool_calls: [] })]);
}

function installFetchMock(sent: any[], assistantText: string) {
  const impl: typeof fetch = async (url, init) => {
    const u = String(url);
    if (u.includes('/agents/')) return jsonRes([{ id: 'a1', name: '测试', role: 'x' }]);
    if (u.includes('/ollama/models')) return jsonRes([{ name: 'qwen3.8' }]);
    if (u.includes('/sessions?')) return jsonRes([{ id: 's1', title: '会话1', message_count: 1 }]);
    if (u.includes('/messages')) return jsonRes([]);
    if (u.includes('/ollama/chat/stream')) {
      try { sent.push(JSON.parse(String(init?.body ?? '{}'))); } catch { /* ignore */ }
      return mockStreamBody(assistantText);
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

/**
 * ⛔ 必须用 act() + 原生 value setter 派发 input 事件，**不能用 fireEvent.change/click**。
 * 原因（本轮踩坑实录）：fireEvent 不在 act 里，点击后 handleSend 内部的异步流消费
 * （reader.read() → parser.push → setLocalMessages）产生的状态更新不会被 flush。
 * 症状极具误导性——用户气泡**能**渲染（同步 setState），assistant 气泡**建出来了但 content 为空**，
 * SSE 解析器也确认收到了完整 body 并产出了事件，看起来像"产品没渲染 assistant 内容"，
 * 实为测试触发路径不对。与既有通过的 chatPanelStream.test.tsx 保持同一范式。
 */
async function sendText(value: string) {
  const ta = getTextarea();
  await act(async () => {
    const setter = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value')!.set!;
    setter.call(ta, value);
    ta.dispatchEvent(new Event('input', { bubbles: true }));
  });
  await act(async () => { getSendButton().click(); });
}

/** 取样式断言用的规范值：overflowWrap 在 jsdom 里由 cssText 反映。 */
function overflowWrapOf(el: Element): string {
  return (el as HTMLElement).style.overflowWrap || '';
}
function minWidthOf(el: Element): string {
  return (el as HTMLElement).style.minWidth || '';
}

beforeEach(() => {
  vi.restoreAllMocks();
  localStorage.clear();
});

describe('B3 长文本换行与表格不溢出', () => {
  it('① assistant 长 URL：容器用标准 overflow-wrap:anywhere + minWidth:0（break-word 别名不足够）', async () => {
    localStorage.setItem('subagent_messages_v4', JSON.stringify({ s1: [] }));
    const sent: any[] = [];
    installFetchMock(sent, `请看这个链接 ${LONG_URL} 结束`);

    render(<ChatPanel projectId="p1" agentId="a1" />);
    await waitFor(() => expect(document.querySelector('textarea')).toBeTruthy(), { timeout: 3000 });

    await sendText('给我一个长链接');

    await waitFor(() => expect(screen.getByText(/请看这个链接/)).toBeTruthy(), { timeout: 4000 });
    const node = screen.getByText(/请看这个链接/);
    // StreamingMarkdown 的外层 div 是 node 的祖先
    const mdRoot = node.closest('div') as HTMLElement;
    expect(mdRoot).toBeTruthy();
    expect(overflowWrapOf(mdRoot)).toBe('anywhere');
    // minWidth:0 是 flex 子项收缩的前提——缺了它 overflow-wrap 形同虚设
    expect(minWidthOf(mdRoot)).toBe('0px');
    // 长串必须完整在 DOM 里（未被截断/丢弃）
    expect(mdRoot.textContent).toContain(LONG_URL);
  });

  it('② 用户消息气泡：同样具备 overflow-wrap:anywhere + minWidth:0', async () => {
    localStorage.setItem('subagent_messages_v4', JSON.stringify({ s1: [] }));
    const sent: any[] = [];
    installFetchMock(sent, 'ok');

    render(<ChatPanel projectId="p1" agentId="a1" />);
    await waitFor(() => expect(document.querySelector('textarea')).toBeTruthy(), { timeout: 3000 });

    await sendText(LONG_URL);

    await waitFor(() => expect(screen.getByText(new RegExp(LONG_URL.slice(0, 40)))).toBeTruthy(), { timeout: 4000 });
    const bubble = screen.getByText(new RegExp(LONG_URL.slice(0, 40)));
    expect(overflowWrapOf(bubble)).toBe('anywhere');
    expect(minWidthOf(bubble)).toBe('0px');
    expect(String(bubble.style.whiteSpace)).toBe('pre-wrap'); // 与 B1 换行保留共存
  });

  it('③ 气泡容器 minWidth:0，且**不加** overflow:hidden（否则会静默裁掉内容）', async () => {
    localStorage.setItem('subagent_messages_v4', JSON.stringify({ s1: [] }));
    const sent: any[] = [];
    installFetchMock(sent, 'ok');

    render(<ChatPanel projectId="p1" agentId="a1" />);
    await waitFor(() => expect(document.querySelector('textarea')).toBeTruthy(), { timeout: 3000 });

    await sendText('检查气泡容器');

    await waitFor(() => expect(screen.getByText(/检查气泡容器/)).toBeTruthy(), { timeout: 4000 });
    // 气泡容器 = maxWidth:78% 的那个 div
    const all = Array.from(document.querySelectorAll('div')) as HTMLElement[];
    const bubbleBox = all.find(d => d.style.maxWidth === '78%' && d.style.minWidth === '0px');
    expect(bubbleBox).toBeTruthy();
    // ⛔ 关键反向断言：overflow 必须不是 hidden
    expect(bubbleBox!.style.overflow).not.toBe('hidden');
  });

  it('④ 宽表格：外层必须有可横向滚动容器，且表格不断字（断字会打散单元格）', async () => {
    localStorage.setItem('subagent_messages_v4', JSON.stringify({ s1: [] }));
    const sent: any[] = [];
    const md = [
      '| 列A | 列B | 列C |',
      '| --- | --- | --- |',
      '| ' + 'x'.repeat(60) + ' | ' + 'y'.repeat(60) + ' | ' + 'z'.repeat(60) + ' |',
    ].join('\n');
    installFetchMock(sent, md);

    render(<ChatPanel projectId="p1" agentId="a1" />);
    await waitFor(() => expect(document.querySelector('textarea')).toBeTruthy(), { timeout: 3000 });

    await sendText('给我一个表格');

    await waitFor(() => expect(document.querySelector('table')).toBeTruthy(), { timeout: 4000 });
    const table = document.querySelector('table') as HTMLElement;
    // 父级必须是横向滚动容器
    const scroller = table.parentElement as HTMLElement;
    expect(scroller).toBeTruthy();
    expect(String(scroller.style.overflowX)).toBe('auto');
    // 表格自身宽度受限，避免撑破气泡
    expect(table.style.maxWidth === '100%' || scroller.style.maxWidth === '100%').toBe(true);
    // 单元格内容完整保留（未被裁剪或断字打散）
    expect(table.textContent).toContain('x'.repeat(60));
    expect(table.querySelector('th')).toBeTruthy();
    expect(table.querySelectorAll('td')).toHaveLength(3);
  });

  it('⑤ 行内代码与链接也具备断行能力（长标识符/长链接同样会溢出）', async () => {
    localStorage.setItem('subagent_messages_v4', JSON.stringify({ s1: [] }));
    const sent: any[] = [];
    const longIdent = 'v'.repeat(120);
    installFetchMock(sent, `调用 \`${longIdent}\` 函数，详见 [文档](${LONG_URL})`);

    render(<ChatPanel projectId="p1" agentId="a1" />);
    await waitFor(() => expect(document.querySelector('textarea')).toBeTruthy(), { timeout: 3000 });

    await sendText('给我行内代码和链接');

    await waitFor(() => expect(document.querySelector('code')).toBeTruthy(), { timeout: 4000 });
    const inlineCode = document.querySelector('code') as HTMLElement;
    expect(overflowWrapOf(inlineCode)).toBe('anywhere');
    expect(inlineCode.textContent).toContain(longIdent);

    await waitFor(() => expect(document.querySelector('a')).toBeTruthy(), { timeout: 4000 });
    const link = document.querySelector('a') as HTMLElement;
    expect(overflowWrapOf(link)).toBe('anywhere');
  });
});
