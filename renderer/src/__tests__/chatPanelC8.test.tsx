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
});
