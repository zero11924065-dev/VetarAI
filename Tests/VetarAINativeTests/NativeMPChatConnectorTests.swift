//
//  NativeMPChatConnectorTests.swift
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

//  逐条锚定（⛔ 行为规格源 subagent/sidecar/model_packs/mp_connector.py 127 行
//  + sidecar/ollama/routing.py L95-162 + agent_engine/loop.py:153-177）：
//    · chat/chat_stream 前置 ensure_running：tier 显式 backend="model_package"
//      （config 后端是 openai_compatible 也按 MP 行算档）；LlamaServerError →
//      openAI(400, 中文明细)；ensure 先于任何协议请求（顺序录证）
//    · list_models 注册表聚合（chat+enabled；size=磁盘字节；context_length 真值
//      才带）；capabilities 逐键；unload_model=stop_server；list_loaded=[active]
//    · degraded（model_package）全走 MP 且 preSwapToPack 跳过；_is_chat_pack
//      any_status 两档；route_to_pack 两后端
//    · 方向① preSwapToPack：驻留逐个 safeUnload（ps 复核 + tag 兼容 + 双超时
//      + 失败静默）；方向② preSwapToActive：活动包在跑先停（失败不阻断）
//
//  全程不触网不要求真进程：FakeProc/FakeSpawner + FakeMPTransport 缝注入。
//

import XCTest
@testable import VetarAINative

// MARK: - 夹具（假进程/假 spawner/假 OpenAI 传输/配置盒）

private final class FakeProc2: NativeLlamaServerProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    var onTerminate: (@Sendable () -> Void)?
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    var exitCode: Int32? { isRunning ? nil : 0 }
    func terminate() {
        lock.lock(); running = false; lock.unlock()
        onTerminate?()
    }
    func kill() { lock.lock(); running = false; lock.unlock() }
    func wait(timeout: Double) async -> Bool { !isRunning }
    func untrack() {}
}

private final class FakeSpawner2: NativeLlamaSpawner, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var argvs: [[String]] = []
    var onSpawn: (@Sendable () -> Void)?
    func spawn(argv: [String], env: [String: String], log: FileHandle) throws
        -> any NativeLlamaServerProcess {
        lock.lock(); argvs.append(argv); lock.unlock()
        onSpawn?()
        return FakeProc2()
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return argvs.count }
}

private final class FakeMPOpenAITransport: NativeOpenAITransport, @unchecked Sendable {
    enum Step {
        case stream(Int, [String])
        case post(Int, String)
    }
    private let lock = NSLock()
    private var steps: [Step]
    private(set) var requests: [String] = []
    var onRequest: (@Sendable () -> Void)?
    init(_ steps: [Step]) { self.steps = steps }

    func streamLines(_ req: URLRequest) async throws
        -> (status: Int, lines: AsyncThrowingStream<String, Error>) {
        lock.lock()
        requests.append(req.url?.absoluteString ?? "")
        let step = steps.isEmpty ? nil : steps.removeFirst()
        lock.unlock()
        onRequest?()
        guard case .stream(let status, let lines) = step else { throw URLError(.badURL) }
        return (status, AsyncThrowingStream { cont in
            for l in lines { cont.yield(l) }
            cont.finish()
        })
    }

    func postJSON(_ req: URLRequest) async throws -> (status: Int, data: Data) {
        lock.lock()
        requests.append(req.url?.absoluteString ?? "")
        let step = steps.isEmpty ? nil : steps.removeFirst()
        lock.unlock()
        onRequest?()
        guard case .post(let status, let body) = step else { throw URLError(.badURL) }
        return (status, Data(body.utf8))
    }
}

private final class CfgBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cfg: [String: JSONValue]
    init(_ c: [String: JSONValue]) { cfg = c }
    func get() -> [String: JSONValue] { lock.lock(); defer { lock.unlock() }; return cfg }
    func set(_ k: String, _ v: JSONValue) { lock.lock(); cfg[k] = v; lock.unlock() }
}

private final class OrderLog2: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var items: [String] = []
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
}

final class NativeMPChatConnectorTests: XCTestCase {

