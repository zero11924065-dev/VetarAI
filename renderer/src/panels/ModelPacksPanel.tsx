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
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with VetarAI. If not, see <https://www.gnu.org/licenses/>.
 */
/**
 * 0.4.29 批 P1：模型包管理器面板。
 *
 * 三区：目录（可安装）/ 已安装 / 目录源设置。
 * 实时性：订阅 APP_RESOURCE_CHANGED（resource==="model_pack"）——
 *   下载生命周期事件（download_start/progress/done/error/cancelled）由后端下载器
 *   经 app_events 总线推全局 SSE，appEvents 的 resource_changed 分支全量透传 data
 *   （含 received_bytes/total_bytes 字节进度），本面板直接消费，无需扩展总线。
 * 安装确认：config.confirm_model_pack_download（默认 true）时先弹窗告知
 *   包名/版本/大小/SHA256 前 12 位/来源；境外来源且当前为标准联网模式时
 *   附「同时开启全量联网」勾选（确认且勾选则先 PUT network_switch=proxy 再安装）。
 */
import React, { useCallback, useEffect, useState } from 'react';
import {
  colors, fonts, radius, typo, cardL, btnPrimary, btnSecondary, btnGhost, btnDangerSoft,
  input, textarea, badge, calloutStyle,
} from '../theme';
import { Icon, Spinner } from '../Icon';
import { confirmDialog } from '../Dialog';
import { apiJson, flash } from '../lib/api';
import { on } from '../events';
import { APP_RESOURCE_CHANGED, AppResourceEvent } from '../appEvents';

// ── 类型（与 sidecar/app.py 契约逐字段对应）──
interface PackFile { path: string; size_bytes: number; sha256: string; sources?: string[] }

interface CatalogPack {
  pack_id: string;
  name: string;
  task: string;                 // asr | chat | embedding
  format: string;               // onnx | gguf
  driver?: string;
  version: string;
  description?: string;
  size_bytes?: number;
  min_app_version?: string;
  homepage?: string;
  license?: string;
  files?: PackFile[];
  // catalog 端点合并时标注
  source?: string;
  installed?: boolean;
  enabled?: boolean;
  installed_version?: string;
}

interface InstalledPack {
  pack_id: string;
  name: string;
  description?: string;
  version: string;
  task: string;
  format: string;
  driver?: string;
  status: string;               // installed | disabled
  enabled: boolean;
  installed_at?: string;
  files?: PackFile[];
  sha256_ok: boolean;
  size_bytes: number;
  missing_files: string[];
  has_partial: boolean;
  dir?: string;
}

interface SourceError { source: string; error: string }

/** 下载进度（download_start 建条目，progress 更新，done/error/cancelled 清除）。 */
interface DlProg { received: number; total: number; file?: string }

/** 任务类型 → 中文徽标文案。 */
const TASK_LABELS: Record<string, string> = {
  asr: '语音转文字',
  chat: '对话',
  embedding: '嵌入',
};

/** 字节数格式化：GB/MB/KB/B（1024 系，保留 1 位小数）。 */
function formatSize(n: number): string {
  if (!Number.isFinite(n) || n <= 0) return '0 B';
  if (n >= 1024 ** 3) return `${(n / 1024 ** 3).toFixed(1)} GB`;
  if (n >= 1024 ** 2) return `${(n / 1024 ** 2).toFixed(1)} MB`;
  if (n >= 1024) return `${(n / 1024).toFixed(0)} KB`;
  return `${n} B`;
}

/** 从源 URL 取 host；file:// 本地目录返回空串。 */
function hostOf(src: string): string {
  const s = String(src || '').trim();
  if (!s || s.startsWith('file://')) return '';
  try { return new URL(s).hostname; } catch { return ''; }
}

/** 境外 host 判定：非 .cn 结尾、非 localhost/回环/纯 IP。 */
function isOverseasHost(host: string): boolean {
  if (!host) return false;
  const h = host.toLowerCase();
  if (h === 'localhost' || h === '::1' || h.startsWith('127.')) return false;
  if (/^\d+\.\d+\.\d+\.\d+$/.test(h)) return false;   // 纯 IP 视为内网/本地
  return !h.endsWith('.cn');
}

const smallBtn = (base: React.CSSProperties): React.CSSProperties => ({
  ...base, height: 22, padding: '0 8px', fontSize: 12,
});

