import { getApiBase } from '../apiBase';
import React, { useEffect, useState, useCallback } from 'react';
import { colors, fonts, radius, typo, cardL, btnPrimary, btnSecondary, input, calloutStyle } from '../theme';
import { Icon, Spinner } from '../Icon';
import { confirmDialog } from '../Dialog';

// M6（TS-112）：推理面板
// - 状态区：当前后端 + 在线状态 + 测试连接
// - 后端配置区：后端单选 / 地址 / API Key / 工具开关（与设置面板同源）
// - 模型管理区：ollama=列表+拉取+删除；openai_compatible=列表+提示

const API = getApiBase();

interface InferenceStatus {
  backend: string; base_url: string; online: boolean;
  detail: string; capabilities: { tools: boolean; vision: boolean; pull: boolean; delete: boolean };
}
interface ModelEntry { name: string; size?: number; context_length?: number; }

export function InferencePanel() {
  const [status, setStatus] = useState<InferenceStatus | null>(null);
  const [models, setModels] = useState<ModelEntry[]>([]);
  const [cfg, setCfg] = useState<any>({});
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const [pullName, setPullName] = useState('');

  const refresh = useCallback(async () => {
    try {
      const [st, md, cf] = await Promise.all([
        fetch(`${API}/inference/status`).then(r => r.ok ? r.json() : null),
        fetch(`${API}/inference/models`).then(r => r.ok ? r.json() : []).catch(() => []),
        fetch(`${API}/config`).then(r => r.ok ? r.json() : {}),
      ]);
      if (st) setStatus(st as InferenceStatus);
      setModels(Array.isArray(md) ? md as ModelEntry[] : []);
      setCfg(cf || {});
    } catch (e) { console.error('inference panel:', e); }
  }, []);
  useEffect(() => { refresh(); }, [refresh]);

  const saveBackend = async (patch: any) => {
    setBusy(true); setMsg(null);
    try {
      const res = await fetch(`${API}/config`, {
        method: 'PUT', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ ...cfg, ...patch }),
      });
      const d = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(d.detail || `HTTP ${res.status}`);
      setMsg('已保存 ✓');
      refresh();
    } catch (e) { setMsg('保存失败: ' + (e as Error).message); }
    finally { setBusy(false); setTimeout(() => setMsg(null), 3000); }
  };

  const doTestConnection = async () => {
    setBusy(true); setMsg('正在测试连接…');
    await refresh();
    setMsg(null); setBusy(false);
  };

  const doPull = async () => {
    if (!pullName.trim() || busy) return;
    setBusy(true); setMsg(`正在拉取 ${pullName} …（首次拉取可能较久）`);
    try {
      const res = await fetch(`${API}/ollama/pull`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name: pullName.trim() }),
      });
      const d = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(d.detail || `HTTP ${res.status}`);
      setMsg(`拉取完成：${pullName}`);
      setPullName('');
      refresh();
    } catch (e) { setMsg('拉取失败: ' + (e as Error).message); }
    finally { setBusy(false); setTimeout(() => setMsg(null), 5000); }
  };

  const doDelete = async (name: string) => {
    const ok = await confirmDialog({ title: '删除模型', message: `确认删除模型 ${name}？删除后需重新拉取才能使用。`, confirmText: '删除', danger: true });
    if (!ok) return;
    setBusy(true); setMsg(null);
    try {
      const res = await fetch(`${API}/ollama/models/${encodeURIComponent(name)}`, { method: 'DELETE' });
      const d = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(d.detail || `HTTP ${res.status}`);
      setMsg(`已删除：${name}`);
      refresh();
    } catch (e) { setMsg('删除失败: ' + (e as Error).message); }
    finally { setBusy(false); setTimeout(() => setMsg(null), 3000); }
  };

  const isOllama = (cfg.inference_backend || 'ollama') === 'ollama';

  // 小按钮样式覆盖
  const smallSecondary: React.CSSProperties = {
    ...btnSecondary, height: 22, padding: '0 8px', fontSize: 12,
  };
  const smallPrimary: React.CSSProperties = {
    ...btnPrimary, height: 22, padding: '0 8px', fontSize: 12,
  };

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 20 }}>
      {/* 标题 */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
        <Icon name="cpu" size={16} style={{ color: colors.textPrimary }} />
        <span style={{ ...typo.sectionTitle, color: colors.textPrimary }}>推理后端</span>
      </div>

      {/* 状态区 - 分区卡 */}
      <div style={{ ...cardL, padding: '16px 20px' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 8 }}>
          <span style={{
            width: 10, height: 10, borderRadius: '50%', flexShrink: 0,
            background: status ? (status.online ? colors.ok : colors.danger) : '#C9C9CF',
          }} />
          <span style={{ fontSize: 14, fontWeight: 600, color: colors.textPrimary }}>
            {isOllama ? 'Ollama' : 'OpenAI 兼容后端'}
            {status ? (status.online ? ' · 在线' : ' · 离线') : ''}
          </span>
          <button className="ui-btn ui-btn-secondary" style={smallSecondary}
            onClick={doTestConnection} disabled={busy}>
            {busy ? <Spinner size={12} /> : null}
            {busy ? '检测中…' : '测试连接'}
          </button>
        </div>
        {status && !status.online && status.detail && (
          <div style={{ ...calloutStyle('error'), marginTop: 4 }}>
            <Icon name="alert-triangle" size={16} style={{ flexShrink: 0 }} />
            <span style={{ wordBreak: 'break-word' }}>{status.detail}</span>
          </div>
        )}
        {msg && (
          <div style={{ ...calloutStyle(msg.includes('失败') ? 'error' : msg.includes('正在') ? 'info' : 'success'), marginTop: 8 }}>
            <Icon name={msg.includes('失败') ? 'alert-triangle' : msg.includes('正在') ? 'info' : 'check'} size={16} style={{ flexShrink: 0 }} />
            <span>{msg}</span>
          </div>
        )}
      </div>

      {/* 后端配置区 - 分区卡 */}
      <div style={{ ...cardL, padding: '16px 20px' }}>
        <div style={{ ...typo.sectionTitle, color: colors.textPrimary, marginBottom: 12 }}>后端选择</div>
        <div style={{ display: 'flex', gap: 12, marginBottom: 12 }}>
          {/* Ollama 选择卡 */}
          <label style={{
            flex: 1, display: 'flex', alignItems: 'flex-start', gap: 10, padding: 12,
            background: colors.bgCard, cursor: 'pointer',
            border: isOllama ? `2px solid ${colors.accent}` : `1px solid ${colors.borderDefault}`,
            borderRadius: radius.m,
            ...(isOllama ? { background: colors.accentBg } : {}),
          }}>
            <input type="radio" checked={isOllama}
              onChange={() => saveBackend({ inference_backend: 'ollama', inference_base_url: '' })}
              style={{ marginTop: 2 }} />
            <div>
              <div style={{ fontSize: 13, fontWeight: 500, color: colors.textPrimary }}>Ollama</div>
              <div style={{ fontSize: 12, color: colors.textTertiary, marginTop: 2 }}>本地运行，自动管理模型</div>
            </div>
          </label>
          {/* OpenAI 兼容选择卡 */}
          <label style={{
            flex: 1, display: 'flex', alignItems: 'flex-start', gap: 10, padding: 12,
            background: colors.bgCard, cursor: 'pointer',
            border: !isOllama ? `2px solid ${colors.accent}` : `1px solid ${colors.borderDefault}`,
            borderRadius: radius.m,
            ...(!isOllama ? { background: colors.accentBg } : {}),
          }}>
            <input type="radio" checked={!isOllama}
              onChange={() => setCfg({ ...cfg, inference_backend: 'openai_compatible' })}
              style={{ marginTop: 2 }} />
            <div>
              <div style={{ fontSize: 13, fontWeight: 500, color: colors.textPrimary }}>OpenAI 兼容</div>
              <div style={{ fontSize: 12, color: colors.textTertiary, marginTop: 2 }}>第三方 API 或本地中转</div>
            </div>
          </label>
        </div>

        {!isOllama && (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 8, paddingLeft: 4 }}>
            <input className="ui-input" style={{ ...input, width: '100%' }}
              value={cfg.inference_base_url || ''} placeholder="http://localhost:1234/v1"
              onChange={e => setCfg({ ...cfg, inference_base_url: e.target.value })} />
            <input className="ui-input" style={{ ...input, width: '100%' }} type="password"
              value={cfg.inference_api_key || ''} placeholder="API Key（可选，远程中转才需要）"
              onChange={e => setCfg({ ...cfg, inference_api_key: e.target.value })} />
            <label style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 13, color: colors.textPrimary }}>
              <input type="checkbox" checked={cfg.openai_compat_supports_tools !== false}
                onChange={e => setCfg({ ...cfg, openai_compat_supports_tools: e.target.checked })} />
              该后端支持工具调用（不支持请取消勾选）
            </label>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
              <button className="ui-btn ui-btn-primary" style={smallPrimary}
                onClick={() => saveBackend({
                  inference_backend: 'openai_compatible',
                  inference_base_url: cfg.inference_base_url || '',
                  inference_api_key: cfg.inference_api_key || '',
                  openai_compat_supports_tools: cfg.openai_compat_supports_tools !== false,
                })} disabled={busy || !(cfg.inference_base_url || '').trim()}>
                {busy ? <Spinner size={12} /> : null}
                保存并切换
              </button>
              {!((cfg.inference_base_url || '').trim()) && (
                <span style={{ fontSize: 12, color: colors.textTertiary }}>请先填写地址</span>
              )}
            </div>
          </div>
        )}
      </div>

      {/* 模型管理区 - 分区卡 */}
      <div style={{ ...cardL, padding: '16px 20px' }}>
        <div style={{ ...typo.sectionTitle, color: colors.textPrimary, marginBottom: 12 }}>
          模型列表（{models.length}）
        </div>
        <div style={{ maxHeight: 200, overflowY: 'auto', marginBottom: 12 }}>
          {models.length === 0 && (
            <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 8, padding: '20px 0' }}>
              <Icon name="cpu" size={36} style={{ color: '#C9C9CF' }} />
              <span style={{ fontSize: 13, color: colors.textTertiary }}>无模型或后端离线</span>
            </div>
          )}
          {models.map(m => (
            <div key={m.name} style={{
              display: 'flex', alignItems: 'center', gap: 8, padding: '5px 0',
              borderBottom: `1px solid ${colors.borderSubtle}`,
            }}>
              <span style={{ flex: 1, fontFamily: fonts.mono, fontSize: 13, color: colors.textPrimary }}>{m.name}</span>
              {typeof m.size === 'number' && m.size > 0 && (
                <span style={{ fontSize: 12, color: colors.textTertiary }}>{(m.size / 1e9).toFixed(1)}GB</span>
              )}
              {m.context_length && <span style={{ fontSize: 12, color: colors.textTertiary }}>ctx {m.context_length}</span>}
              {isOllama && status?.capabilities?.delete && (
                <button className="ui-btn ui-btn-ghost ui-ico-danger"
                  style={{ ...btnSecondary, height: 22, padding: '0 8px', fontSize: 12, background: 'transparent', border: 'none', color: colors.dangerText }}
                  onClick={() => doDelete(m.name)}>
                  <Icon name="trash" size={14} />
                  删除
                </button>
              )}
            </div>
          ))}
        </div>
        {isOllama ? (
          <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
            <input className="ui-input" style={{ ...input, flex: 1, fontFamily: fonts.mono }} value={pullName} placeholder="拉取模型，如 qwen2.5-vl"
              onChange={e => setPullName(e.target.value)} />
            <button className="ui-btn ui-btn-primary" style={smallPrimary}
              onClick={doPull} disabled={busy || !pullName.trim()}>
              {busy ? <Spinner size={12} /> : null}
              拉取
            </button>
          </div>
        ) : (
          <div style={calloutStyle('info')}>
            <Icon name="info" size={16} style={{ flexShrink: 0 }} />
            <span>拉取/删除模型仅 Ollama 后端支持；OpenAI 兼容后端的模型请在其服务端管理。</span>
          </div>
        )}
      </div>
    </div>
  );
}
