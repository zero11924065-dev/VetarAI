//
//  NativeConfigStore.swift
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

//  逐字段移植 subagent/sidecar/config/store.py（唯一事实源，⛔ 只读）：
//    · DEFAULT_CONFIG 55 键（前 54 键顺序 = Python dict 插入序，写盘字节可比；
//      末位 error_analysis_timeout_s 为 0.7.5 W13 原生新增键——Python 侧无对应，
//      排最末不影响既有键序与双跑字节比对）
//    · data_root() 解析链：VETARAI_DATA_ROOT > 已载配置 data_root > 默认 ~/.subagent
//    · getConfig() = get_config()：defaults+disk 合并 / 缺键补写 / network_switch
//      on/off→proxy/auto 遗留迁移 / plugins_enabled·skills_enabled·egress_allowlist 清除
//    · reloadConfig(patch:) = reload_config()：未知键报错 → 合并 → _validate → 原子写
//    · 校验文案与 _validate / infer_options.timeout_validate / validate_model_options 逐字一致
//
//  Python 语义保真点（双跑对照测试逐项核对）：
//    · isinstance(bool, int)==True：端口 / max_tool_rounds 等**未显式排 bool** 的校验，
//      true 按 1 参与范围判定；reconnect_max_attempts / heartbeat_interval / ctx_lazy_start
//      / delegation_max_retries / 各超时键则显式拒绝 bool（逐条对齐源码注释标注）
//    · _to_float 宽松：数值字符串 "300" 合法（float("300")）；NaN/Inf 拒绝
//    · 未知键：get_config 从磁盘读入后随合并结果写回（往返保留，0.4.34 教训）；
//      reload_config 的 patch 含未知键 → ValueError("未知配置项: k")
//    · 原子写：config.json.tmp 写完 rename（M3 L1），rename 失败原文件不动
//
//  网络切换熔断重置（store.py L513-519 guard_reset_circuit）属 network 模块，
//  本波未移植——原生路径仅记日志，侧车并行运行时其熔断器状态由侧车自行维护。
//

import Foundation

// MARK: - 错误

public enum NativeCoreError: Error, Equatable {
    /// _validate / reload_config 的 ValueError（message 与 Python 文案逐字一致）。
    case invalidConfig(String)
    /// 文件 IO 失败（含原子写 rename 失败）。
    case io(String)
    /// SQLite 层失败。
    case database(String)
    /// 端点级业务错误（404/422 语义；message 与 FastAPI detail 逐字一致）。
    case notFound(String)
    case unprocessable(String)
}

// MARK: - Python 类型判定助手（isinstance 语义保真）

public enum PySem {
    /// isinstance(v, bool)
    public static func isBool(_ v: JSONValue) -> Bool {
        if case .bool = v { return true }
        return false
    }

    /// isinstance(v, int)——Python 中 bool 是 int 子类。
    /// - Parameter boolOk: 该校验是否显式排除 bool（`isinstance(v, bool)` 前置拦截）。
    public static func isInt(_ v: JSONValue, boolOk: Bool) -> Bool {
        switch v {
        case .int: return true
        case .bool: return boolOk
        default: return false   // float 3.0 不是 int（isinstance(3.0, int)==False）
        }
    }

    /// isinstance(v, (int, float)) 且非 bool（显式排除模式）→ 取值。
    public static func asNumberNoBool(_ v: JSONValue) -> Double? {
        switch v {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }

    /// infer_options._to_float：bool/None → None；float(v) 宽松（数值字符串合法）；
    /// NaN/Inf → None。
    public static func toFloat(_ v: JSONValue) -> Double? {
        switch v {
        case .bool, .null: return nil
        case .int(let i): return Double(i)
        case .double(let d): return d.isFinite ? d : nil
        case .string(let s):
            // Python float(" 3 ") 容忍首尾空白；Double() 不容忍——先 trim 对齐。
            let t = s.trimmingCharacters(in: .whitespaces)
            guard let d = Double(t), d.isFinite else { return nil }
            return d
        default: return nil
        }
    }

    /// isinstance(v, str)
    public static func isStr(_ v: JSONValue) -> Bool {
        if case .string = v { return true }
        return false
    }

    /// isinstance(v, list) 且全元素 str
    public static func isStrList(_ v: JSONValue) -> Bool {
        guard case .array(let arr) = v else { return false }
        return arr.allSatisfy { isStr($0) }
    }

    /// Python repr() 子集（错误文案 {x!r} 用）：字符串单引号包裹，bool→True/False，None。
    public static func repr(_ v: JSONValue) -> String {
        switch v {
        case .null: return "None"
        case .bool(let b): return b ? "True" : "False"
        case .int(let i): return String(i)
        case .double(let d): return NativeJSONWriter.pyFloatRepr(d)
        case .string(let s): return reprString(s)
        case .array, .object: return v.compactDescription
        }
    }

    /// Python repr(str)：优先单引号；含单引号无双引号时用双引号；控制符转义。
    public static func reprString(_ s: String) -> String {
        let hasSingle = s.contains("'")
        let hasDouble = s.contains("\"")
        let quote: Character = (hasSingle && !hasDouble) ? "\"" : "'"
        var out = String(quote)
        for ch in s {
            if ch == quote || ch == "\\" { out.append("\\\(ch)") }
            else if ch == "\n" { out.append("\\n") }
            else if ch == "\r" { out.append("\\r") }
            else if ch == "\t" { out.append("\\t") }
            else if ch.unicodeScalars.allSatisfy({ $0.value < 0x20 }) {
                for sc in ch.unicodeScalars { out.append(String(format: "\\x%02x", sc.value)) }
            } else { out.append(ch) }
        }
        out.append(quote)
        return out
    }

    /// Python f"{x:g}" 子集（超时范围文案用）：整数值浮点去小数点。
    static func g(_ d: Double) -> String {
        if d == d.rounded() && abs(d) < 1e15 { return String(Int(d)) }
        return String(describing: d)
    }
}

// MARK: - NativeConfigStore

public final class NativeConfigStore: @unchecked Sendable {

