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
