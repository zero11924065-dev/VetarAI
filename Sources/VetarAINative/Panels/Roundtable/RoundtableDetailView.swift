//
//  RoundtableDetailView.swift
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

//  圆桌详情右侧大屏（对标 RoundtableView.tsx 423 行，对齐普通对话的观看体验）：
//    · 顶栏：返回 / 议题 / 状态徽标 / 第 x/y 轮 / 已耗时（进行中每秒跳动）｜
//      主持人（用户主持/AI 主持：名字，crown 图标 warn 色）/ 参与者名单 /
//      保存为文件 / 删除（running 禁用，「讨论进行中不能删除」）
//    · 议题附件行（参考材料 chips，非文本标注「（非文本）」）
//    · 纪要（默认展开，可折叠）/ 按轮分组的多角色发言气泡（头像 = 名字首字 +
//      §8.13 稳定六色板；主持人发言带 crown；发言失败降透明度 + 「·发言失败」）
//    · 新发言到达滚底（用户上滑离开底部则停跟随，回到底部恢复——对齐 H17 滚动语义）
//    · 底部操作区按状态渲染（决策 6：结束权在用户）：
//      waiting_user → 继续下一轮 / 结束并总结；confirm_end → 确认结束 / 再讨论一轮；
//      running → 讨论进行中… + 停止；done → 「讨论已结束，总结见上方」
//

import SwiftUI

struct RoundtableDetailView: View {
    @ObservedObject var vm: RoundtablePanelViewModel
    @State private var autoScroll = true

