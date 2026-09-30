//
//  WarehouseManagerViewModel.swift
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

//  知识仓库资产管理器 ViewModel（逐段对标 subagent/renderer/src/panels/WarehouseManager.tsx，271 行）：
//    · 资产总览：全局知识组 + 各项目知识组（条数 + 存储目录），读取前后端自动对账
//    · 嵌入模型状态条（bge-m3 可用性 + 向量覆盖率；独立拉取，失败不影响主面板）
//    · 打开文件夹（Finder）/ 重建索引（容灾）/ 导入文件（两趟 ask→策略 冲突处理链）
//    · 窗口重获焦点自动刷新（对齐 TSX window focus + visibilitychange 双时机，
//      用户在 Finder 删 .md 后回应用计数自动更新）
//
//  导入同名冲突链（A11，用户 2026-09-12 拍板"弹窗问用户"，不自动改名也不静默覆盖）：
//    第一趟 on_conflict='ask' —— 不冲突的正常导入，冲突的列在 conflicts 里；
//    有冲突才弹窗，用户选完**只重传冲突的那几个文件**（不重复导入已成功的）；
//    两趟结果相加（第一趟 ask 的 skipped 不含冲突项，第二趟 skip 才含——天然不重叠）。
//

import Foundation
import Combine

@MainActor
public final class WarehouseManagerViewModel: ObservableObject {

    // ── 视图状态（对齐 TSX useState 集）──
    @Published public private(set) var groups: [KnowledgeGroup] = []
    @Published public private(set) var loading = false
    /// 正在打开文件夹的分组 dir（按钮 spinner 用）
    @Published public private(set) var opening: String?
    /// 正在导入的分组 dir
    @Published public private(set) var importing: String?
    @Published public private(set) var error: String?
    @Published public private(set) var info: String?
    /// 嵌入模型状态（nil = 未拉到/拉取失败——TSX embedStatus 缺省不渲染状态条）
    @Published public private(set) var embedStatus: EmbeddingStatus?
    /// 0.5.2 A1：「装载中」轮询代际（防重入——每次触发即作废旧轮询环）。
    private var embedPollGeneration = 0

    // ── 依赖与注入缝 ──
    private let appState: AppState
    private let clientOverride: (any WarehouseManagerClient)?
    private var logger: AppLogger { appState.logger }
    private var client: (any WarehouseManagerClient)? {
        clientOverride ?? (appState.runtime.client as? any WarehouseManagerClient)
    }

    /// 同名冲突选择弹窗注入缝（测试替换；默认走全局 DialogCenter）。
    /// 返回 "overwrite" / "rename" / "skip"；nil = 用户选「不处理（保留原文件）」。
    public var choiceHandler: (String, String) async -> String? = { title, message in
        let v = await DialogCenter.shared.present(VDialogSpec(
            title: title, message: message,
            buttons: [
                VDialogButton("不处理（保留原文件）", role: .secondary, value: "__cancel__"),
                VDialogButton("覆盖同名文件", role: .danger, value: "overwrite"),
                VDialogButton("改名并存", role: .secondary, value: "rename"),
                VDialogButton("跳过这些", role: .secondary, value: "skip"),
            ]))
        return v == "__cancel__" ? nil : v
    }

    public init(appState: AppState, clientOverride: (any WarehouseManagerClient)? = nil) {
        self.appState = appState
        self.clientOverride = clientOverride
    }

    // MARK: - 刷新（分组 + 嵌入状态独立拉取，失败不影响主面板）

    public func refresh() async {
        guard let client else { loading = false; return }
        loading = true
        error = nil
        do {
            groups = try await client.listKnowledgeGroups()
        } catch {
            self.error = "加载知识仓库失败: \(SidecarError.describe(error))"
        }
        loading = false
        // 嵌入状态独立拉取，失败不影响主面板（对齐 TSX 第二个 try 的静默 catch）
        if let s = try? await client.fetchEmbeddingStatus() {
            embedStatus = s
        }
        // 0.5.2 A1：装载中 → 轮询至落地，状态条自动翻牌
        if embedStatus?.load_state == "loading" { pollEmbedStatusWhileLoading() }
    }

    /// 0.5.2 A1：嵌入模型装载期间每秒重拉状态直至落地（loaded/failed），
    /// 状态条从「装载中…」自动翻牌。代际守卫：重复 refresh 不叠加轮询环；
    /// 拉取失败即停（不转圈——下次 refresh 重开）。
    private func pollEmbedStatusWhileLoading() {
        embedPollGeneration += 1
        let gen = embedPollGeneration
        Task { [weak self] in
            while let self, gen == self.embedPollGeneration,
                  self.embedStatus?.load_state == "loading" {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled || gen != self.embedPollGeneration { return }
                guard let client = self.client,
                      let s = try? await client.fetchEmbeddingStatus() else { return }
                self.embedStatus = s
            }
        }
    }

    /// 窗口重获焦点刷新（对齐 TSX focus/visibilitychange 订阅）。
    public func onWindowFocus() {
        Task { await refresh() }
    }

