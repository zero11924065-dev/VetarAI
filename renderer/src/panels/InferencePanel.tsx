/*
 * VetarAI - Local-first multi-agent orchestration application
 * Copyright (C) 2026 zero11924065-dev
 *
 * This file is part of VetarAI.
 *
 * VetarAI is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * VetarAI is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with VetarAI. If not, see <https://www.gnu.org/licenses/>.
 */
import { getApiBase } from '../apiBase';
import { apiJson } from '../lib/api';
import React, { useEffect, useState, useCallback } from 'react';
import { colors, fonts, radius, typo, cardL, btnPrimary, btnSecondary, input, calloutStyle } from '../theme';
import { Icon, Spinner } from '../Icon';
import { confirmDialog } from '../Dialog';
import { ModelOptionsEditor } from './ModelOptionsEditor';
import { on } from '../events';
import { APP_RESOURCE_CHANGED, AppResourceEvent } from '../appEvents';

// M6（TS-112）：推理面板
// - 状态区：当前后端 + 在线状态 + 测试连接
// - 后端配置区：后端单选 / 地址 / API Key / 工具开关（与设置面板同源）
// - 模型管理区：统一模型列表（活动后端模型 + 已启用模型包并存，按 model 名自动路由）+ 拉取/删除
//
// 0.4.30（W2）并行化：模型包不再是排他的「第三后端」。inference_backend 保持
// ollama/openai_compatible 时，对话按 model 名自动路由——model=模型包 pack_id
// 走模型包引擎（内置 llama.cpp），其它走活动后端。旧配置 inference_backend=
// model_package 的用户面板兼容显示（状态区仍可辨识，可点任一端卡切回）。

const API = getApiBase();

interface InferenceStatus {
  backend: string; base_url: string; online: boolean;
  detail: string; capabilities: { tools: boolean; vision: boolean; pull: boolean; delete: boolean };
}
interface ModelEntry { name: string; size?: number; context_length?: number;
  /** 0.4.30（W2）：来源标记——'model_pack' = 模型包（pack_id），其余/缺省 = 活动后端模型 */
  source?: string; }

