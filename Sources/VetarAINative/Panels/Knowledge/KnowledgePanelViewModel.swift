//
//  KnowledgePanelViewModel.swift
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

//  知识记忆面板 ViewModel 集（逐段对标 subagent/renderer/src/panels/KnowledgePanel.tsx，540 行）：
//    · KnowledgeTabViewModel —— 推模式知识库（项目 knowledge/ 目录 .md 增删改/启停；
//      _ 前缀 = 禁用不注入；A13：订阅全局资源变更流，Agent 改知识库后实时重拉，
//      正在编辑时跳过以免列表跳动干扰编辑）
//    · MemoryTabViewModel —— 全局/项目两份记忆（草稿直绑 state，不订阅事件——
//      重拉会冲掉未保存编辑，对齐 TSX 注释口径）
//    · SkillsTabViewModel —— SKILL.md 技能：启停开关/增删改/从仓库或本地路径安装
//  文案逐字对齐现状实现。
//

import Foundation
import Combine

// MARK: - 纯函数助手（独立成枚举便于单测；规则逐字对齐 TSX）

public enum KnowledgeFormat {
    /// 新建文件名归一：补 .md 后缀（对齐 TSX createNew 前两行）。
    /// 返回 nil = 非法输入（空串或仅 ".md"），对应 TSX 「请输入文件名」分支。
    public static func normalizeNewFileName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let name = trimmed.hasSuffix(".md") ? trimmed : trimmed + ".md"
        if name.isEmpty || name == ".md" { return nil }
        return name
    }
}

// MARK: - 知识库标签页 VM

@MainActor
public final class KnowledgeTabViewModel: ObservableObject {

    // ── 视图状态（对齐 TSX KnowledgeTab useState 集）──
    @Published public private(set) var items: [KnowledgeFileItem] = []
    /// 正在编辑的文件名（nil = 未编辑）
    @Published public private(set) var editing: String?
    @Published public var editContent = ""
    @Published public var newName = ""
    @Published public private(set) var busy = false
    @Published public private(set) var error: String?
    @Published public private(set) var loaded = false

    // ── 依赖与注入缝 ──
    private let appState: AppState
    private let clientOverride: (any KnowledgePanelClient)?
    private let retryIntervalNanos: UInt64
    private var logger: AppLogger { appState.logger }
    private var client: (any KnowledgePanelClient)? {
        clientOverride ?? (appState.runtime.client as? any KnowledgePanelClient)
    }
    private var projectId: String? { appState.currentProjectId }

    /// 删除确认弹窗注入缝（测试替换；默认走全局 DialogCenter，danger 口径对齐 TSX）。
    public var confirmHandler: (String, String) async -> Bool = { title, message in
        await DialogCenter.shared.confirm(title: title, message: message,
                                          confirmText: "删除", danger: true)
    }

    private var streamTask: Task<Void, Never>?
    private var lastSeq = 0
    private var started = false

    public init(appState: AppState,
                clientOverride: (any KnowledgePanelClient)? = nil,
                retryInterval: TimeInterval = 3) {
        self.appState = appState
        self.clientOverride = clientOverride
        self.retryIntervalNanos = UInt64(retryInterval * 1_000_000_000)
    }

    // MARK: - 生命周期

    /// 挂载：拉列表 + 起资源变更流（对齐 TSX 两个 useEffect）。
    public func start() {
        guard !started else { return }
        started = true
        Task { await refresh() }
        startStream()
    }

    public func stop() {
        started = false
        streamTask?.cancel()
        streamTask = nil
    }

    /// 侧车就绪自愈（对齐 ModelPacks 面板 W2 收口口径：就绪后补拉 + 补起流）。
    public func reloadAfterSidecarReady() {
        guard started else { return }
        Task { await refresh() }
        if streamTask == nil { startStream() }
    }

