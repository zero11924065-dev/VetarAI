//
//  PluginsPanelViewModel.swift
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

//  插件管理面板 ViewModel（逐段对标 subagent/renderer/src/panels/PluginPanel.tsx 419 行）：
//    · 列表：GET /api/plugins（挂载拉一次 + 全局资源变更流 resource=="plugin"/gap 触发
//      重拉，A13 0.4.22 口径；断流 3s 退避重连、卸载绝不重连）
//    · 安装：POST /api/plugins/install {repo_url}；
//      联网安装确认链（0.4.34 口径）——远端 URL（http/https）**每次必弹**「联网安装确认」，
//      无记忆按钮（DialogCenter.confirm 本身无记忆语义）；境外来源且当前非全量联网时附
//      「同时开启全量联网」勾选（默认勾选；确认且勾选则先 PUT network_switch=proxy 再安装，
//      顺序不可颠倒）；本地路径不弹（后端 guard 对本地直连放行）
//    · 启用/禁用：POST toggle（成功后更新列表 + 提示，对齐 TSX 的 await 后乐观更新）
//    · 卸载：danger 确认（「确定卸载插件 "name"？」）→ DELETE → 重拉
//    · 备注（问题5 0.4.1）：PUT note（空串=清除），行内编辑（Enter 保存 / Esc 取消）
//    · Hooks（checkpoint-049 手动触发方案）：展开/折叠 + 逐钩「触发」按钮
//      （禁用的插件由后端 403 拒绝，UI 同步禁用按钮）；输出映射对齐 TSX 分支
//

import Foundation
import Combine

@MainActor
public final class PluginsPanelViewModel: ObservableObject {

    // ── 视图状态（对齐 PluginPanel.tsx useState 集）──
    @Published public private(set) var plugins: [SidecarPlugin] = []
    @Published public var repoUrl = ""
    @Published public private(set) var loading = false
    @Published public private(set) var installing = false
    @Published public private(set) var error: String?
    @Published public private(set) var notice: String?
    @Published public private(set) var expandedHooks: Set<String> = []
    /// 正在执行的钩子 key = "plugin|hook"（单飞：同一时间只允许一个）
    @Published public private(set) var runningHook: String?
    @Published public private(set) var hookOutputs: [String: PluginHookResult] = [:]
    /// 备注行内编辑态（正在编辑的插件名；draft 为草稿文本）
    @Published public private(set) var editingNote: String?
    @Published public var noteDraft = ""

    // ── 联网安装确认链状态 ──
    /// 配置（只在挂载时拉一次；network_switch 判定用，拉取失败按非全量处理）
    @Published public private(set) var cfg: [String: Any]?
    public var networkSwitch: String { (cfg?["network_switch"] as? String) ?? "" }

    // ── 依赖与注入缝 ──
    private let appState: AppState
    private let clientOverride: (any PluginsPanelClient)?
    private let retryIntervalNanos: UInt64      // 资源变更流断流退避（现状 3000ms）
    private var logger: AppLogger { appState.logger }
    private var client: (any PluginsPanelClient)? {
        clientOverride ?? (appState.runtime.client as? any PluginsPanelClient)
    }

    /// 联网安装确认弹窗注入缝（测试替换；默认走全局 DialogCenter）。
    /// 参数：title / message / confirmText / danger / checkboxLabel? / checkboxDefault；
    /// 返回 (是否确认, 勾选值)。**无记忆按钮**（0.4.34：联网安装类每次必问）。
    public var confirmHandler: (String, String, String, Bool, String?, Bool) async -> (ok: Bool, checked: Bool) = { title, message, confirmText, danger, checkboxLabel, checkboxDefault in
        let ok = await DialogCenter.shared.confirm(
            title: title, message: message, confirmText: confirmText,
            danger: danger, checkboxLabel: checkboxLabel, checkboxDefault: checkboxDefault)
        return (ok, DialogCenter.shared.checkboxChecked)
    }

    /// 卸载确认弹窗注入缝（danger 确认）。
    public var uninstallConfirmHandler: (String, String, String, Bool) async -> Bool = { title, message, confirmText, danger in
        await DialogCenter.shared.confirm(title: title, message: message,
                                          confirmText: confirmText, danger: danger)
    }

    private var streamTask: Task<Void, Never>?
    private var lastSeq = 0
    private var started = false

    public init(appState: AppState,
                clientOverride: (any PluginsPanelClient)? = nil,
                retryInterval: TimeInterval = 3) {
        self.appState = appState
        self.clientOverride = clientOverride
        self.retryIntervalNanos = UInt64(retryInterval * 1_000_000_000)
    }

    // MARK: - 生命周期