    /// DEFAULT_CONFIG（键序 = store.py dict 插入序；写盘顺序与双跑字节比对的基准）。
    /// 值逐字对照 store.py L41-186。
    public static let defaultKeys: [String] = [
        "ollama_base_url", "proxy_http_port", "proxy_socks_port", "data_root",
        "default_model", "plugin_repos", "egress_proxy_required",
        "sidecar_host", "sidecar_port", "vite_port", "network_switch",
        "web_search_url", "web_search_url_cn", "max_tool_rounds",
        "compact_archive_dir", "allow_auto_compact", "compact_keep_recent",
        "auto_create_sub_agents", "reconnect_max_attempts", "heartbeat_interval",
        "inference_backend", "inference_base_url", "inference_api_key",
        "openai_compat_supports_tools",
        "timeout_connect", "timeout_reading", "timeout_stream_reading",
        "model_options", "ctx_lazy_enabled", "ctx_lazy_start",
        "default_export_dir", "vision_parse_attachments",
        "delegation_activity_timeout", "delegation_max_retries", "delegation_auto_cleanup",
        "model_parallel", "task_concurrency",
        "error_analysis_model", "confirm_network_install", "model_strengths",
        "delegation_model_swap", "app_control_enabled", "app_control_confirm",
        "computer_use_enabled", "computer_use_confirm_each", "computer_use_app_whitelist",
        "cu_element_locate_enabled", "cu_user_record_max_seconds",
        "auth_confirm_timeout", "auth_grants",
        "model_packs_dir", "model_pack_catalog_urls", "confirm_model_pack_download",
        "model_pack_boot_timeout_s",
        // 0.7.5 W13 原生新增（Python 侧无对应）：报错分析调用超时，隐藏键不进设置页 UI
        "error_analysis_timeout_s",
    ]

    public static let defaultConfig: [String: JSONValue] = [
        "ollama_base_url": .string("http://localhost:11434"),
        "proxy_http_port": .int(21081),
        "proxy_socks_port": .int(21080),
        "data_root": .string("~/.subagent"),
        "default_model": .string("qwen3.8"),
        "plugin_repos": .array([]),
        "egress_proxy_required": .array([]),
        "sidecar_host": .string("127.0.0.1"),
        "sidecar_port": .int(8765),
        "vite_port": .int(5173),
        "network_switch": .string("auto"),
        "web_search_url": .string("https://html.duckduckgo.com/html/"),
        "web_search_url_cn": .string("https://www.so.com/s"),
        "max_tool_rounds": .int(200),
        "compact_archive_dir": .string("~/.subagent/compressed"),
        "allow_auto_compact": .bool(false),
        "compact_keep_recent": .int(10),
        "auto_create_sub_agents": .bool(true),
        "reconnect_max_attempts": .int(3),
        "heartbeat_interval": .double(15.0),
        "inference_backend": .string("ollama"),
        "inference_base_url": .string(""),
        "inference_api_key": .string(""),
        "openai_compat_supports_tools": .bool(true),
        "timeout_connect": .int(0),
        "timeout_reading": .int(0),
        "timeout_stream_reading": .int(0),
        "model_options": .object([:]),
        "ctx_lazy_enabled": .bool(true),
        "ctx_lazy_start": .int(12288),
        "default_export_dir": .string(""),
        "vision_parse_attachments": .bool(false),
        "delegation_activity_timeout": .int(900),
        "delegation_max_retries": .int(2),
        "delegation_auto_cleanup": .bool(false),
        "model_parallel": .bool(false),
        "task_concurrency": .bool(false),
        "error_analysis_model": .string(""),
        "confirm_network_install": .bool(true),
        "model_strengths": .object([:]),
        "delegation_model_swap": .bool(true),
        "app_control_enabled": .bool(false),
        "app_control_confirm": .array([.string("workflow_run"), .string("roundtable_create")]),
        "computer_use_enabled": .bool(false),
        "computer_use_confirm_each": .bool(true),
        "computer_use_app_whitelist": .array([]),
        "cu_element_locate_enabled": .bool(true),
        "cu_user_record_max_seconds": .int(600),
        "auth_confirm_timeout": .int(600),
        "auth_grants": .array([]),
        "model_packs_dir": .string(""),
        "model_pack_catalog_urls": .array([]),
        "confirm_model_pack_download": .bool(true),
        "model_pack_boot_timeout_s": .int(600),
        "error_analysis_timeout_s": .int(60),
    ]

