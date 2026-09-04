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
 * 0.2.1（TS-119）：流程中心主面板（工作流模块入口）。
 *
 * 布局：左列工作流列表 | 中部画布+运行监控 | 右侧节点配置表单（选中节点时）。
 * 运行：POST /api/workflows/{id}/run（SSE），实时刷新节点状态与事件流；
 * 审批节点弹出审批卡片（批准/驳回）；支持停止。
 */
import React, { useCallback, useEffect, useRef, useState } from 'react';
import { getApiBase } from '../apiBase';
import { colors, fonts, radius, btnPrimary, btnSecondary, btnDangerSoft, input, textarea, calloutStyle } from '../theme';
import { Icon, Spinner } from '../Icon';
import { alertDialog, confirmDialog } from '../Dialog';
import { WorkflowCanvas, NodeStatus } from './WorkflowCanvas';
import { WorkflowEditor } from './WorkflowEditor';
import { SSEStreamParser } from '../lib/sseParser';

const API = getApiBase();

interface Workflow {
  id: string;
  name: string;
  description?: string;
  definition: any;
  built_in?: boolean;
  updated_at?: string;
}

interface RunEvent {
  event: string;
  data: Record<string, any>;
  ts: number;
}

export function WorkflowPanel() {
  const [workflows, setWorkflows] = useState<Workflow[]>([]);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [selectedNodeId, setSelectedNodeId] = useState<string | null>(null);
  const [models, setModels] = useState<string[]>([]);
  const [name, setName] = useState('');
  const [desc, setDesc] = useState('');
  const [definition, setDefinition] = useState<any>({ nodes: [{ id: 'start', type: 'start', label: '开始' }], edges: [], params: {} });
  const [dirty, setDirty] = useState(false);
  const [validateMsg, setValidateMsg] = useState('');

  // 运行态
  const [running, setRunning] = useState(false);
  const [runId, setRunId] = useState<string | null>(null);
  const [nodeStatus, setNodeStatus] = useState<Record<string, NodeStatus>>({});
  const [events, setEvents] = useState<RunEvent[]>([]);
  const [approval, setApproval] = useState<{ nodeId: string; label: string; message: string } | null>(null);
  const [paramsText, setParamsText] = useState('{}');
  const [showJson, setShowJson] = useState(false);
  const abortRef = useRef<AbortController | null>(null);

  const selected = workflows.find(w => w.id === selectedId) || null;

  const loadWorkflows = useCallback(async () => {
    try {
      const r = await fetch(`${API}/workflows`);
      if (r.ok) setWorkflows(await r.json());
    } catch { /* 侧车未启动时静默 */ }
  }, []);

  const loadModels = useCallback(async () => {
    try {
      const r = await fetch(`${API}/inference/models`);
      if (r.ok) {
        const list = await r.json();
        setModels(list.map((m: any) => m.name || m).filter(Boolean));
      }
    } catch { /* ignore */ }
  }, []);

  useEffect(() => { loadWorkflows(); loadModels(); }, [loadWorkflows, loadModels]);

  const selectWorkflow = (wf: Workflow) => {
    setSelectedId(wf.id);
    setName(wf.name);
    setDesc(wf.description || '');
    setDefinition(wf.definition || { nodes: [], edges: [], params: {} });
    setSelectedNodeId(null);
    setValidateMsg('');
    setDirty(false);
    stopRun();
  };

  const createWorkflow = async () => {
    const def = { nodes: [{ id: 'start', type: 'start', label: '开始' }], edges: [], params: {} };
    try {
      const r = await fetch(`${API}/workflows`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name: '新工作流', definition: def }),
      });
      if (!r.ok) { alertDialog({ message: `创建失败：${await r.text()}` }); return; }
      const d = await r.json();
      await loadWorkflows();
      setSelectedId(d.id);
      setName('新工作流'); setDesc(''); setDefinition(def); setSelectedNodeId(null); setDirty(false);
    } catch (e: any) { alertDialog({ message: `创建失败：${e?.message || e}` }); }
  };

  const deleteWorkflow = async () => {
    if (!selected || selected.built_in) return;
    const ok = await confirmDialog({ title: '删除工作流', message: `确定删除「${selected.name}」？运行记录会保留。` });
    if (!ok) return;
    try {
      await fetch(`${API}/workflows/${selected.id}`, { method: 'DELETE' });
      setSelectedId(null);
      await loadWorkflows();
    } catch (e: any) { alertDialog({ message: `删除失败：${e?.message || e}` }); }
  };

  const saveWorkflow = async () => {
    if (!selectedId) return;
    try {
      const r = await fetch(`${API}/workflows/${selectedId}`, {
        method: 'PUT', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name, description: desc, definition }),
      });
      if (!r.ok) {
        const detail = await r.text();
        setValidateMsg(detail || '保存失败');
        alertDialog({ message: `保存失败：${detail}` });
        return;
      }
      setValidateMsg('');
      setDirty(false);
      await loadWorkflows();
    } catch (e: any) { alertDialog({ message: `保存失败：${e?.message || e}` }); }
  };

  const stopRun = () => {
    if (abortRef.current) { try { abortRef.current.abort(); } catch { /* ignore */ } abortRef.current = null; }
    setRunning(false);
    setApproval(null);
  };

  const stopRunServer = async () => {
    if (!runId) return;
    try { await fetch(`${API}/workflow-runs/${runId}/stop`, { method: 'POST' }); } catch { /* ignore */ }
    stopRun();
  };

  const runWorkflow = async () => {
    if (!selectedId) return;
    // 运行前先保存（保证服务端定义是最新的）
    await saveWorkflow();
    let params: Record<string, any> = {};
    try { params = JSON.parse(paramsText || '{}'); } catch {
      alertDialog({ message: '运行参数不是合法 JSON' }); return;
    }
    setRunning(true); setEvents([]); setNodeStatus({}); setApproval(null); setRunId(null);
    const controller = new AbortController();
    abortRef.current = controller;
    try {
      const res = await fetch(`${API}/workflows/${selectedId}/run`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ params }), signal: controller.signal,
      });
      if (!res.ok || !res.body) {
        const detail = await res.text().catch(() => '');
        alertDialog({ message: `启动失败：${detail || res.status}` });
        setRunning(false);
        return;
      }
      const reader = res.body.getReader();
      const decoder = new TextDecoder();
      const parser = new SSEStreamParser();
      const captureRunId = (d: any) => { if (d?.run_id && !runId) setRunId(d.run_id); };
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        for (const ev of parser.push(decoder.decode(value, { stream: true }))) {
          captureRunId(ev.data);
          setEvents(prev => [...prev, { event: ev.event, data: ev.data, ts: Date.now() }]);
          if (ev.event === 'node_start') setNodeStatus(prev => ({ ...prev, [ev.data.node_id]: 'running' }));
          if (ev.event === 'node_done') setNodeStatus(prev => ({ ...prev, [ev.data.node_id]: 'done' }));
          if (ev.event === 'node_error') setNodeStatus(prev => ({ ...prev, [ev.data.node_id]: 'error' }));
          if (ev.event === 'approval_required') setApproval({ nodeId: ev.data.node_id, label: ev.data.label, message: ev.data.message });
          if (ev.event === 'workflow_done' || ev.event === 'workflow_failed' || ev.event === 'workflow_stopped') {
            setRunning(false); setApproval(null);
          }
        }
      }
      setRunning(false);
    } catch (e: any) {
      if (e?.name !== 'AbortError') alertDialog({ message: `运行中断：${e?.message || e}` });
      setRunning(false);
    }
  };

  const respondApproval = async (approved: boolean, comment?: string) => {
    if (!runId) return;
    try {
      const r = await fetch(`${API}/workflow-runs/${runId}/approve`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ approved, comment: comment || '' }),
      });
      if (!r.ok) alertDialog({ message: `审批失败：${await r.text().catch(() => '')}` });
      else setApproval(null);
    } catch (e: any) { alertDialog({ message: `审批失败：${e?.message || e}` }); }
  };

  const onDefChange = (d: any) => { setDefinition(d); setDirty(true); };

  return (
    <div style={{ flex: 1, display: 'flex', minHeight: 0, background: colors.bgApp }}>
      {/* 左：工作流列表 */}
      <div style={{ width: 220, borderRight: `1px solid ${colors.borderDefault}`, background: colors.bgSidebar, display: 'flex', flexDirection: 'column' }}>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '10px 12px', borderBottom: `1px solid ${colors.borderSubtle}` }}>
          <span style={{ fontSize: 13, fontWeight: 600 }}>工作流</span>
          <button onClick={createWorkflow} style={{ border: 'none', background: 'transparent', cursor: 'pointer', color: colors.accentText, fontSize: 13 }}>
            <Icon name="plus" size={14} /> 新建
          </button>
        </div>
        <div style={{ flex: 1, overflowY: 'auto', padding: 6 }}>
          {workflows.length === 0 && (
            <div style={{ fontSize: 12, color: colors.textTertiary, padding: '16px 8px', lineHeight: 1.6 }}>
              还没有工作流。点「新建」创建你的第一个流程：拖入节点、连线、设定模型与提示词，即可重复执行。
            </div>
          )}
          {workflows.map(wf => (
            <div key={wf.id}
              onClick={() => selectWorkflow(wf)}
              style={{
                padding: '8px 10px', borderRadius: radius.s, cursor: 'pointer', marginBottom: 2,
                background: selectedId === wf.id ? colors.bgSelected : 'transparent',
                fontSize: 13, color: selectedId === wf.id ? colors.textPrimary : colors.textSecondary,
              }}>
              <div style={{ fontWeight: 500 }}>{wf.name}{wf.built_in ? '（内置）' : ''}</div>
              {wf.description && <div style={{ fontSize: 11, color: colors.textTertiary, marginTop: 2 }}>{wf.description}</div>}
            </div>
          ))}
        </div>
      </div>

      {/* 中：画布 + 运行监控 */}
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0 }}>
        {!selected ? (
          <div style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: 8, color: colors.textTertiary }}>
            <Icon name="layers" size={32} />
            <div style={{ fontSize: 14 }}>流程中心：新建或选择一个工作流开始编排</div>
            <div style={{ fontSize: 12 }}>节点类型：推理 / 工具 / 条件分支 / 并行 / 循环 / 人工审批</div>
          </div>
        ) : (
          <>
            {/* 工具栏 */}
            <div style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '8px 12px', borderBottom: `1px solid ${colors.borderDefault}`, background: colors.bgCard }}>
              <input style={{ ...input, width: 180 }} value={name} onChange={e => { setName(e.target.value); setDirty(true); }} />
              <input style={{ ...input, flex: 1 }} placeholder="描述（可选）" value={desc} onChange={e => { setDesc(e.target.value); setDirty(true); }} />
              <button style={{ ...btnPrimary, height: 26, fontSize: 12 }} onClick={saveWorkflow} disabled={!dirty && !validateMsg}>
                <Icon name="check" size={13} /> 保存{dirty ? ' *' : ''}
              </button>
              <button style={{ ...btnSecondary, height: 26, fontSize: 12 }} onClick={() => setShowJson(v => !v)}>
                <Icon name="file-text" size={13} /> {showJson ? '收起 JSON' : '查看 JSON'}
              </button>
              {!running ? (
                <button style={{ ...btnPrimary, height: 26, fontSize: 12 }} onClick={runWorkflow}>
                  <Icon name="play" size={13} /> 运行
                </button>
              ) : (
                <button style={{ ...btnDangerSoft, height: 26, fontSize: 12 }} onClick={stopRunServer}>
                  <Icon name="stop" size={13} /> 停止
                </button>
              )}
              {!selected.built_in && (
                <button style={{ ...btnDangerSoft, height: 26, fontSize: 12 }} onClick={deleteWorkflow} data-tip="删除工作流">
                  <Icon name="trash" size={13} />
                </button>
              )}
            </div>
            {validateMsg && <div style={{ ...calloutStyle('error'), margin: '6px 12px 0' }}>{validateMsg}</div>}
            {/* 运行参数 */}
            <div style={{ padding: '6px 12px', borderBottom: `1px solid ${colors.borderSubtle}`, background: colors.bgCard, display: 'flex', alignItems: 'center', gap: 6 }}>
              <span style={{ fontSize: 11, color: colors.textTertiary, flexShrink: 0 }}>运行参数（JSON，引用 {'{{params.名称}}'}）：</span>
              <input style={{ ...input, flex: 1, fontSize: 12, height: 26 }} value={paramsText} onChange={e => setParamsText(e.target.value)} placeholder='{"images": [], "dir": "..."}' />
            </div>
            {/* 画布 */}
            <WorkflowCanvas definition={definition} selectedNodeId={selectedNodeId} nodeStatus={nodeStatus} onSelectNode={setSelectedNodeId} />
            {/* 0.2.1（TS-119）：只读 JSON 查看——当前工作流定义的完整结构，供核对/复制 */}
            {showJson && (
              <div style={{ maxHeight: 220, overflowY: 'auto', borderTop: `1px solid ${colors.borderDefault}`, background: colors.bgCode, padding: '8px 12px' }}>
                <pre style={{ margin: 0, fontSize: 11, fontFamily: fonts.mono, color: colors.textPrimary, whiteSpace: 'pre-wrap', wordBreak: 'break-all' }}>
                  {JSON.stringify(definition, null, 2)}
                </pre>
              </div>
            )}
            {/* 审批卡片 */}
            {approval && (
              <div style={{ margin: 8, ...calloutStyle('warn'), alignItems: 'center' }}>
                <span style={{ flex: 1 }}><b>{approval.label}</b>：{approval.message}</span>
                <button style={{ ...btnPrimary, height: 24, fontSize: 12 }} onClick={() => respondApproval(true)}>通过</button>
                <button style={{ ...btnDangerSoft, height: 24, fontSize: 12 }} onClick={() => respondApproval(false)}>驳回</button>
              </div>
            )}
            {/* 事件流 */}
            <div style={{ maxHeight: 150, overflowY: 'auto', borderTop: `1px solid ${colors.borderDefault}`, background: colors.bgCard, padding: '6px 12px', fontFamily: fonts.mono, fontSize: 11 }}>
              {events.length === 0 && <div style={{ color: colors.textTertiary }}>运行事件将显示在这里。</div>}
              {events.map((ev, i) => (
                <div key={i} style={{ color: ev.event.includes('error') || ev.event === 'workflow_failed' ? colors.dangerText : colors.textSecondary, lineHeight: 1.7 }}>
                  {ev.event}{ev.data.node_id ? ` · ${ev.data.node_id}` : ''}{ev.data.error ? ` · ${ev.data.error}` : ''}{ev.data.output_preview ? ` · ${String(ev.data.output_preview).slice(0, 80)}` : ''}{ev.event === 'workflow_reply' && ev.data.text ? ` 💬 ${String(ev.data.text).slice(0, 120)}` : ''}
                </div>
              ))}
              {running && <div style={{ color: colors.accentText }}><Spinner size={12} /> 运行中…</div>}
            </div>
          </>
        )}
      </div>

      {/* 右：节点配置 */}
      {selected && selectedNodeId !== null && (
        <WorkflowEditor definition={definition} onChange={onDefChange}
          selectedNodeId={selectedNodeId} models={models} onClose={() => setSelectedNodeId(null)} />
      )}
    </div>
  );
}
