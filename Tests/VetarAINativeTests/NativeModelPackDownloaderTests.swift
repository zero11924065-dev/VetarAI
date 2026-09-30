//
//  NativeModelPackDownloaderTests.swift
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

//  逐条锚定（⛔ 行为规格源 subagent/sidecar/model_packs/downloader.py，458 行）：
//    · Range 三态：206 追加 / 200 覆盖（基线归零）/ 416 删 .part 重下一次
//    · 快速路径（dest 已在且哈希对 → 零请求）与续传快捷（.part 完整 → 只校验+rename）
//    · 字节数预检 → SHA256 校验，不符换下一源；全源失败汇总（前三条；连接）
//    · 进度事件：download_start/progress（0.15s 节流，脚本时钟注入）/done/error/cancelled
//    · 取消保留 .partial；成功收尾 manifest.json 副本原子写 + register + 空暂存清理
//    · file:// 本地源拷贝不过 guard；本地源不存在文案
//    · ModelPackDownloadManager：重复启动 409 文案 / cancel 无任务 false / 取消收尾
//    · fetch_catalog：file:// 目录取 catalog.json + 相对 sources 改写绝对 file://；
//      http 非 200 / 非法 JSON / 校验失败文案；空源地址
//
//  全程不触网：FakeMPTransport 脚本化步骤 + 录证 Range 头；事件经注入捕获器。
//

import XCTest
import CryptoKit
@testable import VetarAINative

// MARK: - 测试夹具（假传输 / 事件捕获 / 脚本时钟 / 分块闸门）

/// 分块闸门：测试逐块放行，精确编排「下载到一半取消」。
private actor ChunkGate {
    private var permits = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func acquire() async {
        if permits > 0 { permits -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release(_ n: Int = 1) {
        for _ in 0 ..< n {
            if !waiters.isEmpty { waiters.removeFirst().resume() }
            else { permits += 1 }
        }
    }
}

/// 脚本化假传输：每 URL 一队 Step；录证请求（含 Range 头）。
private final class FakeMPTransport: NativeMPDownloadTransport, @unchecked Sendable {
    struct Step: @unchecked Sendable {
        var status: Int = 200
        var chunks: [Data] = []
        var connectError: Error? = nil
        var gate: ChunkGate? = nil
        /// 每块 yield 前回调（参数 = 块序号）——脚本时钟推进挂这里。
        var onChunk: (@Sendable (Int) -> Void)? = nil
    }
    private let lock = NSLock()
    private var steps: [String: [Step]] = [:]
    private var getSteps: [String: [(status: Int, data: Data)]] = [:]
    private(set) var requests: [(url: String, range: String?)] = []

    func script(_ url: String, _ s: [Step]) {
        lock.lock(); steps[url] = s; lock.unlock()
    }
    func scriptGet(_ url: String, status: Int, data: Data) {
        lock.lock(); getSteps[url] = [(status, data)]; lock.unlock()
    }
    func requestCount(_ url: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return requests.filter { $0.url == url }.count
    }

    func streamBytes(url: String, headers: [String: String]) async throws
        -> (status: Int, bytes: AsyncThrowingStream<Data, Error>) {
        lock.lock()
        requests.append((url, headers["Range"]))
        var q = steps[url] ?? []
        let step = q.isEmpty ? nil : q.removeFirst()
        steps[url] = q
        lock.unlock()
        guard let step else { throw URLError(.badURL) }
        if let e = step.connectError { throw e }
        let stream = AsyncThrowingStream<Data, Error> { cont in
            let task = Task {
                for (i, c) in step.chunks.enumerated() {
                    if let g = step.gate { await g.acquire() }
                    if Task.isCancelled { cont.finish(throwing: CancellationError()); return }
                    step.onChunk?(i)
                    cont.yield(c)
                }
                cont.finish()
            }
            cont.onTermination = { @Sendable _ in task.cancel() }
        }
        return (step.status, stream)
    }

    func getData(url: String) async throws -> (status: Int, data: Data) {
        lock.lock()
        var q = getSteps[url] ?? []
        let s = q.isEmpty ? nil : q.removeFirst()
        getSteps[url] = q
        lock.unlock()
        guard let s else { throw URLError(.badURL) }
        return s
    }
}

/// 生命周期/进度事件捕获器。
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var events: [(action: String, packId: String, fields: [String: JSONValue])] = []
    func append(_ action: String, _ packId: String, _ fields: [String: JSONValue]) {
        lock.lock(); events.append((action, packId, fields)); lock.unlock()
    }
    var actions: [String] {
        lock.lock(); defer { lock.unlock() }
        return events.map { $0.action }
    }
    func count(_ action: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return events.filter { $0.action == action }.count
    }
    func fieldsOf(_ action: String, _ idx: Int = 0) -> [String: JSONValue]? {
        lock.lock(); defer { lock.unlock() }
        let m = events.filter { $0.action == action }
        return idx < m.count ? m[idx].fields : nil
    }
}

/// 脚本时钟（进度节流注入）。
private final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var t = 0.0
    func set(_ v: Double) { lock.lock(); t = v; lock.unlock() }
    func now() -> Double { lock.lock(); defer { lock.unlock() }; return t }
}

