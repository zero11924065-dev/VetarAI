//
//  SidecarConfig.swift
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

//  侧车 config.json 的 Codable 模型 + 客户端校验。
//
//  设计前提（任务硬约束）：**设置读写丢键是灾难**。
//  后端 GET /api/config 返回 defaults + 磁盘合并的全量字典，PUT /api/config
//  只接受补丁（patch）写回。因此本模型不做「固定字段结构体」——
//  存储层就是 `[String: JSONValue]` 全量字典，已知键提供类型化访问器，
//  未知键原样留在字典里随编码往返（详见 SettingsPanelW2Tests 的往返保留测试）。
//
//  已知键清单逐条对照：
//    · renderer/src/panels/SettingsPanel.tsx 的 interface Config（UI 消费的键）
//    · sidecar/config/store.py 的 DEFAULT_CONFIG + _validate（后端全键与校验规则）
//  校验文案与后端 _validate 逐字对齐（用户看到的报错口径一致）。
//

import Foundation

// MARK: - JSONValue（任意 JSON 值的保真表示，未知键透传载体）

public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        // 顺序即类型判定优先级：Bool 先于数字（true/false 不会被 1/0 吞掉），
        // Int64 先于 Double（整数保持整数表示，15.0 才落 double）。
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int64.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        throw SidecarError.decodeFailed("JSONValue 无法解码")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    // MARK: 宽松取值（类型不符一律 nil，绝不 throw）

    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
    public var int: Int64? {
        switch self {
        case .int(let v): return v
        case .double(let v) where v == v.rounded() && abs(v) < 9.0e15: return Int64(v)
        default: return nil
        }
    }
    public var double: Double? {
        switch self {
        case .double(let v): return v
        case .int(let v): return Double(v)
        default: return nil
        }
    }
    public var array: [JSONValue]? { if case .array(let v) = self { return v }; return nil }
    public var object: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }
    public var stringArray: [String]? { array?.compactMap { $0.string } }
    public var stringDict: [String: String]? {
        guard let object else { return nil }
        var out: [String: String] = [:]
        for (k, v) in object { guard let s = v.string else { return nil }; out[k] = s }
        return out
    }

    /// 便于测试与日志的紧凑描述。
    public var compactDescription: String {
        switch self {
        case .null: return "null"
        case .bool(let v): return v ? "true" : "false"
        case .int(let v): return String(v)
        case .double(let v): return String(v)
        case .string(let v): return "\"\(v)\""
        case .array(let v): return "[\(v.count) 项]"
        case .object(let v): return "{\(v.count) 键}"
        }
    }
}

// MARK: - AuthGrant（0.4.33 R2：「永久允许」工具授权清单元素）

/// 键口径只有 tool + action（不含路径/参数）；granted_at 是展示用元数据（后端不强校验）。
public struct AuthGrant: Codable, Sendable, Equatable, Identifiable {
    public var tool: String
    public var action: String
    public var granted_at: String?

    public init(tool: String, action: String, granted_at: String? = nil) {
        self.tool = tool
        self.action = action
        self.granted_at = granted_at
    }

    /// 对标 tsx 的 key={`${g.tool}|${g.action}`}
    public var id: String { "\(tool)|\(action)" }

    public init?(json: JSONValue) {
        guard let obj = json.object,
              case .string(let tool) = obj["tool"],
              case .string(let action) = obj["action"] else { return nil }
        self.tool = tool
        self.action = action
        self.granted_at = obj["granted_at"]?.string
    }

    public var json: JSONValue {
        var obj: [String: JSONValue] = ["tool": .string(tool), "action": .string(action)]
        if let granted_at { obj["granted_at"] = .string(granted_at) }
        return .object(obj)
    }
}

// MARK: - SidecarConfig（全量字典存储 + 已知键类型化访问器）

public struct SidecarConfig: Codable, Sendable, Equatable {

    /// 全量键值（含未知键——编码时原样写回，绝不丢键）。
    public private(set) var storage: [String: JSONValue]

