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
// A12（0.4.25）UI 深度重构：设计 Token（唯一数值源）——「纸面工具」方向
// 2026-09-13 用户拍板方向 A：
//   · 暖白纸面底 + 白卡片，近黑正文，主按钮石墨黑；
//   · 强调色只留一枚克制的雾蓝（选中 / 链接 / 焦点），语义色降饱和；
//   · 大留白、8px 间距网格、极浅阴影、圆角收敛（控件 6~8，卡片 10~12）。
// 亮色主题，无深色分支（用户只要灰白亮色）。
// ⛔ 键名 surface 保持向后兼容（19 面板 + App + Dialog 直接 import），
//   本批只换数值与新增键，不删键。
import type { CSSProperties } from 'react';

export const colors = {
  // 中性背景（暖调纸面）
  bgApp: '#FAFAF8',
  bgSidebar: '#F1F0EC',
  bgCard: '#FFFFFF',
  bgHover: '#EEEDE9',
  bgActive: '#E5E3DE',
  bgSelected: '#E9F0FC',
  bgCode: '#F5F4F1',
  bgInlineCode: '#F0EFEB',
  bgToast: '#1C1C1A',

  // 边框（暖灰，逐级加深）
  borderSubtle: '#ECEAE5',
  borderDefault: '#E2E0DA',
  borderStrong: '#D1CEC6',

  // 文字（暖黑）
  textPrimary: '#1C1C1A',
  textSecondary: '#5C594F',
  textTertiary: '#8E8A80',
  textDisabled: '#BDBAB0',

  // 主按钮：石墨黑（ink）
  ink: '#1C1C1A',
  inkHover: '#37352F',
  inkActive: '#000000',
  onInk: '#FAFAF8',

  // 强调色：雾蓝（选中 / 链接 / 焦点环 / 进行态）
  accent: '#3B82F6',
  accentHover: '#2563EB',
  accentActive: '#1D4ED8',
  onAccent: '#FFFFFF',
  accentText: '#2563EB',
  accentBg: '#E9F0FC',
  accentBorder: '#C2D7F8',
  accentBgSoft: '#F4F8FE',
  accentTextDeep: '#1E40AF',

  // 语义色（降饱和：成功 / 警告 / 危险）
  ok: '#3D9B63', okBg: '#EBF6EF', okBorder: '#C8E6D4', okText: '#1F6B3E',
  // 灵动批：用户反馈左栏黄色太深突兀——warn 族整体再降一档（更浅的米黄底、更柔的琥珀字）
  warn: '#C99A3F', warnBg: '#FBF6E9', warnBorder: '#EEE2BE', warnText: '#8A6D24',
  danger: '#DC4C42', dangerBg: '#FBEDEC', dangerBorder: '#F2C7C2', dangerText: '#963026',
  dangerHover: '#C93F36', dangerActive: '#B2342C', dangerLink: '#C0352C',

  // 禁用
  disabledBg: '#E2E0DA',
  disabledText: '#FAFAF8',
  disabledFieldBg: '#F3F2EE',
};

export const fonts = {
  base: '-apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", "Helvetica Neue", "Microsoft YaHei", sans-serif',
  mono: '"SF Mono", ui-monospace, Menlo, Consolas, monospace',
};

export const radius = { s: 6, m: 10, l: 12, pill: 999 };

// 极浅暖调阴影
export const shadow = {
  s: '0 1px 2px rgba(28,28,26,0.04)',
  m: '0 2px 10px rgba(28,28,26,0.06)',
  l: '0 10px 30px rgba(28,28,26,0.12)',
};

// 字号/字重/行高层级
export const typo = {
  pageTitle: { fontSize: 16, fontWeight: 600, lineHeight: 1.4 },
  sectionTitle: { fontSize: 14, fontWeight: 600, lineHeight: 1.4 },
  panelTitle: { fontSize: 12, fontWeight: 600, lineHeight: 1.4, color: colors.textTertiary },
  body: { fontSize: 13, fontWeight: 400, lineHeight: 1.6 },
  msgBody: { fontSize: 14, fontWeight: 400, lineHeight: 1.7 },
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

// 按钮样式（默认态）。悬停/按下用伪类（见 global.css 的 .ui-btn 类）或内联覆盖。
export const btnPrimary = {
  display: 'inline-flex', alignItems: 'center', justifyContent: 'center', gap: 6,
  height: 28, padding: '0 14px', border: 'none', borderRadius: radius.s,
  background: colors.ink, color: colors.onInk,
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

// A12 新增：28×28 方形图标按钮（顶栏/行内操作）
export const iconBtn = {
  display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
  width: 28, height: 28, padding: 0, border: 'none', borderRadius: radius.s,
  background: 'transparent', color: colors.textSecondary,
  cursor: 'pointer', fontFamily: fonts.base, flexShrink: 0,
} as const;

// A12 新增：浮层菜单/Popover 卡片
export const menuCard = {
  background: colors.bgCard,
  border: `1px solid ${colors.borderDefault}`,
  borderRadius: radius.m,
  boxShadow: shadow.l,
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
