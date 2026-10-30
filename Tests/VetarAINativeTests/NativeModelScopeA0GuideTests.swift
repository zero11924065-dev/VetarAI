//
//  NativeModelScopeA0GuideTests.swift
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

//  覆盖：
//    · probeMLXSupport：支持→true / 不支持→false / config.json 不在清单→nil /
//      拉取抛错→nil / JSON 坏→nil / 无 model_type→nil（探测全程不抛错、不触网，
//      注入缝写法沿用 NativeModelScopeInstallerTests：fetchData 内存桩 +
//      supportsModelType 固定表）
//    · preflight 零回归：probe=false 仍抛 unsupportedFormat（错误文案逐字钉死）；
//      probe=nil 静默放行（安装链走通落位登记）
//    · msRecommend 纯函数：有支持的 MLX→其 id；MLX 不支持→nil；无 MLX 档→nil；
//      support 空表→nil；混合档只推 MLX 不推 GGUF
//

import XCTest
import CryptoKit
@testable import VetarAINative

final class NativeModelScopeA0ProbeTests: XCTestCase {

    private var tmp: URL!
    private var store: NativeModelPackStore!
    private var installer: NativeModelScopeInstaller!
    private let ref = ModelScopeRepoRef(org: "mlx-community", name: "M-MLX")

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("msa0_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        store = NativeModelPackStore(
            configProvider: { [:] },
            dataRootProvider: { self.tmp },
            environment: [NativeModelPackStore.envPacksDir: self.tmp.appendingPathComponent("packs").path])
        installer = NativeModelScopeInstaller(store: store)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    private func shaHex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// MLX 档文件清单桩（withConfig=false 模拟 config.json 不在清单的场景）
    private func mlxFiles(withConfig: Bool = true) -> [ModelScopeRepoFile] {
        var files = [ModelScopeRepoFile(path: "model.safetensors", sizeBytes: 1000,
                                        sha256: String(repeating: "a", count: 64), isLFS: true)]
        if withConfig {
            files.append(ModelScopeRepoFile(path: "config.json", sizeBytes: 60,
                                            sha256: String(repeating: "b", count: 64), isLFS: false))
        }
        return files
    }

    /// config.json 内存桩（body 为 nil 时 fetch 抛错，模拟网络失败）
    private func stubConfig(_ body: Data?) {
        installer.fetchData = { _ in
            guard let body else { throw URLError(.networkConnectionLost) }
            return (200, body)
        }
    }

    // MARK: - probe：三态判定

    /// 架构在支持表 → true（可推荐）
    func testProbeSupportedReturnsTrue() async {
        stubConfig(try! JSONSerialization.data(withJSONObject: ["model_type": "qwen3"]))
        installer.supportsModelType = { $0 == "qwen3" }   // 固定表钉桩
        let r = await installer.probeMLXSupport(ref: ref, files: mlxFiles())
        XCTAssertEqual(r, true)
    }

    /// 架构不在支持表 → false（应引导改选 GGUF）
    func testProbeUnsupportedReturnsFalse() async {
        stubConfig(try! JSONSerialization.data(withJSONObject: ["model_type": "deepseek"]))
        installer.supportsModelType = { _ in false }
        let r = await installer.probeMLXSupport(ref: ref, files: mlxFiles())
        XCTAssertEqual(r, false)
    }

    /// config.json 不在文件清单 → nil，且不得发起任何拉取（零额外请求）
    func testProbeNoConfigInFilesReturnsNil() async {
        var fetchCount = 0
        installer.fetchData = { _ in fetchCount += 1; return (200, Data()) }
        installer.supportsModelType = { _ in true }
        let r = await installer.probeMLXSupport(ref: ref, files: mlxFiles(withConfig: false))
        XCTAssertNil(r)
        XCTAssertEqual(fetchCount, 0, "config 不在清单应直接 nil，零拉取")
    }

    /// config.json 拉取抛错 → nil（探测失败不抛错，安装期 preflight 兜底）
    func testProbeFetchThrowsReturnsNil() async {
        stubConfig(nil)
        installer.supportsModelType = { _ in true }
        let r = await installer.probeMLXSupport(ref: ref, files: mlxFiles())
        XCTAssertNil(r)
    }

    /// config.json 不是合法 JSON → nil
    func testProbeBadJSONReturnsNil() async {
        stubConfig(Data("not json".utf8))
        installer.supportsModelType = { _ in true }
        let r = await installer.probeMLXSupport(ref: ref, files: mlxFiles())
        XCTAssertNil(r)
    }

    /// config.json 无 model_type（或空串）→ nil（与既有静默放行口径一致）
    func testProbeMissingModelTypeReturnsNil() async {
        stubConfig(try! JSONSerialization.data(withJSONObject:
            ["architectures": ["Qwen3ForCausalLM"]]))
        installer.supportsModelType = { _ in true }
        let r1 = await installer.probeMLXSupport(ref: ref, files: mlxFiles())
        XCTAssertNil(r1)
        // 空串 model_type 同样 nil（不支持表查询不该收到空架构名）
        stubConfig(try! JSONSerialization.data(withJSONObject: ["model_type": ""]))
        let r2 = await installer.probeMLXSupport(ref: ref, files: mlxFiles())
        XCTAssertNil(r2)
    }

    // MARK: - preflight 零回归（消费 probe 后行为逐字不动）

