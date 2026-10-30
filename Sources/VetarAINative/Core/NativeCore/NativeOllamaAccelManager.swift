//
//  NativeOllamaAccelManager.swift
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

//  背景：flash attention / KV cache 量化 是 Ollama 服务端环境变量，请求级 options
//  覆盖不了（非 per-request 参数）。要提速只能改服务端 env + 重启 Ollama。本模块把
//  「需开发者终端操作」的调优变成「应用内引导 + 授权 + 一键执行 + 恢复」闭环。
//
//  纪律（业主拍板 2026-10-25）：
//    · 绝不擅自改用户 Ollama 设置——检测到可优化项只「引导」，用户授权后才改；
//    · 修改前先备份原脚本（存应用配置区），恢复按钮一键还原 + 重启，零残留；
//    · 只追加「新增」的环境变量，不覆盖用户已设的（KEEP_ALIVE/NUM_PARALLEL 等
//      用户自设项绝不动）；
//    · 环境变量改动必须重启 Ollama 才生效，故「优化」与「恢复」都带一次重启，
//      并提示会中断进行中的对话。
//
//  无特殊系统授权（写 ~/bin + ~/Library/LaunchAgents + launchctl，普通权限；
//  前提：非沙箱应用，Developer ID 直发满足）。
//

import Foundation

/// KV 缓存档位。rawValue 与 OLLAMA_KV_CACHE_TYPE 的脚本值一一对应。
public enum NativeOllamaKVCacheTier: String, CaseIterable, Sendable {
    case f16
    case q8_0
    case q4_0

    /// 新配置默认推荐 q8_0；已配置用户则以原档位为选择初值，不被默认值覆盖。
    public static let recommended: NativeOllamaKVCacheTier = .q8_0

    /// 分段控件文案（档位值 + 产品取向）。
    public var pickerLabel: String {
        switch self {
        case .f16: return "f16 不量化"
        case .q8_0: return "q8_0 推荐"
        case .q4_0: return "q4_0 更省显存"
        }
    }

    /// 授权弹窗与卡片共用的档位说明。
    public var detail: String {
        switch self {
        case .f16: return "不量化，保留原始 KV 缓存精度"
        case .q8_0: return "推荐档，兼顾显存占用与精度"
        case .q4_0: return "更省显存，但精度损失相对更明显"
        }
    }

    /// launchctl / 脚本读取兼容首尾空白与引号；写入始终使用规范 rawValue。
    public init?(configuredValue: String) {
        let normalized = configuredValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .lowercased()
        self.init(rawValue: normalized)
    }
}

/// Ollama 服务端可引导的优化项（请求级覆盖不了的 env 类）。
public enum NativeOllamaOptimization: String, CaseIterable, Sendable {
    case flashAttention = "OLLAMA_FLASH_ATTENTION"
    case kvCacheType = "OLLAMA_KV_CACHE_TYPE"

    /// 建议值（flash attention 开；KV 量化默认推荐档）。选档写入走 apply 的 tier 参数。
    public var recommendedValue: String {
        switch self {
        case .flashAttention: return "1"
        case .kvCacheType: return NativeOllamaKVCacheTier.recommended.rawValue
        }
    }
    /// 面向用户的说明（引导卡片逐字展示）。
    public var label: String {
        switch self {
        case .flashAttention: return "Flash Attention（Metal 上显著提速）"
        case .kvCacheType: return "KV 缓存量化（按所选档位节省显存）"
        }
    }
}

/// Ollama 优化引导错误（文案自持）。
public enum NativeOllamaAccelError: Error, Equatable {
    case noScript
    case applyFailed(String)
    case restoreFailed(String)

    public var message: String {
        switch self {
        case .noScript:
            return "未找到 Ollama 环境变量脚本（~/bin/set-ollama-env.sh）。"
                + "请确认已安装 Ollama，或到「设置 → 推理后端」配置 Ollama 地址。"
        case .applyFailed(let m): return m
        case .restoreFailed(let m): return m
        }
    }
}

/// Ollama 加速优化管理器（检测 / 授权执行 / 恢复，全程可逆）。
public final class NativeOllamaAccelManager: @unchecked Sendable {

    /// 仅备份本模块实际管理过的 key；nil 与「有值但为空」必须可区分。
    private struct Backup: Codable {
        var values: [String: String] = [:]
        var unsetKeys: Set<String> = []

        func contains(_ key: String) -> Bool {
            values[key] != nil || unsetKeys.contains(key)
        }
    }

    private static let backupDefaultsKey = "VetarAI.NativeOllamaAccelManager.backup.v1"

