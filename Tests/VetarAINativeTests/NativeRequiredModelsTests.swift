//
//  NativeRequiredModelsTests.swift
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

//  夹具口径：全部小文件假模型（不碰真 1.1G）；selfCheckOverride 假自检免
//  CoreML/ORT 依赖；HTTP 路径经 URLProtocol 脚本化 stub（stub.local 域），
//  覆盖 Range 三态（206 追加 / 200 覆盖 / 416 删重下一次）与取消挂起。
//
//  覆盖：
//    · 清单解析与初始状态（空盘 → notDownloaded；state 落盘）
//    · 盘上齐件直判 ready（embedder_dir 齐件 / 持久化 ready 但文件被删回退）
//    · file:// 源下载成功链（落位+onModelReady+state 持久化）
//    · model_pack 落 packs 根 + .partial 清理
//    · SHA256 不符剔除换源（双源 failover / 单源 failed 明细）
//    · 占位源（⚠️VERIFY 非 http/file 开头）跳过记明细
//    · HTTP 续传三态：206 追加（Range 头录证）/ 200 覆盖 / 416 删重下
//    · 取消保留 .part + 状态回 notDownloaded（URLError.cancelled 归一化）
//    · 自检不过删目录回 failed（「完全可用」红线）
//

import XCTest
@testable import VetarAINative

// MARK: - URLProtocol 脚本化 stub（仅吞 stub.local 域）

