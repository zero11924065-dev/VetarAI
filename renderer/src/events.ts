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
// TS-115（3.30）：简单前端事件总线（跨面板解耦通知）。
// 用途：AgentPanel 修改模型 → emit('agent:updated') → ChatPanel 刷新 agentInfo。
// 设计：零依赖、零配置；监听者返回 unsubscribe 函数（React useEffect 清理用）。

type Listener = (data: any) => void;
const listeners: Record<string, Set<Listener>> = {};

export function emit(event: string, data?: any): void {
  listeners[event]?.forEach((fn) => {
    try { fn(data); } catch (e) { console.error(`event listener for '${event}' threw:`, e); }
  });
}

export function on(event: string, fn: Listener): () => void {
  if (!listeners[event]) listeners[event] = new Set();
  listeners[event].add(fn);
  return () => { listeners[event]?.delete(fn); };
}

// 测试辅助：清空所有监听（vitest beforeEach 用）
export function __resetEventsForTest(): void {
  for (const k of Object.keys(listeners)) delete listeners[k];
}
