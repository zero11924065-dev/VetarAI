/*
 * VetarAI - Local-first multi-agent orchestration application
 * Copyright (C) 2026 zero11924065-dev
 * GPL-3.0-or-later（见仓库 LICENSE）
 */
/**
 * #1（0.4.20）插入点分裂 · 前端专项。
 *
 * 需求（用户 2026-09-11 确认，对齐千问）：用户「思考中」插入消息 M 后
 *   ① M 作为独立用户气泡插进对话流；
 *   ② agent 当前正在生成的气泡在 M 插入处**就地定格**（保留在 M 上方）；
 *   ③ agent 针对 M 的新思考**另起一个气泡，显示在 M 下方**。
 * 技术上 = 后端在轮次边界 drain 到注入时发 `segment_break`（带 `break_at`），
 * 前端据此分裂气泡。
 *
 * ⛔⛔ **测试策略：一次性流 + 断言最终态**（2026-09-11 实测踩坑后改定）
 *   首轮用 `sseResControllable`（push 分步喂事件）+ 断言中途态 → **6 用例全假失败**。
 *   根因不是产品缺陷（铁证：不含 segment_break 的纯回归用例 S3 也失败），而是可控流的
 *   **时序**：push 发生在 reader 尚未建立时，分片缓冲未按预期交付，中途 token 没进 DOM。
 *   ✅ 正解：用一次性 `sseRes([...])` 给【完整事件序列】（含 segment_break + done），
 *   只断言 **done 之后的最终 DOM**——最终态是确定的，不依赖分片时序。
 *   （注：helpers/fetchMock.ts 里"jsdom 不提供 raf"的注释已过时——探针实测
 *    `typeof requestAnimationFrame === 'function'` 且回调会执行。）
 *
 * ⛔⛔ 本套件核心断言 = **段2 不重复段1**：done 的 content 是【全文】
 *   （loop.py 的 full_text 跨轮累加），前端必须按 break_at 切成 [:break_at]/[break_at:]。
 *   若不切分，段2 气泡会显示"段1+段2"全文 → DOM 里段1 文本出现 2 次。
 *
 * 运行：node node_modules/vitest/vitest.mjs run src/__tests__/chatPanelSegmentBreak.test.tsx
 */
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, waitFor, act } from '@testing-library/react';
import React from 'react';
import { ChatPanel } from '../panels/ChatPanel';

import { jsonRes, sseRes, sseEvent, tokenEvent, doneEvent } from './helpers/fetchMock';

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

