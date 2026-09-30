//
//  NativeMPInferenceBranchTests.swift
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

//  逐条锚定（⛔ 行为规格源 subagent/sidecar/app.py L446-542 +
//  sidecar/ollama/routing.py L95-209 + sidecar/model_packs/mp_connector.py）：
//    · statusMP：backend="model_package"、base_url=驱动活动端口或 ""、online 恒 true
//      （routing 退化 list_models=注册表读永不失败）、caps=MP 能力表
//    · modelsMP：注册表聚合（chat+enabled），endpointRow 映射真值口径
//    · contextLimitMP：tier（config 懒档）→ manifest context_length → unsupported
//    · NativeSidecarClient.chatStream 三已知后端统一经 NativeRoutingChatConnector
//      逐轮归边：pack 模型走 MP 且 preSwapToPack 先卸活动后端驻留；ollama 模型
//      走原生且 preSwapToActive 先停 llama-server；model_package 退化全走 MP；
//      未知后端兜底落 ollama 单例（P3-W6 对齐 routing.py 兜底语义）；tiersOverride=内核共享档位表（loop 升档
//      与驱动异档重启同一份状态——bump 后首轮 spawn 即新档，对比对照可分辨）
//
//  全程不触网不要求真进程：FakeProc3/FakeSpawner3 + FakeMPTransport3 缝注入。
//

import XCTest
@testable import VetarAINative

// MARK: - 夹具（假进程/假 spawner/假 OpenAI 传输；与④同型、文件私有）

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
    private let lock = NSLock()
    private(set) var argvs: [[String]] = []
    var onSpawn: (@Sendable () -> Void)?
    func spawn(argv: [String], env: [String: String], log: FileHandle) throws
        -> any NativeLlamaServerProcess {
        lock.lock(); argvs.append(argv); lock.unlock()
        onSpawn?()
        return FakeProc3()
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return argvs.count }
    func argv(_ i: Int) -> [String] { lock.lock(); defer { lock.unlock() }; return argvs[i] }
}

private final class FakeMPTransport3: NativeOpenAITransport, @unchecked Sendable {
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

private final class OrderLog3: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var items: [String] = []
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return items }
}

// MARK: - 测试本体

final class NativeMPInferenceBranchTests: XCTestCase {

