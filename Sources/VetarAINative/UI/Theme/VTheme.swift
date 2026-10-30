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

//  设计 Token（唯一数值源）：方向2「书房纸墨」（2026-10-19 业主拍板 D1~D5，
//  蓝本 docs/design/UI重构-方向2蓝本与布局优化-2026-10-19.md）：
//    · 冷纸灰白底 + 白卡片，墨黑正文，主按钮石墨黑
//    · 强调色只留一枚克制的藏蓝（选中/链接/焦点/细条），语义色降饱和
//    · 展示层宋体（Songti SC 系统自带）+ 正文黑体；Space 8pt 间距网格
//  历史来源：初版对齐旧线「纸面工具」（subagent/renderer/src/theme.ts，A12 0.4.25），
//  方向2 在其纸面 DNA 上深化（雾蓝→朱砂、宋体展示层、间距令牌化）。
//  深/浅色跟随系统：浅色取拍板值；深色取同族降亮度映射，不追求像素级复刻。
//

import SwiftUI

public enum VTheme {

    // MARK: - 中性背景（方向2「书房纸墨」2026-10-19 拍板：纸感不奶油，白卡片浮起）
    public static let bgApp = adaptive(light: 0xF4F3F0, dark: 0x1E1E1C)
    public static let bgSidebar = adaptive(light: 0xEBEAE5, dark: 0x262624)
    public static let bgCard = adaptive(light: 0xFFFFFF, dark: 0x2C2C2A)
    public static let bgHover = adaptive(light: 0xE9E7E1, dark: 0x3A3A37)
    public static let bgActive = adaptive(light: 0xDFDCD4, dark: 0x444442)
    public static let bgSelected = adaptive(light: 0xE9EEFC, dark: 0x1F2A4A)

    // MARK: - 边框（逐级加深；方向2 去线化再降半档存在感，L2）
    public static let borderSubtle = adaptive(light: 0xE7E4DD, dark: 0x3A3A37)
    public static let borderDefault = adaptive(light: 0xDCD8CF, dark: 0x444442)
    public static let borderStrong = adaptive(light: 0xC9C4B8, dark: 0x555552)

    // MARK: - 文字（墨黑 ↔ 暖白；textTertiary 对比度 3.4→≈4.7:1 修复，S3）
    public static let textPrimary = adaptive(light: 0x1C1C1A, dark: 0xF2F1ED)
    public static let textSecondary = adaptive(light: 0x5C594F, dark: 0xB8B5AB)
    public static let textTertiary = adaptive(light: 0x706C61, dark: 0xA09C92)
    public static let textDisabled = adaptive(light: 0xA9A59A, dark: 0x5C594F)

    // MARK: - 主按钮：石墨黑（ink ↔ 纸白）——方向2 保留：藏蓝只做强调，主按钮仍是墨黑
    public static let ink = adaptive(light: 0x1C1C1A, dark: 0xFAFAF8)
    public static let inkHover = adaptive(light: 0x37352F, dark: 0xFFFFFF)
    public static let onInk = adaptive(light: 0xFAFAF8, dark: 0x1C1C1A)

    // MARK: - 强调色：藏蓝（2026-10-25 业主拍板：朱砂→藏蓝，参考 VetarModel 雾紫换槽思路）
    // 口径不变：强调色只留一枚克制藏蓝（选中/链接/焦点/细条），勿当万能胶。
    public static let accent = Color(hex: 0x3457D5)
    public static let accentHover = Color(hex: 0x2B46B8)
    public static let accentText = adaptive(light: 0x2B46B8, dark: 0x8FA5EC)
    public static let accentBg = adaptive(light: 0xE9EEFC, dark: 0x1F2A4A)
    public static let accentBorder = adaptive(light: 0xC7D3F2, dark: 0x3A4773)
    public static let accentBgSoft = adaptive(light: 0xF4F6FD, dark: 0x232D45)
    public static let accentTextDeep = adaptive(light: 0x243A9C, dark: 0xA8B9F0)

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
    // 方向2 波次2：登录系骨架（AuthScaffold）点阵色 adaptive 化——原 Color(hex: 0xE2DFD6)
    // 固定浅色，深色下刺眼。规格与 canvasDot 不同（间距 30 点 1.1），另立令牌；
    // 深色同族降亮度自取 0x4D4B47（较 canvasDot 深色 0x4A4844 微亮，对齐浅色端
    // 0xE2DFD6 相对 0xD8D5CC 的亮度差 ⚠️VERIFY 待真机过目）。
    /// 登录系骨架点阵（间距 30 点 1.1）
    public static let authScaffoldDot = adaptive(light: 0xE2DFD6, dark: 0x4D4B47)

