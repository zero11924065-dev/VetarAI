//
//  NativeInferenceEndpointsTests.swift
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

//  覆盖（⛔ 行为规格源 subagent/sidecar/app.py L428-592 + ollama/* 逐条对照）：
//    · status：ollama 在线形状 / 离线 detail ≤200 / 8s 超时文案逐字 /
//      openai 能力表+base_url 原值 / 地址缺失文案逐字 / 未知后端落 ollama 行
//    · models：并集行映射（name/id/size 键存在性/details∨直挂 ctx/source 标注）
//      + MP 并集追加 / openai 名单形态 / 502 文案前缀
//    · pull/delete：能力表门控 400 逐字（openai 与 model_package 同文案）/
//      NDJSON 行透传（空白跳过、原样保留）/ deleted:false 不抛错
//    · context/limit：四级回退梯（config 平值 / config 懒档 ceiling+lazy /
//      R3 键去 tag 命中 / ps 匹配三形态+假值续扫 / show / 262144 兜底 /
//      error 不落 show / openai unsupported）
//    · 客户端翻转：MP 整端点 HTTP 转发（status/models/context-limit）/
//      MP 面翻原生 / mpUnionFetcher 回源与降级 / listInferenceModels 映射
//

import XCTest
@testable import VetarAINative

// ════════════════════════════════════════════════════════════
// MARK: - 装配体单测（缝全 stub，不触网）
// ════════════════════════════════════════════════════════════

final class NativeInferenceEndpointsTests: XCTestCase {

