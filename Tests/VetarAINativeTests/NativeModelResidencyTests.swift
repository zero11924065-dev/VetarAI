//
//  NativeModelResidencyTests.swift
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

//  覆盖：默认空集 / 临时数据根持久化与校验 / 精确模型名 / 请求级注入 /
//  Ollama 真实 chat/chatStream 请求体 / 自动卸载候选 / 内存建议 / 未知体积 /
//  27B/35B 只提醒不禁止。HTTP 仅拦截 residency.stub，绝不触真实服务。
//

import XCTest
@testable import VetarAINative

private final class ResidencyStubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = (URLRequest) throws -> (Int, Data)

    private static let lock = NSLock()
    private static var handler: Handler?
    private static var bodies: [[String: Any]] = []

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "residency.stub"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.record(request)
        do {
            guard let handler = Self.currentHandler() else { throw URLError(.unknown) }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/x-ndjson"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func installOKHandler() {
        lock.lock()
        defer { lock.unlock() }
        handler = { _ in
            (200, Data(#"{"message":{"content":"ok"},"done":true}"#.utf8))
        }
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        handler = nil
        bodies = []
    }

    static func recordedBodies() -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return bodies
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResidencyStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func currentHandler() -> Handler? {
        lock.lock()
        defer { lock.unlock() }
        return handler
    }

    private static func record(_ request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        bodies.append(bodyJSON(request))
    }

    private static func bodyJSON(_ request: URLRequest) -> [String: Any] {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = Data()
            let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { chunk.deallocate() }
            while stream.hasBytesAvailable {
                let count = stream.read(chunk, maxLength: 4096)
                if count <= 0 { break }
                buffer.append(chunk, count: count)
            }
            data = buffer
        }
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }
}

final class NativeModelResidencyTests: XCTestCase {
    private let giB: Int64 = 1_024 * 1_024 * 1_024

    override func setUp() {
        super.setUp()
        ResidencyStubURLProtocol.reset()
        ResidencyStubURLProtocol.installOKHandler()
    }

    override func tearDown() {
        ResidencyStubURLProtocol.reset()
        super.tearDown()
    }

    private func makeStore() throws -> (store: NativeConfigStore, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("a1-residency-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (NativeConfigStore(environment: ["VETARAI_DATA_ROOT": root.path]), root)
    }

    private func ollamaConfig(resident: [String]) -> [String: JSONValue] {
        var config = NativeConfigStore.defaultConfig
        config["ollama_base_url"] = .string("http://residency.stub")
        config[NativeModelResidency.configKey] = .array(resident.map { .string($0) })
        return config
    }

    private func connector(_ config: [String: JSONValue]) -> NativeOllamaChatConnector {
        NativeOllamaChatConnector(
            configProvider: { config }, session: ResidencyStubURLProtocol.session())
    }

    private func firstRequestBody() throws -> [String: Any] {
        try XCTUnwrap(ResidencyStubURLProtocol.recordedBodies().first)
    }

    func testDefaultResidencyIsEmpty() {
        XCTAssertEqual(NativeConfigStore.defaultConfig[NativeModelResidency.configKey], .array([]))
        XCTAssertTrue(NativeModelResidency.residentModels([:]).isEmpty)
        XCTAssertTrue(NativeModelResidency.residentModels(NativeConfigStore.defaultConfig).isEmpty)
    }

    func testResidencyPersistsAcrossStoreInstances() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(NativeModelResidency.residentModels(try store.getConfig()).isEmpty)
        _ = try store.reloadConfig(patch: [
            NativeModelResidency.configKey: .array([.string("qwen3:0.5b"), .string("qwen3:27b")]),
        ])
        let reopened = NativeConfigStore(environment: ["VETARAI_DATA_ROOT": root.path])
        XCTAssertEqual(NativeModelResidency.residentModels(try reopened.getConfig()),
                       ["qwen3:0.5b", "qwen3:27b"])
    }

