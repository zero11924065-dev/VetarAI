//
//  NativePluginStore.swift
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

//  逐行为移植（⛔ 只读行为规格源：subagent/sidecar/plugin_loader/loader.py 336 行全量，
//  安装本体在 P2-W3a NativeToolInstall.installPlugin 已移植，本文件不管）：
//    · 启用状态（L56-85 checkpoint-047）：plugins_state.json {名: bool}，默认启用；
//      读失败静默空表；写 = 同目录 .tmp + os.replace 原子换名
//    · 备注（L87-122 问题5 0.4.1）：plugins_notes.json {名: 文本} 独立文件；
//      set_note strip 后空串=清除（pop 条目）；读失败静默空表
//    · 列表（L231-251）：sorted(PLUGINS_ROOT.iterdir()) 仅目录；有 manifest.json
//      则 json.loads + path 注入，无则 {name, path}；逐项合并 enabled（默认 true）
//      与 note（无备注空串）
//    · 卸载（L253-275）：rmtree；state/notes 有条目才重写且**写失败静默 pass**
//    · hook 模块解析（L279-305）：manifest entry_point 缺省 plugin.py（manifest 读
//      失败也回落 plugin.py）；入口文件缺席 → 模块 None → 端点 404
//
//  并发纪律：Python 侧靠 GIL + 原子换名；本层进程内单 NSLock 串行化全部
//  读-改-写（插件管理是低频面板操作，无热路径），原子换名用 POSIX rename(2)
//  （= os.replace 语义：同目录换名覆盖，绝不先删后写留空窗）。
//
//  微差（汇报清单同步）：
//    ① state/notes 落盘键序不保 Python 插入序（JSON 对象无序，语义等价）；
//    ② manifest.json 损坏时 Python 端点 500 详情为框架通用文案，本层 500
//       detail 带「插件 <名> 的 manifest.json 解析失败」（更可诊断）；
//    ③ toggle 的 installed 名单遇 manifest 缺 name 键：Python KeyError 崩 500，
//       本层按「插件不存在」走 nil（→ 端点 400）。
//

import Foundation
import Darwin

public final class NativePluginStore: @unchecked Sendable {

    public let pluginsRoot: URL
    private let lock = NSLock()

    public init(pluginsRoot: URL) {
        self.pluginsRoot = pluginsRoot
        // loader.py L34：PLUGINS_ROOT.mkdir(parents=True, exist_ok=True)
        try? FileManager.default.createDirectory(at: pluginsRoot, withIntermediateDirectories: true)
    }

    private var statePath: URL { pluginsRoot.appendingPathComponent("plugins_state.json") }
    private var notesPath: URL { pluginsRoot.appendingPathComponent("plugins_notes.json") }

    // MARK: - 原子写（_write_state/_write_notes L67-71/L104-108：.tmp + os.replace）

    /// json.dumps(obj, ensure_ascii=False, indent=2) 落 tmp 后 rename 覆盖。
    /// ⚠️ 键序不保 Python 插入序（Swift 字典无序）——JSON 对象无序语义等价，
    /// 与 NativeJSONWriter 文件头既有口径一致。
    static func writeAtomicJSON(_ value: JSONValue, to path: URL) throws {
        let tmp = path.deletingLastPathComponent()
            .appendingPathComponent(path.lastPathComponent + ".tmp")
        try NativeJSONWriter.dumps(value).write(to: tmp, atomically: false, encoding: .utf8)
        if rename(tmp.path, path.path) != 0 {
            try? FileManager.default.removeItem(at: tmp)
            throw NativeCoreError.io("写入 \(path.lastPathComponent) 失败（rename errno=\(errno)）")
        }
    }

    // MARK: - 启用状态（L56-85）

    /// _read_state：不存在/解析失败 → 空表（except Exception: pass）。
    func readState() -> [String: Bool] {
        guard let data = try? Data(contentsOf: statePath),
              case .object(let obj)? = NativeJSONWriter.loads(data) else { return [:] }
        var out: [String: Bool] = [:]
        for (k, v) in obj { out[k] = v.truthy }   // {k: bool(v) for ...}
        return out
    }

    /// is_enabled（L73-75）：默认启用。
    public func isEnabled(_ pluginName: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return readState()[pluginName] ?? true
    }

    /// toggle_enabled（L77-85）：插件不存在返回 nil；存在则翻转并持久化。
    /// installed 名单 = list_installed 各项的 name（Python 同款——manifest 缺 name
    /// 键的目录项 Python 侧会 KeyError 崩 500，本层按「不存在」计，记为微差③）。
    public func toggleEnabled(_ pluginName: String) throws -> Bool? {
        lock.lock(); defer { lock.unlock() }
        let installed = Set(try listInstalledLocked().compactMap { $0["name"]?.string })
        guard installed.contains(pluginName) else { return nil }
        var state = readState()
        let new = !(state[pluginName] ?? true)
        state[pluginName] = new
        try? Self.writeAtomicJSON(.object(state.mapValues { .bool($0) }), to: statePath)
        return new
    }

    // MARK: - 备注（L87-122）

    /// _read_notes：不存在/解析失败 → 空表。
    func readNotes() -> [String: String] {
        guard let data = try? Data(contentsOf: notesPath),
              case .object(let obj)? = NativeJSONWriter.loads(data) else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in obj { out[k] = v.pyStr }   // {k: str(v) for ...}
        return out
    }

    /// get_note（L110-111）。
    public func getNote(_ pluginName: String) -> String {
        lock.lock(); defer { lock.unlock() }
        return readNotes()[pluginName] ?? ""
    }

