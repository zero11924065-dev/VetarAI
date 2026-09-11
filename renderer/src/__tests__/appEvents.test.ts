/*
 * VetarAI - Local-first multi-agent orchestration application
 * Copyright (C) 2026 zero11924065-dev
 * GPL-3.0-or-later（见仓库 LICENSE）
 */
/**
 * A13（0.4.22）专项：appEvents.ts —— App 级常驻订阅「资源变更」流 + 跨面板广播。
 *
 * 覆盖：
 *  T1 启动即订阅 /api/events/stream（带 since=0 游标）
 *  T2 resource_changed → 广播 APP_RESOURCE_CHANGED，字段映射正确（project_id→projectId）
 *  T3 gap → 广播 resource:'*' + gap:true（所有面板无条件重拉，不拿半截状态渲染）
 *  T4 connected 握手只更新游标，**不**广播给面板（避免无意义重拉）
 *  T5 幂等单例：重复 start 返回同一 stop，只开一条连接（防 StrictMode/多面板各开一条）
 *  T6 stop() 复位单例：isRunning=false，可重新 start（App 重挂载/测试隔离）
 *  T7 断流退避重连，第二次 fetch 带上次 seq 游标（since=lastSeq，无延时且不丢变更）
 *  T8 ⛔ 卸载（stop）后断流**不重连**（计划明列约束：无幽灵请求）
 *  T9 源码断言：重连排程受 !cancelled 守卫（撤守卫即 T8 失效，锚定实际形态防注释污染）
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { sseResControllable, sseEvent } from './helpers/fetchMock';
import { on, __resetEventsForTest } from '../events';
import {
  startAppEventStream, isAppEventStreamRunning, __stopAppEventStreamForTest,
  APP_RESOURCE_CHANGED, AppResourceEvent,
} from '../appEvents';

const tick = (ms = 40) => new Promise(r => setTimeout(r, ms));

let streamCtl: ReturnType<typeof sseResControllable> | null = null;
let fetchCalls: string[] = [];

/** mock：/events/stream 返回可控 SSE 流；其余返回空 JSON。闭包读最新 streamCtl（重连时换新流）。 */
function mockEventsStream() {
  streamCtl = sseResControllable();
  const impl: typeof fetch = async (input) => {
    const u = String(typeof input === 'string' ? input : (input as any).url);
    fetchCalls.push(u);
    if (u.includes('/events/stream')) return streamCtl!.res;
    return new Response('{}', { status: 200, headers: { 'Content-Type': 'application/json' } });
  };
  vi.spyOn(globalThis, 'fetch').mockImplementation(impl);
}

const streamUrls = () => fetchCalls.filter(u => u.includes('/events/stream'));

beforeEach(() => {
  vi.restoreAllMocks();
  __stopAppEventStreamForTest();
  __resetEventsForTest();
  fetchCalls = [];
  streamCtl = null;
});
afterEach(() => {
  __stopAppEventStreamForTest();
  vi.useRealTimers();
});

