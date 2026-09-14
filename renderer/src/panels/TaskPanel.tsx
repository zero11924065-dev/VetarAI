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
import { getApiBase } from '../apiBase';
import { apiJson } from '../lib/api';
import { useEffect, useState, useCallback } from 'react';
import { colors, fonts, radius, typo, btnSecondary, btnGhost, badge, calloutStyle } from '../theme';
import { Icon, Spinner } from '../Icon';
import { SSEEvent } from '../lib/sseParser';
import { startResilientStream } from '../lib/sseStream';

// TS-108 M3-2（决策 4/5）：委派任务状态面板。
// - 状态徽标：等待中(queued) / 执行中(running) / 完成(done) / 异常(failed)
// - 失败任务提供"重试"（决策 5 一键重试，生成新任务记录）
// - 0.4.20（#15）：**实时进度**——订阅 `GET /api/projects/{pid}/tasks/stream`，
//   显示子 Agent 正在调用的工具、轮次与已生成字数。
//   原注释写「后端无任务推送通道，刷新即拉」**已失真**：后端此前确实没有委派 SSE 端点，
//   面板只在 mount 时拉一次、之后全靠手点刷新（连自动轮询都没有），
//   用户实测即「委派跑起来后中途看不到任何进展，要等任务整个结束」。
//   手动"刷新"仍保留，作为流断开时的兜底。

interface AgentTask {
  id: string;
  target_agent_id?: string;
  target_agent_name: string;
  task: string;
  status: 'queued' | 'running' | 'done' | 'failed';
  fail_reason?: string | null;
  report?: { status?: string; summary?: string; prompt_eval_count?: number } | null;
  session_id?: string | null;
  created_at?: string;
}

// 0.4.20（#15）：某任务的实时进度（来自 SSE 增量，DB 里没有这些字段）
// 不再设 `ended` 字段：渲染已用 DB 的 `t.status`（queued/running）门控，
//   任务结束后进度本就不显示，再存一个布尔是冗余的"只写不读"状态。
//   收口改为**直接删除该任务的进度记录**（见 task_end 分支），防止反复委派累积。
interface LiveProgress {
  toolName?: string;        // 最近一次 tool_call 的工具名
  toolOk?: boolean;         // 该工具的 tool_result 结果（true/false），未回来则 undefined
  step?: number;            // 当前轮次
  max?: number;             // 轮次上限
  chars?: number;           // 已生成字数
}

const API = getApiBase();

// 状态徽标配色（规范 §6.3）
const STATUS_BADGE: Record<string, { bg: string; fg: string; dot: string; label: string }> = {
  queued:  { bg: colors.bgHover, fg: colors.textSecondary, dot: colors.textTertiary, label: '等待中' },
  running: { bg: colors.accentBg, fg: colors.accentTextDeep, dot: colors.accent, label: '进行中' },
  done:    { bg: colors.okBg, fg: colors.okText, dot: colors.ok, label: '完成' },
  failed:  { bg: colors.dangerBg, fg: colors.dangerText, dot: colors.danger, label: '异常' },
};

// M7（TS-113 建议包2）：已耗时格式化
function fmtElapsed(sec: number): string {
  if (sec < 60) return `${sec}s`;
  if (sec < 3600) return `${Math.floor(sec / 60)}m${sec % 60}s`;
  return `${Math.floor(sec / 3600)}h${Math.floor((sec % 3600) / 60)}m`;
}

