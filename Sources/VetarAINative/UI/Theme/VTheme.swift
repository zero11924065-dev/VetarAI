//
//  VTheme.swift
//  VetarAI — Local-first multi-agent orchestration application
//  Copyright (C) 2026 zero11924065-dev
//
//  This file is part of VetarAI.
//
//  VetarAI is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  VetarAI is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with VetarAI. If not, see <https://www.gnu.org/licenses/>.
//

//  设计 Token（唯一数值源）：风格对齐现状应用「纸面工具」方向
//  （subagent/renderer/src/theme.ts，A12 0.4.25）：
//    · 暖白纸面底 + 白卡片，近黑正文，主按钮石墨黑
//    · 强调色只留一枚克制的雾蓝（选中/链接/焦点），语义色降饱和
//    · 8px 间距网格、极浅阴影、圆角收敛（控件 6~8，卡片 10~12）
//  深/浅色跟随系统：浅色取现状原值；深色取同族降亮度映射，不追求像素级复刻。
//

import SwiftUI

public enum VTheme {

    // MARK: - 中性背景
    public static let bgApp = adaptive(light: 0xFAFAF8, dark: 0x1E1E1C)
    public static let bgSidebar = adaptive(light: 0xF1F0EC, dark: 0x262624)
    public static let bgCard = adaptive(light: 0xFFFFFF, dark: 0x2C2C2A)
    public static let bgHover = adaptive(light: 0xEEEDE9, dark: 0x3A3A37)
    public static let bgActive = adaptive(light: 0xE5E3DE, dark: 0x444442)
    public static let bgSelected = adaptive(light: 0xE9F0FC, dark: 0x2A3A55)

    // MARK: - 边框（逐级加深）
    public static let borderSubtle = adaptive(light: 0xECEAE5, dark: 0x3A3A37)
    public static let borderDefault = adaptive(light: 0xE2E0DA, dark: 0x444442)
    public static let borderStrong = adaptive(light: 0xD1CEC6, dark: 0x555552)

    // MARK: - 文字（暖黑 ↔ 暖白）
    public static let textPrimary = adaptive(light: 0x1C1C1A, dark: 0xF2F1ED)
    public static let textSecondary = adaptive(light: 0x5C594F, dark: 0xB8B5AB)
    public static let textTertiary = adaptive(light: 0x8E8A80, dark: 0x8E8A80)
    public static let textDisabled = adaptive(light: 0xBDBAB0, dark: 0x5C594F)

    // MARK: - 主按钮：石墨黑（ink ↔ 纸白）
    public static let ink = adaptive(light: 0x1C1C1A, dark: 0xFAFAF8)
    public static let inkHover = adaptive(light: 0x37352F, dark: 0xFFFFFF)
    public static let onInk = adaptive(light: 0xFAFAF8, dark: 0x1C1C1A)

    // MARK: - 强调色：雾蓝
    public static let accent = Color(hex: 0x3B82F6)
    public static let accentHover = Color(hex: 0x2563EB)
    public static let accentText = adaptive(light: 0x2563EB, dark: 0x7AA5F8)
    public static let accentBg = adaptive(light: 0xE9F0FC, dark: 0x2A3A55)
    public static let accentBorder = adaptive(light: 0xC2D7F8, dark: 0x3B5380)
    public static let accentBgSoft = adaptive(light: 0xF4F8FE, dark: 0x242E42)
    public static let accentTextDeep = adaptive(light: 0x1E40AF, dark: 0x93B4FA)

    // MARK: - 语义色（降饱和）
    public static let ok = Color(hex: 0x3D9B63)
    public static let okBg = adaptive(light: 0xEBF6EF, dark: 0x24382C)
    public static let okBorder = adaptive(light: 0xC8E6D4, dark: 0x35563F)
    public static let okText = adaptive(light: 0x1F6B3E, dark: 0x7CCB9B)