    // MARK: - 阶段三预留：讨论便签 token（拍板项③ 占位；W5 启用画布便签/筛选胶囊）
    /// noteDiscuss 青色系 #0D9488 族——与五类便签拉开色相（方向2 波次2 收口：
    /// 复审图 discuss 节点左条/类型徽标由 noteUser 紫统一切本族，与画布便签同色）
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

    // MARK: - Workflow 节点分类色（方向2 波次2 迁入+深色映射：
    //  原 WorkflowMeta.swift :32-42 三处 Color(hex:) 固定 sRGB 不走深色，收编为
    //  adaptive 双态令牌；原绿 0x5FA388 与 ok 绿撞色，改青族）
    /// 紫（parallel 并行 / loop 循环）
    public static let wfNodeViolet = adaptive(light: 0x8578C8, dark: 0xA79BE0)
    /// 蓝（file_input/file_read/file_output 等触发/文件族）
    public static let wfNodeBlue = adaptive(light: 0x5B8DB8, dark: 0x7FA8CC)
    /// 青（text_output/variable_set/reply 输出族；原绿 0x5FA388 与 ok 撞色改青）
    public static let wfNodeTeal = adaptive(light: 0x4E8A96, dark: 0x6BA8B4)

    // MARK: - 圆角（方向2 新增 msg 消息泡档，D4）
    public enum Radius {
        public static let s: CGFloat = 6
        /// brand-spec §6 新增：输入框/按钮/提示条统一 8（现行实现大量手写 8，token 化补齐）
        public static let m2: CGFloat = 8
        public static let m: CGFloat = 10
        public static let l: CGFloat = 12
        /// 方向2 D4 新增：消息泡圆角（灵动由阴影/动效承担，气泡保持收敛 14）
        public static let msg: CGFloat = 14
    }

    // MARK: - 间距（方向2 新增 Space 族：8pt 网格，全仓散数 padding 收编的唯一来源）
    public enum Space {
        public static let s1: CGFloat = 4
        public static let s2: CGFloat = 8
        public static let s3: CGFloat = 12
        public static let s4: CGFloat = 16
        public static let s5: CGFloat = 24
        public static let s6: CGFloat = 32
        public static let s7: CGFloat = 48
    }

    public enum Typo {
        /// 展示层·宋体（方向2 D3）：登录页/空态主标题。Songti SC 为 macOS 系统自带，
        /// 零新增依赖；⚠️VERIFY 真机回退形态（旧系统字形差异时兜底 serif）
        public static let display = Font.custom("Songti SC", size: 24).weight(.semibold)
        /// 展示层·宋体：页面大标题（原 title2 20 黑体收档更名）
        public static let title = Font.custom("Songti SC", size: 17).weight(.semibold)
        public static let pageTitle = Font.system(size: 16, weight: .semibold)
        public static let sectionTitle = Font.system(size: 14, weight: .semibold)
        public static let panelTitle = Font.system(size: 12, weight: .semibold)
        public static let body = Font.system(size: 13)
        public static let msgBody = Font.system(size: 14)
        public static let caption = Font.system(size: 12)
        public static let micro = Font.system(size: 11)
        // 方向2 波次2：弹窗标题档——收编解绑弹窗/试用到期弹窗/付费门三处手写
        // .system(size: 15, weight: .semibold)。
        public static let dialogTitle = Font.system(size: 15, weight: .semibold)
        // 方向2 波次2：字标档（brand-spec §7：22 Semibold + tracking -0.11 即 -0.5%em；
        // tracking 修饰保留在消费处 LogoLockup 原处）。
        public static let wordmark = Font.system(size: 22, weight: .semibold)
        // 方向2 波次2：数据身份专用 mono——端口/路径/参数值等纯数据段；
        // 中文标签不随 mono（整行混排会渲染出混合节奏，标签走正文/caption 界面字）。
        public static let mono = Font.system(size: 12, design: .monospaced)
        // 方向2 收编注记：display28(28)/title2(20) 更名收档为 display(24)/title(17)；
        // railLabel(10) 低于「任何文字 ≥11pt」地板且 0 消费，废弃并入 micro(11)。

        // MARK: 工作室视觉丰富化追加（2026-10-20 业主拍板 A~F 六动作，
        //  依据 docs/design/工作室视觉丰富化思路-2026-10-20.md §四 参数 +
        //  mockups/工作室书房墙对比-2026-10-20.html 逐值；红线5 留痕：以下档位
        //  为 A 印章 / F 落款工位牌确需新增，族内无对应档）
        /// 印章刻字（A 印章系统）：宋体 13 Semibold——26×26 印面「讫/勘」用；
        /// 印面篆刻属图形符号（非正文），不参与「任何文字 ≥11pt」地板口径。
        public static let seal = Font.custom("Songti SC", size: 13).weight(.semibold)
        /// 落款/工位牌小字（F）：宋体 11——字画题跋落款档，字级同 micro 地板。
        public static let brushMicro = Font.custom("Songti SC", size: 11)
    }

