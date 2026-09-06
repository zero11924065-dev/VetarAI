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
  // 0.4.9：报错分析 / 联网安装确认 / 委派模型自选与换装
  error_analysis_model?: string;          // 任务161：报错分析用的默认模型（空=用 default_model）
  confirm_network_install?: boolean;      // 任务152：联网安装前必须询问
  model_strengths?: Record<string,string>; // 3.47.2：模型特长画像
  delegation_model_swap?: boolean;        // 3.47.3：委派模型换装
  // 0.4.9（3.48.2）应用内模块控制
  app_control_enabled?: boolean;
  app_control_confirm?: string[];
  // 0.4.9（3.48.1）Computer Use
  computer_use_enabled?: boolean;
  computer_use_confirm_each?: boolean;
  computer_use_app_whitelist?: string[];
}

// 0.4.9（3.48.1）：Computer Use 设置区——总开关 + 每步确认 + 应用白名单 + 权限探测。
// ⚠️ 这是"Agent 直接操作真实电脑"的总闸，故默认关，且开启时强制展示权限状态与风险提示。
function ComputerUseSection({ cfg, save }: { cfg: any; save: (patch: Record<string, any>) => void }) {
  const api = getApiBase();
  const [cap, setCap] = React.useState<any>(null);
  const [loading, setLoading] = React.useState(false);
  const [newApp, setNewApp] = React.useState('');
  const enabled = !!cfg.computer_use_enabled;

  const probe = React.useCallback(async () => {
    setLoading(true);
    try {
      const r = await fetch(`${api}/computer-use/capabilities`);
      setCap(r.ok ? await r.json() : { ok: false, problems: [`探测请求失败：HTTP ${r.status}`] });
    } catch (e) {
      setCap({ ok: false, problems: [`探测失败：${(e as Error).message}（侧车未运行？）`] });
    } finally { setLoading(false); }
  }, []);

  React.useEffect(() => { if (enabled && !cap) probe(); }, [enabled, cap, probe]);

  const wl: string[] = cfg.computer_use_app_whitelist || [];
  const problems: string[] = (cap && cap.problems) || [];

  return (
    <div style={sectionCard}>
      <div style={sectionTitle}>Computer Use（操作电脑）</div>

      <label style={{ display: 'flex', alignItems: 'center', gap: 8, cursor: 'pointer', marginBottom: 8 }}>
        <input type="checkbox" checked={enabled}
          onChange={e => save({ computer_use_enabled: e.target.checked })} />
        <span style={{ fontSize: 13, color: colors.textPrimary }}>允许 Agent 操作我的电脑（截屏 / 点击 / 键盘输入）</span>
      </label>
      <div style={hintStyle}>
        ⚠️ 开启后 Agent 能看到你的屏幕并真实操作鼠标键盘——误操作后果立即可见且可能难以撤销（删文件、发消息、点支付）。
        默认关闭。一期仅支持 macOS，全程本地不联网。建议保持"每步确认"开启，并用应用白名单限定可操作范围。
      </div>

      {enabled && (
        <>
          <label style={{ display: 'flex', alignItems: 'center', gap: 8, cursor: 'pointer', margin: '10px 0 6px' }}>
            <input type="checkbox" checked={cfg.computer_use_confirm_each ?? true}
              onChange={e => save({ computer_use_confirm_each: e.target.checked })} />
            <span style={{ fontSize: 13, color: colors.textPrimary }}>每步操作前都要我确认</span>
          </label>
          <div style={hintStyle}>强烈建议保持开启：每次点击/输入前弹窗告知"在哪个应用、做什么动作、参数是什么"，你同意才执行。关闭后 Agent 可连续自主操作，风险显著上升。</div>

          <label style={formLabel}>允许操作的应用白名单</label>
          {wl.length === 0 && (
            <div style={hintStyle}>（空 = 不限制应用，仍受"每步确认"约束）</div>
          )}
          {wl.map((a, i) => (
            <div key={i} style={{ display: 'flex', gap: 6, alignItems: 'center', marginBottom: 4 }}>
              <span style={{ flex: 1, fontSize: 13, color: colors.textPrimary, fontFamily: fonts.mono }}>{a}</span>
              <button className="ui-btn ui-btn-ghost ui-ico-danger"
                onClick={() => save({ computer_use_app_whitelist: wl.filter(x => x !== a) })}
                style={{ background: 'transparent', border: 'none', cursor: 'pointer', color: colors.textTertiary, padding: 2 }}>
                <Icon name="trash" size={14} />
              </button>
            </div>
          ))}
          <div style={{ display: 'flex', gap: 6, marginTop: 4 }}>
            <input className="ui-input" style={{ ...inpStyle, flex: 1 }} value={newApp}
              placeholder="应用名，如 Finder / 预览 / 文本编辑"
              onChange={e => setNewApp(e.target.value)}
              onKeyDown={e => {
                if (e.key === 'Enter' && newApp.trim() && !wl.includes(newApp.trim())) {
                  save({ computer_use_app_whitelist: [...wl, newApp.trim()] }); setNewApp('');
                }
              }} />
            <button className="ui-btn ui-btn-secondary" style={btnSecondary}
              disabled={!newApp.trim() || wl.includes(newApp.trim())}
              onClick={() => { save({ computer_use_app_whitelist: [...wl, newApp.trim()] }); setNewApp(''); }}>
              添加
            </button>
          </div>
          <div style={hintStyle}>白名单非空时，只有前台应用命中名单才允许操作，越界一律拒绝（防 Agent 跑到别的应用里乱点）。</div>

          {/* 权限探测（防线1：门槛引导） */}
          <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginTop: 12 }}>
            <button className="ui-btn ui-btn-secondary" style={btnSecondary} onClick={probe} disabled={loading}>
              {loading ? '正在探测…' : (cap ? '重新检测权限' : '检测权限')}
            </button>
            {cap && (
              <span style={{ fontSize: 12.5, color: cap.ok ? colors.okText : colors.dangerText }}>
                {cap.ok ? '✓ 能力与权限就绪' : '✗ 存在阻塞项'}
              </span>
            )}
          </div>
          {cap && (
            <div style={{ marginTop: 8, fontSize: 12, lineHeight: 1.7, color: colors.textTertiary,
              background: colors.bgSidebar, padding: '8px 10px', borderRadius: radius.s }}>
              {cap.facts && (
                <div style={{ fontFamily: fonts.mono, marginBottom: problems.length ? 6 : 0 }}>
                  {cap.facts.frontmost_app && <div>前台应用：{cap.facts.frontmost_app}</div>}
                  {cap.facts.screen_points && <div>屏幕逻辑尺寸：{cap.facts.screen_points} 点</div>}
                  {cap.facts.screenshot_px && <div>截屏分辨率：{cap.facts.screenshot_px} px</div>}
                  {cap.facts.retina_scale && <div>Retina 缩放：{cap.facts.retina_scale}x（点击坐标已自动换算）</div>}
                  {/* ⚠️ 判据必须是 accessibility_trusted（AXIsProcessTrusted，问的是"本进程"）。
                      不可用 accessibility（System Events 查询前台应用成功与否）——那走的是
                      System Events 自己的权限，本进程无权限时它照样成功，会误显示"已授予"。 */}
                  <div>辅助功能权限（本进程 AXIsProcessTrusted）：
                    {cap.facts.accessibility_trusted === true ? '✓ 已授予'
                      : cap.facts.accessibility_trusted === false ? '✗ 未授予（点击/输入会被系统静默丢弃）'
                      : '？ 无法探测'}
                  </div>
                  <div>CoreGraphics 接口：{cap.facts.coregraphics || '未探测'}</div>
                </div>
              )}
              {problems.map((pr, i) => (
                <div key={i} style={{ color: colors.dangerText }}>· {pr}</div>
              ))}
              {!problems.length && cap.ok && (
                <div style={{ color: colors.textTertiary }}>· 无需安装任何第三方工具（用系统内置 screencapture + JXA/CoreGraphics）。</div>
              )}
            </div>
          )}
        </>
      )}
    </div>
  );
}

