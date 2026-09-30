//
//  NativeRequiredModels.swift
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

//  两必备模型（安装包不再内置，首装登录后弹窗按需下载）：
//    · bge-m3-coreml（索引）→ 落 {dataRoot}/models/bge-m3-coreml/，
//      NativeEmbedder 解析链第 3 优先位命中，懒加载下次使用时生效；
//    · sensevoice-small（语音识别）→ 落 packsRoot/sensevoice-small/ +
//      NativeModelPackStore 注册表登记（task=asr，复用 0.4.29 包管理口径）。
//
//  状态机（每模型）：notDownloaded → downloading → verifying → ready
//                   ↘ failed(中文明细) ↗（重试回到 downloading；.part 续传）
//  「完全可用」红线（拍板）：SHA256 逐文件校验过后还要**加载自检**——
//    embedder_dir：NativeEmbedder 真装载 encode 一句；model_pack：ASR session 试建。
//    自检不过 = 带病 → 删目录 + 状态回 failed（不许半残上岗）。
//  热生效：自检过后调 NativeEmbedder.resetForRetry() 清失败记忆化，
//    无需重启（拍板「需要重启才生效」为条件分支——两模型加载点都是懒/按需，
//    正常路径热生效；状态污染等异常才走重启兜底，见首装弹窗流）。
//
//  持久化：{dataRoot}/models/required-models-state.json——下载中断重启后
//    状态恢复为 notDownloaded（.part 在盘上，重新发起即续传），ready/failed 原样。
//
//  0.7.6 收口（业主实测三链）：① 暂停→立即重下换代接管——代际令牌拦旧任务
//    进度/状态/登记收尾回写，新任务先等旧任务落地再碰 .part（防旧任务流缓冲
//    尾块与新写双写交错）；② 自检复核闸——下载落位完成窗内 kernel.embedder
//    懒加载与自检 fresh embedder 可能并发 MLModel.compileModel 同一 mlpackage
//    （编译缓存互斥 → 一方瞬时失败），隔 1.5s 复核一次再判死，不替瞬时故障
//    删 GB 级齐件（红线条款不变）；③ 下载停滞看门狗/206 Content-Range 起点
//    校验见 NativeModelDownloader 头注。
//

import Foundation

// MARK: - 清单模型（Resources/required-models.json）

public struct RequiredModelManifest: Codable, Sendable {
    public struct Model: Codable, Sendable {
        public struct File: Codable, Sendable {
            public let path: String
            public let sizeBytes: Int64
            public let sha256: String
            public let sources: [String]
            enum CodingKeys: String, CodingKey {
                case path, sha256, sources
                case sizeBytes = "size_bytes"
            }
        }
        /// install_kind: embedder_dir（落 models/ 目录）| model_pack（落 packs + 注册表）
        public let modelId: String
        public let name: String
        public let purpose: String
        public let installKind: String
        public let packId: String?
        public let destSubdir: String
        public let sizeBytes: Int64
        public let sizeDisplay: String
        public let restartRequired: Bool
        public let files: [File]
        public let packRegistry: [String: String]?
        enum CodingKeys: String, CodingKey {
            case name, purpose, files
            case modelId = "model_id"
            case installKind = "install_kind"
            case packId = "pack_id"
            case destSubdir = "dest_subdir"
            case sizeBytes = "size_bytes"
            case sizeDisplay = "size_display"
            case restartRequired = "restart_required"
            case packRegistry = "pack_registry"
        }
    }
    public let version: Int
    public let models: [Model]
}

// MARK: - 状态机

public enum RequiredModelState: Equatable, Sendable {
    case notDownloaded
    case downloading(progress: Double, detail: String)
    case verifying
    case ready
    case failed(String)

    public var isReady: Bool { if case .ready = self { return true }; return false }
    public var isDownloading: Bool { if case .downloading = self { return true }; return false }
}

public enum RequiredModelsError: LocalizedError {
    case manifestMissing
    case selfCheckFailed(String)
    public var errorDescription: String? {
        switch self {
        case .manifestMissing: return "必备模型清单缺失（required-models.json 不在包内）"
        case .selfCheckFailed(let m): return "模型自检失败：\(m)"
        }
    }
}