    public static let warn = Color(hex: 0xC99A3F)
    public static let warnBg = adaptive(light: 0xFBF6E9, dark: 0x3A3222)
    public static let warnBorder = adaptive(light: 0xEEE2BE, dark: 0x54492C)
    public static let warnText = adaptive(light: 0x8A6D24, dark: 0xD9B868)

    public static let danger = Color(hex: 0xDC4C42)
    public static let dangerBg = adaptive(light: 0xFBEDEC, dark: 0x3E2825)
    public static let dangerBorder = adaptive(light: 0xF2C7C2, dark: 0x5E3833)
    public static let dangerText = adaptive(light: 0x963026, dark: 0xEB9188)

    // MARK: - 工作室便签 token（studio/spec §2/§6：think/summary/error/task 复用上族；
    // noteUser 全新 #8B5CF6，深色按同族降亮度映射）
    public static let noteUser = adaptive(light: 0x8B5CF6, dark: 0xA78BFA)
    public static let noteUserBg = adaptive(light: 0xF5F1FE, dark: 0x32294A)

    // MARK: - 工作室便签浅底族（studio/spec §2 逐值；深色同族降亮度 ⚠️VERIFY 补齐）
    /// think 浅底（复用 accent 族语义，纸体微渐变落点）
    public static let noteThinkBg = adaptive(light: 0xEFF5FE, dark: 0x232E42)
    /// summary 浅底（ok 族）
    public static let noteSummaryBg = adaptive(light: 0xEFF8F2, dark: 0x223529)
    /// error 浅底（danger 族）
    public static let noteErrorBg = adaptive(light: 0xFDF1F0, dark: 0x3D2624)
    /// task 浅底（warn 族）
    public static let noteTaskBg = adaptive(light: 0xFCF7EA, dark: 0x38301F)
    /// 画布点阵（间距 26 点半径 1.2）
    public static let canvasDot = adaptive(light: 0xD8D5CC, dark: 0x4A4844)

    // MARK: - 阶段三预留：讨论便签 token（拍板项③ 占位；W5 启用，本批不接 UI/筛选胶囊）
    /// noteDiscuss 青色系 #0D9488 族——与五类便签拉开色相（discuss 节点现与
    /// 用户便签撞 noteUser 紫，阶段三第六类「讨论便签」上墙时使用）
    public static let noteDiscuss = adaptive(light: 0x0D9488, dark: 0x2DD4BF)
    /// noteDiscuss 浅底（深色同族降亮度 ⚠️VERIFY 待业主真机过目）
    public static let noteDiscussBg = adaptive(light: 0xE8F7F4, dark: 0x17332D)

    // MARK: - 0.7.7 W5 批：业主发言便签 token（拍板 2026-09-28「标签用新的颜色来区分」）
    /// 玫红族——既有色板未用色相（蓝 accent/绿 ok/琥珀 warn/红 danger/紫 noteUser/
    /// 青 noteDiscuss 之外），与 AI 讨论便签（青）、用户便签（紫）一眼可辨。
    /// hex 提成公开常量供钉桩；浅色 600 档、深色 400 档（沿用 noteUser/noteDiscuss
    /// 「深色同族降亮度」推算口径 ⚠️VERIFY 待业主真机过目）。
    public static let noteUserSpeakHexLight: UInt32 = 0xDB2777
    public static let noteUserSpeakHexDark: UInt32 = 0xF472B6
    public static let noteUserSpeakBgHexLight: UInt32 = 0xFDF2F8
    public static let noteUserSpeakBgHexDark: UInt32 = 0x361C2B
    public static let noteUserSpeak = adaptive(light: noteUserSpeakHexLight,
                                               dark: noteUserSpeakHexDark)
    public static let noteUserSpeakBg = adaptive(light: noteUserSpeakBgHexLight,
                                                 dark: noteUserSpeakBgHexDark)

