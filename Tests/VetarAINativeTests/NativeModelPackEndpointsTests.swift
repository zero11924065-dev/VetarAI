//
//  NativeModelPackEndpointsTests.swift
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

//  逐条锚定（⛔ 行为规格源 subagent/sidecar/app.py L2746-2900）：
//    · list：注册表+磁盘探测字段映射（status/enabled/size/context_length/partial）
//    · catalog：多源合并 + pack_id 跨源去重先胜 + source/installed/enabled/
//      installed_version 标注 + sources 计数 + 单源失败 source_errors 不拖死
//    · install：400 三链（不一致/非法 slug/校验失败前 5 条）→ 409（已安装/
//      下载中）→ accepted 不重复 notify（生命周期事件归下载器）
//    · cancel：404 无任务逐字；成功 notify(update, phase="cancelled")
//    · delete：在飞先取消 → 回收运行时 → remove false→404 → notify(delete)
//    · toggle：404 逐字；禁用回收运行时（活动 llama-server 被停）；
//      notify(update, enabled)
//
//  全程不触网不要求真进程：FakeDLTransport/FakeProc3/FakeSpawner3 缝注入，
//  notify 捕获器录证。
//

import XCTest
import CryptoKit
@testable import VetarAINative

// MARK: - 夹具

private actor ChunkGate3 {
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

private final class FakeDLTransport: NativeMPDownloadTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var gets: [String: (status: Int, data: Data)] = [:]
    private var streams: [String: (status: Int, chunks: [Data], gate: ChunkGate3?)] = [:]
    private(set) var requested: [String] = []
    func scriptGet(_ url: String, status: Int, data: Data) {
        lock.lock(); gets[url] = (status, data); lock.unlock()
    }
    func scriptStream(_ url: String, status: Int, chunks: [Data], gate: ChunkGate3? = nil) {
        lock.lock(); streams[url] = (status, chunks, gate); lock.unlock()
    }
    func getData(url: String) async throws -> (status: Int, data: Data) {
        lock.lock(); requested.append(url); let g = gets[url]; lock.unlock()
        guard let g else { throw URLError(.badURL) }
        return g
    }
    func streamBytes(url: String, headers: [String: String]) async throws
        -> (status: Int, bytes: AsyncThrowingStream<Data, Error>) {
        lock.lock(); requested.append(url); let s = streams[url]; lock.unlock()
        guard let s else { throw URLError(.badURL) }
        return (s.status, AsyncThrowingStream { cont in
            let task = Task {
                for c in s.chunks {
                    if let g = s.gate { await g.acquire() }
                    cont.yield(c)
                }
                cont.finish()
            }
            cont.onTermination = { @Sendable _ in task.cancel() }
        })
    }
}

private final class FakeProc3: NativeLlamaServerProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    var exitCode: Int32? { isRunning ? nil : 0 }
    func terminate() { lock.lock(); running = false; lock.unlock() }
    func kill() { lock.lock(); running = false; lock.unlock() }
    func wait(timeout: Double) async -> Bool { !isRunning }
    func untrack() {}
}

private final class FakeSpawner3: NativeLlamaSpawner, @unchecked Sendable {
    func spawn(argv: [String], env: [String: String], log: FileHandle) throws
        -> any NativeLlamaServerProcess { FakeProc3() }
}

private final class NotifyLog: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [(resource: String, action: String, extra: [String: JSONValue])] = []
    func add(_ r: String, _ a: String, _ e: [String: JSONValue]) {
        lock.lock(); calls.append((r, a, e)); lock.unlock()
    }
}

private final class CfgBox3: @unchecked Sendable {
    private let lock = NSLock()
    private var cfg: [String: JSONValue]
    init(_ c: [String: JSONValue]) { cfg = c }
    func get() -> [String: JSONValue] { lock.lock(); defer { lock.unlock() }; return cfg }
}

final class NativeModelPackEndpointsTests: XCTestCase {

