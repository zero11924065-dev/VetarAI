//
//  ModelPacksPanelViewModel.swift
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

//  模型包管理器面板 ViewModel（逐段对标 subagent/renderer/src/panels/ModelPacksPanel.tsx，627 行）：
//    · 三区：目录（可安装）/ 已安装 / 目录源设置
//    · 实时性：订阅全局资源变更流（resource="model_pack"）——下载生命周期事件
//      （download_start/progress/done/error/cancelled）经 app_events 总线推全局 SSE，
//      data 全量透传（含 received_bytes/total_bytes 字节进度）；gap → 无条件重拉；
//      断流 3s 退避重连、卸载绝不重连
//    · 安装确认链：config.confirm_model_pack_download（默认 true）时先弹窗告知
//      包名/版本/大小/SHA256 前 12 位/来源；境外来源且当前非全量联网时附
//      「同时开启全量联网」勾选（默认勾选；确认且勾选则先 PUT network_switch=proxy 再安装，
//      顺序不可颠倒——反了下载仍直连失败）
//    · 卸载（danger 确认）/ 启停开关（禁用保留文件，乐观更新）/ 取消下载（.partial 保留续传）
//    · 目录源设置：目录索引地址（一行一个，http(s):// 或 file:// 本地目录）+
//      模型包安装目录（留空 = 默认）；保存反馈 2s 消隐
//

import Foundation
import Combine

// MARK: - 纯函数助手（独立成枚举便于单测；规则逐字对齐 TSX 同名函数）

public enum ModelPackFormat {

    /// 任务类型 → 中文徽标文案（对齐 TSX TASK_LABELS）。
    public static let taskLabels: [String: String] = [
        "asr": "语音转文字",
        "chat": "对话",
        "embedding": "嵌入",
    ]

    /// 字节数格式化：GB/MB/KB/B（1024 系；GB/MB 保留 1 位小数，KB 取整）。
    public static func formatSize(_ n: Int64) -> String {
        if n <= 0 { return "0 B" }
        let d = Double(n)
        if d >= 1024 * 1024 * 1024 { return String(format: "%.1f GB", d / (1024 * 1024 * 1024)) }
        if d >= 1024 * 1024 { return String(format: "%.1f MB", d / (1024 * 1024)) }
        if d >= 1024 { return "\(Int(d / 1024)) KB" }
        return "\(n) B"
    }

    /// 从源 URL 取 host；file:// 本地目录返回空串（对齐 TSX hostOf）。
    public static func hostOf(_ src: String) -> String {
        let s = src.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s.hasPrefix("file://") { return "" }
        return URL(string: s)?.host ?? ""
    }

    /// 境外 host 判定：非 .cn 结尾、非 localhost/回环/纯 IP（对齐 TSX isOverseasHost）。
    public static func isOverseasHost(_ host: String) -> Bool {
        if host.isEmpty { return false }
        let h = host.lowercased()
        if h == "localhost" || h == "::1" || h.hasPrefix("127.") { return false }
        // 纯 IP 视为内网/本地
        let ipv4 = #"^\d+\.\d+\.\d+\.\d+$"#
        if h.range(of: ipv4, options: .regularExpression) != nil { return false }
        return !h.hasSuffix(".cn")
    }
}

/// 下载进度（download_start 建条目，progress 更新，done/error/cancelled 清除）。
public struct ModelPackDlProgress: Equatable, Sendable {
    public var received: Int64
    public var total: Int64
    public var file: String?
    /// 0.7.5 W7：实时速率（字节/秒；download_progress 事件 bytes_per_second 字段）
    public var bytesPerSecond: Double

    public init(received: Int64 = 0, total: Int64 = 0, file: String? = nil,
                bytesPerSecond: Double = 0) {
        self.received = received
        self.total = total
        self.file = file
        self.bytesPerSecond = bytesPerSecond
    }

    /// 百分比（0~100；total 未知时 0，对齐 TSX prog.total > 0 ? ... : 0）。
    public var percent: Int {
        total > 0 ? min(100, Int(Double(received) / Double(total) * 100)) : 0
    }
}

