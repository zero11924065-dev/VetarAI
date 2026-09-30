//
//  NativeDownloadLoggingW4Tests.swift
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

//  验证口径：
//    · AppLogger 注入缝——NativeModelDownloader / NativeRequiredModels /
//      NativeModelPackDownloader / NativeModelScopeInstaller 全部可注入独立
//      logDirectory 实例（不碰全局单例，断言读真日志文件）
//    · 失败路径留痕：HTTP 404 全源失败 → WARN 逐源 + ERROR 收口，含文件名与
//      HTTP 码；成功路径留「下载开始/进度跳/完成（字节+耗时）」
//    · ⛔ 脱敏红线：源 URL 带 token query 时日志只落文件名，token 绝不落盘
//    · NativeRequiredModels：下载开始/自检复核闸/自检不过删目录回 failed/
//      用户取消（.part 保留）全链留痕
//    · NativeModelPackDownloader：成功/失败生命周期落盘
//    · NativeModelScopeInstaller：安装失败 + 半成品清退事件落盘
//

import XCTest
import CryptoKit
@testable import VetarAINative

// MARK: - 本文件专用 URLProtocol stub（只吞 w4stub.local 域）

private final class W4StubURLProtocol: URLProtocol {
    static let lock = NSLock()
    static var handlers: [String: (URLRequest) -> (Int, Data)] = [:]
    /// 挂起源：头 + 首小块即到后停滞（不发完不 finish），供取消测试掐断。
    static var hangURLs: Set<String> = []
    private var pending: DispatchWorkItem?

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        handlers = [:]; hangURLs = []
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "w4stub.local"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock()
        let rule = Self.handlers[url.absoluteString]
        let hang = Self.hangURLs.contains(url.absoluteString)
        Self.lock.unlock()
        let (status, body) = rule?(request) ?? (404, Data())
        let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                   headerFields: ["Content-Length": "\(body.count)"])!
        schedule(0.02) { [weak self] in
            guard let self else { return }
            self.client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            if hang {
                self.schedule(0.3) { [weak self] in
                    guard let self else { return }
                    self.client?.urlProtocol(self, didLoad: body.prefix(64))
                    // 有意不发完、不 finish（停滞现场）
                }
            } else {
                self.schedule(0.3) { [weak self] in self?.deliver(body, from: 0) }
            }
        }
    }

    private func deliver(_ body: Data, from offset: Int) {
        guard offset < body.count else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let end = min(offset + 65536, body.count)
        let piece = Data(body[offset..<end])
        schedule(0.01) { [weak self] in
            guard let self else { return }
            self.client?.urlProtocol(self, didLoad: piece)
            self.deliver(body, from: end)
        }
    }

    private func schedule(_ delay: TimeInterval, _ block: @escaping () -> Void) {
        let work = DispatchWorkItem(block: block)
        pending = work
        DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work)
    }

    override func stopLoading() { pending?.cancel() }
}

// MARK: - 测试本体

@MainActor
final class NativeDownloadLoggingW4Tests: XCTestCase {

    private var tmp: URL!
    private var logDir: URL!
    private var logger: AppLogger!
    private var httpSession: URLSession!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("w4log_\(UUID().uuidString)")
        logDir = tmp.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        logger = AppLogger(logDirectory: logDir)
        W4StubURLProtocol.reset()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [W4StubURLProtocol.self]
        httpSession = URLSession(configuration: cfg)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        W4StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: 日志读取辅助（AppLogger 串行队列异步落盘——轮询等写盘）

