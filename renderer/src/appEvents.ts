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
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with VetarAI. If not, see <https://www.gnu.org/licenses/>.
 */
/**
 * A13（0.4.22）：应用级「资源变更」实时流 —— App 级常驻订阅 + 跨面板广播。
 *
 * ═══ 为什么需要这个模块 ═══
 *
 * 用户实测缺陷：Agent 在工作时直接写库（创建/修改工作流、项目、插件、知识、推理配置），
 * 但前端 6 个面板没有刷新机制——App.tsx 用 `display` 切换做保活（不卸载组件），各面板的
 * `useEffect` 只在首次挂载时拉一次数据，Agent 改完库后用户切回面板看到的还是旧数据，
 * **必须重启应用**才更新。
 *
 * 后端已补齐出口（`app_events.py` 总线 + `GET /api/events/stream` SSE + 各写端点
 * `_notify_change`）。本模块是前端那一端：**App 级常驻一条 SSE 连接**监听全部资源变更，
 * 收到后经 `events.ts` 广播 `app:resource-changed`，各面板订阅后**按需重拉自己的数据**。
 *
 * ═══ 关键设计决策（勿凭直觉改）═══
 *
 * 1. ⛔ **模块级单例，不是 hook**：整应用只需一条连接。`startAppEventStream()` 幂等——
 *    重复调用返回同一个 stop（防 React StrictMode 双调用 / 多面板各自启动 → N 条连接）。
 *    放模块级而非 App 组件内，是为了让"连接生命周期"独立于任何面板的挂载/卸载。
 *
 * 2. ⛔ **卸载绝不重连**：`stop()` 置 `cancelled=true` + `ctrl.abort()`。断流退避重连只在
 *    `!cancelled` 时排程——这是计划明列的约束（"卸载无幽灵请求"）。与 TaskPanel 同纪律。
 *
 * 3. ⛔ **seq 游标 + 断线补发 + gap 对账**：记住最后收到的 seq，重连时 `?since=<seq>`，
 *    后端补发缓冲区内错过的变更；若缓冲区也挤掉了 → 后端发 `gap` → 本模块广播
 *    `resource:'*'`，**所有面板无条件重拉**（不拿半截状态渲染）。这是"无延时且不丢变更"
 *    的关键，⛔ 不得退化成轮询糊弄（计划明令禁止）。
 *
 * 4. ⛔ **不破坏 App 保活**：本模块只 emit 事件，不碰任何面板的挂载。面板自己决定收到
 *    事件后重拉与否（如 WorkflowPanel 在 dirty 时跳过，避免冲掉未保存的编辑）。
 *
 * 5. ⛔ **流失败静默**：连不上侧车不弹错误条（各面板的手动刷新仍可用），只静默退避重连。
 *    与 TaskPanel 一致——实时刷新是增强，不该因为侧车没起来就糊用户一脸错误。
 */
import { getApiBase } from './apiBase';
import { emit } from './events';
import { SSEStreamParser } from './lib/sseParser';

/** 广播事件名：各面板用 `on(APP_RESOURCE_CHANGED, fn)` 订阅。 */
export const APP_RESOURCE_CHANGED = 'app:resource-changed';

/** 广播给面板的变更事件载荷。 */
export interface AppResourceEvent {
  /** 资源类型：workflow/project/plugin/knowledge/inference/agent；`'*'` = gap 对账（全部重拉）。 */
  resource: string;
  /** 动作：create/update/delete（gap 对账时无）。 */
  action?: string;
  /** 项目级资源带 project_id（全局资源为空串）。面板可据此只刷新对应项目。 */
  projectId?: string;
  /** true = 缓冲断档对账，面板应无条件重拉（不要按 resource 过滤）。 */
  gap?: boolean;
  /** 后端单调 seq（游标/诊断用）。 */
  seq?: number;
  [k: string]: any;
}

