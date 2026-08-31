import { getApiBase } from '../apiBase';
import React, { useEffect, useState, useCallback } from 'react';
import { colors, fonts, radius, typo, cardL, btnPrimary, btnSecondary, btnGhost, input, textarea, calloutStyle } from '../theme';
import { Icon, Spinner } from '../Icon';
import { confirmDialog } from '../Dialog';

// TS-110 M4：知识/记忆/技能管理面板（三标签页）。
// 知识库：<项目工作目录>/knowledge/*.md（_ 前缀=禁用）；记忆：全局/项目两份；技能：启用开关+增删改+仓库安装。

const API = getApiBase();

interface KnowledgeItem { name: string; size: number; enabled: boolean; }
interface SkillItem { name: string; dir_name: string; description: string; enabled: boolean; }

type Tab = 'knowledge' | 'memory' | 'skills';

export function KnowledgePanel({ projectId }: { projectId: string | null }) {
  const [tab, setTab] = useState<Tab>('knowledge');

  const tabs: [Tab, string, React.ReactNode][] = [
    ['knowledge', '知识库', <Icon key="k" name="book" size={14} />],
    ['memory', '记忆', <Icon key="m" name="database" size={14} />],
    ['skills', '技能', <Icon key="s" name="wrench" size={14} />],
  ];

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 20 }}>
      {/* 标题 */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
        <Icon name="book" size={16} style={{ color: colors.textPrimary }} />
        <span style={{ ...typo.sectionTitle, color: colors.textPrimary }}>知识记忆</span>
      </div>

      {/* 未选项目提示条 */}
      {!projectId && (
        <div style={calloutStyle('info')}>
          <Icon name="info" size={16} style={{ flexShrink: 0 }} />
          <span>当前未选择项目：「记忆」标签可管理全局记忆，「技能」全局可用；「知识库」与「项目记忆」需先在主界面选择一个项目。</span>
        </div>
      )}

      {/* 标签头：三标签连排 */}
      <div style={{ display: 'flex' }}>
        {tabs.map(([t, label, icon], idx) => {
          const selected = tab === t;
          const isFirst = idx === 0;
          const isLast = idx === tabs.length - 1;
          return (
            <button
              key={t}
              onClick={() => setTab(t)}
              style={{
                flex: 1, height: 30, display: 'inline-flex', alignItems: 'center', justifyContent: 'center', gap: 6,
                border: `1px solid ${colors.borderStrong}`,
                borderBottom: selected ? `2px solid ${colors.accent}` : `1px solid ${colors.borderStrong}`,
                background: selected ? colors.bgCard : '#F5F5F7',
                color: selected ? colors.accentText : colors.textSecondary,
                fontSize: 13, fontWeight: selected ? 500 : 400, cursor: 'pointer', fontFamily: fonts.base,
                borderRadius: isFirst ? `${radius.s}px 0 0 ${radius.s}px` : isLast ? `0 ${radius.s}px ${radius.s}px 0` : 0,
                marginLeft: idx > 0 ? -1 : 0,
                position: 'relative', zIndex: selected ? 1 : 0,
              }}
            >
              {icon}
              {label}
            </button>
          );
        })}
      </div>

      {tab === 'knowledge' && <KnowledgeTab projectId={projectId} />}
      {tab === 'memory' && <MemoryTab projectId={projectId} />}
      {tab === 'skills' && <SkillsTab />}
    </div>
  );
}

// ── 胶囊状态按钮 ──
function capsuleBtn(on: boolean, label: string, onClick: () => void, disabled?: boolean) {
  return (
    <button
      className="ui-btn"
      onClick={onClick}
      disabled={disabled}
      style={{
        display: 'inline-flex', alignItems: 'center', height: 22, padding: '0 8px',
        borderRadius: radius.pill, fontSize: 11, fontWeight: 500, cursor: 'pointer',
        border: 'none', fontFamily: fonts.base,
        background: on ? colors.accentBg : '#ECECEE',
        color: on ? colors.accentText : colors.textSecondary,
      }}
    >
      {label}
    </button>
  );
}

// ── 小按钮样式 ──
const smallSecondary: React.CSSProperties = {
  ...btnSecondary, height: 22, padding: '0 8px', fontSize: 12,
};
const smallGhost: React.CSSProperties = {
  ...btnGhost, height: 22, padding: '0 8px', fontSize: 12,
};