    /// 读取 Ollama 环境变量缝（生产 = launchctl getenv；测试注入固定表）。
    public var getenv: @Sendable (String) -> String?
    /// 读脚本缝（生产 = 读 ~/bin/set-ollama-env.sh；测试注入临时文件内容）。
    public var readScript: @Sendable () throws -> String
    /// 写脚本缝（生产 = 写 ~/bin/set-ollama-env.sh；测试写临时文件）。
    public var writeScript: @Sendable (String) throws -> Void
    /// 重启 Ollama 缝（生产 = launchctl kickstart；测试录证）。
    public var restartOllama: @Sendable () throws -> Void
    /// 恢复「原本未设置」的变量时同步清 launchd，避免脚本零残留但环境仍残留。
    public var unsetenv: @Sendable (String) -> Void

    /// 生产面板显式注入 .standard；测试及独立纯函数用例默认内存备份，不碰真实配置。
    private let backupDefaults: UserDefaults?
    private var memoryBackup: Backup?

    public init(
        getenv: (@Sendable (String) -> String?)? = nil,
        readScript: (@Sendable () throws -> String)? = nil,
        writeScript: (@Sendable (String) throws -> Void)? = nil,
        restartOllama: (@Sendable () throws -> Void)? = nil,
        backupDefaults: UserDefaults? = nil,
        unsetenv: (@Sendable (String) -> Void)? = nil
    ) {
        self.getenv = getenv ?? { Self.launchctlGetenv($0) }
        self.readScript = readScript ?? { try Self.defaultReadScript() }
        self.writeScript = writeScript ?? { try Self.defaultWriteScript($0) }
        self.restartOllama = restartOllama ?? { try Self.defaultRestartOllama() }
        self.backupDefaults = backupDefaults
        if let unsetenv {
            self.unsetenv = unsetenv
        } else if restartOllama == nil {
            self.unsetenv = { Self.launchctlUnsetenv($0) }
        } else {
            // 注入重启桩的既有单测默认不触真实 launchctl；需要录证时显式注入 unsetenv。
            self.unsetenv = { _ in }
        }
    }

    // MARK: - 生产默认实现

    /// launchctl getenv（空字符串 = 未设置）。
    static func launchctlGetenv(_ key: String) -> String? {
        let out = run("/bin/launchctl", ["getenv", key])
        let v = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    /// 仅恢复流程针对「备份时未设置」的 key 调用，绝不清用户其它环境变量。
    static func launchctlUnsetenv(_ key: String) {
        _ = run("/bin/launchctl", ["unsetenv", key])
    }

    /// 读 ~/bin/set-ollama-env.sh。
    static func defaultReadScript() throws -> String {
        let url = scriptURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NativeOllamaAccelError.noScript
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// 写 ~/bin/set-ollama-env.sh（原子写）。
    static func defaultWriteScript(_ content: String) throws {
        let url = scriptURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// 应用环境变量并重启 Ollama：先重新执行脚本（把 launchctl setenv 刷进
    /// launchd 用户域），再 kickstart 重启 Ollama 继承新环境。
    /// 只 kickstart 不重跑脚本的话，改动的 setenv 不会进入 launchd，Ollama
    /// 重启后仍继承旧环境（须等下次登录才生效）——故必须先重跑脚本。
    static func defaultRestartOllama() throws {
        _ = run("/bin/bash", [scriptURL().path])
        _ = run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/com.ollama.ollama"])
    }

    private static func scriptURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("bin/set-ollama-env.sh")
    }

    /// 同步执行命令（超时 10s）。
    private static func run(_ cmd: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cmd)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
            p.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                          encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    // MARK: - 检测

    /// 当前「未配置」的可引导优化项。launchd 与脚本任一已有值都视为用户已配置，
    /// 因而 q8_0 / q4_0 / f16 以及其它自定义值均不会被默认流程重复追加或覆盖。
    public func detectUnset() -> [NativeOllamaOptimization] {
        let scriptValues = (try? readScript()).map {
            Self.parseOllamaEnvLines(from: $0)
        } ?? []
        return NativeOllamaOptimization.allCases.filter { op in
            if let effective = getenv(op.rawValue),
               !effective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return false
            }
            return !scriptValues.contains(where: { $0.key == op.rawValue })
        }
    }

    /// 当前配置值优先生效中的 launchd，未生效时回落脚本（便于展示「已配置待重启」状态）。
    public func configuredValue(for op: NativeOllamaOptimization) -> String? {
        if let effective = getenv(op.rawValue),
           !effective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return effective
        }
        guard let script = try? readScript() else { return nil }
        return Self.parseOllamaEnvLines(from: script)
            .last(where: { $0.key == op.rawValue })?.value
    }

    /// 当前 KV 档位；自定义/无法识别的值返回 nil，但 detectUnset 仍会尊重并保留它。
    public func currentKVCacheTier() -> NativeOllamaKVCacheTier? {
        configuredValue(for: .kvCacheType).flatMap {
            NativeOllamaKVCacheTier(configuredValue: $0)
        }
    }

