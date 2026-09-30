//
//  WarehousePanelViewModel.swift
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

//  知识仓库检索/注入面板 ViewModel（逐段对标 subagent/renderer/src/panels/WarehousePanel.tsx，252 行）：
//    · 拉模式铁律：内容只有用户显式搜索/勾选才读取，永不自动注入模型上下文
//    · 作用域切换（本项目/全局）；挂载/切作用域自动列全量（依赖不含 query——
//      输入框每敲一键绝不发请求，对齐 TSX useEffect [scope, projectId]）
//    · 关键词搜索（FTS5）/ 混合 / 语义（bge-m3）三模式；留空 = 列出全部
//    · 勾选 → POST /knowledge/inject 拼文本 → onInject 回调（父组件/剪贴板兜底）
//    · TS-121 查虫C：外部转移入库后 initialScope 跟随定位（followExternalScope）
//
//  U3（仓库归位）：面板嵌回聊天右端（ChatDetailView 控制 onClose/onInject），
//  与 TSX 嵌在会话框右侧同构；不再注册为系统组独立面板。
//  防御保留：未选项目时禁用「本项目」作用域并强制全局（后端 scope=project 不带
//  project_id 会返回全部项目条目，面板不暴露这口径；嵌入形态下聊天主页必有
//  projectId，该分支理论上不触发）。
//

import Foundation
import Combine

/// 检索模式（对齐 TSX searchMode 三态）。
public enum WarehouseSearchMode: String, CaseIterable, Sendable {
    case hybrid, keyword, semantic

    public var label: String {
        switch self {
        case .hybrid: return "混合"
        case .keyword: return "关键词"
        case .semantic: return "语义"
        }
    }

    /// 对齐 TSX 三枚按钮的 title 提示。
    public var help: String {
        switch self {
        case .hybrid: return "关键词+语义两路融合（默认，最全）"
        case .keyword: return "精确匹配字词（FTS5 全文）"
        case .semantic: return "理解语义找近义内容（bge-m3 本地模型）"
        }
    }
}

/// 仓库作用域（对齐 TSX scope 二态）。
public enum WarehouseScope: String, CaseIterable, Sendable {
    case project, global

    public var label: String {
        switch self {
        case .project: return "本项目"
        case .global: return "全局"
        }
    }
}

@MainActor
public final class WarehousePanelViewModel: ObservableObject {

    // ── 视图状态（对齐 TSX useState 集）──
    @Published public private(set) var scope: WarehouseScope
    @Published public var query = ""
    @Published public private(set) var results: [WarehouseEntry] = []
    @Published public private(set) var checked: Set<String> = []
    @Published public private(set) var searching = false
    @Published public var searchMode: WarehouseSearchMode = .hybrid

    // ── 依赖与注入缝 ──
    private let appState: AppState
    private let clientOverride: (any WarehousePanelClient)?
    private var logger: AppLogger { appState.logger }
    private var client: (any WarehousePanelClient)? {
        clientOverride ?? (appState.runtime.client as? any WarehousePanelClient)
    }

    /// 当前项目（嵌入形态下聊天主页必有值；nil 防御见文件头说明）。
    public var projectId: String? { appState.currentProjectId }

    /// 注入回调（对齐 TSX onInject prop）：父组件把拼好的文本送进会话。
    /// 缺省时 View 层走剪贴板兜底（复制 + Toast），见 WarehousePanelView。
    public var onInject: ((String) -> Void)?

    /// 挂载载入的代际令牌（对齐 TSX cancelled 标志：卸载/切换后旧响应不落盘）。
    private var loadGeneration = 0

    public init(appState: AppState,
                clientOverride: (any WarehousePanelClient)? = nil,
                initialScope: WarehouseScope? = nil,
                onInject: ((String) -> Void)? = nil) {
        self.appState = appState
        self.clientOverride = clientOverride
        self.onInject = onInject
        // TS-121 查虫C：刚转移到哪个作用域，面板就定位到哪个作用域
        self.scope = initialScope ?? .project
        // 无项目时 project 作用域不可用 → 强制全局
        if self.scope == .project && appState.currentProjectId == nil {
            self.scope = .global
        }
    }

