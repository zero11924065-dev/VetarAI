//
//  PanelBusyGuard.swift
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

//  业主定性：工作流在跑 / 圆桌讨论进行中时，用户关闭或切走面板需弹确认。
//
//  结构：
//    · PanelBusyGuard（AppState 持有，随 app 同寿）：busy 源登记 + 确认文案
//      纯逻辑（本批 XCTest 覆盖：运行中→需确认、空闲→直通）；
//    · BusyGuardAlert：NSAlert 模态呈现（windowShouldClose / 模块切换均为
//      同步答复场景，与 DialogCenter 异步弹窗不同通道）。
//
//  文案按真实中断语义逐源如实写（不夸大不隐瞒）：
//    · 工作流：切走模块 → 侧栏+内容区双挂载点 detach 归零 → VM stop() →
//      stopRunLocal() 本地断流清运行态——实时跟踪确实中断；结果事后可在
//      「运行记录」查看（运行列表重拉自 DB，口径如实）。
//    · 圆桌：讨论跑在内核（面板只是轮询观察），切走/关闭详情不中断——
//      如实告知「继续在后台运行」；关闭窗口若致应用退出才中断，文案写清条件。
//
//  上报方：
//    · WorkflowPanelViewModel.running didSet → report(.workflow)
//    · RoundtablePanelViewModel roundtables/detail didSet → report(.roundtable)
//      （仅 status=="running" 计 busy——waiting_user/confirm_end 非「在跑」）
//    · ChatViewModel（0.7.12 实测修复 F2）→ report(.chat)：口径 = 本进程仍有
//      活流（当前视图 sending 或后台 stash 流非空）；切走不拦（后台续跑属实），
//      关窗/退出拦（关窗=退出=中断，半成品不落库如实告知）。
//

import Foundation
import AppKit

/// busy 源（登记表键）
public enum BusySource: String, Sendable {
    case workflow
    case roundtable
    /// 智能中心会话流式（0.7.12 实测修复 F2：chat 此前从未登记——Cmd+Q 忙守
    /// 对「正在生成回复」完全失效，生成中退出无任何确认直接杀进程）
    case chat
}

/// 确认场景（同一 busy 源在不同场景的中断语义不同，文案分叉）
public enum BusyContext: Sendable {
    /// 切走（模块竖条切换）
    case switchAway
    /// 关闭窗口（关闭按钮 / Cmd+W）
    case closeWindow
    /// 退出应用（Cmd+Q / 菜单退出 / NSApp.terminate；0.7.5 W9）
    case quit
}

/// 确认弹窗文案（标题 + 正文 + 确认钮）
public struct BusyConfirmation: Equatable, Sendable {
    public let title: String
    public let message: String
    public let confirmText: String
    public init(title: String, message: String, confirmText: String) {
        self.title = title
        self.message = message
        self.confirmText = confirmText
    }
}

@MainActor
public final class PanelBusyGuard {

    /// 当前 busy 源集合（私有写；上报经 report）
    public private(set) var busySources: Set<BusySource> = []

    /// reportBusy 登记口：源忙/闲翻转即调（幂等）
    public func report(_ source: BusySource, isBusy: Bool) {
        if isBusy { busySources.insert(source) } else { busySources.remove(source) }
    }

    public var isBusy: Bool { !busySources.isEmpty }

    // MARK: - busy 判定 + 文案（nil = 空闲直通）