@MainActor
public final class NativeRequiredModels: ObservableObject {

    @Published public private(set) var states: [String: RequiredModelState] = [:]
    @Published public private(set) var manifest: RequiredModelManifest?

    private let dataRoot: URL
    private let packStore: NativeModelPackStore
    private var tasks: [String: Task<Void, Never>] = [:]
    /// 代际令牌（暂停→立即重下的换代闸）：startDownload 每次发起换代；旧任务的
    /// 进度回调/状态回写/登记收尾全部按令牌拦下——防已取消旧任务的收尾冲掉
    /// 新任务登记与状态（0.7.6 实测暂停-重下状态残留收口）。
    private var taskGens: [String: UUID] = [:]

    /// 自检供给缝（生产 = 真装载 CoreML/ORT 链；单测注入假自检免框架依赖）。
    /// 抛错即自检不过——调用侧负责删目录 + 状态回 failed。
    public var selfCheckOverride: (@Sendable (RequiredModelManifest.Model) async throws -> Void)?
    /// 单模型就绪钩子（AppState 接线：embedder_dir 就绪 → kernel.embedder.resetForRetry()
    /// 热生效，清下载前可能留下的装载失败记忆化）。
    public var onModelReady: (@Sendable (String) -> Void)?
    /// 失败明细落盘（0.7.7 W4）：默认全局单例；测试注入独立 logDirectory 实例。
    public var logger: AppLogger = .shared

    private var stateFile: URL {
        dataRoot.appendingPathComponent("models/required-models-state.json")
    }

    public init(dataRoot: URL, packStore: NativeModelPackStore) {
        self.dataRoot = dataRoot
        self.packStore = packStore
    }

    // MARK: - 清单加载（bundle Resources 内嵌）

    public func loadManifest(bundle: Bundle = .main) throws {
        guard let url = bundle.url(forResource: "required-models", withExtension: "json") else {
            throw RequiredModelsError.manifestMissing
        }
        try loadManifest(from: url)
    }

    /// 显式清单路径入口（单测/诊断注入缝；生产走 bundle 内嵌）。
    /// 幂等：重复调用重判盘上齐件（在飞下载任务的状态不回冲）。
    public func loadManifest(from url: URL) throws {
        let data = try Data(contentsOf: url)
        // size_bytes 在 JSON 里是 number，标准解码器直解 Int64，无需自定义策略
        let m = try JSONDecoder().decode(RequiredModelManifest.self, from: data)
        manifest = m
        // 初始状态：盘上已齐（旧包内置/已下载）→ ready；持久化状态恢复；否则 notDownloaded
        var restored = readPersistedStates()
        for model in m.models {
            if states[model.modelId]?.isDownloading == true { continue }
            if modelInstalledOnDisk(model) {
                states[model.modelId] = .ready
            } else if let s = restored.removeValue(forKey: model.modelId), s.isReady {
                // 持久化 ready 但盘上文件没了（用户删了）→ 回退未下载
                states[model.modelId] = .notDownloaded
            } else {
                states[model.modelId] = .notDownloaded
            }
        }
        persistStates()
    }

    // MARK: - 盘上齐件判定

    private func modelInstalledOnDisk(_ model: RequiredModelManifest.Model) -> Bool {
        let fm = FileManager.default
        switch model.installKind {
        case "embedder_dir":
            let dir = dataRoot.appendingPathComponent(model.destSubdir)
            // 齐件 = 清单全部文件存在（尺寸抽查大文件即可，全量哈希在自检阶段）
            return model.files.allSatisfy {
                fm.fileExists(atPath: dir.appendingPathComponent($0.path).path)
            }
        case "model_pack":
            guard let pid = model.packId, let dir = try? packStore.packDir(pid) else { return false }
            return packStore.isInstalled(pid) && model.files.allSatisfy {
                fm.fileExists(atPath: dir.appendingPathComponent($0.path).path)
            }
        default: return false
        }
    }

    // MARK: - 下载（可取消；失败保留 .part 续传；进度实时回写 states）

