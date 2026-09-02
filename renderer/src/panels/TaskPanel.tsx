import { getApiBase } from '../apiBase';
import React, { useEffect, useState, useCallback } from 'react';
import { colors, fonts, radius, typo, btnSecondary, btnGhost, badge, calloutStyle } from '../theme';
import { Icon, Spinner } from '../Icon';

// TS-108 M3-2（决策 4/5）：委派任务状态面板。
// - 状态徽标：等待中(queued) / 执行中(running) / 完成(done) / 异常(failed)
// - 失败任务提供"重试"（决策 5 一键重试，生成新任务记录）
// - 手动"刷新"拉取最新状态（后端无任务推送通道，刷新即拉）

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

const API = getApiBase();

// 状态徽标配色（规范 §6.3）
const STATUS_BADGE: Record<string, { bg: string; fg: string; dot: string; label: string }> = {
  queued:  { bg: '#ECECEE', fg: '#5C5C66', dot: '#8E8E99', label: '等待中' },
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
  // M7（TS-113 建议包2）：每秒计时（有进行中任务时才启动）
  const [now, setNow] = useState(() => Date.now());
  const hasActive = tasks.some(t => t.status === 'queued' || t.status === 'running');
  useEffect(() => {
    if (!hasActive) return;
    const timer = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(timer);
  }, [hasActive]);

  const fetchTasks = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const res = await fetch(`${API}/projects/${projectId}/tasks?limit=30`);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      if (Array.isArray(data)) setTasks(data as AgentTask[]);
    } catch (e) {
      setError('加载失败: ' + (e as Error).message);
    } finally {
      setLoading(false);
    }
  }, [projectId]);

  useEffect(() => { fetchTasks(); }, [fetchTasks]);

  const handleRetry = async (taskId: string) => {
    setRetryingId(taskId);
    setRetryMsg(null);
    try {
      const res = await fetch(`${API}/projects/${projectId}/tasks/${taskId}/retry`, { method: 'POST' });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(data?.detail || `HTTP ${res.status}`);
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
      const res = await fetch(`${API}/projects/${projectId}/tasks/${taskId}/stop`, { method: 'POST' });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(data?.detail || `HTTP ${res.status}`);
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
            <span style={typo.panelTitle}>委派任务（最近30条）</span>
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
              <Icon name="clipboard" size={36} style={{ color: '#C9C9CF' }} />
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
                      title="停止该委派任务"
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
                      title="打开该子 Agent 的委派会话"
                      style={{ ...btnGhost, height: 22, padding: '0 8px', fontSize: 12, gap: 4, marginLeft: t.status === 'failed' ? 6 : 'auto' }}>
                      <Icon name="arrow-up-right" size={14} />
                      查看
                    </button>
                  )}
                </div>
                <div style={{ ...typo.caption, color: colors.textSecondary, marginTop: 4, overflow: 'hidden', textOverflow: 'ellipsis', display: '-webkit-box', WebkitLineClamp: 2, WebkitBoxOrient: 'vertical' as any }}>
                  {brief}{(t.task || '').length > 40 ? '…' : ''}
                </div>
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