    private var base: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3w2a_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
        base = nil
        try super.tearDownWithError()
    }

    private func makeKernel(_ tag: String) -> NativeKernel {
        NativeKernel(dataRoot: base.appendingPathComponent(tag))
    }

    /// 手写 config.json（绕过 reloadConfig 校验——构造合法写达不到的形态，
    /// 如未知后端值/openai 缺地址；Python get_config 读侧同样宽容）。
    private func writeRawConfig(_ kernel: NativeKernel, _ obj: [String: JSONValue]) throws {
        let url = kernel.dataRoot.appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: kernel.dataRoot, withIntermediateDirectories: true)
        let text = NativeDatabase.dumpsUTF8(.object(obj))
        try text.write(to: url, atomically: false, encoding: .utf8)
    }

    // MARK: status（app.py L446-472）

    /// ollama 在线：{backend, base_url=config 原值, online, detail="", 能力表全真}。
    func testStatusOllamaOnline() async throws {
        let kernel = makeKernel("d1")
        let asm = kernel.inferenceEndpoints
        asm.ollamaTags = { base in
            XCTAssertEqual(base, "http://localhost:11434")   // 默认 config 键 + rstrip
            return [["name": .string("qwen3.8")]]
        }
        asm.openAIModelIDs = { _, _ in XCTFail("ollama 后端不得走 openai 缝"); return [] }
        let st = await asm.status()
        XCTAssertEqual(st.backend, "ollama")
        XCTAssertEqual(st.base_url, "http://localhost:11434")
        XCTAssertTrue(st.online)
        XCTAssertEqual(st.detail, "")
        XCTAssertEqual(st.capabilities,
                       InferenceCapabilities(tools: true, vision: true, pull: true, delete: true))
    }

    /// ollama 离线：detail = 错误描述前 200 字（str(e)[:200] 等价），online=false。
    func testStatusOllamaOfflineDetail() async throws {
        let kernel = makeKernel("d2")
        let asm = kernel.inferenceEndpoints
        asm.ollamaTags = { _ in throw NativeInferenceError.transport("连接被拒绝") }
        let st = await asm.status()
        XCTAssertFalse(st.online)
        XCTAssertEqual(st.detail, "连接被拒绝")
        XCTAssertLessThanOrEqual(st.detail.count, 200)
    }

    /// 探活超时：文案逐字（app.py L459）。probeTimeout 压小到 0.05s 保测试速度。
    func testStatusProbeTimeoutVerbatim() async throws {
        let kernel = makeKernel("d3")
        let asm = kernel.inferenceEndpoints
        asm.probeTimeout = 0.05
        asm.ollamaTags = { _ in
            try? await Task.sleep(nanoseconds: 500_000_000)
            return []
        }
        let st = await asm.status()
        XCTAssertFalse(st.online)
        XCTAssertEqual(st.detail, "连接超时（8s），请检查地址是否正确、服务是否启动")
    }

    /// openai_compatible：能力表 tools 读 openai_compat_supports_tools（false），
    /// vision 真、pull/delete 假；base_url 返回 config 原值（不 strip/rstrip）；
    /// 探测走 openai 缝且 base/key 经 strip+rstrip。
    func testStatusOpenAICapsAndBaseURL() async throws {
        let kernel = makeKernel("d4")
        _ = try kernel.config.reloadConfig(patch: [
            "inference_backend": .string("openai_compatible"),
            "inference_base_url": .string(" http://host:1234/v1/ "),
            "inference_api_key": .string(" sk-x "),
            "openai_compat_supports_tools": .bool(false),
        ])
        let asm = kernel.inferenceEndpoints
        asm.ollamaTags = { _ in XCTFail("openai 后端不得走 ollama 缝"); return [] }
        asm.openAIModelIDs = { base, key in
            XCTAssertEqual(base, "http://host:1234/v1")
            XCTAssertEqual(key, "sk-x")
            return ["gpt-x"]
        }
        let st = await asm.status()
        XCTAssertEqual(st.backend, "openai_compatible")
        XCTAssertEqual(st.base_url, " http://host:1234/v1/ ", "base_url 返回 config 原值（L469）")
        XCTAssertTrue(st.online)
        XCTAssertEqual(st.capabilities,
                       InferenceCapabilities(tools: false, vision: true, pull: false, delete: false))
    }

    /// openai 地址未配置：detail 逐字（openai_compat._base() L77-78）。
    func testStatusOpenAIMissingBaseURLVerbatim() async throws {
        let kernel = makeKernel("d5")
        try writeRawConfig(kernel, ["inference_backend": .string("openai_compatible")])
        let asm = kernel.inferenceEndpoints
        asm.openAIModelIDs = { base, _ in
            guard !base.isEmpty else { throw NativeInferenceError.backendURLMissing }
            return []
        }
        let st = await asm.status()
        XCTAssertFalse(st.online)
        XCTAssertEqual(st.detail, "推理后端地址未配置（设置面板：推理后端 → 地址）")
    }

    /// live fetcher 层地址空短路与文案（不触网）。
    func testLiveOpenAIModelIDsEmptyBase() async {
        await XCTAssertThrowsErrorAsync({
            try await NativeInferenceEndpointAssembly.liveOpenAIModelIDs("", "k")
        }) { err in
            XCTAssertEqual(String(describing: err), "推理后端地址未配置（设置面板：推理后端 → 地址）")
        }
    }

    /// 未知后端值（手写 config 绕过校验）：routing._active() else 分支 → ollama 行能力表
    /// + ollama 探测缝；base_url 走 else 分支（inference_base_url）。
    func testStatusUnknownBackendFallsToOllamaConnector() async throws {
        let kernel = makeKernel("d6")
        try writeRawConfig(kernel, [
            "inference_backend": .string("bogus"),
            "inference_base_url": .string("http://else-branch"),
        ])
        let asm = kernel.inferenceEndpoints
        asm.ollamaTags = { _ in return [["name": .string("m")]] }
        asm.openAIModelIDs = { _, _ in XCTFail("未知后端落 ollama 连接器"); return [] }
        let st = await asm.status()
        XCTAssertEqual(st.backend, "bogus")
        XCTAssertEqual(st.base_url, "http://else-branch")
        XCTAssertTrue(st.online)
        XCTAssertEqual(st.capabilities,
                       InferenceCapabilities(tools: true, vision: true, pull: true, delete: true))
    }

    // MARK: models（app.py L474-498 + routing.py L189-205）

    /// ollama 并集行映射全形态 + MP 并集追加。
    func testModelsOllamaUnionAndRowMapping() async throws {
        let kernel = makeKernel("d7")
        let asm = kernel.inferenceEndpoints
        asm.ollamaTags = { _ in [
            ["name": .string("qwen3.8"), "size": .int(100),
             "details": .object(["context_length": .int(262144)])],
            ["name": .string("m2"), "context_length": .int(8192)],
            ["id": .string("fallback-id")],
            ["name": .string("")],                                   // 空名跳过
            ["name": .string("m3"), "size": .int(0)],                // size 键在 → 0 也带
            ["name": .string("m4"),
             "details": .object(["context_length": .int(0)]),        // details 假值
             "context_length": .int(4096)],                          // → 直挂值
        ] }
        let out = try await asm.models {
            [InferenceModelEntry(name: "pack-x", size: 5, context_length: 32768, source: "model_pack")]
        }
        XCTAssertEqual(out, [
            InferenceModelEntry(name: "qwen3.8", size: 100, context_length: 262144, source: "ollama"),
            InferenceModelEntry(name: "m2", size: nil, context_length: 8192, source: "ollama"),
            InferenceModelEntry(name: "fallback-id", size: nil, context_length: nil, source: "ollama"),
            InferenceModelEntry(name: "m3", size: 0, context_length: nil, source: "ollama"),
            InferenceModelEntry(name: "m4", size: nil, context_length: 4096, source: "ollama"),
            InferenceModelEntry(name: "pack-x", size: 5, context_length: 32768, source: "model_pack"),
        ])
    }

    /// openai 名单：仅 name + source=openai_compatible（无 size/ctx 键）。
    func testModelsOpenAISourceTag() async throws {
        let kernel = makeKernel("d8")
        _ = try kernel.config.reloadConfig(patch: [
            "inference_backend": .string("openai_compatible"),
            "inference_base_url": .string("http://host/v1"),
        ])
        let asm = kernel.inferenceEndpoints
        asm.openAIModelIDs = { _, _ in ["a", "b"] }
        asm.ollamaTags = { _ in XCTFail("openai 后端不得走 ollama 缝"); return [] }
        let out = try await asm.models { [] }
        XCTAssertEqual(out, [
            InferenceModelEntry(name: "a", source: "openai_compatible"),
            InferenceModelEntry(name: "b", source: "openai_compatible"),
        ])
    }

    /// 活动后端失败 → 502 + 逐字前缀（app.py L481）。
    func testModelsActiveFailure502() async throws {
        let kernel = makeKernel("d9")
        let asm = kernel.inferenceEndpoints
        asm.ollamaTags = { _ in throw NativeInferenceError.transport("连接被拒绝") }
        await XCTAssertThrowsErrorAsync({ try await asm.models { [] } }) { err in
            guard case SidecarError.httpError(let status, let detail) = err else {
                return XCTFail("应为 httpError：\(err)")
            }
            XCTAssertEqual(status, 502)
            XCTAssertTrue(detail.hasPrefix("推理后端不可达："), "detail=\(detail)")
        }
    }

    // MARK: pull / delete 门控与透传（app.py L428-444）

    /// pull 门控：openai 与 model_package 同文案 400（能力表是唯一事实源，无需 HTTP）。
    func testPullGatingRefusedVerbatim() async throws {
        let kernel = makeKernel("d10")
        _ = try kernel.config.reloadConfig(patch: [
            "inference_backend": .string("openai_compatible"),
            "inference_base_url": .string("http://host/v1"),
        ])
        let asm = kernel.inferenceEndpoints
        asm.ollamaPullLines = { _, _ in XCTFail("门控应先于出站"); return [] }
        await XCTAssertThrowsErrorAsync({ try await asm.pull(name: "m") }) { err in
            XCTAssertEqual(err.httpDetail, "当前推理后端不支持模型拉取（仅 Ollama 后端支持）")
            XCTAssertEqual(err.httpStatus, 400)
        }
        _ = try kernel.config.reloadConfig(patch: ["inference_backend": .string("model_package")])
        await XCTAssertThrowsErrorAsync({ try await asm.pull(name: "m") }) { err in
            XCTAssertEqual(err.httpDetail, "当前推理后端不支持模型拉取（仅 Ollama 后端支持）")
            XCTAssertEqual(err.httpStatus, 400)
        }
    }

    /// pull 透传：NDJSON 行原样返回；base 取 config ollama_base_url。
    func testPullPassthrough() async throws {
        let kernel = makeKernel("d11")
        let asm = kernel.inferenceEndpoints
        asm.ollamaPullLines = { base, name in
            XCTAssertEqual(base, "http://localhost:11434")
            XCTAssertEqual(name, "qwen3.8")
            return ["{\"status\":\"pulling manifest\"}", "{\"status\":\"success\"}"]
        }
        let lines = try await asm.pull(name: "qwen3.8")
        XCTAssertEqual(lines, ["{\"status\":\"pulling manifest\"}", "{\"status\":\"success\"}"])
    }

    /// NDJSON 行收集纯函数：空白行跳过、其余原样（含行内空白与 \r\n 形态）。
    func testNDJSONLinesFiltering() {
        let data = "{\"a\":1}\n\n   \n{\"b\":2}\r\n{\"c\":3}\n".data(using: .utf8)!
        XCTAssertEqual(NativeInferenceEndpointAssembly.ndjsonLines(data),
                       ["{\"a\":1}", "{\"b\":2}", "{\"c\":3}"])
        XCTAssertEqual(NativeInferenceEndpointAssembly.ndjsonLines(Data()), [])
    }

    /// delete 门控 400 逐字 + deleted 布尔透传（false 不抛错，端点 200 口径）。
    func testDeleteGatingAndResultPassthrough() async throws {
        let kernel = makeKernel("d12")
        _ = try kernel.config.reloadConfig(patch: [
            "inference_backend": .string("openai_compatible"),
            "inference_base_url": .string("http://host/v1"),
        ])
        let asm = kernel.inferenceEndpoints
        asm.ollamaDeleteModel = { _, _ in XCTFail("门控应先于出站"); return false }
        await XCTAssertThrowsErrorAsync({ try await asm.delete(name: "m") }) { err in
            XCTAssertEqual(err.httpDetail, "当前推理后端不支持模型删除（仅 Ollama 后端支持）")
            XCTAssertEqual(err.httpStatus, 400)
        }
        _ = try kernel.config.reloadConfig(patch: ["inference_backend": .string("ollama")])
        asm.ollamaDeleteModel = { _, _ in true }
        let deleted = try await asm.delete(name: "m")
        XCTAssertTrue(deleted)
        asm.ollamaDeleteModel = { _, _ in false }
        let notDeleted = try await asm.delete(name: "m")
        XCTAssertFalse(notDeleted, "deleted:false 不抛错（app.py L443-444）")
    }

    // MARK: context/limit（app.py L500-592）

    /// 第 1 级·平值：懒加载关闭 → 报配置全量（无 ceiling/lazy）；ps/show 不得触达。
    func testContextLimitConfigPlain() async throws {
        let kernel = makeKernel("d13")
        _ = try kernel.config.reloadConfig(patch: [
            "ctx_lazy_enabled": .bool(false),
            "model_options": .object(["qwen3.8": .object(["num_ctx": .int(32768)])]),
        ])
        let asm = kernel.inferenceEndpoints
        asm.ollamaPS = { _ in XCTFail("config 级命中不得查 ps"); return [] }
        asm.ollamaShowContextLength = { _, _ in XCTFail("config 级命中不得查 show"); return nil }
        let info = await asm.contextLimit(model: "qwen3.8")
        XCTAssertEqual(info, ContextLimitInfo(limit: 32768, source: "config", ceiling: 0, lazy: false))
    }

    /// 第 1 级·懒档：默认开启 → 报当前档（min(12288, 上限)）+ ceiling/lazy 追加。
    func testContextLimitConfigLazyTier() async throws {
        let kernel = makeKernel("d14")
        _ = try kernel.config.reloadConfig(patch: [
            "model_options": .object([
                "big": .object(["num_ctx": .int(65536)]),
                "small": .object(["num_ctx": .int(8192)]),
            ]),
        ])
        let asm = kernel.inferenceEndpoints
        asm.ollamaPS = { _ in XCTFail("config 级命中不得查 ps"); return [] }
        let big = await asm.contextLimit(model: "big")
        XCTAssertEqual(big, ContextLimitInfo(limit: 12288, source: "config",
                                             ceiling: 65536, lazy: true))
        // 上限 < 起始档 → 起始档即上限（D2 直接全量）
        let small = await asm.contextLimit(model: "small")
        XCTAssertEqual(small, ContextLimitInfo(limit: 8192, source: "config",
                                               ceiling: 8192, lazy: true))
    }

    /// 第 1 级·键匹配：配置键带 tag（qwen3.8:latest）命中查询去 tag（R3 第三级）。
    func testContextLimitConfigKeyStripMatching() async throws {
        let kernel = makeKernel("d15")
        _ = try kernel.config.reloadConfig(patch: [
            "ctx_lazy_enabled": .bool(false),
            "model_options": .object(["qwen3.8:latest": .object(["num_ctx": .int(50000)])]),
        ])
        let asm = kernel.inferenceEndpoints
        asm.ollamaPS = { _ in XCTFail("config 级命中不得查 ps"); return [] }
        let info = await asm.contextLimit(model: "qwen3.8")
        XCTAssertEqual(info, ContextLimitInfo(limit: 50000, source: "config"))
    }

    /// 第 2 级·ps：name 匹配三形态（== / 前缀+: / 前缀）；cl 假值续扫下一匹配。
    func testContextLimitPSLevel() async throws {
        let kernel = makeKernel("d16")
        let asm = kernel.inferenceEndpoints
        asm.ollamaPS = { _ in [
            ["name": .string("other:7b"), "context_length": .int(100)],
            ["name": .string("qwen3.8:latest"), "context_length": .int(131072)],
        ] }
        asm.ollamaShowContextLength = { _, _ in XCTFail("ps 命中不得落 show"); return nil }
        let info = await asm.contextLimit(model: "qwen3.8")
        XCTAssertEqual(info, ContextLimitInfo(limit: 131072, source: "ps"))

        // cl=0 假值 → 续扫；details.context_length 同权
        asm.ollamaPS = { _ in [
            ["name": .string("qwen3.8:latest"), "context_length": .int(0)],
            ["name": .string("qwen3.8-pro"),
             "details": .object(["context_length": .int(64000)])],
        ] }
        let info2 = await asm.contextLimit(model: "qwen3.8")
        XCTAssertEqual(info2, ContextLimitInfo(limit: 64000, source: "ps"))
    }

    /// 第 3 级·show：ps 无匹配 → show 的 model_info .context_length。
    func testContextLimitShowLevel() async throws {
        let kernel = makeKernel("d17")
        let asm = kernel.inferenceEndpoints
        asm.ollamaPS = { _ in [["name": .string("other:7b"), "context_length": .int(100)]] }
        asm.ollamaShowContextLength = { base, model in
            XCTAssertEqual(base, "http://localhost:11434")
            XCTAssertEqual(model, "qwen3.8")
            return 131072
        }
        let info = await asm.contextLimit(model: "qwen3.8")
        XCTAssertEqual(info, ContextLimitInfo(limit: 131072, source: "show"))
    }

    /// 第 4 级·兜底：ps 无匹配 + show nil → 262144/default。
    func testContextLimitDefaultLevel() async throws {
        let kernel = makeKernel("d18")
        let asm = kernel.inferenceEndpoints
        asm.ollamaPS = { _ in [] }
        asm.ollamaShowContextLength = { _, _ in nil }
        let info = await asm.contextLimit(model: "qwen3.8")
        XCTAssertEqual(info, ContextLimitInfo(limit: 262144, source: "default"))
    }

    /// error：ps 请求失败 → {0, error}，不落 show（外层 except 口径，L591-592）。
    func testContextLimitErrorBranch() async throws {
        let kernel = makeKernel("d19")
        let asm = kernel.inferenceEndpoints
        asm.ollamaPS = { _ in throw NativeInferenceError.transport("连接被拒绝") }
        asm.ollamaShowContextLength = { _, _ in XCTFail("ps 失败不落 show"); return nil }
        let info = await asm.contextLimit(model: "qwen3.8")
        XCTAssertEqual(info, ContextLimitInfo(limit: 0, source: "error"))
    }

    /// unsupported：openai_compatible → {0, unsupported}，无任何出站。
    func testContextLimitUnsupportedOpenAI() async throws {
        let kernel = makeKernel("d20")
        _ = try kernel.config.reloadConfig(patch: [
            "inference_backend": .string("openai_compatible"),
            "inference_base_url": .string("http://host/v1"),
        ])
        let asm = kernel.inferenceEndpoints
        asm.ollamaPS = { _ in XCTFail("unsupported 不得出站"); return [] }
        asm.ollamaTags = { _ in XCTFail("unsupported 不得出站"); return [] }
        let info = await asm.contextLimit(model: "gpt-x")
        XCTAssertEqual(info, ContextLimitInfo(limit: 0, source: "unsupported"))
    }

    /// show model_info 扫描纯函数：.context_length 后缀键 + 正整数值。
    func testShowContextLengthScan() {
        XCTAssertEqual(NativeInferenceEndpointAssembly.showContextLength(from: [
            "qwen35.context_length": .int(262144), "other": .int(1)]), 262144)
        XCTAssertNil(NativeInferenceEndpointAssembly.showContextLength(from: [
            "a.context_length": .int(0)]))
        XCTAssertNil(NativeInferenceEndpointAssembly.showContextLength(from: [
            "a.context_length": .int(-5)]))
        XCTAssertNil(NativeInferenceEndpointAssembly.showContextLength(from: [:]))
        XCTAssertNil(NativeInferenceEndpointAssembly.showContextLength(from: [
            "a.context_length": .string("x")]))
    }
}

