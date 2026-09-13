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
/**
 * 第 0 批测试加固（0.4.14）· 动作二：类型化 fetch mock。
 *
 * ⛔ 它要根治的问题（"桩与真实签名脱节"）：
 *   旧写法是手写一个假 response 对象再用 `as any` 收尾：
 *     vi.spyOn(globalThis,'fetch').mockImplementation((async (url: any, init?: any) => {
 *       if (u.includes('/x')) return { ok: true, status: 200, json: async () => DATA };
 *     }) as any);
 *   `as any` 把 fetch 的返回类型整个擦掉 → **tsc 完全不检查这个桩**。后果有两类：
 *     ① 假对象缺成员：真实代码读 `res.text()` / `res.statusText` / `res.body.getReader()`，
 *        桩里没有 → 运行时才炸，或更糟——被 `catch` 吞掉后走另一条分支，**测试假绿**；
 *     ② 参数签名分歧：真实代码 `fetch(url, {method,body,signal})`，桩只写 `(url)`，
 *        多传的被 JS 静默忽略 → 桩根本没在验证它声称验证的东西。
 *   这正是"测试网不可信"的来源，也是重构（第 9 批）前必须堵住的洞。
 *
 * ✅ 本 helper 的做法：**返回平台原生 `Response`**（实测 jsdom/node 环境具备
 *   Response + ReadableStream + TextEncoder），并把安装函数的类型钉成 `typeof fetch`。
 *   于是 `as any` 被彻底消除，任何"假对象缺成员/类型不符"都在 **tsc 阶段**报错，
 *   分歧从"测试假绿"变成"编译不过"。
 *
 * 覆盖范围（实测生产代码用到的 Response 成员，grep 统计）：
 *   json ×91、ok ×87、status ×57、text ×5、body ×4、statusText ×1；headers ×0。
 *   原生 Response 全部提供，故无缺口。
 */
import { vi } from 'vitest';