final class NativeModelPackDownloaderTests: XCTestCase {

    private var tmp: URL!
    private var transport: FakeMPTransport!
    private var events: EventLog!
    private var clock: ClockBox!
    private var store: NativeModelPackStore!
    private var downloader: NativeModelPackDownloader!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mpdl_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        transport = FakeMPTransport()
        events = EventLog()
        clock = ClockBox()
        store = NativeModelPackStore(
            configProvider: { [:] },
            dataRootProvider: { self.tmp },
            environment: [NativeModelPackStore.envPacksDir: self.tmp.appendingPathComponent("packs").path])
        downloader = NativeModelPackDownloader(
            store: store, networkGuard: NativeNetworkGuard(), transport: transport)
        downloader.emit = { [events] a, p, f in events?.append(a, p, f) }
        downloader.now = { [clock] in clock?.now() ?? 0 }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    // MARK: 夹具函数

    private func shaHex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 构造通过 validate_pack 的包条目（files: 相对路径 + 内容 + 源表）。
    private func packJSON(_ pid: String,
                          files: [(path: String, data: Data, sources: [String])],
                          sizeOverride: Int64? = nil,
                          shaOverride: String? = nil) -> [String: JSONValue] {
        let fileVals: [JSONValue] = files.map { f in
            .object([
                "path": .string(f.path),
                "size_bytes": .int(Int64(f.data.count)),
                "sha256": .string(shaOverride ?? shaHex(f.data)),
                "sources": .array(f.sources.map { JSONValue.string($0) }),
            ])
        }
        let total = files.reduce(Int64(0)) { $0 + Int64($1.data.count) }
        return [
            "pack_id": .string(pid),
            "name": .string("测试对话包"),
            "task": .string("chat"),
            "format": .string("gguf"),
            "driver": .string("llamacpp"),
            "version": .string("1.0.0"),
            "size_bytes": .int(sizeOverride ?? total),
            "files": .array(fileVals),
        ]
    }

    private func packDir(_ pid: String) -> URL {
        tmp.appendingPathComponent("packs/\(pid)")
    }
    private func partFile(_ pid: String, _ rel: String) -> URL {
        tmp.appendingPathComponent("packs/\(pid)/.partial/\(rel).part")
    }

    private func waitUntil(_ timeout: Double = 5, _ cond: @Sendable () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return cond()
    }