    /// 发起下载（幂等：同模型在飞则忽略）。session 为测试注入缝（URLProtocol mock /
    /// file:// 源不需要）；生产 nil = 下载器自建会话（读超时 60s 口径见下载器头注）。
    public func startDownload(_ modelId: String, session: URLSession? = nil) {
        guard let model = manifest?.models.first(where: { $0.modelId == modelId }) else { return }
        if let t = tasks[modelId], !t.isCancelled { return }   // 在飞幂等
        // 旧任务已取消未收尾（暂停→立即重下）：换代接管——旧任务的进度/状态/登记
        // 收尾回写全部由代际令牌拦下，不再冲掉新任务；新任务先等旧任务落地再碰
        // .part（防旧任务流缓冲尾块与新写双写交错烂文件）。
        let gen = UUID()
        let predecessor = tasks[modelId]
        taskGens[modelId] = gen
        states[modelId] = .downloading(progress: 0, detail: "准备下载…")
        if predecessor != nil {
            logger.info("必备模型换代接管：\(model.name)（\(modelId)）——旧任务收尾回写由代际令牌拦下")
        }
        logger.info("必备模型下载开始：\(model.name)（\(modelId)，\(model.sizeDisplay)，\(model.files.count) 个文件）")
        let dest = destDir(for: model)
        let part = partDir(for: model)
        let downloader = NativeModelDownloader(session: session, logger: logger) { [weak self] p in
            Task { @MainActor in
                guard let self, self.taskGens[modelId] == gen else { return }
                let pct = p.totalBytes > 0
                    ? min(1, Double(p.receivedBytes) / Double(p.totalBytes)) : 0
                let remaining = Self.fmtRemaining(received: p.receivedBytes,
                                                  total: p.totalBytes,
                                                  bytesPerSecond: p.bytesPerSecond)
                let detail = "\(p.file) · \(Self.fmtSize(p.receivedBytes)) / "
                    + "\(Self.fmtSize(p.totalBytes))（\(Int(pct * 100))%）"
                    + (p.currentSource.isEmpty ? "" : " · \(p.currentSource)")
                    + (p.bytesPerSecond > 0 ? " · \(Self.fmtSpeed(p.bytesPerSecond))" : "")
                    + (remaining.isEmpty ? "" : " · \(remaining)")
                    + (p.note.isEmpty ? "" : " · \(p.note)")
                self.states[modelId] = .downloading(progress: pct, detail: detail)
            }
        }
        let task = Task {
            _ = await predecessor?.value   // 等已取消旧任务收尾落地（.part 单写者）
            let specs = model.files.map {
                RequiredFileSpec(path: $0.path, sizeBytes: $0.sizeBytes,
                                 sha256: $0.sha256.lowercased(), sources: $0.sources)
            }
            do {
                try await downloader.downloadFiles(specs, destDir: dest, partDir: part)
                await MainActor.run {
                    guard self.taskGens[modelId] == gen else { return }
                    self.states[modelId] = .verifying
                    self.logger.info("必备模型下载完成，进入自检：\(modelId)")
                }
                do {
                    try await self.selfCheckedWithRetry(model)
                } catch {
                    // 自检不过 = 带病（「完全可用」红线）——此刻 dest 必为本次新装
                    // （downloadFiles 校验通过才原子落位），删目录+撤登记回 failed，
                    // 不许半残上岗；下载阶段失败不走此分支（dest 从未被污染）。
                    // 已被换代（用户重下中）则不动手——dest/.part 归新任务所有。
                    await MainActor.run {
                        guard self.taskGens[modelId] == gen else { return }
                        self.logger.error("必备模型自检复核仍不过，删目录回 failed：\(modelId)"
                            + " —— \(error.localizedDescription)")
                        if model.installKind == "model_pack", let pid = model.packId {
                            self.packStore.unregisterPack(pid)
                        }
                        try? FileManager.default.removeItem(at: dest)
                    }
                    throw error
                }
                await MainActor.run {
                    guard self.taskGens[modelId] == gen else { return }
                    self.states[modelId] = .ready
                    self.persistStates()
                    self.cleanupPartDir(part)
                    self.onModelReady?(modelId)
                    self.logger.info("必备模型就绪（自检通过）：\(modelId)")
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard self.taskGens[modelId] == gen else { return }
                    self.states[modelId] = .notDownloaded   // .part 保留，下次续传
                    self.persistStates()
                    self.logger.info("必备模型下载已取消（.part 保留续传）：\(modelId)")
                }
            } catch {
                await MainActor.run {
                    guard self.taskGens[modelId] == gen else { return }
                    self.states[modelId] = .failed(error.localizedDescription)
                    self.persistStates()
                    self.logger.error("必备模型下载失败：\(modelId)"
                        + " —— \(NativeModelDownloader.logSafeDetail(error.localizedDescription))")
                }
            }
            await MainActor.run {
                guard self.taskGens[modelId] == gen else { return }
                self.tasks[modelId] = nil
                self.taskGens[modelId] = nil
            }
        }
        tasks[modelId] = task
    }

