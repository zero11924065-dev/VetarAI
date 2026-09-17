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
 * 背景与逐条推理已迁出：详见 交接/03-修复与调试历史记录.md 第十三部分
 *
 * 1. **模块级单例，不是 hook**：整应用只需一条连接。`startAppEventStream()` 幂等——
 * 2. **卸载绝不重连**：`stop()` 置 `cancelled=true` + `ctrl.abort()`。断流退避重连只在
 * 3. **seq 游标 + 断线补发 + gap 对账**：记住最后收到的 seq，重连时 `?since=<seq>`，
 *    的关键，不得退化成轮询糊弄（计划明令禁止）。
 * 4. **不破坏 App 保活**：本模块只 emit 事件，不碰任何面板的挂载。面板自己决定收到
 * 5. **流失败静默**：连不上侧车不弹错误条（各面板的手动刷新仍可用），只静默退避重连。
 */
import { getApiBase } from './apiBase';
import { emit } from './events';
import { SSEEvent } from './lib/sseParser';
import { startResilientStream } from './lib/sseStream';

/** 广播事件名：各面板用 `on(APP_RESOURCE_CHANGED, fn)` 订阅。 */
export const APP_RESOURCE_CHANGED = 'app:resource-changed';

/** 0.4.30（W3）：请求打开整页设置页并定位到某分区。
 *  载荷 { section: SectionKey }——目前由 ChatPanel 的「ASR 未安装/已禁用」提醒层
 *  「去模型包面板」按钮发出；App 顶层订阅后切到设置页对应分区。 */
export const APP_OPEN_SETTINGS = 'app:open-settings';

/** 广播给面板的变更事件载荷。 */
export interface AppResourceEvent {
  /** 资源类型：workflow/project/plugin/knowledge/inference/agent/session；`'*'` = gap 对账（全部重拉）。
   *  session（0.4.28 REQ-AGT-020）：委派写子会话消息，payload 带 session_id/message_role，ChatPanel 定向重拉。 */
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
 * 幂等：已启动则直接返回同一个 stop，不重复开连接（防 StrictMode 双调用 / 多处启动）。
 * 必须在 App 顶层 `useEffect(() => startAppEventStream(), [])` 调用——空依赖，
 *    整个应用生命周期只启停一次，与保活的子面板挂载/卸载无关。
 */
export function startAppEventStream(): () => void {
  if (stopFn) return stopFn;            // 单例：已有活跃连接

  let cancelled = false;
  let lastSeq = 0;                      // 重连时带 ?since=lastSeq 补发错过的变更

  const applyEvent = (ev: SSEEvent) => {
    if (cancelled) return;              // 卸载后不再 emit（不写任何状态）
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
        // 断档对账：错过的变更无从补发 → 广播 '*'，所有面板无条件重拉，
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

  // B9-2 C8：重连壳归并至 lib/sseStream（形状逐行同构，仅 URL 每次求值带游标）。
  // retryMs 传原值 RETRY_MS；卸载不重连的 cancelled/abort 守卫在壳内原位保留。
  const stopStream = startResilientStream({
    url: () => `${getApiBase()}/events/stream?since=${lastSeq}`,   // 带 since：重连时补发缓冲区内错过的变更（无延时且不丢）
    onEvent: applyEvent,
    retryMs: RETRY_MS,
  });

  stopFn = () => {
    cancelled = true;
    stopStream();                       // ctrl.abort() + 清退避定时器（壳内）
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