/** SSE 事件行构造器（与后端 `sidecar/agent_engine/loop.py` 的输出格式一致）。 */
export const sseEvent = (event: string, data: unknown): string =>
  `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;

/**
 * ⛔ mock 载荷必须与后端权威结构一致，否则测试是在验证一个不存在的协议。
 * 已核实的权威字段（sidecar/agent_engine/loop.py）：
 *   token → {"delta": ...}      （:1036，不是 text）
 *   done  → {"content": ..., "tool_calls": [...]}   （:1068）
 * 若 done 不带 content，前端只能靠 requestAnimationFrame 增量 flush，
 * 而 **jsdom 默认不提供 raf** → 内容渲染不出来，极易误判为产品缺陷（本轮踩过）。
 */
export const tokenEvent = (delta: string): string => sseEvent('token', { delta });
export const doneEvent = (content: string, toolCalls: unknown[] = []): string =>
  sseEvent('done', { content, tool_calls: toolCalls });

/** JSON 响应。status>=400 时 ok 自动为 false（与真实 fetch 语义一致）。 */
export function jsonRes(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

/**
 * SSE 流式响应：body 是真实 ReadableStream，可被 res.body.getReader() 消费。
 * 用于 /ollama/chat/stream 这类流式端点。
 */
export function sseRes(events: string[], status = 200): Response {
  const text = events.join('');
  const encoder = new TextEncoder();
  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      controller.enqueue(encoder.encode(text));
      controller.close();
    },
  });
  return new Response(stream, {
    status,
    headers: { 'Content-Type': 'text/event-stream' },
  });
}

/**
 * 慢速 SSE：分段 enqueue，段间留间隔。
 * 用于构造"流进行中"的稳定中间态（如验证工具步骤运行中不得折叠），
 * ⛔ 不要用瞬间结束的流去断言中间态——那是时序赌博，是 chatPanelStream 长期 flaky 的根源。
 */
export function sseResSlow(events: string[], gapMs = 120, status = 200): Response {
  const encoder = new TextEncoder();
  const stream = new ReadableStream<Uint8Array>({
    async start(controller) {
      for (const e of events) {
        controller.enqueue(encoder.encode(e));
        await new Promise(r => setTimeout(r, gapMs));
      }
      controller.close();
    },
  });
  return new Response(stream, { status, headers: { 'Content-Type': 'text/event-stream' } });
}

/** 可控 SSE：把 enqueue/close 的控制权交给测试，用于精确构造"卸载后才发 done"等时序。 */
/**
 * 可控 SSE：把 enqueue/close 的控制权交给测试，用于精确构造"卸载后才发 done"等时序。
 *
 * 带**缓冲区**：start() 之前调用的 push 先暂存，start 触发时一次性冲刷。
 * 这是防御性的（WHATWG 规范下 start 通常在构造期同步执行，故多数情况用不到），
 * 但可避免不同运行时实现下 start 时机差异导致事件丢失。
 *
 * ⛔ 使用方注意（我在此踩过坑，归因一度写错）：push 之后**必须在 act 内 await 一拍**，
 * 否则 reader 读到数据与 React 重渲染会发生在 act 之外、DOM 不被 flush，
 * 表现为"事件像没送达"。正确写法：
 *   await act(async () => { ctl.push(ev); await new Promise(r => setTimeout(r, 50)); });
 * 真实原因不是本 helper 丢事件——曾误判为此并写进注释，实测（一次性流 sseRes 能正常
 * 渲染同样的工具步骤）后纠正。
 */
export function sseResControllable(status = 200): {
  res: Response;
  push: (event: string) => void;
  close: () => void;
} {
  const encoder = new TextEncoder();
  let started = false;
  let ctrl: ReadableStreamDefaultController<Uint8Array> | null = null;
  let closed = false;
  const buffer: string[] = [];

  const flush = () => {
    if (!ctrl) return;
    while (buffer.length) {
      try { ctrl.enqueue(encoder.encode(buffer.shift()!)); }
      catch { buffer.length = 0; break; }   // 已关闭 → 丢弃剩余
    }
  };

  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      started = true;
      ctrl = controller;
      flush();                               // 冲刷 start 之前积压的事件
      if (closed) { try { controller.close(); } catch { /* noop */ } }
    },
  });

  return {
    res: new Response(stream, { status, headers: { 'Content-Type': 'text/event-stream' } }),
    push: (e: string) => {
      if (closed) return;
      buffer.push(e);
      if (started) flush();
    },
    close: () => {
      closed = true;
      if (started && ctrl) { try { ctrl.close(); } catch { /* 已关闭 */ } }
    },
  };
}

/** 路由处理函数：按 url/init 决定返回哪个 Response；返回 null 表示"未匹配"。 */
export type FetchRoute = (
  url: string,
  init: RequestInit | undefined,
) => Response | null | Promise<Response | null>;

export interface FetchMockHandle {
  /** 所有被调用的 (method, url) 记录，供断言"确实请求了某端点"。 */
  calls: Array<{ method: string; url: string; init?: RequestInit }>;
  /** 命中某端点的次数。 */
  countOf: (urlFragment: string) => number;
  /** 最后一次命中某端点的请求体（JSON 解析后），供断言发给后端的载荷。 */
  lastBodyOf: (urlFragment: string) => any;
  /** 未匹配到任何路由的 url（暴露"测试漏配路由"这类静默问题）。 */
  unmatched: string[];
}

/**
 * 安装类型化 fetch mock。
 *
 * ⛔ 关键：`mockImplementation` 的参数类型是 `typeof fetch`（下面显式标注），
 * 因此 route 必须返回 `Response`——返回手写假对象会 **tsc 报错**，脱节在编译期暴露。
 * 这就是动作二的全部价值：把"运行时静默分歧"变成"编译期硬错误"。
 *
 * @param routes  按顺序匹配，第一个返回非 null 的生效；全部未命中则返回 jsonRes({}) 并记入 unmatched
 * @param fallback 未命中时的兜底响应（默认空 JSON 对象）
 */
export function installFetchMock(
  routes: FetchRoute[],
  fallback: () => Response = () => jsonRes({}),
): FetchMockHandle {
  const handle: FetchMockHandle = { calls: [], countOf: () => 0, lastBodyOf: () => undefined, unmatched: [] };

  handle.countOf = (frag: string) => handle.calls.filter(c => c.url.includes(frag)).length;
  handle.lastBodyOf = (frag: string) => {
    const hits = handle.calls.filter(c => c.url.includes(frag));
    if (!hits.length) return undefined;
    const raw = hits[hits.length - 1].init?.body;
    if (typeof raw !== 'string') return raw;
    try { return JSON.parse(raw); } catch { return raw; }
  };

  const impl: typeof fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === 'string' ? input : (input instanceof URL ? input.toString() : input.url);
    handle.calls.push({ method: String(init?.method || 'GET'), url, init });
    for (const route of routes) {
      const r = await route(url, init);
      if (r) return r;
    }
    handle.unmatched.push(url);
    return fallback();
  };

  vi.spyOn(globalThis, 'fetch').mockImplementation(impl);
  return handle;
}

/**
 * 便捷路由：url 含某片段 → 返回固定 Response。
 * 让常见写法一行搞定，且保持类型受检。
 */
export const route = (urlFragment: string, make: () => Response): FetchRoute =>
  (url) => (url.includes(urlFragment) ? make() : null);

/** 便捷路由：url 含某片段 → 返回固定 JSON。 */
export const routeJson = (urlFragment: string, data: unknown, status = 200): FetchRoute =>
  route(urlFragment, () => jsonRes(data, status));
