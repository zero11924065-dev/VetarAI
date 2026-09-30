//
//  NativeEmbedder.swift
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

//  移植 subagent/sidecar/knowledge/embedder.py（⛔ 只读行为规格），摘除 Python
//  onnxruntime 依赖的第一刀：ONNX int8 → CoreML FP16（W3 pilot 路线 B 产物）。
//
//  模型：vetarai-native/models/bge_m3_dense_fp16.mlpackage（gitignored；动态序列 1-1024，
//  CLS + L2 归一化包装已烘焙进模型——但 FP16 算术实测范数漂 0.9998–1.0001，
//  故 encodeOne 仍按 embedder.py encode() 口径防御性再归一化后再 round(6)）。
//  等价性（pilot §2）：
//  CoreML FP16 vs 官方 FP32 真值 cos = 0.99994–0.99998，**优于**现状 int8（0.978–0.986）——
//  换型是精度提升而非损失。
//
//  关键纪律（pilot §3/§6 实测，勿凭直觉改）：
//    · computeUnits 必须 .cpuOnly——动态形状的符号输出维 [?,1024] 会让 ANE/GPU 触发
//      E5RT "Invalid blob shape" 回退，反而更慢更耗电。
//    · 分词 = huggingface/swift-transformers Tokenizers（唯一已论证外部依赖，
//      SPM revision 锁定），直接消费 tokenizer.json（Unigram + Metaspace +
//      TemplateProcessing 自动加 <s>/</s>），语料级 parity 门禁：
//      NativeEmbedderTests.testTokenizerParityGolden（25 条中英混合样本逐 token 全等）。
//    · 截断口径：Python 侧 enable_truncation(max_length=512) 在分词管道层生效
//      （含特殊 token 共 512；截断先于后处理，句尾 </s> 保留——golden #24 尾部背书）；
//      swift-transformers 不自动截断 → encode 后 truncateToMax()（prefix(511)+</s>）。
//      Python 的 _chunk_texts 因截断先行而实际恒为单块（len(ids)≤512 恒真），
//      故原生不再实现分块——单块前向即为等价行为。
//    · dense 落盘前 round(6)（对齐 encode() 的 round(float(x),6)），blob 为 float32 LE
//      （struct.pack("<1024f") 等价物）。
//    · sparse/ColBERT 输出未随 pilot 转换（pilot §6.4）→ 原生查询侧 sparse 恒为空，
//      semantic 评分退化为 0.7*cos + 0.3*0。向量空间等价已证，排序一致性由双跑门禁背书。
//
//  懒加载：首次 encode 才编译/装载（实测 2–4.5s），NSLock 串行防并发重载；
//  0.5.2 A1 真懒加载：启动预热撤除——启动零嵌入功耗（0.5.1 实测启动 4.2~4.5s
//  CPU 饱和窗即来自预装载），首载由首次真实检索/入库触发；装载三态
//  （notLoaded/loading/loaded/failed）供 UI 嵌入状态条「装载中」分支；
//  侧车旧向量重编码错峰到首载成功钩子之后（NativeRuntime 接线）。
//  缺失降级：模型/分词器不齐 → modelAvailable=false，检索层自动降级纯关键词
//  （对齐 embedder.py 的 EmbedUnavailableError 静默降级语义）。
//

import CoreML
import Foundation
import Tokenizers
import Hub

/// 嵌入模型不可用（对齐 embedder.EmbedUnavailableError——调用方降级为关键词检索）。
public struct EmbedUnavailableError: Error, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

public final class NativeEmbedder: @unchecked Sendable {

    /// 原生模型标识（写入 knowledge_embeddings.model 列；与侧车 'bge-m3-onnx-int8' 区分——
    /// 嵌入索引兼容策略见 NativeKnowledgeStore.reembedForeignModelEntriesIfNeeded）。
    public static let modelID = "bge-m3-coreml-fp16"
    /// 模型目录名（数据根/环境变量下挂的子目录）。
    public static let modelDirName = "bge-m3-coreml"
    /// 模型包文件名（W3 pilot 主产物）。
    public static let modelFileName = "bge_m3_dense_fp16.mlpackage"

