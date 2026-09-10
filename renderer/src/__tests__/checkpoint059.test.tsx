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
import { render, waitFor } from '@testing-library/react';
import React from 'react';
import { ChatPanel } from '../panels/ChatPanel';

import { jsonRes } from './helpers/fetchMock';

// checkpoint-059：僵尸气泡清理回归。
// 场景：缓存里残留"进行中"的空内容 assistant 气泡（流式写穿冻结的快照），
// 后端其实已完成（DB 有最终回复）。加载合并后：DB 的最终回复在屏，僵尸气泡不出现，
// 界面不再定格"思考中…"。
if (typeof (globalThis as any).localStorage === 'undefined') {
  (globalThis as any).localStorage = {
    _d: {} as Record<string, string>,
    getItem(k: string) { return this._d[k] ?? null; },
    setItem(k: string, v: string) { this._d[k] = String(v); },
    removeItem(k: string) { delete this._d[k]; },
    clear() { this._d = {}; },
  };
}

const DB_MSGS = [
  { id: 1, role: 'user', content: '财务在不在，让他帮我查一下食品类的开票税点', created_at: 't1' },
  { id: 2, role: 'assistant', content: '好的，已安排财务专员为您完成查询。食品类开票税点：…', created_at: 't2' },
];

beforeEach(() => { vi.restoreAllMocks(); localStorage.clear(); });

function mountWithDbAndZombieCache(zombie: any) {
  localStorage.setItem('subagent_messages_v4', JSON.stringify({
    s1: [...DB_MSGS, zombie],
  }));
  const impl: typeof fetch = async (url) => {
    const u = String(url);
    if (u.includes('/agents/')) return jsonRes([{ id: 'a1', name: '行政主管', role: 'x' }]);
    if (u.includes('/ollama/models')) return jsonRes([{ name: 'qwen3.6:35b' }]);
    if (u.includes('/sessions?')) return jsonRes([{ id: 's1', title: '会话 1', message_count: 2 }]);
    if (u.includes('/sessions/s1/messages')) return jsonRes(DB_MSGS);
    return jsonRes([]);
  };
  vi.spyOn(globalThis, 'fetch').mockImplementation(impl);
  return render(<ChatPanel projectId="p1" agentId="a1" />);
}

describe('checkpoint-059 僵尸气泡清理', () => {
  it('空内容进行态气泡被清理：DB 最终回复显示，无思考中定格', async () => {
    const { unmount } = mountWithDbAndZombieCache({ id: 'local_z1', role: 'assistant', content: '', thinking: true, waitingSeconds: 21 });
    await waitFor(() => {
      expect(document.body.textContent).toContain('已安排财务专员');
    }, { timeout: 3000 });
    // 等待合并加载完成（缓存写回后也不含僵尸）
    await new Promise(r => setTimeout(r, 100));
    const cache = JSON.parse(localStorage.getItem('subagent_messages_v4') || '{}')['s1'] || [];
    expect(cache.some((m: any) => m.id === 'local_z1')).toBe(false);
    unmount();
  });

  it('有内容的中断气泡恢复为"已停止"态（thinking/waitingSeconds 清除）', async () => {
    const { unmount } = mountWithDbAndZombieCache({ id: 'local_z2', role: 'assistant', content: '半截回复…', thinking: true, waitingSeconds: 9 });
    await waitFor(() => {
      const cache = JSON.parse(localStorage.getItem('subagent_messages_v4') || '{}')['s1'] || [];
      const z = cache.find((m: any) => m.id === 'local_z2');
      return expect(z && z.thinking === false && z.waitingSeconds === 0 && z.stopped === true).toBeTruthy();
    }, { timeout: 3000 });
    unmount();
  });

  // #13（0.4.19）：缓存恢复的异常中断气泡必须有可见标记。
  // 判据：无 manualStopped（非用户点停）且无 completedDuration（没走 done 路径）
  // → 崩溃/关应用/断连造成的半成品。此前恢复后与正常回复长得一样，用户看不出没写完。
  it('中断气泡恢复后标"已中断执行"（用户能看出是半成品）', async () => {
    const { unmount } = mountWithDbAndZombieCache({
      id: 'local_z3', role: 'assistant', content: '写到一半的回复', thinking: true, waitingSeconds: 5,
    });
    await waitFor(() => {
      expect(document.body.textContent).toContain('已中断执行');
    }, { timeout: 3000 });
    await waitFor(() => {
      const cache = JSON.parse(localStorage.getItem('subagent_messages_v4') || '{}')['s1'] || [];
      const z = cache.find((m: any) => m.id === 'local_z3');
      return expect(z && typeof z.interruptedNote === 'string' && z.interruptedNote.includes('已中断执行')).toBeTruthy();
    }, { timeout: 3000 });
    unmount();
  });

  it('正常完成的气泡（有 completedDuration）不得被误标中断', async () => {
    const { unmount } = mountWithDbAndZombieCache({
      id: 'local_z4', role: 'assistant', content: '完整回复内容', thinking: false,
      completedDuration: 12, stopped: true,
    });
    await waitFor(() => {
      expect(document.body.textContent).toContain('完整回复内容');
    }, { timeout: 3000 });
    await new Promise(r => setTimeout(r, 100));
    expect(document.body.textContent).not.toContain('已中断执行');
    const cache = JSON.parse(localStorage.getItem('subagent_messages_v4') || '{}')['s1'] || [];
    const z = cache.find((m: any) => m.id === 'local_z4');
    expect(z && z.interruptedNote === undefined).toBe(true);
    unmount();
  });

  it('手动停止的气泡走"已手动停止"渲染，不重复标"已中断执行"', async () => {
    const { unmount } = mountWithDbAndZombieCache({
      id: 'local_z5', role: 'assistant', content: '手动停下的半截', thinking: false,
      manualStopped: true, stopped: true,
    });
    await waitFor(() => {
      expect(document.body.textContent).toContain('已手动停止');
    }, { timeout: 3000 });
    expect(document.body.textContent).not.toContain('已中断执行');
    unmount();
  });
});
