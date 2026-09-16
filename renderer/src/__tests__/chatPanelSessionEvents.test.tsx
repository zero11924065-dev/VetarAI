/*
 * VetarAI - Local-first multi-agent orchestration application
 * Copyright (C) 2026 zero11924065-dev
 * GPL-3.0-or-later（见仓库 LICENSE）
 */
/**
 * REQ-AGT-020（0.4.28）专项：ChatPanel 订阅 APP_RESOURCE_CHANGED 的 session 事件。
 *
 * 链路：委派写子会话直写 DB（无流式事件）→ 后端 delegation.py 写点后经 A13 总线发
 * resource='session' 事件（带 session_id）→ 全局 SSE → appEvents 广播 → ChatPanel
 * 三道过滤（resource / 当前会话 / 非流式）→ 走既有 loadSessionMessages 重拉 DB 合并。
 * 与 a13PanelRefresh.test.tsx 同一纪律：**直接 emit** 广播事件（不经真实 SSE），
 * 聚焦面板侧契约。
 *
 * 覆盖（任务书 ①②③）：
 *  E1 打开的非流式会话收到 session 事件 → 重拉 DB，新消息合并可见
 *  E2 ⛔ 流式进行中的当前会话收到事件 → 绝不重拉（不冲掉乐观/流式气泡态）
 *  E3 其他会话 / 缺 session_id / 非 session 资源 / gap 事件 → 全部忽略（不重拉）
 *
 * 变异锚点（mutate_frontend.py 档 26~29 对应）：E3 抓过滤①②、E2 抓过滤③、E1 抓重拉调用。
 */
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, waitFor, act } from '@testing-library/react';
import React from 'react';
import { ChatPanel } from '../panels/ChatPanel';
import { installFetchMock, route, routeJson, jsonRes, sseResControllable, tokenEvent } from './helpers/fetchMock';
import { emit, __resetEventsForTest } from '../events';
import { APP_RESOURCE_CHANGED } from '../appEvents';

if (typeof (globalThis as any).localStorage === 'undefined') {
  (globalThis as any).localStorage = {
    _d: {} as Record<string, string>,
    getItem(k: string) { return this._d[k] ?? null; },
    setItem(k: string, v: string) { this._d[k] = String(v); },
    removeItem(k: string) { delete this._d[k]; },
    clear() { this._d = {}; },
  };
}

const MSGS_FRAG = '/sessions/s1/messages';

/** 通用路由：dbMessages 由用例可变赋值，模拟"服务端后台直写 DB"。 */
function baseRoutes(dbRef: { msgs: any[] }, extra: any[] = []) {
  return [
    routeJson('/agents/', [{ id: 'a1', name: '测试Agent', role: '工程师' }]),
    routeJson('/ollama/models', [{ name: 'qwen3.8' }]),
    routeJson('/sessions?', [{ id: 's1', title: '会话1', message_count: 0 }]),
    route(MSGS_FRAG, () => jsonRes(dbRef.msgs)),
    ...extra,
  ];
}

beforeEach(() => {
  vi.restoreAllMocks();
  __resetEventsForTest();
  localStorage.clear();
});