    private func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)??.int64Value ?? 0
    }

    // MARK: - 成功主流程

    func testDownloadSuccessLifecycleAndRegistry() async throws {
        let content = Data(repeating: 0x61, count: 1000)
        let url = "https://cdn.example.com/model.gguf"
        transport.script(url, [.init(status: 200, chunks: [content])])
        let pack = packJSON("qwen-mini", files: [("model.gguf", content, [url])])

        let entry = try await downloader.downloadPack(pack)

        // 文件到位 + .part 不残留 + manifest.json 副本写入
        XCTAssertEqual(try Data(contentsOf: packDir("qwen-mini/model.gguf")), content)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partFile("qwen-mini", "model.gguf").path))
        let manData = try Data(contentsOf: packDir("qwen-mini/manifest.json"))
        XCTAssertEqual(NativeJSONWriter.loads(manData)?.object?["pack_id"]?.string, "qwen-mini")
        // 空暂存目录已清理（.partial 在包目录内）
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: packDir("qwen-mini/.partial").path))
        // registry 登记：status/version/files 裁剪（无 sources）
        XCTAssertEqual(entry["status"]?.string, "installed")
        XCTAssertEqual(entry["version"]?.string, "1.0.0")
        let f0 = entry["files"]?.array?.first?.object
        XCTAssertEqual(f0?["path"]?.string, "model.gguf")
        XCTAssertEqual(f0?["sha256"]?.string, shaHex(content))
        XCTAssertNil(f0?["sources"])
        XCTAssertEqual(entry["sha256_ok"]?.bool, true)
        // 事件序列：start → progress（起/止至少）→ done
        XCTAssertEqual(events.actions.first, "download_start")
        XCTAssertEqual(events.actions.last, "download_done")
        let start = events.fieldsOf("download_start")
        XCTAssertEqual(start?["total_bytes"]?.int, 1000)
        XCTAssertEqual(start?["file_count"]?.int, 1)
        XCTAssertEqual(start?["name"]?.string, "测试对话包")
        XCTAssertEqual(start?["version"]?.string, "1.0.0")
        XCTAssertEqual(events.fieldsOf("download_done")?["total_bytes"]?.int, 1000)
        XCTAssertGreaterThanOrEqual(events.count("download_progress"), 2)
        XCTAssertEqual(transport.requestCount(url), 1)
    }

    func testProgressThrottledByScriptClock() async throws {
        let c1 = Data(repeating: 0x1, count: 100)
        let c2 = Data(repeating: 0x2, count: 100)
        let c3 = Data(repeating: 0x3, count: 100)
        let url = "https://cdn.example.com/big.gguf"
        let gate = ChunkGate()   // 逐块放行：消费端追平后再推进脚本时钟，杜绝生产者抢跑
        let clock = self.clock!
        transport.script(url, [.init(status: 200, chunks: [c1, c2, c3], gate: gate)])
        let pack = packJSON("throttle-pack",
                            files: [("big.gguf", c1 + c2 + c3, [url])])
        let dl = Task { try await self.downloader.downloadPack(pack) }
        let part = partFile("throttle-pack", "big.gguf")

        await gate.release(1)   // 块1 于 t=0.00 消费：0.00-0.00 < 0.15 不触发
        let landed1 = await waitUntil { self.fileSize(part) == 100 }
        XCTAssertTrue(landed1)
        clock.set(0.05)
        await gate.release(1)   // 块2 于 t=0.05：0.05 < 0.15 不触发
        let landed2 = await waitUntil { self.fileSize(part) == 200 }
        XCTAssertTrue(landed2)
        clock.set(0.20)
        await gate.release(1)   // 块3 于 t=0.20：0.20 ≥ 0.15 触发一次
        _ = try await dl.value

        // startFile 必发(0.00) + 节流窗口后一次(块3) + finishFile 必发 = 3
        XCTAssertEqual(events.count("download_progress"), 3)
        let mid = events.fieldsOf("download_progress", 1)
        XCTAssertEqual(mid?["file_received"]?.int, 300)
        XCTAssertEqual(mid?["received_bytes"]?.int, 300)
        let fin = events.fieldsOf("download_progress", 2)
        XCTAssertEqual(fin?["file_received"]?.int, 300)
        XCTAssertEqual(fin?["total_bytes"]?.int, 300)
        XCTAssertEqual(fin?["file"]?.string, "big.gguf")
    }

    // MARK: - 0.7.5 W7：进度事件实时速率字段

    /// 进度事件携带 bytes_per_second（滚动窗均速，与必备模型下载器同口径）
    func testProgressEventsCarryBytesPerSecondW7() async throws {
        let c1 = Data(repeating: 0x1, count: 100)
        let c2 = Data(repeating: 0x2, count: 100)
        let url = "https://cdn.example.com/rate.gguf"
        let gate = ChunkGate()
        let clock = self.clock!
        transport.script(url, [.init(status: 200, chunks: [c1, c2], gate: gate)])
        let pack = packJSON("rate-pack", files: [("rate.gguf", c1 + c2, [url])])
        let dl = Task { try await self.downloader.downloadPack(pack) }

        await gate.release(1)   // 块1 于 t=0.00 消费：未过节流窗不发
        let landed1 = await waitUntil { self.fileSize(self.partFile("rate-pack", "rate.gguf")) == 100 }
        XCTAssertTrue(landed1)
        clock.set(0.20)
        await gate.release(1)   // 块2 于 t=0.20 消费：触发一次节流进度
        _ = try await dl.value

        // startFile + 节流一次 + finishFile = 3，且每条都带 bytes_per_second 键
        XCTAssertEqual(events.count("download_progress"), 3)
        for i in 0..<3 {
            XCTAssertNotNil(events.fieldsOf("download_progress", i)?["bytes_per_second"],
                            "第 \(i) 条进度事件缺 bytes_per_second 字段")
        }
        // 节流条：样本 (0.00,100)+(0.20,100)，span 下限 0.5 → 200/0.5 = 400 B/s
        let mid = events.fieldsOf("download_progress", 1)
        XCTAssertEqual(mid?["bytes_per_second"]?.double ?? 0, 400, accuracy: 0.001)
        // startFile 速率归零（不带上一文件残值）
        XCTAssertEqual(events.fieldsOf("download_progress", 0)?["bytes_per_second"]?.double, 0)
    }

    /// displayRate 纯函数：窗龄剔除 / span 下限 0.5 / 空窗归零
    func testDisplayRateWindowMathW7() {
        var samples: [(Double, Int64)] = []
        // 空窗 → 0
        XCTAssertEqual(NativeModelPackDownloader.displayRate(samples: &samples, now: 0), 0)
        // span 下限 0.5s（首块瞬时尖刺防爆表）：(0,50) 于 t=0 → 50/0.5=100
        samples = [(0, 50)]
        XCTAssertEqual(NativeModelPackDownloader.displayRate(samples: &samples, now: 0), 100)
        // 窗龄剔除：t=10 时 (0,50) 超 3s 窗龄被剔，仅剩 (9.5,150) → 150/0.5=300
        samples = [(0, 50), (9.5, 150)]
        XCTAssertEqual(NativeModelPackDownloader.displayRate(samples: &samples, now: 10), 300)
        XCTAssertEqual(samples.count, 1)   // 旧样本已剔除
        // 正常跨度：(0,100)+(2,300) 于 t=2 → 400/2=200
        samples = [(0, 100), (2, 300)]
        XCTAssertEqual(NativeModelPackDownloader.displayRate(samples: &samples, now: 2), 200)
    }

    // MARK: - Range 三态

    func testResume206AppendsWithRangeHeader() async throws {
        let full = Data(repeating: 0x62, count: 500)
        let head = full.prefix(200)
        let tail = full.suffix(300)
        let url = "https://cdn.example.com/resume.gguf"
        // 预置半截 .part（上次中断残留）
        try FileManager.default.createDirectory(
            at: partFile("res-pack", "m.gguf").deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try head.write(to: partFile("res-pack", "m.gguf"))
        transport.script(url, [.init(status: 206, chunks: [Data(tail)])])
        let pack = packJSON("res-pack", files: [("m.gguf", full, [url])])

        _ = try await downloader.downloadPack(pack)

        XCTAssertEqual(transport.requests.first?.range, "bytes=200-")
        XCTAssertEqual(try Data(contentsOf: packDir("res-pack/m.gguf")), full)
    }

    func testFull200OverwritesPartialBaseline() async throws {
        let full = Data(repeating: 0x63, count: 300)
        let url = "https://cdn.example.com/fresh.gguf"
        // 预置脏 .part；服务端不理会 Range 直接回 200 → 覆盖写
        try FileManager.default.createDirectory(
            at: partFile("ov-pack", "m.gguf").deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data(repeating: 0xFF, count: 50).write(to: partFile("ov-pack", "m.gguf"))
        transport.script(url, [.init(status: 200, chunks: [full])])
        let pack = packJSON("ov-pack", files: [("m.gguf", full, [url])])

        _ = try await downloader.downloadPack(pack)

        XCTAssertEqual(transport.requests.first?.range, "bytes=50-")   // 有问
        XCTAssertEqual(try Data(contentsOf: packDir("ov-pack/m.gguf")), full)  // 但被覆盖
    }

    func test416DeletesPartAndRetriesOnce() async throws {
        let full = Data(repeating: 0x64, count: 120)
        let url = "https://cdn.example.com/range.gguf"
        // 预置半截 .part（100 ≤ 声明 120，不触发超长预删；服务端文件已变 → 416）
        try FileManager.default.createDirectory(
            at: partFile("p416", "m.gguf").deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data(repeating: 0x77, count: 100).write(to: partFile("p416", "m.gguf"))
        transport.script(url, [
            .init(status: 416),                       // 越界：删 .part
            .init(status: 200, chunks: [full]),       // 从头重下（不再带 Range）
        ])
        let pack = packJSON("p416", files: [("m.gguf", full, [url])])

        _ = try await downloader.downloadPack(pack)

        XCTAssertEqual(transport.requestCount(url), 2)
        XCTAssertEqual(transport.requests[0].range, "bytes=100-")
        XCTAssertNil(transport.requests[1].range)
        XCTAssertEqual(try Data(contentsOf: packDir("p416/m.gguf")), full)
    }

    func test416TwiceFailsSourceAndFallsBack() async throws {
        let full = Data(repeating: 0x65, count: 60)
        let bad = "https://cdn.example.com/always416.gguf"
        let good = "https://mirror.example.com/m.gguf"
        try FileManager.default.createDirectory(
            at: partFile("p416b", "m.gguf").deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data(repeating: 0x77, count: 10).write(to: partFile("p416b", "m.gguf"))
        transport.script(bad, [.init(status: 416), .init(status: 416)])
        transport.script(good, [.init(status: 200, chunks: [full])])
        let pack = packJSON("p416b", files: [("m.gguf", full, [bad, good])])

        _ = try await downloader.downloadPack(pack)

        // 第一源两次 416 → 回退第二源成功（416 后 .part 已删，第二源不带 Range）
        XCTAssertEqual(transport.requestCount(bad), 2)
        XCTAssertEqual(transport.requestCount(good), 1)
        XCTAssertNil(transport.requests.last?.range)
        XCTAssertEqual(try Data(contentsOf: packDir("p416b/m.gguf")), full)
    }

    // MARK: - 校验与源回退

    func testShaMismatchFallsToNextSource() async throws {
        let good = Data(repeating: 0x66, count: 80)
        let u1 = "https://cdn.example.com/wrong.gguf"
        let u2 = "https://mirror.example.com/right.gguf"
        transport.script(u1, [.init(status: 200, chunks: [Data(repeating: 0x00, count: 80)])])
        transport.script(u2, [.init(status: 200, chunks: [good])])
        let pack = packJSON("sha-pack", files: [("m.gguf", good, [u1, u2])])

        _ = try await downloader.downloadPack(pack)

        XCTAssertEqual(transport.requestCount(u1), 1)
        XCTAssertEqual(transport.requestCount(u2), 1)
        XCTAssertEqual(try Data(contentsOf: packDir("sha-pack/m.gguf")), good)
    }

    func testByteCountMismatchMessage() async throws {
        let url = "https://cdn.example.com/short.gguf"
        transport.script(url, [.init(status: 200, chunks: [Data(repeating: 0x1, count: 3)])])
        // 声明 10 字节（内容随意——预检在哈希之前触发）
        let pack = packJSON("byte-pack",
                            files: [("m.gguf", Data(repeating: 0x1, count: 10), [url])])

        do {
            _ = try await downloader.downloadPack(pack)
            XCTFail("应抛字节数不符")
        } catch let e as NativePackDownloadError {
            XCTAssertTrue(e.message.contains("字节数不符"), e.message)
            XCTAssertTrue(e.message.contains("应为 10"), e.message)
            XCTAssertTrue(e.message.contains("收到 3"), e.message)
        }
        // 失败发 download_error，且 .part 现场保留
        XCTAssertEqual(events.actions.last, "download_error")
        XCTAssertTrue(FileManager.default.fileExists(atPath: partFile("byte-pack", "m.gguf").path))
    }

    func testAllSourcesFailedSummary() async throws {
        let good = Data(repeating: 0x67, count: 40)
        let u1 = "https://a.example.com/m.gguf"
        let u2 = "https://b.example.com/m.gguf"
        transport.script(u1, [.init(status: 404)])
        transport.script(u2, [.init(status: 200, chunks: [Data(repeating: 0x9, count: 40)])]) // 哈希错
        let pack = packJSON("fail-pack", files: [("m.gguf", good, [u1, u2])])

        do {
            _ = try await downloader.downloadPack(pack)
            XCTFail("应抛全源失败")
        } catch let e as NativePackDownloadError {
            XCTAssertTrue(e.message.hasPrefix("文件 m.gguf 全部源失败 —— "), e.message)
            XCTAssertTrue(e.message.contains("HTTP 404"), e.message)
            XCTAssertTrue(e.message.contains("SHA256 不符"), e.message)
            XCTAssertTrue(e.message.contains("；"), e.message)
        }
        XCTAssertEqual(events.actions.last, "download_error")
        XCTAssertNotNil(events.fieldsOf("download_error")?["error"]?.string)
    }

    // MARK: - 快速路径 / 续传快捷

    func testDestAlreadyCompleteSkipsNetwork() async throws {
        let content = Data(repeating: 0x68, count: 64)
        let url = "https://cdn.example.com/skip.gguf"
        let pack = packJSON("skip-pack", files: [("m.gguf", content, [url])])
        // 预置最终文件且哈希正确（上次中断在 rename 之后）
        try FileManager.default.createDirectory(at: packDir("skip-pack"),
                                                withIntermediateDirectories: true)
        try content.write(to: packDir("skip-pack/m.gguf"))

        _ = try await downloader.downloadPack(pack)

        XCTAssertEqual(transport.requests.count, 0)   // 零网络请求
        XCTAssertEqual(events.actions.last, "download_done")
    }

    func testPartCompleteRenamesWithoutNetwork() async throws {
        let content = Data(repeating: 0x69, count: 64)
        let url = "https://cdn.example.com/part.gguf"
        let pack = packJSON("part-pack", files: [("m.gguf", content, [url])])
        try FileManager.default.createDirectory(
            at: partFile("part-pack", "m.gguf").deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try content.write(to: partFile("part-pack", "m.gguf"))

        _ = try await downloader.downloadPack(pack)

        XCTAssertEqual(transport.requests.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partFile("part-pack", "m.gguf").path))
        XCTAssertEqual(try Data(contentsOf: packDir("part-pack/m.gguf")), content)
    }

    func testOversizedPartIsRedownloaded() async throws {
        let content = Data(repeating: 0x6A, count: 32)
        let url = "https://cdn.example.com/oversize.gguf"
        try FileManager.default.createDirectory(
            at: partFile("big-part", "m.gguf").deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data(repeating: 0x77, count: 100).write(to: partFile("big-part", "m.gguf"))
        transport.script(url, [.init(status: 200, chunks: [content])])
        let pack = packJSON("big-part", files: [("m.gguf", content, [url])])

        _ = try await downloader.downloadPack(pack)

        // 超长的 .part 被删后重下（不带 Range，从 0 起）
        XCTAssertEqual(transport.requestCount(url), 1)
        XCTAssertNil(transport.requests.first?.range ?? nil)
        XCTAssertEqual(try Data(contentsOf: packDir("big-part/m.gguf")), content)
    }

    // MARK: - file:// 本地源

    func testLocalFileSourceCopies() async throws {
        let content = Data(repeating: 0x6B, count: 256)
        let src = tmp.appendingPathComponent("import/model.gguf")
        try FileManager.default.createDirectory(at: src.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try content.write(to: src)
        let pack = packJSON("local-pack",
                            files: [("model.gguf", content, ["file://\(src.path)"])])

        _ = try await downloader.downloadPack(pack)

        XCTAssertEqual(transport.requests.count, 0)   // 本地源不过网络
        XCTAssertEqual(try Data(contentsOf: packDir("local-pack/model.gguf")), content)
    }

    func testLocalSourceMissingMessage() async throws {
        let missing = tmp.appendingPathComponent("nope/model.gguf")
        let pack = packJSON("miss-pack",
                            files: [("model.gguf", Data(repeating: 1, count: 4),
                                     ["file://\(missing.path)"])])

        do {
            _ = try await downloader.downloadPack(pack)
            XCTFail("应抛本地源不存在")
        } catch let e as NativePackDownloadError {
            XCTAssertTrue(e.message.contains("本地源不存在"), e.message)
        }
    }

    // MARK: - 取消语义

    func testCancelKeepsPartialAndEmitsCancelled() async throws {
        let chunk = Data(repeating: 0x6C, count: 128)
        let url = "https://cdn.example.com/slow.gguf"
        let gate = ChunkGate()
        transport.script(url, [.init(status: 200,
                                     chunks: [chunk, chunk, chunk, chunk, chunk], gate: gate)])
        let pack = packJSON("cancel-pack",
                            files: [("m.gguf", Data(repeating: 0x6C, count: 640), [url])])
        let manager = NativeModelPackDownloadManager(downloader: downloader)
        try manager.start("cancel-pack", pack: pack)
        XCTAssertTrue(manager.isActive("cancel-pack"))

        await gate.release(1)   // 放行第一块
        let landed = await waitUntil { self.fileSize(self.partFile("cancel-pack", "m.gguf")) == 128 }
        XCTAssertTrue(landed, "第一块应落盘")

        let cancelTask = Task { await manager.cancel("cancel-pack") }
        try await Task.sleep(nanoseconds: 50_000_000)   // 让 cancel 先送达
        await gate.release(5)                            // 唤醒流 → 消费端检查到取消
        let ok = await cancelTask.value

        XCTAssertTrue(ok)
        XCTAssertFalse(manager.isActive("cancel-pack"))
        // 取消保留 .partial 现场 + 发 download_cancelled（带字节进度）
        XCTAssertTrue(FileManager.default.fileExists(atPath: partFile("cancel-pack", "m.gguf").path))
        XCTAssertEqual(events.actions.last, "download_cancelled",
                       "终止事件=\(events.actions) 明细=\(events.fieldsOf("download_error")?["error"]?.string ?? "nil")")
        XCTAssertEqual(events.fieldsOf("download_cancelled")?["total_bytes"]?.int, 640)
    }

    // MARK: - 任务管理器

    func testManagerDuplicateStartThrows409Message() async throws {
        let url = "https://cdn.example.com/dup.gguf"
        let gate = ChunkGate()
        transport.script(url, [.init(status: 200, chunks: [Data(repeating: 1, count: 8)], gate: gate)])
        let pack = packJSON("dup-pack", files: [("m.gguf", Data(repeating: 1, count: 8), [url])])
        let manager = NativeModelPackDownloadManager(downloader: downloader)

        try manager.start("dup-pack", pack: pack)
        XCTAssertThrowsError(try manager.start("dup-pack", pack: pack)) { error in
            XCTAssertEqual((error as? NativePackDownloadError)?.message, "模型包 dup-pack 正在下载中")
        }
        // 清理：取消并放行收尾
        let cancelTask = Task { await manager.cancel("dup-pack") }
        try await Task.sleep(nanoseconds: 50_000_000)
        await gate.release(2)
        _ = await cancelTask.value
    }

    func testManagerCancelWithoutTaskReturnsFalse() async {
        let manager = NativeModelPackDownloadManager(downloader: downloader)
        let ok = await manager.cancel("ghost-pack")
        XCTAssertFalse(ok)
    }

    // MARK: - fetch_catalog

    func testFetchCatalogFileURLRewritesRelativeSources() async throws {
        let catDir = tmp.appendingPathComponent("localcat")
        try FileManager.default.createDirectory(at: catDir, withIntermediateDirectories: true)
        var pack = packJSON("cat-pack",
                            files: [("weights/m.gguf", Data(repeating: 1, count: 4),
                                     ["weights/m.gguf", "https://cdn.example.com/m.gguf"])])
        // 相对 sources 在 validate 阶段非法——但改写发生在校验之前（L426-433）
        pack["files"] = .array([.object([
            "path": .string("weights/m.gguf"),
            "size_bytes": .int(4),
            "sha256": .string(String(repeating: "a", count: 64)),
            "sources": .array([.string("weights/m.gguf"),
                               .string("https://cdn.example.com/m.gguf")]),
        ])])
        let catalog: [String: JSONValue] = ["version": .int(1), "packs": .array([.object(pack)])]
        try NativeJSONWriter.dumps(.object(catalog)).write(
            to: catDir.appendingPathComponent("catalog.json"), atomically: false, encoding: .utf8)

        let (packs, error) = await downloader.fetchCatalog("file://\(catDir.path)")

        XCTAssertNil(error)
        let sources = packs?.first?["files"]?.array?.first?.object?["sources"]?.array
        // 相对源已改写为该目录下的绝对 file://；绝对源原样保留
        XCTAssertTrue(sources?.first?.string?.hasPrefix("file://") ?? false)
        XCTAssertTrue(sources?.first?.string?.contains("weights/m.gguf") ?? false)
        XCTAssertEqual(sources?.last?.string, "https://cdn.example.com/m.gguf")
        XCTAssertEqual(packs?.first?["pack_id"]?.string, "cat-pack")
    }

    func testFetchCatalogLocalMissing() async {
        // 不存在的目录：is_dir 为假，路径原样进入文案（同 Python L420-421）
        let (_, error) = await downloader.fetchCatalog("file://\(tmp.path)/no-such-dir")
        XCTAssertEqual(error, "本地 catalog 不存在: \(tmp.path)/no-such-dir")
    }

    func testFetchCatalogHTTPOK() async throws {
        let url = "https://catalog.example.com/catalog.json"
        let pack = packJSON("http-pack",
                            files: [("m.gguf", Data(repeating: 1, count: 4),
                                     ["https://cdn.example.com/m.gguf"])])
        let catalog: [String: JSONValue] = ["version": .int(1), "packs": .array([.object(pack)])]
        transport.scriptGet(url, status: 200,
                            data: Data(NativeJSONWriter.dumps(.object(catalog)).utf8))

        let (packs, error) = await downloader.fetchCatalog(url)

        XCTAssertNil(error)
        XCTAssertEqual(packs?.count, 1)
        XCTAssertEqual(packs?.first?["pack_id"]?.string, "http-pack")
    }

    func testFetchCatalogHTTPNon200() async {
        let url = "https://catalog.example.com/catalog.json"
        transport.scriptGet(url, status: 503, data: Data())
        let (packs, error) = await downloader.fetchCatalog(url)
        XCTAssertNil(packs)
        XCTAssertEqual(error, "catalog.example.com: HTTP 503")
    }

    func testFetchCatalogInvalidJSON() async {
        let url = "https://catalog.example.com/broken.json"
        transport.scriptGet(url, status: 200, data: Data("{ not json".utf8))
        let (_, error) = await downloader.fetchCatalog(url)
        XCTAssertTrue(error?.contains("catalog 不是合法 JSON") ?? false, error ?? "")
    }

    func testFetchCatalogValidationFailureMessage() async {
        let url = "https://catalog.example.com/dup.json"
        let pack = packJSON("dup-id",
                            files: [("m.gguf", Data(repeating: 1, count: 4),
                                     ["https://cdn.example.com/m.gguf"])])
        let catalog: [String: JSONValue] = ["version": .int(1),
                                            "packs": .array([.object(pack), .object(pack)])]
        transport.scriptGet(url, status: 200,
                            data: Data(NativeJSONWriter.dumps(.object(catalog)).utf8))

        let (_, error) = await downloader.fetchCatalog(url)
        XCTAssertTrue(error?.hasPrefix("catalog 校验失败: ") ?? false, error ?? "")
        XCTAssertTrue(error?.contains("pack_id 重复") ?? false, error ?? "")
    }

    func testFetchCatalogEmptyURL() async {
        let (_, error) = await downloader.fetchCatalog("   ")
        XCTAssertEqual(error, "空 catalog 源地址")
    }
}


// MARK: - 0.7.4 W7 本地 catalog 读取超时（TCC 保护目录内核态悬挂兜底）

extension NativeModelPackDownloaderTests {

    /// 注入永久悬挂的读取器（模拟 TCC 保护目录 open() 内核态阻塞）+ 超时 0.2s
    /// → 调用方由计时器分支脱身，错误文案引导系统设置授权。
    func testFetchCatalogLocalReadTimeout() async {
        downloader.localCatalogReadTimeout = 0.2
        downloader.localCatalogReader = { _ in
            try? await Task.sleep(nanoseconds: 30_000_000_000)   // 永久悬挂
            return nil
        }
        let (_, error) = await downloader.fetchCatalog("file://\(tmp.path)/protected-dir")
        XCTAssertTrue(error?.contains("读取本地 catalog 超时") ?? false, error ?? "")
        XCTAssertTrue(error?.contains("系统设置→隐私与安全性") ?? false, error ?? "")
    }

    /// 注入读取器返回合法 catalog → 走通解析（超时竞速不影响正常读取）。
    func testFetchCatalogLocalInjectedReaderOK() async {
        let pack = packJSON("inj-pack",
                            files: [("m.gguf", Data(repeating: 1, count: 4),
                                     ["m.gguf"])])
        let catalog: [String: JSONValue] = ["version": .int(1), "packs": .array([.object(pack)])]
        let bytes = Data(NativeJSONWriter.dumps(.object(catalog)).utf8)
        downloader.localCatalogReader = { _ in bytes }
        let (packs, error) = await downloader.fetchCatalog("file://\(tmp.path)/anydir")
        XCTAssertNil(error)
        XCTAssertEqual(packs?.first?["pack_id"]?.string, "inj-pack")
    }
}
