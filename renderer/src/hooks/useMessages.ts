/** Per-session message history with localStorage + API persistence. */
import { useState, useCallback } from 'react';

export interface ToolStep {
  id: string;
  name: string;
  args?: any;
  status: 'running' | 'ok' | 'error';
  summary?: string;
  error?: string;
}
export interface Message {
  id?: string; // B02/B05（TS-101）：稳定消息 id（DB id 或 local_* 流式 id），列表 key 与流式定位用
  role: string;
  content: string;
  model_used?: string;
  pending_images?: string[];
  /** 0.1.71（TS-118）：历史消息落库的委派附着图片（API 字段，子会话回看可见） */
  images?: string[];
  created_at?: string;
  // M1-4 流式过程可视化
  toolSteps?: ToolStep[];
  step?: number;
  maxStep?: number;
  tokensUsed?: number;
  streamError?: string;
  stopped?: boolean;
  // TS-102 B13：思考中指示（thinking 事件到达→正文首 token 到达期间为 true）
  thinking?: boolean;
  // checkpoint-067b D-1：思考完成后的累计秒数，固化为"思考用时 Xs"一直保留显示
  thinkingDuration?: number;
  // H17 问题3：本轮上下文已用 token（prompt_eval_count），持久化后历史会话可恢复指示器
  prompt_eval_count?: number;
  // M5（TS-111）：错误分类（business=业务错误如模型不存在，不重试；network=网络错误，走重连兜底）
  errorKind?: 'business' | 'network';
  // M5（TS-111）：长加载提示（发送后长时间无事件时的已等待秒数，>0 显示）
  waitingSeconds?: number;
  // TS-116（3.29）：完成用时（秒）= 气泡出现 → done/error 事件
  completedDuration?: number;
  // TS-116（3.29）：气泡出现时间戳（ms，Date.now()）
  startedAt?: number;
  // TS-120（0.3.0）：已移入知识仓库 → 脱离模型上下文（占位显示）
  archived?: boolean;
}

const STORAGE_KEY = 'subagent_messages_v4';

// Global mutable store — keyed by sessionId
let _store: Record<string, Message[]> = {};
try { _store = JSON.parse(localStorage.getItem(STORAGE_KEY) || '{}'); } catch {}

function persist() { localStorage.setItem(STORAGE_KEY, JSON.stringify(_store)); }

export function useSessionMessages(sessionId: string) {
  const storeKey = sessionId;
  const [messages, setMessages] = useState<Message[]>(() => _store[storeKey] || []);

  function addMessage(msg: Message) {
    if (!(_store[storeKey])) _store[storeKey] = [];
    _store[storeKey].push(msg);
    persist();
    setMessages([..._store[storeKey]]);
  }

  function getMessages(): Message[] { return [...(_store[storeKey] || [])]; }

  function clear() {
    delete _store[storeKey];
    persist();
    setMessages([]);
  }

  /** 从 API 加载历史消息到本地 store（覆盖） */
  function loadFromAPI(apiMessages: Message[]) {
    _store[storeKey] = apiMessages;
    persist();
    setMessages([...apiMessages]);
  }

  return { messages, addMessage, getMessages, clear, loadFromAPI };
}

/** B07（TS-101）：把一组消息写进某 session 的本地缓存（流式完成/截断时同步，刷新不丢） */
export function syncSessionLocal(sessionId: string, messages: Message[]) {
  try {
    const key = 'subagent_messages_v4';
    const store: Record<string, any> = JSON.parse(localStorage.getItem(key) || '{}');
    store[sessionId] = messages;
    localStorage.setItem(key, JSON.stringify(store));
  } catch {}
}

/** 删除某个 session 的所有本地缓存（配合 API 删除） */
export function purgeSessionLocal(sessionId: string) {
  delete _store[sessionId];
  persist();
}

/** 删除某个 agent 的所有本地缓存（配合 API 删除 agent） */
export function purgeAgentLocal(agentSessionIds: string[]) {
  for (const sid of agentSessionIds) {
    delete _store[sid];
  }
  persist();
}