    public func cancelDownload(_ modelId: String) {
        if tasks[modelId] != nil {
            logger.info("用户取消必备模型下载：\(modelId)")
        }
        tasks[modelId]?.cancel()
    }

    // MARK: - 展示辅助

    /// 有任一模型未就绪（弹窗触发与面板红点判定用）
    public var needsDownload: Bool {
        guard let m = manifest else { return false }
        return m.models.contains { states[$0.modelId]?.isReady != true }
    }

    public func state(for modelId: String) -> RequiredModelState {
        states[modelId] ?? .notDownloaded
    }

    static func fmtSize(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1024 { return String(format: "%.2f GB", mb / 1024) }
        return String(format: "%.0f MB", mb)
    }

    /// 速率格式化（0.7.4 W2 下载详情行）：≥1MB/s → "%.1f MB/s"；否则 "%.0f KB/s"。
    static func fmtSpeed(_ bps: Double) -> String {
        if bps >= 1_048_576 { return String(format: "%.1f MB/s", bps / 1_048_576) }
        return String(format: "%.0f KB/s", bps / 1024)
    }

    /// 预计剩余时间（0.7.7 生产验收批，DBG-188：静态「约 3 分钟」与冷源实测 65 分钟严重偏离——
    /// 改按实测速率动态估算，随速率滚动窗随行更新）。速率未知（≤0）或已下完 → 空串（不编造）；
    /// <60s → "预计剩余约 N 秒"；<60min → "预计剩余约 N 分钟"；否则 "预计剩余约 H 小时 M 分钟"
    /// （小时档带分钟零头——61 分钟若只显「约 2 小时」粗粒度同样失真）。
    static func fmtRemaining(received: Int64, total: Int64, bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0, total > received, received >= 0 else { return "" }
        let sec = Double(total - received) / bytesPerSecond
        if sec < 60 { return "预计剩余约 \(Int(sec.rounded(.up))) 秒" }
        let min = sec / 60
        if min < 60 { return "预计剩余约 \(Int(min.rounded(.up))) 分钟" }
        var h = Int(min / 60)
        var m = Int((min - Double(h) * 60).rounded(.up))
        if m == 60 { h += 1; m = 0 }   // 59.6min 零头进位：1 小时 60 分钟 → 2 小时
        return m == 0 ? "预计剩余约 \(h) 小时" : "预计剩余约 \(h) 小时 \(m) 分钟"
    }

    // MARK: - 目录口径（dest/partial 分家，续传现场在 partial）

    private func destDir(for model: RequiredModelManifest.Model) -> URL {
        switch model.installKind {
        case "model_pack":
            let pid = model.packId ?? model.modelId
            return (try? packStore.packDir(pid)) ?? dataRoot.appendingPathComponent(model.destSubdir)
        default:
            return dataRoot.appendingPathComponent(model.destSubdir)
        }
    }

    private func partDir(for model: RequiredModelManifest.Model) -> URL {
        if model.installKind == "model_pack", let pid = model.packId,
           let pd = try? packStore.partialDir(pid) { return pd }
        return dataRoot.appendingPathComponent("models/.partial/\(model.modelId)")
    }

