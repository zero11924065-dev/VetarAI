//
//  TaskPanelView.swift
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

//  任务队列面板（对标 subagent/renderer/src/panels/TaskPanel.tsx，446 行）：
//    · 标题行：「委派任务（最近30条）」+ 实时流连接指示圆点 + 手动刷新
//    · 提示条：错误 / 重试结果 / 停止结果（后两者 6s 自动消隐）
//    · 任务卡：状态徽标（等待中/进行中/完成/异常）+ 目标 Agent + 已耗时 +
//      停止（running）/ 重试（failed）/ 查看（跳转委派会话）+ 任务摘要 +
//      实时进度（工具调用/轮次/字数，仅进行中显示）+ 失败原因 / 完成摘要 / 上下文用量
//  文案与数值逐字对齐现状实现；视觉用 VTheme 近似（接入指南 §3）。
//

import SwiftUI

public struct TaskPanelView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var vmBox = TaskPanelViewModelBox()

    public init() {}

    public var body: some View {
        // 与 ChatPanelView 同一 Box 模式：StateObject 构建早于 environmentObject 注入
        if let vm = vmBox.vm {
            TaskPanelBody(vm: vm)
        } else {
            VLoadingView("任务面板初始化…")
                .task { vmBox.attach(appState: appState) }
        }
    }
}

/// 延迟构建 TaskPanelViewModel（需要已注入的 AppState）。
@MainActor
final class TaskPanelViewModelBox: ObservableObject {
    @Published var vm: TaskPanelViewModel?
    func attach(appState: AppState) {
        if vm == nil { vm = TaskPanelViewModel(appState: appState) }
    }
}