private final class StubURLProtocol: URLProtocol {
    static let lock = NSLock()
    static var handlers: [String: (URLRequest) -> (Int, Data)] = [:]
    static var ranges: [String?] = []
    static var hangURLs: Set<String> = []
    /// 0.7.6 收口测试缝：一次性挂起源——首次连接停滞（头+首块即到后不发完），
    /// 命中即出集（看门狗重连/重试的后续请求走 handlers 正常投递）。
    static var hangOnceURLs: Set<String> = []
    /// 0.7.6 收口测试缝：按 URL 追加响应头（Content-Range 录证用）。
    static var extraHeaders: [String: [String: String]] = [:]
    /// Bug7 收口测试缝：按 URL 记「再以 -1005 连接丢失掐断 N 次」——头+首块
    /// （1000 字节）即到后 didFailWithError(.networkConnectionLost)，贴业主实测
    /// （app-20260928.log：高速流 3s 后掐断）；次数耗尽后走 handlers 正常投递。
    static var connLostPlan: [String: Int] = [:]
    private var pending: DispatchWorkItem?

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        handlers = [:]; ranges = []; hangURLs = []; hangOnceURLs = []; extraHeaders = [:]
        connLostPlan = [:]
    }
    static func recordedRanges() -> [String?] {
        lock.lock(); defer { lock.unlock() }; return ranges
    }
    /// Range 感知响应：bytes=N- → N≥全长 416 / 否则 206 尾段；无 Range → 200 全量
    static func rangeAware(_ full: Data, status416: Bool = true) -> (URLRequest) -> (Int, Data) {
        { req in
            guard let range = req.value(forHTTPHeaderField: "Range"),
                  range.hasPrefix("bytes="), range.hasSuffix("-"),
                  let n = Int64(range.dropFirst(6).dropLast()), n > 0 else {
                return (200, full)
            }
            if n >= full.count { return status416 ? (416, Data()) : (200, full) }
            return (206, full.subdata(in: Int(n)..<full.count))
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "stub.local"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock()
        Self.ranges.append(request.value(forHTTPHeaderField: "Range"))
        let rule = Self.handlers[url.absoluteString]
        var hang = Self.hangURLs.contains(url.absoluteString)
        if Self.hangOnceURLs.contains(url.absoluteString) {
            Self.hangOnceURLs.remove(url.absoluteString)
            hang = true
        }
        // Bug7 剧本消费（与 hangOnceURLs 一次性语义对齐——命中即递减，耗尽后
        // 后续请求走 handlers 正常投递）：本次是否以 -1005 掐断
        var connLost = false
        if let n = Self.connLostPlan[url.absoluteString], n > 0 {
            Self.connLostPlan[url.absoluteString] = n - 1
            connLost = true
        }
        let extra = Self.extraHeaders[url.absoluteString] ?? [:]
        Self.lock.unlock()
        let (status, body) = rule?(request) ?? (404, Data())
        var headerFields = extra
        headerFields["Content-Length"] = "\(body.count)"
        let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                   headerFields: headerFields)!
        // 全异步投递（头 20ms 后、体 64KB 分块各 10ms 间隔，首块再等 0.3s）：
        // 探针实证 AsyncBytes 不缓冲「迭代器挂上前到达」的数据（竞态整段丢失），
        // 放慢投递贴真网络时序；挂起源（hang）头+首块即到后停滞，供取消测试掐断。
        schedule(0.02) { [weak self] in
            guard let self else { return }
            self.client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            if connLost {
                // Bug7 剧本：头+首块（1000 字节）即到后以 -1005 掐断（贴业主实测：
                // 高速流中连接被链路侧掐断）。有意不 finish——didFailWithError 收口。
                self.schedule(0.3) { [weak self] in
                    guard let self else { return }
                    self.client?.urlProtocol(self, didLoad: body.prefix(1000))
                    self.schedule(0.2) { [weak self] in
                        guard let self else { return }
                        self.client?.urlProtocol(self,
                            didFailWithError: URLError(.networkConnectionLost))
                    }
                }
            } else if hang {
                // 挂起源：头 + 首块即到（bytes(for:) 需首块才返回，mock 口径），
                // 之后不再投递——模拟停滞连接，供取消测试掐断
                self.schedule(0.3) { [weak self] in
                    guard let self else { return }
                    self.client?.urlProtocol(self, didLoad: body.prefix(64))
                    // 有意不发完、不 finish（停滞现场）
                }
            } else {
                // ⚠️ AsyncBytes 不缓冲「迭代器挂上前到达」的数据（探针实证：体早于
                // 消费方就位 = 整段静默丢失）——首块延迟 0.3s 等迭代器就位；
                // 真网络源无此问题（响应到达前迭代早已开始），仅 mock 需要
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
final class NativeRequiredModelsTests: XCTestCase {

    private var tmp: URL!
    private var packsRoot: URL!
    private var store: NativeModelPackStore!
    private var httpSession: URLSession!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("reqmodels_\(UUID().uuidString)")
        packsRoot = tmp.appendingPathComponent("packs")
        try FileManager.default.createDirectory(at: packsRoot, withIntermediateDirectories: true)
        store = NativeModelPackStore(
            configProvider: { [:] },
            dataRootProvider: { [tmp] in tmp! },
            environment: ["VETARAI_MODEL_PACKS_DIR": self.packsRoot.path])
        StubURLProtocol.reset()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        httpSession = URLSession(configuration: cfg)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: 夹具

    /// 写源文件并回 SHA256（小文件假模型）
    @discardableResult
    private func makeSource(_ rel: String, _ content: Data) -> (url: URL, sha: String) {
        let url = tmp.appendingPathComponent("src/\(rel)")
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try! content.write(to: url)
        return (url, try! NativeModelDownloader.sha256FileSync(url))
    }

    /// 造清单并喂给被测实例（selfCheckOverride 默认放行）
    private func makeRM(models: [RequiredModelManifest.Model],
                        selfCheckFails: Bool = false) throws -> NativeRequiredModels {
        let rm = NativeRequiredModels(dataRoot: tmp, packStore: store)
        rm.selfCheckOverride = { model in
            if selfCheckFails {
                throw RequiredModelsError.selfCheckFailed("假自检不通过（\(model.modelId)）")
            }
        }
        let manifest = RequiredModelManifest(version: 1, models: models)
        let data = try JSONEncoder().encode(manifest)
        let url = tmp.appendingPathComponent("manifest.json")
        try data.write(to: url)
        try rm.loadManifest(from: url)
        return rm
    }

    private func embedderModel(files: [RequiredModelManifest.Model.File]) -> RequiredModelManifest.Model {
        RequiredModelManifest.Model(
            modelId: "bge-m3-coreml", name: "索引模型", purpose: "测试",
            installKind: "embedder_dir", packId: nil,
            destSubdir: "models/bge-m3-coreml",
            sizeBytes: files.reduce(0) { $0 + $1.sizeBytes }, sizeDisplay: "1 KB",
            restartRequired: false, files: files, packRegistry: nil)
    }

    private func packModel(files: [RequiredModelManifest.Model.File]) -> RequiredModelManifest.Model {
        RequiredModelManifest.Model(
            modelId: "sensevoice-small", name: "语音模型", purpose: "测试",
            installKind: "model_pack", packId: "sensevoice-small",
            destSubdir: "packs/sensevoice-small",
            sizeBytes: files.reduce(0) { $0 + $1.sizeBytes }, sizeDisplay: "1 KB",
            restartRequired: false, files: files,
            packRegistry: ["task": "asr", "format": "onnx",
                           "driver": "onnxruntime", "version": "1.0.0"])
    }

    private func fileEntry(_ rel: String, _ content: Data,
                           sources: [String]) -> RequiredModelManifest.Model.File {
        let data = content
        let sha = data.sha256Hex()
        return RequiredModelManifest.Model.File(
            path: rel, sizeBytes: Int64(data.count), sha256: sha, sources: sources)
    }

    /// 状态轮询（下载任务异步推进；至多 timeout 秒）
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

    private func persistedStates() -> [String: String] {
        let url = tmp.appendingPathComponent("models/required-models-state.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return obj
    }

    // MARK: ① 清单解析与初始状态

    func testManifestParsesAndInitialStates() throws {
        let f = fileEntry("tokenizer.json", Data("分词器".utf8), sources: ["file:///dev/null"])
        let rm = try makeRM(models: [embedderModel(files: [f]), packModel(files: [f])])
        XCTAssertEqual(rm.manifest?.models.count, 2)
        XCTAssertEqual(rm.state(for: "bge-m3-coreml"), .notDownloaded, "空盘 → 未下载")
        XCTAssertEqual(rm.state(for: "sensevoice-small"), .notDownloaded)
        XCTAssertTrue(rm.needsDownload)
        // loadManifest 落持久化（中断恢复的数据基）
        XCTAssertEqual(persistedStates()["bge-m3-coreml"], "notDownloaded")
    }

    // MARK: ② 盘上齐件直判 ready / 持久化 ready 但文件被删 → 回退

    func testInstalledOnDiskMarksReadyWithoutDownload() throws {
        let content = Data("分词器内容".utf8)
        let f = fileEntry("tokenizer.json", content, sources: ["file:///dev/null"])
        let model = embedderModel(files: [f])
        // 先落盘齐件再加载清单（模拟旧包内置/已下载）
        let dir = tmp.appendingPathComponent("models/bge-m3-coreml")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try content.write(to: dir.appendingPathComponent("tokenizer.json"))
        let rm = try makeRM(models: [model])
        XCTAssertEqual(rm.state(for: "bge-m3-coreml"), .ready, "盘上齐件 → ready（免下载）")
        XCTAssertFalse(rm.needsDownload)
    }

    func testPersistedReadyButFilesDeletedFallsBack() throws {
        let f = fileEntry("tokenizer.json", Data("x".utf8), sources: ["file:///dev/null"])
        // 手写持久化 ready，盘上无文件 → 回退未下载（用户删了文件的场景）
        let stateDir = tmp.appendingPathComponent("models")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try "{\"bge-m3-coreml\":\"ready\"}".write(to: stateDir.appendingPathComponent("required-models-state.json"),
                                                 atomically: true, encoding: .utf8)
        let rm = try makeRM(models: [embedderModel(files: [f])])
        XCTAssertEqual(rm.state(for: "bge-m3-coreml"), .notDownloaded,
                       "持久化 ready 但盘上文件没了 → 回退未下载")
    }

    // MARK: ③ file:// 源成功链（落位 + 钩子 + 持久化 + 跨实例恢复）

    func testFileSourceDownloadSuccess() async throws {
        let content = Data(repeating: 0x5A, count: 3000)
        let src = makeSource("bge/tokenizer.json", content)
        let f = fileEntry("tokenizer.json", content, sources: ["file://\(src.url.path)"])
        let rm = try makeRM(models: [embedderModel(files: [f])])
        final class HookBox: @unchecked Sendable { var ids: [String] = [] }
        let hook = HookBox()
        rm.onModelReady = { hook.ids.append($0) }

        rm.startDownload("bge-m3-coreml")
        let s = await waitState(rm, "bge-m3-coreml") { $0.isReady || !$0.isDownloading && $0 != .notDownloaded }
        XCTAssertEqual(s, .ready)
        // 落位到解析链第 3 优先位（{dataRoot}/models/bge-m3-coreml/）
        let dest = tmp.appendingPathComponent("models/bge-m3-coreml/tokenizer.json")
        XCTAssertEqual(try? Data(contentsOf: dest), content, "落位内容与源一致")
        XCTAssertEqual(hook.ids, ["bge-m3-coreml"], "onModelReady 触发（AppState 接 embedder 热生效）")
        XCTAssertEqual(persistedStates()["bge-m3-coreml"], "ready")
        // 跨实例恢复：新实例 loadManifest → 盘上齐件直判 ready
        let rm2 = try makeRM(models: [embedderModel(files: [f])])
        XCTAssertEqual(rm2.state(for: "bge-m3-coreml"), .ready)
    }

    // MARK: ④ model_pack 落 packs 根 + 暂存清理

    func testModelPackInstallsUnderPackRoot() async throws {
        let content = Data(repeating: 0x11, count: 1500)
        let src = makeSource("sv/model_quant.onnx", content)
        let f = fileEntry("model_quant.onnx", content, sources: ["file://\(src.url.path)"])
        let rm = try makeRM(models: [packModel(files: [f])])
        rm.startDownload("sensevoice-small")
        let s = await waitState(rm, "sensevoice-small") { $0.isReady }
        XCTAssertEqual(s, .ready)
        XCTAssertEqual(try? Data(contentsOf: packsRoot.appendingPathComponent("sensevoice-small/model_quant.onnx")),
                       content, "落 packs 根（NativeModelPackStore 口径）")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: packsRoot.appendingPathComponent("sensevoice-small/.partial/model_quant.onnx.part").path),
            "成功后 .partial 清理")
    }

    // MARK: ⑤ SHA256 不符剔除换源

    func testShaMismatchFallsToNextSource() async throws {
        let good = Data(repeating: 0x42, count: 2000)
        let bad = Data(repeating: 0x24, count: 2000)
        let badSrc = makeSource("bad.bin", bad)
        let goodSrc = makeSource("good.bin", good)
        let f = fileEntry("weights.bin", good,
                          sources: ["file://\(badSrc.url.path)", "file://\(goodSrc.url.path)"])
        let rm = try makeRM(models: [embedderModel(files: [f])])
        rm.startDownload("bge-m3-coreml")
        let s = await waitState(rm, "bge-m3-coreml") { $0.isReady }
        XCTAssertEqual(s, .ready, "第一源哈希不符 → 剔除换第二源成功")
        XCTAssertEqual(try? Data(contentsOf: tmp.appendingPathComponent(
            "models/bge-m3-coreml/weights.bin")), good)
    }

    func testShaMismatchSingleSourceFails() async throws {
        let good = Data(repeating: 0x42, count: 1000)
        let bad = makeSource("bad.bin", Data(repeating: 0x99, count: 1000))
        let f = fileEntry("weights.bin", good, sources: ["file://\(bad.url.path)"])
        let rm = try makeRM(models: [embedderModel(files: [f])])
        rm.startDownload("bge-m3-coreml")
        let s = await waitState(rm, "bge-m3-coreml") {
            if case .failed = $0 { return true }; return false
        }
        guard case .failed(let msg) = s else { return XCTFail("应 failed，实得 \(s)") }
        XCTAssertTrue(msg.contains("SHA256 不符"), "明细含哈希不符：\(msg)")
        XCTAssertEqual(persistedStates()["bge-m3-coreml"]?.hasPrefix("failed:"), true)
    }

    // MARK: ⑥ 占位源跳过记明细

    func testPlaceholderSourceSkipped() async throws {
        let f = fileEntry("tokenizer.json", Data("x".utf8),
                          sources: ["⚠️VERIFY-GITHUB-RELEASE-BGE-M3/tokenizer.json"])
        let rm = try makeRM(models: [embedderModel(files: [f])])
        rm.startDownload("bge-m3-coreml")
        let s = await waitState(rm, "bge-m3-coreml") {
            if case .failed = $0 { return true }; return false
        }
        guard case .failed(let msg) = s else { return XCTFail("应 failed，实得 \(s)") }
        XCTAssertTrue(msg.contains("占位源未配置"), "占位源跳过记明细：\(msg)")
    }

    // MARK: ⑦ HTTP Range 三态（URLProtocol stub 录证）

    func testHTTPResume206Appends() async throws {
        let full = Data((0..<4096).map { UInt8($0 % 251) })
        let url = "https://stub.local/bge/weight.bin"
        StubURLProtocol.handlers[url] = StubURLProtocol.rangeAware(full)
        let f = fileEntry("weight.bin", full, sources: [url])
        let rm = try makeRM(models: [embedderModel(files: [f])])
        // 预置半截 .part（上次中断现场）
        let partDir = tmp.appendingPathComponent("models/.partial/bge-m3-coreml")
        try FileManager.default.createDirectory(at: partDir, withIntermediateDirectories: true)
        try full.prefix(1000).write(to: partDir.appendingPathComponent("weight.bin.part"))

        rm.startDownload("bge-m3-coreml", session: httpSession)
        let s = await waitState(rm, "bge-m3-coreml") { $0.isReady }
        XCTAssertEqual(s, .ready)
        XCTAssertEqual(StubURLProtocol.recordedRanges(), ["bytes=1000-"],
                       "带 Range 续传（半截 1000 字节）")
        XCTAssertEqual(try? Data(contentsOf: tmp.appendingPathComponent(
            "models/bge-m3-coreml/weight.bin")), full, "206 追加后全文正确（SHA256 过）")
    }

    func testHTTP200OverwriteRestart() async throws {
        let full = Data(repeating: 0x77, count: 2048)
        let url = "https://stub.local/bge/weight.bin"
        StubURLProtocol.handlers[url] = { _ in (200, full) }   // 不理会 Range 的源
        let f = fileEntry("weight.bin", full, sources: [url])
        let rm = try makeRM(models: [embedderModel(files: [f])])
        let partDir = tmp.appendingPathComponent("models/.partial/bge-m3-coreml")
        try FileManager.default.createDirectory(at: partDir, withIntermediateDirectories: true)
        try Data(repeating: 0x00, count: 500).write(to: partDir.appendingPathComponent("weight.bin.part"))

        rm.startDownload("bge-m3-coreml", session: httpSession)
        let s = await waitState(rm, "bge-m3-coreml") { $0.isReady }
        XCTAssertEqual(s, .ready)
        XCTAssertEqual(try? Data(contentsOf: tmp.appendingPathComponent(
            "models/bge-m3-coreml/weight.bin")), full, "200 覆盖重下（半截作废）")
    }

    func testHTTP416DeletesPartAndRedownloads() async throws {
        let full = Data(repeating: 0x33, count: 1024)
        let url = "https://stub.local/bge/weight.bin"
        // stub 口径：带 Range → 恒 416（模拟服务端不认断点）；无 Range → 200 全量
        StubURLProtocol.handlers[url] = { req in
            if req.value(forHTTPHeaderField: "Range") != nil { return (416, Data()) }
            return (200, full)
        }
        let f = fileEntry("weight.bin", full, sources: [url])
        let rm = try makeRM(models: [embedderModel(files: [f])])
        // 预置半截 .part（服务端视角已失效的断点现场）
        try full.prefix(300).write(to: {
            let d = tmp.appendingPathComponent("models/.partial/bge-m3-coreml")
            try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            return d.appendingPathComponent("weight.bin.part")
        }())

        rm.startDownload("bge-m3-coreml", session: httpSession)
        let s = await waitState(rm, "bge-m3-coreml") { $0.isReady }
        XCTAssertEqual(s, .ready, "416 → 删半截从头 → 成功")
        XCTAssertEqual(StubURLProtocol.recordedRanges(), ["bytes=300-", nil],
                       "先带 Range 被 416，删后无 Range 重下（只一次）")
        XCTAssertEqual(try? Data(contentsOf: tmp.appendingPathComponent(
            "models/bge-m3-coreml/weight.bin")), full)
    }

    // MARK: ⑧ 取消保留 .part + 状态回 notDownloaded

    func testCancelKeepsPartAndRevertsState() async throws {
        let full = Data(repeating: 0x66, count: 5000)
        let url = "https://stub.local/bge/slow.bin"
        StubURLProtocol.handlers[url] = StubURLProtocol.rangeAware(full)
        StubURLProtocol.hangURLs.insert(url)   // 头+首块即到后停滞
        let f = fileEntry("slow.bin", full, sources: [url])
        let rm = try makeRM(models: [embedderModel(files: [f])])
        // 预置上次中断的半截 .part（500B）——取消语义要保的就是这份续传现场；
        // 预置使断言不依赖 mock 停滞连接下 bytes(for:) 的返回时机
        let partURL = tmp.appendingPathComponent("models/.partial/bge-m3-coreml/slow.bin.part")
        try FileManager.default.createDirectory(at: partURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try full.prefix(500).write(to: partURL)

        rm.startDownload("bge-m3-coreml", session: httpSession)
        XCTAssertTrue(rm.state(for: "bge-m3-coreml").isDownloading)
        try await Task.sleep(nanoseconds: 600_000_000)   // 让请求发出并停滞
        rm.cancelDownload("bge-m3-coreml")
        let s = await waitState(rm, "bge-m3-coreml", timeout: 5) { $0 == .notDownloaded }
        XCTAssertEqual(s, .notDownloaded,
                       "取消 → 回 notDownloaded（URLError.cancelled 归一化，不误判 failed）")
        XCTAssertTrue(FileManager.default.fileExists(atPath: partURL.path),
                      ".part 现场保留（下次续传）")
        XCTAssertEqual((try? Data(contentsOf: partURL))?.count, 500,
                       "取消不清不毁半截（保持 500B 现场）")
        XCTAssertEqual(persistedStates()["bge-m3-coreml"], "notDownloaded")
    }

    // MARK: ⑨ 自检不过删目录回 failed（「完全可用」红线）

    func testSelfCheckFailureDeletesDestAndFails() async throws {
        let content = Data(repeating: 0x21, count: 800)
        let src = makeSource("bge/tokenizer.json", content)
        let f = fileEntry("tokenizer.json", content, sources: ["file://\(src.url.path)"])
        let rm = try makeRM(models: [embedderModel(files: [f])], selfCheckFails: true)
        rm.startDownload("bge-m3-coreml")
        let s = await waitState(rm, "bge-m3-coreml") {
            if case .failed = $0 { return true }; return false
        }
        guard case .failed(let msg) = s else { return XCTFail("应 failed，实得 \(s)") }
        XCTAssertTrue(msg.contains("自检失败"), "明细：\(msg)")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tmp.appendingPathComponent("models/bge-m3-coreml/tokenizer.json").path),
            "自检不过 → 删目录（不许半残上岗）")
    }
}

// MARK: - Data SHA256 便捷（夹具内联；生产口径 = sha256FileSync 流式）

private extension Data {
    func sha256Hex() -> String {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sha_\(UUID().uuidString)")
        try! write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        return try! NativeModelDownloader.sha256FileSync(tmp)
    }
}


// MARK: - 0.7.4 W2 下载器分块桥 + 速率显示

extension NativeRequiredModelsTests {

    /// 进度快照捕获盒（onProgress 跨隔离域回调，@unchecked Sendable 锁保护）。
    private final class ProgressBox: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [DownloadProgress] = []
        func append(_ p: DownloadProgress) { lock.lock(); items.append(p); lock.unlock() }
        var snapshot: [DownloadProgress] { lock.lock(); defer { lock.unlock() }; return items }
    }

    /// W2①：分块写盘正确性——700KB HTTP body（stub 64KB 分块投递）经新桥下载，
    /// 落位文件与源逐字节一致（downloadFiles 内置 SHA256 校验通过本身即证明完整链）。
    func testChunkedDownloadWritesExactBytes() async throws {
        let body = Data((0..<700 * 1024).map { UInt8($0 % 251) })
        let url = "http://stub.local/big.bin"
        StubURLProtocol.handlers[url] = { _ in (200, body) }
        let dl = NativeModelDownloader(session: httpSession)
        let spec = RequiredFileSpec(path: "big.bin", sizeBytes: Int64(body.count),
                                    sha256: body.sha256Hex(), sources: [url])
        let dest = tmp.appendingPathComponent("dest")
        let part = tmp.appendingPathComponent("part")
        try await dl.downloadFiles([spec], destDir: dest, partDir: part)
        let got = try Data(contentsOf: dest.appendingPathComponent("big.bin"))
        XCTAssertEqual(got, body, "700KB 分块下载落位逐字节一致")
    }

    /// W2②：速率上屏——下载过程中至少一个进度快照 bytesPerSecond > 0。
    func testChunkedDownloadReportsSpeed() async throws {
        let body = Data((0..<700 * 1024).map { UInt8($0 % 251) })
        let url = "http://stub.local/speed.bin"
        StubURLProtocol.handlers[url] = { _ in (200, body) }
        let box = ProgressBox()
        let dl = NativeModelDownloader(session: httpSession) { p in box.append(p) }
        let spec = RequiredFileSpec(path: "speed.bin", sizeBytes: Int64(body.count),
                                    sha256: body.sha256Hex(), sources: [url])
        try await dl.downloadFiles([spec], destDir: tmp.appendingPathComponent("d2"),
                                   partDir: tmp.appendingPathComponent("p2"))
        XCTAssertTrue(box.snapshot.contains { $0.bytesPerSecond > 0 },
                      "进度快照序列中应出现 bytesPerSecond > 0")
    }

    /// W2③：displayRate 滚动窗纯函数——空窗 0；超窗样本剔除；span 下限 0.5s。
    func testDisplayRateWindow() {
        let now = Date()
        var empty: [(Date, Int64)] = []
        XCTAssertEqual(NativeModelDownloader.displayRate(samples: &empty, now: now), 0)

        var samples: [(Date, Int64)] = [
            (now.addingTimeInterval(-4), 1000),   // 超窗（默认 3s）→ 剔除
            (now.addingTimeInterval(-1), 2000),
            (now, 3000),
        ]
        let rate = NativeModelDownloader.displayRate(samples: &samples, now: now)
        XCTAssertEqual(samples.count, 2, "超窗样本已剔除")
        XCTAssertEqual(rate, 5000, accuracy: 1, "窗内均速 = 5000B/1s")

        var one: [(Date, Int64)] = [(now, 1024)]
        let spike = NativeModelDownloader.displayRate(samples: &one, now: now)
        XCTAssertEqual(spike, 2048, accuracy: 1, "span 下限 0.5s 防首块尖刺")
    }

    /// W2④：fmtSpeed 格式——≥1MB/s 一位小数 MB/s；否则整数 KB/s。
    func testFmtSpeed() {
        XCTAssertEqual(NativeRequiredModels.fmtSpeed(2 * 1_048_576), "2.0 MB/s")
        XCTAssertEqual(NativeRequiredModels.fmtSpeed(512 * 1024), "512 KB/s")
    }

    /// 生产验收批（DBG-188）：fmtRemaining 动态剩余时间——速率未知/已下完 → 空串不编造；
    /// 秒/分钟/小时三档格式；283 KB/s 冷源场景给出「约 65 分钟」量级（静态「约 3 分钟」失真修正）。
    func testFmtRemaining() {
        // 速率未知或已下完 → 空串（不编造）
        XCTAssertEqual(NativeRequiredModels.fmtRemaining(received: 100, total: 1000, bytesPerSecond: 0), "")
        XCTAssertEqual(NativeRequiredModels.fmtRemaining(received: 100, total: 1000, bytesPerSecond: -5), "")
        XCTAssertEqual(NativeRequiredModels.fmtRemaining(received: 1000, total: 1000, bytesPerSecond: 100), "")
        // 秒档：<60s
        XCTAssertEqual(NativeRequiredModels.fmtRemaining(received: 0, total: 45 * 1024, bytesPerSecond: 1024),
                       "预计剩余约 45 秒")
        // 分钟档：1.13GB 按 2 MB/s = 540.4s ≈ 9.01 分钟 → 向上取整 10
        XCTAssertEqual(NativeRequiredModels.fmtRemaining(received: 0, total: 1133435264,
                                                         bytesPerSecond: 2 * 1_048_576),
                       "预计剩余约 10 分钟")
        // DBG-188 现场复现：283 KB/s 下余 1.02GB ≈ 61.4 分钟 → 小时档带分钟零头（不显「约 2 小时」失真）
        XCTAssertEqual(NativeRequiredModels.fmtRemaining(received: 65_050_690, total: 1133435264,
                                                         bytesPerSecond: 283 * 1024),
                       "预计剩余约 1 小时 2 分钟")
        // 小时档：10 KB/s 下 1.13GB ≈ 30 小时 45 分钟
        XCTAssertEqual(NativeRequiredModels.fmtRemaining(received: 0, total: 1133435264,
                                                         bytesPerSecond: 10 * 1024),
                       "预计剩余约 30 小时 45 分钟")
        // 整小时零头进位：3600s 整 → 「约 1 小时」（无零头分钟）
        XCTAssertEqual(NativeRequiredModels.fmtRemaining(received: 0, total: 3600 * 1024,
                                                         bytesPerSecond: 1024),
                       "预计剩余约 1 小时")
    }
}