    private func readLog() -> String {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: logDir, includingPropertiesForKeys: nil) else { return "" }
        return files.filter { $0.lastPathComponent.hasPrefix("app-") && $0.pathExtension == "log" }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }

    private func waitLog(timeout: Double = 6, _ pred: (String) -> Bool) async -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let s = readLog()
            if pred(s) { return s }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return readLog()
    }

    // MARK: 夹具

    private func shaHex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeSource(_ rel: String, _ content: Data) -> URL {
        let url = tmp.appendingPathComponent("src/\(rel)")
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try! content.write(to: url)
        return url
    }

    private func embedderModel(_ files: [RequiredModelManifest.Model.File])
        -> RequiredModelManifest.Model {
        RequiredModelManifest.Model(
            modelId: "bge-m3-coreml", name: "索引模型", purpose: "测试",
            installKind: "embedder_dir", packId: nil,
            destSubdir: "models/bge-m3-coreml",
            sizeBytes: files.reduce(0) { $0 + $1.sizeBytes }, sizeDisplay: "1 KB",
            restartRequired: false, files: files, packRegistry: nil)
    }

    private func makeRM(models: [RequiredModelManifest.Model],
                        selfCheckFails: Bool = false) throws -> NativeRequiredModels {
        let packsRoot = tmp.appendingPathComponent("packs")
        try FileManager.default.createDirectory(at: packsRoot, withIntermediateDirectories: true)
        let store = NativeModelPackStore(
            configProvider: { [:] },
            dataRootProvider: { [tmp] in tmp! },
            environment: ["VETARAI_MODEL_PACKS_DIR": packsRoot.path])
        let rm = NativeRequiredModels(dataRoot: tmp, packStore: store)
        rm.logger = logger
        rm.selfCheckOverride = { model in
            if selfCheckFails {
                throw RequiredModelsError.selfCheckFailed("假自检不通过（\(model.modelId)）")
            }
        }
        let manifest = RequiredModelManifest(version: 1, models: models)
        let url = tmp.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(manifest).write(to: url)
        try rm.loadManifest(from: url)
        return rm
    }

    private func waitState(_ rm: NativeRequiredModels, _ id: String,
                           timeout: TimeInterval = 10,
                           where pred: (RequiredModelState) -> Bool) async -> RequiredModelState {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let s = rm.state(for: id)
            if pred(s) { return s }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return rm.state(for: id)
    }

    // MARK: ① 脱敏红线：logSafeName 只取文件名

    func testLogSafeNameStripsQueryAndToken() {
        XCTAssertEqual(
            NativeModelDownloader.logSafeName(
                "https://cdn.example.com/models/bge-m3/tokenizer.json?token=SECRET7&sig=abc"),
            "tokenizer.json", "http(s) 源只落文件名，query/token 不落")
        XCTAssertEqual(
            NativeModelDownloader.logSafeName("file:///tmp/x/weights.bin"),
            "weights.bin")
        XCTAssertEqual(
            NativeModelDownloader.logSafeName("⚠️VERIFY-GITHUB-RELEASE-BGE-M3/tokenizer.json"),
            "tokenizer.json", "占位源同样只取末段")
        // 整串无路径分隔的非 URL 形态：截断兜底且不带 query
        let bare = NativeModelDownloader.logSafeName("⚠️VERIFY-SOURCE?token=SECRET7")
        XCTAssertFalse(bare.contains("SECRET7"), "非 URL 形态也要剥掉 query")
        // 错误明细脱敏闸：文案里嵌的完整 URL 剥 query，其余信息保留
        let detail = NativeModelDownloader.logSafeDetail(
            "文件 w.bin 全部源失败 —— https://cdn.example.com/a/w.bin?token=SECRET7：HTTP 404")
        XCTAssertFalse(detail.contains("SECRET7"), "明细里的 query 剥掉：\(detail)")
        XCTAssertTrue(detail.contains("HTTP 404"), "HTTP 码保留：\(detail)")
    }

    // MARK: ② 下载器失败路径：HTTP 404 + token 不落盘

    func testDownloaderHTTPFailureLogsFilenameButNotToken() async throws {
        let url = "https://w4stub.local/bge/weight.bin?token=SECRET7"
        W4StubURLProtocol.handlers[url] = { _ in (404, Data()) }
        let dl = NativeModelDownloader(session: httpSession, logger: logger)
        let spec = RequiredFileSpec(path: "weight.bin", sizeBytes: 100,
                                    sha256: shaHex(Data(repeating: 1, count: 100)),
                                    sources: [url])
        do {
            try await dl.downloadFiles([spec], destDir: tmp.appendingPathComponent("d"),
                                       partDir: tmp.appendingPathComponent("p"))
            XCTFail("404 应失败")
        } catch { /* 预期失败 */ }
        let log = await waitLog { $0.contains("[ERROR]") }
        XCTAssertTrue(log.contains("weight.bin"), "日志含文件名：\n\(log)")
        XCTAssertTrue(log.contains("HTTP 404"), "日志含 HTTP 码：\n\(log)")
        XCTAssertTrue(log.contains("文件全部源失败"), "日志含全源失败收口：\n\(log)")
        XCTAssertFalse(log.contains("SECRET7"), "⛔ token 绝不落盘：\n\(log)")
        XCTAssertFalse(log.contains("token="), "⛔ query 不落盘：\n\(log)")
    }

    // MARK: ③ 下载器成功路径：开始 / 进度跳 / 完成（字节+耗时）

    func testDownloaderSuccessLogsStartMilestoneAndDone() async throws {
        let content = Data(repeating: 0x5A, count: 3000)
        let src = makeSource("bge/tokenizer.json", content)
        let dl = NativeModelDownloader(logger: logger)
        let spec = RequiredFileSpec(path: "tokenizer.json", sizeBytes: Int64(content.count),
                                    sha256: shaHex(content),
                                    sources: ["file://\(src.path)"])
        try await dl.downloadFiles([spec], destDir: tmp.appendingPathComponent("d2"),
                                   partDir: tmp.appendingPathComponent("p2"))
        let log = await waitLog { $0.contains("文件下载完成") }
        XCTAssertTrue(log.contains("下载开始：共 1 个文件"), "批次开始落盘：\n\(log)")
        XCTAssertTrue(log.contains("文件下载开始：tokenizer.json"), "单文件开始落盘：\n\(log)")
        XCTAssertTrue(log.contains("下载进度 100%：tokenizer.json"), "每 10% 一跳（末跳）：\n\(log)")
        XCTAssertTrue(log.contains("文件下载完成：tokenizer.json（3000 字节"),
                      "完成含总字节：\n\(log)")
        XCTAssertTrue(log.contains("耗时"), "完成含耗时：\n\(log)")
        XCTAssertTrue(log.contains("下载批次完成"), "批次完成落盘：\n\(log)")
    }

    // MARK: ④ 停滞看门狗触发与重连次数落盘

    func testStallWatchdogReconnectLogged() async throws {
        let full = Data(repeating: 0x71, count: 100_000)
        let url = "https://w4stub.local/bge/dead.bin"
        W4StubURLProtocol.handlers[url] = { _ in (200, full) }
        W4StubURLProtocol.hangURLs.insert(url)   // 恒停滞
        let oldTimeout = NativeModelDownloader.stallTimeout
        let oldMax = NativeModelDownloader.maxStallRetries
        NativeModelDownloader.stallTimeout = 0.6
        NativeModelDownloader.maxStallRetries = 1
        defer {
            NativeModelDownloader.stallTimeout = oldTimeout
            NativeModelDownloader.maxStallRetries = oldMax
        }
        let dl = NativeModelDownloader(session: httpSession, logger: logger)
        let spec = RequiredFileSpec(path: "dead.bin", sizeBytes: Int64(full.count),
                                    sha256: shaHex(full), sources: [url])
        do {
            try await dl.downloadFiles([spec], destDir: tmp.appendingPathComponent("d3"),
                                       partDir: tmp.appendingPathComponent("p3"))
            XCTFail("恒停滞源应失败")
        } catch { /* 预期失败 */ }
        let log = await waitLog { $0.contains("停滞重连耗尽") }
        XCTAssertTrue(log.contains("停滞看门狗触发：dead.bin.part，Range 重连续传（第 1/1 次"),
                      "看门狗触发与第几次重连落盘：\n\(log)")
        XCTAssertTrue(log.contains("[ERROR]"), "重连耗尽按 ERROR 落盘：\n\(log)")
    }

    // MARK: ⑤ NativeRequiredModels：开始 / 自检复核闸 / 自检不过删目录回 failed

    func testRequiredModelsSelfCheckFailureLogged() async throws {
        let content = Data(repeating: 0x21, count: 800)
        let src = makeSource("bge/tokenizer.json", content)
        let f = RequiredModelManifest.Model.File(
            path: "tokenizer.json", sizeBytes: Int64(content.count),
            sha256: shaHex(content), sources: ["file://\(src.path)"])
        let rm = try makeRM(models: [embedderModel([f])], selfCheckFails: true)
        rm.startDownload("bge-m3-coreml")
        let s = await waitState(rm, "bge-m3-coreml") {
            if case .failed = $0 { return true }; return false
        }
        guard case .failed = s else { return XCTFail("应 failed，实得 \(s)") }
        let log = await waitLog { $0.contains("自检复核仍不过") }
        XCTAssertTrue(log.contains("必备模型下载开始：索引模型（bge-m3-coreml"), "开始落盘：\n\(log)")
        XCTAssertTrue(log.contains("必备模型下载完成，进入自检：bge-m3-coreml"), "自检入口落盘：\n\(log)")
        XCTAssertTrue(log.contains("自检首检未过，1.5s 后复核"), "复核闸 WARN 落盘：\n\(log)")
        XCTAssertTrue(log.contains("必备模型自检复核未过"), "复核结果 ERROR 落盘：\n\(log)")
        XCTAssertTrue(log.contains("必备模型自检复核仍不过，删目录回 failed"), "红线条款落盘：\n\(log)")
    }

    // MARK: ⑥ NativeRequiredModels：用户取消落盘（.part 保留）

    func testRequiredModelsCancelLogged() async throws {
        let full = Data(repeating: 0x66, count: 5000)
        let url = "https://w4stub.local/bge/slow.bin"
        W4StubURLProtocol.handlers[url] = { _ in (200, full) }
        W4StubURLProtocol.hangURLs.insert(url)
        let f = RequiredModelManifest.Model.File(
            path: "slow.bin", sizeBytes: Int64(full.count),
            sha256: shaHex(full), sources: [url])
        let rm = try makeRM(models: [embedderModel([f])])
        rm.startDownload("bge-m3-coreml", session: httpSession)
        XCTAssertTrue(rm.state(for: "bge-m3-coreml").isDownloading)
        try await Task.sleep(nanoseconds: 600_000_000)   // 让请求发出并停滞
        rm.cancelDownload("bge-m3-coreml")
        let s = await waitState(rm, "bge-m3-coreml", timeout: 5) { $0 == .notDownloaded }
        XCTAssertEqual(s, .notDownloaded)
        let log = await waitLog { $0.contains("已取消（.part 保留续传）：bge-m3-coreml") }
        XCTAssertTrue(log.contains("用户取消必备模型下载：bge-m3-coreml"), "取消动作落盘：\n\(log)")
    }

    // MARK: ⑦ NativeModelPackDownloader：成功/失败生命周期落盘

    private func makePackStore() -> NativeModelPackStore {
        NativeModelPackStore(
            configProvider: { [:] },
            dataRootProvider: { [tmp] in tmp! },
            environment: ["VETARAI_MODEL_PACKS_DIR": tmp.appendingPathComponent("packs").path])
    }

    private func packJSON(_ pid: String, path: String, data: Data, source: String,
                          shaOverride: String? = nil) -> [String: JSONValue] {
        [
            "pack_id": .string(pid),
            "name": .string("W4 测试包"),
            "task": .string("chat"),
            "format": .string("gguf"),
            "driver": .string("llamacpp"),
            "version": .string("1.0.0"),
            "size_bytes": .int(Int64(data.count)),
            "files": .array([.object([
                "path": .string(path),
                "size_bytes": .int(Int64(data.count)),
                "sha256": .string(shaOverride ?? shaHex(data)),
                "sources": .array([.string(source)]),
            ])]),
        ]
    }

    func testPackDownloaderSuccessAndFailureLogged() async throws {
        let store = makePackStore()
        let dl = NativeModelPackDownloader(store: store, networkGuard: NativeNetworkGuard())
        dl.logger = logger
        dl.emit = { _, _, _ in }   // 测试不接原生总线

        // 成功链（file:// 本地源）
        let content = Data(repeating: 0x61, count: 1000)
        let src = makeSource("pack/model.gguf", content)
        _ = try await dl.downloadPack(
            packJSON("w4-pack-ok", path: "model.gguf", data: content,
                     source: "file://\(src.path)"))
        var log = await waitLog { $0.contains("模型包下载完成") }
        XCTAssertTrue(log.contains("模型包下载开始：W4 测试包（w4-pack-ok，1 个文件 / 1000 字节）"),
                      "包下载开始落盘：\n\(log)")
        XCTAssertTrue(log.contains("模型包下载完成：w4-pack-ok（1000 字节"), "完成含字节：\n\(log)")

        // 失败链（本地源不存在 → 全源失败）
        _ = try? await dl.downloadPack(
            packJSON("w4-pack-bad", path: "model.gguf", data: content,
                     source: "file:///nonexistent-w4/missing.gguf"))
        log = await waitLog { $0.contains("模型包下载失败：w4-pack-bad") }
        XCTAssertTrue(log.contains("[ERROR]"), "包失败按 ERROR 落盘：\n\(log)")
        XCTAssertTrue(log.contains("本地源不存在"), "失败原因落盘：\n\(log)")
    }

    // MARK: ⑧ NativeModelScopeInstaller：安装失败 + 半成品清退落盘

    func testModelScopeInstallFailureLogsRetract() async throws {
        let store = makePackStore()
        let installer = NativeModelScopeInstaller(store: store)
        installer.logger = logger
        // 下载器同步注入测试 logger（断言不依赖全局单例）
        installer.makeDownloader = { [logger] onProgress in
            NativeModelDownloader(onProgress: onProgress, logger: logger!)
        }
        let ref = ModelScopeRepoRef(org: "w4org", name: "w4model")
        let file = ModelScopeRepoFile(path: "model.gguf", sizeBytes: 100,
                                      sha256: shaHex(Data(repeating: 1, count: 100)), isLFS: false)
        let variant = ModelScopeVariant(id: "model", title: "model",
                                        format: .gguf, files: [file])
        let snapshot = ModelScopeRepoSnapshot(ref: ref, license: "", variants: [variant])
        // 源指向不存在的本地文件 → 下载失败 → 半成品清退分支
        installer.resolveURLForFile = { _, path in "file:///nonexistent-w4/\(path)" }
        do {
            _ = try await installer.install(snapshot: snapshot, variantId: "model")
            XCTFail("不存在源应失败")
        } catch { /* 预期失败 */ }
        let log = await waitLog { $0.contains("魔塔安装失败") }
        XCTAssertTrue(log.contains("魔塔安装开始：w4org/w4model · model"), "安装开始落盘：\n\(log)")
        XCTAssertTrue(log.contains("魔塔安装失败：ms-w4org-w4model-model"), "失败含 pid：\n\(log)")
        XCTAssertTrue(log.contains("半成品清退"), "清退事件落盘：\n\(log)")
    }
}