    /// 核心判定（W8 XCTest 载体）：有 busy 源 → 组确认文案；空闲 → nil 直通。
    public func confirmation(for context: BusyContext) -> BusyConfirmation? {
        guard isBusy else { return nil }
        var parts: [String] = []
        if busySources.contains(.workflow) {
            switch context {
            case .switchAway:
                parts.append("工作流正在运行，切走后本次运行的实时进度将中断"
                             + "（结果可稍后在运行记录中查看）")
            case .closeWindow:
                // 0.7.5 W11：末窗关闭即退出应用（对齐 0.4.x）——关窗=退出=中断运行，
                // 旧文案「中断实时跟踪」在新口径下属于轻描淡写，如实升级为中断运行。
                // （极端边角：关于面板等辅助窗开着时关主窗不触发退出，文案偏重警告
                //   方向，属可接受的保守告知。）
                parts.append("工作流正在运行，关闭窗口将退出应用并中断本次运行")
            case .quit:
                // W9 如实口径：内核在本进程，退出即杀运行——进度中断；
                // 已执行部分落库可事后查看（运行列表重拉自 DB）。
                parts.append("工作流正在运行，退出应用将中断本次运行的进度"
                             + "（已执行部分可在「运行记录」中查看）")
            }
        }
        if busySources.contains(.roundtable) {
            switch context {
            case .switchAway:
                parts.append("圆桌讨论进行中，离开后讨论继续在后台运行，可随时回来查看")
            case .closeWindow:
                // 0.7.5 W11：末窗关闭即退出应用——「若应用退出」条件变为必然，如实直写。
                parts.append("圆桌讨论进行中，关闭窗口将退出应用，进行中的讨论将中断")
            case .quit:
                // W9 如实口径：讨论跑在本进程内核（Phase 3 侧车已归零），退出应用
                // 即终止——不能沿用「后台继续」（那是切走/不关应用的口径）。
                parts.append("圆桌讨论进行中，退出应用将中断本次讨论"
                             + "（讨论由本应用内核执行，退出即终止）")
            }
        }
        if busySources.contains(.chat) {
            switch context {
            case .switchAway:
                // F2 如实口径：chat 切走后台续跑（0.7.8 后台流 stash 语义），
                // 不拦不弹——仅 .chat 单源时 parts 为空，下方直通 nil。
                break
            case .closeWindow:
                // 0.7.5 W11 同构：关窗=退出=中断（assistant 半成品不落库，
                // 用户消息仍在——0.7.12 R1 起重进标「已中断」可一键重发）。
                parts.append("正在生成回复，关闭窗口将退出应用并中断本次生成")
            case .quit:
                // F2 如实口径：流式由本进程内核执行，退出即中断；
                // 已生成的半成品不落库（done 才落库），不谎称可恢复。
                parts.append("正在生成回复，退出应用将中断本次生成")
            }
        }
        // 唯一 busy 源是 .chat 且场景为切走 → 无确认内容，直通（后台续跑属实）
        guard !parts.isEmpty else { return nil }
        switch context {
        case .switchAway:
            return BusyConfirmation(title: "确认离开",
                                    message: parts.joined(separator: "\n") + "\n确定离开吗？",
                                    confirmText: "离开")
        case .closeWindow:
            return BusyConfirmation(title: "确认关闭窗口",
                                    message: parts.joined(separator: "\n") + "\n确定关闭吗？",
                                    confirmText: "关闭")
        case .quit:
            return BusyConfirmation(title: "确认退出",
                                    message: parts.joined(separator: "\n") + "\n确定退出吗？",
                                    confirmText: "退出")
        }
    }

    /// 圆桌详情「返回列表」确认文案（仅讨论 running 时弹；后台继续口径——
    /// 讨论跑在内核，退出详情只停本地轮询，讨论本身不中断）。
    public static func roundtableDetailCloseConfirmation(
        running: Bool
    ) -> BusyConfirmation? {
        guard running else { return nil }
        return BusyConfirmation(
            title: "确认离开",
            message: "圆桌讨论进行中，离开后讨论继续在后台运行，可随时回来查看。\n确定离开吗？",
            confirmText: "离开")
    }
}

// MARK: - NSAlert 模态呈现（同步答复场景：模块切换 / windowShouldClose）

public enum BusyGuardAlert {

    /// NSAlert 模态确认（true = 用户点了确认钮）
    @MainActor
    public static func confirm(_ c: BusyConfirmation) -> Bool {
        let alert = NSAlert()
        alert.messageText = c.title
        alert.informativeText = c.message
        alert.alertStyle = .warning
        alert.addButton(withTitle: c.confirmText)
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// 确认闸便捷入口：busy → 弹确认（用户确认才放行）；空闲 → 直通
    @MainActor
    public static func gate(_ busyGuard: PanelBusyGuard, context: BusyContext) -> Bool {
        guard let c = busyGuard.confirmation(for: context) else { return true }
        return confirm(c)
    }
}

// MARK: - W9/W11 终止闸决策（纯逻辑，XCTest 载体；呈现层 VetarAppDelegate）

/// Cmd+Q / 菜单退出 / 末窗关闭 三类终止入口的统一决策：
///   · 末窗关闭链已取过同意（windowShouldClose 闸弹过一次）→ 直通，防双弹窗；
///   · 空闲 → 直通；
///   · 其余 busy → 需弹 .quit 确认闸。
public enum QuitGatePolicy {
    public static func needsConfirmation(skipAfterWindowClose: Bool, isBusy: Bool) -> Bool {
        if skipAfterWindowClose { return false }
        return isBusy
    }
}
