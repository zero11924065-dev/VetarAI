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
import React, { useState } from 'react';
import { ProjectPanel } from './panels/ProjectPanel';
import { AgentPanel } from './panels/AgentPanel';
import { ChatPanel } from './panels/ChatPanel';
import { TaskPanel } from './panels/TaskPanel';
import { RoundtablePanel } from './panels/RoundtablePanel';
import { IndependentAgentsPanel } from './panels/IndependentAgentsPanel';
import { RoundtableView } from './panels/RoundtableView';
import { SettingsPage } from './panels/SettingsPage';
import { WorkflowPanel } from './panels/WorkflowPanel';
import { ModuleNav, ModuleKey } from './panels/ModuleNav';
import { TipPortal } from './TipPortal';
import { getApiBase } from './apiBase';
import { colors, fonts } from './theme';
import { Icon, Spinner } from './Icon';
import { alertDialog } from './Dialog';

export default function App() {
  const [selectedProjectId, setSelectedProjectId] = useState<string | null>(null);
  const [selectedAgentId, setSelectedAgentId] = useState<string | null>(null);
  // 0.2.1（TS-119）：一级模块导航——智能中心（独立Agent+项目组，现有页面原样）/
  // 流程中心（工作流模块）。切换采用显示/隐藏（不卸载），运行中的聊天流与工作流不中断。
  const [activeModule, setActiveModule] = useState<ModuleKey>('intelligence');
  // M7（TS-113）手风琴互斥：左栏折叠面板点开一个自动收起其余
  // checkpoint-045：左栏仅保留任务队列/圆桌；其余低频模块收入整页设置
  type PanelKey = 'tasks' | 'roundtable';
  const [openPanel, setOpenPanel] = useState<PanelKey | null>(null);
  const togglePanel = (p: PanelKey) => setOpenPanel(prev => (prev === p ? null : p));
  // checkpoint-045：整页设置视图（左栏底部齿轮入口）
  const [showSettingsPage, setShowSettingsPage] = useState(false);
  // checkpoint-051：手风琴头悬停态（内联样式写不了伪类）
  const [hoverPanel, setHoverPanel] = useState<string | null>(null);

  const openLogsFolder = async () => {
    const bridge = (window as any).subagent;
    if (bridge && typeof bridge.openLogsFolder === 'function') {
      const res = await bridge.openLogsFolder().catch((e: Error) => ({ ok: false, error: e.message }));
      if (!res || !res.ok) {
        alertDialog({ message: `打开日志文件夹失败：${res && res.error ? res.error : '未知错误'}` });
      }
      return;
    }
    // 纯浏览器环境（无 Electron 桥）：降级显示日志路径
    try {
      const r = await fetch(`${getApiBase()}/logs/info`);
      const d = r.ok ? await r.json() : null;
      alertDialog({ message: d && d.log_dir ? `日志目录：${d.log_dir}` : '无法获取日志目录' });
    } catch (e) {
      alertDialog({ message: '无法获取日志目录（侧车未运行？）' });
    }
  };
  // 问题5修复：打开数据缓存目录（数据库/导出/知识索引/全局知识）——与日志目录分开
  const openDataDir = async () => {
    const bridge = (window as any).subagent;
    if (bridge && typeof bridge.openDataDir === 'function') {
      const res = await bridge.openDataDir().catch((e: Error) => ({ ok: false, error: e.message }));
      if (!res || !res.ok) {
        alertDialog({ message: `打开数据缓存目录失败：${res && res.error ? res.error : '未知错误'}` });
      }
      return;
    }
    // 纯浏览器环境：降级提示数据目录位置
    alertDialog({ message: '数据缓存目录：~/.subagent（可在 Finder 手动打开）' });
  };
  // TS-109 改进：右侧大屏查看的圆桌 id（null = 正常对话视图）
  const [viewingRtId, setViewingRtId] = useState<string | null>(null);
  // M7（TS-113 建议包4）：任务队列跳转——目标子 Agent 与其委派会话
  const [jumpTarget, setJumpTarget] = useState<{ agentId: string; sessionId: string | null } | null>(null);
  // H16 修复：ChatPanel 保活注册表（key = project|agent）。
  // 切换 Agent 只隐藏不销毁——否则主 Agent 的委派流（分钟级）事件写入已销毁组件，
  // 回复未渲染进 localMessages → 切回只见 user 消息 → 用户再发一条 → 历史缺 assistant
  // 回复 → 模型把所有未答问题重答一遍（"回复累积"根因）。
  const [aliveChatKeys, setAliveChatKeys] = useState<string[]>([]);
  const activeChatKey = selectedProjectId && selectedAgentId
    ? `${selectedProjectId}|${selectedAgentId}` : null;

  const selectProject = (pid: string) => {
    setSelectedProjectId(pid);
    setAliveChatKeys([]);  // 换项目 → 旧面板全部卸载
    setViewingRtId(null);  // 换项目 → 退出圆桌视图
  };
  // checkpoint-056：项目删除成功 → 清空项目/Agent 选中态，杜绝幽灵项目上继续操作
  const handleProjectDeleted = (pid: string) => {
    if (pid !== selectedProjectId) return; // 删的不是当前选中项目，不动
    setSelectedProjectId(null);
    setSelectedAgentId(null);
    setAliveChatKeys([]);
    setViewingRtId(null);
    setShowSettingsPage(false);
  };
  const selectAgent = (aid: string | null) => {
    setSelectedAgentId(aid);
    setViewingRtId(null);  // 点选 Agent → 回到对话视图
    if (aid && selectedProjectId) {
      const k = `${selectedProjectId}|${aid}`;
      setAliveChatKeys(prev => prev.includes(k) ? prev : [...prev, k]);
    }
  };
  // checkpoint-058：独立 Agent（与项目平级的一等公民）——不属于任何项目。
  // 选中后以命名空间 ia-<agentId> 作为会话/存储作用域，聊天/委派/导出机制全复用，
  // 但数据物理隔离在 projects/ia-<id>/ 下——删除任何项目都不影响独立 Agent。
  const selectIndependentAgent = (agentId: string) => {
    const ns = `ia-${agentId}`;
    setSelectedProjectId(ns);
    setSelectedAgentId(agentId);
    setViewingRtId(null);
    setAliveChatKeys([`${ns}|${agentId}`]);
  };
  // checkpoint-061：独立 Agent 删除成功 → 若删的是当前选中项，清空选中态与保活面板，
  // 杜绝"幽灵聊天面板"（面板指向已删除的 ia- 命名空间，继续发消息会重建幽灵数据）。
  const handleIndependentAgentDeleted = (agentId: string) => {
    if (agentId !== selectedAgentId) return;
    setSelectedAgentId(null);
    setSelectedProjectId(null);
    setAliveChatKeys([]);
    setViewingRtId(null);
  };
  const jumpToAgent = (agentId: string, sessionId: string | null) => {
    setJumpTarget({ agentId, sessionId });
    selectAgent(agentId);
  };

  // checkpoint-051：手风琴头（规范 §8.3）
  const accordionHeadStyle = (key: PanelKey, open: boolean): React.CSSProperties => ({
    display: 'flex', alignItems: 'center', gap: 8, width: '100%', height: 36,
    padding: '8px 12px', border: 'none', boxSizing: 'border-box',
    background: open || hoverPanel === key ? colors.bgHover : 'transparent',
    borderTop: `1px solid ${colors.borderSubtle}`,
    color: open || hoverPanel === key ? colors.textPrimary : colors.textSecondary,
    fontSize: 13, textAlign: 'left', cursor: 'pointer', fontFamily: fonts.base,
    transition: 'background-color .15s ease, color .15s ease',
  });

  return (
    <div style={{ display: 'flex', height: '100vh', background: colors.bgApp, fontFamily: fonts.base, color: colors.textPrimary }}>
      {/* 0.4.5：全局 portal 悬停提示层（不被任何滚动容器裁切，根治提示看不到） */}
      <TipPortal />
      {/* 0.2.1（TS-119）：一级模块导航栏（最左竖条）。
          问题6修复：设置入口上移到此导航底部——职能/流程两个中心都能打开设置 */}
      <ModuleNav
        active={activeModule}
        onSelect={(k) => { setShowSettingsPage(false); setActiveModule(k); }}
        onOpenSettings={() => { setActiveModule('intelligence'); setShowSettingsPage(v => !v); }}
        settingsActive={showSettingsPage}
      />

      {/* 智能中心：现有页面整体原样包入（独立 Agent / 项目组 / 聊天），
          切换模块仅隐藏不卸载——运行中的委派流与工作流不受影响。
          问题6：设置页打开时同样隐藏（组件保活，仅显示切换） */}
      <div style={{ display: activeModule === 'intelligence' && !showSettingsPage ? 'flex' : 'none', flex: 1, minWidth: 0, minHeight: 0 }}>
      {/* Left sidebar（flexShrink:0 防止被右侧超宽内容挤压出屏幕）
          checkpoint-046：打开整页设置时隐藏左栏（全屏展示，视觉体验优先）
          checkpoint-051：亮色主题（规范 §8.0） */}
      <div style={{ width: 380, flexShrink: 0, background: colors.bgSidebar, borderRight: `1px solid ${colors.borderDefault}`, display: showSettingsPage ? 'none' : 'flex', flexDirection: 'column', minHeight: 0, overflow: 'hidden' }}>
        {/* checkpoint-058：独立 Agent（与项目平级的一等公民）——左栏最上方，
            不依赖任何项目；可单独创建/删除，删项目不影响 */}
        <IndependentAgentsPanel selectedAgentId={selectedAgentId} onSelect={selectIndependentAgent} onAgentDeleted={handleIndependentAgentDeleted} />
        <ProjectPanel onSelect={selectProject} onProjectDeleted={handleProjectDeleted} selectedProjectId={selectedProjectId} />
        {/* 独立 Agent 命名空间（ia- 前缀）不显示"项目内 Agent"面板 */}
        {selectedProjectId && !selectedProjectId.startsWith('ia-') && (
          <AgentPanel
            key={`agent-panel-${selectedProjectId}`}
            projectId={selectedProjectId}
            selectedAgentId={selectedAgentId}
            onSelectAgent={selectAgent}
          />
        )}

        {/* Task queue toggle (TS-108 M3-2 决策 4：任务队列可视化) */}
        {selectedProjectId && (
          <div>
            <button
              onClick={() => togglePanel('tasks')}
              onMouseEnter={() => setHoverPanel('tasks')}
              onMouseLeave={() => setHoverPanel(null)}
              style={accordionHeadStyle('tasks', openPanel === 'tasks')}
            >
              <Icon name="clipboard" size={16} />
              <span style={{ flex: 1 }}>任务队列</span>
              <Icon name={openPanel === 'tasks' ? 'chevron-up' : 'chevron-down'} size={14} style={{ color: colors.textTertiary }} />
            </button>
            {openPanel === 'tasks' && (
              <div style={{ maxHeight: '45vh', overflowY: 'auto' }}>
                <TaskPanel projectId={selectedProjectId} onJumpToAgent={jumpToAgent} />
              </div>
            )}
          </div>
        )}

        {/* Roundtable toggle (TS-109 M3-3：圆桌讨论入口) */}
        {selectedProjectId && (
          <div>
            <button
              onClick={() => togglePanel('roundtable')}
              onMouseEnter={() => setHoverPanel('roundtable')}
              onMouseLeave={() => setHoverPanel(null)}
              style={accordionHeadStyle('roundtable', openPanel === 'roundtable')}
            >
              <Icon name="mic" size={16} />
              <span style={{ flex: 1 }}>圆桌</span>
              <Icon name={openPanel === 'roundtable' ? 'chevron-up' : 'chevron-down'} size={14} style={{ color: colors.textTertiary }} />
            </button>
            {openPanel === 'roundtable' && (
              <div style={{ maxHeight: '45vh', overflowY: 'auto' }}>
                <RoundtablePanel
                  projectId={selectedProjectId}
                  selectedId={viewingRtId}
                  onSelect={(rtId) => setViewingRtId(rtId)}
                />
              </div>
            )}
          </div>
        )}

        {/* 问题1修复（0.3.2实测）：原左栏底部"设置"齿轮与一级导航的设置重复，已删除。
            设置入口统一为最左导航栏底部的设置按钮，职能/流程两个中心共用。 */}
      </div>

      {/* Right: chat / 圆桌大屏（minWidth:0 切断子内容 min-content 向上传导，防超宽内容顶开整页；
          M7 TS-113 滚动锁定：minHeight:0 切断高度传导，仅消息区滚动，顶栏/输入区固定） */}
      <div style={{ flex: 1, minWidth: 0, minHeight: 0, display: showSettingsPage ? 'none' : 'flex', flexDirection: 'column', position: 'relative', overflow: 'hidden', background: colors.bgApp }}>
        {/* TS-109 改进：圆桌详情右侧大屏（与对话视图互斥显示；对话组件保活不销毁） */}
        {selectedProjectId && viewingRtId && (
          <div style={{ flex: 1, minHeight: 0, display: 'flex', flexDirection: 'column' }}>
            <RoundtableView
              projectId={selectedProjectId}
              roundtableId={viewingRtId}
              onExit={() => setViewingRtId(null)}
            />
          </div>
        )}
        {(!selectedProjectId || !viewingRtId) && !activeChatKey && (
          <div style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: 10, color: colors.textTertiary }}>
            <h2 style={{ fontSize: 16, fontWeight: 600, margin: 0 }}>开始对话</h2>
            <div style={{ fontSize: 13, color: colors.textTertiary, textAlign: 'center', lineHeight: 1.6 }}>
              在左侧选择一个项目和 Agent，或点击顶部「独立 Agent」创建一个不属于任何项目的 Agent。
            </div>
          </div>
        )}
        {/* H16：保活渲染所有已激活的 ChatPanel，切换仅隐藏（display:none）。
            避免组件销毁导致后台委派流的回复无处落点、切回后消息历史丢失、模型重答累积。
            查看圆桌时也隐藏（保持挂载，流式继续写入）。 */}
        {aliveChatKeys.map(k => {
          const [pid, aid] = k.split('|');
          const active = k === activeChatKey && !viewingRtId;
          const isJumpTarget = jumpTarget?.agentId === aid;
          return (
            <div key={k} style={{ flex: 1, minHeight: 0, display: active ? 'flex' : 'none', flexDirection: 'column', minWidth: 0 }}>
              <ChatPanel projectId={pid} agentId={aid}
                jumpToSessionId={isJumpTarget ? jumpTarget?.sessionId : null}
                onJumpConsumed={isJumpTarget ? () => setJumpTarget(null) : undefined} />
            </div>
          );
        })}
      </div>
      </div>

      {/* 0.2.1（TS-119）：流程中心（工作流模块）。同样保持挂载，仅切换显示，
          运行中的工作流在切回智能中心时继续执行。问题6：设置页打开时也隐藏 */}
      <div style={{ display: activeModule === 'workflow' && !showSettingsPage ? 'flex' : 'none', flex: 1, minWidth: 0, minHeight: 0 }}>
        <WorkflowPanel />
      </div>

      {/* checkpoint-045（问题6修复）：整页设置视图提到顶层——与模块容器平级，
          职能中心/流程中心都能打开（此前藏在职能中心左栏内，流程中心看不到）。
          对话/圆桌/工作流组件均保活不销毁，仅显示切换。 */}
      {showSettingsPage && (
        <div style={{ flex: 1, minWidth: 0, minHeight: 0, display: 'flex', flexDirection: 'column' }}>
          <SettingsPage
            projectId={selectedProjectId}
            onExit={() => setShowSettingsPage(false)}
            onOpenLogs={openLogsFolder}
            onOpenDataDir={openDataDir}
          />
        </div>
      )}
    </div>
  );
}