    var body: some View {
        if let detail = vm.detail {
            detailContent(detail)
        } else {
            // 对齐 TSX detail==null 分支：居中 Spinner + 加载中…
            VStack(spacing: 8) {
                ProgressView().controlSize(.regular)
                Text("加载中…")
                    .font(VTheme.Typo.body)
                    .foregroundStyle(VTheme.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(VTheme.bgApp)
        }
    }

    private func detailContent(_ detail: Roundtable) -> some View {
        VStack(spacing: 0) {
            header(detail)

            if let error = vm.error {
                VCallout(.error, error).padding(.horizontal, 16).padding(.top, 8)
            }
            if let notice = vm.notice {
                VCallout(.success, notice).padding(.horizontal, 16).padding(.top, 8)
            }

            if let atts = detail.attachments, !atts.isEmpty {
                attachmentsRow(atts)
            }

            if detail.minutes != nil {
                minutesSection(detail)
            }

            messagesArea(detail)

            actionBar(detail)
        }
        .background(VTheme.bgApp)
    }

    // MARK: - 顶栏（§8.13）

    private func header(_ detail: Roundtable) -> some View {
        HStack(spacing: 8) {
            // W8（0.7.4）：讨论进行中返回先弹确认（后台继续口径，防误关）
            Button { vm.requestExitDetail() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.left")
                    Text("返回")
                }
                .font(VTheme.Typo.caption)
            }
            .buttonStyle(.vGhost)
            .controlSize(.small)
            .help("返回对话")
            .accessibilityIdentifier("rtBackButton")

            Image(systemName: "mic")
                .foregroundStyle(VTheme.textPrimary)
            Text(detail.topic)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(VTheme.textPrimary)
                .lineLimit(1)

            RTStatusBadge(status: detail.status)
            Text("第 \(detail.round)/\(detail.max_rounds) 轮")
                .font(VTheme.Typo.caption)
                .foregroundStyle(VTheme.textSecondary)

            if let elapsed = vm.elapsedLabel {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                    Text("已耗时 \(elapsed)")
                }
                .font(VTheme.Typo.micro)
                .foregroundStyle(VTheme.textTertiary)
                .accessibilityIdentifier("rtElapsed")
            }

            Spacer(minLength: 8)

            // 主持人（用户验收反馈：主持人应显示在右侧）
            HStack(spacing: 4) {
                Image(systemName: "crown")
                Text(vm.moderatorLabel)
            }
            .font(VTheme.Typo.caption)
            .foregroundStyle(VTheme.warn)

            Text("参与者：\(detail.participants.map(\.name).joined(separator: "、"))")
                .font(VTheme.Typo.caption)
                .foregroundStyle(VTheme.textTertiary)
                .lineLimit(1)

            Button { vm.exportDiscussion() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.down")
                    Text("保存为文件")
                }
                .font(VTheme.Typo.caption)
            }
            .buttonStyle(.vSecondary)
            .controlSize(.small)
            .disabled(vm.detailBusy)
            .help("把整场讨论保存为 Markdown 文件")
            .accessibilityIdentifier("rtExportButton")

            Button { vm.deleteDiscussion() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "trash")
                    Text("删除")
                }
                .font(VTheme.Typo.caption)
            }
            .buttonStyle(.vSecondary)
            .controlSize(.small)
            .tint(VTheme.dangerText)
            .disabled(vm.detailBusy || detail.status == "running")
            .opacity(detail.status == "running" ? 0.5 : 1)
            .help(detail.status == "running" ? "讨论进行中不能删除" : "删除这场讨论")
            .accessibilityIdentifier("rtDeleteButton")
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .overlay(alignment: .bottom) {
            Rectangle().fill(VTheme.borderSubtle).frame(height: 1)
        }
    }

    // MARK: - 议题附件行（H18-3）

    private func attachmentsRow(_ atts: [RTAttachmentMeta]) -> some View {
        HStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "paperclip")
                Text("参考材料：")
            }
            .foregroundStyle(VTheme.textTertiary)
            FlowLayout(spacing: 4) {
                ForEach(atts) { att in
                    HStack(spacing: 3) {
                        Image(systemName: "doc")
                            .foregroundStyle(VTheme.textTertiary)
                        Text(att.name + (att.is_text == false ? "（非文本）" : ""))
                            .foregroundStyle(VTheme.textPrimary)
                    }
                    .font(VTheme.Typo.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(VTheme.bgCard, in: RoundedRectangle(cornerRadius: VTheme.Radius.s))
                    .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.s).stroke(VTheme.borderSubtle))
                }
            }
        }
        .font(VTheme.Typo.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VTheme.bgSidebar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(VTheme.borderSubtle).frame(height: 1)
        }
    }

    // MARK: - 纪要（默认展开）

    private func minutesSection(_ detail: Roundtable) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { vm.showMinutes.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                    Text("讨论纪要")
                    Image(systemName: "chevron.down")
                        .foregroundStyle(VTheme.textTertiary)
                        .rotationEffect(.degrees(vm.showMinutes ? 180 : 0))
                }
                .font(VTheme.Typo.body)
                .fontWeight(.medium)
                .foregroundStyle(VTheme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .accessibilityIdentifier("rtMinutesToggle")

            if vm.showMinutes {
                Text(detail.minutes ?? "")
                    .font(VTheme.Typo.body)
                    .lineSpacing(4)
                    .foregroundStyle(VTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .textSelection(.enabled)
            }
        }
        .background(VTheme.bgCard)
        .overlay(alignment: .bottom) {
            Rectangle().fill(VTheme.borderSubtle).frame(height: 1)
        }
    }

    // MARK: - 发言区（按轮分组；新发言滚底，上滑停跟随）

    private func messagesArea(_ detail: Roundtable) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(vm.groupedRounds, id: \.round) { group in
                        roundSeparator(group.round)
                        ForEach(group.messages) { m in
                            messageRow(m, moderatorAgentId: detail.moderator == "ai" ? detail.moderator_agent_id : nil)
                        }
                    }

                    if detail.status == "running" {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("第 \(detail.round) 轮讨论中，发言陆续产生…（自动刷新）")
                        }
                        .font(VTheme.Typo.body)
                        .foregroundStyle(VTheme.textTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(12)
                    }

                    if detail.status == "done", let summary = detail.summary, !summary.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Image(systemName: "list.clipboard")
                                Text("讨论总结")
                            }
                            .font(VTheme.Typo.body)
                            .fontWeight(.semibold)
                            Text(summary)
                                .font(VTheme.Typo.msgBody)
                                .lineSpacing(4)
                                .foregroundStyle(VTheme.textPrimary)
                                .textSelection(.enabled)
                        }
                        .foregroundStyle(VTheme.okText)
                        .padding(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(VTheme.okBg, in: RoundedRectangle(cornerRadius: VTheme.Radius.m))
                        .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.m).stroke(VTheme.okBorder))
                        .padding(.top, 8)
                    }

                    // 底部锚点：可见 = 用户位于底部 → 新发言自动滚底；
                    // 不可见（上滑离开）→ 停跟随（对齐 handleScroll/handleWheel 语义）
                    Color.clear
                        .frame(height: 1)
                        .id("rtBottom")
                        .onAppear { autoScroll = true }
                        .onDisappear { autoScroll = false }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: detail.messages?.count ?? 0) { _, _ in
                guard autoScroll else { return }
                proxy.scrollTo("rtBottom")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func roundSeparator(_ round: Int) -> some View {
        HStack(spacing: 12) {
            Rectangle().fill(VTheme.borderDefault).frame(width: 40, height: 1)
            Text("第 \(round) 轮")
                .font(VTheme.Typo.caption)
                .foregroundStyle(VTheme.textTertiary)
                .fixedSize()
            Rectangle().fill(VTheme.borderDefault).frame(width: 40, height: 1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private func messageRow(_ m: RTMessage, moderatorAgentId: String?) -> some View {
        let palette = RoundtableFormat.avatarColors(m.agent_id)
        return HStack(alignment: .top, spacing: 10) {
            // 头像（名字首字 + 角色稳定配色）
            Text(String(m.agent_name.prefix(1)))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(hex: palette.fg))
                .frame(width: 36, height: 36)
                .background(Color(hex: palette.bg), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    if moderatorAgentId == m.agent_id {
                        Image(systemName: "crown")
                            .font(.system(size: 12))
                            .foregroundStyle(VTheme.warn)
                    }
                    Text(m.agent_name)
                        .font(VTheme.Typo.body)
                        .fontWeight(.medium)
                        .foregroundStyle(VTheme.textPrimary)
                    if !m.ok {
                        Text("·发言失败")
                            .font(VTheme.Typo.caption)
                            .foregroundStyle(VTheme.dangerText)
                    }
                }
                Text(m.content)
                    .font(VTheme.Typo.msgBody)
                    .lineSpacing(4)
                    .foregroundStyle(VTheme.textPrimary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(VTheme.bgCard, in: RoundedRectangle(cornerRadius: VTheme.Radius.m))
                    .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.m).stroke(VTheme.borderDefault))
                    .frame(maxWidth: 620, alignment: .leading)   // ≈ TSX maxWidth 85%
            }
            Spacer(minLength: 0)
        }
        .opacity(m.ok ? 1 : 0.55)
        .padding(.bottom, 12)
    }

    // MARK: - 底部操作区（决策 6：结束权在用户）

    @ViewBuilder
    private func actionBar(_ detail: Roundtable) -> some View {
        HStack(spacing: 10) {
            switch detail.status {
            case "waiting_user":
                Text("本轮结束，请选择：")
                    .font(VTheme.Typo.caption)
                    .foregroundStyle(VTheme.textSecondary)
                Button { vm.continueDiscussion() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "play")
                        Text("继续下一轮")
                    }
                }
                .buttonStyle(.vPrimary)
                .disabled(vm.detailBusy)
                .accessibilityIdentifier("rtContinueButton")
                Button { vm.finishDiscussion() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "stop")
                        Text("结束并总结")
                    }
                }
                .buttonStyle(.vSecondary)
                .disabled(vm.detailBusy)
                .accessibilityIdentifier("rtFinishButton")

            case "confirm_end":
                HStack(spacing: 4) {
                    Image(systemName: "crown")
                        .foregroundStyle(VTheme.warn)
                    Text("主持人认为各方已达成共识，是否收尾由你决定：")
                }
                .font(VTheme.Typo.caption)
                .foregroundStyle(VTheme.warnText)
                Button { vm.finishDiscussion() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "stop")
                        Text("确认结束")
                    }
                }
                .buttonStyle(.vPrimary)
                .disabled(vm.detailBusy)
                .accessibilityIdentifier("rtConfirmFinishButton")
                Button { vm.continueDiscussion() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "play")
                        Text("再讨论一轮")
                    }
                }
                .buttonStyle(.vSecondary)
                .disabled(vm.detailBusy)
                .accessibilityIdentifier("rtContinueMoreButton")

            case "running":
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("讨论进行中…")
                }
                .font(VTheme.Typo.body)
                .foregroundStyle(VTheme.textTertiary)
                Button { vm.stopDiscussion() } label: {
                    HStack(spacing: 4) {
                        if vm.stopping {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "stop")
                        }
                        Text("停止")
                    }
                }
                .buttonStyle(.vSecondary)
                .tint(VTheme.dangerText)
                .disabled(vm.stopping)
                .help("停止讨论（将在当前发言完成后中止本轮，已完成发言保留）")
                .accessibilityIdentifier("rtStopButton")

            case "done":
                HStack(spacing: 4) {
                    Image(systemName: "checkmark")
                    Text("讨论已结束，总结见上方")
                }
                .font(VTheme.Typo.body)
                .foregroundStyle(VTheme.okText)

            default:   // failed 及其他：无操作按钮（对齐 TSX 无分支）
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(alignment: .top) {
            Rectangle().fill(VTheme.borderSubtle).frame(height: 1)
        }
    }
}
