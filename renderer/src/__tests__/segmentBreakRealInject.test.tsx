/*
 * VetarAI - Local-first multi-agent orchestration application
 * Copyright (C) 2026 zero11924065-dev
 * GPL-3.0-or-later（见仓库 LICENSE）
 */
/**
 * #1 插入点分裂 —— **真实注入路径**（乐观气泡 + segment_break 交互）复现测试。
 *
 * ═══ 为什么需要它（chatPanelSegmentBreak.test.tsx 的覆盖盲区）═══
 *
 * 现有 S1~S7 用一次性流**直接喂 segment_break 对象**，既没有工具调用，
 * 也**从未经由真实的 handleInject 路径**。于是漏掉了生产中同时发生的两件事：
 *
 *   1. 用户「思考中」点发送/回车 → `handleSend` 因 `sending` 转 `handleInject`
 *      （ChatPanel.tsx:1233），后者**乐观追加一个用户气泡到数组末尾**（:1918-1919），
 *      再 POST /inject；
 *   2. 后端下一轮 drain 到注入 → 发 `segment_break`，其处理器又**在段1 之后 splice
 *      插入一个 `local_inject_*` 用户气泡 + 新 assistant 气泡**（:1536-1546）。
 *
 * 两者叠加的后果（本套件要锁住的）：
 *   ⛔ 同一条插入消息**显示两次**（乐观气泡 + 分裂插入的气泡）；
 *   ⛔ 且顺序错乱——乐观气泡在**数组末尾**，而新 assistant 气泡插在段1 之后，
 *      于是用户的插入消息跑到了 agent 新回复的**下方**，视觉上就像
 *      「agent 还在回复我上一个问题」（用户 2026-09-12 实测原话）。
 *   （刷新后会被 mergeDbWithLocal 的 matchesDb 按 content 去重 → 恢复正常，
 *     故这是**实时视图**缺陷，不是落库缺陷。）
 *
 * ═══ 测试手法（⛔ 不要用 sseResControllable）═══
 *
 * 用 `sseResSlow`：**一次性给定完整事件序列**（与 S1~S7 同款可靠范式，
 * 避开可控流分步 push 在本项目 jsdom 下的时序坑），但事件间留 gapMs 延时，
 * 使流在断言期间**保持进行中**（sending=true），从而能在中途真实触发 handleInject。
 *
 * 运行：node node_modules/vitest/vitest.mjs run src/__tests__/segmentBreakRealInject.test.tsx
 */
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, waitFor, act } from '@testing-library/react';
import React from 'react';
import { ChatPanel } from '../panels/ChatPanel';

import { jsonRes, sseEvent, tokenEvent, doneEvent, sseResSlow } from './helpers/fetchMock';

if (typeof (globalThis as any).localStorage === 'undefined') {
  (globalThis as any).localStorage = {
    _d: {} as Record<string, string>,
    getItem(k: string) { return this._d[k] ?? null; },
    setItem(k: string, v: string) { this._d[k] = String(v); },
    removeItem(k: string) { delete this._d[k]; },
    clear() { this._d = {}; },
  };
}

beforeEach(() => { vi.restoreAllMocks(); localStorage.clear(); });

const INJECT_TEXT = '改看B表';
const SEG1_TEXT = '第一段正文';
const SEG2_TEXT = '针对插入的新回复';

const segBreak = (injected: string, breakAt: number) =>
  sseEvent('segment_break', {
    injected_messages: [{ role: 'user', content: injected }],
    break_at: breakAt,
  });
const toolCall = (id: string, name: string) =>
  sseEvent('tool_call', { id, name, args: {} });
const toolResult = (id: string, name: string) =>
  sseEvent('tool_result', { id, name, ok: true, summary: 'ok' });

/**
 * 装载 ChatPanel：chat/stream 返回**慢速一次性流**（事件间留延时，流保持进行中），
 * 其余端点给最小可用响应。inject 返回 ok:true（模拟真实活流注入成功）。
 */
function mountWithSlowStream(evs: string[], gapMs = 180) {
  const injectCalls: string[] = [];
  const impl: typeof fetch = async (url, init) => {
    const u = String(url);
    if (u.includes('/inject')) {
      // 记录注入请求体，供断言"确实走了真实注入路径"
      try { injectCalls.push(JSON.parse(String(init?.body || '{}')).content || ''); } catch { /* noop */ }
      return jsonRes({ ok: true, detail: '已加入：模型完成当前这一步后会读到你的新消息' });
    }
    if (u.includes('/agents/')) return jsonRes([{ id: 'a1', name: '行政主管', role: 'x' }]);
    if (u.includes('/ollama/models')) return jsonRes([{ name: 'qwen3.6:35b' }]);
    if (u.includes('/sessions?')) return jsonRes([{ id: 's1', title: '会话 1', message_count: 1 }]);
    if (u.includes('/messages')) return jsonRes([]);
    if (u.includes('/ollama/chat/stream')) return sseResSlow(evs, gapMs);
    return jsonRes([]);
  };
  vi.spyOn(globalThis, 'fetch').mockImplementation(impl);
  const utils = render(<ChatPanel projectId="p1" agentId="a1" />);
  return { ...utils, injectCalls };
}