    private var base: URL!
    private var kernel: NativeKernel!
    private var spawner: FakeSpawner3!
    private var envBin: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3w3a6_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        kernel = NativeKernel(dataRoot: base)
        // 驱动全缝：假二进制 + 假 spawner + 即真探测 + 固定端口 + 零等待
        envBin = base.appendingPathComponent("bin/llama-server")
        try FileManager.default.createDirectory(at: envBin.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: envBin)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: envBin.path)
        spawner = FakeSpawner3()
        let driver = kernel.llamaDriver
        driver.environment = [NativeLlamaCppDriver.envLlamaServer: envBin.path]
        driver.bundleResourceURL = nil
        driver.spawner = spawner
        driver.probe = { _ in true }
        driver.freePort = { 54321 }
        driver.sleep = { _ in }
        // 快速失败：活动后端探测不触真网（contextLimit 的 ps 级连接拒绝即返）
        _ = try kernel.config.reloadConfig(patch: [
            "ollama_base_url": .string("http://127.0.0.1:1"),
        ])
    }

    override func tearDownWithError() throws {
        kernel = nil
        spawner = nil
        try? FileManager.default.removeItem(at: base)
        base = nil
        try super.tearDownWithError()
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
        let store = kernel.modelPackStore
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

    /// 生产同构 MP 连接器（kernel 三件套 + 内核共享档位表），仅 transport 换假。
    private func makeMPConn(_ transport: FakeMPTransport3) -> NativeMPChatConnector {
        NativeMPChatConnector(
            driver: kernel.llamaDriver, store: kernel.modelPackStore,
            tiers: kernel.lazyCtxTiers,
            configProvider: { [kernel] in (try? kernel?.config.getConfig()) ?? [:] },
            guard: NativeNetworkGuard(), transport: transport)
    }

    private func makeClient() -> NativeSidecarClient {
        NativeSidecarClient(kernel: kernel)
    }

    private func req(_ model: String, content: String = "你好") -> ChatStreamRequest {
        ChatStreamRequest(
            agent_id: "", model: model,
            messages: [ChatStreamMessage(role: "user", content: content)],
            project_id: "", session_id: "s1", sandbox_root: base.path)
    }

    private func collectEvents(_ stream: AsyncThrowingStream<SSEEvent, Error>) async throws
        -> [String] {
        var names: [String] = []
        for try await ev in stream { names.append(ev.event) }
        return names
    }

    // ════════════════════════════════════════════════════════════
    // MARK: - statusMP（app.py L446-472 的 MP 面）
    // ════════════════════════════════════════════════════════════

    /// 驱动未启动：base_url=""、online 恒 true（注册表读永不失败）、caps=MP 表。
    func testStatusMPIdle() throws {
        let st = kernel.inferenceEndpoints.statusMP()
        XCTAssertEqual(st.backend, "model_package")
        XCTAssertEqual(st.base_url, "")
        XCTAssertTrue(st.online)
        XCTAssertEqual(st.detail, "")
        XCTAssertEqual(st.capabilities,
                       InferenceCapabilities(tools: true, vision: false,
                                             pull: false, delete: false))
    }

    /// 驱动启动后（假 spawner）：base_url 带活动动态端口（含 /v1）。
    func testStatusMPActiveBaseURL() async throws {
        try seedPack("p1")
        _ = try await kernel.llamaDriver.ensureServer("p1")
        let st = kernel.inferenceEndpoints.statusMP()
        XCTAssertEqual(st.base_url, "http://127.0.0.1:54321/v1")
        XCTAssertTrue(st.online)
    }

    // ════════════════════════════════════════════════════════════
    // MARK: - modelsMP（app.py L474-498 + routing.py L196-197 退化）
    // ════════════════════════════════════════════════════════════

    /// 注册表聚合：只 enabled chat 包；endpointRow 真值口径（size/ctx/source）。
    func testModelsMPRegistryMapping() throws {
        try seedPack("chat-on", contextLength: 8192)
        try seedPack("chat-off")
        try seedPack("asr-pack", task: "asr")
        XCTAssertNotNil(kernel.modelPackStore.setEnabled("chat-off", enabled: false))
        let rows = kernel.inferenceEndpoints.modelsMP()
        XCTAssertEqual(rows, [
            InferenceModelEntry(name: "chat-on", size: 4,
                                context_length: 8192, source: "model_pack"),
        ])
    }

    // ════════════════════════════════════════════════════════════
    // MARK: - contextLimitMP（app.py L529-542 的 MP 面）
    // ════════════════════════════════════════════════════════════

    /// ①config 懒档：num_ctx 4096 → 当前档 min(12288,4096)=4096，ceiling/lazy 同口径。
    func testContextLimitMPConfigTier() throws {
        try seedPack("p-tier")
        _ = try kernel.config.reloadConfig(patch: [
            "model_options": .object(["p-tier": .object(["num_ctx": .int(4096)])]),
        ])
        let info = kernel.inferenceEndpoints.contextLimitMP(model: "p-tier")
        XCTAssertEqual(info, ContextLimitInfo(limit: 4096, source: "config",
                                              ceiling: 4096, lazy: true))
    }

    /// ②manifest 面：无 num_ctx 有 context_length=8192 → source="manifest"。
    func testContextLimitMPManifest() throws {
        try seedPack("p-man", contextLength: 8192)
        let info = kernel.inferenceEndpoints.contextLimitMP(model: "p-man")
        XCTAssertEqual(info, ContextLimitInfo(limit: 8192, source: "manifest"))
    }

    /// ③皆无 → unsupported（limit 0，前端隐藏指示器，不瞎兜底）。
    func testContextLimitMPUnsupported() throws {
        try seedPack("p-none")
        let info = kernel.inferenceEndpoints.contextLimitMP(model: "p-none")
        XCTAssertEqual(info, ContextLimitInfo(limit: 0, source: "unsupported"))
    }

    // ════════════════════════════════════════════════════════════
    // MARK: - chatStream 分流（NativeRoutingChatConnector 逐轮归边）
    // ════════════════════════════════════════════════════════════

    /// pack 模型（ollama 后端）走 MP：preSwapToPack 先卸活动后端驻留，再 spawn，
    /// 再发协议请求（顺序录证）。
    func testChatStreamPackModelRoutesMPWithPreswap() async throws {
        try seedPack("qwen-mp")
        let order = OrderLog3()
        kernel.modelPackRouter.activeLoadedModels = { ["resident-7b"] }
        kernel.modelPackRouter.activeUnload = { name in
            order.add("unload:\(name)"); return true
        }
        spawner.onSpawn = { order.add("spawn") }
        let transport = FakeMPTransport3([.stream(200, [
            #"data: {"choices":[{"delta":{"content":"好"}}],"usage":{"prompt_tokens":3,"completion_tokens":1}}"#,
            "data: [DONE]",
        ])])
        transport.onRequest = { order.add("request") }
        let client = makeClient()
        client.mpChatConnectorOverride = makeMPConn(transport)

        let names = try await collectEvents(client.chatStream(req("qwen-mp")))

        XCTAssertTrue(names.contains("done"), "MP 原生链路事件流完整: \(names)")
        XCTAssertEqual(order.snapshot(), ["unload:resident-7b", "spawn", "request"])
        XCTAssertEqual(transport.requests.first,
                       "http://127.0.0.1:54321/v1/chat/completions")
        XCTAssertFalse(spawner.argv(0).contains("-c"), "未配 num_ctx → 驱动不显式带 -c")
    }

    /// ollama 模型（非包）走原生活动后端：preSwapToActive 先停在跑的 llama-server
    /// （还内存），连接拒绝转 error 事件。
    func testChatStreamOllamaModelStopsLlamaServer() async throws {
        try seedPack("qwen-mp")
        _ = try await kernel.llamaDriver.ensureServer("qwen-mp")
        XCTAssertEqual(kernel.llamaDriver.activePack(), "qwen-mp")
        let client = makeClient()
        client.mpChatConnectorOverride = makeMPConn(FakeMPTransport3([]))

        let names = try await collectEvents(client.chatStream(req("qwen3")))

        XCTAssertNil(kernel.llamaDriver.activePack(),
                     "路由至活动后端前已停止 llama-server（方向②）")
        XCTAssertTrue(names.contains("error"),
                      "ollama 原生链路（127.0.0.1:1 连接拒绝转 error）: \(names)")
        XCTAssertEqual(spawner.count, 1, "活动后端路径不再 spawn")
    }

    /// model_package 退化：全部模型走 MP（包模型正常流式；未安装包 400 中文明细
    /// 转 error 事件）；退化跳过换装编排（不查活动后端 ps）。
    func testChatStreamDegradedAllMP() async throws {
        try seedPack("qwen-mp")
        _ = try kernel.config.reloadConfig(patch: [
            "inference_backend": .string("model_package"),
        ])
        var psCalls = 0
        kernel.modelPackRouter.activeLoadedModels = { psCalls += 1; return ["x"] }
        let transport = FakeMPTransport3([.stream(200, [
            #"data: {"choices":[{"delta":{"content":"答"}}]}"#,
            "data: [DONE]",
        ])])
        let client = makeClient()
        client.mpChatConnectorOverride = makeMPConn(transport)

        let names = try await collectEvents(client.chatStream(req("qwen-mp")))
        XCTAssertTrue(names.contains("done"), "退化模式包模型流式完整: \(names)")
        XCTAssertEqual(psCalls, 0, "退化跳过 preSwap 编排（routing.py L127-128）")

        let names2 = try await collectEvents(client.chatStream(req("ghost")))
        XCTAssertTrue(names2.contains("error"), "未安装包 → openAI(400) 转 error: \(names2)")
    }

    /// 未知后端兜底落 ollama 单例（P3-W6 对齐 routing.py _active() L81-89 兜底语义——
    /// 历史上走 HTTP fallback 属 W2b 偏差，侧车归零后 Python 源实证不报错；
    /// 写裸 config 绕过校验构造非法值——写入侧 400 拦截见 config/store.py L344-346）。
    func testChatStreamUnknownBackendFallsBackToOllama() async throws {
        let url = kernel.dataRoot.appendingPathComponent("config.json")
        try NativeDatabase.dumpsUTF8(.object([
            "inference_backend": .string("bogus"),
        ])).write(to: url, atomically: false, encoding: .utf8)
        let client = makeClient()
        client.mpChatConnectorOverride = makeMPConn(FakeMPTransport3([]))

        let names = try await collectEvents(client.chatStream(req("m")))
        XCTAssertTrue(names.contains("error"),
                      "未知后端兜底落 ollama（127.0.0.1:1 连接拒绝转 error）: \(names)")
        XCTAssertEqual(spawner.count, 0, "未知后端不触 MP 驱动")
    }

    /// tiersOverride=内核共享档位表：loop 升档与驱动异档重启同一份状态——
    /// 大消息（est≥档×0.85）触发 bump 12288→24576 后，同轮 ensure 即按新档
    /// spawn（对照：未传 tiersOverride 时 loop bump 落在每流自建表，驱动仍 12288）。
    func testChatStreamMPTiersSharedWithKernel() async throws {
        try seedPack("big-pack")
        _ = try kernel.config.reloadConfig(patch: [
            "inference_backend": .string("model_package"),
            "model_options": .object(["big-pack": .object(["num_ctx": .int(32768)])]),
        ])
        let transport = FakeMPTransport3([.stream(200, [
            #"data: {"choices":[{"delta":{"content":"好"}}],"usage":{"prompt_tokens":3,"completion_tokens":1}}"#,
            "data: [DONE]",
        ])])
        let client = makeClient()
        client.mpChatConnectorOverride = makeMPConn(transport)   // tiers=kernel.lazyCtxTiers

        // 20000 字 → est≈12000 ≥ 12288×0.85=10444.8 → loop round 1 bump → 24576
        let big = String(repeating: "字", count: 20000)
        let names = try await collectEvents(client.chatStream(req("big-pack", content: big)))

        XCTAssertTrue(names.contains("done"), "事件流完整: \(names)")
        XCTAssertEqual(spawner.count, 1)
        XCTAssertEqual(Array(spawner.argv(0).suffix(2)), ["-c", "24576"],
                       "loop bump 落内核共享表 → 同轮 ensure 按新档 spawn")
        XCTAssertEqual(kernel.lazyCtxTiers.currentCtxFor("big-pack", backend: "model_package"),
                       24576, "bump 后档位留在内核共享实例（只升不降）")
    }
}