    /// 已废弃键（checkpoint-047 + B11）：get_config 幂等清除并触发写盘。
    static let legacyKeys = ["plugins_enabled", "skills_enabled", "egress_allowlist"]

    // ── 注入缝 ──
    /// 环境变量表（默认进程环境；测试注入 ["VETARAI_DATA_ROOT": tmp]）。
    public var environment: [String: String]
    /// 原子替换实现（默认 POSIX rename 同目录原子语义 = os.replace；测试注入抛错）。
    public var replacer: (_ tmp: URL, _ target: URL) throws -> Void
    /// 日志回调（网络切换熔断重置等原生侧降级点）。
    public var log: (String) -> Void

    private let lock = NSRecursiveLock()
    /// _MEM（store.py L188）：最近一次 get_config/reload_config 的合并结果。
    /// internal（非 private）：测试可直接注入以覆盖 data_root 解析链（避免误触真实 ~/.subagent）。
    var mem: [String: JSONValue] = [:]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                log: @escaping (String) -> Void = { _ in }) {
        self.environment = environment
        self.log = log
        self.replacer = { tmp, target in
            // os.replace 同语义：同目录 rename(2)，目标存在则原子覆盖。
            if rename(tmp.path, target.path) != 0 {
                let err = String(cString: strerror(errno))
                throw NativeCoreError.io("原子替换失败: \(err)")
            }
        }
    }

    // MARK: - 路径解析（store.py L191-231）

    /// ~ 展开（expanduser 常用子集：仅 "~"/"~/" 前缀）。
    public static func expandUser(_ raw: String) -> URL {
        if raw == "~" { return URL(fileURLWithPath: NSHomeDirectory()) }
        if raw.hasPrefix("~/") {
            return URL(fileURLWithPath: NSHomeDirectory() + String(raw.dropFirst(1)))
        }
        return URL(fileURLWithPath: raw)
    }

    /// Path.resolve()（Python 非严格语义）：realpath(3) 解析已存在前缀，不存在的尾部词法拼接。
    /// ⚠️ 不能用 URL.resolvingSymlinksInPath：现代 macOS 的 /var→/private/var 是
    /// firmlink 而非 symlink，Foundation 不解 firmlink（/var/folders 原样保留），
    /// 与 Python realpath 口径不一致（双跑 testStorageDualRun 曾在此翻车）。
    public static func resolvePath(_ url: URL) -> URL {
        let fm = FileManager.default
        var existing = url.path
        var tail: [String] = []
        while !existing.isEmpty && !fm.fileExists(atPath: existing) {
            let parent = (existing as NSString).deletingLastPathComponent
            if parent == existing { break }
            tail.insert((existing as NSString).lastPathComponent, at: 0)
            existing = parent
        }
        var resolved = existing
        if let buf = realpath(existing, nil) {
            resolved = String(cString: buf)
            free(buf)
        }
        for comp in tail { resolved = (resolved as NSString).appendingPathComponent(comp) }
        return URL(fileURLWithPath: resolved)
    }

    /// data_root()：VETARAI_DATA_ROOT > _MEM["data_root"] > DEFAULT_CONFIG。
    public func dataRoot() -> URL {
        let envRaw = (environment["VETARAI_DATA_ROOT"] ?? "").trimmingCharacters(in: .whitespaces)
        if !envRaw.isEmpty { return Self.expandUser(envRaw) }
        let raw = lock.withLock { mem["data_root"]?.string } ?? Self.defaultConfig["data_root"]?.string ?? "~/.subagent"
        return Self.expandUser(raw)
    }

    public func projectsRoot() -> URL {
        let p = dataRoot().appendingPathComponent("projects")
        try? FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
        return p
    }

    public func pluginsRoot() -> URL {
        let p = dataRoot().appendingPathComponent("plugins")
        try? FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
        return p
    }

    public func configPath() -> URL { dataRoot().appendingPathComponent("config.json") }

    // MARK: - 磁盘读写（store.py L234-259）

