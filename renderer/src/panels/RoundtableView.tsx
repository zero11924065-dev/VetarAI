import { getApiBase } from '../apiBase';
import React, { useEffect, useState, useCallback, useRef } from 'react';
import { colors, fonts, radius, shadow, typo, card, btnPrimary, btnSecondary, btnGhost, btnDangerSoft, badge, calloutStyle, select as selectStyle } from '../theme';
import { Icon, Spinner } from '../Icon';
import { confirmDialog } from '../Dialog';

// TS-109 改进（用户验收反馈）：圆桌详情右侧大屏展示（对齐普通对话的观看体验）。
// 头部：议题 + 状态 + 轮次 + 主持人（用户/AI）+ 参与者；
// 主体：纪要（默认展开）+ 多角色发言气泡（大面积、按轮分组）；
// 底部：按状态渲染操作按钮（决策 6：结束权在用户）+ 总结展示。

const API = getApiBase();

export interface AgentLite { id: string; name: string; role?: string; model_name?: string; }
export interface RTMessage { id: number; rt_id: string; round: number; agent_id: string; agent_name: string; content: string; ok: boolean; }
export interface RTAttachment { name: string; size?: number; is_text?: boolean; truncated?: boolean; }
export interface Roundtable {
  id: string; topic: string; participants: AgentLite[];
  moderator: 'user' | 'ai'; moderator_agent_id?: string | null;
  max_rounds: number; round: number;
  status: 'running' | 'waiting_user' | 'confirm_end' | 'done' | 'failed';
  minutes?: string; summary?: string; messages?: RTMessage[];
  attachments?: RTAttachment[];
  created_at?: string;  // M7（TS-113 建议包2）：耗时计时数据源
}

// §6.3 状态徽标配色映射
const STATUS_BADGE: Record<string, { bg: string; fg: string; dot: string }> = {
  running:       { bg: colors.accentBg,    fg: colors.accentTextDeep, dot: colors.accent },
  waiting_user:  { bg: colors.warnBg,      fg: colors.warnText,       dot: colors.warn },
  confirm_end:   { bg: colors.warnBg,      fg: colors.warnText,       dot: colors.warn },
  done:          { bg: colors.okBg,        fg: colors.okText,         dot: colors.ok },
  failed:        { bg: colors.dangerBg,    fg: colors.dangerText,     dot: colors.danger },
};
const STATUS_LABEL: Record<string, string> = {
  running: '讨论中', waiting_user: '等待用户', confirm_end: '待确认结束', done: '已结束', failed: '异常',
};

// 头像 6 色（§8.13，哈希算法保持不变，仅换色板）
const AVATAR_COLORS: [string, string][] = [
  ['#DCF1FE', '#075985'],
  ['#DEF3E4', '#1F7A3D'],
  ['#FCEEDC', '#A05A00'],
  ['#EEE4FB', '#6B3FA0'],
  ['#FCE0E6', '#B03052'],
  ['#DFF2F6', '#0F7490'],
];
function avatarColor(agentId: string): [string, string] {
  let h = 0;
  for (let i = 0; i < agentId.length; i++) h = (h * 31 + agentId.charCodeAt(i)) >>> 0;
  return AVATAR_COLORS[h % AVATAR_COLORS.length];
}

