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
import { purgeSessionLocal, syncSessionLocal, Message, ToolStep } from '../hooks/useMessages';
import { SSEStreamParser } from '../lib/sseParser';
import { colors, fonts, radius, shadow, btnPrimary, btnSecondary, btnGhost, btnDangerSoft, select as selectStyle, calloutStyle, iconBtn, menuCard } from '../theme';
import { Icon, Spinner, IconName } from '../Icon';
import { confirmDialog, promptDialog } from '../Dialog';
import { on } from '../events';
import { WarehousePanel } from './WarehousePanel';
import { reportBusy } from '../busyState';

interface AgentConfig { id: string; name: string; role?: string; model_name?: string; type_: string; parent_agent_id?: string | null; system_prompt?: string | null; }
interface Session { id: string; title: string; message_count: number; }
interface PendingItem { name: string; dataUri: string; isImage: boolean; size: number; parsedText?: string; parsing?: boolean; parseFailed?: boolean;
  /** C7（0.4.18）：后端落盘后的**绝对路径**；写进消息正文使 agent 在后续会话仍可 read_file 原件 */
  savedPath?: string; }

const API = getApiBase();

// B1（0.4.12）：输入的「判空」与「内容保真」必须共用同一套规则。
// ⛔ 此前的两个缺陷（同一段代码的两面）：
//   ① 内容用了判空值——`replace(/[\s...]/,'')` 里的 `\s` 同时匹配**换行与普通空格**，
//      该值本只用于"是否为空白"判定，却被 push 进气泡 content；而 apiMessages 派生自 content，
//      于是发给模型的载荷也被剥掉全部空白（"please fix this bug" → "pleasefixthisbug"），
//      用户 Shift+Enter 的换行在会话里丢失。
//   ② 判据不一致——发送按钮用 `input.trim()`，而 `trim()` **不剥**零宽/BOM/软连字符，
//      handleSend 却用更严格的 cleanText 规则；纯不可见字符时按钮可点但点了不发送（死点击）。
// 归一化：只剔真正的不可见字符；\u00A0 降级为普通空格（直接删会让两侧单词粘连）；换行与词间空格保留。
function normalizeInputText(raw: string): string {
  return raw.replace(/[\u200B-\u200F\u2060\uFEFF\u00AD]/g, '').replace(/\u00A0/g, ' ');
}
/** 发送可用性唯一判据：按钮 disabled 与 handleSend 守卫必须调同一个函数。 */
function hasSendableText(raw: string): boolean {
  return normalizeInputText(raw).trim().length > 0;
}

/**
 * A/B-2（0.4.23）：消息「移入知识仓库」后，重算顶栏上下文指示器。
 *
 * ⛔ **为什么是扣减而不是归零**：原实现在归档后把后端真实字数 `ctx_chars` 置 0，
 * 让指示器退回**纯前端启发式**（只数未归档的 user/assistant 正文 ×0.6）。而启发式
 * **不含 system prompt 与工具声明**——实测 `tools_spec` 单独就 8433 字符 ≈ **5060 token**
 * （18 个工具）。于是"移入仓库后"数字不是变小一点，而是**断崖式掉到远低于真实值**，
 * 直到下一轮 `state` 事件才跳回 → 用户看到数字忽大忽小（用户 2026-09-12 报
 * 「token 计数逻辑有误，修复多次未成功」的成因之一；历次修复都只在调估算精度，没人动过这里）。
 *
 * ✅ 正解：只从真实值里**扣掉被归档消息自身的贡献**，保住 system prompt + 工具声明基线，
 * 同时仍然满足用户明确要求的「移入仓库即下降、脱离上下文就该重新计算」。
 *
 * ⛔ 已知近似（如实标注，不假装精确）：扣的是消息 `content` 的字符数，而后端 `_ctx_chars`
 * 统计的是 msgs 全部角色与全部字段（含 role 等 JSON 结构字符），故扣减**略小于**真实减少量。
 * 这是保守方向的误差（宁可少扣也不把数字扣到偏低），且下一轮 `state` 事件会用后端真值纠正。
 *
 * @param backendCtxChars 后端最近一次回传的真实上下文字符数（0 = 尚无真值）
 * @returns nextCtxChars：新的真实字符数基准；nextTokenUsed：要显示的 token 数，
 *          **null 表示不要硬写显示值**（交由启发式估算兜底，避免显示 0 这种更糟的失真）
 */
export function ctxTokensAfterArchive(
  backendCtxChars: number,
  msgs: Array<{ id?: number | string; content?: string }>,
  archivedIds: Set<number>,
): { nextCtxChars: number; nextTokenUsed: number | null } {
  // ⛔ 边界守卫：无后端真值时（会话刚加载、还没跑过任何一轮、从未收到 state 事件）
  //   不得做扣减——扣减会得出 0，把原本启发式还能算出的值也清成 0（比原行为更糟）。
  //   此时保持"归零 + 交回估算 effect 按未归档消息重算"的原语义。
  if (!(backendCtxChars > 0)) {
    return { nextCtxChars: 0, nextTokenUsed: null };
  }
  const archivedChars = msgs
    .filter(m => typeof m.id === 'number' && archivedIds.has(m.id))
    .reduce((sum, m) => sum + ((m.content || '').length), 0);
  const nextCtxChars = Math.max(0, backendCtxChars - archivedChars);
  // ⛔ 扣到 0（极端：归档了几乎全部内容）→ 返回 null，不硬显示 0，交回启发式兜底
  return { nextCtxChars, nextTokenUsed: nextCtxChars > 0 ? Math.round(nextCtxChars * 0.6) : null };
}

/**
 * 把 running 态工具步骤收敛为 interrupted（0.4.22 重打包修复二，checkpoint-109）。
 *
 * ═══ 为什么抽成纯函数 ═══
 * 用户实测（2026-09-12 四图）：插入分裂成功后，被定格的旧气泡**仍显示**「正在调用
 * web_search…」转圈与「模型加载/推理中…已等待 26s」横幅。落库证据：该会话只有 2 条
 * assistant 落库，**分裂出的段1 从未落库**；其折叠行却显示 5 步而分裂点只经过 1~2 轮
 * → **M5 重连导致 loop 整轮重跑**，attempt1 断连时残留的 running（其 tool_result
 * 随断连丢失）再无人收敛。
 *
 * 收敛此前只存在于 3 条手动停止路径（C2，0.4.16）。本批把收敛扩到 5 个出口
 * （3 停止 + 分裂定格 + done 兜底），抽纯函数共用：
 *   · 语义统一（既非 ok 也非 error，不谎称成功/失败）；
 *   · chatPanelC2ToolSteps 的静态计数断言改为数【调用点】，任何一条路径被删都会红。
 *
 * ⛔ 历史注释断言「分裂点不可能有 running（tool_result 必同轮到达）」——该断言只在
 *   **单连接不重连**时成立，重连/断连即破（tool_result 丢失而 running 永留）。
 *
 * 无 running 时原样返回（引用不变，避免无谓的新数组触发重渲染）。
 */
export function convergeRunningSteps(steps: ToolStep[] | undefined): ToolStep[] | undefined {
  if (!steps || steps.length === 0) return steps;
  if (!steps.some(st => st.status === 'running')) return steps;
  return steps.map(st => (st.status === 'running' ? { ...st, status: 'interrupted' as const } : st));
}

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
// checkpoint-048：聊天上传支持办公文档（走后端附件解析端点）
// ⛔ C3 局部去重（0.4.18）：此处原有 `PARSEABLE_EXTS` 白名单，是后端
//    `attachments/parser.py: SUPPORTED_EXTS` 的**第二份真相源**，且已**漂移**：
//    缺 `.pptx`（0.4.6 后端已加解析、前端漏改 → 用户能选 pptx 却从不解析，
//    且因 parseable=false 直接 continue，界面连「（仅文件名）」都不显示），
//    也缺后端 TEXT_EXTS 里的 .js/.ts/.py/.html/.css/.xml/.toml/.cfg/.conf/.sh/.markdown。
//    ⛔ 修法不是"把清单补全"（后端下次加格式仍会漂），而是**删掉白名单、交后端唯一裁决**：
//    非图片一律调解析端点，后端对不支持的格式返回 text=null → 前端显示「（仅文件名）」。
//    与既有渲染三态（解析中… / 已提取 /（仅文件名））天然契合。
//    代价：传 .zip/.exe 等会多一次往返，但后端有 10MB 上限保护（_CHAT_ATT_MAX_BYTES）。
//    ⚠️ 故 handleFileChange 的判据简化为 `!item.isImage`，不再引用任何前端格式清单。

// TS-102 B14：流式/临时消息稳定 id 生成器（单调序号，同一毫秒内也不重复）
let localMsgSeq = 0;
function newLocalMsgId(): string { return `local_${Date.now()}_${++localMsgSeq}`; }