    /// 查询侧指令前缀（embedder.py QUERY_INSTRUCTION 逐字：bge-m3 官方推荐，
    /// query 与 passage 不对称以提升检索质量）。
    public static let queryInstruction = "Represent this sentence for searching relevant passages: "
    /// 截断上限（embedder.py _CHUNK_TOKENS=512；含特殊 token）。
    public static let maxTokens = 512
    /// dense 维度（bge-m3 1024 维）。
    public static let denseDim = 1024

    /// 数据根（= 侧车 VETARAI_DATA_ROOT；构造注入，与 NativeKernel 同根）。
    public let dataRoot: URL
    /// 显式模型目录覆盖（测试注入；nil = 走三级解析）。
    public let modelDirOverride: URL?
    private let environment: [String: String]
    public var log: (String) -> Void

    // 懒加载状态（NSLock 串行化；对齐 embedder.py _lock + _state 单例）。
    private let lock = NSLock()
    private var model: MLModel?
    private var tokenizer: (any Tokenizer)?
    private var loadedDir: String?
    private var loadFailed = false   // 装载失败记忆化：避免每次检索都重试 2s 的加载

    // ── 0.5.2 A1：装载三态 + 一次性首载钩子（真懒加载配套）──

    /// 装载三态（UI 嵌入状态条「装载中」分支与诊断用）。
    public enum LoadState: String, Sendable {
        case notLoaded, loading, loaded, failed
    }
    /// 三态独立小锁：getter 只持本锁；ensureLoaded 持主 lock 内写 state——
    /// 锁序恒 主→state 或仅 state，永不反向互嵌（无死锁面）。
    private let stateLock = NSLock()
    private var _loadState: LoadState = .notLoaded
    /// 装载三态（线程安全读；不触发装载）。
    public var loadState: LoadState { stateLock.withLock { _loadState } }

    /// 一次性首载钩子（0.5.2 A1 错峰重编码接线点）：首次装载成功后、主 lock
    /// 释放**之后**同步触发并即刻清空。绝不在主 lock 内回调——钩子若反向调
    /// encodeOne（重编码旧向量正是此场景），主 lock 内回调 = NSLock 同线程
    /// 重入死锁。仅装载线程读写本属性，无竞态面。
    public var onFirstLoad: (@Sendable () -> Void)?

    public init(dataRoot: URL, modelDir: URL? = nil,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                log: @escaping (String) -> Void = { _ in }) {
        self.dataRoot = dataRoot
        self.modelDirOverride = modelDir
        self.environment = environment
        self.log = log
    }

    // MARK: - 模型目录解析（对齐 embedder.default_model_dir 三级回退精神，CoreML 目录口径）

