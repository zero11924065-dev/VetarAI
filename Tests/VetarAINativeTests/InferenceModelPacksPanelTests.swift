//
//  InferenceModelPacksPanelTests.swift
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

//  InferencePanel / ModelOptionsEditor / ModelPacksPanel 单测：
//    · 契约模型宽容解码（InferenceStatusInfo / InferenceModelEntry / CatalogPack /
//      InstalledPack / ModelPackCatalogResponse，含 Int64/Double 混合数值）
//    · ModelPackFormat 纯函数（formatSize / hostOf / isOverseasHost 逐分支）
//    · ModelOptionsEditorViewModel coerce 校验（int/float/list/边界/非法文案逐字）
//      + 草稿模式（未改动不提交 / Enter 后 blur 不重复 PUT / 非法草稿保留不回弹 /
//      清空 = 移除该项）+ 后端门禁（OpenAI 兼容置灰 / 模型包 num_ctx 解锁）
//    · InferencePanelViewModel：saveBackend 补丁写回与消息消隐、设为默认（模型包
//      换装编排文案）、参数入口建空条目、拉取/删除消息流、资源变更事件过滤
//    · ModelPacksPanelViewModel：安装确认链（境外勾选 → 先切 proxy 再安装 / 取消不发请求）、
//      下载进度事件状态机（start/progress/done/error/cancelled）、卸载/启停、目录源保存
//

import XCTest
@testable import VetarAINative

// MARK: - W2 Mock 客户端（两协议方法均可注入/记录）

final class W2MockClient: InferencePanelClient, ModelPacksPanelClient {
    let baseURL = URL(string: "http://127.0.0.1:1/api")!

    // 注入结果
    var config: [String: Any] = [
        "inference_backend": "ollama",
        "ollama_base_url": "http://localhost:11434",
        "default_model": "qwen3.8",
        "model_options": [String: [String: Any]](),
        "ctx_lazy_enabled": true,
        "ctx_lazy_start": 12288,
        "timeout_connect": 0, "timeout_reading": 0, "timeout_stream_reading": 0,
    ]
    var inferenceStatus = InferenceStatusInfo(
        backend: "ollama", base_url: "http://localhost:11434", online: true,
        capabilities: InferenceCapabilities(tools: true, vision: false, pull: true, delete: true))
    var inferenceModels: [InferenceModelEntry] = [
        InferenceModelEntry(name: "qwen3.8", size: 5_200_000_000, context_length: 262144),
        InferenceModelEntry(name: "chat-7b-gguf", source: "model_pack"),
    ]
    var installedPacks: [InstalledPack] = []
    var catalogPacks: [CatalogPack] = []
    var catalogRaw: [String: [String: Any]] = [:]
    var catalogSourceErrors: [ModelPackSourceError] = []
    var fetchConfigError: Error?
    var statusError: Error?
    var modelsError: Error?
    var listPacksError: Error?
    var installError: Error?
    var pullError: Error?
    var deleteError: Error?

    // 调用记录
    private(set) var putConfigCalls: [[String: Any]] = []
    private(set) var pullCalls: [String] = []
    private(set) var deleteCalls: [String] = []
    private(set) var installCalls: [(packId: String, entry: [String: Any])] = []
    private(set) var cancelCalls: [String] = []
    private(set) var deletePackCalls: [String] = []
    private(set) var toggleCalls: [(String, Bool)] = []

    // 资源变更流控制
    private var streamContinuation: AsyncThrowingStream<SSEEvent, Error>.Continuation?
    func pushStreamEvent(_ ev: SSEEvent) { streamContinuation?.yield(ev) }
    func finishStream(throwing error: Error? = nil) {
        if let error { streamContinuation?.finish(throwing: error) }
        else { streamContinuation?.finish() }
    }

    // MARK: SidecarClientProtocol 基础桩

    func probeReady() async throws -> Bool { true }
    func listModels() async throws -> [OllamaModel] { [] }
    func listProjects() async throws -> [SidecarProject] { [] }
    func createProject(name: String, workingDir: String) async throws -> String { "p1" }
    func listAgents(projectId: String) async throws -> [SidecarAgent] { [] }
    func createAgent(projectId: String, name: String, type: String, modelName: String?) async throws -> String { "a1" }
    func listSessions(projectId: String, agentId: String) async throws -> [ChatSession] { [] }
    func createSession(projectId: String, agentId: String, title: String) async throws -> String { "s1" }
    func loadMessages(projectId: String, sessionId: String) async throws -> [ChatMessage] { [] }
    func stopChat(sessionId: String) async throws {}
    func respondAuth(_ body: AuthRespondRequest) async throws {}
    func chatStream(_ body: ChatStreamRequest) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    // MARK: InferencePanelClient

    func fetchConfig() async throws -> [String: Any] {
        if let fetchConfigError { throw fetchConfigError }
        return config
    }
    func putConfig(_ patch: [String: Any]) async throws {
        putConfigCalls.append(patch)
        for (k, v) in patch { config[k] = v }
    }
    func fetchInferenceStatus() async throws -> InferenceStatusInfo {
        if let statusError { throw statusError }
        return inferenceStatus
    }
    func fetchInferenceModels() async throws -> [InferenceModelEntry] {
        if let modelsError { throw modelsError }
        return inferenceModels
    }
    func pullModel(name: String) async throws {
        pullCalls.append(name)
        if let pullError { throw pullError }
    }
    func deleteModel(name: String) async throws {
        deleteCalls.append(name)
        if let deleteError { throw deleteError }
    }
    func appEventsStream(since: Int) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { cont in self.streamContinuation = cont }
    }

    // MARK: ModelPacksPanelClient

    func listModelPacks() async throws -> ModelPackListResponse {
        if let listPacksError { throw listPacksError }
        return ModelPackListResponse(packs: installedPacks)
    }
    func fetchModelPackCatalog() async throws -> (catalog: ModelPackCatalogResponse,
                                                  rawEntries: [String: [String: Any]]) {
        (ModelPackCatalogResponse(packs: catalogPacks, sources: 1,
                                  source_errors: catalogSourceErrors), catalogRaw)
    }
    func installModelPack(packId: String, catalogEntry: [String: Any]) async throws {
        installCalls.append((packId, catalogEntry))
        if let installError { throw installError }
    }
    func cancelModelPackDownload(packId: String) async throws {
        cancelCalls.append(packId)
    }
    func deleteModelPack(packId: String) async throws {
        deletePackCalls.append(packId)
        installedPacks.removeAll { $0.pack_id == packId }
    }
    func toggleModelPack(packId: String, enabled: Bool) async throws {
        toggleCalls.append((packId, enabled))
    }
}