    /// 项目切换（TSX useEffect [refresh] 依赖 projectId）。
    public func onProjectChanged() {
        guard started else { return }
        Task { await refresh() }
    }

    // MARK: - 列表

    public func refresh() async {
        guard let projectId else { items = []; loaded = true; return }
        guard let client else { loaded = true; return }
        do {
            items = try await client.listKnowledge(projectId: projectId)
        } catch {
            // TSX 仅 console.error 静默；原生落日志保持一致（不弹错误条打断浏览）
            logger.warn("knowledge list: \(SidecarError.describe(error))")
        }
        loaded = true
    }

    // MARK: - 资源变更流（A13：Agent 改知识库后实时重拉；editing 守卫）

    private func startStream() {
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let client = self.client else {
                    try? await Task.sleep(nanoseconds: self.retryIntervalNanos)
                    continue
                }
                do {
                    for try await ev in client.appEventsStream(since: self.lastSeq) {
                        if Task.isCancelled { break }
                        self.apply(event: ev)
                    }
                } catch {
                    if !Task.isCancelled {
                        self.logger.warn("知识库资源变更流断开：\(SidecarError.describe(error))，3s 后重连")
                    }
                }
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: self.retryIntervalNanos)
            }
        }
    }

    /// 事件分发（对齐 TSX on(APP_RESOURCE_CHANGED)：
    /// `if (!ev.gap && ev.resource !== 'knowledge') return; if (editing) return; refresh()`）。
    public func apply(event ev: SSEEvent) {
        if let seq = ev.int("seq"), seq > lastSeq { lastSeq = seq }
        switch ev.event {
        case "gap":
            guard editing == nil else { return }
            Task { await self.refresh() }
        case "resource_changed":
            guard (ev.string("resource") ?? "") == "knowledge" else { return }
            // editing 守卫：正在编辑某条时跳过重拉（重拉只更新 items，不碰 editContent 草稿）
            guard editing == nil else { return }
            Task { await self.refresh() }
        default:
            break
        }
    }

    // MARK: - 编辑 / 保存 / 新建

    public func openEdit(_ name: String) {
        Task {
            guard let projectId, let client else { return }
            do {
                let d = try await client.readKnowledge(projectId: projectId, name: name)
                editing = name
                editContent = d.content
                error = nil
            } catch {
                // 注：catch 隐式绑定 error 遮蔽同名属性，赋值必须显式 self.
                self.error = "读取失败: \(SidecarError.describe(error))"
            }
        }
    }

    public func cancelEdit() {
        editing = nil
    }

    public func saveEdit(_ name: String) {
        Task {
            guard let projectId, let client else { return }
            busy = true
            error = nil
            do {
                try await client.writeKnowledge(projectId: projectId, name: name, content: editContent)
                editing = nil
                await refresh()
            } catch {
                self.error = "保存失败: \(SidecarError.describe(error))"
            }
            busy = false
        }
    }

    public func createNew() {
        guard let name = KnowledgeFormat.normalizeNewFileName(newName) else {
            error = "请输入文件名"
            return
        }
        Task {
            guard let projectId, let client else { return }
            busy = true
            error = nil
            do {
                try await client.writeKnowledge(projectId: projectId, name: name, content: "")
                newName = ""
                await refresh()
            } catch {
                self.error = "新建失败: \(SidecarError.describe(error))"
            }
            busy = false
        }
    }

    // MARK: - 启停 / 删除

    public func toggle(_ name: String) {
        Task {
            guard let projectId, let client else { return }
            do {
                try await client.toggleKnowledge(projectId: projectId, name: name)
                await refresh()      // 对齐 TSX：成功与 HTTP 错误都重拉
            } catch let e as SidecarError {
                // HTTP 错误（如 400 同名冲突）：呈现 detail 后仍重拉
                if case .httpError(_, let detail) = e {
                    self.error = detail.isEmpty ? "切换失败" : detail
                    await refresh()
                } else {
                    self.error = "切换失败: \(SidecarError.describe(e))"
                }
            } catch {
                self.error = "切换失败: \(SidecarError.describe(error))"
            }
        }
    }

    public func remove(_ name: String) {
        Task {
            let ok = await confirmHandler("删除知识文件", "删除知识文件 \(name)？")
            guard ok, let projectId, let client else { return }
            do {
                try await client.deleteKnowledge(projectId: projectId, name: name)
                await refresh()
            } catch {
                self.error = "删除失败: \(SidecarError.describe(error))"
            }
        }
    }
}