    public init(storage: [String: JSONValue] = [:]) {
        self.storage = storage
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        storage = try c.decode([String: JSONValue].self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(storage)
    }

    // MARK: 已知键名（唯一字符串源，避免散写 typo）

    public enum Key {
        public static let ollamaBaseURL = "ollama_base_url"
        public static let proxyHTTPPort = "proxy_http_port"
        public static let proxySOCKSPort = "proxy_socks_port"
        public static let dataRoot = "data_root"
        public static let defaultModel = "default_model"
        public static let pluginRepos = "plugin_repos"
        public static let egressProxyRequired = "egress_proxy_required"
        public static let sidecarHost = "sidecar_host"
        public static let sidecarPort = "sidecar_port"
        public static let vitePort = "vite_port"
        public static let networkSwitch = "network_switch"
        public static let maxToolRounds = "max_tool_rounds"
        public static let compactArchiveDir = "compact_archive_dir"
        public static let allowAutoCompact = "allow_auto_compact"
        public static let compactKeepRecent = "compact_keep_recent"
        public static let autoCreateSubAgents = "auto_create_sub_agents"
        public static let reconnectMaxAttempts = "reconnect_max_attempts"
        public static let heartbeatInterval = "heartbeat_interval"
        public static let inferenceBackend = "inference_backend"
        public static let inferenceBaseURL = "inference_base_url"
        public static let inferenceAPIKey = "inference_api_key"
        public static let openaiCompatSupportsTools = "openai_compat_supports_tools"
        public static let defaultExportDir = "default_export_dir"
        public static let visionParseAttachments = "vision_parse_attachments"
        public static let modelParallel = "model_parallel"
        public static let taskConcurrency = "task_concurrency"
        public static let errorAnalysisModel = "error_analysis_model"
        public static let confirmNetworkInstall = "confirm_network_install"
        public static let confirmModelPackDownload = "confirm_model_pack_download"
        public static let modelStrengths = "model_strengths"
        public static let delegationModelSwap = "delegation_model_swap"
        public static let appControlEnabled = "app_control_enabled"
        public static let appControlConfirm = "app_control_confirm"
        public static let computerUseEnabled = "computer_use_enabled"
        public static let computerUseConfirmEach = "computer_use_confirm_each"
        public static let computerUseAppWhitelist = "computer_use_app_whitelist"
        public static let cuElementLocateEnabled = "cu_element_locate_enabled"
        public static let authConfirmTimeout = "auth_confirm_timeout"
        public static let authGrants = "auth_grants"
        // 0.4.31 懒加载（UI 在 InferencePanel——并行波次；此处仅登记键名保证覆盖）
        public static let ctxLazyEnabled = "ctx_lazy_enabled"
        public static let ctxLazyStart = "ctx_lazy_start"
    }

    // MARK: 通用读写

    public func value(_ key: String) -> JSONValue? { storage[key] }

    public mutating func set(_ key: String, _ value: JSONValue?) {
        if let value { storage[key] = value } else { storage.removeValue(forKey: key) }
    }

    /// 提取子集补丁（分区保存用；键不在 storage 中则跳过——补丁语义是「写入这些键」）。
    public func patch(_ keys: [String]) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for k in keys { if let v = storage[k] { out[k] = v } }
        return out
    }

    /// 「保存全部」补丁 = 全量字典（对标 tsx save(cfg) 整包回写）。
    public func asPatch() -> [String: JSONValue] { storage }

    /// 未知键（无类型化访问器消费的键不算未知；这里指不在已知键名表里的键）清单——诊断/测试用。
    public var unknownKeys: [String] {
        let known = SidecarConfig.allKnownKeys
        return storage.keys.filter { !known.contains($0) }.sorted()
    }

    /// 已知键全集（store.py DEFAULT_CONFIG + tsx Config interface 的并集）。
    public static let allKnownKeys: Set<String> = [
        Key.ollamaBaseURL, Key.proxyHTTPPort, Key.proxySOCKSPort, Key.dataRoot,
        Key.defaultModel, Key.pluginRepos, Key.egressProxyRequired, Key.sidecarHost,
        Key.sidecarPort, Key.vitePort, Key.networkSwitch, Key.maxToolRounds,
        Key.compactArchiveDir, Key.allowAutoCompact, Key.compactKeepRecent,
        Key.autoCreateSubAgents, Key.reconnectMaxAttempts, Key.heartbeatInterval,
        Key.inferenceBackend, Key.inferenceBaseURL, Key.inferenceAPIKey,
        Key.openaiCompatSupportsTools, Key.defaultExportDir, Key.visionParseAttachments,
        Key.modelParallel, Key.taskConcurrency, Key.errorAnalysisModel,
        Key.confirmNetworkInstall, Key.confirmModelPackDownload, Key.modelStrengths,
        Key.delegationModelSwap, Key.appControlEnabled, Key.appControlConfirm,
        Key.computerUseEnabled, Key.computerUseConfirmEach, Key.computerUseAppWhitelist,
        Key.cuElementLocateEnabled, Key.authConfirmTimeout, Key.authGrants,
        Key.ctxLazyEnabled, Key.ctxLazyStart,
        // store.py DEFAULT_CONFIG 里 UI 不直接编辑、但属契约内的键：
        "web_search_url", "web_search_url_cn", "timeout_connect", "timeout_reading",
        "timeout_stream_reading", "model_options", "delegation_activity_timeout",
        "delegation_max_retries", "delegation_auto_cleanup", "cu_user_record_max_seconds",
        "model_packs_dir", "model_pack_catalog_urls", "model_pack_boot_timeout_s",
    ]