// MARK: - 0.7.6 收口：停滞看门狗 / Content-Range 校验 / 暂停-重下换代 / 自检复核

extension NativeRequiredModelsTests {

    /// 收口①a：停滞看门狗——首连头+首块即到后停滞，超 stallTimeout 自动掐停
    /// 连接并 Range 重连续传（不静默挂起），note 上屏，最终落位逐字节一致。
    func testStallWatchdogReconnectsAndResumes() async throws {
        let full = Data((0..<200_000).map { UInt8($0 % 251) })
        let url = "http://stub.local/stall.bin"
        StubURLProtocol.handlers[url] = StubURLProtocol.rangeAware(full)
        StubURLProtocol.hangOnceURLs.insert(url)   // 首连停滞，重连后正常投递
        let oldTimeout = NativeModelDownloader.stallTimeout
        NativeModelDownloader.stallTimeout = 0.8   // 测试提速（生产 20s）
        defer { NativeModelDownloader.stallTimeout = oldTimeout }
        let box = ProgressBox()
        let dl = NativeModelDownloader(session: httpSession) { p in box.append(p) }
        let spec = RequiredFileSpec(path: "stall.bin", sizeBytes: Int64(full.count),
                                    sha256: full.sha256Hex(), sources: [url])
        let dest = tmp.appendingPathComponent("ds"), part = tmp.appendingPathComponent("ps")
        try await dl.downloadFiles([spec], destDir: dest, partDir: part)
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("stall.bin")), full,
                       "停滞→掐停→重连续传→落位逐字节一致（SHA256 过）")
        XCTAssertGreaterThanOrEqual(StubURLProtocol.recordedRanges().count, 2,
                                    "停滞后自动重连（请求 ≥2 次）")
        XCTAssertTrue(box.snapshot.contains { !$0.note.isEmpty },
                      "重连提示经进度快照 note 上屏")
    }

    /// 收口①b：停滞重连耗尽——恒停滞源在 maxStallRetries 次后上抛中文明细
    /// （错误上屏走 failed，不无限挂起）。
    func testStallRetriesExhaustedFails() async throws {
        let full = Data(repeating: 0x71, count: 100_000)
        let url = "http://stub.local/dead.bin"
        StubURLProtocol.handlers[url] = StubURLProtocol.rangeAware(full)
        StubURLProtocol.hangURLs.insert(url)   // 恒停滞
        let oldTimeout = NativeModelDownloader.stallTimeout
        let oldMax = NativeModelDownloader.maxStallRetries
        NativeModelDownloader.stallTimeout = 0.6
        NativeModelDownloader.maxStallRetries = 1
        defer {
            NativeModelDownloader.stallTimeout = oldTimeout
            NativeModelDownloader.maxStallRetries = oldMax
        }
        let dl = NativeModelDownloader(session: httpSession)
        let spec = RequiredFileSpec(path: "dead.bin", sizeBytes: Int64(full.count),
                                    sha256: full.sha256Hex(), sources: [url])
        do {
            try await dl.downloadFiles([spec], destDir: tmp.appendingPathComponent("dd"),
                                       partDir: tmp.appendingPathComponent("pd"))
            XCTFail("恒停滞源应失败")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("停滞"),
                          "明细含停滞：\(error.localizedDescription)")
        }
    }

    /// 收口②a：206 续传 Content-Range 起点谎报（CDN 边缘错位）——不盲追加，
    /// 按 416 同款删 .part 无 Range 从头（只一次），落位逐字节一致。
    func testContentRangeMismatchRetriesClean() async throws {
        let full = Data((0..<4096).map { UInt8($0 % 247) })
        let url = "http://stub.local/mismatch.bin"
        StubURLProtocol.handlers[url] = { req in
            guard req.value(forHTTPHeaderField: "Range") != nil else { return (200, full) }
            return (206, full.subdata(in: 300..<full.count))   // 体对但头起点谎报
        }
        StubURLProtocol.extraHeaders[url] = [
            "Content-Range": "bytes 0-\(full.count - 1)/\(full.count)"   // 起点 0 ≠ 300
        ]
        let spec = RequiredFileSpec(path: "m.bin", sizeBytes: Int64(full.count),
                                    sha256: full.sha256Hex(), sources: [url])
        let partDir = tmp.appendingPathComponent("pm")
        try FileManager.default.createDirectory(at: partDir, withIntermediateDirectories: true)
        try full.prefix(300).write(to: partDir.appendingPathComponent("m.bin.part"))
        let dl = NativeModelDownloader(session: httpSession)
        try await dl.downloadFiles([spec], destDir: tmp.appendingPathComponent("dm"),
                                   partDir: partDir)
        XCTAssertEqual(StubURLProtocol.recordedRanges(), ["bytes=300-", nil],
                       "错位 206 → 删 .part 无 Range 重下（只一次）")
        XCTAssertEqual(try Data(contentsOf: tmp.appendingPathComponent("dm/m.bin")), full,
                       "清退重下后落位逐字节一致")
    }

    /// 收口②b：暂停→立即重下——旧任务已取消未收尾，重下不得被吞（换代接管），
    /// 旧任务收尾不冲新任务登记，最终 ready 且落位逐字节一致（无双写交错）。
    func testCancelThenImmediateRetryRunsToReady() async throws {
        let full = Data(repeating: 0x4D, count: 3000)
        let url = "https://stub.local/bge/retry.bin"
        StubURLProtocol.handlers[url] = StubURLProtocol.rangeAware(full)
        StubURLProtocol.hangOnceURLs.insert(url)
        let f = fileEntry("retry.bin", full, sources: [url])
        let rm = try makeRM(models: [embedderModel(files: [f])])
        // 预置半截 .part（500B）——取消语义要保的续传现场（同 ⑧ 口径）
        let partURL = tmp.appendingPathComponent("models/.partial/bge-m3-coreml/retry.bin.part")
        try FileManager.default.createDirectory(at: partURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try full.prefix(500).write(to: partURL)

        rm.startDownload("bge-m3-coreml", session: httpSession)
        XCTAssertTrue(rm.state(for: "bge-m3-coreml").isDownloading)
        try await Task.sleep(nanoseconds: 600_000_000)   // 让请求发出并停滞
        rm.cancelDownload("bge-m3-coreml")
        rm.startDownload("bge-m3-coreml", session: httpSession)   // 立即重下——不得被吞
        let s = await waitState(rm, "bge-m3-coreml") { $0.isReady }
        XCTAssertEqual(s, .ready,
                       "暂停→立即重下：换代接管跑到底（旧任务收尾不冲新任务登记/状态）")
        XCTAssertEqual(try? Data(contentsOf: tmp.appendingPathComponent(
            "models/bge-m3-coreml/retry.bin")), full, "续传落位逐字节一致（无残留交错）")
    }

    /// 收口②c：自检瞬时失败（完成窗并发编译互斥形态）——复核闸隔 1.5s 复核
    /// 一次，过 → ready 不删齐件；自检恰好被调 2 次（红线判死路径不变）。
    func testSelfCheckTransientFailureRetriedOnce() async throws {
        let content = Data(repeating: 0x2E, count: 900)
        let src = makeSource("bge/tokenizer.json", content)
        let f = fileEntry("tokenizer.json", content, sources: ["file://\(src.url.path)"])
        let rm = NativeRequiredModels(dataRoot: tmp, packStore: store)
        final class CountBox: @unchecked Sendable { var n = 0 }
        let box = CountBox()
        rm.selfCheckOverride = { _ in
            box.n += 1
            if box.n == 1 {
                throw RequiredModelsError.selfCheckFailed("假并发编译瞬时失败")
            }
        }
        let manifest = RequiredModelManifest(version: 1, models: [embedderModel(files: [f])])
        let murl = tmp.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(manifest).write(to: murl)
        try rm.loadManifest(from: murl)

        rm.startDownload("bge-m3-coreml")
        let s = await waitState(rm, "bge-m3-coreml") { $0.isReady }
        XCTAssertEqual(s, .ready, "自检瞬时失败 → 1.5s 复核通过 → ready（不删齐件）")
        XCTAssertEqual(box.n, 2, "自检恰好复核一次")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tmp.appendingPathComponent("models/bge-m3-coreml/tokenizer.json").path),
            "瞬时失败不删齐件")
    }
}