// MARK: - 记忆标签页 VM

@MainActor
public final class MemoryTabViewModel: ObservableObject {

    // ── 视图状态（对齐 TSX MemoryTab useState 集）──
    @Published public var globalMem = ""
    @Published public var projectMem = ""
    @Published public private(set) var busy = false
    /// 轻提示条文案（"已保存 ✓" 2500ms 消隐；"保存失败: …" 常驻）
    @Published public private(set) var msg: String?
    @Published public private(set) var loaded = false

    /// 对齐 TSX `msg.startsWith('保存失败') ? 'error' : 'success'`。
    public var msgIsError: Bool { msg?.hasPrefix("保存失败") == true }

    private let appState: AppState
    private let clientOverride: (any KnowledgePanelClient)?
    private let flashNanos: UInt64
    private var logger: AppLogger { appState.logger }
    private var client: (any KnowledgePanelClient)? {
        clientOverride ?? (appState.runtime.client as? any KnowledgePanelClient)
    }
    private var projectId: String? { appState.currentProjectId }
    private var flashTask: Task<Void, Never>?

    public init(appState: AppState,
                clientOverride: (any KnowledgePanelClient)? = nil,
                flashInterval: TimeInterval = 2.5) {
        self.appState = appState
        self.clientOverride = clientOverride
        self.flashNanos = UInt64(flashInterval * 1_000_000_000)
    }

    // MARK: - 载入（全局必拉；项目记忆仅选了项目才拉。失败静默，对齐 TSX）

    public func load() {
        Task {
            guard let client else { loaded = true; return }
            if let g = try? await client.readMemory(scope: "global", projectId: nil) {
                globalMem = g.content
            }
            if let projectId,
               let p = try? await client.readMemory(scope: "project", projectId: projectId) {
                projectMem = p.content
            }
            loaded = true
        }
    }

    // MARK: - 保存

    public func save(scope: String) {
        let content = scope == "global" ? globalMem : projectMem
        Task {
            guard let client else { return }
            busy = true
            msg = nil
            do {
                try await client.writeMemory(scope: scope, projectId: projectId, content: content)
                flash("已保存 ✓")
            } catch {
                msg = "保存失败: \(SidecarError.describe(error))"
            }
            busy = false
        }
    }

    /// 成功文案 2500ms 消隐（对齐 TSX flash(setMsg, '已保存 ✓', 2500)）。
    private func flash(_ text: String) {
        msg = text
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.flashNanos ?? 2_500_000_000)
            guard !Task.isCancelled else { return }
            self?.msg = nil
        }
    }
}

// MARK: - 技能标签页 VM

@MainActor
public final class SkillsTabViewModel: ObservableObject {

    /// 编辑/新建表单（对齐 TSX form useState）。
    public struct SkillForm: Equatable {
        public var name = ""
        public var description = ""
        public var body = ""
        public init() {}
    }

    // ── 视图状态（对齐 TSX SkillsTab useState 集）──
    @Published public private(set) var skills: [SkillItem] = []
    /// 正在编辑的技能 dir_name
    @Published public private(set) var editing: String?
    @Published public var form = SkillForm()
    @Published public private(set) var creating = false
    @Published public var installUrl = ""
    @Published public private(set) var busy = false
    @Published public private(set) var error: String?
    @Published public private(set) var loaded = false