    /// 侧车就绪自愈（面板先于侧车打开时补拉；对齐 ModelPacks/Roundtable 的
    /// reloadAfterSidecarReady 口径——收口阶段补齐：挂载首拉在侧车就绪前会
    /// 「连接失败」，就绪后自动重拉一次）。
    public func reloadAfterSidecarReady() {
        Task { await refresh() }
    }

    // MARK: - 打开文件夹 / 重建索引

    public func openDir(_ g: KnowledgeGroup) {
        Task {
            guard let client else { return }
            opening = g.dir
            do {
                let r = try await client.openKnowledgeDir(scope: g.scope, projectId: g.project_id)
                // 200 但 ok:false（非 macOS / 打开超时）：TSX 静默忽略；原生呈现 detail
                // 便于用户感知失败（差异已记录在 docs/pilot/w3-notes.md）
                if !r.ok, let detail = r.detail, !detail.isEmpty {
                    self.error = "打开文件夹失败: \(detail)"
                }
            } catch {
                self.error = "打开文件夹失败: \(SidecarError.describe(error))"
            }
            opening = nil
        }
    }

    public func rebuild() {
        Task {
            guard let client else { return }
            loading = true
            error = nil
            do {
                try await client.rebuildKnowledgeIndex()
                await refresh()
            } catch {
                self.error = "重建索引失败: \(SidecarError.describe(error))"
            }
            loading = false
        }
    }

    // MARK: - 导入文件（两趟 ask→策略 冲突处理链）

    /// 文件名提取（对齐 TSX baseName：按 / 与 \ 双分隔符取末段）。
    /// 注：Swift split 默认省略空段，尾随分隔符场景返回末段名而非整串回退——
    /// 文件选择器不会产出尾随分隔符的路径，差异不可达。
    nonisolated public static func baseName(_ path: String) -> String {
        let parts = path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        return parts.last.map(String.init) ?? path
    }

    /// 导入汇总文案（对齐 TSX parts 拼装：导入/跳过/失败/同名，顿号连接；全零 → 未导入任何文件）。
    nonisolated public static func importSummary(imported: Int, skipped: Int, failed: Int,
                                     conflictCount: Int) -> String {
        var parts: [String] = []
        if imported > 0 { parts.append("导入 \(imported) 个") }
        if skipped > 0 { parts.append("跳过 \(skipped) 个") }
        if failed > 0 { parts.append("失败 \(failed) 个") }
        if conflictCount > 0 { parts.append("同名 \(conflictCount) 个") }
        return parts.isEmpty ? "未导入任何文件" : parts.joined(separator: "，")
    }

    /// 冲突弹窗消息体（逐字对齐 TSX message 拼装）。
    nonisolated public static func conflictMessage(_ conflicts: [String]) -> String {
        var m = "\(conflicts.count) 个文件在知识目录里已有同名：\n"
        m += conflicts.prefix(8).joined(separator: "\n")
        if conflicts.count > 8 { m += "\n…等共 \(conflicts.count) 个" }
        m += "\n\n要如何处理？（你的本机原始文件不会被改动）"
        return m
    }

    /// 导入入口（paths 来自 View 层 NSOpenPanel；空数组 = 用户取消，静默返回）。
    public func importFiles(_ g: KnowledgeGroup, paths: [String]) {
        guard !paths.isEmpty else { return }
        Task { await importFilesAsync(g, paths: paths) }
    }

    private func importFilesAsync(_ g: KnowledgeGroup, paths: [String]) async {
        guard let client else { return }
        importing = g.dir
        error = nil
        info = nil
        do {
            // 第一趟：ask —— 只导入不冲突的，冲突的报回来
            var result = try await client.importKnowledgeFiles(
                scope: g.scope, projectId: g.project_id, paths: paths, onConflict: "ask")
            let conflicts = result.conflicts

            if !conflicts.isEmpty {
                let choice = await choiceHandler(
                    "知识目录已有同名文件", Self.conflictMessage(conflicts))
                if let choice {
                    // 只重传冲突的那几个（第一趟已把不冲突的成功导入，不能重复）
                    let conflictSet = Set(conflicts)
                    let retryPaths = paths.filter { conflictSet.contains(Self.baseName($0)) }
                    let second = try await client.importKnowledgeFiles(
                        scope: g.scope, projectId: g.project_id,
                        paths: retryPaths, onConflict: choice)
                    // 两趟结果直接相加，无需特判 choice（天然不重叠，见文件头注）
                    result = KnowledgeImportResult(
                        imported: result.imported + second.imported,
                        failed: result.failed + second.failed,
                        skipped: result.skipped + second.skipped,
                        conflicts: second.conflicts,
                        details: result.details + second.details)
                } else {
                    // 用户选择不处理：冲突文件如实计入 skipped
                    result.skipped += conflicts.count
                }
            }

            info = Self.importSummary(imported: result.imported, skipped: result.skipped,
                                      failed: result.failed, conflictCount: conflicts.count)
            await refresh()
        } catch {
            self.error = "导入文件失败: \(SidecarError.describe(error))"
        }
        importing = nil
    }
}