function getTextarea(): HTMLTextAreaElement {
  const el = document.querySelector('textarea');
  if (!el) throw new Error('未找到输入框');
  return el as HTMLTextAreaElement;
}

/** 原生 setter 派发 input（React 受控组件必须这样，fireEvent.change 不可靠） */
function typeInto(el: HTMLTextAreaElement, text: string) {
  const setter = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value')!.set!;
  setter.call(el, text);
  el.dispatchEvent(new Event('input', { bubbles: true }));
}

/** 发第一条消息开流。 */
async function sendFirstMessage(text = '第一个问题') {
  await waitFor(() => expect(getTextarea()).toBeTruthy(), { timeout: 3000 });
  await act(async () => {
    typeInto(getTextarea(), text);
    getTextarea().dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
  });
  await waitFor(() => expect(document.body.textContent).toContain(text), { timeout: 3000 });
}

/** 流进行中（sending=true）再发一条 → handleSend 转 handleInject。 */
async function injectWhileStreaming(text: string) {
  await act(async () => {
    typeInto(getTextarea(), text);
    getTextarea().dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
    await new Promise(r => setTimeout(r, 30));   // 让 handleInject 的乐观 setLocalMessages 落地
  });
}

describe('#1 插入点分裂 · 真实注入路径（乐观气泡 + segment_break）', () => {
  it('I1 ⛔ 插入消息不得显示两次（乐观气泡 vs segment_break 插入的气泡）', async () => {
    // 真实生产序列：段1 正文 → 工具调用 → segment_break → 段2 正文 → done(全文)
    const { injectCalls } = mountWithSlowStream([
      tokenEvent(SEG1_TEXT),
      toolCall('c1', 'read_file'),
      toolResult('c1', 'read_file'),
      segBreak(INJECT_TEXT, SEG1_TEXT.length),
      tokenEvent(SEG2_TEXT),
      doneEvent(SEG1_TEXT + SEG2_TEXT),
    ]);
    await sendFirstMessage();

    // 等段1 正文出现（此刻流仍进行中，因为后面还有事件未消费完）
    await waitFor(() => expect(document.body.textContent).toContain(SEG1_TEXT), { timeout: 3000 });

    // ⛔ 真实注入：走 handleSend → sending → handleInject（乐观追加气泡 + POST /inject）
    await injectWhileStreaming(INJECT_TEXT);

    // 等流跑完（done 之后段2 到位）
    await waitFor(() => expect(document.body.textContent).toContain(SEG2_TEXT), { timeout: 6000 });

    // 前置：确认真的走了注入端点（否则本用例什么也没测）
    expect(injectCalls).toContain(INJECT_TEXT);

    const txt = document.body.textContent || '';
    // ⛔ 核心断言：插入消息只应出现 **1 次**。出现 2 次 = 乐观气泡与 segment_break
    //    插入的气泡重复（用户会看到自己那条消息显示两遍）。
    expect(txt.split(INJECT_TEXT).length - 1).toBe(1);
  });

  it('I2 ⛔ 顺序必须是 段1 → 插入消息 → 段2（插入消息不得跑到新回复下方）', async () => {
    mountWithSlowStream([
      tokenEvent(SEG1_TEXT),
      segBreak(INJECT_TEXT, SEG1_TEXT.length),
      tokenEvent(SEG2_TEXT),
      doneEvent(SEG1_TEXT + SEG2_TEXT),
    ]);
    await sendFirstMessage();
    await waitFor(() => expect(document.body.textContent).toContain(SEG1_TEXT), { timeout: 3000 });
    await injectWhileStreaming(INJECT_TEXT);
    await waitFor(() => expect(document.body.textContent).toContain(SEG2_TEXT), { timeout: 6000 });

    const txt = document.body.textContent || '';
    // ⛔ 乐观气泡被追加到数组末尾 → 插入消息会跑到段2 **之后**，
    //    用户看到的就是"agent 还在回复上一个问题"。这里锁死正确顺序。
    expect(txt.indexOf(SEG1_TEXT)).toBeLessThan(txt.indexOf(INJECT_TEXT));
    expect(txt.indexOf(INJECT_TEXT)).toBeLessThan(txt.indexOf(SEG2_TEXT));
  });

  it('I3 段1/段2 各只出现一次（done 全文按 break_at 正确切分，不因注入路径而回归）', async () => {
    mountWithSlowStream([
      tokenEvent(SEG1_TEXT),
      segBreak(INJECT_TEXT, SEG1_TEXT.length),
      tokenEvent(SEG2_TEXT),
      doneEvent(SEG1_TEXT + SEG2_TEXT),
    ]);
    await sendFirstMessage();
    await waitFor(() => expect(document.body.textContent).toContain(SEG1_TEXT), { timeout: 3000 });
    await injectWhileStreaming(INJECT_TEXT);
    await waitFor(() => expect(document.body.textContent).toContain(SEG2_TEXT), { timeout: 6000 });

    const txt = document.body.textContent || '';
    expect(txt.split(SEG1_TEXT).length - 1).toBe(1);
    expect(txt.split(SEG2_TEXT).length - 1).toBe(1);
    expect(txt).not.toContain(SEG1_TEXT + SEG2_TEXT);   // 段2 不得显示全文
  });
});
