//
//  IndependentAgentsPanelViewModel.swift
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

//  独立 Agent 面板 ViewModel（逐段对标 subagent/renderer/src/panels/IndependentAgentsPanel.tsx，
//  305 行；checkpoint-058/058b/061 形态）：
//    · 独立 Agent = 不属于任何项目的一等公民（全局注册 + ia-<id> 命名空间数据目录，
//      删除项目不影响它；全局记忆/技能/插件照常可用）
//    · 列表：GET /api/independent-agents（挂载拉一次；失败静默记日志——现状 catch{} 语义）
//    · 模型列表：GET /api/ollama/models（创建表单与行内切换共用；失败静默回退后端默认）
//    · 创建：POST {name, model_name?, system_prompt?}——名称缺省「独立 Agent N」；
//      失败弹「创建失败」；成功清空名称/角色设定 + 刷新 + 直接进入对话（选中新建的）
//    · 删除：确认弹窗（危险，文案逐字）→ DELETE；失败弹「删除失败」；
//      删当前选中项清全局选中态（checkpoint-061：杜绝幽灵聊天面板）
//    · 行内切换模型 / 行内编辑角色设定：PUT {model_name} / {system_prompt}（留空保存 = 清除）
//    · 选中：以命名空间 ia-<agentId> 作为会话/存储作用域写 AppState
//      （currentProjectId = "ia-<id>"、currentAgentId = id——对齐 App.tsx selectIndependentAgent）
//

import Foundation
import Combine

@MainActor
public final class IndependentAgentsPanelViewModel: ObservableObject {

    /// checkpoint-058：独立 Agent 命名空间前缀（与后端 INDEP_NS_PREFIX 一致）
    public static let namespacePrefix = "ia-"

    // ── 视图状态（对齐 IndependentAgentsPanel.tsx useState 集）──
    @Published public private(set) var agents: [IndependentAgent] = []
    @Published public private(set) var modelList: [OllamaModel] = []
    @Published public var newName = ""
    @Published public var newModel = ""           // 创建表单选中模型（空 = 后端默认）
    @Published public var newPrompt = ""
    @Published public private(set) var creating = false
    @Published public var editingId: String?
    @Published public var editText = ""
    @Published public private(set) var savingPrompt = false

    // ── 依赖与注入缝 ──
    private let appState: AppState
    private let clientOverride: IndependentAgentsPanelClient?
    /// 删除确认弹窗注入缝（测试替换为免 UI 实现；默认走全局 DialogCenter）
    var confirmDelete: (IndependentAgent) async -> Bool
    /// 提示弹窗注入缝（创建/删除/保存失败）
    var alertPresenter: (String, String) async -> Void

    private var logger: AppLogger { appState.logger }
    private var client: IndependentAgentsPanelClient? {
        clientOverride ?? appState.runtime.client as? IndependentAgentsPanelClient
    }

    private var started = false
    /// 0.7.16 批次7 修复②：模型目录变更总线订阅（.vmodel/模型包装完即刷新下拉，
    /// 不再要重启）；随 stop() 取消、start() 重挂。
    private var modelCatalogBusTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    public init(appState: AppState,
                clientOverride: IndependentAgentsPanelClient? = nil) {
        self.appState = appState
        self.clientOverride = clientOverride
        self.confirmDelete = { agent in
            await DialogCenter.shared.confirm(
                title: "删除独立 Agent",
                message: "删除「\(agent.name)」？其所有会话与消息将被清空，且不可恢复。",
                confirmText: "删除", cancelText: "取消", danger: true)
        }
        self.alertPresenter = { title, message in
            await DialogCenter.shared.alert(title: title, message: message)
        }
    }

    // MARK: - 生命周期