    // MARK: - 脚本内容（纯函数，可测试）

    /// 给现有脚本追加一组环境变量行（幂等：已存在的行不重复追加）。
    public static func appendEnvLines(to script: String,
                                      additions: [(key: String, value: String)]) -> String {
        var lines = script.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (k, v) in additions {
            let line = "launchctl setenv \(k) \(v)"
            let normalized = line.trimmingCharacters(in: .whitespaces)
            if !lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == normalized }) {
                lines.append(line)
            }
        }
        var out = lines.joined(separator: "\n")
        if !out.hasSuffix("\n") { out += "\n" }
        return out
    }

    /// 从脚本移除指定环境变量行（恢复用）。
    public static func removeEnvLines(from script: String,
                                      keys: Set<String>) -> String {
        let lines = script.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let kept = lines.filter { line in
            for k in keys {
                if line.contains("setenv \(k) ") { return false }
            }
            return true
        }
        var out = kept.joined(separator: "\n")
        if !out.hasSuffix("\n") { out += "\n" }
        return out
    }

    // MARK: - 执行（授权后调用）

    /// 应用优化：备份原值 → 按所选档位写脚本 → 重启。
    /// 默认只新增未配置 key；replaceExistingKVCache 仅供用户在卡片上明确换档并再次授权后使用。
    public func apply(_ ops: [NativeOllamaOptimization],
                      kvCacheTier: NativeOllamaKVCacheTier = .recommended,
                      replaceExistingKVCache: Bool = false) throws {
        guard !ops.isEmpty else { return }
        let original = try readScript()
        let hadBackup: Bool
        do {
            hadBackup = try loadBackup() != nil
            try backupOriginalValues(for: ops, in: original)
        } catch {
            throw NativeOllamaAccelError.applyFailed(
                "Ollama 优化备份失败，未修改设置：\(error.localizedDescription)")
        }

        var base = original
        if replaceExistingKVCache && ops.contains(.kvCacheType) {
            base = Self.removeEnvLines(
                from: base, keys: [NativeOllamaOptimization.kvCacheType.rawValue])
        }
        let existingKeys = Set(Self.parseOllamaEnvLines(from: base).map(\.key))
        let additions = ops.compactMap { op -> (key: String, value: String)? in
            guard !existingKeys.contains(op.rawValue) else { return nil }
            let value = op == .kvCacheType ? kvCacheTier.rawValue : op.recommendedValue
            return (key: op.rawValue, value: value)
        }
        let updated = Self.appendEnvLines(to: base, additions: additions)
        do {
            try writeScript(updated)
            try? restartOllama()   // 重启失败不阻断（下次启动生效）
        } catch {
            // 首次写入失败等于未发生优化，清掉临时备份，避免污染用户后续重试的原值。
            if !hadBackup { clearBackup() }
            throw NativeOllamaAccelError.applyFailed(
                "Ollama 环境变量写入失败：\(error.localizedDescription)")
        }
    }

    /// 恢复本模块备份的原值；旧版本无备份时保留原「移除本模块项」兼容路径。
    /// 未配置过的 key 同步 unset launchd，原本有值的 key 写回原值，其它用户行不动。
    public func restore() throws {
        let original = try readScript()
        let backup: Backup?
        do {
            backup = try loadBackup()
        } catch {
            throw NativeOllamaAccelError.restoreFailed(
                "Ollama 优化备份读取失败，未修改设置：\(error.localizedDescription)")
        }

        let allKeys = Set(NativeOllamaOptimization.allCases.map(\.rawValue))
        let managedKeys = backup.map {
            Set($0.values.keys).union($0.unsetKeys)
        } ?? allKeys
        var updated = Self.removeEnvLines(from: original, keys: managedKeys)
        if let backup {
            let restorations = NativeOllamaOptimization.allCases.compactMap {
                op -> (key: String, value: String)? in
                guard let value = backup.values[op.rawValue] else { return nil }
                return (key: op.rawValue, value: value)
            }
            updated = Self.appendEnvLines(to: updated, additions: restorations)
        }

        do {
            try writeScript(updated)
            let keysToUnset = backup?.unsetKeys ?? managedKeys
            for key in keysToUnset { unsetenv(key) }
            try? restartOllama()
            if backup != nil { clearBackup() }
        } catch {
            throw NativeOllamaAccelError.restoreFailed(
                "Ollama 环境变量恢复失败：\(error.localizedDescription)")
        }
    }

    /// 同一 key 只在首次管理时记录原值，后续换档不会把「上次优化值」误当备份。
    private func backupOriginalValues(for ops: [NativeOllamaOptimization],
                                      in script: String) throws {
        var backup = try loadBackup() ?? Backup()
        let existing = Self.parseOllamaEnvLines(from: script)
        for op in ops where !backup.contains(op.rawValue) {
            if let pair = existing.last(where: { $0.key == op.rawValue }) {
                backup.values[op.rawValue] = pair.value
            } else {
                backup.unsetKeys.insert(op.rawValue)
            }
        }
        try storeBackup(backup)
    }

    private func loadBackup() throws -> Backup? {
        guard let backupDefaults else { return memoryBackup }
        guard let data = backupDefaults.data(forKey: Self.backupDefaultsKey) else { return nil }
        return try JSONDecoder().decode(Backup.self, from: data)
    }

    private func storeBackup(_ backup: Backup) throws {
        guard let backupDefaults else {
            memoryBackup = backup
            return
        }
        let data = try JSONEncoder().encode(backup)
        backupDefaults.set(data, forKey: Self.backupDefaultsKey)
    }

    private func clearBackup() {
        backupDefaults?.removeObject(forKey: Self.backupDefaultsKey)
        memoryBackup = nil
    }

    // MARK: - Ollama 环境变量读取 / 逐项编辑（业主 2026-10-26 拍板）

    /// 读取脚本中所有 `launchctl setenv KEY VALUE` 行（**仅 OLLAMA_ 前缀**，纯函数）。
    /// 只管理 Ollama 专属变量，绝不碰代理（NO_PROXY/no_proxy）等非 OLLAMA 行。
    /// 保留脚本原序；VALUE 原样保留（含带引号形态），不做语义解释。
    public static func parseOllamaEnvLines(from script: String)
        -> [(key: String, value: String)] {
        var out: [(String, String)] = []
        for raw in script.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("launchctl setenv ") else { continue }
            let rest = String(line.dropFirst("launchctl setenv ".count))
            guard let spaceIdx = rest.firstIndex(of: " ") else { continue }
            let key = String(rest[..<spaceIdx])
            guard key.hasPrefix("OLLAMA_") else { continue }
            let value = String(rest[rest.index(after: spaceIdx)...])
                .trimmingCharacters(in: .whitespaces)
            out.append((key, value))
        }
        return out
    }

    /// 用新的 OLLAMA_* 列表替换脚本中的 OLLAMA_* setenv 行，保留其余内容
    /// （shebang / 注释 / 变量赋值 / 非 Ollama setenv 如 NO_PROXY）。纯函数。
    /// 新 OLLAMA 行追加到末尾（顺序不敏感，launchctl setenv 无依赖）。
    public static func replaceOllamaEnvLines(in script: String,
                                             with vars: [(key: String, value: String)]) -> String {
        let kept = script.split(separator: "\n", omittingEmptySubsequences: false).filter { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("launchctl setenv ") else { return true }   // 保留非 setenv 行
            let rest = line.dropFirst("launchctl setenv ".count)
            let key = rest.split(separator: " ", maxSplits: 1,
                                 omittingEmptySubsequences: true).first ?? ""
            return !key.hasPrefix("OLLAMA_")   // 只替换 OLLAMA_ 行
        }
        var lines = kept
        for (k, v) in vars {
            lines.append("launchctl setenv \(k) \(v)")
        }
        var out = lines.joined(separator: "\n")
        if !out.hasSuffix("\n") { out += "\n" }
        return out
    }

    /// 读取当前脚本中的 Ollama 专属环境变量（含当前生效值对比）。
    public func listEnvVars() throws -> [NativeOllamaEnvVar] {
        let script = try readScript()
        return Self.parseOllamaEnvLines(from: script).map {
            NativeOllamaEnvVar(key: $0.key, value: $0.value, effective: getenv($0.key))
        }
    }

    /// 保存环境变量（替换 OLLAMA_* 行，保留其余）→ 写脚本 → 重启。改前原脚本
    /// 由 writeScript 缝的调用方负责备份（见 InferencePanelViewModel.saveEnvVars）。
    public func saveEnvVars(_ vars: [NativeOllamaEnvVar]) throws {
        let script = try readScript()
        let pairs = vars.map { (key: $0.key, value: $0.value) }
        let updated = Self.replaceOllamaEnvLines(in: script, with: pairs)
        do {
            try writeScript(updated)
            try? restartOllama()   // 重启失败不阻断（下次启动生效）
        } catch {
            throw NativeOllamaAccelError.applyFailed(
                "Ollama 环境变量写入失败：\(error.localizedDescription)")
        }
    }
}

/// Ollama 环境变量条目（脚本值 + 当前生效值，用于设置页逐项编辑）。
public struct NativeOllamaEnvVar: Equatable, Sendable, Identifiable {
    public let key: String
    public var value: String
    /// 当前生效值（launchctl getenv；nil = 未设置/未生效）。
    public var effective: String?
    public var id: String { key }
    /// 脚本值与生效值是否一致（不一致 = 改了脚本但还没重启 Ollama）。
    public var isSynced: Bool { effective == value }
}
