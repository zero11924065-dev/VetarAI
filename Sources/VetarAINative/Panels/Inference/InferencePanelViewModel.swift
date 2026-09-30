//
//  InferencePanelViewModel.swift
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

//  推理后端面板 ViewModel（逐段对标 subagent/renderer/src/panels/InferencePanel.tsx，463 行）：
//    · 状态区：当前后端 + 在线状态 + 测试连接（refresh 三连：status/models/config）
//    · 后端配置区：Ollama / OpenAI 兼容单选卡（旧 model_package 配置兼容显示），
//      地址 / API Key / 工具开关（PUT /api/config 合并写回）
//    · 推理参数与超时：timeout_connect / timeout_reading / timeout_stream_reading（0=默认）+
//      0.4.31 懒加载设置（ctx_lazy_enabled 默认开 / ctx_lazy_start 默认 12288）
//    · 模型管理区：统一模型列表（活动后端模型 + 已启用模型包，source 徽标区分）、
//      设为默认（只存 default_model，不动 inference_backend）、每模型「参数」入口、
//      拉取 / 删除（仅 Ollama）
//    · A13（0.4.22）：订阅全局资源变更流（resource=inference / gap）实时重拉，
//      断流 3s 退避重连、卸载绝不重连
//
//  消息条自动消隐口径：保存/删除 3s、拉取 5s（对齐 TSX setTimeout 值）。
//

import Foundation
import Combine

@MainActor
public final class InferencePanelViewModel: ObservableObject {

    // ── 视图状态（对齐 TSX useState 集）──
    @Published public private(set) var status: InferenceStatusInfo?
    @Published public private(set) var models: [InferenceModelEntry] = []
    @Published public private(set) var cfg: [String: Any] = [:]
    @Published public private(set) var busy = false
    /// 操作反馈消息（自动消隐；含「失败」=error，含「正在」=info，其余=success）
    @Published public private(set) var message: String?
    @Published public var pullName = ""
    /// 模型列表行点「参数」→ 让下方编辑器展开该模型（受控一次性信号）
    @Published public private(set) var focusModel: String?

    // ── 输入框草稿（TSX 直接以 cfg 为草稿缓冲；SwiftUI 侧拆成显式草稿字段，
    //    cfg 仍是唯一持久化真相，保存后 refresh 重同步草稿）──
    @Published public var ollamaURLDraft = ""
    @Published public var openAIBaseURLDraft = ""
    @Published public var openAIKeyDraft = ""
    @Published public var openAISupportsTools = true
    /// 超时三键草稿（timeout_connect / timeout_reading / timeout_stream_reading）
    @Published public var timeoutDrafts: [String: String] = [
        "timeout_connect": "0", "timeout_reading": "0", "timeout_stream_reading": "0",
    ]
    @Published public var ctxLazyStartDraft = "12288"

    /// 每模型推理参数编辑器（内嵌；onSave 复用本面板 saveBackend）
    public let optionsEditor: ModelOptionsEditorViewModel

    // ── 派生（对齐 TSX 计算值）──
    public var backend: String { (cfg["inference_backend"] as? String) ?? "ollama" }
    public var isOllama: Bool { backend == "ollama" }
    /// 旧配置兼容显示（0.4.30 W2：模型包已并入统一列表并行路由）
    public var isModelPackage: Bool { backend == "model_package" }
    public var defaultModel: String? { cfg["default_model"] as? String }
    public var ctxLazyEnabled: Bool {
        // !== false 口径（缺省 true）
        (cfg["ctx_lazy_enabled"] as? NSNumber)?.boolValue ?? true
    }
    public var modelOptions: [String: [String: Any]] {
        (cfg["model_options"] as? [String: [String: Any]]) ?? [:]
    }

    // ── 依赖与注入缝 ──
    private let appState: AppState
    private let clientOverride: (any InferencePanelClient)?
    private let retryIntervalNanos: UInt64
    private let msgTTL: (save: UInt64, pull: UInt64)
    private var logger: AppLogger { appState.logger }
    private var client: (any InferencePanelClient)? { clientOverride ?? (appState.runtime.client as? any InferencePanelClient) }

    private var streamTask: Task<Void, Never>?
    private var msgClearTask: Task<Void, Never>?
    private var lastSeq = 0
    private var started = false

