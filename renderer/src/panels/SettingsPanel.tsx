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
import { getApiBase, setApiBase, getInjected } from '../apiBase';
import React, { useEffect, useState } from 'react';
import { colors, fonts, radius, typo, cardL, btnPrimary, btnSecondary, input, select, calloutStyle } from '../theme';
import { Icon } from '../Icon';
import { alertDialog } from '../Dialog';

interface Config {
  ollama_base_url: string;
  proxy_http_port: number;
  proxy_socks_port: number;
  data_root: string;
  default_model: string;
  plugin_repos: string[];
  egress_allowlist: string[];
  sidecar_host: string;
  sidecar_port: number;
  vite_port: number;
  network_switch: 'auto' | 'proxy' | 'on' | 'off';
  max_tool_rounds: number;
  compact_archive_dir: string;
  allow_auto_compact: boolean;
  compact_keep_recent: number;
  auto_create_sub_agents?: boolean;
  reconnect_max_attempts?: number;   // M5（TS-111）：断线重连最大次数
  heartbeat_interval?: number;       // M5（TS-111）：SSE 心跳基础间隔秒
  // M6（TS-112）：推理后端抽象
  inference_backend?: 'ollama' | 'openai_compatible';
  inference_base_url?: string;
  inference_api_key?: string;
  openai_compat_supports_tools?: boolean;
  // M7（TS-113）：体验与契约增强
  default_export_dir?: string;
  vision_parse_attachments?: boolean;
  // checkpoint-067b D-4：大模型并行 + 任务并发开关（两个独立布尔开关）
  model_parallel?: boolean;
  task_concurrency?: boolean;
}

// M2 压缩记录展示
function CompactLogSection() {
  const [logs, setLogs] = useState<any[] | null>(null);
  const api = getApiBase();

  useEffect(() => {
    // 从 localStorage 读当前 sessionId（简化：直接读最近一个）
    try {
      const stored = localStorage.getItem('subagent_current_session');
      if (stored) {
        fetch(`${api}/sessions/${stored}/compact_log?project_id=global`)
          .then(r => r.json())
          .then(d => setLogs(d.logs || []))
          .catch(() => setLogs([]));
      } else {
        setLogs([]);
      }
    } catch { setLogs([]); }
  }, []);

  if (logs === null) return null;
  if (logs.length === 0) return <div style={{ ...typo.micro, marginTop: 8 }}>暂无压缩记录</div>;
  return (
    <div style={{ marginTop: 10 }}>
      <div style={{ ...typo.caption, color: colors.textTertiary, marginBottom: 4 }}>最近压缩记录</div>
      {logs.map((l: any, i: number) => (
        <div key={i} style={{ ...typo.micro, marginBottom: 3, lineHeight: 1.5 }}>
          {l.ts} · {l.before_tokens}→{l.after_tokens} tok · {l.archive_path || '无归档'}
          {l.error && <span style={{ color: colors.dangerText }}> · {l.error}</span>}
        </div>
      ))}
    </div>
  );
}

/** 分区卡容器样式（§8.14 内容分区卡通用） */
const sectionCard: React.CSSProperties = {
  ...cardL,
  padding: '16px 20px',
};

/** 分区标题样式 */
const sectionTitle: React.CSSProperties = {
  ...typo.sectionTitle,
  color: colors.textPrimary,
  marginBottom: 12,
};

/** 表单标签样式 */
const formLabel: React.CSSProperties = {
  display: 'block',
  fontSize: 12, fontWeight: 400, lineHeight: 1.5,
  color: colors.textSecondary,
  margin: '10px 0 3px',
  fontFamily: fonts.base,
};

/** 输入框样式（带 ui-input class 以支持焦点伪类） */
const inpStyle: React.CSSProperties = {
  ...input,
  width: '100%',
};

/** 提示文字样式 */
const hintStyle: React.CSSProperties = {
  ...typo.micro,
  marginTop: 3,
};

