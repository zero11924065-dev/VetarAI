//
//  WarehouseManagerView.swift
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

//  知识仓库资产管理器（SwiftUI 移植，对标 WarehouseManager.tsx，271 行）：
//    · 说明行（拉模式铁律：永不自动注入模型上下文）
//    · 嵌入模型状态条（bge-m3 可用/不可用 + 已向量化 n/m 条）
//    · 错误条 / 成功信息条
//    · 知识分组列表：全局组 + 各项目组（图标/名称/条数/目录路径 +
//      「导入文件」（NSOpenPanel 多选）+「打开文件夹」）
//    · 重建索引按钮（容灾，tooltip 逐字对齐）
//    · 窗口重获焦点自动刷新（NSApplication.didBecomeActiveNotification）
//  文案逐字对齐现状实现；视觉用 VTheme 近似（接入指南 §3）。
//
//  双形态：embedded=true 时裸内容（嵌进 KnowledgePanel 的「知识仓库」标签）；
//  否则带标题行（独立「仓库管理」面板位）。
//

import SwiftUI
import AppKit

public struct WarehouseManagerView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var vmBox = WarehouseManagerViewModelBox()
    private let embedded: Bool

    public init(embedded: Bool = false) {
        self.embedded = embedded
    }

    public var body: some View {
        if let vm = vmBox.vm {
            WarehouseManagerBody(vm: vm, runtime: appState.runtime, embedded: embedded)
        } else {
            VLoadingView("知识仓库初始化…")
                .frame(minHeight: 120)
                .task { vmBox.attach(appState: appState) }
        }
    }
}

@MainActor
final class WarehouseManagerViewModelBox: ObservableObject {
    @Published var vm: WarehouseManagerViewModel?
    func attach(appState: AppState) {
        if vm == nil { vm = WarehouseManagerViewModel(appState: appState) }
    }
}

private struct WarehouseManagerBody: View {
    @ObservedObject var vm: WarehouseManagerViewModel
    /// 直接观察 NativeRuntime（AppState 不转发子服务发布；历史上经 appState.sidecar 读不触发刷新）
    @ObservedObject var runtime: NativeRuntime
    let embedded: Bool

    var body: some View {
        VCard {
            if embedded {
                content
            } else {
                // 独立面板形态：补标题行（对齐其他面板的标题观感）
                HStack(spacing: 8) {
                    Image(systemName: "internaldrive")
                        .font(.system(size: 14))
                        .foregroundStyle(VTheme.textPrimary)
                    Text("知识仓库管理")
                        .font(VTheme.Typo.sectionTitle)
                        .foregroundStyle(VTheme.textPrimary)
                }
                .padding(.bottom, 12)
                content
            }
        }
        .onAppear { Task { await vm.refresh() } }
        // 侧车就绪自愈：面板先于侧车打开时首拉「连接失败」，就绪后自动补拉
        // P3-W6⑤：nativeReady 于 runtime init 同步点亮、任何视图出现前恒 true，
        // 旧「就绪自愈」onChange（永不触发）随侧车归零删除——首拉在挂载链路上。
        // 问题3修复：Finder 删 .md 后回应用计数自动刷新（后端读取前对账）
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
                vm.onWindowFocus()
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("知识仓库（拉模式）：从会话转移进来的对话/知识，保存为 .md 文件永久存储；只有你在会话框右侧面板显式搜索/勾选时才读取，永不自动注入模型上下文。与「知识库」（自动注入）是不同的东西。项目知识存于项目文件夹的\"知识库\"目录，全局知识存于应用数据目录。在 Finder 删除 .md 文件后，索引会在下次读取时自动对账清除。")
                .font(VTheme.Typo.caption)
                .foregroundStyle(VTheme.textTertiary)
                .lineSpacing(3)
                .padding(.bottom, 12)

            // 嵌入状态条（TSX embedStatus 缺省不渲染）
            // 0.5.2 A1：真懒加载三态——装载中/装载失败单独文案（另起分支，
            // 不动现有 可用/不可用 两态文案）；装载中由 VM 每秒轮询至落地。
            if let st = vm.embedStatus {
                let loading = st.load_state == "loading"
                let failed = st.load_state == "failed"
                let ok = st.available && !loading && !failed
                HStack(spacing: 8) {
                    Image(systemName: loading ? "arrow.triangle.2.circlepath"
                          : ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                    Text(loading
                         ? "语义嵌入（bge-m3 本地）：索引模型装载中…（首次语义检索触发，完成前检索降级为关键词）"
                         : failed
                         ? "语义嵌入（bge-m3 本地）：装载失败（检索自动降级为关键词）"
                         : st.available
                         ? "语义嵌入（bge-m3 本地）：可用 · 已向量化 \(st.entries_embedded)/\(st.entries_total) 条"
                         : "语义嵌入（bge-m3 本地）：不可用（缺少模型文件，检索自动降级为关键词）")
                        .font(VTheme.Typo.caption)
                }
                .foregroundStyle(ok ? VTheme.okText : VTheme.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ok ? VTheme.okBg : VTheme.bgCard,
                            in: RoundedRectangle(cornerRadius: VTheme.Radius.s))
                .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.s)
                    .stroke(ok ? VTheme.okBorder : VTheme.borderDefault))
                .padding(.bottom, 12)
                .accessibilityIdentifier("warehouseMgr.embedStatus")
            }

