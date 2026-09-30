//
//  CUPermissionGuideTests.swift
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

//  覆盖（不触 TCC，系统交互层不在测试面）：
//    · Bool? → 三态解析（granted/denied/unknown）
//    · missing()：全授→空；缺谁列谁；unknown 视为需引导；顺序恒为声明序
//    · allGranted()
//    · 引导卡数据：三权限各自 title/purpose/consequence/steps 非空、
//      深链锚点逐字、canRequestInApp、needsRestart 如实分叉
//      （辅助功能即刻生效；屏幕录制/输入监控须重启——TCC 按进程启动时读取）
//    · 分步引导收口：末步恒含「复核」口径；须重启权限的步骤如实写「重启」
//

import XCTest
@testable import VetarAINative

final class CUPermissionGuideTests: XCTestCase {

    // MARK: - 状态解析

    func testStateMapping() {
        XCTAssertEqual(CUPermissionGuide.state(of: true), .granted)
        XCTAssertEqual(CUPermissionGuide.state(of: false), .denied)
        XCTAssertEqual(CUPermissionGuide.state(of: nil), .unknown)
    }

    // MARK: - missing / allGranted

    func testMissingEmptyWhenAllGranted() {
        let s: [CUPermission: CUPermissionState] = [
            .accessibility: .granted, .screenCapture: .granted, .inputMonitoring: .granted,
        ]
        XCTAssertEqual(CUPermissionGuide.missing(s), [])
        XCTAssertTrue(CUPermissionGuide.allGranted(s))
    }

    func testMissingListsDeniedInDeclaredOrder() {
        let s: [CUPermission: CUPermissionState] = [
            .accessibility: .granted, .screenCapture: .denied, .inputMonitoring: .denied,
        ]
        XCTAssertEqual(CUPermissionGuide.missing(s), [.screenCapture, .inputMonitoring])
        XCTAssertFalse(CUPermissionGuide.allGranted(s))
    }

    func testMissingTreatsUnknownAsNeedingGuide() {
        let s: [CUPermission: CUPermissionState] = [
            .accessibility: .unknown, .screenCapture: .granted, .inputMonitoring: .granted,
        ]
        XCTAssertEqual(CUPermissionGuide.missing(s), [.accessibility])
    }

    func testMissingDefaultsToUnknownWhenStatusAbsent() {
        // 探针尚未跑（空字典）→ 三权限全列（引导先于状态）
        XCTAssertEqual(CUPermissionGuide.missing([:]),
                       [.accessibility, .screenCapture, .inputMonitoring])
    }

    // MARK: - 引导卡数据

    func testGuideItemsCompleteForEveryPermission() {
        for p in CUPermission.allCases {
            let item = CUPermissionGuide.guideItem(for: p, state: .denied)
            XCTAssertEqual(item.permission, p)
            XCTAssertEqual(item.state, .denied)
            XCTAssertFalse(item.title.isEmpty)
            XCTAssertFalse(item.purpose.isEmpty)
            XCTAssertFalse(item.consequence.isEmpty)
            XCTAssertGreaterThanOrEqual(item.steps.count, 3)
            XCTAssertTrue(item.canRequestInApp)
            // 每套步骤必含「复核刷新」收口指引（辅助功能流程末步为排障补充，故不定死末步）
            XCTAssertTrue(item.steps.contains { $0.contains("复核") })
        }
    }