export function ModelPacksPanel() {
  const [installed, setInstalled] = useState<InstalledPack[]>([]);
  const [catalog, setCatalog] = useState<CatalogPack[]>([]);
  const [sourceErrors, setSourceErrors] = useState<SourceError[]>([]);
  const [cfg, setCfg] = useState<any>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [dlProgress, setDlProgress] = useState<Record<string, DlProg>>({});
  const [dlErrors, setDlErrors] = useState<Record<string, string>>({});
  // 已发 install 请求、download_start 未到的等待态（按钮禁用防连点）
  const [installing, setInstalling] = useState<Record<string, boolean>>({});
  // 目录源设置区草稿与已保存反馈
  const [catalogDraft, setCatalogDraft] = useState('');
  const [dirDraft, setDirDraft] = useState('');
  const [savedUrls, setSavedUrls] = useState(false);
  const [savedDir, setSavedDir] = useState(false);

  // 列表重拉：已安装 + 目录（事件驱动刷新只走这里，不动设置区草稿）
  const fetchLists = useCallback(async () => {
    try {
      const [inst, cat] = await Promise.all([
        apiJson('/model-packs'),
        apiJson('/model-packs/catalog'),
      ]);
      setInstalled(Array.isArray(inst?.packs) ? inst.packs : []);
      setCatalog(Array.isArray(cat?.packs) ? cat.packs : []);
      setSourceErrors(Array.isArray(cat?.source_errors) ? cat.source_errors : []);
      setError(null);
    } catch (e: any) {
      setError('无法获取模型包列表: ' + (e.message || '侧车未运行'));
    } finally {
      setLoading(false);
    }
  }, []);

  // 配置只在挂载时拉一次（confirm 开关 / network_switch / 设置区草稿初值），
  // 事件刷新不走这里——否则下载事件会覆盖用户正在编辑的目录源草稿。
  const fetchConfig = useCallback(async () => {
    try {
      const c = await apiJson('/config');
      setCfg(c);
      setCatalogDraft((c?.model_pack_catalog_urls || []).join('\n'));
      setDirDraft(String(c?.model_packs_dir || ''));
    } catch {
      // 配置拉取失败不挡列表：confirm 开关按默认 true 处理
    }
  }, []);

  useEffect(() => { void fetchLists(); void fetchConfig(); }, [fetchLists, fetchConfig]);

  // 订阅模型包资源变更流：进度事件更新进度条，写操作/生命周期事件触发重拉
  useEffect(() => {
    const off = on(APP_RESOURCE_CHANGED, (ev: AppResourceEvent) => {
      if (ev.gap) { void fetchLists(); return; }              // 断档对账：无条件重拉
      if (ev.resource !== 'model_pack') return;
      const pid = String(ev.pack_id || '');
      switch (ev.action) {
        case 'download_start':
          setDlProgress(prev => ({
            ...prev,
            [pid]: { received: 0, total: Number(ev.total_bytes) || 0 },
          }));
          setDlErrors(prev => { const n = { ...prev }; delete n[pid]; return n; });
          break;
        case 'download_progress':
          setDlProgress(prev => ({
            ...prev,
            [pid]: {
              received: Number(ev.received_bytes) || 0,
              total: Number(ev.total_bytes) || prev[pid]?.total || 0,
              file: ev.file ? String(ev.file) : prev[pid]?.file,
            },
          }));
          break;
        case 'download_done':
          setDlProgress(prev => { const n = { ...prev }; delete n[pid]; return n; });
          flash(setNotice, `模型包 ${pid} 安装完成`, 4000);
          void fetchLists();
          break;
        case 'download_error':
          setDlProgress(prev => { const n = { ...prev }; delete n[pid]; return n; });
          setDlErrors(prev => ({ ...prev, [pid]: String(ev.error || '下载失败') }));
          break;
        case 'download_cancelled':
          setDlProgress(prev => { const n = { ...prev }; delete n[pid]; return n; });
          void fetchLists();
          break;
        case 'update':
        case 'delete':
          void fetchLists();
          break;
      }
    });
    return off;                            // 卸载注销（不重连、无幽灵监听）
  }, [fetchLists]);

  // ── 安装流：确认弹窗（含境外来源的全量联网勾选）→ install ──
  async function handleInstall(p: CatalogPack) {
    const needConfirm = cfg?.confirm_model_pack_download !== false;   // 缺省视为开启
    let enableProxy = false;
    if (needConfirm) {
      const src = String(p.source || '');
      const host = hostOf(src);
      // 境外来源且当前非全量联网 → 附「同时开启全量联网」勾选（默认勾选）
      const offerProxy = isOverseasHost(host) && cfg?.network_switch !== 'proxy';
      const sha = String(p.files?.[0]?.sha256 || '');
      const ok = await confirmDialog({
        title: '下载模型包确认',
        message: (
          <div style={{ lineHeight: 1.8 }}>
            将从外部来源下载并安装模型包：
            <br />名称：{p.name || p.pack_id}
            <br />版本：v{p.version || '?'}
            <br />大小：{formatSize(Number(p.size_bytes) || 0)}
            {sha && (<><br />SHA256：{sha.slice(0, 12)}…</>)}
            <br />来源：{src || '（未知）'}
            <br /><br />请确认来源可信后再下载；取消则不联网、不安装。
          </div>
        ),
        confirmText: '下载并安装',
        cancelText: '取消',
        ...(offerProxy ? {
          checkboxLabel: '同时开启全量联网（经代理访问海外站点）',
          checkboxDefault: true,
          onCheckbox: (c: boolean) => { enableProxy = c; },
        } : {}),
      });
      if (!ok) return;
      if (offerProxy && enableProxy) {
        // 先切全量联网再发安装——顺序反了下载仍会直连失败
        await apiJson('/config', {
          method: 'PUT', headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ network_switch: 'proxy' }),
        });
        setCfg((c: any) => (c ? { ...c, network_switch: 'proxy' } : c));
      }
    }
    setInstalling(prev => ({ ...prev, [p.pack_id]: true }));
    setDlErrors(prev => { const n = { ...prev }; delete n[p.pack_id]; return n; });
    try {
      await apiJson('/model-packs/install', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        // catalog 条目原样回传（后端校验时忽略 source/installed 等标注键）
        body: JSON.stringify({ pack_id: p.pack_id, catalog_entry: p }),
      });
      // 进度由 SSE download_start/progress 驱动；409（已安装/下载中）走 catch
    } catch (e: any) {
      setDlErrors(prev => ({ ...prev, [p.pack_id]: '安装请求失败: ' + e.message }));
    } finally {
      setInstalling(prev => { const n = { ...prev }; delete n[p.pack_id]; return n; });
    }
  }

  async function handleCancel(pid: string) {
    try {
      await apiJson('/model-packs/cancel', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ pack_id: pid }),
      });
      // 进度条目清理由 download_cancelled 事件负责
    } catch (e: any) {
      setDlErrors(prev => ({ ...prev, [pid]: '取消失败: ' + e.message }));
    }
  }

  async function handleUninstall(pack: InstalledPack) {
    const ok = await confirmDialog({
      title: '卸载模型包',
      message: `确定卸载模型包 "${pack.name || pack.pack_id}"（v${pack.version || '?'}）？\n将删除其全部文件（含未完成的下载残留）。`,
      confirmText: '卸载',
      danger: true,
    });
    if (!ok) return;
    setError(null);
    try {
      await apiJson(`/model-packs/${encodeURIComponent(pack.pack_id)}`, { method: 'DELETE' });
      flash(setNotice, `模型包 "${pack.name || pack.pack_id}" 已卸载`, 4000);
      void fetchLists();
    } catch (e: any) {
      setError('卸载失败: ' + e.message);
    }
  }

  async function handleToggle(pack: InstalledPack) {
    const next = !pack.enabled;
    try {
      await apiJson(`/model-packs/${encodeURIComponent(pack.pack_id)}/toggle`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ enabled: next }),
      });
      setInstalled(prev => prev.map(p => p.pack_id === pack.pack_id ? { ...p, enabled: next } : p));
      flash(setNotice, `模型包 "${pack.name || pack.pack_id}" 已${next ? '启用' : '禁用'}`, 3000);
    } catch (e: any) {
      setError('切换失败: ' + e.message);
    }
  }

  // ── 目录源设置区保存 ──
  async function saveCatalogUrls() {
    const urls = catalogDraft.split('\n').map(s => s.trim()).filter(Boolean);
    setError(null);
    try {
      await apiJson('/config', {
        method: 'PUT', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ model_pack_catalog_urls: urls }),
      });
      setCfg((c: any) => (c ? { ...c, model_pack_catalog_urls: urls } : c));
      setSavedUrls(true);
      setTimeout(() => setSavedUrls(false), 2000);
      void fetchLists();          // 源变了，目录区立即重拉
    } catch (e: any) {
      setError('保存目录源失败: ' + e.message);
    }
  }

  async function savePacksDir() {
    setError(null);
    try {
      await apiJson('/config', {
        method: 'PUT', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ model_packs_dir: dirDraft.trim() }),
      });
      setCfg((c: any) => (c ? { ...c, model_packs_dir: dirDraft.trim() } : c));
      setSavedDir(true);
      setTimeout(() => setSavedDir(false), 2000);
    } catch (e: any) {
      setError('保存安装目录失败: ' + e.message);
    }
  }

  const noSources = (cfg?.model_pack_catalog_urls || []).length === 0 && sourceErrors.length === 0;

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 20 }}>
      {/* 标题行 */}
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <Icon name="layers" size={16} style={{ color: colors.textPrimary }} />
          <span style={{ ...typo.sectionTitle, color: colors.textPrimary }}>模型包管理</span>
        </div>
        <button className="ui-btn ui-btn-ghost" style={btnGhost} onClick={() => void fetchLists()} data-tip="刷新">
          <Icon name="rotate-cw" size={14} />
          刷新
        </button>
      </div>

      {/* 错误提示条 */}
      {error && (
        <div style={calloutStyle('error')}>
          <Icon name="alert-triangle" size={16} style={{ flexShrink: 0 }} />
          <span>{error}</span>
        </div>
      )}
      {/* 轻提示条（安装完成/卸载/开关反馈） */}
      {notice && (
        <div style={calloutStyle('success')}>
          <Icon name="check" size={16} style={{ flexShrink: 0 }} />
          <span>{notice}</span>
        </div>
      )}

      {/* 目录（可安装）- 分区卡 */}
      <div style={{ ...cardL, padding: '16px 20px' }}>
        <div style={{ ...typo.sectionTitle, color: colors.textPrimary, marginBottom: 4 }}>目录（可安装）</div>
        <div style={{ ...typo.micro, marginBottom: 12 }}>来自目录源的模型包；点击安装即开始下载，中断后可从断点续传。</div>

        {/* 目录源拉取失败警告条（单源失败不拖死整列） */}
        {sourceErrors.map((se, i) => (
          <div key={i} style={{ ...calloutStyle('warn'), marginBottom: 8 }}>
            <Icon name="alert-triangle" size={16} style={{ flexShrink: 0 }} />
            <span>目录源 {se.source} 拉取失败：{se.error}</span>
          </div>
        ))}

        {loading ? (
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8, padding: '24px 0' }}>
            <Spinner size={20} />
            <span style={{ ...typo.caption, color: colors.textTertiary }}>加载中…</span>
          </div>
        ) : catalog.length === 0 ? (
          noSources ? (
            // 空目录且无源：引导去下方加目录源
            <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 8, padding: '24px 0' }}>
              <Icon name="layers" size={36} style={{ color: colors.borderStrong }} />
              <span style={{ fontSize: 13, color: colors.textTertiary, textAlign: 'center', lineHeight: 1.7 }}>
                还没有配置模型包目录源。<br />
                在下方「目录源设置」中添加目录索引地址（http(s):// 或 file:// 本地目录），保存后这里会列出可安装的模型包。
              </span>
            </div>
          ) : (
            <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 8, padding: '24px 0' }}>
              <Icon name="layers" size={36} style={{ color: colors.borderStrong }} />
              <span style={{ fontSize: 13, color: colors.textTertiary }}>目录为空——已配置的源里没有可安装的模型包。</span>
            </div>
          )
        ) : (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
            {catalog.map(p => {
              const prog = dlProgress[p.pack_id];
              const dlErr = dlErrors[p.pack_id];
              const busy = !!installing[p.pack_id];
              const host = hostOf(String(p.source || ''));
              return (
                <div key={p.pack_id} style={{
                  background: colors.bgCard, border: `1px solid ${colors.borderDefault}`,
                  borderRadius: radius.m, padding: 12,
                }}>
                  <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                    <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
                      <span style={{ fontSize: 13, fontWeight: 500, color: colors.textPrimary }}>{p.name || p.pack_id}</span>
                      <span style={badge(colors.accentBg, colors.accentText)}>{TASK_LABELS[p.task] || p.task || '未知'}</span>
                      <span style={{ fontSize: 12, fontFamily: fonts.mono, color: colors.textTertiary }}>v{p.version || '?'}</span>
                      <span style={{ fontSize: 12, color: colors.textTertiary }}>{formatSize(Number(p.size_bytes) || 0)}</span>
                      {p.installed && (
                        <span style={badge(colors.okBg, colors.okText)}>
                          已安装{p.installed_version && p.installed_version !== p.version ? ` v${p.installed_version}` : ''}
                        </span>
                      )}
                    </div>
                    {prog ? (
                      <button
                        className="ui-btn ui-btn-danger-soft"
                        style={smallBtn(btnDangerSoft)}
                        onClick={() => handleCancel(p.pack_id)}
                      >
                        <Icon name="x" size={14} />
                        取消
                      </button>
                    ) : p.installed ? (
                      <button className="ui-btn ui-btn-secondary" style={smallBtn(btnSecondary)} disabled>已安装</button>
                    ) : (
                      <button
                        className="ui-btn ui-btn-primary"
                        style={smallBtn(btnPrimary)}
                        onClick={() => void handleInstall(p)}
                        disabled={busy}
                      >
                        {busy ? <Spinner size={12} /> : <Icon name="download" size={14} />}
                        {busy ? '安装中…' : '安装'}
                      </button>
                    )}
                  </div>

                  {p.description && (
                    <div style={{ marginTop: 6, fontSize: 12, color: colors.textSecondary, lineHeight: 1.6 }}>{p.description}</div>
                  )}
                  <div style={{ ...typo.micro, marginTop: 6 }}>
                    来源：{host || '本地目录'}{p.format ? ` · ${p.format}` : ''}{p.license ? ` · ${p.license}` : ''}
                  </div>

                  {/* 下载中：进度条（SSE download_progress 驱动） */}
                  {prog && (
                    <div style={{ marginTop: 8 }}>
                      <div style={{ height: 6, borderRadius: 3, background: colors.bgHover, overflow: 'hidden' }}>
                        <div
                          data-progress-bar={p.pack_id}
                          style={{
                            width: `${prog.total > 0 ? Math.min(100, Math.round(prog.received / prog.total * 100)) : 0}%`,
                            height: '100%', background: colors.accent, transition: 'width .3s ease',
                          }}
                        />
                      </div>
                      <div style={{ ...typo.micro, marginTop: 4 }}>
                        已下载 {formatSize(prog.received)} / {formatSize(prog.total)}
                        {prog.total > 0 ? `（${Math.min(100, Math.round(prog.received / prog.total * 100))}%）` : ''}
                        {prog.file ? ` · ${prog.file}` : ''}
                      </div>
                    </div>
                  )}
                  {/* 下载/安装错误：显示在卡片上 */}
                  {dlErr && (
                    <div style={{ marginTop: 6, fontSize: 12, color: colors.dangerText, display: 'flex', alignItems: 'center', gap: 6 }}>
                      <Icon name="alert-circle" size={14} style={{ flexShrink: 0 }} />
                      <span>{dlErr}</span>
                    </div>
                  )}
                </div>
              );
            })}
          </div>
        )}
      </div>

      {/* 已安装 - 分区卡 */}
      <div style={{ ...cardL, padding: '16px 20px' }}>
        <div style={{ ...typo.sectionTitle, color: colors.textPrimary, marginBottom: 12 }}>已安装</div>
        {installed.length === 0 ? (
          <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 8, padding: '24px 0' }}>
            <Icon name="download" size={36} style={{ color: colors.borderStrong }} />
            <span style={{ fontSize: 13, color: colors.textTertiary }}>尚未安装任何模型包。从上方目录选择安装。</span>
          </div>
        ) : (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
            {installed.map(p => {
              const corrupted = !p.sha256_ok || (p.missing_files || []).length > 0;
              return (
                <div key={p.pack_id} style={{
                  background: colors.bgCard, border: `1px solid ${colors.borderDefault}`,
                  borderRadius: radius.m, padding: 12, opacity: p.enabled ? 1 : 0.7,
                }}>
                  <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                    <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
                      <span style={{ fontSize: 13, fontWeight: 500, color: p.enabled ? colors.textPrimary : colors.textTertiary }}>{p.name || p.pack_id}</span>
                      <span style={badge(colors.accentBg, colors.accentText)}>{TASK_LABELS[p.task] || p.task || '未知'}</span>
                      <span style={{ fontSize: 12, fontFamily: fonts.mono, color: colors.textTertiary }}>v{p.version || '?'}</span>
                      {p.format && <span style={{ fontSize: 12, color: colors.textTertiary }}>{p.format}</span>}
                      <span style={{ fontSize: 12, color: colors.textTertiary }}>{formatSize(p.size_bytes || 0)}</span>
                      {/* 缺文件或校验未通过 → 警示标记 */}
                      {corrupted && (
                        <span style={badge(colors.warnBg, colors.warnText)}>
                          <Icon name="alert-triangle" size={12} />
                          {!p.sha256_ok ? '校验未通过' : '文件缺失'}
                        </span>
                      )}
                    </div>
                    <div style={{ display: 'flex', gap: 6, flexShrink: 0 }}>
                      {/* 启用/禁用开关（禁用保留文件，推理侧按 enabled 过滤） */}
                      <button
                        className="ui-btn ui-btn-ghost"
                        style={{
                          ...smallBtn(btnGhost),
                          background: p.enabled ? colors.accentBg : colors.bgHover,
                          color: p.enabled ? colors.accentText : colors.textSecondary,
                        }}
                        onClick={() => void handleToggle(p)}
                        title={p.enabled ? '点击禁用此模型包' : '点击启用此模型包'}
                      >
                        {p.enabled ? '禁用' : '启用'}
                      </button>
                      <button
                        className="ui-btn ui-btn-danger-soft"
                        style={smallBtn(btnDangerSoft)}
                        onClick={() => void handleUninstall(p)}
                      >
                        <Icon name="trash" size={14} />
                        卸载
                      </button>
                    </div>
                  </div>

                  {p.description && (
                    <div style={{ marginTop: 6, fontSize: 12, color: colors.textSecondary, lineHeight: 1.6 }}>{p.description}</div>
                  )}
                  {(p.missing_files || []).length > 0 && (
                    <div style={{ ...typo.micro, marginTop: 6, color: colors.warnText }}>
                      缺失文件：{p.missing_files.join('、')}
                    </div>
                  )}
                  {/* 半截下载残留：到目录区再次点安装即自动断点续传 */}
                  {p.has_partial && (
                    <div style={{ ...typo.micro, marginTop: 6, color: colors.warnText }}>
                      有未完成下载，可继续安装（到上方目录区再次点击「安装」即自动续传）。
                    </div>
                  )}
                </div>
              );
            })}
          </div>
        )}
      </div>

      {/* 目录源设置 - 分区卡 */}
      <div style={{ ...cardL, padding: '16px 20px' }}>
        <div style={{ ...typo.sectionTitle, color: colors.textPrimary, marginBottom: 12 }}>目录源设置</div>

        <div style={{ ...typo.panelTitle, marginBottom: 6 }}>目录索引地址（一行一个）</div>
        <textarea
          className="ui-input"
          value={catalogDraft}
          onChange={e => setCatalogDraft(e.target.value)}
          placeholder={'https://example.com/model-packs.json\nfile:///Users/you/packs/'}
          style={{ ...textarea, width: '100%', minHeight: 72, fontFamily: fonts.mono, fontSize: 12 }}
        />
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginTop: 6 }}>
          <button className="ui-btn ui-btn-primary" style={smallBtn(btnPrimary)} onClick={() => void saveCatalogUrls()}>
            保存目录源
          </button>
          {savedUrls && <span style={{ fontSize: 12, color: colors.okText }}>已保存 ✓</span>}
        </div>
        <div style={{ ...typo.micro, marginTop: 6 }}>
          支持 http(s):// 远程索引与 file:// 本地目录；多个源按从上到下的顺序合并，同名包以先出现的源为准。
        </div>

        <div style={{ ...typo.panelTitle, margin: '14px 0 6px' }}>模型包安装目录（留空 = 默认）</div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <input
            className="ui-input"
            value={dirDraft}
            onChange={e => setDirDraft(e.target.value)}
            placeholder="留空使用默认安装根（数据目录/models/packs）"
            style={{ ...input, flex: 1, fontFamily: fonts.mono, fontSize: 12 }}
          />
          <button className="ui-btn ui-btn-primary" style={smallBtn(btnPrimary)} onClick={() => void savePacksDir()}>
            保存目录
          </button>
          {savedDir && <span style={{ fontSize: 12, color: colors.okText }}>已保存 ✓</span>}
        </div>
      </div>
    </div>
  );
}
