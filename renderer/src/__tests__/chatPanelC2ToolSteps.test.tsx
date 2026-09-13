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

import { jsonRes, sseRes, sseEvent } from './helpers/fetchMock';
import { readChatPanelSource } from './helpers/chatSource';

/**
 * 第 3 批（0.4.16）C2 **根因③** 专项：停止后最后一个工具不得仍显示"正在调用…"。
 *
 * ⛔ 这是一个**我第一遍实现时遗漏、被用户要求逐条核查代码后才发现**的根因：
 * C2 需求写明"三重根因"，我做了①（前端调 stop 端点）②（cancel_check 接线 + Event 硬取消），
 * 但根因③「前端 tool_call 的 running 状态未在 abort 时 patch」完全没做。后果是需求标题
 * 那个**用户可见症状依旧存在**：工具步骤以 status:'running' 加入，停止时只 patch 了
 * content/stopped/thinking，于是界面上最后一个工具**永久转圈显示"正在调用 …"**；
 * 更连带使 B4 折叠判据 `done && running === 0` 永不满足 → 步骤组**永远展开**
 * （这正是 C8 的"不可折叠"症状）；后端还把 running 原样落库 → 刷新后依旧"正在调用"。
 *
 * 修法：新增第四态 `interrupted`（⛔ 不能标 ok=谎称成功，也不能标 error=谎报失败并污染
 * B4 约束①的警示色），前端三条停止路径 patch toolSteps、后端落库出口统一收敛。
 *
 * ⛔ 测试构造方式（我在 jsdom 环境限制上碰壁后的最终取舍，写在 describe 内）：
 * 用一次性流 enqueue(tool_call + cancelled) 后 close —— 流结束触发渲染 flush，
 * 可稳定断言收敛结果。曾试过"流保持打开 + push 中间态"，但 jsdom 下流不 close
 * 时渲染不刷新，中间态根本观察不到（详见 describe 内的范围说明）。
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

const TOOL_CALL = sseEvent('tool_call', { id: 'c1', name: 'read_file', args: { path: 'a.py' } });

describe('C2 根因③：停止后工具步骤不得仍显示"正在调用"', () => {
  /**
   * ⛔ 测试范围说明（我在 jsdom 环境限制上反复碰壁后的取舍，不是偷懒）：
   * 三条停止路径（cancelled 事件 / 内层 AbortError / 外层 AbortError）的 toolSteps
   * patch 代码是**同一次替换生成的完全相同语句**，故测 cancelled 一条即可代表三条；
   * 另两条用**静态核查**确保存在（见用例③）。
   *
   * 为什么不测"点停止按钮"的前端中间态：需要流保持打开才有 running 中间态，
   * 而 jsdom 下**流不 close 时渲染不 flush**（对照实验：一次性流 sseRes 会关流，
   * 能正常渲染并显示"工具调用 N 步"；故意不 close 的流则连步骤条都不出现）。
   * 这是测试环境限制，非被测代码缺陷——cancelled 用例已证明同一套 patch 逻辑生效。
   */
  it('① 后端 cancelled 到达 → running 步骤收敛，"正在调用"消失并标中断', async () => {
    // 竞态场景：后端先发 cancelled（可能先于前端 AbortError 到达）
    const encoder = new TextEncoder();
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(encoder.encode(
          TOOL_CALL + sseEvent('cancelled', { detail: '已停止生成' })));
        controller.close();
      },
    });
    const res = new Response(stream, { status: 200, headers: { 'Content-Type': 'text/event-stream' } });
    const impl: typeof fetch = async (url) => {
      const u = String(url);
      if (u.includes('/agents/')) return jsonRes([{ id: 'a1', name: '行政主管', role: 'x' }]);
      if (u.includes('/ollama/models')) return jsonRes([{ name: 'qwen3.6:35b' }]);
      if (u.includes('/sessions?')) return jsonRes([{ id: 's1', title: '会话 1', message_count: 1 }]);
      if (u.includes('/messages')) return jsonRes([]);
      if (u.includes('/ollama/chat/stream')) return res;
      return jsonRes([]);
    };
    vi.spyOn(globalThis, 'fetch').mockImplementation(impl);
    const { unmount } = render(<ChatPanel projectId="p1" agentId="a1" />);
    const ta = () => document.querySelector('textarea') as HTMLTextAreaElement;
    await waitFor(() => expect(ta()).toBeTruthy(), { timeout: 3000 });
    const setter = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value')!.set!;
    await act(async () => {
      setter.call(ta(), '读一下');
      ta().dispatchEvent(new Event('input', { bubbles: true }));
      ta().dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
    });
    await waitFor(() => {
      expect(document.body.textContent).toContain('工具调用 1 步');
    }, { timeout: 4000 });

    const txt = document.body.textContent || '';
    // ⛔ 核心断言：不得仍显示"正在调用"（这正是 C2 需求标题的用户可见症状）
    expect(txt).not.toContain('正在调用');
    // 折叠摘要如实标出中断数（不谎称成功"已完成"，也不谎报"N 失败"）
    expect(txt).toContain('中断');
    expect(txt).not.toContain('已完成');
    // 用户主动停止的标记仍在（C6 语义）
    expect(txt).toContain('已手动停止');
    unmount();
  });

  it('② 正常完成（done）的步骤仍为 ok，不被误标 interrupted（防止修过头）', async () => {
    const impl: typeof fetch = async (url) => {
      const u = String(url);
      if (u.includes('/agents/')) return jsonRes([{ id: 'a1', name: '行政主管', role: 'x' }]);
      if (u.includes('/ollama/models')) return jsonRes([{ name: 'qwen3.6:35b' }]);
      if (u.includes('/sessions?')) return jsonRes([{ id: 's1', title: '会话 1', message_count: 1 }]);
      if (u.includes('/messages')) return jsonRes([]);
      if (u.includes('/ollama/chat/stream')) return sseRes([
        TOOL_CALL,
        sseEvent('tool_result', { id: 'c1', name: 'read_file', ok: true, summary: '读到 120 行' }),
        sseEvent('done', { content: '已完成', tool_calls: [] }),
      ]);
      return jsonRes([]);
    };
    vi.spyOn(globalThis, 'fetch').mockImplementation(impl);
    const { unmount } = render(<ChatPanel projectId="p1" agentId="a1" />);
    const ta = () => document.querySelector('textarea') as HTMLTextAreaElement;
    await waitFor(() => expect(ta()).toBeTruthy(), { timeout: 3000 });
    const setter = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value')!.set!;
    await act(async () => {
      setter.call(ta(), '读文件');
      ta().dispatchEvent(new Event('input', { bubbles: true }));
      ta().dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
    });
    await waitFor(() => {
      expect(document.body.textContent).toContain('已完成');
    }, { timeout: 4000 });
    const txt = document.body.textContent || '';
    expect(txt).toContain('工具调用 1 步');
    expect(txt).not.toContain('中断');       // ⛔ 成功不得被标中断
    expect(txt).not.toContain('正在调用');
    unmount();
  });

  it('③ 五条收敛出口的 toolSteps patch 均存在（静态核查，覆盖 jsdom 测不到的路径）', async () => {
    // 读源码核查：所有"流/停止终止"出口都必须把 running 收敛为 interrupted。
    // ⛔ 0.4.22 重打包修复二（checkpoint-109）：收敛抽成模块级纯函数 convergeRunningSteps，
    //   出口从 3 条（手动停止×3）扩到 **5 条**（+分裂定格 segment_break、+done 兜底）——
    //   用户实测分裂气泡残留「正在调用…」转圈，根因是 M5 重连丢 tool_result 后
    //   done/定格路径都不收敛。断言改为数【调用点】：任何一条出口被删都会红。
    // ⛔ 0.4.26（B9-2 C4/R4-S1）：三处手动停止 patch 收敛进共享闭包 applyUserStopped()
    //   （行为测试①② + B12 + C8 全绿佐证行为不变），静态断言随之改为两段式：
    //   patch 点计数（分裂定格 + done + 闭包 = 3）+ 闭包接线计数（1 定义 + 3 调用 = 4），
    //   任一停止路径忘调闭包、或任一 patch 点被删，都会红——绑定强度不低于原"数 5"。
    // ⛔ 用正则核查**真实代码**，不靠文本子串（注释里的字样会误伤，C5 已踩过）。
    // ⛔ 不留"读不到就假通过"的兜底分支：?raw 失效时必须**失败**而非空转
    //   （空转断言比没有断言更危险——它给出虚假的安全感）。
    const src = await readChatPanelSource();
    expect(src.length).toBeGreaterThan(10000);      // 确实读到了源码
    // 调用点统一写法 `toolSteps: convergeRunningSteps(`（定义处是
    // `function convergeRunningSteps(steps:`，不含该前缀，不会误计）
    expect((src.match(/toolSteps: convergeRunningSteps\(/g) || []).length).toBe(3);
    // 三条手动停止路径（cancelled 事件 / 内层重试 AbortError / 外层流 AbortError）
    // 必须全部接线共享闭包：3 处调用 + 1 处定义（箭头函数定义写法 `= (...) =>`
    // 不含 `applyUserStopped(` 前缀，不会误计；⛔ 指针注释不得含函数名字面量）
    expect((src.match(/applyUserStopped\(/g) || []).length).toBe(3);
    expect(src).toContain('const applyUserStopped =');
    // 纯函数本体必须存在（收敛逻辑的唯一真相源）
    expect(src).toContain('export function convergeRunningSteps(');
  });
});
