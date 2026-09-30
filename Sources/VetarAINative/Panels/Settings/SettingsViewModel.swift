//
//  SettingsViewModel.swift
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

//  设置页（基础设置分区）ViewModel。读写口径逐条对照
//  subagent/renderer/src/panels/SettingsPanel.tsx：
//    · load()   = tsx load()：GET /api/config；失败「读取配置失败（侧车未运行？）: …」
//    · save()   = tsx save(patch)：PUT /api/config 补丁 → 响应为新全量配置；
//                 成功文案「已保存（端口类改动需重启应用生效）」；失败上屏 detail
//    · loadModels() = tsx loadModels()：GET /api/inference/models；失败回退手动输入
//    · CU 探测 / 压缩记录 / 名单增删 / 授权清单移除 均对照同名函数
//
//  草稿模型：字符串类字段直接写 config.storage（对标 tsx setCfg 单源）；
//  数值类字段用字符串草稿（保存时转换 + ConfigValidator 预校验，范围同后端 _validate）。
//  保存响应回灌时只 resync 本次 patch 涉及的草稿键——避免勾选无关开关时
//  把用户正在输入的数值草稿覆盖掉（tsx 天然无此问题：输入直写 cfg）。
//

import Foundation

@MainActor
public final class SettingsViewModel: ObservableObject {

    // ── 配置主体（nil = 未加载）──
    @Published public private(set) var config: SidecarConfig?
    @Published public var message: String?
    @Published public var errorMessage: String?
    @Published public private(set) var saving = false

    // ── 模型下拉（/api/inference/models；空 → 手动输入回退）──
    @Published public private(set) var modelOptions: [String] = []
    @Published public private(set) var modelsLoading = false

    // ── 列表输入草稿（插件仓库 / 需代理名单 / CU 应用白名单）──
    @Published public var newRepo = ""
    @Published public var newProxyRequired = ""
    @Published public var newWhitelistApp = ""

    // ── 数值字段字符串草稿（保存时转换+校验）──
    @Published public var draftMaxToolRounds = ""
    @Published public var draftReconnectMaxAttempts = ""
    @Published public var draftHeartbeatInterval = ""
    @Published public var draftAuthConfirmTimeout = ""
    @Published public var draftProxyHTTPPort = ""
    @Published public var draftCompactKeepRecent = ""

    // ── 模型特长草稿（独立提交：保存模型特长按钮）──
    @Published public private(set) var strengthsDraft: [String: String] = [:]

    // ── CU 能力探测（nil = 未探测）──
    @Published public private(set) var cuCapabilities: CUCapabilities?
    @Published public private(set) var cuProbing = false

    // ── 压缩记录（nil = 未加载 → 不渲染；[] = 暂无压缩记录）──
    @Published public private(set) var compactLogs: [CompactLogEntry]?

    // ── 依赖注入（测试缝；真实面板经 SettingsViewModelBox 接 AppState）──
    private let clientProvider: () -> SettingsPanelClient?
    private let sessionIdProvider: () -> String?
    private let logger: AppLogger

    /// 上次从后端同步的模型特长（用于「仅在真正变化时重置草稿」，对齐 tsx 的
    /// useEffect(..., [JSON.stringify(strengths)]) 语义）。
    private var lastSyncedStrengths: [String: String] = [:]

    public init(clientProvider: @escaping () -> SettingsPanelClient?,
                sessionIdProvider: @escaping () -> String? = { nil },
                logger: AppLogger = .shared) {
        self.clientProvider = clientProvider
        self.sessionIdProvider = sessionIdProvider
        self.logger = logger
    }

    private var client: SettingsPanelClient? { clientProvider() }

    // MARK: - 生命周期

    /// 面板出现时调用（对标 tsx useEffect([], {load, loadModels}) + CompactLogSection）。
    public func onAppear() {
        if config == nil { Task { await load() } }
        if modelOptions.isEmpty && !modelsLoading { Task { await loadModels() } }
        loadCompactLogs()
    }

    // MARK: - 读取

    public func load() async {
        errorMessage = nil
        guard let client else {
            errorMessage = "读取配置失败: 内核不可用"
            return
        }
        do {
            let cfg = try await client.getConfig()
            applyConfig(cfg, resyncAllDrafts: true)
            logger.info("设置配置已读取（\(cfg.storage.count) 键）")
        } catch {
            errorMessage = "读取配置失败: \(SidecarError.describe(error))"
        }
    }

    public func loadModels() async {
        modelsLoading = true
        defer { modelsLoading = false }
        guard let client else { modelOptions = []; return }
        do {
            modelOptions = try await client.listInferenceModels().map(\.name)
        } catch {
            modelOptions = []   // 拉取失败 → 回退手动输入（tsx 同口径）
            logger.warn("模型列表拉取失败：\(SidecarError.describe(error))")
        }
    }