// MARK: - Bug7 收口（业主 2026-09-28 拍板）：瞬时网络错误同源原地重试
//
//  实测原景（app-20260928.log L1774-1782）：魔塔单源直链首次下载 3.1s 被
//  -1005 掐断（已收 18.8MB）→ 旧链直接「源失败换下一源」→ 单源=判死；
//  业主手动再点立即满速成功。修复后：判死前先同源原地重试（Range 续传基线），
//  重试耗尽才走换源/判死。以下两个钉桩用 connLostPlan 剧本缝复刻该现场
//  （URLProtocol stub，绝不触网；transientBackoffSeconds 提速 + defer 还原，
//  同 stallTimeout 先例）。

extension NativeRequiredModelsTests {

    /// Bug7①：首次 -1005（高速流中被掐，已收 1000 字节）→ 判「源失败换下一源」
    /// 之前自动同源原地重试（Range: bytes=1000- 续传基线）→ 成功落位逐字节一致。
    /// 单源文件不报「全部源失败」——「首次必败、手动重试必成」体验就此消灭。
    func testTransientConnLostRetriesSameSourceAndSucceeds() async throws {
        let full = Data((0..<4096).map { UInt8($0 % 251) })
        let url = "http://stub.local/bug7.gguf"
        StubURLProtocol.handlers[url] = StubURLProtocol.rangeAware(full)
        StubURLProtocol.connLostPlan[url] = 1   // 首发 -1005，重试走正常投递
        let oldBackoff = NativeModelDownloader.transientBackoffSeconds
        NativeModelDownloader.transientBackoffSeconds = [0.05, 0.05]   // 提速（生产 1s/3s）
        defer { NativeModelDownloader.transientBackoffSeconds = oldBackoff }
        let box = ProgressBox()
        let dl = NativeModelDownloader(session: httpSession) { p in box.append(p) }
        let spec = RequiredFileSpec(path: "bug7.gguf", sizeBytes: Int64(full.count),
                                    sha256: full.sha256Hex(), sources: [url])
        try await dl.downloadFiles([spec], destDir: tmp.appendingPathComponent("d7"),
                                   partDir: tmp.appendingPathComponent("p7"))
        XCTAssertEqual(try Data(contentsOf: tmp.appendingPathComponent("d7/bug7.gguf")), full,
                       "首次 -1005 → 自动同源重试 → 落位逐字节一致（SHA256 过，不报全部源失败）")
        XCTAssertEqual(StubURLProtocol.recordedRanges(), [nil, "bytes=1000-"],
                       "首发无 Range；重试带断点续传基线 1000（不重下已收字节）——恰好 2 次请求")
        XCTAssertTrue(box.snapshot.contains { $0.note.contains("自动重试中") },
                      "重试提示经进度快照 note 上屏（数据恢复流动即清）")
    }