@MainActor
public final class ModelPacksPanelViewModel: ObservableObject {

    // ── 视图状态（对齐 TSX useState 集）──
    @Published public private(set) var installed: [InstalledPack] = []
    @Published public private(set) var catalog: [CatalogPack] = []
    /// 安装回传用原始目录条目（catalog_entry 原样回传，保可选键）
    public private(set) var rawCatalogEntries: [String: [String: Any]] = [:]
    @Published public private(set) var sourceErrors: [ModelPackSourceError] = []
    @Published public private(set) var cfg: [String: Any]?
    @Published public private(set) var loading = true
    @Published public private(set) var error: String?
    /// 轻提示条（安装完成/卸载/开关反馈；flash 自动消隐）
    @Published public private(set) var notice: String?
    @Published public private(set) var dlProgress: [String: ModelPackDlProgress] = [:]
    @Published public private(set) var dlErrors: [String: String] = [:]
    /// 已发 install 请求、download_start 未到的等待态（按钮禁用防连点）
    @Published public private(set) var installing: Set<String> = []
    // 目录源设置区草稿与已保存反馈
    @Published public var catalogDraft = ""
    @Published public var dirDraft = ""
    @Published public private(set) var savedURLs = false
    @Published public private(set) var savedDir = false

    // ── 派生 ──
    /// 无源且无错误 → 引导空态（对齐 TSX noSources）
    public var noSources: Bool {
        let urls = (cfg?["model_pack_catalog_urls"] as? [String]) ?? []
        return urls.isEmpty && sourceErrors.isEmpty
    }
    public var confirmDownloadEnabled: Bool {
        // cfg?.confirm_model_pack_download !== false（缺省视为开启）
        (cfg?["confirm_model_pack_download"] as? NSNumber)?.boolValue ?? true
    }
    public var networkSwitch: String { (cfg?["network_switch"] as? String) ?? "" }

    // ── 依赖与注入缝 ──
    private let appState: AppState
    private let clientOverride: (any ModelPacksPanelClient)?
    private let retryIntervalNanos: UInt64
    private let savedFlashNanos: UInt64
    private var logger: AppLogger { appState.logger }
    private var client: (any ModelPacksPanelClient)? { clientOverride ?? (appState.runtime.client as? any ModelPacksPanelClient) }

    /// 确认弹窗注入缝（测试替换；默认走全局 DialogCenter）。
    public var confirmHandler: (String, String, String, Bool, String?, Bool) async -> (ok: Bool, checked: Bool) = { title, message, confirmText, danger, checkboxLabel, checkboxDefault in
        let ok = await DialogCenter.shared.confirm(
            title: title, message: message, confirmText: confirmText,
            danger: danger, checkboxLabel: checkboxLabel, checkboxDefault: checkboxDefault)
        return (ok, DialogCenter.shared.checkboxChecked)
    }

    private var streamTask: Task<Void, Never>?
    private var noticeClearTask: Task<Void, Never>?
    private var savedFlashTask: Task<Void, Never>?
    private var lastSeq = 0
    private var started = false

    public init(appState: AppState,
                clientOverride: (any ModelPacksPanelClient)? = nil,
                retryInterval: TimeInterval = 3,
                savedFlash: TimeInterval = 2) {
        self.appState = appState
        self.clientOverride = clientOverride
        self.retryIntervalNanos = UInt64(retryInterval * 1_000_000_000)
        self.savedFlashNanos = UInt64(savedFlash * 1_000_000_000)
    }

    // MARK: - 生命周期

    /// 挂载：拉列表 + 拉一次配置 + 起资源变更流（对齐两个 useEffect）。
    public func start() {
        guard !started else { return }
        started = true
        Task { await fetchLists() }
        Task { await fetchConfig() }
        startStream()
        // .vmodel 列表为本地注册表读取（无侧车依赖），挂载即刷
        refreshVModels()
    }

    public func stop() {
        started = false
        streamTask?.cancel()
        streamTask = nil
        noticeClearTask?.cancel()
        noticeClearTask = nil
        savedFlashTask?.cancel()
        savedFlashTask = nil
    }

