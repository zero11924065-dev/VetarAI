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
 * 0.2.1（TS-119）：一级模块导航栏（最左竖条）。
 *
 * 智能中心（默认）= 现有独立 Agent / 项目组 / 聊天页面（整体包为其二级视图，
 * 页面本身零改动）；流程中心 = 工作流模块。
 * 切换模块采用显示/隐藏（不卸载），聊天流与运行中的工作流在切换后不中断。
 *
 * A12（0.4.25）「纸面工具」：52px 细条导航——图标 + 微标签，
 * 选中态 = 雾蓝浅底 + 左侧 3px 指示条；设置固定底部（两模块共用入口）。
 */
import React, { useState } from 'react';
import { colors, fonts } from '../theme';
import { Icon, IconName } from '../Icon';

export type ModuleKey = 'intelligence' | 'workflow';

interface Props {
  active: ModuleKey;
  onSelect: (key: ModuleKey) => void;
  /** 问题6修复：设置入口上移到一级导航，流程中心也能打开设置 */
  onOpenSettings?: () => void;
  settingsActive?: boolean;
}

const MODULES: { key: ModuleKey; label: string; icon: IconName }[] = [
  { key: 'intelligence', label: '智能中心', icon: 'bot' },
  { key: 'workflow', label: '流程中心', icon: 'layers' },
];

function NavButton({ label, icon, isActive, isHover, onClick, onEnter, onLeave, extraStyle }: {
  label: string; icon: IconName; isActive: boolean; isHover: boolean;
  onClick: () => void; onEnter: () => void; onLeave: () => void;
  extraStyle?: React.CSSProperties;
}) {
  return (
    <button
      onClick={onClick}
      onMouseEnter={onEnter}
      onMouseLeave={onLeave}
      data-tip={label}
      className="tip-right"
      style={{
        position: 'relative',
        width: 42, height: 46, border: 'none', borderRadius: 10, cursor: 'pointer',
        display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: 3,
        background: isActive ? colors.bgSelected : isHover ? colors.bgHover : 'transparent',
        color: isActive ? colors.accentText : colors.textSecondary,
        fontFamily: fonts.base, transition: 'background-color .15s ease',
        ...extraStyle,
      }}>
      {isActive && (
        <span style={{
          position: 'absolute', left: -5, top: 12, bottom: 12, width: 3,
          borderRadius: 2, background: colors.accent,
        }} />
      )}
      <Icon name={icon} size={18} />
      <span style={{ fontSize: 10, fontWeight: isActive ? 600 : 400, letterSpacing: 0.2 }}>{label}</span>
    </button>
  );
}

export function ModuleNav({ active, onSelect, onOpenSettings, settingsActive }: Props) {
  const [hover, setHover] = useState<ModuleKey | 'settings' | null>(null);
  return (
    <div style={{
      width: 52, flexShrink: 0, background: colors.bgCard,
      borderRight: `1px solid ${colors.borderDefault}`,
      display: 'flex', flexDirection: 'column', alignItems: 'center',
      paddingTop: 8, gap: 4,
    }}>
      {MODULES.map(m => (
        <NavButton
          key={m.key}
          label={m.label}
          icon={m.icon}
          isActive={!settingsActive && active === m.key}
          isHover={hover === m.key}
          onClick={() => onSelect(m.key)}
          onEnter={() => setHover(m.key)}
          onLeave={() => setHover(null)}
        />
      ))}
      {/* 问题6：设置固定在导航底部——职能中心/流程中心都能进入设置 */}
      {onOpenSettings && (
        <NavButton
          label="设置"
          icon="settings"
          isActive={!!settingsActive}
          isHover={hover === 'settings'}
          onClick={onOpenSettings}
          onEnter={() => setHover('settings')}
          onLeave={() => setHover(null)}
          extraStyle={{ marginTop: 'auto', marginBottom: 8 }}
        />
      )}
    </div>
  );
}
