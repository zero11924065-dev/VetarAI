import React, { useState } from 'react';
import { SettingsPanel } from './SettingsPanel';
import { PluginPanel } from './PluginPanel';
import { KnowledgePanel } from './KnowledgePanel';
import { InferencePanel } from './InferencePanel';
import { colors, fonts, radius } from '../theme';
import { Icon, type IconName } from '../Icon';

/**
 * checkpoint-045（用户 2026-08-30 需求）：整页设置视图。
 * 左栏只留常用模块，低频模块（基础设置/知识记忆/推理后端/插件管理）
 * 统一收进左下角"设置"入口打开的整页视图：左侧分类导航 + 右侧内容区。
 * "打开日志文件夹"合并在"基础设置"顶部。
 * checkpoint-053：关于VetarAI 移至原生菜单栏（macOS 应用菜单 → 关于），不再占设置页。
 */
type SectionKey = 'general' | 'knowledge' | 'inference' | 'plugins';

const SECTIONS: { key: SectionKey; icon: IconName; label: string; needProject?: boolean }[] = [
  { key: 'general', icon: 'sliders', label: '基础设置' },
  { key: 'knowledge', icon: 'book', label: '知识记忆', needProject: true },
  { key: 'inference', icon: 'cpu', label: '推理后端' },
  { key: 'plugins', icon: 'plug', label: '插件管理' },
];

export function SettingsPage({ projectId, onExit, onOpenLogs, onOpenDataDir }: {
  projectId: string | null;
  onExit: () => void;
  onOpenLogs: () => void;
  /** 问题5：打开数据缓存目录（与日志目录分开） */
  onOpenDataDir?: () => void;
}) {
  const [section, setSection] = useState<SectionKey>('general');
  const [hoveredNav, setHoveredNav] = useState<SectionKey | null>(null);

  return (
    <div style={{ display: 'flex', height: '100%', minHeight: 0, background: colors.bgApp }}>
      {/* 左侧分类导航（§8.14） */}
      <div style={{
        width: 220, flexShrink: 0,
        background: colors.bgSidebar,
        borderRight: `1px solid ${colors.borderDefault}`,
        display: 'flex', flexDirection: 'column',
        padding: '12px 10px', gap: 4, overflowY: 'auto',
      }}>
        {/* ← 返回应用 */}
        <button
          className="ui-btn ui-btn-ghost"
          onClick={onExit}
          style={{
            display: 'flex', alignItems: 'center', gap: 6,
            background: 'transparent', border: 'none', cursor: 'pointer',
            color: colors.textSecondary, fontSize: 13, fontFamily: fonts.base,
            padding: '6px 8px', marginBottom: 8, textAlign: 'left',
          }}
        >
          <Icon name="arrow-left" size={14} />
          返回应用
        </button>

        {/* 导航项 */}
        {SECTIONS.map(s => {
          const active = section === s.key;
          const hovered = hoveredNav === s.key;
          const bg = active ? colors.bgSelected : hovered ? colors.bgHover : 'transparent';
          const fg = active ? colors.accentText : colors.textSecondary;
          const fw = active ? 500 : 400;
          return (
            <button
              key={s.key}
              onClick={() => setSection(s.key)}
              onMouseEnter={() => setHoveredNav(s.key)}
              onMouseLeave={() => setHoveredNav(null)}
              style={{
                display: 'flex', alignItems: 'center', gap: 8,
                width: '100%', height: 32, padding: '0 12px',
                border: 'none', borderRadius: radius.s, cursor: 'pointer',
                background: bg, color: fg, fontSize: 13, fontWeight: fw,
                fontFamily: fonts.base, textAlign: 'left',
                transition: 'background-color .15s ease, color .15s ease',
              }}
            >
              <Icon name={s.icon} size={16} />
              {s.label}
            </button>
          );
        })}
      </div>

      {/* 右侧内容区（§8.14） */}
      <div style={{
        flex: 1, minWidth: 0, minHeight: 0, overflowY: 'auto',
        background: colors.bgApp, padding: '18px 24px',
      }}>
        {section === 'general' && (
          <SettingsPanel embedded onOpenLogs={onOpenLogs} onOpenDataDir={onOpenDataDir} />
        )}
        {section === 'knowledge' && (
          <KnowledgePanel projectId={projectId} />
        )}
        {section === 'inference' && <InferencePanel />}
        {section === 'plugins' && <PluginPanel />}
      </div>
    </div>
  );
}
