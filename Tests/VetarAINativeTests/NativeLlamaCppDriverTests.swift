//
//  NativeLlamaCppDriverTests.swift
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

//  逐条锚定（⛔ 行为规格源 subagent/sidecar/model_packs/llamacpp_driver.py，440 行）：
//    · 二进制三态解析链：bundle Resources/drivers > env > dataRoot/drivers
//      （P3-W6④ 翻转——bundle 最高，数据根兜底）；env 非法回退；
//      is_file+可执行门禁；找不到中文明细含「已查找」列表
//    · 注册表门禁：未安装/已禁用中文明细；失效包是活动服务对象先停再抛
//    · GGUF 缺失两类（清单无 .gguf / 磁盘缺文件）逐字文案
//    · 同包同档复用 / 同包异档重启（-c 换档）/ 异包换装停旧启新（顺序断言）
//    · ctx 优先级：显式 > manifest context_length > 不带 -c
//    · 启动失败两类：早死（exit 码+日志尾巴）/ 超时（钳后秒数+日志尾巴），均回收现场
//    · 停止双防护：已死不动作；SIGTERM 宽限 → SIGKILL；stop 名字匹配防护
//    · 子进程 env 剥离 6 代理键保留其余；boot timeout 钳 [10,7200] 默认 600
//
//  全程不要求真模型/真进程：FakeProc + FakeSpawner 缝注入，健康探测/时钟/睡眠全缝。
//

import XCTest
@testable import VetarAINative

// MARK: - 假进程 / 假 spawner / 顺序录证

private final class FakeProc: NativeLlamaServerProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var running: Bool
    private var exit: Int32?
    private(set) var terminateCount = 0
    private(set) var killCount = 0
    var exitOnTerminate = true
    var onTerminate: (@Sendable () -> Void)?

    init(running: Bool = true, exit: Int32? = nil) {
        self.running = running
        self.exit = exit
    }
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    var exitCode: Int32? {
        lock.lock(); defer { lock.unlock() }
        return running ? nil : exit
    }
    func terminate() {
        lock.lock()
        terminateCount += 1
        if exitOnTerminate { running = false; exit = 0 }
        lock.unlock()
        onTerminate?()
    }
    func kill() {
        lock.lock()
        killCount += 1
        running = false
        exit = -9
        lock.unlock()
    }
    func die(exit code: Int32 = 0) {   // 模拟进程自行退出
        lock.lock(); running = false; exit = code; lock.unlock()
    }
    func untrack() {}
    func wait(timeout: Double) async -> Bool { !isRunning }
}

private final class FakeSpawner: NativeLlamaSpawner, @unchecked Sendable {
    private let lock = NSLock()
    var queue: [FakeProc] = []
    private(set) var calls: [[String]] = []
    private(set) var envs: [[String: String]] = []
    var logText: String?
    var onSpawn: (@Sendable () -> Void)?

    func spawn(argv: [String], env: [String: String], log: FileHandle) throws
        -> any NativeLlamaServerProcess {
        lock.lock()
        calls.append(argv)
        envs.append(env)
        let text = logText
        let proc = queue.isEmpty ? FakeProc() : queue.removeFirst()
        lock.unlock()
        if let text {
            try? log.write(contentsOf: Data(text.utf8))
            try? log.synchronize()
        }
        onSpawn?()
        return proc
    }
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls.count }
}

private final class OrderLog: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var items: [String] = []
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
}

private final class ClockBox2: @unchecked Sendable {
    private let lock = NSLock()
    private var t = 0.0
    func advance(_ d: Double) { lock.lock(); t += d; lock.unlock() }
    func now() -> Double { lock.lock(); defer { lock.unlock() }; return t }
}

final class NativeLlamaCppDriverTests: XCTestCase {