describe('A13 appEvents 应用级资源变更流', () => {
  it('T1 启动即订阅 /api/events/stream（带 since=0）', async () => {
    mockEventsStream();
    const stop = startAppEventStream();
    await tick();
    expect(streamUrls().length).toBe(1);
    expect(streamUrls()[0]).toContain('since=0');
    expect(isAppEventStreamRunning()).toBe(true);
    stop();
  });

  it('T2 resource_changed → 广播，字段映射正确（project_id→projectId）', async () => {
    mockEventsStream();
    const got: AppResourceEvent[] = [];
    const off = on(APP_RESOURCE_CHANGED, (e) => got.push(e));
    const stop = startAppEventStream();
    await tick();
    streamCtl!.push(sseEvent('resource_changed',
      { resource: 'workflow', action: 'update', project_id: 'p1', workflow_id: 'wf9', seq: 5 }));
    await tick();
    expect(got.length).toBe(1);
    expect(got[0].resource).toBe('workflow');
    expect(got[0].action).toBe('update');
    expect(got[0].projectId).toBe('p1');
    expect(got[0].workflow_id).toBe('wf9');
    expect(got[0].seq).toBe(5);
    off(); stop();
  });

  it('T3 gap → 广播 resource:"*" + gap:true（全面板无条件重拉）', async () => {
    mockEventsStream();
    const got: AppResourceEvent[] = [];
    const off = on(APP_RESOURCE_CHANGED, (e) => got.push(e));
    const stop = startAppEventStream();
    await tick();
    streamCtl!.push(sseEvent('gap', { from: 1, oldest_available: 50, seq: 50 }));
    await tick();
    expect(got.length).toBe(1);
    expect(got[0].resource).toBe('*');
    expect(got[0].gap).toBe(true);
    off(); stop();
  });

  it('T4 connected 握手只更新游标，不广播给面板', async () => {
    mockEventsStream();
    const got: AppResourceEvent[] = [];
    const off = on(APP_RESOURCE_CHANGED, (e) => got.push(e));
    const stop = startAppEventStream();
    await tick();
    streamCtl!.push(sseEvent('connected', { seq: 3 }));
    await tick();
    expect(got.length).toBe(0);   // connected 不触发面板重拉
    off(); stop();
  });

  it('T5 幂等单例：重复 start 同一 stop，只开一条连接', async () => {
    mockEventsStream();
    const s1 = startAppEventStream();
    const s2 = startAppEventStream();
    expect(s1).toBe(s2);          // 同一 stop 函数
    await tick();
    expect(streamUrls().length).toBe(1);   // ⛔ 不开第二条连接
    s1();
    expect(isAppEventStreamRunning()).toBe(false);
  });

  it('T6 stop() 复位单例，可重新 start', async () => {
    mockEventsStream();
    const stop = startAppEventStream();
    await tick();
    expect(isAppEventStreamRunning()).toBe(true);
    stop();
    expect(isAppEventStreamRunning()).toBe(false);
    // 重新 start 应开新连接（单例已复位）
    streamCtl = sseResControllable();
    const stop2 = startAppEventStream();
    await tick();
    expect(isAppEventStreamRunning()).toBe(true);
    expect(streamUrls().length).toBe(2);
    stop2();
  });

  it('T7 断流退避重连，第二次 fetch 带上次 seq 游标', async () => {
    vi.useFakeTimers();
    try {
      mockEventsStream();
      const stop = startAppEventStream();
      await vi.advanceTimersByTimeAsync(50);          // 首连 + 读 connected
      streamCtl!.push(sseEvent('resource_changed',
        { resource: 'agent', action: 'delete', seq: 9 }));
      await vi.advanceTimersByTimeAsync(50);          // 消费 → lastSeq=9
      expect(streamUrls().length).toBe(1);
      streamCtl!.close();                             // 断流 → 排重连
      await vi.advanceTimersByTimeAsync(50);
      streamCtl = sseResControllable();               // 第二次 fetch 返回新流
      await vi.advanceTimersByTimeAsync(3000);        // 触发退避重连
      expect(streamUrls().length).toBe(2);
      expect(streamUrls()[1]).toContain('since=9');   // ⛔ 带游标补发，不丢变更
      stop();
    } finally { vi.useRealTimers(); }
  });

  it('T8 ⛔ 卸载（stop）后断流不重连（无幽灵请求）', async () => {
    vi.useFakeTimers();
    try {
      mockEventsStream();
      const stop = startAppEventStream();
      await vi.advanceTimersByTimeAsync(50);
      expect(streamUrls().length).toBe(1);
      stop();                                          // cancelled=true + abort
      await vi.advanceTimersByTimeAsync(50);           // abort 令 read 抛错 → 走 catch
      await vi.advanceTimersByTimeAsync(5000);         // 远超退避间隔
      expect(streamUrls().length).toBe(1);             // ⛔ 没有第二条连接
    } finally { vi.useRealTimers(); }
  });

  it('T9 源码断言：重连排程受 !cancelled 守卫（撤守卫即 T8 失效）', async () => {
    // ⛔ ?raw 真读源码（项目既有范式，见 checkpoint073）——防"注释里写了就算实现"的污染。
    const code = await import('../appEvents?raw').then(m => m.default as string);
    // ⛔ 锚定实际形态：if (!cancelled) retryTimer = setTimeout(run, RETRY_MS)
    expect(/if\s*\(\s*!cancelled\s*\)\s*retryTimer\s*=\s*setTimeout\(\s*run/.test(code)).toBe(true);
    // ⛔ stop 里必须 cancelled=true + abort（卸载不重连的另一半）
    expect(code).toContain('cancelled = true');
    expect(code).toContain('ctrl.abort()');
  });
});