    /// 挂载：拉列表 + 拉模型（对齐 useEffect [] 一次性；现状的 refreshKey/事件总线
    /// 在原生侧由本面板自身变更后显式刷新覆盖——独立 Agent 只能由用户手动建删，
    /// 无委派自动新建场景，不需要 AgentPanel 那种 8s 轮询）
    public func start() {
        guard !started else { return }
        started = true
        Task { await fetchAgents() }
        Task { await fetchModels() }
        // 0.7.16 批次7 修复②：模型目录变更 → 重拉模型下拉（进程内总线直订，
        // ChatViewModel agentBusTask 同款模式）。
        modelCatalogBusTask = Task { [weak self] in
            for await ev in NativeAppEvents.subscribe() {
                guard let self else { return }
                guard NativeAppEvents.isModelCatalogChangedEvent(ev) else { continue }
                await self.fetchModels()
            }
        }
        // 内核就绪（nativeReady）自愈重拉（P3-W6 口径：恒原生，nativeReady 为唯一
        // 就绪信号；历史上为 侧车 ready / 内核接管 双信号 CombineLatest，
        // checkpoint-064 首启空白修复语义由 nativeReady 单信号承接——runtime init
        // 同步点亮，VM start 时本就已就绪，initialLoad 已覆盖首拉）。
        appState.runtime.$nativeReady
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] nativeReady in
                guard let self, self.started, nativeReady else { return }
                Task { await self.fetchAgents() }
                Task { await self.fetchModels() }
            }
            .store(in: &cancellables)
    }

    public func stop() {
        started = false
        modelCatalogBusTask?.cancel()
        modelCatalogBusTask = nil
    }

    // MARK: - 拉取（失败静默记日志，对齐现状 catch{}/console.error——侧车未运行不弹错）

    public func fetchAgents() async {
        guard let client else { return }
        do {
            agents = try await client.listIndependentAgents()
        } catch {
            logger.warn("独立 Agent 列表加载失败：\(SidecarError.describe(error))")
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

    // MARK: - 创建（防重入 / 缺省值链 / 失败弹窗 / 成功后选中新建的进入对话）

    public func create() {
        guard !creating else { return }
        guard let client else { return }
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let nameToUse = name.isEmpty ? "独立 Agent \(agents.count + 1)" : name
        let modelToUse = newModel.isEmpty ? nil : newModel
        let promptTrimmed = newPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let promptToUse = promptTrimmed.isEmpty ? nil : promptTrimmed
        creating = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let newId = try await client.createIndependentAgent(
                    name: nameToUse, modelName: modelToUse, systemPrompt: promptToUse)
                self.newName = ""
                self.newPrompt = ""
                await self.fetchAgents()
                // 现状：创建后直接进入对话；原生侧显式切到聊天主页（问题1联动），
                // 否则新建后用户不知道去哪用
                if let agent = self.agents.first(where: { $0.id == newId }) {
                    self.startChat(agent)
                } else {
                    self.select(id: newId)
                    self.appState.selectPanel(PanelRegistry.chatHome)
                }
            } catch {
                await self.alertPresenter("创建失败", SidecarError.detailText(error))
            }
            self.creating = false
        }
    }

    // MARK: - 删除（确认弹窗 → DELETE；删当前选中项清全局选中态，checkpoint-061）

    public func delete(_ agent: IndependentAgent) {
        Task { [weak self] in
            guard let self else { return }
            let ok = await self.confirmDelete(agent)
            guard ok else { return }
            guard let client else { return }
            do {
                try await client.deleteIndependentAgent(agentId: agent.id)
            } catch {
                await self.alertPresenter("删除失败", SidecarError.detailText(error))
                return
            }
            // checkpoint-061：删除成功 → 若删的是当前选中项，清空选中态，
            // 杜绝「幽灵聊天面板」（面板指向已删除的 ia- 命名空间，继续发消息会重建幽灵数据）
            if self.appState.currentAgentId == agent.id {
                self.appState.currentAgentId = nil
                if self.appState.currentProjectId == Self.namespacePrefix + agent.id {
                    self.appState.currentProjectId = nil
                }
                self.appState.currentSessionId = nil
            }
            await self.fetchAgents()
        }
    }

    // MARK: - 行内切换模型（PUT {model_name}；失败记日志不弹窗，照常刷新对齐现状）

    public func switchModel(_ agent: IndependentAgent, to model: String) {
        guard !model.isEmpty else { return }   // 现状：选中空「默认」占位项不触发
        guard let client else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await client.updateIndependentAgent(
                    agentId: agent.id, update: IndependentAgentUpdateRequest(model_name: model))
            } catch {
                self.logger.error("切换模型失败：\(SidecarError.describe(error))")
            }
            await self.fetchAgents()
            // W6（0.7.4 核销）：emit('agent:updated') 原生等价 = A13 资源总线
            // agent/update——发布侧已在端点层接线（updateIndependentAgent 成功即广播，
            // app.py L356 逐行为），本处无需重复发布；下游 ChatPanel 订阅总线刷新。
        }
    }

    // MARK: - 行内编辑角色设定（PUT {system_prompt}，留空保存则清除）

    public func beginEdit(_ agent: IndependentAgent) {
        editingId = agent.id
        editText = agent.system_prompt ?? ""
    }

    public func cancelEdit() {
        editingId = nil
    }

    public func savePrompt(_ agent: IndependentAgent) {
        guard !savingPrompt else { return }
        guard let client else { return }
        savingPrompt = true
        let text = editText
        Task { [weak self] in
            guard let self else { return }
            do {
                try await client.updateIndependentAgent(
                    agentId: agent.id, update: IndependentAgentUpdateRequest(system_prompt: text))
                self.editingId = nil
                await self.fetchAgents()
            } catch {
                await self.alertPresenter("保存失败", SidecarError.detailText(error))
            }
            self.savingPrompt = false
        }
    }

    // MARK: - 选择（checkpoint-058：以 ia-<id> 命名空间作为项目作用域）

    public func select(_ agent: IndependentAgent) {
        select(id: agent.id)
    }

    /// 按 id 选中（创建成功后直接进入对话共用）
    public func select(id: String) {
        // 对齐 App.tsx selectIndependentAgent：projectId = ia-<agentId>，agentId = id；
        // 换上下文 → 旧会话选择失效
        appState.currentProjectId = Self.namespacePrefix + id
        appState.currentAgentId = id
        appState.currentSessionId = nil
    }

    /// 问题1联动「开始对话」入口：选中该独立 Agent 并切到聊天主页（U2：智能中心常驻聊天）。
    /// U2 起单击行即调本入口（原版 selectIndependentAgent 单击即见聊天）。
    /// 会话面板经 AppState 发布订阅跟随切换上下文（ChatViewModel 联动），
    /// 无需跨面板事件总线。
    public func startChat(_ agent: IndependentAgent) {
        select(agent)
        appState.selectPanel(PanelRegistry.chatHome)
    }

    /// 当前是否选中该独立 Agent（命名空间 + agent 双重一致，供行高亮）
    public func isSelected(_ agent: IndependentAgent) -> Bool {
        appState.currentAgentId == agent.id
    }
}