export function RoundtableView({ projectId, roundtableId, onExit }: {
  projectId: string; roundtableId: string; onExit: () => void;
}) {
  const [detail, setDetail] = useState<Roundtable | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [showMinutes, setShowMinutes] = useState(true);
  const scrollRef = useRef<HTMLDivElement>(null);
  const autoScrollRef = useRef(true);
  const programmaticScrollRef = useRef(false);
  // M7（TS-113 建议包2）：进行中已耗时（每秒计时，终态停止）
  const [now, setNow] = useState(() => Date.now());
  const rtActive = !!detail && detail.status !== 'done' && detail.status !== 'failed';
  useEffect(() => {
    if (!rtActive) return;
    const t = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(t);
  }, [rtActive]);
  const elapsedLabel = (() => {
    if (!detail || !detail.created_at) return null;
    // checkpoint-067 N-3：SQLite datetime('now') 存的是 UTC，而 Date.parse 对
    // 无时区的 "2026-08-30T14:00:00" 会当本地时间解析 → 多算一个时区（8h）。
    // 补 'Z' 后缀按 UTC 解析，消除时区偏移（之前"8H12m"=8h 时区偏差+真实耗时）。
    const started = Date.parse(detail.created_at.replace(' ', 'T') + 'Z');
    if (Number.isNaN(started)) return null;
    const sec = Math.max(0, Math.floor((now - started) / 1000));
    if (sec < 60) return `${sec}s`;
    if (sec < 3600) return `${Math.floor(sec / 60)}m${sec % 60}s`;
    return `${Math.floor(sec / 3600)}h${Math.floor((sec % 3600) / 60)}m`;
  })();

  const fetchDetail = useCallback(async () => {
    try {
      const res = await fetch(`${API}/roundtables/${roundtableId}?project_id=${projectId}`);
      if (!res.ok) return;
      const data = await res.json();
      setDetail(data as Roundtable);
    } catch (e) { console.error('rt detail:', e); }
  }, [projectId, roundtableId]);

  useEffect(() => { fetchDetail(); }, [fetchDetail]);

  // 5s 轮询（无事件推送通道；终态 done/failed 停止轮询）
  useEffect(() => {
    if (!detail || detail.status === 'done' || detail.status === 'failed') return;
    const t = setInterval(() => { fetchDetail(); }, 5000);
    return () => clearInterval(t);
  }, [fetchDetail, detail?.status, detail?.id]);

  // 新发言到达时滚底（用户上滑则不跟随——复用 H17 修复的滚动语义）
  const msgCount = detail?.messages?.length || 0;
  useEffect(() => {
    if (autoScrollRef.current) {
      programmaticScrollRef.current = true;
      const el = scrollRef.current;
      // scrollTo 在个别环境（如 jsdom）不存在，做防御性判断
      if (el && typeof el.scrollTo === 'function') el.scrollTo({ top: el.scrollHeight, behavior: 'auto' });
    }
  }, [msgCount]);

  function handleScroll() {
    const el = scrollRef.current;
    if (!el) return;
    if (programmaticScrollRef.current) { programmaticScrollRef.current = false; return; }
    autoScrollRef.current = el.scrollHeight - el.scrollTop - el.clientHeight <= 100;
  }
  function handleWheel(e: React.WheelEvent) {
    if (e.deltaY < 0) autoScrollRef.current = false;
    else if (e.deltaY > 0) {
      const el = scrollRef.current;
      if (el && el.scrollHeight - el.scrollTop - el.clientHeight <= 100) autoScrollRef.current = true;
    }
  }

  const handleContinue = async () => {
    if (busy) return;
    setBusy(true); setError(null);
    try {
      const res = await fetch(`${API}/roundtables/${roundtableId}/continue?project_id=${projectId}`, { method: 'POST' });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(data?.detail || `HTTP ${res.status}`);
      fetchDetail();
    } catch (e) { setError('继续失败: ' + (e as Error).message); }
    finally { setBusy(false); }
  };

  const handleFinish = async () => {
    if (busy) return;
    setBusy(true); setError(null);
    try {
      const res = await fetch(`${API}/roundtables/${roundtableId}/finish?project_id=${projectId}`, { method: 'POST' });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(data?.detail || `HTTP ${res.status}`);
      fetchDetail();
    } catch (e) { setError('结束失败: ' + (e as Error).message); }
    finally { setBusy(false); }
  };

  // checkpoint-067 N-1：手动停止进行中的圆桌（在当前发言完成后中止本轮）
  const [stopping, setStopping] = useState(false);
  const handleStop = async () => {
    if (stopping) return;
    setStopping(true); setError(null);
    try {
      const res = await fetch(`${API}/roundtables/${roundtableId}/stop?project_id=${projectId}`, { method: 'POST' });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(data?.detail || `HTTP ${res.status}`);
      setNotice('已请求停止，将在当前发言完成后中止');
      setTimeout(() => setNotice(null), 6000);
      fetchDetail();
    } catch (e) { setError('停止失败: ' + (e as Error).message); }
    finally { setStopping(false); }
  };

  // TS-109 增强（H18-2）：保存为本地 Markdown 文件
  const handleExport = async () => {
    if (busy) return;
    setBusy(true); setError(null); setNotice(null);
    try {
      const res = await fetch(`${API}/roundtables/${roundtableId}/export?project_id=${projectId}`, { method: 'POST' });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(data?.detail || `HTTP ${res.status}`);
      setNotice(`已保存：${data.path || data.name || '未知路径'}`);
      setTimeout(() => setNotice(null), 8000);
    } catch (e) { setError('保存失败: ' + (e as Error).message); }
    finally { setBusy(false); }
  };

  // TS-109 增强（H18-1）：删除讨论
  const handleDelete = async () => {
    if (busy) return;
    const ok = await confirmDialog({ title: '删除圆桌讨论', message: '确定删除这场圆桌讨论吗？全部发言记录将被清除，不可恢复。', danger: true, confirmText: '删除' });
    if (!ok) return;
    setBusy(true); setError(null);
    try {
      const res = await fetch(`${API}/roundtables/${roundtableId}?project_id=${projectId}`, { method: 'DELETE' });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(data?.detail || `HTTP ${res.status}`);
      onExit();  // 删除成功 → 退出大屏
    } catch (e) { setError('删除失败: ' + (e as Error).message); setBusy(false); }
  };

  if (!detail) {
    return (
      <div style={{ flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center', color: colors.textTertiary, background: colors.bgApp }}>
        <Spinner size={20} />
        <span style={{ marginLeft: 8, fontSize: 13 }}>加载中…</span>
      </div>
    );
  }

  const sb = STATUS_BADGE[detail.status] || STATUS_BADGE.running;
  const statusLabel = STATUS_LABEL[detail.status] || '讨论中';
  // 主持人展示（用户验收反馈：主持人应显示在右侧）
  const moderatorAgent = detail.moderator === 'ai'
    ? detail.participants.find(p => p.id === detail.moderator_agent_id) : null;
  const moderatorLabel = detail.moderator === 'ai'
    ? `AI 主持：${moderatorAgent ? moderatorAgent.name : '（未知）'}` : '用户主持（结束权在你）';

  // 按轮分组发言
  const rounds: Record<number, RTMessage[]> = {};
  (detail.messages || []).forEach(m => {
    if (!rounds[m.round]) rounds[m.round] = [];
    rounds[m.round].push(m);
  });
  const roundNos = Object.keys(rounds).map(Number).sort((a, b) => a - b);

  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%', minWidth: 0, minHeight: 0, background: colors.bgApp }}>
      {/* ── 顶栏 (§8.13)：议题 + 状态 + 主持人 + 参与者 ── */}
      <div style={{ height: 48, padding: '0 16px', borderBottom: `1px solid ${colors.borderSubtle}`, display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 8, flexShrink: 0 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap', minWidth: 0 }}>
          <button className="ui-btn ui-btn-ghost" onClick={onExit} data-tip="返回对话"
            style={{ ...btnGhost, height: 28, gap: 4 }}>
            <Icon name="arrow-left" size={14} /> 返回
          </button>
          <Icon name="mic" size={16} style={{ color: colors.textPrimary }} />
          <span style={{ color: colors.textPrimary, fontWeight: 600, fontSize: 14, overflowWrap: 'anywhere' }}>{detail.topic}</span>
          {/* 状态徽标 (§6.3) */}
          <span style={badge(sb.bg, sb.fg)}>
            <span style={{ width: 6, height: 6, borderRadius: '50%', background: sb.dot, flexShrink: 0 }} />
            {statusLabel}
          </span>
          <span style={{ color: colors.textSecondary, fontSize: 12 }}>第 {detail.round}/{detail.max_rounds} 轮</span>
          {rtActive && elapsedLabel && (
            <span style={{ color: colors.textTertiary, fontSize: 11, display: 'inline-flex', alignItems: 'center', gap: 4 }}>
              <Icon name="clock" size={14} /> 已耗时 {elapsedLabel}
            </span>
          )}
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 12, color: colors.textTertiary, flexWrap: 'wrap', flexShrink: 0 }}>
          {/* 主持人 */}
          <span style={{ color: '#FF9500', display: 'inline-flex', alignItems: 'center', gap: 4 }}>
            <Icon name="crown" size={14} style={{ color: '#FF9500' }} /> {moderatorLabel}
          </span>
          {/* 参与者 */}
          <span>参与者：{detail.participants.map(p => p.name).join('、')}</span>
          {/* TS-109 增强：保存为文件 + 删除（H18-1/H18-2） */}
          <button className="ui-btn ui-btn-secondary" onClick={handleExport} disabled={busy} title="把整场讨论保存为 Markdown 文件"
            style={{ ...btnSecondary, height: 22, padding: '0 8px', fontSize: 12 }}>
            <Icon name="download" size={14} /> 保存为文件
          </button>
          <button className="ui-btn ui-btn-danger-soft" onClick={handleDelete} disabled={busy || detail.status === 'running'}
            title={detail.status === 'running' ? '讨论进行中不能删除' : '删除这场讨论'}
            style={{ ...btnDangerSoft, height: 22, padding: '0 8px', fontSize: 12, opacity: detail.status === 'running' ? 0.5 : 1 }}>
            <Icon name="trash" size={14} /> 删除
          </button>
        </div>
      </div>

      {/* 错误/通知条 */}
      {error && <div style={{ ...calloutStyle('error'), borderRadius: 0, padding: '6px 16px', borderBottom: `1px solid ${colors.dangerBorder}` }}>{error}</div>}
      {notice && <div style={{ ...calloutStyle('success'), borderRadius: 0, padding: '6px 16px', borderBottom: `1px solid ${colors.okBorder}` }}>{notice}</div>}

      {/* TS-109 增强（H18-3）：议题附件展示 */}
      {detail.attachments && detail.attachments.length > 0 && (
        <div style={{ padding: '6px 16px', borderBottom: `1px solid ${colors.borderSubtle}`, background: '#F5F5F7', fontSize: 12 }}>
          <span style={{ color: colors.textTertiary, display: 'inline-flex', alignItems: 'center', gap: 4 }}>
            <Icon name="paperclip" size={14} /> 参考材料：
          </span>
          {detail.attachments.map((a, i) => (
            <span key={i} style={{ display: 'inline-flex', alignItems: 'center', gap: 3, background: '#F5F5F7', padding: '2px 6px', borderRadius: radius.s, margin: '2px 4px 2px 0', color: colors.textPrimary, border: `1px solid ${colors.borderSubtle}`, fontSize: 12 }}>
              <Icon name="file" size={14} style={{ color: colors.textTertiary }} /> {a.name}{a.is_text === false && <span style={{ color: colors.textTertiary }}>（非文本）</span>}
            </span>
          ))}
        </div>
      )}

      {/* ── 纪要（默认展开）── */}
      {detail.minutes && (
        <div style={{ borderBottom: `1px solid ${colors.borderSubtle}`, background: colors.bgCard }}>
          <button onClick={() => setShowMinutes(v => !v)}
            style={{ width: '100%', textAlign: 'left', background: 'transparent', border: 'none', padding: '6px 16px', cursor: 'pointer', fontSize: 13, fontWeight: 500, color: colors.textPrimary, display: 'flex', alignItems: 'center', gap: 6 }}>
            <Icon name="file-text" size={14} /> 讨论纪要 <Icon name={showMinutes ? 'chevron-up' : 'chevron-down'} size={14} style={{ color: colors.textTertiary }} />
          </button>
          {showMinutes && (
            <pre style={{ whiteSpace: 'pre-wrap', wordBreak: 'break-word', fontSize: 13, lineHeight: 1.6, color: colors.textSecondary, margin: 0, padding: '0 16px 12px', fontFamily: fonts.base }}>
              {detail.minutes}
            </pre>
          )}
        </div>
      )}

      {/* ── 发言区（大面积，按轮分组，多角色气泡）── */}
      <div ref={scrollRef} onScroll={handleScroll} onWheel={handleWheel}
        style={{ flex: 1, overflowY: 'auto', padding: 16, position: 'relative', minWidth: 0, background: colors.bgApp }}>
        {roundNos.map(rn => (
          <div key={rn}>
            {/* 轮分隔 */}
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 12, margin: '16px 0' }}>
              <div style={{ width: 40, height: 1, background: colors.borderDefault }} />
              <span style={{ color: colors.textTertiary, fontSize: 12, whiteSpace: 'nowrap' }}>第 {rn} 轮</span>
              <div style={{ width: 40, height: 1, background: colors.borderDefault }} />
            </div>
            {(rounds[rn] || []).map(m => {
              const [avBg, avFg] = avatarColor(m.agent_id);
              return (
                <div key={m.id} style={{ display: 'flex', gap: 10, marginBottom: 12, opacity: m.ok ? 1 : 0.55 }}>
                  {/* 头像（名字首字 + 角色稳定配色） */}
                  <div style={{
                    width: 36, height: 36, borderRadius: '50%', flexShrink: 0,
                    background: avBg, color: avFg,
                    display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 600,
                  }}>
                    {m.agent_name.slice(0, 1)}
                  </div>
                  <div style={{ flex: 1, minWidth: 0 }}>
                    <div style={{ fontSize: 13, fontWeight: 500, color: colors.textPrimary, marginBottom: 3, display: 'flex', alignItems: 'center', gap: 4 }}>
                      {moderatorAgent?.id === m.agent_id && <Icon name="crown" size={14} style={{ color: '#FF9500' }} />}
                      <span>{m.agent_name}</span>
                      {!m.ok && <span style={{ color: colors.dangerText, fontSize: 12, fontWeight: 400 }}>·发言失败</span>}
                    </div>
                    <div style={{
                      background: colors.bgCard, borderRadius: radius.m, padding: '10px 14px',
                      fontSize: 14, lineHeight: 1.65, color: colors.textPrimary,
                      whiteSpace: 'pre-wrap', wordBreak: 'break-word', maxWidth: '85%',
                      border: `1px solid ${colors.borderDefault}`,
                    }}>
                      {m.content}
                    </div>
                  </div>
                </div>
              );
            })}
          </div>
        ))}
        {detail.status === 'running' && (
          <div style={{ textAlign: 'center', color: colors.textTertiary, fontSize: 13, padding: 12, display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 6 }}>
            <Spinner size={14} /> 第 {detail.round} 轮讨论中，发言陆续产生…（自动刷新）
          </div>
        )}

        {/* ── 总结（终态）── */}
        {detail.status === 'done' && detail.summary && (
          <div style={{ ...calloutStyle('success'), marginTop: 8, borderRadius: radius.m, padding: '12px 16px', flexDirection: 'column' }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 6, fontWeight: 600, fontSize: 13, marginBottom: 6 }}>
              <Icon name="clipboard" size={16} /> 讨论总结
            </div>
            <pre style={{ whiteSpace: 'pre-wrap', wordBreak: 'break-word', fontSize: 14, lineHeight: 1.65, color: colors.textPrimary, margin: 0, fontFamily: fonts.base }}>
              {detail.summary}
            </pre>
          </div>
        )}
      </div>

      {/* ── 底部操作区（决策 6：结束权在用户）── */}
      <div style={{ borderTop: `1px solid ${colors.borderSubtle}`, padding: '10px 16px', display: 'flex', gap: 10, alignItems: 'center', justifyContent: 'center', flexWrap: 'wrap', flexShrink: 0 }}>
        {detail.status === 'waiting_user' && (
          <>
            <span style={{ color: colors.textSecondary, fontSize: 12 }}>本轮结束，请选择：</span>
            <button className="ui-btn ui-btn-primary" onClick={handleContinue} disabled={busy}
              style={{ ...btnPrimary }}>
              <Icon name="play" size={14} /> 继续下一轮
            </button>
            <button className="ui-btn ui-btn-secondary" onClick={handleFinish} disabled={busy}
              style={{ ...btnSecondary }}>
              <Icon name="stop" size={14} /> 结束并总结
            </button>
          </>
        )}
        {detail.status === 'confirm_end' && (
          <>
            <span style={{ color: colors.warnText, fontSize: 12, display: 'inline-flex', alignItems: 'center', gap: 4 }}>
              <Icon name="crown" size={14} style={{ color: '#FF9500' }} /> 主持人认为各方已达成共识，是否收尾由你决定：
            </span>
            <button className="ui-btn ui-btn-primary" onClick={handleFinish} disabled={busy}
              style={{ ...btnPrimary }}>
              <Icon name="stop" size={14} /> 确认结束
            </button>
            <button className="ui-btn ui-btn-secondary" onClick={handleContinue} disabled={busy}
              style={{ ...btnSecondary }}>
              <Icon name="play" size={14} /> 再讨论一轮
            </button>
          </>
        )}
        {detail.status === 'running' && (
          <>
            <span style={{ color: colors.textTertiary, fontSize: 13, display: 'inline-flex', alignItems: 'center', gap: 6 }}>
              <Spinner size={14} /> 讨论进行中…
            </span>
            {/* checkpoint-067 N-1：手动停止（在当前发言完成后中止本轮） */}
            <button className="ui-btn ui-btn-danger-soft" onClick={handleStop} disabled={stopping}
              title="停止讨论（将在当前发言完成后中止本轮，已完成发言保留）"
              style={{ ...btnDangerSoft }}>
              {stopping ? <Spinner size={14} /> : <Icon name="stop" size={14} />} 停止
            </button>
          </>
        )}
        {detail.status === 'done' && (
          <span style={{ color: colors.okText, fontSize: 13, display: 'inline-flex', alignItems: 'center', gap: 4 }}>
            <Icon name="check" size={14} /> 讨论已结束，总结见上方
          </span>
        )}
      </div>
    </div>
  );
}