    // MARK: - 作用域 / 项目变化

    /// 切换作用域（TSX setScope 触发 useEffect [scope, projectId] → 自动列全量）。
    public func setScope(_ s: WarehouseScope) {
        guard s != scope else { return }
        if s == .project && projectId == nil { return }   // 无项目禁用本项目
        scope = s
        Task { await loadEntries() }
    }

    /// 外部转移入库后的定位跟随（TS-121 查虫C：对齐 useEffect [initialScope]）。
    public func followExternalScope(_ s: WarehouseScope) {
        if s == .project && projectId == nil { return }
        guard s != scope else { return }
        scope = s
        Task { await loadEntries() }
    }

    /// 项目变化 → 重列（scope=project 才有意义；全局作用域不依赖项目）。
    public func onProjectChanged() {
        if scope == .project && projectId == nil { scope = .global }
        Task { await loadEntries() }
    }

    /// 侧车就绪自愈（收口阶段补齐，对齐 ModelPacks/Roundtable 口径）：
    /// 面板先于侧车打开时挂载首拉静默失败、列表停在空态，就绪后自动补拉一次。
    public func reloadAfterSidecarReady() {
        Task { await loadEntries() }
    }

    // MARK: - 列表 / 搜索

    /// 挂载/切作用域时列全量（对齐 TSX 第二个 useEffect：失败静默不清空现有结果之外的状态，
    /// 但 TSX 失败时 setResults 不动——这里保持一致：仅成功才落结果）。
    public func loadEntries() async {
        loadGeneration += 1
        let gen = loadGeneration
        guard let client else { return }
        let pid = scope == .project ? projectId : nil
        if scope == .project && pid == nil { return }
        do {
            let data = try await client.listWarehouseEntries(scope: scope.rawValue, projectId: pid)
            guard gen == loadGeneration else { return }   // 过期响应丢弃
            results = data
            checked = []
        } catch {
            logger.warn("knowledge entries: \(SidecarError.describe(error))")
        }
    }

    /// 搜索（对齐 TSX doSearch：留空 = 列出全部；失败清空结果）。
    public func doSearch() {
        Task {
            guard let client else { return }
            searching = true
            let pid = scope == .project ? projectId : nil
            if scope == .project && pid == nil { searching = false; return }
            let q = query.trimmingCharacters(in: .whitespaces)
            do {
                if q.isEmpty {
                    results = try await client.listWarehouseEntries(scope: scope.rawValue, projectId: pid)
                } else {
                    results = try await client.searchWarehouse(
                        query: q, scope: scope.rawValue, projectId: pid,
                        mode: searchMode.rawValue, limit: 20)
                }
                checked = []
            } catch {
                results = []      // TSX catch 分支：setResults([])
            }
            searching = false
        }
    }

    // MARK: - 勾选 / 注入

    public func toggleCheck(_ id: String) {
        if checked.contains(id) { checked.remove(id) } else { checked.insert(id) }
    }

    /// 发送勾选条目到会话（对齐 TSX handleInject：0 条不动；失败静默——原生落日志）。
    public func inject() {
        guard !checked.isEmpty else { return }
        let ids = Array(checked)
        Task {
            guard let client else { return }
            do {
                let text = try await client.injectWarehouseEntries(entryIds: ids)
                checked = []
                onInject?(text)
            } catch {
                // TSX 静默 catch；原生至少落日志便于排查
                logger.warn("knowledge inject: \(SidecarError.describe(error))")
            }
        }
    }

    // MARK: - 展示辅助（对齐 TSX 结果卡片的文案/空态三分支）

    /// 空态文案（对齐 TSX：searching ? '搜索中…' : (query.trim() ? '无匹配结果' : '暂无知识条目')）。
    public var emptyHint: String {
        if searching { return "搜索中…" }
        return query.trimmingCharacters(in: .whitespaces).isEmpty ? "暂无知识条目" : "无匹配结果"
    }

    /// 相关度得分文案（对齐 TSX：>= 1% 四舍五入百分比，否则三位小数）。
    nonisolated public static func scoreText(_ score: Double) -> String {
        score >= 0.01 ? "\(Int((score * 100).rounded()))%" : String(format: "%.3f", score)
    }
}
