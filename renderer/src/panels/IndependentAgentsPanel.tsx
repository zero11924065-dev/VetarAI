import { getApiBase } from '../apiBase';
import React, { useEffect, useState } from 'react';
import { colors, fonts, radius, shadow, typo, badge, btnPrimary, btnSecondary, btnGhost, input, textarea as textareaStyle, select as selectStyle } from '../theme';
import { Icon, Spinner } from '../Icon';
import { confirmDialog, alertDialog } from '../Dialog';

interface IndepAgent { id: string; name: string; model_name?: string; system_prompt?: string | null; }

const API = getApiBase();
/** checkpoint-058：独立 Agent 命名空间（与后端 INDEP_NS_PREFIX 一致） */
export const INDEP_NS_PREFIX = 'ia-';

/** checkpoint-058：独立 Agent 面板（与项目平级的一等公民）。
 * 不基于任何项目：全局注册、独立数据目录，删除项目不影响；可单独创建/删除。
 * 表头式折叠模块：点表头展开（创建表单 + 列表），再点收起。
 * checkpoint-058b：创建表单支持模型选择与角色设定；列表项支持切换模型与行内编辑角色设定。 */
export function IndependentAgentsPanel({ selectedAgentId, onSelect, onAgentDeleted, refreshKey = 0 }: {
  selectedAgentId: string | null;
  /** 选中独立 Agent：父级据此切到命名空间会话（projectId = ia-<id>） */
  onSelect: (agentId: string) => void;
  /** checkpoint-061：删除成功回调——父级据此清空选中态（杜绝幽灵聊天面板） */
  onAgentDeleted?: (agentId: string) => void;
  /** 外部触发刷新（如删除后） */
  refreshKey?: number;
}) {
  const [open, setOpen] = useState(false);
  const [agents, setAgents] = useState<IndepAgent[]>([]);
  const [headHover, setHeadHover] = useState(false);
  const [hoverId, setHoverId] = useState<string | null>(null);
  const [newName, setNewName] = useState('');
  const [creating, setCreating] = useState(false);
  // 创建表单：模型下拉（拉取可用模型列表）+ 角色设定
  const [modelList, setModelList] = useState<{name:string}[]>([]);
  const [newModel, setNewModel] = useState('');
  const [newPrompt, setNewPrompt] = useState('');
  // 列表项：行内编辑角色设定
  const [editingId, setEditingId] = useState<string | null>(null);
  const [editText, setEditText] = useState('');
  const [savingPrompt, setSavingPrompt] = useState(false);

  async function fetchAgents() {
    try {
      const r = await fetch(`${API}/independent-agents`);
      if (!r.ok) return;
      const d = await r.json();
      if (Array.isArray(d)) setAgents(d as IndepAgent[]);
    } catch { /* 侧车未运行：静默 */ }
  }

  async function fetchModels() {
    try {
      const r = await fetch(`${API}/ollama/models`);
      const d = await r.json();
      if (Array.isArray(d)) setModelList(d as {name:string}[]);
    } catch { /* 静默：创建时回退后端默认 */ }
  }

  useEffect(() => { fetchAgents(); fetchModels(); }, [refreshKey]);

  async function handleCreate() {
    if (creating) return;
    const name = newName.trim() || `独立 Agent ${agents.length + 1}`;
    setCreating(true);
    try {
      const r = await fetch(`${API}/independent-agents`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          name,
          model_name: newModel || undefined,
          system_prompt: newPrompt.trim() || undefined,
        }),
      });
      const d = r.ok ? await r.json() : null;
      if (!d || !d.agent_id) {
        await alertDialog({ title: '创建失败', message: (d && d.detail) || `HTTP ${r.status}` });
      } else {
        setNewName('');
        setNewPrompt('');
        await fetchAgents();
        onSelect(d.agent_id); // 创建后直接进入对话
      }
    } catch (e: any) {
      await alertDialog({ title: '创建失败', message: e.message || '未知错误' });
    } finally {
      setCreating(false);
    }
  }

  async function handleDelete(agent: IndepAgent) {
    const ok = await confirmDialog({
      title: '删除独立 Agent',
      message: `删除「${agent.name}」？其所有会话与消息将被清空，且不可恢复。`,
      confirmText: '删除',
      cancelText: '取消',
      danger: true,
    });
    if (!ok) return;
    try {
      const r = await fetch(`${API}/independent-agents/${agent.id}`, { method: 'DELETE' });
      if (!r.ok) {
        const d = await r.json().catch(() => ({}));
        await alertDialog({ title: '删除失败', message: d.detail || `HTTP ${r.status}` });
        return;
      }
      onAgentDeleted?.(agent.id); // checkpoint-061：通知父级清空选中态
      await fetchAgents();
    } catch (e: any) {
      await alertDialog({ title: '删除失败', message: e.message || '未知错误' });
    }
  }

  /** 切换某个独立 Agent 的模型 */
  async function handleSwitchModel(agent: IndepAgent, modelName: string) {
    try {
      const r = await fetch(`${API}/independent-agents/${agent.id}`, {
        method: 'PUT', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ model_name: modelName }),
      });
      if (!r.ok) { const d = await r.json().catch(() => ({})); console.error('switch model failed:', d); }
      fetchAgents();
    } catch (e) { console.error('switch model failed:', e); }
  }

  /** 保存角色设定编辑 */
  async function savePrompt(agent: IndepAgent) {
    if (savingPrompt) return;
    setSavingPrompt(true);
    try {
      const r = await fetch(`${API}/independent-agents/${agent.id}`, {
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
    } catch (e: any) {
      await alertDialog({ title: '保存失败', message: e.message || '未知错误' });
    } finally { setSavingPrompt(false); }
  }

  return (
    <div style={{ borderBottom: `1px solid ${colors.borderSubtle}`, fontFamily: fonts.base }}>
      {/* 表头：点击展开/收起全部独立 Agent */}
      <button
        onClick={() => setOpen(o => !o)}
        onMouseEnter={() => setHeadHover(true)}
        onMouseLeave={() => setHeadHover(false)}
        style={{
          display: 'flex', alignItems: 'center', gap: 8, width: '100%', height: 36,
          padding: '8px 12px', border: 'none', boxSizing: 'border-box',
          background: open || headHover ? colors.bgHover : 'transparent',
          color: open || headHover ? colors.textPrimary : colors.textSecondary,
          fontSize: 13, textAlign: 'left', cursor: 'pointer', fontFamily: fonts.base,
          transition: 'background-color .15s ease, color .15s ease',
        }}
      >
        <Icon name="bot" size={16} />
        <span style={{ flex: 1 }}>独立 Agent</span>
        {agents.length > 0 && (
          <span style={{ ...badge(colors.accentBg, colors.accentText), fontSize: 11 }}>{agents.length}</span>
        )}
        <Icon name={open ? 'chevron-up' : 'chevron-down'} size={14} style={{ color: colors.textTertiary }} />
      </button>

      {/* 展开区：创建表单 + 独立 Agent 列表
          checkpoint-061：独立 Agent 多时展开区会撑爆侧栏挤掉下方项目/设置入口——
          限高 45vh（与左栏其他手风琴一致）+ 独立滚动。 */}
      {open && (
        <div style={{ padding: '4px 12px 10px', maxHeight: '45vh', overflowY: 'auto' }}>
          {/* 创建表单：名称 / 模型 / 角色设定 */}
          <div style={{ background: colors.bgCard, border: `1px solid ${colors.borderDefault}`, borderRadius: radius.m, padding: 10, display: 'flex', flexDirection: 'column', gap: 6, marginBottom: 6 }}>
            <div style={{ display: 'flex', gap: 6 }}>
              <input value={newName} onChange={e => setNewName(e.target.value)}
                onKeyDown={e => e.key === 'Enter' && !e.nativeEvent.isComposing && e.keyCode !== 229 && handleCreate()}
                placeholder="新独立 Agent 名称" className="ui-input"
                style={{ ...input, flex: 1, minWidth: 0, height: 28, fontSize: 12 }} />
              <button className="ui-btn ui-btn-primary" onClick={handleCreate} disabled={creating}
                style={{ ...btnPrimary, height: 28, padding: '0 10px', fontSize: 12, whiteSpace: 'nowrap' }}>
                {creating ? <Spinner size={12} style={{ borderTopColor: colors.onAccent }} /> : <Icon name="plus" size={14} />}
                创建
              </button>
            </div>
            <select value={newModel} onChange={e => setNewModel(e.target.value)} style={{ ...selectStyle, height: 28, fontSize: 12 }}>
              <option value="">模型（默认）</option>
              {modelList.map(m => <option key={m.name} value={m.name}>{m.name}</option>)}
            </select>
            <textarea value={newPrompt} onChange={e => setNewPrompt(e.target.value)}
              placeholder="角色设定（可选）：如「你是严谨的文档审校员」，随对话注入模型"
              rows={2} className="ui-input" style={{ ...textareaStyle, width: '100%', minWidth: 0, fontSize: 12 }} />
          </div>

          {agents.length === 0 ? (
            <div style={{ fontSize: 12, color: colors.textTertiary, padding: '6px 2px' }}>
              暂无独立 Agent。独立 Agent 不属于任何项目，删项目不影响它；全局记忆/技能/插件照常可用。
            </div>
          ) : agents.map(a => {
            const isSelected = selectedAgentId === a.id;
            const isHover = hoverId === a.id;
            const isEditing = editingId === a.id;
            return (
              <div key={a.id} style={{ margin: '3px 0' }}>
                <div
                  onClick={() => onSelect(a.id)}
                  onMouseEnter={() => setHoverId(a.id)}
                  onMouseLeave={() => setHoverId(null)}
                  style={{
                    padding: '6px 10px',
                    borderRadius: isEditing ? `${radius.s}px ${radius.s}px 0 0` : radius.s,
                    cursor: 'pointer', display: 'flex', alignItems: 'center', gap: 6,
                    background: isSelected ? colors.bgCard : (isHover ? colors.bgHover : 'transparent'),
                    border: isSelected ? `1px solid ${colors.borderDefault}` : '1px solid transparent',
                    boxShadow: isSelected ? shadow.s : 'none',
                    transition: 'background-color .15s ease, border-color .15s ease',
                    userSelect: 'none',
                  }}>
                  <Icon name="bot" size={14} style={{ color: colors.accentText, flexShrink: 0 }} />
                  <span style={{ ...typo.body, fontSize: 13, fontWeight: isSelected ? 500 : 400, flex: 1, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                    {a.name}
                  </span>
                  {a.system_prompt && <Icon name="file-text" size={11} style={{ color: colors.accentText, flexShrink: 0 }} title="已设角色设定" />}
                  {/* 模型切换（无 model_name 也可选，兜底"默认"项） */}
                  {modelList.length > 0 && (
                    <select value={a.model_name || ''}
                      onClick={e => e.stopPropagation()}
                      onChange={e => { const v = e.target.value; if (v) { e.stopPropagation(); handleSwitchModel(a, v); } }}
                      title="切换该独立 Agent 的模型"
                      style={{ ...selectStyle, fontSize: 11, padding: '2px 4px', height: 22, maxWidth: 120 }}>
                      {!a.model_name && <option value="">默认</option>}
                      {modelList.map(m => <option key={m.name} value={m.name}>{m.name}</option>)}
                    </select>
                  )}
                  <button className="ui-btn ui-btn-ghost"
                    onClick={e => { e.stopPropagation(); setEditingId(a.id); setEditText(a.system_prompt || ''); }}
                    style={{ ...btnGhost, height: 22, padding: '0 4px', color: colors.textTertiary }} title="编辑角色设定">
                    <Icon name="pencil" size={14} />
                  </button>
                  <button className="ui-btn ui-btn-ghost ui-ico-danger"
                    onClick={e => { e.stopPropagation(); handleDelete(a); }}
                    style={{ ...btnGhost, height: 22, padding: '0 4px', color: colors.textTertiary }} title="删除独立 Agent">
                    <Icon name="trash" size={14} />
                  </button>
                </div>
                {/* 行内角色设定编辑区 */}
                {isEditing && (
                  <div style={{ background: colors.bgCard, padding: '8px 10px', borderRadius: `0 0 ${radius.m}px ${radius.m}px`, border: `1px solid ${colors.borderDefault}`, borderTop: 'none' }}>
                    <textarea value={editText} onChange={e => setEditText(e.target.value)}
                      placeholder="角色设定（system_prompt）：留空保存则清除"
                      rows={3} className="ui-input" style={{ ...textareaStyle, width: '100%', minWidth: 0, fontSize: 12 }} />
                    <div style={{ display: 'flex', gap: 6, marginTop: 6, justifyContent: 'flex-end' }}>
                      <button className="ui-btn ui-btn-secondary" onClick={() => setEditingId(null)}
                        style={{ ...btnSecondary, height: 24, padding: '0 10px', fontSize: 12 }}>取消</button>
                      <button className="ui-btn ui-btn-primary" onClick={() => savePrompt(a)} disabled={savingPrompt}
                        style={{ ...btnPrimary, height: 24, padding: '0 10px', fontSize: 12, opacity: savingPrompt ? 0.6 : 1 }}>
                        {savingPrompt ? <Spinner size={12} style={{ borderTopColor: colors.onAccent }} /> : '保存'}
                      </button>
                    </div>
                  </div>
                )}
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}
