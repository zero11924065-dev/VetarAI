/*
 * VetarAI - Local-first multi-agent orchestration application
 * Copyright (C) 2026 zero11924065-dev
 * GPL-3.0-or-later（见仓库 LICENSE）
 */
/**
 * F3（0.4.33 插单实测修复批）：思考条 1↔2 行跳动修复。
 *
 * ═══ 治什么（用户原话）═══
 * 「当模型速度极快时，显示的问题有的时候一行，有的时候两行，来回跳跃导致会话窗口内
 *   整体上下频繁跳动」——即思考预览（thinkingPreview，末 120 字）在 WebkitLineClamp:3
 *   时代随流式内容长短在 1/2/3 行间切换，下方内容整体上下抖动。
 *
 * ═══ 修法 ═══
 * 预览钳制单行（whiteSpace:nowrap + overflow:hidden + textOverflow:ellipsis），
 * 完整预览留 title 悬浮（信息不丢）。纯 CSS 层改动，不动流式逻辑。
 *
 * ═══ 测法 ═══
 * 组件测试钉住：推入一条长思考增量（160 字，未钳制时必折行），预览落地后断言
 * 承载 span ① 样式含单行钳制三件套 ② title 持有完整预览文本。
 * 另加源码契约：ChatPanel 源码不得再出现 WebkitLineClamp（防多行钳制回潮）。
 * 帧调度手法照抄 chatPanelF4ThinkingThrottle（手动 rAF 队列，不用时序赌博）。
 *
 * 运行：node node_modules/vitest/vitest.mjs run src/__tests__/chatPanelF3ThinkingLineClamp.test.tsx
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, waitFor, act } from '@testing-library/react';
import React from 'react';
import { ChatPanel } from '../panels/ChatPanel';
import { jsonRes, sseEvent } from './helpers/fetchMock';
import { readChatPanelSource } from './helpers/chatSource';

// ── 手动帧调度（同 F4）：把 rAF 回调收进队列，由测试决定何时"过一帧" ──────────
let rafSeq = 0;
const rafMap = new Map<number, FrameRequestCallback>();

function runFrame() {
  const pending = Array.from(rafMap.entries());
  rafMap.clear();
  act(() => { for (const [, cb] of pending) cb(Date.now()); });
}

beforeEach(() => {
  vi.restoreAllMocks();
  localStorage.clear();
  rafSeq = 0;
  rafMap.clear();
  vi.stubGlobal('requestAnimationFrame', (cb: FrameRequestCallback) => {
    const id = ++rafSeq; rafMap.set(id, cb); return id;
  });
  vi.stubGlobal('cancelAnimationFrame', (id: number) => { rafMap.delete(id); });
});

afterEach(() => { vi.unstubAllGlobals(); vi.useRealTimers(); });

// ── 可控流（real timers 版，同 F4）──
function controllableStream() {
  const encoder = new TextEncoder();
  let ctrl: ReadableStreamDefaultController<Uint8Array> | null = null;
  const buffer: string[] = [];
  const flush = () => {
    if (!ctrl) return;
    while (buffer.length) {
      try { ctrl.enqueue(encoder.encode(buffer.shift()!)); } catch { buffer.length = 0; break; }
    }
  };
  const stream = new ReadableStream<Uint8Array>({
    start(controller) { ctrl = controller; flush(); },
  });
  return {
    res: new Response(stream, { status: 200, headers: { 'Content-Type': 'text/event-stream' } }),
    push: (e: string) => { buffer.push(e); flush(); },
    close: () => { if (ctrl) { try { ctrl.close(); } catch { /* 已关闭 */ } } },
  };
}

