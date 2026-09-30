//
//  PanelRegistry.swift
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

//  面板注册表：2 个面板各占一个导航位（另有一枚不进列表的「聊天主页」chatHome）。
//  Phase 1 收口：logs / diagnostics 保留占位页（.pending，Phase 2 重写）——
//  两槽的入口已按现状口径归并设置面板（「打开日志文件夹」「打开数据目录」按钮）。
//  问题6收口（实测修复）：workflows/workflow-editor/workflow-canvas 三个注册位
//  内容相同（都路由 WorkflowPanelView，编辑器/画布已内嵌其中）→ 只保留
//  「工作流」一个入口，另两位从注册表移除（21→19，与现状单「工作流」模块一致）。
//  U2（智能中心导航复刻·方案A）：「会话」从智能中心组移除（19→18）——聊天不再是
//  面板列表的一项，而是智能中心内容区的常驻主页。对齐原版 App.tsx：一级导航只有
//  智能中心/流程中心/设置，无会话入口；单击 Agent 即见聊天（两级导航，不再是三级）。
//  U3（仓库归位）：「仓库」独立面板从系统组移除（18→17）——WarehousePanel 嵌回
//  聊天右端 300pt 窄栏（对齐 ChatPanel.tsx:3152-3164），系统组保留「仓库管理」。
//  V1（智能中心侧栏单栏堆叠复刻）：智能中心组五个导航项全部移除（17→12）——
//  原版智能中心侧栏不是面板列表，而是单栏堆叠（App.tsx:233-290）：独立 Agent
//  手风琴 + 项目区 + 项目内 Agent 区 + 栏底任务队列/圆桌手风琴，由
//  IntelligenceSidebarView 直接挂载，五块不占注册表导航位；内容区 = chatHome
//  常驻 + 圆桌详情大屏（打开时覆盖，聊天保活）。旧记忆键（tasks 等）恢复落空 →
//  启动兜底 chatHome，不崩。
//  V4（设置整页覆盖复刻）：「系统」组整体从 rail/注册表移除（12→2）——
//  原版一级 rail 只有 智能中心/流程中心 + 底部「设置」齿轮（ModuleNav.tsx:44-47），
//  低频模块全部收进设置覆盖页内部导航（SettingsPage.tsx:38-44）：
//    · 知识记忆/推理后端/模型包/插件管理 → 覆盖页内嵌（SettingsPageView）
//    · 模型选项已内嵌推理后端（InferencePanelView）；仓库管理已内嵌知识记忆
//      （KnowledgePanelView「知识仓库」标签 = WarehouseManagerView）
//    · 日志/数据与诊断两占位导航项删除（能力 = 基础设置「打开日志文件夹/数据目录」按钮）
//    · 基础设置 → 覆盖页内部导航项；「关于」项 0.7.1 Bug 7 撤除（菜单栏恢复 macOS
//      标准关于弹窗，AboutPanel 诊断能力并入基础设置底部「诊断」区，AboutPanel 删除）
//  旧设置记忆键/深链（"settings"/"warehouse"/系统组各键）恢复落空兜底不崩：
//  "settings" → AppState 启动时打开设置覆盖页；其余 → 组默认面板。
//  接入方法见 docs/Phase1-面板接入指南.md。
//
//  分组对标现状应用（subagent/renderer/src/App.tsx + ModuleNav.tsx）：
//    智能中心（intelligence）—— 无注册表面板（侧栏单栏堆叠见 IntelligenceSidebarView；
//                                 内容区常驻聊天主页 chatHome，不占导航位）
//    流程中心（workflow）     —— 工作流 / CU 宏
//

import Foundation

public enum ModuleGroup: String, CaseIterable, Identifiable, Sendable {
    case intelligence
    case workflow
    /// 超级工作室（W3）：一级模块竖条第三枚；付费门控模块（LicenseGateLogic.studioGated）
    case studio

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .intelligence: return "智能中心"
        case .workflow: return "流程中心"
        case .studio: return "工作室"
        }
    }

    /// SF Symbol（一级模块竖条图标，对标 ModuleNav 的 bot/layers）
    public var icon: String {
        switch self {
        case .intelligence: return "sparkles.rectangle.stack"
        case .workflow: return "square.stack.3d.up"
        case .studio: return "square.grid.2x2" // spec §1：2×2 便签格语义
        }
    }
}

