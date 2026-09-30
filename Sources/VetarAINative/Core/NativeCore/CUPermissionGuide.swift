//
//  CUPermissionGuide.swift
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

//  需求背景：REQ-FUT-005 待办「引导式权限流程」（0.4.32 二期范围外另立项，
//  业主 2026-09-26 拍板排 0.7.5 W2；二期②OCR/③AppleScript 暂缓登记，不在本包）。
//
//  修复前原生线现状（亲查）：
//    · 设置-CU 页（SettingsCUView）仅「检测权限」按钮 + 三态事实行——缺权限时
//      只列后果文案，无授权路径、无直达、无分步引导；
//    · CU 宏面板（CuMacroPanelView）有 R4「输入监控」单权限引导条（请求授权钮
//      + 文字路径）——只覆盖录制一个场景一个权限。
//  本包补齐：三权限（辅助功能/屏幕录制/输入监控，macOS TCC 三项独立授权、
//  互不覆盖）统一引导式流程——检测各权限状态、缺失时中文分步引导
// （系统设置直达按钮 / 说明 / 复核刷新）。
//
//  分层：本文件＝纯逻辑（状态解析 + 引导数据，XCTest 覆盖；UI 不直接触 TCC，
//  状态由注入 provider 供给——生产为系统只读状态位，测试为桩）。
//  呈现层＝CUPermissionGuideView（设置-CU 页挂载）。
//
//  未授权不硬闯（既有防线，本包不松动，仅列索引）：
//    · 执行层防线1：NativeComputerUse 动作前查 AXIsProcessTrusted /
//      CGPreflightScreenCaptureAccess，缺权限报错返回（不点击不截屏）；
//    · 录制层：CuMacroPanelViewModel.startUserRecord 先查 permission，
//      未授权落引导 callout、不发 start；
//    · AX 读树：NativeCoreGraphicsCUAdapter.hitTest/appElements 缺权限静默回落。
//

import Foundation
import AppKit
import ApplicationServices
import Combine

// MARK: - 模型

/// CU 三权限（声明序即引导展示序）
public enum CUPermission: String, CaseIterable, Sendable {
    /// 辅助功能（AXIsProcessTrusted）——模拟点击/键盘 + AX 元素定位
    case accessibility
    /// 屏幕录制（CGPreflightScreenCaptureAccess）——截屏（缺它只拍到壁纸）
    case screenCapture
    /// 输入监控（CGPreflightListenEventAccess）——「录制我的操作」CGEventTap 监听
    case inputMonitoring
}

/// 三态（nil 探测不到单列——AX/CG 状态位在当前部署目标恒可读，防御保留）
public enum CUPermissionState: String, Sendable {
    case granted, denied, unknown
}

/// 单权限引导卡数据（缺失时呈现；全字段纯值，Equatable 可测）
public struct CUPermissionGuideItem: Equatable, Sendable {
    public let permission: CUPermission
    public let state: CUPermissionState
    public let title: String             // 权限名
    public let purpose: String           // 用途（为什么需要）
    public let consequence: String       // 未授权后果（如实）
    public let steps: [String]           // 分步引导（中文，顺序执行）
    public let settingsDeepLink: String  // 系统设置直达（x-apple.systempreferences）
    public let canRequestInApp: Bool     // 可应用内触发系统授权弹窗
    public let needsRestart: Bool        // 授权后须重启本应用才生效（如实）
}

// MARK: - 状态解析 + 引导数据

public enum CUPermissionGuide {

    /// Bool? 状态位 → 三态（nil = 无法探测）
    public static func state(of raw: Bool?) -> CUPermissionState {
        switch raw {
        case .some(true): return .granted
        case .some(false): return .denied
        case .none: return .unknown
        }
    }

    /// 缺失权限列表（denied/unknown 均视为需引导；顺序 = 声明序，稳定可测）
    public static func missing(_ statuses: [CUPermission: CUPermissionState]) -> [CUPermission] {
        CUPermission.allCases.filter { (statuses[$0] ?? .unknown) != .granted }
    }

