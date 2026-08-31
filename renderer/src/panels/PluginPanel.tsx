import { getApiBase } from '../apiBase';
import React, { useEffect, useState, useCallback } from 'react';
import { colors, fonts, radius, typo, cardL, btnPrimary, btnSecondary, btnDangerSoft, btnGhost, input, calloutStyle } from '../theme';
import { Icon, Spinner } from '../Icon';
import { confirmDialog } from '../Dialog';

interface Plugin {
  name: string;
  version?: string;
  entry_point?: string;
  hooks?: string[];
  path?: string;
  enabled?: boolean;  // checkpoint-047：逐项启用开关
}

const API = getApiBase();

export function PluginPanel({ onClose }: { onClose?: () => void }) {
  const [plugins, setPlugins] = useState<Plugin[]>([]);
  const [repoUrl, setRepoUrl] = useState('');
  const [loading, setLoading] = useState(false);
  const [installing, setInstalling] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [expandedHooks, setExpandedHooks] = useState<Record<string, boolean>>({});
  // checkpoint-049：手动触发钩子的运行态与输出（用户 2026-08-30 拍板：手动触发方案）
  const [runningHook, setRunningHook] = useState<string | null>(null); // key = `${plugin}|${hook}`
  const [hookOutputs, setHookOutputs] = useState<Record<string, { ok: boolean; text: string }>>({});

  const fetchPlugins = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const res = await fetch(`${API}/plugins`);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      if (Array.isArray(data)) setPlugins(data as Plugin[]);
    } catch (e: any) {
      setError('无法获取插件列表: ' + (e.message || '侧车未运行'));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { fetchPlugins(); }, [fetchPlugins]);

  async function handleInstall() {
    if (!repoUrl.trim()) return;
    setInstalling(true);
    setError(null);
    setNotice(null);
    try {
      const res = await fetch(`${API}/plugins/install`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ repo_url: repoUrl.trim() }),
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data.detail || `HTTP ${res.status}`);
      setNotice(`插件 "${data.name}" v${data.version || '?'} 安装成功`);
      setRepoUrl('');
      fetchPlugins();
    } catch (e: any) {
      setError('安装失败: ' + e.message);
    } finally {
      setInstalling(false);
    }
  }

  async function handleUninstall(name: string) {
    const ok = await confirmDialog({ title: '卸载插件', message: `确定卸载插件 "${name}"？`, confirmText: '卸载', danger: true });
    if (!ok) return;
    setError(null);
    setNotice(null);
    try {
      const res = await fetch(`${API}/plugins/${encodeURIComponent(name)}`, { method: 'DELETE' });
      if (!res.ok) {
        const d = await res.json();
        throw new Error(d.detail || `HTTP ${res.status}`);
      }
      setNotice(`插件 "${name}" 已卸载`);
      fetchPlugins();
    } catch (e: any) {
      setError('卸载失败: ' + e.message);
    }
  }

  function toggleHooks(name: string) {
    setExpandedHooks(prev => ({ ...prev, [name]: !prev[name] }));
  }

  // checkpoint-052：插件逐项启用/禁用开关（用户要求合并到插件列表项旁）
  async function handleToggleEnabled(name: string, currentEnabled: boolean) {
    setError(null);
    setNotice(null);
    try {
      const res = await fetch(`${API}/plugins/${encodeURIComponent(name)}/toggle`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ enabled: !currentEnabled }),
      });
      if (!res.ok) {
        const d = await res.json().catch(() => ({}));
        throw new Error(d.detail || `HTTP ${res.status}`);
      }
      setPlugins(prev => prev.map(p => p.name === name ? { ...p, enabled: !currentEnabled } : p));
      setNotice(`插件 "${name}" 已${!currentEnabled ? '启用' : '禁用'}`);
    } catch (e: any) {
      setError('切换失败: ' + e.message);
    }
  }

  // checkpoint-049：手动触发钩子（后端端点早已存在；禁用的插件由后端拒绝并提示）
  async function handleTriggerHook(pluginName: string, hookName: string) {
    const key = `${pluginName}|${hookName}`;
    if (runningHook) return;
    setRunningHook(key);
    setHookOutputs(prev => {
      const next = { ...prev };
      delete next[key];
      return next;
    });
    try {
      const res = await fetch(
        `${API}/plugins/${encodeURIComponent(pluginName)}/hooks/${encodeURIComponent(hookName)}`,
        {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ agent_context: { trigger: 'manual', source: 'plugin_panel' } }),
        });
      const d = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(d.detail || `HTTP ${res.status}`);
      if (d.error) {
        setHookOutputs(prev => ({ ...prev, [key]: { ok: false, text: `执行出错：${d.error}` } }));
      } else {
        const text = d.result === undefined ? '（无返回值）'
          : (typeof d.result === 'string' ? d.result : JSON.stringify(d.result, null, 2));
        setHookOutputs(prev => ({ ...prev, [key]: { ok: true, text } }));
      }
    } catch (e: any) {
      setHookOutputs(prev => ({ ...prev, [key]: { ok: false, text: `触发失败：${e.message}` } }));
    } finally {
      setRunningHook(null);
    }
  }

  // 小按钮样式覆盖
  const smallBtn = (base: React.CSSProperties): React.CSSProperties => ({
    ...base, height: 22, padding: '0 8px', fontSize: 12,
  });

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 20 }}>
      {/* 标题行 */}
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <Icon name="plug" size={16} style={{ color: colors.textPrimary }} />
          <span style={{ ...typo.sectionTitle, color: colors.textPrimary }}>插件管理</span>
        </div>
        {onClose && (
          <button className="ui-btn ui-btn-ghost" style={btnGhost} onClick={onClose}>
            <Icon name="x" size={14} />
          </button>
        )}
      </div>

      {/* 错误提示条 */}
      {error && (
        <div style={calloutStyle('error')}>
          <Icon name="alert-triangle" size={16} style={{ flexShrink: 0 }} />
          <span>{error}</span>
        </div>
      )}
      {/* 成功提示条 */}
      {notice && (
        <div style={calloutStyle('success')}>
          <Icon name="check" size={16} style={{ flexShrink: 0 }} />
          <span>{notice}</span>
        </div>
      )}

      {/* 安装区 - 分区卡 */}
      <div style={{ ...cardL, padding: '16px 20px' }}>
        <div style={{ ...typo.sectionTitle, color: colors.textPrimary, marginBottom: 12 }}>安装插件</div>
        <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
          <input
            value={repoUrl}
            onChange={e => setRepoUrl(e.target.value)}
            onKeyDown={e => e.key === 'Enter' && !e.nativeEvent.isComposing && e.keyCode !== 229 && handleInstall()}
            placeholder="https://github.com/owner/repo 或本地路径"
            className="ui-input"
            style={{ ...input, flex: 1, fontFamily: fonts.mono, fontSize: 13 }}
          />
          <button
            className="ui-btn ui-btn-primary"
            style={{ ...btnPrimary, ...(installing || !repoUrl.trim() ? {} : {}) }}
            onClick={handleInstall}
            disabled={installing || !repoUrl.trim()}
          >
            {installing ? <Spinner size={14} /> : <Icon name="plus" size={14} />}
            {installing ? '安装中...' : '安装'}
          </button>
        </div>
      </div>

      {/* 插件列表 - 分区卡 */}
      <div style={{ ...cardL, padding: '16px 20px' }}>
        <div style={{ ...typo.sectionTitle, color: colors.textPrimary, marginBottom: 12 }}>插件列表</div>

        {loading ? (
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8, padding: '24px 0' }}>
            <Spinner size={20} />
            <span style={{ ...typo.caption, color: colors.textTertiary }}>加载中…</span>
          </div>
        ) : plugins.length === 0 ? (
          <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 8, padding: '24px 0' }}>
            <Icon name="plug" size={36} style={{ color: '#C9C9CF' }} />
            <span style={{ fontSize: 13, color: colors.textTertiary }}>暂无插件。在上方输入 GitHub 仓库地址安装。</span>
          </div>
        ) : (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
            {plugins.map(p => {
              const disabled = p.enabled === false;
              return (
                <div key={p.name} style={{
                  background: colors.bgCard, border: `1px solid ${colors.borderDefault}`,
                  borderRadius: radius.m, padding: 12, opacity: disabled ? 0.7 : 1,
                }}>
                  <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                    <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
                      <span style={{ fontSize: 13, fontWeight: 500, color: disabled ? colors.textTertiary : colors.textPrimary }}>{p.name}</span>
                      {p.version && <span style={{ fontSize: 12, fontFamily: fonts.mono, color: colors.textTertiary }}>v{p.version}</span>}
                      {/* checkpoint-052：逐项启用/禁用开关 */}
                      <button
                        className="ui-btn ui-btn-ghost"
                        style={{
                          ...smallBtn(btnGhost),
                          background: disabled ? '#ECECEE' : colors.accentBg,
                          color: disabled ? colors.textSecondary : colors.accentText,
                        }}
                        onClick={() => handleToggleEnabled(p.name, !disabled)}
                        title={disabled ? '点击启用此插件' : '点击禁用此插件'}
                      >
                        {disabled ? '启用' : '禁用'}
                      </button>
                    </div>
                    <button
                      className="ui-btn ui-btn-danger-soft"
                      style={smallBtn(btnDangerSoft)}
                      onClick={() => handleUninstall(p.name)}
                    >
                      <Icon name="trash" size={14} />
                      卸载
                    </button>
                  </div>

                  {p.hooks && p.hooks.length > 0 ? (
                    <div style={{ marginTop: 8 }}>
                      <button
                        className="ui-btn ui-btn-ghost"
                        style={{ ...btnGhost, height: 22, padding: '0 4px', fontSize: 12, color: colors.textTertiary }}
                        onClick={() => toggleHooks(p.name)}
                      >
                        <Icon name={expandedHooks[p.name] ? 'chevron-up' : 'chevron-down'} size={14} />
                        Hooks ({p.hooks.length})
                      </button>
                      {expandedHooks[p.name] && (
                        <div style={{ marginTop: 6, paddingLeft: 8 }}>
                          {p.hooks.map(h => {
                            const key = `${p.name}|${h}`;
                            const out = hookOutputs[key];
                            const busy = runningHook === key;
                            return (
                              <div key={h} style={{ fontSize: 12, color: colors.textSecondary, padding: '4px 0', borderBottom: `1px solid ${colors.borderSubtle}` }}>
                                <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                                  <code style={{
                                    background: colors.bgCode, padding: '1px 6px', borderRadius: radius.s,
                                    fontFamily: fonts.mono, fontSize: 12, color: colors.textPrimary,
                                  }}>{h}</code>
                                  <button
                                    className="ui-btn ui-btn-secondary"
                                    style={smallBtn(btnSecondary)}
                                    onClick={() => handleTriggerHook(p.name, h)}
                                    disabled={disabled || runningHook !== null}
                                    title={disabled ? '插件已禁用，无法触发' : '手动触发此钩子'}
                                  >
                                    {busy ? <Spinner size={12} /> : <Icon name="play" size={14} />}
                                    {busy ? '执行中…' : '触发'}
                                  </button>
                                </div>
                                {out && (
                                  <pre style={{
                                    margin: '4px 0 2px', padding: '8px 10px', borderRadius: radius.s, fontSize: 11,
                                    whiteSpace: 'pre-wrap', wordBreak: 'break-word', maxHeight: 160, overflowY: 'auto',
                                    background: colors.bgCode, fontFamily: fonts.mono,
                                    color: out.ok ? colors.okText : colors.dangerText,
                                  }}>
                                    {out.text}
                                  </pre>
                                )}
                              </div>
                            );
                          })}
                          <div style={{ fontSize: 11, color: colors.textTertiary, marginTop: 6 }}>
                            Hook 触发方式：手动触发——点击每个钩子的"触发"，执行结果展示在下方。
                          </div>
                        </div>
                      )}
                    </div>
                  ) : (
                    <div style={{ marginTop: 6, fontSize: 11, color: colors.textTertiary }}>（该插件未声明钩子）</div>
                  )}
                </div>
              );
            })}
          </div>
        )}
      </div>

      {/* 说明 - 分区卡 */}
      <div style={{ ...cardL, padding: '16px 20px' }}>
        <div style={{ fontSize: 12, color: colors.textTertiary, lineHeight: 1.6 }}>
          <strong>插件格式：</strong>仓库需包含 <code style={{ fontFamily: fonts.mono, background: colors.bgInlineCode, padding: '0 4px', borderRadius: 3 }}>manifest.json</code>（name, version, entry_point, hooks）和入口文件（默认 <code style={{ fontFamily: fonts.mono, background: colors.bgInlineCode, padding: '0 4px', borderRadius: 3 }}>plugin.py</code>）。
          Hook 函数签名：<code style={{ fontFamily: fonts.mono, background: colors.bgInlineCode, padding: '0 4px', borderRadius: 3 }}>def hook_name(context: dict) -&gt; dict</code>。
          钩子采用手动触发（展开 Hooks → 触发）；启用/禁用开关在每个插件名称旁。
        </div>
      </div>
    </div>
  );
}
