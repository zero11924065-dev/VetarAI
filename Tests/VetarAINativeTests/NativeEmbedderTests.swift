//
//  NativeEmbedderTests.swift
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

//  ⏱ 慢套件（模型装载 2s + 推理），单跑：
//    swift test --filter NativeEmbedderTests
//
//  门禁（pilot §4/§6.3 要求）：分词器语料级 parity——25 条中英混合样本
//  （Fixtures/tokenizer_golden.json，由 Python tokenizers 0.21.4 + enable_truncation(512)
//  生成，含 pilot 原 5 条回归 + 长文截断 + 查询指令前缀 + 空白/标点边界），
//  原生分词结果必须逐条 token id 全等。本门禁失败 = 分词器不可信，阻塞交付。
//
//  向量真值对照：docs/pilot/swift_coreml_fp16_cpuonly.json（W3 pilot 同机同模型产出，
//  compute_units=cpuOnly——动态形状强制 cpuOnly 是 pilot §3 硬结论，旧的
//  swift_coreml_fp16.json 是 compute_units=all 真值，与 cpuOnly 输出 cos 仅 0.9999±3e-4，
//  用它做门禁会把合规实现误判红）。原生 encodeOne 与真值 cos 必须 ≥ 0.9999
//  （同一 CoreML 模型同一 computeUnits，数值应几乎逐位一致）。
//

import XCTest
@testable import VetarAINative

final class NativeEmbedderTests: XCTestCase {

    /// 仓内模型目录（gitignored 大资产；缺失 → 全套件 XCTSkip，CI/换机不阻塞）。
    private static func repoModelDir(_ file: StaticString = #filePath) -> URL {
        // #filePath = <repo>/Tests/VetarAINativeTests/NativeEmbedderTests.swift
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // VetarAINativeTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // <repo>/
            .appendingPathComponent("models/bge-m3-coreml", isDirectory: true)
    }

    private var tmpRoot: URL!
    private var embedder: NativeEmbedder!