// ── M1-4：Markdown 流式渲染（未闭合 ``` 先当纯文本，闭合后转代码块）──
// ⛔⛔ F2（0.4.23 安全区）：包 `React.memo`。
// 主因（`36-…测量操作卡.md` 5.7 真机数据坐实）：流式/思考期每个 SSE 事件都 setLocalMessages
//   → 重渲染整个消息列表（实测 93~95 条），**每条 assistant 都重新走 ReactMarkdown 完整解析**，
//   而其中 94 条的 text 一个字没变 → 重解析纯属浪费，是 Electron 渲染进程烧满一核（~103%）的主成本。
// memo 后 text 不变即跳过重渲染与重解析。
// ⛔ 默认浅比较即可、**不需要自定义比较函数**：本组件是叶子组件，只接收 `text` 一个 prop，
//   其余（colors/fonts/radius）全部读模块级 theme 常量，不随渲染变化。
// ⛔ 属"安全区"：memo 不改输出 DOM/样式，也不动消息列表 `.map()` 结构 → 与 A12 UI 重构零冲突。
export const StreamingMarkdown = React.memo(function StreamingMarkdown({ text }: { text: string }) {
  const openFences = (text.match(/```/g) || []).length;
  const balanced = openFences % 2 === 0;
  if (!text) return null;
  // B3（0.4.12）：长文本溢出聊天框。⛔ 三个真实成因，缺一都会漏：
  //   ① `wordBreak:'break-word'` 是**已废弃的别名**（word-break 规范值只有 normal|break-all|keep-all），
  //      标准写法是 `overflowWrap:'anywhere'`——它才会把「无空格长串」（长 URL、base64、
  //      超长英文标识符）也纳入断行计算，而 `break-word` 只在"软换行机会"处生效，长 URL 仍会撑破容器。
  //   ② 缺 `minWidth:0`：本组件是 flex 子项，flex 子项默认 `min-width:auto`（不得小于内容宽度），
  //      因此**再怎么写 overflow-wrap 也不会收缩**，必须先解开这个下限。
  //   ③ 表格：已启用 remarkGfm，但 components 只自定义了 code，`<table>` 是裸的 →
  //      宽表格会直接撑破 maxWidth:78% 的气泡。表格不能断字（会把单元格内容打散、破坏对齐），
  //      正确做法是给它一个可横向滚动的包裹层。
  const wrapStyle: React.CSSProperties = {
    overflowWrap: 'anywhere', wordBreak: 'break-word', // 保留 break-word 兜底老内核
    minWidth: 0, maxWidth: '100%',
  };
  if (!balanced) {
    // 代码块未闭合 → 整段按 pre-wrap 纯文本，避免半截 markdown 抖动
    return <pre style={{ ...wrapStyle, whiteSpace:'pre-wrap', margin:0, fontFamily:'inherit', fontSize:14, overflowX:'auto' }}>{text}</pre>;
  }
  return (
    <div style={{ ...wrapStyle, fontSize:14, lineHeight:1.65 }}>
      <ReactMarkdown remarkPlugins={[remarkGfm]} components={{
        code({ className, children, ...rest }: any) {
          const isBlock = /language-/.test(className || '');
          if (isBlock) return <pre style={{ background:colors.bgCode, padding:'8px 10px', borderRadius:radius.s, overflowX:'auto', fontSize:12.5, margin:'6px 0', border:`1px solid ${colors.borderSubtle}`, fontFamily:fonts.mono, lineHeight:1.6, maxWidth:'100%' }}><code className={className} style={{ fontFamily:fonts.mono, fontSize:12.5, whiteSpace:'pre' }}>{children}</code></pre>;
          return <code style={{ background:colors.bgInlineCode, padding:'1px 5px', borderRadius:4, fontSize:12.5, fontFamily:fonts.mono, ...wrapStyle }} {...rest}>{children}</code>;
        },
        // B3：表格外包一层横向滚动容器——表格自身宽度不受限，超出部分滚动查看，
        // 不再撑破气泡。tableLayout:fixed + width:100% 让列宽按容器分配，避免窄表被拉变形。
        table({ children, ...rest }: any) {
          return (
            <div style={{ overflowX:'auto', maxWidth:'100%', margin:'6px 0' }}>
              <table style={{ borderCollapse:'collapse', width:'100%', tableLayout:'auto', fontSize:13 }} {...rest}>{children}</table>
            </div>
          );
        },
        th({ children, ...rest }: any) {
          return <th style={{ border:`1px solid ${colors.borderSubtle}`, padding:'4px 8px', background:colors.bgCode, textAlign:'left', ...wrapStyle }} {...rest}>{children}</th>;
        },
        td({ children, ...rest }: any) {
          return <td style={{ border:`1px solid ${colors.borderSubtle}`, padding:'4px 8px', ...wrapStyle }} {...rest}>{children}</td>;
        },
        // 链接：长 URL 同样需要断行，否则单行链接即可撑破气泡
        a({ children, ...rest }: any) {
          return <a style={{ color:colors.accent, ...wrapStyle }} {...rest}>{children}</a>;
        },
      }}>{text}</ReactMarkdown>
    </div>
  );
});

// ── M1-4：工具步骤折叠条 ──
function ToolStepBar({ step }: { step: ToolStep }) {
  const [open, setOpen] = useState(false);
  const label = step.status === 'running'
    ? `正在调用 ${step.name}…`
    : step.status === 'interrupted'
    ? `${step.name}（已中断，未完成）`
    : step.status === 'ok'
      ? `${step.name} 完成（${step.summary || 'ok'}）`
      : `${step.name} 失败：${step.error || 'unknown'}`;
  return (
    /* checkpoint-060：折叠条单行化修复重叠事故——旧实现行高固定 30px 但标签允许换行，
       长摘要（如委派交卷数百字）会在 flex 行内上下对称溢出，叠印到上下消息上。
       现标签单行省略号截断；完整摘要/错误/参数在展开区查看（信息不丢）。 */
    /* A12（0.4.25）：去卡片边框改时间线——左侧 2px 竖线 + 行内容排布，
       步骤条目从"卡片堆"变为文档内的轻量过程记录。 */
    <div style={{ marginBottom:6, borderLeft:`2px solid ${colors.borderDefault}`, overflow:'hidden' }}>
      <div onClick={() => setOpen(o=>!o)} style={{ display:'flex', alignItems:'center', gap:7, padding:'0 10px', height:30, cursor:'pointer', color:colors.textSecondary, fontSize:12.5 }}>
        {/* C2（0.4.16）：interrupted 用中性 stop 图标，不用 ✓（谎称成功）也不用 ✗（谎报失败）*/}
        {step.status === 'running' ? <Spinner size={12} />
          : step.status === 'ok' ? <Icon name="check" size={14} style={{ color:colors.ok }} />
          : step.status === 'interrupted' ? <Icon name="stop" size={12} style={{ color:colors.textTertiary }} />
          : <Icon name="x" size={14} style={{ color:colors.danger }} />}
        <span style={{ flex:1, minWidth:0, overflow:'hidden', whiteSpace:'nowrap', textOverflow:'ellipsis' }} title={label}>{label}</span>
        <Icon name={open ? 'chevron-up' : 'chevron-down'} size={14} style={{ color:colors.textTertiary }} />
      </div>
      {open && (
        <div style={{ padding:'4px 10px 10px', fontSize:12, color:colors.textSecondary, animation:'ui-fade-in .14s ease' }}>
          {(step.summary || step.error) && (
            <div style={{ whiteSpace:'pre-wrap', wordBreak:'break-word', marginBottom:6, color: step.status === 'error' ? colors.dangerText : colors.textSecondary }}>
              {step.status === 'error' ? (step.error || 'unknown') : step.summary}
            </div>
          )}
          <pre style={{ margin:0, padding:'8px 10px', background:colors.bgHover, borderRadius:radius.s, fontSize:12, color:colors.textSecondary, whiteSpace:'pre-wrap', wordBreak:'break-word', maxHeight:160, overflowY:'auto', fontFamily:fonts.mono }}>
{JSON.stringify(step.args ?? {}, null, 2)}
          </pre>
        </div>
      )}
    </div>
  );
}

// ── 附件正文注入标记 ──
// ⛔ ATTACH_MARK 是附件正文注入的**唯一标记**（handleSend 注入处使用），
//    不可在别处写字面量副本，否则改一处漏一处（C3/A10 刚清理过双源漂移）。
// ⛔ #11（0.4.19）：此前 B10 + C8 遗留（0.4.18，提交 7f577fc）按此标记把附件段
//    与超长 assistant 正文折叠显示（折叠外壳组件 + 字数/行数阈值常量，阈值约 600 字 / 20 行）。
//    用户拍板**全部删除**——该折叠从未被要求过（用户原话「我虚构的需求」「没有意义」），
//    把内容藏起来只会让用户以为信息丢了。现正文一律原样铺开。
//    ⛔ 标记本身保留：它早在 B10 之前就存在（附件注入的分隔符），与折叠无关。
//    ⛔ B4 工具步骤折叠（ToolStepsGroup）**保留**：它折叠的是过程条目而非内容，
//    且解决的正是用户报过的「工具调用步骤一直占着会话窗」痛点（用户 2026-09-10 拍板）。
const ATTACH_MARK = '--- 附件内容 ---';

/**
 * B4（0.4.12）：工具步骤「完成后折叠」。
 *
 * 问题：每条 ToolStepBar 自身虽已单行折叠，但 N 个步骤会**常驻**会话窗（每条约 38px），
 * 一轮对话调十几次工具就会把正文顶出视野——用户报告"工具调用步骤一直占着会话窗"。
 *
 * 方案：整组收拢为一行摘要；运行中自动展开，全部终结后自动收拢，点击可再展开。
 * ⛔ 两个必须守住的约束（否则会引入新缺陷）：
 *   ① **失败不能被折叠藏起来**——收拢行须显眼标出失败数并用警示色，
 *      否则用户以为一切正常，排查线索被藏掉；error 步骤也不计入"成功"。
 *   ② **用户手动展开/收拢的状态不能被自动行为覆盖**——自动切换只在状态跃迁的那一次生效，
 *      用户点过之后（userToggled）组件重渲染也不得再自动改动。
 *
 * "已完成"判据不能用 msg.stopped：DB 加载的历史消息**不带** stopped（只有缓存恢复才置位），
 * 而历史消息里的工具步骤恰恰是最该折叠的。故由外层传入 done（流是否已结束），
 * 组内再确认没有 running 步骤。
 */
function ToolStepsGroup({ steps, done }: { steps: ToolStep[]; done: boolean }) {
  const running = steps.filter(s => s.status === 'running').length;
  const failed = steps.filter(s => s.status === 'error').length;
  const okCount = steps.filter(s => s.status === 'ok').length;
  // C8（0.4.16）：中断步骤数。⛔ 它既不算 running（否则 running===0 永不满足、步骤组永远展开
  // = C8"不可折叠"症状），也不算 failed（否则 B4 约束①的警示色会谎报"失败"，
  // 而用户主动停止并不是工具出错）。
  const interrupted = steps.filter(s => s.status === 'interrupted').length;
  // 自动收拢条件：外层已告知流结束，且没有仍在跑的步骤
  const shouldCollapse = done && running === 0;
  const [userToggled, setUserToggled] = useState(false);
  const [open, setOpen] = useState(false);
  // 状态跃迁时同步一次：运行中展开、完成后收拢；用户手动点过就不再自动改
  const prevCollapseRef = useRef(shouldCollapse);
  useEffect(() => {
    if (prevCollapseRef.current !== shouldCollapse) {
      prevCollapseRef.current = shouldCollapse;
      if (!userToggled) setOpen(!shouldCollapse);
    }
  }, [shouldCollapse, userToggled]);

  const collapsed = shouldCollapse && !open;
  const headLabel = collapsed
    ? (failed > 0
        ? `工具调用 ${steps.length} 步 · ${okCount} 成功 · ${failed} 失败${interrupted > 0 ? ` · ${interrupted} 中断` : ''}`
        : interrupted > 0
          ? `工具调用 ${steps.length} 步 · ${okCount} 成功 · ${interrupted} 中断`
          : `工具调用 ${steps.length} 步 · 已完成`)
    : running > 0
      ? `正在调用工具（${running}/${steps.length} 进行中）…`
      : `工具调用 ${steps.length} 步`;

  /* A12 灵动批：手风琴高度过渡（grid 0fr↔1fr）。
     ⛔ 折中点：流结束的**自动收拢**必须同步卸载步骤（B4 测试①/④ 断言
     收拢后 textContent 立即不含步骤文案）；仅「用户手动收起」走 210ms 收缩动画
     （步骤保持挂载、grid 1fr→0fr，播完再卸载）——该窗口期无任何测试断言。 */
  const [userClosing, setUserClosing] = useState(false);
  const closeTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const [entered, setEntered] = useState(false);
  useEffect(() => {
    if (collapsed) { setEntered(false); return; }
    // 展开首帧 0fr、次帧 1fr → 展开动画（jsdom 无 rAF 时降级 setTimeout(0)）
    if (typeof requestAnimationFrame === 'function') {
      let id2 = 0;
      const id1 = requestAnimationFrame(() => { id2 = requestAnimationFrame(() => setEntered(true)); });
      return () => { cancelAnimationFrame(id1); if (id2) cancelAnimationFrame(id2); };
    }
    const t = setTimeout(() => setEntered(true), 0);
    return () => clearTimeout(t);
  }, [collapsed]);
  useEffect(() => () => { if (closeTimer.current) clearTimeout(closeTimer.current); }, []);

  const handleBarClick = () => {   // 收拢 → 展开
    if (closeTimer.current) { clearTimeout(closeTimer.current); closeTimer.current = null; }
    setUserClosing(false);
    setUserToggled(true); setOpen(true);
  };
  const handleHeadClick = () => {  // 展开 → 用户手动收起（走收缩动画窗口）
    setUserToggled(true);
    setUserClosing(true);
    closeTimer.current = setTimeout(() => { setUserClosing(false); setOpen(false); }, 210);
  };

  if (collapsed && !userClosing) {
    /* 收拢态：整组一行，点击展开全部步骤（展开后每条仍可单独查看摘要/参数） */
    return (
      <div style={{ marginBottom:8 }}>
        <div
          onClick={handleBarClick}
          style={{ display:'flex', alignItems:'center', gap:6, padding:'0 10px', height:28,
            cursor:'pointer', borderRadius:radius.pill, fontSize:12.5,
            border:`1px solid ${failed > 0 ? colors.warnBorder : colors.borderSubtle}`,
            background: failed > 0 ? colors.warnBg : colors.bgHover,
            color: failed > 0 ? colors.warnText : colors.textSecondary }}>
          {failed > 0
            ? <Icon name="alert-triangle" size={13} style={{ color: colors.warnText, flexShrink:0 }} />
            : <Icon name="check-circle" size={13} style={{ color: colors.ok, flexShrink:0 }} />}
          <span style={{ flex:1, minWidth:0, overflow:'hidden', whiteSpace:'nowrap', textOverflow:'ellipsis' }} title={headLabel}>
            {headLabel}
          </span>
          <Icon name="chevron-right" size={13} style={{ color:colors.textTertiary, flexShrink:0 }} />
        </div>
      </div>
    );
  }
  /* 展开态：逐条渲染；多于一步时给出可点收起的组头。
     userClosing 窗口内 collapsed 尚未成立（open 仍 true），步骤保持挂载、grid 收向 0fr。 */
  return (
    <div style={{ marginBottom:8 }}>
      {steps.length > 1 && (
        <div
          onClick={handleHeadClick}
          style={{ display:'flex', alignItems:'center', gap:6, marginBottom:6, height:22,
            cursor:'pointer', fontSize:12, color:colors.textTertiary }}>
          <Icon name="layers" size={12} style={{ flexShrink:0 }} />
          <span style={{ flex:1, minWidth:0, overflow:'hidden', whiteSpace:'nowrap', textOverflow:'ellipsis' }} title={headLabel}>{headLabel}</span>
          <Icon name="chevron-down" size={12} style={{ flexShrink:0, transform:'rotate(180deg)', transition:'transform .2s ease' }} />
        </div>
      )}
      <div style={{
        display:'grid',
        gridTemplateRows: userClosing ? '0fr' : entered ? '1fr' : '0fr',
        transition:'grid-template-rows .2s cubic-bezier(.2,.8,.3,1)',
      }}>
        <div style={{ overflow:'hidden', minHeight:0 }}>
          {steps.map((st, j) => <ToolStepBar key={st.id||j} step={st} />)}
        </div>
      </div>
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
  // A12（0.4.25）：顶栏「⋯ 更多操作」菜单（总结/导出/单元归档/重命名/删除收纳其中，治"会话窗上方拥挤"）
  const [showMoreMenu, setShowMoreMenu] = useState(false);
  // 0.4.9（3.47.1 单元归档）：会话窗开关，默认关。仅开启时后端才暴露 archive_work_unit
  // 工具并注入归档纪律（关闭时工具不存在，零开销）；非自动——必须用户主动启用。
  const [autoArchiveUnit, setAutoArchiveUnit] = useState(false);
  // 查虫K-3：转移序号——面板 key 的一部分，保证连续转移到同一作用域
  // （期间手动切过作用域）也能重新定位到转移目标作用域
  const [warehouseTransferSeq, setWarehouseTransferSeq] = useState(0);
  // checkpoint-059：活流标记——记录当前仍有进行中流的会话 id（H16 流继续场景）。
  // 切换/加载会话时，仅对该会话的缓存气泡跳过僵尸清理；其余会话的缓存视为"死态"清理。
  const activeStreamSidRef = useRef<string | null>(null);
  const messagesEndRef = useRef<HTMLDivElement>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);
  const abortRef = useRef<AbortController | null>(null);
  // 0.4.12 附带修复：节流计时器提升为组件级 ref，卸载时 clearTimeout（无害卫生）。
  // 原实现是 handleSend 的闭包局部变量，卸载后外部无从清理。
  const cacheSyncTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  // B12（0.4.21）：流级计时器同样提升为组件级 ref —— ⛔ **卸载 cleanup 不 abort 流**（实测：
  // `:659` 那处 cleanup 只置 mountedRef=false 并清 cacheSyncTimer，不调 abort），
  // 因此组件卸载时 handleSend 的 `finally` **根本不会执行**。若只在 finally 清理，
  // 卸载后这个每秒计时器会继续空转。故必须在 finally 与卸载 cleanup **两处**都 clearInterval。
  // 📌 注：它不会造成"幽灵写入"——patchStreamMsg 走 setLocalMessages(prev=>...) 的 updater，
  //   React 18 卸载后 updater 不被调用（同上方 cacheSyncTimer 的变异测试结论）；
  //   清理它属"无害卫生"（停掉空转 timer），但仍必须做。
  const runElapsedTimerRef = useRef<ReturnType<typeof setInterval> | null>(null);
  // 0.4.12 附带修复（**真实根因**）：卸载守卫。
  // ⛔ 定位纠错——最初以为泄漏来自上面的节流 timer，但**变异测试证伪**：把卸载清理删掉，
  // 回归测试照样全绿。原因是节流 timer 的写缓存动作在
  //   `setLocalMessages(prev => { syncSessionLocal(...); return prev; })` 的 updater 里，
  // 而 React 18 卸载后 updater **根本不会被调用** → 那条路径本就不会幽灵写入。
  // 插桩 localStorage.setItem 抓到的真实调用栈，是两处**直接**调用 syncSessionLocal 的异步回调：
  //   ① applyEvent 的 done 分支——流循环在卸载后仍被 reader.read() 推进；
  //   ② alignLocalIdsWithDb——finally 里发起的 fetch，回来时组件已卸载。
  // 后果：切 agent / 关面板后仍有"幽灵写入"，可把已离开会话的内容写进缓存；
  // 测试侧则跨用例泄漏，表现为 chatPanelStream 长期 flaky
  // （'目录里有 2 个文件' 串进 '旧流文字继续串话?' 的断言）。
  // 故正解是用 mountedRef 守卫这两处，而不是只清 timer。
  const mountedRef = useRef(true);
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
    // C8（0.4.16）：DB 同 role 定稿 content 列表，用于**前缀匹配**。
    // ⛔ 精确匹配不够：前端 abort 时可能比后端少收几个 token，缓存 content 是 DB 定稿的
    // **前缀**而非全等 → 精确匹配失配 → 副本被当新消息追加到末尾且重复（C8 根因①）。
    // 配合"停止态已落库 + 不再拼（已停止）"，前缀匹配即可让停止气泡与 DB 定稿正确去重。
    const dbContentsByRole: Record<string, string[]> = {};
    for (const m of dbMsgs) { if (m.content) (dbContentsByRole[m.role] ||= []).push(m.content); }
    const matchesDb = (role: string, content: string): boolean => {
      if (!content) return false;
      if (dbByContent.has(`${role}::${content}`)) return true;            // 精确
      const list = dbContentsByRole[role] || [];
      return list.some(db => db.length > content.length && db.startsWith(content));  // 前缀
    };
    // C8 补漏（0.4.17）：**正文为空**的定稿按「工具步骤签名」去重。
    // ⛔ 上面 matchesDb 与下面的判据都以 content 为前提（`if (!content) return false` /
    //    `if (m.content && ...)`），于是"模型只调了工具、还没吐任何正文"时用户点停止
    //    → 缓存副本 content 为空串 → **整个去重被短路跳过** → 副本追加到末尾且重复，
    //    C8 的"挪末尾+重复"症状原样复发（探针实测：assistant 由 1 条变 2 条）。
    //    这恰恰是 C2 根因③针对的场景（停止时工具仍在 running，正文往往为空），
    //    故必须与 running→interrupted 收敛配套。
    // 签名归一：running 视同 interrupted —— DB 定稿由 _persist_assistant 收敛为 interrupted，
    // 而缓存副本可能是收敛前的 running（或旧版本写入的缓存），二者应判为同一条。
    const stepSig = (steps: ToolStep[]): string => steps.map(s =>
      `${s?.id ?? ''}|${s?.name ?? ''}|${s?.status === 'running' ? 'interrupted' : (s?.status ?? '')}`).join(';');
    const dbEmptyBodySteps = new Set<string>();
    for (const m of dbMsgs) {
      if ((m.content || '').trim()) continue;                 // 有正文的走前缀匹配
      const st = m.toolSteps || [];
      if (st.length > 0) dbEmptyBodySteps.add(`${m.role}::${stepSig(st)}`);
    }
    const extra: Message[] = [];
    for (const m of local) {
      const key = String(m.id ?? '');
      if (key.startsWith('local_')) {
        // 流式气泡：若 DB 已有同角色、内容相同或以其为前缀的定稿（流式期间已落盘），以 DB 为准不重复追加
        if (m.content && matchesDb(m.role, m.content)) continue;
        // C8 补漏（0.4.17）：正文为空时改按工具步骤签名去重（见上 dbEmptyBodySteps 注释）
        const _steps = m.toolSteps || [];
        if (!(m.content || '').trim() && _steps.length > 0
            && dbEmptyBodySteps.has(`${m.role}::${stepSig(_steps)}`)) continue;
        // 活流（该会话仍有进行中的流）→ 原样保留，流会继续推进（H16 语义）
        if (live) { extra.push(m); continue; }
        // checkpoint-059：僵尸气泡清理——空内容（且无工具步骤）的进行态气泡不恢复
        // （后端要么已完成、要么已中断，均以 DB 为准）；有内容的中断气泡恢复时清除
        // "思考中/等待秒数"等活态标记并标"已停止"（缓存恢复的流永远不会再推进，
        // 否则界面永远停在"思考中…已等待 Ns"卡死态）。
        const hasSubstance = (m.content || '').trim().length > 0 || ((m.toolSteps || []).length > 0);
        if (!hasSubstance) continue;
        // ⛔ #13（0.4.19）：与瞬显路径同一判据补中断标记（见上方缓存瞬显注释）：
        // 无 manualStopped 且无 completedDuration → 异常中断的半成品，标"已中断执行"。
        // 不置 manualStopped（不能谎称用户手动停止）；不用 stopped 判（done 也置，会误标正常完成）。
        extra.push({
          ...m, thinking: false, waitingSeconds: 0, stopped: true,
          ...((!m.manualStopped && m.completedDuration == null)
            ? { interruptedNote: '已中断执行（应用断开或崩溃，内容为半成品）' } : {}),
        });
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
        // C8（0.4.16）：后端 stopped 列 = 用户主动停止（只在 C2取消/CancelledError 路径落 True，
        // done 路径为 False）→ 语义等价前端 manualStopped。DB 来源的消息据此映射出 manualStopped，
        // 使刷新/切回会话后仍显示"已手动停止"标签（此前停止态不落库，刷新即丢，是 C8 根因③）。
        // ⛔ 只映射 DB 来源：前端内存的 stopped 语义更宽（done/error 也置，见 useMessages.ts），
        // 不能全局把 stopped 当 manualStopped，否则正常完成也会显示"已手动停止"（C6 修过的缺陷）。
        const dbMsgs = (msgs as Message[]).map(m =>
          (m.stopped && !m.manualStopped) ? { ...m, manualStopped: true } : m);
        const merged = local.length > 0 ? mergeDbWithLocal(dbMsgs, local, live) : dbMsgs;
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
  // B3（0.4.8）：后端每轮经 state 事件回传的【真实】上下文字数（含 system prompt、
  // 工具结果、tools 声明）。此前前端只按 user/assistant 消息估算，漏算工具读入的大段
  // 内容（如 read_file 读 90KB PDF），顶栏显示"≈17"而实际已数万 token。
  // 有后端真实值时优先采用；无值时回退本地估算。新流/切会话时复位（见各复位点）。
  const backendCtxCharsRef = useRef<number>(0);

  // 问题4：上下文估算——对未归档消息文本做 token 估计（启发式，与发送过滤规则一致：
  // 仅 user/assistant、排除 archived）。中文约 1 字 1 token，英文约 4 字符 1 token，
  // 混合文本按 0.6 系数近似。目的不是精确计费，而是让用户直观看到"移入仓库后确实变少了"。
  function estimateContextTokens(msgs: Message[]): number {
    // B3：后端真实字数优先（同一 0.6 系数换算为 token，与上限口径一致）
    const real = backendCtxCharsRef.current;
    if (real > 0) return Math.round(real * 0.6);
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
  // 0.4.12 附带修复：卸载收尾。
  // mountedRef 置 false 是**主修复**——两处直接写缓存的异步回调据此短路（见其声明处注释）；
  // clearTimeout 是附带的无害卫生（其写操作本就在 updater 内，卸载后不会执行）。
  // ⛔ 此处**故意不 abort 流**：中断语义由 handleStop / 会话切换各自负责，
  // 卸载时擅自 abort 会撞上 C6 刚分离出的 manualStopped（"用户手动停止"）语义。
  useEffect(() => {
    // 挂载即置 true：当前未启用 StrictMode，但若将来启用，React 会 mount→unmount→remount，
    // 缺少这一步会让 mountedRef 永久停在 false，两处卸载守卫将永久短路（缓存不再写入）。
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
      if (cacheSyncTimerRef.current) { clearTimeout(cacheSyncTimerRef.current); cacheSyncTimerRef.current = null; }
      // B12（0.4.21）：⛔ 卸载 cleanup **不 abort 流**，所以 handleSend 的 finally 不会执行
      //   → 流级计时器必须在这里也清一次，否则卸载后它每秒空转（无害但白耗）。
      if (runElapsedTimerRef.current) { clearInterval(runElapsedTimerRef.current); runElapsedTimerRef.current = null; }
    };
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
    // B3（0.4.8）：切换会话时，后端回传的真实字数属于上一个会话 → 复位，
    // 避免新会话短暂沿用旧值。活流会话（流仍在推进）不复位，下一轮 state 会刷新。
    if (activeStreamSidRef.current !== currentSessionId) backendCtxCharsRef.current = 0;
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
            // 0.4.12（C6）：原写 `stopped: m.stopped || true` —— 恒真表达式（无论 m.stopped 为何
            // 都得到 true），是逻辑错误写法。本意确为强制置位（缓存恢复的流永不再推进，须清活态），
            // 故直接写 true 并把意图写进注释。⛔ 不置 manualStopped：恢复的缓存流无法判断
            // 究竟是用户手动停止还是崩溃/关闭窗口导致中断，不能谎称"已手动停止"。
            // ⛔ #13（0.4.19）：但"无法区分"不等于"不标记"——此前恢复出的半成品气泡
            // 没有任何可见标记，用户看不出这条没写完（真机事故：关应用打断后回看，
            // 半截回复与正常回复长得一样）。用两个实时路径可验证的签名区分：
            //   · manualStopped=true → 用户自己点的停止 → 走既有"已手动停止"渲染，不重复标；
            //   · 无 completedDuration → 没走 done 路径（done 必置该字段）→ 异常中断
            //     （崩溃/关应用/断连）→ 标"已中断执行"。
            // ⛔ 不能用 stopped 判：done 路径同样置 stopped，会把正常完成误标成中断。
            .map(m => {
              if (!String(m.id ?? '').startsWith('local_')) return m;
              const base = { ...m, thinking: false, waitingSeconds: 0, stopped: true };
              if (!m.manualStopped && m.completedDuration == null) {
                return { ...base, interruptedNote: '已中断执行（应用断开或崩溃，内容为半成品）' };
              }
              return base;
            });
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
      // 0.4.12 附带修复：卸载守卫。本函数由 handleSend 的 finally 触发，
      // 组件卸载（切 agent / 关面板）后这个 fetch 仍会回来，并直接 syncSessionLocal 写缓存
      // → "幽灵写入"，也是测试跨用例泄漏的源头之一。两个 await 之后都要判。
      if (!mountedRef.current) return;
      if (!res.ok) return;
      // 查虫D：对齐期间用户可能已切走会话——过期结果不得覆盖新会话显示
      if (currentSessionIdRef.current !== sid) return;
      const dbMsgs = (await res.json()) as Message[];
      if (!mountedRef.current) return; // 第二个 await 之后同样可能已卸载
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
      // ⛔ A/B-2（0.4.23）：归档后**不要**把后端真实值归零（否则指示器退回纯前端启发式，
      //   漏掉 system prompt 与工具声明 ≈5060 token → 数字断崖式掉到远低于真实值，
      //   下一轮 state 事件才跳回 = 用户报的"数字忽大忽小"）。
      //   改为只扣掉被归档消息自身的贡献，保住基线，同时仍满足"移入仓库即下降"。
      //   ⛔ 计算与边界守卫全部收在纯函数 `ctxTokensAfterArchive` 里（模块顶部，有单测覆盖）——
      //   此处**不要**再内联一份实现，否则两处漂移。nextTokenUsed 为 null 表示不硬写显示值
      //   （无后端真值 / 扣到 0 两种情形），交由估算 effect 用启发式兜底，避免显示 0。
      const _arch = ctxTokensAfterArchive(backendCtxCharsRef.current,
                                         localMessagesRef.current, selectedMsgIds);
      backendCtxCharsRef.current = _arch.nextCtxChars;
      if (_arch.nextTokenUsed !== null) setTokenUsed(_arch.nextTokenUsed);
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

    // checkpoint-048：可解析的文档调后端解析端点提取文本
    // C3 局部去重（0.4.18）：⛔ 不再用前端格式白名单预判（见文件顶部注释——那份清单
    //    已与后端 SUPPORTED_EXTS 漂移，导致 .pptx 等永远不被解析且界面无任何状态）。
    //    改为「非图片一律交后端裁决」：后端对不支持的格式返回 text=null，
    //    前端按既有三态显示「（仅文件名）」。图片仍单独走 dataUri 视觉链路，不调解析端点。
    for (const item of newItems) {
      if (item.isImage) continue;
      const b64 = item.dataUri.split(',')[1] || '';
      setPendingItems(prev => prev.map(p => p.name === item.name && p.dataUri === item.dataUri ? { ...p, parsing: true } : p));
      try {
        // C7（0.4.18）：带 project/session 归属 → 后端据此落盘并回传绝对路径。
        // ⛔ 会话未创建时（currentSessionIdRef 为 null）后端只解析不落盘、不报错，
        //    不能因此让用户传不了文件（savedPath 缺省 → 正文不写路径，退回旧行为）。
        const res = await fetch(`${API}/attachments/parse`, {
          method: 'POST', headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ name: item.name, content_base64: b64,
            project_id: projectId, session_id: currentSessionIdRef.current || '' }),
        });
        const d = await res.json();
        if (!res.ok) throw new Error(d.detail || `HTTP ${res.status}`);
        setPendingItems(prev => prev.map(p =>
          p.name === item.name && p.dataUri === item.dataUri
            ? { ...p, parsing: false, parsedText: d.text || undefined, parseFailed: !d.text,
                // C7：路径独立于"是否解析成功"——无法解析的格式（如 .zip/图片外的二进制）
                // 同样落盘，agent 后续可自行 read_file，不必因解析失败就彻底丢失原件。
                savedPath: d.saved_path || undefined }
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

  async function handleSend(explicitText?: string) {
    // A5（0.4.16）：思考中（sending）点发送/回车 → 走"插入新消息"，不打断当前轮。
    // 用户拍板语义：模型先做完手上这一轮，下一轮开始前读到这条新消息，再自行
    // 纠偏或补充——正如助手处理用户在其工作时发来的消息的方式。
    if (sending) { handleInject(explicitText); return; }
    // B13（0.4.22）：explicitText 用于"压缩后自动续发"等程序化重发——
    // ⛔ 不能依赖 input state：setTimeout/异步回调里的 handleSend 闭包捕获的是调度时刻的旧 input
    // （点击压缩瞬间 input 为空），导致 hasSendableText('') 为 false、重发静默无效（原意图从未生效）。
    // ⛔⛔ **必须 typeof==='string' 判断**：发送按钮 `onClick={handleSend}` 会把 **click 事件对象**
    // 作为首参传入（React 惯例），若用 `!= null` 判断会把 MouseEvent 当文本 → String(e)='[object Object]'
    // 污染正文（2026-09-11 回归实测：8 用例红、气泡首行 '[object Object]'）。
    const src = typeof explicitText === 'string' ? explicitText : input;
    // checkpoint-067 R-1 + B1（0.4.12）：判空与内容一律走模块级 normalizeInputText/hasSendableText，
    // 与发送按钮的 disabled 共用同一判据（详见那两个函数上方的注释——它们各自记录了一个真实缺陷）。
    const hasText = hasSendableText(src);
    const contentText = normalizeInputText(src).trim();
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
    if (hasText) parts.push(contentText);
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
    // C7（0.4.18）：⛔ 旧实现 `.filter(f => f.parsedText)` 把**解析失败的文件整条丢掉**，
    //    于是那些文件既没内容也没路径 → agent 永远无从得知它的存在，更读不到原件。
    //    现改为：有解析文本 → 文本 + 路径；只有路径（如 .zip/扫描件等解析不出的格式）→ 仅路径，
    //    让 agent 自行决定要不要 read_file。这才是"后续会话读得到"的治本点。
    // ⛔ 表#6（0.4.19）：附件由【推模式】改为【拉模式】——正文只写路径，agent 自己 read_file。
    //
    // 推模式的真实代价：解析全文（后端上限单文件 20 万字符）被拼进 user 消息正文 →
    // 该正文**落库**，并在此后**每一轮**都随 apiMessages 发给模型。传一个 50 页 PDF，
    // 之后每次对话都重复携带它，上下文被吃满、prefill 变慢（0.4.8「主 Agent 自读 90KB PDF
    // 跑 20 分钟」的同类机制，只是发生在附件链路）。
    //
    // ⛔ 为什么现在才能改：表#4（commit 8c2daaa）让 read_file 真能解析 docx/xlsx/pptx/pdf
    // （此前只会返回二进制乱码）→ 给路径 agent 才真读得到。**在此之前给路径等于没给**。
    // 与表#8（委派 file_paths）同一设计：传路径，把"读"的动作交给真正要用内容的那一方。
    //
    // ⛔ 本改动**取代** checkpoint-067 R-2「完整优先，全额注入」的拍板：R-2 当时成立的前提是
    // agent 读不了附件文件，只能靠注入；该前提已被表#4 消除。完整性不降反升——
    // read_file 走 doc_reader，含表格与格式概要，且不受 20 万字符注入上限约束。
    //
    // ⛔ 退化路径必须保留：拿不到 savedPath 时（会话尚未创建 / 后端落盘失败）仍全额注入，
    // 否则用户会**彻底失去**让 agent 看到该文件的能力——那是比上下文膨胀严重得多的回归。
    const textFileContents: string[] = textFileItems
      .filter(f => f.parsedText || f.savedPath)
      .map(f => {
        // 有落盘路径 → 只给路径 + 明确的读取指令（拉模式）
        if (f.savedPath) {
          return `[📄 ${f.name}]（原件已保存：${f.savedPath}）\n`
               + `⛔ 该文件内容**未**随消息发送。如任务需要其内容，请用 read_file 读取上述绝对路径`
               + `（docx/xlsx/pptx/pdf 会自动解析为文本+格式概要）；`
               + `不要凭文件名臆测内容，读不到就如实说明。`;
        }
        // 无路径 → 退回全额注入（宁多占上下文，不可让 agent 彻底看不到文件）
        return `[${f.name}]（⚠️ 原件未能落盘，故全文随消息附上）\n${f.parsedText}`;
      });

    const finalMessages = [...apiMessages];
    if (textFileContents.length && finalMessages.length > 0) {
      const lastIdx = finalMessages.length - 1;
      // 附件正文注入：用模块常量 ATTACH_MARK 作分隔标记，把用户原话与附件全文分开。
      // ⛔ #11（0.4.19）更正过时注释：此处原写「UserBody 折叠时按同一标记切分」，
      //    但 UserBody/FoldSection 已随正文折叠一并删除（用户拍板全删），**折叠消费方已不存在**。
      //    标记本身保留——它早于折叠功能存在，作用是让落库正文里"哪段是附件"可读可辨，
      //    且 agent 仍从落库正文读全文。⛔ 表#6（附件改走路径）落地后本段注入逻辑会被重做。
      finalMessages[lastIdx] = { ...finalMessages[lastIdx], content: finalMessages[lastIdx].content + `\n\n${ATTACH_MARK}\n` + textFileContents.join('\n\n') };
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
    // #1（0.4.20）插入点分裂：streamMsgId 从 const 改 let —— 用户「思考中」插入消息后，
    // 后端发 segment_break，前端把当前气泡定格、插入用户气泡、为新 assistant 气泡开新 id。
    // flushAcc(1353)/patchStreamMsg(1372) 两个闭包捕获的是【变量绑定】不是值，
    // 分裂时给 streamMsgId 重新赋值，后续 token/工具事件自动写入新气泡。
    let streamMsgId = assistantMsg.id!;
    // #1：记录最近一次 segment_break 的断点（后端回传的 break_at = 已生成正文字符数）。
    //   done 的 content 是【全文】（loop.py full_text 跨轮累加），前端据此把全文切成
    //   段1=[:break_at] / 段2=[break_at:]，否则 done 用全文覆盖段2 会让段2 重复段1 内容。
    //   -1 = 本流尚未发生过分裂。
    let lastBreakAt = -1;
    // #1：记录因分裂而定格的各段 assistant 气泡 id。done 写缓存时排除它们，
    //   使缓存与 DB（_persist_assistant 只落一条合并消息）对齐 —— 否则刷新后
    //   段2 作为 DB 全文的「后缀」匹配不上 matchesDb（前缀匹配），会被重复追加。
    const frozenSegIds: string[] = [];

    const controller = new AbortController();
    abortRef.current = controller;
    // checkpoint-055：流式内容实时写穿缓存（500ms 节流）。缓存因此始终是完整"活态"，
    // 合并加载统一以缓存为本地快照——消除"内存快照滞后/串会话"竞态（切走切回不丢气泡）。
    let lastCacheSync = 0;
    // 0.4.12 附带修复：改用组件级 cacheSyncTimerRef（原为闭包局部变量，卸载后无人能清理）。
    // 新流启动前先清掉上一流可能仍挂起的节流 timer，避免两流的 doSync 交错写缓存。
    if (cacheSyncTimerRef.current) { clearTimeout(cacheSyncTimerRef.current); cacheSyncTimerRef.current = null; }
    function scheduleStreamCacheSync() {
      const doSync = () => {
        cacheSyncTimerRef.current = null;
        if (currentSessionIdRef.current !== streamSid) return; // 已切走：归属保护，不写旧会话
        lastCacheSync = Date.now();
        setLocalMessages(prev => { syncSessionLocal(streamSid, prev); return prev; });
      };
      if (cacheSyncTimerRef.current) return; // 已有挂起的同步
      const elapsed = Date.now() - lastCacheSync;
      if (elapsed >= 500) doSync();
      else cacheSyncTimerRef.current = setTimeout(doSync, 500 - elapsed);
    }
    // 节流：token 高频时 rAF 合并一次 setState（避免每 token 重渲染卡 UI）
    // B05（TS-101）：按 streamMsgId 定位目标气泡，不再盲写"最后一条"
    // ⛔⛔ F4（0.4.23 安全区）：**思考增量也并入这同一个按帧 flush**。
    // 真机数据（`36-…测量操作卡.md` 5.7）：模型运行时 Electron 渲染进程 ~103%（烧满一核），
    //   而 ollama 仅 ~22%、codex 跑同样模型前端 0% → 前端在自我空转。D 场景（思考圆圈，
    //   fps 3.7 / longtask 78%）的元凶就是 thinking 分支：qwen3.8 是思考模型、思考增量高频到达，
    //   而此前**每个 delta 都单独 patchStreamMsg** → 每次都重渲染整个消息列表（93~95 条）。
    // 现在：thinkingPreview 增量累积进 accThinking，与正文**共用同一次 rAF 提交**
    //   （一帧内无论到了多少个 delta，最多提交一次）→ 思考期提交数从"每 delta 一次"降到"每帧一次"。
    // ⛔ 语义不变项（都有测试守护，chatPanelF4ThinkingThrottle）：
    //   预览仍是末 120 字（slice(-120) 保留）、思考态开/关与计时走 startThinkingPhase/closeThinkingPhase
    //   （**不参与节流**，故阶段语义与 B12 计时完全不受影响）、每条终结路径都清 accThinking。
    let rafId = 0;
    const flushAcc = () => {
      rafId = 0;
      if (currentSessionIdRef.current !== streamSid) { accContent = ''; accThinking = ''; return; }
      if (!accContent && !accThinking) return;
      const c = accContent; accContent = '';
      const t = accThinking; accThinking = '';
      setLocalMessages(prev => {
        const idx = prev.findIndex(m => m.id === streamMsgId);
        if (idx < 0) return prev;
        const next = [...prev];
        next[idx] = {
          ...next[idx],
          // ⛔ 两个字段都可能为空（只来了 thinking、或只来了 token）→ 条件展开，
          //   避免把 content 写成 `undefined + c` 或无谓地重置 thinkingPreview。
          ...(c ? { content: (next[idx].content || '') + c } : {}),
          ...(t ? { thinkingPreview: ((next[idx].thinkingPreview || '') + t).slice(-120) } : {}),
        };
        return next;
      });
      scheduleStreamCacheSync();
    };
    let accContent = '';
    let accThinking = '';   // F4：思考预览的按帧累积缓冲（与 accContent 同生同灭）
    // 问题（0.4.2实测·长思考界面静默）修复：旧版用一次性 sawContent 守卫，
    // 导致【首轮正文之后的思考增量全被丢弃】——首轮先出正文、后续轮长思考时界面静默、
    // 思考计时停跳。改为"阶段化"：思考指示随每个思考阶段开/关，任意一轮思考都可见、
    // 计时持续跳动，并附简版思考预览（让你实时知道 agent 在想什么、不是空转）。
    let thinkingStartedAt: number | null = null;
    // B05：工具事件也按 id 定位（防止数组变化时落到错误气泡）
    // ⛔⛔ 止血（0.4.24，checkpoint-111）：新增 `persist` 选项（**默认 true，既有调用点语义零变化**）。
    //
    // 真凶（2026-09-13 用户真机复测 + 实测坐实，详见 `39-…执行计划.md` 第一节）：
    //   `syncSessionLocal`（useMessages.ts）每次调用都对 **47MB** 缓存做
    //   `JSON.parse` → 改一个字段 → `JSON.stringify` → `localStorage.setItem`，**全同步阻塞主线程**，
    //   真机单次约 **400ms**（M6 切会话独立实测 406ms、探针 longTaskMaxMs 439ms 互证）。
    //   而它被 scheduleStreamCacheSync 以 500ms 节流挂在本函数上 →
    //   **两个计时器（流级 + 等待）每秒各 patch 一次 = 每秒 2 次 47MB 全量重写 = 主线程被占 803ms/秒**。
    //
    // 为什么计时器不该落盘：它写的三个字段（runElapsed / thinkingElapsed / waitingSeconds）
    //   **本就是瞬态显示值、不落库**（DB 表 session_messages 的 INSERT 列清单不含它们，
    //   已核实 `sidecar/storage/store.py:736`）。刷新后流已结束、计时器不会复活，
    //   这三个字段也不会被读回使用 → 缓存里存它们**毫无价值**，纯粹是每秒 2 次的 400ms 阻塞。
    //
    // ⛔ persist 默认 true：正文 token / 工具步骤 / 错误 / 分裂定格等路径**仍照常写穿**
    //   （B07：流式写穿保证刷新/重启不丢消息）。只有计时器两处显式传 false。
    const patchStreamMsg = (patch: (m: Message) => Message, opts?: { persist?: boolean }) => {
      if (currentSessionIdRef.current !== streamSid) return;
      setLocalMessages(prev => {
        const idx = prev.findIndex(m => m.id === streamMsgId);
        if (idx < 0) return prev;
        const next = [...prev];
        next[idx] = patch(next[idx]);
        return next;
      });
      if (opts?.persist === false) return;   // 瞬态字段：只更新内存态，不写缓存
      scheduleStreamCacheSync();
    };
    // ⛔⛔ B12（0.4.21）：**流级计时器**（取代原"思考阶段计时器"）。
    //
    // 原缺陷：计时器只在思考态运行，首个正文 token 到达即被 closeThinkingPhase 清除，
    //   思考用时定格进 thinkingDuration（这是**正确的**——思考确实已结束，再跳就是谎报）；
    //   而"等待首条正文"的 waitTimer 按 H19 设计同样在首正文即清。于是
    //   「正文已出 + 工具执行中 + 下轮思考未开始」这一区间界面上**没有任何跳动计时**，
    //   用户无从判断任务是否还活着（用户 2026-09-11 报告并附截图：步骤 4/200 时只剩定格的「思考 22s」）。
    //
    // 现设计：**一个**计时器覆盖整轮流的生命周期（流开始建、流结束清），每秒**一次** patchStreamMsg
    //   同时写两个字段：runElapsed（整轮已耗时，全程跳）+ thinkingElapsed（仅思考态更新）。
    //   ⛔ **不新增第二个计时器**：否则思考态期间每秒两次 setLocalMessages → 消息列表重渲染翻倍
    //     （ChatPanel 2400+ 行、正是 B6/B7 待治理的性能瓶颈区，不能再加压）。
    //   ⛔ runElapsed 用**被 patch 的那条气泡自己的 startedAt** 计算，故插入点分裂后自动跟随段2
    //     （streamMsgId 已重指向段2、段2 有自己的 startedAt），无需任何特判；
    //     段1 因定格时被置 stopped=true → isStreamingThis 为 false → 不渲染进行计时（天然正确）。
    //   ⛔ **不得**在此更新 thinkingDuration/completedDuration：前者是思考定格值（语义="思考已结束"），
    //     后者是 C6「正常完成/手动停止/异常中断」三态判据的一半，两者都由各自路径专职写入。
    const startRunElapsedTimer = () => {
      if (runElapsedTimerRef.current) clearInterval(runElapsedTimerRef.current);
      runElapsedTimerRef.current = setInterval(() => {
        const now = Date.now();
        // ⛔ 止血（0.4.24）：persist:false —— 计时 tick 只改瞬态显示值，不得引发 47MB 缓存全量重写
        //   （每秒 1 次 × 约 400ms 阻塞主线程，是真机 longtask 803ms/秒的主因之一）。
        patchStreamMsg(mm => ({
          ...mm,
          runElapsed: mm.startedAt ? Math.round((now - mm.startedAt) / 1000) : mm.runElapsed,
          thinkingElapsed: (mm.thinking && thinkingStartedAt)
            ? Math.round((now - thinkingStartedAt) / 1000) : mm.thinkingElapsed,
        }), { persist: false });
      }, 1000);
    };
    startRunElapsedTimer();   // ⛔ 流一开始就跑，不等到思考阶段（工具先跑/直接出正文的场景也要有计时）
    // 阶段化思考：开/关当前思考阶段（可多次开闭）
    // B1（0.4.8）修复：thinking 增量连续到达（间隔常<1s），此前每次都无条件重置
    // thinkingStartedAt 并重建计时器 → 计时器"创建即清除"永不触发，界面恒显 0s。
    // 改为"阶段开一次"语义：仅当不在思考态时才记录开始时间；已在思考态则直接返回。
    // ⛔ B12：计时器已上移为流级，本函数**不再创建/清除计时器**，只负责置思考态与记录起点。
    let thinkingPhaseOpen = false;
    const startThinkingPhase = () => {
      if (thinkingPhaseOpen) return; // 阶段已开
      thinkingPhaseOpen = true;
      thinkingStartedAt = Date.now();
      patchStreamMsg(m => m.thinking ? m : { ...m, thinking: true, thinkingElapsed: 0 });
    };
    const closeThinkingPhase = () => {
      thinkingPhaseOpen = false; // B1：复位，下一个思考阶段重新计时
      // ⛔ B12：**此处不再 clearInterval** —— 流级计时器要跑完整轮（它还在驱动 runElapsed）。
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
        // ⛔⛔ F4（0.4.23 安全区）：**不再每 delta 一次 patchStreamMsg**（那是 D 场景烧满核的元凶），
        //   改为累积进 accThinking、调度按帧 flush，与正文 token 共用同一次提交。
        //   startThinkingPhase 仍每 delta 调用（它内部有 thinkingPhaseOpen 守卫，重复调用是 no-op，
        //   且思考态开启必须即时、不能被节流拖延）。
        if (delta) {
          accThinking += delta;
          if (!rafId) rafId = requestAnimationFrame(flushAcc);
        }
      } else if (ev.event === 'tool_call') {
        closeThinkingPhase(); // 模型停止思考去调工具，关闭当前思考阶段
        patchStreamMsg(m => ({ ...m, toolSteps: [...(m.toolSteps||[]), { id: d.id||'', name: d.name||'tool', args: d.args, status: 'running' as const }] }));
      } else if (ev.event === 'tool_result') {
        patchStreamMsg(m => ({ ...m, toolSteps: (m.toolSteps||[]).map(st =>
          st.id === d.id ? { ...st, status: d.ok ? 'ok' as const : 'error' as const, summary: d.summary, error: d.error } : st) }));
      } else if (ev.event === 'state') {
        // 问题4：不再用 prompt_eval_count 覆盖指示器——那是"本轮实际评估增量"（KV缓存复用时偏小）。
        // prompt_eval_count 仍记录到消息对象，供调试/历史参考。
        // B3（0.4.8）：改用后端回传的真实上下文字数 ctx_chars 驱动指示器（含工具结果
        // 与 system prompt），根治"≈17"严重低估；无该字段时保持原估算驱动。
        if (typeof d.ctx_chars === 'number' && d.ctx_chars > 0) {
          // ⛔ 0.4.22 重打包修复二（checkpoint-109）：**单调守门**。
          //   ctx_chars 是"该轮开头"的上下文快照，随**轮末** state 回传。M5 重连会让
          //   loop 整轮重跑：attempt2 第 1 轮末的 state（小值，如 6057 token）会**晚于**
          //   attempt1 末轮的 state（大值，如 7617）到达 → 直接覆盖 = 用户看到数字
          //   "发第二条后反而降低"（2026-09-12 实测图2）。
          //   守门：取大者。上下文的真实减少只允许走**显式路径**（归档扣减
          //   ctxTokensAfterArchive / 压缩 / 切会话复位），它们直接写 ref 与显示值，
          //   不经此守门 → 单调性不会妨碍"移入仓库即下降"。
          //   ⛔ 已知代价（如实标注）：归档后下一轮的 state 真值若**小于**扣减后的 ref，
          //     会被守门夹住 → 真值纠正延迟到上下文重新增长超过它为止。换来的是
          //     重连旧值永不覆盖、数字不再忽大忽小（用户首要诉求是单调平滑）。
          const nextChars = Math.max(backendCtxCharsRef.current, d.ctx_chars);
          backendCtxCharsRef.current = nextChars;
          setTokenUsed(prev => Math.max(prev, Math.round(nextChars * 0.6)));
        }
        patchStreamMsg(m => ({ ...m, step: d.step, maxStep: d.max, tokensUsed: d.tokens_used,
          ...(typeof d.prompt_eval_count === 'number' ? { prompt_eval_count: d.prompt_eval_count } : {}) }));
      } else if (ev.event === 'segment_break') {
        // #1（0.4.20）插入点分裂：用户「思考中」插入消息后，后端在轮次边界 drain 到注入、
        // 先发此事件。前端把【当前正在生成的气泡】就地定格、插入用户气泡、为新 assistant
        // 气泡开新 id，并把 streamMsgId 重指向新气泡（flushAcc/patchStreamMsg 闭包捕获变量
        // 绑定，后续 token/工具事件自动写入新气泡）。对齐千问：插入消息上方的旧气泡定格，
        // 针对插入消息的新思考显示在其下方。
        if (currentSessionIdRef.current !== streamSid) return; // 已切走：归属保护
        // ① 先把 rAF 里挂起的 token 增量 flush 进【当前段】，避免定格时丢尾部正文
        if (rafId) { cancelAnimationFrame(rafId); rafId = 0; }
        closeThinkingPhase();               // 停掉当前段的思考计时器
        const pending = accContent; accContent = '';
        // ⛔ F4：思考缓冲必须在此丢弃（不是"留到下一帧"）。
        //   段1 定格时显式置 thinkingPreview: undefined；而 streamMsgId 下面会重指向段2 →
        //   若不清空，挂起的帧 flush 会把**段1 的思考预览写进段2 气泡**（跨段串味）。
        accThinking = '';
        const frozenId = streamMsgId;       // 定格前捕获旧 id（updater 闭包用）
        frozenSegIds.push(frozenId);
        lastBreakAt = (typeof d.break_at === 'number' && d.break_at >= 0) ? d.break_at : -1;
        const injected = Array.isArray(d.injected_messages) ? d.injected_messages : [];
        const newId = newLocalMsgId();
        setLocalMessages(prev => {
          const idx = prev.findIndex(m => m.id === frozenId);
          if (idx < 0) {
            // ⛔ A-3（0.4.23）：这条路径此前**完全静默**——不分裂、不报错，且紧接着
            //   `streamMsgId = newId` 仍会执行 → 后续 token 写向一个不存在的气泡 → 正文也丢。
            //   本次排查（用户实测"插入后不分裂"）最费劲的地方正是它无声无息，只能靠读代码猜。
            //   ⛔ 只加诊断，不改行为：真机复现时控制台能直接给出 frozenId 与现存 id 列表，
            //   一眼看出是 id 漂移（alignLocalIdsWithDb 换了 id）还是气泡已被移除。
            console.warn('[segment_break] 找不到要定格的气泡，分裂已跳过（后续正文可能丢失）',
                         { frozenId, existingIds: prev.map(m => m.id).slice(-8) });
            return prev;
          }
          const next = [...prev];
          // 定格段1：⛔ 必须给 completedDuration —— 否则刷新恢复时会被
          //   `!manualStopped && completedDuration==null` 判据误标成"已中断执行（半成品）"，
          //   但段1 是【正常完成】的段，不是异常中断。stopped 停掉打字机光标。
          const frozenDur = next[idx].startedAt
            ? Math.round((Date.now() - next[idx].startedAt) / 1000) : undefined;
          // ⛔⛔ 0.4.22 重打包修复二（checkpoint-109）：定格时**必须收敛运行态**，两处：
          //   ① toolSteps 的 running → interrupted（convergeRunningSteps）；
          //   ② waitingSeconds 清 0（横幅判据 `!content && waitingSeconds>=8` 即不成立）。
          //   ⛔ 推翻本处历史注释的旧断言（"分裂点不可能有 running"）：该断言只在
          //     **单连接不重连**时成立。用户 2026-09-12 实测 + 落库证据（分裂气泡从未落库、
          //     折叠行却显示 5 步而分裂点只经 1~2 轮）证明 **M5 重连会让 loop 整轮重跑**，
          //     attempt1 断连时残留的 running（其 tool_result 随断连丢失）走到分裂点仍在。
          //   ⛔ 分裂后 streamMsgId 重指向新气泡 → 本流的 +1 计时 / 首 token 清零 / done
          //     收尾**全部写新气泡**，旧气泡再无事件到达 → 不在此处清，横幅与转圈**永久残留**
          //     （截图两帧同为「已等待 26s」不再跳，正是"再无事件到达"的指纹）。
          //   语义说明：interrupted 与 completedDuration 并存**不矛盾**——前者说的是
          //     "这段里有个工具没等到结果"（如实），后者说的是"这段的生成过程正常结束"。
          next[idx] = {
            ...next[idx],
            content: (next[idx].content || '') + pending,
            stopped: true, thinking: false, thinkingElapsed: undefined, thinkingPreview: undefined,
            waitingSeconds: 0,
            toolSteps: convergeRunningSteps(next[idx].toolSteps),
            ...(frozenDur !== undefined ? { completedDuration: frozenDur } : {}),
          };
          // ② 插入注入的用户气泡 + ③ 新开 assistant 气泡（承接后续 token）
          // ⛔⛔ **必须复用 handleInject 已乐观追加的气泡**（0.4.23 修复，I1 测试复现）：
          //   handleInject（:1918-1919）在 POST /inject **之前**就把用户气泡追加到了数组末尾，
          //   本分支若再无条件新建 `local_inject_*` 气泡 → 同一条消息**显示两次**
          //   （实测 `expected 2 to be 1`；刷新后才被 mergeDbWithLocal 的 content 去重掩盖，
          //    故这是**实时视图**缺陷）。修法：按 content 匹配已存在的乐观气泡 → 摘出、
          //   重插到段1 之后并**复用其 id**（该 id 已随乐观气泡写进本地缓存，复用才不错位）。
          // ⛔ **必须从尾部倒着找**：链式插入（用户连插两条同文本）时，上一次分裂已插入的
          //   气泡也在数组里且位置更靠前；正序会误吃掉它，倒序才能命中最新追加的乐观气泡。
          const injectedBubbles: Message[] = injected
            .filter((im: any) => String(im?.content || '').trim())
            .map((im: any, j: number) => {
              const content = String(im.content);
              let dupIdx = -1;
              // 只在段1 之后找（乐观气泡必然在末尾；段1 之前的历史消息不可动）
              for (let i = next.length - 1; i > idx; i--) {
                if (next[i].role === 'user' && String(next[i].content || '') === content) {
                  dupIdx = i; break;
                }
              }
              if (dupIdx >= 0) {
                const [existing] = next.splice(dupIdx, 1);   // 摘出乐观气泡，稍后重插到正确位置
                return existing;                             // ⛔ 复用其 id 与对象
              }
              // 未命中（注入来自其他来源，或乐观气泡未及落地）→ 才新建
              return { id: `local_inject_${Date.now()}_${j}`, role: 'user', content };
            });
          const newAssistant: Message = {
            id: newId, role: 'assistant', content: '', model_used: modelUsed,
            toolSteps: [], step: 0, maxStep: next[idx].maxStep ?? 5, tokensUsed: 0,
            startedAt: Date.now(),
          };
          next.splice(idx + 1, 0, ...injectedBubbles, newAssistant);
          return next;
        });
        streamMsgId = newId;                 // 重指向：后续事件写入新气泡
        scheduleStreamCacheSync();
      } else if (ev.event === 'error') {
        patchStreamMsg(m => {
          const completedDuration = m.startedAt
            ? Math.round((Date.now() - m.startedAt) / 1000)
            : undefined;
          return {
            ...m, streamError: d.detail || '生成出错',
            // 0.4.9 任务161：接收后端报错分析（人话诊断 + 用的哪个模型）
            ...(typeof d.analysis === 'string' && d.analysis ? { errorAnalysis: d.analysis } : {}),
            ...(typeof d.analysis_model === 'string' && d.analysis_model ? { errorAnalysisModel: d.analysis_model } : {}),
            thinking: false, thinkingElapsed: undefined,
            thinkingPreview: undefined, stopped: true,
            ...(completedDuration !== undefined ? { completedDuration } : {}),
          };
        });
      } else if (ev.event === 'auth_request') {
        // 授权弹窗两类：①敏感路径删除（2026-08-28）②联网安装插件/技能（0.4.9 任务152）。
        // 其余操作默认放行，不弹窗。
        const rid = d.request_id;
        const toolName = d.tool_name || '未知工具';
        const targetPath = d.target_path || '未知路径';
        const isNetInstall = d.action === 'net_install';
        const isAppModule = d.action === 'app_module';   // 0.4.9（3.48.2）应用内模块高成本动作确认
        const isComputerUse = d.action === 'computer_use'; // 0.4.9（3.48.1）操作真实电脑，逐步确认
        const ex = d.extra || {};
        const actionLabel = d.action === 'computer_use' ? '操作电脑' : d.action === 'app_module' ? '调用应用模块' : d.action === 'net_install' ? '联网安装' : d.action === 'delete' ? '删除' : d.action === 'write' ? '写入' : d.action === 'mkdir' ? '新建目录' : d.action === 'read' ? '读取' : d.action === 'list' ? '列出' : d.action || '操作';
        // 异步执行，不阻塞 SSE 事件循环
        (async () => {
          let allowed = false;
          let enableNetwork = false;
          if (isNetInstall) {
            // 联网安装：必须告知"下载什么、从哪下载"，用户确认后才联网（用户实测事故：
            // 子 Agent 擅自 install_skill 去 GitHub 拉取，弹 git 凭据窗并装入无关插件）。
            const needEnable = !!ex.need_enable_network;
            allowed = await confirmDialog({
              title: '联网安装确认',
              message: `Agent 请求联网下载并安装${ex.install_type || '内容'}：\n\n来源：${ex.source_url || targetPath}\n\n⚠️ 这会从外部仓库下载代码并装入应用。请确认来源可信后再允许；拒绝则不联网、不安装。`,
              danger: true,
              confirmText: '允许安装',
              cancelText: '拒绝',
              // 当前非全量联网（auto）→ GitHub 大概率连不上，额外提供"同时开启全量联网"勾选
              ...(needEnable ? {
                checkboxLabel: '同时开启全量联网（切换到「全量」模式，经代理访问海外站点）',
                checkboxDefault: true,
                onCheckbox: (c: boolean) => { enableNetwork = c; },
              } : {}),
            });
          } else if (isAppModule) {
            // 3.48.2：运行工作流 / 创建圆桌等高成本动作，执行前请用户确认
            const mod = ex.module || '?';
            const act = ex.action || '?';
            const paramsTxt = (() => {
              try {
                const t = JSON.stringify(ex.params || {}, null, 2);
                return t.length > 600 ? t.slice(0, 600) + '\n…（已截断）' : t;
              } catch { return '（参数无法显示）'; }
            })();
            allowed = await confirmDialog({
              title: '应用模块操作确认',
              message: `Agent 请求调用应用内模块：\n\n模块：${mod}\n动作：${act}\n\n参数：\n${paramsTxt}\n\n该操作成本较高（会运行工作流或创建圆桌讨论、占用模型与内存），是否允许？`,
              danger: true,
              confirmText: '允许执行',
              cancelText: '拒绝',
            });
          } else if (isComputerUse) {
            // 3.48.1：Agent 要操作真实电脑（点击/输入）。误操作后果可见（删文件/发消息/点支付），
            // 故每一步都必须让用户看清"在哪个应用、做什么动作、参数是什么"再决定。
            const desc = ex.desc || '操作电脑';
            const app = ex.app || '（未知前台应用）';
            const argsTxt = (() => {
              try {
                const t = JSON.stringify(ex.args || {}, null, 2);
                return t.length > 500 ? t.slice(0, 500) + '\n…（已截断）' : t;
              } catch { return '（参数无法显示）'; }
            })();
            allowed = await confirmDialog({
              title: '电脑操作确认',
              message: `Agent 请求${desc}：\n\n当前前台应用：${app}\n参数：\n${argsTxt}\n\n⚠️ 这会真实操作你的电脑（鼠标/键盘），效果立即可见且可能难以撤销。确认要执行吗？`,
              danger: true,
              confirmText: '允许执行',
              cancelText: '拒绝',
            });
          } else {
            allowed = await confirmDialog({
              title: '操作授权',
              message: `Agent 请求${actionLabel}敏感位置的内容：\n\n${targetPath}\n\n工具：${toolName}\n\n该操作位于系统敏感区域，是否允许？`,
              danger: true,
              confirmText: '允许',
              cancelText: '拒绝',
            });
          }
          try {
            await fetch(`${API}/auth/respond`, {
              method: 'POST', headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ request_id: rid, allowed, enable_network: allowed && enableNetwork }),
            });
          } catch (e) { console.error('auth respond failed:', e); }
        })();
      } else if (ev.event === 'compact_required') {
        setCompactWarning({ used: d.used, limit: d.limit, est: d.est_rounds_left });
        setSending(false);
      } else if (ev.event === 'cancelled') {
        // C2（0.4.16）：后端确认已停止（stop 端点置位 → gen() 硬取消在飞请求后发此事件）。
        // ⛔ 语义与前端 AbortError 路径**完全一致**（都是用户主动停止），故复用同一处理：
        // 保留已生成内容 + stopped + manualStopped（C6：只有手动停止才显示"已手动停止"文案）。
        // 为什么必须显式处理：前端事件白名单原本**没有 cancelled**，后端发了会被静默忽略 →
        // 若竞态下 cancelled 先于 AbortError 到达（或后端因其他路径取消），消息会既无"已手动停止"
        // 标签也无光标，看起来像"卡住"。不依赖"abort 一定先到"这种脆弱时序。
        if (rafId) { cancelAnimationFrame(rafId); rafId = 0; }
        closeThinkingPhase();
        const c = accContent; accContent = '';
        accThinking = '';   // F4：流已终止，丢弃挂起的思考缓冲（下面已置 thinkingPreview: undefined）
        patchStreamMsg(m => ({ ...m, content: (m.content || '') + c, stopped: true, manualStopped: true, thinking: false,
          // C2 根因③（0.4.16）：⛔ 此前遗漏——工具步骤以 status:'running' 加入，
          // 停止时只 patch 了 content/stopped/thinking，**没碰 toolSteps**，于是
          // 界面上最后一个工具永久显示"正在调用 …"（正是 C2 需求标题的症状），
          // 且 B4 折叠判据 `done && running===0` 永不满足 → 步骤组永远展开（C8"不可折叠"）。
          // 标为 interrupted（既非 ok 也非 error，不谎称成功/失败）。
          toolSteps: convergeRunningSteps(m.toolSteps) }));
        setLocalMessages(prev => { syncSessionLocal(streamSid, prev); return prev; });
        setSending(false);
      }
      // done → 最终 content 以 done 为准（覆盖已累加，保证完整）
      if (ev.event === 'done') {
        if (rafId) { cancelAnimationFrame(rafId); rafId = 0; }
        closeThinkingPhase(); // 收尾：清思考计时器与阶段标记
        // #1：清掉可能挂起的节流缓存写，防止它在下方"折叠缓存"之后又把分裂气泡写回。
        if (cacheSyncTimerRef.current) { clearTimeout(cacheSyncTimerRef.current); cacheSyncTimerRef.current = null; }
        patchStreamMsg(m => {
          let content = m.content || '';
          if (typeof d.content === 'string') {
            // #1：done 的 content 是【全文】（loop.py full_text 跨轮累加 = 段1+段2）。
            //   分裂后 streamMsgId 指向段2，必须只取 [break_at:]，否则段2 会重复显示段1 全文。
            content = (lastBreakAt >= 0) ? d.content.slice(lastBreakAt) : d.content;
          }
          else if (accContent) content = content + accContent;
          // TS-116（3.29）：计算完成用时（气泡出现 → done）
          const completedDuration = m.startedAt
            ? Math.round((Date.now() - m.startedAt) / 1000)
            : undefined;
          return {
            ...m, content, thinking: false, thinkingElapsed: undefined, thinkingPreview: undefined,
            stopped: true,
            // ⛔ 0.4.22 重打包修复二（checkpoint-109）：done 兜底收敛 running 步骤。
            //   正常流下 tool_result 必先于 done 到达，此处收敛是 no-op；
            //   但 **M5 重连/断连会丢 tool_result**（attempt1 的工具结果随连接丢失），
            //   此后 done 到达而 running 永留 → 「正在调用 …」转圈永久残留（F3 测试复现）。
            //   三条手动停止路径之外，这是第五个收敛出口（共用 convergeRunningSteps）。
            toolSteps: convergeRunningSteps(m.toolSteps),
            ...(completedDuration !== undefined ? { completedDuration } : {}),
          };
        });
        if (accContent) { /* done 已覆盖，丢弃残留 */ }
        accContent = '';
        accThinking = '';   // F4：done 已置 thinkingPreview: undefined，挂起的思考缓冲必须丢弃
        // B02：message_count 用冻结的 streamSid，不用闭包 currentSessionId
        setSessions(prev => prev.map(s => s.id === streamSid ? { ...s, message_count: s.message_count + 2 } : s));
        // B07（TS-101）：流式完成 → 本地缓存同步（刷新/重启后可恢复）。
        // 按 streamMsgId 精确定位本流消息（不依赖数组顺序/身份），直接写缓存。
        // ⛔ 显式标注 Message：不标则类型是 `Message | {id,role,content}` 联合，
        //   fallback 分支缺 toolSteps/completedDuration → 下方 #1 缓存折叠访问这两个
        //   可选字段时 tsc 报 TS2339（实测踩到）。fallback 已满足 Message 必需字段。
        const finalMsg: Message = localMessagesRef.current.find(m => m.id === streamMsgId)
          || { id: streamMsgId, role: 'assistant', content: (typeof d.content === 'string' ? d.content : '') };
        // 0.4.12 附带修复（**真实根因之一**）：卸载守卫。
        // 本分支由 reader.read() 循环驱动，组件卸载后循环仍会继续推进并执行到这里，
        // 直接 syncSessionLocal 写缓存 → "幽灵写入"（插桩 localStorage.setItem 抓到的调用栈
        // 正是 applyEvent ← applyEventWrapped ← handleSend）。
        // ⛔ 只守卫这一行写缓存，不要扩大到整块：下方的 setLocalMessages 走 updater，
        // React 18 卸载后 updater 本就不会被调用，无需也不应改变其行为。
        if (mountedRef.current) {
          // checkpoint-061：缓存读取加保护——缓存损坏时 JSON.parse 抛错会被外层误判为
          // 网络错误触发重连循环；损坏即按空缓存兜底（DB 已有定稿，不丢消息）。
          let existing: any[] = [];
          try { existing = JSON.parse(localStorage.getItem('subagent_messages_v4') || '{}')[streamSid] || []; } catch { existing = []; }
          if (frozenSegIds.length > 0) {
            // #1 分裂场景：缓存折叠成与 DB 一致的结构。
            //   DB 侧：inject 端点已立即落库 M1（user）；_persist_assistant 在 done 落
            //   【一条合并 assistant】（段1+段2 全文）。若缓存保留分裂的段1/段2/注入气泡，
            //   刷新 mergeDbWithLocal 时段2（= DB 全文的【后缀】）匹配不上 matchesDb（前缀
            //   匹配）→ 被当多余气泡重复追加。故移除全部分裂气泡，只写一条合并全文 assistant，
            //   使缓存 ≡ DB 的 assistant 部分（M1 刷新时从 DB 加载，注入气泡由 matchesDb 去重）。
            //   ⛔ toolSteps 取段2 的（finalMsg）：刷新后以 DB 为准（DB 存全部步骤），缓存仅过渡显示。
            const dropIds = new Set<string>([...frozenSegIds, streamMsgId]);
            const others = existing.filter((m: any) =>
              !dropIds.has(String(m.id)) && !String(m.id || '').startsWith('local_inject_'));
            const merged: Message = {
              id: streamMsgId, role: 'assistant',
              content: (typeof d.content === 'string' ? d.content : (finalMsg.content || '')),
              model_used: modelUsed, stopped: true, toolSteps: finalMsg.toolSteps,
              ...(finalMsg.completedDuration !== undefined ? { completedDuration: finalMsg.completedDuration } : {}),
            };
            const hasUser = others.some((m: any) => m.id === userMsg.id);
            syncSessionLocal(streamSid, hasUser ? [...others, merged] : [...others, userMsg, merged]);
          } else {
            // checkpoint-055：本轮 user 消息确保在缓存（此前只落 assistant，缓存残缺是丢消息根因之一）。
            // user 在发送时已按序写入，这里仅兜底补入（不重排，保持时序）
            const others = existing.filter((m: any) => m.id !== streamMsgId);
            const hasUser = others.some((m: any) => m.id === userMsg.id);
            syncSessionLocal(streamSid, hasUser ? [...others, finalMsg] : [...others, userMsg, finalMsg]);
          }
        }
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
          // ⛔ 止血（0.4.24）：persist:false —— 同流级计时器，waitingSeconds 是瞬态显示值，
          //   每秒 tick 不得引发 47MB 缓存全量重写。
          patchStreamMsg(m => ({ ...m, waitingSeconds: (m.waitingSeconds || 0) + 1 }), { persist: false });
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
              // 0.4.9（3.47.1）：单元归档开关透传（关闭时后端不暴露该工具）
              auto_archive_unit: autoArchiveUnit,
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
          stopWaitTimer();
          if (e?.name === 'AbortError') {
            // 用户主动停止 → 真断流（后端 CancelledError 静默结束，B06 已截断落盘 DB），保留已渲染内容 + 标记
            if (rafId) { cancelAnimationFrame(rafId); rafId = 0; }
            const c = accContent; accContent = '';
            accThinking = '';   // F4：用户停止，丢弃挂起的思考缓冲（下面置 thinking:false）
            // 0.4.12（C6）：只有 AbortError 才是**用户手动停止**，故额外置 manualStopped；
            // done/error 路径只置 stopped（"流已终止"），不再被渲染成"已手动停止"。
            patchStreamMsg(m => ({ ...m, content: (m.content || '') + c, stopped: true, manualStopped: true, thinking: false,
          // C2 根因③（0.4.16）：⛔ 此前遗漏——工具步骤以 status:'running' 加入，
          // 停止时只 patch 了 content/stopped/thinking，**没碰 toolSteps**，于是
          // 界面上最后一个工具永久显示"正在调用 …"（正是 C2 需求标题的症状），
          // 且 B4 折叠判据 `done && running===0` 永不满足 → 步骤组永远展开（C8"不可折叠"）。
          // 标为 interrupted（既非 ok 也非 error，不谎称成功/失败）。
          toolSteps: convergeRunningSteps(m.toolSteps) }));
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
        accThinking = '';   // F4：用户停止，丢弃挂起的思考缓冲（下面置 thinking:false）
        // 0.4.12（C6）：同上，仅此处（用户手动停止）置 manualStopped
        patchStreamMsg(m => ({ ...m, content: (m.content || '') + c, stopped: true, manualStopped: true, thinking: false,
          // C2 根因③（0.4.16）：⛔ 此前遗漏——工具步骤以 status:'running' 加入，
          // 停止时只 patch 了 content/stopped/thinking，**没碰 toolSteps**，于是
          // 界面上最后一个工具永久显示"正在调用 …"（正是 C2 需求标题的症状），
          // 且 B4 折叠判据 `done && running===0` 永不满足 → 步骤组永远展开（C8"不可折叠"）。
          // 标为 interrupted（既非 ok 也非 error，不谎称成功/失败）。
          toolSteps: convergeRunningSteps(m.toolSteps) }));
        // B07：停止时的已生成部分也同步本地缓存
        setLocalMessages(prev => { syncSessionLocal(streamSid, prev); return prev; });
      } else {
        const errMsg: Message = { id: newLocalMsgId(), role: 'assistant', content: `❌ ${e.message || '请求失败'}`, model_used: getEffectiveModel() };
        setLocalMessages(prev => [...prev, errMsg]);
      }
    } finally {
      abortRef.current = null;
      // B12（0.4.21）：流结束（done/error/abort/重连耗尽都经此出口）→ 清流级计时器，
      //   runElapsed 停止跳动，界面改由 completedDuration 的「完成 Ns」接管。
      if (runElapsedTimerRef.current) { clearInterval(runElapsedTimerRef.current); runElapsedTimerRef.current = null; }
      setSending(false);
      activeStreamSidRef.current = null; // checkpoint-059：流结束，清除活流标记
      setReconnectNotice(null);
      // TS-121（问题3）：user 消息落库后把 local_ 临时 id 换成 DB 数字 id，勾选模式即刻可用
      if (streamSid) alignLocalIdsWithDb(streamSid);
    }
  }

  // 停止生成（C2 / 0.4.16：前端 abort + **通知后端真停**）
  //
  // ⛔ 此前只有 `abortRef.current?.abort()` —— 它仅关掉 SSE 连接，**后端毫不知情**，
  // 会把剩余轮次与 token 全部跑完（本地大模型上可达数分钟）。用户看到的"停止"
  // 只是前端不再显示而已，机器还在烧算力。这是 C2 的第一处断裂。
  //
  // 顺序：**先发停止请求（不 await），再 abort**。
  //   - stop 是独立 HTTP 请求，不依赖 SSE 连接，所以 abort 不会打断它；
  //   - 不 await 是为了 UI 立即响应（abort 同步生效），不让用户等一个往返；
  //   - 失败只记日志不弹错：即使后端没收到，abort 也已让前端脱离该流，
  //     且后端在流结束时（finally）会自行注销，不会留下残留标志。
  function handleStop() {
    // 活流归属会话优先（流开始时登记、结束时清除），兜底用当前会话
    const sid = activeStreamSidRef.current || currentSessionIdRef.current;
    if (sid) {
      fetch(`${API}/chat/${encodeURIComponent(sid)}/stop`, { method: 'POST' })
        .catch(e => console.error('chat stop failed:', e));
    }
    abortRef.current?.abort();
  }

  // A5（0.4.16）：把"思考中"输入的新消息投进后端待注入队列（不打断当前流）。
  // 乐观显示用户气泡（与正常发送一致），后端先落库再入队，loop 下一轮 drain 读到。
  async function handleInject(explicitText?: string) {
    const sid = activeStreamSidRef.current || currentSessionIdRef.current;
    if (!sid) return;
    // B13（0.4.22）：explicitText 供程序化重发（压缩续发等）使用。⛔ 不能依赖闭包 input：
    // 异步回调（setTimeout）里的 handleInject 捕获的是调度时刻的旧 input（常为空），会静默无效。
    // ⛔ typeof==='string' 防护：防止误绑 onClick 时把事件对象当文本（'[object Object]' 污染）。
    const src = typeof explicitText === 'string' ? explicitText : input;
    if (!hasSendableText(src)) return;
    const text = normalizeInputText(src).trim();
    // 乐观追加用户气泡并写穿缓存（与 handleSend 的即时反馈一致）
    const userMsg: Message = { id: newLocalMsgId(), role: 'user', content: text };
    setLocalMessages(prev => { const next = [...prev, userMsg]; syncSessionLocal(sid, next); return next; });
    setInput('');
    try {
      const r = await fetch(`${API}/chat/${encodeURIComponent(sid)}/inject`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ project_id: projectId, agent_id: agentId, content: text }),
      });
      const d = await r.json().catch(() => ({}));
      // 无活流（可能当前轮刚好结束）→ 如实告知，让用户直接发送。
      // ⛔ A-3（0.4.23）：改用 toast，不用 reconnectNotice —— 后者在流的 finally 里被
      //   `setReconnectNotice(null)` 清除（:1909）。注入失败恰恰最常发生在**流即将结束**时
      //   （用户在最后一轮插入 → 后端无下一轮可 drain，见 loop.py 最后一轮补救），
      //   于是提示一闪而过、用户什么也看不到 = **完全感知不到失败**。
      //   toast 不归流生命周期管，能稳定显示 4 秒。
      if (!d.ok) {
        setToast(d.detail || '当前没有进行中的生成，请直接发送');
        setTimeout(() => setToast(null), 4000);
      }
    } catch (e) { console.error('inject failed:', e); }
  }

  function resendLast() {
    // M5 做指数退避自动重连；本任务：手动重发上一条 user 消息
    const lastUser = [...localMessages].reverse().find(m => m.role === 'user');
    if (lastUser) { setInput(lastUser.content); }
  }

  // B13（0.4.22）：显式 content 的重发入口。⛔ 与 resendLast/handleSend 不同，它不依赖
  // 闭包里的 input state —— 压缩回调在 setTimeout 里调用时 input 已变（或本就是空），
  // 用参数传 content 才能保证"压缩后让模型继续任务"的原意图真的生效。
  async function resendWithContent(content: string) {
    const text = String(content || '').trim();
    if (!text) return;
    const sid = activeStreamSidRef.current || currentSessionIdRef.current || currentSessionId;
    if (!sid) return;
    // 流仍在进行 → 走注入（A5 语义）；流已结束 → 走正常发送。二者都显式传文本。
    if (sending) {
      await handleInject(text);
      return;
    }
    // ⛔ 直接传参给 handleSend（显式文本通道），⛔ 不走 setInput+setTimeout 旧路（闭包空 input 静默无效）
    await handleSend(text);
  }

  const modelUsed = getEffectiveModel();

  // Token 进度条颜色三档
  const tokenRatio = contextLimit > 0 ? tokenUsed / contextLimit : 0;
  const tokenBarColor = tokenRatio >= 0.99 ? colors.danger : tokenRatio >= 0.90 ? colors.warn : colors.ok;

  // A12（0.4.25）：顶栏「⋯ 更多操作」菜单项（原 9 枚图标平铺太挤 → 低频动作收纳进菜单）。
  // ⛔ data-tip 一律保留原文（提示文字是文案原文）；可见标签为同义短名。
  const moreMenuItem = (label: string, icon: IconName, tip: string, onClick: () => void,
    opts?: { danger?: boolean; disabled?: boolean; active?: boolean; busy?: boolean }) => (
    <button
      key={label}
      className="ui-menu-item"
      data-tip={tip}
      disabled={opts?.disabled}
      onClick={() => { setShowMoreMenu(false); onClick(); }}
      style={{
        display: 'flex', alignItems: 'center', gap: 8, width: '100%',
        padding: '7px 10px', border: 'none', borderRadius: 6, background: 'transparent',
        fontSize: 12.5, fontFamily: fonts.base, textAlign: 'left', boxSizing: 'border-box',
        color: opts?.danger ? colors.dangerText : colors.textPrimary,
        cursor: opts?.disabled ? 'not-allowed' : 'pointer', opacity: opts?.disabled ? 0.5 : 1,
      }}>
      {opts?.busy
        ? <Spinner size={13} />
        : <Icon name={icon} size={14} style={{ color: opts?.danger ? colors.dangerText : colors.textTertiary, flexShrink: 0 }} />}
      <span style={{ flex: 1, minWidth: 0 }}>{label}</span>
      {opts?.active && <Icon name="check" size={13} style={{ color: colors.accent, flexShrink: 0 }} />}
    </button>
  );

  return (
    <div style={{ display:'flex', height:'100%', minWidth:0, overflow:'hidden', background:colors.bgApp }}>
    {/* 左侧：原会话面板（纵向）；右侧：知识仓库面板（可折叠）。
        0.4.4：顶部/左右加留白——顶栏此前紧贴窗口外框，视觉上"贴边"。 */}
    <div className="chat-topbar-scope" style={{ display:'flex', flexDirection:'column', height:'100%', flex:1, minWidth:0, overflow:'hidden' }}>
      {/* Top bar —— A12「纸面工具」：白底细线 + 低频操作收纳进 ⋯ 菜单（治"会话窗上方拥挤"）。
          TS-121：nowrap——右侧知识仓库面板展开收窄会话区时，按钮组不得换行把顶栏撑高挤内容。
          0.4.0 实测重叠根治：原生 select 被压缩时文字不裁剪会向左溢出覆盖相邻元素（实测盖住 Agent 名），
          必须用"容器收缩 + overflow 裁剪"包裹；名字保留最小宽度 + 省略号。 */}
      <div style={{ height:50, padding:'0 14px', borderBottom:`1px solid ${colors.borderDefault}`, background:colors.bgCard, display:'flex', justifyContent:'space-between', alignItems:'center', gap:8, flexShrink:0, overflow:'hidden' }}>
        <div style={{display:'flex',alignItems:'center',gap:8,flexWrap:'nowrap',minWidth:0}}>
          <div style={{display:'flex',alignItems:'center',gap:7,flexShrink:1,minWidth:48}}>
            <span style={{ width:26, height:26, borderRadius:8, flexShrink:0, display:'inline-flex', alignItems:'center', justifyContent:'center', background:colors.accentBgSoft, border:`1px solid ${colors.accentBorder}` }}>
              <Icon name="bot" size={14} style={{color:colors.accentText}} />
            </span>
            <span style={{fontSize:14,fontWeight:600,color:colors.textPrimary,whiteSpace:'nowrap',overflow:'hidden',textOverflow:'ellipsis'}}>{agentInfo?.name || agentId.slice(0,8)}...</span>
          </div>
          {/* select 收缩容器：flex 容器负责压缩，overflow:hidden 裁剪，杜绝文字溢出覆盖 */}
          <div className="chat-topbar-select" style={{flex:'0 1 auto',minWidth:0,maxWidth:180,overflow:'hidden'}}>
            <select
              value={currentSessionId || ''}
              onChange={e => handleSwitchSession(e.target.value)}
              style={{...selectStyle, width:'100%', minWidth:80, height:28, borderRadius:radius.s}}
            >
              {sessions.length === 0 && <option value="">无会话</option>}
              {sessions.map(s => (
                <option key={s.id} value={s.id}>{s.title} ({s.message_count}条)</option>
              ))}
            </select>
          </div>
          {/* TS-115（3.26）：会话列表刷新按钮 */}
          <button className="ui-btn ui-btn-ghost ui-icon-btn" onClick={handleRefreshSessions} data-tip="刷新会话列表" disabled={refreshing}
            style={{...iconBtn, cursor: refreshing ? 'default' : 'pointer'}}>
            {refreshing
              ? <Spinner size={14} />
              : <Icon name="rotate-cw" size={15} />}
          </button>
          <button className="ui-btn ui-btn-ghost ui-icon-btn" onClick={handleNewSession} data-tip="新建会话"
            style={iconBtn}>
            <Icon name="plus" size={16} />
          </button>
        </div>
        <div style={{display:'flex',alignItems:'center',gap:10,flexShrink:0}}>
          <span className="chat-topbar-model" style={{fontFamily:fonts.mono,fontSize:11.5,color:colors.textTertiary,whiteSpace:'nowrap',overflow:'hidden',textOverflow:'ellipsis',maxWidth:140}}>{modelList.find(m=>m.name===modelUsed)?.name || modelUsed}</span>
          {contextLimit > 0 && (
            <div
              title={`当前会话上下文估算：约 ${tokenUsed} / 上限 ${contextLimit}（按未移入仓库的对话实时估算，移入仓库后即下降；非模型精确计费口径）`}
              style={{display:'flex',alignItems:'center',gap:6,fontSize:11, cursor:'help'}}>
              <span className="chat-topbar-ctx-text" style={{color:colors.textTertiary, whiteSpace:'nowrap'}}>上下文 ≈{tokenUsed} / {contextLimit}</span>
              <div style={{width:64,height:4,background:colors.borderSubtle,borderRadius:2,overflow:'hidden'}}>
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
            <span className="chat-topbar-ctx-text" style={{color:colors.dangerText,fontSize:11}}>上下文：获取失败</span>
          )}
          {currentSessionId && (
            <>
              {/* TS-120：勾选消息移入知识仓库 */}
              <button className="ui-btn ui-btn-ghost ui-icon-btn"
                onClick={() => { setSelectMode(v => !v); setSelectedMsgIds(new Set()); }}
                data-tip="勾选消息 → 移入知识仓库"
                style={{...iconBtn, background:selectMode?colors.accentBg:'transparent'}}>
                <Icon name="check" size={16} style={{color:selectMode?colors.accentText:undefined}} />
              </button>
              {/* TS-120：知识仓库面板开关（可收起） */}
              <button className="ui-btn ui-btn-ghost ui-icon-btn"
                onClick={() => setShowKnowledgePanel(v => !v)}
                data-tip="知识仓库（检索/注入）"
                style={{...iconBtn, background:showKnowledgePanel?colors.accentBg:'transparent'}}>
                <Icon name="database" size={16} style={{color:showKnowledgePanel?colors.accentText:undefined}} />
              </button>
              {/* A12：⋯ 更多操作（总结 / 导出 / 单元归档 / 重命名 / 删除） */}
              <div style={{ position:'relative' }}>
                <button className="ui-btn ui-btn-ghost ui-icon-btn" onClick={() => setShowMoreMenu(v => !v)} data-tip="更多操作"
                  style={{...iconBtn, background:showMoreMenu?colors.bgActive:'transparent'}}>
                  <Icon name="dots" size={16} />
                </button>
                {showMoreMenu && (
                  <>
                    <div style={{ position:'fixed', inset:0, zIndex:1200 }} onClick={() => setShowMoreMenu(false)} />
                    <div className="ui-pop-in" style={{ ...menuCard, position:'absolute', top:34, right:0, zIndex:1201, minWidth:190, padding:4, transformOrigin:'top right' }}>
                      {moreMenuItem('生成会话总结', 'file-text', '生成会话总结并保存（Markdown + 记录）', handleSummarizeSession, { disabled: summarizing, busy: summarizing })}
                      {moreMenuItem('导出会话', 'download', '导出会话为 Markdown', handleExportSession)}
                      {moreMenuItem('单元归档', 'archive', '单元归档：开启后 Agent 每完成一个工作单元（批量任务）会把该段对话移入知识仓库，防止上下文膨胀。默认关闭，需手动开启', () => setAutoArchiveUnit(v => !v), { active: autoArchiveUnit })}
                      <div style={{ height:1, background:colors.borderSubtle, margin:'4px 6px' }} />
                      {moreMenuItem('重命名', 'pencil', '重命名', () => handleRenameSession(currentSessionId))}
                      {moreMenuItem('删除', 'trash', '删除', () => handleDeleteSession(currentSessionId), { danger: true })}
                    </div>
                  </>
                )}
              </div>
            </>
          )}
        </div>
      </div>

      {/* M2 溢出预警警告条 (§8.7) */}
      {compactWarning && (
        <div style={{ ...calloutStyle('warn'), borderRadius:radius.m, padding:'10px 16px', margin:'8px 16px 0', flexWrap:'wrap', animation:'ui-fade-in .14s ease' }}>
          <Icon name="alert-triangle" size={16} style={{flexShrink:0}} />
          <span>上下文已用 {compactWarning.used}/{compactWarning.limit}（{Math.round(compactWarning.used/compactWarning.limit*100)}%），预计还能约 {compactWarning.est >= 0 ? compactWarning.est : '未知'} 轮。请选择处理方式：</span>
          <div style={{display:'flex',gap:8,flexWrap:'wrap'}}>
            <button className="ui-btn ui-btn-primary" onClick={async () => {
              try {
                await fetch(`${API}/sessions/${currentSessionId}/compact`, { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({}) });
                setCompactWarning(null);
                setToast('已压缩，继续任务中...');
                setTimeout(() => setToast(null), 3000);
                // ⛔⛔ B13 修复（2026-09-11，两条真实 bug）：
                //   旧实现 `setInput(lastUser.content); setTimeout(()=>handleSend(),500)` 有两个缺陷：
                //   ① **回填输入框**＝播下重复种子：用户看到输入框里出现刚发过的消息，任何后续回车
                //      （含 B14 场景里"想清掉残留换行"的回车）都会把它**再发一遍**（走 A5 inject →
                //      界面出现第二条一模一样的用户气泡 = 用户截图现象）。
                //   ② **自动重发静默无效**：setTimeout 捕获的 handleSend 闭包里 input 是点击瞬间的空串，
                //      `hasSendableText('')` 为 false → 直接 return，"压缩后让模型继续任务"的原意图从未生效。
                //   ✅ 新实现：压缩成功后重新拉消息，判断最后一条 user 消息**是否还在保留区**：
                //      - 还在（默认 keep_recent=10，通常如此）→ **什么都不做**（它已在上下文里，模型看得到；
                //        回填输入框只会造成重复）。仅保留 toast 提示。
                //      - 已被压缩掉 → 用**显式 content 参数**重发（不依赖闭包 input），保原设计意图。
                try {
                  const after = await fetch(`${API}/sessions/${currentSessionId}/messages?project_id=${encodeURIComponent(projectId)}`).then((r: any) => r.ok ? r.json() : []);
                  const afterList = Array.isArray(after) ? after : [];
                  const lastUser = [...(localMessagesRef.current || [])].reverse().find((m: any) => m.role === 'user');
                  // ⛔⛔ 不能用 id 比较：localMessages 里的 id 是 **local_ 临时 id**（流未结束时
                  //   alignLocalIdsWithDb 还没把它换成 DB 数字 id），与 messages 接口返回的 DB id
                  //   **永不相等** → has() 恒 false → 永远误判"已被压缩掉" → 永远重发（=bug 复现）。
                  //   ✅ 改用 **content+role 比较**：只要保留区里还有"同内容的 user 消息"，
                  //   就说明模型上下文里看得到它 → 不重发（重复内容无意义且会造成重复气泡）。
                  const retained = lastUser && afterList.some((m: any) =>
                    m.role === 'user' && String(m.content || '') === String(lastUser.content || ''));
                  if (lastUser && !retained) {
                    // 最后一条 user 确实已被压缩掉 → 显式重发（content 作参数，避免旧闭包空 input）
                    resendWithContent(String(lastUser.content || ''));
                  }
                } catch { /* 判断失败则不重发（保守：宁可少发不可重复） */ }
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
      {toast && <div style={{ position:'absolute', top:60, right:16, background:colors.bgToast, color:'#FFFFFF', padding:'8px 14px', borderRadius:radius.s, fontSize:13, zIndex:999, boxShadow:shadow.m, animation:'ui-fade-in .14s ease' }}>{toast}</div>}

      {/* TS-120：勾选模式浮动栏（选中 N 条 → 移入知识仓库） */}
      {selectMode && (
        <div style={{ ...menuCard, position:'absolute', bottom:96, left:'50%', transform:'translateX(-50%)', display:'flex', alignItems:'center', gap:8, padding:'8px 14px', zIndex:998, animation:'ui-fade-in .14s ease' }}>
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
        <div style={{ position:'absolute', inset:0, background:'rgba(28,28,26,0.36)', backdropFilter:'blur(6px)', WebkitBackdropFilter:'blur(6px)', display:'flex', alignItems:'center', justifyContent:'center', zIndex:1000, animation:'ui-overlay-in .16s ease' }}
          onClick={() => setShowTransferModal(false)}>
          <div onClick={e => e.stopPropagation()}
            style={{ width:400, background:colors.bgCard, borderRadius:radius.l, boxShadow:shadow.l, padding:22, border:`1px solid ${colors.borderSubtle}`, animation:'ui-pop-in .18s cubic-bezier(.2,.8,.3,1)' }}>
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
        <div style={{ ...calloutStyle('warn'), borderRadius:radius.m, padding:'6px 16px', margin:'8px 16px 0', animation:'ui-fade-in .14s ease' }}>
          <Spinner size={14} />
          <span style={{fontSize:13}}>{reconnectNotice}</span>
        </div>
      )}

      {/* Messages (§8.9)：A12 正文居中限宽（820），纸面底 */}
      <div ref={scrollAreaRef} onScroll={handleScroll} onWheel={handleWheel} style={{ flex:1, overflowY:'auto', padding:'16px 24px', position:'relative', background:colors.bgApp }}>
        {localMessages.length === 0 && (
          <div style={{textAlign:'center',marginTop:'30vh',display:'flex',flexDirection:'column',alignItems:'center',gap:8}}>
            <Icon name="message-circle" size={36} style={{color:colors.borderStrong}} />
            <span style={{fontSize:13,color:colors.textTertiary}}>{currentSessionId ? '新会话 — 开始对话吧' : '加载中...'}</span>
          </div>
        )}
        {localMessages.map((msg, i) => {
          const isUser = msg.role === 'user';
          const isSystem = msg.role === 'system';
          // ⛔ B10/C8 局部去重（0.4.18）：这个"当前正在流式生成的就是本条"判据，
          //    原本在渲染循环里**字面量重复多次**（工具步骤折叠 done / 打字机光标 等），
          //    注释还写着"复用同一判据"却是各写各的 → 改一处漏一处的漂移隐患。
          //    提取为单一常量共用：工具步骤折叠用 !isStreamingThis、打字机光标用 isStreamingThis。
          //    （#11/0.4.19 删正文折叠后，正文不再是消费方，但 B4 步骤折叠与光标仍共用此判据。）
          const isStreamingThis = sending && !msg.stopped && !msg.streamError
            && i === localMessages.length - 1;
          const bubbleBg = isUser ? colors.bgCard : isSystem ? colors.okBg : 'transparent';
          const bubbleBorder = isUser ? `1px solid ${colors.borderDefault}` : isSystem ? `1px solid ${colors.okBorder}` : 'none';
          const bubbleColor = isUser ? colors.textPrimary : isSystem ? colors.okText : colors.textPrimary;
          const bubbleRadius = isUser ? `${radius.l}px ${radius.l}px ${4}px ${radius.l}px` : radius.m;
          /* A12：assistant 改无框文档式（透明底、无内边距卡片感），用户消息保留纸面卡片气泡 */
          const bubblePadding = isUser || isSystem ? '10px 14px' : '2px 0';
          return (
            <div key={msg.id || i} className="ui-rise-in" style={{ maxWidth:820, margin:'0 auto 14px', display:'flex', flexDirection:'column', alignItems: isUser ? 'flex-end' : 'flex-start' }}>
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
              {/* B3：maxWidth 已封顶，但 flex 子项默认 min-width:auto（不得小于内容宽度），
                  长串会把气泡顶开并在消息区拉出横向滚动条；minWidth:0 解开该下限即可让
                  overflow-wrap:anywhere 生效。⛔ 这里**故意不加 overflow:hidden**——那会把仍溢出的
                  内容静默裁掉、用户永久看不到；表格与代码块各自有独立横向滚动层，不需要它兜底。 */}
              <div style={{ maxWidth:'78%', minWidth:0, padding:bubblePadding, borderRadius:bubbleRadius, background:bubbleBg, border:bubbleBorder, color:bubbleColor }}>
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
                {/* 思考中指示（阶段化：任意轮思考都显示，秒数每秒跳动，附简版预览）
                    A12：去掉 callout 框，改细状态行——6px 雾蓝脉动圆点 + 文案，
                    思考预览降为 tertiary 三行截断。文案「思考中… Ns」原样保留。 */}
                {msg.role === 'assistant' && msg.thinking && (
                  <div style={{ marginBottom:6, display:'flex', flexDirection:'column', gap:3 }}>
                    <span style={{ display: 'inline-flex', alignItems: 'center', gap: 7, fontSize:12, color:colors.accentText }}>
                      <span style={{ width:6, height:6, borderRadius:'50%', background:colors.accent, flexShrink:0, animation:'ui-pulse-dot 1.2s ease-in-out infinite' }} />
                      <span>思考中… {msg.thinkingElapsed != null ? `${msg.thinkingElapsed}s` : ''}</span>
                    </span>
                    {/* 简版思考预览：让你实时知道 agent 在想什么（只留末尾 120 字） */}
                    {msg.thinkingPreview && (
                      <span style={{ fontSize: 11, color: colors.textTertiary, lineHeight: 1.5,
                        display: '-webkit-box', WebkitLineClamp: 3, WebkitBoxOrient: 'vertical', overflow: 'hidden',
                        wordBreak: 'break-word', width: '100%', paddingLeft:13 }}>
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
                    {/* B12（0.4.21）：整轮进行计时 —— 补上「思考已结束但任务仍在进行」的空白区间。
                        ⛔ 判据用 isStreamingThis（= sending && !stopped && !streamError）：
                          · 思考态不显示（此时上方「思考中… Ns」在跳，避免两个数字同时跳成噪音）
                          · 段1（分裂定格，stopped=true）不显示 · 手动停止/出错/历史消息（无活流）不显示
                        ⛔ 流一结束（finally 置 sending=false）自动消失，由右侧「完成 Ns」接管。 */}
                    {isStreamingThis && msg.runElapsed != null && msg.runElapsed > 0 && (
                      <span style={{display:'inline-flex',alignItems:'center',gap:4}}>
                        <Icon name="clock" size={12} /> 进行中 {msg.runElapsed}s
                      </span>
                    )}
                    {msg.completedDuration != null && msg.completedDuration > 0 && (
                      <span style={{display:'inline-flex',alignItems:'center',gap:4}}>
                        <Icon name="check-circle" size={12} /> 完成 {msg.completedDuration}s
                      </span>
                    )}
                  </div>
                )}
                {/* M1-4 + B4（0.4.12）：工具步骤整组折叠（在 content 上方，顺序堆叠）。
                    done = 该消息不是"正在流式的那条"——复用下方光标的同一判据，
                    保证流进行中的步骤始终可见，流一结束即自动收拢成一行。
                    ⛔ 不用 msg.stopped 判 done：DB 加载的历史消息不带 stopped，
                    而历史消息的工具步骤恰恰最该折叠。 */}
                {msg.toolSteps && msg.toolSteps.length > 0 && (
                  <ToolStepsGroup
                    steps={msg.toolSteps}
                    done={!isStreamingThis}
                  />
                )}
                {/* 内容：用户消息纯文本原样显示；assistant 用 Markdown 流式渲染。
                    ⛔ #11（0.4.19）：正文折叠已按用户拍板删除（原 B10 附件段折叠 /
                    C8 超长正文折叠），内容与附件一律铺开，不再藏进「展开全文」。
                    ⛔ isStreamingThis 仍被两处消费：上方 B4 工具步骤折叠 done 判据、
                    下方打字机光标 —— 它不是折叠遗留物，不可随正文折叠一并删掉。 */}
                {msg.role === 'user'
                  ? <div style={{whiteSpace:'pre-wrap',overflowWrap:'anywhere',wordBreak:'break-word',fontSize:14,lineHeight:1.65,minWidth:0,maxWidth:'100%'}}>{msg.content}</div>
                  : <StreamingMarkdown text={msg.content} />}
                {/* 流式打字机光标 */}
                {msg.role === 'assistant' && isStreamingThis && (
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
                <div style={{ ...calloutStyle('error'), marginTop:8, flexDirection:'column', maxWidth:'78%', borderRadius:radius.m }}>
                  <div style={{display:'flex',alignItems:'flex-start',gap:8}}>
                    <Icon name="alert-triangle" size={16} style={{flexShrink:0,marginTop:2}} />
                    <span style={{whiteSpace:'pre-wrap',wordBreak:'break-word'}}>{msg.streamError}</span>
                  </div>
                  {/* 0.4.9 任务161：报错分析（用户设置的默认模型给出的人话诊断） */}
                  {msg.errorAnalysis && (
                    <div style={{
                      marginTop:10, padding:'8px 10px', borderRadius:radius.s,
                      background:colors.bgSidebar, border:`1px solid ${colors.borderDefault}`,
                      display:'flex', alignItems:'flex-start', gap:8,
                    }}>
                      <Icon name="sparkle" size={15} style={{flexShrink:0,marginTop:2,color:colors.accent}} />
                      <div style={{flex:1,minWidth:0}}>
                        <div style={{fontSize:11.5,color:colors.textTertiary,marginBottom:3}}>
                          报错分析{msg.errorAnalysisModel ? `（${msg.errorAnalysisModel}）` : ''}
                        </div>
                        <div style={{fontSize:12.5,color:colors.textSecondary,lineHeight:1.6,whiteSpace:'pre-wrap',wordBreak:'break-word'}}>
                          {msg.errorAnalysis}
                        </div>
                      </div>
                    </div>
                  )}
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
                <div style={{ ...calloutStyle('info'), marginTop:8, maxWidth:'78%', borderRadius:radius.m }}>
                  <Spinner size={14} />
                  <span style={{fontSize:12}}>模型加载/推理中，较久属正常（本地模型）…已等待 {msg.waitingSeconds}s</span>
                </div>
              )}
              {/* 0.4.12（C6）：只有**用户手动停止**（manualStopped）才显示此条。
                  此前判据是 stopped，而 done/error 正常结束也置 stopped → 正常执行完
                  也错误显示"已手动停止 重新发送"（用户真机反馈）。stopped 现仅用于停光标。 */}
              {msg.role === 'assistant' && msg.manualStopped && (
                <div style={{ marginTop:8, display:'flex', alignItems:'center', gap:8 }}>
                  <Icon name="stop" size={14} style={{color:colors.textTertiary}} />
                  <span style={{ fontSize:12, color:colors.textTertiary }}>已手动停止</span>
                  <button className="ui-btn ui-btn-secondary" onClick={resendLast} style={{...btnSecondary, height:22, padding:'0 8px', fontSize:12}}>
                    <Icon name="rotate-cw" size={14} /> 重新发送
                  </button>
                </div>
              )}
              {/* #13（0.4.19）：缓存恢复的异常中断气泡的可见标记。
                  此前这类气泡（崩溃/关应用打断）恢复后与正常回复长得一样，
                  用户看不出这条没写完。判据与置位逻辑见 loadSessionMessages/瞬显注释。
                  ⛔ 与"已手动停止"互斥渲染：manualStopped 的气泡走上面那条，不重复标。 */}
              {msg.role === 'assistant' && !msg.manualStopped && msg.interruptedNote && (
                <div style={{ marginTop:8, display:'flex', alignItems:'center', gap:6 }}>
                  <Icon name="alert-triangle" size={14} style={{color:colors.textTertiary}} />
                  <span style={{ fontSize:12, color:colors.textTertiary }}>{msg.interruptedNote}</span>
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
                    cursor:'pointer', boxShadow:shadow.s, animation:'ui-pop-in .16s ease'}}>
            <Icon name="chevron-down" size={16} style={{color:colors.textSecondary}} />
          </button>
        )}
      </div>

      {/* 暂存区 (§8.11) */}
      {pendingItems.length > 0 && (
        <div style={{ padding:'8px 16px', borderTop:`1px solid ${colors.borderSubtle}`, background:colors.bgSidebar, display:'flex', flexWrap:'wrap', gap:8, alignItems:'center' }}>
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

      {/* Input (§8.12)：A12 悬浮 composer 卡片——外层留白、内层 820 居中纸面卡片，
          textarea 去边框融入卡片，底行左附件右发送/停止（30px 石墨圆钮）。
          ⛔ 事件链/IME 守卫/preventDefault/placeholder/data-tip 全部原样保留。 */}
      <div style={{ padding:'10px 16px 14px', flexShrink:0 }}>
        <input ref={fileInputRef} type="file" multiple style={{display:'none'}} onChange={handleFileChange} accept="image/*,.txt,.md,.csv,.json,.js,.ts,.py,.html,.css,.yaml,.yml,.log,.ini,.pdf,.doc,.docx,.xlsx,.xlsm,.pptx" />
        <div style={{ maxWidth:820, margin:'0 auto', background:colors.bgCard, border:`1px solid ${colors.borderDefault}`, borderRadius:radius.l, boxShadow:shadow.s }}>
        <textarea value={input} disabled={inputDisabled} onChange={e=>setInput(e.target.value)}
          onCompositionStart={()=>{composingRef.current=true;}}
          onCompositionEnd={()=>{composingRef.current=false; compositionEndAtRef.current=Date.now();}}
          onKeyDown={e=>{
            // checkpoint-067b R-1/D-6：精确区分"输入法选词的回车"与"想发送的回车"。
            // 仅依赖 composing/isComposing/keyCode229 判断是否在输入法组合中（这些为真时回车是选词确认，不发送）。
            // 去掉原 80ms 时间窗的粗暴拦截（它会把用户"想发送的回车"吞掉变成换行）。
            if (composingRef.current || e.nativeEvent.isComposing || e.keyCode===229) return;
            if (e.key==='Enter' && !e.shiftKey) {
              // B14（0.4.22）：⛔ 必须 preventDefault。handleSend 会 setInput('') 清空输入框，
              // 但浏览器对回车键的**默认行为**是往 textarea 插入一个换行——不阻止的话，
              // 清空后又被插入 '\n' → 值非空 → placeholder 中文提示消失、看似"残留一个换行"，
              // 用户需再按一次回车才恢复空白（用户 2026-09-11 报告）。
              // ⛔ 不影响 Shift+Enter（换行，走浏览器默认）与输入法选词（上面已 return）。
              e.preventDefault();
              handleSend();
            }
          }}
          placeholder={pendingItems.length ? '输入文字描述，或直接发送...' : '输入消息（可先上传附件，再输入文字，一起发送）...'}
          style={{padding:'10px 14px 4px',border:'none',background:'transparent',color:colors.textPrimary,fontSize:14,width:'100%',minHeight:38,maxHeight:120,resize:'none',fontFamily:fonts.base,lineHeight:1.6,boxSizing:'border-box',outline:'none'}} />
        <div style={{ display:'flex', alignItems:'center', padding:'4px 10px 8px' }}>
          {/* 验收修复：补回上传按钮（checkpoint-003 会话系统重写时丢失，handleUpload 成死代码） */}
          <button className="ui-btn ui-btn-ghost" onClick={handleUpload} data-tip="上传图片或文本文件（发送前可在暂存区删除）"
            style={{width:28,height:28,padding:0,display:'inline-flex',alignItems:'center',justifyContent:'center',borderRadius:radius.s,flexShrink:0,border:'none'}}>
            <Icon name="paperclip" size={16} style={{color:colors.textSecondary}} />
          </button>
          <div style={{ flex:1 }} />
        {sending ? (
          <>
            {/* A5（0.4.16）：思考中也能发送——插入新消息（不打断当前轮，下一轮被读到）。
                无文本时禁用，与正常发送按钮同一判据。 */}
            <button className="ui-btn ui-btn-primary" onClick={() => handleSend()} data-tip="发送新消息（模型完成当前这一步后会读到）"
              disabled={!hasSendableText(input)}
              style={{width:30,height:30,padding:0,display:'inline-flex',alignItems:'center',justifyContent:'center',borderRadius:'50%',border:'none',cursor:'pointer',flexShrink:0,opacity:hasSendableText(input)?1:0.5,marginRight:6}}>
              <Icon name="send" size={15} style={{color:colors.onInk}} />
            </button>
            <button onClick={handleStop} data-tip="停止"
              style={{width:30,height:30,padding:0,display:'inline-flex',alignItems:'center',justifyContent:'center',borderRadius:'50%',border:'none',background:colors.ink,cursor:'pointer',flexShrink:0}}>
              <Icon name="stop" size={12} style={{color:colors.onInk}} />
            </button>
          </>
        ) : (
          <button className="ui-btn ui-btn-primary" onClick={() => handleSend()} data-tip="发送" disabled={inputDisabled || (!hasSendableText(input) && pendingItems.length===0)}
            style={{width:30,height:30,padding:0,display:'inline-flex',alignItems:'center',justifyContent:'center',borderRadius:'50%',border:'none',cursor:'pointer',flexShrink:0,opacity:(!hasSendableText(input) && pendingItems.length===0) ? 0.5 : 1}}>
            <Icon name="send" size={15} style={{color:colors.onInk}} />
          </button>
        )}
        </div>
        </div>
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
