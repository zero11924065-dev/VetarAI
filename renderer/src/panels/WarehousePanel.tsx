/**
 * TS-120（0.3.0）：知识仓库右侧面板（拉模式）。
 *
 * 与 KnowledgePanel.tsx（M4 设置页的知识/记忆/技能三标签，推模式）严格区分：
 * 本面板是会话框右侧的"知识仓库"——对话/知识转移进来成为独立 .md 文件，
 * 只有用户显式搜索/勾选才读取，永不自动注入模型上下文。
 *
 * 功能：作用域切换（本项目/全局）/ 关键词搜索（FTS5）/ 列出条目 / 结果勾选
 *      / 发送到会话窗（作为用户消息注入，仅勾选的条目）。
 * 面板可收起/展开由父组件（ChatPanel）控制；本组件只负责面板内容。
 */
import { useState, useCallback, useEffect } from 'react';
import { getApiBase } from '../apiBase';
import { colors, radius, shadow } from '../theme';
import { Icon, Spinner } from '../Icon';

const API = getApiBase();

const inputStyle = {
  padding: '6px 10px', borderRadius: radius.s, border: `1px solid ${colors.borderStrong}`,
  background: colors.bgCard, color: colors.textPrimary, fontSize: 13, fontFamily: 'inherit',
  boxSizing: 'border-box' as const,
};

export interface WarehouseEntry {
  id: string; title: string; scope: string; project_id?: string;
  category?: string; keywords?: string[]; file_path?: string; created_at?: string;
  body?: string;
  /** 阶段二：混合/语义检索返回的相关度得分 */
  score?: number;
}