    /// 全部就绪（三权限均 granted）
    public static func allGranted(_ statuses: [CUPermission: CUPermissionState]) -> Bool {
        missing(statuses).isEmpty
    }

    /// 单权限引导卡
    public static func guideItem(for p: CUPermission,
                                 state: CUPermissionState) -> CUPermissionGuideItem {
        CUPermissionGuideItem(permission: p, state: state,
                              title: title(for: p), purpose: purpose(for: p),
                              consequence: consequence(for: p), steps: steps(for: p),
                              settingsDeepLink: settingsDeepLink(for: p),
                              canRequestInApp: true, needsRestart: needsRestart(for: p))
    }

    public static func title(for p: CUPermission) -> String {
        switch p {
        case .accessibility: return "辅助功能"
        case .screenCapture: return "屏幕录制"
        case .inputMonitoring: return "输入监控"
        }
    }

    public static func purpose(for p: CUPermission) -> String {
        switch p {
        case .accessibility:
            return "模拟鼠标点击与键盘输入，并读取界面元素做元素定位（命中校正点击坐标）"
        case .screenCapture:
            return "截取屏幕画面，供 Agent 视觉理解当前界面"
        case .inputMonitoring:
            return "「录制我的操作」监听你的鼠标键盘动作（listen-only 只监听、不拦截）"
        }
    }

    public static func consequence(for p: CUPermission) -> String {
        switch p {
        case .accessibility:
            return "未授予时点击/输入会被系统静默丢弃，元素定位也不可用"
        case .screenCapture:
            return "未授予时截屏只拍到桌面壁纸，Agent 看不到任何窗口"
        case .inputMonitoring:
            return "未授予时系统拒绝建立事件监听，无法开始「录制我的操作」"
        }
    }

    /// 分步引导（末步恒为复核——「回到本页点『复核刷新』确认状态变为 ✓ 已授予」）
    public static func steps(for p: CUPermission) -> [String] {
        switch p {
        case .accessibility:
            return [
                "点击「打开系统设置」直达 隐私与安全性 → 辅助功能（或点「请求系统授权」由系统发起授权弹窗）",
                "在列表中找到 VetarAI 并打开开关（列表里没有就点「+」添加本应用）",
                "回到本页点「复核刷新」，确认状态变为 ✓ 已授予",
                "若开关已开但状态仍未变：把 VetarAI 从列表选中点「−」移除，再重新添加授权",
            ]
        case .screenCapture:
            return [
                "点击「打开系统设置」直达 隐私与安全性 → 屏幕录制（或点「请求系统授权」）",
                "在列表中打开 VetarAI 的开关",
                "按系统提示「退出并重新打开」本应用——屏幕录制授权必须重启后才生效",
                "重启后回到本页点「复核刷新」，确认状态变为 ✓ 已授予",
            ]
        case .inputMonitoring:
            return [
                "点击「打开系统设置」直达 隐私与安全性 → 输入监控（或点「请求系统授权」）",
                "在列表中打开 VetarAI 的开关（列表里没有就点「+」添加本应用）",
                "退出并重新打开本应用——输入监控授权按进程启动时读取，须重启生效",
                "重启后回到本页点「复核刷新」，或直接去 CU 宏面板重试「录制我的操作」",
            ]
        }
    }

    /// 系统设置直达深链（macOS 13+ System Settings 仍受理 legacy security anchor）
    public static func settingsDeepLink(for p: CUPermission) -> String {
        switch p {
        case .accessibility:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .screenCapture:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case .inputMonitoring:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        }
    }

    /// 授权后是否须重启本应用（如实：屏幕录制/输入监控 TCC 按进程启动时读取；
    /// 辅助功能开关即刻生效）。与 NativeUserRecorder.requestListenAccess 头注同口径。
    public static func needsRestart(for p: CUPermission) -> Bool {
        switch p {
        case .accessibility: return false
        case .screenCapture, .inputMonitoring: return true
        }
    }
}

