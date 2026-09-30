//
//  SettingsCUView.swift
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

//  设置覆盖页「CU」分区：原版 CU 区设置项（SettingsPanel.tsx:82-221 ComputerUseSection）——
//  总开关 + 风险提示 / 每步确认 / 元素定位（0.4.32 E2）/ 应用白名单 / 权限探测。
//  V4 前本区嵌在「基础设置」分区中部（tsx 同构，SettingsPanel.tsx:732）；
//  V4 按设置覆盖页内部导航拆为独立分区（基础设置不再重复展示）。
//  CU 宏列表按用户拍板留在流程中心不动（tsx:214-216 内嵌 CuMacroPanel 的位置），
//  此处宏位置放「打开 CU 宏面板」跳转（关闭覆盖页并切到流程中心 → CU 宏）。
//

import SwiftUI

public struct SettingsCUView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var vmBox = SettingsViewModelBox()

    public init() {}

    public var body: some View {
        if let vm = vmBox.vm {
            SettingsCUBody(vm: vm, runtime: appState.runtime)
        } else {
            VLoadingView("设置加载中…")
                .task { vmBox.attach(appState: appState) }
        }
    }
}

private struct SettingsCUBody: View {
    @ObservedObject var vm: SettingsViewModel
    /// 直接观察 NativeRuntime（同 SettingsPanelView：AppState 不转发子服务变更，
    /// 侧车就绪后需自动重载配置）
    @ObservedObject var runtime: NativeRuntime

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let err = vm.errorMessage {
                    VCallout(.error, err)
                        .accessibilityIdentifier("settings.cu.errorCallout")   // DBG-160：与 SettingsPanelView 区分
                }
                if let msg = vm.message {
                    VCallout(.success, msg)
                        .accessibilityIdentifier("settings.cu.successCallout")   // DBG-160：与 SettingsPanelView 区分
                }

                if vm.config == nil {
                    if vm.errorMessage != nil {
                        VEmptyStateView(icon: "exclamationmark.triangle",
                                        title: "读取配置失败",
                                        message: "配置读取失败（内核或数据根不可用）。请稍后点「重新加载」重试。")
                        Button("重试") { Task { await vm.load() } }
                            .buttonStyle(.vSecondary)
                            .accessibilityIdentifier("settings.cu.retryButton")   // DBG-160：与 SettingsPanelView 区分
                    } else {
                        VLoadingView("加载配置中…")
                    }
                } else {
                    ComputerUseSection(vm: vm)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(VTheme.bgApp)
        .onAppear { vm.onAppear() }
        // P3-W6⑤：nativeReady 于 runtime init 同步点亮、任何视图出现前恒 true，
        // 旧「就绪自愈」onChange（永不触发）随侧车归零删除——首拉在挂载链路上。
    }
}

// MARK: - Computer Use（0.4.9 3.48.1 + 0.4.32 E2 + 宏跳转入口）

struct ComputerUseSection: View {
    @ObservedObject var vm: SettingsViewModel
    @EnvironmentObject private var appState: AppState
    /// M3 修复：CU 权限状态单一真源——权限结论行全页只此一份（下方引导区），
    /// 探测区不再读 vm.cuCapabilities 缓存渲染权限行（双口径同屏矛盾消解）。
    @StateObject private var cuPermStore = CUPermissionStatusStore()

    private var enabled: Bool { vm.config?.computerUseEnabled ?? false }

