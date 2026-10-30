//
//  CuMacroPanelView.swift
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

//  CU 任务宏面板（对标 subagent/renderer/src/panels/CuMacroPanel.tsx，487 行；
//  0.4.32–0.4.34 最新形态；图2 两板块单栏化后宏列表迁去流程中心侧栏手风琴）：
//    · 双模式说明 hint（录什么 / 不录什么 / 产物去向）
//    · 错误条（error）/ 0 步停止警告条（warn）/ 输入监控未授权引导条（warn + 请求授权按钮）
//    · 录制控制：录制中 = info 条（正在录制「名」+ 双模式明细…已捕获 N 步 + 停止并保存）；
//      未录制 = 名称输入 + 「录制 Agent 操作」/「录制我的操作」双入口
//    · 命中率行（回放口径）+ 口径说明
//    · 回放进度卡（进度条 / 当前步骤 + 命中方式徽标 / error·done 终态条）
//    · 选中宏详情卡（名称、时间·步数 + 回放（空宏置灰）+ 删除；未选中 = 引导空态）
//  文案逐字对齐现状实现；视觉用 VTheme 近似（接入指南 §3）。
//
//  ViewModel 走 WorkflowCenterState 共享单例（侧栏「CU 宏」手风琴列表与本面板同源；
//  attach/detach 计数生命周期替代原 Box 延迟构建 + start/stop）。
//

import SwiftUI

public struct CuMacroPanelView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var center: WorkflowCenterState

    public init() {}

    public var body: some View {
        if let vm = center.cuMacroVM {
            CuMacroPanelBody(vm: vm, runtime: appState.runtime)
        } else {
            VLoadingView("CU 宏面板初始化…")
        }
    }
}

private struct CuMacroPanelBody: View {
    @ObservedObject var vm: CuMacroPanelViewModel
    /// 直接观察 NativeRuntime（AppState 不转发子服务发布；历史上经 appState.sidecar 读不触发刷新）
    @ObservedObject var runtime: NativeRuntime