    public init(appState: AppState,
                clientOverride: (any InferencePanelClient)? = nil,
                retryInterval: TimeInterval = 3,
                saveMessageTTL: TimeInterval = 3,
                pullMessageTTL: TimeInterval = 5) {
        self.appState = appState
        self.clientOverride = clientOverride
        self.retryIntervalNanos = UInt64(retryInterval * 1_000_000_000)
        self.msgTTL = (UInt64(saveMessageTTL * 1_000_000_000), UInt64(pullMessageTTL * 1_000_000_000))
        self.optionsEditor = ModelOptionsEditorViewModel()
        self.optionsEditor.onSaveBridge = { [weak self] patch in
            await self?.saveBackend(patch)
        }
    }

    // MARK: - 生命周期

    /// 挂载：拉一次 + 起全局资源变更流（对齐 useEffect [refresh] + on(APP_RESOURCE_CHANGED)）。
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
        msgClearTask?.cancel()
        msgClearTask = nil
    }

    /// 侧车就绪自愈（W2 收口冒烟实测：面板先于侧车打开时 start() 的 refresh/起流
    /// 因 client=nil 早退且不再补，面板永远空态；就绪后补一次重拉 + 补起流。
    /// 对标 SettingsPanel 的 onChange(sidecar.status) 自愈口径——原生线 UI 与侧车
    /// 同起存在打开竞态，Electron 线由主进程 gate 掉）。
    public func reloadAfterSidecarReady() {
        guard started else { return }
        Task { await refresh() }
        if streamTask == nil { startStream() }
    }

    // MARK: - 数据加载（status 失败保留旧值；models 失败空列表；cfg 失败空字典）

    public func refresh() async {
        guard let client else { return }
        // Promise.all 并联；网络层失败时 TSX 整体 catch 不动状态——这里按端点独立容错近似：
        // status 只在成功时更新（对齐 `if (st) setStatus(st)`），models 失败回落 []，cfg 失败回落 {}
        async let st = try? client.fetchInferenceStatus()
        async let md = try? client.fetchInferenceModels()
        async let cf = try? client.fetchConfig()
        if let st = await st { status = st }
        models = (await md) ?? []
        cfg = (await cf) ?? [:]
        syncDraftsFromConfig()
    }

    /// cfg → 草稿同步（保存成功 / 外部刷新后输入框显示持久化值）。
    private func syncDraftsFromConfig() {
        ollamaURLDraft = (cfg["ollama_base_url"] as? String) ?? ""
        openAIBaseURLDraft = (cfg["inference_base_url"] as? String) ?? ""
        openAIKeyDraft = (cfg["inference_api_key"] as? String) ?? ""
        // !== false 口径
        openAISupportsTools = (cfg["openai_compat_supports_tools"] as? NSNumber)?.boolValue ?? true
        for key in ["timeout_connect", "timeout_reading", "timeout_stream_reading"] {
            let n = (cfg[key] as? NSNumber)?.intValue ?? 0
            timeoutDrafts[key] = String(n)
        }
        let lazyStart = (cfg["ctx_lazy_start"] as? NSNumber)?.intValue ?? 12288
        ctxLazyStartDraft = String(lazyStart)
        optionsEditor.update(cfg: cfg, isOllama: isOllama, isModelPackage: isModelPackage, busy: busy)
    }

    // MARK: - 保存（{...cfg, ...patch} 合并 PUT；未知键随 cfg 原文回传）

    /// 补丁写回（对齐 TSX saveBackend 的可观察行为；后端 reload_config 是合并语义，
    /// 无需也不应把 cfg 全量回写——全量回写会把并行面板在间隙里的改动冲掉）。
    public func saveBackend(_ patch: [String: Any]) async {
        guard let client else { return }
        busy = true
        optionsEditor.busy = true
        message = nil
        do {
            try await client.putConfig(patch)
            setMessage("已保存 ✓")
            await refresh()
        } catch {
            setMessage("保存失败: \(SidecarError.describe(error))")
        }
        busy = false
        optionsEditor.busy = false
        scheduleClearMessage(after: msgTTL.save)
    }

    /// 测试连接：重拉状态（对齐 doTestConnection：busy + 「正在测试连接…」→ refresh → 清消息）。
    public func testConnection() async {
        busy = true
        message = "正在测试连接…"
        await refresh()
        message = nil
        busy = false
    }

    /// 选 Ollama 卡：立即保存并清空 OpenAI 地址（对齐单选 onChange）。
    public func selectOllamaBackend() async {
        await saveBackend(["inference_backend": "ollama", "inference_base_url": ""])
    }

    /// 选 OpenAI 兼容卡：仅本地切换（地址/Key 填好后点「保存并切换」才落库）。
    public func markOpenAICompatibleSelected() {
        var c = cfg
        c["inference_backend"] = "openai_compatible"
        cfg = c
    }

    /// 保存 Ollama 地址（草稿值落库）。
    public func saveOllamaURL() async {
        await saveBackend(["ollama_base_url": ollamaURLDraft])
    }

    /// 保存并切换 OpenAI 兼容后端（地址为空时按钮禁用，见 View）。
    public func saveOpenAICompatible() async {
        await saveBackend([
            "inference_backend": "openai_compatible",
            "inference_base_url": openAIBaseURLDraft,
            "inference_api_key": openAIKeyDraft,
            "openai_compat_supports_tools": openAISupportsTools,
        ])
    }

    /// 保存单个超时键（0 = 用默认值；非法输入按 0 处理，对齐 Number('')=0 口径）。
    public func saveTimeout(_ key: String) async {
        let n = Int(timeoutDrafts[key] ?? "") ?? 0
        await saveBackend([key: max(0, n)])
    }

    /// 懒加载总开关（勾选即保存，!== false 缺省 true）。
    public func setCtxLazyEnabled(_ on: Bool) async {
        await saveBackend(["ctx_lazy_enabled": on])
    }

    /// 懒加载起始档（默认 12288；合法域 2048~1048576 由后端校验）。
    public func saveCtxLazyStart() async {
        let n = Int(ctxLazyStartDraft) ?? 12288
        await saveBackend(["ctx_lazy_start": n])
    }

    /// 设为默认模型：只存 default_model（模型包即 pack_id），不动 inference_backend（0.4.30 W2）。
    public func selectDefaultModel(_ m: InferenceModelEntry) async {
        await saveBackend(["default_model": m.name])
        setMessage(m.isModelPack
            ? "已选为默认模型：\(m.name)（模型包对话时会暂停其它本地模型——换装编排）"
            : "已选为默认模型：\(m.name)")
    }

    /// 模型列表行「参数」按钮：确保 model_options 有该模型条目 → 展开下方编辑器。
    public func configureParams(for name: String) async {
        var mo = modelOptions
        if mo[name] == nil { mo[name] = [:] }
        focusModel = name
        optionsEditor.focus(model: name)
        await saveBackend(["model_options": mo])
    }

    // MARK: - 拉取 / 删除（仅 Ollama；能力表是唯一事实源）

    public func pullModel() async {
        let name = pullName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !busy, let client else { return }
        busy = true
        message = "正在拉取 \(name) …（首次拉取可能较久）"
        do {
            try await client.pullModel(name: name)
            setMessage("拉取完成：\(name)")
            pullName = ""
            await refresh()
        } catch {
            setMessage("拉取失败: \(SidecarError.describe(error))")
        }
        busy = false
        scheduleClearMessage(after: msgTTL.pull)
    }

    public func deleteModel(_ name: String) async {
        let ok = await DialogCenter.shared.confirm(
            title: "删除模型",
            message: "确认删除模型 \(name)？删除后需重新拉取才能使用。",
            confirmText: "删除", danger: true)
        guard ok, let client else { return }
        busy = true
        message = nil
        do {
            try await client.deleteModel(name: name)
            setMessage("已删除：\(name)")
            await refresh()
        } catch {
            setMessage("删除失败: \(SidecarError.describe(error))")
        }
        busy = false
        scheduleClearMessage(after: msgTTL.save)
    }

    // MARK: - 全局资源变更流（A13 0.4.22：inference 资源变更 / gap → 重拉）

    private func startStream() {
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                // client 未就绪（面板先于侧车打开）时不退出，退避后重取——
                // 配合 reloadAfterSidecarReady 兜底竞态。
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
                        self.logger.warn("资源变更流断开：\(SidecarError.describe(error))，3s 后重连")
                    }
                }
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: self.retryIntervalNanos)
            }
        }
    }

    /// 事件分发（对齐 appEvents.ts applyEvent + InferencePanel 订阅条件）。
    public func apply(event ev: SSEEvent) {
        if let seq = ev.int("seq"), seq > lastSeq { lastSeq = seq }
        switch ev.event {
        case "connected":
            break                       // 仅初始化游标（上面已统一处理 seq）
        case "resource_changed":
            let resource = ev.string("resource") ?? ""
            guard resource == "inference" else { return }
            Task { await self.refresh() }
        case "gap":
            // 断档对账：无条件重拉（对齐 ev.gap 分支）
            Task { await self.refresh() }
        default:
            break                       // stream_end / stream_error / 未知：忽略（重连壳兜底）
        }
    }

    // MARK: - 消息自动消隐

    private func setMessage(_ text: String) {
        message = text
    }

    private func scheduleClearMessage(after nanos: UInt64) {
        msgClearTask?.cancel()
        msgClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }
}