    private func cleanupPartDir(_ dir: URL) {
        // 空暂存目录顺手清；有残留（别的中断文件）保留
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - 自检（「完全可用」红线：纯检查，清理由调用侧 startDownload 兜底）+ 登记

    private func selfCheck(_ model: RequiredModelManifest.Model) async throws {
        if let override = selfCheckOverride { return try await override(model) }
        switch model.installKind {
        case "embedder_dir":
            // 真装载 encode 一句（bge-m3 CoreML 编译 82–200ms 口径）
            let embedder = NativeEmbedder(dataRoot: dataRoot)
            let vec = await Task.detached(priority: .utility) {
                embedder.encodeOneOrNil("模型自检")
            }.value
            guard vec != nil else {
                throw RequiredModelsError.selfCheckFailed("索引模型装载/编码未通过（已删除，请重新下载）")
            }
        case "model_pack":
            guard let pid = model.packId else { return }
            // 登记注册表（NativeModelPackStore 口径：status/installed_at/files/sha256_ok）
            var pack: [String: JSONValue] = [
                "files": .array(model.files.map { .object([
                    "path": .string($0.path),
                    "size_bytes": .int($0.sizeBytes),
                    "sha256": .string($0.sha256)]) })
            ]
            if let reg = model.packRegistry {
                pack["task"] = .string(reg["task"] ?? "")
                pack["format"] = .string(reg["format"] ?? "")
                pack["driver"] = .string(reg["driver"] ?? "")
                pack["version"] = .string(reg["version"] ?? "")
            }
            try packStore.registerPack(pid, pack: pack)
            // ASR 真装载自检（「完全可用」红线）：注册表解析 → 文件三元组 → ORT 工厂 → 真建 session。
            // 任一环节不过 = 带病 → 调用侧删登记+目录，状态回 failed。
            let ok = await Task.detached(priority: .utility) { () -> Bool in
                do {
                    let driver = NativeAsrDriver(
                        store: self.packStore,
                        dataRootProvider: { self.dataRoot },
                        bundleResourceURL: Bundle.main.resourceURL)
                    let resolvedPid = try driver.resolveAsrPack(pid)
                    let files = try driver.packFiles(resolvedPid)
                    let factory = try driver.sessionFactoryProvider()
                    _ = try factory.makeSession(onnxPath: files.onnx)
                    return true
                } catch { return false }
            }.value
            guard ok else {
                throw RequiredModelsError.selfCheckFailed("语音模型装载未通过（已删除，请重新下载）")
            }
        default:
            break
        }
    }

    /// 自检复核闸（0.7.6 实测间歇「安装失败」收口）：下载落位完成的同一窗口内，
    /// kernel.embedder 懒加载（用户检索触发）与自检 fresh embedder 可能并发
    /// MLModel.compileModel 同一 mlpackage（编译缓存互斥 → 一方瞬时失败）。
    /// 瞬时失败不值得按红线删 GB 级齐件——隔 1.5s 复核一次；仍不过才抛错走
    /// 红线条款（调用侧删目录回 failed），红线本身不变。
    private func selfCheckedWithRetry(_ model: RequiredModelManifest.Model) async throws {
        do {
            try await selfCheck(model)
        } catch {
            logger.warn("必备模型自检首检未过，1.5s 后复核：\(model.modelId)"
                + " —— \(error.localizedDescription)")
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            do {
                try await selfCheck(model)
                logger.info("必备模型自检复核通过：\(model.modelId)")
            } catch {
                logger.error("必备模型自检复核未过：\(model.modelId)"
                    + " —— \(error.localizedDescription)")
                throw error
            }
        }
    }

    // MARK: - 持久化

    private func persistStates() {
        var obj: [String: String] = [:]
        for (k, v) in states {
            switch v {
            case .ready: obj[k] = "ready"
            case .failed(let m): obj[k] = "failed:\(m)"
            default: obj[k] = "notDownloaded"   // downloading/verifying 重启后回未下载（.part 续传）
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: obj) {
            try? FileManager.default.createDirectory(
                at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: stateFile, options: .atomic)
        }
    }

    private func readPersistedStates() -> [String: RequiredModelState] {
        guard let data = try? Data(contentsOf: stateFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return obj.mapValues { s in
            if s == "ready" { return .ready }
            if s.hasPrefix("failed:") { return .failed(String(s.dropFirst(7))) }
            return .notDownloaded
        }
    }
}