    /// 侧车就绪自愈（W2 收口冒烟实测：面板先于侧车打开时 start() 的拉取/起流
    /// 因 client=nil 早退且不再补；就绪后补拉列表 + 补拉配置（仅当配置尚未拉到）
    /// + 补起流。对标 SettingsPanel 的 onChange(sidecar.status) 自愈口径）。
    public func reloadAfterSidecarReady() {
        guard started else { return }
        Task { await fetchLists() }
        if cfg == nil { Task { await fetchConfig() } }
        if streamTask == nil { startStream() }
    }

    // MARK: - 列表重拉（事件驱动刷新只走这里，不动设置区草稿）

    public func fetchLists() async {
        guard let client else { loading = false; return }
        do {
            // Promise.all 并联（对齐 TSX fetchLists）
            async let inst = client.listModelPacks()
            async let cat = client.fetchModelPackCatalog()
            let (instResp, catResp) = try await (inst, cat)
            installed = instResp.packs
            catalog = catResp.catalog.packs
            rawCatalogEntries = catResp.rawEntries
            sourceErrors = catResp.catalog.source_errors
            error = nil
        } catch {
            self.error = "无法获取模型包列表: \(SidecarError.describe(error))"
        }
        loading = false
    }

    /// 配置只在挂载时拉一次（confirm 开关 / network_switch / 设置区草稿初值），
    /// 事件刷新不走这里——否则下载事件会覆盖用户正在编辑的目录源草稿。
    public func fetchConfig() async {
        guard let client else { return }
        if let c = try? await client.fetchConfig() {
            cfg = c
            catalogDraft = ((c["model_pack_catalog_urls"] as? [String]) ?? []).joined(separator: "\n")
            dirDraft = (c["model_packs_dir"] as? String) ?? ""
        }
        // 配置拉取失败不挡列表：confirm 开关按默认 true 处理
    }

    // MARK: - 全局资源变更流（下载生命周期 + 写操作触发重拉）