    private var tmp: URL!
    private var store: NativeModelPackStore!
    private var cfg: CfgBox!
    private var spawner: FakeSpawner2!
    private var driver: NativeLlamaCppDriver!
    private var tiers: NativeLazyCtxTiers!
    private var envBin: URL!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mpconn_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        store = NativeModelPackStore(
            configProvider: { [:] },
            dataRootProvider: { self.tmp },
            environment: [NativeModelPackStore.envPacksDir: self.tmp.appendingPathComponent("packs").path])
        cfg = CfgBox(["inference_backend": .string("ollama")])
        spawner = FakeSpawner2()
        envBin = tmp.appendingPathComponent("bin/llama-server")
        try? FileManager.default.createDirectory(at: envBin.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? Data("#!/bin/sh\n".utf8).write(to: envBin)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                               ofItemAtPath: envBin.path)
        driver = NativeLlamaCppDriver(
            store: store, spawner: spawner,
            environment: [NativeLlamaCppDriver.envLlamaServer: envBin.path],
            dataRootProvider: { self.tmp },
            configProvider: { [cfg] in cfg?.get() ?? [:] },
            bundleResourceURL: nil)
        driver.freePort = { 54321 }
        driver.probe = { _ in true }
        driver.sleep = { _ in }
        tiers = NativeLazyCtxTiers(configProvider: { [cfg] in cfg?.get() ?? [:] })
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    // MARK: 夹具函数