    // MARK: - 圆角 / 阴影 / 字号（对齐 radius/typo token）
    public enum Radius {
        public static let s: CGFloat = 6
        /// brand-spec §6 新增：输入框/按钮/提示条统一 8（现行实现大量手写 8，token 化补齐）
        public static let m2: CGFloat = 8
        public static let m: CGFloat = 10
        public static let l: CGFloat = 12
    }

    public enum Typo {
        /// brand-spec §6 新增：登录页/空态主标题（28/Semibold）
        public static let display28 = Font.system(size: 28, weight: .semibold)
        /// brand-spec §6 新增：页面大标题（20/Semibold）
        public static let title2 = Font.system(size: 20, weight: .semibold)
        public static let pageTitle = Font.system(size: 16, weight: .semibold)
        public static let sectionTitle = Font.system(size: 14, weight: .semibold)
        public static let panelTitle = Font.system(size: 12, weight: .semibold)
        public static let body = Font.system(size: 13)
        public static let msgBody = Font.system(size: 14)
        public static let caption = Font.system(size: 12)
        public static let micro = Font.system(size: 11)
        /// brand-spec §6 新增：模块竖条标签（10/Regular，系统级微标下限）
        public static let railLabel = Font.system(size: 10)
    }

    // MARK: - 阴影（brand-spec §4/§6 新增三级；深色降 alpha 50% 由调用处自适应，
    //  此处按浅色实例值落地，深色折半用 shadow 颜色动态化——adaptiveAlpha 同族机制）
    public enum Shadow {
        /// card：y5 blur14 黑 5.5%
        public static let card = (color: Color.black.opacity(0.055), radius: CGFloat(14), y: CGFloat(5))
        /// popover/弹窗：y10 blur30 黑 12%
        public static let popover = (color: Color.black.opacity(0.12), radius: CGFloat(30), y: CGFloat(10))
        /// sticky（便签常态，studio 预留）：y4 blur12 黑 8%
        public static let sticky = (color: Color.black.opacity(0.08), radius: CGFloat(12), y: CGFloat(4))
        /// stickyDrag（便签拖动中，studio/spec §2）：y14 blur28 黑 16%
        public static let stickyDrag = (color: Color.black.opacity(0.16), radius: CGFloat(28), y: CGFloat(14))
    }

    // MARK: - 动效（brand-spec §4/§6 新增四档）
    public enum Motion {
        /// 微交互（悬停/按下）：120ms easeOut
        public static let micro: Animation = .easeOut(duration: 0.12)
        /// 面板开合/筛选切换：200ms easeInOut
        public static let panel: Animation = .easeInOut(duration: 0.2)
        /// 弹窗出现：220ms spring(response 0.32, damping 0.86)
        public static let dialog: Animation = .spring(response: 0.32, dampingFraction: 0.86)
        /// 加载 spinner：0.9s 线性循环（调用处 .repeatForever(autoreverses: false)）
        public static let spinner: Animation = .linear(duration: 0.9)
        /// 便签贴上画布（studio/spec §2）：260ms spring(response 0.3, damping 0.78) 缩放 0.9→1
        public static let stickOn: Animation = .spring(response: 0.3, dampingFraction: 0.78)
        /// 便签落位回弹（studio/spec §2）：180ms spring(response 0.28, damping 0.8)
        public static let stickSettle: Animation = .spring(response: 0.28, dampingFraction: 0.8)
        /// 画布缩放松手吸附：100ms easeOut
        public static let zoomSnap: Animation = .easeOut(duration: 0.1)
    }

    /// 浅深双色构建（跟随系统外观）。
    public static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let darkMode = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: darkMode ? dark : light)
        }))
    }
}

public extension Color {
    init(hex: UInt32) {
        self.init(nsColor: NSColor(hex: hex))
    }
}

public extension NSColor {
    convenience init(hex: UInt32) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255
        let g = CGFloat((hex >> 8) & 0xFF) / 255
        let b = CGFloat(hex & 0xFF) / 255
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
