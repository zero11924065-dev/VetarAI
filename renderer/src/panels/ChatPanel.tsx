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
import React, { useState, useRef, useEffect, useCallback } from 'react';
import ReactMarkdown from 'react-markdown';
import remarkGfm from 'remark-gfm';
import { useSessionMessages, purgeSessionLocal, syncSessionLocal, Message, ToolStep } from '../hooks/useMessages';
import { SSEStreamParser } from '../lib/sseParser';
import { colors, fonts, radius, shadow, typo, card, btnPrimary, btnSecondary, btnGhost, btnDanger, btnDangerSoft, select as selectStyle, calloutStyle } from '../theme';
import { Icon, Spinner, IconName } from '../Icon';
import { confirmDialog, promptDialog } from '../Dialog';
import { on } from '../events';
import { WarehousePanel } from './WarehousePanel';
import { reportBusy } from '../busyState';

interface AgentConfig { id: string; name: string; role?: string; model_name?: string; type_: string; parent_agent_id?: string | null; system_prompt?: string | null; }
interface Session { id: string; title: string; message_count: number; }
interface PendingItem { name: string; dataUri: string; isImage: boolean; size: number; parsedText?: string; parsing?: boolean; parseFailed?: boolean; }

const API = getApiBase();

// TS-116（3.28）：消息时间戳格式化（SQLite datetime('now') 是 UTC，补 'Z' 解析）
function formatTime(isoString: string): string {
  if (!isoString) return '';
  const date = new Date(isoString.includes('T') ? isoString : isoString.replace(' ', 'T') + 'Z');
  if (isNaN(date.getTime())) return '';
  const now = new Date();
  const diffMs = now.getTime() - date.getTime();
  const diffMins = Math.floor(diffMs / 60000);
  if (diffMins < 1) return '刚刚';
  if (diffMins < 60) return `${diffMins} 分钟前`;
  const isToday = date.toDateString() === now.toDateString();
  if (isToday) return date.toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit' });
  const isYesterday = new Date(now.getTime() - 86400000).toDateString() === date.toDateString();
  if (isYesterday) return `昨天 ${date.toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit' })}`;
  return date.toLocaleDateString('zh-CN', { month: '2-digit', day: '2-digit' }) + ' ' +
         date.toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit' });
}
const IMAGE_MIMES = ['image/png','image/jpeg','image/webp','image/gif','image/bmp'];
// checkpoint-048：聊天上传支持办公文档（走后端附件解析端点）
const PARSEABLE_EXTS = ['.pdf','.docx','.xlsx','.xlsm','.csv','.txt','.md','.json','.yaml','.yml','.log','.ini'];

// TS-102 B14：流式/临时消息稳定 id 生成器（单调序号，同一毫秒内也不重复）
let localMsgSeq = 0;
function newLocalMsgId(): string { return `local_${Date.now()}_${++localMsgSeq}`; }