    // MARK: - 阴影（方向2：card 0.055→0.05；新增 composer 悬浮档，D4）
    //  方向2 波次2：深色降 alpha 50% 收口到令牌层（原注释称「由调用处自适应」，
    //  实际全仓无调用处做——令牌直接出双态：浅色不变、深色减半；消费点不动）。
    //  ⚠️VERIFY 深色阴影观感待真机过目。
    public enum Shadow {
        /// card：y5 blur14 黑 5%（深色 2.5%）
        public static let card = (color: shadowColor(lightAlpha: 0.05), radius: CGFloat(14), y: CGFloat(5))
        /// popover/弹窗：y10 blur30 黑 12%（深色 6%）
        public static let popover = (color: shadowColor(lightAlpha: 0.12), radius: CGFloat(30), y: CGFloat(10))
        /// composer（方向2 D4 悬浮输入区专用）：y4 blur20 黑 10%（深色 5%）
        public static let composer = (color: shadowColor(lightAlpha: 0.10), radius: CGFloat(20), y: CGFloat(4))
        /// sticky（便签常态，studio 预留）：y4 blur12 黑 8%（深色 4%）
        public static let sticky = (color: shadowColor(lightAlpha: 0.08), radius: CGFloat(12), y: CGFloat(4))
        /// stickyRaised（E 空间纵深·便签浮起中档：拖动 stickyDrag > 选中/钉住 本档 >
        /// 常态 sticky；2026-10-20 拍板追加，族内原仅两级）：y7 blur18 黑 11%（深色 5.5%）
        public static let stickyRaised = (color: shadowColor(lightAlpha: 0.11), radius: CGFloat(18), y: CGFloat(7))
        /// stickyDrag（便签拖动中，studio/spec §2）：y14 blur28 黑 16%（深色 8%）
        public static let stickyDrag = (color: shadowColor(lightAlpha: 0.16), radius: CGFloat(28), y: CGFloat(14))

        /// 阴影色双态构建：浅色取实例 alpha，深色减半（radius/y 不随外观变化）。
        private static func shadowColor(lightAlpha: CGFloat) -> Color {
            Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
                let darkMode = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return NSColor.black.withAlphaComponent(darkMode ? lightAlpha / 2 : lightAlpha)
            }))
        }
    }

    // MARK: - 动效（方向2 新增 msgIn 消息入场，L1）
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
        /// 消息入场（方向2 L1）：200ms easeOut 淡入+上移 8pt（位移由消费处组合）
        public static let msgIn: Animation = .easeOut(duration: 0.2)
        /// 进度条推进反馈（方向2 波次4b：收编 RequiredModelsPrompt 手写 easeOut 0.3——
        /// 族内无同值档，micro 0.12 太急、msgIn 0.2 不等值，保 0.3 原值入令牌）
        public static let progress: Animation = .easeOut(duration: 0.3)

        // MARK: 工作室视觉丰富化追加（2026-10-20 拍板 A/D 三档，规格值出处：
        //  思路文档 §四-A「150ms 缩放下压」/ §四-D「2.6s 呼吸」「2s 叩门」；
        //  族内无相近档——micro 0.12 太急、spinner 0.9 不等值，红线5 留痕追加）
        /// 盖章下压（A 印章）：150ms easeOut，缩放 1.15→1 + 墨晕扩散同步
        public static let sealStamp: Animation = .easeOut(duration: 0.15)
        /// 状态呼吸半周期（D）：1.3s easeInOut——PhaseAnimator 两档往返成全周期 2.6s
        public static let breathe: Animation = .easeInOut(duration: 1.3)
        /// 叩门脉动半周期（D）：1.0s easeInOut——藏蓝细框 0.25↔0.55 全周期 2s
        public static let knock: Animation = .easeInOut(duration: 1.0)
    }

    // MARK: - 遮罩（方向2 波次2 新增：弹窗 scrim 统一令牌）
    /// 弹窗/浮层背景遮罩（收编 ActivationView/AgreementDialogView/AccountPanelView/
    /// LicenseBanners/PaywallGate 共 5 处手写 Color.black.opacity(0.3)）；
    /// 浅色黑 30%，深色升 45% 压得住亮底（⚠️VERIFY 待真机过目）。
    public static let scrim = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        let darkMode = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return NSColor.black.withAlphaComponent(darkMode ? 0.45 : 0.30)
    }))

    // MARK: - Toast（方向2 波次4b 新增语义令牌）
    /// Toast 胶囊底：原 VToast 手写 Color(hex: 0x1C1C1A).opacity(0.92)——ink 浅色值拷贝；
    /// 直接换 ink 令牌深色下会翻白（Toast 文案恒白，翻白即消失），故立双态恒深墨令牌。
    public static let toastBg = Color(hex: 0x1C1C1A).opacity(0.92)

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