    private var hintFont: Font { VTheme.Typo.micro }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                // ── 面板标题 + 双模式说明 ──
                Text("任务宏（操作录制与回放）")
                    .font(VTheme.Typo.sectionTitle)
                    .foregroundStyle(VTheme.textPrimary)
                Text("录制 Agent 操作：记录 Agent 自己发起的 CU 动作（语义化步骤）；回放时逐步重新定位执行，窗口挪动后仍能命中。")
                    .font(hintFont)
                    .foregroundStyle(VTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("录制我的操作：记录你的鼠标点击与键盘输入（密码框内容不会被记录）；录制产物与 Agent 宏同格式，可回放、可交给 Agent 使用。")
                    .font(hintFont)
                    .foregroundStyle(VTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                // ── 错误条（含 409 互斥 detail 原文上屏）──
                if let error = vm.error {
                    VCallout(.error, error)
                        .accessibilityIdentifier("cuMacroErrorCallout")
                }

                // ── 0.4.33 F2：0 步停止警告（warn 而非 error——动作本身成功，只是没有可保存的内容）──
                if let warn = vm.warn {
                    VCallout(.warn, warn)
                        .accessibilityIdentifier("cuMacroWarnCallout")
                }

                // ── R4：输入监控未授权引导（录制中不显示）──
                if vm.permDenied && !vm.recording {
                    // 方向2 波次2：逐字段手写复制 VCallout 外观收编回库——warn 外观 +
                    // accessory 尾随槽承载双按钮（原版 :73-104）；vSecondary 上的
                    // .controlSize(.small) 属死代码（自定义样式不响应），随收编删除
                    VCallout(.warn, "录制我的操作需要「输入监控」权限。请前往 系统设置 → 隐私与安全性 → 输入监控 为本应用开启；或点击「请求授权」由系统发起授权。") {
                        // 0.7.5 W2：补「打开系统设置」直达钮（与设置-CU 页引导同深链）
                        Button("打开系统设置") {
                            CUPermissionRequest.openSystemSettings(for: .inputMonitoring)
                        }
                        .buttonStyle(.vSecondary)
                        .accessibilityIdentifier("cuMacroPermissionOpenSettingsButton")
                        Button(vm.permBusy ? "正在请求…" : "请求授权") {
                            vm.requestPermission()
                        }
                        .buttonStyle(.vSecondary)
                        .disabled(vm.permBusy)
                        .accessibilityIdentifier("cuMacroPermissionRequestButton")
                    }
                    .accessibilityIdentifier("cuMacroPermissionCallout")
                }

                // ── 录制控制 ──
                if vm.recording {
                    // 方向2 波次2：逐字段手写复制 VCallout 外观收编回库——info 外观 +
                    // accessory 尾随槽承载明细行+停止钮（原版 :107-134）；vPrimary 上的
                    // .controlSize(.small) 死代码随收编删除；stop 图标 9pt → 11pt（原版 :118）
                    VCallout(.info, recordingTitle) {
                        Text(recordingDetail)
                            .font(VTheme.Typo.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            vm.stopRecord()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 11))
                                Text("停止并保存")
                            }
                        }
                        .buttonStyle(.vPrimary)
                        .disabled(vm.busy)
                        .accessibilityIdentifier("cuMacroStopButton")
                    }
                    .accessibilityIdentifier("cuMacroRecordingCallout")
                } else {
                    HStack(spacing: 6) {
                        TextField("宏名称，如 每日晨间整理", text: $vm.recName)
                            .textFieldStyle(.plain)
                            .vInputStyle()
                            .onSubmit { vm.startRecord() }
                            .accessibilityIdentifier("cuMacroNameField")
                        Button("录制 Agent 操作") { vm.startRecord() }
                            .buttonStyle(.vSecondary)
                            .disabled(vm.busy || vm.runActive
                                      || vm.recName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("cuMacroStartAgentButton")
                        Button("录制我的操作") { vm.startUserRecord() }
                            .buttonStyle(.vSecondary)
                            .disabled(vm.busy || vm.runActive
                                      || vm.recName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("cuMacroStartUserButton")
                    }
                }

                // ── 元素定位命中率（回放口径）──
                hitRateLine
                // ── 命中率全程审计（0.7.4 W5，进程内运行记录聚合口径）──
                if let sel = vm.selected, let a = vm.audit[sel.id] {
                    Text("审计口径：回放 \(a.replays) 次 · 成功 \(a.successes) 次 · 元素命中 \(a.element_hits) / 像素回落 \(a.pixel_fallbacks)")
                        .font(VTheme.Typo.caption)
                        .foregroundStyle(VTheme.textTertiary)
                        .accessibilityIdentifier("cuMacroAuditLine")
                }
                Text("口径：仅统计最近一次回放的点击步骤（element=元素命中，pixel_fallback=回落像素）；日常每次点击的全程审计见数据目录 computer_use/actions.jsonl。")
                    .font(hintFont)
                    .foregroundStyle(VTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                // ── 回放进度卡 ──
                if let run = vm.run {
                    ReplayRunCard(run: run)
                }

                // ── 选中宏详情卡（图2：宏列表迁去侧栏手风琴，此处只显示选中宏）──
                if let macro = vm.selected {
                    SelectedMacroCard(macro: macro, vm: vm)
                } else {
                    // 引导空态（未选中任何宏）
                    // 方向2 波次2：手写空态收编 VEmptyStateView（原版 :181-191）
                    VEmptyStateView(icon: "desktopcomputer",
                                    title: "未选择宏",
                                    message: "在左侧选择一个宏，或开始录制新宏")
                        .padding(.vertical, 20)
                        .accessibilityIdentifier("cuMacroEmptySelection")
                }
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 双挂载点计数生命周期：侧栏手风琴列表与本面板任一存活则轮询不停
        .onAppear { vm.attach() }
        .onDisappear { vm.detach() }
        // 侧车就绪自愈：面板先于侧车打开时首拉失败，就绪后自动补拉
        // P3-W6⑤：nativeReady 于 runtime init 同步点亮、任何视图出现前恒 true，
        // 旧「就绪自愈」onChange（永不触发）随侧车归零删除——首拉在挂载链路上。
    }

    /// R4：录制进行态双文案（recording_mode 分叉；停止按钮两模式同一）
    /// 方向2 波次2：原「● 正在录制…」五段单 Text 拆分层级（去 ● 装饰点，
    /// 原版 :206-213）——主行 = 状态词+名称，进 VCallout 主文案；
    /// 明细行 = 模式+已捕获步数+模式说明，进 accessory 列。
    private var recordingTitle: String {
        vm.recordingName.isEmpty ? "正在录制" : "正在录制「\(vm.recordingName)」"
    }

    private var recordingDetail: String {
        let modePart = vm.recordingMode == .user ? "录制我的操作中" : "录制 Agent 操作中"
        let tailPart = vm.recordingMode == .user
            ? "——你的鼠标点击与键盘输入会记为一步"
            : "——此后 Agent 的每个 CU 动作都会记为一步"
        return "\(modePart)…已捕获 \(vm.recordingSteps) 步\(tailPart)"
    }

    private var hitRateLine: some View {
        let hr = CuMacroPanelViewModel.hitRate(steps: vm.run?.steps ?? [])
        return HStack(spacing: 4) {
            Text("元素定位命中率（回放口径）：")
            if let percent = hr.percent {
                // 方向2 波次2：英文契约键（element/pixel_fallback）不上屏，走既有
                // methodLabels 人话映射（原版 :220；与 :308 MethodBadge 同源）
                Text("\(percent)%（\(CuMacroPanelViewModel.methodLabels["element"] ?? "element") \(hr.element) / \(CuMacroPanelViewModel.methodLabels["pixel_fallback"] ?? "pixel_fallback") \(hr.pixelFallback)，样本 \(hr.element + hr.pixelFallback)）")
                    .fontWeight(.bold)
                    .foregroundStyle(VTheme.textPrimary)
            } else {
                Text("暂无回放样本")
                    .foregroundStyle(VTheme.textTertiary)
            }
        }
        .font(VTheme.Typo.caption)
        .foregroundStyle(VTheme.textSecondary)
        .accessibilityIdentifier("cuMacroHitRate")
    }
}

// MARK: - 回放进度卡（进度条 / 当前步骤 / 终态条）

private struct ReplayRunCard: View {
    let run: CuReplayRun

    private var lastStep: CuReplayStep? { run.steps.last }
    private var pct: Int { CuMacroPanelViewModel.progressPercent(run: run) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("回放「\(run.macro_name.isEmpty ? run.macro_id : run.macro_name)」")
                Spacer()
                Text("进度 \(run.completed)/\(run.total)")
            }
            .font(VTheme.Typo.caption)
            .foregroundStyle(VTheme.textSecondary)

            // 进度条（error = 红，其余 = 强调色）
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(VTheme.borderDefault)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(run.status == "error" ? VTheme.danger : VTheme.accent)
                        .frame(width: geo.size.width * CGFloat(pct) / 100)
                }
            }
            .frame(height: 4)
            // 方向2 波次2：动效字面量归 Motion.panel 令牌（原版 :263）
            .animation(VTheme.Motion.panel, value: pct)

            // 当前步骤 = 已登记的最后一步（运行中它就是刚执行的那步）
            if let step = lastStep {
                HStack(spacing: 6) {
                    Text("第 \(step.seq) 步 \(step.action)")
                        // 方向2 波次2：12 手写 mono 归 Typo.mono 令牌（原版 :269；步骤动作名为数据身份段）
                        .font(VTheme.Typo.mono)
                        .foregroundStyle(VTheme.textSecondary)
                    MethodBadge(method: step.method)
                    if !step.ok {
                        Text("失败")
                            .font(VTheme.Typo.caption)
                            .foregroundStyle(VTheme.dangerText)
                    }
                }
            }

            if run.status == "error" {
                VCallout(.error, "回放中止\(run.failed_seq != nil ? "：第 \(run.failed_seq!) 步失败" : "")\(run.error.isEmpty ? "" : "——\(run.error)")")
            }
            if run.status == "done" {
                VCallout(.success, "回放完成：\(run.completed)/\(run.total) 步成功")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        // 方向2 波次2：bgSidebar 当内容卡底 → bgCard（原版 :289）
        .background(VTheme.bgCard, in: RoundedRectangle(cornerRadius: VTheme.Radius.s))
        .accessibilityIdentifier("cuMacroReplayCard")
    }
}