    override func setUp() async throws {
        let dir = Self.repoModelDir()
        try XCTSkipUnless(NativeEmbedder.dirIsUsable(dir),
                          "CoreML 模型目录不齐件（\(dir.path)），跳过嵌入套件")
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("p2w1_embed_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        embedder = NativeEmbedder(dataRoot: tmpRoot, modelDir: dir)
    }

    override func tearDown() {
        if let tmpRoot { try? FileManager.default.removeItem(at: tmpRoot) }
        embedder = nil
        super.tearDown()
    }

    // MARK: - 语料级 parity 门禁（pilot §6.3 必做项）

    private struct Golden: Decodable {
        let text: String
        let input_ids: [Int]
        let attention_mask: [Int]
    }

    /// 25 条中英混合样本：原生分词 token id 与 Python tokenizers 逐条全等。
    func testTokenizerParityGolden() throws {
        guard let url = Bundle.module.url(forResource: "tokenizer_golden", withExtension: "json") else {
            return XCTFail("tokenizer_golden.json 未进测试 bundle")
        }
        let samples = try JSONDecoder().decode([Golden].self, from: Data(contentsOf: url))
        XCTAssertGreaterThanOrEqual(samples.count, 20, "parity 门禁样本数不足 20")
        var failures: [String] = []
        for (i, s) in samples.enumerated() {
            let ids = try embedder.tokenize(s.text)
            if ids != s.input_ids {
                failures.append("""
                    [#\(i)] \(s.text.prefix(24))…
                      got (\(ids.count)): \(ids.prefix(12))…
                      want(\(s.input_ids.count)): \(s.input_ids.prefix(12))…
                    """)
            }
            // attention_mask 口径：无填充单序列恒全 1
            XCTAssertEqual(s.attention_mask, Array(repeating: 1, count: s.input_ids.count),
                           "golden 样本 [#\(i)] mask 应全 1")
        }
        XCTAssertTrue(failures.isEmpty, "分词 parity 失败 \(failures.count)/\(samples.count)：\n\(failures.joined(separator: "\n"))")
    }

    /// 截断口径：>512 token 输入产出恰好 512（enable_truncation(512) 等价）。
    func testTokenizerTruncation512() throws {
        let long = String(repeating: "知识条目正文。", count: 400)   // 远超 512 token
        let ids = try embedder.tokenize(long)
        XCTAssertEqual(ids.count, NativeEmbedder.maxTokens)
    }

    // MARK: - CoreML 嵌入（真值对照 + 不变量）

    /// 与 pilot 同机真值（swift_coreml_fp16_cpuonly.json，cpuOnly 口径）逐样本 cos ≥ 0.9999。
    func testCoreMLEncodeMatchesPilotTruth() throws {
        struct Truth: Decodable {
            struct R: Decodable { let text: String; let dense_vec: [Float] }
            let results: [R]
        }
        let url = Self.repoModelDir().deletingLastPathComponent()   // models/
            .deletingLastPathComponent()                            // <repo>/
            .appendingPathComponent("docs/pilot/swift_coreml_fp16_cpuonly.json")
        let truth = try JSONDecoder().decode(Truth.self, from: Data(contentsOf: url))
        XCTAssertEqual(truth.results.count, 5, "pilot 真值样本数应为 5")
        for r in truth.results {
            let vec = try embedder.encodeOne(r.text)
            XCTAssertEqual(vec.count, NativeEmbedder.denseDim)
            let cos = NativeEmbedder.cosine(vec, r.dense_vec)
            XCTAssertGreaterThanOrEqual(cos, 0.9999,
                                        "与 pilot 真值 cos 过低（\(r.text.prefix(16))…）: \(cos)")
        }
    }

    /// 编码不变量：1024 维 + 单位向量（L2 归一化烘焙在模型里）+ 空文本零向量。
    func testEncodeInvariants() throws {
        let v = try embedder.encodeOne("向量数据库结合嵌入模型可以实现语义搜索。")
        XCTAssertEqual(v.count, 1024)
        let norm = v.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
        XCTAssertEqual(norm, 1.0, accuracy: 1e-3, "dense 应为单位向量（round(6) 后微差容忍）")
        // 空文本 → 零向量占位（encode() 空文本分支）
        let zero = try embedder.encodeOne("   ")
        XCTAssertTrue(zero.allSatisfy { $0 == 0 })
        // 查询指令改变向量（不对称检索语义存在）
        let q = try embedder.encodeOne("咖啡冲泡", withQueryInstruction: true)
        let d = try embedder.encodeOne("咖啡冲泡")
        XCTAssertLessThan(NativeEmbedder.cosine(q, d), 0.99999,
                          "查询指令前缀应改变向量（query/passage 不对称）")
    }

    /// 序列化往返：denseToBlob/blobToDense 逐位一致（float32 LE）。
    func testBlobRoundTrip() throws {
        let vec = try embedder.encodeOne("序列化往返测试")
        let back = NativeEmbedder.blobToDense(NativeEmbedder.denseToBlob(vec))
        XCTAssertEqual(back.count, vec.count)
        for (a, b) in zip(vec, back) { XCTAssertEqual(a.bitPattern, b.bitPattern) }
        // 与 Python struct.pack 口径核对：前 4 字节 = float32 LE
        let pyPacked: [Float] = [0.5, -0.25, 1.0, 3.1415927]
        let blob = NativeEmbedder.denseToBlob(pyPacked)
        XCTAssertEqual([UInt8](blob.prefix(4)), [0x00, 0x00, 0x00, 0x3F])   // 0.5 LE
        XCTAssertEqual([UInt8](blob[4..<8]), [0x00, 0x00, 0x80, 0xBE])      // -0.25 LE
    }

    /// 可用性/降级：齐件目录 → available；空目录 → 不可用 + 编码抛 EmbedUnavailableError。
    func testAvailabilityAndDegrade() throws {
        XCTAssertTrue(embedder.modelAvailable())
        let empty = tmpRoot.appendingPathComponent("empty-models", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let dead = NativeEmbedder(dataRoot: tmpRoot, modelDir: empty)
        XCTAssertFalse(dead.modelAvailable())
        XCTAssertThrowsError(try dead.encodeOne("x")) { err in
            XCTAssertTrue(err is EmbedUnavailableError)
        }
        XCTAssertNil(dead.encodeOneOrNil("x"))   // 静默降级路径
    }
}