    var body: some View {
        SectionCard(title: "Computer Use（操作电脑）") {
            Toggle("允许 Agent 操作我的电脑（截屏 / 点击 / 键盘输入）", isOn: Binding(
                get: { enabled },
                set: { vm.saveBool(SidecarConfig.Key.computerUseEnabled, $0) }))
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("settings.cuEnabledToggle")
            HintText("⚠️ 开启后 Agent 能看到你的屏幕并真实操作鼠标键盘——误操作后果立即可见且可能难以撤销（删文件、发消息、点支付）。默认关闭。一期仅支持 macOS，全程本地不联网。建议保持\"每步确认\"开启，并用应用白名单限定可操作范围。")

            if enabled {
                Toggle("每步操作前都要我确认", isOn: Binding(
                    get: { vm.config?.computerUseConfirmEach ?? true },
                    set: { vm.saveBool(SidecarConfig.Key.computerUseConfirmEach, $0) }))
                    .toggleStyle(.checkbox)
                    .padding(.top, 10)
                    .accessibilityIdentifier("settings.cuConfirmEachToggle")
                HintText("强烈建议保持开启：每次点击/输入前弹窗告知\"在哪个应用、做什么动作、参数是什么\"，你同意才执行。关闭后 Agent 可连续自主操作，风险显著上升。")

                // 0.4.32（CU 二期 E2）：元素定位校正开关
                Toggle("元素定位（命中测试校正点击坐标）", isOn: Binding(
                    get: { vm.config?.cuElementLocateEnabled ?? true },
                    set: { vm.saveBool(SidecarConfig.Key.cuElementLocateEnabled, $0) }))
                    .toggleStyle(.checkbox)
                    .padding(.top, 10)
                    .accessibilityIdentifier("settings.cuElementLocateToggle")
                HintText("开启后（默认），点击前先用辅助功能命中测试取目标元素的精确位置再点——窗口挪动、界面缩放后仍能点准；未命中时自动回落原像素坐标（回落会如实记录）。关闭则回到一期纯像素点击。")

                // 应用白名单
                FormLabel("允许操作的应用白名单")
                let wl = vm.config?.computerUseAppWhitelist ?? []
                if wl.isEmpty {
                    HintText("（空 = 不限制应用，仍受\"每步确认\"约束）")
                }
                ForEach(wl, id: \.self) { app in
                    ListRow(text: app) { vm.removeWhitelistApp(app) }
                }
                ListAddRow(text: $vm.newWhitelistApp,
                           placeholder: "应用名，如 Finder / 预览 / 文本编辑",
                           addDisabled: vm.newWhitelistApp.trimmingCharacters(in: .whitespaces).isEmpty
                               || wl.contains(vm.newWhitelistApp.trimmingCharacters(in: .whitespaces))) {
                    vm.addWhitelistApp()
                }
                HintText("白名单非空时，只有前台应用命中名单才允许操作，越界一律拒绝（防 Agent 跑到别的应用里乱点）。")

                // 权限探测（防线1：门槛引导）——M3：按钮同刻刷新权限单真源，
                // 能力明细（非权限事实）仍走 vm.cuCapabilities（含真截屏自检，不随出现频刷）
                HStack(spacing: 8) {
                    Button {
                        Task {
                            await vm.probeCU()
                            cuPermStore.refresh()
                        }
                    } label: {
                        Text(vm.cuProbing ? "正在探测…"
                             : (vm.cuCapabilities == nil ? "检测权限" : "重新检测权限"))
                    }
                    .buttonStyle(.vSecondary)
                    .disabled(vm.cuProbing)
                    .accessibilityIdentifier("settings.cuProbeButton")
                }
                .padding(.top, 12)

                if let cap = vm.cuCapabilities {
                    capabilityFacts(cap)
                }

                // 0.7.5 W2（REQ-FUT-005）：引导式权限流程——三权限（辅助功能/
                // 屏幕录制/输入监控）状态 + 缺失分步引导（系统设置直达/请求授权/
                // 复核刷新）。纯逻辑见 CUPermissionGuide.swift。
                // M3：权限状态行全页唯一一套（单真源 cuPermStore，出现/按钮同刻刷新）。
                CUPermissionGuideView(store: cuPermStore)
                    .padding(.top, 12)

                // 0.4.32（CU 三期 P3）任务宏：tsx 在 CU 区底部内嵌 CuMacroPanel
                // （SettingsPanel.tsx:214-216）；用户已拍板 CU 宏留在流程中心不动，
                // 宏位置放「打开 CU 宏面板」跳转——关闭设置覆盖页并切到流程中心 → CU 宏。
                HStack(spacing: 8) {
                    Image(systemName: "desktopcomputer")
                        .foregroundStyle(VTheme.textTertiary)
                    Text("任务宏（录制 / 回放 / 命中率）在「流程中心 → CU 宏」面板")
                        .font(VTheme.Typo.caption)
                        .foregroundStyle(VTheme.textSecondary)
                    Button("打开 CU 宏面板") {
                        appState.closeSettings()
                        if let panel = PanelRegistry.panel(forKey: "cu-macro") {
                            appState.selectPanel(panel)
                        }
                    }
                    .buttonStyle(.vSecondary)
                    .controlSize(.small)
                    .accessibilityIdentifier("settings.cuMacroJump")
                }
                .padding(.top, 12)
            }
        }
        // tsx：useEffect(() => { if (enabled && !cap) probe(); }, [enabled, cap])
        // M3：权限单真源随出现即刷新（只读状态位，零副作用）；能力探测仍首探口径
        .task(id: enabled) {
            if enabled {
                cuPermStore.refresh()
                if vm.cuCapabilities == nil && !vm.cuProbing {
                    await vm.probeCU()
                }
            }
        }
    }

    /// 探测结果明细（tsx facts 展示块）。M3：权限结论行/problems 摘出本区——
    /// 权限状态只由引导区单真源呈现，本区仅留非权限能力事实（屏幕/前台应用/
    /// CoreGraphics 接口），杜绝「缓存 ✗ vs 直读 ✓」同屏矛盾。
    @ViewBuilder
    private func capabilityFacts(_ cap: CUCapabilities) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let v = cap.factString("frontmost_app") {
                factLine("前台应用：\(v)")
            }
            if let v = cap.factString("screen_points") {
                factLine("屏幕逻辑尺寸：\(v) 点")
            }
            if let v = cap.factString("screenshot_px") {
                factLine("截屏分辨率：\(v) px")
            }
            if let v = cap.factString("retina_scale") {
                factLine("Retina 缩放：\(v)x（点击坐标已自动换算）")
            }
            factLine("CoreGraphics 接口：\(cap.factString("coregraphics") ?? "未探测")")
            Text("· 无需安装任何第三方工具（用系统内置 screencapture + JXA/CoreGraphics）。")
                .font(VTheme.Typo.caption)
                .foregroundStyle(VTheme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VTheme.bgSidebar, in: RoundedRectangle(cornerRadius: VTheme.Radius.s))
        .padding(.top, 8)
    }

    private func factLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(VTheme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
