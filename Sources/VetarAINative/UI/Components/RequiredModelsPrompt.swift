//
//  RequiredModelsPrompt.swift
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

//  拍板口径：
//    · 安装包不再内置 bge-m3（索引）+ SenseVoice（语音）；首装登录后弹窗下载；
//    · 允许后台下载——「后台继续」关弹窗不杀任务（NativeRequiredModels 任务
//      自持，进度在模型包面板可继续看）；
//    · 完成后弹窗确认：自检过 →「已就绪」热生效（两模型加载点皆懒/按需，
//      正常路径无需重启）；manifest 标记 restart_required 的条目 →「需重启」
//      → 确认后 AppState.restartApp()（W8 暂停落盘红线 + 参数保留重生）；
//    · 「以后再说」同样置标记不反复骚扰——模型包面板（设置覆盖页）随时可手动下。
//
//  RequiredModelRow 同时服务首装弹窗与模型包面板「必备模型」区卡（单一行实现，
//  状态徽标/进度条/按钮两场景同构）。
//

import SwiftUI

// MARK: - 首装弹窗

public struct RequiredModelsPromptView: View {
    @EnvironmentObject private var appState: AppState

    public init() {}

    private var rm: NativeRequiredModels { appState.requiredModels }
    private var models: [RequiredModelManifest.Model] { rm.manifest?.models ?? [] }
    private var pending: [RequiredModelManifest.Model] {
        models.filter { !rm.state(for: $0.modelId).isReady }
    }
    private var anyDownloading: Bool {
        models.contains { rm.state(for: $0.modelId).isDownloading }
    }
    private var failed: [RequiredModelManifest.Model] {
        models.filter { if case .failed = rm.state(for: $0.modelId) { return true }; return false }
    }
    private var anyVerifying: Bool {
        models.contains { if case .verifying = rm.state(for: $0.modelId) { return true }; return false }
    }
    /// 下载完成后需重启才生效的条目（数据驱动；当前清单两模型均 false = 热生效）
    private var restartNeeded: Bool {
        models.contains { $0.restartRequired && rm.state(for: $0.modelId).isReady }
    }

    public var body: some View {
        ZStack {
            Color.black.opacity(0.30)
                .ignoresSafeArea()
                .accessibilityIdentifier("requiredModels.overlay")
            // 遮罩点击不收起（下载决策需显式选择；「以后再说」/「后台继续」兜底）

            VStack(alignment: .leading, spacing: 14) {
                header
                ForEach(models, id: \.modelId) { m in
                    RequiredModelRow(model: m, state: rm.state(for: m.modelId),
                                     onStart: { rm.startDownload(m.modelId) },
                                     onCancel: { rm.cancelDownload(m.modelId) })
                }
                footer
            }
            .padding(22)
            .frame(width: 520)
            .background(VTheme.bgCard, in: RoundedRectangle(cornerRadius: VTheme.Radius.l))
            .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.l).stroke(VTheme.borderSubtle))
            .shadow(color: .black.opacity(0.18), radius: 24, y: 8)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("下载必备模型")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(VTheme.textPrimary)
            let totalBytes = pending.reduce(Int64(0)) { $0 + $1.sizeBytes }
            Text(pending.isEmpty
                 ? "必备模型已就绪。"
                 : "首次使用需要下载 \(pending.count) 个必备模型（共 \(NativeRequiredModels.fmtSize(totalBytes))，网络良好时预计 \(Self.estimatedTime(totalBytes))，下载中会显示实时速率与预计剩余时间）。下载在后台进行，不阻塞其他功能。")
                .font(.system(size: 12))
                .foregroundStyle(VTheme.textSecondary)
                .lineSpacing(3)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if restartNeeded {
            // 需重启分支（ADR 兜底）：确认 → W8 暂停落盘 + 参数保留重生
            VCallout(.warn, "部分模型需要重启后才能生效。重启前会自动保存进行中的工作，不会丢失数据。")
            HStack {
                Spacer()
                Button("稍后重启") { appState.dismissRequiredModelsPrompt() }
                    .buttonStyle(.vGhost)
                    .accessibilityIdentifier("requiredModels.restartLater")
                Button("立即重启") { appState.restartApp() }
                    .buttonStyle(.vPrimary)
                    .accessibilityIdentifier("requiredModels.restartNow")
            }
        } else if pending.isEmpty {
            // 完成弹窗确认（拍板）：自检全过 → 已就绪，热生效无需重启
            VCallout(.success, "全部必备模型已下载并通过完整性校验，无需重启即可使用。")
            HStack {
                Spacer()
                Button("完成") { appState.dismissRequiredModelsPrompt() }
                    .buttonStyle(.vPrimary)
                    .accessibilityIdentifier("requiredModels.done")
            }
        } else if anyDownloading || anyVerifying {
            HStack {
                Spacer()
                Button("后台继续") { appState.dismissRequiredModelsPrompt() }
                    .buttonStyle(.vGhost)
                    .help("关闭此窗口，下载在后台继续；可随时到「设置 → 模型包」查看进度")
                    .accessibilityIdentifier("requiredModels.background")
            }
        } else {
            if !failed.isEmpty {
                VCallout(.error, "\(failed.count) 个模型下载失败。失败文件已保留断点，重试将从中断处继续。")
            }
            HStack {
                Spacer()
                Button("以后再说") { appState.dismissRequiredModelsPrompt() }
                    .buttonStyle(.vGhost)
                    .accessibilityIdentifier("requiredModels.later")
                Button(failed.isEmpty ? "现在下载" : "重试失败项") {
                    for m in pending { rm.startDownload(m.modelId) }
                }
                .buttonStyle(.vPrimary)
                .accessibilityIdentifier("requiredModels.startAll")
            }
        }
    }

    /// 预计时间（按 8 MB/s 估算——下载前无实测速率，仅作量级参考；上屏文案已标
    /// 「网络良好时」，下载中由 fmtRemaining 按实测速率动态估算接替，DBG-188）。
    static func estimatedTime(_ bytes: Int64) -> String {
        let sec = Double(bytes) / (8 * 1024 * 1024)
        if sec < 60 { return "约 \(Int(sec.rounded(.up))) 秒" }
        return "约 \(Int((sec / 60).rounded(.up))) 分钟"
    }
}

