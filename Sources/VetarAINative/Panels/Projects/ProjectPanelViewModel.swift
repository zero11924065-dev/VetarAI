//
//  ProjectPanelViewModel.swift
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

//  项目组面板 ViewModel（逐段对标 subagent/renderer/src/panels/ProjectPanel.tsx，415 行）：
//    · 列表：GET /api/projects（复用 Wave 0 listProjects）
//      首启退避重试 [0, 0.8, 1.5, 2.5, 3.5, 5.0]s（checkpoint-064：封装侧车启动慢，
//      避免「前端先于侧车就绪」的永久连接错误）；侧车变为 ready 时自动重拉（原生自愈）
//    · 新建：原生 NSOpenPanel 目录选择（等价现状 Electron 分支；取消 = 取消创建），
//      选择器不可用 → 内联手动输入（现状 browser fallback 的 manualMode 语义保留）；
//      POST /api/projects {name, working_dir}——R2（0.7.12 实测 A6）起默认名 =
//      绑定文件夹名（重名加序号），旧「项目 N」仅作文件夹名取不到的回退
//    · 选择：写 AppState.currentProjectId（项目是全局上下文源头，Wave 1 口径）；
//      换项目同时清 currentAgentId/currentSessionId（旧项目作用域选择失效，
//      对齐现状 App.tsx selectProject 卸载全部旧聊天面板/退出圆桌的语义）
//    · 删除：确认弹窗（危险，文案逐字）→ DELETE /api/projects/{pid}；
//      删当前选中项清全局选中态（checkpoint-056：杜绝幽灵项目）
//      ⚠️ 现状 fetch 不检 DELETE 响应码——HTTP 错误（如 404）视同完成照常刷新收敛，
//      仅网络层失败跳过刷新（console.error 语义 → 记日志）
//    · 行内改名：PUT /api/projects/{pid} {name}（M5/TS-111；空名不请求直接取消）
//    · 查看根目录：POST /api/projects/open-working-dir（0.4.5）
//    · 工作组导出：POST /api/projects/{pid}/export-workgroup → 6s 闪示通知（TS-121）
//

import Foundation
import Combine
import AppKit

@MainActor
public final class ProjectPanelViewModel: ObservableObject {

    // ── 视图状态（对齐 ProjectPanel.tsx useState 集）──
    @Published public private(set) var projects: [SidecarProject] = []
    @Published public private(set) var loading = false
    @Published public private(set) var error: String?
    /// 工作组导出结果闪示通知（6s 自动消隐；「导出失败」前缀 = error 样式）
    @Published public private(set) var notice: String?
    /// 手动目录输入模式（目录选择器不可用时的内联 fallback）
    @Published public var manualMode = false
    @Published public var manualPath = ""
    /// 行内改名
    @Published public var renamingId: String?
    @Published public var renameValue = ""
    @Published public private(set) var exportingId: String?
    @Published public private(set) var openingDirId: String?

    /// 拉取失败文案（P3-W6 起恒原生架构——失败=内核/数据根读取异常，非侧车断连；
    /// 键名 connectError 保留以免牵动调用点与既有测试引用）
    public static let connectError = "项目数据读取失败，请检查数据根是否可写"

    /// 目录选择结果（原生 NSOpenPanel 映射现状三态：选中 / 取消 / 不可用→手动输入）
    public enum DirectoryPickResult: Equatable {
        case picked(String)
        case cancelled
        case unavailable
    }

    // ── 依赖与注入缝 ──
    private let appState: AppState
    private let clientOverride: ProjectsPanelClient?
    /// 目录选择器（测试注入；默认 NSOpenPanel）
    var pickDirectory: () async -> DirectoryPickResult
    /// 删除确认弹窗注入缝（测试替换为免 UI 实现；默认走全局 DialogCenter）
    var confirmDelete: (String) async -> Bool

    private let retryDelays: [TimeInterval]     // checkpoint-064 首启退避（现状毫秒 → 秒）
    private let noticeTTL: TimeInterval         // 现状 flash 6000ms

    private var logger: AppLogger { appState.logger }
    private var client: ProjectsPanelClient? {
        clientOverride ?? appState.runtime.client as? ProjectsPanelClient
    }

    private var noticeClearTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    public init(appState: AppState,
                clientOverride: ProjectsPanelClient? = nil,
                retryDelays: [TimeInterval] = [0, 0.8, 1.5, 2.5, 3.5, 5.0],
                noticeTTL: TimeInterval = 6) {
        self.appState = appState
        self.clientOverride = clientOverride
        self.retryDelays = retryDelays
        self.noticeTTL = noticeTTL
        self.pickDirectory = { await Self.systemDirectoryPicker() }
        self.confirmDelete = { name in
            await DialogCenter.shared.confirm(
                title: "删除项目",
                message: "删除项目「\(name)」将删除其项目记录与全部对话/Agent/任务数据；你的工作目录中的文件不受影响。删除后不可恢复，确认？",
                confirmText: "删除", cancelText: "取消", danger: true)
        }
    }

    // MARK: - 生命周期