    private var tmp: URL!
    private var store: NativeModelPackStore!
    private var spawner: FakeSpawner!
    private var driver: NativeLlamaCppDriver!
    private var envBin: URL!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("llama_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        store = NativeModelPackStore(
            configProvider: { [:] },
            dataRootProvider: { self.tmp },
            environment: [NativeModelPackStore.envPacksDir: self.tmp.appendingPathComponent("packs").path])
        spawner = FakeSpawner()
        envBin = tmp.appendingPathComponent("bin/llama-server")
        try? FileManager.default.createDirectory(
            at: envBin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? makeExec(envBin)
        driver = NativeLlamaCppDriver(
            store: store,
            spawner: spawner,
            environment: [NativeLlamaCppDriver.envLlamaServer: envBin.path,
                          "HTTP_PROXY": "http://proxy:7890", "https_proxy": "http://proxy:7890",
                          "ALL_PROXY": "socks5://proxy:1080", "all_proxy": "socks5://proxy:1080",
                          "http_proxy": "http://proxy:7890", "HTTPS_PROXY": "http://proxy:7890",
                          "CUSTOM_KEEP": "1"],
            dataRootProvider: { self.tmp },
            configProvider: { [:] },
            bundleResourceURL: nil)
        driver.freePort = { 54321 }
        driver.probe = { _ in true }
        driver.sleep = { _ in }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    // MARK: 夹具

    private func makeExec(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: url.path)
    }

    @discardableResult
    private func seedPack(_ pid: String, ggufInManifest: Bool = true,
                          ggufOnDisk: Bool = true,
                          contextLength: Int? = nil) throws -> URL {
        let rel = ggufInManifest ? "model.gguf" : "notes.txt"
        let pack: [String: JSONValue] = [
            "pack_id": .string(pid),
            "task": .string("chat"),
            "format": .string("gguf"),
            "driver": .string("llamacpp"),
            "version": .string("1.0.0"),
            "size_bytes": .int(4),
            "files": .array([.object([
                "path": .string(rel),
                "size_bytes": .int(4),
                "sha256": .string(String(repeating: "a", count: 64)),
            ])]),
        ]
        try store.registerPack(pid, pack: pack)
        let dir = try store.packDir(pid)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if ggufInManifest && ggufOnDisk {
            try Data(repeating: 1, count: 4).write(to: dir.appendingPathComponent(rel))
        }
        if let cl = contextLength {
            var man = pack
            man["context_length"] = .int(Int64(cl))
            try NativeJSONWriter.dumps(.object(man)).write(
                to: dir.appendingPathComponent("manifest.json"),
                atomically: false, encoding: .utf8)
        }
        return dir
    }

    // MARK: - 二进制解析链（P3-W6④：bundle > env > dataRoot）

    func testResolveBinaryBundleFirst() throws {
        // 三候选全在（env 置位 + dataRoot 有 + bundle 有）→ bundle 最高优先
        let dataRootBin = tmp.appendingPathComponent("drivers/llama-server")
        try makeExec(dataRootBin)
        let bundleRes = tmp.appendingPathComponent("Bundle/Contents/Resources")
        let bundleBin = bundleRes.appendingPathComponent("drivers/llama-server")
        try makeExec(bundleBin)
        driver.bundleResourceURL = bundleRes
        XCTAssertEqual(try driver.resolveServerBinary().path, bundleBin.path)   // bundle 优先
    }

    func testResolveBinaryEnvWinsWhenBundleAbsent() throws {
        let dataRootBin = tmp.appendingPathComponent("drivers/llama-server")
        try makeExec(dataRootBin)
        XCTAssertEqual(try driver.resolveServerBinary().path, envBin.path)   // 无 bundle → env 优先
    }

    func testResolveBinaryEnvInvalidFallsToDataRoot() throws {
        driver.environment[NativeLlamaCppDriver.envLlamaServer] = "/nonexistent/llama-server"
        let dataRootBin = tmp.appendingPathComponent("drivers/llama-server")
        try makeExec(dataRootBin)
        XCTAssertEqual(try driver.resolveServerBinary().path, dataRootBin.path)
    }