    private func startStream() {
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                // client 未就绪（面板先于侧车打开）时不退出，退避后重取。
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

    /// 事件分发（对齐 TSX on(APP_RESOURCE_CHANGED) switch 逐分支）。
    public func apply(event ev: SSEEvent) {
        if let seq = ev.int("seq"), seq > lastSeq { lastSeq = seq }
        switch ev.event {
        case "connected":
            break
        case "gap":
            // 断档对账：无条件重拉（对齐 ev.gap 分支）
            Task { await self.fetchLists() }
        case "resource_changed":
            guard (ev.string("resource") ?? "") == "model_pack" else { return }
            let pid = ev.string("pack_id") ?? ""
            switch ev.string("action") ?? "" {
            case "download_start":
                dlProgress[pid] = ModelPackDlProgress(
                    received: 0, total: Int64(ev.int("total_bytes") ?? 0))
                dlErrors.removeValue(forKey: pid)
            case "download_progress":
                var p = dlProgress[pid] ?? ModelPackDlProgress()
                p.received = Int64(ev.int("received_bytes") ?? 0)
                if let t = ev.int("total_bytes") { p.total = Int64(t) }
                if let f = ev.string("file") { p.file = f }
                if let r = ev.double("bytes_per_second") { p.bytesPerSecond = r }   // 0.7.5 W7 速率
                dlProgress[pid] = p
            case "download_done":
                dlProgress.removeValue(forKey: pid)
                flash("模型包 \(pid) 安装完成", ttl: 4)
                Task { await self.fetchLists() }
            case "download_error":
                dlProgress.removeValue(forKey: pid)
                dlErrors[pid] = ev.string("error") ?? "下载失败"
            case "download_cancelled":
                dlProgress.removeValue(forKey: pid)
                Task { await self.fetchLists() }
            case "update", "delete":
                Task { await self.fetchLists() }
            default:
                break
            }
        default:
            break
        }
    }

    // MARK: - 安装流（确认弹窗含境外全量联网勾选 → install）

    /// 确认弹窗消息体（逐字对齐 TSX message JSX 的文本行）。
    public static func installConfirmMessage(_ p: CatalogPack) -> String {
        var lines = "将从外部来源下载并安装模型包："
        lines += "\n名称：\(p.name.isEmpty ? p.pack_id : p.name)"
        lines += "\n版本：v\(p.version.isEmpty ? "?" : p.version)"
        lines += "\n大小：\(ModelPackFormat.formatSize(p.size_bytes ?? 0))"
        let sha = p.files?.first?.sha256 ?? ""
        if !sha.isEmpty {
            lines += "\nSHA256：\(sha.prefix(12))…"
        }
        lines += "\n来源：\((p.source ?? "").isEmpty ? "（未知）" : (p.source ?? ""))"
        lines += "\n\n请确认来源可信后再下载；取消则不联网、不安装。"
        return lines
    }

    /// 是否附「同时开启全量联网」勾选（境外来源且当前非全量联网）。
    public func offersProxyCheckbox(for p: CatalogPack) -> Bool {
        let host = ModelPackFormat.hostOf(p.source ?? "")
        return ModelPackFormat.isOverseasHost(host) && networkSwitch != "proxy"
    }

    public func install(_ p: CatalogPack) {
        Task { await installAsync(p) }
    }

    private func installAsync(_ p: CatalogPack) async {
        guard let client else { return }
        var enableProxy = false
        if confirmDownloadEnabled {
            let offerProxy = offersProxyCheckbox(for: p)
            let result = await confirmHandler(
                "下载模型包确认",
                Self.installConfirmMessage(p),
                "下载并安装",
                false,
                offerProxy ? "同时开启全量联网（经代理访问海外站点）" : nil,
                true)                       // 勾选默认开（对齐 checkboxDefault: true）
            guard result.ok else { return }  // 取消则不联网、不安装
            if offerProxy && result.checked {
                enableProxy = true
            }
            if enableProxy {
                // 先切全量联网再发安装——顺序反了下载仍会直连失败
                do {
                    try await client.putConfig(["network_switch": "proxy"])
                    var c = cfg ?? [:]
                    c["network_switch"] = "proxy"
                    cfg = c
                } catch {
                    dlErrors[p.pack_id] = "开启全量联网失败: \(SidecarError.describe(error))"
                    return
                }
            }
        }
        installing.insert(p.pack_id)
        dlErrors.removeValue(forKey: p.pack_id)
        do {
            // catalog 条目原样回传（后端校验时忽略 source/installed 等标注键）
            let entry = rawCatalogEntries[p.pack_id] ?? ["pack_id": p.pack_id]
            try await client.installModelPack(packId: p.pack_id, catalogEntry: entry)
            // 进度由 SSE download_start/progress 驱动；409（已安装/下载中）走 catch
        } catch {
            dlErrors[p.pack_id] = "安装请求失败: \(SidecarError.describe(error))"
        }
        installing.remove(p.pack_id)
    }

    // MARK: - 取消下载 / 卸载 / 启停

    public func cancelDownload(_ pid: String) {
        Task {
            guard let client else { return }
            do {
                try await client.cancelModelPackDownload(packId: pid)
                // 进度条目清理由 download_cancelled 事件负责
            } catch {
                dlErrors[pid] = "取消失败: \(SidecarError.describe(error))"
            }
        }
    }

    public func uninstall(_ pack: InstalledPack) {
        Task {
            let displayName = pack.name.isEmpty ? pack.pack_id : pack.name
            let result = await confirmHandler(
                "卸载模型包",
                "确定卸载模型包 \"\(displayName)\"（v\(pack.version.isEmpty ? "?" : pack.version)）？\n将删除其全部文件（含未完成的下载残留）。",
                "卸载",
                true, nil, false)
            guard result.ok, let client else { return }
            error = nil
            do {
                try await client.deleteModelPack(packId: pack.pack_id)
                flash("模型包 \"\(displayName)\" 已卸载", ttl: 4)
                await fetchLists()
            } catch {
                self.error = "卸载失败: \(SidecarError.describe(error))"
            }
        }
    }

    /// 启用/禁用（禁用保留文件，推理侧按 enabled 过滤；乐观更新对齐 TSX setInstalled map）。
    public func toggle(_ pack: InstalledPack) {
        Task {
            guard let client else { return }
            let next = !pack.enabled
            do {
                try await client.toggleModelPack(packId: pack.pack_id, enabled: next)
                installed = installed.map {
                    guard $0.pack_id == pack.pack_id else { return $0 }
                    var copy = $0
                    copy = InstalledPack(
                        pack_id: $0.pack_id, name: $0.name, description: $0.description,
                        version: $0.version, task: $0.task, format: $0.format, driver: $0.driver,
                        status: next ? "installed" : "disabled", enabled: next,
                        installed_at: $0.installed_at, files: $0.files, sha256_ok: $0.sha256_ok,
                        size_bytes: $0.size_bytes, missing_files: $0.missing_files,
                        has_partial: $0.has_partial, dir: $0.dir)
                    return copy
                }
                let displayName = pack.name.isEmpty ? pack.pack_id : pack.name
                flash("模型包 \"\(displayName)\" 已\(next ? "启用" : "禁用")", ttl: 3)
            } catch {
                self.error = "切换失败: \(SidecarError.describe(error))"
            }
        }
    }

    // MARK: - 目录源设置区保存

    public func saveCatalogURLs() {
        Task {
            guard let client else { return }
            let urls = catalogDraft
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            error = nil
            do {
                try await client.putConfig(["model_pack_catalog_urls": urls])
                var c = cfg ?? [:]
                c["model_pack_catalog_urls"] = urls
                cfg = c
                flashSavedURLs()
                await fetchLists()               // 源变了，目录区立即重拉
            } catch {
                self.error = "保存目录源失败: \(SidecarError.describe(error))"
            }
        }
    }

    public func savePacksDir() {
        Task {
            guard let client else { return }
            let dir = dirDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            error = nil
            do {
                try await client.putConfig(["model_packs_dir": dir])
                var c = cfg ?? [:]
                c["model_packs_dir"] = dir
                cfg = c
                flashSavedDir()
            } catch {
                self.error = "保存安装目录失败: \(SidecarError.describe(error))"
            }
        }
    }

    // MARK: - .vmodel（VetarModel 训练产物；.vmodel 集成批）

    /// 已安装 .vmodel 列表（本地注册表读取，无侧车依赖）
    @Published public private(set) var vmodels: [InstalledVModel] = []
    /// 安装进行中（校验+解包 GB 级，按钮禁用防连点）
    @Published public private(set) var vmodelBusy = false

    private var vmodelInstaller: NativeVModelInstaller {
        NativeVModelInstaller(config: appState.runtime.kernel.config)
    }

    /// 本地重刷（挂载/安装/移除/启停后调用）
    public func refreshVModels() {
        vmodels = vmodelInstaller.listInstalled()
    }

    /// 安装流：loadMetadata 快筛 → verify 逐块校验 → extractAssets 流式解包 → 登记。
    /// 后台线程跑（GB 级）；错误一律黑盒/闸门文案（NativeVModelError.message 直展：
    /// 三组口径 + SDK 0.2.0 密钥闸门——激活引导/私模型限定/密钥撤销/登录引导/重试）。
    public func installVModel(from path: String) {
        guard !vmodelBusy else { return }
        vmodelBusy = true
        error = nil
        let installer = vmodelInstaller
        Task.detached { [weak self] in
            do {
                let entry = try await installer.install(fileAt: path)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.vmodelBusy = false
                    self.refreshVModels()
                    self.flash("「\(entry.name)」安装完成，已加入工作室模型池", ttl: 4)
                }
            } catch {
                let msg = (error as? NativeVModelError)?.message ?? "安装失败，请检查磁盘空间后重试"
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.vmodelBusy = false
                    self.error = msg
                }
            }
        }
    }

    /// 移除（danger 确认；删解包目录+清登记，源 .vmodel 文件不动）
    public func removeVModel(_ m: InstalledVModel) {
        Task { [weak self] in
            guard let self else { return }
            let (ok, _) = await self.confirmHandler(
                "移除模型",
                "确定移除「\(m.name)」吗？已解包的文件将被删除，你的 .vmodel 源文件不受影响，可重新安装。",
                "移除", true, nil, false)
            guard ok else { return }
            do {
                try self.vmodelInstaller.remove(id: m.id)
                self.refreshVModels()
                self.flash("已移除「\(m.name)」", ttl: 3)
            } catch {
                self.error = (error as? NativeVModelError)?.message ?? "移除失败，请重试"
            }
        }
    }

    /// 启停（禁用保留文件，工作室模型池按 enabled 过滤）
    public func toggleVModel(_ m: InstalledVModel) {
        do {
            try vmodelInstaller.setEnabled(id: m.id, !m.enabled)
            refreshVModels()
        } catch {
            self.error = (error as? NativeVModelError)?.message ?? "操作失败，请重试"
        }
    }

    // MARK: - 魔塔链接安装（0.7.5 W10 / REQ-FUT-021）

    /// 输入草稿（三形态：模型页链接 / ollama 风格 / SDK 片段）
    @Published public var msInput = ""
    /// 解析+拉取成功的仓库快照（档位选择数据源）
    @Published public private(set) var msSnapshot: ModelScopeRepoSnapshot?
    @Published public private(set) var msResolving = false
    /// 选中档位 id（默认第一档）
    @Published public var msSelectedVariant = ""
    /// 下载进度（nil = 未在下载；NativeModelDownloader 快照含滚动速率）
    @Published public private(set) var msProgress: DownloadProgress?
    @Published public private(set) var msError: String?
    private var msTask: Task<Void, Never>?

    private var msInstaller: NativeModelScopeInstaller {
        NativeModelScopeInstaller(store: appState.runtime.kernel.modelPackStore)
    }

    /// 解析输入并拉取仓库快照（文件列表+license；格式不支持在此报错）
    public func msResolve() {
        guard !msResolving, msProgress == nil else { return }
        msResolving = true
        msError = nil
        msSnapshot = nil
        let installer = msInstaller
        let input = msInput
        Task { [weak self] in
            do {
                let snap = try await installer.resolve(input)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.msSnapshot = snap
                    self.msSelectedVariant = snap.variants.first?.id ?? ""
                    self.msResolving = false
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.msError = error.localizedDescription
                    self.msResolving = false
                }
            }
        }
    }

    /// 下载并安装选中档位（进度含速率上屏；完成刷新列表，安装后全场景平级可选）
    public func msInstall() {
        guard let snap = msSnapshot, msProgress == nil else { return }
        msError = nil
        msProgress = DownloadProgress()
        let installer = msInstaller
        let variantId = msSelectedVariant
        msTask = Task { [weak self] in
            do {
                let pid = try await installer.install(snapshot: snap, variantId: variantId) { [weak self] p in
                    Task { @MainActor in
                        guard let self else { return }
                        self.msProgress = p
                    }
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.msProgress = nil
                    self.msSnapshot = nil
                    self.msInput = ""
                    self.flash("魔塔模型已安装（\(pid)），可在会话/委派/工作室全场景选用", ttl: 5)
                    Task { await self.fetchLists() }
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    self?.msProgress = nil   // .partial 保留，重新安装即续传
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.msProgress = nil
                    self.msError = error.localizedDescription
                }
            }
        }
    }

    /// 取消下载（.partial 保留续传）
    public func msCancel() { msTask?.cancel() }

    // MARK: - 轻提示 / 保存反馈自动消隐

    private func flash(_ text: String, ttl: TimeInterval) {
        notice = text
        noticeClearTask?.cancel()
        noticeClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(ttl * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    private func flashSavedURLs() {
        savedURLs = true
        savedFlashTask?.cancel()
        savedFlashTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.savedFlashNanos ?? 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.savedURLs = false
        }
    }

    private func flashSavedDir() {
        savedDir = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.savedFlashNanos ?? 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.savedDir = false
        }
    }
}