/// 命中方式徽标（语义色令牌：element=成功，回落=警告，中止=危险，其余中性）。
private struct MethodBadge: View {
    let method: String

    private var colors: (bg: Color, fg: Color) {
        switch method {
        case "element": return (VTheme.okBg, VTheme.okText)
        case "pixel_fallback": return (VTheme.warnBg, VTheme.warnText)
        case "abort": return (VTheme.dangerBg, VTheme.dangerText)
        default: return (VTheme.bgHover, VTheme.textSecondary)
        }
    }

    var body: some View {
        Text(CuMacroPanelViewModel.methodLabels[method] ?? method)
            // 方向2 波次2：11 medium 手写归 Typo.micro 令牌（原版 :309）
            .font(VTheme.Typo.micro.weight(.medium))
            .foregroundStyle(colors.fg)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(colors.bg, in: Capsule())
    }
}

// MARK: - 选中宏详情卡（名称、时间·步数、回放（空宏置灰）、删除；按钮逻辑沿用原宏行）

private struct SelectedMacroCard: View {
    let macro: CuMacroSummary
    @ObservedObject var vm: CuMacroPanelViewModel

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(macro.name)
                    .font(VTheme.Typo.body)
                    .foregroundStyle(VTheme.textPrimary)
                Text("\(macro.created_at) · \(macro.steps) 步")
                    .font(VTheme.Typo.micro)
                    .foregroundStyle(VTheme.textTertiary)
            }
            Spacer(minLength: 4)
            Button {
                vm.startReplay(macro)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "play.fill")
                        // 方向2 波次2：9pt 图标 → 11pt（原版 :338）
                        .font(.system(size: 11))
                    Text("回放")
                }
            }
            .buttonStyle(.vSecondary)
            // 0.4.33 F2 空宏防护：steps==0 置灰 + 提示「宏没有步骤」
            .disabled(vm.busy || vm.runActive || vm.recording || macro.steps <= 0)
            .help(macro.steps <= 0 ? "宏没有步骤" : "")
            .accessibilityIdentifier("cuMacroReplayButton.\(macro.id)")
            Button {
                vm.delete(macro)
            } label: {
                Image(systemName: "trash")
            }
            // 方向2 波次2：vGhost+外层 dangerText 是死代码（内层覆盖）——
            // 改 vGhostDanger 染色在样式本体生效；.controlSize(.small) 死代码随删（原版 :354-356）
            .buttonStyle(.vGhostDanger)
            .disabled(vm.busy)
            .help("删除宏")
            // 方向2 波次4：AX 补账
            .accessibilityLabel("删除宏")
            .accessibilityIdentifier("cuMacroDeleteButton.\(macro.id)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        // 方向2 波次2：bgSidebar 当内容卡底 → bgCard（与回放进度卡同批收编，原版 :363）
        .background(VTheme.bgCard, in: RoundedRectangle(cornerRadius: VTheme.Radius.s))
        // DBG-160：容器不挂 id（内有 cuMacroReplayButton.*/cuMacroDeleteButton.* 叶子 id）
    }
}