function mount() {
  const ctl = controllableStream();
  const impl: typeof fetch = async (url, init) => {
    const u = String(url);
    void init;
    if (u.includes('/agents/')) return jsonRes([{ id: 'a1', name: '行政主管', role: 'x' }]);
    if (u.includes('/ollama/models')) return jsonRes([{ name: 'qwen3.8' }]);
    if (u.includes('/sessions?')) return jsonRes([{ id: 's1', title: '会话 1', message_count: 1 }]);
    if (u.includes('/messages')) return jsonRes([]);
    if (u.includes('/ollama/chat/stream')) return ctl.res;
    return jsonRes([]);
  };
  vi.spyOn(globalThis, 'fetch').mockImplementation(impl);
  return { ...render(<ChatPanel projectId="p1" agentId="a1" />), ctl };
}

function getTextarea(): HTMLTextAreaElement {
  const el = document.querySelector('textarea');
  if (!el) throw new Error('未找到输入框 textarea');
  return el as HTMLTextAreaElement;
}

function typeInto(el: HTMLTextAreaElement, text: string) {
  const setter = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value')!.set!;
  setter.call(el, text);
  el.dispatchEvent(new Event('input', { bubbles: true }));
}

async function settle(ms = 60, rounds = 6) {
  for (let i = 0; i < rounds; i++) await act(async () => { await new Promise(r => setTimeout(r, ms)); });
}

async function send(text: string) {
  await waitFor(() => expect(getTextarea()).toBeTruthy(), { timeout: 3000 });
  await settle(40, 5);
  await act(async () => {
    typeInto(getTextarea(), text);
    getTextarea().dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
  });
  await waitFor(() => expect(document.body.textContent).toContain(text), { timeout: 3000 });
}

// 长思考增量：160 字（80 甲 + 80 乙），未钳行时必折 2+ 行；
// 预览只留末 120 字 → '甲'×40 + '乙'×80。
const HEAD = '甲'.repeat(40);
const TAIL = '乙'.repeat(80);
const LONG_DELTA = '甲'.repeat(80) + TAIL;
const PREVIEW_TEXT = HEAD + TAIL;

describe('F3（0.4.33）思考预览单行钳制', () => {
  it('长思考预览渲染为单行钳制 span：nowrap+hidden+ellipsis，title 持完整预览', async () => {
    const { ctl } = mount();
    await send('开始思考');

    await act(async () => {
      ctl.push(sseEvent('thinking', { delta: LONG_DELTA }));
      await new Promise(r => setTimeout(r, 12));
    });
    await waitFor(() => expect(document.body.textContent).toContain('思考中'), { timeout: 3000 });
    runFrame();   // 按帧 flush accThinking → thinkingPreview 落地

    // 预览文本落地（末 120 字语义不变：头部 40 个甲被 slice 掉）
    await waitFor(() => expect(document.body.textContent).toContain(TAIL), { timeout: 3000 });
    expect(document.body.textContent).not.toContain('甲'.repeat(80));

    // 承载 span：单行钳制三件套 + title 完整预览（悬浮可读，信息不丢）
    const el = screen.getByTitle(PREVIEW_TEXT);
    expect(el.tagName).toBe('SPAN');
    expect(el.style.whiteSpace).toBe('nowrap');
    expect(el.style.overflow).toBe('hidden');
    expect(el.style.textOverflow).toBe('ellipsis');
    // ⛔ 不得再是多行 -webkit-box 钳制（1↔2 行跳动的根因）
    expect(el.style.display).not.toBe('-webkit-box');
  });

  it('源码契约：ChatPanel 不得再出现 WebkitLineClamp（防多行钳制回潮）', async () => {
    const src = await readChatPanelSource();
    expect(src.length).toBeGreaterThan(10000);
    expect(src.includes('WebkitLineClamp')).toBe(false);
    // 单行钳制 + title 悬浮的形态锚点（锚真实代码形态，非裸文案）
    expect(/title=\{msg\.thinkingPreview\}/.test(src)).toBe(true);
    expect(/whiteSpace:\s*'nowrap',\s*overflow:\s*'hidden',\s*textOverflow:\s*'ellipsis'/.test(src)).toBe(true);
  });
});
