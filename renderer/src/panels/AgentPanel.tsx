import { getApiBase } from '../apiBase';
import React, { useEffect, useState } from 'react';
import { colors, fonts, radius, shadow, typo, btnPrimary, btnSecondary, btnGhost, input, textarea as textareaStyle, select as selectStyle, badge, calloutStyle } from '../theme';
import { Icon, Spinner } from '../Icon';
import { confirmDialog, alertDialog } from '../Dialog';

interface Agent { id: string; name: string; role?: string; model_name?: string; type_: string; parent_agent_id?: string | null; system_prompt?: string | null; }

const API = getApiBase();

export function AgentPanel({ projectId, selectedAgentId, onSelectAgent }: {
  projectId: string; selectedAgentId: string | null; onSelectAgent: (id: string) => void;
}) {
  const [agents, setAgents] = useState<Agent[]>([]);
  const [newName, setNewName] = useState('');
  const [selectedModel, setSelectedModel] = useState('');
  const [newType, setNewType] = useState<'main' | 'sub'>('main');
  const [modelList, setModelList] = useState<{name:string,size?:number}[]>([]);
  const [creating, setCreating] = useState(false);
  // M1-3 补漏（U3）：system_prompt 编辑 —— 创建时可选填写，已有 Agent 行内编辑
  const [newPrompt, setNewPrompt] = useState('');
  const [editingId, setEditingId] = useState<string | null>(null);
  const [editText, setEditText] = useState('');
  const [savingPrompt, setSavingPrompt] = useState(false);
  const [hoverId, setHoverId] = useState<string | null>(null);

  async function fetchAgents() {
    try {
      const res = await fetch(`${API}/agents/${projectId}`);
      if (!res.ok) return;
      const data = await res.json();
      if (Array.isArray(data)) setAgents(data as Agent[]);
    } catch (e) { console.error('Failed to load agents:', e); }
  }

  async function fetchModels() {
    try {
      const res = await fetch(`${API}/ollama/models`);
      const data = await res.json();
      if (Array.isArray(data)) setModelList(data as {name:string,size?:number}[]);
    } catch (e) { console.error('Failed to load models:', e); }
  }

  useEffect(() => { fetchAgents(); fetchModels(); }, [projectId]);
  // H17 问题1：委派执行中可能随时自动新建子 Agent（后端行为），前端无事件通道 →
  // 轮询刷新列表，让新建的子 Agent 及时出现在左侧（8s 间隔，单次轻量 SQLite 查询）
  useEffect(() => {
    const t = setInterval(() => { fetchAgents(); }, 8000);
    return () => clearInterval(t);
  }, [projectId]);

  async function handleCreate() {
    if (creating) return;
    const modelToUse = selectedModel || modelList[0]?.name || 'qwen3.8';
    setCreating(true);
    try {
      const res = await fetch(`${API}/agents`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          project_id: projectId,
          name: newName.trim() || `Agent ${agents.length + 1}`,
          type_: newType,
          model_name: modelToUse,
          system_prompt: newPrompt.trim() || undefined,
        }),
      });
      if (!res.ok) {
        const d = await res.json().catch(() => ({}));
        console.error('create agent failed:', res.status, d.detail);
        await alertDialog({ title: '创建失败', message: d.detail || `HTTP ${res.status}` });
      } else {
        setNewName('');
        setNewPrompt('');
      }
      fetchAgents();
    } catch (e) {
      console.error('Failed to create agent:', e);
      await alertDialog({ title: '创建失败', message: (e as any).message });
    } finally {
      setCreating(false);
    }
  }

  async function handleDelete(agentId: string) {
    const ok = await confirmDialog({
      title: '删除 Agent',
      message: '删除该 Agent？其所有会话和消息将被清空。',
      confirmText: '删除',
      cancelText: '取消',
      danger: true,
    });
    if (!ok) return;
    try {
      await fetch(`${API}/agents/${projectId}/${agentId}`, { method: 'DELETE' });
      if (selectedAgentId === agentId) onSelectAgent(null as any);
      fetchAgents();
    } catch (e) { console.error('Failed to delete agent:', e); }
  }

  // M1-3 补漏（U3）：保存 system_prompt 编辑 → PUT /api/agents（DB 持久化，注入在 build_system_prompt）
  async function savePrompt(agentId: string) {
    if (savingPrompt) return;
    setSavingPrompt(true);
    try {
      const r = await fetch(`${API}/agents/${projectId}/${agentId}`, {
        method: 'PUT', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ system_prompt: editText }),
      });
      if (!r.ok) {
        const d = await r.json().catch(() => ({}));
        await alertDialog({ title: '保存失败', message: d.detail || `HTTP ${r.status}` });
      } else {
        setEditingId(null);
        fetchAgents();
      }
    } catch (e) {
      console.error('save prompt failed', e);
      await alertDialog({ title: '保存失败', message: (e as any).message });
    } finally { setSavingPrompt(false); }
  }

  return (
    <div style={{
      padding: 12, flex: 1, minHeight: 0, overflowY: 'auto', fontFamily: fonts.base,
    }}>
      {/* 面板标题行 */}
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 8, paddingBottom: 8, borderBottom: `1px solid ${colors.borderSubtle}` }}>
        <span style={typo.panelTitle}>Agent</span>
      </div>

      {/* 创建表单：白底卡片 */}
      <div style={{ marginBottom: 8, background: colors.bgCard, border: `1px solid ${colors.borderDefault}`, borderRadius: radius.m, padding: 12, display: 'flex', flexDirection: 'column', gap: 6 }}>
        <div style={{ display: 'flex', gap: 6 }}>
          <input value={newName} onChange={e => setNewName(e.target.value)}
            onKeyDown={e => e.key === 'Enter' && !e.nativeEvent.isComposing && e.keyCode !== 229 && handleCreate()}
            placeholder="Agent 名称" className="ui-input" style={{ ...input, flex: 1, minWidth: 0 }} />
          <select value={newType} onChange={e => setNewType(e.target.value as 'main' | 'sub')} style={{ ...selectStyle, maxWidth: 92 }}>
            <option value="main">主Agent</option>
            <option value="sub">子Agent</option>
          </select>
        </div>
        <div style={{ display: 'flex', gap: 6 }}>
          {modelList.length > 0 ? (
            <select value={selectedModel} onChange={e => setSelectedModel(e.target.value)} style={{ ...selectStyle, flex: 1, minWidth: 0 }}>
              <option value="">模型（默认首个）</option>
              {modelList.map(m => <option key={m.name} value={m.name}>{m.name}</option>)}
            </select>
          ) : (
            <select style={{ ...selectStyle, flex: 1, minWidth: 0 }} disabled>
              <option>模型加载中…</option>
            </select>
          )}
          <button className="ui-btn ui-btn-primary" onClick={handleCreate} disabled={creating}
            style={{ ...btnPrimary, whiteSpace: 'nowrap' }}>
            {creating ? <><Spinner size={12} style={{ borderTopColor: colors.onAccent }} /> 创建中…</> : <><Icon name="plus" size={14} /> 添加</>}
          </button>
        </div>
        {/* M1-3 补漏（U3）：创建时可选填角色设定（system_prompt） */}
        <textarea value={newPrompt} onChange={e => setNewPrompt(e.target.value)}
          placeholder="角色设定（可选）：如「你是严谨的代码审查员」，随对话注入模型"
          rows={2} className="ui-input" style={{ ...textareaStyle, width: '100%', minWidth: 0 }} />
      </div>

      {/* 空态 */}
      {agents.length === 0 && (
        <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', padding: '24px 0', gap: 8 }}>
          <Icon name="bot" size={36} style={{ color: '#C9C9CF' }} />
          <span style={{ fontSize: 13, color: colors.textTertiary }}>暂无 Agent，先在上方填写并点"+ 添加"创建</span>
        </div>
      )}

      {/* Agent 列表 */}
      {agents.map(a => {
        const isSelected = selectedAgentId === a.id;
        const isHover = hoverId === a.id;
        const isEditing = editingId === a.id;
        return (
          <div key={a.id} style={{ margin: '4px 0' }}>
            <div onClick={() => onSelectAgent(a.id)}
              onMouseEnter={() => setHoverId(a.id)}
              onMouseLeave={() => setHoverId(null)}
              style={{
                padding: '8px 10px',
                borderRadius: isEditing ? `${radius.s}px ${radius.s}px 0 0` : radius.s,
                cursor: 'pointer', display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 6,
                background: isSelected ? colors.bgCard : (isHover ? colors.bgHover : 'transparent'),
                border: isSelected ? `1px solid ${colors.borderDefault}` : '1px solid transparent',
                boxShadow: isSelected ? shadow.s : 'none',
                transition: 'background-color .15s ease, border-color .15s ease',
                userSelect: 'none',
              }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 6, minWidth: 0, flex: 1 }}>
                {/* 类型徽标 */}
                <span style={a.type_ === 'main'
                  ? { ...badge(colors.accentBg, colors.accentText), height: 18, fontSize: 11 }
                  : { ...badge('#DFF4F6', '#0F7490'), height: 18, fontSize: 11 }
                }>
                  {a.type_ === 'main' ? '主' : '子'}
                </span>
                <span style={{ ...typo.body, fontWeight: isSelected ? 500 : 400, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{a.name}</span>
                {a.system_prompt && <Icon name="file-text" size={11} style={{ color: colors.accentText, flexShrink: 0 }} title="已设角色设定" />}
              </div>
              <div style={{ display: 'flex', alignItems: 'center', gap: 4, flexShrink: 0 }}>
                {a.model_name && (
                  <select value={a.model_name}
                    onClick={e => e.stopPropagation()}
                    onChange={async e => {
                      e.stopPropagation();
                      const v = e.target.value;
                      try {
                        const r = await fetch(`${API}/agents/${projectId}/${a.id}`, {
                          method: 'PUT', headers: { 'Content-Type': 'application/json' },
                          body: JSON.stringify({ model_name: v }),
                        });
                        if (!r.ok) { const d = await r.json().catch(() => ({})); console.error('change model failed', d); }
                        fetchAgents();
                      } catch (err) { console.error('change model failed', err); }
                    }}
                    title="切换该 Agent 的模型"
                    style={{ ...selectStyle, fontSize: 11, padding: '2px 4px', height: 22, maxWidth: 140 }}>
                    {modelList.map(m => <option key={m.name} value={m.name}>{m.name}</option>)}
                  </select>
                )}
                {/* M1-3 补漏（U3）：编辑角色设定 */}
                <button className="ui-btn ui-btn-ghost"
                  onClick={e => { e.stopPropagation(); setEditingId(a.id); setEditText(a.system_prompt || ''); }}
                  style={{ ...btnGhost, height: 22, padding: '0 4px', color: colors.textTertiary }} title="编辑角色设定">
                  <Icon name="pencil" size={14} />
                </button>
                <button className="ui-btn ui-btn-ghost ui-ico-danger"
                  onClick={e => { e.stopPropagation(); handleDelete(a.id); }}
                  style={{ ...btnGhost, height: 22, padding: '0 4px', color: colors.textTertiary }} title="删除 Agent">
                  <Icon name="trash" size={14} />
                </button>
              </div>
            </div>
            {/* M1-3 补漏（U3）：行内编辑区 */}
            {isEditing && (
              <div style={{ background: colors.bgCard, padding: '8px 10px', borderRadius: `0 0 ${radius.m}px ${radius.m}px`, border: `1px solid ${colors.borderDefault}`, borderTop: 'none' }}>
                <textarea value={editText} onChange={e => setEditText(e.target.value)}
                  placeholder="角色设定（system_prompt）：留空保存则清除"
                  rows={3} className="ui-input" style={{ ...textareaStyle, width: '100%', minWidth: 0 }} />
                <div style={{ display: 'flex', gap: 6, marginTop: 6, justifyContent: 'flex-end' }}>
                  <button className="ui-btn ui-btn-secondary" onClick={() => setEditingId(null)} style={btnSecondary}>取消</button>
                  <button className="ui-btn ui-btn-primary" onClick={() => savePrompt(a.id)} disabled={savingPrompt}
                    style={{ ...btnPrimary, opacity: savingPrompt ? 0.6 : 1 }}>
                    {savingPrompt ? <><Spinner size={12} style={{ borderTopColor: colors.onAccent }} /> 保存中…</> : '保存'}
                  </button>
                </div>
              </div>
            )}
          </div>
        );
      })}
    </div>
  );
}
