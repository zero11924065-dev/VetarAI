//
//  NativeModelPackStore.swift
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

//  逐行为移植（⛔ 只读行为规格源：subagent/sidecar/model_packs/store.py，260 行）：
//    · packs_root 解析链（L50-73）：env VETARAI_MODEL_PACKS_DIR > config
//      model_packs_dir > {data_root}/models/packs；每次调用实时解析（设置页改
//      model_packs_dir 立即生效）；铁律：任一父级组件以 .app 结尾 → 拒绝
//      （打包后 Resources 只读且重签失效，写进去等于静默丢模型）
//    · registry.json 读（损坏一律 {}）/ 原子写（tmp + rename，L103-111）
//    · register/unregister/set_enabled（L122-168；status installed|disabled）
//    · manifest.json 副本读取（L171-189；展示元数据以它为准，注册表只存运行必需）
//    · list_installed（L192-242）：注册表 + 磁盘探测（缺文件/实际占用/.partial 残留）
//      + manifest 合并（name/description/context_length）
//    · remove_pack（L245-260）：先删目录再清注册表（删目录抛错时注册表仍在可重试）
//
//  偏差：
//    ① registry.json 落盘键序为字典序（NativeJSONWriter 既定口径；Python 保插入序——
//       JSON 无序语义不受键序影响，双跑比对以读回内容为准）。
//

import Foundation

/// 模型包存储错误（端点层映射：packsRootForbidden → 500；invalidPackId → 400/按点处理）。
public enum NativeModelPackError: Error, Equatable {
    /// packs_root 铁律：安装根落在 .app 包内（store.py L69-71 RuntimeError 逐字文案）。
    case packsRootForbidden(String)
    /// pack_dir 的非法 pack_id（store.py L82 ValueError 逐字文案）。
    case invalidPackId(String)
    /// IO 失败（原子替换等）。
    case io(String)

    public var message: String {
        switch self {
        case .packsRootForbidden(let p): return "模型包安装根不允许位于 .app 包内: \(p)"
        case .invalidPackId(let pid):
            return "非法 pack_id（须 slug 小写字母/数字/-/_，1~64 长）: \(PySem.reprString(pid))"
        case .io(let m): return m
        }
    }
}

public final class NativeModelPackStore: @unchecked Sendable {

    public static let envPacksDir = "VETARAI_MODEL_PACKS_DIR"

    /// 注册表锁（store.py _LOCK = threading.RLock 等价；read/write 均经它串行）。
    private let lock = NSLock()
    /// 环境变量表（VETARAI_MODEL_PACKS_DIR 解析用；测试注入，生产 = 进程环境）。
    public var environment: [String: String]
    private let configProvider: @Sendable () -> [String: JSONValue]
    private let dataRootProvider: @Sendable () -> URL

    /// - Parameters:
    ///   - configProvider: get_config() 动态读（packs_root 每次实时解析同款）。
    ///   - dataRootProvider: data_root() 解析（kernel 注入 config.dataRoot）。
    ///   - environment: env 解析表（默认进程环境；测试注入隔离）。
    public init(configProvider: @escaping @Sendable () -> [String: JSONValue],
                dataRootProvider: @escaping @Sendable () -> URL,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.configProvider = configProvider
        self.dataRootProvider = dataRootProvider
        self.environment = environment
    }

    /// 生产装配：直接吃 NativeConfigStore（解析链与 Python 同源）。
    public convenience init(config: NativeConfigStore) {
        self.init(
            configProvider: { (try? config.getConfig()) ?? NativeConfigStore.defaultConfig },
            dataRootProvider: { config.dataRoot() })
    }

    // MARK: - packs_root（L50-73）

    /// 解析模型包安装根（每次调用实时解析）。
    /// 优先级：env VETARAI_MODEL_PACKS_DIR > config model_packs_dir > data_root()/models/packs。
    /// - Throws: NativeModelPackError.packsRootForbidden（任一父级组件以 .app 结尾）。
    @discardableResult
    public func packsRoot() throws -> URL {
        var raw = (environment[Self.envPacksDir] ?? "").trimmingCharacters(in: .whitespaces)
        if raw.isEmpty {
            raw = (configProvider()["model_packs_dir"]?.string ?? "")
                .trimmingCharacters(in: .whitespaces)
        }
        let p: URL
        if !raw.isEmpty {
            p = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        } else {
            p = dataRootProvider().appendingPathComponent("models/packs")
        }
        // 封印铁律（L69-71）：安装根永不落在 .app 包内
        if p.pathComponents.contains(where: { $0.hasSuffix(".app") }) {
            throw NativeModelPackError.packsRootForbidden(p.path)
        }
        try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
        return p
    }

