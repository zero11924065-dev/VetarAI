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
/**
 * 0.4.32（CU 三期 P3，REQ-FUT-006 / 计划 E6）：Computer Use 任务宏面板。
 *
 * - 宏列表：名称 / 创建时间 / 步骤数 + 回放 / 删除（删除走 confirmDialog，照 PluginPanel 范式）。
 * - 录制控制：输入名称 → 开始录制 → 停止并保存；录制中显示进行态。
 *   口径（计划 E4）：录制的是 Agent 自己发起的 CU 动作序列（语义化步骤），
 *   ⛔ 不是系统级用户操作录制。
 * - 回放进度：触发后轮询 GET /api/cu-macros/replays/{run_id}（任务明令轮询；
 *   app_events 的 replay_step 事件不逐条消费——步骤高频，逐一重拉列表太吵，
 *   SSE 订阅只用于宏 create/delete 的列表刷新，照 InferencePanel A13 范式）。
 * - 命中率：回放口径（计划 P3 拍板）——executor 审计只落盘 actions.jsonl、
 *   无读取端点，故统计最近一次回放 run.steps 里 element vs pixel_fallback；
 *   UI 如实标注口径，不假装是全程命中率。
 *
 * 挂载：SettingsPanel 的 ComputerUseSection 内（CU 总开关开启时），
 * 原因是宏的录制/回放本身就是 CU 动作，无 CU 时面板无意义。
 *
 * 0.4.33（插单实测修复批 F2，空宏防护）：
 * - 录制中轮询 recording_steps，实时显示「已捕获 N 步」（看得见「没录到」）；
 * - stop 返回 saved:false（0 步契约）→ warn callout 原文上屏，不 refresh 出宏；
 * - steps==0 的宏（含历史遗留）回放按钮置灰 + title「宏没有步骤」；
 *   仍触发的 422「宏没有可回放的步骤」走 catch detail 上屏（既有范式）。
 */
import { apiJson } from '../lib/api';
import React, { useCallback, useEffect, useState } from 'react';
import { colors, fonts, radius, typo, btnPrimary, btnSecondary, input, calloutStyle } from '../theme';
import { Icon } from '../Icon';
import { confirmDialog } from '../Dialog';
import { on } from '../events';
import { APP_RESOURCE_CHANGED, AppResourceEvent } from '../appEvents';

/** 宏列表摘要（与后端 cu_macro.list_macros 一致：steps 是步骤数）。 */
interface MacroSummary { id: string; name: string; created_at: string; steps: number }
/** 回放步骤明细（与 cu_macro._step_finish 落 run["steps"] 的结构一致）。 */
interface ReplayStep { seq: number; action: string; method: string; ok: boolean; error?: string }
/** 回放运行记录（与 cu_macro.start_replay 登记的 run 结构一致）。 */
interface ReplayRun {
  run_id: string; macro_id: string; macro_name: string;
  status: string;                       // running | done | error
  total: number; completed: number;
  failed_seq: number | null; error: string;
  steps: ReplayStep[];
}

/** 命中方式 → 人话标签（method 值与后端契约一致：element/pixel_fallback/abort/payload）。 */
const METHOD_LABEL: Record<string, string> = {
  element: '元素定位',
  pixel_fallback: '像素回落',
  payload: '按键/输入',
  abort: '中止',
};

/** 命中方式徽标配色（语义色令牌：element=成功，回落=警告，中止=危险，其余中性）。 */
function methodBadgeStyle(method: string): React.CSSProperties {
  const map = {
    element: { bg: colors.okBg, fg: colors.okText },
    pixel_fallback: { bg: colors.warnBg, fg: colors.warnText },
    abort: { bg: colors.dangerBg, fg: colors.dangerText },
  }[method] || { bg: colors.bgHover, fg: colors.textSecondary };
  return {
    display: 'inline-flex', alignItems: 'center',
    height: 18, padding: '0 7px', borderRadius: radius.pill,
    fontSize: 11, fontWeight: 500, background: map.bg, color: map.fg,
    flexShrink: 0,
  };
}

const hintStyle: React.CSSProperties = { ...typo.micro, marginTop: 3 };

