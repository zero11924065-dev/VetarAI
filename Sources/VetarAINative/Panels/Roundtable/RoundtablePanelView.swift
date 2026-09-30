//
//  RoundtablePanelView.swift
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

//  圆桌面板手风琴内容（左栏：创建 + 列表；对标 RoundtablePanel.tsx 269 行）：
//    · 创建区：议题输入 / 参与者 chips（点选切换）/ 用户主持·AI 主持单选
//      （AI 主持时下拉限选已勾参与者）/ 轮数 2~10 / 议题附件（NSOpenPanel 选文本文件，
//      ≤5 个、单个 ≤2MB）/ 「开始讨论」（创建中禁用防连点）
//    · 列表区：状态徽标（讨论中/等待用户/待确认结束/已结束/异常）+ 轮次 + 主持方式 +
//      议题（40 字截断）；点击卡片 → 右侧大屏详情（RoundtableDetailView）
//    · 空态「暂无圆桌讨论」；错误提示条
//  V1（智能中心侧栏单栏堆叠复刻）：整页面板壳移除——本文件只提供手风琴展开区
//  内容视图 `RoundtableListContentView`（原版 RoundtablePanel 只输出创建+列表，
//  手风琴头由 App.tsx:270-279 统一渲染；选中即右侧大屏详情，App.tsx:320-328）。
//  VM 为 IntelligenceCenterState 持有的共享 RoundtablePanelViewModel（手风琴列表与
//  内容区大屏双挂载点，attach/detach 计数生命周期）。
//  文案与数值逐字对齐现状实现；视觉用 VTheme 近似（接入指南 §3）。
//

import SwiftUI
import UniformTypeIdentifiers

/// 圆桌手风琴展开区内容（原版 RoundtablePanel.tsx:137-268 整段：创建区 + 列表区）。
/// VM 由 IntelligenceCenterState 共享注入；attach/detach 由侧栏分区与详情大屏驱动。
struct RoundtableListContentView: View {
    @ObservedObject var vm: RoundtablePanelViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            createSection
                .padding(.bottom, 8)

            if let error = vm.error {
                VCallout(.error, error).padding(.bottom, 6)
            }

            if vm.roundtables.isEmpty && vm.error == nil {
                VStack(spacing: 8) {
                    Image(systemName: "mic")
                        .font(.system(size: 30))
                        .foregroundStyle(VTheme.borderStrong)
                    Text("暂无圆桌讨论")
                        .font(VTheme.Typo.body)
                        .foregroundStyle(VTheme.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            }

            ForEach(vm.roundtables) { rt in
                RoundtableRowCard(rt: rt, isSelected: vm.selectedId == rt.id)
                    .contentShape(Rectangle())
                    .onTapGesture { vm.select(rt.id) }
                    .padding(.bottom, 8)
                    .accessibilityIdentifier("rtItem.\(rt.id)")
            }
        }
        // 原版手风琴内容 padding: '8px 12px'（RoundtablePanel.tsx:138）
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: 创建区

    private var createSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("输入讨论议题…", text: $vm.topic)
                .textFieldStyle(.plain)
                .vInputStyle()
                .accessibilityIdentifier("rtTopicInput")

            Text("参与者（至少 2 个）：")
                .font(VTheme.Typo.caption)
                .foregroundStyle(VTheme.textSecondary)
            FlowLayout(spacing: 6) {
                ForEach(vm.agents, id: \.id) { agent in
                    let selected = vm.selectedAgentIds.contains(agent.id)
                    Text(agent.name + (agent.role.map { "（\($0)）" } ?? ""))
                        .font(VTheme.Typo.caption)
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .background(selected ? VTheme.accentBg : VTheme.bgHover, in: Capsule())
                        .foregroundStyle(selected ? VTheme.accentText : VTheme.textSecondary)
                        .contentShape(Capsule())
                        .onTapGesture { vm.toggleAgent(agent.id) }
                        .accessibilityIdentifier("rtAgentChip.\(agent.id)")
                }
            }

            HStack(spacing: 10) {
                // 主持人单选（对齐两个 radio label）
                Button { vm.moderator = "user" } label: {
                    HStack(spacing: 3) {
                        Image(systemName: vm.moderator == "user" ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 12))
                        Text("用户主持")
                    }
                    .font(VTheme.Typo.body)
                    .foregroundStyle(VTheme.textPrimary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("rtModeratorUser")

                Button { vm.moderator = "ai" } label: {
                    HStack(spacing: 3) {
                        Image(systemName: vm.moderator == "ai" ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 12))
                        Text("AI 主持：")
                    }
                    .font(VTheme.Typo.body)
                    .foregroundStyle(VTheme.textPrimary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("rtModeratorAI")

                if vm.moderator == "ai" {
                    Picker(selection: $vm.moderatorAgentId) {
                        Text("选择主持人…").tag("")
                        ForEach(vm.moderatorCandidates, id: \.id) { agent in
                            Text(agent.name).tag(agent.id)
                        }
                    } label: { EmptyView() }
                    .labelsHidden()
                    .frame(maxWidth: 160)
                    .accessibilityIdentifier("rtModeratorPicker")
                }

                Stepper(value: $vm.maxRounds, in: 2...10) {
                    HStack(spacing: 3) {
                        Text("轮数")
                        Text("\(vm.maxRounds)")
                            .monospacedDigit()
                    }
                    .font(VTheme.Typo.body)
                    .foregroundStyle(VTheme.textPrimary)
                }
                .accessibilityIdentifier("rtMaxRounds")

                Spacer()

                Button { vm.create() } label: {
                    HStack(spacing: 4) {
                        if vm.creating { ProgressView().controlSize(.mini) }
                        Text(vm.creating ? "进行中…" : "开始讨论")
                    }
                    .font(VTheme.Typo.caption)
                }
                .buttonStyle(.vPrimary)
                .controlSize(.small)
                .disabled(vm.creating)
                .accessibilityIdentifier("rtCreateButton")
            }

            // ── 议题附件（H18-3：提供文件材料作为讨论依据）──
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Button { pickAttachments() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "paperclip")
                            Text("添加参考材料（可选）")
                        }
                        .font(VTheme.Typo.caption)
                    }
                    .buttonStyle(.vGhost)
                    .controlSize(.small)
                    .disabled(vm.creating)
                    .accessibilityIdentifier("rtAttachButton")
                    Text("文本文件将作为讨论依据")
                        .font(VTheme.Typo.micro)
                        .foregroundStyle(VTheme.textTertiary)
                }
                if !vm.pendingAttachments.isEmpty {
                    FlowLayout(spacing: 4) {
                        ForEach(Array(vm.pendingAttachments.enumerated()), id: \.offset) { index, att in
                            HStack(spacing: 4) {
                                Image(systemName: "doc")
                                    .foregroundStyle(VTheme.textTertiary)
                                Text(att.name.count > 18 ? String(att.name.prefix(18)) + "…" : att.name)
                                    .foregroundStyle(VTheme.textPrimary)
                                Button { vm.removeAttachment(at: index) } label: {
                                    Image(systemName: "xmark")
                                        .foregroundStyle(VTheme.textTertiary)
                                }
                                .buttonStyle(.plain)
                                .help("移除附件")
                            }
                            .font(VTheme.Typo.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(VTheme.bgHover, in: RoundedRectangle(cornerRadius: VTheme.Radius.s))
                            .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.s).stroke(VTheme.borderSubtle))
                        }
                    }
                }
            }
            .padding(.top, 6)
            .overlay(alignment: .top) {
                Rectangle().fill(VTheme.borderSubtle).frame(height: 1)
                    .overlay(Rectangle().fill(VTheme.bgApp).frame(height: 1).offset(y: 0.5))
            }
        }
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(VTheme.borderSubtle).frame(height: 1)
        }
    }

    /// NSOpenPanel 选议题附件（对齐 accept 白名单扩展名；读为 Data → VM 做上限校验与 base64）。
    private func pickAttachments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        let exts = ["txt", "md", "csv", "json", "js", "ts", "py", "html", "css", "log", "xml", "yml", "yaml"]
        panel.allowedContentTypes = exts.compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK else { return }
        var files: [(name: String, data: Data)] = []
        for url in panel.urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) {
                files.append((name: url.lastPathComponent, data: data))
            }
        }
        vm.addAttachments(files)
    }
}