    private func seedPack(_ pid: String, task: String = "chat",
                          contextLength: Int? = nil) throws {
        let pack: [String: JSONValue] = [
            "pack_id": .string(pid), "task": .string(task),
            "format": .string("gguf"), "driver": .string("llamacpp"),
            "version": .string("1.0.0"), "size_bytes": .int(4),
            "files": .array([.object([
                "path": .string("model.gguf"), "size_bytes": .int(4),
                "sha256": .string(String(repeating: "a", count: 64)),
            ])]),
        ]
        try store.registerPack(pid, pack: pack)
        let dir = try store.packDir(pid)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4).write(to: dir.appendingPathComponent("model.gguf"))
        if let cl = contextLength {
            var man = pack
            man["context_length"] = .int(Int64(cl))
            try NativeJSONWriter.dumps(.object(man)).write(
                to: dir.appendingPathComponent("manifest.json"),
                atomically: false, encoding: .utf8)
        }
    }

    private func makeConnector(_ transport: FakeMPOpenAITransport) -> NativeMPChatConnector {
        NativeMPChatConnector(
            driver: driver, store: store, tiers: tiers,
            configProvider: { [cfg] in cfg?.get() ?? [:] },
            guard: NativeNetworkGuard(), transport: transport)
    }

    private func makeRouter(
        loaded: (@Sendable () async throws -> [String])? = nil,
        unload: (@Sendable (String) async throws -> Bool)? = nil
    ) -> NativeModelPackRouter {
        NativeModelPackRouter(
            store: store, driver: driver,
            configProvider: { [cfg] in cfg?.get() ?? [:] },
            activeLoadedModels: loaded, activeUnload: unload)
    }

    // MARK: - MP 连接器

    func testChatStreamEnsuresTierThenStreams() async throws {
        try seedPack("qwen-mp")
        // config 后端故意 openai_compatible：显式 "model_package" 参仍按 MP 行算档
        cfg.set("inference_backend", .string("openai_compatible"))
        cfg.set("model_options", .object(["qwen-mp": .object(["num_ctx": .int(4096)])]))
        let order = OrderLog2()
        spawner.onSpawn = { order.add("spawn") }
        let transport = FakeMPOpenAITransport([.stream(200, [
            #"data: {"choices":[{"delta":{"content":"你"}}]}"#,
            #"data: {"choices":[{"delta":{"content":"好"}}],"usage":{"prompt_tokens":3,"completion_tokens":2}}"#,
            "data: [DONE]",
        ])])
        transport.onRequest = { order.add("request") }
        let conn = makeConnector(transport)

        var events: [NativeChatStreamEvent] = []
        for try await ev in conn.chatStream(model: "qwen-mp",
                                            messages: [["role": .string("user"),
                                                        "content": .string("hi")]],
                                            tools: nil, images: nil) {
            events.append(ev)
        }

        XCTAssertEqual(order.items, ["spawn", "request"])   // ensure 先于协议请求
        XCTAssertEqual(events, [.contentDelta("你"), .contentDelta("好"),
                                .done(promptEvalCount: 3, evalCount: 2)])
        // 懒加载档：min(12288, 4096) = 4096 → 驱动 -c 4096
        XCTAssertEqual(Array(spawner.argvs[0].suffix(2)), ["-c", "4096"])
        // 回环地址 + 无 Bearer（inference_api_key 置空）
        XCTAssertEqual(transport.requests.first, "http://127.0.0.1:54321/v1/chat/completions")
    }

    func testChatStreamEnsureFailureMapsOpenAI400() async throws {
        let transport = FakeMPOpenAITransport([])
        let conn = makeConnector(transport)
        do {
            for try await _ in conn.chatStream(model: "ghost",
                                               messages: [["role": .string("user"),
                                                           "content": .string("hi")]],
                                               tools: nil, images: nil) {}
            XCTFail("应抛 openAI 400")
        } catch let NativeChatConnectorError.openAI(status, message, detail) {
            XCTAssertEqual(status, 400)
            XCTAssertEqual(message, "模型包 'ghost' 未安装。请到「模型包」面板安装后再对话。")
            XCTAssertEqual(detail, "")
        }
        XCTAssertEqual(transport.requests.count, 0)   // 未发任何协议请求
    }

    func testChatNonStreamEnsuresThenPosts() async throws {
        try seedPack("chat-pack")
        let order = OrderLog2()
        spawner.onSpawn = { order.add("spawn") }
        let transport = FakeMPOpenAITransport([.post(200, #"{"choices":[{"message":{"content":"答"}}]}"#)])
        transport.onRequest = { order.add("request") }
        let conn = makeConnector(transport)
        let text = try await conn.chat(model: "chat-pack",
                                       messages: [["role": .string("user"),
                                                   "content": .string("hi")]])
        XCTAssertEqual(text, "答")
        XCTAssertEqual(order.items, ["spawn", "request"])
    }

    func testListModelsRegistryAggregate() async throws {
        try seedPack("chat-on", contextLength: 8192)
        try seedPack("chat-off")
        try seedPack("asr-pack", task: "asr")
        XCTAssertNotNil(store.setEnabled("chat-off", enabled: false))
        let conn = makeConnector(FakeMPOpenAITransport([]))
        let models = conn.listModels()
        XCTAssertEqual(models.count, 1)
        let m = models[0]
        XCTAssertEqual(m["name"]?.string, "chat-on")
        XCTAssertEqual(m["size"]?.int, 4)                       // 磁盘实际字节
        XCTAssertEqual(m["source"]?.string, "model_pack")
        XCTAssertEqual(m["context_length"]?.int, 8192)          // 真值才带
        // 未声明 context_length 的包不带该键（另断言于 chat-off 被排除）
    }

    func testCapabilitiesExact() {
        let conn = makeConnector(FakeMPOpenAITransport([]))
        XCTAssertEqual(conn.capabilities(),
                       ["backend": .string("model_package"), "tools": .bool(true),
                        "vision": .bool(false), "pull": .bool(false), "delete": .bool(false)])
    }

    func testUnloadAndListLoaded() async throws {
        try seedPack("loaded-pack")
        let conn = makeConnector(FakeMPOpenAITransport([]))
        _ = try await driver.ensureServer("loaded-pack")
        XCTAssertEqual(conn.listLoadedModels(), ["loaded-pack"])
        let mismatch = await conn.unloadModel("other-pack")
        XCTAssertFalse(mismatch)                                // 名字匹配防护
        XCTAssertEqual(conn.listLoadedModels(), ["loaded-pack"])
        let ok = await conn.unloadModel("loaded-pack")
        XCTAssertTrue(ok)
        XCTAssertEqual(conn.listLoadedModels(), [])
    }

    // MARK: - 路由判定

    func testDegradedRoutesAllToPack() async {
        cfg.set("inference_backend", .string("model_package"))
        var psCalls = 0
        let router = makeRouter(loaded: { psCalls += 1; return ["m"] })
        XCTAssertTrue(router.degraded())
        XCTAssertTrue(router.routeToPack("任意模型"))            // 退化全走 MP
        await router.preSwapToPack()
        XCTAssertEqual(psCalls, 0)                               // 退化跳过编排
    }

    func testIsChatPackStates() throws {
        try seedPack("chat-on")
        try seedPack("chat-off")
        try seedPack("asr-pack", task: "asr")
        XCTAssertNotNil(store.setEnabled("chat-off", enabled: false))
        let router = makeRouter()
        XCTAssertTrue(router.isChatPack("chat-on"))
        XCTAssertFalse(router.isChatPack("chat-off"))            // 禁用不参与对话路由
        XCTAssertTrue(router.isChatPack("chat-off", anyStatus: true))  // 卸载路由含禁用
        XCTAssertFalse(router.isChatPack("asr-pack"))            // 非 chat 任务
        XCTAssertFalse(router.isChatPack("unknown"))
        XCTAssertFalse(router.isChatPack(""))
        // 命中即路由（活动后端是 openai 也一样）
        cfg.set("inference_backend", .string("openai_compatible"))
        XCTAssertTrue(router.routeToPack("chat-on"))
        XCTAssertFalse(router.routeToPack("qwen3"))
    }

    // MARK: - 换装编排

    func testPreSwapToPackUnloadsResidentWithTagCompat() async {
        let order = OrderLog2()
        var psCalls = 0
        var unloaded: [String] = []
        let router = makeRouter(
            loaded: {
                psCalls += 1
                order.add("ps")
                return ["glm-ocr:latest", "qwen3"]
            },
            unload: { name in
                order.add("unload:\(name)")
                unloaded.append(name)
                return true
            })
        await router.preSwapToPack()
        // 逐个 safeUnload（每个内部 ps 复核一次）：ps 1+2 次；tag 兼容命中
        XCTAssertEqual(psCalls, 3)
        XCTAssertEqual(Set(unloaded), ["glm-ocr:latest", "qwen3"])
        XCTAssertEqual(order.items.first, "ps")                  // 先查后卸
    }

    func testPreSwapToPackListFailureSilent() async {
        struct Boom: Error {}
        var unloadCalls = 0
        let router = makeRouter(
            loaded: { throw Boom() },
            unload: { _ in unloadCalls += 1; return true })
        await router.preSwapToPack()                             // 不抛
        XCTAssertEqual(unloadCalls, 0)
    }

    func testSafeUnloadNotInMemorySkips() async {
        var unloadCalls = 0
        let router = makeRouter(
            loaded: { ["qwen3"] },
            unload: { _ in unloadCalls += 1; return true })
        let ok = await router.safeUnload("glm-ocr")              // 不在内存
        XCTAssertFalse(ok)
        XCTAssertEqual(unloadCalls, 0)                           // 不触发「为卸载而加载」
    }

    func testSafeUnloadTimeoutsSilent() async {
        let router = makeRouter(
            loaded: {
                try? await Task.sleep(nanoseconds: 60_000_000_000)   // 永不返回
                return ["m"]
            },
            unload: { _ in true })
        router.swapPSTimeout = 0.05
        let ok = await router.safeUnload("m")
        XCTAssertFalse(ok)                                       // ps 超时静默 False

        let router2 = makeRouter(
            loaded: { ["m"] },
            unload: { _ in
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                return true
            })
        router2.swapTimeout = 0.05
        let ok2 = await router2.safeUnload("m")
        XCTAssertFalse(ok2)                                      // unload 超时静默 False
    }

    func testPreSwapToActiveStopsRunningServer() async throws {
        try seedPack("mp-live")
        let router = makeRouter()
        await router.preSwapToActive()                           // 无活动包：廉价早退
        _ = try await driver.ensureServer("mp-live")
        XCTAssertEqual(driver.activePack(), "mp-live")
        await router.preSwapToActive()                           // 停 llama-server 还内存
        XCTAssertNil(driver.activePack())
    }
}