    /// 挂载：拉列表 + 拉一次配置 + 起资源变更流（对齐 TSX 两个 useEffect）。
    public func start() {
        guard !started else { return }
        started = true
        Task { await fetchPlugins() }
        Task { await fetchConfig() }
        startStream()
    }

    public func stop() {
        started = false
        streamTask?.cancel()
        streamTask = nil
    }

    /// 侧车就绪自愈（面板先于侧车打开时补拉；对齐 ModelPacks 口径）。
    public func reloadAfterSidecarReady() {
        guard started else { return }
        Task { await fetchPlugins() }
        if cfg == nil { Task { await fetchConfig() } }
        if streamTask == nil { startStream() }
    }

    // MARK: - 列表加载

    public func fetchPlugins() async {
        guard let client else { loading = false; return }
        loading = true
        error = nil
        do {
            plugins = try await client.listPlugins()
        } catch {
            self.error = "无法获取插件列表: \(SidecarError.describe(error))"
        }
        loading = false
    }

    /// 配置只在挂载时拉一次（network_switch 判定用；失败不挡列表）。
    public func fetchConfig() async {
        guard let client else { return }
        cfg = try? await client.fetchConfig()
    }

    // MARK: - 全局资源变更流（A13 0.4.22：Agent/用户装删改插件后实时重拉）

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
                        self.logger.warn("插件资源变更流断开：\(SidecarError.describe(error))，3s 后重连")
                    }
                }
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: self.retryIntervalNanos)
            }
        }
    }

    /// 事件分发（对齐 TSX on(APP_RESOURCE_CHANGED)：gap 无条件重拉；否则只认 plugin 资源）。
    public func apply(event ev: SSEEvent) {
        if let seq = ev.int("seq"), seq > lastSeq { lastSeq = seq }
        switch ev.event {
        case "gap":
            Task { await self.fetchPlugins() }
        case "resource_changed":
            // 对齐 `if (!ev.gap && ev.resource !== 'plugin') return;`
            guard (ev.string("resource") ?? "") == "plugin" else { return }
            Task { await self.fetchPlugins() }
        default:
            break                 // connected / 未知事件忽略，向前兼容
        }
    }

    // MARK: - 安装（联网安装确认链 → install）

    /// 远端 URL 判定（http/https 起头才走联网确认；本地路径直装——后端 guard 同口径）。
    public static func isRemoteURL(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t.hasPrefix("http://") || t.hasPrefix("https://")
    }

    /// 确认弹窗消息体（语义对齐 AuthPrompt net_install 文案，主语换为用户主动安装）。
    public static func installConfirmMessage(_ url: String) -> String {
        """
        将从外部仓库下载并安装插件：

        来源：\(url)

        ⚠️ 这会从外部仓库下载代码并装入应用。请确认来源可信后再允许；拒绝则不联网、不安装。
        """
    }

    /// 是否附「同时开启全量联网」勾选（境外来源且当前非全量联网；复用模型包同口径判定）。
    public func offersProxyCheckbox(for url: String) -> Bool {
        let host = ModelPackFormat.hostOf(url)
        return ModelPackFormat.isOverseasHost(host) && networkSwitch != "proxy"
    }

    public func install() {
        let url = repoUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, !installing else { return }
        Task { await installAsync(url) }
    }

    private func installAsync(_ url: String) async {
        guard let client else { return }
        // 联网安装确认链：远端每次必弹（0.4.34），无记忆按钮
        if Self.isRemoteURL(url) {
            let offerProxy = offersProxyCheckbox(for: url)
            let result = await confirmHandler(
                "联网安装确认",
                Self.installConfirmMessage(url),
                "允许安装",
                true,                       // danger（对齐 net_install 分支红色确认）
                offerProxy ? AuthPrompt.enableNetworkCheckboxLabel : nil,
                true)                       // 勾选默认开
            guard result.ok else { return } // 取消则不联网、不安装
            if offerProxy && result.checked {
                // 先切全量联网再发安装——顺序反了下载仍会直连失败
                do {
                    try await client.putConfig(["network_switch": "proxy"])
                    var c = cfg ?? [:]
                    c["network_switch"] = "proxy"
                    cfg = c
                } catch {
                    self.error = "开启全量联网失败: \(SidecarError.describe(error))"
                    return
                }
            }
        }
        installing = true
        error = nil
        notice = nil
        do {
            let res = try await client.installPlugin(repoUrl: url)
            notice = "插件 \"\(res.name)\" v\(res.version ?? "?") 安装成功"
            repoUrl = ""
            await fetchPlugins()
        } catch {
            self.error = "安装失败: \(SidecarError.describe(error))"
        }
        installing = false
    }

    // MARK: - 卸载（danger 确认）

    public func uninstall(_ name: String) {
        Task { [weak self] in
            guard let self else { return }
            let ok = await self.uninstallConfirmHandler(
                "卸载插件", "确定卸载插件 \"\(name)\"？", "卸载", true)
            guard ok else { return }
            self.error = nil
            self.notice = nil
            do {
                guard let client = self.client else { return }
                try await client.uninstallPlugin(name: name)
                self.notice = "插件 \"\(name)\" 已卸载"
                await self.fetchPlugins()
            } catch {
                self.error = "卸载失败: \(SidecarError.describe(error))"
            }
        }
    }

    // MARK: - 启用/禁用（checkpoint-052 逐项开关；成功后更新列表——对齐 TSX await 后更新）

    public func toggleEnabled(_ plugin: SidecarPlugin) {
        let current = !plugin.isDisabled
        error = nil
        notice = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let client = self.client else { return }
                let newState = try await client.togglePlugin(name: plugin.name, enabled: !current)
                self.plugins = self.plugins.map { p in
                    guard p.name == plugin.name else { return p }
                    return SidecarPlugin(name: p.name, version: p.version,
                                         entry_point: p.entry_point, hooks: p.hooks,
                                         path: p.path, enabled: newState,
                                         note: p.note, description: p.description)
                }
                self.notice = "插件 \"\(plugin.name)\" 已\(newState ? "启用" : "禁用")"
            } catch {
                self.error = "切换失败: \(SidecarError.describe(error))"
            }
        }
    }

    // MARK: - 备注（问题5 0.4.1：行内编辑；空串=清除）

    /// 进入编辑态（草稿初值 = 现有备注）。
    public func beginEditNote(_ plugin: SidecarPlugin) {
        editingNote = plugin.name
        noteDraft = plugin.note ?? ""
    }

    public func cancelEditNote() {
        editingNote = nil
    }

    public func saveNote(_ name: String) {
        error = nil
        let draft = noteDraft
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let client = self.client else { return }
                let saved = try await client.setPluginNote(name: name, note: draft)
                self.plugins = self.plugins.map { p in
                    guard p.name == name else { return p }
                    return SidecarPlugin(name: p.name, version: p.version,
                                         entry_point: p.entry_point, hooks: p.hooks,
                                         path: p.path, enabled: p.enabled,
                                         note: saved, description: p.description)
                }
                self.editingNote = nil
                self.notice = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "插件 \"\(name)\" 备注已清除"
                    : "插件 \"\(name)\" 备注已保存"
            } catch {
                self.error = "备注保存失败: \(SidecarError.describe(error))"
            }
        }
    }

    // MARK: - Hooks（checkpoint-049 手动触发方案）

    public static func hookKey(_ plugin: String, _ hook: String) -> String { "\(plugin)|\(hook)" }

    public func toggleHooksExpanded(_ name: String) {
        if expandedHooks.contains(name) {
            expandedHooks.remove(name)
        } else {
            expandedHooks.insert(name)
        }
    }

    /// 触发钩子（单飞：runningHook 非空时拒绝新触发，对齐 `if (runningHook) return`）。
    public func triggerHook(plugin: String, hook: String) {
        let key = Self.hookKey(plugin, hook)
        guard runningHook == nil else { return }
        runningHook = key
        hookOutputs.removeValue(forKey: key)
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let client = self.client else { return }
                let raw = try await client.triggerPluginHook(plugin: plugin, hook: hook)
                self.hookOutputs[key] = Self.mapHookOutput(raw)
            } catch {
                self.hookOutputs[key] = PluginHookResult(
                    ok: false, text: "触发失败：\(SidecarError.describe(error))")
            }
            self.runningHook = nil
        }
    }

    /// 钩子响应 → 展示文本（逐分支对齐 PluginPanel.tsx handleTriggerHook）：
    ///   · d.error 真值 → 「执行出错：…」（ok=false）
    ///   · d.result 缺失/JSON null → 「（无返回值）」
    ///   · 字符串 result → 原文
    ///   · 其他 → JSON pretty 2 空格缩进
    public static func mapHookOutput(_ d: [String: Any]) -> PluginHookResult {
        if let e = d["error"] as? String, !e.isEmpty {
            return PluginHookResult(ok: false, text: "执行出错：\(e)")
        }
        guard let result = d["result"], !(result is NSNull) else {
            return PluginHookResult(ok: true, text: "（无返回值）")
        }
        if let s = result as? String {
            return PluginHookResult(ok: true, text: s)
        }
        if JSONSerialization.isValidJSONObject(result),
           let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted]),
           let text = String(data: data, encoding: .utf8) {
            return PluginHookResult(ok: true, text: text)
        }
        return PluginHookResult(ok: true, text: "\(result)")
    }
}