    /// 优先级：显式覆盖 > VETARAI_MODELS_DIR/<name> > {dataRoot}/models/<name> > 应用包内。
    /// 齐件判定 = .mlpackage + tokenizer.json（对齐 model_available 的文件齐备语义）。
    public func resolvedModelDir() -> URL? {
        if let o = modelDirOverride { return Self.dirIsUsable(o) ? o : nil }
        var candidates: [URL] = []
        if let envDir = environment["VETARAI_MODELS_DIR"], !envDir.isEmpty {
            candidates.append(URL(fileURLWithPath: (envDir as NSString).expandingTildeInPath)
                .appendingPathComponent(Self.modelDirName, isDirectory: true))
        }
        candidates.append(dataRoot.appendingPathComponent("models/\(Self.modelDirName)", isDirectory: true))
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("models/\(Self.modelDirName)", isDirectory: true))
        }
        return candidates.first(where: Self.dirIsUsable)
    }

    /// 齐件判定（对齐 embedder.model_available：模型 + tokenizer.json）。
    public static func dirIsUsable(_ dir: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: dir.appendingPathComponent(Self.modelFileName).path)
            && fm.fileExists(atPath: dir.appendingPathComponent("tokenizer.json").path)
    }

    /// model_available() 等价（供嵌入状态端点与降级判断；不触发加载）。
    public func modelAvailable() -> Bool { resolvedModelDir() != nil }

    /// 当前解析出的模型目录（状态端点 model_dir 字段；无 → 空串口径由调用方定）。
    public func modelDirPath() -> String { resolvedModelDir()?.path ?? "" }

    /// 下载补装后的热生效复位（REQ-FUT-015 / ADR-0051）：清失败记忆化 + 已载实例，
    /// 下次使用走完整解析链重新懒加载——正常路径无需重启（拍板「重启」仅兜底分支）。
    /// 锁序与 ensureLoaded 一致（主 lock 与 stateLock 分别持有，永不互嵌）。
    public func resetForRetry() {
        lock.withLock {
            model = nil
            tokenizer = nil
            loadedDir = nil
            loadFailed = false
        }
        stateLock.withLock { _loadState = .notLoaded }
    }

    // MARK: - 懒加载（NSLock 单例；装载失败记忆化防重试风暴）

    private func ensureLoaded() throws -> (MLModel, any Tokenizer) {
        // didLoad：本次调用完成了首次装载 → 出锁后触发一次性 onFirstLoad
        // （出锁回调是死锁防线，见 onFirstLoad 头注）。
        var didLoad = false
        defer {
            if didLoad {
                let hook = onFirstLoad
                onFirstLoad = nil
                hook?()
            }
        }
        return try lock.withLock {
            if let model, let tokenizer { return (model, tokenizer) }
            if loadFailed { throw EmbedUnavailableError("嵌入模型此前装载失败（本会话不再重试）") }
            guard let dir = resolvedModelDir() else {
                loadFailed = true
                stateLock.withLock { _loadState = .failed }
                throw EmbedUnavailableError(
                    "嵌入模型文件缺失（需要 \(Self.modelFileName) 与 tokenizer.json）")
            }
            stateLock.withLock { _loadState = .loading }
            do {
                let t0 = Date()
                // 0.5.2 A3：装载本体（编译 + MLModel init + 分词器）放 .background QoS
                // 队列执行——总功不变，摊薄为低水位（承 0.4.x 侧车 CPU 整治口径；
                // 重编码侧 QoS 随 A1 钩子已是 Task.detached(.background)）。
                // .sync 保调用方语义不变：首次检索等装载完照样拿语义结果
                // （对齐 0.4.x 侧车首查行为）；并发重载仍由主 lock 串行。
                let (m, tok) = try DispatchQueue.global(qos: .background).sync {
                    // .mlpackage → .mlmodelc 编译（pilot 实测 82–200ms；compileModel 自带缓存目录）
                    let compiled = try MLModel.compileModel(at: dir.appendingPathComponent(Self.modelFileName))
                    let cfg = MLModelConfiguration()
                    cfg.computeUnits = .cpuOnly   // ⛔ 动态形状符号输出维下 ANE/GPU 触发 E5RT 回退（pilot §3）
                    let m = try MLModel(contentsOf: compiled, configuration: cfg)
                    // 分词器：同步 Config 路径（AutoTokenizer.from(tokenizerConfig:tokenizerData:)），
                    // 不触网、不经 Hub 下载；config.json 不需要（绕过 unsupportedTokenizer 注册表，
                    // tokenizer.json 内含 Unigram 模型定义自描述）。
                    let tok = try Self.loadTokenizer(from: dir)
                    return (m, tok)
                }
                model = m
                tokenizer = tok
                loadedDir = dir.path
                stateLock.withLock { _loadState = .loaded }
                didLoad = true
                log("NativeEmbedder: bge-m3 CoreML 装载完成（\(String(format: "%.1f", Date().timeIntervalSince(t0)))s，cpuOnly）")
                return (m, tok)
            } catch let e as EmbedUnavailableError {
                loadFailed = true
                stateLock.withLock { _loadState = .failed }
                throw e
            } catch {
                loadFailed = true
                stateLock.withLock { _loadState = .failed }
                throw EmbedUnavailableError("嵌入模型装载失败: \(error.localizedDescription)")
            }
        }
    }

    /// tokenizer.json + tokenizer_config.json → Tokenizer（同步；tokenizer_config 缺失时用空配置兜底）。
    private static func loadTokenizer(from dir: URL) throws -> any Tokenizer {
        let tokURL = dir.appendingPathComponent("tokenizer.json")
        guard let tokObj = try JSONSerialization.jsonObject(with: Data(contentsOf: tokURL)) as? [String: Any] else {
            throw EmbedUnavailableError("tokenizer.json 解析失败")
        }
        var cfgObj: [String: Any] = [:]
        let cfgURL = dir.appendingPathComponent("tokenizer_config.json")
        if let d = try? Data(contentsOf: cfgURL),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            cfgObj = o
        }
        do {
            return try AutoTokenizer.from(tokenizerConfig: Config(cfgObj as [NSString: Any]),
                                          tokenizerData: Config(tokObj as [NSString: Any]))
        } catch {
            throw EmbedUnavailableError("分词器装载失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 分词（语料级 parity 门禁：NativeEmbedderTests）

    /// </s> token id（tokenizer.json TemplateProcessing 后处理器写入的句尾特殊 token，
    /// XLMRoberta 系恒为 2；golden 门禁 #24 尾部 `…2564, 2` 背书）。
    private static let sepTokenID = 2

    /// 截断对齐 Python `enable_truncation(max_length=512)` 语义：HF tokenizers 的截断在
    /// 后处理**之前**生效——内容截到 512 − 特殊 token 数（单序列 = 1 个句尾 </s>），
    /// 再由 TemplateProcessing 补上 </s>，总长按 512（golden #24 尾部为 2 而非内容 token）。
    /// 朴素 prefix(512) 会把 </s> 切掉，长文 parity 必挂。
    private static func truncateToMax(_ ids: [Int]) -> [Int] {
        guard ids.count > maxTokens else { return ids }
        return Array(ids.prefix(maxTokens - 1)) + [sepTokenID]
    }

    /// 分词 → token id 序列（含 <s>/</s> 特殊 token；>512 截断对齐 enable_truncation 口径）。
    /// 仅供门禁测试与 encode 内部使用。
    public func tokenize(_ text: String) throws -> [Int] {
        let (_, tok) = try ensureLoaded()
        let ids = tok.encode(text: text)   // addSpecialTokens=true（TemplateProcessing 加 <s>/</s>）
        return Self.truncateToMax(ids)
    }

    // MARK: - 编码（encode_one 等价物）

    /// 单条编码 → 1024 维单位向量（dense）。
    /// - Parameter withQueryInstruction: 查询侧加 bge-m3 指令前缀（检索查询用；入库文档不加）。
    /// - Throws: EmbedUnavailableError（模型缺失/装载失败）——调用方静默降级。
    public func encodeOne(_ text: String, withQueryInstruction: Bool = false) throws -> [Float] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // 对齐 encode()：空文本返回零向量占位（不抛错）。
        guard !trimmed.isEmpty else { return [Float](repeating: 0, count: Self.denseDim) }
        let (m, tok) = try ensureLoaded()
        let input = withQueryInstruction ? Self.queryInstruction + trimmed : trimmed
        var ids = tok.encode(text: input)
        if ids.count > Self.maxTokens { ids = Self.truncateToMax(ids) }
        let n = ids.count
        let idsArr = try MLMultiArray(shape: [1, NSNumber(value: n)], dataType: .int32)
        let maskArr = try MLMultiArray(shape: [1, NSNumber(value: n)], dataType: .int32)
        let idsPtr = idsArr.dataPointer.bindMemory(to: Int32.self, capacity: n)
        let maskPtr = maskArr.dataPointer.bindMemory(to: Int32.self, capacity: n)
        for (i, id) in ids.enumerated() { idsPtr[i] = Int32(id); maskPtr[i] = 1 }
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: idsArr),
            "attention_mask": MLFeatureValue(multiArray: maskArr),
        ])
        let out = try m.prediction(from: provider)
        guard let vec = out.featureValue(for: "dense_vec")?.multiArrayValue,
              vec.count == Self.denseDim else {
            throw EmbedUnavailableError("嵌入模型输出异常（dense_vec 缺失或维度≠\(Self.denseDim)）")
        }
        let p = vec.dataPointer.bindMemory(to: Float32.self, capacity: Self.denseDim)
        // 模型导出时虽已烘焙 L2 归一化（pilot §1），但 FP16 算术实测范数漂到 0.9998–1.0001；
        // 对齐 embedder.py encode() 的防御性再归一化（norm>1e-9 → dense/norm，float64 计算），
        // 然后 round(6) 对齐落盘精度（Python round 在 float64 上 half-to-even →
        // Double + .toNearestOrEven，勿用默认 half-away）。
        var v = (0..<Self.denseDim).map { Double(p[$0]) }
        let norm = v.reduce(0.0) { $0 + $1 * $1 }.squareRoot()
        if norm > 1e-9 { v = v.map { $0 / norm } }
        return v.map { Float(($0 * 1e6).rounded(.toNearestOrEven) / 1e6) }
    }

    /// encodeOne 的可用性安全变体：不可用/失败 → nil（对齐 _embed_entry 静默降级）。
    public func encodeOneOrNil(_ text: String, withQueryInstruction: Bool = false) -> [Float]? {
        try? encodeOne(text, withQueryInstruction: withQueryInstruction)
    }

    // MARK: - 向量序列化与度量（embedder.py dense_to_blob / blob_to_dense / cosine / sparse_dot）

    /// dense_to_blob：float32 小端打包（struct.pack("<Nf") 等价）。
    public static func denseToBlob(_ vec: [Float]) -> Data {
        var data = Data(count: vec.count * 4)
        data.withUnsafeMutableBytes { ptr in
            for (i, v) in vec.enumerated() {
                ptr.storeBytes(of: v.bitPattern.littleEndian, toByteOffset: i * 4, as: UInt32.self)
            }
        }
        return data
    }

    /// blob_to_dense：float32 小端解包。
    public static func blobToDense(_ blob: Data) -> [Float] {
        let n = blob.count / 4
        guard n > 0 else { return [] }
        return (0..<n).map { i in
            let v = blob.withUnsafeBytes { ptr in
                ptr.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)
            }
            return Float(bitPattern: UInt32(littleEndian: v))
        }
    }

    /// cosine：dense 已归一化，点积即余弦（维度不齐/空 → 0）。
    public static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard !a.isEmpty, !b.isEmpty, a.count == b.count else { return 0.0 }
        var s = 0.0
        for i in 0..<a.count { s += Double(a[i]) * Double(b[i]) }
        return s
    }

    /// sparse_dot：稀疏点积（小字典一侧遍历）。原生查询侧 sparse 恒为空（CoreML 未转
    /// sparse 头），本函数为读侧车遗留向量与双跑对照保留。
    public static func sparseDot(_ q: [String: Double], _ d: [String: Double]) -> Double {
        guard !q.isEmpty, !d.isEmpty else { return 0.0 }
        let (small, big) = q.count <= d.count ? (q, d) : (d, q)
        var s = 0.0
        for (tok, w) in small { s += w * (big[tok] ?? 0.0) }
        return s
    }
}
