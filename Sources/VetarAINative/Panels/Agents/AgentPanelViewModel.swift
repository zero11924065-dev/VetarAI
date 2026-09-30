//
//  AgentPanelViewModel.swift
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

//  项目内 Agent 面板 ViewModel（逐段对标 subagent/renderer/src/panels/AgentPanel.tsx）：
//    · 列表：GET /api/agents/{pid}（挂载拉一次 + 8s 轮询——委派执行中后端会
//      自动新建子 Agent，前端无事件通道，轮询兜底，对齐现状 H17 注释语义）
//    · 模型列表：GET /api/ollama/models（创建表单与行内切换共用）
//    · 创建：POST /api/agents {project_id, name, type_, model_name, system_prompt?}
//      名称缺省 "Agent N"；模型缺省选中值 → 列表首个 → 'qwen3.8'（现状兜底链逐字保留）
//    · 删除：确认弹窗（危险）→ DELETE /api/agents/{pid}/{aid}；删当前选中项则清空选择
//    · 行内编辑角色设定：PUT {system_prompt}（留空保存则清除）
//    · 行内切换模型：PUT {model_name}
//

import Foundation
import Combine

@MainActor
public final class AgentPanelViewModel: ObservableObject {

    // ── 视图状态（对齐 AgentPanel.tsx useState 集）──
    @Published public private(set) var agents: [SidecarAgent] = []
    @Published public private(set) var modelList: [OllamaModel] = []
    @Published public var newName = ""
    @Published public var newType = "main"          // 'main' | 'sub'
    @Published public var selectedModel = ""        // 创建表单选中模型（空 = 默认首个）
    @Published public var newPrompt = ""
    @Published public private(set) var creating = false
    @Published public var editingId: String?
    @Published public var editText = ""
    @Published public private(set) var savingPrompt = false

    // ── 依赖与注入缝 ──
    private let appState: AppState
    private let clientOverride: SidecarClientProtocol?
    private let pollIntervalNanos: UInt64           // 现状 8000ms
    /// 确认弹窗 / 提示弹窗注入缝（测试替换为免 UI 实现；默认走全局 DialogCenter）
    var confirmDelete: () async -> Bool
    var alertPresenter: (String, String) async -> Void

    private var logger: AppLogger { appState.logger }
    private var client: SidecarClientProtocol? { clientOverride ?? appState.runtime.client }

    private var pollTask: Task<Void, Never>?
    /// 0.7.16 批次7 修复②：模型目录变更总线订阅（.vmodel/模型包装完即刷新下拉，
    /// 不再要重启）；随 stop() 取消、start() 重挂。
    private var modelCatalogBusTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    public init(appState: AppState,
                clientOverride: SidecarClientProtocol? = nil,
                pollInterval: TimeInterval = 8) {
        self.appState = appState
        self.clientOverride = clientOverride
        self.pollIntervalNanos = UInt64(pollInterval * 1_000_000_000)
        self.confirmDelete = {
            await DialogCenter.shared.confirm(
                title: "删除 Agent",
                message: "删除该 Agent？其所有会话和消息将被清空。",
                confirmText: "删除", cancelText: "取消", danger: true)
        }
        self.alertPresenter = { title, message in
            await DialogCenter.shared.alert(title: title, message: message)
        }
    }

    // MARK: - 生命周期