private struct TaskPanelBody: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var vm: TaskPanelViewModel

    var body: some View {
        Group {
            if appState.currentProjectId == nil {
                // 现行导航口径：项目/Agent 在智能中心侧栏（单栏堆叠）选择，
                // 不存在「会话」面板——文案与 RootView 引导空态同一口径
                VEmptyStateView(
                    icon: "folder",
                    title: "未选择项目",
                    message: "委派任务挂在项目下；请先在左侧选择项目和 Agent。"
                )
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { vm.start() }
        .onDisappear { vm.stop() }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // ── 面板标题行 ──
                HStack(spacing: 6) {
                    Text("委派任务（最近30条）")
                        .font(VTheme.Typo.panelTitle)
                        .foregroundStyle(VTheme.textSecondary)
                    // 实时流连接指示（绿=实时进度已连接；灰=未连接，点刷新兜底）
                    Circle()
                        .fill(vm.streamOn ? VTheme.ok : VTheme.borderStrong)
                        .frame(width: 6, height: 6)
                        .help(vm.streamOn ? "实时进度已连接" : "实时流未连接，请点击刷新")
                        .accessibilityIdentifier("taskStreamIndicator")
                    Spacer()
                    Button { vm.reload() } label: {
                        HStack(spacing: 4) {
                            if vm.loading {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text(vm.loading ? "刷新中…" : "刷新")
                        }
                        .font(VTheme.Typo.caption)
                    }
                    .buttonStyle(.vGhost)
                    .controlSize(.small)
                    .disabled(vm.loading)
                    .accessibilityIdentifier("taskRefreshButton")
                }
                .padding(.bottom, 6)

                // ── 提示条（错误 / 重试 / 停止）──
                if let error = vm.error {
                    VCallout(.error, error).padding(.bottom, 6)
                }
                if let msg = vm.retryMsg {
                    VCallout(.warn, msg).padding(.bottom, 6)
                }
                if let msg = vm.stopMsg {
                    VCallout(.warn, msg).padding(.bottom, 6)
                }

                // ── 加载中 / 空态 ──
                if vm.loading && vm.tasks.isEmpty {
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.regular)
                        Text("加载中…")
                            .font(VTheme.Typo.caption)
                            .foregroundStyle(VTheme.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else if vm.tasks.isEmpty && vm.error == nil {
                    VStack(spacing: 8) {
                        Image(systemName: "clipboard")
                            .font(.system(size: 30))
                            .foregroundStyle(VTheme.borderStrong)
                        Text("暂无委派任务")
                            .font(VTheme.Typo.body)
                            .foregroundStyle(VTheme.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }

                // ── 任务卡列表 ──
                ForEach(vm.tasks) { task in
                    TaskCardView(task: task, vm: vm)
                        .padding(.bottom, 8)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - 状态徽标（配色对齐 TaskPanel.tsx STATUS_BADGE，规范 §6.3）

private struct StatusBadgeStyle {
    let bg: Color
    let fg: Color
    let dot: Color
    let label: String
}

private func statusBadge(_ status: String) -> StatusBadgeStyle {
    switch status {
    case "running":
        return StatusBadgeStyle(bg: VTheme.accentBg, fg: VTheme.accentTextDeep,
                                dot: VTheme.accent, label: "进行中")
    case "done":
        return StatusBadgeStyle(bg: VTheme.okBg, fg: VTheme.okText,
                                dot: VTheme.ok, label: "完成")
    case "failed":
        return StatusBadgeStyle(bg: VTheme.dangerBg, fg: VTheme.dangerText,
                                dot: VTheme.danger, label: "异常")
    default:   // queued 及未知状态回落（前端 STATUS_BADGE[t.status] || queued）
        return StatusBadgeStyle(bg: VTheme.bgHover, fg: VTheme.textSecondary,
                                dot: VTheme.textTertiary, label: "等待中")
    }
}

// MARK: - 任务卡

private struct TaskCardView: View {
    let task: AgentTask
    @ObservedObject var vm: TaskPanelViewModel

    var body: some View {
        let sb = statusBadge(task.status)
        VStack(alignment: .leading, spacing: 4) {
            // 头行：徽标 + 目标 Agent + 已耗时 / 操作按钮
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Circle().fill(sb.dot).frame(width: 6, height: 6)
                    Text(sb.label)
                }
                .font(VTheme.Typo.micro)
                .foregroundStyle(sb.fg)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(sb.bg, in: Capsule())

                HStack(spacing: 2) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11))
                    Text(task.target_agent_name)
                        .font(VTheme.Typo.body)
                }
                .foregroundStyle(VTheme.textPrimary)
                .lineLimit(1)

                Spacer(minLength: 4)

                if task.isActive, let elapsed = TaskElapsed.elapsed(createdAt: task.created_at, now: vm.now) {
                    HStack(spacing: 3) {
                        Image(systemName: "clock").font(.system(size: 11))
                        Text(elapsed)
                    }
                    .font(VTheme.Typo.micro)
                    .foregroundStyle(VTheme.textTertiary)
                }

                if task.status == "running" {
                    Button { vm.stopTask(task.id) } label: {
                        HStack(spacing: 4) {
                            if vm.stoppingId == task.id {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "stop.circle")
                            }
                            Text(vm.stoppingId == task.id ? "停止中…" : "停止")
                        }
                        .font(VTheme.Typo.caption)
                    }
                    .buttonStyle(.vSecondary)
                    .controlSize(.small)
                    .tint(VTheme.dangerText)
                    .disabled(vm.stoppingId != nil)
                    .help("停止该委派任务")
                    .accessibilityIdentifier("taskStopButton.\(task.id)")
                }
                if task.status == "failed" {
                    Button { vm.retry(taskId: task.id) } label: {
                        HStack(spacing: 4) {
                            if vm.retryingId == task.id {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text(vm.retryingId == task.id ? "重试中…" : "重试")
                        }
                        .font(VTheme.Typo.caption)
                    }
                    .buttonStyle(.vSecondary)
                    .controlSize(.small)
                    .disabled(vm.retryingId != nil)
                    .accessibilityIdentifier("taskRetryButton.\(task.id)")
                }
                if task.target_agent_id != nil {
                    Button { vm.jumpToAgent(task) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.right")
                            Text("查看")
                        }
                        .font(VTheme.Typo.caption)
                    }
                    .buttonStyle(.vGhost)
                    .controlSize(.small)
                    .help("打开该子 Agent 的委派会话")
                    .accessibilityIdentifier("taskJumpButton.\(task.id)")
                }
            }

            // 任务摘要（空白折叠 + 40 字截断，两行截断；对齐 brief 规则）
            Text(brief)
                .font(VTheme.Typo.caption)
                .foregroundStyle(VTheme.textSecondary)
                .lineLimit(2)

            // 实时进度（SSE 增量；只在任务进行中显示，终态交给 DB 字段）
            if task.isActive, let p = vm.live[task.id] {
                HStack(spacing: 6) {
                    if let tool = p.toolName, !tool.isEmpty {
                        HStack(spacing: 3) {
                            if let ok = p.toolOk {
                                Image(systemName: ok ? "checkmark" : "xmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(ok ? VTheme.okText : VTheme.dangerText)
                            } else {
                                ProgressView().controlSize(.mini)
                            }
                            Text(p.toolOk == nil ? "正在调用 \(tool)" : tool)
                                .foregroundStyle(VTheme.textSecondary)
                        }
                    }
                    if let step = p.step {
                        Text(p.max.map { "第 \(step)/\($0) 轮" } ?? "第 \(step) 轮")
                    }
                    if let chars = p.chars, chars > 0 {
                        Text("已生成 \(chars) 字")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(VTheme.textTertiary)
                .accessibilityIdentifier("taskLiveProgress.\(task.id)")
            }

            if task.status == "failed", let reason = task.fail_reason, !reason.isEmpty {
                Text("原因：\(reason)")
                    .font(VTheme.Typo.caption)
                    .foregroundStyle(VTheme.dangerText)
            }
            if task.status == "done", let summary = task.report?.summary, !summary.isEmpty {
                Text("摘要：\(String(summary.prefix(60)))")
                    .font(VTheme.Typo.caption)
                    .foregroundStyle(VTheme.okText)
            }
            if task.status == "done", let n = task.report?.prompt_eval_count, n > 0 {
                Text("上下文用量：\(n) tokens")
                    .font(.system(size: 11))
                    .foregroundStyle(VTheme.textTertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(VTheme.bgCard, in: RoundedRectangle(cornerRadius: VTheme.Radius.m))
        .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.m).stroke(VTheme.borderDefault))
    }

    /// brief = task 折叠空白后前 40 字，超长补 "…"（对齐 TaskPanel.tsx；
    /// 注意省略号判定用原始 task 长度，非折叠后长度——逐字保留现状边界行为）。
    private var brief: String {
        let collapsed = task.task.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let head = String(collapsed.prefix(40))
        return task.task.count > 40 ? head + "…" : head
    }
}