    /// _load_from_disk：不存在/解析失败/非对象 → 空 dict。
    /// 读入走 NativeJSONWriter.loads（json.loads 文本保真：15.0 回读仍是浮点——
    /// Foundation JSONDecoder 会把 15.0 宽松成 int(15)，导致默认值写读后漂移）。
    /// 告警口径对齐 L242-243：仅解析失败告警；非对象（如 [1,2]）静默按空（L240）。
    private func loadFromDisk() -> [String: JSONValue] {
        let path = configPath()
        guard FileManager.default.fileExists(atPath: path.path) else { return [:] }
        do {
            let data = try Data(contentsOf: path)
            guard let parsed = NativeJSONWriter.loads(data) else {
                log("failed to read \(path.path): invalid JSON")
                return [:]
            }
            guard case .object(let obj) = parsed else { return [:] }   // isinstance dict 检查
            return obj
        } catch {
            log("failed to read \(path.path): \(error.localizedDescription)")
            return [:]
        }
    }

    /// _save：tmp + rename 原子写（M3 L1）。格式 = json.dumps(ensure_ascii=False, indent=2)。
    /// 键序：DEFAULT_CONFIG 序优先，未知键字典序追加（Python 为磁盘原序，语义等价）。
    private func save(_ cfg: [String: JSONValue]) throws {
        let path = configPath()
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let text = NativeJSONWriter.dumpsObject(cfg, keyOrder: Self.defaultKeys)
        let tmp = path.deletingLastPathComponent()
            .appendingPathComponent(path.lastPathComponent + ".tmp")
        try text.write(to: tmp, atomically: false, encoding: .utf8)
        try replacer(tmp, path)
    }

    // MARK: - get_config（store.py L461-488）

    /// defaults+disk 合并；缺键补写；network_switch 遗留迁移；废弃键清除。
    /// 未知键随合并结果写回（往返保留红线）。
    /// ⚠️ Python get_config 的 _save 异常**不吞**（L485-486 直接传播 → 端点 500）——保留。
    @discardableResult
    public func getConfig() throws -> [String: JSONValue] {
        try lock.withLock {
            let onDisk = loadFromDisk()
            var merged = Self.defaultConfig.merging(onDisk) { _, disk in disk }
            var missing = Self.defaultKeys.filter { onDisk[$0] == nil }
            // 网络开关旧值迁移（off→auto / on→proxy），幂等写回
            let rawSwitch = (merged["network_switch"]?.string ?? "").lowercased()
            if rawSwitch == "on" || rawSwitch == "off" {
                merged["network_switch"] = .string(rawSwitch == "on" ? "proxy" : "auto")
                missing.append("network_switch")
            }
            // 废弃键只删不迁移（egress_allowlist 语义相反，搬运会反转允许/拒绝）
            for legacy in Self.legacyKeys where merged[legacy] != nil {
                merged.removeValue(forKey: legacy)
                missing.append(legacy)
            }
            if !missing.isEmpty { try save(merged) }
            mem = merged
            return merged
        }
    }

    // MARK: - reload_config（store.py L491-520）

    /// 补丁合并 + 全量校验 + 原子写。未知键 / 校验失败抛 invalidConfig（文案逐字）。
    /// - Returns: 新全量配置（与 PUT /api/config 响应同构）。
    @discardableResult
    public func reloadConfig(patch: [String: JSONValue]) throws -> [String: JSONValue] {
        try lock.withLock {
            var cur = Self.defaultConfig.merging(loadFromDisk()) { _, disk in disk }
            let prevSwitch = (cur["network_switch"]?.string ?? "").lowercased()
            for (k, v) in patch {
                guard Self.defaultConfig[k] != nil else {
                    throw NativeCoreError.invalidConfig("未知配置项: \(k)")
                }
                cur[k] = v
            }
            try validate(cur)
            try save(cur)
            mem = cur
            let newSwitch = (cur["network_switch"]?.string ?? "").lowercased()
            if newSwitch != prevSwitch {
                // guard_reset_circuit 属 network 模块（未移植）：原生内核无熔断器状态；
                // 侧车并行运行时其熔断器由侧车 guard.py 自管（重启侧车即复位）。
                log("network_switch 已切换（\(prevSwitch)→\(newSwitch)）：原生内核无熔断器需重置")
            }
            return cur
        }
    }

    // MARK: - _validate（store.py L291-458 + infer_options 校验，文案逐字）

    /// Python `cur.get(k)` 的 None 口径：缺失与显式 null 同视为 None。
    /// _validate 的可选键检查全是 "if x is not None and <非法> → raise"——
    /// 磁盘上显式写 null 的键必须跳过而非报错（Swift `if let` 会绑到 .null 误报）。
    static func pyGet(_ cur: [String: JSONValue], _ k: String) -> JSONValue? {
        guard let v = cur[k], v != .null else { return nil }
        return v
    }