    /// set_note（L113-122）：strip 后空串=清除；返回最终备注。
    @discardableResult
    public func setNote(_ pluginName: String, note: String) -> String {
        lock.lock(); defer { lock.unlock() }
        var notes = readNotes()
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)   // Python str.strip()
        if !trimmed.isEmpty {
            notes[pluginName] = trimmed
        } else {
            notes.removeValue(forKey: pluginName)
        }
        try? Self.writeAtomicJSON(.object(notes.mapValues { .string($0) }), to: notesPath)
        return notes[pluginName] ?? ""
    }

    // MARK: - 列表（L231-251）

    /// list_installed。manifest.json 读/解析失败 → 抛（Python json.loads 异常
    /// 上抛 → 端点 500 同口径；详情文案不逐字，记为微差②）；目录排序按路径字符串
    /// （Python sorted(PosixPath) 同序）。
    public func listInstalled() throws -> [[String: JSONValue]] {
        lock.lock(); defer { lock.unlock() }
        return try listInstalledLocked()
    }

    private func listInstalledLocked() throws -> [[String: JSONValue]] {
        let fm = FileManager.default
        let dirs = ((try? fm.contentsOfDirectory(atPath: pluginsRoot.path)) ?? [])
            .map { pluginsRoot.appendingPathComponent($0) }
            .sorted { $0.path < $1.path }          // sorted(PLUGINS_ROOT.iterdir())
        var results: [[String: JSONValue]] = []
        for p in dirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: p.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let mf = p.appendingPathComponent("manifest.json")
            var item: [String: JSONValue]
            if fm.fileExists(atPath: mf.path) {
                guard let data = try? Data(contentsOf: mf),
                      case .object(let obj)? = NativeJSONWriter.loads(data) else {
                    throw NativeCoreError.io("插件 \(p.lastPathComponent) 的 manifest.json 解析失败")
                }
                item = obj
                item["path"] = .string(p.path)
            } else {
                item = ["name": .string(p.lastPathComponent), "path": .string(p.path)]
            }
            results.append(item)
        }
        // checkpoint-047：附逐项启用状态（默认启用）
        let state = readState()
        for i in results.indices {
            let name = results[i]["name"]?.string ?? ""
            results[i]["enabled"] = .bool(state[name] ?? true)
        }
        // 问题5（0.4.1）：附用户备注（无备注为空串）
        let notes = readNotes()
        for i in results.indices {
            let name = results[i]["name"]?.string ?? ""
            results[i]["note"] = .string(notes[name] ?? "")
        }
        return results
    }

    // MARK: - 卸载（L253-275）

    /// uninstall：目录不存在 → false；rmtree 后清理 state/notes 条目
    /// （仅当条目存在才重写；**写失败静默 pass**逐字）。
    @discardableResult
    public func uninstall(_ pluginName: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let p = pluginsRoot.appendingPathComponent(pluginName)
        guard FileManager.default.fileExists(atPath: p.path) else { return false }
        try? FileManager.default.removeItem(at: p)
        // checkpoint-047：卸载时清理启用状态条目
        var state = readState()
        if state[pluginName] != nil {
            state.removeValue(forKey: pluginName)
            try? Self.writeAtomicJSON(.object(state.mapValues { .bool($0) }), to: statePath)
        }
        // 问题5（0.4.1）：卸载时同步清理备注
        var notes = readNotes()
        if notes[pluginName] != nil {
            notes.removeValue(forKey: pluginName)
            try? Self.writeAtomicJSON(.object(notes.mapValues { .string($0) }), to: notesPath)
        }
        return true
    }

    // MARK: - hook 模块解析（_load_plugin_module L279-305 的前半段）

    /// 插件目录是否存在（pdir.exists()）。
    public func pluginDirExists(_ pluginName: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: pluginsRoot.appendingPathComponent(pluginName).path, isDirectory: &isDir)
    }

    /// manifest entry_point 读取（L286-292）：manifest 缺席/损坏/缺键 → "plugin.py"。
    public func entryPoint(_ pluginName: String) -> String {
        let mf = pluginsRoot.appendingPathComponent(pluginName).appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: mf),
              case .object(let obj)? = NativeJSONWriter.loads(data),
              let entry = obj["entry_point"]?.string else { return "plugin.py" }
        return entry
    }

    /// 入口文件是否存在（entry_path.exists()，L294-296）。
    public func entryFileExists(_ pluginName: String, entryPoint: String) -> Bool {
        FileManager.default.fileExists(atPath:
            pluginsRoot.appendingPathComponent(pluginName).appendingPathComponent(entryPoint).path)
    }

    /// hook 调用模块名（L299）：subagent_plugin_<名，- 换 _>。
    public static func moduleName(_ pluginName: String) -> String {
        "subagent_plugin_" + pluginName.replacingOccurrences(of: "-", with: "_")
    }
}

// MARK: - JSONValue 的 Python 语义小工具（本文件私有口径）

private extension JSONValue {
    /// Python bool(v)：false/0/0.0/""/[]/{}/null → false，其余 true。
    var truthy: Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .double(let d): return d != 0
        case .string(let s): return !s.isEmpty
        case .array(let a): return !a.isEmpty
        case .object(let o): return !o.isEmpty
        }
    }

    /// Python str(v)（notes 值的 {k: str(v)} 归一；常态本来就是 string）。
    var pyStr: String {
        switch self {
        case .string(let s): return s
        case .null: return "None"
        case .bool(let b): return b ? "True" : "False"
        case .int(let i): return String(i)
        case .double(let d): return NativeDatabase.dumpsUTF8(self)
        case .array, .object: return NativeDatabase.dumpsUTF8(self)
        }
    }
}