    func testSettingsDeepLinksExactAnchors() {
        XCTAssertEqual(CUPermissionGuide.settingsDeepLink(for: .accessibility),
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        XCTAssertEqual(CUPermissionGuide.settingsDeepLink(for: .screenCapture),
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        XCTAssertEqual(CUPermissionGuide.settingsDeepLink(for: .inputMonitoring),
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    func testNeedsRestartTruthfulPerPermission() {
        // 如实口径：屏幕录制/输入监控授权须重启本应用生效（TCC 按进程启动时读取），
        // 辅助功能开关即刻生效——步骤文案同步含「重启」。
        XCTAssertFalse(CUPermissionGuide.needsRestart(for: .accessibility))
        XCTAssertTrue(CUPermissionGuide.needsRestart(for: .screenCapture))
        XCTAssertTrue(CUPermissionGuide.needsRestart(for: .inputMonitoring))
        XCTAssertFalse(CUPermissionGuide.steps(for: .accessibility).contains { $0.contains("重启") })
        XCTAssertTrue(CUPermissionGuide.steps(for: .screenCapture).contains { $0.contains("重启") })
        XCTAssertTrue(CUPermissionGuide.steps(for: .inputMonitoring).contains { $0.contains("重启") })
    }

    func testGuideItemTitlesChinese() {
        XCTAssertEqual(CUPermissionGuide.title(for: .accessibility), "辅助功能")
        XCTAssertEqual(CUPermissionGuide.title(for: .screenCapture), "屏幕录制")
        XCTAssertEqual(CUPermissionGuide.title(for: .inputMonitoring), "输入监控")
    }

    // MARK: - 顺序稳定性（引导展示序 = 声明序）

    func testAllCasesDeclaredOrder() {
        XCTAssertEqual(CUPermission.allCases,
                       [.accessibility, .screenCapture, .inputMonitoring])
    }

    // MARK: - M3（0.7.5 收口审查）：权限状态单一真源
    //
    // 修复前：探测区读 vm.cuCapabilities 缓存 facts、引导区 onAppear 直读 TCC——
    // 存在「A 显示 ✗ 未授权、B 显示 ✓ 已授权」同屏矛盾路径。修复后权限结论
    // 全页只走 CUPermissionStatusStore（probeStatuses 直读为唯一权威）。
    // 诚实边界：SwiftUI 同屏渲染不可 XCTest 断言；本层保证「单一来源 +
    // 任一刷新动作两消费面同刻失效」，矛盾路径在逻辑层封死。

    @MainActor
    func testM3_storeRefreshPublishesProbeSnapshot() {
        let snapshot: [CUPermission: CUPermissionState] = [
            .accessibility: .granted, .screenCapture: .denied, .inputMonitoring: .granted,
        ]
        let store = CUPermissionStatusStore(probe: { snapshot })
        XCTAssertEqual(store.statuses, [:], "首探前为空（消费侧按 unknown 呈现）")
        store.refresh()
        XCTAssertEqual(store.statuses, snapshot, "refresh 必须发布探针快照（唯一写入口）")
    }

    @MainActor
    func testM3_storeBoolStateMapping() {
        var granted = false
        let store = CUPermissionStatusStore(probe: {
            [.accessibility: granted ? .granted : .denied]
        })
        XCTAssertNil(store.boolState(for: .accessibility),
                     "未首探 → 三态 nil（？ 无法探测）")
        store.refresh()
        XCTAssertEqual(store.boolState(for: .accessibility), false, "denied → false（✗）")
        granted = true
        store.refresh()
        XCTAssertEqual(store.boolState(for: .accessibility), true, "granted → true（✓）")
    }

    @MainActor
    func testM3_singleSourceInvalidatesAllConsumersAtomically() {
        // 模拟报告触发路径：已探测（✗ 缓存）→ 用户去系统设置开权限 → 回页刷新。
        // 状态行（boolState）与引导卡（missing）是同源两消费面——refresh 后必须
        // 同刻翻转，不存在「一行 ✓ 一行 ✗」的单边陈旧窗口。
        var axGranted = false
        let store = CUPermissionStatusStore(probe: {
            [.accessibility: axGranted ? .granted : .denied,
             .screenCapture: .granted,
             .inputMonitoring: .granted]
        })
        store.refresh()
        XCTAssertEqual(store.boolState(for: .accessibility), false)
        XCTAssertEqual(CUPermissionGuide.missing(store.statuses), [.accessibility])

        axGranted = true   // 用户在系统设置完成授权
        store.refresh()    // 回页/按钮同刻刷新（生产接线：onAppear/检测权限/复核刷新）
        XCTAssertEqual(store.boolState(for: .accessibility), true)
        XCTAssertEqual(CUPermissionGuide.missing(store.statuses), [],
                       "单真源 refresh 后所有消费面必须一致——同屏矛盾路径封死")
    }
}