    /// Bug7②：重试 2 次仍败 → 判死上抛（恰好 3 次请求 = 1 + 2 重试，不多不少，
    /// 防超次/死循环回归）；半成品清退口径不变——dest 不落位冒名，.part 续传
    /// 现场保留（下次重试经快速路径/Range 自愈）。
    func testTransientConnLostExhaustedFailsDead() async throws {
        let full = Data(repeating: 0x51, count: 4096)
        let url = "http://stub.local/bug7-dead.gguf"
        StubURLProtocol.handlers[url] = StubURLProtocol.rangeAware(full)
        StubURLProtocol.connLostPlan[url] = 99   // 恒 -1005（真死源）
        let oldBackoff = NativeModelDownloader.transientBackoffSeconds
        NativeModelDownloader.transientBackoffSeconds = [0.05, 0.05]
        defer { NativeModelDownloader.transientBackoffSeconds = oldBackoff }
        let dl = NativeModelDownloader(session: httpSession)
        let spec = RequiredFileSpec(path: "dead.gguf", sizeBytes: Int64(full.count),
                                    sha256: full.sha256Hex(), sources: [url])
        do {
            try await dl.downloadFiles([spec], destDir: tmp.appendingPathComponent("d8"),
                                       partDir: tmp.appendingPathComponent("p8"))
            XCTFail("重试耗尽应判死上抛")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("全部源失败"),
                          "单源重试耗尽 → 全部源失败判死：\(error.localizedDescription)")
        }
        XCTAssertEqual(StubURLProtocol.recordedRanges().count, 3,
                       "恰好 3 次请求（1 次首发 + 2 次重试）——不无限重试不超次")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tmp.appendingPathComponent("d8/dead.gguf").path),
            "判死不落位（半成品不冒名顶替完成文件）")
        XCTAssertEqual(
            (try? Data(contentsOf: tmp.appendingPathComponent("p8/dead.gguf.part")))?.count,
            3000, "半成品清退为 .part 续传现场——3 次尝试各收 1000 字节累进保留"
                + "（佐证重试走 Range 续传而非重下；下次重试经续传自愈）")
    }
}