export function WarehousePanel({ projectId, onInject, onClose, initialScope }: {
  projectId: string;
  /** 把勾选条目注入会话（父组件负责拼成用户消息发送） */
  onInject: (text: string) => void;
  onClose: () => void;
  /** TS-121 查虫C：刚转移到哪个作用域，面板就定位到哪个作用域 */
  initialScope?: 'project' | 'global';
}) {
  const [scope, setScope] = useState<'project' | 'global'>(initialScope || 'project');
  // TS-121 查虫C：面板已展开时，外部转移到另一作用域 → 定位跟随
  useEffect(() => { if (initialScope) setScope(initialScope); }, [initialScope]);
  const [query, setQuery] = useState('');
  const [results, setResults] = useState<WarehouseEntry[]>([]);
  const [checked, setChecked] = useState<Set<string>>(new Set());
  const [searching, setSearching] = useState(false);
  // TS-120 阶段二：检索模式——混合（默认，两路融合）/ 关键词（FTS5 精确）/ 语义（bge-m3 向量）
  const [searchMode, setSearchMode] = useState<'hybrid' | 'keyword' | 'semantic'>('hybrid');

  const doSearch = useCallback(async () => {
    setSearching(true);
    try {
      const params = new URLSearchParams();
      params.set('scope', scope);
      if (scope === 'project') params.set('project_id', projectId);
      const url = query.trim()
        ? `${API}/knowledge/search?q=${encodeURIComponent(query.trim())}&mode=${searchMode}&${params}`
        : `${API}/knowledge/entries?${params}`;
      const res = await fetch(url);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      setResults(Array.isArray(data) ? data : []);
      setChecked(new Set());
    } catch {
      setResults([]);
    } finally {
      setSearching(false);
    }
  }, [query, scope, projectId, searchMode]);

  // TS-121（问题2 + 查虫A）：挂载/切换作用域时自动载入该作用域全部条目——
  // 转移入库后自动展开即见新条目，外部增删（经后端对账）也即时反映。
  // 关键：依赖只有 scope/projectId，不含 query——否则输入框每敲一键就发一次请求。
  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const params = new URLSearchParams();
        params.set('scope', scope);
        if (scope === 'project') params.set('project_id', projectId);
        const res = await fetch(`${API}/knowledge/entries?${params}`);
        if (!res.ok || cancelled) return;
        const data = await res.json();
        if (cancelled) return;
        setResults(Array.isArray(data) ? data : []);
        setChecked(new Set());
      } catch { /* 静默：列表加载失败不打断面板 */ }
    })();
    return () => { cancelled = true; };
  }, [scope, projectId]);

  const toggleCheck = (id: string) => {
    setChecked(prev => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id); else next.add(id);
      return next;
    });
  };

  const handleInject = async () => {
    if (checked.size === 0) return;
    try {
      const res = await fetch(`${API}/knowledge/inject`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ entry_ids: Array.from(checked) }),
      });
      const d = await res.json();
      if (!res.ok) throw new Error(d.detail || `HTTP ${res.status}`);
      onInject(d.text);
      setChecked(new Set());
    } catch { /* 静默 */ }
  };

  return (
    <div style={{ width: 300, flexShrink: 0, borderLeft: `1px solid ${colors.borderSubtle}`, background: colors.bgSidebar, display: 'flex', flexDirection: 'column', height: '100%', overflow: 'hidden' }}>
      {/* 头部 */}
      <div style={{ padding: '10px 12px', borderBottom: `1px solid ${colors.borderSubtle}`, display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
          <Icon name="database" size={15} style={{ color: colors.accentText }} />
          <span style={{ fontSize: 13, fontWeight: 600, color: colors.textPrimary }}>知识仓库</span>
        </div>
        <button onClick={onClose} data-tip="收起面板"
          style={{ width: 24, height: 24, padding: 0, display: 'inline-flex', alignItems: 'center', justifyContent: 'center', border: 'none', background: 'transparent', cursor: 'pointer', borderRadius: radius.s }}>
          <Icon name="chevron-right" size={15} style={{ color: colors.textSecondary }} />
        </button>
      </div>

      {/* 作用域切换 */}
      <div style={{ padding: '10px 12px 4px', display: 'flex', gap: 6 }}>
        {(['project', 'global'] as const).map(s => (
          <button key={s} onClick={() => setScope(s)}
            style={{
              flex: 1, padding: '5px 0', fontSize: 12, borderRadius: radius.s, cursor: 'pointer',
              border: scope === s ? `1px solid ${colors.accentBorder}` : `1px solid ${colors.borderStrong}`,
              background: scope === s ? colors.accentBg : colors.bgCard,
              color: scope === s ? colors.accentText : colors.textSecondary,
            }}>
            {s === 'project' ? '本项目' : '全局'}
          </button>
        ))}
      </div>

      {/* 搜索框 */}
      <div style={{ padding: '8px 12px 4px', display: 'flex', gap: 6 }}>
        <input value={query} onChange={e => setQuery(e.target.value)}
          onKeyDown={e => { if (e.key === 'Enter') doSearch(); }}
          placeholder="搜索（关键词/换述，留空=列出全部）"
          style={{ ...inputStyle, flex: 1, minWidth: 0 }} />
        <button onClick={doSearch} disabled={searching} data-tip="搜索"
          style={{ width: 32, height: 32, padding: 0, display: 'inline-flex', alignItems: 'center', justifyContent: 'center', border: 'none', background: colors.accent, color: colors.onAccent, borderRadius: radius.s, cursor: searching ? 'wait' : 'pointer', flexShrink: 0 }}>
          {searching ? <Spinner size={14} /> : <Icon name="sparkle" size={14} />}
        </button>
      </div>

      {/* 检索模式切换（阶段二：混合/关键词/语义） */}
      <div style={{ padding: '0 12px 6px', display: 'flex', gap: 6 }}>
        {([['hybrid', '混合'], ['keyword', '关键词'], ['semantic', '语义']] as const).map(([m, label]) => (
          <button key={m} onClick={() => setSearchMode(m)}
            title={m === 'hybrid' ? '关键词+语义两路融合（默认，最全）'
              : m === 'keyword' ? '精确匹配字词（FTS5 全文）'
              : '理解语义找近义内容（bge-m3 本地模型）'}
            style={{
              flex: 1, padding: '3px 0', fontSize: 11, borderRadius: radius.s, cursor: 'pointer',
              border: searchMode === m ? `1px solid ${colors.accentBorder}` : `1px solid ${colors.borderSubtle}`,
              background: searchMode === m ? colors.accentBg : colors.bgCard,
              color: searchMode === m ? colors.accentText : colors.textTertiary,
            }}>
            {label}
          </button>
        ))}
      </div>

      {/* 结果列表 */}
      <div style={{ flex: 1, overflowY: 'auto', padding: '4px 12px' }}>
        {results.length === 0 && (
          <div style={{ textAlign: 'center', color: colors.textTertiary, fontSize: 12, padding: '24px 0' }}>
            {searching ? '搜索中…' : (query.trim() ? '无匹配结果' : '暂无知识条目')}
          </div>
        )}
        {results.map(e => (
          <div key={e.id}
            style={{ padding: '8px 10px', marginBottom: 6, borderRadius: radius.s, background: colors.bgCard, border: `1px solid ${colors.borderSubtle}`, boxShadow: shadow.s }}>
            <div style={{ display: 'flex', alignItems: 'flex-start', gap: 6 }}>
              <input type="checkbox" checked={checked.has(e.id)} onChange={() => toggleCheck(e.id)}
                style={{ accentColor: colors.accent, marginTop: 2, cursor: 'pointer' }} />
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ fontSize: 12, fontWeight: 600, color: colors.textPrimary, wordBreak: 'break-word' }}>
                  {e.title}
                  {/* 阶段二：相关度得分（混合/语义模式返回） */}
                  {typeof (e as any).score === 'number' && (
                    <span style={{ fontSize: 10, color: colors.textTertiary, marginLeft: 6, fontWeight: 400 }}>
                      相关 {(e as any).score >= 0.01 ? Math.round((e as any).score * 100) + '%' : (e as any).score.toFixed(3)}
                    </span>
                  )}
                </div>
                {e.category && <div style={{ fontSize: 10, color: colors.textTertiary, marginTop: 2 }}>分类：{e.category}</div>}
                {e.created_at && <div style={{ fontSize: 10, color: colors.textTertiary, marginTop: 2 }}>{e.created_at}</div>}
              </div>
            </div>
          </div>
        ))}
      </div>

      {/* 底部：发送到会话 */}
      <div style={{ padding: '10px 12px', borderTop: `1px solid ${colors.borderSubtle}` }}>
        <button onClick={handleInject} disabled={checked.size === 0}
          style={{
            width: '100%', padding: '8px 0', fontSize: 13, borderRadius: radius.s, cursor: checked.size ? 'pointer' : 'default',
            border: 'none', background: checked.size ? colors.accent : colors.disabledBg,
            color: checked.size ? colors.onAccent : colors.disabledText,
            opacity: checked.size ? 1 : 0.7,
          }}>
          发送 {checked.size} 条到会话
        </button>
        <div style={{ fontSize: 10, color: colors.textTertiary, marginTop: 6, lineHeight: 1.5 }}>
          注入的内容会作为你的消息进入对话（仅你勾选的条目）。知识内容默认不自动进入上下文。
        </div>
      </div>
    </div>
  );
}