// 0.4.9（3.47.2）：模型特长画像编辑——用户描述各模型擅长什么，
// 主 Agent 委派时按画像自选模型（delegate_task 的 model 参数）。
// 单条限 100 字（后端 config 层同样校验，超长会被拒绝）。
function ModelStrengthsSection({ modelOptions, cfg, save }: {
  modelOptions: string[];
  cfg: any;
  save: (patch: Record<string, any>) => void;
}) {
  const strengths: Record<string, string> = cfg.model_strengths || {};
  const [draft, setDraft] = React.useState<Record<string, string>>({ ...strengths });
  React.useEffect(() => { setDraft({ ...strengths }); }, [JSON.stringify(strengths)]);

  const setOne = (model: string, text: string) => {
    const next = { ...draft };
    if (text.trim()) next[model] = text.slice(0, 100);
    else delete next[model];
    setDraft(next);
  };
  const commit = () => save({ model_strengths: draft });

  return (
    <div style={sectionCard}>
      <div style={sectionTitle}>模型特长（委派时按此自选模型）</div>
      <div style={hintStyle}>
        描述每个本地模型擅长什么，主 Agent 委派子任务时会自动按特长挑模型——例如把图片识别派给 OCR 专用小模型、把长文推理留给大模型。
        留空则不注入（主 Agent 沿用默认模型）。单条上限 100 字。
      </div>
      {/* 0.4.10（用户要求"模型变化后自动变化"）：列表 = 实时可用模型 ∪ 已配置模型。
          并集是必要的：若只显示实时模型，被删模型的特长记录就【在界面上消失但仍留在配置里】，
          用户既看不见也清不掉。故已配置但当前不可用的模型也列出，标记「已不可用」并可一键清理。
          注意：后端注入提示词前已与可用模型取交集，故"已不可用"项不会误导 Agent；
          这里保留它只为让用户能查看/恢复/清理（重新下载同名模型后特长自动恢复生效）。 */}
      {(() => {
        const avail = modelOptions.length ? modelOptions : [];
        const configured = Object.keys(strengths);
        const stale = configured.filter(m => !avail.includes(m));
        const all = [...new Set([...avail, ...configured])];
        return (
          <>
            {all.map(m => {
              const isStale = avail.length > 0 && !avail.includes(m);
              return (
                <div key={m} style={{ marginBottom: 8 }}>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                    <label style={{ ...formLabel, marginBottom: 0, flex: 1 }}>
                      {m}
                      {isStale && (
                        <span style={{ marginLeft: 6, fontSize: 11, color: colors.textTertiary,
                          background: colors.bgSidebar, padding: '1px 6px', borderRadius: radius.s }}>
                          已不可用（未注入，可保留待恢复或删除）
                        </span>
                      )}
                    </label>
                    {isStale && (
                      <button className="ui-btn ui-btn-ghost ui-ico-danger" data-tip="删除该模型的特长记录"
                        onClick={() => setOne(m, '')}
                        style={{ background: 'transparent', border: 'none', cursor: 'pointer',
                          color: colors.textTertiary, padding: 2 }}>
                        <Icon name="trash" size={13} />
                      </button>
                    )}
                  </div>
                  <input className="ui-input" style={{ ...inpStyle, width: '100%', boxSizing: 'border-box', marginTop: 4 }}
                    value={draft[m] || ''} maxLength={100}
                    placeholder={isStale ? '（该模型当前不可用，特长已保留；重新下载后自动生效）'
                                         : '如：OCR/图片转写专用，小而快'}
                    onChange={e => setOne(m, e.target.value)} />
                </div>
              );
            })}
            {stale.length > 0 && (
              <div style={hintStyle}>
                有 {stale.length} 个模型的特长当前不会注入提示词（模型已从本机移除）。
                记录已保留——重新下载同名模型后会自动恢复生效。要彻底清除请点右侧删除图标后保存。
              </div>
            )}
          </>
        );
      })()}
      {!modelOptions.length && !Object.keys(strengths).length && (
        <div style={hintStyle}>当前推理后端没有可用模型（或未连接）。连上后即可在此填写特长。</div>
      )}
      <button className="ui-btn ui-btn-primary" style={{ ...btnPrimary, marginTop: 6 }} onClick={commit}>
        保存模型特长
      </button>
    </div>
  );
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
// 0.4.9（3.48.2）：与后端 app_modules/registry.py 的 APP_MODULE_REGISTRY 保持一致。
// 后端新增模块/动作时，此处需同步（否则新动作在设置页无法配置确认级别）。
const ALL_MODULE_ACTIONS = [
  'workflow_list', 'workflow_run', 'workflow_get_runs',
  'knowledge_search', 'knowledge_inject', 'knowledge_groups',
  'roundtable_create',
];

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

            <label style={{ display: 'flex', alignItems: 'center', gap: 8, cursor: 'pointer', marginTop: 8 }}>
              <input type="checkbox" checked={cfg.delegation_model_swap ?? true}
                onChange={e => save({ delegation_model_swap: e.target.checked })} />
              <span style={{ fontSize: 13, color: colors.textPrimary }}>委派模型换装</span>
            </label>
            <div style={hintStyle}>委派前卸载主模型、子 Agent 交卷后卸载子模型，腾出内存给子任务独占（本地内存有限时推荐开启）。开启「大模型并行」或「任务并发」时自动失效——并行场景卸载会互相冲突。已内置 0.4.7 事故防护：卸载带 20s 独立超时，且卸载前先确认模型确在内存（避免为卸载而加载）。</div>
          </div>

          {/* ===== 0.4.9 任务161：报错分析 ===== */}
          <div style={sectionCard}>
            <div style={sectionTitle}>报错分析</div>
            <label style={formLabel}>报错分析模型</label>
            <select className="ui-input" style={{ ...select, width: '100%' }}
              value={cfg.error_analysis_model || ''}
              onChange={e => { const v = e.target.value; setCfg({ ...cfg, error_analysis_model: v }); save({ error_analysis_model: v }); }}>
              <option value="">（跟随默认模型：{cfg.default_model || '未设置'}）</option>
              {modelOptions.map(m => <option key={m} value={m}>{m}</option>)}
            </select>
            <div style={hintStyle}>任务失败时，除显示具体原因（工具名 / 参数 / 真实错误）外，再用该模型给出一句人话诊断与下一步建议。当前模型是 OCR 等专用小模型、不具备分析能力时，会自动改用它来分析——这正是本项的用途。留空则跟随默认模型；分析失败或超时 60s 会静默跳过，只显示失败原因，不影响原始报错。</div>
          </div>

          {/* ===== 0.4.9 3.48.2：应用内模块控制 ===== */}
          <div style={sectionCard}>
            <div style={sectionTitle}>应用内模块控制</div>
            <label style={{ display: 'flex', alignItems: 'center', gap: 8, cursor: 'pointer', marginBottom: 8 }}>
              <input type="checkbox" checked={cfg.app_control_enabled ?? false}
                onChange={e => save({ app_control_enabled: e.target.checked })} />
              <span style={{ fontSize: 13, color: colors.textPrimary }}>允许 Agent 调动应用内模块</span>
            </label>
            <div style={hintStyle}>
              <b style={{ color: colors.textSecondary }}>开启后：</b>Agent 可通过 app_control 调用工作流（跑确定性流程，如批量识图）、知识仓库（查历史沉淀）、圆桌（发起多 Agent 会诊）。其中查询类动作直接执行；运行工作流／创建圆桌等高成本动作会先弹窗请你确认。<br />
              <b style={{ color: colors.textSecondary }}>关闭时（默认）：</b>该工具不会出现在 Agent 的工具列表里（零开销），Agent 无法调动任何应用内模块。<br />
              以后新增模块只需在注册表登记一条，Agent 自动获得调用能力。
            </div>

            <label style={formLabel}>需要我确认的动作</label>
            {(ALL_MODULE_ACTIONS || []).map(a => (
              <label key={a} style={{ display: 'flex', alignItems: 'center', gap: 8, cursor: 'pointer', marginBottom: 4 }}>
                <input type="checkbox" checked={(cfg.app_control_confirm || []).includes(a)}
                  onChange={e => {
                    const cur = cfg.app_control_confirm || [];
                    const next = e.target.checked ? [...cur, a] : cur.filter(x => x !== a);
                    save({ app_control_confirm: next });
                  }} />
                <span style={{ fontSize: 12.5, color: colors.textPrimary, fontFamily: fonts.mono }}>{a}</span>
              </label>
            ))}
            <div style={hintStyle}>勾选的动作在执行前会弹窗请你确认（默认勾选运行工作流与创建圆桌两项高成本动作）；取消勾选则直接执行。查询类动作建议保持不勾选。</div>
          </div>

          {/* ===== 0.4.9 3.48.1：Computer Use（操作真实电脑，风险最高） ===== */}
          <ComputerUseSection cfg={cfg} save={save} />

          {/* ===== 0.4.9 3.47.2：模型特长画像 ===== */}
          <ModelStrengthsSection modelOptions={modelOptions} cfg={cfg} save={save} />

          {/* ===== 网络 ===== */}
          <div style={sectionCard}>
            <div style={sectionTitle}>网络</div>

            {/* 问题8（0.3.2实测）：代理引导——无代理/有代理两种情况分别说清楚 */}
            <div style={{ fontSize: 12, color: colors.textTertiary, lineHeight: 1.7, marginBottom: 10,
              background: colors.bgSidebar, padding: '8px 10px', borderRadius: radius.s }}>
              <b style={{ color: colors.textSecondary }}>怎么选？</b><br />
              · 关闭全量联网（默认「标准」）：可以正常上网——国内网站、以及不需要代理就能访问的境外网站都能正常触达；只有"必须经代理才能连接"的境外网站访问不到（会自动跳过、不空转）。<br />
              · 开启全量联网（「全量」）：触达所有网站，包括海外原本受限的网站。需先在电脑启动代理软件（Clash / 小飞机等），
              端口填代理软件的本地监听端口（Clash 默认 HTTP 端口 7890；在代理软件"端口/设置"里查看）。
              国内网站在两种模式下都始终直连，不经代理。
            </div>

            <div style={{ display: 'flex', gap: 8 }}>
              <div style={{ flex: 1 }}>
                <label style={formLabel}>HTTP 代理端口（仅「全量」模式生效）</label>
                <input className="ui-input" style={inpStyle} type="number" value={cfg.proxy_http_port}
                  onChange={e => setCfg({ ...cfg, proxy_http_port: Number(e.target.value) })} />
              </div>
              <div style={{ flex: 1 }}>
                <label style={formLabel}>SOCKS 代理端口（可选）</label>
                <input className="ui-input" style={inpStyle} type="number" value={cfg.proxy_socks_port}
                  onChange={e => setCfg({ ...cfg, proxy_socks_port: Number(e.target.value) })} />
              </div>
            </div>

            <label style={formLabel}>联网范围（境外网站）</label>
            <select className="ui-input" style={{ ...select, width: '100%' }} value={cfg.network_switch === 'on' ? 'proxy' : cfg.network_switch === 'off' ? 'auto' : cfg.network_switch}
              onChange={e => {
                const v = e.target.value as 'auto' | 'proxy';
                setCfg({ ...cfg, network_switch: v });
                save({ network_switch: v });   // 切换即保存，立即生效
              }}>
              <option value="auto">标准（默认）：国内 + 免代理境外站正常触达，需代理的境外站访问不到</option>
              <option value="proxy">全量：触达所有网站（含海外受限站），需先启动代理软件</option>
            </select>
            <div style={hintStyle}>
              标准＝不主动走代理：能直连的都直连，连不上的境外站自动暂停重试防空转；全量＝境外请求都经代理端口，可达受限站
            </div>

            <label style={{ display: 'flex', alignItems: 'center', gap: 8, cursor: 'pointer', marginBottom: 10 }}>
              <input type="checkbox" checked={cfg.confirm_network_install ?? true}
                onChange={e => save({ confirm_network_install: e.target.checked })} />
              <span style={{ fontSize: 13, color: colors.textPrimary }}>联网安装插件/技能前必须询问我</span>
            </label>
            <div style={hintStyle}>开启后，Agent 要从外部仓库（如 GitHub）下载安装插件或技能时，会先弹窗告知下载来源与类型，你同意才联网；当前为标准联网模式时还会一并询问是否切换到全量联网。强烈建议保持开启——曾发生子 Agent 擅自联网拉取、弹出账号密码窗并装入两个无关插件的事故。</div>

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