public enum PanelStatus: String, Sendable {
    case linked     // 已挂实现
    case pending    // 待重写（占位页）
}

public struct PanelDescriptor: Identifiable, Hashable, Sendable {
    /// 稳定键（UserDefaults 记忆 / 深链用）
    public let key: String
    public let title: String
    /// SF Symbol 图标名
    public let icon: String
    public let group: ModuleGroup
    public let status: PanelStatus
    /// 对标现状实现的源文件（重写时对照阅读）
    public let referencePath: String
    /// 一句话职责说明（占位页展示）
    public let summary: String

    public var id: String { key }
}

public enum PanelRegistry {

    /// U2（方案A）：「会话」不再是侧栏面板——聊天是智能中心内容区的常驻主页。
    /// 该描述符不进 `all`（不占导航位、不出现在面板侧栏），仅作：
    ///   ① 智能中心默认落点（切模块 / 启动兜底）② UserDefaults 记忆键 "chat" 的恢复目标
    ///   ③ 各面板「去对话 / 开始对话 / 任务跳转」的导航目标（= 选中智能中心 + 设置上下文）。
    public static let chatHome = PanelDescriptor(
        key: "chat", title: "会话", icon: "bubble.left.and.bubble.right",
        group: .intelligence, status: .linked,
        referencePath: "renderer/src/panels/ChatPanel.tsx",
        summary: "智能中心常驻聊天主页（U2 起不再注册为侧栏面板）")

    /// W3：工作室主页（全屏模块，无侧栏面板——对齐 U2 聊天主页同口径：
    /// 不进 all、不占导航位，仅作切模块落点与记忆恢复目标）。
    public static let studioHome = PanelDescriptor(
        key: "studio", title: "工作室", icon: "square.grid.2x2",
        group: .studio, status: .linked,
        referencePath: "Sources/VetarAINative/UI/Studio/StudioPanelView.swift",
        summary: "超级工作室常驻主页（应用内全屏，无面板侧栏）")

    /// 2 个面板（顺序即侧栏展示顺序）。
    /// V1：智能中心组无注册项——五块（独立 Agent/项目/项目内 Agent/任务队列/圆桌）
    /// 由 IntelligenceSidebarView 单栏堆叠直接挂载（对齐 App.tsx:233-290）。
    /// V4：系统组 10 个导航项全部移除——低频模块收进设置整页覆盖的内部导航
    ///（SettingsPageView，对齐 ModuleNav.tsx:44-47 + SettingsPage.tsx:38-44）。
    public static let all: [PanelDescriptor] = [
        // ── 流程中心（2）──
        PanelDescriptor(key: "workflows", title: "工作流", icon: "square.stack.3d.up",
                        group: .workflow, status: .linked,
                        referencePath: "renderer/src/panels/WorkflowPanel.tsx",
                        summary: "工作流列表 / 运行 / 历史（编辑器与画布已内嵌本面板）"),
        PanelDescriptor(key: "cu-macro", title: "CU 宏", icon: "desktopcomputer",
                        group: .workflow, status: .linked,
                        referencePath: "renderer/src/panels/CuMacroPanel.tsx",
                        summary: "Computer-Use 操作宏"),
    ]

    public static func panel(forKey key: String) -> PanelDescriptor? {
        // 聊天主页可经键解析（UserDefaults 记忆恢复 / 深链），但不占侧栏导航位
        if key == chatHome.key { return chatHome }
        // W3：工作室主页同口径
        if key == studioHome.key { return studioHome }
        return all.first { $0.key == key }
    }

    public static func panels(in group: ModuleGroup) -> [PanelDescriptor] {
        all.filter { $0.group == group }
    }

    public static func defaultPanel(in group: ModuleGroup) -> PanelDescriptor {
        // U2：智能中心默认落聊天主页（对齐原版：切进智能中心即见聊天 / 引导空态）
        if group == .intelligence { return chatHome }
        // W3：工作室默认落工作室主页（全屏模块）
        if group == .studio { return studioHome }
        return panels(in: group).first!
    }
}
