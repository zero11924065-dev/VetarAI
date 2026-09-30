//
//  FeedbackViews.swift
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

//  约定书 §2.11 + 任务书 D 组落点（设置「更新与反馈」面板内，检查更新卡之下）：
//    · 问题反馈卡：标题（必填 ≤100）/ 分类（bug·建议·其他）/ 描述（≤5000）/
//      附件（NSOpenPanel 多选，白名单 png/jpg/jpeg/gif/webp/pdf/txt/log/md/zip，
//      单 ≤10MB ≤5 个，超限本地直拒）/ 提交（成功后清空表单、结果条直展
//      服务端 message「反馈已提交，感谢您的反馈！」；429 文案由客户端内建回退）。
//    · 我的反馈卡：状态四态映射（open 待处理 / progress 处理中 /
//      resolved 已解决 / closed 已关闭）+ admin_reply 展示 + 刷新钮
//      （外层 ScrollView 另有 .refreshable 下拉刷新）。
//    · app/appVersion/osVersion 自动带上不展示（FeedbackCenter 组包）；
//      未登录时两张卡给登录引导文案（不发请求）。
//  AX 纪律：互斥分支字面量 id 必须全局唯一（success/error 两条结果条分别
//  feedback.submitSuccess / feedback.submitError）；列表行不挂 id 防静态撞车。
//  一键附日志（业主拍板）：开关默认开启（feedback.attachLogsToggle），日志 zip 占
//  1 个附件名额——开关开时自选附件上限降为辅 4 个、关恢复 5；chip（feedback.logChip）
//  点 × 等同关开关；提交失败不清空日志附件态，成功随表单重置回默认并重新收集。
//

import AppKit
import SwiftUI

// MARK: - 问题反馈卡

public struct FeedbackFormCard: View {
    @EnvironmentObject private var appState: AppState

    @State private var title = ""
    @State private var descriptionText = ""
    @State private var category = "bug"
    @State private var attachments: [FeedbackAttachment] = []
    @State private var localError: String?
    /// 「自动附上运行日志」开关（业主口径：默认开启，用户可关；点 chip × = 等同关开关）。
    @State private var attachLogs = FeedbackCenter.attachLogsDefault
    /// 已构建的日志 zip（占 1 个附件名额；构建失败为 nil 不阻塞提交）。
    @State private var logAttachment: FeedbackAttachment?
    @State private var buildingLogs = false

    public init() {}

    /// 附件扩展名 → MIME（白名单子集；契约 §2.11 未要求精确 MIME，按通用值上送）。
    static func mimeType(for filename: String) -> String {
        switch (filename as NSString).pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "pdf": return "application/pdf"
        case "zip": return "application/zip"
        case "md": return "text/markdown"
        default: return "text/plain"   // txt / log
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.bubble")
                    .foregroundStyle(VTheme.accentText)
                Text("问题反馈")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(VTheme.textPrimary)
            }

            // 标题（必填 ≤100）
            TextField("标题（必填，≤100 字）", text: $title)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("feedback.titleField")

            // 分类（契约枚举 bug/suggestion/other）
            Picker("分类", selection: $category) {
                Text("Bug").tag("bug")
                Text("建议").tag("suggestion")
                Text("其他").tag("other")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("feedback.categoryPicker")

            // 描述（≤5000）
            TextEditor(text: $descriptionText)
                .font(.system(size: 13))
                .frame(minHeight: 88, maxHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.m2)
                    .stroke(VTheme.borderDefault, lineWidth: 1))
                .accessibilityIdentifier("feedback.descriptionEditor")
            Text("详细描述（可空，≤5000 字）· 已输入 \(descriptionText.count) 字")
                .font(VTheme.Typo.micro)
                .foregroundStyle(descriptionText.count > FeedbackCenter.descriptionMaxLength
                                 ? VTheme.dangerText : VTheme.textTertiary)