    // MARK: - 保存（通用补丁通道）

    /// PUT 补丁写回。成功：config 换为后端返回的新全量、message 上屏；
    /// 失败：errorMessage 上屏（客户端预校验文案与后端 400 detail 同口径）。
    /// - Parameter resyncKeys: 保存成功后需要回灌的草稿键（默认 = patch 键）。
    @discardableResult
    public func save(patch: [String: JSONValue],
                     successMessage: String = "已保存（端口类改动需重启应用生效）",
                     errorPrefix: String = "",
                     resyncKeys: [String]? = nil) async -> Bool {
        message = nil
        errorMessage = nil
        if let err = ConfigValidator.validate(patch: patch) {
            errorMessage = errorPrefix + err
            return false
        }
        guard let client else {
            errorMessage = errorPrefix + "内核不可用"
            return false
        }
        saving = true
        defer { saving = false }
        do {
            let newCfg = try await client.updateConfig(patch)
            applyConfig(newCfg, resyncKeys: resyncKeys ?? Array(patch.keys))
            message = successMessage
            logger.info("设置已保存：\(patch.keys.sorted().joined(separator: ","))")
            return true
        } catch {
            errorMessage = errorPrefix + SidecarError.describe(error)
            logger.warn("设置保存失败：\(SidecarError.describe(error))")
            return false
        }
    }

    /// 布尔开关「勾选即保存」（tsx 单键 save 范式；本地先写 storage 让 UI 即时反映，服务端回显确认）。
    public func saveBool(_ key: String, _ value: Bool) {
        config?.set(key, .bool(value))
        Task { await save(patch: [key: .bool(value)]) }
    }

    /// 字符串列表整体替换保存（名单增删共用）。
    private func saveStringList(_ key: String, _ list: [String], successMessage: String? = nil) async {
        if let successMessage {
            await save(patch: [key: .array(list.map { .string($0) })], successMessage: successMessage)
        } else {
            await save(patch: [key: .array(list.map { .string($0) })])
        }
    }

    // MARK: - 保存全部 / 分区保存（草稿键 → storage → 补丁）

    /// 数值草稿键 → storage 键映射。
    private var numericDraftKeys: [String] {
        [SidecarConfig.Key.maxToolRounds, SidecarConfig.Key.reconnectMaxAttempts,
         SidecarConfig.Key.heartbeatInterval, SidecarConfig.Key.authConfirmTimeout,
         SidecarConfig.Key.proxyHTTPPort, SidecarConfig.Key.compactKeepRecent]
    }

    /// 把数值字符串草稿写进 storage（转换失败 → errorMessage 并中止）。
    /// 返回 false = 有非法输入。校验范围交 ConfigValidator（与后端 _validate 对齐）。
    @discardableResult
    private func applyNumericDrafts(keys: [String]) -> Bool {
        guard var cfg = config else { return false }
        for key in keys {
            let raw: String
            switch key {
            case SidecarConfig.Key.maxToolRounds: raw = draftMaxToolRounds
            case SidecarConfig.Key.reconnectMaxAttempts: raw = draftReconnectMaxAttempts
            case SidecarConfig.Key.heartbeatInterval: raw = draftHeartbeatInterval
            case SidecarConfig.Key.authConfirmTimeout: raw = draftAuthConfirmTimeout
            case SidecarConfig.Key.proxyHTTPPort: raw = draftProxyHTTPPort
            case SidecarConfig.Key.compactKeepRecent: raw = draftCompactKeepRecent
            default: continue
            }
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            switch key {
            case SidecarConfig.Key.heartbeatInterval, SidecarConfig.Key.authConfirmTimeout:
                guard let v = Double(trimmed) else {
                    errorMessage = "\(key) 必须是数字"; return false
                }
                cfg.set(key, .double(v))
            default:
                guard let v = Int64(trimmed) else {
                    errorMessage = "\(key) 必须是整数"; return false
                }
                cfg.set(key, .int(v))
            }
        }
        config = cfg
        return true
    }

    /// 「保存全部」= tsx save(cfg)：数值草稿落 storage 后整包回写。
    public func saveAll() async {
        message = nil
        errorMessage = nil
        guard let cfg = config else { return }
        guard applyNumericDrafts(keys: numericDraftKeys) else { return }
        guard let merged = config else { return }
        _ = cfg  // cfg 是应用草稿前的快照；patch 用 merged（含草稿）
        await save(patch: merged.asPatch(), resyncKeys: numericDraftKeys)
    }