    /// 挂载：首启退避重试拉列表（checkpoint-064）；侧车转 ready 时自愈重拉。
    public func start() {
        guard !started else { return }
        started = true
        Task { await self.initialLoad() }
        // P3-W6：内核就绪（nativeReady）单信号触发自愈重拉（恒原生；历史上为
        // 侧车 ready / 内核接管双信号 CombineLatest，P3-W1a 语义由 nativeReady 承接）。
        appState.runtime.$nativeReady
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] nativeReady in
                guard let self, self.started, nativeReady else { return }
                Task { _ = await self.fetchProjects() }
            }
            .store(in: &cancellables)
    }

    public func stop() {
        started = false
        noticeClearTask?.cancel()
        noticeClearTask = nil
    }

    /// checkpoint-064：首启退避重试（现状 delays=[0,800,1500,2500,3500,5000]ms，最多 ~30s 窗口）。
    /// 每次重试前先上屏「正在读取项目数据…（第 i 次重试，内核启动中）」；成功即清错误并返回；
    /// 全部失败则保留最后的连接错误（错误条上有手动「重试」入口）。
    private func initialLoad() async {
        for (i, delay) in retryDelays.enumerated() {
            if Task.isCancelled { return }
            if delay > 0 {
                error = "正在读取项目数据…（第 \(i) 次重试，内核启动中）"
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if Task.isCancelled { return }
            }
            if await fetchProjects() {
                error = nil
                return
            }
        }
    }

    // MARK: - 拉取（失败上屏连接错误 + 记日志，对齐现状 setError + console.error）

    @discardableResult
    public func fetchProjects() async -> Bool {
        error = nil
        guard let client else {
            error = Self.connectError
            return false
        }
        do {
            projects = try await client.listProjects()
            return true
        } catch {
            self.error = Self.connectError
            logger.warn("项目列表加载失败：\(SidecarError.describe(error))")
            return false
        }
    }

    /// 错误条上的手动「重试」（现状：单次 fetch，不走退避链）
    public func retry() {
        Task { _ = await self.fetchProjects() }
    }

    // MARK: - 新建（目录选择 → createWithDir；取消/不可用分支对齐现状）

    public func create() {
        // 现状：loading || error 时按钮禁用且直接 return
        guard !loading, error == nil, client != nil else { return }
        loading = true
        error = nil
        Task { [weak self] in
            guard let self else { return }
            switch await self.pickDirectory() {
            case .cancelled:
                // 现状 Electron 分支：取消 = 直接取消创建（不回退手动输入）
                self.loading = false
            case .unavailable:
                // 现状 browser 分支末端：选择器不可用 → 内联手动输入
                self.loading = false
                self.manualMode = true
            case .picked(let dir):
                await self.createWithDir(dir)
            }
        }
    }

    /// 用指定目录创建项目（R2 0.7.12 实测 A6：名称缺省 = 绑定文件夹名，
    /// 重名追加序号；成功清手动态并刷新）
    public func createWithDir(_ workingDir: String) async {
        guard let client else { loading = false; return }
        loading = true
        error = nil
        do {
            _ = try await client.createProject(
                name: Self.defaultProjectName(forDir: workingDir,
                                              existingNames: projects.map(\.name)),
                workingDir: workingDir)
            manualMode = false
            manualPath = ""
            _ = await fetchProjects()
        } catch {
            self.error = "创建失败: \(SidecarError.detailText(error))"
            logger.error("创建项目失败：\(SidecarError.describe(error))")
        }
        loading = false
    }

    /// R2（0.7.12 实测 A6）：新建项目默认名 = 绑定文件夹名——消费者心智
    /// 「项目 = 文件夹」（选了「E2E测试项目目录」却叫「项目 1」，与文件夹脱节）。
    /// 与现有项目重名 → 「名 2」「名 3」…取第一个空位；文件夹名取不到
    /// （根目录/纯空白等极端）→ 回退旧口径「项目 N」（N = 现有数 + 1）。
    /// 名字仍可随时行内改名（M5/TS-111 既有能力，本函数只管默认名）。
    public static func defaultProjectName(forDir dir: String, existingNames: [String]) -> String {
        // 尾斜杠先由 lastPathComponent 归一；根目录「/」、纯空白等裁完为空 → 回退
        let base = (dir as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "/")))
        guard !base.isEmpty else { return "项目 \(existingNames.count + 1)" }
        let taken = Set(existingNames)
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// 手动输入确认：留空 = 取消（退出手动模式，不发请求）
    public func createManual() {
        let t = manualPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty {
            manualMode = false
            return
        }
        Task { await self.createWithDir(t) }
    }

    public func cancelManual() {
        manualMode = false
        manualPath = ""
    }

    // MARK: - 选择（项目是全局上下文源头：写 AppState.currentProjectId）

    public func select(_ project: SidecarProject) {
        guard appState.currentProjectId != project.id else { return }
        appState.currentProjectId = project.id
        // 换项目 → 旧项目作用域的 Agent/会话选择失效（对齐 App.tsx selectProject：
        // 换项目卸载全部旧聊天面板、退出圆桌视图；原生侧以清空共享选择表达同语义）
        appState.currentAgentId = nil
        appState.currentSessionId = nil
    }

    /// 问题1联动「去对话」入口：选中项目并切到聊天主页（U2：智能中心常驻聊天）。
    /// 会话面板经 AppState 发布订阅跟随切换（ChatViewModel 联动；只选项目时
    /// 落到主 Agent/首个 Agent——0.7.6 实测 Bug1 新口径：项目无 Agent 不隐式
    /// 创建，会话区空态提示请在左侧 Agent 区「+ 添加」）。
    public func startChat(_ project: SidecarProject) {
        select(project)
        appState.selectPanel(PanelRegistry.chatHome)
    }

    // MARK: - 删除（确认弹窗 → DELETE；删当前项目清全局选中态，checkpoint-056）

    public func delete(_ project: SidecarProject) {
        Task { [weak self] in
            guard let self else { return }
            let ok = await self.confirmDelete(project.name)
            guard ok else { return }
            guard let client else { return }
            do {
                try await client.deleteProject(projectId: project.id)
            } catch let e as SidecarError {
                if case .httpError = e {
                    // 现状 fetch 不检 DELETE 响应码：HTTP 错误（含 404）视同完成，照常收敛
                    logger.warn("删除项目返回 HTTP 错误（按现状口径照常刷新）：\(SidecarError.describe(e))")
                } else {
                    // 网络层失败：现状 console.error 后不刷新
                    logger.error("删除项目失败：\(SidecarError.describe(e))")
                    return
                }
            } catch {
                logger.error("删除项目失败：\(SidecarError.describe(error))")
                return
            }
            // checkpoint-056：删除成功后立即重置选中态——否则界面停留在「幽灵项目」，
            // 用户可继续在其上创建 Agent/发消息，后端查无项目报 422
            if self.appState.currentProjectId == project.id {
                self.appState.currentProjectId = nil
                self.appState.currentAgentId = nil
                self.appState.currentSessionId = nil
            }
            _ = await self.fetchProjects()
        }
    }

    // MARK: - 行内改名（M5/TS-111：空名不请求直接取消；成败都退编辑态 + 刷新）

    public func beginRename(_ project: SidecarProject) {
        renamingId = project.id
        renameValue = project.name
    }

    public func cancelRename() {
        renamingId = nil
        renameValue = ""
    }

    public func saveRename(_ project: SidecarProject) {
        let name = renameValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            renamingId = nil
            return
        }
        guard let client else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await client.renameProject(projectId: project.id, name: name)
            } catch {
                self.error = "改名失败: \(SidecarError.detailText(error))"
            }
            self.renamingId = nil
            self.renameValue = ""
            _ = await self.fetchProjects()
        }
    }

    // MARK: - 查看根目录（0.4.5：Finder 打开项目工作目录；动作级防重）

    public func openWorkingDir(_ project: SidecarProject) {
        guard openingDirId == nil else { return }
        guard let client else { return }
        openingDirId = project.id
        error = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let r = try await client.openWorkingDir(projectId: project.id)
                // 200 但 ok:false（非 macOS / 打开超时）：现状静默忽略；原生记日志备查
                if !r.ok {
                    self.logger.warn("打开工作目录软失败：\(r.detail ?? "未知原因")（\(r.dir)）")
                }
            } catch {
                self.error = "打开工作目录失败: \(SidecarError.detailText(error))"
            }
            self.openingDirId = nil
        }
    }

    // MARK: - 工作组导出（TS-121 0.3.1 补遗2：结果 6s 闪示）

    public func exportWorkgroup(_ project: SidecarProject) {
        guard exportingId == nil else { return }
        guard let client else { return }
        exportingId = project.id
        Task { [weak self] in
            guard let self else { return }
            do {
                let r = try await client.exportWorkgroup(projectId: project.id)
                // 现状展示导出文件所在目录（path 去末段）
                let dir = (r.path as NSString).deletingLastPathComponent
                self.flashNotice("工作组已导出：\(r.name)（目录：\(dir)）")
            } catch {
                self.flashNotice("导出失败：\(SidecarError.detailText(error))")
            }
            self.exportingId = nil
        }
    }

    /// 闪示通知：立即上屏，TTL 后清除（新通知取消旧清除计时，避免新消息被旧定时器提前抹掉）
    private func flashNotice(_ text: String) {
        noticeClearTask?.cancel()
        notice = text
        noticeClearTask = Task { [weak self, noticeTTL] in
            try? await Task.sleep(nanoseconds: UInt64(noticeTTL * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    // MARK: - 原生目录选择器（等价现状 Electron 分支；取消 = 取消创建）

    /// NSOpenPanel 选目录。取消 → .cancelled；异常 → .unavailable（落手动输入）。
    public static func systemDirectoryPicker() async -> DirectoryPickResult {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选择项目工作目录"
        let response = await panel.begin()
        guard response == .OK, let url = panel.url else { return .cancelled }
        return .picked(url.path)
    }
}