    func testResolveBinaryBundleNonExecutableFallsToDataRoot() throws {
        // env 置空；bundle 候选存在但不可执行 → 跳过，落到 dataRoot 兜底
        driver.environment.removeValue(forKey: NativeLlamaCppDriver.envLlamaServer)
        let dataRootBin = tmp.appendingPathComponent("drivers/llama-server")
        try makeExec(dataRootBin)
        let bundleRes = tmp.appendingPathComponent("Bundle/Contents/Resources")
        let bundleBin = bundleRes.appendingPathComponent("drivers/llama-server")
        try makeExec(bundleBin)
        try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                              ofItemAtPath: bundleBin.path)
        driver.bundleResourceURL = bundleRes
        XCTAssertEqual(try driver.resolveServerBinary().path, dataRootBin.path)
    }

    func testResolveBinaryNoneListsCandidates() {
        driver.environment.removeValue(forKey: NativeLlamaCppDriver.envLlamaServer)
        driver.bundleResourceURL = tmp.appendingPathComponent("Bundle/Resources")
        XCTAssertThrowsError(try driver.resolveServerBinary()) { error in
            let msg = (error as? NativeLlamaServerError)?.message ?? ""
            XCTAssertTrue(msg.contains("未找到 llama-server 二进制"), msg)
            XCTAssertTrue(msg.contains("VETARAI_LLAMA_SERVER"), msg)
            XCTAssertTrue(msg.contains("已查找: "), msg)
            XCTAssertTrue(msg.contains("、"), msg)   // 多候选顿号连接
            XCTAssertTrue(msg.contains("drivers/llama-server"), msg)
        }
    }

    // MARK: - 注册表门禁

    func testGateUninstalledMessage() async {
        await XCTAssertAsyncThrowsNativeLlama(try await driver.ensureServer("ghost-pack")) { msg in
            XCTAssertEqual(msg, "模型包 'ghost-pack' 未安装。请到「模型包」面板安装后再对话。")
        }
    }

    func testGateDisabledStopsActiveThenThrows() async throws {
        try seedPack("pack-a")
        let proc = FakeProc()
        spawner.queue = [proc]
        _ = try await driver.ensureServer("pack-a")
        XCTAssertEqual(driver.activePack(), "pack-a")
        XCTAssertNotNil(store.setEnabled("pack-a", enabled: false))   // 禁用持久化成功
        await XCTAssertAsyncThrowsNativeLlama(try await driver.ensureServer("pack-a")) { msg in
            XCTAssertEqual(msg, "模型包 'pack-a' 已禁用。请到「模型包」面板启用后再对话。")
        }
        // 失效包正是活动服务对象：先回收子进程再抛
        XCTAssertEqual(proc.terminateCount, 1)
        XCTAssertNil(driver.activePack())
    }

    // MARK: - GGUF 解析

    func testGGUFMissingInManifest() async throws {
        try seedPack("no-gguf", ggufInManifest: false)
        await XCTAssertAsyncThrowsNativeLlama(try await driver.ensureServer("no-gguf")) { msg in
            XCTAssertTrue(msg.contains("的清单中没有 .gguf 权重文件"), msg)
        }
    }

    func testGGUFMissingOnDisk() async throws {
        try seedPack("lost-gguf", ggufOnDisk: false)
        await XCTAssertAsyncThrowsNativeLlama(try await driver.ensureServer("lost-gguf")) { msg in
            XCTAssertTrue(msg.contains("的权重文件缺失: model.gguf"), msg)
            XCTAssertTrue(msg.contains("重新安装"), msg)
        }
    }

    // MARK: - ensure 复用 / 异档重启 / 换装

    func testEnsureSuccessReuseArgvAndEnvStrip() async throws {
        try seedPack("qwen-a")
        let url1 = try await driver.ensureServer("qwen-a", contextLength: 4096)
        XCTAssertEqual(url1, "http://127.0.0.1:54321/v1")
        XCTAssertEqual(driver.activePack(), "qwen-a")
        XCTAssertEqual(driver.activeBaseURL(), url1)
        // argv：--model/--port/--host 127.0.0.1/-c 4096
        let argv = spawner.calls[0]
        XCTAssertEqual(argv[0], envBin.path)
        XCTAssertEqual(Array(argv[1...2]), ["--model", try store.packDir("qwen-a")
            .appendingPathComponent("model.gguf").path])
        XCTAssertTrue(argv.contains("--port") && argv.contains("54321"))
        XCTAssertTrue(argv.contains("--host") && argv.contains("127.0.0.1"))
        XCTAssertEqual(Array(argv.suffix(2)), ["-c", "4096"])
        // 子进程 env：6 代理键剥离，其余保留
        let env = spawner.envs[0]
        for k in NativeLlamaCppDriver.proxyEnvKeys { XCTAssertNil(env[k], k) }
        XCTAssertEqual(env["CUSTOM_KEEP"], "1")
        // 同包同档复用：不起第二个进程
        let url2 = try await driver.ensureServer("qwen-a", contextLength: 4096)
        XCTAssertEqual(url2, url1)
        XCTAssertEqual(spawner.callCount, 1)
    }

    func testEnsureSamePackDifferentCtxRestarts() async throws {
        try seedPack("qwen-b")
        _ = try await driver.ensureServer("qwen-b", contextLength: 4096)
        _ = try await driver.ensureServer("qwen-b", contextLength: 8192)   // 懒加载升档
        XCTAssertEqual(spawner.callCount, 2)                               // 停旧启新
        XCTAssertEqual(Array(spawner.calls[1].suffix(2)), ["-c", "8192"])
        let url = try await driver.ensureServer("qwen-b", contextLength: 8192)
        XCTAssertEqual(url, "http://127.0.0.1:54321/v1")
        XCTAssertEqual(spawner.callCount, 2)                               // 新档复用
    }

    func testSwapPackStopsOldBeforeSpawningNew() async throws {
        try seedPack("pack-old")
        try seedPack("pack-new")
        let order = OrderLog()
        let oldProc = FakeProc()
        oldProc.onTerminate = { order.add("term:old") }
        spawner.queue = [oldProc]
        spawner.onSpawn = { order.add("spawn") }
        _ = try await driver.ensureServer("pack-old")
        _ = try await driver.ensureServer("pack-new")
        XCTAssertEqual(order.items, ["spawn", "term:old", "spawn"])   // 停旧先于启新
        XCTAssertEqual(oldProc.terminateCount, 1)
        XCTAssertEqual(driver.activePack(), "pack-new")
    }

    // MARK: - ctx 优先级

    func testCtxPriorityExplicitOverManifestOverDefault() async throws {
        try seedPack("ctx-pack", contextLength: 2048)
        _ = try await driver.ensureServer("ctx-pack")                 // manifest 2048
        XCTAssertEqual(Array(spawner.calls[0].suffix(2)), ["-c", "2048"])
        _ = try await driver.ensureServer("ctx-pack", contextLength: 8192)  // 显式覆盖
        XCTAssertEqual(Array(spawner.calls[1].suffix(2)), ["-c", "8192"])
    }

    func testNoCtxAnywhereOmitsDashC() async throws {
        try seedPack("plain-pack")
        _ = try await driver.ensureServer("plain-pack")
        XCTAssertFalse(spawner.calls[0].contains("-c"))
        // 再带档 → 异档重启
        _ = try await driver.ensureServer("plain-pack", contextLength: 1024)
        XCTAssertEqual(spawner.callCount, 2)
        XCTAssertEqual(Array(spawner.calls[1].suffix(2)), ["-c", "1024"])
    }

    // MARK: - 启动失败

    func testEarlyExitErrorCarriesLogTailAndCleansUp() async throws {
        try seedPack("die-pack")
        spawner.queue = [FakeProc(running: false, exit: 3)]
        spawner.logText = "gguf 损坏无法加载"
        await XCTAssertAsyncThrowsNativeLlama(try await driver.ensureServer("die-pack")) { msg in
            XCTAssertTrue(msg.contains("llama-server 启动后立即退出（exit=3）"), msg)
            XCTAssertTrue(msg.contains("gguf 损坏无法加载"), msg)
        }
        XCTAssertNil(driver.activePack())   // 现场已回收
    }

    func testBootTimeoutErrorAndCleanup() async throws {
        try seedPack("slow-pack")
        let clock = ClockBox2()
        let slowProc = FakeProc()
        spawner.queue = [slowProc]
        driver.now = { clock.now() }
        driver.sleep = { ns in clock.advance(Double(ns) / 1_000_000_000) }
        driver.probe = { _ in false }
        driver.configProvider = { ["model_pack_boot_timeout_s": .int(10)] }
        await XCTAssertAsyncThrowsNativeLlama(try await driver.ensureServer("slow-pack")) { msg in
            XCTAssertTrue(msg.contains("llama-server 启动超时（10s 内 /v1/models 未就绪）"), msg)
            XCTAssertTrue(msg.contains("日志尾巴："), msg)
        }
        XCTAssertEqual(slowProc.terminateCount, 1)   // 启动失败回收现场
        XCTAssertNil(driver.activePack())
    }

    // MARK: - 停止

    func testStopServerNameMatchGuard() async throws {
        try seedPack("pack-s")
        _ = try await driver.ensureServer("pack-s")
        let stopped = await driver.stopServer("other-pack")
        XCTAssertFalse(stopped)                       // 不匹配 = 不动
        XCTAssertEqual(driver.activePack(), "pack-s")
        let stopped2 = await driver.stopServer("pack-s")
        XCTAssertTrue(stopped2)
        XCTAssertNil(driver.activePack())
        let stopped3 = await driver.stopServer()      // 本无活动
        XCTAssertFalse(stopped3)
    }

    func testStopAlreadyDeadProcSkipsTerminate() async throws {
        try seedPack("pack-d")
        let proc = FakeProc()
        spawner.queue = [proc]
        _ = try await driver.ensureServer("pack-d")
        proc.die(exit: 0)                              // 进程自行退出
        let stopped = await driver.stopServer()
        XCTAssertTrue(stopped)
        XCTAssertEqual(proc.terminateCount, 0)         // 防护①：已死不动作
        XCTAssertNil(driver.activePack())
    }

    func testStopSigkillAfterGrace() async throws {
        try seedPack("pack-k")
        let proc = FakeProc()
        proc.exitOnTerminate = false                   // SIGTERM 无效
        spawner.queue = [proc]
        _ = try await driver.ensureServer("pack-k")
        driver.terminateGrace = 0.01                   // 收窄宽限（Python 同款注释语义）
        driver.killWait = 0.01
        let stopped = await driver.stopServer()
        XCTAssertTrue(stopped)
        XCTAssertEqual(proc.terminateCount, 1)
        XCTAssertEqual(proc.killCount, 1)              // 宽限内未死 → 补 SIGKILL
    }

    // MARK: - boot timeout 钳制

    func testBootTimeoutClamp() {
        driver.configProvider = { [:] }
        XCTAssertEqual(driver.bootTimeout(), 600)
        driver.configProvider = { ["model_pack_boot_timeout_s": .int(5)] }
        XCTAssertEqual(driver.bootTimeout(), 10)       // 下钳
        driver.configProvider = { ["model_pack_boot_timeout_s": .int(99999)] }
        XCTAssertEqual(driver.bootTimeout(), 7200)     // 上钳
        driver.configProvider = { ["model_pack_boot_timeout_s": .double(120.5)] }
        XCTAssertEqual(driver.bootTimeout(), 120.5)
        driver.configProvider = { ["model_pack_boot_timeout_s": .int(0)] }
        XCTAssertEqual(driver.bootTimeout(), 600)      // falsy 回落默认
    }
}

// MARK: - async 抛错断言助手

private func XCTAssertAsyncThrowsNativeLlama(
    _ expression: @autoclosure () async throws -> String,
    _ assert: (String) -> Void,
    file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("应抛 NativeLlamaServerError", file: file, line: line)
    } catch let e as NativeLlamaServerError {
        assert(e.message)
    } catch {
        XCTFail("错误类型不符: \(error)", file: file, line: line)
    }
}
