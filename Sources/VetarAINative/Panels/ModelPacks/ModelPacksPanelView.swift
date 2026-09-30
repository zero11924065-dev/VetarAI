//
//  ModelPacksPanelView.swift
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

//  模型包管理器面板（SwiftUI 移植，对标 ModelPacksPanel.tsx，627 行）：
//    · 标题行 + 刷新；错误条 / 轻提示条
//    · 目录（可安装）区卡：源错误警告条 / 加载中 / 两种空态 / 目录条目卡
//      （徽标 / 版本 / 大小 / 已安装标记 / 来源行 / 下载进度条 / 取消 / 安装）
//    · 已安装区卡：启停开关 / 卸载 / 校验未通过·文件缺失警示 / 半截下载残留提示
//    · 目录源设置区卡：目录索引地址（一行一个；file:// 本地目录可用「选择目录…」
//      按钮经 NSOpenPanel 填入）+ 模型包安装目录（留空 = 默认）
//  文案逐字对齐现状实现；视觉用 VTheme 近似（接入指南 §3）。
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

public struct ModelPacksPanelView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var vmBox = ModelPacksPanelViewModelBox()

    public init() {}

    public var body: some View {
        if let vm = vmBox.vm {
            ModelPacksPanelBody(vm: vm, runtime: appState.runtime)
        } else {
            VLoadingView("模型包面板初始化…")
                .task { vmBox.attach(appState: appState) }
        }
    }
}

/// 延迟构建 ModelPacksPanelViewModel（需要已注入的 AppState）。
@MainActor
final class ModelPacksPanelViewModelBox: ObservableObject {
    @Published var vm: ModelPacksPanelViewModel?
    func attach(appState: AppState) {
        if vm == nil { vm = ModelPacksPanelViewModel(appState: appState) }
    }
}