    /// registry_path（L76-77）。
    public func registryPath() throws -> URL {
        try packsRoot().appendingPathComponent("registry.json")
    }

    /// pack_dir（L80-83）：非法 pack_id → invalidPackId。
    public func packDir(_ packId: String) throws -> URL {
        guard NativeModelPackManifest.validPackId(packId) else {
            throw NativeModelPackError.invalidPackId(packId)
        }
        return try packsRoot().appendingPathComponent(packId)
    }

    /// partial_dir（L86-87）。
    public func partialDir(_ packId: String) throws -> URL {
        try packDir(packId).appendingPathComponent(".partial")
    }

    // MARK: - registry.json 读写（L90-111）

    /// read_registry：文件缺失/损坏一律返回 {}（损坏不阻断列表，宁可当空装）。
    public func readRegistry() -> [String: [String: JSONValue]] {
        lock.lock(); defer { lock.unlock() }
        return readRegistryLocked()
    }

    private func readRegistryLocked() -> [String: [String: JSONValue]] {
        guard let path = try? registryPath(),
              let data = try? Data(contentsOf: path),
              let v = NativeJSONWriter.loads(data),
              case .object(let o) = v else { return [:] }
        var out: [String: [String: JSONValue]] = [:]
        for (k, val) in o where val.object != nil {
            out[k] = val.object
        }
        return out
    }

    /// write_registry：tmp + rename 原子写（写一半被 kill 不得留下半截注册表）。
    public func writeRegistry(_ reg: [String: [String: JSONValue]]) throws {
        lock.lock(); defer { lock.unlock() }
        try writeRegistryLocked(reg)
    }

    private func writeRegistryLocked(_ reg: [String: [String: JSONValue]]) throws {
        let path = try registryPath()
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = path.deletingLastPathComponent()
            .appendingPathComponent(path.lastPathComponent + ".tmp")
        let obj = JSONValue.object(reg.mapValues { .object($0) })
        try NativeJSONWriter.dumps(obj).write(to: tmp, atomically: false, encoding: .utf8)
        // os.replace 同语义：同目录 rename(2)，目标存在则原子覆盖
        if rename(tmp.path, path.path) != 0 {
            throw NativeModelPackError.io("原子替换失败: \(String(cString: strerror(errno)))")
        }
    }

    // MARK: - 查询（L114-119）

    public func isInstalled(_ packId: String) -> Bool {
        readRegistry()[packId] != nil
    }

    public func getEntry(_ packId: String) -> [String: JSONValue]? {
        readRegistry()[packId]
    }

    // MARK: - register / unregister / set_enabled（L122-168）

    /// register_pack：下载全部完成后登记（status 默认 installed；files 只留三键，
    /// sha256 小写化；installed_at = datetime.now().isoformat(timespec="seconds")）。
    public func registerPack(_ packId: String, pack: [String: JSONValue]) throws {
        guard NativeModelPackManifest.validPackId(packId) else {
            throw NativeModelPackError.invalidPackId(packId)
        }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let files: [JSONValue] = (pack["files"]?.array ?? []).compactMap { f -> JSONValue? in
            guard case .object(let fo) = f, case .string(let p) = fo["path"] else { return nil }
            return .object([
                "path": .string(p),
                "size_bytes": fo["size_bytes"] ?? .int(0),
                "sha256": .string((fo["sha256"]?.string ?? "").lowercased()),
            ])
        }
        let entry: [String: JSONValue] = [
            "status": .string("installed"),
            "installed_at": .string(df.string(from: Date())),
            "version": .string(pack["version"].map(WFText.pyStr) ?? ""),
            "task": .string(pack["task"].map(WFText.pyStr) ?? ""),
            "format": .string(pack["format"].map(WFText.pyStr) ?? ""),
            "driver": .string(pack["driver"].map(WFText.pyStr) ?? ""),
            "files": .array(files),
            "sha256_ok": .bool(true),
        ]
        lock.lock()
        var reg = readRegistryLocked()
        reg[packId] = entry
        try writeRegistryLocked(reg)
        lock.unlock()
    }

    /// unregister_pack：移除注册表条目；不存在返回 false。
    @discardableResult
    public func unregisterPack(_ packId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var reg = readRegistryLocked()
        guard reg[packId] != nil else { return false }
        reg[packId] = nil
        try? writeRegistryLocked(reg)
        return true
    }