export function SettingsPanel({ onClose, embedded, onOpenLogs, onOpenDataDir }: { onClose?: () => void; embedded?: boolean; onOpenLogs?: () => void; onOpenDataDir?: () => void }) {
  const [cfg, setCfg] = useState<Config | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [newRepo, setNewRepo] = useState('');
  const [newAllow, setNewAllow] = useState('');
  // checkpoint-053：默认模型下拉选择——拉取当前推理后端可用模型列表
  const [modelOptions, setModelOptions] = useState<string[]>([]);
  const [modelsLoading, setModelsLoading] = useState(false);
  const api = getApiBase();

  async function loadModels() {
    setModelsLoading(true);
    try {
      const r = await fetch(`${api}/inference/models`);
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      const data = await r.json();
      if (Array.isArray(data)) {
        setModelOptions(data.map((m: any) => m.name).filter(Boolean));
      }
    } catch (e) {
      setModelOptions([]); // 拉取失败 → 回退手动输入
    } finally {
      setModelsLoading(false);
    }
  }

  async function load() {
    setErr(null);
    try {
      const r = await fetch(`${api}/config`);
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      setCfg(await r.json());
    } catch (e: any) {
      setErr('读取配置失败（侧车未运行？）: ' + e.message);
    }
  }

  useEffect(() => { load(); loadModels(); }, []);

  async function save(patch: Partial<Config>) {
    setMsg(null); setErr(null);
    try {
      const r = await fetch(`${api}/config`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(patch),
      });
      const data = await r.json();
      if (!r.ok) throw new Error(data.detail || `HTTP ${r.status}`);
      setCfg(data);
      // 如果 sidecar host/port 变了，同步前端的 api base
      if (patch.sidecar_host || patch.sidecar_port) {
        const host = patch.sidecar_host || data.sidecar_host;
        const port = patch.sidecar_port || data.sidecar_port;
        setApiBase(`http://${host}:${port}/api`);
      }
      setMsg('已保存（端口类改动需重启应用生效）');
    } catch (e: any) {
      setErr(e.message);
    }
  }

  async function addRepo() {
    if (!cfg || !newRepo.trim()) return;
    save({ plugin_repos: [...(cfg.plugin_repos || []), newRepo.trim()] });
    setNewRepo('');
  }
  function removeRepo(url: string) {
    if (!cfg) return;
    save({ plugin_repos: (cfg.plugin_repos || []).filter(x => x !== url) });
  }
  async function addAllow() {
    if (!cfg || !newAllow.trim()) return;
    setMsg(null); setErr(null);
    const v = newAllow.trim();
    try {
      const r = await fetch(`${api}/config`, {
        method: 'PUT', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ egress_allowlist: [...(cfg.egress_allowlist || []), v] }),
      });
      const data = await r.json();
      if (!r.ok) throw new Error(data.detail || `HTTP ${r.status}`);
      setCfg(data); setNewAllow('');
      setMsg('已加入放行名单');
    } catch (e: any) { setErr('加入放行名单失败: ' + e.message); }
  }
  function removeAllow(v: string) {
    if (!cfg) return;
    save({ egress_allowlist: (cfg.egress_allowlist || []).filter(x => x !== v) });
  }

  return (
    <div style={{ padding: 0 }}>
      {/* 顶部操作栏：关闭按钮。问题5：原"打开日志文件夹"与基础区按钮重复（打开同一目录），
          已统一收进下方"基础"区底部，与"打开数据缓存目录"分列两个按钮 */}
      <div style={{ display: 'flex', justifyContent: 'flex-end', alignItems: 'center', marginBottom: 20 }}>
        {onClose && (
          <button
            className="ui-btn ui-btn-ghost"
            onClick={onClose}
            data-tip="关闭"
            style={{ background: 'transparent', border: 'none', cursor: 'pointer', color: colors.textSecondary, padding: 4 }}
          >
            <Icon name="x" size={16} />
          </button>
        )}
      </div>

      {/* 保存结果反馈（calloutStyle） */}
      {err && (
        <div style={{ ...calloutStyle('error'), marginBottom: 12 }}>
          <Icon name="alert-triangle" size={16} style={{ flexShrink: 0, marginTop: 2 }} />
          <span>{err}</span>
        </div>
      )}
      {msg && (
        <div style={{ ...calloutStyle('success'), marginBottom: 12 }}>
          <Icon name="check" size={16} style={{ flexShrink: 0, marginTop: 2 }} />
          <span>{msg}</span>
        </div>
      )}

      {/* 问题5修复：日志与数据缓存是两个不同的目录，分两个按钮（顶层渲染，
          不依赖配置加载状态，配置未加载完成也可点）：
          · 日志文件夹 → logs/（app.log / sidecar.log）
          · 数据缓存目录 → 数据根（数据库、导出、知识索引、全局知识等） */}
      {(onOpenLogs || onOpenDataDir) && (
        <div style={{ marginBottom: 20, display: 'flex', flexDirection: 'column', gap: 10 }}>
          {onOpenLogs && (
            <div>
              <button className="ui-btn ui-btn-secondary" onClick={onOpenLogs}
                style={{ ...btnSecondary, gap: 6 }}>
                <Icon name="folder" size={14} /> 打开日志文件夹
              </button>
              <div style={hintStyle}>应用运行日志（app.log、sidecar.log），排查报错看这里。</div>
            </div>
          )}
          {onOpenDataDir && (
            <div>
              <button className="ui-btn ui-btn-secondary" onClick={onOpenDataDir}
                style={{ ...btnSecondary, gap: 6 }}>
                <Icon name="database" size={14} /> 打开数据缓存目录
              </button>
              <div style={hintStyle}>应用数据根目录：数据库、会话导出、知识仓库索引与全局知识等。按需清理前请先确认用途。</div>
            </div>
          )}
        </div>
      )}

      {!cfg ? (
        <div style={{ ...typo.body, color: colors.textTertiary }}>加载配置中…</div>
      ) : (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 20 }}>

          {/* ===== 基础 ===== */}
          <div style={sectionCard}>
            <div style={sectionTitle}>基础</div>

            {/* 问题6修复（0.3.2实测）：Ollama 地址已移至"推理后端"面板，
                与后端选择放在一起，此处不再重复展示。 */}

            <label style={formLabel}>默认模型</label>
            {modelOptions.length > 0 ? (
              <select className="ui-input" style={{ ...select, width: '100%' }} value={cfg.default_model}
                onChange={e => setCfg({ ...cfg, default_model: e.target.value })}>
                {/* 当前值可能不在列表中（已卸载的模型），保留显示避免丢失 */}
                {!modelOptions.includes(cfg.default_model) && cfg.default_model && (
                  <option value={cfg.default_model}>{cfg.default_model}（当前不可用）</option>
                )}
                {modelOptions.map(m => <option key={m} value={m}>{m}</option>)}
              </select>
            ) : (
              <input className="ui-input" style={inpStyle} value={cfg.default_model}
                placeholder={modelsLoading ? '正在拉取可用模型…' : '无可用模型，可手动输入'}
                onChange={e => setCfg({ ...cfg, default_model: e.target.value })} />
            )}
            <div style={hintStyle}>从当前推理后端拉取的可用模型中选择；列表为空时可手动输入。</div>

            <label style={formLabel}>数据根目录 data_root</label>
            <input className="ui-input" style={inpStyle} value={cfg.data_root}
              onChange={e => setCfg({ ...cfg, data_root: e.target.value })} />

            <label style={formLabel}>工具调用最大轮次（Agent 单次对话最多调用工具的次数）</label>
            <input className="ui-input" style={inpStyle} type="number" min={1} max={1000} value={cfg.max_tool_rounds}
              onChange={e => setCfg({ ...cfg, max_tool_rounds: Number(e.target.value) })} />
            <div style={hintStyle}>
              默认 200，范围 1-1000。轮次越大，Agent 可执行越复杂的任务，但也消耗更多 token。
              无效空转有独立防护（连续失败自动停止、重复搜索自动拦截），无需靠轮次上限兜底
            </div>
          </div>

          {/* ===== 稳定性 ===== */}
          <div style={sectionCard}>
            <div style={sectionTitle}>稳定性</div>

            <div style={{ display: 'flex', gap: 8 }}>
              <div style={{ flex: 1 }}>
                <label style={formLabel}>断线重连次数</label>
                <input className="ui-input" style={inpStyle} type="number" min={1} max={10} value={cfg.reconnect_max_attempts ?? 3}
                  onChange={e => setCfg({ ...cfg, reconnect_max_attempts: Number(e.target.value) })} />
              </div>
              <div style={{ flex: 1 }}>
                <label style={formLabel}>心跳间隔（秒）</label>
                <input className="ui-input" style={inpStyle} type="number" min={5} max={60} value={cfg.heartbeat_interval ?? 15}
                  onChange={e => setCfg({ ...cfg, heartbeat_interval: Number(e.target.value) })} />
              </div>
            </div>
            <div style={hintStyle}>
              重连次数：网络错误时自动重试的最大次数（1-10）。心跳间隔：长任务保活的基础间隔（5-60 秒，实际按事件节奏动态调整）
            </div>
          </div>

          {/* ===== checkpoint-067b D-4：并发与调度 ===== */}
          <div style={sectionCard}>
            <div style={sectionTitle}>并发与调度</div>

            <label style={{ display: 'flex', alignItems: 'center', gap: 8, cursor: 'pointer', marginBottom: 8 }}>
              <input type="checkbox" checked={cfg.model_parallel ?? false}
                onChange={e => save({ model_parallel: e.target.checked })} />
              <span style={{ fontSize: 13, color: colors.textPrimary }}>大模型并行</span>
            </label>
            <div style={hintStyle}>开启后多个模型可同时运行（消耗更多内存）；关闭时切换模型会等待 5s 让旧模型释放（Ollama 无 unload API，等待 GC）。</div>

            <label style={{ display: 'flex', alignItems: 'center', gap: 8, cursor: 'pointer', marginTop: 8 }}>
              <input type="checkbox" checked={cfg.task_concurrency ?? false}
                onChange={e => save({ task_concurrency: e.target.checked })} />
              <span style={{ fontSize: 13, color: colors.textPrimary }}>任务并发</span>
            </label>
            <div style={hintStyle}>开启后多个委派任务可并行执行；关闭时任务排队依次运行（串行排队，本机性能受限时推荐关闭）。</div>
          </div>

          {/* ===== 网络 ===== */}
          <div style={sectionCard}>
            <div style={sectionTitle}>网络</div>

            {/* 问题8（0.3.2实测）：代理引导——无代理/有代理两种情况分别说清楚 */}
            <div style={{ fontSize: 12, color: colors.textTertiary, lineHeight: 1.7, marginBottom: 10,
              background: colors.bgSidebar, padding: '8px 10px', borderRadius: radius.s }}>
              <b style={{ color: colors.textSecondary }}>怎么填？</b><br />
              · 电脑没装代理软件：什么都不用改——保持"自动探测"，应用会境内直连、境外失败自动暂停。<br />
              · 有代理软件（Clash / 小飞机等）：境外访问模式选"走代理"，端口填代理软件的本地监听端口
              （Clash 默认 HTTP 端口 7890；在代理软件的"端口/设置"里查看）。应用只在需要访问境外时走代理，
              境内请求始终直连。
            </div>

            <div style={{ display: 'flex', gap: 8 }}>
              <div style={{ flex: 1 }}>
                <label style={formLabel}>HTTP 代理端口（仅"走代理"模式生效）</label>
                <input className="ui-input" style={inpStyle} type="number" value={cfg.proxy_http_port}
                  onChange={e => setCfg({ ...cfg, proxy_http_port: Number(e.target.value) })} />
              </div>
              <div style={{ flex: 1 }}>
                <label style={formLabel}>SOCKS 代理端口（可选）</label>
                <input className="ui-input" style={inpStyle} type="number" value={cfg.proxy_socks_port}
                  onChange={e => setCfg({ ...cfg, proxy_socks_port: Number(e.target.value) })} />
              </div>
            </div>

            <label style={formLabel}>境外访问模式</label>
            <select className="ui-input" style={{ ...select, width: '100%' }} value={cfg.network_switch === 'on' ? 'proxy' : cfg.network_switch === 'off' ? 'auto' : cfg.network_switch}
              onChange={e => {
                const v = e.target.value as 'auto' | 'proxy';
                setCfg({ ...cfg, network_switch: v });
                save({ network_switch: v });   // 切换即保存，立即生效
              }}>
              <option value="auto">自动探测（默认，无需管理）</option>
              <option value="proxy">走代理（已启动代理软件时使用）</option>
            </select>
            <div style={hintStyle}>
              自动探测：境内直连；境外先尝试，连续失败自动暂停重试（防空转）。走代理：境外请求经代理端口访问
            </div>

            <label style={formLabel}>放行名单（境内/白名单，支持 *.xxx 通配）</label>
            {(cfg.egress_allowlist || []).map((a, i) => (
              <div key={i} style={{ display: 'flex', gap: 6, alignItems: 'center', marginBottom: 4 }}>
                <span style={{ flex: 1, fontSize: 13, color: colors.textPrimary, fontFamily: fonts.mono }}>{a}</span>
                <button
                  className="ui-btn ui-btn-ghost ui-ico-danger"
                  onClick={() => removeAllow(a)}
                  style={{ background: 'transparent', border: 'none', cursor: 'pointer', color: colors.textTertiary, padding: 2 }}
                >
                  <Icon name="x" size={14} />
                </button>
              </div>
            ))}
            {(cfg.egress_allowlist || []).length === 0 && (
              <div style={{ ...typo.micro, marginBottom: 4 }}>（空）</div>
            )}
            <div style={{ display: 'flex', gap: 6, marginTop: 4 }}>
              <input className="ui-input" style={{ ...inpStyle, flex: 1 }} value={newAllow} placeholder="如 baidu.com 或 *.qq.com"
                onChange={e => setNewAllow(e.target.value)} />
              <button
                className="ui-btn ui-btn-secondary"
                onClick={addAllow}
                style={{ ...btnSecondary, height: 22, padding: '0 8px', fontSize: 12, whiteSpace: 'nowrap' }}
              >
                添加
              </button>
            </div>
            <div style={hintStyle}>
              OFF 状态下，仅白名单（本地/内网/.cn/名单内）可直连，其余需开启网络开关
            </div>
          </div>

          {/* ===== 插件仓库 ===== */}
          <div style={sectionCard}>
            <div style={sectionTitle}>插件仓库</div>

            <label style={formLabel}>插件仓库（可追加）</label>
            {(cfg.plugin_repos || []).map((r, i) => (
              <div key={i} style={{ display: 'flex', gap: 6, alignItems: 'center', marginBottom: 4 }}>
                <span style={{ flex: 1, fontSize: 13, color: colors.textPrimary, fontFamily: fonts.mono, overflow: 'hidden', textOverflow: 'ellipsis' }}>{r}</span>
                <button
                  className="ui-btn ui-btn-ghost ui-ico-danger"
                  onClick={() => removeRepo(r)}
                  style={{ background: 'transparent', border: 'none', cursor: 'pointer', color: colors.textTertiary, padding: 2 }}
                >
                  <Icon name="x" size={14} />
                </button>
              </div>
            ))}
            <div style={{ display: 'flex', gap: 6, marginTop: 4 }}>
              <input className="ui-input" style={{ ...inpStyle, flex: 1 }} value={newRepo} placeholder="https://github.com/owner/repo 或本地路径"
                onChange={e => setNewRepo(e.target.value)} />
              <button
                className="ui-btn ui-btn-secondary"
                onClick={addRepo}
                style={{ ...btnSecondary, height: 22, padding: '0 8px', fontSize: 12, whiteSpace: 'nowrap' }}
              >
                添加
              </button>
            </div>
          </div>

          {/* checkpoint-056b：侧车端口分区已移除——该输入框原本就没有保存按钮（无效配置项），
              且应用正式落地后侧车端口属内部实现细节，不暴露给用户。
              如需修改可直接编辑配置文件的 sidecar_port。 */}

          {/* ===== 上下文管理 ===== */}
          <div style={sectionCard}>
            <div style={sectionTitle}>上下文管理</div>

            <label style={formLabel}>压缩归档目录</label>
            <input className="ui-input" style={inpStyle} value={cfg.compact_archive_dir || ''}
              placeholder="~/.subagent/compressed"
              onChange={e => setCfg({ ...cfg, compact_archive_dir: e.target.value })} />
            <div style={hintStyle}>
              智能压缩时，被摘要的消息会以 MD 文件先存到这里
            </div>

            {/* 问题3修复（0.3.2实测）：勾选即保存（单键）——此前只改内存状态，
                需点"保存"按钮才落盘，勾选后切页就丢失。单键保存不会连带写入
                其他字段的未保存草稿（与本区 model_parallel 等开关同一风格）。 */}
            <label style={{ display: 'flex', alignItems: 'center', gap: 6, cursor: 'pointer', marginTop: 8 }}>
              <input type="checkbox" checked={cfg.allow_auto_compact || false}
                onChange={e => save({ allow_auto_compact: e.target.checked })} />
              <span style={{ fontSize: 12, color: colors.textPrimary }}>允许自动压缩</span>
            </label>
            <div style={hintStyle}>
              勾选后，上下文接近上限时系统可自动执行智能压缩；不勾选则只在预警时等你手动选择
            </div>

            <label style={formLabel}>压缩保留条数（保护最近 N 条消息不动）</label>
            <input className="ui-input" style={inpStyle} type="number" min={2} max={100} value={cfg.compact_keep_recent ?? 10}
              onChange={e => setCfg({ ...cfg, compact_keep_recent: Number(e.target.value) })} />

            <div style={{ marginTop: 10 }}>
              <button
                className="ui-btn ui-btn-primary"
                onClick={() => save({
                  compact_archive_dir: cfg.compact_archive_dir,
                  allow_auto_compact: cfg.allow_auto_compact,
                  compact_keep_recent: cfg.compact_keep_recent,
                })}
                style={btnPrimary}
              >
                <Icon name="download" size={14} />
                保存上下文管理
              </button>
            </div>

            {/* M2 压缩记录 */}
            <CompactLogSection />
          </div>

          {/* ===== 多 Agent ===== */}
          <div style={sectionCard}>
            <div style={sectionTitle}>多 Agent</div>

            <label style={{ display: 'flex', alignItems: 'center', gap: 6, cursor: 'pointer' }}>
              <input type="checkbox" checked={cfg.auto_create_sub_agents !== false}
                onChange={e => save({ auto_create_sub_agents: e.target.checked })} />
              <span style={{ fontSize: 12, color: colors.textPrimary }}>允许主 Agent 自动新建子 Agent</span>
            </label>
            <div style={hintStyle}>
              开启后，委派目标不存在且任务书带"建议角色"时，系统会自动新建该角色的子 Agent 并执行；
              关闭后，委派目标不存在时将转述给你手动决定。
            </div>

            <div style={{ marginTop: 10 }}>
              <button
                className="ui-btn ui-btn-primary"
                onClick={() => save({ auto_create_sub_agents: cfg.auto_create_sub_agents !== false })}
                style={btnPrimary}
              >
                <Icon name="download" size={14} />
                保存多 Agent 设置
              </button>
            </div>
          </div>

          {/* ===== 导出与附件 ===== */}
          <div style={sectionCard}>
            <div style={sectionTitle}>导出与附件</div>

            <label style={formLabel}>默认导出目录</label>
            <input className="ui-input" style={inpStyle} value={cfg.default_export_dir || ''}
              placeholder="留空 = 各项目的工作目录"
              onChange={e => setCfg({ ...cfg, default_export_dir: e.target.value })} />
            <div style={hintStyle}>
              圆桌导出 / 交卷报告 / 会话导出统一保存到该目录。留空则存到各项目自己的工作目录。知识库与记忆始终跟项目走，不受此配置影响。
            </div>

            {/* 问题4修复（0.3.2实测）：同问题3，勾选即保存（单键） */}
            <label style={{ display: 'flex', alignItems: 'center', gap: 6, cursor: 'pointer', marginTop: 10 }}>
              <input type="checkbox" checked={cfg.vision_parse_attachments === true}
                onChange={e => save({ vision_parse_attachments: e.target.checked })} />
              <span style={{ fontSize: 12, color: colors.textPrimary }}>圆桌图片附件交给视觉模型识别</span>
            </label>
            <div style={hintStyle}>
              开启后上传的图片附件会经视觉模型识别为文字参与讨论（需视觉模型）；关闭则图片仅作为材料标注。
            </div>

            <div style={{ marginTop: 10 }}>
              <button
                className="ui-btn ui-btn-primary"
                onClick={() => save({
                  default_export_dir: cfg.default_export_dir || '',
                  vision_parse_attachments: cfg.vision_parse_attachments === true,
                })}
                style={btnPrimary}
              >
                <Icon name="download" size={14} />
                保存导出与附件设置
              </button>
            </div>
          </div>

          {/* ===== 底部操作栏 ===== */}
          <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
            <button
              className="ui-btn ui-btn-primary"
              onClick={() => save(cfg)}
              style={btnPrimary}
            >
              <Icon name="download" size={14} />
              保存全部
            </button>
            <button
              className="ui-btn ui-btn-secondary"
              onClick={load}
              style={btnSecondary}
            >
              <Icon name="rotate-cw" size={14} />
              重新加载
            </button>
          </div>

          <div style={{ ...typo.micro, fontFamily: fonts.mono }}>
            配置文件：{getInjected().configPath || '~/.subagent/config.json'}
          </div>
        </div>
      )}
    </div>
  );
}