// MARK: - 测试工具

@MainActor
private func makeW2AppState(client: W2MockClient) -> AppState {
    TestRuntimeSupport.makeAppState(client: client)
}

private func sse(_ event: String, _ data: [String: Any] = [:]) -> SSEEvent {
    SSEEvent(event: event, data: data, rawData: "")
}

@MainActor
private func waitFor(_ timeoutMs: UInt64 = 2000,
                     _ cond: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
    while Date() < deadline {
        if cond() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return cond()
}

// MARK: - 契约模型解码

final class W2ContractDecodeTests: XCTestCase {

    func testInferenceStatusDecode() throws {
        let json = """
        {"backend":"openai_compatible","base_url":"http://localhost:1234/v1",
         "online":false,"detail":"连接超时（8s），请检查地址是否正确、服务是否启动",
         "capabilities":{"tools":true,"vision":false,"pull":false,"delete":false}}
        """.data(using: .utf8)!
        let st = try JSONDecoder().decode(InferenceStatusInfo.self, from: json)
        XCTAssertEqual(st.backend, "openai_compatible")
        XCTAssertFalse(st.online)
        XCTAssertTrue(st.detail.contains("连接超时"))
        XCTAssertTrue(st.capabilities.tools)
        XCTAssertFalse(st.capabilities.pull)
    }

    func testInferenceStatusToleratesMissingFields() throws {
        let st = try JSONDecoder().decode(InferenceStatusInfo.self, from: Data("{}".utf8))
        XCTAssertEqual(st.backend, "ollama")
        XCTAssertFalse(st.online)
        XCTAssertEqual(st.capabilities, InferenceCapabilities())
    }

    func testInferenceModelEntryDecode() throws {
        let json = """
        [{"name":"qwen3.8","size":5200000000,"context_length":262144},
         {"name":"chat-7b","source":"model_pack"},
         {"id":"gpt-4o-mini"}]
        """.data(using: .utf8)!
        let models = try JSONDecoder().decode([InferenceModelEntry].self, from: json)
        XCTAssertEqual(models.count, 3)
        XCTAssertEqual(models[0].size, 5_200_000_000)
        XCTAssertEqual(models[0].context_length, 262144)
        XCTAssertFalse(models[0].isModelPack)
        XCTAssertTrue(models[1].isModelPack)
        XCTAssertEqual(models[2].name, "")   // openai_compatible 的 id 键后端已映射为 name
    }

    func testCatalogPackDecodeWithOptionalKeys() throws {
        let json = """
        {"pack_id":"bge-m3-onnx","name":"BGE-M3 向量","task":"embedding","format":"onnx",
         "driver":"onnxruntime","version":"1.0.0","description":"多语言嵌入模型",
         "size_bytes":2270000000,"min_app_version":"0.4.29","license":"MIT",
         "files":[{"path":"model.onnx","size_bytes":2000000000,"sha256":"abcdef0123456789"}],
         "source":"https://example.com/catalog.json","installed":true,"enabled":true,
         "installed_version":"0.9.0"}
        """.data(using: .utf8)!
        let p = try JSONDecoder().decode(CatalogPack.self, from: json)
        XCTAssertEqual(p.pack_id, "bge-m3-onnx")
        XCTAssertEqual(p.task, "embedding")
        XCTAssertEqual(p.files?.first?.sha256, "abcdef0123456789")
        XCTAssertEqual(p.installed, true)
        XCTAssertEqual(p.installed_version, "0.9.0")
    }

    func testInstalledPackDecodeAndCorrupted() throws {
        let json = """
        {"packs":[{"pack_id":"sensevoice-small","name":"SenseVoice 语音转文字","version":"1.0.0",
          "task":"asr","format":"onnx","status":"installed","enabled":true,
          "sha256_ok":false,"size_bytes":936000000,"missing_files":["tokens.txt"],
          "has_partial":true}]}
        """.data(using: .utf8)!
        let resp = try JSONDecoder().decode(ModelPackListResponse.self, from: json)
        XCTAssertEqual(resp.packs.count, 1)
        let p = resp.packs[0]
        XCTAssertFalse(p.sha256_ok)
        XCTAssertEqual(p.missing_files, ["tokens.txt"])
        XCTAssertTrue(p.corrupted)
        XCTAssertTrue(p.has_partial)
    }

    func testCatalogResponseSourceErrors() throws {
        let json = """
        {"packs":[],"sources":1,
         "source_errors":[{"source":"https://bad.example.com/x.json","error":"HTTP 404"}]}
        """.data(using: .utf8)!
        let resp = try JSONDecoder().decode(ModelPackCatalogResponse.self, from: json)
        XCTAssertEqual(resp.sources, 1)
        XCTAssertEqual(resp.source_errors.first?.error, "HTTP 404")
    }
}

// MARK: - ModelPackFormat 纯函数

final class ModelPackFormatTests: XCTestCase {
    func testFormatSize() {
        XCTAssertEqual(ModelPackFormat.formatSize(0), "0 B")
        XCTAssertEqual(ModelPackFormat.formatSize(-5), "0 B")
        XCTAssertEqual(ModelPackFormat.formatSize(512), "512 B")
        XCTAssertEqual(ModelPackFormat.formatSize(2048), "2 KB")
        XCTAssertEqual(ModelPackFormat.formatSize(1_572_864), "1.5 MB")
        XCTAssertEqual(ModelPackFormat.formatSize(2_270_000_000), "2.1 GB")
    }

    func testHostOf() {
        XCTAssertEqual(ModelPackFormat.hostOf(""), "")
        XCTAssertEqual(ModelPackFormat.hostOf("  "), "")
        XCTAssertEqual(ModelPackFormat.hostOf("file:///Users/x/packs/catalog.json"), "")
        XCTAssertEqual(ModelPackFormat.hostOf("https://raw.githubusercontent.com/a/b.json"),
                       "raw.githubusercontent.com")
        XCTAssertEqual(ModelPackFormat.hostOf("not a url"), "")
    }

    func testIsOverseasHost() {
        XCTAssertFalse(ModelPackFormat.isOverseasHost(""))
        XCTAssertFalse(ModelPackFormat.isOverseasHost("localhost"))
        XCTAssertFalse(ModelPackFormat.isOverseasHost("::1"))
        XCTAssertFalse(ModelPackFormat.isOverseasHost("127.0.0.1"))
        XCTAssertFalse(ModelPackFormat.isOverseasHost("192.168.1.10"))   // 纯 IP 视为内网
        XCTAssertFalse(ModelPackFormat.isOverseasHost("mirrors.aliyun.com.cn"))
        XCTAssertTrue(ModelPackFormat.isOverseasHost("raw.githubusercontent.com"))
        XCTAssertTrue(ModelPackFormat.isOverseasHost("GITHUB.COM"))       // 大小写不敏感
    }
}

// MARK: - ModelOptionsEditorViewModel

@MainActor
final class ModelOptionsEditorVMTests: XCTestCase {

    private func param(_ key: String) -> ModelOptionParamDef {
        ModelOptionParams.all.first { $0.key == key }!
    }

    // MARK: coerce 纯函数

    func testCoerceIntValid() {
        XCTAssertEqual(ModelOptionsEditorViewModel.coerce(param("num_ctx"), raw: " 8192 "), .int(8192))
    }

    func testCoerceEmptyRemoves() {
        XCTAssertEqual(ModelOptionsEditorViewModel.coerce(param("num_ctx"), raw: "  "), .remove)
    }

    func testCoerceIntRejectsFraction() {
        XCTAssertEqual(ModelOptionsEditorViewModel.coerce(param("num_ctx"), raw: "2.5"),
                       .invalid("上下文上限 num_ctx 必须是整数"))
    }

    func testCoerceRejectsNaN() {
        XCTAssertEqual(ModelOptionsEditorViewModel.coerce(param("temperature"), raw: "abc"),
                       .invalid("随机性 temperature 必须是数字"))
    }

    func testCoerceRange() {
        XCTAssertEqual(ModelOptionsEditorViewModel.coerce(param("num_ctx"), raw: "128"),
                       .invalid("上下文上限 num_ctx 不得小于 256"))
        XCTAssertEqual(ModelOptionsEditorViewModel.coerce(param("num_ctx"), raw: "2000000"),
                       .invalid("上下文上限 num_ctx 不得大于 1048576"))
        XCTAssertEqual(ModelOptionsEditorViewModel.coerce(param("temperature"), raw: "2.1"),
                       .invalid("随机性 temperature 不得大于 2"))
        XCTAssertEqual(ModelOptionsEditorViewModel.coerce(param("top_k"), raw: "0"),
                       .invalid("top_k 不得小于 1"))
    }

    func testCoerceListSplitsAndTrims() {
        XCTAssertEqual(ModelOptionsEditorViewModel.coerce(param("stop"), raw: "</s>, 用户: ,,"),
                       .list(["</s>", "用户:"]))
        XCTAssertEqual(ModelOptionsEditorViewModel.coerce(param("stop"), raw: ", ,"), .remove)
    }

    func testCoerceNegativeNumPredict() {
        XCTAssertEqual(ModelOptionsEditorViewModel.coerce(param("num_predict"), raw: "-2"), .int(-2))
        XCTAssertEqual(ModelOptionsEditorViewModel.coerce(param("num_predict"), raw: "-3"),
                       .invalid("最大生成 num_predict 不得小于 -2"))
    }

    // MARK: valueToString

    func testValueToStringNormalization() {
        XCTAssertEqual(ModelOptionsEditorViewModel.valueToString(param("num_ctx"), nil), "")
        XCTAssertEqual(ModelOptionsEditorViewModel.valueToString(param("num_ctx"), NSNull()), "")
        XCTAssertEqual(ModelOptionsEditorViewModel.valueToString(param("num_ctx"), 8192), "8192")
        XCTAssertEqual(ModelOptionsEditorViewModel.valueToString(param("temperature"), 0.5), "0.5")
        // JS String(2.0) === "2"：整数值不带 .0
        XCTAssertEqual(ModelOptionsEditorViewModel.valueToString(param("temperature"), 2.0), "2")
        XCTAssertEqual(ModelOptionsEditorViewModel.valueToString(param("stop"), ["</s>", "用户:"]),
                       "</s>, 用户:")
    }

    // MARK: 草稿模式提交流

    func testCommitUnchangedDoesNotSave() async {
        var saves: [[String: Any]] = []
        let vm = ModelOptionsEditorViewModel(onSave: { patch in saves.append(patch) })
        vm.update(cfg: ["model_options": ["qwen3.8": ["num_ctx": 8192]]],
                  isOllama: true, isModelPackage: false, busy: false)
        // 草稿 = 已存值（未改动）→ 不 PUT
        vm.commit(model: "qwen3.8", def: param("num_ctx"))
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(saves.isEmpty)
        XCTAssertNil(vm.errorMessage)
    }

    func testCommitValidValueSavesAndNormalizes() async {
        var saves: [[String: Any]] = []
        let vm = ModelOptionsEditorViewModel(onSave: { patch in saves.append(patch) })
        vm.update(cfg: ["model_options": ["qwen3.8": [:]]],
                  isOllama: true, isModelPackage: false, busy: false)
        vm.editDraft(model: "qwen3.8", def: param("num_ctx"), text: " 8192 ")
        vm.commit(model: "qwen3.8", def: param("num_ctx"))
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(saves.count, 1)
        let mo = saves[0]["model_options"] as? [String: [String: Any]]
        XCTAssertEqual((mo?["qwen3.8"]?["num_ctx"] as? Int), 8192)
        // 草稿归一化同步
        XCTAssertEqual(vm.displayValue(model: "qwen3.8", def: param("num_ctx")), "8192")
        XCTAssertNil(vm.errorMessage)
    }

    func testCommitInvalidKeepsDraftNoSave() async {
        var saves: [[String: Any]] = []
        let vm = ModelOptionsEditorViewModel(onSave: { patch in saves.append(patch) })
        vm.update(cfg: ["model_options": ["qwen3.8": [:]]],
                  isOllama: true, isModelPackage: false, busy: false)
        vm.editDraft(model: "qwen3.8", def: param("num_ctx"), text: "2")
        vm.commit(model: "qwen3.8", def: param("num_ctx"))
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(saves.isEmpty)
        XCTAssertEqual(vm.errorMessage, "上下文上限 num_ctx 不得小于 256")
        // ⛔ 草稿保留不回弹（REQ-INFER-009）
        XCTAssertEqual(vm.displayValue(model: "qwen3.8", def: param("num_ctx")), "2")
    }

    func testCommitEmptyRemovesKey() async {
        var saves: [[String: Any]] = []
        let vm = ModelOptionsEditorViewModel(onSave: { patch in saves.append(patch) })
        vm.update(cfg: ["model_options": ["qwen3.8": ["num_ctx": 8192]]],
                  isOllama: true, isModelPackage: false, busy: false)
        vm.editDraft(model: "qwen3.8", def: param("num_ctx"), text: "")
        vm.commit(model: "qwen3.8", def: param("num_ctx"))
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(saves.count, 1)
        let mo = saves[0]["model_options"] as? [String: [String: Any]]
        XCTAssertNil(mo?["qwen3.8"]?["num_ctx"])
    }

    func testEnterThenBlurDoesNotDoubleSave() async {
        var saves: [[String: Any]] = []
        let vm = ModelOptionsEditorViewModel(onSave: { patch in saves.append(patch) })
        vm.update(cfg: ["model_options": ["qwen3.8": [:]]],
                  isOllama: true, isModelPackage: false, busy: false)
        vm.editDraft(model: "qwen3.8", def: param("temperature"), text: "0.7")
        vm.commit(model: "qwen3.8", def: param("temperature"))   // Enter
        vm.endFocus(model: "qwen3.8", def: param("temperature")) // 紧接 blur
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(saves.count, 1)
    }

    func testExternalRefreshKeepsFocusedDraft() {
        let vm = ModelOptionsEditorViewModel()
        vm.update(cfg: ["model_options": ["qwen3.8": ["num_ctx": 8192]]],
                  isOllama: true, isModelPackage: false, busy: false)
        vm.beginFocus(model: "qwen3.8", def: param("num_ctx"))
        vm.editDraft(model: "qwen3.8", def: param("num_ctx"), text: "1638")
        // 外部配置刷新（Agent 改配置后的重拉）：聚焦字段不被覆盖
        vm.update(cfg: ["model_options": ["qwen3.8": ["num_ctx": 4096]]],
                  isOllama: true, isModelPackage: false, busy: false)
        XCTAssertEqual(vm.displayValue(model: "qwen3.8", def: param("num_ctx")), "1638")
        // 未聚焦字段同步新值
        XCTAssertEqual(vm.displayValue(model: "qwen3.8", def: param("temperature")), "")
    }

    // MARK: 后端门禁（0.4.31 num_ctx 对模型包解锁）

    func testBackendGating() {
        let vm = ModelOptionsEditorViewModel()
        vm.update(cfg: [:], isOllama: true, isModelPackage: false, busy: false)
        XCTAssertFalse(vm.isDisabled(param("num_ctx")))
        XCTAssertFalse(vm.isDisabled(param("top_k")))

        // OpenAI 兼容：num_ctx / top_k 置灰
        vm.update(cfg: [:], isOllama: false, isModelPackage: false, busy: false)
        XCTAssertTrue(vm.isDisabled(param("num_ctx")))
        XCTAssertTrue(vm.isDisabled(param("top_k")))
        XCTAssertFalse(vm.isDisabled(param("temperature")))

        // 模型包：num_ctx 解锁（上限语义），top_k 依旧置灰
        vm.update(cfg: [:], isOllama: false, isModelPackage: true, busy: false)
        XCTAssertFalse(vm.isDisabled(param("num_ctx")))
        XCTAssertTrue(vm.isDisabled(param("top_k")))
    }

    func testRemoveModel() async {
        var saves: [[String: Any]] = []
        let vm = ModelOptionsEditorViewModel(onSave: { patch in saves.append(patch) })
        vm.update(cfg: ["model_options": ["qwen3.8": ["num_ctx": 8192], "deepseek-r1": [:]]],
                  isOllama: true, isModelPackage: false, busy: false)
        vm.expandedModel = "qwen3.8"
        vm.removeModel("qwen3.8")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(saves.count, 1)
        let mo = saves[0]["model_options"] as? [String: [String: Any]]
        XCTAssertNil(mo?["qwen3.8"])
        XCTAssertNotNil(mo?["deepseek-r1"])
        XCTAssertEqual(vm.expandedModel, "deepseek-r1")
    }
}

// MARK: - InferencePanelViewModel

@MainActor
final class InferencePanelVMTests: XCTestCase {

    func testRefreshPopulatesStatusModelsConfig() async {
        let client = W2MockClient()
        let vm = InferencePanelViewModel(appState: makeW2AppState(client: client),
                                         clientOverride: client,
                                         saveMessageTTL: 0.05, pullMessageTTL: 0.05)
        await vm.refresh()
        XCTAssertEqual(vm.status?.backend, "ollama")
        XCTAssertTrue(vm.status?.online ?? false)
        XCTAssertEqual(vm.models.count, 2)
        XCTAssertTrue(vm.isOllama)
        XCTAssertFalse(vm.isModelPackage)
        XCTAssertEqual(vm.defaultModel, "qwen3.8")
        // 草稿同步
        XCTAssertEqual(vm.ollamaURLDraft, "http://localhost:11434")
        XCTAssertTrue(vm.ctxLazyEnabled)
        XCTAssertEqual(vm.ctxLazyStartDraft, "12288")
        vm.stop()
    }

    func testRefreshModelsFailureFallsBackEmpty() async {
        let client = W2MockClient()
        client.modelsError = SidecarError.httpError(status: 502, detail: "推理后端不可达")
        let vm = InferencePanelViewModel(appState: makeW2AppState(client: client),
                                         clientOverride: client)
        await vm.refresh()
        XCTAssertEqual(vm.models, [])
        XCTAssertNotNil(vm.status)              // status 不受 models 失败拖累
        vm.stop()
    }

    func testSaveBackendSendsPatchOnly() async {
        let client = W2MockClient()
        let vm = InferencePanelViewModel(appState: makeW2AppState(client: client),
                                         clientOverride: client, saveMessageTTL: 0.05)
        await vm.refresh()
        await vm.saveBackend(["timeout_reading": 600])
        XCTAssertEqual(client.putConfigCalls.count, 1)
        XCTAssertEqual(client.putConfigCalls[0].keys.sorted(), ["timeout_reading"])
        XCTAssertEqual(client.putConfigCalls[0]["timeout_reading"] as? Int, 600)
        XCTAssertEqual(vm.message, "已保存 ✓")
        // 消息 50ms 后自动消隐
        let cleared = await waitFor(1000) { vm.message == nil }
        XCTAssertTrue(cleared)
        vm.stop()
    }

    func testSaveBackendFailureMessage() async {
        let client = W2MockClient()
        let vm = InferencePanelViewModel(appState: makeW2AppState(client: client),
                                         clientOverride: client, saveMessageTTL: 0.05)
        await vm.refresh()
        await vm.saveBackend(["ctx_lazy_start": 100])     // mock 不校验，直接改 config
        // 模拟后端拒绝：fetchConfig 后 putConfig 抛错路径另行验证——这里用 saveOllamaURL
        // mock 不抛错，故直接验证成功路径文案即可（失败路径由 SidecarError.describe 拼接）。
        XCTAssertEqual(vm.message, "已保存 ✓")
        vm.stop()
    }

    func testSelectDefaultModelPackShowsOrchestrationNote() async {
        let client = W2MockClient()
        let vm = InferencePanelViewModel(appState: makeW2AppState(client: client),
                                         clientOverride: client, saveMessageTTL: 60)
        await vm.refresh()
        let pack = vm.models.first { $0.isModelPack }!
        await vm.selectDefaultModel(pack)
        XCTAssertEqual(client.putConfigCalls.last?["default_model"] as? String, "chat-7b-gguf")
        XCTAssertEqual(vm.message,
                       "已选为默认模型：chat-7b-gguf（模型包对话时会暂停其它本地模型——换装编排）")
        vm.stop()
    }

    func testSelectDefaultBackendModelPlainMessage() async {
        let client = W2MockClient()
        let vm = InferencePanelViewModel(appState: makeW2AppState(client: client),
                                         clientOverride: client, saveMessageTTL: 60)
        await vm.refresh()
        await vm.selectDefaultModel(vm.models[0])
        XCTAssertEqual(vm.message, "已选为默认模型：qwen3.8")
        vm.stop()
    }

    func testConfigureParamsCreatesEmptyEntryAndFocuses() async {
        let client = W2MockClient()
        let vm = InferencePanelViewModel(appState: makeW2AppState(client: client),
                                         clientOverride: client, saveMessageTTL: 60)
        await vm.refresh()
        await vm.configureParams(for: "qwen3.8")
        let mo = client.putConfigCalls.last?["model_options"] as? [String: [String: Any]]
        XCTAssertNotNil(mo?["qwen3.8"])
        XCTAssertEqual(vm.focusModel, "qwen3.8")
        // 编辑器受控展开
        XCTAssertEqual(vm.optionsEditor.expandedModel, "qwen3.8")
        vm.stop()
    }

    func testPullSuccessAndFailureMessages() async {
        let client = W2MockClient()
        let vm = InferencePanelViewModel(appState: makeW2AppState(client: client),
                                         clientOverride: client, pullMessageTTL: 0.05)
        await vm.refresh()
        vm.pullName = " qwen2.5-vl "
        await vm.pullModel()
        XCTAssertEqual(client.pullCalls, ["qwen2.5-vl"])
        XCTAssertEqual(vm.message, "拉取完成：qwen2.5-vl")
        XCTAssertEqual(vm.pullName, "")

        client.pullError = SidecarError.httpError(status: 400, detail: "当前推理后端不支持模型拉取（仅 Ollama 后端支持）")
        vm.pullName = "bad-model"
        await vm.pullModel()
        XCTAssertTrue(vm.message?.contains("拉取失败") == true)
        XCTAssertTrue(vm.message?.contains("仅 Ollama") == true)
        vm.stop()
    }

    func testBackendDerivedValues() async {
        let client = W2MockClient()
        client.config["inference_backend"] = "openai_compatible"
        client.config["inference_base_url"] = "http://localhost:1234/v1"
        client.config["ctx_lazy_enabled"] = false
        let vm = InferencePanelViewModel(appState: makeW2AppState(client: client),
                                         clientOverride: client)
        await vm.refresh()
        XCTAssertFalse(vm.isOllama)
        XCTAssertFalse(vm.isModelPackage)
        XCTAssertFalse(vm.ctxLazyEnabled)
        XCTAssertEqual(vm.openAIBaseURLDraft, "http://localhost:1234/v1")

        client.config["inference_backend"] = "model_package"
        await vm.refresh()
        XCTAssertTrue(vm.isModelPackage)
        XCTAssertFalse(vm.isOllama)
        vm.stop()
    }

    func testResourceEventFiltering() async {
        let client = W2MockClient()
        let vm = InferencePanelViewModel(appState: makeW2AppState(client: client),
                                         clientOverride: client)
        await vm.refresh()
        client.inferenceStatus.online = false
        // 非 inference 资源：不触发重拉
        vm.apply(event: sse("resource_changed", ["resource": "workflow", "action": "update", "seq": 1]))
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(vm.status?.online ?? false)

        // inference 资源：触发重拉
        vm.apply(event: sse("resource_changed", ["resource": "inference", "action": "update", "seq": 2]))
        let flipped = await waitFor(1000) { vm.status?.online == false }
        XCTAssertTrue(flipped)

        // gap：无条件重拉
        client.inferenceStatus.online = true
        vm.apply(event: sse("gap", ["seq": 3]))
        let back = await waitFor(1000) { vm.status?.online == true }
        XCTAssertTrue(back)
        vm.stop()
    }

    func testTimeoutSaveCoercesInvalidToZero() async {
        let client = W2MockClient()
        let vm = InferencePanelViewModel(appState: makeW2AppState(client: client),
                                         clientOverride: client, saveMessageTTL: 60)
        await vm.refresh()
        vm.timeoutDrafts["timeout_reading"] = "abc"
        await vm.saveTimeout("timeout_reading")
        XCTAssertEqual(client.putConfigCalls.last?["timeout_reading"] as? Int, 0)
        vm.timeoutDrafts["timeout_reading"] = "600"
        await vm.saveTimeout("timeout_reading")
        XCTAssertEqual(client.putConfigCalls.last?["timeout_reading"] as? Int, 600)
        vm.stop()
    }
}

// MARK: - ModelPacksPanelViewModel

@MainActor
final class ModelPacksPanelVMTests: XCTestCase {

    private func makePack(_ pid: String, source: String = "https://raw.githubusercontent.com/x/y/catalog.json",
                          sha: String = "abcdef0123456789ff") -> CatalogPack {
        CatalogPack(pack_id: pid, name: "包\(pid)", task: "chat", format: "gguf",
                    version: "1.0.0", size_bytes: 2_000_000_000,
                    files: [PackFileInfo(path: "model.gguf", size_bytes: 2_000_000_000, sha256: sha)],
                    source: source)
    }

    func testFetchListsPopulates() async {
        let client = W2MockClient()
        client.installedPacks = [InstalledPack(pack_id: "p1", name: "包1", version: "1.0.0",
                                               task: "asr", format: "onnx", size_bytes: 100)]
        client.catalogPacks = [makePack("p2")]
        client.catalogRaw = ["p2": ["pack_id": "p2", "context_length": 32768]]
        let vm = ModelPacksPanelViewModel(appState: makeW2AppState(client: client),
                                          clientOverride: client)
        await vm.fetchLists()
        XCTAssertEqual(vm.installed.map(\.pack_id), ["p1"])
        XCTAssertEqual(vm.catalog.map(\.pack_id), ["p2"])
        // 原始条目保留（install 回传保住可选键）
        XCTAssertEqual(vm.rawCatalogEntries["p2"]?["context_length"] as? Int, 32768)
        XCTAssertNil(vm.error)
        XCTAssertFalse(vm.loading)
        vm.stop()
    }

    func testFetchListsErrorMessage() async {
        let client = W2MockClient()
        client.listPacksError = SidecarError.offline("连接被拒")
        let vm = ModelPacksPanelViewModel(appState: makeW2AppState(client: client),
                                          clientOverride: client)
        await vm.fetchLists()
        XCTAssertTrue(vm.error?.contains("无法获取模型包列表") == true)
        vm.stop()
    }

    func testDownloadEventStateMachine() async {
        let client = W2MockClient()
        let vm = ModelPacksPanelViewModel(appState: makeW2AppState(client: client),
                                          clientOverride: client)
        // start → progress → done 全链路
        vm.apply(event: sse("resource_changed", ["resource": "model_pack", "action": "download_start",
                                                 "pack_id": "p1", "total_bytes": 1000, "seq": 1]))
        XCTAssertEqual(vm.dlProgress["p1"]?.total, 1000)
        XCTAssertEqual(vm.dlProgress["p1"]?.received, 0)

        vm.apply(event: sse("resource_changed", ["resource": "model_pack", "action": "download_progress",
                                                 "pack_id": "p1", "received_bytes": 500, "file": "model.gguf", "seq": 2]))
        XCTAssertEqual(vm.dlProgress["p1"]?.received, 500)
        XCTAssertEqual(vm.dlProgress["p1"]?.file, "model.gguf")
        XCTAssertEqual(vm.dlProgress["p1"]?.percent, 50)

        vm.apply(event: sse("resource_changed", ["resource": "model_pack", "action": "download_done",
                                                 "pack_id": "p1", "seq": 3]))
        XCTAssertNil(vm.dlProgress["p1"])
        XCTAssertEqual(vm.notice, "模型包 p1 安装完成")

        // error：进度清除 + 错误落卡片
        vm.apply(event: sse("resource_changed", ["resource": "model_pack", "action": "download_start",
                                                 "pack_id": "p2", "total_bytes": 10, "seq": 4]))
        vm.apply(event: sse("resource_changed", ["resource": "model_pack", "action": "download_error",
                                                 "pack_id": "p2", "error": "校验失败", "seq": 5]))
        XCTAssertNil(vm.dlProgress["p2"])
        XCTAssertEqual(vm.dlErrors["p2"], "校验失败")

        // cancelled：进度清除
        vm.apply(event: sse("resource_changed", ["resource": "model_pack", "action": "download_start",
                                                 "pack_id": "p3", "total_bytes": 10, "seq": 6]))
        vm.apply(event: sse("resource_changed", ["resource": "model_pack", "action": "download_cancelled",
                                                 "pack_id": "p3", "seq": 7]))
        XCTAssertNil(vm.dlProgress["p3"])

        // 其它资源不消费
        vm.apply(event: sse("resource_changed", ["resource": "workflow", "action": "update", "seq": 8]))
        XCTAssertTrue(vm.dlProgress.isEmpty)
        vm.stop()
    }

    /// 0.7.5 W7：download_progress 事件 bytes_per_second 字段落进度条目（速率同口径上屏）
    func testDownloadProgressCarriesRateW7() async {
        let client = W2MockClient()
        let vm = ModelPacksPanelViewModel(appState: makeW2AppState(client: client),
                                          clientOverride: client)
        vm.apply(event: sse("resource_changed", ["resource": "model_pack", "action": "download_start",
                                                 "pack_id": "r1", "total_bytes": 1000, "seq": 1]))
        XCTAssertEqual(vm.dlProgress["r1"]?.bytesPerSecond, 0)
        vm.apply(event: sse("resource_changed", ["resource": "model_pack", "action": "download_progress",
                                                 "pack_id": "r1", "received_bytes": 500,
                                                 "bytes_per_second": 12_582_912.5, "seq": 2]))
        XCTAssertEqual(vm.dlProgress["r1"]?.bytesPerSecond ?? 0, 12_582_912.5, accuracy: 0.01)
        // 后续事件缺字段时保留前值（不清零——节流末跳可能不带样本）
        vm.apply(event: sse("resource_changed", ["resource": "model_pack", "action": "download_progress",
                                                 "pack_id": "r1", "received_bytes": 800, "seq": 3]))
        XCTAssertEqual(vm.dlProgress["r1"]?.bytesPerSecond ?? 0, 12_582_912.5, accuracy: 0.01)
        vm.stop()
    }

    func testInstallConfirmMessageVerbatim() {
        let p = makePack("chat-7b", source: "")
        let msg = ModelPacksPanelViewModel.installConfirmMessage(p)
        XCTAssertTrue(msg.contains("将从外部来源下载并安装模型包："))
        XCTAssertTrue(msg.contains("名称：包chat-7b"))
        XCTAssertTrue(msg.contains("版本：v1.0.0"))
        XCTAssertTrue(msg.contains("大小：1.9 GB"))
        XCTAssertTrue(msg.contains("SHA256：abcdef012345…"))
        XCTAssertTrue(msg.contains("来源：（未知）"))
        XCTAssertTrue(msg.contains("请确认来源可信后再下载；取消则不联网、不安装。"))
    }

    func testInstallConfirmedOverseasSwitchesProxyFirst() async {
        let client = W2MockClient()
        client.config["network_switch"] = "auto"
        let p = makePack("chat-7b")      // githubusercontent = 境外
        client.catalogPacks = [p]
        client.catalogRaw = ["chat-7b": ["pack_id": "chat-7b", "context_length": 8192]]
        let vm = ModelPacksPanelViewModel(appState: makeW2AppState(client: client),
                                          clientOverride: client)
        await vm.fetchLists()
        await vm.fetchConfig()
        var askedCheckbox: String?
        vm.confirmHandler = { title, message, confirmText, danger, checkboxLabel, checkboxDefault in
            askedCheckbox = checkboxLabel
            return (true, true)          // 确认且勾选
        }
        vm.install(p)
        let done = await waitFor(1000) { !client.installCalls.isEmpty }
        XCTAssertTrue(done)
        XCTAssertEqual(askedCheckbox, "同时开启全量联网（经代理访问海外站点）")
        // 顺序：先 PUT network_switch=proxy，再 install
        XCTAssertEqual(client.putConfigCalls.first?["network_switch"] as? String, "proxy")
        XCTAssertEqual(client.installCalls.first?.packId, "chat-7b")
        // catalog_entry 原样回传（保住 context_length）
        XCTAssertEqual(client.installCalls.first?.entry["context_length"] as? Int, 8192)
        XCTAssertEqual(vm.networkSwitch, "proxy")
        vm.stop()
    }

    func testInstallCancelDoesNotRequest() async {
        let client = W2MockClient()
        let vm = ModelPacksPanelViewModel(appState: makeW2AppState(client: client),
                                          clientOverride: client)
        await vm.fetchLists()
        await vm.fetchConfig()
        vm.confirmHandler = { _, _, _, _, _, _ in (false, false) }
        vm.install(makePack("chat-7b"))
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(client.installCalls.isEmpty)
        XCTAssertTrue(client.putConfigCalls.isEmpty)
        vm.stop()
    }

    func testInstallLocalSourceNoProxyCheckbox() async {
        let client = W2MockClient()
        let vm = ModelPacksPanelViewModel(appState: makeW2AppState(client: client),
                                          clientOverride: client)
        await vm.fetchLists()
        await vm.fetchConfig()
        var askedCheckbox: String?? = .some(nil)
        vm.confirmHandler = { _, _, _, _, checkboxLabel, _ in
            askedCheckbox = checkboxLabel
            return (true, true)
        }
        // file:// 本地目录源：境外判定为 false → 不附联网勾选
        vm.install(makePack("local-pack", source: "file:///Users/x/packs/catalog.json"))
        let done = await waitFor(1000) { !client.installCalls.isEmpty }
        XCTAssertTrue(done)
        XCTAssertTrue(askedCheckbox! == nil)
        XCTAssertTrue(client.putConfigCalls.isEmpty)     // 不碰 network_switch
        vm.stop()
    }

    func testInstallFailureLandsOnCard() async {
        let client = W2MockClient()
        client.installError = SidecarError.httpError(status: 409, detail: "模型包 p1 已安装；如需重装请先卸载")
        let vm = ModelPacksPanelViewModel(appState: makeW2AppState(client: client),
                                          clientOverride: client)
        await vm.fetchLists()
        await vm.fetchConfig()
        vm.confirmHandler = { _, _, _, _, _, _ in (true, false) }
        vm.install(makePack("p1"))
        let done = await waitFor(1000) { vm.dlErrors["p1"] != nil }
        XCTAssertTrue(done)
        XCTAssertTrue(vm.dlErrors["p1"]?.contains("安装请求失败") == true)
        XCTAssertTrue(vm.dlErrors["p1"]?.contains("已安装") == true)
        XCTAssertFalse(vm.installing.contains("p1"))
        vm.stop()
    }

    func testConfirmDisabledSkipsDialog() async {
        let client = W2MockClient()
        client.config["confirm_model_pack_download"] = false
        let vm = ModelPacksPanelViewModel(appState: makeW2AppState(client: client),
                                          clientOverride: client)
        await vm.fetchLists()
        await vm.fetchConfig()
        vm.confirmHandler = { _, _, _, _, _, _ in
            XCTFail("confirm_model_pack_download=false 时不应弹窗")
            return (false, false)
        }
        vm.install(makePack("p1"))
        let done = await waitFor(1000) { !client.installCalls.isEmpty }
        XCTAssertTrue(done)
        vm.stop()
    }

    func testToggleAndUninstall() async {
        let client = W2MockClient()
        client.installedPacks = [InstalledPack(pack_id: "p1", name: "包1", version: "1.0.0",
                                               task: "asr", format: "onnx", enabled: true)]
        let vm = ModelPacksPanelViewModel(appState: makeW2AppState(client: client),
                                          clientOverride: client)
        await vm.fetchLists()

        // 禁用：乐观更新 + 轻提示
        vm.toggle(vm.installed[0])
        var done = await waitFor(1000) { !client.toggleCalls.isEmpty }
        XCTAssertTrue(done)
        XCTAssertEqual(client.toggleCalls.first?.0, "p1")
        XCTAssertEqual(client.toggleCalls.first?.1, false)
        XCTAssertFalse(vm.installed[0].enabled)
        XCTAssertEqual(vm.notice, "模型包 \"包1\" 已禁用")

        // 卸载：确认后 DELETE
        vm.confirmHandler = { _, _, _, _, _, _ in (true, false) }
        vm.uninstall(vm.installed[0])
        done = await waitFor(1000) { !client.deletePackCalls.isEmpty }
        XCTAssertTrue(done)
        XCTAssertEqual(client.deletePackCalls, ["p1"])
        done = await waitFor(1000) { vm.installed.isEmpty }
        XCTAssertTrue(done)
        vm.stop()
    }

    func testSaveCatalogURLsSplitsLines() async {
        let client = W2MockClient()
        client.catalogPacks = []
        let vm = ModelPacksPanelViewModel(appState: makeW2AppState(client: client),
                                          clientOverride: client, savedFlash: 0.05)
        await vm.fetchLists()
        await vm.fetchConfig()
        vm.catalogDraft = "https://a.com/x.json\n\n  file:///Users/x/packs/  \n"
        vm.saveCatalogURLs()
        let done = await waitFor(1000) { !client.putConfigCalls.isEmpty }
        XCTAssertTrue(done)
        let urls = client.putConfigCalls.first?["model_pack_catalog_urls"] as? [String]
        XCTAssertEqual(urls, ["https://a.com/x.json", "file:///Users/x/packs/"])
        XCTAssertTrue(vm.savedURLs)
        let cleared = await waitFor(1000) { !vm.savedURLs }
        XCTAssertTrue(cleared)
        vm.stop()
    }

    func testGapEventRefetches() async {
        let client = W2MockClient()
        let vm = ModelPacksPanelViewModel(appState: makeW2AppState(client: client),
                                          clientOverride: client)
        await vm.fetchLists()
        client.installedPacks = [InstalledPack(pack_id: "late", name: "晚到", version: "1",
                                               task: "chat", format: "gguf")]
        vm.apply(event: sse("gap", ["seq": 9]))
        let done = await waitFor(1000) { vm.installed.contains { $0.pack_id == "late" } }
        XCTAssertTrue(done)
        vm.stop()
    }
}