    /// set_enabled：启用/禁用持久化。返回新状态；未安装返回 nil。
    @discardableResult
    public func setEnabled(_ packId: String, enabled: Bool) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        var reg = readRegistryLocked()
        guard var entry = reg[packId] else { return nil }
        entry["status"] = .string(enabled ? "installed" : "disabled")
        reg[packId] = entry
        try? writeRegistryLocked(reg)
        return enabled
    }

    // MARK: - manifest.json 副本（L171-189）

    /// _manifest_copy / read_manifest：读包内 manifest.json 副本；读不到返回 {}。
    public func readManifest(_ packId: String) -> [String: JSONValue] {
        guard let path = try? packDir(packId).appendingPathComponent("manifest.json"),
              let data = try? Data(contentsOf: path),
              let v = NativeJSONWriter.loads(data),
              case .object(let o) = v else { return [:] }
        return o
    }

    // MARK: - list_installed（L192-242）

    /// 已安装列表：注册表条目 + 磁盘探测（缺文件/实际占用/半截下载残留）。
    /// 探测以磁盘为准而非盲信注册表。
    public func listInstalled() -> [[String: JSONValue]] {
        let fm = FileManager.default
        var out: [[String: JSONValue]] = []
        // Python sorted(dict.items())：pack_id 字典序
        for (packId, entry) in readRegistry().sorted(by: { $0.key < $1.key }) {
            let d = NativeModelPackManifest.validPackId(packId) ? try? packDir(packId) : nil
            var missing: [String] = []
            var onDisk: Int64 = 0
            for f in entry["files"]?.array ?? [] {
                guard case .object(let fo) = f, case .string(let rel) = fo["path"] else { continue }
                var isDir: ObjCBool = false
                if let fp = d?.appendingPathComponent(rel),
                   fm.fileExists(atPath: fp.path, isDirectory: &isDir), !isDir.boolValue {
                    // fp.stat().st_size（OSError 静默跳过，L206-208）
                    let size = (try? fm.attributesOfItem(atPath: fp.path)[.size] as? NSNumber)??.int64Value ?? 0
                    onDisk += size
                } else {
                    missing.append(rel)
                }
            }
            var hasPartial = false
            if let pd = try? partialDir(packId), fm.fileExists(atPath: pd.path),
               let enumerator = fm.enumerator(at: pd, includingPropertiesForKeys: nil) {
                for case let u as URL in enumerator where u.lastPathComponent.hasSuffix(".part") {
                    hasPartial = true
                    break
                }
            }
            let man = readManifest(packId)
            // 可选键 context_length：非法/未声明一律归 0（安装入口已拦，这里仅防御）
            var contextLength: Int64 = 0
            if case .int(let cl) = man["context_length"], cl > 0 { contextLength = cl }
            let status = entry["status"]?.string ?? "installed"
            out.append([
                "pack_id": .string(packId),
                "name": .string(man["name"].map(WFText.pyStr).flatMap { $0.isEmpty ? nil : $0 } ?? packId),
                "description": .string(man["description"].map(WFText.pyStr) ?? ""),
                "version": entry["version"] ?? .string(""),
                "task": entry["task"] ?? .string(""),
                "format": entry["format"] ?? .string(""),
                "driver": entry["driver"] ?? .string(""),
                "context_length": .int(contextLength),
                "status": .string(status),
                "enabled": .bool(status == "installed"),
                "installed_at": entry["installed_at"] ?? .string(""),
                "files": entry["files"] ?? .array([]),
                "sha256_ok": entry["sha256_ok"] ?? .bool(false),
                "size_bytes": .int(onDisk),
                "missing_files": .array(missing.map { .string($0) }),
                "has_partial": .bool(hasPartial),
                "dir": .string(d?.path ?? ""),
            ])
        }
        return out
    }

    // MARK: - remove_pack（L245-260）

    /// 卸载：删目录（含 .partial 残留）+ 注册表条目清理。两者都不存在返回 false。
    /// 顺序：先删目录再清注册表——删目录抛错时注册表仍在，前端仍能显示可重试。
    public func removePack(_ packId: String) throws -> Bool {
        var existed = isInstalled(packId)
        guard let d = try? packDir(packId) else { return false }   // ValueError → False
        if FileManager.default.fileExists(atPath: d.path) {
            try FileManager.default.removeItem(at: d)   // rmtree（抛错上透，注册表保留）
            existed = true
        }
        unregisterPack(packId)
        return existed
    }
}
