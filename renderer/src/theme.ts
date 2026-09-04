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
// checkpoint-051 UI 重设计：设计 Token（唯一数值源）
// 依据 /交接/21-UI设计规范.md §2~§5。亮色主题，无深色分支。
// 只定义"看起来是什么样"，不改交互/文案。

import type { CSSProperties } from 'react';

export const colors = {
  // 中性背景
  bgApp: '#F7F7F8',
  bgSidebar: '#F1F1F3',
  bgCard: '#FFFFFF',
  bgHover: '#ECECEE',
  bgActive: '#E4E4E8',
  bgSelected: '#E3F4FE',
  bgCode: '#F3F3F5',
  bgInlineCode: '#EFF0F3',
  bgToast: '#1F1F24',

  // 边框
  borderSubtle: '#ECECEF',
  borderDefault: '#E3E3E8',
  borderStrong: '#D5D5DA',

  // 文字
  textPrimary: '#1A1A1E',
  textSecondary: '#5C5C66',
  textTertiary: '#8E8E99',
  textDisabled: '#B8B8C0',

  // 主色（蓝）
  accent: '#38BDF8',
  accentHover: '#0EA5E9',
  accentActive: '#0284C7',
  onAccent: '#063452',
  accentText: '#0369A1',
  accentBg: '#E3F4FE',
  accentBorder: '#BAE6FD',
  accentBgSoft: '#F0F9FF',
  accentTextDeep: '#075985',

  // 语义色（成功/警告/危险）
  ok: '#34C759', okBg: '#EDF9F1', okBorder: '#CDEBD8', okText: '#1F6B3A',
  warn: '#FF9500', warnBg: '#FFF7EC', warnBorder: '#F5DFB8', warnText: '#8A5A00',
  danger: '#FF3B30', dangerBg: '#FEF0EF', dangerBorder: '#FBC6C2', dangerText: '#8A1F16',
  dangerHover: '#E5342A', dangerActive: '#CC2E24', dangerLink: '#D70015',

  // 禁用
  disabledBg: '#D9D9DE',
  disabledText: '#FAFAFB',
  disabledFieldBg: '#F2F2F4',
};

export const fonts = {
  base: '-apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", "Helvetica Neue", "Microsoft YaHei", sans-serif',
  mono: '"SF Mono", ui-monospace, Menlo, Consolas, monospace',
};

export const radius = { s: 6, m: 10, l: 14, pill: 999 };

export const shadow = {
  s: '0 1px 2px rgba(0,0,0,0.05)',
  m: '0 4px 12px rgba(0,0,0,0.08)',
  l: '0 12px 32px rgba(0,0,0,0.14)',
};

// 字号/字重/行高层级
export const typo = {
  pageTitle: { fontSize: 16, fontWeight: 600, lineHeight: 1.4 },
  sectionTitle: { fontSize: 14, fontWeight: 600, lineHeight: 1.4 },
  panelTitle: { fontSize: 12, fontWeight: 600, lineHeight: 1.4, color: colors.textTertiary },
  body: { fontSize: 13, fontWeight: 400, lineHeight: 1.6 },
  msgBody: { fontSize: 14, fontWeight: 400, lineHeight: 1.65 },
  caption: { fontSize: 12, fontWeight: 400, lineHeight: 1.5 },
  micro: { fontSize: 11, fontWeight: 400, lineHeight: 1.4, color: colors.textTertiary },
};

// 常用复合样式
export const card = {
  background: colors.bgCard,
  border: `1px solid ${colors.borderDefault}`,
  borderRadius: radius.m,
};
export const cardL = {
  background: colors.bgCard,
  border: `1px solid ${colors.borderDefault}`,
  borderRadius: radius.l,
};

// 按钮样式（默认态）。悬停/按下用伪类（见 global.css 的 .btn 类）或内联覆盖。
export const btnPrimary = {
  display: 'inline-flex', alignItems: 'center', justifyContent: 'center', gap: 6,
  height: 28, padding: '0 14px', border: 'none', borderRadius: radius.s,
  background: colors.accent, color: colors.onAccent,
  fontSize: 13, fontWeight: 500, cursor: 'pointer', fontFamily: fonts.base,
} as const;

export const btnSecondary = {
  display: 'inline-flex', alignItems: 'center', justifyContent: 'center', gap: 6,
  height: 28, padding: '0 14px', borderRadius: radius.s,
  background: colors.bgCard, border: `1px solid ${colors.borderStrong}`, color: colors.textPrimary,
  fontSize: 13, fontWeight: 400, cursor: 'pointer', fontFamily: fonts.base,
} as const;

export const btnGhost = {
  display: 'inline-flex', alignItems: 'center', justifyContent: 'center', gap: 6,
  height: 28, padding: '0 10px', border: 'none', borderRadius: radius.s,
  background: 'transparent', color: colors.textSecondary,
  fontSize: 13, cursor: 'pointer', fontFamily: fonts.base,
} as const;

export const btnDanger = {
  ...btnPrimary,
  background: colors.danger, color: '#FFFFFF',
} as const;

export const btnDangerSoft = {
  ...btnSecondary,
  border: `1px solid ${colors.dangerBorder}`, color: colors.dangerText,
} as const;

// 输入框
export const input = {
  height: 30, padding: '0 10px', background: colors.bgCard,
  border: `1px solid ${colors.borderStrong}`, borderRadius: radius.s,
  fontSize: 13, color: colors.textPrimary, fontFamily: fonts.base,
  boxSizing: 'border-box' as const,
};
export const textarea = {
  padding: '8px 10px', background: colors.bgCard,
  border: `1px solid ${colors.borderStrong}`, borderRadius: radius.s,
  fontSize: 13, color: colors.textPrimary, fontFamily: fonts.base, lineHeight: 1.6,
  boxSizing: 'border-box' as const, resize: 'vertical' as const,
};
export const select = {
  padding: '4px 8px', background: colors.bgCard,
  border: `1px solid ${colors.borderStrong}`, borderRadius: radius.s,
  fontSize: 13, color: colors.textPrimary, fontFamily: fonts.base,
};

// 状态徽标（胶囊）
export const badge = (bg: string, fg: string): CSSProperties => ({
  display: 'inline-flex', alignItems: 'center', gap: 5,
  height: 20, padding: '0 8px', borderRadius: radius.pill,
  fontSize: 11, fontWeight: 500, background: bg, color: fg, flexShrink: 0,
});

// 提示条（四类色块）
export type CalloutKind = 'info' | 'success' | 'warn' | 'error';
export const calloutStyle = (kind: CalloutKind): CSSProperties => {
  const map = {
    info: { bg: colors.accentBgSoft, border: colors.accentBorder, fg: colors.accentTextDeep },
    success: { bg: colors.okBg, border: colors.okBorder, fg: colors.okText },
    warn: { bg: colors.warnBg, border: colors.warnBorder, fg: colors.warnText },
    error: { bg: colors.dangerBg, border: colors.dangerBorder, fg: colors.dangerText },
  }[kind];
  return {
    display: 'flex', alignItems: 'flex-start', gap: 8,
    padding: '8px 12px', borderRadius: radius.s,
    background: map.bg, border: `1px solid ${map.border}`,
    color: map.fg, fontSize: 13, lineHeight: 1.6,
  };
};