// MARK: - 系统交互（生产实调；测试不触——纯逻辑层不覆盖这两个函数）

public enum CUPermissionRequest {

    /// 打开系统设置对应隐私面板（直达锚点；深链失效时退隐私与安全性首页）
    @MainActor
    public static func openSystemSettings(for p: CUPermission) {
        let primary = CUPermissionGuide.settingsDeepLink(for: p)
        if let url = URL(string: primary) {
            NSWorkspace.shared.open(url)
        }
    }

    /// 应用内触发系统授权弹窗（各权限对应 TCC request API；系统只弹一次，
    /// 之后须走系统设置手动开关——引导步骤文案已如实写明重启口径）。
    /// 返回请求后即时状态（仅供参考，权威状态以复核刷新 preflight 为准）。
    @discardableResult
    public static func requestSystemPrompt(for p: CUPermission) -> Bool {
        switch p {
        case .accessibility:
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        case .screenCapture:
            return CGRequestScreenCaptureAccess()
        case .inputMonitoring:
            return NativeUserRecorder.requestListenAccess()
        }
    }

    /// 生产状态位探针（只读、不触发弹窗、无隐私副作用）：
    /// 辅助功能 / 屏幕录制 / 输入监控三项 TCC 状态一次取齐。
    public static func probeStatuses() -> [CUPermission: CUPermissionState] {
        [
            .accessibility: CUPermissionGuide.state(of: AXIsProcessTrusted()),
            .screenCapture: CUPermissionGuide.state(of: CGPreflightScreenCaptureAccess()),
            .inputMonitoring: CUPermissionGuide.state(of: NativeUserRecorder.listenAccessGranted()),
        ]
    }
}

// MARK: - 权限状态单一真源（0.7.5 收口审查 M3 修复：CU 权限双口径同屏矛盾）

/// 设置-CU 页权限状态唯一权威。修复前同屏两套口径：
///   A 既有探测区读 vm.cuCapabilities facts（内核探测缓存，仅首探/手动按钮刷新）；
///   B 本引导区 onAppear 直读 TCC——存在「A 显示 ✗ 未授权、B 显示 ✓ 已授权」路径。
/// 统一后：
///   · 唯一权威读取 = CUPermissionRequest.probeStatuses()（AX/CG/Listen 三状态位
///     直读，只读无副作用，刷新成本可忽略）；
///   · 探测区不再渲染权限结论行（权限行只保留引导区这一套，探测区仅呈
///     非权限能力事实：前台应用/屏幕尺寸/截屏分辨率/CoreGraphics 接口）；
///   · 刷新时机一致：页出现 / 「检测权限」/「复核刷新」/「请求系统授权」后
///     同刻调 refresh()——任一动作单源失效，两侧永不分叉。
@MainActor
public final class CUPermissionStatusStore: ObservableObject {

    /// 三权限当前状态（空字典 = 尚未首探；消费侧按 unknown 呈现）
    @Published public private(set) var statuses: [CUPermission: CUPermissionState] = [:]

    /// 探针缝（生产 = 系统 TCC 直读；测试注入桩——纯逻辑层纪律同款）
    private let probe: () -> [CUPermission: CUPermissionState]

    public init(probe: @escaping () -> [CUPermission: CUPermissionState] =
                    CUPermissionRequest.probeStatuses) {
        self.probe = probe
    }

    /// 重探并发布（唯一写入口；页出现与全部刷新按钮同走此处）
    public func refresh() {
        statuses = probe()
    }

    /// 既有三态行消费口径：granted→true / denied→false / unknown(含未首探)→nil
    public func boolState(for p: CUPermission) -> Bool? {
        switch statuses[p] ?? .unknown {
        case .granted: return true
        case .denied: return false
        case .unknown: return nil
        }
    }
}