// ── 知识库标签页 ──
function KnowledgeTab({ projectId }: { projectId: string | null }) {
  const [items, setItems] = useState<KnowledgeItem[]>([]);
  const [editing, setEditing] = useState<string | null>(null);
  const [editContent, setEditContent] = useState('');
  const [newName, setNewName] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    if (!projectId) return;
    try {
      const res = await fetch(`${API}/projects/${projectId}/knowledge`);
      if (res.ok) {
        const d = await res.json();
        if (Array.isArray(d)) setItems(d as KnowledgeItem[]);
      }
    } catch (e) { console.error('knowledge list:', e); }
  }, [projectId]);
  useEffect(() => { refresh(); }, [refresh]);

  if (!projectId) {
    return (
      <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 8, padding: '24px 0' }}>
        <Icon name="book" size={36} style={{ color: '#C9C9CF' }} />
        <span style={{ fontSize: 13, color: colors.textTertiary }}>请先在主界面选择一个项目，即可管理该项目的知识库（项目文件夹/knowledge/）。</span>
      </div>
    );
  }

  const openEdit = async (name: string) => {
    try {
      const res = await fetch(`${API}/projects/${projectId}/knowledge/${encodeURIComponent(name)}`);
      if (!res.ok) { setError('读取失败'); return; }
      const d = await res.json();
      setEditing(name); setEditContent(d.content || ''); setError(null);
    } catch (e) { setError('读取失败: ' + (e as Error).message); }
  };

  const saveEdit = async (name: string) => {
    setBusy(true); setError(null);
    try {
      const res = await fetch(`${API}/projects/${projectId}/knowledge`, {
        method: 'PUT', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name, content: editContent }),
      });
      if (!res.ok) { const d = await res.json().catch(() => ({})); throw new Error(d.detail || `HTTP ${res.status}`); }
      setEditing(null); refresh();
    } catch (e) { setError('保存失败: ' + (e as Error).message); }
    finally { setBusy(false); }
  };

  const createNew = async () => {
    const name = newName.trim().endsWith('.md') ? newName.trim() : newName.trim() + '.md';
    if (!name || name === '.md') { setError('请输入文件名'); return; }
    setBusy(true); setError(null);
    try {
      const res = await fetch(`${API}/projects/${projectId}/knowledge`, {
        method: 'PUT', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name, content: '' }),
      });
      if (!res.ok) { const d = await res.json().catch(() => ({})); throw new Error(d.detail || `HTTP ${res.status}`); }
      setNewName(''); refresh();
    } catch (e) { setError('新建失败: ' + (e as Error).message); }
    finally { setBusy(false); }
  };

  const toggle = async (name: string) => {
    try {
      const res = await fetch(`${API}/projects/${projectId}/knowledge/${encodeURIComponent(name)}/toggle`, { method: 'POST' });
      if (!res.ok) { const d = await res.json().catch(() => ({})); setError(d.detail || '切换失败'); }
      refresh();
    } catch (e) { setError('切换失败: ' + (e as Error).message); }
  };

  const remove = async (name: string) => {
    const ok = await confirmDialog({ title: '删除知识文件', message: `删除知识文件 ${name}？`, confirmText: '删除', danger: true });
    if (!ok) return;
    try {
      await fetch(`${API}/projects/${projectId}/knowledge/${encodeURIComponent(name)}`, { method: 'DELETE' });
      refresh();
    } catch (e) { setError('删除失败: ' + (e as Error).message); }
  };

  return (
    <div style={{ ...cardL, padding: '16px 20px' }}>
      <div style={{ fontSize: 12, color: colors.textTertiary, marginBottom: 12, lineHeight: 1.6 }}>
        知识文件存放在项目文件夹的 knowledge/ 目录，对话时自动注入给 Agent（以 _ 开头的文件不注入）。
      </div>
      {error && (
        <div style={{ ...calloutStyle('error'), marginBottom: 12 }}>
          <Icon name="alert-triangle" size={16} style={{ flexShrink: 0 }} />
          <span>{error}</span>
        </div>
      )}
      <div style={{ display: 'flex', gap: 8, marginBottom: 12, alignItems: 'center' }}>
        <input value={newName} onChange={e => setNewName(e.target.value)} placeholder="新知识文件名（.md）"
          className="ui-input" style={{ ...input, flex: 1 }} />
        <button className="ui-btn ui-btn-primary" style={smallSecondary} onClick={createNew} disabled={busy}>
          {busy ? <Spinner size={12} /> : <Icon name="plus" size={14} />}
          新建
        </button>
      </div>
      {items.length === 0 && (
        <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 8, padding: '20px 0' }}>
          <Icon name="file-text" size={36} style={{ color: '#C9C9CF' }} />
          <span style={{ fontSize: 13, color: colors.textTertiary }}>暂无知识文件</span>
        </div>
      )}
      {items.map(it => (
        <div key={it.name}>
          <div style={{
            display: 'flex', alignItems: 'center', gap: 8, padding: '6px 0',
            borderBottom: `1px solid ${colors.borderSubtle}`,
            opacity: it.enabled ? 1 : 0.6,
          }}>
            <span style={{
              width: 8, height: 8, borderRadius: '50%', flexShrink: 0,
              background: it.enabled ? colors.ok : '#C9C9CF',
            }} />
            <span style={{ flex: 1, fontSize: 13, color: it.enabled ? colors.textPrimary : colors.textTertiary }}>{it.name}</span>
            {capsuleBtn(it.enabled, it.enabled ? '启用' : '禁用', () => toggle(it.name))}
            <button className="ui-btn ui-btn-ghost" style={smallGhost} onClick={() => openEdit(it.name)}>
              <Icon name="pencil" size={14} />
              编辑
            </button>
            <button className="ui-btn ui-btn-ghost ui-ico-danger" style={{ ...smallGhost, color: colors.dangerText }} onClick={() => remove(it.name)}>
              <Icon name="trash" size={14} />
              删除
            </button>
          </div>
          {editing === it.name && (
            <div style={{ padding: '8px 0' }}>
              <textarea value={editContent} onChange={e => setEditContent(e.target.value)} rows={8}
                className="ui-input" style={{ ...textarea, width: '100%' }} />
              <div style={{ display: 'flex', gap: 8, marginTop: 6 }}>
                <button className="ui-btn ui-btn-secondary" style={smallSecondary} onClick={() => saveEdit(it.name)} disabled={busy}>
                  {busy ? <Spinner size={12} /> : null}
                  保存
                </button>
                <button className="ui-btn ui-btn-ghost" style={smallGhost} onClick={() => setEditing(null)}>取消</button>
              </div>
            </div>
          )}
        </div>
      ))}
    </div>
  );
}

