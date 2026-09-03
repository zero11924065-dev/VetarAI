import { getApiBase } from '../apiBase';
import React, { useEffect, useState, useCallback } from 'react';
import { Roundtable } from './RoundtableView';
import { colors, fonts, radius, typo, btnPrimary, btnGhost, input, select as selectStyle, badge, calloutStyle } from '../theme';
import { Icon, Spinner } from '../Icon';

// TS-109 M3-3 改进（用户验收反馈）：左栏圆桌面板精简为"创建 + 列表"，
// 详情移到右侧大屏（RoundtableView），对齐普通对话的观看体验。
// 列表项点击 → onSelect(rtId) 由 App 切换右侧区域；创建成功 → 自动打开详情。

const API = getApiBase();

interface AgentLite { id: string; name: string; role?: string; model_name?: string; }

// 圆桌状态徽标配色（规范 §6.3）
const RT_STATUS_BADGE: Record<string, { bg: string; fg: string; dot: string; label: string }> = {
  running:      { bg: colors.accentBg, fg: colors.accentTextDeep, dot: colors.accent, label: '讨论中' },
  waiting_user: { bg: colors.warnBg, fg: colors.warnText, dot: colors.warn, label: '等待用户' },
  confirm_end:  { bg: colors.warnBg, fg: colors.warnText, dot: colors.warn, label: '待确认结束' },
  done:         { bg: colors.okBg, fg: colors.okText, dot: colors.ok, label: '已结束' },
  failed:       { bg: colors.dangerBg, fg: colors.dangerText, dot: colors.danger, label: '异常' },
};