    // MARK: 类型化访问器（get 宽松：缺失/类型不符 → 默认值；默认值逐条对齐 tsx 的 ?? 与后端 DEFAULT_CONFIG）

    private func string(_ key: String, _ def: String) -> String { storage[key]?.string ?? def }
    private func bool(_ key: String, _ def: Bool) -> Bool { storage[key]?.bool ?? def }
    private func int(_ key: String, _ def: Int) -> Int { storage[key]?.int.map { Int($0) } ?? def }
    private func double(_ key: String, _ def: Double) -> Double { storage[key]?.double ?? def }
    private func stringArray(_ key: String) -> [String] { storage[key]?.stringArray ?? [] }

    public var defaultModel: String {
        get { string(Key.defaultModel, "") }
        set { set(Key.defaultModel, .string(newValue)) }
    }
    public var dataRoot: String {
        get { string(Key.dataRoot, "") }
        set { set(Key.dataRoot, .string(newValue)) }
    }
    /// 后端校验 1-1000，默认 200。
    public var maxToolRounds: Int {
        get { int(Key.maxToolRounds, 200) }
        set { set(Key.maxToolRounds, .int(Int64(newValue))) }
    }
    /// 1-10，默认 3。
    public var reconnectMaxAttempts: Int {
        get { int(Key.reconnectMaxAttempts, 3) }
        set { set(Key.reconnectMaxAttempts, .int(Int64(newValue))) }
    }
    /// 5-60 秒，默认 15（后端允许 int/float）。
    public var heartbeatInterval: Double {
        get { double(Key.heartbeatInterval, 15) }
        set { set(Key.heartbeatInterval, .double(newValue)) }
    }
    /// 0-86400 秒，默认 600；0 = 无限等待。
    public var authConfirmTimeout: Double {
        get { double(Key.authConfirmTimeout, 600) }
        set { set(Key.authConfirmTimeout, .double(newValue)) }
    }
    public var authGrants: [AuthGrant] {
        get { storage[Key.authGrants]?.array?.compactMap(AuthGrant.init(json:)) ?? [] }
        set { set(Key.authGrants, .array(newValue.map { $0.json })) }
    }
    public var modelParallel: Bool {
        get { bool(Key.modelParallel, false) }
        set { set(Key.modelParallel, .bool(newValue)) }
    }
    public var taskConcurrency: Bool {
        get { bool(Key.taskConcurrency, false) }
        set { set(Key.taskConcurrency, .bool(newValue)) }
    }
    public var delegationModelSwap: Bool {
        get { bool(Key.delegationModelSwap, true) }
        set { set(Key.delegationModelSwap, .bool(newValue)) }
    }
    public var errorAnalysisModel: String {
        get { string(Key.errorAnalysisModel, "") }
        set { set(Key.errorAnalysisModel, .string(newValue)) }
    }
    public var appControlEnabled: Bool {
        get { bool(Key.appControlEnabled, false) }
        set { set(Key.appControlEnabled, .bool(newValue)) }
    }
    public var appControlConfirm: [String] {
        get { stringArray(Key.appControlConfirm) }
        set { set(Key.appControlConfirm, .array(newValue.map { .string($0) })) }
    }
    public var computerUseEnabled: Bool {
        get { bool(Key.computerUseEnabled, false) }
        set { set(Key.computerUseEnabled, .bool(newValue)) }
    }
    public var computerUseConfirmEach: Bool {
        get { bool(Key.computerUseConfirmEach, true) }
        set { set(Key.computerUseConfirmEach, .bool(newValue)) }
    }
    public var cuElementLocateEnabled: Bool {
        get { bool(Key.cuElementLocateEnabled, true) }
        set { set(Key.cuElementLocateEnabled, .bool(newValue)) }
    }
    public var computerUseAppWhitelist: [String] {
        get { stringArray(Key.computerUseAppWhitelist) }
        set { set(Key.computerUseAppWhitelist, .array(newValue.map { .string($0) })) }
    }
    public var modelStrengths: [String: String] {
        get { storage[Key.modelStrengths]?.stringDict ?? [:] }
        set { set(Key.modelStrengths, .object(newValue.mapValues { .string($0) })) }
    }
    public var proxyHTTPPort: Int {
        get { int(Key.proxyHTTPPort, 21081) }
        set { set(Key.proxyHTTPPort, .int(Int64(newValue))) }
    }
    /// 原始值（auto/proxy + 遗留 on/off）。
    public var networkSwitch: String {
        get { string(Key.networkSwitch, "auto") }
        set { set(Key.networkSwitch, .string(newValue)) }
    }
    /// UI 显示口径（tsx L763：on→proxy，off→auto，其余原样；UI 只提供 auto/proxy 两档）。
    public var networkSwitchDisplay: String {
        switch networkSwitch {
        case "on": return "proxy"
        case "off": return "auto"
        default: return networkSwitch
        }
    }
    public var confirmNetworkInstall: Bool {
        get { bool(Key.confirmNetworkInstall, true) }
        set { set(Key.confirmNetworkInstall, .bool(newValue)) }
    }
    public var confirmModelPackDownload: Bool {
        get { bool(Key.confirmModelPackDownload, true) }
        set { set(Key.confirmModelPackDownload, .bool(newValue)) }
    }
    public var egressProxyRequired: [String] {
        get { stringArray(Key.egressProxyRequired) }
        set { set(Key.egressProxyRequired, .array(newValue.map { .string($0) })) }
    }
    public var pluginRepos: [String] {
        get { stringArray(Key.pluginRepos) }
        set { set(Key.pluginRepos, .array(newValue.map { .string($0) })) }
    }
    public var compactArchiveDir: String {
        get { string(Key.compactArchiveDir, "") }
        set { set(Key.compactArchiveDir, .string(newValue)) }
    }
    public var allowAutoCompact: Bool {
        get { bool(Key.allowAutoCompact, false) }
        set { set(Key.allowAutoCompact, .bool(newValue)) }
    }
    /// 2-100，默认 10。
    public var compactKeepRecent: Int {
        get { int(Key.compactKeepRecent, 10) }
        set { set(Key.compactKeepRecent, .int(Int64(newValue))) }
    }
    /// tsx 口径 `!== false`：缺省 = true。
    public var autoCreateSubAgents: Bool {
        get { bool(Key.autoCreateSubAgents, true) }
        set { set(Key.autoCreateSubAgents, .bool(newValue)) }
    }
    public var defaultExportDir: String {
        get { string(Key.defaultExportDir, "") }
        set { set(Key.defaultExportDir, .string(newValue)) }
    }
    /// tsx 口径 `=== true`：缺省/非 true = false。
    public var visionParseAttachments: Bool {
        get { bool(Key.visionParseAttachments, false) }
        set { set(Key.visionParseAttachments, .bool(newValue)) }
    }
}