    /// 「保存上下文管理」：compact_archive_dir / allow_auto_compact / compact_keep_recent。
    public func saveContextSection() async {
        message = nil
        errorMessage = nil
        let keys = [SidecarConfig.Key.compactArchiveDir,
                    SidecarConfig.Key.allowAutoCompact,
                    SidecarConfig.Key.compactKeepRecent]
        guard applyNumericDrafts(keys: [SidecarConfig.Key.compactKeepRecent]) else { return }
        guard let cfg = config else { return }
        await save(patch: cfg.patch(keys), resyncKeys: keys)
    }

    /// 「保存导出与附件设置」：default_export_dir / vision_parse_attachments。
    public func saveExportSection() async {
        message = nil
        errorMessage = nil
        let keys = [SidecarConfig.Key.defaultExportDir, SidecarConfig.Key.visionParseAttachments]
        guard let cfg = config else { return }
        await save(patch: cfg.patch(keys), resyncKeys: keys)
    }

    /// 「保存多 Agent 设置」：auto_create_sub_agents（tsx 提交 `!== false` 归一值）。
    public func saveMultiAgentSection() async {
        message = nil
        errorMessage = nil
        let value = config?.autoCreateSubAgents ?? true
        await save(patch: [SidecarConfig.Key.autoCreateSubAgents: .bool(value)],
                   resyncKeys: [SidecarConfig.Key.autoCreateSubAgents])
    }

    /// 「保存模型特长」：提交整个 strengthsDraft（单条 ≤100 字由输入层截断 + 校验层兜底）。
    public func saveStrengths() async {
        message = nil
        errorMessage = nil
        await save(patch: [SidecarConfig.Key.modelStrengths: .object(strengthsDraft.mapValues { .string($0) })],
                   resyncKeys: [SidecarConfig.Key.modelStrengths])
    }

    // MARK: - 逐项操作（对标 tsx 同名函数）

    /// 默认模型 / 报错分析模型 / 网络模式（Picker 变更）。
    public func setDraftString(_ key: String, _ value: String) { config?.set(key, .string(value)) }

    public func saveErrorAnalysisModel(_ model: String) {
        config?.errorAnalysisModel = model
        Task { await save(patch: [SidecarConfig.Key.errorAnalysisModel: .string(model)]) }
    }

    public func saveNetworkSwitch(_ display: String) {   // UI 只有 auto/proxy 两档
        config?.networkSwitch = display
        Task { await save(patch: [SidecarConfig.Key.networkSwitch: .string(display)]) }
    }

    /// 插件仓库：追加（不去重，tsx 同）/ 移除。
    public func addPluginRepo() {
        let v = newRepo.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty, config != nil else { return }
        let next = (config?.pluginRepos ?? []) + [v]
        config?.pluginRepos = next
        newRepo = ""
        Task { await saveStringList(SidecarConfig.Key.pluginRepos, next) }
    }
    public func removePluginRepo(_ url: String) {
        let next = (config?.pluginRepos ?? []).filter { $0 != url }
        config?.pluginRepos = next
        Task { await saveStringList(SidecarConfig.Key.pluginRepos, next) }
    }

    /// 「需代理」名单：追加走独立成功/失败文案（tsx addProxyReq），移除走通用 save。
    public func addProxyRequired() {
        let v = newProxyRequired.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty, config != nil else { return }
        let next = (config?.egressProxyRequired ?? []) + [v]
        Task {
            let ok = await save(
                patch: [SidecarConfig.Key.egressProxyRequired: .array(next.map { .string($0) })],
                successMessage: "已加入「需代理」名单：标准模式下将不再尝试直连该域名",
                errorPrefix: "加入「需代理」名单失败: ")
            if ok {
                config?.egressProxyRequired = next
                newProxyRequired = ""
            }
        }
    }
    public func removeProxyRequired(_ v: String) {
        let next = (config?.egressProxyRequired ?? []).filter { $0 != v }
        config?.egressProxyRequired = next
        Task { await saveStringList(SidecarConfig.Key.egressProxyRequired, next) }
    }

    /// 应用内模块控制：勾选/取消某个需确认动作（tsx 逐项 save）。
    public func setAppControlConfirm(_ action: String, on: Bool) {
        var cur = config?.appControlConfirm ?? []
        if on {
            if !cur.contains(action) { cur.append(action) }
        } else {
            cur.removeAll { $0 == action }
        }
        config?.appControlConfirm = cur
        Task { await save(patch: [SidecarConfig.Key.appControlConfirm: .array(cur.map { .string($0) })]) }
    }