// MARK: - 单模型行（弹窗与设置面板共用）

public struct RequiredModelRow: View {
    let model: RequiredModelManifest.Model
    let state: RequiredModelState
    let onStart: () -> Void
    let onCancel: () -> Void

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(model.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(VTheme.textPrimary)
                stateBadge
                Spacer(minLength: 8)
                Text(model.sizeDisplay)
                    .font(VTheme.Typo.caption)
                    .foregroundStyle(VTheme.textTertiary)
                actionButton
            }
            Text(model.purpose)
                .font(VTheme.Typo.caption)
                .foregroundStyle(VTheme.textSecondary)
                .lineSpacing(2)
            if case .downloading(let progress, let detail) = state {
                VStack(alignment: .leading, spacing: 4) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(VTheme.bgHover)
                                .frame(height: 6)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(VTheme.accent)
                                .frame(width: geo.size.width * CGFloat(progress), height: 6)
                                .animation(.easeOut(duration: 0.3), value: progress)
                        }
                    }
                    .frame(height: 6)
                    Text(detail)
                        .font(VTheme.Typo.micro)
                        .foregroundStyle(VTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.top, 2)
            }
            if case .failed(let message) = state {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 11))
                    Text(message).font(VTheme.Typo.caption).lineLimit(2)
                }
                .foregroundStyle(VTheme.dangerText)
            }
        }
        .padding(12)
        .background(VTheme.bgApp, in: RoundedRectangle(cornerRadius: VTheme.Radius.m))
        .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.m).stroke(VTheme.borderDefault))
    }

    @ViewBuilder
    private var stateBadge: some View {
        switch state {
        case .notDownloaded:
            badge("未下载", fg: VTheme.textTertiary, bg: VTheme.bgHover)
        case .downloading:
            badge("下载中", fg: VTheme.accentText, bg: VTheme.accentBg)
        case .verifying:
            badge("校验中", fg: VTheme.accentText, bg: VTheme.accentBg)
        case .ready:
            badge("已就绪", fg: VTheme.okText, bg: VTheme.okBg)
        case .failed:
            badge("失败", fg: VTheme.dangerText, bg: VTheme.warnBg)
        }
    }

    private func badge(_ text: String, fg: Color, bg: Color) -> some View {
        Text(text)
            .font(VTheme.Typo.micro)
            .foregroundStyle(fg)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(bg, in: RoundedRectangle(cornerRadius: VTheme.Radius.s))
    }

    @ViewBuilder
    private var actionButton: some View {
        switch state {
        case .notDownloaded:
            Button {
                onStart()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.down.circle").font(.system(size: 10))
                    Text("下载").font(VTheme.Typo.caption)
                }
            }
            .buttonStyle(.vPrimary)
            .controlSize(.small)
            .accessibilityIdentifier("requiredModels.download.\(model.modelId)")
        case .downloading, .verifying:
            Button("取消") { onCancel() }
                .buttonStyle(.vDanger)
                .controlSize(.small)
                .disabled({ if case .verifying = state { return true }; return false }())
                .accessibilityIdentifier("requiredModels.cancel.\(model.modelId)")
        case .ready:
            EmptyView()
        case .failed:
            Button("重试") { onStart() }
                .buttonStyle(.vPrimary)
                .controlSize(.small)
                .accessibilityIdentifier("requiredModels.retry.\(model.modelId)")
        }
    }
}
