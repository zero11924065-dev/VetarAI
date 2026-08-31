import { getApiBase } from '../apiBase';
import React, { useEffect, useState } from 'react';
import { colors, fonts, radius, shadow, typo, btnPrimary, btnSecondary, btnGhost, input, calloutStyle } from '../theme';
import { Icon, Spinner } from '../Icon';
import { confirmDialog } from '../Dialog';

interface Project { id: string; name: string; working_dir: string; }

const API = getApiBase();

export function ProjectPanel({ onSelect, onProjectDeleted, selectedProjectId }: {
  onSelect: (id: string) => void; onProjectDeleted?: (id: string) => void;
  /** checkpoint-057：外部（独立 Agent 面板）切项目时同步内部高亮 */
  selectedProjectId?: string | null;
}) {
  const [projects, setProjects] = useState<Project[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // 手动目录输入模式（非 Electron / preload 未注入时的 fallback，替代被废弃的 prompt()）
  const [manualMode, setManualMode] = useState(false);
  const [manualPath, setManualPath] = useState('');
  // M5（TS-111）：项目改名行内编辑（后端 PUT /api/projects/{id} 已存在）
  const [renamingId, setRenamingId] = useState<string | null>(null);
  const [renameValue, setRenameValue] = useState('');
  const [hoverId, setHoverId] = useState<string | null>(null);
  const [selectedId, setSelectedId] = useState<string | null>(null);

  // checkpoint-057：外部切换项目（如从独立 Agent 面板联动）时同步高亮
  useEffect(() => { setSelectedId(selectedProjectId ?? null); }, [selectedProjectId]);

  async function fetchProjects() {
    setError(null);
    try {
      const res = await fetch(`${API}/projects`);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      if (Array.isArray(data)) setProjects(data as Project[]);
      return true;
    } catch (e: any) {
      setError('无法连接侧车，请确保 Python sidecar 正在运行');
      console.error('Fetch projects failed:', e);
      return false;
    }
  }

  // checkpoint-064：封装后侧车是独立二进制，首启需数秒；首屏加载做退避重试
  // （最多 ~30s），避免"前端先于侧车就绪"导致的永久连接错误提示。
  useEffect(() => {
    let cancelled = false;
    const delays = [0, 800, 1500, 2500, 3500, 5000]; // 渐进退避
    (async () => {
      for (let i = 0; i < delays.length; i++) {
        if (cancelled) return;
        if (delays[i] > 0) {
          setError(`正在连接侧车…（第 ${i} 次，侧车启动中）`);
          await new Promise(r => setTimeout(r, delays[i]));
          if (cancelled) return;
        }
        const ok = await fetchProjects();
        if (ok) { setError(null); return; }
      }
      // 全部重试失败：保留最后的错误提示，附手动重试入口（由错误条的"重试"触发）
    })();
    return () => { cancelled = true; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // 返回: 'electron' = 在 Electron 内；'browser' = 纯浏览器
  // TS-103 B03：改为检测 preload 注入的 window.subagent（渲染进程已无 Node 能力）
  function env(): 'electron' | 'browser' {
    const w = window as any;
    return (w?.subagent?.chooseWorkingDir) ? 'electron' : 'browser';
  }

  // Electron：弹原生目录选择器。返回 { dir } 或 { canceled }。
  async function pickWorkingDirElectron(): Promise<{ dir?: string; canceled?: boolean }> {
    const w = window as any;
    try {
      const dir = await w.subagent.chooseWorkingDir();
      if (dir) return { dir };
      return { canceled: true };      // 用户在原生对话框点了取消
    } catch (e) {
      console.error('Electron 目录选择器不可用', e);
      return { canceled: true };
    }
  }

  async function handleCreate() {
    if (loading || error) return;
    setLoading(true);
    setError(null);
    try {
      // B3：工作目录由用户选择
      let working_dir: string;
      if (env() === 'electron') {
        // Electron 环境：原生目录选择器；取消 = 直接取消创建（不回退 prompt）
        const r = await pickWorkingDirElectron();
        if (r.canceled || !r.dir) { setLoading(false); return; }
        working_dir = r.dir;
      } else {
        // 非 Electron 环境（或主进程过旧、preload 未生效）：
        // 优先经侧车弹原生"选择文件夹"对话框（2026-08-28 新增端点）；
        // 端点不可用（非 macOS / 侧车不支持）才降级到内联手动输入。
        setLoading(false);
        try {
          const r = await fetch(`${API}/dialog/choose-dir`, { method: 'POST' });
          if (r.ok) {
            const d = await r.json();
            if (d.canceled) return;            // 用户点了取消
            if (d.dir) { await createWithDir(d.dir); return; }
          }
        } catch (err) { console.error('choose-dir fallback:', err); }
        setManualMode(true);
        return;
      }
      await createWithDir(working_dir);
    } catch (e: any) {
      setError('创建失败: ' + e.message);
      console.error('Create failed:', e);
    }
    setLoading(false);
  }

  // 用指定目录创建项目（内联输入确认 / Electron 分支共用）
  async function createWithDir(working_dir: string) {
    setLoading(true);
    setError(null);
    try {
      const res = await fetch(`${API}/projects`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name: `项目 ${projects.length + 1}`, working_dir }),
      });
      if (!res.ok) {
        const d = await res.json().catch(() => ({}));
        throw new Error(d.detail || `HTTP ${res.status}`);
      }
      const data = await res.json();
      console.log('Created project:', data);
      setManualMode(false);
      setManualPath('');
      fetchProjects();
    } catch (e: any) {
      setError('创建失败: ' + e.message);
      console.error('Create failed:', e);
    }
    setLoading(false);
  }

  async function handleCreateManual() {
    const t = manualPath.trim();
    if (!t) { setManualMode(false); return; }  // 留空 = 取消
    await createWithDir(t);
  }

  async function handleDelete(id: string, name: string) {
    // M6（TS-112）B8：删除项目确认弹窗（工作目录文件不受影响，仅删项目记录与对话数据）
    const ok = await confirmDialog({
      title: '删除项目',
      message: `删除项目「${name}」将删除其项目记录与全部对话/Agent/任务数据；你的工作目录中的文件不受影响。删除后不可恢复，确认？`,
      confirmText: '删除',
      cancelText: '取消',
      danger: true,
    });
    if (!ok) return;
    try {
      await fetch(`${API}/projects/${id}`, { method: 'DELETE' });
      // checkpoint-056：删除成功后立即通知父级重置选中态——否则界面停留在"幽灵项目"，
      // 用户可继续在其上创建 Agent/发消息，后端查无项目报 422
      onProjectDeleted?.(id);
      fetchProjects();
    } catch (e: any) { console.error('Delete failed:', e); }
  }

  // M5（TS-111）：保存改名（空名拒绝；成功后刷新列表并退出编辑态）
  async function saveRename(id: string) {
    const name = renameValue.trim();
    if (!name) { setRenamingId(null); return; }  // 空名不请求，直接取消
    try {
      const res = await fetch(`${API}/projects/${id}`, {
        method: 'PUT', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name }),
      });
      if (!res.ok) {
        const d = await res.json().catch(() => ({}));
        setError('改名失败: ' + (d.detail || `HTTP ${res.status}`));
      }
    } catch (e: any) { setError('改名失败: ' + e.message); }
    setRenamingId(null);
    setRenameValue('');
    fetchProjects();
  }

  return (
    /* checkpoint-057b：面板瘦身——外层不再 flex:1 撑满（避免把下方 Agent 区挤到底部），
       列表区独立滚动（maxHeight 限高），整体紧凑：小内边距、窄行距 */
    <div style={{ padding: 8, borderBottom: `1px solid ${colors.borderSubtle}`, flexShrink: 0, fontFamily: fonts.base }}>
      {/* 面板标题行 */}
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 6, paddingBottom: 6, borderBottom: `1px solid ${colors.borderSubtle}` }}>
        <span style={typo.panelTitle}>项目</span>
        <button
          className="ui-btn ui-btn-ghost"
          style={{ ...btnGhost, height: 22, padding: '0 8px', fontSize: 12, gap: 4 }}
          onClick={(e) => { e.preventDefault(); console.log('Button clicked!'); handleCreate(); }}
          disabled={loading || !!error}
        >
          {loading ? <Spinner size={12} /> : <Icon name="plus" size={14} />}
          新建项目
        </button>
      </div>

      {/* 错误提示条（checkpoint-064：附手动重试） */}
      {error && (
        <div style={{ ...calloutStyle('error'), marginBottom: 8 }}>
          <Icon name="alert-circle" size={16} style={{ flexShrink: 0, marginTop: 2 }} />
          <span style={{ flex: 1 }}>{error}</span>
          {error.includes('无法连接') && (
            <button
              className="ui-btn ui-btn-secondary"
              onClick={() => { fetchProjects(); }}
              style={{ ...btnSecondary, height: 24, padding: '0 10px', fontSize: 12, flexShrink: 0 }}
            >
              <Icon name="rotate-cw" size={13} />
              重试
            </button>
          )}
        </div>
      )}

      {/* 手动输入工作目录（内联 fallback，任何环境可用） */}
      {manualMode && (
        <div style={{ marginTop: 8, background: colors.bgCard, padding: '8px 10px', borderRadius: radius.m, border: `1px solid ${colors.borderDefault}`, marginBottom: 8 }}>
          <div style={{ fontSize: 12, color: colors.textSecondary, marginBottom: 6 }}>
            请输入项目工作目录的绝对路径（留空取消）：
          </div>
          <div style={{ display: 'flex', gap: 6 }}>
            <input value={manualPath} onChange={e => setManualPath(e.target.value)}
              onKeyDown={e => e.key === 'Enter' && !e.nativeEvent.isComposing && e.keyCode !== 229 && handleCreateManual()}
              placeholder="/Users/you/projects/demo"
              autoFocus
              className="ui-input"
              style={{ ...input, flex: 1, height: 28, fontSize: 12 }} />
            <button className="ui-btn ui-btn-primary" style={{ ...btnPrimary, height: 28, padding: '0 10px', fontSize: 12 }} onClick={handleCreateManual}>确定</button>
            <button className="ui-btn ui-btn-secondary" style={{ ...btnSecondary, height: 28, padding: '0 10px', fontSize: 12 }} onClick={() => { setManualMode(false); setManualPath(''); }}>取消</button>
          </div>
        </div>
      )}

      {/* 项目列表：独立滚动区（限高 30vh），项目再多也不撑开面板挤压下方 */}
      <div style={{ marginTop: 4, maxHeight: '30vh', overflowY: 'auto' }}>
        {projects.length === 0 && !error && !loading ? (
          /* 空态 */
          <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', padding: '24px 0', gap: 8 }}>
            <Icon name="folder" size={36} style={{ color: '#C9C9CF' }} />
            <span style={{ fontSize: 13, color: colors.textTertiary }}>暂无项目，点击上方按钮创建</span>
          </div>
        ) : loading && projects.length === 0 ? (
          /* 加载中 */
          <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', padding: '24px 0', gap: 8 }}>
            <Spinner size={20} />
            <span style={{ fontSize: 12, color: colors.textTertiary }}>加载中…</span>
          </div>
        ) : projects.map(p => {
          const isSelected = selectedId === p.id;
          const isHover = hoverId === p.id;
          const isRenaming = renamingId === p.id;
          return (
            <div key={p.id}
              onClick={() => { if (!isRenaming) { setSelectedId(p.id); onSelect(p.id); } }}
              onMouseEnter={() => setHoverId(p.id)}
              onMouseLeave={() => setHoverId(null)}
              style={{
                padding: '8px 10px', margin: '4px 0', borderRadius: radius.s,
                cursor: 'pointer', display: 'flex', justifyContent: 'space-between', alignItems: 'center',
                background: isSelected ? colors.bgCard : (isHover ? colors.bgHover : 'transparent'),
                border: isSelected ? `1px solid ${colors.borderDefault}` : '1px solid transparent',
                boxShadow: isSelected ? shadow.s : 'none',
                transition: 'background-color .15s ease, border-color .15s ease',
              }}>
              {isRenaming ? (
                /* M5（TS-111）：行内改名编辑框 */
                <div style={{ display: 'flex', gap: 6, alignItems: 'center', flex: 1 }}>
                  <input value={renameValue} autoFocus
                    onChange={e => setRenameValue(e.target.value)}
                    onClick={e => e.stopPropagation()}
                    onKeyDown={e => {
                      if (e.key === 'Enter' && !e.nativeEvent.isComposing && e.keyCode !== 229) saveRename(p.id);
                      if (e.key === 'Escape') { setRenamingId(null); setRenameValue(''); }
                    }}
                    className="ui-input"
                    style={{ ...input, flex: 1, height: 26, fontSize: 12 }} />
                  <button className="ui-btn ui-btn-primary" onClick={e => { e.stopPropagation(); saveRename(p.id); }}
                    style={{ ...btnPrimary, height: 22, padding: '0 8px', fontSize: 12 }}>保存</button>
                  <button className="ui-btn ui-btn-secondary" onClick={e => { e.stopPropagation(); setRenamingId(null); setRenameValue(''); }}
                    style={{ ...btnSecondary, height: 22, padding: '0 8px', fontSize: 12 }}>取消</button>
                </div>
              ) : (
                <>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 6, minWidth: 0, flex: 1 }}>
                    <Icon name="folder" size={16} style={{ color: colors.textTertiary, flexShrink: 0 }} />
                    <span style={{ ...typo.body, fontWeight: isSelected ? 500 : 400, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{p.name}</span>
                  </div>
                  <span style={{ display: 'flex', alignItems: 'center', gap: 2, opacity: isHover ? 1 : 0, transition: 'opacity .15s ease' }}>
                    <button title="重命名"
                      className="ui-btn ui-btn-ghost"
                      onClick={e => { e.stopPropagation(); setRenamingId(p.id); setRenameValue(p.name); }}
                      style={{ ...btnGhost, height: 22, padding: '0 4px', color: colors.textTertiary }}>
                      <Icon name="pencil" size={14} />
                    </button>
                    <button title="删除"
                      className="ui-btn ui-btn-ghost ui-ico-danger"
                      onClick={e => { e.stopPropagation(); handleDelete(p.id, p.name); }}
                      style={{ ...btnGhost, height: 22, padding: '0 4px', color: colors.textTertiary }}>
                      <Icon name="trash" size={14} />
                    </button>
                  </span>
                </>
              )}
            </div>
          );
        })}
      </div>
    </div>
  );
}
