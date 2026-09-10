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
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with VetarAI. If not, see <https://www.gnu.org/licenses/>.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, waitFor } from '@testing-library/react';
import React from 'react';
import { ChatPanel, AssistantBody } from '../panels/ChatPanel';

import { jsonRes } from './helpers/fetchMock';

/**
 * B10 + C8 遗留（0.4.18）· 正文折叠（附件段落 / 长篇 assistant 正文）。
 *
 *  ⛔ 纯显示层：折叠**不得**改动 content、不得改发给模型的载荷、不得改落库——
 *     agent 仍从落库正文读全文（B10 的核心约束："内容保留让 agent 可读，但界面能折叠"）。
 *
 *  覆盖：
 *   B10  ① 含附件标记的 user 消息：原话照常显示，附件段默认折叠（治文字墙）
 *        ② 点击展开能看到附件全文
 *        ③ 无附件标记的普通 user 消息：原样显示（不引入折叠控件）
 *   C8   ④ 超长 assistant 正文（流已结束）默认折叠，点击展开
 *        ⑤ 短正文不折叠（不引入无谓点击）
 *        ⑥ ⛔ 流式生成中不折叠（否则用户看不到正在生成的内容）
 *   共用 ⑦ 折叠是显示层：展开前后 content 不变（载荷/落库不受影响）
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

beforeEach(() => { vi.restoreAllMocks(); localStorage.clear(); });

const ATTACH_MARK = '--- 附件内容 ---';

// DB 加载的历史消息（流已结束、非活流）—— B10/C8 折叠的主战场就是这种
function mount(dbMsgs: any[]) {
  const impl: typeof fetch = async (url) => {
    const u = String(url);
    if (u.includes('/agents/')) return jsonRes([{ id: 'a1', name: '行政主管', role: 'x' }]);
    if (u.includes('/ollama/models')) return jsonRes([{ name: 'qwen3.6:35b' }]);
    if (u.includes('/sessions?')) return jsonRes([{ id: 's1', title: '会话 1', message_count: dbMsgs.length }]);
    if (u.includes('/sessions/s1/messages')) return jsonRes(dbMsgs);
    return jsonRes([]);
  };
  vi.spyOn(globalThis, 'fetch').mockImplementation(impl);
  return render(<ChatPanel projectId="p1" agentId="a1" />);
}

const LONG_BODY = '这是很长的正文内容。'.repeat(80);   // ≈1600 字，超过 BODY_FOLD_CHARS(600)
const SHORT_BODY = '简短回答。';

describe('B10 + C8 正文折叠 · 显示层', () => {
  // ── B10 ①② 附件段折叠 ──
  it('B10-① user 消息含附件标记 → 原话显示、附件段默认折叠', async () => {
    const attach = '[合同.docx]（原件已保存：/x/合同.docx）\n' + '合同条款正文。'.repeat(50);
    const dbMsgs = [
      { id: 1, role: 'user', content: `请帮我看这份合同\n\n${ATTACH_MARK}\n${attach}`, created_at: 't1' },
    ];
    const { unmount } = mount(dbMsgs);
    await waitFor(() => {
      expect(document.body.textContent).toContain('请帮我看这份合同');
    }, { timeout: 3000 });
    // 用户原话照常显示（折叠只折附件段，不折原话）
    expect(document.body.textContent).toContain('请帮我看这份合同');
    // 附件段默认折叠 → 折叠提示出现，附件全文不铺开
    expect(document.body.textContent).toContain('附件内容');
    expect(document.body.textContent).not.toContain('合同条款正文');
    unmount();
  });

  it('B10-② 点击折叠条 → 展开能看到附件全文', async () => {
    const attach = '[合同.docx]（原件已保存：/x/合同.docx）\n合同条款正文甲乙丙。';
    const dbMsgs = [
      { id: 1, role: 'user', content: `看合同\n\n${ATTACH_MARK}\n${attach}`, created_at: 't1' },
    ];
    const { unmount } = mount(dbMsgs);
    await waitFor(() => {
      expect(document.body.textContent).toContain('附件内容');
    }, { timeout: 3000 });
    expect(document.body.textContent).not.toContain('合同条款正文甲乙丙');
    // 点折叠条展开
    const toggle = screen.getByText(/附件内容/);
    toggle.click();
    await waitFor(() => {
      expect(document.body.textContent).toContain('合同条款正文甲乙丙');
    }, { timeout: 1500 });
    unmount();
  });

  it('B10-③ 无附件标记的普通 user 消息 → 原样显示、不引入折叠控件', async () => {
    const dbMsgs = [{ id: 1, role: 'user', content: '普通提问没有附件', created_at: 't1' }];
    const { unmount } = mount(dbMsgs);
    await waitFor(() => {
      expect(document.body.textContent).toContain('普通提问没有附件');
    }, { timeout: 3000 });
    expect(screen.queryByText(/附件内容/)).toBeNull();
    unmount();
  });

  // ── C8 ④⑤ 长篇 assistant 正文折叠 ──
  it('C8-④ 超长 assistant 正文（流已结束）→ 默认折叠，点击展开', async () => {
    const dbMsgs = [
      { id: 1, role: 'user', content: '详细讲讲', created_at: 't1' },
      { id: 2, role: 'assistant', content: LONG_BODY, created_at: 't2' },
    ];
    const { unmount } = mount(dbMsgs);
    await waitFor(() => {
      expect(document.body.textContent).toContain('展开全文');
    }, { timeout: 3000 });
    // 默认折叠：正文开头不该直接铺开（折叠提示在、完整正文藏起）
    expect(document.body.textContent).toContain('展开全文');
    // 点击展开
    screen.getByText(/展开全文/).click();
    await waitFor(() => {
      expect(document.body.textContent).toContain('这是很长的正文内容');
    }, { timeout: 1500 });
    unmount();
  });

  it('C8-⑤ 短 assistant 正文 → 不折叠（无折叠控件）', async () => {
    const dbMsgs = [
      { id: 1, role: 'user', content: '问', created_at: 't1' },
      { id: 2, role: 'assistant', content: SHORT_BODY, created_at: 't2' },
    ];
    const { unmount } = mount(dbMsgs);
    await waitFor(() => {
      expect(document.body.textContent).toContain('简短回答');
    }, { timeout: 3000 });
    expect(screen.queryByText(/展开全文/)).toBeNull();
    expect(screen.queryByText(/收起全文/)).toBeNull();
    unmount();
  });

  // ── 共用 ⑦ 折叠是显示层：不改 content ──
  it('共用-⑦ 折叠/展开不改 content（落库与载荷不受影响）', async () => {
    const dbMsgs = [
      { id: 1, role: 'user', content: '详细讲讲', created_at: 't1' },
      { id: 2, role: 'assistant', content: LONG_BODY, created_at: 't2' },
    ];
    const { unmount } = mount(dbMsgs);
    await waitFor(() => {
      expect(document.body.textContent).toContain('展开全文');
    }, { timeout: 3000 });
    // 折叠态：缓存里的 content 仍是完整长文（折叠只是显示层，没截断/没改）
    const cache1 = JSON.parse(localStorage.getItem('subagent_messages_v4') || '{}')['s1'] || [];
    const asst1 = cache1.find((m: any) => m.role === 'assistant');
    expect(asst1 && asst1.content.length).toBe(LONG_BODY.length);
    // 展开后 content 不变
    screen.getByText(/展开全文/).click();
    await waitFor(() => {
      expect(document.body.textContent).toContain('这是很长的正文内容');
    }, { timeout: 1500 });
    const cache2 = JSON.parse(localStorage.getItem('subagent_messages_v4') || '{}')['s1'] || [];
    const asst2 = cache2.find((m: any) => m.role === 'assistant');
    expect(asst2 && asst2.content).toBe(LONG_BODY);
    unmount();
  });

  // ── C8 ⑥ ⛔ 流式生成中绝不折叠（否则用户看不到正在生成的内容）──
  // ⛔⛔ 这里**不能**用全面板流式测试：jsdom 下 SSE 流不 close 时渲染不 flush，
  //    而流一 close，sending 立即转 false → streaming 判据无法稳定为真
  //    （0.4.16 续八同一坑，曾连败 4 次）。故改为**组件级单元测试**：
  //    直接渲染 AssistantBody 传 streaming，精确测"折叠 vs 原样"的契约；
  //    streaming 判据本身（与打字机光标一致）由下方 T-src 源码断言守护。
  it('C8-⑥a AssistantBody streaming=true → 超长正文也不折叠（原样渲染）', () => {
    const { container } = render(<AssistantBody content={LONG_BODY} streaming={true} />);
    // 流式中：正文实时可见，且**没有**"展开全文"折叠控件
    expect(container.textContent).toContain('这是很长的正文内容');
    expect(container.textContent).not.toContain('展开全文');
  });

  it('C8-⑥b AssistantBody streaming=false + 超长 → 折叠（与 ⑥a 互为反证）', () => {
    const { container } = render(<AssistantBody content={LONG_BODY} streaming={false} />);
    expect(container.textContent).toContain('展开全文');
    expect(container.textContent).not.toContain('这是很长的正文内容');
  });

  it('C8-⑥c AssistantBody streaming=true + 短正文 → 原样（不长本就不折叠）', () => {
    const { container } = render(<AssistantBody content={SHORT_BODY} streaming={true} />);
    expect(container.textContent).toContain('简短回答');
    expect(container.textContent).not.toContain('展开全文');
  });

  it('C8-⑥-src streaming 判据已收敛为单一变量、三处共用（防漂移）', async () => {
    // ⛔ 局部去重后：流式判据只在 isStreamingThis 定义处写**一次**，
    //    工具步骤折叠(done)、正文折叠(streaming)、打字机光标三处引用同一变量。
    //    钉死这个形态：若将来有人把判据改回字面量重复，或三处不再共用，此断言失败。
    const src = await import('../panels/ChatPanel?raw').then(m => (m as any).default as string);
    // 1) 判据字面量只应出现 1 次（在 isStreamingThis 定义处）——出现 2+ 次=又重复了
    const cond = 'sending && !msg.stopped && !msg.streamError';
    expect(src.split(cond).length - 1).toBe(1);
    // 2) isStreamingThis 被三处消费：done={!isStreamingThis}、streaming={isStreamingThis}、光标 && isStreamingThis
    expect(src).toContain('done={!isStreamingThis}');
    expect(src).toContain('streaming={isStreamingThis}');
    expect(src).toMatch(/msg\.role === 'assistant' && isStreamingThis &&/);
  });
});