// MARK: - ConfigValidator（客户端预校验，规则与文案逐字对齐 store.py _validate）

public enum ConfigValidator {

    /// 校验一个写回补丁；返回首条错误文案（nil = 通过）。
    /// 覆盖 SettingsPanel 可编辑键；后端仍是最终守门（400 detail 原样上屏）。
    public static func validate(patch: [String: JSONValue]) -> String? {
        for (key, value) in patch {
            if let err = validateKey(key, value: value) { return err }
        }
        return nil
    }

    public static func validateKey(_ key: String, value: JSONValue) -> String? {
        switch key {
        case SidecarConfig.Key.maxToolRounds:
            guard let v = value.int, (1...1000).contains(v) else {
                return "max_tool_rounds 必须是 1-1000 的整数"
            }
        case SidecarConfig.Key.reconnectMaxAttempts:
            guard let v = value.int, (1...10).contains(v) else {
                return "reconnect_max_attempts 必须是 1-10 的整数"
            }
        case SidecarConfig.Key.heartbeatInterval:
            guard let v = value.double, (5.0...60.0).contains(v) else {
                return "heartbeat_interval 必须是 5-60 的秒数"
            }
        case SidecarConfig.Key.authConfirmTimeout:
            guard let v = value.double, (0...86400).contains(v) else {
                return "auth_confirm_timeout 必须是 0-86400 的秒数（0=无限等待）"
            }
        case SidecarConfig.Key.compactKeepRecent:
            guard let v = value.int, (2...100).contains(v) else {
                return "compact_keep_recent 必须是 2-100 的整数"
            }
        case SidecarConfig.Key.proxyHTTPPort, SidecarConfig.Key.proxySOCKSPort,
             SidecarConfig.Key.sidecarPort, SidecarConfig.Key.vitePort:
            guard let v = value.int, (1...65535).contains(v) else {
                return "\(key) 必须是 1-65535 的整数"
            }
        case SidecarConfig.Key.dataRoot:
            guard let s = value.string, !s.trimmingCharacters(in: .whitespaces).isEmpty else {
                return "data_root 不能为空"
            }
        case SidecarConfig.Key.defaultModel:
            guard let s = value.string, !s.trimmingCharacters(in: .whitespaces).isEmpty else {
                return "default_model 不能为空"
            }
        case SidecarConfig.Key.networkSwitch:
            guard let s = value.string, ["on", "off", "auto", "proxy"].contains(s) else {
                return "network_switch 必须是 auto/proxy（遗留值 on/off 会自动迁移）"
            }
        case SidecarConfig.Key.compactArchiveDir:
            guard let s = value.string else { return "compact_archive_dir 必须是绝对路径或含 ~ 的合法路径" }
            let t = s.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty && !(t.hasPrefix("/") || t.hasPrefix("~")) {
                return "compact_archive_dir 必须是绝对路径或含 ~ 的合法路径"
            }
        case SidecarConfig.Key.modelStrengths:
            guard let d = value.stringDict else {
                return "model_strengths 必须是 {模型名: 特长描述} 的字符串字典"
            }
            for (m, desc) in d where desc.count > 100 {
                return "model_strengths[\(m)] 特长描述超过 100 字，请精简"
            }
        case SidecarConfig.Key.egressProxyRequired:
            guard let arr = value.stringArray else {
                return "egress_proxy_required 必须是字符串数组"
            }
            for entry in arr where !isValidDomainEntry(entry) {
                return "egress_proxy_required 含非法域名: \(entry)（需为合法域名，支持 *.xxx 通配）"
            }
        case SidecarConfig.Key.authGrants:
            guard let arr = value.array else {
                return "auth_grants 必须是对象数组（{tool, action, granted_at}）"
            }
            for item in arr {
                guard let g = AuthGrant(json: item), !g.tool.isEmpty, !g.action.isEmpty else {
                    return "auth_grants 元素必须含非空字符串 tool 与 action"
                }
            }
        case SidecarConfig.Key.ctxLazyStart:
            guard let v = value.int, (2048...1048576).contains(v) else {
                return "ctx_lazy_start 必须是 2048-1048576 的整数"
            }
        default:
            break
        }
        return nil
    }

    /// 「需代理」名单域名合法性（移植 store.py `_valid_domain_entry`）：
    /// 普通域名或 *.xxx 通配；拒绝空串/单标签/IP/URL/下划线。
    public static func isValidDomainEntry(_ raw: String) -> Bool {
        let e = raw.trimmingCharacters(in: .whitespaces).lowercased()
            .trimmingTrailingCharacters(".")
        guard !e.isEmpty else { return false }
        let rest = e.hasPrefix("*.") ? String(e.dropFirst(2)) : e
        let labels = rest.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        let pattern = #"^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
        for label in labels {
            let s = String(label)
            guard re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil else { return false }
        }
        // 排除纯数字标签形态（IP）：至少一个标签含字母
        return labels.contains { $0.range(of: "[a-z]", options: .regularExpression) != nil }
    }
}

private extension String {
    /// 去掉尾部所有 '.'（对标 Python rstrip(".")）。
    func trimmingTrailingCharacters(_ ch: Character) -> String {
        var s = self
        while s.last == ch { s.removeLast() }
        return s
    }
}