            // 附件（白名单 + ≤10MB；日志开关开时 zip 占 1 槽 → 自选上限 4，关恢复 5）
            HStack(spacing: 12) {
                Button {
                    pickAttachments()
                } label: {
                    Label("添加附件", systemImage: "paperclip")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 120, height: 32)
                        .background(VTheme.accentBgSoft,
                                    in: RoundedRectangle(cornerRadius: VTheme.Radius.m2))
                        .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.m2)
                            .stroke(VTheme.accentBorder, lineWidth: 1))
                        .foregroundStyle(VTheme.accentText)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("feedback.attachButton")
                if attachLogs {
                    Text("已附日志，还可添加 \(FeedbackCenter.userAttachmentLimit(logsAttached: true) - attachments.count) 个附件")
                        .font(VTheme.Typo.micro)
                        .foregroundStyle(VTheme.textTertiary)
                } else {
                    Text("\(attachments.count)/\(FeedbackCenter.maxAttachmentCount) 个 · 支持截图/日志/pdf/zip，单个 ≤10MB")
                        .font(VTheme.Typo.micro)
                        .foregroundStyle(VTheme.textTertiary)
                }
            }
            if !attachments.isEmpty {
                ForEach(Array(attachments.enumerated()), id: \.offset) { idx, att in
                    HStack(spacing: 8) {
                        Image(systemName: "doc")
                            .foregroundStyle(VTheme.textTertiary)
                        Text(att.filename)
                            .font(VTheme.Typo.caption)
                            .foregroundStyle(VTheme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(byteText(att.data.count))
                            .font(VTheme.Typo.micro)
                            .foregroundStyle(VTheme.textTertiary)
                        Spacer()
                        Button {
                            attachments.remove(at: idx)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(VTheme.textTertiary)
                        }
                        .buttonStyle(.plain)   // 行内不挂 id（DBG-AX 静态撞车纪律）
                    }
                }
            }

            // ── 一键附日志（开关默认开启；zip 构建在后台，chip 可移除 = 关开关）──
            Toggle(isOn: $attachLogs) {
                Text("自动附上运行日志")
                    .font(VTheme.Typo.caption)
                    .foregroundStyle(VTheme.textPrimary)
            }
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("feedback.attachLogsToggle")
            Text("自动收集最近 3 天运行日志用于定位问题，已脱敏（不含账号、密码、令牌等敏感信息）")
                .font(VTheme.Typo.micro)
                .foregroundStyle(VTheme.textTertiary)
            if attachLogs {
                if let logAttachment {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.zipper")
                            .foregroundStyle(VTheme.textTertiary)
                        Text("日志已附加（\(byteText(logAttachment.data.count))）")
                            .font(VTheme.Typo.caption)
                            .foregroundStyle(VTheme.textPrimary)
                        Button {
                            // 点 × = 等同关开关（日志附件态同步清空）
                            attachLogs = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(VTheme.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("feedback.logChipRemove")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(VTheme.bgHover, in: Capsule())
                    .accessibilityIdentifier("feedback.logChip")
                } else if buildingLogs {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("正在收集日志…")
                            .font(VTheme.Typo.micro)
                            .foregroundStyle(VTheme.textTertiary)
                    }
                    .accessibilityIdentifier("feedback.logBuilding")
                }
            }

            // 本地校验错误（白名单/大小/数量直拒）
            if let localError {
                Text(localError)
                    .font(VTheme.Typo.caption)
                    .foregroundStyle(VTheme.dangerText)
                    .accessibilityIdentifier("feedback.localError")
            }

            // 提交 + 结果条
            HStack(spacing: 12) {
                Button {
                    localError = nil
                    Task {
                        // 日志 zip 占 1 个附件名额（拼在自选附件之后同槽上送）
                        var all = attachments
                        if attachLogs, let logAttachment { all.append(logAttachment) }
                        await appState.feedback.submit(
                            title: title,
                            description: descriptionText,
                            category: category,
                            attachments: all,
                            isOnline: appState.network.isOnline)
                        if case .success = appState.feedback.submitOutcome {
                            // 成功清空表单（结果条保留——任务书 D 提交成功提示口径）；
                            // 日志附件态随表单重置回默认开关并重新收集（新时间戳）
                            title = ""
                            descriptionText = ""
                            category = "bug"
                            attachments = []
                            attachLogs = FeedbackCenter.attachLogsDefault
                            await rebuildLogs()
                        }
                        // 失败：表单与日志附件态全部保留（业主口径——不清空）
                    }
                } label: {
                    HStack(spacing: 6) {
                        if appState.feedback.submitting {
                            ProgressView().controlSize(.small)
                        }
                        Text(appState.feedback.submitting ? "提交中…" : "提交反馈")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .frame(width: 120, height: 32)
                    .background(VTheme.accentBgSoft,
                                in: RoundedRectangle(cornerRadius: VTheme.Radius.m2))
                    .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.m2)
                        .stroke(VTheme.accentBorder, lineWidth: 1))
                    .foregroundStyle(VTheme.accentText)
                }
                .buttonStyle(.plain)
                .disabled(appState.feedback.submitting)
                .accessibilityIdentifier("feedback.submitButton")

                if let outcome = appState.feedback.submitOutcome {
                    switch outcome {
                    case .success(let msg):
                        Label(msg, systemImage: "checkmark.circle.fill")
                            .font(VTheme.Typo.caption)
                            .foregroundStyle(VTheme.okText)
                            .lineLimit(2)
                            .accessibilityIdentifier("feedback.submitSuccess")
                    case .failed(let msg):
                        Text(msg)
                            .font(VTheme.Typo.caption)
                            .foregroundStyle(VTheme.dangerText)
                            .lineLimit(2)
                            .accessibilityIdentifier("feedback.submitError")
                    }
                }
            }
            Text("版本与系统信息会自动附上用于排查；每天最多提交 5 条。")
                .font(VTheme.Typo.micro)
                .foregroundStyle(VTheme.textTertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VTheme.bgCard, in: RoundedRectangle(cornerRadius: VTheme.Radius.m))
        .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.m)
            .stroke(VTheme.borderSubtle, lineWidth: 1))
        .task { await rebuildLogs() }   // 进面板即按默认开关收集日志（构建失败静默降级）
        .onChange(of: attachLogs) { _, on in
            if on {
                Task { await rebuildLogs() }
            } else {
                logAttachment = nil   // 关开关/点 chip ×：日志附件态清空（槽位恢复 5）
            }
        }
    }

    private func pickAttachments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "添加"
        guard panel.runModal() == .OK else { return }
        // 槽位会计：日志开关开 = 自选上限 4（zip 占 1 槽），关 = 5（契约 §2.11 上限）
        let limit = FeedbackCenter.userAttachmentLimit(logsAttached: attachLogs)
        for url in panel.urls {
            guard attachments.count + 1 <= limit else {
                localError = attachLogs
                    ? "已附运行日志，自选附件最多 \(limit) 个"
                    : "附件最多 \(FeedbackCenter.maxAttachmentCount) 个"
                return
            }
            guard let data = try? Data(contentsOf: url) else {
                localError = "附件「\(url.lastPathComponent)」读取失败"
                return
            }
            if let err = FeedbackCenter.validateAttachment(filename: url.lastPathComponent,
                                                           bytes: data.count) {
                localError = err
                return
            }
            localError = nil
            attachments.append(FeedbackAttachment(filename: url.lastPathComponent,
                                                  data: data,
                                                  mimeType: Self.mimeType(for: url.lastPathComponent)))
        }
    }

    /// 构建日志 zip（后台线程读文件+压缩，防大日志冻 UI；失败 nil 不阻塞提交）。
    /// 开关打开时调用；关闭由 onChange 直接清空态，无需构建。
    private func rebuildLogs() async {
        guard attachLogs else { logAttachment = nil; return }
        buildingLogs = true
        logAttachment = await Task.detached(priority: .utility) {
            LogAttachmentBuilder().build()?.attachment
        }.value
        buildingLogs = false
    }

    private func byteText(_ n: Int) -> String {
        if n >= 1024 * 1024 { return String(format: "%.1fMB", Double(n) / 1024 / 1024) }
        if n >= 1024 { return String(format: "%.0fKB", Double(n) / 1024) }
        return "\(n)B"
    }
}

