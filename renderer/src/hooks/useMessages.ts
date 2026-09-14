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
/** Per-session message history with localStorage + API persistence. */
import { useState } from 'react';

export interface ToolStep {
  id: string;
  name: string;
  args?: any;
  // C2/C8（0.4.16）：新增 'interrupted' —— 用户停止时该工具**尚未跑完**。
  // 不能标 'ok'（谎称成功）也不能标 'error'（谎报失败，会污染失败计数与警示色）；
  // 也不能留在 'running'（会永久显示"正在调用…"，且令 B4 折叠判据 running===0 永不满足）。
  status: 'running' | 'ok' | 'error' | 'interrupted';
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
  // 0.4.9 任务161：报错诊断（由用户在设置里指定的报错分析模型生成的人话结论）
  // 后端 _build_error_payload 随 error 事件回传；无分析（未配置/失败/超时）时为 undefined。
  errorAnalysis?: string;
  errorAnalysisModel?: string;
  stopped?: boolean;
  /** 0.4.12（C6）：用户**手动**点了停止（仅 AbortError 路径置位）。
   *  不要与 stopped 混用：stopped 是"流已终止"（done/error/abort/缓存恢复都置位，
   *  用来停掉打字机光标），而 manualStopped 才是"用户主动停止"（用来显示"已手动停止 + 重新发送"）。
   *  此前二者共用 stopped → 正常执行完（done 也置 stopped）界面同样显示"已手动停止 重新发送"，
   *  与事实相反（用户真机反馈：agent执行完停止，为什么下方显示也是已手动停止）。 */
  manualStopped?: boolean;
  /** #13（0.4.19）：缓存恢复的中断气泡的可见说明文案。
   *  仅由"缓存瞬显/合并恢复"路径置位：该气泡既无 manualStopped（非用户点停），
   *  也无 completedDuration（没走 done 路径）→ 只能是崩溃/关应用/断连造成的异常中断。
   *  正常完成（有 completedDuration）与手动停止（有 manualStopped）都不置，
   *  故此字段不会把"正常完成"误标成中断。 */
  interruptedNote?: string;
  // TS-102 B13：思考中指示（thinking 事件到达→正文首 token 到达期间为 true）
  thinking?: boolean;
  // 0.4.2 阶段化思考：当前思考阶段已持续秒数（每秒跳动）
  thinkingElapsed?: number;
  // 0.4.2 阶段化思考：简版思考预览（末尾 ~120 字，让用户知道 agent 在想什么）
  thinkingPreview?: string;
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
  /** B12（0.4.21）：整轮进行计时（秒）= 气泡出现（startedAt）→ 流结束，全程每秒跳动。
   *  存在的理由：思考结束后「思考 Ns」定格（正确，思考已结束），但任务仍在进行
   *  （工具执行/正文输出/下轮思考未开始）时，界面原本无任何跳动计时 → 用户无法判断是否还活着。
   *  **瞬态字段，不落库**（同 thinkingElapsed/waitingSeconds）：历史消息无活流，不显示。
   *  仅在 isStreamingThis 时渲染；流结束（done/error/abort/停止）即停，由 completedDuration 接管。 */
  runElapsed?: number;
  // TS-120（0.3.0）：已移入知识仓库 → 脱离模型上下文（占位显示）
  archived?: boolean;
}

const STORAGE_KEY = 'subagent_messages_v4';

// ── F6（0.4.24，checkpoint-111）：图片 base64 移出会话缓存 ──────────────────
/**
 * 真凶（2026-09-13 实测坐实）：47MB 会话缓存中图片 base64 占 95.3%，`syncSessionLocal`
 * 每次写入全量 parse/stringify、同步阻塞主线程约 400ms → 两个写出口须对**所有会话**剥离。
 * 实测明细与四个安全卡点已迁出：详见 交接/03-修复与调试历史记录.md 第十六部分
 *
 * 关键约束（决定方案，不可省）：`syncSessionLocal` parse 的是**整个 store**，
 * 已知代价（如实标注，不隐瞒）：「乐观追加 user 气泡 → POST 落库」这个**几十毫秒窗口**内
 */
const HEAVY_PREFIX = 'data:';
const isHeavy = (s: unknown): boolean => typeof s === 'string' && s.startsWith(HEAVY_PREFIX);
/** 只留非 base64 项（http(s) URL 体积小、且 DB 未必有副本 → 保留，避免误丢） */
const keepLight = (arr: string[]): string[] => arr.filter(s => !isHeavy(s));

/**
 * 剥离一组消息里的图片 base64（**缓存副本专用**）。
 * 绝不原地修改传入数组/对象：调用方传的是 React state 里的消息对象，
 *   原地改会让**界面上正在显示的图片当场消失**（比重写慢更糟）。
 *   → 一律 `{ ...m }` 造新对象；无重图的消息**原样返回引用**（零开销、幂等）。
 */
function stripMsgImages(msgs: Message[]): Message[] {
  if (!Array.isArray(msgs)) return msgs;
  let changed = false;
  const out = msgs.map(m => {
    if (!m || typeof m !== 'object') return m;
    const hasHeavyImg = Array.isArray(m.images) && m.images.some(isHeavy);
    const hasHeavyPending = Array.isArray(m.pending_images) && m.pending_images.some(isHeavy);
    if (!hasHeavyImg && !hasHeavyPending) return m;      // 原样返回引用，不造新对象
    changed = true;
    const next: Message = { ...m };
    if (hasHeavyImg) next.images = keepLight(m.images!);
    // pending_images 是"本地流式附着图"、DB 无对应列，故整个删除（其 base64 全是重图）。
    //   刷新后该 user 消息从 DB 恢复时带的是 `images` 字段（app.py:1134 落库），图片仍在。
    if (hasHeavyPending) delete (next as any).pending_images;
    return next;
  });
  return changed ? out : msgs;
}

/** 剥离整个 store（所有会话）的图片 base64 —— 整体迁移，见上方关键约束 */
function stripStoreImages(store: Record<string, Message[]>): Record<string, Message[]> {
  const out: Record<string, Message[]> = {};
  for (const sid of Object.keys(store)) {
    out[sid] = stripMsgImages(store[sid]);
  }
  return out;
}

// Global mutable store — keyed by sessionId
let _store: Record<string, Message[]> = {};
try { _store = JSON.parse(localStorage.getItem(STORAGE_KEY) || '{}'); } catch {}

// F6：落盘前剥离图片 base64。内存态 `_store` **保持完整**（正常使用零变化），
//   只有写进 localStorage 的副本被剥离 → 每次 persist 都幂等地再剥一次，开销极小。
function persist() { localStorage.setItem(STORAGE_KEY, JSON.stringify(stripStoreImages(_store))); }

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
    // F6：本会话的图片先剥离，再对**整个 store** 剥离一次后落盘。
    //   只剥本会话毫无意义——parse/stringify 处理的是整个 store，其他会话的 45MB 仍在，
    //   单次写入照样约 400ms（计划 2.0 节的关键约束）。整 store 剥离同时完成老缓存迁移：
    //   `loadSessionMessages` 每次都会调本函数 → 用户一切会话，存量 45MB 即被清掉。
    store[sessionId] = stripMsgImages(messages);
    localStorage.setItem(key, JSON.stringify(stripStoreImages(store)));
  } catch {}
}

/** 删除某个 session 的所有本地缓存（配合 API 删除） */
export function purgeSessionLocal(sessionId: string) {
  delete _store[sessionId];
  persist();
}