/** 断流退避重连间隔（ms）。与 TaskPanel 一致。 */
const RETRY_MS = 3000;

// 模块级单例：当前活跃连接的 stop 函数（null = 未启动）。
let stopFn: (() => void) | null = null;

/**
 * 启动 App 级资源变更流（幂等单例）。返回 stop 函数（App 卸载时调用）。
 *
 * ⛔ 幂等：已启动则直接返回同一个 stop，不重复开连接（防 StrictMode 双调用 / 多处启动）。
 * ⛔ 必须在 App 顶层 `useEffect(() => startAppEventStream(), [])` 调用——空依赖，
 *    整个应用生命周期只启停一次，与保活的子面板挂载/卸载无关。
 */
export function startAppEventStream(): () => void {
  if (stopFn) return stopFn;            // 单例：已有活跃连接

  let cancelled = false;
  const ctrl = new AbortController();
  let retryTimer: ReturnType<typeof setTimeout> | null = null;
  let lastSeq = 0;                      // 重连时带 ?since=lastSeq 补发错过的变更

  const applyEvent = (ev: { event: string; data: Record<string, any> }) => {
    if (cancelled) return;              // ⛔ 卸载后不再 emit（不写任何状态）
    const d = ev.data || {};
    // 统一更新游标：connected/resource_changed/gap 的 data 都带 seq（端点已并入）
    if (typeof d.seq === 'number' && d.seq > lastSeq) lastSeq = d.seq;
    switch (ev.event) {
      case 'resource_changed':
        emit(APP_RESOURCE_CHANGED, {
          ...d,
          resource: String(d.resource || ''),
          action: String(d.action || ''),
          projectId: d.project_id != null ? String(d.project_id) : '',
        } as AppResourceEvent);
        break;
      case 'gap':
        // ⛔ 断档对账：错过的变更无从补发 → 广播 '*'，所有面板无条件重拉，
        //    而不是拿着半截状态继续渲染（与后端 gap 语义对齐）。
        emit(APP_RESOURCE_CHANGED, {
          resource: '*', gap: true, seq: d.seq,
          from: d.from, oldest_available: d.oldest_available,
        } as AppResourceEvent);
        break;
      // connected（仅初始化游标，上面已统一处理 seq）/ stream_end / stream_error /
      // 心跳注释行（已被 parser 忽略）/ 未知事件：不下发，向前兼容。
      default:
        break;
    }
  };

  const run = async () => {
    try {
      const API = getApiBase();
      // ⛔ 带 since：重连时补发缓冲区内错过的变更（无延时且不丢）
      const res = await fetch(`${API}/events/stream?since=${lastSeq}`, { signal: ctrl.signal });
      if (!res.ok || !res.body) throw new Error(`HTTP ${res.status}`);
      if (cancelled) return;
      const reader = res.body.getReader();
      const parser = new SSEStreamParser();
      const dec = new TextDecoder();
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        for (const ev of parser.push(dec.decode(value, { stream: true }))) applyEvent(ev);
      }
      for (const ev of parser.flush()) applyEvent(ev);
    } catch {
      // 静默：流失败不弹错误条（面板手动刷新仍可用），只在下方退避重连
    }
    if (!cancelled) retryTimer = setTimeout(run, RETRY_MS);   // ⛔ 卸载后不重连
  };

  void run();

  stopFn = () => {
    cancelled = true;
    ctrl.abort();
    if (retryTimer) clearTimeout(retryTimer);
    stopFn = null;                      // 允许后续重新启动（如测试 / App 重挂载）
  };
  return stopFn;
}

/** 诊断/测试用：当前是否有活跃连接。 */
export function isAppEventStreamRunning(): boolean {
  return stopFn != null;
}

/** 测试辅助：强制停止并复位单例（vitest afterEach 用，防用例间串流）。 */
export function __stopAppEventStreamForTest(): void {
  if (stopFn) stopFn();
  stopFn = null;
}