    private var tmp: URL!
    private var store: NativeModelPackStore!
    private var transport: FakeDLTransport!
    private var downloader: NativeModelPackDownloader!
    private var manager: NativeModelPackDownloadManager!
    private var driver: NativeLlamaCppDriver!
    private var cfg: CfgBox3!
    private var notify: NotifyLog!
    private var endpoints: NativeModelPackEndpoints!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mpep_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        store = NativeModelPackStore(
            configProvider: { [:] },
            dataRootProvider: { self.tmp },
            environment: [NativeModelPackStore.envPacksDir: self.tmp.appendingPathComponent("packs").path])
        transport = FakeDLTransport()
        downloader = NativeModelPackDownloader(store: store, networkGuard: NativeNetworkGuard(),
                                               transport: transport)
        manager = NativeModelPackDownloadManager(downloader: downloader)
        let envBin = tmp.appendingPathComponent("bin/llama-server")
        try? FileManager.default.createDirectory(at: envBin.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? Data("#!/bin/sh\n".utf8).write(to: envBin)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                               ofItemAtPath: envBin.path)
        driver = NativeLlamaCppDriver(
            store: store, spawner: FakeSpawner3(),
            environment: [NativeLlamaCppDriver.envLlamaServer: envBin.path],
            dataRootProvider: { self.tmp }, bundleResourceURL: nil)
        driver.freePort = { 54321 }
        driver.probe = { _ in true }
        driver.sleep = { _ in }
        cfg = CfgBox3([:])
        notify = NotifyLog()
        endpoints = NativeModelPackEndpoints(
            store: store, downloader: downloader, manager: manager, driver: driver,
            configProvider: { [cfg] in cfg?.get() ?? [:] })
        endpoints.notify = { [notify] r, a, e in notify?.add(r, a, e) }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    // MARK: 夹具函数

    private func shaHex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func catalogEntry(_ pid: String, data: Data,
                              source: String) -> [String: JSONValue] {
        [
            "pack_id": .string(pid),
            "name": .string("包 \(pid)"),
            "task": .string("chat"),
            "format": .string("gguf"),
            "driver": .string("llamacpp"),
            "version": .string("1.2.0"),
            "size_bytes": .int(Int64(data.count)),
            "files": .array([.object([
                "path": .string("model.gguf"),
                "size_bytes": .int(Int64(data.count)),
                "sha256": .string(shaHex(data)),
                "sources": .array([.string(source)]),
            ])]),
        ]
    }