export function InferencePanel() {
  const [status, setStatus] = useState<InferenceStatus | null>(null);
  const [models, setModels] = useState<ModelEntry[]>([]);
  const [cfg, setCfg] = useState<any>({});
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const [pullName, setPullName] = useState('');
  // 第 2 批（0.4.15）A2/A4：模型列表行点「参数」按钮 → 让下方编辑器展开该模型。
  // 不用「下拉选模型」的方式新增配置：那会把模型名再渲染一遍，与模型列表撞成
  // 两处同名文本，令 getByText('qwen3.8') 报 Found multiple elements。
  const [focusModel, setFocusModel] = useState<string | null>(null);

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

  // A13（0.4.22）：Agent/用户改推理配置（后端/地址/API Key/工具开关）后实时重拉。
  // 也响应 gap 对账。InferencePanel 只在设置页打开时挂载，订阅随挂载/卸载，无幽灵监听。
  useEffect(() => {
    const off = on(APP_RESOURCE_CHANGED, (ev: AppResourceEvent) => {
      if (!ev.gap && ev.resource !== 'inference') return;
      void refresh();
    });
    return off;
  }, [refresh]);

  const saveBackend = async (patch: any) => {
    setBusy(true); setMsg(null);
    try {
      const d = await apiJson(`/config`, {
        method: 'PUT', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ ...cfg, ...patch }),
      });
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
      const d = await apiJson(`/ollama/pull`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name: pullName.trim() }),
      });
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
      const d = await apiJson(`/ollama/models/${encodeURIComponent(name)}`, { method: 'DELETE' });
      setMsg(`已删除：${name}`);
      refresh();
    } catch (e) { setMsg('删除失败: ' + (e as Error).message); }
    finally { setBusy(false); setTimeout(() => setMsg(null), 3000); }
  };

  const backend = cfg.inference_backend || 'ollama';
  const isOllama = backend === 'ollama';
  // 0.4.29（P2）引入的模型包后端标记；0.4.30（W2）起仅作**旧配置兼容显示**：
  // 模型包已并入统一列表按 model 名并行路由，不再要求把后端切到 model_package。
  const isMP = backend === 'model_package';

  // 0.4.30（W2）：选中模型 → 只存 default_model（模型包即 pack_id），不动 inference_backend。
  // 模型包附带「换装编排」提示：对话时会暂停其它本地模型（同一时刻只跑一个本地大模型）。
  const selectDefaultModel = async (m: ModelEntry) => {
    await saveBackend({ default_model: m.name });
    setMsg(m.source === 'model_pack'
      ? `已选为默认模型：${m.name}（模型包对话时会暂停其它本地模型——换装编排）`
      : `已选为默认模型：${m.name}`);
  };

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
            background: status ? (status.online ? colors.ok : colors.danger) : colors.borderStrong,
          }} />
          <span style={{ fontSize: 14, fontWeight: 600, color: colors.textPrimary }}>
            {isOllama ? 'Ollama' : isMP ? '模型包' : 'OpenAI 兼容后端'}
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
            border: backend === 'openai_compatible' ? `2px solid ${colors.accent}` : `1px solid ${colors.borderDefault}`,
            borderRadius: radius.m,
            ...(backend === 'openai_compatible' ? { background: colors.accentBg } : {}),
          }}>
            <input type="radio" checked={backend === 'openai_compatible'}
              onChange={() => setCfg({ ...cfg, inference_backend: 'openai_compatible' })}
              style={{ marginTop: 2 }} />
            <div>
              <div style={{ fontSize: 13, fontWeight: 500, color: colors.textPrimary }}>OpenAI 兼容</div>
              <div style={{ fontSize: 12, color: colors.textTertiary, marginTop: 2 }}>第三方 API 或本地中转</div>
            </div>
          </label>
        </div>

        {/* 0.4.30（W2）旧配置兼容：inference_backend=model_package 的用户不炸——
            模型包已并入统一模型列表并行路由，提示其点任一端卡即可切回正常配置。 */}
        {isMP && (
          <div style={{ ...calloutStyle('info'), marginBottom: 12 }}>
            <Icon name="info" size={16} style={{ flexShrink: 0 }} />
            <span>当前为旧版「模型包后端」配置。模型包现已与后端模型并行可用（按模型名自动路由，
              对话时自动换装），点击上方 Ollama 或 OpenAI 兼容即可切回常规配置；模型包仍在「模型包」面板安装与管理。</span>
          </div>
        )}

        {/* 问题6修复（0.3.2实测）：Ollama 地址从"基础设置"挪到推理后端面板 */}
        {isOllama && (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 8, paddingLeft: 4, marginBottom: 12 }}>
            <label style={{ fontSize: 12, color: colors.textSecondary }}>Ollama 地址</label>
            <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
              <input className="ui-input" style={{ ...input, flex: 1 }}
                value={cfg.ollama_base_url || ''} placeholder="http://localhost:11434"
                onChange={e => setCfg({ ...cfg, ollama_base_url: e.target.value })} />
              <button className="ui-btn ui-btn-primary" style={smallPrimary}
                onClick={() => saveBackend({ ollama_base_url: cfg.ollama_base_url || '' })}
                disabled={busy}>
                {busy ? <Spinner size={12} /> : null}
                保存
              </button>
            </div>
            <div style={{ fontSize: 12, color: colors.textTertiary, lineHeight: 1.6 }}>
              本机默认 http://localhost:11434；Ollama 运行在其他机器或自定义端口时，改为对应地址。
            </div>
          </div>
        )}

        {/* openai_compatible 才需要地址/Key 表单；isMP（旧配置）无配置项——兼容提示已在上方略 */}

        {!isOllama && !isMP && (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 8, paddingLeft: 4 }}>
            {/* 问题7（0.3.2实测）：第三方启动器接入引导——LM Studio 等走 OpenAI 兼容 */}
            <div style={{ fontSize: 12, color: colors.textTertiary, lineHeight: 1.6 }}>
              适配 LM Studio、llama.cpp server、vLLM 等提供 OpenAI 兼容接口的启动器。
              LM Studio：先在应用内开启本地服务器（默认端口 1234），地址填
              <span style={{ fontFamily: fonts.mono }}> http://localhost:1234/v1</span>，然后点"保存并切换"。
            </div>
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

      {/* ===== 第 2 批（0.4.15）A1/A2/A4：推理参数与超时 ===== */}
      <div style={{ ...cardL, padding: '16px 20px' }}>
        <div style={{ ...typo.sectionTitle, color: colors.textPrimary, marginBottom: 12 }}>
          推理参数与超时
        </div>

        {/* A1：超时（0 = 用默认值）*/}
        <div style={{ fontSize: 13, color: colors.textPrimary, marginBottom: 8 }}>推理超时（秒，填 0 = 用默认值）</div>
        <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
          {([
            ['timeout_connect', '连接超时', 10],
            ['timeout_reading', '非流式读超时', 300],
            ['timeout_stream_reading', '流式读超时', 1800],
          ] as Array<[string, string, number]>).map(([key, label, dft]) => (
            <div key={key} style={{ flex: '1 1 150px', minWidth: 150 }}>
              <div style={{ fontSize: 12, color: colors.textSecondary, marginBottom: 4 }}>{label}</div>
              <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                <input className="ui-input" type="number" min={0}
                  style={{ ...input, flex: 1, fontFamily: fonts.mono }}
                  value={String(cfg[key] ?? 0)}
                  onChange={e => setCfg({ ...cfg, [key]: e.target.value === '' ? 0 : Number(e.target.value) })} />
                <button className="ui-btn ui-btn-secondary" style={smallSecondary} disabled={busy}
                  onClick={() => saveBackend({ [key]: Number(cfg[key] ?? 0) })}>保存</button>
              </div>
              <div style={{ fontSize: 11, color: colors.textTertiary, marginTop: 2 }}>默认 {dft}s</div>
            </div>
          ))}
        </div>
        <div style={{ fontSize: 12, color: colors.textTertiary, lineHeight: 1.6, marginTop: 8 }}>
          本地大参数模型（30B/35B）处理超长文本时，「非流式读超时」300s 可能偏紧——工作流推理节点走的就是它。
          流式（聊天）默认 1800s，覆盖思考间隙。
        </div>

        {/* 0.4.31（P2 懒加载，D2/D8）：模型缓存懒加载设置（Ollama 与模型包生效；
            OpenAI 兼容后端的上下文由服务端管理，此项不介入） */}
        <div style={{ fontSize: 13, color: colors.textPrimary, margin: '16px 0 8px' }}>模型缓存懒加载</div>
        <label style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 13,
          color: colors.textPrimary, cursor: 'pointer' }}>
          <input type="checkbox" checked={cfg.ctx_lazy_enabled !== false} disabled={busy}
            onChange={e => saveBackend({ ctx_lazy_enabled: e.target.checked })} />
          启用懒加载（上下文先以低档运行，膨胀时自动升档至 num_ctx 上限）
        </label>
        <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', marginTop: 8 }}>
          <div style={{ flex: '1 1 150px', minWidth: 150 }}>
            <div style={{ fontSize: 12, color: colors.textSecondary, marginBottom: 4 }}>起始档（首次加载的上下文档位）</div>
            <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
              <input className="ui-input" type="number" min={2048} max={1048576}
                style={{ ...input, flex: 1, fontFamily: fonts.mono }}
                value={String(cfg.ctx_lazy_start ?? 12288)}
                onChange={e => setCfg({ ...cfg, ctx_lazy_start: e.target.value === '' ? 12288 : Number(e.target.value) })} />
              <button className="ui-btn ui-btn-secondary" style={smallSecondary} disabled={busy}
                onClick={() => saveBackend({ ctx_lazy_start: Number(cfg.ctx_lazy_start ?? 12288) })}>保存</button>
            </div>
            <div style={{ fontSize: 11, color: colors.textTertiary, marginTop: 2 }}>默认 12288（2048~1048576）</div>
          </div>
        </div>
        <div style={{ fontSize: 12, color: colors.textTertiary, lineHeight: 1.6, marginTop: 4 }}>
          上限 = 下方按模型配置的 num_ctx；未配 num_ctx 的模型不受影响。仅 Ollama 与模型包生效。
        </div>

        {/* A2/A4：每模型推理参数 */}
        <div style={{ ...typo.sectionTitle, color: colors.textPrimary, margin: '20px 0 8px' }}>
          模型推理参数（按模型单独配置）
        </div>
        <ModelOptionsEditor cfg={cfg} busy={busy} onSave={saveBackend} isOllama={isOllama}
          isModelPackage={isMP} focus={focusModel} />
      </div>

      {/* 模型管理区 - 分区卡 */}
      <div style={{ ...cardL, padding: '16px 20px' }}>
        <div style={{ ...typo.sectionTitle, color: colors.textPrimary, marginBottom: 12 }}>
          模型列表（{models.length}）
        </div>
        <div style={{ maxHeight: 200, overflowY: 'auto', marginBottom: 12 }}>
          {models.length === 0 && (
            <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 8, padding: '20px 0' }}>
              <Icon name="cpu" size={36} style={{ color: colors.borderStrong }} />
              {/* 0.4.30（W2）：空态覆盖「后端离线/无模型/无已启用模型包」三种情况 */}
              <span style={{ fontSize: 13, color: colors.textTertiary }}>暂无可用模型（后端离线或未安装模型）</span>
              <span style={{ fontSize: 12, color: colors.textTertiary }}>模型包安装并启用后也会出现在此列表（在「模型包」面板管理）</span>
            </div>
          )}
          {models.map(m => (
            <div key={m.name} style={{
              display: 'flex', alignItems: 'center', gap: 8, padding: '5px 0',
              borderBottom: `1px solid ${colors.borderSubtle}`,
            }}>
              <span style={{ fontFamily: fonts.mono, fontSize: 13, color: colors.textPrimary }}>{m.name}</span>
              {/* 0.4.30（W2）：来源徽标——模型包与后端模型在统一列表中可辨 */}
              {m.source === 'model_pack' && (
                <span style={{
                  fontSize: 11, color: colors.accentText, background: colors.accentBg,
                  border: `1px solid ${colors.accent}`, borderRadius: radius.s, padding: '0 6px', flexShrink: 0,
                }}>模型包</span>
              )}
              <span style={{ flex: 1 }} />
              {typeof m.size === 'number' && m.size > 0 && (
                <span style={{ fontSize: 12, color: colors.textTertiary }}>{(m.size / 1e9).toFixed(1)}GB</span>
              )}
              {m.context_length && <span style={{ fontSize: 12, color: colors.textTertiary }}>ctx {m.context_length}</span>}
              {/* 0.4.30（W2）：选为默认模型——只存 default_model（模型包即 pack_id），
                  不动 inference_backend；对话按 model 名自动路由到模型包引擎或活动后端 */}
              {cfg.default_model === m.name ? (
                <span style={{ fontSize: 11, color: colors.ok, flexShrink: 0 }}>当前默认</span>
              ) : (
                <button className="ui-btn ui-btn-ghost"
                  data-tip={m.source === 'model_pack'
                    ? '选为默认模型（模型包对话时会暂停其它本地模型——换装编排）'
                    : '选为默认模型'}
                  style={{ ...btnSecondary, height: 22, padding: '0 8px', fontSize: 12, background: 'transparent', border: 'none', color: colors.textTertiary }}
                  onClick={() => void selectDefaultModel(m)}>
                  <Icon name="check" size={14} />
                  设为默认
                </button>
              )}
              {/* A2/A4（0.4.15）：就地配置该模型的推理参数。
                  按钮文案不含模型名，避免与行内模型名重复渲染（保 getByText 唯一性） */}
              <button className="ui-btn ui-btn-ghost"
                data-tip="配置该模型的 num_ctx / temperature 等推理参数"
                style={{ ...btnSecondary, height: 22, padding: '0 8px', fontSize: 12, background: 'transparent', border: 'none', color: (cfg.model_options || {})[m.name] ? colors.accent : colors.textTertiary }}
                onClick={() => {
                  const mo = { ...(cfg.model_options || {}) };
                  if (!mo[m.name]) mo[m.name] = {};
                  setFocusModel(m.name);
                  saveBackend({ model_options: mo });
                }}>
                <Icon name="sliders" size={14} />
                参数
              </button>
              {isOllama && m.source !== 'model_pack' && status?.capabilities?.delete && (
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
            <span>拉取/删除模型仅 Ollama 后端支持；OpenAI 兼容后端的模型请在其服务端管理，
              模型包的安装、启用与卸载请在「模型包」面板进行。</span>
          </div>
        )}
      </div>
    </div>
  );
}