describe('REQ-AGT-020 ChatPanel 子会话实时刷新', () => {
  it('E1 打开的非流式会话收到 session 事件 → 重拉合并新消息可见', async () => {
    const dbRef = { msgs: [] as any[] };
    const h = installFetchMock(baseRoutes(dbRef));
    render(<ChatPanel projectId="p1" agentId="a1" />);

    // 初始化选定 s1 并完成首次 DB 加载
    await waitFor(() => expect(h.countOf(MSGS_FRAG)).toBeGreaterThanOrEqual(1), { timeout: 3000 });
    const before = h.countOf(MSGS_FRAG);

    // 服务端后台直写两条委派消息（子 Agent 任务书 + 首轮回复）
    dbRef.msgs = [
      { id: 101, role: 'user', content: '【委派任务】识别附图文字' },
      { id: 102, role: 'assistant', content: '识别结果：ABC', model_used: 'glm-ocr:latest' },
    ];
    await act(async () => {
      emit(APP_RESOURCE_CHANGED, {
        resource: 'session', action: 'create', projectId: 'p1',
        session_id: 's1', message_role: 'assistant', seq: 7,
      });
      await new Promise(r => setTimeout(r, 50));
    });

    // 重拉发生 + 新消息经既有合并路径渲染出来
    await waitFor(() => expect(h.countOf(MSGS_FRAG)).toBeGreaterThan(before), { timeout: 3000 });
    expect(await screen.findByText(/识别结果：ABC/, {}, { timeout: 3000 })).toBeTruthy();
    expect(await screen.findByText(/【委派任务】识别附图文字/)).toBeTruthy();
  });

  it('E2 ⛔ 流式进行中的当前会话收到事件 → 不重拉（不冲掉流式气泡）', async () => {
    const dbRef = { msgs: [] as any[] };
    const ctl = sseResControllable();
    const h = installFetchMock(baseRoutes(dbRef, [route('/chat/stream', () => ctl.res)]));
    render(<ChatPanel projectId="p1" agentId="a1" />);
    await waitFor(() => expect(h.countOf(MSGS_FRAG)).toBeGreaterThanOrEqual(1), { timeout: 3000 });

    // 发一条消息让 s1 进入流式（activeStreamSidRef=s1）
    const inputEl = document.querySelector('textarea[placeholder*="输入消息"]') as HTMLTextAreaElement;
    await act(async () => {
      const setter = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value')!.set!;
      setter.call(inputEl, '继续生成');
      inputEl.dispatchEvent(new Event('input', { bubbles: true }));
    });
    await act(async () => {
      (document.querySelector('button[data-tip="发送"]') as HTMLElement).click();
      await new Promise(r => setTimeout(r, 50));
    });
    // 流式确实进行中（停止按钮出现）；推一个 token 保持活流（不发 done）
    await waitFor(() => expect(document.querySelector('button[data-tip="停止"]')).toBeTruthy(), { timeout: 3000 });
    await act(async () => {
      ctl.push(tokenEvent('流式内容'));
      await new Promise(r => setTimeout(r, 50));
    });

    const before = h.countOf(MSGS_FRAG);
    dbRef.msgs = [{ id: 201, role: 'assistant', content: '不该出现的DB消息' }];
    await act(async () => {
      emit(APP_RESOURCE_CHANGED, {
        resource: 'session', action: 'create', projectId: 'p1',
        session_id: 's1', message_role: 'assistant', seq: 8,
      });
      await new Promise(r => setTimeout(r, 80));
    });

    // ⛔ 绝不重拉：消息端点零新增请求，DB 里的"不该出现"消息不得上屏
    expect(h.countOf(MSGS_FRAG)).toBe(before);
    expect(screen.queryByText(/不该出现的DB消息/)).toBeNull();
    ctl.close();
  });

  it('E3 其他会话 / 缺 session_id / 非 session 资源 / gap → 全部忽略', async () => {
    const dbRef = { msgs: [] as any[] };
    const h = installFetchMock(baseRoutes(dbRef));
    render(<ChatPanel projectId="p1" agentId="a1" />);
    await waitFor(() => expect(h.countOf(MSGS_FRAG)).toBeGreaterThanOrEqual(1), { timeout: 3000 });
    // ⛔ 计数必须覆盖【任意会话】的消息端点：撤掉"仅当前会话"过滤的变异会把
    //    s2 的事件当成当前会话去重拉 /sessions/s2/messages——只数 s1 会漏抓（首轮实测）。
    const anyMsgs = () =>
      h.calls.filter(c => c.url.includes('/sessions/') && c.url.includes('/messages')).length;
    const before = anyMsgs();

    await act(async () => {
      // ① 其他会话的 session 事件（子会话 s2 在推进，但用户打开的是 s1）
      emit(APP_RESOURCE_CHANGED, { resource: 'session', action: 'create', session_id: 's2', seq: 9 });
      // ② 缺 session_id 的畸形事件
      emit(APP_RESOURCE_CHANGED, { resource: 'session', action: 'create', seq: 10 });
      // ③ 非 session 资源（即便带了 session_id 字段也不得越权重拉消息区）
      emit(APP_RESOURCE_CHANGED, { resource: 'workflow', action: 'update', session_id: 's1', seq: 11 });
      // ④ gap 对账事件（resource:'*'，无 session_id 可定向，不碰消息区）
      emit(APP_RESOURCE_CHANGED, { resource: '*', gap: true, seq: 12 });
      await new Promise(r => setTimeout(r, 80));
    });

    expect(anyMsgs()).toBe(before);   // ⛔ 四类事件都不得触发任何会话的消息重拉
  });
});
