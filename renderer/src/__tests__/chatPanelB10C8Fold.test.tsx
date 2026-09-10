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
import { ChatPanel } from '../panels/ChatPanel';

import { jsonRes } from './helpers/fetchMock';

/**
 * #11（0.4.19）· 删除正文折叠后的【反向守护】测试。
 *
 * ⛔ 历史：0.4.18（提交 7f577fc）曾加入 B10（附件段折叠）+ C8 遗留（超长 assistant
 *    正文折叠），本文件当时测的是"折叠存在、点击展开"。用户明确这是**我虚构的需求**
 *    （"从未要求过折叠，觉得没意义"），2026-09-10 拍板**全部删除**：内容与附件一律铺开。
 *
 * 本文件现在守护的是**删除后的契约**（反向断言）：
 *   R1 超长 assistant 正文 → 全文直接铺开，不出现"展开全文/收起全文"折叠控件
 *   R2 含附件标记的 user 消息 → 原话 + 附件全文都铺开，不出现"附件内容"折叠控件
 *   R3 短正文 / 无附件消息 → 照常显示（删除折叠不得误伤正常渲染）
 *   R4 content 不被改动：渲染不截断、落库/载荷仍是完整原文（删的是显示层折叠，不是内容）
 *   R5 ⛔ B4 工具步骤折叠**保留**（用户拍板）：有工具步骤的消息仍出现"工具调用 N 步"折叠组
 *   R6 源码层：FoldSection / UserBody / AssistantBody / BODY_FOLD_* 已不存在（防回潮）
 *
 * ⛔ 这些是**删除验证**，不是功能验证——断言全是"折叠控件 not.toContain / queryByText 为 null"。
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

// ⛔ ATTACH_MARK 是附件正文注入的分隔标记，早在 B10 折叠之前就存在（与折叠无关，保留）。
//    注入后正文形如「用户原话\n\n--- 附件内容 ---\n附件全文」。
const ATTACH_MARK = '--- 附件内容 ---';

// DB 加载的历史消息（流已结束、非活流）—— 折叠曾发生在这种场景，删除后应全文铺开
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

const LONG_BODY = '这是很长的正文内容。'.repeat(80);   // ≈1600 字，远超已删除的 BODY_FOLD_CHARS(600)
const SHORT_BODY = '简短回答。';

describe('#11 删除正文折叠 · 反向守护', () => {
  // ── R1 超长 assistant 正文不再折叠 ──
  it('R1 超长 assistant 正文 → 全文铺开，无"展开全文"折叠控件', async () => {
    const dbMsgs = [
      { id: 1, role: 'user', content: '详细讲讲', created_at: 't1' },
      { id: 2, role: 'assistant', content: LONG_BODY, created_at: 't2' },
    ];
    const { unmount } = mount(dbMsgs);
    await waitFor(() => {
      expect(document.body.textContent).toContain('这是很长的正文内容');
    }, { timeout: 3000 });
    // ⛔ 折叠已删：正文尾部内容也直接可见（不需点击展开）
    expect(document.body.textContent).toContain('这是很长的正文内容');
    expect(screen.queryByText(/展开全文/)).toBeNull();
    expect(screen.queryByText(/收起全文/)).toBeNull();
    unmount();
  });

  // ── R2 附件段不再折叠 ──
  it('R2 含附件标记的 user 消息 → 原话+附件全文铺开，无"附件内容"折叠控件', async () => {
    const attach = '[合同.docx]（原件已保存：/x/合同.docx）\n' + '合同条款正文甲乙丙。'.repeat(50);
    const dbMsgs = [
      { id: 1, role: 'user', content: `请帮我看这份合同\n\n${ATTACH_MARK}\n${attach}`, created_at: 't1' },
    ];
    const { unmount } = mount(dbMsgs);
    await waitFor(() => {
      expect(document.body.textContent).toContain('请帮我看这份合同');
    }, { timeout: 3000 });
    // 用户原话照常显示
    expect(document.body.textContent).toContain('请帮我看这份合同');
    // ⛔ 附件全文直接铺开（折叠已删，不再藏起来需点击）
    expect(document.body.textContent).toContain('合同条款正文甲乙丙');
    expect(screen.queryByText(/📄 附件内容/)).toBeNull();
    expect(screen.queryByText(/收起附件内容/)).toBeNull();
    unmount();
  });

  // ── R3 短正文 / 无附件消息不被误伤 ──
  it('R3a 短 assistant 正文 → 照常显示（删折叠不误伤正常渲染）', async () => {
    const dbMsgs = [
      { id: 1, role: 'user', content: '问', created_at: 't1' },
      { id: 2, role: 'assistant', content: SHORT_BODY, created_at: 't2' },
    ];
    const { unmount } = mount(dbMsgs);
    await waitFor(() => {
      expect(document.body.textContent).toContain('简短回答');
    }, { timeout: 3000 });
    expect(screen.queryByText(/展开全文/)).toBeNull();
    unmount();
  });

  it('R3b 无附件标记的普通 user 消息 → 原样显示，无折叠控件', async () => {
    const dbMsgs = [{ id: 1, role: 'user', content: '普通提问没有附件', created_at: 't1' }];
    const { unmount } = mount(dbMsgs);
    await waitFor(() => {
      expect(document.body.textContent).toContain('普通提问没有附件');
    }, { timeout: 3000 });
    expect(screen.queryByText(/附件内容/)).toBeNull();
    unmount();
  });

  // ── R4 content 不被改动（删的是显示层折叠，不是内容）──
  it('R4 超长正文渲染不截断 content（缓存/落库仍是完整原文）', async () => {
    const dbMsgs = [
      { id: 1, role: 'user', content: '详细讲讲', created_at: 't1' },
      { id: 2, role: 'assistant', content: LONG_BODY, created_at: 't2' },
    ];
    const { unmount } = mount(dbMsgs);
    await waitFor(() => {
      expect(document.body.textContent).toContain('这是很长的正文内容');
    }, { timeout: 3000 });
    const cache = JSON.parse(localStorage.getItem('subagent_messages_v4') || '{}')['s1'] || [];
    const asst = cache.find((m: any) => m.role === 'assistant');
    expect(asst && asst.content).toBe(LONG_BODY);
    unmount();
  });

  // ── R5 ⛔ B4 工具步骤折叠保留（用户拍板）──
  it('R5 有工具步骤的 assistant 消息 → B4 步骤折叠组仍在（用户拍板保留）', async () => {
    const dbMsgs = [
      { id: 1, role: 'user', content: '查一下', created_at: 't1' },
      { id: 2, role: 'assistant', content: '已完成查询。', created_at: 't2',
        // ⛔ 前端 Message 字段是驼峰 toolSteps（非后端下划线 tool_steps），
        //    用错字段名步骤不会渲染 → B4 折叠组不出现（对照既有 chatPanelB4Collapse.test.tsx）。
        toolSteps: [
          { id: 'tc1', name: 'read_file', args: {}, status: 'ok', summary: 'ok' },
          { id: 'tc2', name: 'web_search', args: {}, status: 'ok', summary: 'ok' },
        ] },
    ];
    const { unmount } = mount(dbMsgs);
    await waitFor(() => {
      // B4 收拢态摘要文案："工具调用 N 步 · 已完成"
      expect(document.body.textContent).toMatch(/工具调用\s*2\s*步/);
    }, { timeout: 3000 });
    unmount();
  });

  // ── R6 源码层：折叠组件与阈值常量已彻底移除（防回潮）──
  it('R6 源码不含 FoldSection/UserBody/AssistantBody/BODY_FOLD_*（折叠不可回潮）', async () => {
    const src = await import('../panels/ChatPanel?raw').then(m => (m as any).default as string);
    // ⛔ 一律匹配【声明形态】（function/const 前缀），不用裸名——
    //    否则注释里提到旧名（如本文件 R6 标题、ChatPanel 的历史注释）就会误命中、误报。
    expect(src.includes('function FoldSection')).toBe(false);
    expect(src.includes('function UserBody')).toBe(false);
    expect(src.includes('function AssistantBody')).toBe(false);
    expect(src.includes('const BODY_FOLD_CHARS')).toBe(false);
    expect(src.includes('const BODY_FOLD_LINES')).toBe(false);
    // ⛔ 不再用裸文案（"展开全文"等）断言：注释里描述历史时会自然提到这些词，
    //    裸匹配会被注释误命中。声明形态（function/const）断言已足够守护折叠不回潮。
    // ⛔ B4 步骤折叠组件必须仍在（与上面被删的三个区分开）
    expect(src.includes('function ToolStepsGroup')).toBe(true);
    // ⛔ ATTACH_MARK 必须保留（附件注入标记，与折叠无关）
    expect(src.includes("const ATTACH_MARK = '--- 附件内容 ---'")).toBe(true);
  });
});