// ── 记忆标签页 ──
function MemoryTab({ projectId }: { projectId: string | null }) {
  const [globalMem, setGlobalMem] = useState('');
  const [projectMem, setProjectMem] = useState('');
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      const g = await fetch(`${API}/memory?scope=global`);
      if (g.ok) setGlobalMem((await g.json()).content || '');
      if (projectId) {
        const p = await fetch(`${API}/memory?scope=project&project_id=${projectId}`);
        if (p.ok) setProjectMem((await p.json()).content || '');
      }
    } catch (e) { console.error('memory load:', e); }
  }, [projectId]);
  useEffect(() => { load(); }, [load]);

  const save = async (scope: string, content: string) => {
    setBusy(true); setMsg(null);
    try {
      const res = await fetch(`${API}/memory`, {
        method: 'PUT', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ scope, project_id: projectId, content }),
      });
      if (!res.ok) { const d = await res.json().catch(() => ({})); throw new Error(d.detail || `HTTP ${res.status}`); }
      setMsg('已保存 ✓'); setTimeout(() => setMsg(null), 2500);
    } catch (e) { setMsg('保存失败: ' + (e as Error).message); }
    finally { setBusy(false); }
  };

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 20 }}>
      <div style={{ ...cardL, padding: '16px 20px' }}>
        <div style={{ fontSize: 12, color: colors.textTertiary, marginBottom: 12, lineHeight: 1.6 }}>
          记忆是 Agent 的持久信息。以"禁止/不得/不允许/严禁"开头的行会进入红线（必须遵守）。
          与知识库冲突时，以记忆为准；项目记忆与全局记忆冲突时，以项目记忆为准。
        </div>
        {msg && (
          <div style={{ ...calloutStyle(msg.startsWith('保存失败') ? 'error' : 'success'), marginBottom: 12 }}>
            <Icon name={msg.startsWith('保存失败') ? 'alert-triangle' : 'check'} size={16} style={{ flexShrink: 0 }} />
            <span>{msg}</span>
          </div>
        )}

        {/* 全局记忆 */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginBottom: 8 }}>
          <Icon name="globe" size={14} style={{ color: colors.accentText }} />
          <span style={{ fontSize: 13, fontWeight: 500, color: colors.textPrimary }}>全局记忆（所有项目生效，存于数据目录）</span>
        </div>
        <textarea value={globalMem} onChange={e => setGlobalMem(e.target.value)} rows={5}
          className="ui-input" style={{ ...textarea, width: '100%', minHeight: 120 }} />
        <button className="ui-btn ui-btn-secondary" style={{ ...smallSecondary, marginTop: 8 }}
          onClick={() => save('global', globalMem)} disabled={busy}>
          {busy ? <Spinner size={12} /> : null}
          保存全局记忆
        </button>
      </div>

      {/* 项目记忆 */}
      <div style={{ ...cardL, padding: '16px 20px' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginBottom: 8 }}>
          <Icon name="folder" size={14} style={{ color: colors.accentText }} />
          <span style={{ fontSize: 13, fontWeight: 500, color: colors.textPrimary }}>项目记忆（仅本项目，存于项目文件夹 memory.md）</span>
        </div>
        {projectId ? (
          <>
            <textarea value={projectMem} onChange={e => setProjectMem(e.target.value)} rows={5}
              className="ui-input" style={{ ...textarea, width: '100%', minHeight: 120 }} />
            <button className="ui-btn ui-btn-secondary" style={{ ...smallSecondary, marginTop: 8 }}
              onClick={() => save('project', projectMem)} disabled={busy}>
              {busy ? <Spinner size={12} /> : null}
              保存项目记忆
            </button>
          </>
        ) : (
          <div style={calloutStyle('info')}>
            <Icon name="info" size={16} style={{ flexShrink: 0 }} />
            <span>未选择项目：请先在主界面选择一个项目，即可编辑项目记忆。</span>
          </div>
        )}
      </div>
    </div>
  );
}