// ════════════════════════════════════════════════════════════
// MARK: - 客户端翻转（NativeSidecarClient+Panels 分流纪律）
// ════════════════════════════════════════════════════════════

final class NativeInferenceClientFlipTests: XCTestCase {

    private var base: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3w2af_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
        base = nil
        try super.tearDownWithError()
    }

    private func makeKernel(_ tag: String) -> NativeKernel {
        NativeKernel(dataRoot: base.appendingPathComponent(tag))
    }

    /// 种一个最小 chat 包（registry + gguf 占位 + 可选 manifest context_length）。
    private func seedPack(_ kernel: NativeKernel, _ pid: String,
                          contextLength: Int? = nil) throws {
        let pack: [String: JSONValue] = [
            "pack_id": .string(pid), "task": .string("chat"),
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

    /// backend=model_package：status MP 面原生（P3-W3a）——base_url=驱动活动端口
    /// （未启动 ""）、online 恒 true、caps=MP 表（P3-W6 起全原生，无 HTTP fallback 层）。
    func testClientStatusMPNative() async throws {
        let kernel = makeKernel("f1")
        _ = try kernel.config.reloadConfig(patch: ["inference_backend": .string("model_package")])
        kernel.inferenceEndpoints.ollamaTags = { _ in XCTFail("MP 不得走原生探测"); return [] }
        let client = NativeSidecarClient(kernel: kernel)
        let st = try await client.fetchInferenceStatus()
        XCTAssertEqual(st, InferenceStatusInfo(
            backend: "model_package", base_url: "", online: true, detail: "",
            capabilities: InferenceCapabilities(tools: true, vision: false,
                                                pull: false, delete: false)))
    }

    /// ollama：status 原生。
    func testClientStatusNativeNoHTTP() async throws {
        let kernel = makeKernel("f2")
        kernel.inferenceEndpoints.ollamaTags = { _ in [["name": .string("m")]] }
        let client = NativeSidecarClient(kernel: kernel)
        let st = try await client.fetchInferenceStatus()
        XCTAssertTrue(st.online)
        XCTAssertEqual(st.backend, "ollama")
    }

    /// backend=model_package：models MP 面原生（P3-W3a）——注册表聚合（只 enabled
    /// chat 包，并集退化为全 MP）。
    func testClientModelsMPNative() async throws {
        let kernel = makeKernel("f3")
        _ = try kernel.config.reloadConfig(patch: ["inference_backend": .string("model_package")])
        kernel.inferenceEndpoints.ollamaTags = { _ in XCTFail("MP 不得走原生名单"); return [] }
        try seedPack(kernel, "pack-x", contextLength: 8192)
        try seedPack(kernel, "pack-off")
        XCTAssertNotNil(kernel.modelPackStore.setEnabled("pack-off", enabled: false))
        let client = NativeSidecarClient(kernel: kernel)
        let out = try await client.fetchInferenceModels()
        XCTAssertEqual(out, [
            InferenceModelEntry(name: "pack-x", size: 4,
                                context_length: 8192, source: "model_pack"),
        ])
    }

    /// ollama：models 原生并集——活动后端原生 + MP 部分经 mpUnionFetcher 缝。
    func testClientModelsNativeUnionViaStub() async throws {
        let kernel = makeKernel("f4")
        kernel.inferenceEndpoints.ollamaTags = { _ in [["name": .string("a"), "size": .int(7)]] }
        let client = NativeSidecarClient(kernel: kernel)
        client.mpUnionFetcher = {
            [InferenceModelEntry(name: "p", size: 5, context_length: 32768, source: "model_pack")]
        }
        let out = try await client.fetchInferenceModels()
        XCTAssertEqual(out, [
            InferenceModelEntry(name: "a", size: 7, source: "ollama"),
            InferenceModelEntry(name: "p", size: 5, context_length: 32768, source: "model_pack"),
        ])
    }

    /// 默认 mpUnionFetcher：MP 注册表为空 → 空并集，活动后端名单不受影响
    /// （P3-W6：历史名为 AbsentFallback——经无 ModelPacksPanelClient 的 fallback 模拟缺席侧车）。
    func testClientModelsMPUnionEmpty() async throws {
        let kernel = makeKernel("f5")
        kernel.inferenceEndpoints.ollamaTags = { _ in [["name": .string("a")]] }
        let client = NativeSidecarClient(kernel: kernel)
        let out = try await client.fetchInferenceModels()
        XCTAssertEqual(out, [InferenceModelEntry(name: "a", source: "ollama")])
    }

    /// backend=model_package：context/limit MP 面原生（P3-W3a）——tier→manifest→
    /// unsupported 三级（app.py L528-529 判据不 strip 同口径）。
    func testClientContextLimitMPNative() async throws {
        let kernel = makeKernel("f6")
        _ = try kernel.config.reloadConfig(patch: ["inference_backend": .string("model_package")])
        kernel.inferenceEndpoints.ollamaPS = { _ in XCTFail("MP 不得走原生 ps"); return [] }
        try seedPack(kernel, "pack-x", contextLength: 8192)
        let client = NativeSidecarClient(kernel: kernel)
        let info = try await client.fetchContextLimit(model: "pack-x")
        XCTAssertEqual(info, ContextLimitInfo(limit: 8192, source: "manifest"))
        let none = try await client.fetchContextLimit(model: "ghost")
        XCTAssertEqual(none, ContextLimitInfo(limit: 0, source: "unsupported"))
    }

    /// ollama：context/limit 原生（ps 级）。
    func testClientContextLimitNative() async throws {
        let kernel = makeKernel("f7")
        kernel.inferenceEndpoints.ollamaPS = { _ in [
            ["name": .string("qwen3.8:latest"), "context_length": .int(131072)]
        ] }
        let client = NativeSidecarClient(kernel: kernel)
        let info = try await client.fetchContextLimit(model: "qwen3.8")
        XCTAssertEqual(info, ContextLimitInfo(limit: 131072, source: "ps"))
    }

    /// pull/delete 门控原生（openai 后端 400 逐字）。
    func testClientPullDeleteGatingNative() async throws {
        let kernel = makeKernel("f8")
        _ = try kernel.config.reloadConfig(patch: [
            "inference_backend": .string("openai_compatible"),
            "inference_base_url": .string("http://host/v1"),
        ])
        let client = NativeSidecarClient(kernel: kernel)
        await XCTAssertThrowsErrorAsync({ try await client.pullModel(name: "m") }) { err in
            XCTAssertEqual(err.httpDetail, "当前推理后端不支持模型拉取（仅 Ollama 后端支持）")
        }
        await XCTAssertThrowsErrorAsync({ try await client.deleteModel(name: "m") }) { err in
            XCTAssertEqual(err.httpDetail, "当前推理后端不支持模型删除（仅 Ollama 后端支持）")
        }
    }

    /// pull/delete ollama 原生：Void 口径成功；deleted:false 不抛错。
    func testClientPullDeleteOllamaNative() async throws {
        let kernel = makeKernel("f9")
        var pulledName: String?
        kernel.inferenceEndpoints.ollamaPullLines = { _, name in
            pulledName = name
            return ["{\"status\":\"success\"}"]
        }
        kernel.inferenceEndpoints.ollamaDeleteModel = { _, _ in false }
        let client = NativeSidecarClient(kernel: kernel)
        try await client.pullModel(name: "qwen3.8")
        XCTAssertEqual(pulledName, "qwen3.8")
        try await client.deleteModel(name: "qwen3.8")   // deleted:false → Void 不抛
    }

    /// listInferenceModels（SettingsPanel）：原生名单映射 InferenceModelItem。
    func testClientListInferenceModelsMaps() async throws {
        let kernel = makeKernel("f10")
        kernel.inferenceEndpoints.ollamaTags = { _ in [
            ["name": .string("a"), "size": .int(7),
             "details": .object(["context_length": .int(262144)])],
        ] }
        let client = NativeSidecarClient(kernel: kernel)
        client.mpUnionFetcher = {
            [InferenceModelEntry(name: "p", size: 5, context_length: 32768, source: "model_pack")]
        }
        let out = try await client.listInferenceModels()
        XCTAssertEqual(out, [
            InferenceModelItem(name: "a", size: 7, contextLength: 262144, source: "ollama"),
            InferenceModelItem(name: "p", size: 5, contextLength: 32768, source: "model_pack"),
        ])
    }
}

// ════════════════════════════════════════════════════════════
// MARK: - 测试桩与断言助手
// ════════════════════════════════════════════════════════════

// MARK: - 断言助手

private extension Error {
    var httpStatus: Int? {
        guard let e = self as? SidecarError, case .httpError(let s, _) = e else { return nil }
        return s
    }
    var httpDetail: String? {
        guard let e = self as? SidecarError, case .httpError(_, let d) = e else { return nil }
        return d
    }
}

/// async 版 throws 断言（XCTAssertThrowsError 不吃 async 闭包）。
func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line,
    _ errorHandler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("应抛错：\(message())", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