    /// CU 应用白名单：追加（去重 + 空串拦截，tsx 按钮 disabled 同口径）/ 移除。
    public func addWhitelistApp() {
        let v = newWhitelistApp.trimmingCharacters(in: .whitespaces)
        let cur = config?.computerUseAppWhitelist ?? []
        guard !v.isEmpty, !cur.contains(v) else { return }
        let next = cur + [v]
        config?.computerUseAppWhitelist = next
        newWhitelistApp = ""
        Task { await saveStringList(SidecarConfig.Key.computerUseAppWhitelist, next) }
    }
    public func removeWhitelistApp(_ app: String) {
        let next = (config?.computerUseAppWhitelist ?? []).filter { $0 != app }
        config?.computerUseAppWhitelist = next
        Task { await saveStringList(SidecarConfig.Key.computerUseAppWhitelist, next) }
    }

    /// 已永久授权的工具：逐条移除 = 写回过滤后的完整数组（tsx 同口径；后端 reload_config 校验结构）。
    public func removeAuthGrant(_ grant: AuthGrant) {
        let next = (config?.authGrants ?? []).filter {
            !($0.tool == grant.tool && $0.action == grant.action)
        }
        config?.authGrants = next
        Task {
            await save(patch: [SidecarConfig.Key.authGrants: .array(next.map { $0.json })],
                       resyncKeys: [SidecarConfig.Key.authGrants])
        }
    }

    // MARK: - 模型特长草稿

    /// 单条编辑：空（trim 后）= 删除该模型记录；否则截断到 100 字（tsx setOne 同口径）。
    public func setStrength(_ model: String, _ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            strengthsDraft.removeValue(forKey: model)
        } else {
            strengthsDraft[model] = String(text.prefix(100))
        }
    }

    // MARK: - Computer Use 探测（tsx ComputerUseSection probe）

    public func probeCU() async {
        cuProbing = true
        defer { cuProbing = false }
        guard let client else {
            cuCapabilities = CUCapabilities(ok: false, problems: ["探测失败：内核不可用"], facts: [:])
            return
        }
        do {
            cuCapabilities = try await client.computerUseCapabilities()
        } catch {
            cuCapabilities = CUCapabilities(
                ok: false,
                problems: ["探测失败：\(SidecarError.describe(error))"],
                facts: [:])
        }
    }

    // MARK: - 压缩记录（tsx CompactLogSection：当前会话无 → []；失败 → []）

    public func loadCompactLogs() {
        guard let sid = sessionIdProvider(), !sid.isEmpty else {
            compactLogs = []
            return
        }
        Task {
            guard let client else { compactLogs = []; return }
            do {
                // tsx 固定 project_id=global（读最近一个会话的压缩记录）
                compactLogs = try await client.compactLog(projectId: "global", sessionId: sid)
            } catch {
                compactLogs = []
            }
        }
    }

    // MARK: - 私有：配置应用与草稿回灌

    /// resyncAllDrafts = true（load）时全部草稿回灌；否则只回灌 resyncKeys 命中的数值草稿，
    /// 模型特长仅在实际变化时重置（对齐 tsx useEffect 依赖 JSON.stringify(strengths)）。
    private func applyConfig(_ cfg: SidecarConfig, resyncAllDrafts: Bool = false, resyncKeys: [String] = []) {
        config = cfg
        func resync(_ key: String, _ apply: () -> Void) {
            if resyncAllDrafts || resyncKeys.contains(key) { apply() }
        }
        resync(SidecarConfig.Key.maxToolRounds) { self.draftMaxToolRounds = String(cfg.maxToolRounds) }
        resync(SidecarConfig.Key.reconnectMaxAttempts) { self.draftReconnectMaxAttempts = String(cfg.reconnectMaxAttempts) }
        resync(SidecarConfig.Key.heartbeatInterval) { self.draftHeartbeatInterval = Self.formatNumber(cfg.heartbeatInterval) }
        resync(SidecarConfig.Key.authConfirmTimeout) { self.draftAuthConfirmTimeout = Self.formatNumber(cfg.authConfirmTimeout) }
        resync(SidecarConfig.Key.proxyHTTPPort) { self.draftProxyHTTPPort = String(cfg.proxyHTTPPort) }
        resync(SidecarConfig.Key.compactKeepRecent) { self.draftCompactKeepRecent = String(cfg.compactKeepRecent) }
        let strengths = cfg.modelStrengths
        if resyncAllDrafts || (resyncKeys.contains(SidecarConfig.Key.modelStrengths) && strengths != lastSyncedStrengths) {
            strengthsDraft = strengths
        }
        lastSyncedStrengths = strengths
    }

    /// 15.0 → "15"，15.5 → "15.5"（数值输入框展示口径）。
    static func formatNumber(_ v: Double) -> String {
        v == v.rounded() && abs(v) < 1e15 ? String(Int64(v)) : String(v)
    }
}