export function TaskPanel({ projectId, onJumpToAgent }: {
  projectId: string;
  onJumpToAgent?: (agentId: string, sessionId: string | null) => void;
}) {
  const [tasks, setTasks] = useState<AgentTask[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [retryingId, setRetryingId] = useState<string | null>(null);
  const [retryMsg, setRetryMsg] = useState<string | null>(null);
  // TS-114（3.25）：停止按钮状态
  const [stoppingId, setStoppingId] = useState<string | null>(null);
  const [stopMsg, setStopMsg] = useState<string | null>(null);
  // 0.4.20（#15）：实时进度（按 task_id）+ 流连接状态
  const [live, setLive] = useState<Record<string, LiveProgress>>({});
  const [streamOn, setStreamOn] = useState(false);
  // M7（TS-113 建议包2）：每秒计时（有进行中任务时才启动）
  const [now, setNow] = useState(() => Date.now());
  const hasActive = tasks.some(t => t.status === 'queued' || t.status === 'running');
  useEffect(() => {
    if (!hasActive) return;
    const timer = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(timer);
  }, [hasActive]);

  // silent=true 用于流事件触发的刷新：不能走 setLoading(true)，
  // 否则每条事件都让"刷新"按钮闪一次"刷新中…"（一次委派上百条事件 = 全程闪烁）。
  const loadTasks = useCallback(async (silent: boolean) => {
    if (!silent) setLoading(true);
    setError(null);
    try {
      const res = await fetch(`${API}/projects/${projectId}/tasks?limit=30`);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      if (Array.isArray(data)) setTasks(data as AgentTask[]);
    } catch (e) {
      if (!silent) setError('加载失败: ' + (e as Error).message);
    } finally {
      if (!silent) setLoading(false);
    }
  }, [projectId]);

  const fetchTasks = useCallback(() => loadTasks(false), [loadTasks]);

  useEffect(() => { fetchTasks(); }, [fetchTasks]);

  // 0.4.20（#15）：订阅委派实时进度流。
  // 卸载/切项目必须 abort：项目已有 chatPanelUnmountLeak 先例——
  //   卸载后继续写状态会导致内存泄漏与"写已卸载组件"告警。
  // 不叠加定时器：上方每秒计时 setInterval 保持不动，本 effect 只负责流。
  // 断流后自动重连（3s 退避），但**卸载后绝不重连**。
  useEffect(() => {
    let cancelled = false;

    const applyEvent = (ev: SSEEvent) => {
      if (cancelled) return;                       // 卸载后不再写任何状态
      const d = ev.data || {};
      const tid = String(d.task_id || '');
      switch (ev.event) {
        case 'snapshot': {
          // DB 权威基线：整体替换，并清掉已不在列表里的实时进度
          const list = Array.isArray(d.tasks) ? d.tasks as AgentTask[] : [];
          setTasks(list);
          setLive(prev => {
            const ids = new Set(list.map(t => t.id));
            const next: Record<string, LiveProgress> = {};
            for (const k of Object.keys(prev)) if (ids.has(k)) next[k] = prev[k];
            return next;
          });
          break;
        }
        case 'status': {
          if (!tid) break;
          const st = String(d.state || '');
          // 这里原先有一行 `setLive(... ended: false)`，删掉 ended 后它成了纯空操作。
          // 状态本身不在这里改：**终态一律以 DB 为准**（静默重拉拿 report/fail_reason
          // 等完整字段），避免流事件与 DB 两个真相源打架。
          if (st === 'done' || st === 'failed') void loadTasks(true);
          break;
        }
        case 'tool_call':
          if (!tid) break;
          setLive(prev => ({
            ...prev,
            [tid]: { ...prev[tid], toolName: String(d.name || ''), toolOk: undefined },
          }));
          break;
        case 'tool_result':
          if (!tid) break;
          setLive(prev => ({ ...prev, [tid]: { ...prev[tid], toolOk: Boolean(d.ok) } }));
          break;
        case 'progress':
          if (!tid) break;
          setLive(prev => ({
            ...prev,
            [tid]: {
              ...prev[tid],
              step: typeof d.step === 'number' ? d.step : prev[tid]?.step,
              max: typeof d.max === 'number' ? d.max : prev[tid]?.max,
              chars: typeof d.chars === 'number' ? d.chars : prev[tid]?.chars,
            },
          }));
          break;
        case 'task_end':
          if (!tid) break;
          // 收口：删除该任务的实时进度记录。
          // 不是行为变更（渲染已按 DB 的 status 门控，终态本就不显示进度），
          //    而是**内存清理**：一个长会话里反复委派会不断新增 task_id，
          //    只增不删会让 live 记录无上限累积。
          setLive(prev => {
            if (!(tid in prev)) return prev;        // 无变化则复用原对象，免触发重渲染
            const next = { ...prev };
            delete next[tid];
            return next;
          });
          void loadTasks(true);                    // 重拉快照：failed 原因/摘要以 DB 为准
          break;
        case 'gap':
        case 'stream_end':
        case 'stream_error':
          // 断档或流结束 → 重拉快照对齐（不静默错乱地拿半截状态渲染）
          void loadTasks(true);
          break;
        default:
          break;                                    // 未知事件忽略，向前兼容
      }
    };

    // B9-2 C8：消费壳+重连壳归并至 lib/sseStream（形状逐行同构）。
    // retryMs 传原值 3000；setStreamOn 时序不变：onConnect=原 setStreamOn(true) 位置，
    //    onClose=原 finally 内 if(!cancelled) setStreamOn(false)；卸载不重连守卫在壳内。
    const stopStream = startResilientStream({
      url: () => `${API}/projects/${projectId}/tasks/stream`,
      onEvent: applyEvent,
      retryMs: 3000,                           // 断流退避重连
      onConnect: () => setStreamOn(true),
      onClose: () => setStreamOn(false),
    });

    return () => {
      cancelled = true;
      stopStream();                            // ctrl.abort() + 清退避定时器（壳内）
      setStreamOn(false);
    };
  }, [projectId, loadTasks]);

  const handleRetry = async (taskId: string) => {
    setRetryingId(taskId);
    setRetryMsg(null);
    try {
      const data = await apiJson(`/projects/${projectId}/tasks/${taskId}/retry`, { method: 'POST' });
      const ok = data?.result?.ok;
      setRetryMsg(ok ? '重试完成：子任务成功交卷' : `重试完成但未成功：${data?.result?.error || '未知原因'}`);
      await fetchTasks();
    } catch (e) {
      setRetryMsg('重试失败: ' + (e as Error).message);
    } finally {
      setRetryingId(null);
      setTimeout(() => setRetryMsg(null), 6000);
    }
  };

  const handleStop = async (taskId: string) => {
    setStoppingId(taskId);
    setStopMsg(null);
    try {
      const data = await apiJson(`/projects/${projectId}/tasks/${taskId}/stop`, { method: 'POST' });
      setStopMsg('已请求停止，将在当前步骤完成后中止');
      // 立即刷新一次拿到最新状态（轮询 8s 之外的人工刷新）
      await fetchTasks();
    } catch (e) {
      setStopMsg('停止失败: ' + (e as Error).message);
    } finally {
      setStoppingId(null);
      setTimeout(() => setStopMsg(null), 6000);
    }
  };

  // 手风琴头由 App.tsx 统一渲染（checkpoint-051）；本组件只输出内容。
  return (
    <div style={{ fontFamily: fonts.base, padding: '8px 12px' }}>
          {/* 面板标题行 */}
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 6 }}>
            <span style={typo.panelTitle}>
              委派任务（最近30条）
              {/* 0.4.20（#15）：实时流连接指示。streamOn 此前是只写不读的死状态
                  （声明 + 3 处 setStreamOn，从未被读取），现接入让用户知道
                  看到的是实时进度还是已退回手动刷新兜底——流断开时静默降级是最糟的，
                  用户会以为"没进展"其实是"没连上"。圆点做法沿用状态徽标，不引入新图标名。 */}
              <span
                data-testid="stream-indicator"
                title={streamOn ? '实时进度已连接' : '实时流未连接，请点击刷新'}
                style={{
                  display: 'inline-block', width: 6, height: 6, borderRadius: '50%',
                  marginLeft: 6, verticalAlign: 'middle',
                  background: streamOn ? colors.ok : colors.borderStrong,
                }} />
            </span>
            <button className="ui-btn ui-btn-ghost" onClick={fetchTasks} disabled={loading}
              style={{ ...btnGhost, height: 22, padding: '0 8px', fontSize: 12, gap: 4 }}>
              {loading ? <Spinner size={12} /> : <Icon name="rotate-cw" size={14} />}
              {loading ? '刷新中…' : '刷新'}
            </button>
          </div>

          {/* 错误提示条 */}
          {error && (
            <div style={{ ...calloutStyle('error'), marginBottom: 6 }}>
              <Icon name="alert-circle" size={16} style={{ flexShrink: 0, marginTop: 2 }} />
              <span>{error}</span>
            </div>
          )}

          {/* 重试消息 */}
          {retryMsg && (
            <div style={{ ...calloutStyle('warn'), marginBottom: 6 }}>
              <Icon name="info" size={16} style={{ flexShrink: 0, marginTop: 2 }} />
              <span>{retryMsg}</span>
            </div>
          )}

          {/* TS-114 停止消息 */}
          {stopMsg && (
            <div style={{ ...calloutStyle('warn'), marginBottom: 6 }}>
              <Icon name="info" size={16} style={{ flexShrink: 0, marginTop: 2 }} />
              <span>{stopMsg}</span>
            </div>
          )}

          {/* 加载中 */}
          {loading && tasks.length === 0 && (
            <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', padding: '24px 0', gap: 8 }}>
              <Spinner size={20} />
              <span style={{ fontSize: 12, color: colors.textTertiary }}>加载中…</span>
            </div>
          )}

          {/* 空态 */}
          {tasks.length === 0 && !loading && !error && (
            <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', padding: '24px 0', gap: 8 }}>
              <Icon name="clipboard" size={36} style={{ color: colors.borderStrong }} />
              <span style={{ fontSize: 13, color: colors.textTertiary }}>暂无委派任务</span>
            </div>
          )}

          {/* 任务卡列表 */}
          {tasks.map(t => {
            const sb = STATUS_BADGE[t.status] || STATUS_BADGE.queued;
            const brief = (t.task || '').replace(/\s+/g, ' ').slice(0, 40);
            // M7（TS-113 建议包2）：进行中任务的已耗时
            // checkpoint-067 N-3：SQLite datetime('now') 存 UTC，补 'Z' 后缀按 UTC 解析，
            // 否则 Date.parse 当本地时间多算一个时区（8h）。
            let elapsed: string | null = null;
            if ((t.status === 'queued' || t.status === 'running') && t.created_at) {
              const started = Date.parse(t.created_at.replace(' ', 'T') + 'Z');
              if (!Number.isNaN(started)) {
                elapsed = fmtElapsed(Math.max(0, Math.floor((now - started) / 1000)));
              }
            }
            return (
              <div key={t.id} style={{
                background: colors.bgCard, border: `1px solid ${colors.borderDefault}`,
                borderRadius: radius.m, padding: '8px 10px', marginBottom: 8,
              }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 6, flexWrap: 'wrap' }}>
                  {/* 状态徽标 */}
                  <span style={badge(sb.bg, sb.fg)}>
                    <span style={{ width: 6, height: 6, borderRadius: '50%', background: sb.dot, flexShrink: 0 }} />
                    {sb.label}
                  </span>
                  <span style={{ ...typo.body, color: colors.textPrimary }}>
                    <Icon name="arrow-right" size={14} style={{ verticalAlign: 'middle', marginRight: 2 }} />
                    {t.target_agent_name}
                  </span>
                  {elapsed && (
                    <span style={{ ...typo.micro, display: 'inline-flex', alignItems: 'center', gap: 3, marginLeft: 'auto' }}>
                      <Icon name="clock" size={14} />
                      {elapsed}
                    </span>
                  )}
                  {/* TS-114（3.25）：running 任务停止按钮 */}
                  {t.status === 'running' && (
                    <button
                      className="ui-btn ui-btn-secondary"
                      onClick={() => handleStop(t.id)}
                      disabled={stoppingId !== null}
                      data-tip="停止该委派任务"
                      style={{
                        ...btnSecondary,
                        height: 22,
                        padding: '0 8px',
                        fontSize: 12,
                        gap: 4,
                        marginLeft: 'auto',
                        background: colors.dangerBg,
                        color: colors.dangerText,
                        borderColor: 'transparent',
                      }}>
                      {stoppingId === t.id ? <Spinner size={12} /> : <Icon name="stop" size={14} />}
                      {stoppingId === t.id ? '停止中…' : '停止'}
                    </button>
                  )}
                  {t.status === 'failed' && (
                    <button className="ui-btn ui-btn-secondary" onClick={() => handleRetry(t.id)} disabled={retryingId !== null}
                      style={{ ...btnSecondary, height: 22, padding: '0 8px', fontSize: 12, marginLeft: 'auto', gap: 4 }}>
                      {retryingId === t.id ? <Spinner size={12} /> : <Icon name="rotate-cw" size={14} />}
                      {retryingId === t.id ? '重试中…' : '重试'}
                    </button>
                  )}
                  {/* M7（TS-113 建议包4）：跳转子 Agent 委派会话 */}
                  {t.target_agent_id && onJumpToAgent && (
                    <button className="ui-btn ui-btn-ghost"
                      onClick={() => onJumpToAgent(t.target_agent_id!, t.session_id || null)}
                      data-tip="打开该子 Agent 的委派会话"
                      style={{ ...btnGhost, height: 22, padding: '0 8px', fontSize: 12, gap: 4, marginLeft: t.status === 'failed' ? 6 : 'auto' }}>
                      <Icon name="arrow-up-right" size={14} />
                      查看
                    </button>
                  )}
                </div>
                <div style={{ ...typo.caption, color: colors.textSecondary, marginTop: 4, overflow: 'hidden', textOverflow: 'ellipsis', display: '-webkit-box', WebkitLineClamp: 2, WebkitBoxOrient: 'vertical' as any }}>
                  {brief}{(t.task || '').length > 40 ? '…' : ''}
                </div>
                {/* 0.4.20（#15）：实时进度——只在任务进行中显示，终态交给下方 DB 字段渲染。
                    数据来自 SSE 增量（DB 里没有），任务结束后由 snapshot/task_end 重拉清除。 */}
                {(t.status === 'queued' || t.status === 'running') && live[t.id] && (
                  <div data-testid="live-progress" style={{
                    display: 'flex', alignItems: 'center', gap: 6, flexWrap: 'wrap',
                    marginTop: 4, fontSize: 11, color: colors.textTertiary,
                  }}>
                    {live[t.id].toolName && (
                      <span style={{ display: 'inline-flex', alignItems: 'center', gap: 3 }}>
                        {live[t.id].toolOk === undefined
                          ? <Spinner size={11} />
                          : <Icon name={live[t.id].toolOk ? 'check' : 'x'} size={12}
                                  style={{ color: live[t.id].toolOk ? colors.okText : colors.dangerText }} />}
                        <span data-testid="live-tool" style={{ color: colors.textSecondary }}>
                          {live[t.id].toolOk === undefined ? '正在调用 ' : ''}{live[t.id].toolName}
                        </span>
                      </span>
                    )}
                    {typeof live[t.id].step === 'number' && (
                      <span data-testid="live-step">
                        第 {live[t.id].step}{typeof live[t.id].max === 'number' ? `/${live[t.id].max}` : ''} 轮
                      </span>
                    )}
                    {typeof live[t.id].chars === 'number' && live[t.id].chars! > 0 && (
                      <span data-testid="live-chars">已生成 {live[t.id].chars} 字</span>
                    )}
                  </div>
                )}
                {t.status === 'failed' && t.fail_reason && (
                  <div style={{ fontSize: 12, color: colors.dangerText, marginTop: 4 }}>原因：{t.fail_reason}</div>
                )}
                {t.status === 'done' && t.report?.summary && (
                  <div style={{ fontSize: 12, color: colors.okText, marginTop: 4 }}>摘要：{String(t.report.summary).slice(0, 60)}</div>
                )}
                {/* TS-116（3.20③）：委派上下文用量 */}
                {t.status === 'done' && t.report?.prompt_eval_count != null && t.report.prompt_eval_count > 0 && (
                  <div style={{ fontSize: 11, color: colors.textTertiary, marginTop: 2 }}>
                    上下文用量：{t.report.prompt_eval_count} tokens
                  </div>
                )}
              </div>
            );
          })}
    </div>
  );
}