// ── M1-4：Markdown 流式渲染（未闭合 ``` 先当纯文本，闭合后转代码块）──
function StreamingMarkdown({ text }: { text: string }) {
  const openFences = (text.match(/```/g) || []).length;
  const balanced = openFences % 2 === 0;
  if (!text) return null;
  if (!balanced) {
    // 代码块未闭合 → 整段按 pre-wrap 纯文本，避免半截 markdown 抖动
    return <pre style={{ whiteSpace:'pre-wrap', wordBreak:'break-word', margin:0, fontFamily:'inherit', fontSize:14 }}>{text}</pre>;
  }
  return (
    <div style={{ fontSize:14, lineHeight:1.65, wordBreak:'break-word' }}>
      <ReactMarkdown remarkPlugins={[remarkGfm]} components={{
        code({ className, children, ...rest }: any) {
          const isBlock = /language-/.test(className || '');
          if (isBlock) return <pre style={{ background:colors.bgCode, padding:'8px 10px', borderRadius:radius.s, overflowX:'auto', fontSize:12.5, margin:'6px 0', border:`1px solid ${colors.borderSubtle}`, fontFamily:fonts.mono, lineHeight:1.6 }}><code className={className} style={{ fontFamily:fonts.mono, fontSize:12.5 }}>{children}</code></pre>;
          return <code style={{ background:colors.bgInlineCode, padding:'1px 5px', borderRadius:4, fontSize:12.5, fontFamily:fonts.mono }} {...rest}>{children}</code>;
        },
      }}>{text}</ReactMarkdown>
    </div>
  );
}

// ── M1-4：工具步骤折叠条 ──
function ToolStepBar({ step }: { step: ToolStep }) {
  const [open, setOpen] = useState(false);
  const label = step.status === 'running'
    ? `正在调用 ${step.name}…`
    : step.status === 'ok'
      ? `${step.name} 完成（${step.summary || 'ok'}）`
      : `${step.name} 失败：${step.error || 'unknown'}`;
  return (
    /* checkpoint-060：折叠条单行化修复重叠事故——旧实现行高固定 30px 但标签允许换行，
       长摘要（如委派交卷数百字）会在 flex 行内上下对称溢出，叠印到上下消息上。
       现标签单行省略号截断；完整摘要/错误/参数在展开区查看（信息不丢）。 */
    <div style={{ marginBottom:8, border:`1px solid ${colors.borderSubtle}`, borderRadius:radius.s, background:'#F5F5F7', overflow:'hidden' }}>
      <div onClick={() => setOpen(o=>!o)} style={{ display:'flex', alignItems:'center', gap:6, padding:'0 10px', height:30, cursor:'pointer', color:colors.textPrimary, fontSize:13 }}>
        {step.status === 'running' ? <Spinner size={12} /> : step.status === 'ok' ? <Icon name="check" size={14} style={{ color:colors.ok }} /> : <Icon name="x" size={14} style={{ color:colors.danger }} />}
        <span style={{ flex:1, minWidth:0, overflow:'hidden', whiteSpace:'nowrap', textOverflow:'ellipsis' }} title={label}>{label}</span>
        <Icon name={open ? 'chevron-up' : 'chevron-down'} size={14} style={{ color:colors.textTertiary }} />
      </div>
      {open && (
        <div style={{ padding:'8px 10px', borderTop:`1px solid ${colors.borderSubtle}`, fontSize:12, color:colors.textSecondary }}>
          {(step.summary || step.error) && (
            <div style={{ whiteSpace:'pre-wrap', wordBreak:'break-word', marginBottom:6, color: step.status === 'error' ? colors.dangerText : colors.textSecondary }}>
              {step.status === 'error' ? (step.error || 'unknown') : step.summary}
            </div>
          )}
          <pre style={{ margin:0, fontSize:12, color:colors.textSecondary, whiteSpace:'pre-wrap', wordBreak:'break-word', maxHeight:160, overflowY:'auto', fontFamily:fonts.mono }}>
{JSON.stringify(step.args ?? {}, null, 2)}
          </pre>
        </div>
      )}
    </div>
  );
}

// ── M5（TS-111）：模型降级引导卡片 ──
// 检测到"模型不存在"类错误时展示：一键切换其他本地模型（自动重发）/ 重新拉取该模型。
function ModelRescueBar({ projectId, agentId, currentModel, onSwitched }: {
  projectId: string; agentId: string; currentModel: string; onSwitched: () => void;
}) {
  const API2 = getApiBase();
  const [models, setModels] = useState<{ name: string }[]>([]);
  const [busy, setBusy] = useState(false);
  const [pulling, setPulling] = useState(false);
  const [info, setInfo] = useState<string | null>(null);

  useEffect(() => {
    fetch(`${API2}/ollama/models`).then(r => r.ok ? r.json() : []).then(d => {
      if (Array.isArray(d)) setModels(d as { name: string }[]);
    }).catch(() => {});
  }, [API2]);

  const candidates = models.filter(m => m.name !== currentModel);

  const switchTo = async (name: string) => {
    if (!name || busy) return;
    setBusy(true); setInfo(null);
    try {
      const res = await fetch(`${API2}/agents/${projectId}/${agentId}`, {
        method: 'PUT', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ model_name: name }),
      });
      if (!res.ok) { const d = await res.json().catch(() => ({})); throw new Error(d.detail || `HTTP ${res.status}`); }
      setInfo(`已切换到 ${name}，正在重新发送…`);
      setTimeout(() => onSwitched(), 400);
    } catch (e) { setInfo('切换失败: ' + (e as Error).message); }
    finally { setBusy(false); }
  };

  const repull = async () => {
    if (pulling) return;
    setPulling(true); setInfo(`正在拉取 ${currentModel} …（首次拉取可能较久）`);
    try {
      const res = await fetch(`${API2}/ollama/pull`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name: currentModel }),
      });
      if (!res.ok) { const d = await res.json().catch(() => ({})); throw new Error(d.detail || `HTTP ${res.status}`); }
      setInfo(`拉取完成：${currentModel}。请点击"重新发送"。`);
    } catch (e) { setInfo('拉取失败: ' + (e as Error).message); }
    finally { setPulling(false); }
  };

  return (
    <div style={{ ...calloutStyle('warn'), marginTop:8, flexDirection:'column' }}>
      <div style={{ marginBottom:6, fontSize:13, fontWeight:500 }}><Icon name="wrench" size={16} style={{ marginRight:6, verticalAlign:'middle' }} />模型「{currentModel}」不可用，可选：</div>
      <div style={{ display:'flex', gap:8, alignItems:'center', flexWrap:'wrap' }}>
        <select defaultValue="" onChange={e => switchTo(e.target.value)} disabled={busy || candidates.length === 0}
          style={{ ...selectStyle, fontSize:12, height:22, maxWidth:140 }}>
          <option value="" disabled>{candidates.length ? '一键切换到…' : '（无其他本地模型）'}</option>
          {candidates.map(m => <option key={m.name} value={m.name}>{m.name}</option>)}
        </select>
        <button className="ui-btn ui-btn-secondary" onClick={repull} disabled={pulling}
          style={{ ...btnSecondary, height:22, padding:'0 8px', fontSize:12 }}>
          {pulling ? '拉取中…' : `重新拉取 ${currentModel}`}
        </button>
      </div>
      {info && <div style={{ marginTop:6, fontSize:12 }}>{info}</div>}
    </div>
  );
}

// ── M6（TS-112）：视觉模型引导卡片 ──
// assistant 消息内容命中"[⚠️ 当前模型不支持多模态"时展示：
// 切换视觉模型（自动重发）/ 一键拉取 qwen2.5-vl（仅 ollama 后端）/ 知道了。
function VisionRescueCard({ projectId, agentId, currentModel, onSwitched }: {
  projectId: string; agentId: string; currentModel: string; onSwitched: () => void;
}) {
  const API2 = getApiBase();
  const [models, setModels] = useState<{ name: string }[]>([]);
  const [backend, setBackend] = useState<string>('ollama');
  const [busy, setBusy] = useState(false);
  const [pulling, setPulling] = useState(false);
  const [info, setInfo] = useState<string | null>(null);
  const [dismissed, setDismissed] = useState(false);

  useEffect(() => {
    fetch(`${API2}/ollama/models`).then(r => r.ok ? r.json() : []).then(d => {
      if (Array.isArray(d)) setModels(d as { name: string }[]);
    }).catch(() => {});
    fetch(`${API2}/inference/status`).then(r => r.ok ? r.json() : null).then(s => {
      if (s && typeof s.backend === 'string') setBackend(s.backend);
    }).catch(() => {});
  }, [API2]);

  // 视觉模型候选：名称含 vl / vision（排除当前模型）
  const visionCandidates = models.filter(m =>
    m.name !== currentModel && /vl|vision/i.test(m.name));

  const switchTo = async (name: string) => {
    if (!name || busy) return;
    setBusy(true); setInfo(null);
    try {
      const res = await fetch(`${API2}/agents/${projectId}/${agentId}`, {
        method: 'PUT', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ model_name: name }),
      });
      if (!res.ok) { const d = await res.json().catch(() => ({})); throw new Error(d.detail || `HTTP ${res.status}`); }
      setInfo(`已切换到 ${name}，正在重新发送…`);
      setTimeout(() => onSwitched(), 400);
    } catch (e) { setInfo('切换失败: ' + (e as Error).message); }
    finally { setBusy(false); }
  };

  const pullVision = async () => {
    if (pulling) return;
    setPulling(true); setInfo('正在拉取 qwen2.5-vl …（首次拉取可能较久）');
    try {
      const res = await fetch(`${API2}/ollama/pull`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name: 'qwen2.5-vl' }),
      });
      if (!res.ok) { const d = await res.json().catch(() => ({})); throw new Error(d.detail || `HTTP ${res.status}`); }
      setInfo('拉取完成：qwen2.5-vl。请从上方下拉框切换后自动重发，或点"重新发送"。');
    } catch (e) { setInfo('拉取失败: ' + (e as Error).message); }
    finally { setPulling(false); }
  };

  if (dismissed) return null;

  return (
    <div style={{ ...calloutStyle('success'), marginTop:8, flexDirection:'column' }}>
      <div style={{ marginBottom:6, fontSize:13, fontWeight:500 }}><Icon name="image" size={16} style={{ marginRight:6, verticalAlign:'middle' }} />当前模型不支持图片分析。可选：</div>
      <div style={{ display:'flex', gap:8, alignItems:'center', flexWrap:'wrap' }}>
        <select defaultValue="" onChange={e => switchTo(e.target.value)}
          disabled={busy || visionCandidates.length === 0}
          style={{ ...selectStyle, fontSize:12, height:22, maxWidth:140 }}>
          <option value="" disabled>{visionCandidates.length ? '切换视觉模型…' : '（无可用视觉模型）'}</option>
          {visionCandidates.map(m => <option key={m.name} value={m.name}>{m.name}</option>)}
        </select>
        {backend === 'ollama' && (
          <button className="ui-btn ui-btn-primary" onClick={pullVision} disabled={pulling}
            style={{ ...btnPrimary, height:22, padding:'0 8px', fontSize:12 }}>
            {pulling ? '拉取中…' : '一键拉取 qwen2.5-vl'}
          </button>
        )}
        <button className="ui-btn ui-btn-ghost" onClick={() => setDismissed(true)}
          style={{ ...btnGhost, height:22, padding:'0 8px', fontSize:12 }}>
          知道了
        </button>
      </div>
      {info && <div style={{ marginTop:6, fontSize:12 }}>{info}</div>}
    </div>
  );
}

export function ChatPanel({ projectId, agentId, jumpToSessionId, onJumpConsumed }: {
  projectId: string; agentId: string;
  // M7（TS-113 建议包4）：任务队列跳转——外部指定要切换到的会话
  jumpToSessionId?: string | null;
  onJumpConsumed?: () => void;
}) {
  const [input, setInput] = useState('');
  const [agentInfo, setAgentInfo] = useState<AgentConfig | null>(null);
  const [modelList, setModelList] = useState<{name:string}[]>([]);
  const [sessions, setSessions] = useState<Session[]>([]);
  const [currentSessionId, setCurrentSessionId] = useState<string | null>(null);
  const [pendingItems, setPendingItems] = useState<PendingItem[]>([]);
  const [sending, setSending] = useState(false);
  // TS-120（0.3.0）：知识仓库——勾选模式与选中消息、转移弹窗、右侧面板开关
  const [selectMode, setSelectMode] = useState(false);
  const [selectedMsgIds, setSelectedMsgIds] = useState<Set<number>>(new Set());
  const [showTransferModal, setShowTransferModal] = useState(false);
  const [transferScope, setTransferScope] = useState<'project' | 'global'>('project');
  const [transferTitle, setTransferTitle] = useState('');
  const [transferCategory, setTransferCategory] = useState('');
  const [transferKeywords, setTransferKeywords] = useState('');
  const [transferring, setTransferring] = useState(false);
  const [showKnowledgePanel, setShowKnowledgePanel] = useState(false);
  // 查虫K-3：转移序号——面板 key 的一部分，保证连续转移到同一作用域
  // （期间手动切过作用域）也能重新定位到转移目标作用域
  const [warehouseTransferSeq, setWarehouseTransferSeq] = useState(0);
  // checkpoint-059：活流标记——记录当前仍有进行中流的会话 id（H16 流继续场景）。
  // 切换/加载会话时，仅对该会话的缓存气泡跳过僵尸清理；其余会话的缓存视为"死态"清理。
  const activeStreamSidRef = useRef<string | null>(null);
  const messagesEndRef = useRef<HTMLDivElement>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);
  const abortRef = useRef<AbortController | null>(null);
  // 输入法组合态（IME composition）：用 ref 显式跟踪，拦截组合期内按回车导致的误发送。
  // 背景：macOS 中文输入法在 Chromium 下，确认候选词的回车有时以 isComposing:false 触发，
  // 仅靠 keydown 的 isComposing/keyCode 守卫不可靠，故改用 compositionstart/end 事件跟踪。
  const composingRef = useRef(false);
  // checkpoint-067 R-1：compositionend 时间戳——部分输入法（含 macOS）在"回车确认候选词"后，
  // 先触发 compositionend、紧接着再派发一个裸回车（此时 composing/isComposing 均已失效），
  // 若不忽略会导致空白内容被误发送。记录 end 时刻，窗口内的回车一律不发送。
  const compositionEndAtRef = useRef(0);
  // TS-102 B15：滚动控制 —— 距底 ≤100px 才跟随滚底；手动上滚则停止跟随并出"回到底部"按钮
  const scrollAreaRef = useRef<HTMLDivElement>(null);
  const autoScrollRef = useRef(true);
  const [showBackToBottom, setShowBackToBottom] = useState(false);
  // H17 问题2：区分"程序滚底"与"用户滚动"——程序滚底触发的 onScroll 不改变跟随状态，
  // 否则会覆盖用户刚发起的上滚意图（思考期内容短，距底永远 <100px，用户被持续拽回底部）
  const programmaticScrollRef = useRef(false);
  // B02（TS-101）：ref 存最新 sessionId，流式回调内用它做身份校验，防止串话
  const currentSessionIdRef = useRef<string | null>(null);
  useEffect(() => { currentSessionIdRef.current = currentSessionId; }, [currentSessionId]);
  // 独立于 sessionId 的本地消息缓存（避免 hook 内部闭包问题）
  const [localMessages, setLocalMessages] = useState<Message[]>([]);
  // 0.4.4：会话生成中上报忙碌态（关闭应用时弹确认）
  useEffect(() => { reportBusy('chat', sending); }, [sending]);
  // B07（TS-101）：ref 存最新 localMessages，done 时可读最终消息内容
  const localMessagesRef = useRef<Message[]>([]);
  useEffect(() => { localMessagesRef.current = localMessages; }, [localMessages]);

  // ── checkpoint-055：切回/加载丢消息修复 ──
  // 根因：① user 消息从不写本地缓存（仅 done 时同步 assistant），缓存天然残缺；
  // ② 加载策略"缓存优先"用残缺缓存覆盖，屏蔽了更完整的 DB 历史（DB 其实全在）。
  // 新策略：DB 为权威源；加载时合并「DB 全量 + 本地未落盘的流式气泡（local_* 前缀 id）」，
  // 既不丢进行中的气泡，也不让残缺缓存屏蔽 DB 历史。
  const loadingSidRef = useRef<string | null>(null);
  function mergeDbWithLocal(dbMsgs: Message[], local: Message[], live: boolean): Message[] {
    const dbIds = new Set(dbMsgs.map(m => String(m.id ?? '')));
    const dbByContent = new Set(dbMsgs.filter(m => m.content).map(m => `${m.role}::${m.content}`));
    const extra: Message[] = [];
    for (const m of local) {
      const key = String(m.id ?? '');
      if (key.startsWith('local_')) {
        // 流式气泡：若 DB 已有同角色同内容的定稿（流式期间已落盘），以 DB 为准不重复追加
        if (m.content && dbByContent.has(`${m.role}::${m.content}`)) continue;
        // 活流（该会话仍有进行中的流）→ 原样保留，流会继续推进（H16 语义）
        if (live) { extra.push(m); continue; }
        // checkpoint-059：僵尸气泡清理——空内容（且无工具步骤）的进行态气泡不恢复
        // （后端要么已完成、要么已中断，均以 DB 为准）；有内容的中断气泡恢复时清除
        // "思考中/等待秒数"等活态标记并标"已停止"（缓存恢复的流永远不会再推进，
        // 否则界面永远停在"思考中…已等待 Ns"卡死态）。
        const hasSubstance = (m.content || '').trim().length > 0 || ((m.toolSteps || []).length > 0);
        if (!hasSubstance) continue;
        extra.push({ ...m, thinking: false, waitingSeconds: 0, stopped: true });
      } else if (key && !dbIds.has(key)) {
        extra.push(m); // 本地 id 不在 DB（极端兜底）
      }
    }
    return [...dbMsgs, ...extra];
  }
  async function loadSessionMessages(sid: string) {
    loadingSidRef.current = sid;
    try {
      const res = await fetch(`${API}/sessions/${sid}/messages?project_id=${encodeURIComponent(projectId)}`);
      if (loadingSidRef.current !== sid) return; // 已切去别的会话，丢弃过期结果
      if (!res.ok) return;
      const msgs = await res.json();
      if (loadingSidRef.current !== sid) return;
      if (Array.isArray(msgs)) {
        // 本地快照统一读缓存：流式写穿（scheduleStreamCacheSync）保证缓存是完整活态，
        // 且天然按会话隔离——不读内存 ref，杜绝"ref 滞后/串会话"两类竞态
        let local: Message[] = [];
        try { local = JSON.parse(localStorage.getItem('subagent_messages_v4') || '{}')[sid] || []; } catch { local = []; }
        const live = activeStreamSidRef.current === sid;
        const merged = local.length > 0 ? mergeDbWithLocal(msgs as Message[], local, live) : (msgs as Message[]);
        setLocalMessages(merged);
        syncSessionLocal(sid, merged); // 合并结果回写缓存，缓存从此与 DB 对齐
        restoreTokenIndicator(merged);
      }
    } catch (e) { console.error('load messages:', e); }
    finally { if (loadingSidRef.current === sid) loadingSidRef.current = null; }
  }
  // M2 上下文指示器：tokenUsed（已用）+ contextLimit（上限）
  // 问题4修复：tokenUsed 语义从"模型上轮实际评估增量"（KV缓存复用时数值偏小且转移后不刷新）
  // 改为"未归档消息的实时估算"——与发送逻辑同源，转移入仓后立刻下降，反映真实上下文压力。
  const [tokenUsed, setTokenUsed] = useState<number>(0);
  const [contextLimit, setContextLimit] = useState<number>(0);
  const [contextSource, setContextSource] = useState<string>('');

  // 问题4：上下文估算——对未归档消息文本做 token 估计（启发式，与发送过滤规则一致：
  // 仅 user/assistant、排除 archived）。中文约 1 字 1 token，英文约 4 字符 1 token，
  // 混合文本按 0.6 系数近似。目的不是精确计费，而是让用户直观看到"移入仓库后确实变少了"。
  function estimateContextTokens(msgs: Message[]): number {
    let total = 0;
    for (const m of msgs) {
      if (m.archived) continue;
      if (m.role !== 'user' && m.role !== 'assistant') continue;
      total += Math.round(((m.content || '').length) * 0.6);
    }
    return total;
  }
  // M5（TS-111）：断线重连提示条 + 最大重试次数（读配置，默认 3）
  const [reconnectNotice, setReconnectNotice] = useState<string | null>(null);
  const reconnectMaxRef = useRef(3);
  useEffect(() => {
    fetch(`${API}/config`).then(r => r.ok ? r.json() : null).then((cfg: any) => {
      const n = Number(cfg?.reconnect_max_attempts);
      if (Number.isFinite(n) && n >= 1 && n <= 10) reconnectMaxRef.current = Math.floor(n);
    }).catch(() => {});
  }, []);
  // M2 溢出预警
  const [compactWarning, setCompactWarning] = useState<{used:number;limit:number;est:number}|null>(null);
  const [toast, setToast] = useState<string|null>(null);

  // M2：拉取上下文上限
  const fetchContextLimit = useCallback(async (model?: string) => {
    const m = model || agentInfo?.model_name || 'qwen3.8';
    try {
      const r = await fetch(`${API}/context/limit?model=${encodeURIComponent(m)}`);
      if (r.ok) {
        const d = await r.json();
        setContextLimit(d.context_limit || d.context_length || 0);
        setContextSource(d.source || '');
      }
    } catch { /* 不阻塞 */ }
  }, [agentInfo?.model_name]);

  useEffect(() => { fetchContextLimit(); }, [fetchContextLimit]);

  const msgHistory = useSessionMessages(currentSessionId || 'none');
  // H17 问题3（问题4重构）：恢复上下文用量指示器——改为对（未归档）消息实时估算，
  // 取最后一条带 prompt_eval_count 的历史值仅作为无消息可估时的兜底。
  function restoreTokenIndicator(msgs: Message[]) {
    const est = estimateContextTokens(msgs);
    if (est > 0) { setTokenUsed(est); return; }
    for (let i = msgs.length - 1; i >= 0; i--) {
      const v = (msgs[i] as Message).prompt_eval_count;
      if (typeof v === 'number' && v > 0) { setTokenUsed(v); return; }
    }
    setTokenUsed(0);
  }
  // 问题4：消息列表任何变化（发送/归档/切换/流式落盘）都即时重估，指示器始终反映真实上下文
  useEffect(() => {
    const est = estimateContextTokens(localMessages);
    if (est > 0) setTokenUsed(est);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [localMessages]);
  // 同步：当 currentSessionId 变化时，从 localStorage 读取（H16：useMessages 的 _store
  // 与 syncSessionLocal 写的 localStorage 可能不同步，直接读 localStorage 为准；
  // 缓存为空时保留现有状态，避免清空进行中的流式内容）
  useEffect(() => {
    if (currentSessionId) {
      // checkpoint-055：缓存仅瞬显防白屏，随后一律以 DB 为准合并加载
      try {
        const store = JSON.parse(localStorage.getItem('subagent_messages_v4') || '{}');
        const cached = store[currentSessionId];
        if (Array.isArray(cached) && cached.length > 0) {
          // checkpoint-059：活流会话原样瞬显（流还在推进）；其余会话瞬显前清理僵尸气泡
          // （空内容进行态丢弃；有内容的去活态标记，避免恢复后"思考中"动画永久定格）
          const isLive = activeStreamSidRef.current === currentSessionId;
          const view = isLive ? (cached as Message[]) : (cached as Message[])
            .filter(m => !(String(m.id ?? '').startsWith('local_') && !(m.content || '').trim() && !((m.toolSteps || []).length)))
            .map(m => String(m.id ?? '').startsWith('local_') ? { ...m, thinking: false, waitingSeconds: 0, stopped: m.stopped || true } : m);
          if (view.length > 0) {
            setLocalMessages(view);
            restoreTokenIndicator(view);
          }
        }
      } catch {}
      loadSessionMessages(currentSessionId);
    } else {
      setLocalMessages([]);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [currentSessionId]);

  // ── 数据加载 ──
  const fetchAgentData = useCallback(async () => {
    try {
      const [agentRes, modelsRes] = await Promise.all([
        fetch(`${API}/agents/${projectId}`).then(r => r.json()),
        fetch(`${API}/ollama/models`).then(r => r.json()),
      ]);
      if (Array.isArray(agentRes)) setAgentInfo(agentRes.find((a:any) => a.id === agentId) || null);
      if (Array.isArray(modelsRes)) setModelList(modelsRes as {name:string}[]);
    } catch (e) { console.error('agent data:', e); }
  }, [projectId, agentId]);

  // TS-115（3.26）：5s 超时 + 失败重试 1 次（后端 list_sessions JOIN 已消除 N+1，
  // 前端兜底防"委派任务运行时写锁竞争 → 前端挂起 → 只显示部分会话"）
  const fetchSessions = useCallback(async (retry = false): Promise<Session[] | null> => {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 5000);
    try {
      const res = await fetch(`${API}/sessions?project_id=${projectId}&agent_id=${agentId}`, {
        signal: controller.signal,
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      if (Array.isArray(data)) {
        setSessions(data as Session[]);
        return data as Session[];
      }
    } catch (e) {
      if (!retry) {
        // 失败重试 1 次（含超时 / 网络错 / HTTP 错）
        return fetchSessions(true);
      }
      console.error('sessions:', e);
    } finally {
      clearTimeout(timer);
    }
    return null;
  }, [projectId, agentId]);
  // 刷新按钮 loading 态
  const [refreshing, setRefreshing] = useState(false);
  const handleRefreshSessions = useCallback(async () => {
    setRefreshing(true);
    try {
      await fetchSessions();
    } finally {
      setRefreshing(false);
    }
  }, [fetchSessions]);

  useEffect(() => { fetchAgentData(); }, [fetchAgentData]);

  // TS-115（3.30）：AgentPanel 修改模型后 emit('agent:updated') → 此处刷新 agentInfo，
  // 确保 getEffectiveModel() 立即返回新模型（无需刷新页面/重启应用）。
  useEffect(() => {
    const unsub = on('agent:updated', (data: any) => {
      if (data && data.agent_id === agentId && data.project_id === projectId) {
        fetch(`${API}/agents/${projectId}`)
          .then(r => r.json())
          .then((list: any) => {
            const updated = Array.isArray(list) ? list.find((a: any) => a.id === agentId) : null;
            if (updated) setAgentInfo(updated);
          })
          .catch(e => console.error('agent:updated refresh failed:', e));
      }
    });
    return unsub;
  }, [agentId, projectId]);

  // 初始化：加载会话列表 → 选第一个或新建 → 加载消息
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const data = (await fetchSessions()) || [];
      if (cancelled) return;

      let targetSessionId: string | null = null;

      if (data.length > 0) {
        targetSessionId = data[0].id;
      } else {
        // 没有会话，自动新建一个
        try {
          const res = await fetch(`${API}/sessions`, {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ project_id: projectId, agent_id: agentId, title: '会话 1' }),
          });
          if (res.ok) {
            const d = await res.json();
            targetSessionId = d.session_id;
            setSessions([{ id: d.session_id, title: '会话 1', message_count: 0 }]);
          }
        } catch (e) { console.error('auto-create session:', e); }
      }

      if (targetSessionId && !cancelled) {
        // checkpoint-055：只负责选定会话，加载统一由 [currentSessionId] effect 触发（缓存瞬显 + DB 合并）
        setCurrentSessionId(targetSessionId);
      }
    })();
    return () => { cancelled = true; };
  }, [projectId, agentId]); // 只在 agent 变化时初始化

  // ── 切换会话 ──
  // checkpoint-055：缓存瞬显（防白屏）+ 切 id 触发合并加载；加载竞态由 loadingSidRef 守卫
  function handleSwitchSession(sid: string) {
    if (sid === currentSessionId) return;
    try {
      const store = JSON.parse(localStorage.getItem('subagent_messages_v4') || '{}');
      const cached = store[sid];
      if (Array.isArray(cached) && cached.length > 0) {
        setLocalMessages(cached);
        restoreTokenIndicator(cached);
      } else {
        setLocalMessages([]); // 无缓存：清空显示加载态
      }
    } catch { setLocalMessages([]); }
    setCurrentSessionId(sid);
  }

  // M7（TS-113 建议包4）：任务队列跳转——会话列表加载后切到指定会话
  useEffect(() => {
    if (!jumpToSessionId || sessions.length === 0) return;
    if (jumpToSessionId === currentSessionId) {
      onJumpConsumed?.();
      return;
    }
    if (sessions.some(s => s.id === jumpToSessionId)) {
      handleSwitchSession(jumpToSessionId);
      onJumpConsumed?.();
    } else {
      // 会话不存在（可能已被清理）→ 仅消费，不误导用户
      onJumpConsumed?.();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [jumpToSessionId, sessions]);

  // ── 新建会话 ──
  async function handleNewSession() {
    try {
      const res = await fetch(`${API}/sessions`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ project_id: projectId, agent_id: agentId, title: `会话 ${sessions.length + 1}` }),
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const d = await res.json();
      const newSession: Session = { id: d.session_id, title: `会话 ${sessions.length + 1}`, message_count: 0 };
      setSessions(prev => [newSession, ...prev]);
      setCurrentSessionId(d.session_id);
      setLocalMessages([]); // 新会话 = 空白
    } catch (e) { console.error('new session:', e); }
  }

  // ── M7（TS-113）：导出会话为 Markdown（走统一默认导出目录）──
  // 0.2.4（Z1 修复）：FastAPI 422 的 detail 是对象数组，直接拼接会渲染成
  // "[object Object]"。_errMsg 统一提取可读文案。
  const _errMsg = (d: any, status: number): string => {
    const detail = d?.detail;
    if (typeof detail === 'string') return detail;
    if (Array.isArray(detail)) {
      const msgs = detail.map((x: any) => x?.msg || '').filter(Boolean).join('；');
      return msgs || `请求参数错误（HTTP ${status}）`;
    }
    if (detail && typeof detail === 'object') return JSON.stringify(detail);
    return `HTTP ${status}`;
  };
  async function handleExportSession() {
    if (!currentSessionId) return;
    try {
      setToast('正在导出…');
      const res = await fetch(`${API}/sessions/${currentSessionId}/export?project_id=${encodeURIComponent(projectId)}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ project_id: projectId, agent_id: agentId }),
      });
      const d = await res.json();
      if (!res.ok) throw new Error(_errMsg(d, res.status));
      setToast(`已导出：${d.name}`);
      setTimeout(() => setToast(null), 4000);
    } catch (e) {
      setToast('导出失败: ' + (e as Error).message);
      setTimeout(() => setToast(null), 4000);
    }
  }

  // ── checkpoint-048（需求 3.6）：会话自动总结（模型生成 → 落 MD+DB）──
  const [summarizing, setSummarizing] = useState(false);
  async function handleSummarizeSession() {
    if (!currentSessionId || summarizing) return;
    setSummarizing(true);
    setToast('正在生成总结…');
    try {
      const res = await fetch(`${API}/sessions/${currentSessionId}/summarize?project_id=${encodeURIComponent(projectId)}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ project_id: projectId, agent_id: agentId, model: getEffectiveModel() }),
      });
      const d = await res.json();
      if (!res.ok) throw new Error(_errMsg(d, res.status));
      setToast(`总结已保存 ✓（${d.saved_file?.split('/').pop() || ''}）`);
      setTimeout(() => setToast(null), 5000);
    } catch (e) {
      setToast('总结失败: ' + (e as Error).message);
      setTimeout(() => setToast(null), 5000);
    } finally {
      setSummarizing(false);
    }
  }

  // ── TS-120（0.3.0）：知识仓库——勾选消息转移入库 ──
  // TS-121（问题3）：流式消息用 local_ 临时 id 渲染，DB 落库后才是数字 id；
  // 勾选框只认数字 id（后端 transfer 也只认数字 id）。流结束后用 DB 对齐本地 id，
  // 勾选模式即刻可用（此前要等切窗重进触发重载才出现勾选框）。
  async function alignLocalIdsWithDb(sid: string) {
    try {
      const res = await fetch(`${API}/sessions/${sid}/messages?project_id=${encodeURIComponent(projectId)}`);
      if (!res.ok) return;
      // 查虫D：对齐期间用户可能已切走会话——过期结果不得覆盖新会话显示
      if (currentSessionIdRef.current !== sid) return;
      const dbMsgs = (await res.json()) as Message[];
      const prev = localMessagesRef.current;
      if (!prev.some(m => String(m.id ?? '').startsWith('local_'))) return;
      // 查虫B：同内容消息可能出现多条（如"继续"），按内容排队取号，
      // 避免 Map 覆盖导致第二条永远拿不到数字 id。
      const dbByKey = new Map<string, Message[]>();
      for (const d of dbMsgs) {
        if (!d.content) continue;
        const key = `${d.role}::${d.content}`;
        const arr = dbByKey.get(key);
        if (arr) arr.push(d); else dbByKey.set(key, [d]);
      }
      const next = prev.map(m => {
        if (!String(m.id ?? '').startsWith('local_')) return m;
        const key = m.content ? `${m.role}::${m.content}` : '';
        const arr = key ? dbByKey.get(key) : undefined;
        const hit = arr && arr.length > 0 ? arr.shift() : undefined;
        if (!hit) return m; // 内容未命中 → 留给位置兜底
        // 以 DB 数字 id 为准；本地展示扩展字段（思考/完成用时等）迁移过去不丢
        const { id: _lid, ...localExtras } = m as Message & Record<string, unknown>;
        return { ...hit, ...localExtras, id: hit.id } as Message;
      });
      // 查虫K-5：位置兜底——停止生成后后端落盘内容可能被截断（与本地气泡不一致），
      // 按「同角色、时序顺序」把仍为 local_ 的消息对到 DB 剩余未消费的消息上。
      const dbConsumed = new Set(next.filter(m => typeof m.id === 'number').map(m => m.id));
      const dbLeft = dbMsgs.filter(d => !dbConsumed.has(d.id));
      let cursor = 0;
      const aligned = next.map(m => {
        if (!String(m.id ?? '').startsWith('local_')) return m;
        for (let i = cursor; i < dbLeft.length; i++) {
          if (dbLeft[i].role === m.role) {
            const hitDb = dbLeft[i];
            // 中间跳过的不同角色消息视为无对应（保持时序不乱配）
            cursor = i + 1;
            const { id: _lid, ...localExtras } = m as Message & Record<string, unknown>;
            return { ...hitDb, ...localExtras, id: hitDb.id } as Message;
          }
        }
        return m; // DB 确实没有（尚未落盘）→ 保留临时态
      });
      setLocalMessages(aligned);
      syncSessionLocal(sid, aligned); // 缓存同步对齐，刷新/切回后仍是数字 id
    } catch { /* 对齐失败静默：不影响会话本身 */ }
  }

  async function handleTransferToWarehouse() {
    if (!currentSessionId || selectedMsgIds.size === 0) return;
    setTransferring(true);
    try {
      const res = await fetch(`${API}/knowledge/transfer`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          project_id: projectId,
          session_id: currentSessionId,
          message_ids: Array.from(selectedMsgIds),
          scope: transferScope,
          title: transferTitle.trim() || undefined,
          category: transferCategory.trim(),
          keywords: transferKeywords.trim()
            ? transferKeywords.split(/[,，、\s]+/).filter(Boolean)
            : [],
        }),
      });
      const d = await res.json();
      if (!res.ok) throw new Error(_errMsg(d, res.status));
      // 标记已选消息为归档（脱离上下文、占位显示）
      // TS-121（问题2连带）：此前 syncSessionLocal 写的是未标记的旧 localMessages，
      // 归档态没进缓存 → 刷新/切回后占位消失。改用同一份 next 写状态与缓存。
      const nextArchived = localMessagesRef.current.map(m =>
        typeof m.id === 'number' && selectedMsgIds.has(m.id) ? { ...m, archived: true } : m);
      setLocalMessages(nextArchived);
      if (currentSessionId) syncSessionLocal(currentSessionId, nextArchived);
      setToast(`已移入知识仓库 ✓（${d.title}）`);
      setTimeout(() => setToast(null), 4000);
      // 关闭弹窗、清空勾选；自动展开右侧面板（问题2：转移后即时可见新条目）。
      // 查虫K-3：转移序号递增 + key 含作用域，连续转移同一作用域也能重新定位。
      setShowTransferModal(false);
      setSelectedMsgIds(new Set());
      setSelectMode(false);
      setShowKnowledgePanel(true);
      setWarehouseTransferSeq(v => v + 1);
      setTransferTitle(''); setTransferCategory(''); setTransferKeywords('');
    } catch (e) {
      setToast('转移失败: ' + (e as Error).message);
      setTimeout(() => setToast(null), 4000);
    } finally {
      setTransferring(false);
    }
  }

  function toggleMessageSelect(msgId: number | string | undefined) {
    if (typeof msgId !== 'number') return;
    setSelectedMsgIds(prev => {
      const next = new Set(prev);
      if (next.has(msgId)) next.delete(msgId); else next.add(msgId);
      return next;
    });
  }

  // ── 删除会话 ──
  async function handleDeleteSession(sid: string) {
    const ok = await confirmDialog({ title: '删除会话', message: '确定删除此会话？所有消息将永久清除。', danger: true, confirmText: '删除' });
    if (!ok) return;
    try {
      await fetch(`${API}/sessions/${sid}?project_id=${projectId}`, { method: 'DELETE' });
      purgeSessionLocal(sid);
      setSessions(prev => prev.filter(s => s.id !== sid));
      if (currentSessionId === sid) {
        setCurrentSessionId(null);
        setLocalMessages([]);
        // 如果还有其他会话，切到第一个
        const remaining = sessions.filter(s => s.id !== sid);
        if (remaining.length > 0) {
          handleSwitchSession(remaining[0].id);
        }
      }
    } catch (e) { console.error('delete session:', e); }
  }

  // ── 重命名会话 ──
  async function handleRenameSession(sid: string) {
    // checkpoint-051 S2：window.prompt 替换为自定义输入弹窗（交互语义不变：取消=不改名）
    const newTitle = await promptDialog({ title: '重命名会话', defaultValue: '未命名会话', confirmText: '保存', cancelText: '取消' });
    if (!newTitle) return;
    try {
      await fetch(`${API}/sessions/${sid}?project_id=${projectId}`, {
        method: 'PUT', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ title: newTitle }),
      });
      setSessions(prev => prev.map(s => s.id === sid ? { ...s, title: newTitle } : s));
    } catch (e) { console.error('rename:', e); }
  }

  // TS-102 B15：仅当用户贴近底部（≤100px）时才自动滚底；手动上滚即暂停跟随
  function handleScroll() {
    const el = scrollAreaRef.current;
    if (!el) return;
    if (programmaticScrollRef.current) {
      // 本次滚动由程序滚底触发 → 不改变跟随状态（H17 问题2）
      programmaticScrollRef.current = false;
      return;
    }
    const distFromBottom = el.scrollHeight - el.scrollTop - el.clientHeight;
    const atBottom = distFromBottom <= 100;
    autoScrollRef.current = atBottom;
    setShowBackToBottom(!atBottom);
  }
  // H17 问题2：滚轮直接表达用户意图——向上滚立即停止跟随（不依赖 100px 阈值；
  // 思考期内容很短，用户上滑距离永远到不了 100px，旧逻辑会把页面持续拽回底部）
  function handleWheel(e: React.WheelEvent) {
    if (e.deltaY < 0) {
      autoScrollRef.current = false;
      setShowBackToBottom(true);
    } else if (e.deltaY > 0) {
      const el = scrollAreaRef.current;
      if (el && el.scrollHeight - el.scrollTop - el.clientHeight <= 100) {
        autoScrollRef.current = true;
        setShowBackToBottom(false);
      }
    }
  }
  function scrollToBottom() {
    const el = scrollAreaRef.current;
    if (el) {
      programmaticScrollRef.current = true;
      el.scrollTo({ top: el.scrollHeight, behavior: 'auto' });
    }
    autoScrollRef.current = true;
    setShowBackToBottom(false);
  }
  useEffect(() => {
    if (autoScrollRef.current) {
      // TS-102 B15：用 auto（即时）而非 smooth——smooth 动画中途会触发 onScroll 且距底 >100px，
      // 会被误判为"用户上滚"而中断跟随
      programmaticScrollRef.current = true;
      messagesEndRef.current?.scrollIntoView({ behavior: 'auto' });
    }
  }, [localMessages]);

  function getEffectiveModel(): string { return agentInfo?.model_name || 'qwen3.8'; }

  // ── 上传 ──
  function handleUpload() { fileInputRef.current?.click(); }

  async function handleFileChange(e: React.ChangeEvent<HTMLInputElement>) {
    const files = e.target.files;
    if (!files || !files.length) return;
    const newItems: PendingItem[] = [];
    for (const file of Array.from(files)) {
      const dataUri = await new Promise<string>((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve(reader.result as string);
        reader.onerror = reject;
        reader.readAsDataURL(file);
      });
      newItems.push({ name: file.name, dataUri, isImage: file.type.startsWith('image/'), size: file.size });
    }
    setPendingItems(prev => [...prev, ...newItems]);
    e.target.value = '';

    // checkpoint-048：可解析的文档（PDF/Word/Excel/CSV/文本族）调后端解析端点提取文本
    for (const item of newItems) {
      const ext = item.name.toLowerCase();
      const parseable = !item.isImage && PARSEABLE_EXTS.some(pe => ext.endsWith(pe));
      if (!parseable) continue;
      const b64 = item.dataUri.split(',')[1] || '';
      setPendingItems(prev => prev.map(p => p.name === item.name && p.dataUri === item.dataUri ? { ...p, parsing: true } : p));
      try {
        const res = await fetch(`${API}/attachments/parse`, {
          method: 'POST', headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ name: item.name, content_base64: b64 }),
        });
        const d = await res.json();
        if (!res.ok) throw new Error(d.detail || `HTTP ${res.status}`);
        setPendingItems(prev => prev.map(p =>
          p.name === item.name && p.dataUri === item.dataUri
            ? { ...p, parsing: false, parsedText: d.text || undefined, parseFailed: !d.text }
            : p));
      } catch (err) {
        setPendingItems(prev => prev.map(p =>
          p.name === item.name && p.dataUri === item.dataUri ? { ...p, parsing: false, parseFailed: true } : p));
      }
    }
  }

  function removePending(idx: number) { setPendingItems(prev => prev.filter((_, i) => i !== idx)); }

  // ── 发送 ──
  // M2：警告条未处理前禁止发送
  const inputDisabled = !!compactWarning;

  async function handleSend() {
    if (sending) return;
    // checkpoint-067 R-1：严格判定空白——除常规空白外，零宽字符（\u200B-\u200F）、
    // 不换行空格（\u00A0）、BOM（\uFEFF）、其他控制/格式字符（\u00AD、\u2060）也算空白，
    // 杜绝输入法误插入的不可见字符被当成有内容而发送"空白消息"。
    const cleanText = input.replace(/[\s\u00A0\u200B-\u200F\u2060\uFEFF\u00AD]/g, '');
    const hasText = cleanText.length > 0;
    const hasImages = pendingItems.some(p => p.isImage);
    if (!hasText && !hasImages) return;

    if (!currentSessionId) {
      await handleNewSession();
      return;
    }

    setSending(true);
    const imageItems = pendingItems.filter(p => p.isImage);
    const textFileItems = pendingItems.filter(p => !p.isImage);

    const parts: string[] = [];
    if (hasText) parts.push(cleanText);
    if (imageItems.length) parts.push(`[📎 ${imageItems.length} 张图片已附加]`);
    if (textFileItems.length) parts.push(textFileItems.map(f => `[📄 ${f.name}]`).join(' '));

    const userMsg: Message = { id: newLocalMsgId(), role: 'user', content: parts.join('\n'), pending_images: imageItems.map(i => i.dataUri) };

    // 立即更新 UI
    const newLocal = [...localMessages, userMsg];
    setLocalMessages(newLocal);
    // checkpoint-055：user 消息立即写缓存（此前仅 done 时同步 assistant，缓存残缺是切回丢消息根因之一）
    if (currentSessionId) syncSessionLocal(currentSessionId, newLocal);
    setInput('');
    setPendingItems([]);

    const modelUsed = getEffectiveModel();
    // TS-120（0.3.0）：已移入知识仓库（archived）的消息不进入模型上下文
    const apiMessages = newLocal
      .filter(m => (m.role === 'user' || m.role === 'assistant') && !m.archived)
      .map(m => ({ role: m.role, content: m.content }));

    // checkpoint-048：附件文本优先用后端解析结果（PDF/Word/Excel/CSV/文本族）；
    // 解析中/失败的文件仅作文件名标注，不阻塞发送
    // checkpoint-067 R-2（用户拍板"完整优先，宁慢勿断"）：律所分析客户材料要求内容完整，
    // 不得截断——附件文字【全额注入】，单文件上限由后端放宽保障；
    // 超时风险改由后端放宽流式读超时承担，前端不再牺牲完整性。
    const textFileContents: string[] = textFileItems
      .filter(f => f.parsedText)
      .map(f => `[${f.name}]\n${f.parsedText}`);

    const finalMessages = [...apiMessages];
    if (textFileContents.length && finalMessages.length > 0) {
      const lastIdx = finalMessages.length - 1;
      finalMessages[lastIdx] = { ...finalMessages[lastIdx], content: finalMessages[lastIdx].content + '\n\n--- 附件内容 ---\n' + textFileContents.join('\n\n') };
    }

    // 创建占位 assistant 气泡（流式累加用）
    // B02（TS-101）：streamSid 冻结本流归属会话；B05：气泡带稳定 id，事件按 id 定位写入
    const streamSid = currentSessionId;
    activeStreamSidRef.current = streamSid; // checkpoint-059：登记活流归属，供加载时区分活/死态
    const assistantMsg: Message = {
      id: newLocalMsgId(), // TS-102 B14：改用单调序号生成器，杜绝同毫秒碰撞
      role: 'assistant', content: '', model_used: modelUsed,
      toolSteps: [], step: 0, maxStep: 5, tokensUsed: 0,
      startedAt: Date.now(), // TS-116（3.29）：气泡出现时间
    };
    setLocalMessages(prev => [...prev, assistantMsg]);
    const streamMsgId = assistantMsg.id!;

    const controller = new AbortController();
    abortRef.current = controller;
    // checkpoint-055：流式内容实时写穿缓存（500ms 节流）。缓存因此始终是完整"活态"，
    // 合并加载统一以缓存为本地快照——消除"内存快照滞后/串会话"竞态（切走切回不丢气泡）。
    let lastCacheSync = 0;
    let cacheSyncTimer: ReturnType<typeof setTimeout> | null = null;
    function scheduleStreamCacheSync() {
      const doSync = () => {
        cacheSyncTimer = null;
        if (currentSessionIdRef.current !== streamSid) return; // 已切走：归属保护，不写旧会话
        lastCacheSync = Date.now();
        setLocalMessages(prev => { syncSessionLocal(streamSid, prev); return prev; });
      };
      if (cacheSyncTimer) return; // 已有挂起的同步
      const elapsed = Date.now() - lastCacheSync;
      if (elapsed >= 500) doSync();
      else cacheSyncTimer = setTimeout(doSync, 500 - elapsed);
    }
    // 节流：token 高频时 rAF 合并一次 setState（避免每 token 重渲染卡 UI）
    // B05（TS-101）：按 streamMsgId 定位目标气泡，不再盲写"最后一条"
    let rafId = 0;
    const flushAcc = () => {
      rafId = 0;
      if (currentSessionIdRef.current !== streamSid) { accContent = ''; return; }
      if (!accContent) return;
      const c = accContent; accContent = '';
      setLocalMessages(prev => {
        const idx = prev.findIndex(m => m.id === streamMsgId);
        if (idx < 0) return prev;
        const next = [...prev];
        next[idx] = { ...next[idx], content: (next[idx].content || '') + c };
        return next;
      });
      scheduleStreamCacheSync();
    };
    let accContent = '';
    // 问题（0.4.2实测·长思考界面静默）修复：旧版用一次性 sawContent 守卫，
    // 导致【首轮正文之后的思考增量全被丢弃】——首轮先出正文、后续轮长思考时界面静默、
    // 思考计时停跳。改为"阶段化"：思考指示随每个思考阶段开/关，任意一轮思考都可见、
    // 计时持续跳动，并附简版思考预览（让你实时知道 agent 在想什么、不是空转）。
    let thinkingStartedAt: number | null = null;
    let thinkingElapsedTimer: ReturnType<typeof setInterval> | null = null;
    // B05：工具事件也按 id 定位（防止数组变化时落到错误气泡）
    const patchStreamMsg = (patch: (m: Message) => Message) => {
      if (currentSessionIdRef.current !== streamSid) return;
      setLocalMessages(prev => {
        const idx = prev.findIndex(m => m.id === streamMsgId);
        if (idx < 0) return prev;
        const next = [...prev];
        next[idx] = patch(next[idx]);
        return next;
      });
      scheduleStreamCacheSync();
    };
    // 阶段化思考：开/关当前思考阶段（可多次开闭）
    const startThinkingPhase = () => {
      thinkingStartedAt = Date.now();
      if (thinkingElapsedTimer) clearInterval(thinkingElapsedTimer);
      thinkingElapsedTimer = setInterval(() => {
        patchStreamMsg(mm => mm.thinking
          ? { ...mm, thinkingElapsed: Math.round((Date.now() - (thinkingStartedAt || Date.now())) / 1000) }
          : mm);
      }, 1000);
      patchStreamMsg(m => m.thinking ? m : { ...m, thinking: true, thinkingElapsed: 0 });
    };
    const closeThinkingPhase = () => {
      if (thinkingElapsedTimer) { clearInterval(thinkingElapsedTimer); thinkingElapsedTimer = null; }
      patchStreamMsg(m => {
        if (!m.thinking) return m;
        const duration = thinkingStartedAt ? Math.round((Date.now() - thinkingStartedAt) / 1000) : undefined;
        return { ...m, thinking: false, thinkingElapsed: undefined,
          ...(duration !== undefined ? { thinkingDuration: duration } : {}) };
      });
    };

    const applyEvent = (ev: { event: string; data: any }) => {
      const d = ev.data || {};
      if (ev.event === 'token') {
        accContent += (typeof d.delta === 'string' ? d.delta : '');
        if (!rafId) rafId = requestAnimationFrame(flushAcc);
        // 正文到达 = 当前思考阶段结束（每轮都成立，不再一次性）
        closeThinkingPhase();
      } else if (ev.event === 'thinking') {
        // 思考增量（任意轮）→ 阶段化显示：思考中 + 每秒跳动 + 简版预览
        startThinkingPhase();
        const delta = typeof d.delta === 'string' ? d.delta : '';
        if (delta) {
          patchStreamMsg(m => ({ ...m, thinkingPreview: ((m.thinkingPreview || '') + delta).slice(-120) }));
        }
      } else if (ev.event === 'tool_call') {
        closeThinkingPhase(); // 模型停止思考去调工具，关闭当前思考阶段
        patchStreamMsg(m => ({ ...m, toolSteps: [...(m.toolSteps||[]), { id: d.id||'', name: d.name||'tool', args: d.args, status: 'running' as const }] }));
      } else if (ev.event === 'tool_result') {
        patchStreamMsg(m => ({ ...m, toolSteps: (m.toolSteps||[]).map(st =>
          st.id === d.id ? { ...st, status: d.ok ? 'ok' as const : 'error' as const, summary: d.summary, error: d.error } : st) }));
      } else if (ev.event === 'state') {
        // 问题4：不再用 prompt_eval_count 覆盖指示器——那是"本轮实际评估增量"（KV缓存复用时偏小）。
        // 指示器统一由"未归档消息实时估算"驱动（见 localMessages 变化的 effect）。
        // prompt_eval_count 仍记录到消息对象，供调试/历史参考。
        patchStreamMsg(m => ({ ...m, step: d.step, maxStep: d.max, tokensUsed: d.tokens_used,
          ...(typeof d.prompt_eval_count === 'number' ? { prompt_eval_count: d.prompt_eval_count } : {}) }));
      } else if (ev.event === 'error') {
        patchStreamMsg(m => {
          const completedDuration = m.startedAt
            ? Math.round((Date.now() - m.startedAt) / 1000)
            : undefined;
          return {
            ...m, streamError: d.detail || '生成出错', thinking: false, thinkingElapsed: undefined,
            thinkingPreview: undefined, stopped: true,
            ...(completedDuration !== undefined ? { completedDuration } : {}),
          };
        });
      } else if (ev.event === 'auth_request') {
        // 敏感操作授权弹窗（2026-08-28 权限宽松化）：仅当 Agent 要【删除】系统敏感位置
        // （系统目录/用户关键资产/应用数据）时弹出确认框。其余操作默认放行，不弹窗。
        const rid = d.request_id;
        const toolName = d.tool_name || '未知工具';
        const targetPath = d.target_path || '未知路径';
        const actionLabel = d.action === 'delete' ? '删除' : d.action === 'write' ? '写入' : d.action === 'mkdir' ? '新建目录' : d.action === 'read' ? '读取' : d.action === 'list' ? '列出' : d.action || '操作';
        // 异步执行，不阻塞 SSE 事件循环
        (async () => {
          const allowed = await confirmDialog({
            title: '操作授权',
            message: `Agent 请求${actionLabel}敏感位置的内容：\n\n${targetPath}\n\n工具：${toolName}\n\n该操作位于系统敏感区域，是否允许？`,
            danger: true,
            confirmText: '允许',
            cancelText: '拒绝',
          });
          try {
            await fetch(`${API}/auth/respond`, {
              method: 'POST', headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ request_id: rid, allowed }),
            });
          } catch (e) { console.error('auth respond failed:', e); }
        })();
      } else if (ev.event === 'compact_required') {
        setCompactWarning({ used: d.used, limit: d.limit, est: d.est_rounds_left });
        setSending(false);
      }
      // done → 最终 content 以 done 为准（覆盖已累加，保证完整）
      if (ev.event === 'done') {
        if (rafId) { cancelAnimationFrame(rafId); rafId = 0; }
        closeThinkingPhase(); // 收尾：清思考计时器与阶段标记
        patchStreamMsg(m => {
          let content = m.content || '';
          if (typeof d.content === 'string') content = d.content;
          else if (accContent) content = content + accContent;
          // TS-116（3.29）：计算完成用时（气泡出现 → done）
          const completedDuration = m.startedAt
            ? Math.round((Date.now() - m.startedAt) / 1000)
            : undefined;
          return {
            ...m, content, thinking: false, thinkingElapsed: undefined, thinkingPreview: undefined,
            stopped: true,
            ...(completedDuration !== undefined ? { completedDuration } : {}),
          };
        });
        if (accContent) { /* done 已覆盖，丢弃残留 */ }
        accContent = '';
        // B02：message_count 用冻结的 streamSid，不用闭包 currentSessionId
        setSessions(prev => prev.map(s => s.id === streamSid ? { ...s, message_count: s.message_count + 2 } : s));
        // B07（TS-101）：流式完成 → 本地缓存同步（刷新/重启后可恢复）。
        // 按 streamMsgId 精确定位本流消息（不依赖数组顺序/身份），直接写缓存。
        const finalMsg = localMessagesRef.current.find(m => m.id === streamMsgId)
          || { id: streamMsgId, role: 'assistant', content: (typeof d.content === 'string' ? d.content : '') };
        // checkpoint-061：缓存读取加保护——缓存损坏时 JSON.parse 抛错会被外层误判为
        // 网络错误触发重连循环；损坏即按空缓存兜底（DB 已有定稿，不丢消息）。
        let existing: any[] = [];
        try { existing = JSON.parse(localStorage.getItem('subagent_messages_v4') || '{}')[streamSid] || []; } catch { existing = []; }
        // checkpoint-055：本轮 user 消息确保在缓存（此前只落 assistant，缓存残缺是丢消息根因之一）。
        // user 在发送时已按序写入，这里仅兜底补入（不重排，保持时序）
        const others = existing.filter((m: any) => m.id !== streamMsgId);
        const hasUser = others.some((m: any) => m.id === userMsg.id);
        syncSessionLocal(streamSid, hasUser ? [...others, finalMsg] : [...others, userMsg, finalMsg]);
        if (currentSessionIdRef.current === streamSid) {
          setLocalMessages(prev => {
            const idx = prev.findIndex(m => m.id === streamMsgId);
            if (idx >= 0) return prev;
            return [...prev, finalMsg as Message];
          });
        }
      }
    };

    try {
      // ===== M5（TS-111）：重连退避循环 =====
      // 错误分类：400/404 等业务错误（模型不存在/参数错误）立即终止不重试；
      // 网络错误/5xx/流中途断开 → 指数退避重连（1s→2s→4s… 上限 30s + 0~300ms jitter），
      // 次数取配置；重连请求带 skip_user_persist=true（user 消息首次已落库，防重复）。
      const maxAttempts = reconnectMaxRef.current;
      let attempt = 0;
      let usedSkipPersist = false;   // 首次请求已落库 user，后续重连一律跳过
      while (true) {
        // 长加载计时：发送后 8s 未收到正文 → 气泡显示等待秒数（每秒刷新）。
        // H19 修复：清除条件必须是"首个正文 token"——thinking/tool_call 等事件几秒内就会到达，
        // 若任何事件都清除计时器，指示器永远到不了 8s 阈值；用户真正等待的是正文输出。
        const waitTimer = setInterval(() => {
          patchStreamMsg(m => ({ ...m, waitingSeconds: (m.waitingSeconds || 0) + 1 }));
        }, 1000);
        const stopWaitTimer = () => clearInterval(waitTimer);
        const gotFirstContent = { v: false };
        const origApplyEvent = applyEvent;
        const applyEventWrapped = (ev: { event: string; data: any }) => {
          if (!gotFirstContent.v && ev.event === 'token') {
            gotFirstContent.v = true;
            stopWaitTimer();
            patchStreamMsg(m => (m.waitingSeconds ? { ...m, waitingSeconds: 0 } : m));
          }
          origApplyEvent(ev);
        };
        try {
          const res = await fetch(`${API}/ollama/chat/stream`, {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
              agent_id: agentId, model: modelUsed, project_id: projectId,
              session_id: currentSessionId, messages: finalMessages,
              images: imageItems.map(i => i.dataUri),
              skip_user_persist: usedSkipPersist,
            }),
            signal: controller.signal,
          });
          if (!res.ok || !res.body) {
            const errBody = await res.text().catch(() => '');
            const err = new Error(`HTTP ${res.status}: ${errBody.slice(0,200) || res.statusText}`);
            (err as any).httpStatus = res.status;
            stopWaitTimer();
            throw err;
          }
          const reader = res.body.getReader();
          const decoder = new TextDecoder();
          const parser = new SSEStreamParser();
          while (true) {
            const { value, done } = await reader.read();
            if (done) break;
            for (const ev of parser.push(decoder.decode(value, { stream: true }))) applyEventWrapped(ev);
          }
          for (const ev of parser.flush()) applyEventWrapped(ev);
          stopWaitTimer();
          break; // 流正常读完 → 结束
        } catch (e: any) {
          if (typeof stopWaitTimer === 'function') stopWaitTimer();
          if (e?.name === 'AbortError') {
            // 用户主动停止 → 真断流（后端 CancelledError 静默结束，B06 已截断落盘 DB），保留已渲染内容 + 标记
            if (rafId) { cancelAnimationFrame(rafId); rafId = 0; }
            const c = accContent; accContent = '';
            patchStreamMsg(m => ({ ...m, content: (m.content || '') + c + '（已停止）', stopped: true, thinking: false }));
            // B07：停止时的已生成部分也同步本地缓存
            setLocalMessages(prev => { syncSessionLocal(streamSid, prev); return prev; });
            break;
          }
          // M5 错误分类：业务错误（400/404）立即终止不重试；网络/5xx/流中断走重连
          const status = e?.httpStatus;
          const isBusinessError = status === 400 || status === 404 || status === 422;
          if (isBusinessError || attempt >= maxAttempts) {
            patchStreamMsg(m => ({
              ...m,
              streamError: isBusinessError
                ? (e.message || '请求失败')
                : `连接中断，已重试 ${attempt} 次仍失败。已保留已生成内容：${e.message || ''}`.trim(),
              errorKind: isBusinessError ? 'business' : 'network',
              thinking: false,
            }));
            setReconnectNotice(null);
            break;
          }
          attempt += 1;
          usedSkipPersist = true;
          const backoff = Math.min(30000, 1000 * Math.pow(2, attempt - 1)) + Math.floor(Math.random() * 300);
          setReconnectNotice(`正在恢复连接…（第 ${attempt}/${maxAttempts} 次，${Math.round(backoff / 1000)}s 后重试）`);
          await new Promise(r => setTimeout(r, backoff));
        }
      }
    } catch (e: any) {
      if (e?.name === 'AbortError') {
        // 用户主动停止 → 真断流（后端 CancelledError 静默结束，B06 已截断落盘 DB），保留已渲染内容 + 标记
        if (rafId) { cancelAnimationFrame(rafId); rafId = 0; }
        const c = accContent; accContent = '';
        patchStreamMsg(m => ({ ...m, content: (m.content || '') + c + '（已停止）', stopped: true, thinking: false }));
        // B07：停止时的已生成部分也同步本地缓存
        setLocalMessages(prev => { syncSessionLocal(streamSid, prev); return prev; });
      } else {
        const errMsg: Message = { id: newLocalMsgId(), role: 'assistant', content: `❌ ${e.message || '请求失败'}`, model_used: getEffectiveModel() };
        setLocalMessages(prev => [...prev, errMsg]);
      }
    } finally {
      abortRef.current = null;
      setSending(false);
      activeStreamSidRef.current = null; // checkpoint-059：流结束，清除活流标记
      setReconnectNotice(null);
      // TS-121（问题3）：user 消息落库后把 local_ 临时 id 换成 DB 数字 id，勾选模式即刻可用
      if (streamSid) alignLocalIdsWithDb(streamSid);
    }
  }

  // 停止生成（AbortController 真断流）
  function handleStop() {
    abortRef.current?.abort();
  }

  function resendLast() {
    // M5 做指数退避自动重连；本任务：手动重发上一条 user 消息
    const lastUser = [...localMessages].reverse().find(m => m.role === 'user');
    if (lastUser) { setInput(lastUser.content); }
  }

  const modelUsed = getEffectiveModel();

  // Token 进度条颜色三档
  const tokenRatio = contextLimit > 0 ? tokenUsed / contextLimit : 0;
  const tokenBarColor = tokenRatio >= 0.99 ? colors.danger : tokenRatio >= 0.90 ? colors.warn : colors.ok;

  return (
    <div style={{ display:'flex', height:'100%', minWidth:0, overflow:'hidden', background:colors.bgApp }}>
    {/* 左侧：原会话面板（纵向）；右侧：知识仓库面板（可折叠）。
        0.4.4：顶部/左右加留白——顶栏此前紧贴窗口外框，视觉上"贴边"。 */}
    <div style={{ display:'flex', flexDirection:'column', height:'100%', flex:1, minWidth:0, overflow:'hidden', padding:'10px 12px 0 12px' }}>
      {/* Top bar (§8.6) */}
      <div style={{ height:48, padding:'0 16px', borderBottom:`1px solid ${colors.borderSubtle}`, display:'flex', justifyContent:'space-between', alignItems:'center', gap:8, flexShrink:0 }}>
        {/* TS-121：nowrap——右侧知识仓库面板展开收窄会话区时，按钮组不得换行把顶栏撑高挤内容。
            0.4.0 实测重叠根治：原生 select 被压缩时文字不裁剪会向左溢出覆盖相邻元素（实测盖住 Agent 名），
            必须用"容器收缩 + overflow 裁剪"包裹；名字保留最小宽度 + 省略号。 */}
        <div style={{display:'flex',alignItems:'center',gap:8,flexWrap:'nowrap',minWidth:0}}>
          <div style={{display:'flex',alignItems:'center',gap:6,flexShrink:1,minWidth:48}}>
            <Icon name="bot" size={16} style={{color:colors.textPrimary,flexShrink:0}} />
            <span style={{fontSize:14,fontWeight:600,color:colors.textPrimary,whiteSpace:'nowrap',overflow:'hidden',textOverflow:'ellipsis'}}>{agentInfo?.name || agentId.slice(0,8)}...</span>
          </div>
          {/* select 收缩容器：flex 容器负责压缩，overflow:hidden 裁剪，杜绝文字溢出覆盖 */}
          <div style={{flex:'0 1 auto',minWidth:0,maxWidth:200,overflow:'hidden'}}>
            <select
              value={currentSessionId || ''}
              onChange={e => handleSwitchSession(e.target.value)}
              style={{...selectStyle, width:'100%', minWidth:80}}
            >
              {sessions.length === 0 && <option value="">无会话</option>}
              {sessions.map(s => (
                <option key={s.id} value={s.id}>{s.title} ({s.message_count}条)</option>
              ))}
            </select>
          </div>
          {/* 图标按钮组（TS-121：整体不可压缩，宽度不足时顶栏横向滚动而非换行） */}
          <div style={{display:'flex',alignItems:'center',gap:8,flexShrink:0}}>
          {/* TS-115（3.26）：会话列表刷新按钮 */}
          <button className="ui-btn ui-btn-ghost" onClick={handleRefreshSessions} data-tip="刷新会话列表" disabled={refreshing}
            style={{width:28,height:28,padding:0,display:'inline-flex',alignItems:'center',justifyContent:'center',borderRadius:radius.s,background:'transparent',border:'none',cursor:'pointer'}}>
            {refreshing
              ? <Spinner size={14} />
              : <Icon name="rotate-cw" size={15} style={{color:colors.textSecondary}} />}
          </button>
          <button className="ui-btn ui-btn-ghost" onClick={handleNewSession} data-tip="新建会话"
            style={{width:28,height:28,padding:0,display:'inline-flex',alignItems:'center',justifyContent:'center',borderRadius:radius.s,background:'transparent',border:'none',cursor:'pointer'}}>
            <Icon name="plus" size={16} style={{color:colors.textSecondary}} />
          </button>
          {currentSessionId && (
            <>
              <button className="ui-btn ui-btn-ghost" onClick={handleSummarizeSession} disabled={summarizing}
                title="生成会话总结并保存（Markdown + 记录）"
                style={{width:28,height:28,padding:0,display:'inline-flex',alignItems:'center',justifyContent:'center',borderRadius:radius.s,background:'transparent',border:'none',cursor:summarizing?'wait':'pointer'}}>
                {summarizing ? <Spinner size={14} /> : <Icon name="file-text" size={16} style={{color:colors.textSecondary}} />}
              </button>
              <button className="ui-btn ui-btn-ghost" onClick={handleExportSession} data-tip="导出会话为 Markdown"
                style={{width:28,height:28,padding:0,display:'inline-flex',alignItems:'center',justifyContent:'center',borderRadius:radius.s,background:'transparent',border:'none',cursor:'pointer'}}>
                <Icon name="download" size={16} style={{color:colors.textSecondary}} />
              </button>
              {/* TS-120：勾选消息移入知识仓库 */}
              <button className="ui-btn ui-btn-ghost"
                onClick={() => { setSelectMode(v => !v); setSelectedMsgIds(new Set()); }}
                data-tip="勾选消息 → 移入知识仓库"
                style={{width:28,height:28,padding:0,display:'inline-flex',alignItems:'center',justifyContent:'center',borderRadius:radius.s,background:selectMode?colors.accentBg:'transparent',border:'none',cursor:'pointer'}}>
                <Icon name="check" size={16} style={{color:selectMode?colors.accentText:colors.textSecondary}} />
              </button>
              {/* TS-120：知识仓库面板开关（可收起） */}
              <button className="ui-btn ui-btn-ghost"
                onClick={() => setShowKnowledgePanel(v => !v)}
                data-tip="知识仓库（检索/注入）"
                style={{width:28,height:28,padding:0,display:'inline-flex',alignItems:'center',justifyContent:'center',borderRadius:radius.s,background:showKnowledgePanel?colors.accentBg:'transparent',border:'none',cursor:'pointer'}}>
                <Icon name="database" size={16} style={{color:showKnowledgePanel?colors.accentText:colors.textSecondary}} />
              </button>
              <button className="ui-btn ui-btn-ghost" onClick={() => handleRenameSession(currentSessionId)} data-tip="重命名"
                style={{width:28,height:28,padding:0,display:'inline-flex',alignItems:'center',justifyContent:'center',borderRadius:radius.s,background:'transparent',border:'none',cursor:'pointer'}}>
                <Icon name="pencil" size={16} style={{color:colors.textSecondary}} />
              </button>
              <button className="ui-btn ui-btn-ghost ui-ico-danger" onClick={() => handleDeleteSession(currentSessionId)} data-tip="删除"
                style={{width:28,height:28,padding:0,display:'inline-flex',alignItems:'center',justifyContent:'center',borderRadius:radius.s,background:'transparent',border:'none',cursor:'pointer'}}>
                <Icon name="trash" size={16} style={{color:colors.textSecondary}} />
              </button>
            </>
          )}
          </div>
        </div>
        <div style={{display:'flex',alignItems:'center',gap:8,flexShrink:0}}>
          <span style={{fontFamily:fonts.mono,fontSize:12,color:colors.textTertiary}}>{modelList.find(m=>m.name===modelUsed)?.name || modelUsed}</span>
          {contextLimit > 0 && (
            <div
              title={`当前会话上下文估算：约 ${tokenUsed} / 上限 ${contextLimit}（按未移入仓库的对话实时估算，移入仓库后即下降；非模型精确计费口径）`}
              style={{display:'flex',alignItems:'center',gap:6,fontSize:11, cursor:'help'}}>
              <span style={{color:colors.textTertiary}}>上下文 ≈{tokenUsed} / {contextLimit}</span>
              <div style={{width:80,height:6,background:colors.borderDefault,borderRadius:3,overflow:'hidden'}}>
                <div style={{
                  width: Math.min(100, tokenRatio * 100) + '%',
                  height: '100%',
                  background: tokenBarColor,
                  transition: 'width 0.3s',
                }} />
              </div>
            </div>
          )}
          {contextLimit === 0 && contextSource === 'error' && (
            <span style={{color:colors.dangerText,fontSize:11}}>上下文：获取失败</span>
          )}
        </div>
      </div>

      {/* M2 溢出预警警告条 (§8.7) */}
      {compactWarning && (
        <div style={{ ...calloutStyle('warn'), borderRadius:0, padding:'10px 16px', borderBottom:`1px solid ${colors.warnBorder}`, flexWrap:'wrap' }}>
          <Icon name="alert-triangle" size={16} style={{flexShrink:0}} />
          <span>上下文已用 {compactWarning.used}/{compactWarning.limit}（{Math.round(compactWarning.used/compactWarning.limit*100)}%），预计还能约 {compactWarning.est >= 0 ? compactWarning.est : '未知'} 轮。请选择处理方式：</span>
          <div style={{display:'flex',gap:8,flexWrap:'wrap'}}>
            <button className="ui-btn ui-btn-primary" onClick={async () => {
              try {
                await fetch(`${API}/sessions/${currentSessionId}/compact`, { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({}) });
                setCompactWarning(null);
                setToast('已压缩，继续任务中...');
                setTimeout(() => setToast(null), 3000);
                const msgs = localMessagesRef.current;
                const lastUser = [...msgs].reverse().find((m:any) => m.role === 'user');
                if (lastUser) { setInput(lastUser.content); setTimeout(() => handleSend(), 500); }
              } catch (e) { setToast('压缩失败: ' + (e as Error).message); }
            }} style={{...btnPrimary, height:28}}>智能压缩</button>
            <button className="ui-btn ui-btn-secondary" onClick={async () => {
              setCompactWarning(null);
              await handleNewSession();
              setToast('已开新会话，请重新描述任务');
              setTimeout(() => setToast(null), 3000);
            }} style={{...btnSecondary, height:28}}>清空开新会话</button>
            <button className="ui-btn ui-btn-danger-soft" onClick={async () => {
              try {
                const cfg = await fetch(`${API}/config`).then((r:any)=>r.json());
                const dir = cfg.compact_archive_dir || '~/.subagent/compressed';
                await fetch(`${API}/sessions/${currentSessionId}/export`, { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({ dir }) });
                setCompactWarning(null);
                await handleNewSession();
                setToast('已导出并开新会话');
                setTimeout(() => setToast(null), 3000);
              } catch (e) { setToast('导出失败: ' + (e as Error).message); }
            }} style={{...btnDangerSoft, height:28}}>导出后清空</button>
          </div>
        </div>
      )}
      {/* Toast (§6.6) */}
      {toast && <div style={{ position:'absolute', top:60, right:16, background:colors.bgToast, color:'#FFFFFF', padding:'8px 14px', borderRadius:radius.s, fontSize:13, zIndex:999, boxShadow:shadow.m }}>{toast}</div>}

      {/* TS-120：勾选模式浮动栏（选中 N 条 → 移入知识仓库） */}
      {selectMode && (
        <div style={{ position:'absolute', bottom:90, left:'50%', transform:'translateX(-50%)', display:'flex', alignItems:'center', gap:8, background:colors.bgCard, border:`1px solid ${colors.borderDefault}`, borderRadius:radius.m, padding:'8px 14px', boxShadow:shadow.m, zIndex:998 }}>
          <span style={{ fontSize:12, color:colors.textSecondary }}>已勾选 {selectedMsgIds.size} 条</span>
          <button className="ui-btn ui-btn-primary" disabled={selectedMsgIds.size === 0 || transferring}
            onClick={() => setShowTransferModal(true)}
            style={{ ...btnPrimary, height:26, fontSize:12 }}>
            {transferring ? <Spinner size={12} /> : null} 移入知识仓库
          </button>
          <button className="ui-btn ui-btn-ghost" onClick={() => { setSelectMode(false); setSelectedMsgIds(new Set()); }}
            style={{ ...btnGhost, height:26, fontSize:12 }}>取消</button>
        </div>
      )}

      {/* TS-120：转移弹窗（选作用域/标题/分类/关键词） */}
      {showTransferModal && (
        <div style={{ position:'absolute', inset:0, background:'rgba(0,0,0,0.35)', display:'flex', alignItems:'center', justifyContent:'center', zIndex:1000 }}
          onClick={() => setShowTransferModal(false)}>
          <div onClick={e => e.stopPropagation()}
            style={{ width:400, background:colors.bgCard, borderRadius:radius.l, boxShadow:shadow.l, padding:20 }}>
            <div style={{ display:'flex', alignItems:'center', gap:8, marginBottom:14 }}>
              <Icon name="database" size={16} style={{ color:colors.accentText }} />
              <span style={{ fontSize:14, fontWeight:600, color:colors.textPrimary }}>移入知识仓库</span>
              <span style={{ fontSize:12, color:colors.textTertiary }}>（{selectedMsgIds.size} 条）</span>
            </div>
            <div style={{ fontSize:12, color:colors.textTertiary, marginBottom:10, lineHeight:1.6 }}>
              勾选的对话将保存为知识条目并脱离本会话上下文（不再发给模型）。内容以 .md 文件永久保存，你删除前一直在。
            </div>
            <div style={{ marginBottom:10 }}>
              <div style={{ fontSize:12, color:colors.textSecondary, marginBottom:4 }}>保存范围</div>
              <div style={{ display:'flex', gap:6 }}>
                {(['project', 'global'] as const).map(s => (
                  <button key={s} onClick={() => setTransferScope(s)}
                    style={{ flex:1, padding:'6px 0', fontSize:12, borderRadius:radius.s, cursor:'pointer',
                      border: transferScope===s ? `1px solid ${colors.accentBorder}` : `1px solid ${colors.borderStrong}`,
                      background: transferScope===s ? colors.accentBg : colors.bgCard,
                      color: transferScope===s ? colors.accentText : colors.textSecondary }}>
                    {s === 'project' ? '本项目（项目文件夹/知识库）' : '全局（所有项目可用）'}
                  </button>
                ))}
              </div>
            </div>
            <div style={{ marginBottom:10 }}>
              <div style={{ fontSize:12, color:colors.textSecondary, marginBottom:4 }}>标题（留空自动取首条前 20 字）</div>
              <input value={transferTitle} onChange={e => setTransferTitle(e.target.value)} placeholder="留空自动生成"
                style={{ padding:'6px 10px', borderRadius:radius.s, border:`1px solid ${colors.borderStrong}`, background:colors.bgCard, color:colors.textPrimary, fontSize:13, width:'100%', boxSizing:'border-box' }} />
            </div>
            <div style={{ display:'flex', gap:8, marginBottom:14 }}>
              <div style={{ flex:1 }}>
                <div style={{ fontSize:12, color:colors.textSecondary, marginBottom:4 }}>分类（可选）</div>
                <input value={transferCategory} onChange={e => setTransferCategory(e.target.value)} placeholder="如：客户材料"
                  style={{ padding:'6px 10px', borderRadius:radius.s, border:`1px solid ${colors.borderStrong}`, background:colors.bgCard, color:colors.textPrimary, fontSize:13, width:'100%', boxSizing:'border-box' }} />
              </div>
              <div style={{ flex:1 }}>
                <div style={{ fontSize:12, color:colors.textSecondary, marginBottom:4 }}>关键词（可选，逗号分隔）</div>
                <input value={transferKeywords} onChange={e => setTransferKeywords(e.target.value)} placeholder="如：聊天,证据"
                  style={{ padding:'6px 10px', borderRadius:radius.s, border:`1px solid ${colors.borderStrong}`, background:colors.bgCard, color:colors.textPrimary, fontSize:13, width:'100%', boxSizing:'border-box' }} />
              </div>
            </div>
            <div style={{ display:'flex', gap:8, justifyContent:'flex-end' }}>
              <button className="ui-btn ui-btn-ghost" onClick={() => setShowTransferModal(false)} style={{ ...btnGhost, height:28 }}>取消</button>
              <button className="ui-btn ui-btn-primary" disabled={transferring} onClick={handleTransferToWarehouse}
                style={{ ...btnPrimary, height:28 }}>
                {transferring ? <Spinner size={12} /> : null} 确认转移
              </button>
            </div>
          </div>
        </div>
      )}

      {/* M5（TS-111）：断线重连提示条 (§8.8) */}
      {reconnectNotice && (
        <div style={{ ...calloutStyle('warn'), borderRadius:0, padding:'6px 16px', borderBottom:`1px solid ${colors.warnBorder}` }}>
          <Spinner size={14} />
          <span style={{fontSize:13}}>{reconnectNotice}</span>
        </div>
      )}

      {/* Messages (§8.9) */}
      <div ref={scrollAreaRef} onScroll={handleScroll} onWheel={handleWheel} style={{ flex:1, overflowY:'auto', padding:16, position:'relative', background:colors.bgApp }}>
        {localMessages.length === 0 && (
          <div style={{textAlign:'center',marginTop:'30vh',display:'flex',flexDirection:'column',alignItems:'center',gap:8}}>
            <Icon name="message-circle" size={36} style={{color:'#C9C9CF'}} />
            <span style={{fontSize:13,color:colors.textTertiary}}>{currentSessionId ? '新会话 — 开始对话吧' : '加载中...'}</span>
          </div>
        )}
        {localMessages.map((msg, i) => {
          const isUser = msg.role === 'user';
          const isSystem = msg.role === 'system';
          const bubbleBg = isUser ? colors.accent : isSystem ? colors.okBg : colors.bgCard;
          const bubbleBorder = isUser ? 'none' : isSystem ? `1px solid ${colors.okBorder}` : `1px solid ${colors.borderDefault}`;
          const bubbleColor = isUser ? colors.onAccent : isSystem ? colors.okText : colors.textPrimary;
          const bubbleRadius = isUser ? `${radius.m}px ${4}px ${radius.m}px ${radius.m}px` : radius.m;
          return (
            <div key={msg.id || i} style={{ marginBottom:12, display:'flex', flexDirection:'column', alignItems: isUser ? 'flex-end' : 'flex-start' }}>
              {/* 角色标签行 */}
              <div style={{fontSize:11,color:colors.textTertiary,marginBottom:4,display:'flex',alignItems:'center',gap:4}}>
                {/* TS-120：勾选模式下显示复选框（系统消息不可勾选）。TS-121：流结束后
                    alignLocalIdsWithDb 已把 local_ 临时 id 换成 DB 数字 id，勾选即刻可用。
                    查虫K-2：已归档（已在仓库）的消息不显示勾选框，防止重复转移生成重复条目 */}
                {selectMode && !isSystem && !msg.archived && typeof msg.id === 'number' && (
                  <input type="checkbox" checked={selectedMsgIds.has(msg.id)}
                    onChange={() => toggleMessageSelect(msg.id)}
                    style={{ accentColor: colors.accent, cursor: 'pointer' }} />
                )}
                <Icon name={isUser ? 'user' : isSystem ? 'info' : 'bot'} size={12} />
                {isUser ? '你' : isSystem ? '系统' : (msg.model_used || 'AI')}
                {msg.created_at && <span style={{marginLeft:4,opacity:0.7}}>{formatTime(msg.created_at)}</span>}
              </div>
              {/* 气泡 */}
              <div style={{ maxWidth:'78%', padding:'10px 14px', borderRadius:bubbleRadius, background:bubbleBg, border:bubbleBorder, color:bubbleColor }}>
                {msg.archived ? (
                  /* TS-120：已移入知识仓库 → 占位提示（内容脱离模型上下文，文件永久保存在仓库） */
                  <div style={{ fontSize:12, color: colors.textTertiary, display:'flex', alignItems:'center', gap:6, fontStyle:'italic' }}>
                    <Icon name="database" size={13} />
                    此内容已移入知识仓库，不再参与对话上下文
                  </div>
                ) : (
                <>
                {(() => {
                  // 0.1.71（TS-118）：pending_images=本地流式附着图；images=DB 落库的委派附着图（子会话回看）
                  const _imgs = msg.pending_images ?? msg.images;
                  return _imgs && _imgs.length > 0 ? (
                    <div style={{marginBottom:6}}>{_imgs.map((uri,j) => <img key={j} src={uri} alt="img" style={{maxWidth:150,maxHeight:150,borderRadius:radius.s,marginRight:4,verticalAlign:'top',border:`1px solid ${colors.borderDefault}`}} />)}</div>
                  ) : null;
                })()}
                {/* 思考中指示（阶段化：任意轮思考都显示，秒数每秒跳动，附简版预览） */}
                {msg.role === 'assistant' && msg.thinking && (
                  <div style={{ ...calloutStyle('info'), marginBottom:8, flexDirection: 'column', alignItems: 'flex-start', gap: 4 }}>
                    <span style={{ display: 'inline-flex', alignItems: 'center', gap: 6 }}>
                      <Spinner size={14} />
                      <span>思考中… {msg.thinkingElapsed != null ? `${msg.thinkingElapsed}s` : ''}</span>
                    </span>
                    {/* 简版思考预览：让你实时知道 agent 在想什么（只留末尾 120 字） */}
                    {msg.thinkingPreview && (
                      <span style={{ fontSize: 11, color: colors.textTertiary, lineHeight: 1.5,
                        display: '-webkit-box', WebkitLineClamp: 3, WebkitBoxOrient: 'vertical', overflow: 'hidden',
                        wordBreak: 'break-word', width: '100%' }}>
                        {msg.thinkingPreview}
                      </span>
                    )}
                  </div>
                )}
                {/* checkpoint-067b D-1：思考完成后保留显示思考用时 */}
                {msg.role === 'assistant' && !msg.thinking && (
                  <div style={{ fontSize:11, color:colors.textTertiary, marginBottom:6, display:'inline-flex', alignItems:'center', gap:8 }}>
                    {msg.thinkingDuration != null && msg.thinkingDuration > 0 && (
                      <span style={{display:'inline-flex',alignItems:'center',gap:4}}>
                        <Icon name="clock" size={12} /> 思考 {msg.thinkingDuration}s
                      </span>
                    )}
                    {msg.completedDuration != null && msg.completedDuration > 0 && (
                      <span style={{display:'inline-flex',alignItems:'center',gap:4}}>
                        <Icon name="check-circle" size={12} /> 完成 {msg.completedDuration}s
                      </span>
                    )}
                  </div>
                )}
                {/* M1-4：工具折叠条（在 content 上方，顺序堆叠） */}
                {msg.toolSteps && msg.toolSteps.length > 0 && (
                  <div style={{ marginBottom:8 }}>
                    {msg.toolSteps.map((st, j) => <ToolStepBar key={st.id||j} step={st} />)}
                  </div>
                )}
                {/* 内容：用户消息纯文本；assistant 用 Markdown 流式渲染 */}
                {msg.role === 'user'
                  ? <div style={{whiteSpace:'pre-wrap',wordBreak:'break-word',fontSize:14,lineHeight:1.65}}>{msg.content}</div>
                  : <StreamingMarkdown text={msg.content} />}
                {/* 流式打字机光标 */}
                {msg.role === 'assistant' && sending && !msg.stopped && !msg.streamError && i === localMessages.length - 1 && (
                  <span className="ui-caret" style={{height:16,verticalAlign:'middle'}}>&nbsp;</span>
                )}
                {/* M1-4：state 计数（步骤 x/max · 已用 N tokens） */}
                {msg.role === 'assistant' && (msg.tokensUsed != null || (msg.step != null && msg.step > 0)) && (
                  <div style={{ marginTop:6, fontSize:11, color:colors.textTertiary }}>
                    步骤 {msg.step ?? 0}/{msg.maxStep ?? 5} · 已用 {msg.tokensUsed ?? 0} tokens
                  </div>
                )}
                </>
                )}
              </div>
              {/* M1-4：error 事件红色块 + 已完成部分提示 + 重发按钮；M5：模型降级卡片 + 复制错误 */}
              {msg.role === 'assistant' && msg.streamError && (
                <div style={{ ...calloutStyle('error'), marginTop:8, flexDirection:'column', maxWidth:'78%' }}>
                  <div style={{display:'flex',alignItems:'flex-start',gap:8}}>
                    <Icon name="alert-triangle" size={16} style={{flexShrink:0,marginTop:2}} />
                    <span>{msg.streamError}</span>
                  </div>
                  <div style={{ marginTop:8, display:'flex', gap:8, alignItems:'center', flexWrap:'wrap' }}>
                    <span style={{ color:colors.dangerText, fontSize:12 }}>已完成部分见上方</span>
                    <button className="ui-btn ui-btn-danger-soft" onClick={resendLast} style={{...btnDangerSoft, height:22, padding:'0 8px', fontSize:12}}>
                      <Icon name="rotate-cw" size={14} /> 重新发送
                    </button>
                    <button className="ui-btn ui-btn-ghost" onClick={() => { navigator.clipboard?.writeText(msg.streamError || '').catch(() => {}); }}
                      style={{...btnGhost, height:22, padding:'0 8px', fontSize:12}}>
                      <Icon name="copy" size={14} /> 复制错误详情
                    </button>
                  </div>
                  {/* M5 模型降级引导：检测到"模型不存在"类错误 → 切换/重新拉取 */}
                  {/不存在|does not exist|not found|404/i.test(msg.streamError) && (
                    <ModelRescueBar projectId={projectId} agentId={agentId}
                      currentModel={msg.model_used || modelUsed} onSwitched={resendLast} />
                  )}
                </div>
              )}
              {/* M5：长加载提示（发送后长时间无事件） */}
              {msg.role === 'assistant' && !msg.streamError && !msg.content && (msg.waitingSeconds || 0) >= 8 && (
                <div style={{ ...calloutStyle('info'), marginTop:8, maxWidth:'78%' }}>
                  <Spinner size={14} />
                  <span style={{fontSize:12}}>模型加载/推理中，较久属正常（本地模型）…已等待 {msg.waitingSeconds}s</span>
                </div>
              )}
              {msg.role === 'assistant' && msg.stopped && (
                <div style={{ marginTop:8, display:'flex', alignItems:'center', gap:8 }}>
                  <Icon name="stop" size={14} style={{color:colors.textTertiary}} />
                  <span style={{ fontSize:12, color:colors.textTertiary }}>已手动停止</span>
                  <button className="ui-btn ui-btn-secondary" onClick={resendLast} style={{...btnSecondary, height:22, padding:'0 8px', fontSize:12}}>
                    <Icon name="rotate-cw" size={14} /> 重新发送
                  </button>
                </div>
              )}
              {/* M6（TS-112）视觉引导：正文命中多模态降级文案 → 切换视觉模型/一键拉取/知道了 */}
              {msg.role === 'assistant' && typeof msg.content === 'string'
                && msg.content.includes('[⚠️ 当前模型不支持多模态') && (
                <VisionRescueCard projectId={projectId} agentId={agentId}
                  currentModel={msg.model_used || modelUsed} onSwitched={resendLast} />
              )}
            </div>
          );
        })}
        <div ref={messagesEndRef} />
        {/* TS-102 B15：手动上滚后出现的"回到底部"按钮 */}
        {showBackToBottom && (
          <button onClick={scrollToBottom} data-tip="回到底部"
            style={{position:'sticky', bottom:8, left:'50%', transform:'translateX(-50%)', display:'flex', alignItems:'center', justifyContent:'center',
                    width:36, height:36, margin:'8px auto 0', background:colors.bgCard, border:`1px solid ${colors.borderDefault}`, borderRadius:'50%',
                    cursor:'pointer', boxShadow:shadow.s}}>
            <Icon name="chevron-down" size={16} style={{color:colors.textSecondary}} />
          </button>
        )}
      </div>

      {/* 暂存区 (§8.11) */}
      {pendingItems.length > 0 && (
        <div style={{ padding:'8px 16px', borderTop:`1px solid ${colors.borderSubtle}`, background:'#F5F5F7', display:'flex', flexWrap:'wrap', gap:8, alignItems:'center' }}>
          <span style={{fontSize:11,color:colors.textTertiary,marginRight:4}}>暂存区:</span>
          {pendingItems.filter(p=>p.isImage).map((item, idx) => (
            <div key={idx} style={{ position:'relative' }}>
              <img src={item.dataUri} alt={item.name} style={{maxWidth:80,maxHeight:80,borderRadius:radius.s,border:`1px solid ${colors.borderDefault}`}} />
              <button onClick={() => removePending(pendingItems.indexOf(item))} data-tip="移除该附件" style={{position:'absolute',top:-6,right:-6,background:colors.bgToast,color:'#fff',border:'none',borderRadius:'50%',width:16,height:16,fontSize:10,cursor:'pointer',lineHeight:'16px',padding:0,display:'flex',alignItems:'center',justifyContent:'center'}}>
                <Icon name="x" size={10} style={{color:'#fff'}} />
              </button>
            </div>
          ))}
          {pendingItems.filter(p=>!p.isImage).map((item, idx) => (
            <span key={idx} style={{background:colors.bgCard,padding:'4px 8px',borderRadius:radius.s,fontSize:12,color:colors.textPrimary,display:'inline-flex',alignItems:'center',gap:4,border:`1px solid ${colors.borderDefault}`}}>
              <Icon name="file" size={14} style={{color:colors.textTertiary}} /> {item.name}
              {/* checkpoint-048：附件解析状态（解析中/已提取/无法解析仅标注） */}
              {item.parsing && <span style={{color:colors.warn,fontSize:11,display:'inline-flex',alignItems:'center',gap:3}}><Spinner size={12} /> 解析中…</span>}
              {!item.parsing && item.parsedText && <span style={{color:colors.ok,fontSize:11,display:'inline-flex',alignItems:'center',gap:3}}><Icon name="check" size={14} style={{color:colors.ok}} /> 已提取</span>}
              {!item.parsing && item.parseFailed && <span style={{color:colors.textTertiary,fontSize:11}}>（仅文件名）</span>}
              <button className="ui-ico-danger" data-tip="移除该附件" onClick={() => removePending(pendingItems.indexOf(item))} style={{background:'none',border:'none',cursor:'pointer',padding:0,display:'inline-flex',alignItems:'center'}}>
                <Icon name="x" size={14} style={{color:colors.textTertiary}} />
              </button>
            </span>
          ))}
        </div>
      )}

      {/* Input (§8.12) */}
      <div style={{ padding:'12px 16px', borderTop:`1px solid ${colors.borderSubtle}`, display:'flex', gap:8, alignItems:'flex-end', flexShrink:0 }}>
        <input ref={fileInputRef} type="file" multiple style={{display:'none'}} onChange={handleFileChange} accept="image/*,.txt,.md,.csv,.json,.js,.ts,.py,.html,.css,.yaml,.yml,.log,.ini,.pdf,.docx,.xlsx,.xlsm" />
        {/* 验收修复：补回上传按钮（checkpoint-003 会话系统重写时丢失，handleUpload 成死代码） */}
        <button className="ui-btn ui-btn-secondary" onClick={handleUpload} title="上传图片或文本文件（发送前可在暂存区删除）"
          style={{width:38,height:38,padding:0,display:'inline-flex',alignItems:'center',justifyContent:'center',borderRadius:radius.s,flexShrink:0}}>
          <Icon name="paperclip" size={16} style={{color:colors.textSecondary}} />
        </button>
        <textarea value={input} disabled={inputDisabled} onChange={e=>setInput(e.target.value)}
          onCompositionStart={()=>{composingRef.current=true;}}
          onCompositionEnd={()=>{composingRef.current=false; compositionEndAtRef.current=Date.now();}}
          onKeyDown={e=>{
            // checkpoint-067b R-1/D-6：精确区分"输入法选词的回车"与"想发送的回车"。
            // 仅依赖 composing/isComposing/keyCode229 判断是否在输入法组合中（这些为真时回车是选词确认，不发送）。
            // 去掉原 80ms 时间窗的粗暴拦截（它会把用户"想发送的回车"吞掉变成换行）。
            if (composingRef.current || e.nativeEvent.isComposing || e.keyCode===229) return;
            if (e.key==='Enter' && !e.shiftKey) handleSend();
          }}
          placeholder={pendingItems.length ? '输入文字描述，或直接发送...' : '输入消息（可先上传附件，再输入文字，一起发送）...'}
          style={{padding:'8px 10px',borderRadius:radius.s,border:`1px solid ${colors.borderStrong}`,background:colors.bgCard,color:colors.textPrimary,fontSize:14,flex:1,minHeight:38,maxHeight:120,resize:'none',fontFamily:fonts.base,lineHeight:1.6,boxSizing:'border-box'}} />
        {sending ? (
          <button onClick={handleStop} data-tip="停止"
            style={{width:38,height:38,padding:0,display:'inline-flex',alignItems:'center',justifyContent:'center',borderRadius:radius.s,border:'none',background:'#1A1A1E',cursor:'pointer',flexShrink:0}}>
            <Icon name="stop" size={12} style={{color:'#FFFFFF'}} />
          </button>
        ) : (
          <button className="ui-btn ui-btn-primary" onClick={handleSend} data-tip="发送" disabled={inputDisabled || (!input.trim() && pendingItems.length===0)}
            style={{width:38,height:38,padding:0,display:'inline-flex',alignItems:'center',justifyContent:'center',borderRadius:radius.s,border:'none',cursor:'pointer',flexShrink:0,opacity:(!input.trim() && pendingItems.length===0) ? 0.5 : 1}}>
            <Icon name="send" size={16} style={{color:colors.onAccent}} />
          </button>
        )}
      </div>
    </div>
    {/* TS-120：右侧知识仓库面板（可折叠，默认收起，不影响会话区布局）
        TS-121 查虫C：initialScope=转移目标作用域，转全局时面板直接定位全局。
        查虫K-3：key 含转移序号，连续转移同一作用域也触发重新定位 */}
    {showKnowledgePanel && (
      <WarehousePanel
        key={`${transferScope}-${warehouseTransferSeq}`}
        projectId={projectId}
        initialScope={transferScope}
        onClose={() => setShowKnowledgePanel(false)}
        onInject={(text) => {
          // 把勾选知识拼进输入框（作为用户消息注入会话，仅勾选的条目）
          setInput(prev => prev ? prev + '\n\n' + text : text);
          setToast('知识已注入输入框，确认后发送');
          setTimeout(() => setToast(null), 3000);
        }}
      />
    )}
    </div>
  );
}