    /// probe=false：install 仍在下载大权重前抛 unsupportedFormat，
    /// 错误文案与 1.0.8 预检原版逐字一致（零回归钉死）
    func testPreflightFalseStillThrowsVerbatimMessage() async throws {
        let cfgData = try JSONSerialization.data(withJSONObject:
            ["model_type": "deepseek", "architectures": ["DeepseekV3ForCausalLM"]])
        installer.fetchData = { _ in (200, cfgData) }
        installer.supportsModelType = { _ in false }
        let variant = ModelScopeVariant(id: "mlx", title: "MLX 整仓", format: .mlx,
                                        files: mlxFiles())
        let snap = ModelScopeRepoSnapshot(ref: ref, license: "", variants: [variant])
        do {
            _ = try await installer.install(snapshot: snap, variantId: "mlx")
            XCTFail("应抛 unsupportedFormat")
        } catch {
            guard case NativeModelScopeError.unsupportedFormat(let m) = error else {
                return XCTFail("应抛 unsupportedFormat，得到 \(error)")
            }
            XCTAssertEqual(m, "该模型暂不支持：架构「deepseek」暂不在本机 MLX 推理支持列表内，"
                + "请改选 GGUF 版本（如有）或改用其他模型。", "错误文案逐字不变（A0 零回归口径）")
        }
        // 拦截在下载前：注册表无登记
        let pid = ModelScopeManifestBuilder.packId(ref: ref, variant: variant)
        XCTAssertNil(store.getEntry(pid))
    }

    /// probe=nil（config 拉取失败 → 无法判定）：静默放行——安装链照常走通，
    /// 落盘完整性由 ModelScopeMLXValidator 把关（file:// 本地源全链不触网）
    func testPreflightNilSilentlyPasses() async throws {
        let weightData = Data(repeating: 0x3, count: 600)
        let localWeight = tmp.appendingPathComponent("src-model.safetensors")
        try weightData.write(to: localWeight)
        let cfgData = try JSONSerialization.data(withJSONObject:
            ["model_type": "qwen3", "architectures": ["Qwen3ForCausalLM"]])
        let localConfig = tmp.appendingPathComponent("src-config.json")
        try cfgData.write(to: localConfig)
        let files = [
            ModelScopeRepoFile(path: "config.json", sizeBytes: Int64(cfgData.count),
                               sha256: shaHex(cfgData), isLFS: false),
            ModelScopeRepoFile(path: "model.safetensors", sizeBytes: Int64(weightData.count),
                               sha256: shaHex(weightData), isLFS: true),
        ]
        let variant = ModelScopeVariant(id: "mlx", title: "MLX 整仓", format: .mlx, files: files)
        let snap = ModelScopeRepoSnapshot(ref: ref, license: "", variants: [variant])
        // 探测期拉 config 必失败（网络断）→ probe=nil；即使架构「不支持」也应放行
        stubConfig(nil)
        installer.supportsModelType = { _ in false }
        // 下载链走 file:// 本地源（config 本地副本含合法 model_type，validator 能过）
        installer.resolveURLForFile = { _, path in
            path == "config.json" ? localConfig.absoluteString : localWeight.absoluteString
        }
        let pid = try await installer.install(snapshot: snap, variantId: "mlx")
        let entry = store.getEntry(pid)
        XCTAssertEqual(entry?["format"]?.string, "mlx")
        XCTAssertEqual(entry?["driver"]?.string, "mlxswift")
        XCTAssertEqual(entry?["status"]?.string, "installed")
    }
}

// MARK: - A0：档位推荐决策（纯函数钉桩）

final class ModelScopeA0RecommendTests: XCTestCase {

    private func v(_ id: String, _ fmt: ModelScopeFormat) -> ModelScopeVariant {
        ModelScopeVariant(id: id, title: id, format: fmt, files: [
            ModelScopeRepoFile(path: "f.bin", sizeBytes: 1,
                               sha256: String(repeating: "a", count: 64), isLFS: false),
        ])
    }

    /// 存在探测「支持」的 MLX 档 → 推荐它（秒级加载）
    func testRecommendSupportedMLX() async {
        let r = await ModelPacksPanelViewModel.msRecommend(
            variants: [v("q4_k_m", .gguf), v("mlx", .mlx)],
            support: ["mlx": true])
        XCTAssertEqual(r, "mlx")
    }

    /// MLX 档探测「不支持」→ 不推荐（维持第一档，GGUF 兜底）
    func testRecommendUnsupportedMLXReturnsNil() async {
        let r = await ModelPacksPanelViewModel.msRecommend(
            variants: [v("mlx", .mlx)], support: ["mlx": false])
        XCTAssertNil(r)
    }

    /// 无 MLX 档 → 不推荐
    func testRecommendNoMLXVariantReturnsNil() async {
        let r = await ModelPacksPanelViewModel.msRecommend(
            variants: [v("q4_k_m", .gguf), v("q8_0", .gguf)],
            support: ["q4_k_m": true, "q8_0": true])
        XCTAssertNil(r)
    }

    /// support 空表（探测全未知）→ 不推荐
    func testRecommendEmptySupportReturnsNil() async {
        let r = await ModelPacksPanelViewModel.msRecommend(
            variants: [v("mlx", .mlx)], support: [:])
        XCTAssertNil(r)
    }

    /// 混合档只推 MLX 不推 GGUF：GGUF「支持」而 MLX 未知 → nil；
    /// GGUF 与 MLX 均「支持」→ 仍只推 MLX 档
    func testRecommendNeverPicksGGUF() async {
        let variants = [v("q4_k_m", .gguf), v("mlx", .mlx)]
        let r1 = await ModelPacksPanelViewModel.msRecommend(
            variants: variants, support: ["q4_k_m": true])
        XCTAssertNil(r1, "GGUF 档永不进推荐（MLX 未探测/未知不推荐）")
        let r2 = await ModelPacksPanelViewModel.msRecommend(
            variants: variants, support: ["q4_k_m": true, "mlx": true])
        XCTAssertEqual(r2, "mlx")
    }
}