    func testMixedTypeResidencyArrayIsRejectedWithoutChangingDisk() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try store.getConfig()
        XCTAssertThrowsError(try store.reloadConfig(patch: [
            NativeModelResidency.configKey: .array([.string("qwen3"), .int(1)]),
        ])) { error in
            XCTAssertEqual(error as? NativeCoreError,
                           .invalidConfig("model_residency 必须是字符串数组"))
        }
        XCTAssertTrue(NativeModelResidency.residentModels(try store.getConfig()).isEmpty)
    }

    func testExactModelMatchAndPurePayloadInjection() {
        let config = ollamaConfig(resident: ["qwen3"])
        let payload: [String: JSONValue] = ["model": .string("qwen3"), "stream": .bool(false)]
        XCTAssertTrue(NativeModelResidency.isResident(model: "qwen3", config: config))
        XCTAssertFalse(NativeModelResidency.isResident(model: "qwen3:latest", config: config))
        XCTAssertEqual(NativeModelResidency.applyingOllamaKeepAlive(
            payload, model: "qwen3", config: config)["keep_alive"], .int(-1))
        let unselected = NativeModelResidency.applyingOllamaKeepAlive(
            payload, model: "qwen3:latest", config: config)
        XCTAssertEqual(unselected, payload)
        XCTAssertNil(unselected["keep_alive"])
    }

    func testAutomaticUnloadOnlyExemptsExactResidentModel() {
        let config = ollamaConfig(resident: ["qwen3"])
        XCTAssertFalse(NativeModelResidency.shouldAutomaticallyUnloadOllama(
            model: "qwen3", config: config))
        XCTAssertTrue(NativeModelResidency.shouldAutomaticallyUnloadOllama(
            model: "qwen3:latest", config: config))
        XCTAssertEqual(NativeModelResidency.ollamaAutomaticUnloadCandidates(
            loaded: ["qwen3", "qwen3:latest", "glm-ocr"], config: config),
            ["qwen3:latest", "glm-ocr"])
    }

    func testOllamaChatInjectsKeepAliveForSelectedModel() async throws {
        let config = ollamaConfig(resident: ["qwen3:0.5b"])
        let answer = try await connector(config).chat(
            model: "qwen3:0.5b", messages: [["role": .string("user"), "content": .string("hi")]])
        XCTAssertEqual(answer, "ok")
        let body = try firstRequestBody()
        XCTAssertEqual(body["keep_alive"] as? Int, -1)
        XCTAssertEqual(body["stream"] as? Bool, false)
    }

    func testOllamaChatOmitsKeepAliveForUnselectedModel() async throws {
        let answer = try await connector(ollamaConfig(resident: [])).chat(
            model: "qwen3:0.5b", messages: [["role": .string("user"), "content": .string("hi")]])
        XCTAssertEqual(answer, "ok")
        let body = try firstRequestBody()
        XCTAssertNil(body["keep_alive"], "未勾选请求必须完全不出现 keep_alive")
        XCTAssertEqual(body["model"] as? String, "qwen3:0.5b")
    }

    func testOllamaStreamingChatUsesSameResidencyInjection() async throws {
        let config = ollamaConfig(resident: ["qwen3:0.5b"])
        var events: [NativeChatStreamEvent] = []
        for try await event in connector(config).chatStream(
            model: "qwen3:0.5b",
            messages: [["role": .string("user"), "content": .string("hi")]],
            tools: nil, images: nil, thinkingMode: nil) {
            events.append(event)
        }
        XCTAssertTrue(events.contains(.contentDelta("ok")))
        let body = try firstRequestBody()
        XCTAssertEqual(body["keep_alive"] as? Int, -1)
        XCTAssertEqual(body["stream"] as? Bool, true)
    }

    func testMemoryAdviceUsesQuarterBudgetAndMaximumKnownCount() {
        let models = [
            InferenceModelEntry(name: "8g", size: 8 * giB),
            InferenceModelEntry(name: "6g", size: 6 * giB),
            InferenceModelEntry(name: "4g", size: 4 * giB),
        ]
        let advice = NativeModelResidency.advice(
            models: models, selected: [], totalMemory: 64 * giB)
        XCTAssertEqual(advice.budgetBytes, 16 * giB)
        XCTAssertEqual(advice.recommendedCount, 2)
        XCTAssertFalse(advice.exceedsBudget)
        XCTAssertEqual(advice.unknownCandidateCount, 0)
    }

    func testSelectedModelsOverBudgetOnlyProduceWarning() {
        let models = [InferenceModelEntry(name: "qwen3:27b", size: 18 * giB)]
        let selected: Set<String> = ["qwen3:27b"]
        let advice = NativeModelResidency.advice(
            models: models, selected: selected, totalMemory: 64 * giB)
        XCTAssertTrue(advice.exceedsBudget)
        XCTAssertEqual(advice.selectedKnownBytes, 18 * giB)
        let payload = NativeModelResidency.applyingOllamaKeepAlive(
            [:], model: "qwen3:27b", config: ollamaConfig(resident: ["qwen3:27b"]))
        XCTAssertEqual(payload["keep_alive"], .int(-1), "超预算不得阻断用户选择")
    }

    func testNilAndZeroSizesStayUnknownAndOutOfTotals() {
        let models = [
            InferenceModelEntry(name: "nil-size", size: nil),
            InferenceModelEntry(name: "zero-size", size: 0),
            InferenceModelEntry(name: "known", size: 2 * giB),
        ]
        let selected: Set<String> = ["nil-size", "zero-size", "known"]
        let advice = NativeModelResidency.advice(
            models: models, selected: selected, totalMemory: 64 * giB)
        XCTAssertEqual(advice.selectedKnownBytes, 2 * giB)
        XCTAssertEqual(advice.unknownCandidateCount, 2)
        XCTAssertEqual(advice.unknownSelectedCount, 2)
        XCTAssertEqual(advice.recommendedCount, 1)
    }

    func testLargeModelWarningDoesNotGateSelection() {
        XCTAssertTrue(NativeModelResidency.needsLargeModelWarning(
            name: "qwen3:27b", size: nil))
        XCTAssertTrue(NativeModelResidency.needsLargeModelWarning(
            name: "custom-35B-instruct", size: nil))
        XCTAssertTrue(NativeModelResidency.needsLargeModelWarning(
            name: "unnamed-large", size: 17 * giB))
        XCTAssertFalse(NativeModelResidency.needsLargeModelWarning(
            name: "qwen3:0.5b", size: giB))
        let config = ollamaConfig(resident: ["qwen3:27b", "custom-35B-instruct"])
        XCTAssertEqual(NativeModelResidency.residentModels(config).count, 2)
        XCTAssertEqual(NativeModelResidency.applyingOllamaKeepAlive(
            [:], model: "custom-35B-instruct", config: config)["keep_alive"], .int(-1))
    }

    func testMemorySnapshotHasPhysicalTotalAndConservativeFreeValue() {
        let snapshot = NativeModelResidency.currentMemorySnapshot()
        XCTAssertGreaterThan(snapshot.totalBytes, 0)
        if let free = snapshot.freeBytes { XCTAssertGreaterThanOrEqual(free, 0) }
    }
}
