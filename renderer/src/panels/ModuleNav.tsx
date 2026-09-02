/**
 * 0.2.1（TS-119）：一级模块导航栏（最左竖条）。
 *
 * 智能中心（默认）= 现有独立 Agent / 项目组 / 聊天页面（整体包为其二级视图，
 * 页面本身零改动）；流程中心 = 工作流模块。
 * 切换模块采用显示/隐藏（不卸载），聊天流与运行中的工作流在切换后不中断。
 */
import React, { useState } from 'react';
import { colors, fonts } from '../theme';
import { Icon, IconName } from '../Icon';

export type ModuleKey = 'intelligence' | 'workflow';

interface Props {
  active: ModuleKey;
  onSelect: (key: ModuleKey) => void;
}

const MODULES: { key: ModuleKey; label: string; icon: IconName }[] = [
  { key: 'intelligence', label: '智能中心', icon: 'bot' },
  { key: 'workflow', label: '流程中心', icon: 'layers' },
];

export function ModuleNav({ active, onSelect }: Props) {
  const [hover, setHover] = useState<ModuleKey | null>(null);
  return (
    <div style={{
      width: 64, flexShrink: 0, background: colors.bgSidebar,
      borderRight: `1px solid ${colors.borderDefault}`,
      display: 'flex', flexDirection: 'column', alignItems: 'center',
      paddingTop: 10, gap: 6,
    }}>
      {MODULES.map(m => {
        const isActive = active === m.key;
        const isHover = hover === m.key;
        return (
          <button key={m.key}
            onClick={() => onSelect(m.key)}
            onMouseEnter={() => setHover(m.key)}
            onMouseLeave={() => setHover(null)}
            style={{
              width: 52, height: 52, border: 'none', borderRadius: 8, cursor: 'pointer',
              display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: 3,
              background: isActive ? colors.bgSelected : isHover ? colors.bgHover : 'transparent',
              color: isActive ? colors.accentText : colors.textSecondary,
              fontFamily: fonts.base, transition: 'background-color .15s ease',
            }}>
            <Icon name={m.icon} size={20} />
            <span style={{ fontSize: 10, fontWeight: isActive ? 600 : 400 }}>{m.label}</span>
          </button>
        );
      })}
    </div>
  );
}
