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
import { render, screen, waitFor } from '@testing-library/react';
import React from 'react';
import { ChatPanel } from '../panels/ChatPanel';

import { jsonRes } from './helpers/fetchMock';

/**
 * 第 3 批（0.4.16）C8 专项 · 前端：停止气泡不再挪到末尾 / 不再重复 / 刷新后仍标"已手动停止"。
 *
 * 对应 C8 三个根因里前端负责的两个：
 *  ② 停止时前端曾把「（已停止）」拼进 content → 缓存副本与 DB 定稿内容不一致 → 去重失配
 *     → 副本被 mergeDbWithLocal 追加到会话**末尾且重复**。修复：不再拼接（content 与 DB 一致）。
 *  ① mergeDbWithLocal 去重从"精确相等"增强为**前缀匹配**：前端 abort 时可能比后端少收几个
 *     token，缓存 content 是 DB 定稿的前缀 → 精确匹配失配、前缀匹配命中 → 正确去重。
 *  ③ 停止态此前不落库 → 刷新即丢"已手动停止"。现 DB 有 stopped 列，loadSessionMessages
 *     把 DB 的 stopped 映射成 manualStopped（⛔ 只映射 DB 来源，前端内存 stopped 语义更宽）。
 *
 * 后端落库链路见 test_c8_stopped_persist.py。
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

// DB 定稿（模型实际生成完并落库的完整内容）
const DB_FULL = '这是完整的定稿回答包含了全部内容的结尾部分';
// 前端 abort 时缓存的中间态：是 DB 定稿的**前缀**（少收了结尾几个 token）
const CACHE_PREFIX = '这是完整的定稿回答包含了全部';

function mount(dbMsgs: any[], cache: any[] | null) {
  if (cache) {
    localStorage.setItem('subagent_messages_v4', JSON.stringify({ s1: cache }));
  }
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

const readCache = (sid = 's1'): any[] =>
  JSON.parse(localStorage.getItem('subagent_messages_v4') || '{}')[sid] || [];

describe('C8 停止气泡 · 前端合并', () => {
  it('前缀去重：缓存是 DB 定稿的前缀 → 合并后不重复、不挪到末尾', async () => {
    // DB：user + assistant 定稿（stopped=true，即用户停止后落库的那条）
    const dbMsgs = [
      { id: 1, role: 'user', content: '请详细介绍一下这个方案', created_at: 't1' },
      { id: 2, role: 'assistant', content: DB_FULL, created_at: 't2', stopped: true },
    ];
    // 缓存：user + 一条 local_ 流式气泡，其 content 是 DB 定稿的**前缀**
    const cache = [
      { id: 1, role: 'user', content: '请详细介绍一下这个方案', created_at: 't1' },
      { id: 'local_x', role: 'assistant', content: CACHE_PREFIX, stopped: true, manualStopped: true, thinking: false },
    ];
    const { unmount } = mount(dbMsgs, cache);

    // DB 定稿完整显示（含结尾，证明屏上是 DB 版本而非缓存前缀版本）
    await waitFor(() => {
      expect(document.body.textContent).toContain('结尾部分');
    }, { timeout: 3000 });
    // 等合并 + 回写缓存完成
    await new Promise(r => setTimeout(r, 150));

    // ⛔ 核心断言：缓存前缀气泡被去重，不再作为副本残留在合并结果里
    //（去重失败 → local_x 会进 extra → 追加到末尾且重复，正是 C8 现象）
    const after = readCache();
    expect(after.some((m: any) => m.id === 'local_x')).toBe(false);
    // assistant 定稿在合并结果里只有一条（不重复）
    const assistants = after.filter((m: any) => m.role === 'assistant');
    expect(assistants.length).toBe(1);
    unmount();
  });

  it('精确匹配回归：缓存 content 与 DB 完全相等 → 仍去重（保护原有路径）', async () => {
    const dbMsgs = [
      { id: 1, role: 'user', content: '问题', created_at: 't1' },
      { id: 2, role: 'assistant', content: '完全相同的回答', created_at: 't2' },
    ];
    const cache = [
      { id: 1, role: 'user', content: '问题', created_at: 't1' },
      { id: 'local_eq', role: 'assistant', content: '完全相同的回答', thinking: false, stopped: true },
    ];
    const { unmount } = mount(dbMsgs, cache);
    await waitFor(() => { expect(document.body.textContent).toContain('完全相同的回答'); }, { timeout: 3000 });
    await new Promise(r => setTimeout(r, 150));
    const after = readCache();
    expect(after.some((m: any) => m.id === 'local_eq')).toBe(false);
    expect(after.filter((m: any) => m.role === 'assistant').length).toBe(1);
    unmount();
  });

  it('stopped 映射：DB 消息带 stopped → 刷新后仍显示"已手动停止"', async () => {
    // 无本地缓存（模拟刷新后纯从 DB 加载）→ local.length===0 → 直接用映射后的 dbMsgs
    const dbMsgs = [
      { id: 1, role: 'user', content: '开始生成', created_at: 't1' },
      { id: 2, role: 'assistant', content: '生成到一半被用户停止的内容', created_at: 't2', stopped: true },
    ];
    const { unmount } = mount(dbMsgs, null);
    await waitFor(() => {
      // stopped→manualStopped 映射生效后，渲染层据 manualStopped 显示此标签
      expect(screen.getByText('已手动停止')).toBeTruthy();
    }, { timeout: 3000 });
    unmount();
  });

  it('正常完成的消息（无 stopped）不显示"已手动停止"（防 C6 回归）', async () => {
    const dbMsgs = [
      { id: 1, role: 'user', content: '正常提问', created_at: 't1' },
      { id: 2, role: 'assistant', content: '正常完整回答没有被中断', created_at: 't2' },
    ];
    const { unmount } = mount(dbMsgs, null);
    await waitFor(() => {
      expect(document.body.textContent).toContain('正常完整回答没有被中断');
    }, { timeout: 3000 });
    // ⛔ C6 缺陷曾让正常完成也显示"已手动停止"；stopped 映射只认 DB stopped=true，不得误伤
    expect(screen.queryByText('已手动停止')).toBeNull();
    unmount();
  });

  // ── C8 补漏（0.4.17）：正文为空 + 有工具步骤 ──
  // ⛔ 场景：模型"只调了工具、还没吐任何正文"时用户点停止。这恰是 C2 根因③针对的情形。
  // 旧判据 `if (m.content && matchesDb(...))` 与 `matchesDb` 内的 `if (!content) return false`
  // 都以 content 为前提 → content 为空串时**整个去重被短路跳过** → 缓存副本进 extra
  // → 追加到末尾且重复（探针实测 assistant 由 1 条变 2 条、local_x 残留）。
  // ⚠️ mock 必须用**端点输出形态**（toolSteps，app.py:688 已做 tool_steps→toolSteps 转换），
  //    用存储层形态（tool_steps）会因字段名不符而假失败——本文件曾因此得出错误结论。
  const EMPTY_BODY_STEPS = [
    { id: 'c1', name: 'read_file', args: { path: 'a.py' }, status: 'interrupted' },
    { id: 'c2', name: 'list_dir', args: { path: '.' }, status: 'ok' },
  ];

  it('空正文 + 工具步骤：DB 与缓存同一条 → 不重复、不挪到末尾', async () => {
    const dbMsgs = [
      { id: 1, role: 'user', content: '请读一下这个文件', created_at: 't1' },
      { id: 2, role: 'assistant', content: '', created_at: 't2', stopped: true,
        toolSteps: EMPTY_BODY_STEPS },
    ];
    const cache = [
      { id: 1, role: 'user', content: '请读一下这个文件', created_at: 't1' },
      { id: 'local_x', role: 'assistant', content: '', stopped: true, manualStopped: true,
        thinking: false, toolSteps: EMPTY_BODY_STEPS },
    ];
    const { unmount } = mount(dbMsgs, cache);
    await waitFor(() => {
      expect(document.body.textContent).toContain('请读一下这个文件');
    }, { timeout: 3000 });
    await new Promise(r => setTimeout(r, 150));

    const after = readCache();
    // ⛔ 核心：副本被去重（旧实现在此得到 2 条 + local_x 残留）
    expect(after.filter((m: any) => m.role === 'assistant').length).toBe(1);
    expect(after.some((m: any) => m.id === 'local_x')).toBe(false);
    unmount();
  });

  it('空正文去重：缓存仍是收敛前的 running、DB 已收敛为 interrupted → 判为同一条', async () => {
    // DB 定稿由 _persist_assistant 把 running 收敛成 interrupted；缓存副本可能是收敛前的
    // running（或旧版本写入的缓存）。签名归一（running≡interrupted）保证不误判为两条。
    const dbMsgs = [
      { id: 1, role: 'user', content: '请读一下这个文件', created_at: 't1' },
      { id: 2, role: 'assistant', content: '', created_at: 't2', stopped: true,
        toolSteps: [{ id: 'c1', name: 'read_file', args: {}, status: 'interrupted' }] },
    ];
    const cache = [
      { id: 1, role: 'user', content: '请读一下这个文件', created_at: 't1' },
      { id: 'local_x', role: 'assistant', content: '', stopped: true, manualStopped: true,
        thinking: false, toolSteps: [{ id: 'c1', name: 'read_file', args: {}, status: 'running' }] },
    ];
    const { unmount } = mount(dbMsgs, cache);
    await waitFor(() => {
      expect(document.body.textContent).toContain('请读一下这个文件');
    }, { timeout: 3000 });
    await new Promise(r => setTimeout(r, 150));

    const after = readCache();
    expect(after.filter((m: any) => m.role === 'assistant').length).toBe(1);
    expect(after.some((m: any) => m.id === 'local_x')).toBe(false);
    // ⛔ 屏上必须是 DB 的定稿态（interrupted），不能是缓存的 running（那会永久转圈）。
    // B4 折叠态下渲染的是**收拢摘要**「工具调用 N 步 · M 成功 · K 中断」，不是展开态的
    // 「已中断，未完成」——故断言对准摘要。⚠️ 这条断言同时证明 running 没赢：
    // 若用的是缓存的 running 副本，B4 判据 `done && running===0` 不满足 → 组收不拢 →
    // 摘要不会出现，且会渲染"正在调用…"。
    const body = document.body.textContent || '';
    expect(body).toContain('中断');
    expect(body).not.toContain('正在调用');
    unmount();
  });

  it('空正文但工具步骤**不同** → 不得过度去重（仍保留副本，防丢消息）', async () => {
    // 反向约束：签名去重不能宽到把"另一条不同消息"也吞掉（那会丢用户可见内容）
    const dbMsgs = [
      { id: 1, role: 'user', content: '第一个问题', created_at: 't1' },
      { id: 2, role: 'assistant', content: '', created_at: 't2', stopped: true,
        toolSteps: [{ id: 'c1', name: 'read_file', args: {}, status: 'interrupted' }] },
    ];
    const cache = [
      { id: 1, role: 'user', content: '第一个问题', created_at: 't1' },
      { id: 'local_y', role: 'assistant', content: '', stopped: true, manualStopped: true,
        thinking: false, toolSteps: [{ id: 'c9', name: 'web_search', args: {}, status: 'interrupted' }] },
    ];
    const { unmount } = mount(dbMsgs, cache);
    await waitFor(() => {
      expect(document.body.textContent).toContain('第一个问题');
    }, { timeout: 3000 });
    await new Promise(r => setTimeout(r, 150));

    const after = readCache();
    // 步骤签名不同 → 视为两条不同消息，副本必须保留（宁可多显示，不可丢内容）
    expect(after.filter((m: any) => m.role === 'assistant').length).toBe(2);
    unmount();
  });
});