    private func seedInstalled(_ pid: String, contextLength: Int? = nil) throws {
        let entry = catalogEntry(pid, data: Data(repeating: 1, count: 4),
                                 source: "https://cdn.example.com/m.gguf")
        try store.registerPack(pid, pack: entry)
        let dir = try store.packDir(pid)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4).write(to: dir.appendingPathComponent("model.gguf"))
        if let cl = contextLength {
            var man = entry
            man["context_length"] = .int(Int64(cl))
            try NativeJSONWriter.dumps(.object(man)).write(
                to: dir.appendingPathComponent("manifest.json"),
                atomically: false, encoding: .utf8)
        }
    }

    private func catalogJSON(_ packs: [[String: JSONValue]]) -> Data {
        Data(NativeJSONWriter.dumps(.object([
            "version": .int(1),
            "packs": .array(packs.map { .object($0) }),
        ])).utf8)
    }

    private func waitUntil(_ timeout: Double = 5, _ cond: @Sendable () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return cond()
    }

    // MARK: - list

    func testListPacksFieldMapping() throws {
        try seedInstalled("pack-a", contextLength: 8192)
        try seedInstalled("pack-b")
        XCTAssertNotNil(store.setEnabled("pack-b", enabled: false))
        let resp = endpoints.listPacks()
        XCTAssertEqual(resp.packs.count, 2)
        let a = resp.packs.first { $0.pack_id == "pack-a" }!
        XCTAssertEqual(a.status, "installed")
        XCTAssertTrue(a.enabled)
        XCTAssertEqual(a.size_bytes, 4)
        XCTAssertEqual(a.context_length, 8192)
        XCTAssertEqual(a.task, "chat")
        let b = resp.packs.first { $0.pack_id == "pack-b" }!
        XCTAssertEqual(b.status, "disabled")
        XCTAssertFalse(b.enabled)
    }

    // MARK: - catalog

    func testCatalogMergeDedupAndAnnotations() async throws {
        try seedInstalled("pack-inst")
        let u1 = "https://cat1.example.com/catalog.json"
        let u2 = "https://cat2.example.com/catalog.json"
        cfg = CfgBox3(["model_pack_catalog_urls": .array([.string(u1), .string(u2)])])
        // 重建 endpoints 以读新 config
        endpoints = NativeModelPackEndpoints(
            store: store, downloader: downloader, manager: manager, driver: driver,
            configProvider: { [cfg] in cfg?.get() ?? [:] })
        endpoints.notify = { [notify] r, a, e in notify?.add(r, a, e) }
        let d = Data(repeating: 1, count: 4)
        transport.scriptGet(u1, status: 200, data: catalogJSON([
            catalogEntry("pack-inst", data: d, source: "https://cdn.example.com/a.gguf"),
            catalogEntry("pack-b", data: d, source: "https://cdn.example.com/b.gguf"),
        ]))
        transport.scriptGet(u2, status: 200, data: catalogJSON([
            catalogEntry("pack-b", data: d, source: "https://cdn.example.com/b2.gguf"),  // 跨源重复
            catalogEntry("pack-c", data: d, source: "https://cdn.example.com/c.gguf"),
        ]))

        let (catalog, raw) = await endpoints.catalog()

        XCTAssertEqual(catalog.sources, 2)
        XCTAssertEqual(catalog.source_errors, [])
        XCTAssertEqual(catalog.packs.map(\.pack_id), ["pack-inst", "pack-b", "pack-c"])
        let inst = catalog.packs[0]
        XCTAssertEqual(inst.installed, true)
        XCTAssertEqual(inst.enabled, true)
        XCTAssertEqual(inst.installed_version, "1.2.0")
        XCTAssertEqual(inst.source, u1)
        let b = catalog.packs[1]
        XCTAssertEqual(b.source, u1)                      // 去重：先出现源生效
        XCTAssertEqual(b.installed, false)
        XCTAssertEqual(b.installed_version, "")
        XCTAssertEqual(catalog.packs[2].source, u2)
        // rawEntries 保住可选键原样回传（含标注键，install 校验时忽略）
        XCTAssertEqual(raw["pack-inst"]?["pack_id"] as? String, "pack-inst")
        XCTAssertNotNil(raw["pack-inst"]?["files"])
        XCTAssertEqual(raw["pack-b"]?["source"] as? String, u1)
    }

    func testCatalogSourceErrorDoesNotDragOthers() async throws {
        let u1 = "https://bad.example.com/catalog.json"
        let u2 = "https://good.example.com/catalog.json"
        let cfgBox = CfgBox3(["model_pack_catalog_urls": .array([.string(u1), .string(u2)])])
        endpoints = NativeModelPackEndpoints(
            store: store, downloader: downloader, manager: manager, driver: driver,
            configProvider: { [cfgBox] in cfgBox.get() })
        endpoints.notify = { [notify] r, a, e in notify?.add(r, a, e) }
        transport.scriptGet(u1, status: 503, data: Data())
        transport.scriptGet(u2, status: 200, data: catalogJSON([
            catalogEntry("pack-x", data: Data(repeating: 1, count: 4),
                         source: "https://cdn.example.com/x.gguf"),
        ]))

        let (catalog, _) = await endpoints.catalog()

        XCTAssertEqual(catalog.sources, 1)
        XCTAssertEqual(catalog.source_errors.count, 1)
        XCTAssertEqual(catalog.source_errors[0].source, u1)
        XCTAssertEqual(catalog.source_errors[0].error, "bad.example.com: HTTP 503")
        XCTAssertEqual(catalog.packs.map(\.pack_id), ["pack-x"])
    }

    func testCatalogEmptyURLs() async {
        let (catalog, raw) = await endpoints.catalog()
        XCTAssertEqual(catalog.packs, [])
        XCTAssertEqual(catalog.sources, 0)
        XCTAssertEqual(catalog.source_errors, [])
        XCTAssertTrue(raw.isEmpty)
    }

    // MARK: - install 400/409 链

    func testInstallPackIdMismatch() {
        let entry = catalogEntry("real-id", data: Data(repeating: 1, count: 4),
                                 source: "https://cdn.example.com/m.gguf")
        XCTAssertThrowsError(try endpoints.install(packId: "other-id", catalogEntry: entry)) { error in
            guard case SidecarError.httpError(let status, let detail) = error else {
                return XCTFail("错误类型不符: \(error)")
            }
            XCTAssertEqual(status, 400)
            XCTAssertEqual(detail, "pack_id 与 catalog_entry.pack_id 不一致")
        }
    }

    func testInstallInvalidSlug() {
        var entry = catalogEntry("Bad_ID", data: Data(repeating: 1, count: 4),
                                 source: "https://cdn.example.com/m.gguf")
        entry["pack_id"] = .string("Bad_ID")
        XCTAssertThrowsError(try endpoints.install(packId: "Bad_ID", catalogEntry: entry)) { error in
            guard case SidecarError.httpError(let status, let detail) = error else {
                return XCTFail("错误类型不符: \(error)")
            }
            XCTAssertEqual(status, 400)
            XCTAssertEqual(detail, "非法 pack_id（须 slug 小写字母/数字/-/_，1~64 长）: 'Bad_ID'")
        }
    }

    func testInstallValidationFailure() {
        var entry = catalogEntry("bad-size", data: Data(repeating: 1, count: 4),
                                 source: "https://cdn.example.com/m.gguf")
        entry["size_bytes"] = .int(999)   // 与 files 之和不一致
        XCTAssertThrowsError(try endpoints.install(packId: "bad-size", catalogEntry: entry)) { error in
            guard case SidecarError.httpError(let status, let detail) = error else {
                return XCTFail("错误类型不符: \(error)")
            }
            XCTAssertEqual(status, 400)
            XCTAssertTrue(detail.hasPrefix("catalog_entry 校验失败: "), detail)
            XCTAssertTrue(detail.contains("size_bytes(999) 与 files 之和(4) 不一致"), detail)
        }
    }

    func testInstallAlreadyInstalled409() throws {
        try seedInstalled("dup-pack")
        let entry = catalogEntry("dup-pack", data: Data(repeating: 1, count: 4),
                                 source: "https://cdn.example.com/m.gguf")
        XCTAssertThrowsError(try endpoints.install(packId: "dup-pack", catalogEntry: entry)) { error in
            guard case SidecarError.httpError(let status, let detail) = error else {
                return XCTFail("错误类型不符: \(error)")
            }
            XCTAssertEqual(status, 409)
            XCTAssertEqual(detail, "模型包 dup-pack 已安装；如需重装请先卸载")
        }
    }

    func testInstallAcceptedAndDuplicate409WhileDownloading() async throws {
        let gate = ChunkGate3()
        let content = Data(repeating: 7, count: 64)
        let url = "https://cdn.example.com/slow.gguf"
        transport.scriptStream(url, status: 200, chunks: [content], gate: gate)
        let entry = catalogEntry("slow-pack", data: content, source: url)

        try endpoints.install(packId: "slow-pack", catalogEntry: entry)   // accepted
        XCTAssertTrue(manager.isActive("slow-pack"))
        XCTAssertEqual(notify.calls.count, 0)   // 端点不重复 notify（事件归下载器）

        XCTAssertThrowsError(try endpoints.install(packId: "slow-pack", catalogEntry: entry)) { error in
            guard case SidecarError.httpError(let status, let detail) = error else {
                return XCTFail("错误类型不符: \(error)")
            }
            XCTAssertEqual(status, 409)
            XCTAssertEqual(detail, "模型包 slow-pack 正在下载中")
        }
        // 收尾：取消放行
        let cancelTask = Task { await self.manager.cancel("slow-pack") }
        try await Task.sleep(nanoseconds: 50_000_000)
        await gate.release(2)
        _ = await cancelTask.value
    }

    // MARK: - cancel

    func testCancelNoTask404() async {
        do {
            try await endpoints.cancel(packId: "ghost")
            XCTFail("应 404")
        } catch let SidecarError.httpError(status, detail) {
            XCTAssertEqual(status, 404)
            XCTAssertEqual(detail, "模型包 ghost 没有进行中的下载任务")
        } catch {
            XCTFail("错误类型不符: \(error)")
        }
    }

    func testCancelSuccessNotifies() async throws {
        let gate = ChunkGate3()
        let content = Data(repeating: 8, count: 64)
        let url = "https://cdn.example.com/cancel.gguf"
        transport.scriptStream(url, status: 200, chunks: [content], gate: gate)
        let entry = catalogEntry("cancel-pack", data: content, source: url)
        try endpoints.install(packId: "cancel-pack", catalogEntry: entry)
        let seen = await waitUntil { self.transport.requested.contains(url) }
        XCTAssertTrue(seen)

        try await endpoints.cancel(packId: "cancel-pack")

        XCTAssertEqual(notify.calls.count, 1)
        XCTAssertEqual(notify.calls[0].resource, "model_pack")
        XCTAssertEqual(notify.calls[0].action, "update")
        XCTAssertEqual(notify.calls[0].extra["pack_id"]?.string, "cancel-pack")
        XCTAssertEqual(notify.calls[0].extra["phase"]?.string, "cancelled")
    }

    // MARK: - delete

    func testDeleteUnknown404() async {
        do {
            try await endpoints.deletePack("ghost")
            XCTFail("应 404")
        } catch let SidecarError.httpError(status, detail) {
            XCTAssertEqual(status, 404)
            XCTAssertEqual(detail, "模型包 ghost 未安装")
        } catch {
            XCTFail("错误类型不符: \(error)")
        }
    }

    func testDeleteRemovesAndNotifies() async throws {
        try seedInstalled("del-pack")
        try await endpoints.deletePack("del-pack")
        XCTAssertNil(store.getEntry("del-pack"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tmp.appendingPathComponent("packs/del-pack").path))
        XCTAssertEqual(notify.calls.last?.action, "delete")
        XCTAssertEqual(notify.calls.last?.extra["pack_id"]?.string, "del-pack")
    }

    func testDeleteCancelsInflightDownloadFirst() async throws {
        let gate = ChunkGate3()
        let content = Data(repeating: 9, count: 64)
        let url = "https://cdn.example.com/inflight.gguf"
        transport.scriptStream(url, status: 200, chunks: [content], gate: gate)
        let entry = catalogEntry("inflight-pack", data: content, source: url)
        try endpoints.install(packId: "inflight-pack", catalogEntry: entry)
        let seen = await waitUntil { self.transport.requested.contains(url) }
        XCTAssertTrue(seen)
        // 在飞下载：dest 目录已建（下载起点）→ remove 成功（Python remove_pack 目录∨
        // 注册表任一存在即 true 同款）——删除成立且取消必先发生
        let deleteTask = Task { try await self.endpoints.deletePack("inflight-pack") }
        try await Task.sleep(nanoseconds: 50_000_000)
        await gate.release(2)
        try await deleteTask.value
        XCTAssertFalse(manager.isActive("inflight-pack"))   // 在飞下载已被取消
        XCTAssertFalse(FileManager.default.fileExists(      // 目录（含 .partial）已删
            atPath: tmp.appendingPathComponent("packs/inflight-pack").path))
        XCTAssertEqual(notify.calls.last?.action, "delete")
        XCTAssertEqual(notify.calls.last?.extra["pack_id"]?.string, "inflight-pack")
    }

    // MARK: - toggle

    func testToggleUnknown404() async {
        do {
            try await endpoints.toggle(packId: "ghost", enabled: false)
            XCTFail("应 404")
        } catch let SidecarError.httpError(status, detail) {
            XCTAssertEqual(status, 404)
            XCTAssertEqual(detail, "模型包 ghost 未安装")
        } catch {
            XCTFail("错误类型不符: \(error)")
        }
    }

    func testToggleDisableReleasesRuntimeAndNotifies() async throws {
        try seedInstalled("live-pack")
        _ = try await driver.ensureServer("live-pack")
        XCTAssertEqual(driver.activePack(), "live-pack")

        try await endpoints.toggle(packId: "live-pack", enabled: false)

        XCTAssertNil(driver.activePack())               // 禁用＝立即停 llama-server
        XCTAssertEqual(store.getEntry("live-pack")?["status"]?.string, "disabled")
        XCTAssertEqual(notify.calls.last?.action, "update")
        XCTAssertEqual(notify.calls.last?.extra["enabled"]?.bool, false)

        try await endpoints.toggle(packId: "live-pack", enabled: true)   // 启用不触发回收
        XCTAssertEqual(store.getEntry("live-pack")?["status"]?.string, "installed")
        XCTAssertEqual(notify.calls.last?.extra["enabled"]?.bool, true)
        XCTAssertNil(driver.activePack())
    }

    // MARK: - ASR 运行时回收（P3-W3b：app.py L2774-2778 asr_driver.unload 同构）

    /// 装一个 ASR 包（三件套；tokens/am.mvn 合法最小集）。
    private func installAsrPackMp(_ packId: String) {
        let pack: [String: JSONValue] = [
            "version": .string("1.0.0"), "task": .string("asr"),
            "format": .string("onnx"), "driver": .string("onnxruntime"),
            "files": .array([
                .object(["path": .string("model_quant.onnx"), "size_bytes": .int(3),
                         "sha256": .string("aa")]),
                .object(["path": .string("am.mvn"), "size_bytes": .int(3),
                         "sha256": .string("bb")]),
                .object(["path": .string("tokens.json"), "size_bytes": .int(3),
                         "sha256": .string("cc")]),
            ]),
        ]
        try! store.registerPack(packId, pack: pack)
        let dir = tmp.appendingPathComponent("packs/\(packId)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("model_quant.onnx").path,
                                       contents: Data([1, 2, 3]))
        FileManager.default.createFile(atPath: dir.appendingPathComponent("tokens.json").path,
                                       contents: Data(#"["<blk>","▁你"]"#.utf8))
        let vals = (0..<560).map { _ in "0.25" }.joined(separator: " ")
        let mvn = "<Nnet> \n<Splice> 560 560\n[ 0 ]\n"
            + "<AddShift> 560 560 \n<LearnRateCoef> 0 [ \(vals) ]\n"
            + "<Rescale> 560 560 \n<LearnRateCoef> 0 [ \(vals) ]\n"
        FileManager.default.createFile(atPath: dir.appendingPathComponent("am.mvn").path,
                                       contents: Data(mvn.utf8))
        FileManager.default.createFile(atPath: dir.appendingPathComponent("manifest.json").path,
                                       contents: Data("{\"pack_id\": \"\(packId)\"}".utf8))
    }

    private func makeAsrDriver() -> NativeAsrDriver {
        let d = NativeAsrDriver(store: store, environment: [:],
                                dataRootProvider: { self.tmp }, bundleResourceURL: nil)
        d.sessionFactoryProvider = { FakeAsrFactoryMp() }
        d.decodeAudio = { _, _ in ([Float](repeating: 0.01, count: 16000), 1.0) }
        return d
    }

    func testToggleDisableReleasesAsrSession() async throws {
        installAsrPackMp("sv")
        let asr = makeAsrDriver()
        endpoints.asrDriver = asr
        _ = try asr.transcribe(path: URL(fileURLWithPath: "/tmp/x.wav"))
        XCTAssertEqual(asr.loadedPackId, "sv", "转写后 session 应已装载")

        try await endpoints.toggle(packId: "sv", enabled: false)

        XCTAssertNil(asr.loadedPackId,
                     "禁用＝立即回收 ASR onnx session（app.py L2774-2778 asr_driver.unload）")
        // 不匹配防护：换一个包装载后禁别的包不得误卸（unload 的 pack_id 匹配语义）
        installAsrPackMp("sv2")
        _ = try asr.transcribe(path: URL(fileURLWithPath: "/tmp/x.wav"))
        XCTAssertEqual(asr.loadedPackId, "sv2")
        try await endpoints.toggle(packId: "sv", enabled: true)   // sv 启用不回收
        try await endpoints.toggle(packId: "sv2", enabled: false) // sv2 匹配回收
        XCTAssertNil(asr.loadedPackId)
    }

    func testDeleteReleasesAsrSession() async throws {
        installAsrPackMp("sv")
        let asr = makeAsrDriver()
        endpoints.asrDriver = asr
        _ = try asr.transcribe(path: URL(fileURLWithPath: "/tmp/x.wav"))
        XCTAssertEqual(asr.loadedPackId, "sv")

        try await endpoints.deletePack("sv")

        XCTAssertNil(asr.loadedPackId, "卸载＝回收 ASR onnx session")
        XCTAssertNil(store.getEntry("sv"))
        XCTAssertEqual(notify.calls.last?.action, "delete")
    }
}

// MARK: - ASR 假会话（P3-W3b；与 NativeAsrDriverTests 夹具同形，文件私有）

private final class FakeAsrSessionMp: NativeAsrSenseVoiceSession, @unchecked Sendable {
    func runSenseVoice(speech: [Float], frames: Int,
                       language: Int32, textnorm: Int32) throws -> NativeAsrSenseVoiceOutput {
        .init(logits: [0, 1], outFrames: 1, vocab: 2, outLen: 1)
    }
}

private struct FakeAsrFactoryMp: NativeAsrSessionFactory {
    func makeSession(onnxPath: URL) throws -> any NativeAsrSenseVoiceSession { FakeAsrSessionMp() }
}