    /// 表单可见性（对齐 TSX `creating || editing`）。
    public var formVisible: Bool { creating || editing != nil }
    /// 保存路径分支（对齐 TSX save(creating && !editing)）。
    public var savingIsNew: Bool { creating && editing == nil }

    private let appState: AppState
    private let clientOverride: (any KnowledgePanelClient)?
    private var logger: AppLogger { appState.logger }
    private var client: (any KnowledgePanelClient)? {
        clientOverride ?? (appState.runtime.client as? any KnowledgePanelClient)
    }

    /// 删除确认弹窗注入缝（对齐 TSX confirmDialog danger）。
    public var confirmHandler: (String, String) async -> Bool = { title, message in
        await DialogCenter.shared.confirm(title: title, message: message,
                                          confirmText: "删除", danger: true)
    }

    public init(appState: AppState, clientOverride: (any KnowledgePanelClient)? = nil) {
        self.appState = appState
        self.clientOverride = clientOverride
    }

    // MARK: - 列表

    public func refresh() {
        Task {
            guard let client else { loaded = true; return }
            do {
                skills = try await client.listSkills()
            } catch {
                logger.warn("skills list: \(SidecarError.describe(error))")
            }
            loaded = true
        }
    }

    // MARK: - 新建 / 编辑 / 保存

    public func toggleCreating() {
        creating.toggle()
        editing = nil
    }

    public func openEdit(_ dirName: String) {
        Task {
            guard let client else { return }
            do {
                let d = try await client.readSkill(dirName: dirName)
                editing = dirName
                form = SkillForm()
                form.name = d.name.isEmpty ? dirName : d.name
                form.description = d.description
                form.body = d.content
                error = nil
            } catch {
                self.error = "读取失败: \(SidecarError.describe(error))"
            }
        }
    }

    public func cancelForm() {
        creating = false
        editing = nil
    }

    public func save() {
        let name = form.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            error = "请输入技能名"
            return
        }
        let isNew = savingIsNew
        Task {
            guard let client else { return }
            busy = true
            error = nil
            do {
                if isNew {
                    try await client.createSkill(name: name, description: form.description,
                                                 body: form.body, enabled: true)
                } else {
                    try await client.updateSkill(dirName: editing ?? name,
                                                 description: form.description,
                                                 body: form.body, enabled: true)
                }
                creating = false
                editing = nil
                form = SkillForm()
                refresh()
            } catch {
                self.error = "保存失败: \(SidecarError.describe(error))"
            }
            busy = false
        }
    }

    // MARK: - 启停 / 删除 / 安装

    public func toggle(_ dirName: String) {
        Task {
            guard let client else { return }
            do {
                try await client.toggleSkill(dirName: dirName)
                refresh()            // 对齐 TSX：成功与 HTTP 错误都重拉
            } catch let e as SidecarError {
                if case .httpError(_, let detail) = e {
                    self.error = detail.isEmpty ? "切换失败" : detail
                    refresh()
                } else {
                    self.error = "切换失败: \(SidecarError.describe(e))"
                }
            } catch {
                self.error = "切换失败: \(SidecarError.describe(error))"
            }
        }
    }

    public func remove(_ dirName: String) {
        Task {
            let ok = await confirmHandler("删除技能", "删除技能 \(dirName)？")
            guard ok, let client else { return }
            do {
                try await client.deleteSkill(dirName: dirName)
                refresh()
            } catch {
                self.error = "删除失败: \(SidecarError.describe(error))"
            }
        }
    }

    public func install() {
        let url = installUrl.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else {
            error = "请输入仓库地址或本地路径"
            return
        }
        Task {
            guard let client else { return }
            busy = true
            error = nil
            do {
                try await client.installSkill(url: url)
                installUrl = ""
                refresh()
            } catch {
                self.error = "安装失败: \(SidecarError.describe(error))"
            }
            busy = false
        }
    }
}