// MARK: - 我的反馈卡

public struct FeedbackMineCard: View {
    @EnvironmentObject private var appState: AppState
    /// R3（0.7.12 实测 A9）：展开中的条目 id 集（点击行头折叠/展开只读详情）
    @State private var expandedIDs: Set<Int> = []

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle")
                    .foregroundStyle(VTheme.accentText)
                Text("我的反馈")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(VTheme.textPrimary)
                Spacer()
                Button {
                    Task {
                        await appState.feedback.refreshMine(
                            isOnline: appState.network.isOnline)
                    }
                } label: {
                    HStack(spacing: 4) {
                        if appState.feedback.loadingMine {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text("刷新")
                            .font(VTheme.Typo.caption)
                    }
                    .foregroundStyle(VTheme.accentText)
                }
                .buttonStyle(.plain)
                .disabled(appState.feedback.loadingMine)
                .accessibilityIdentifier("feedback.refreshButton")
            }

            if let err = appState.feedback.mineError, appState.feedback.myFeedback.isEmpty {
                Text(err)
                    .font(VTheme.Typo.caption)
                    .foregroundStyle(VTheme.textTertiary)
                    .accessibilityIdentifier("feedback.mineError")
            } else if appState.feedback.myFeedback.isEmpty, !appState.feedback.loadingMine {
                Text("暂无反馈记录")
                    .font(VTheme.Typo.caption)
                    .foregroundStyle(VTheme.textTertiary)
                    .accessibilityIdentifier("feedback.mineEmpty")
            } else {
                VStack(spacing: 10) {
                    ForEach(appState.feedback.myFeedback, id: \.id) { item in
                        row(item)
                    }
                }
                .accessibilityIdentifier("feedback.mineList")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VTheme.bgCard, in: RoundedRectangle(cornerRadius: VTheme.Radius.m))
        .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.m)
            .stroke(VTheme.borderSubtle, lineWidth: 1))
        .task {
            // 进面板拉一次（断网/未登录静默——FeedbackCenter 内置引导文案）
            await appState.feedback.refreshMine(isOnline: appState.network.isOnline)
        }
    }

    @ViewBuilder
    private func row(_ item: FeedbackItem) -> some View {
        let expanded = expandedIDs.contains(item.id)
        VStack(alignment: .leading, spacing: 6) {
            // R3（0.7.12 实测 A9）：行头可点——折叠/展开只读详情（chevron 指示态）
            HStack(spacing: 8) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(VTheme.textTertiary)
                    .frame(width: 10)
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(VTheme.textPrimary)
                    .lineLimit(expanded ? nil : 1)
                    .fixedSize(horizontal: false, vertical: expanded)
                Spacer()
                statusChip(item.status)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if expanded { expandedIDs.remove(item.id) } else { expandedIDs.insert(item.id) }
            }
            .accessibilityIdentifier("feedback.mineRow.\(item.id)")
            HStack(spacing: 8) {
                Text(FeedbackCenter.categoryText(item.category))
                Text("·")
                Text(item.createdAt.prefix(10))
                if item.attachmentCount > 0 {
                    Text("·")
                    Text("\(item.attachmentCount) 个附件")
                }
            }
            .font(VTheme.Typo.micro)
            .foregroundStyle(VTheme.textTertiary)

            // R3 展开详情（只读；契约 mine 返回字段全集 + 本机缓存描述）
            if expanded {
                VStack(alignment: .leading, spacing: 5) {
                    if let desc = appState.feedback.submittedDescription(for: item) {
                        Text(desc)
                            .font(VTheme.Typo.caption)
                            .foregroundStyle(VTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    } else {
                        // 如实口径：服务端不下发描述，不编造；本机新提交的可回看
                        Text("描述未留存（服务端不返回描述，本机新提交的反馈可在此回看全文）")
                            .font(VTheme.Typo.micro)
                            .foregroundStyle(VTheme.textTertiary)
                    }
                    Divider().padding(.vertical, 2)
                    detailLine("编号", "#\(item.id)")
                    detailLine("提交时间", item.createdAt)
                    if !item.updatedAt.isEmpty, item.updatedAt != item.createdAt {
                        detailLine("更新时间", item.updatedAt)
                    }
                    detailLine("提交环境", "\(item.appVersion) · \(item.osVersion)")
                    detailLine("附件", item.attachmentCount > 0
                               ? "\(item.attachmentCount) 个" : "无")
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(VTheme.bgCard, in: RoundedRectangle(cornerRadius: VTheme.Radius.m2))
                .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.m2)
                    .stroke(VTheme.borderSubtle, lineWidth: 1))
            }

            if !item.adminReply.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .foregroundStyle(VTheme.okText)
                    Text(item.adminReply)
                        .font(VTheme.Typo.caption)
                        .foregroundStyle(VTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(VTheme.okBg, in: RoundedRectangle(cornerRadius: VTheme.Radius.m2))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VTheme.bgApp, in: RoundedRectangle(cornerRadius: VTheme.Radius.m2))
        .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.m2)
            .stroke(VTheme.borderSubtle, lineWidth: 1))
    }

    /// R3 详情字段行（标签定宽 + 值可选中复制）
    private func detailLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(VTheme.Typo.micro)
                .foregroundStyle(VTheme.textTertiary)
                .frame(width: 56, alignment: .leading)
            Text(value)
                .font(VTheme.Typo.micro)
                .foregroundStyle(VTheme.textSecondary)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func statusChip(_ status: String) -> some View {
        let (fg, bg): (Color, Color) = {
            switch status {
            case "open": return (VTheme.warnText, VTheme.warnBg)
            case "progress": return (VTheme.accentText, VTheme.accentBgSoft)
            case "resolved": return (VTheme.okText, VTheme.okBg)
            default: return (VTheme.textTertiary, VTheme.bgHover)   // closed/未知
            }
        }()
        Text(FeedbackCenter.statusText(status))
            .font(VTheme.Typo.micro)
            .foregroundStyle(fg)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(bg, in: Capsule())
    }
}