/** 装载 ChatPanel：chat/stream 返回【一次性完整事件序列】evs。 */
function mountWithStream(evs: string[]) {
  const impl: typeof fetch = async (url, init) => {
    const u = String(url);
    const method = String(init?.method || 'GET');
    void method; void init;
    if (u.includes('/agents/')) return jsonRes([{ id: 'a1', name: '行政主管', role: 'x' }]);
    if (u.includes('/ollama/models')) return jsonRes([{ name: 'qwen3.6:35b' }]);
    if (u.includes('/sessions?')) return jsonRes([{ id: 's1', title: '会话 1', message_count: 1 }]);
    if (u.includes('/messages')) return jsonRes([]);
    if (u.includes('/inject')) return jsonRes({ ok: true, detail: '已加入' });
    if (u.includes('/ollama/chat/stream')) return sseRes(evs);
    return jsonRes([]);
  };
  vi.spyOn(globalThis, 'fetch').mockImplementation(impl);
  return render(<ChatPanel projectId="p1" agentId="a1" />);
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
async function sendFirstMessage() {
  await waitFor(() => expect(getTextarea()).toBeTruthy(), { timeout: 3000 });
  await act(async () => {
    typeInto(getTextarea(), '第一个问题');
    getTextarea().dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
  });
  await waitFor(() => {
    expect(document.body.textContent).toContain('第一个问题');
  }, { timeout: 3000 });
}

const segBreak = (injected: string, breakAt: number) =>
  sseEvent('segment_break', {
    injected_messages: [{ role: 'user', content: injected }],
    break_at: breakAt,
  });

describe('#1 插入点分裂（segment_break）', () => {
  it('S1 分裂后：段1 定格在上、注入用户气泡居中、段2 在下（且段2 不重复段1）', async () => {
    // 事件序列：段1 正文 → segment_break(break_at=3) → 段2 正文 → done(全文)
    mountWithStream([
      tokenEvent('第一段'),
      segBreak('请改正方向', 3),
      tokenEvent('第二段'),
      doneEvent('第一段第二段'),
    ]);
    await sendFirstMessage();

    await waitFor(() => {
      const txt = document.body.textContent || '';
      expect(txt).toContain('第一段');          // 段1 定格保留
      expect(txt).toContain('请改正方向');       // 注入的用户气泡
      expect(txt).toContain('第二段');          // 段2 新气泡
    }, { timeout: 3000 });

    const txt = document.body.textContent || '';
    // ⛔ 核心：段1 文本只出现 1 次 —— 若 done 全文未按 break_at 切分，
    //   段2 会显示"第一段第二段"，导致"第一段"出现 2 次
    expect(txt.split('第一段').length - 1).toBe(1);
    expect(txt.split('第二段').length - 1).toBe(1);
    // 顺序：段1 在注入消息之前，注入消息在段2 之前
    expect(txt.indexOf('第一段')).toBeLessThan(txt.indexOf('请改正方向'));
    expect(txt.indexOf('请改正方向')).toBeLessThan(txt.indexOf('第二段'));
  });

  it('S2 ⛔ done 全文按 break_at 切分：段2 不重复段1（本套件核心）', async () => {
    // 故意让段1、段2 用可区分的文本，done 给合并全文
    mountWithStream([
      tokenEvent('甲乙丙'),
      segBreak('换个方向', 3),
      tokenEvent('丁戊己'),
      doneEvent('甲乙丙丁戊己'),
    ]);
    await sendFirstMessage();

    await waitFor(() => {
      expect(document.body.textContent).toContain('丁戊己');
    }, { timeout: 3000 });

    const txt = document.body.textContent || '';
    // 段1 只显示"甲乙丙"，段2 只显示"丁戊己"
    expect(txt.split('甲乙丙').length - 1).toBe(1);
    expect(txt.split('丁戊己').length - 1).toBe(1);
    // ⛔ 若未切分，段2 会显示全文"甲乙丙丁戊己"→"甲乙丙"出现 2 次
    expect(txt).not.toContain('甲乙丙丁戊己');
  });

  it('S3 无 segment_break → 正常单气泡，done 全文直接覆盖（回归保护）', async () => {
    mountWithStream([tokenEvent('普通回复'), doneEvent('普通回复完整')]);
    await sendFirstMessage();

    await waitFor(() => {
      expect(document.body.textContent).toContain('普通回复完整');
    }, { timeout: 3000 });

    const txt = document.body.textContent || '';
    expect(txt).not.toContain('local_inject_');          // 不得有注入气泡残留
    expect(txt.split('普通回复完整').length - 1).toBe(1); // 正文只出现一次
  });

  it('S4 段1 定格后带 completedDuration → 不被误标"已中断执行"', async () => {
    mountWithStream([
      tokenEvent('第一段内容'),
      segBreak('插入的消息', 5),
      tokenEvent('第二段内容'),
      doneEvent('第一段内容第二段内容'),
    ]);
    await sendFirstMessage();

    await waitFor(() => {
      expect(document.body.textContent).toContain('插入的消息');
    }, { timeout: 3000 });

    // ⛔ 段1 是【正常完成】的段（分裂时给了 completedDuration），
    //   绝不能显示"已中断执行（半成品）"——那是 #13(0.4.19) 给异常中断气泡的标记。
    expect(document.body.textContent).not.toContain('已中断执行');
  });

  it('S5 多次 segment_break → 链式分裂（3 段各自独立，done 全文正确切分）', async () => {
    mountWithStream([
      tokenEvent('AAA'),
      segBreak('插入一', 3),
      tokenEvent('BBB'),
      segBreak('插入二', 6),
      tokenEvent('CCC'),
      doneEvent('AAABBBCCC'),
    ]);
    await sendFirstMessage();

    await waitFor(() => {
      const txt = document.body.textContent || '';
      expect(txt).toContain('插入一');
      expect(txt).toContain('插入二');
      expect(txt).toContain('CCC');
    }, { timeout: 3000 });

    const txt = document.body.textContent || '';
    // 每段各只出现一次（若最后一段误显示全文，AAA 会出现 2 次）
    expect(txt.split('AAA').length - 1).toBe(1);
    expect(txt.split('BBB').length - 1).toBe(1);
    expect(txt.split('CCC').length - 1).toBe(1);
    expect(txt).not.toContain('AAABBBCCC');
    // 顺序：AAA → 插入一 → BBB → 插入二 → CCC
    const order = ['AAA', '插入一', 'BBB', '插入二', 'CCC'].map(s => txt.indexOf(s));
    expect(order.every((v, i) => i === 0 || v > order[i - 1])).toBe(true);
  });

  it('S6 segment_break 的 injected_messages 为空 → 不插入空气泡（仍定格分裂）', async () => {
    // 后端只发 break_at、不带注入消息（防御：数组为空时不应插空气泡）
    mountWithStream([
      tokenEvent('前段'),
      sseEvent('segment_break', { injected_messages: [], break_at: 2 }),
      tokenEvent('后段'),
      doneEvent('前段后段'),
    ]);
    await sendFirstMessage();

    await waitFor(() => {
      expect(document.body.textContent).toContain('后段');
    }, { timeout: 3000 });

    const txt = document.body.textContent || '';
    expect(txt.split('前段').length - 1).toBe(1);
    expect(txt.split('后段').length - 1).toBe(1);
    expect(txt).not.toContain('local_inject_');
  });

  it('S7 break_at 缺失（异常 payload）→ 段2 退回用累加内容，不崩', async () => {
    // 防御：后端漏发 break_at 时前端不得抛错，段2 至少显示 token 累加的内容
    mountWithStream([
      tokenEvent('前段'),
      sseEvent('segment_break', { injected_messages: [{ role: 'user', content: '插入' }] }),
      tokenEvent('后段'),
      doneEvent('前段后段'),
    ]);
    await sendFirstMessage();

    await waitFor(() => {
      const txt = document.body.textContent || '';
      expect(txt).toContain('插入');
      expect(txt).toContain('后段');
    }, { timeout: 3000 });
    // 不崩即通过；段1 内容仍在
    expect(document.body.textContent).toContain('前段');
  });
});