            if let error = vm.error {
                VCallout(.error, error)
                    .accessibilityIdentifier("warehouseMgr.error")
                    .padding(.bottom, 12)
            }
            if let info = vm.info {
                VCallout(.success, info)
                    .accessibilityIdentifier("warehouseMgr.info")
                    .padding(.bottom, 12)
            }

            // 头行：知识分组 + 重建索引
            HStack {
                Text("知识分组")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(VTheme.textPrimary)
                Spacer()
                Button {
                    vm.rebuild()
                } label: {
                    HStack(spacing: 4) {
                        if vm.loading { ProgressView().controlSize(.small) }
                        Text("重建索引")
                    }
                }
                .buttonStyle(.vSecondary)
                .controlSize(.small)
                .disabled(vm.loading)
                .help("扫描知识目录内全部文档（md / docx / pdf / xlsx / pptx / doc / txt 等）重建索引（索引损坏时容灾）")
                .accessibilityIdentifier("warehouseMgr.rebuild")
            }
            .padding(.bottom, 12)

            if vm.groups.isEmpty && !vm.loading {
                Text("暂无知识分组")
                    .font(VTheme.Typo.caption)
                    .foregroundStyle(VTheme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            }

            ForEach(vm.groups) { g in
                HStack(spacing: 10) {
                    Image(systemName: g.scope == "global" ? "globe" : "folder")
                        .font(.system(size: 14))
                        .foregroundStyle(VTheme.accentText)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(g.project_name)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(VTheme.textPrimary)
                            Text("\(g.count) 条")
                                .font(VTheme.Typo.micro)
                                .foregroundStyle(VTheme.textTertiary)
                        }
                        Text(g.dir.isEmpty ? "（目录不可用）" : g.dir)
                            .font(VTheme.Typo.micro)
                            .foregroundStyle(VTheme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        pickImportFiles(for: g)
                    } label: {
                        HStack(spacing: 4) {
                            if vm.importing == g.dir { ProgressView().controlSize(.small) }
                            Text("导入文件")
                        }
                    }
                    .buttonStyle(.vSecondary)
                    .controlSize(.small)
                    .disabled(vm.importing == g.dir || g.dir.isEmpty)
                    .help("选择本机文件（pdf / docx / xlsx / pptx / txt / md 等）导入本知识组，复制进知识目录并解析索引，可在会话右侧检索")
                    .accessibilityIdentifier("warehouseMgr.import.\(g.id)")

                    Button {
                        vm.openDir(g)
                    } label: {
                        HStack(spacing: 4) {
                            if vm.opening == g.dir { ProgressView().controlSize(.small) }
                            Text("打开文件夹")
                        }
                    }
                    .buttonStyle(.vSecondary)
                    .controlSize(.small)
                    .disabled(vm.opening == g.dir || g.dir.isEmpty)
                    .accessibilityIdentifier("warehouseMgr.openDir.\(g.id)")
                }
                .padding(.vertical, 10)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(VTheme.borderSubtle).frame(height: 1)
                }
            }
        }
    }

    /// 导入文件选择（原生 NSOpenPanel 替代 Electron bridge chooseInputFile：
    /// 多选、仅文件、非递归——拉模式铁律不变，用户主动选）。
    private func pickImportFiles(for g: KnowledgeGroup) {
        let panel = NSOpenPanel()
        panel.title = "选择要导入知识仓库的文件"
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK else { return }   // 用户取消：静默返回
        let paths = panel.urls.map(\.path)
        vm.importFiles(g, paths: paths)
    }
}