// ── 技能标签页 ──
function SkillsTab() {
  const [skills, setSkills] = useState<SkillItem[]>([]);
  const [editing, setEditing] = useState<string | null>(null);
  const [form, setForm] = useState({ name: '', description: '', body: '' });
  const [creating, setCreating] = useState(false);
  const [installUrl, setInstallUrl] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    try {
      const res = await fetch(`${API}/skills`);
      if (res.ok) {
        const d = await res.json();
        if (Array.isArray(d)) setSkills(d as SkillItem[]);
      }
    } catch (e) { console.error('skills list:', e); }
  }, []);
  useEffect(() => { refresh(); }, [refresh]);

  const openEdit = async (dirName: string) => {
    try {
      const res = await fetch(`${API}/skills/${encodeURIComponent(dirName)}`);
      if (!res.ok) { setError('读取失败'); return; }
      const d = await res.json();
      setEditing(dirName);
      setForm({ name: d.name || dirName, description: d.description || '', body: d.content || '' });
      setError(null);
    } catch (e) { setError('读取失败: ' + (e as Error).message); }
  };

  const save = async (isNew: boolean) => {
    if (!form.name.trim()) { setError('请输入技能名'); return; }
    setBusy(true); setError(null);
    try {
      const url = isNew ? `${API}/skills` : `${API}/skills/${encodeURIComponent(editing || form.name)}`;
      const res = await fetch(url, {
        method: isNew ? 'POST' : 'PUT', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name: form.name.trim(), description: form.description, body: form.body, enabled: true }),
      });
      if (!res.ok) { const d = await res.json().catch(() => ({})); throw new Error(d.detail || `HTTP ${res.status}`); }
      setCreating(false); setEditing(null); setForm({ name: '', description: '', body: '' });
      refresh();
    } catch (e) { setError('保存失败: ' + (e as Error).message); }
    finally { setBusy(false); }
  };

  const toggle = async (dirName: string) => {
    try {
      const res = await fetch(`${API}/skills/${encodeURIComponent(dirName)}/toggle`, { method: 'POST' });
      if (!res.ok) { const d = await res.json().catch(() => ({})); setError(d.detail || '切换失败'); }
      refresh();
    } catch (e) { setError('切换失败: ' + (e as Error).message); }
  };

  const remove = async (dirName: string) => {
    const ok = await confirmDialog({ title: '删除技能', message: `删除技能 ${dirName}？`, confirmText: '删除', danger: true });
    if (!ok) return;
    try {
      await fetch(`${API}/skills/${encodeURIComponent(dirName)}`, { method: 'DELETE' });
      refresh();
    } catch (e) { setError('删除失败: ' + (e as Error).message); }
  };

  const install = async () => {
    if (!installUrl.trim()) { setError('请输入仓库地址或本地路径'); return; }
    setBusy(true); setError(null);
    try {
      const res = await fetch(`${API}/skills/install`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ url: installUrl.trim() }),
      });
      const d = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(d.detail || `HTTP ${res.status}`);
      setInstallUrl(''); refresh();
    } catch (e) { setError('安装失败: ' + (e as Error).message); }
    finally { setBusy(false); }
  };

  return (
    <div style={{ ...cardL, padding: '16px 20px' }}>
      <div style={{ fontSize: 12, color: colors.textTertiary, marginBottom: 12, lineHeight: 1.6 }}>
        技能（SKILL.md）是 Agent 按需引用的指令集：启用后出现在提示词清单，Agent 需要时调 read_skill 读取正文。
      </div>
      {error && (
        <div style={{ ...calloutStyle('error'), marginBottom: 12 }}>
          <Icon name="alert-triangle" size={16} style={{ flexShrink: 0 }} />
          <span>{error}</span>
        </div>
      )}

      {/* 安装 + 新建 */}
      <div style={{ display: 'flex', gap: 8, marginBottom: 12, alignItems: 'center' }}>
        <input value={installUrl} onChange={e => setInstallUrl(e.target.value)} placeholder="从仓库/本地路径安装（含 SKILL.md）"
          className="ui-input" style={{ ...input, flex: 1 }} />
        <button className="ui-btn ui-btn-secondary" style={smallSecondary} onClick={install} disabled={busy}>
          {busy ? <Spinner size={12} /> : null}
          安装
        </button>
        <button className="ui-btn ui-btn-primary" style={{ ...btnPrimary, height: 22, padding: '0 8px', fontSize: 12 }}
          onClick={() => { setCreating(v => !v); setEditing(null); }}>
          <Icon name="plus" size={14} />
          新建
        </button>
      </div>

      {(creating || editing) && (
        <div style={{
          border: `1px solid ${colors.borderDefault}`, borderRadius: radius.m, padding: 12, marginBottom: 12,
          background: colors.bgCard,
        }}>
          <input value={form.name} onChange={e => setForm({ ...form, name: e.target.value })} placeholder="技能名（字母/数字/中文/-/_）"
            disabled={!!editing} className="ui-input" style={{ ...input, width: '100%', marginBottom: 8 }} />
          <input value={form.description} onChange={e => setForm({ ...form, description: e.target.value })} placeholder="一句话描述（何时用这个技能）"
            className="ui-input" style={{ ...input, width: '100%', marginBottom: 8 }} />
          <textarea value={form.body} onChange={e => setForm({ ...form, body: e.target.value })} rows={8} placeholder="技能指令正文（Markdown）"
            className="ui-input" style={{ ...textarea, width: '100%' }} />
          <div style={{ display: 'flex', gap: 8, marginTop: 8 }}>
            <button className="ui-btn ui-btn-secondary" style={smallSecondary} onClick={() => save(creating && !editing)} disabled={busy}>
              {busy ? <Spinner size={12} /> : null}
              保存
            </button>
            <button className="ui-btn ui-btn-ghost" style={smallGhost} onClick={() => { setCreating(false); setEditing(null); }}>取消</button>
          </div>
        </div>
      )}

      {skills.length === 0 && (
        <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 8, padding: '20px 0' }}>
          <Icon name="wrench" size={36} style={{ color: '#C9C9CF' }} />
          <span style={{ fontSize: 13, color: colors.textTertiary }}>暂无技能</span>
        </div>
      )}
      {skills.map(s => (
        <div key={s.dir_name}>
          <div style={{
            display: 'flex', alignItems: 'center', gap: 8, padding: '6px 0',
            borderBottom: `1px solid ${colors.borderSubtle}`,
            opacity: s.enabled ? 1 : 0.6,
          }}>
            <span style={{
              width: 8, height: 8, borderRadius: '50%', flexShrink: 0,
              background: s.enabled ? colors.ok : '#C9C9CF',
            }} />
            <span style={{ fontSize: 13, color: s.enabled ? colors.textPrimary : colors.textTertiary }}>{s.name}</span>
            <span style={{ color: colors.textTertiary, flex: 1, fontSize: 12, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{s.description}</span>
            {capsuleBtn(s.enabled, s.enabled ? '启用' : '禁用', () => toggle(s.dir_name))}
            <button className="ui-btn ui-btn-ghost" style={smallGhost} onClick={() => openEdit(s.dir_name)}>
              <Icon name="pencil" size={14} />
              编辑
            </button>
            <button className="ui-btn ui-btn-ghost ui-ico-danger" style={{ ...smallGhost, color: colors.dangerText }} onClick={() => remove(s.dir_name)}>
              <Icon name="trash" size={14} />
              删除
            </button>
          </div>
        </div>
      ))}
    </div>
  );
}