    /// 挂载：拉列表 + 拉模型 + 起 8s 轮询；项目切换 → 重拉（对齐 useEffect [projectId]）。
    public func start() {
        guard !started else { return }
        started = true
        Task { await fetchAgents() }
        Task { await fetchModels() }
        startPolling()
        // 0.7.16 批次7 修复②：模型目录变更 → 重拉模型下拉（进程内总线直订，
        // ChatViewModel agentBusTask 同款模式）。
        modelCatalogBusTask = Task { [weak self] in
            for await ev in NativeAppEvents.subscribe() {
                guard let self else { return }
                guard NativeAppEvents.isModelCatalogChangedEvent(ev) else { continue }
                await self.fetchModels()
            }
        }
        appState.$currentProjectId
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, self.started else { return }
                self.agents = []
                Task { await self.fetchAgents() }
            }
            .store(in: &cancellables)
    }

    public func stop() {
        started = false
        pollTask?.cancel()
        pollTask = nil
        modelCatalogBusTask?.cancel()
        modelCatalogBusTask = nil
    }

    // MARK: - 拉取（失败静默记日志，对齐前端 console.error 分支——列表面板不弹错）

    public func fetchAgents() async {
        guard let client, let pid = appState.currentProjectId else { return }
        do {
            agents = try await client.listAgents(projectId: pid)
        } catch {
            logger.warn("Agent 列表加载失败：\(SidecarError.describe(error))")
        }
    }

    public func fetchModels() async {
        guard let client else { return }
        do {
            modelList = try await client.listModels()
        } catch {
            logger.warn("模型列表加载失败：\(SidecarError.describe(error))")
        }
    }

    /// 8s 轮询：委派执行中后端可能随时自动新建子 Agent，无事件通道 → 轮询刷新。
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self?.pollIntervalNanos ?? 8_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.fetchAgents()
            }
        }
    }

    // MARK: - 创建（对齐 handleCreate：防重入 / 缺省值链 / 失败弹窗 / 结束必刷新）

    public func create() {
        guard !creating else { return }
        guard let client, let pid = appState.currentProjectId else { return }
        creating = true
        let modelToUse = !selectedModel.isEmpty ? selectedModel : (modelList.first?.name ?? "qwen3.8")
        let nameToUse = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty ? "Agent \(agents.count + 1)" : newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let promptToUse = newPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await client.createAgent(
                    projectId: pid, name: nameToUse, type: self.newType,
                    modelName: modelToUse,
                    systemPrompt: promptToUse.isEmpty ? nil : promptToUse)
                self.newName = ""
                self.newPrompt = ""
            } catch {
                await self.alertPresenter("创建失败", SidecarError.describe(error))
            }
            // 现状实现：无论成败最后都 fetchAgents()
            await self.fetchAgents()
            self.creating = false
        }
    }

    // MARK: - 删除（确认弹窗 → DELETE；删当前选中项清空选择）

    public func delete(_ agent: SidecarAgent) {
        Task { [weak self] in
            guard let self else { return }
            let ok = await self.confirmDelete()
            guard ok else { return }
            guard let client, let pid = self.appState.currentProjectId else { return }
            do {
                try await client.deleteAgent(projectId: pid, agentId: agent.id)
                if self.appState.currentAgentId == agent.id {
                    self.appState.currentAgentId = nil
                }
            } catch {
                // 现状仅 console.error（不弹窗）；原生侧记日志同语义
                self.logger.error("删除 Agent 失败：\(SidecarError.describe(error))")
            }
            await self.fetchAgents()
        }
    }

    // MARK: - 行内编辑角色设定（PUT {system_prompt}，留空保存则清除）

    public func beginEdit(_ agent: SidecarAgent) {
        editingId = agent.id
        editText = agent.system_prompt ?? ""
    }

    public func cancelEdit() {
        editingId = nil
    }

    public func savePrompt(_ agent: SidecarAgent) {
        guard !savingPrompt else { return }
        guard let client, let pid = appState.currentProjectId else { return }
        savingPrompt = true
        let text = editText
        Task { [weak self] in
            guard let self else { return }
            do {
                try await client.updateAgent(projectId: pid, agentId: agent.id,
                                             update: AgentUpdateRequest(system_prompt: text))
                self.editingId = nil
                await self.fetchAgents()
            } catch {
                await self.alertPresenter("保存失败", SidecarError.describe(error))
            }
            self.savingPrompt = false
        }
    }

    // MARK: - 行内切换模型（PUT {model_name}）

    public func changeModel(_ agent: SidecarAgent, to model: String) {
        guard let client, let pid = appState.currentProjectId else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await client.updateAgent(projectId: pid, agentId: agent.id,
                                             update: AgentUpdateRequest(model_name: model))
            } catch {
                // 现状仅 console.error（不弹窗）
                self.logger.error("切换模型失败：\(SidecarError.describe(error))")
            }
            await self.fetchAgents()
            // W6（0.7.4 核销）：emit('agent:updated') 原生等价 = A13 资源总线
            // agent/update——发布侧已在端点层接线（updateAgent 成功即广播，app.py L812
            // 逐行为），本处无需重复发布；下游 ChatPanel 订阅总线刷新 agentInfo。
        }
    }

    // MARK: - 选择（对齐 onSelectAgent）

    public func select(_ agent: SidecarAgent) {
        appState.currentAgentId = agent.id
    }

    /// U2：项目内 Agent 单击 = 选中 + 直达聊天主页（对齐原版 App.tsx selectAgent——
    /// 单击 Agent 即见聊天；照 ProjectPanelViewModel.startChat 模式）。
    /// 行内编辑 / 删除 / 切模型按钮各自独立，不经此路径。
    public func startChat(_ agent: SidecarAgent) {
        select(agent)
        appState.selectPanel(PanelRegistry.chatHome)
    }
}
