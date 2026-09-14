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
 * B9-2 C8（R4-S5）：SSE 公共 I/O 壳。
 *
 * 本文件是【形状归并】而非新逻辑——两个壳逐行来自既有站点（appEvents/TaskPanel/
 * ChatPanel 的内联实现），行为保持不变：
 *
 * 1. `consumeSSE`：消费壳 —— getReader/TextDecoder/SSEStreamParser/push 循环/flush。
 *    事件回调【同步派发】（与三站点原内联循环一致：同一 read 批次内不引入微任务间隔，
 *    流式时序敏感，不得改成 await 回调）。
 *
 * 2. `startResilientStream`：弹性重连壳 —— cancelled 标志/AbortController/retryTimer/
 *    静默 catch/退避 setTimeout(run, ms)/返回清理函数。
 *    退避毫秒数（retryMs）由调用方传入，本壳不写死任何数值。
 *    两站点差异已参数化：url（每次尝试重新求值，appEvents 靠它带 ?since= 游标）、
 *    onConnect（TaskPanel 的 setStreamOn(true)，appEvents 无）、
 *    onClose（TaskPanel 的 finally setStreamOn(false)，appEvents 无）。
 */
import { SSEEvent, SSEStreamParser } from './sseParser';

/**
 * 消费一条 SSE 响应体：读完整个流，逐事件【同步】回调 onEvent，结尾 flush 残留缓冲。
 * 与三站点原内联循环逐行同构（仅壳归并，事件语义不变）。
 */
export async function consumeSSE(
  body: ReadableStream<Uint8Array>,
  onEvent: (ev: SSEEvent) => void | Promise<void>,
): Promise<void> {
  const reader = body.getReader();
  const decoder = new TextDecoder();
  const parser = new SSEStreamParser();
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    for (const ev of parser.push(decoder.decode(value, { stream: true }))) onEvent(ev);
  }
  for (const ev of parser.flush()) onEvent(ev);
}

/** startResilientStream 参数集（两站点实际差异项）。 */
export interface ResilientStreamOptions {
  /** 每次连接尝试重新求值（重连时可带最新游标，如 appEvents 的 ?since=lastSeq）。 */
  url: () => string;
  /** 事件回调（同步派发；调用方自行做 cancelled/卸载守卫）。 */
  onEvent: (ev: SSEEvent) => void;
  /** 断流退避重连间隔（ms）。调用方原值传入，本壳不改写。 */
  retryMs: number;
  /** 连接建立且未取消后触发（TaskPanel：setStreamOn(true)；appEvents 不传）。 */
  onConnect?: () => void;
  /** 流结束/失败后的 finally 中、未取消时触发（TaskPanel：setStreamOn(false)；appEvents 不传）。 */
  onClose?: () => void;
}

/**
 * 启动弹性 SSE 流：失败/断流静默退避重连，stop 后绝不重连。
 * 返回 stop 函数（cancelled=true + abort + 清退避定时器）。
 *
 * 卸载绝不重连：断流退避重连只在 !cancelled 时排程。
 * 流失败静默：不弹错误条（各面板手动刷新仍可用），只静默退避重连。
 */
export function startResilientStream(opts: ResilientStreamOptions): () => void {
  let cancelled = false;
  const ctrl = new AbortController();
  let retryTimer: ReturnType<typeof setTimeout> | null = null;

  const run = async () => {
    try {
      const res = await fetch(opts.url(), { signal: ctrl.signal });
      if (!res.ok || !res.body) throw new Error(`HTTP ${res.status}`);
      if (cancelled) return;
      opts.onConnect?.();
      await consumeSSE(res.body, opts.onEvent);
    } catch {
      // 静默：流失败不弹错误条（面板手动刷新仍可用），只在下方退避重连
    } finally {
      if (!cancelled) opts.onClose?.();
    }
    if (!cancelled) retryTimer = setTimeout(run, opts.retryMs);   // 卸载后不重连
  };

  void run();

  return () => {
    cancelled = true;
    ctrl.abort();
    if (retryTimer) clearTimeout(retryTimer);
  };
}