export function RoundtablePanel({ projectId, selectedId, onSelect }: {
  projectId: string; selectedId: string | null; onSelect: (rtId: string) => void;
}) {
  const [agents, setAgents] = useState<AgentLite[]>([]);
  const [roundtables, setRoundtables] = useState<Roundtable[]>([]);
  // 创建表单
  const [topic, setTopic] = useState('');
  const [selectedAgents, setSelectedAgents] = useState<string[]>([]);
  const [moderator, setModerator] = useState<'user' | 'ai'>('user');
  const [moderatorAgentId, setModeratorAgentId] = useState<string>('');
  const [maxRounds, setMaxRounds] = useState(5);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // TS-109 增强（H18-3）：议题附件（背景材料）
  const [pendingFiles, setPendingFiles] = useState<{ name: string; content_base64: string }[]>([]);
  const fileInputRef = React.useRef<HTMLInputElement>(null);

  const fetchAgents = useCallback(async () => {
    try {
      const res = await fetch(`${API}/agents/${projectId}`);
      if (!res.ok) return;
      const data = await res.json();
      if (Array.isArray(data)) setAgents(data as AgentLite[]);
    } catch (e) { console.error('rt agents:', e); }
  }, [projectId]);

  const fetchRoundtables = useCallback(async () => {
    try {
      const res = await fetch(`${API}/projects/${projectId}/roundtables?limit=20`);
      if (!res.ok) return;
      const data = await res.json();
      if (Array.isArray(data)) setRoundtables(data as Roundtable[]);
    } catch (e) { console.error('rt list:', e); }
  }, [projectId]);

  useEffect(() => { fetchAgents(); fetchRoundtables(); }, [fetchAgents, fetchRoundtables]);

  // 轮询：列表 5s（AgentPanel 同款模式）
  useEffect(() => {
    const t = setInterval(() => { fetchRoundtables(); }, 5000);
    return () => clearInterval(t);
  }, [fetchRoundtables]);

  const toggleAgent = (id: string) => {
    setSelectedAgents(prev => prev.includes(id) ? prev.filter(x => x !== id) : [...prev, id]);
  };

  // TS-109 增强（H18-3）：读取选中文件为 base64（最多 5 个、单个 ≤2MB）
  const handleFileChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const files = Array.from(e.target.files || []);
    if (!files.length) return;
    const room = 5 - pendingFiles.length;
    if (room <= 0) { setError('最多上传 5 个附件'); return; }
    const batch = files.slice(0, room);
    batch.forEach(f => {
      if (f.size > 2 * 1024 * 1024) { setError(`文件 ${f.name} 超过 2MB，已跳过`); return; }
      const reader = new FileReader();
      reader.onload = () => {
        const result = String(reader.result || '');
        const b64 = result.includes(',') ? result.split(',')[1] : result;
        setPendingFiles(prev => [...prev, { name: f.name, content_base64: b64 }]);
      };
      reader.readAsDataURL(f);
    });
    if (e.target) e.target.value = '';
  };

  const handleCreate = async () => {
    if (busy) return;
    if (!topic.trim()) { setError('请输入议题'); return; }
    if (selectedAgents.length < 2) { setError('至少选择 2 个参与者'); return; }
    if (moderator === 'ai' && !moderatorAgentId) { setError('请选择 AI 主持人'); return; }
    setBusy(true); setError(null);
    try {
      const res = await fetch(`${API}/projects/${projectId}/roundtables`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          topic: topic.trim(), agent_ids: selectedAgents,
          moderator, moderator_agent_id: moderator === 'ai' ? moderatorAgentId : null,
          max_rounds: maxRounds,
          attachments: pendingFiles,
        }),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(data?.detail || `HTTP ${res.status}`);
      setTopic(''); setSelectedAgents([]); setModerator('user'); setModeratorAgentId('');
      setPendingFiles([]);
      fetchRoundtables();
      if (data.id) onSelect(data.id);  // 创建成功 → 右侧直接打开详情
    } catch (e) {
      setError('创建失败: ' + (e as Error).message);
    } finally { setBusy(false); }
  };

  // 手风琴头由 App.tsx 统一渲染（checkpoint-051）；本组件只输出内容。
  return (
    <div style={{ fontFamily: fonts.base, padding: '8px 12px' }}>
          {/* ── 创建区 ── */}
          <div style={{ borderBottom: `1px solid ${colors.borderSubtle}`, paddingBottom: 8, marginBottom: 8 }}>
            <input value={topic} onChange={e => setTopic(e.target.value)} placeholder="输入讨论议题…"
              className="ui-input"
              style={{ ...input, width: '100%', boxSizing: 'border-box', marginBottom: 6 }} />

            <div style={{ marginBottom: 4, fontSize: 12, color: colors.textSecondary }}>参与者（至少 2 个）：</div>
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6, marginBottom: 6 }}>
              {agents.map(a => {
                const sel = selectedAgents.includes(a.id);
                return (
                  <span key={a.id}
                    onClick={() => toggleAgent(a.id)}
                    style={{
                      display: 'inline-flex', alignItems: 'center',
                      height: 22, padding: '0 10px', borderRadius: radius.pill, cursor: 'pointer',
                      fontSize: 12, userSelect: 'none',
                      background: sel ? colors.accentBg : '#ECECEE',
                      color: sel ? colors.accentText : colors.textSecondary,
                      transition: 'background-color .15s ease, color .15s ease',
                    }}>
                    {a.name}{a.role ? `（${a.role}）` : ''}
                  </span>
                );
              })}
            </div>

            <div style={{ display: 'flex', gap: 6, alignItems: 'center', marginBottom: 6, flexWrap: 'wrap' }}>
              <label style={{ display: 'flex', alignItems: 'center', gap: 3, fontSize: 13, color: colors.textPrimary, cursor: 'pointer' }}>
                <input type="radio" checked={moderator === 'user'} onChange={() => setModerator('user')} /> 用户主持
              </label>
              <label style={{ display: 'flex', alignItems: 'center', gap: 3, fontSize: 13, color: colors.textPrimary, cursor: 'pointer' }}>
                <input type="radio" checked={moderator === 'ai'} onChange={() => setModerator('ai')} /> AI 主持：
              </label>
              {moderator === 'ai' && (
                <select value={moderatorAgentId} onChange={e => setModeratorAgentId(e.target.value)}
                  style={{ ...selectStyle, fontSize: 12 }}>
                  <option value="">选择主持人…</option>
                  {agents.filter(a => selectedAgents.includes(a.id)).map(a => (
                    <option key={a.id} value={a.id}>{a.name}</option>
                  ))}
                </select>
              )}
              <label style={{ display: 'flex', alignItems: 'center', gap: 3, fontSize: 13, color: colors.textPrimary }}>
                轮数 <input type="number" min={2} max={10} value={maxRounds}
                  onChange={e => setMaxRounds(Number(e.target.value) || 5)}
                  className="ui-input"
                  style={{ ...input, width: 70, height: 28, fontSize: 12 }} />
              </label>
              <button className="ui-btn ui-btn-primary" onClick={handleCreate} disabled={busy}
                style={{ ...btnPrimary, marginLeft: 'auto', height: 28, fontSize: 12, padding: '0 14px' }}>
                {busy ? <><Spinner size={12} style={{ borderTopColor: colors.onAccent }} /> 进行中…</> : '开始讨论'}
              </button>
            </div>

            {/* ── 议题附件（H18-3：提供文件材料作为讨论依据）── */}
            <div style={{ borderTop: `1px dashed ${colors.borderSubtle}`, paddingTop: 6 }}>
              <input ref={fileInputRef} type="file" multiple style={{ display: 'none' }}
                onChange={handleFileChange} accept=".txt,.md,.csv,.json,.js,.ts,.py,.html,.css,.log,.xml,.yml,.yaml" />
              <button className="ui-btn ui-btn-ghost" onClick={() => fileInputRef.current?.click()} disabled={busy}
                style={{ ...btnGhost, height: 22, padding: '0 8px', fontSize: 12, gap: 4 }}>
                <Icon name="paperclip" size={14} />
                添加参考材料（可选）
              </button>
              <span style={{ color: colors.textTertiary, fontSize: 11, marginLeft: 6 }}>文本文件将作为讨论依据</span>
              {pendingFiles.length > 0 && (
                <div style={{ marginTop: 4, display: 'flex', flexWrap: 'wrap', gap: 4 }}>
                  {pendingFiles.map((f, i) => (
                    <span key={i} style={{
                      background: '#F5F5F7', padding: '4px 8px', borderRadius: radius.s,
                      border: `1px solid ${colors.borderSubtle}`,
                      fontSize: 12, color: colors.textPrimary, display: 'inline-flex', alignItems: 'center', gap: 4,
                    }}>
                      <Icon name="file" size={14} style={{ color: colors.textTertiary }} />
                      {f.name.length > 18 ? f.name.slice(0, 18) + '…' : f.name}
                      <button className="ui-ico-danger" onClick={() => setPendingFiles(prev => prev.filter((_, j) => j !== i))}
                        data-tip="移除附件"
                        style={{ background: 'none', border: 'none', color: colors.textTertiary, cursor: 'pointer', padding: 0, display: 'inline-flex' }}>
                        <Icon name="x" size={14} />
                      </button>
                    </span>
                  ))}
                </div>
              )}
            </div>
          </div>

          {/* 错误提示条 */}
          {error && (
            <div style={{ ...calloutStyle('error'), marginBottom: 6 }}>
              <Icon name="alert-circle" size={16} style={{ flexShrink: 0, marginTop: 2 }} />
              <span>{error}</span>
            </div>
          )}

          {/* ── 列表区（点击 → 右侧大屏详情）── */}
          {roundtables.length === 0 && !error && (
            <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', padding: '24px 0', gap: 8 }}>
              <Icon name="mic" size={36} style={{ color: '#C9C9CF' }} />
              <span style={{ fontSize: 13, color: colors.textTertiary }}>暂无圆桌讨论</span>
            </div>
          )}
          {roundtables.map(rt => {
            const sb = RT_STATUS_BADGE[rt.status] || RT_STATUS_BADGE.running;
            const isSelected = selectedId === rt.id;
            return (
              <div key={rt.id} data-testid={`rt-item-${rt.id}`} onClick={() => onSelect(rt.id)}
                style={{
                  background: isSelected ? colors.accentBg : colors.bgCard,
                  border: `1px solid ${isSelected ? colors.accent : colors.borderDefault}`,
                  borderRadius: radius.m, padding: '8px 10px', marginBottom: 8, cursor: 'pointer',
                  transition: 'background-color .15s ease, border-color .15s ease',
                }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                  {/* 状态徽标 */}
                  <span style={badge(sb.bg, sb.fg)}>
                    <span style={{ width: 6, height: 6, borderRadius: '50%', background: sb.dot, flexShrink: 0 }} />
                    {sb.label}
                  </span>
                  <span style={{ ...typo.micro, color: colors.textTertiary }}>第 {rt.round}/{rt.max_rounds} 轮</span>
                  <span style={{ ...typo.micro, color: colors.textTertiary }}>{rt.moderator === 'ai' ? 'AI主持' : '用户主持'}</span>
                </div>
                <div style={{ ...typo.body, color: colors.textPrimary, marginTop: 4, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                  {rt.topic.slice(0, 40)}{rt.topic.length > 40 ? '…' : ''}
                </div>
              </div>
            );
          })}
    </div>
  );
}