private struct ModelPacksPanelBody: View {
    @ObservedObject var vm: ModelPacksPanelViewModel
    /// 直接观察 NativeRuntime（AppState 不转发子服务的 objectWillChange——
    /// 面板必须自己观察侧车才能在「就绪」时自愈重载，W2 收口冒烟实测）。
    @ObservedObject var runtime: NativeRuntime
    /// W10（REQ-FUT-015）：必备模型区卡数据源（AppState 已桥接其 objectWillChange）
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                titleRow
                if let error = vm.error {
                    VCallout(.error, error).accessibilityIdentifier("modelPacks.error")
                }
                if let notice = vm.notice {
                    VCallout(.success, notice).accessibilityIdentifier("modelPacks.notice")
                }
                requiredModelsCard
                modelScopeCard
                catalogCard
                installedCard
                vmodelCard
                sourcesCard
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VTheme.bgApp)
        .onAppear { vm.start() }
        .onDisappear { vm.stop() }
        // 侧车就绪竞态自愈：面板先于侧车打开时 start() 早退，就绪后补载一次。
        // P3-W6⑤：nativeReady 于 runtime init 同步点亮、任何视图出现前恒 true，
        // 旧「就绪自愈」onChange（永不触发）随侧车归零删除——首拉在挂载链路上。
    }

    // MARK: - 必备模型区卡（REQ-FUT-015 / ADR-0051：不再内置，按需下载）

    private var requiredModelsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("必备模型")
                    .font(VTheme.Typo.sectionTitle)
                    .foregroundStyle(VTheme.textPrimary)
                Text("索引与语音识别两个必备模型不随安装包内置，按需下载（断点续传 + SHA256 校验）；未安装时对应功能自动降级或提示。")
                    .font(VTheme.Typo.micro)
                    .foregroundStyle(VTheme.textTertiary)
            }
            let rm = appState.requiredModels
            if let manifest = rm.manifest {
                ForEach(manifest.models, id: \.modelId) { m in
                    RequiredModelRow(model: m, state: rm.state(for: m.modelId),
                                     onStart: { rm.startDownload(m.modelId) },
                                     onCancel: { rm.cancelDownload(m.modelId) })
                }
            } else {
                VCallout(.warn, "必备模型清单缺失（required-models.json 不在包内）。")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VTheme.bgCard, in: RoundedRectangle(cornerRadius: VTheme.Radius.l))
        .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.l).stroke(VTheme.borderSubtle))
    }

    // MARK: - 魔塔链接安装区卡（0.7.5 W10 / REQ-FUT-021）

    private var modelScopeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("从魔塔链接安装")
                    .font(VTheme.Typo.sectionTitle)
                    .foregroundStyle(VTheme.textPrimary)
                Text("粘贴魔塔社区模型页链接 / ollama 风格标识 / SDK 代码片段，解析后选档位下载安装（GGUF 与 MLX 两族；断点续传 + SHA256 校验）。")
                    .font(VTheme.Typo.micro)
                    .foregroundStyle(VTheme.textTertiary)
            }

            HStack(spacing: 8) {
                TextField("https://modelscope.cn/models/组织/模型名 或 snapshot_download('组织/模型名')",
                          text: $vm.msInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .vInputStyle()
                    .disabled(vm.msProgress != nil)
                    .accessibilityIdentifier("modelPacks.msInput")
                Button {
                    vm.msResolve()
                } label: {
                    HStack(spacing: 4) {
                        if vm.msResolving { ProgressView().controlSize(.mini) }
                        Text(vm.msResolving ? "解析中…" : "解析").font(VTheme.Typo.caption)
                    }
                }
                .buttonStyle(.vPrimary)
                .controlSize(.small)
                .disabled(vm.msResolving || vm.msProgress != nil
                          || vm.msInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("modelPacks.msResolve")
            }

            if let snap = vm.msSnapshot {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("\(snap.ref.org)/\(snap.ref.name)")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(VTheme.textPrimary)
                        // 合规红线①：license 标签
                        Text("许可：\(snap.license.isEmpty ? "未标注" : snap.license)")
                            .font(VTheme.Typo.micro)
                            .foregroundStyle(VTheme.accentText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(VTheme.accentBg, in: RoundedRectangle(cornerRadius: VTheme.Radius.s))
                        Text(snap.variants.first?.format == .mlx ? "MLX" : "GGUF")
                            .font(VTheme.Typo.micro)
                            .foregroundStyle(VTheme.okText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(VTheme.okBg, in: RoundedRectangle(cornerRadius: VTheme.Radius.s))
                    }
                    // 合规红线②：源链接 + ③自查提示
                    Text("来源：\(snap.ref.pageURL)")
                        .font(VTheme.Typo.micro)
                        .foregroundStyle(VTheme.textTertiary)
                        .textSelection(.enabled)
                    Text(NativeModelScopeInstaller.complianceNotice)
                        .font(VTheme.Typo.micro)
                        .foregroundStyle(VTheme.warnText)

                    if snap.variants.count > 1 {
                        Picker("档位", selection: $vm.msSelectedVariant) {
                            ForEach(snap.variants, id: \.id) { v in
                                Text("\(v.title)（\(ModelPackFormat.formatSize(v.totalBytes))）").tag(v.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 420, alignment: .leading)
                        .disabled(vm.msProgress != nil)
                        .accessibilityIdentifier("modelPacks.msVariant")
                    } else if let v = snap.variants.first {
                        Text("档位：\(v.title)（\(ModelPackFormat.formatSize(v.totalBytes))）")
                            .font(VTheme.Typo.caption)
                            .foregroundStyle(VTheme.textSecondary)
                    }

                    HStack(spacing: 8) {
                        if vm.msProgress == nil {
                            Button {
                                vm.msInstall()
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "arrow.down.circle").font(.system(size: 10))
                                    Text("下载并安装").font(VTheme.Typo.caption)
                                }
                            }
                            .buttonStyle(.vPrimary)
                            .controlSize(.small)
                            .accessibilityIdentifier("modelPacks.msInstall")
                        } else {
                            Button {
                                vm.msCancel()
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "xmark").font(.system(size: 10))
                                    Text("取消").font(VTheme.Typo.caption)
                                }
                            }
                            .buttonStyle(.vDanger)
                            .controlSize(.small)
                            .accessibilityIdentifier("modelPacks.msCancel")
                        }
                    }
                }
                .padding(12)
                .background(VTheme.bgCard, in: RoundedRectangle(cornerRadius: VTheme.Radius.m))
                .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.m).stroke(VTheme.borderDefault))
            }

            // 下载进度（含速率——与必备模型/目录源进度行同口径）
            if let prog = vm.msProgress {
                VStack(alignment: .leading, spacing: 4) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(VTheme.bgHover)
                                .frame(height: 6)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(VTheme.accent)
                                .frame(width: geo.size.width * msPercent(prog), height: 6)
                        }
                    }
                    .frame(height: 6)
                    Text("已下载 \(ModelPackFormat.formatSize(prog.receivedBytes)) / \(ModelPackFormat.formatSize(prog.totalBytes))\(prog.totalBytes > 0 ? "（\(Int(msPercent(prog) * 100))%）" : "")\(prog.file.isEmpty ? "" : " · \(prog.file)")\(prog.bytesPerSecond > 0 ? " · \(NativeRequiredModels.fmtSpeed(prog.bytesPerSecond))" : "")")
                        .font(VTheme.Typo.micro)
                        .foregroundStyle(VTheme.textTertiary)
                }
            }

            if let msErr = vm.msError {
                VCallout(.error, msErr).accessibilityIdentifier("modelPacks.msError")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VTheme.bgCard, in: RoundedRectangle(cornerRadius: VTheme.Radius.l))
        .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.l).stroke(VTheme.borderSubtle))
    }

    /// 魔塔下载进度百分比（0~1；total 未知时 0）
    private func msPercent(_ p: DownloadProgress) -> CGFloat {
        guard p.totalBytes > 0 else { return 0 }
        return CGFloat(min(1, Double(p.receivedBytes) / Double(p.totalBytes)))
    }

    // MARK: - 标题行

    private var titleRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "layers")
                    .font(.system(size: 14))
                    .foregroundStyle(VTheme.textPrimary)
                Text("模型包管理")
                    .font(VTheme.Typo.sectionTitle)
                    .foregroundStyle(VTheme.textPrimary)
            }
            Spacer()
            Button {
                Task { await vm.fetchLists() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11))
                    Text("刷新").font(VTheme.Typo.caption)
                }
            }
            .buttonStyle(.vGhost)
            .controlSize(.small)
            .help("刷新")
            .accessibilityIdentifier("modelPacks.refresh")
        }
    }

    // MARK: - 目录（可安装）区卡

    private var catalogCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("目录（可安装）")
                    .font(VTheme.Typo.sectionTitle)
                    .foregroundStyle(VTheme.textPrimary)
                Text("来自目录源的模型包；点击安装即开始下载，中断后可从断点续传。")
                    .font(VTheme.Typo.micro)
                    .foregroundStyle(VTheme.textTertiary)
            }

            // 目录源拉取失败警告条（单源失败不拖死整列）
            ForEach(Array(vm.sourceErrors.enumerated()), id: \.offset) { _, se in
                VCallout(.warn, "目录源 \(se.source) 拉取失败：\(se.error)")
            }

            if vm.loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.regular)
                    Text("加载中…")
                        .font(VTheme.Typo.caption)
                        .foregroundStyle(VTheme.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else if vm.catalog.isEmpty {
                if vm.noSources {
                    // 空目录且无源：引导去下方加目录源（文案逐字）
                    VStack(spacing: 8) {
                        Image(systemName: "layers")
                            .font(.system(size: 30))
                            .foregroundStyle(VTheme.borderStrong)
                        Text("还没有配置模型包目录源。\n在下方「目录源设置」中添加目录索引地址（http(s):// 或 file:// 本地目录），保存后这里会列出可安装的模型包。")
                            .font(VTheme.Typo.body)
                            .foregroundStyle(VTheme.textTertiary)
                            .multilineTextAlignment(.center)
                            .lineSpacing(3)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "layers")
                            .font(.system(size: 30))
                            .foregroundStyle(VTheme.borderStrong)
                        Text("目录为空——已配置的源里没有可安装的模型包。")
                            .font(VTheme.Typo.body)
                            .foregroundStyle(VTheme.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
            } else {
                VStack(spacing: 12) {
                    ForEach(vm.catalog) { p in
                        catalogEntryCard(p)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VTheme.bgCard, in: RoundedRectangle(cornerRadius: VTheme.Radius.l))
        .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.l).stroke(VTheme.borderSubtle))
    }

    private func catalogEntryCard(_ p: CatalogPack) -> some View {
        let prog = vm.dlProgress[p.pack_id]
        let dlErr = vm.dlErrors[p.pack_id]
        let busy = vm.installing.contains(p.pack_id)
        let host = ModelPackFormat.hostOf(p.source ?? "")
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                HStack(spacing: 8) {
                    Text(p.name.isEmpty ? p.pack_id : p.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(VTheme.textPrimary)
                    Text(ModelPackFormat.taskLabels[p.task] ?? (p.task.isEmpty ? "未知" : p.task))
                        .font(VTheme.Typo.micro)
                        .foregroundStyle(VTheme.accentText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(VTheme.accentBg, in: RoundedRectangle(cornerRadius: VTheme.Radius.s))
                    Text("v\(p.version.isEmpty ? "?" : p.version)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(VTheme.textTertiary)
                    Text(ModelPackFormat.formatSize(p.size_bytes ?? 0))
                        .font(VTheme.Typo.caption)
                        .foregroundStyle(VTheme.textTertiary)
                    if p.installed == true {
                        Text("已安装\(installedVersionSuffix(p))")
                            .font(VTheme.Typo.micro)
                            .foregroundStyle(VTheme.okText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(VTheme.okBg, in: RoundedRectangle(cornerRadius: VTheme.Radius.s))
                    }
                }
                Spacer(minLength: 8)
                if prog != nil {
                    Button {
                        vm.cancelDownload(p.pack_id)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "xmark").font(.system(size: 10))
                            Text("取消").font(VTheme.Typo.caption)
                        }
                    }
                    .buttonStyle(.vDanger)
                    .controlSize(.small)
                    .accessibilityIdentifier("modelPacks.cancel.\(p.pack_id)")
                } else if p.installed == true {
                    Text("已安装")
                        .font(VTheme.Typo.caption)
                        .foregroundStyle(VTheme.textTertiary)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(VTheme.bgHover, in: RoundedRectangle(cornerRadius: VTheme.Radius.s))
                } else {
                    Button {
                        vm.install(p)
                    } label: {
                        HStack(spacing: 3) {
                            if busy {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.down.circle").font(.system(size: 10))
                            }
                            Text(busy ? "安装中…" : "安装").font(VTheme.Typo.caption)
                        }
                    }
                    .buttonStyle(.vPrimary)
                    .controlSize(.small)
                    .disabled(busy)
                    .accessibilityIdentifier("modelPacks.install.\(p.pack_id)")
                }
            }

            if let desc = p.description, !desc.isEmpty {
                Text(desc)
                    .font(VTheme.Typo.caption)
                    .foregroundStyle(VTheme.textSecondary)
                    .lineSpacing(2)
            }
            Text("来源：\(host.isEmpty ? "本地目录" : host)\(p.format.isEmpty ? "" : " · \(p.format)")\(p.license.map { " · \($0)" } ?? "")")
                .font(VTheme.Typo.micro)
                .foregroundStyle(VTheme.textTertiary)

            // 下载中：进度条（SSE download_progress 驱动）
            if let prog {
                VStack(alignment: .leading, spacing: 4) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(VTheme.bgHover)
                                .frame(height: 6)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(VTheme.accent)
                                .frame(width: geo.size.width * CGFloat(prog.percent) / 100, height: 6)
                                .animation(.easeOut(duration: 0.3), value: prog.percent)
                        }
                    }
                    .frame(height: 6)
                    Text("已下载 \(ModelPackFormat.formatSize(prog.received)) / \(ModelPackFormat.formatSize(prog.total))\(prog.total > 0 ? "（\(prog.percent)%）" : "")\(prog.file.map { " · \($0)" } ?? "")\(prog.bytesPerSecond > 0 ? " · \(NativeRequiredModels.fmtSpeed(prog.bytesPerSecond))" : "")")
                        .font(VTheme.Typo.micro)
                        .foregroundStyle(VTheme.textTertiary)
                }
                .padding(.top, 2)
            }
            // 下载/安装错误：显示在卡片上
            if let dlErr {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 11))
                    Text(dlErr).font(VTheme.Typo.caption)
                }
                .foregroundStyle(VTheme.dangerText)
            }
        }
        .padding(12)
        .background(VTheme.bgCard, in: RoundedRectangle(cornerRadius: VTheme.Radius.m))
        .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.m).stroke(VTheme.borderDefault))
    }

    /// 已安装徽标版本后缀（对齐 TSX：installed_version !== version 时附 v 旧版号）。
    private func installedVersionSuffix(_ p: CatalogPack) -> String {
        guard let iv = p.installed_version, !iv.isEmpty, iv != p.version else { return "" }
        return " v\(iv)"
    }

    // MARK: - 已安装区卡

    private var installedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("已安装")
                .font(VTheme.Typo.sectionTitle)
                .foregroundStyle(VTheme.textPrimary)

            if vm.installed.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 30))
                        .foregroundStyle(VTheme.borderStrong)
                    Text("尚未安装任何模型包。从上方目录选择安装。")
                        .font(VTheme.Typo.body)
                        .foregroundStyle(VTheme.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                VStack(spacing: 12) {
                    ForEach(vm.installed) { p in
                        installedEntryCard(p)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VTheme.bgCard, in: RoundedRectangle(cornerRadius: VTheme.Radius.l))
        .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.l).stroke(VTheme.borderSubtle))
    }

    private func installedEntryCard(_ p: InstalledPack) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                HStack(spacing: 8) {
                    Text(p.name.isEmpty ? p.pack_id : p.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(p.enabled ? VTheme.textPrimary : VTheme.textTertiary)
                    Text(ModelPackFormat.taskLabels[p.task] ?? (p.task.isEmpty ? "未知" : p.task))
                        .font(VTheme.Typo.micro)
                        .foregroundStyle(VTheme.accentText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(VTheme.accentBg, in: RoundedRectangle(cornerRadius: VTheme.Radius.s))
                    Text("v\(p.version.isEmpty ? "?" : p.version)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(VTheme.textTertiary)
                    if !p.format.isEmpty {
                        Text(p.format)
                            .font(VTheme.Typo.caption)
                            .foregroundStyle(VTheme.textTertiary)
                    }
                    // MLX 推理徽标（0.7.7 W3：driver=mlxswift 的 chat 包选中即可
                    // 装载对话——判定沿用 0.7.3 .vmodel 条目「MLX 可推理」同款口径，
                    // 即条目本身具备 MLX 可推理性时恒展示）
                    if p.task == "chat", p.driver == "mlxswift" {
                        HStack(spacing: 3) {
                            Image(systemName: "cpu").font(.system(size: 9))
                            Text("MLX 可推理").font(VTheme.Typo.micro)
                        }
                        .foregroundStyle(VTheme.accentText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(VTheme.accentBg, in: RoundedRectangle(cornerRadius: VTheme.Radius.s))
                    }
                    Text(ModelPackFormat.formatSize(p.size_bytes))
                        .font(VTheme.Typo.caption)
                        .foregroundStyle(VTheme.textTertiary)
                    // 缺文件或校验未通过 → 警示标记
                    if p.corrupted {
                        HStack(spacing: 3) {
                            Image(systemName: "exclamationmark.triangle").font(.system(size: 9))
                            Text(!p.sha256_ok ? "校验未通过" : "文件缺失")
                                .font(VTheme.Typo.micro)
                        }
                        .foregroundStyle(VTheme.warnText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(VTheme.warnBg, in: RoundedRectangle(cornerRadius: VTheme.Radius.s))
                    }
                }
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    // 启用/禁用开关（禁用保留文件，推理侧按 enabled 过滤）
                    Button {
                        vm.toggle(p)
                    } label: {
                        Text(p.enabled ? "禁用" : "启用")
                            .font(VTheme.Typo.caption)
                            .foregroundStyle(p.enabled ? VTheme.accentText : VTheme.textSecondary)
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(p.enabled ? VTheme.accentBg : VTheme.bgHover,
                                        in: RoundedRectangle(cornerRadius: VTheme.Radius.s))
                    }
                    .buttonStyle(.plain)
                    .help(p.enabled ? "点击禁用此模型包" : "点击启用此模型包")
                    .accessibilityIdentifier("modelPacks.toggle.\(p.pack_id)")
                    Button {
                        vm.uninstall(p)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "trash").font(.system(size: 10))
                            Text("卸载").font(VTheme.Typo.caption)
                        }
                    }
                    .buttonStyle(.vDanger)
                    .controlSize(.small)
                    .accessibilityIdentifier("modelPacks.uninstall.\(p.pack_id)")
                }
            }

            if let desc = p.description, !desc.isEmpty {
                Text(desc)
                    .font(VTheme.Typo.caption)
                    .foregroundStyle(VTheme.textSecondary)
                    .lineSpacing(2)
            }
            if !p.missing_files.isEmpty {
                Text("缺失文件：\(p.missing_files.joined(separator: "、"))")
                    .font(VTheme.Typo.micro)
                    .foregroundStyle(VTheme.warnText)
            }
            // 半截下载残留：到目录区再次点安装即自动断点续传
            if p.has_partial {
                Text("有未完成下载，可继续安装（到上方目录区再次点击「安装」即自动续传）。")
                    .font(VTheme.Typo.micro)
                    .foregroundStyle(VTheme.warnText)
            }
        }
        .padding(12)
        .background(VTheme.bgCard, in: RoundedRectangle(cornerRadius: VTheme.Radius.m))
        .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.m).stroke(VTheme.borderDefault))
        .opacity(p.enabled ? 1 : 0.7)
    }

    // MARK: - VetarModel 模型（.vmodel）区卡（.vmodel 集成批）

    private var vmodelCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("VetarModel 模型（.vmodel）")
                    .font(VTheme.Typo.sectionTitle)
                    .foregroundStyle(VTheme.textPrimary)
                Text("VetarModel 训练导出的模型文件；安装后进入工作室模型池，可选为主模型或分派对话（本机 MLX 推理）。")
                    .font(VTheme.Typo.micro)
                    .foregroundStyle(VTheme.textTertiary)
            }

            HStack(spacing: 8) {
                Button {
                    pickVModelFile()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.down").font(.system(size: 10))
                        Text("安装 .vmodel 文件…").font(VTheme.Typo.caption)
                    }
                }
                .buttonStyle(.vPrimary)
                .controlSize(.small)
                .disabled(vm.vmodelBusy)
                .help("选择 VetarModel 导出的 .vmodel 模型文件，校验通过后安装")
                .accessibilityIdentifier("modelPacks.installVModel")
                if vm.vmodelBusy {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("校验并安装中…")
                            .font(VTheme.Typo.caption)
                            .foregroundStyle(VTheme.textTertiary)
                    }
                }
            }

            if vm.vmodels.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "cube")
                        .font(.system(size: 30))
                        .foregroundStyle(VTheme.borderStrong)
                    Text("还没有安装 VetarModel 模型。在 VetarModel 完成训练并导出 .vmodel 文件后，点上方按钮安装。")
                        .font(VTheme.Typo.body)
                        .foregroundStyle(VTheme.textTertiary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                VStack(spacing: 12) {
                    ForEach(vm.vmodels, id: \.id) { m in
                        vmodelEntryCard(m)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VTheme.bgCard, in: RoundedRectangle(cornerRadius: VTheme.Radius.l))
        .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.l).stroke(VTheme.borderSubtle))
    }

    private func vmodelEntryCard(_ m: InstalledVModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                HStack(spacing: 8) {
                    Text(m.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(m.enabled ? VTheme.textPrimary : VTheme.textTertiary)
                    // 规模档位徽标（黑盒档位名 + 参数量）
                    Text(NativeVModelInstaller.scaleDisplayName(forScaleIndex: m.scaleIndex))
                        .font(VTheme.Typo.micro)
                        .foregroundStyle(VTheme.accentText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(VTheme.accentBg, in: RoundedRectangle(cornerRadius: VTheme.Radius.s))
                    if let b = NativeVModelInstaller.parametersB(forScaleIndex: m.scaleIndex) {
                        Text(b.truncatingRemainder(dividingBy: 1) == 0
                             ? "\(Int(b))B" : String(format: "%.1fB", b))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(VTheme.textTertiary)
                    }
                    Text(ModelPackFormat.formatSize(Int64(bitPattern: m.assetBytes)))
                        .font(VTheme.Typo.caption)
                        .foregroundStyle(VTheme.textTertiary)
                    // 来源文件名（同名不同档并存时的区分依据，0.7.16 批次7 修复①配套）
                    Text(m.sourceFile)
                        .font(VTheme.Typo.caption)
                        .foregroundStyle(VTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 180)
                        .help(m.sourceFile)
                    // MLX 推理徽标（0.7.3 起正式可分派：LoRA 叠加底座本机推理）
                    HStack(spacing: 3) {
                        Image(systemName: "cpu").font(.system(size: 9))
                        Text("MLX 可推理").font(VTheme.Typo.micro)
                    }
                    .foregroundStyle(VTheme.accentText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(VTheme.accentBg, in: RoundedRectangle(cornerRadius: VTheme.Radius.s))
                }
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    Button {
                        vm.toggleVModel(m)
                    } label: {
                        Text(m.enabled ? "禁用" : "启用")
                            .font(VTheme.Typo.caption)
                            .foregroundStyle(m.enabled ? VTheme.accentText : VTheme.textSecondary)
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(m.enabled ? VTheme.accentBg : VTheme.bgHover,
                                        in: RoundedRectangle(cornerRadius: VTheme.Radius.s))
                    }
                    .buttonStyle(.plain)
                    .help(m.enabled ? "点击禁用（工作室模型池不再列出）" : "点击启用")
                    .accessibilityIdentifier("modelPacks.vmodel.toggle.\(m.id)")
                    Button {
                        vm.removeVModel(m)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "trash").font(.system(size: 10))
                            Text("移除").font(VTheme.Typo.caption)
                        }
                    }
                    .buttonStyle(.vDanger)
                    .controlSize(.small)
                    .accessibilityIdentifier("modelPacks.vmodel.remove.\(m.id)")
                }
            }

            if !m.purpose.isEmpty {
                Text(m.purpose)
                    .font(VTheme.Typo.caption)
                    .foregroundStyle(VTheme.textSecondary)
                    .lineSpacing(2)
            }
            HStack(spacing: 12) {
                Text("缓存预设：\(vmodelCachePresetLabel(m.cachePresetRaw))")
                if m.capabilities.contains("vision") { Text("能力：对话+视觉") }
                if m.effectiveIdentity != nil { Text("已设身份") }
            }
            .font(VTheme.Typo.micro)
            .foregroundStyle(VTheme.textTertiary)
        }
        .padding(12)
        .background(VTheme.bgCard, in: RoundedRectangle(cornerRadius: VTheme.Radius.m))
        .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.m).stroke(VTheme.borderDefault))
        .opacity(m.enabled ? 1 : 0.7)
    }

    /// 缓存预设原文 → 黑盒文案（0短/1标准/2长；非法回落标准——SDK 同款口径）
    private func vmodelCachePresetLabel(_ raw: Int) -> String {
        switch raw {
        case 0: return "短"
        case 2: return "长"
        default: return "标准"
        }
    }

    /// NSOpenPanel 选 .vmodel 文件 → 安装流（校验/解包在 ViewModel 后台线程）
    private func pickVModelFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "vmodel") ?? .data]
        panel.message = "选择 VetarModel 导出的 .vmodel 模型文件"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        vm.installVModel(from: url.path)
    }

    // MARK: - 目录源设置区卡

    private var sourcesCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("目录源设置")
                .font(VTheme.Typo.sectionTitle)
                .foregroundStyle(VTheme.textPrimary)
                .padding(.bottom, 6)

            Text("目录索引地址（一行一个）")
                .font(VTheme.Typo.panelTitle)
                .foregroundStyle(VTheme.textPrimary)
            TextEditor(text: $vm.catalogDraft)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 72, maxHeight: 120)
                .padding(4)
                .background(VTheme.bgCard, in: RoundedRectangle(cornerRadius: VTheme.Radius.s))
                .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.s).stroke(VTheme.borderStrong))
                .accessibilityIdentifier("modelPacks.catalogURLs")
            HStack(spacing: 8) {
                Button {
                    vm.saveCatalogURLs()
                } label: {
                    Text("保存目录源").font(VTheme.Typo.caption)
                }
                .buttonStyle(.vPrimary)
                .controlSize(.small)
                .accessibilityIdentifier("modelPacks.saveCatalogURLs")
                // 本地安装入口：选文件夹 → 以 file:// 目录源追加（对齐 file:// 源口径）
                Button {
                    appendLocalCatalogDir()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "folder").font(.system(size: 10))
                        Text("选择本地目录…").font(VTheme.Typo.caption)
                    }
                }
                .buttonStyle(.vSecondary)
                .controlSize(.small)
                .help("选择包含 catalog.json 的本地目录，以 file:// 目录源加入")
                .accessibilityIdentifier("modelPacks.pickLocalDir")
                if vm.savedURLs {
                    Text("已保存 ✓")
                        .font(VTheme.Typo.caption)
                        .foregroundStyle(VTheme.okText)
                }
            }
            Text("支持 http(s):// 远程索引与 file:// 本地目录；多个源按从上到下的顺序合并，同名包以先出现的源为准。")
                .font(VTheme.Typo.micro)
                .foregroundStyle(VTheme.textTertiary)

            Text("模型包安装目录（留空 = 默认）")
                .font(VTheme.Typo.panelTitle)
                .foregroundStyle(VTheme.textPrimary)
                .padding(.top, 8)
            HStack(spacing: 8) {
                TextField("留空使用默认安装根（数据目录/models/packs）", text: $vm.dirDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .vInputStyle()
                    .accessibilityIdentifier("modelPacks.packsDir")
                Button {
                    vm.savePacksDir()
                } label: {
                    Text("保存目录").font(VTheme.Typo.caption)
                }
                .buttonStyle(.vPrimary)
                .controlSize(.small)
                .accessibilityIdentifier("modelPacks.savePacksDir")
                if vm.savedDir {
                    Text("已保存 ✓")
                        .font(VTheme.Typo.caption)
                        .foregroundStyle(VTheme.okText)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VTheme.bgCard, in: RoundedRectangle(cornerRadius: VTheme.Radius.l))
        .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.l).stroke(VTheme.borderSubtle))
    }

    /// NSOpenPanel 选本地目录 → file://<path>/catalog.json 追加到草稿（一行一个）。
    private func appendLocalCatalogDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择包含 catalog.json 的模型包目录"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let line = url.appendingPathComponent("catalog.json").absoluteString
        if vm.catalogDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            vm.catalogDraft = line
        } else {
            vm.catalogDraft += "\n" + line
        }
    }
}