// MARK: - 列表卡片（对齐 RoundtablePanel.tsx 列表项）

private struct RoundtableRowCard: View {
    let rt: Roundtable
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                RTStatusBadge(status: rt.status)
                Text("第 \(rt.round)/\(rt.max_rounds) 轮")
                Text(rt.moderator == "ai" ? "AI主持" : "用户主持")
            }
            .font(VTheme.Typo.micro)
            .foregroundStyle(VTheme.textTertiary)

            Text(RoundtableFormat.truncatedTopic(rt.topic))
                .font(VTheme.Typo.body)
                .foregroundStyle(VTheme.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? VTheme.accentBg : VTheme.bgCard, in: RoundedRectangle(cornerRadius: VTheme.Radius.m))
        .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.m)
            .stroke(isSelected ? VTheme.accent : VTheme.borderDefault))
    }
}

// MARK: - 状态徽标（列表/详情共用；配色对齐 TSX RT_STATUS_BADGE，规范 §6.3）

struct RTStatusBadge: View {
    let status: String

    var body: some View {
        let s = style
        HStack(spacing: 4) {
            Circle().fill(s.dot).frame(width: 6, height: 6)
            Text(s.label)
        }
        .font(VTheme.Typo.micro)
        .foregroundStyle(s.fg)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(s.bg, in: Capsule())
    }

    private var style: (bg: Color, fg: Color, dot: Color, label: String) {
        switch status {
        case "waiting_user", "confirm_end":
            return (VTheme.warnBg, VTheme.warnText, VTheme.warn, RoundtableFormat.statusLabel(status))
        case "done":
            return (VTheme.okBg, VTheme.okText, VTheme.ok, RoundtableFormat.statusLabel(status))
        case "failed":
            return (VTheme.dangerBg, VTheme.dangerText, VTheme.danger, RoundtableFormat.statusLabel(status))
        default:   // running 及未知状态回落（对齐 RT_STATUS_BADGE[s] || running）
            return (VTheme.accentBg, VTheme.accentTextDeep, VTheme.accent, RoundtableFormat.statusLabel(status))
        }
    }
}

// MARK: - 流式换行布局（chips 自动换行，对齐 flex wrap）

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowH: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowH + spacing
                rowH = 0
            }
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowH: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowH + spacing
                rowH = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
    }
}