    public func validate(_ cur: [String: JSONValue]) throws {
        // ollama_base_url
        let u = cur["ollama_base_url"] ?? .null
        guard case .string(let us) = u, us.hasPrefix("http://") || us.hasPrefix("https://") else {
            throw NativeCoreError.invalidConfig("ollama_base_url 必须是 http(s):// 地址")
        }
        // 端口（⚠️ Python isinstance(int) 含 bool：true=1 合法、false=0 越界——保留怪癖）
        for k in ["sidecar_port", "vite_port", "proxy_http_port", "proxy_socks_port"] {
            let v = cur[k] ?? .null
            guard PySem.isInt(v, boolOk: true) else {
                throw NativeCoreError.invalidConfig("\(k) 必须是 1-65535 的整数")
            }
            let n: Int64 = v.int ?? ((v.bool ?? false) ? 1 : 0)
            guard (1...65535).contains(n) else {
                throw NativeCoreError.invalidConfig("\(k) 必须是 1-65535 的整数")
            }
        }
        // data_root
        guard case .string(let dr) = cur["data_root"] ?? .null,
              !dr.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw NativeCoreError.invalidConfig("data_root 不能为空")
        }
        // plugin_repos（None 跳过校验）
        if let pr = Self.pyGet(cur, "plugin_repos"), !(PySem.isStrList(pr)) {
            throw NativeCoreError.invalidConfig("plugin_repos 必须是字符串数组")
        }
        // default_model
        guard case .string(let dm) = cur["default_model"] ?? .null,
              !dm.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw NativeCoreError.invalidConfig("default_model 不能为空")
        }
        // network_switch
        guard let ns = cur["network_switch"]?.string, ["on", "off", "auto", "proxy"].contains(ns) else {
            throw NativeCoreError.invalidConfig("network_switch 必须是 auto/proxy（遗留值 on/off 会自动迁移）")
        }
        // egress_proxy_required
        if let pr = Self.pyGet(cur, "egress_proxy_required") {
            guard PySem.isStrList(pr) else {
                throw NativeCoreError.invalidConfig("egress_proxy_required 必须是字符串数组")
            }
            for entry in pr.stringArray ?? [] where !ConfigValidator.isValidDomainEntry(entry) {
                throw NativeCoreError.invalidConfig(
                    "egress_proxy_required 含非法域名: \(PySem.reprString(entry))（需为合法域名，支持 *.xxx 通配）")
            }
        }
        // max_tool_rounds（⚠️ 未排 bool：true=1 通过——保留）
        let mtr = cur["max_tool_rounds"] ?? .null
        guard PySem.isInt(mtr, boolOk: true) else {
            throw NativeCoreError.invalidConfig("max_tool_rounds 必须是 1-1000 的整数")
        }
        let mtrN: Int64 = mtr.int ?? ((mtr.bool ?? false) ? 1 : 0)
        guard (1...1000).contains(mtrN) else {
            throw NativeCoreError.invalidConfig("max_tool_rounds 必须是 1-1000 的整数")
        }
        // compact_archive_dir（None 跳过；空串/空白 → 报错，与 store.py 一致）
        if let cad = Self.pyGet(cur, "compact_archive_dir") {
            guard case .string(let s) = cad, !s.trimmingCharacters(in: .whitespaces).isEmpty,
                  s.hasPrefix("/") || s.hasPrefix("~") else {
                throw NativeCoreError.invalidConfig("compact_archive_dir 必须是绝对路径或含 ~ 的合法路径")
            }
        }
        if let aac = Self.pyGet(cur, "allow_auto_compact"), !PySem.isBool(aac) {
            throw NativeCoreError.invalidConfig("allow_auto_compact 必须是 bool")
        }
        if let ckr = Self.pyGet(cur, "compact_keep_recent") {
            guard PySem.isInt(ckr, boolOk: true) else {
                throw NativeCoreError.invalidConfig("compact_keep_recent 必须是 2-100 的整数")
            }
            let n: Int64 = ckr.int ?? ((ckr.bool ?? false) ? 1 : 0)
            guard (2...100).contains(n) else {
                throw NativeCoreError.invalidConfig("compact_keep_recent 必须是 2-100 的整数")
            }
        }
        if let v = Self.pyGet(cur, "auto_create_sub_agents"), !PySem.isBool(v) {
            throw NativeCoreError.invalidConfig("auto_create_sub_agents 必须是 bool")
        }
        // reconnect_max_attempts（显式排 bool）
        if let v = Self.pyGet(cur, "reconnect_max_attempts") {
            guard case .int(let n) = v, (1...10).contains(n) else {
                throw NativeCoreError.invalidConfig("reconnect_max_attempts 必须是 1-10 的整数")
            }
        }
        // heartbeat_interval（显式排 bool，int/float 5-60）
        if let v = Self.pyGet(cur, "heartbeat_interval") {
            guard let f = PySem.asNumberNoBool(v), (5.0...60.0).contains(f) else {
                throw NativeCoreError.invalidConfig("heartbeat_interval 必须是 5-60 的秒数")
            }
        }
        // inference_backend
        if let ib = Self.pyGet(cur, "inference_backend") {
            guard let s = ib.string, ["ollama", "openai_compatible", "model_package"].contains(s) else {
                throw NativeCoreError.invalidConfig("inference_backend 必须是 ollama、openai_compatible 或 model_package")
            }
        }
        if cur["inference_backend"]?.string == "openai_compatible" {
            let base = cur["inference_base_url"]?.string ?? ""
            guard !base.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw NativeCoreError.invalidConfig("openai_compatible 后端必须填写 inference_base_url（如 http://localhost:1234/v1）")
            }
        }
        if let v = Self.pyGet(cur, "openai_compat_supports_tools"), !PySem.isBool(v) {
            throw NativeCoreError.invalidConfig("openai_compat_supports_tools 必须是 bool")
        }
        // infer_options.timeout_validate（A1；错误文案含 :g 格式化）
        if let err = Self.timeoutValidate(cur) {
            throw NativeCoreError.invalidConfig(err)
        }
        // infer_options.validate_model_options（A2/A4）
        if let err = Self.validateModelOptions(Self.pyGet(cur, "model_options")) {
            throw NativeCoreError.invalidConfig(err)
        }
        if let v = Self.pyGet(cur, "ctx_lazy_enabled"), !PySem.isBool(v) {
            throw NativeCoreError.invalidConfig("ctx_lazy_enabled 必须是 bool")
        }
        if let v = Self.pyGet(cur, "ctx_lazy_start") {
            guard case .int(let n) = v, (2048...1048576).contains(n) else {
                throw NativeCoreError.invalidConfig("ctx_lazy_start 必须是 2048-1048576 的整数")
            }
        }
        if let v = Self.pyGet(cur, "default_export_dir"), !PySem.isStr(v) {
            throw NativeCoreError.invalidConfig("default_export_dir 必须是字符串（空=项目工作目录）")
        }
        if let v = Self.pyGet(cur, "vision_parse_attachments"), !PySem.isBool(v) {
            throw NativeCoreError.invalidConfig("vision_parse_attachments 必须是 bool")
        }
        // 两条同构超时校验（0=不限；显式排 bool）
        for (key, label) in [("delegation_activity_timeout", "0=关闭"), ("auth_confirm_timeout", "0=无限等待")] {
            if let v = Self.pyGet(cur, key) {
                guard let f = PySem.asNumberNoBool(v), (0...86400).contains(f) else {
                    throw NativeCoreError.invalidConfig("\(key) 必须是 0-86400 的秒数（\(label)）")
                }
            }
        }
        // cu_user_record_max_seconds（10-86400，无 0=不限档）
        if let v = Self.pyGet(cur, "cu_user_record_max_seconds") {
            guard let f = PySem.asNumberNoBool(v), (10...86400).contains(f) else {
                throw NativeCoreError.invalidConfig("cu_user_record_max_seconds 必须是 10-86400 的秒数")
            }
        }
        // auth_grants
        if let ag = Self.pyGet(cur, "auth_grants") {
            guard case .array(let arr) = ag, arr.allSatisfy({ $0.object != nil }) else {
                throw NativeCoreError.invalidConfig("auth_grants 必须是对象数组（{tool, action, granted_at}）")
            }
            for g in arr {
                let obj = g.object ?? [:]
                guard case .string(let tool) = obj["tool"] ?? .null, !tool.isEmpty,
                      case .string(let action) = obj["action"] ?? .null, !action.isEmpty else {
                    throw NativeCoreError.invalidConfig("auth_grants 元素必须含非空字符串 tool 与 action")
                }
            }
        }
        // delegation_max_retries（显式排 bool）
        if let v = Self.pyGet(cur, "delegation_max_retries") {
            guard case .int(let n) = v, (0...10).contains(n) else {
                throw NativeCoreError.invalidConfig("delegation_max_retries 必须是 0-10 的整数（0=不限）")
            }
        }
        for k in ["delegation_auto_cleanup", "model_parallel", "task_concurrency"] {
            if let v = Self.pyGet(cur, k), !PySem.isBool(v) {
                throw NativeCoreError.invalidConfig("\(k) 必须是 bool")
            }
        }
        for k in ["confirm_network_install", "delegation_model_swap", "app_control_enabled",
                  "computer_use_enabled", "computer_use_confirm_each",
                  "confirm_model_pack_download", "cu_element_locate_enabled"] {
            if let v = Self.pyGet(cur, k), !PySem.isBool(v) {
                throw NativeCoreError.invalidConfig("\(k) 必须是 bool")
            }
        }
        if let v = Self.pyGet(cur, "error_analysis_model"), !PySem.isStr(v) {
            throw NativeCoreError.invalidConfig("error_analysis_model 必须是字符串（模型名，空=用默认模型）")
        }
        // model_strengths（键嵌文案非 repr，对齐 f"model_strengths[{_mk}]"）
        if let ms = Self.pyGet(cur, "model_strengths") {
            guard case .object(let d) = ms, d.values.allSatisfy({ PySem.isStr($0) }) else {
                throw NativeCoreError.invalidConfig("model_strengths 必须是 {模型名: 特长描述} 的字符串字典")
            }
            for (mk, mv) in d where (mv.string?.count ?? 0) > 100 {
                throw NativeCoreError.invalidConfig("model_strengths[\(mk)] 特长描述超过 100 字，请精简")
            }
        }
        if let v = Self.pyGet(cur, "app_control_confirm"), !PySem.isStrList(v) {
            throw NativeCoreError.invalidConfig("app_control_confirm 必须是字符串数组（需确认的动作名）")
        }
        if let v = Self.pyGet(cur, "computer_use_app_whitelist"), !PySem.isStrList(v) {
            throw NativeCoreError.invalidConfig("computer_use_app_whitelist 必须是字符串数组（应用名）")
        }
        // model_packs_dir（空 = 默认安装根；非空须 / 或 ~ 开头）
        if let v = Self.pyGet(cur, "model_packs_dir") {
            guard case .string(let s) = v else {
                throw NativeCoreError.invalidConfig("model_packs_dir 必须是字符串（空 = data_root()/models/packs）")
            }
            let t = s.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty && !(s.hasPrefix("/") || s.hasPrefix("~")) {
                throw NativeCoreError.invalidConfig("model_packs_dir 必须是绝对路径或 ~ 开头（空 = 默认安装根）")
            }
        }
        if let v = Self.pyGet(cur, "model_pack_catalog_urls") {
            guard PySem.isStrList(v) else {
                throw NativeCoreError.invalidConfig("model_pack_catalog_urls 必须是字符串数组")
            }
            for urlStr in v.stringArray ?? []
            where !(urlStr.hasPrefix("http://") || urlStr.hasPrefix("https://") || urlStr.hasPrefix("file://")) {
                throw NativeCoreError.invalidConfig(
                    "model_pack_catalog_urls 含非法源: \(PySem.reprString(urlStr))（须 http(s):// 或 file://）")
            }
        }
        // model_pack_boot_timeout_s（10-7200；显式排 bool）
        if let v = Self.pyGet(cur, "model_pack_boot_timeout_s") {
            guard let f = PySem.asNumberNoBool(v), (10...7200).contains(f) else {
                throw NativeCoreError.invalidConfig("model_pack_boot_timeout_s 必须是 10-7200 的秒数")
            }
        }
        // error_analysis_timeout_s（0.7.5 W13 新增；5-600，显式排 bool）：
        // 下限 5——本地小模型报错分析最快也要数秒，再低必然误超时；
        // 上限 600——与反馈上传动态超时上限同档，超出即推理服务异常，不应再空等
        if let v = Self.pyGet(cur, "error_analysis_timeout_s") {
            guard let f = PySem.asNumberNoBool(v), (5...600).contains(f) else {
                throw NativeCoreError.invalidConfig("error_analysis_timeout_s 必须是 5-600 的秒数")
            }
        }
    }

    // MARK: - infer_options 校验移植（ollama/infer_options.py L390-434，文案逐字）

    /// 超时键 → (兜底值, (下限, 上限))。0 = 用默认值（合法）。
    /// M11（0.7.4 口径对齐）：timeout_stream_reading 由 Python infer_options 旧口径
    /// 30~21600 放宽为 10~7200，与 NativeOllamaChatConnector/NativeOpenAIChatConnector
    /// 读路径钳制完全一致（否则面板写不进 10~29 秒段，读路径钳制形同虚设）。
    static let timeoutKeys: [(String, Double, Double, Double)] = [
        ("timeout_connect", 10.0, 1.0, 600.0),
        ("timeout_reading", 300.0, 10.0, 7200.0),
        ("timeout_stream_reading", 1800.0, 10.0, 7200.0),
    ]

    static func timeoutValidate(_ cfg: [String: JSONValue]) -> String? {
        for (key, fb, lo, hi) in timeoutKeys {
            guard let raw = cfg[key], raw != .null else { continue }   // Python raw is None → 跳过
            guard let f = PySem.toFloat(raw) else {
                return "\(key) 必须是数值（秒）"
            }
            if f != 0 && !(lo...hi).contains(f) {
                return "\(key) 必须在 \(PySem.g(lo))~\(PySem.g(hi)) 秒之间（0=用默认值 \(PySem.g(fb))）"
            }
        }
        return nil
    }

    /// error_analysis_timeout_s 读路径（0.7.5 W13；NativeChatRuntime 与
    /// NativeOpenAIChatConnector 两处报错分析调用同源读取，隐藏键不进设置页 UI）：
    /// 缺键/<=0/非法 → 60（等价 0.7.4 前写死旧行为）；>0 钳 5~600（与写入校验同域）。
    public static func errorAnalysisTimeoutS(_ config: [String: JSONValue]) -> Double {
        guard let f = config["error_analysis_timeout_s"].flatMap(PySem.toFloat), f > 0 else { return 60.0 }
        return min(max(f, 5.0), 600.0)
    }

    /// 规范参数名集合（_PARAM_MAP["ollama"] 键；排序后与错误文案一致）。
    static let knownModelParams: Set<String> =
        ["num_ctx", "temperature", "top_p", "top_k", "repeat_penalty", "num_predict", "seed", "stop"]

    /// _PARAM_RANGE（None = 不做数值校验）。
    static let paramRanges: [String: (Double, Double)?] = [
        "num_ctx": (256, 1_048_576), "temperature": (0.0, 2.0), "top_p": (0.0, 1.0),
        "top_k": (1, 1000), "repeat_penalty": (0.0, 3.0), "num_predict": (-2, 1_048_576),
        "seed": nil, "stop": nil,
    ]

    /// 错误文案「合法范围 X~Y」逐字表（infer_options.py L412：f"{rng[0]}~{rng[1]}"）。
    /// Python 字面量 int/float 混合（num_ctx/top_k/num_predict 是 int 输出无小数点；
    /// temperature/top_p/repeat_penalty 是 float 输出带 .0），Swift 端无法用统一 Double
    /// 复刻，故按 Python 实际输出显式钉住。
    static let paramRangeHints: [String: String] = [
        "num_ctx": "256~1048576", "temperature": "0.0~2.0", "top_p": "0.0~1.0",
        "top_k": "1~1000", "repeat_penalty": "0.0~3.0", "num_predict": "-2~1048576",
    ]

    static func validateModelOptions(_ mo: JSONValue?) -> String? {
        guard let mo, mo != .null else { return nil }
        guard case .object(let root) = mo else {
            return "model_options 必须是 {模型名: {参数名: 值}} 的字典"
        }
        let allowed = knownModelParams.sorted().joined(separator: ", ")
        for (model, params) in root {
            if model.trimmingCharacters(in: .whitespaces).isEmpty {
                return "model_options 的键必须是非空模型名"
            }
            guard case .object(let pd) = params else {
                return "model_options[\(PySem.reprString(model))] 必须是参数字典"
            }
            for (k, v) in pd {
                guard knownModelParams.contains(k) else {
                    return "model_options[\(PySem.reprString(model))] 含未知参数 \(PySem.reprString(k))（可用：\(allowed)）"
                }
                if coerceParam(k, v) == nil {
                    let hint: String
                    if paramRanges[k] ?? nil != nil {
                        hint = "，合法范围 \(paramRangeHints[k] ?? "")"
                    } else {
                        hint = "（须为字符串或字符串数组）"
                    }
                    return "model_options[\(PySem.reprString(model))].\(k) 的值非法：\(PySem.repr(v))\(hint)"
                }
            }
        }
        return nil
    }

    /// infer_options._coerce（校验视角：合法返回非 nil）。
    static func coerceParam(_ canon: String, _ v: JSONValue) -> JSONValue? {
        if canon == "stop" {
            if case .string(let s) = v, !s.isEmpty { return .array([.string(s)]) }
            if PySem.isStrList(v), let arr = v.array, !arr.isEmpty { return .array(arr) }
            return nil
        }
        if canon == "seed" {
            if PySem.isBool(v) { return nil }
            switch v {
            case .int(let i): return .int(i)
            case .double(let d): return d.isFinite ? .int(Int64(d)) : nil
            case .string(let s):
                // Python int("x")：整数字符串可转
                guard let i = Int64(s.trimmingCharacters(in: .whitespaces)) else { return nil }
                return .int(i)
            default: return nil
            }
        }
        if ["num_ctx", "top_k", "num_predict"].contains(canon) {
            guard let f = PySem.toFloat(v) else { return nil }
            let iv = Int64(f)
            if let rng = paramRanges[canon] ?? nil,
               !(Int64(rng.0)...Int64(rng.1)).contains(iv) { return nil }
            return .int(iv)
        }
        // 浮点参数（temperature / top_p / repeat_penalty）
        guard let f = PySem.toFloat(v) else { return nil }
        if let rng = paramRanges[canon] ?? nil, !(rng.0...rng.1).contains(f) { return nil }
        return .double(f)
    }
}

// MARK: - NSRecursiveLock 便捷

private extension NSRecursiveLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