export function CuMacroPanel({ pollMs = 500 }: { pollMs?: number }) {
  const [macros, setMacros] = useState<MacroSummary[] | null>(null);
  const [recording, setRecording] = useState(false);
  const [recordingName, setRecordingName] = useState('');
  const [recordingSteps, setRecordingSteps] = useState(0);   // 0.4.33(F2)：录制中实时已捕获步骤数
  const [recName, setRecName] = useState('');
  const [busy, setBusy] = useState(false);          // 录制起停/回放启动/删除的动作级防重
  const [run, setRun] = useState<ReplayRun | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [warn, setWarn] = useState<string | null>(null);     // 0.4.33(F2)：0 步停止警告（saved:false）

  const refresh = useCallback(async () => {
    try {
      const d = await apiJson('/cu-macros');
      setMacros(Array.isArray(d?.macros) ? d.macros as MacroSummary[] : []);
      const rec = !!d?.recording;
      setRecording(rec);
      // recording_steps（0.4.33 新增契约字段，未录制为 0）；缺键按 0 兜底
      setRecordingSteps(typeof d?.recording_steps === 'number' ? d.recording_steps : 0);
      if (!rec) setRecordingName('');
    } catch (e) {
      setErr('读取宏列表失败: ' + (e as Error).message);
    }
  }, []);
  useEffect(() => { void refresh(); }, [refresh]);

  // 0.4.33（F2）：录制中轮询 GET /cu-macros 拿 recording_steps，实时显示「已捕获 N 步」，
  // 让用户在停止前就能看见「没录到」（而不是存出个空宏才发现）。
  // ⛔ 只同步步骤数：recording 开关态不随轮询翻面（防抖——stop 落盘宏后 SSE create 会 refresh 收敛），
  //   否则对端 stop 的竞态会把本地录制 UI 闪没。
  useEffect(() => {
    if (!recording) return;
    let alive = true;
    const t = setInterval(async () => {
      try {
        const d = await apiJson('/cu-macros');
        if (alive) setRecordingSteps(typeof d?.recording_steps === 'number' ? d.recording_steps : 0);
      } catch { /* 单拍失败静默，下一拍重试（轮询语义） */ }
    }, pollMs);
    return () => { alive = false; clearInterval(t); };
  }, [recording, pollMs]);

  // A13（0.4.22）实时刷新：宏 create/delete → 重拉列表。
  // replay_step 事件刻意不消费：回放进度走轮询（见下），步骤事件高频，
  // 若逐条重拉列表会造成录制/回放期间无意义的大量请求。
  useEffect(() => on(APP_RESOURCE_CHANGED, (ev: AppResourceEvent) => {
    if (ev.gap || (ev.resource === 'cu_macro' && (ev.action === 'create' || ev.action === 'delete'))) {
      void refresh();
    }
  }), [refresh]);

  // 回放进度轮询：run 进行中每 pollMs 拉一次状态；done/error 自动停；卸载清理。
  const runId = run?.run_id || '';
  const runActive = run?.status === 'running';
  useEffect(() => {
    if (!runActive || !runId) return;
    let alive = true;
    const t = setInterval(async () => {
      try {
        const d = await apiJson(`/cu-macros/replays/${runId}`);
        if (alive && d?.run) setRun(d.run as ReplayRun);
      } catch { /* 单拍失败静默，下一拍重试（轮询语义） */ }
    }, pollMs);
    return () => { alive = false; clearInterval(t); };
  }, [runActive, runId, pollMs]);

  const startRecord = async () => {
    const name = recName.trim();
    if (!name || busy || runActive) return;
    setBusy(true); setErr(null); setWarn(null);
    try {
      const d = await apiJson('/cu-macros/record/start', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name }),
      });
      setRecording(true);
      setRecordingName(String(d?.name || name));
      setRecordingSteps(0);
      setRecName('');
    } catch (e) { setErr('开始录制失败: ' + (e as Error).message); }
    finally { setBusy(false); }
  };

  const stopRecord = async () => {
    if (busy) return;
    setBusy(true); setErr(null); setWarn(null);
    try {
      const d = await apiJson('/cu-macros/record/stop', { method: 'POST' });
      setRecording(false);
      setRecordingName('');
      setRecordingSteps(0);
      // 0.4.33（F2）0 步停止契约：HTTP 200 {ok:true, saved:false, steps:0, message}
      //   → 警告原文上屏，⛔ 不 refresh（宏没落盘，列表无新项可刷）；
      //   saved:true（或旧后端无该键）→ 原流程 refresh 出新宏。
      if (d?.saved === false) {
        setWarn(String(d?.message || '未捕获到任何动作，宏未保存'));
      } else {
        await refresh();
      }
    } catch (e) { setErr('停止录制失败: ' + (e as Error).message); }
    finally { setBusy(false); }
  };

  const startReplay = async (m: MacroSummary) => {
    // 回放忙防重：真实键鼠是独占资源，后端另有 422 兜底（replay_busy）
    // 0.4.33（F2）空宏防护：steps==0 的宏（含历史遗留）不回放，按钮已置灰，此处双保险；
    //   若仍触发到后端 422「宏没有可回放的步骤」，走 catch 把 detail 如实上屏。
    if (busy || runActive || m.steps <= 0) return;
    setBusy(true); setErr(null);
    try {
      const d = await apiJson(`/cu-macros/${encodeURIComponent(m.id)}/replay`, { method: 'POST' });
      setRun({
        run_id: String(d.run_id), macro_id: m.id, macro_name: m.name,
        status: 'running', total: m.steps, completed: 0,
        failed_seq: null, error: '', steps: [],
      });
    } catch (e) { setErr('回放启动失败: ' + (e as Error).message); }
    finally { setBusy(false); }
  };

  const del = async (m: MacroSummary) => {
    const okDel = await confirmDialog({
      title: '删除任务宏',
      message: `确定删除宏「${m.name}」？删除后无法恢复。`,
      confirmText: '删除', danger: true,
    });
    if (!okDel) return;
    setBusy(true); setErr(null);
    try {
      await apiJson(`/cu-macros/${encodeURIComponent(m.id)}`, { method: 'DELETE' });
      if (run?.macro_id === m.id) setRun(null);
      await refresh();
    } catch (e) { setErr('删除失败: ' + (e as Error).message); }
    finally { setBusy(false); }
  };

  // ── 命中率（回放口径）：最近一次回放的点击步骤里 element vs pixel_fallback ──
  const steps = run?.steps || [];
  const elemHits = steps.filter(s => s.method === 'element').length;
  const pixHits = steps.filter(s => s.method === 'pixel_fallback').length;
  const sample = elemHits + pixHits;
  const hitRate = sample > 0 ? Math.round((elemHits / sample) * 100) : null;

  // 当前步骤 = 已登记的最后一步（运行中它就是刚执行的那步）
  const lastStep = steps.length ? steps[steps.length - 1] : null;
  const progressPct = run && run.total > 0
    ? Math.min(100, Math.round((run.completed / run.total) * 100)) : 0;

  return (
    <div style={{ marginTop: 16, borderTop: `1px solid ${colors.borderSubtle}`, paddingTop: 12 }}>
      <div style={{ ...typo.sectionTitle, fontSize: 13, color: colors.textPrimary, marginBottom: 4 }}>
        任务宏（操作录制与回放）
      </div>
      <div style={hintStyle}>
        录制的是 Agent 自己发起的 CU 动作（语义化步骤）；回放时逐步重新定位执行，窗口挪动后仍能命中。
      </div>

      {err && (
        <div style={{ ...calloutStyle('error'), margin: '8px 0' }}>
          <Icon name="alert-triangle" size={15} style={{ flexShrink: 0, marginTop: 2 }} />
          <span>{err}</span>
        </div>
      )}

      {/* 0.4.33（F2）：0 步停止警告——后端 saved:false 的 message 原文上屏（warn 而非 error：
          录制/停止动作本身成功，只是没有可保存的内容） */}
      {warn && (
        <div style={{ ...calloutStyle('warn'), margin: '8px 0' }}>
          <Icon name="alert-triangle" size={15} style={{ flexShrink: 0, marginTop: 2 }} />
          <span>{warn}</span>
        </div>
      )}

      {/* ── 录制控制 ── */}
      {recording ? (
        <div style={{ ...calloutStyle('info'), margin: '8px 0', alignItems: 'center' }}>
          <span style={{ flex: 1 }}>
            ● 正在录制{recordingName ? `「${recordingName}」` : ''} · 已捕获 {recordingSteps} 步——此后 Agent 的每个 CU 动作都会记为一步
          </span>
          <button className="ui-btn ui-btn-primary"
            style={{ ...btnPrimary, height: 24, padding: '0 10px', fontSize: 12 }}
            onClick={stopRecord} disabled={busy}>
            <Icon name="stop" size={12} /> 停止并保存
          </button>
        </div>
      ) : (
        <div style={{ display: 'flex', gap: 6, margin: '8px 0' }}>
          <input className="ui-input" style={{ ...input, flex: 1 }} value={recName}
            placeholder="宏名称，如 每日晨间整理"
            onChange={e => setRecName(e.target.value)}
            onKeyDown={e => { if (e.key === 'Enter') void startRecord(); }} />
          <button className="ui-btn ui-btn-secondary"
            style={{ ...btnSecondary, whiteSpace: 'nowrap' }}
            onClick={startRecord} disabled={busy || runActive || !recName.trim()}>
            开始录制
          </button>
        </div>
      )}

      {/* ── 元素定位命中率（回放口径） ── */}
      <div style={{ fontSize: 12, color: colors.textSecondary, margin: '6px 0' }}>
        元素定位命中率（回放口径）：
        {hitRate === null ? (
          <span style={{ color: colors.textTertiary }}>暂无回放样本</span>
        ) : (
          <b style={{ color: colors.textPrimary }}>
            {hitRate}%（element {elemHits} / pixel_fallback {pixHits}，样本 {sample}）
          </b>
        )}
      </div>
      <div style={hintStyle}>
        口径：仅统计最近一次回放的点击步骤（element=元素命中，pixel_fallback=回落像素）；
        日常每次点击的全程审计见数据目录 computer_use/actions.jsonl。
      </div>

      {/* ── 回放进度 ── */}
      {run && (
        <div style={{
          background: colors.bgSidebar, borderRadius: radius.s,
          padding: '8px 10px', margin: '8px 0', fontFamily: fonts.base,
        }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 12, color: colors.textSecondary }}>
            <span>回放「{run.macro_name || run.macro_id}」</span>
            <span>进度 {run.completed}/{run.total}</span>
          </div>
          <div style={{ height: 4, borderRadius: 2, background: colors.borderDefault, margin: '6px 0' }}>
            <div style={{
              height: 4, borderRadius: 2, transition: 'width .2s ease',
              background: run.status === 'error' ? colors.danger : colors.accent,
              width: `${progressPct}%`,
            }} />
          </div>
          {lastStep && (
            <div style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 12, color: colors.textSecondary }}>
              <span style={{ fontFamily: fonts.mono }}>
                第 {lastStep.seq} 步 {lastStep.action}
              </span>
              <span style={methodBadgeStyle(lastStep.method)}>
                {METHOD_LABEL[lastStep.method] || lastStep.method}
              </span>
              {!lastStep.ok && <span style={{ color: colors.dangerText }}>失败</span>}
            </div>
          )}
          {run.status === 'error' && (
            <div style={{ ...calloutStyle('error'), marginTop: 6 }}>
              <Icon name="alert-triangle" size={14} style={{ flexShrink: 0, marginTop: 2 }} />
              <span>
                回放中止{run.failed_seq != null ? `：第 ${run.failed_seq} 步失败` : ''}
                {run.error ? `——${run.error}` : ''}
              </span>
            </div>
          )}
          {run.status === 'done' && (
            <div style={{ ...calloutStyle('success'), marginTop: 6 }}>
              <Icon name="check" size={14} style={{ flexShrink: 0, marginTop: 2 }} />
              <span>回放完成：{run.completed}/{run.total} 步成功</span>
            </div>
          )}
        </div>
      )}

      {/* ── 宏列表 ── */}
      {macros === null ? (
        <div style={hintStyle}>加载宏列表…</div>
      ) : macros.length === 0 ? (
        <div style={hintStyle}>暂无宏——输入名称开始录制第一个。</div>
      ) : (
        macros.map(m => (
          <div key={m.id} style={{
            display: 'flex', alignItems: 'center', gap: 8,
            padding: '6px 0', borderTop: `1px solid ${colors.borderSubtle}`,
          }}>
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ fontSize: 13, color: colors.textPrimary }}>{m.name}</div>
              <div style={hintStyle}>{m.created_at} · {m.steps} 步</div>
            </div>
            <button className="ui-btn ui-btn-secondary"
              style={{ ...btnSecondary, height: 24, padding: '0 10px', fontSize: 12, gap: 4 }}
              onClick={() => void startReplay(m)}
              disabled={busy || runActive || recording || m.steps <= 0}
              title={m.steps <= 0 ? '宏没有步骤' : undefined}>
              <Icon name="play" size={11} /> 回放
            </button>
            <button className="ui-btn ui-btn-ghost ui-ico-danger" data-tip="删除宏"
              onClick={() => void del(m)} disabled={busy}
              style={{ background: 'transparent', border: 'none', cursor: 'pointer', color: colors.textTertiary, padding: 2 }}>
              <Icon name="trash" size={14} />
            </button>
          </div>
        ))
      )}
    </div>
  );
}
