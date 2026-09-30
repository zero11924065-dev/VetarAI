//
//  NativeModelScopeTests.swift
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
//    · 三形态输入解析（模型页链接 / ollama 风格 / SDK 片段 / 裸 org/name）
//      + 非法输入边界（空、单段、散文、路径穿越、异域、非法字符）
//    · 官方 API 响应解码（文件列表 Code/Files/blob 过滤/Sha256 小写化；
//      license 提取与缺失容错）——响应体为 2026-09-27 curl 实测结构同款
//    · 格式判定：GGUF 仓逐文件档位 / MLX 仓（safetensors+config.json）整仓档位
//      / 不支持格式文案 / GGUF 优先
//    · 清单组装：pack_id slug 合法且 ≤64、resolve 直链、manifest 驱动映射与
//      合规提示入描述
//    · 安装编排：注入缝全链（fetchData 桩 + file:// 源重写）——下载→落位→
//      manifest.json→登记，全程不触网
//

import XCTest
import CryptoKit
@testable import VetarAINative

final class ModelScopeLinkParserTests: XCTestCase {

    // MARK: 形态① 模型页链接

    func testParsePageURL() {
        let r = ModelScopeLinkParser.parse("https://modelscope.cn/models/Qwen/Qwen2.5-0.5B-Instruct-GGUF")
        XCTAssertEqual(r?.org, "Qwen")
        XCTAssertEqual(r?.name, "Qwen2.5-0.5B-Instruct-GGUF")
        XCTAssertEqual(r?.pageURL, "https://modelscope.cn/models/Qwen/Qwen2.5-0.5B-Instruct-GGUF")
    }

    func testParsePageURLWithTrailingSlashAndQuery() {
        let r = ModelScopeLinkParser.parse("https://modelscope.cn/models/Qwen/Qwen2.5-0.5B-Instruct-GGUF/files?tab=1")
        XCTAssertEqual(r?.org, "Qwen")
        XCTAssertEqual(r?.name, "Qwen2.5-0.5B-Instruct-GGUF")
    }

    func testParsePageURLHTTPAndWWW() {
        let r = ModelScopeLinkParser.parse("http://www.modelscope.cn/models/mlx-community/Qwen3-4B-4bit")
        XCTAssertEqual(r?.org, "mlx-community")
        XCTAssertEqual(r?.name, "Qwen3-4B-4bit")
    }

    // MARK: 形态② ollama 风格

    func testParseOllamaStyle() {
        let r = ModelScopeLinkParser.parse("modelscope.cn/Qwen/Qwen2.5-0.5B-Instruct-GGUF")
        XCTAssertEqual(r?.org, "Qwen")
        XCTAssertEqual(r?.name, "Qwen2.5-0.5B-Instruct-GGUF")
    }

    // MARK: 形态③ SDK 代码片段 / 裸标识

    func testParseSDKSnippetSingleQuotes() {
        let r = ModelScopeLinkParser.parse("snapshot_download('Qwen/Qwen2.5-0.5B-Instruct-GGUF')")
        XCTAssertEqual(r?.org, "Qwen")
        XCTAssertEqual(r?.name, "Qwen2.5-0.5B-Instruct-GGUF")
    }

    func testParseSDKSnippetDoubleQuotesWithArgs() {
        let snippet = """
        from modelscope import snapshot_download
        model_dir = snapshot_download(model_id="mlx-community/Qwen3-4B-4bit", cache_dir="./models")
        """
        let r = ModelScopeLinkParser.parse(snippet)
        XCTAssertEqual(r?.org, "mlx-community")
        XCTAssertEqual(r?.name, "Qwen3-4B-4bit")
    }

    func testParseBareIdentifier() {
        let r = ModelScopeLinkParser.parse("Qwen/Qwen2.5-0.5B-Instruct-GGUF")
        XCTAssertEqual(r?.org, "Qwen")
        XCTAssertEqual(r?.name, "Qwen2.5-0.5B-Instruct-GGUF")
    }

    // MARK: 非法输入

    func testRejectEmpty() {
        XCTAssertNil(ModelScopeLinkParser.parse(""))
        XCTAssertNil(ModelScopeLinkParser.parse("   \n "))
    }

    func testRejectSingleSegment() {
        XCTAssertNil(ModelScopeLinkParser.parse("Qwen"))
    }

    func testRejectProse() {
        XCTAssertNil(ModelScopeLinkParser.parse("帮我下载 Qwen/Qwen2.5 这个模型谢谢"))
    }

    func testRejectForeignDomain() {
        XCTAssertNil(ModelScopeLinkParser.parse("https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF"))
    }

    func testRejectPathTraversal() {
        XCTAssertNil(ModelScopeLinkParser.parse("https://modelscope.cn/models/../etc"))
        XCTAssertNil(ModelScopeLinkParser.parse("a/../b"))
    }

    func testRejectIllegalChars() {
        XCTAssertNil(ModelScopeLinkParser.parse("org/na me"))
        XCTAssertNil(ModelScopeLinkParser.parse("org?name=x/yyy"))
    }
}

final class ModelScopeAPITests: XCTestCase {

    /// 2026-09-27 curl 实测同款响应结构（截取关键行）
    private func filesJSON(_ files: [[String: Any]], code: Int = 200,
                           message: String = "") -> Data {
        let root: [String: Any] = code == 200
            ? ["Code": 200, "Data": ["Files": files]]
            : ["Code": code, "Message": message]
        return try! JSONSerialization.data(withJSONObject: root)
    }

    func testEndpoints() {
        let ref = ModelScopeRepoRef(org: "Qwen", name: "M")
        XCTAssertEqual(ModelScopeAPI.filesURL(ref),
                       "https://modelscope.cn/api/v1/models/Qwen/M/repo/files?Recursive=true")
        XCTAssertEqual(ModelScopeAPI.infoURL(ref),
                       "https://modelscope.cn/api/v1/models/Qwen/M")
        XCTAssertEqual(ModelScopeAPI.resolveURL(ref, path: "a/b.gguf"),
                       "https://modelscope.cn/api/v1/models/Qwen/M/resolve/master/a/b.gguf")
    }

    func testDecodeFilesHappyPath() throws {
        let data = filesJSON([
            ["Path": ".gitattributes", "Size": 1630,
             "Sha256": "C04FE798248680304F09BDD123B107F87A982AB46BB8A4286864C465ADF7F486",
             "Type": "blob", "IsLFS": false],
            ["Path": "qwen-q4_k_m.gguf", "Size": 1_266_425_696,
             "Sha256": "8e0ae26000627ed62de0e78e41860af70094558b9d2913385c842a6aa06cf3fc",
             "Type": "blob", "IsLFS": true],
            ["Path": "subdir", "Size": 0, "Sha256": "", "Type": "tree", "IsLFS": false],
        ])
        let files = try ModelScopeAPI.decodeFiles(data)
        XCTAssertEqual(files.count, 2)          // tree 目录行跳过
        XCTAssertEqual(files[1].path, "qwen-q4_k_m.gguf")
        XCTAssertEqual(files[1].sizeBytes, 1_266_425_696)
        XCTAssertTrue(files[1].isLFS)
        XCTAssertEqual(files[0].sha256, files[0].sha256.lowercased())   // 小写化
    }

    func testDecodeFilesAPIError() {
        let data = filesJSON([], code: 10010101, message: "模型不存在")
        XCTAssertThrowsError(try ModelScopeAPI.decodeFiles(data)) { e in
            guard case NativeModelScopeError.apiError(let m) = e else {
                return XCTFail("应抛 apiError，得到 \(e)")
            }
            XCTAssertTrue(m.contains("模型不存在"))
        }
    }

    func testDecodeFilesEmptyRepo() {
        let data = filesJSON([])
        XCTAssertThrowsError(try ModelScopeAPI.decodeFiles(data)) { e in
            XCTAssertEqual(e as? NativeModelScopeError, .emptyRepo)
        }
    }

    func testDecodeFilesInvalidJSON() {
        XCTAssertThrowsError(try ModelScopeAPI.decodeFiles(Data("not json".utf8)))
    }

    func testDecodeLicense() {
        let ok = try! JSONSerialization.data(withJSONObject:
            ["Code": 200, "Data": ["License": "apache-2.0", "Name": "M"]])
        XCTAssertEqual(ModelScopeAPI.decodeLicense(ok), "apache-2.0")
        let missing = try! JSONSerialization.data(withJSONObject: ["Code": 200, "Data": [:]])
        XCTAssertEqual(ModelScopeAPI.decodeLicense(missing), "")
        XCTAssertEqual(ModelScopeAPI.decodeLicense(Data("bad".utf8)), "")
    }
}

final class ModelScopeFormatDetectorTests: XCTestCase {

    private func f(_ path: String, _ size: Int64 = 100) -> ModelScopeRepoFile {
        ModelScopeRepoFile(path: path, sizeBytes: size, sha256: String(repeating: "a", count: 64),
                           isLFS: size > 1000)
    }

    func testGGUFRepoOneVariantPerFile() throws {
        let vs = try ModelScopeFormatDetector.detectVariants(files: [
            f("README.md"), f("config.json"),
            f("m-q2_k.gguf", 2_000), f("m-q4_k_m.gguf", 3_000), f("m-fp16.gguf", 8_000),
        ])
        XCTAssertEqual(vs.count, 3)
        XCTAssertTrue(vs.allSatisfy { $0.format == .gguf })
        XCTAssertEqual(vs.map(\.id), ["m-fp16", "m-q2_k", "m-q4_k_m"])   // 路径字典序
        XCTAssertEqual(vs[1].files.count, 1)
        XCTAssertEqual(vs[1].totalBytes, 2_000)
    }

    func testMLXRepoWholeRepoVariant() throws {
        let vs = try ModelScopeFormatDetector.detectVariants(files: [
            f("config.json"), f("generation_config.json"),
            f("model.safetensors.index.json"),
            f("model-00001-of-00002.safetensors", 4_000_000),
            f("model-00002-of-00002.safetensors", 3_000_000),
            f("tokenizer.json"), f("tokenizer_config.json"),
            f("README.md"), f("train.py"),   // 非白名单杂项不收
        ])
        XCTAssertEqual(vs.count, 1)
        XCTAssertEqual(vs[0].format, .mlx)
        let paths = vs[0].files.map(\.path)
        XCTAssertTrue(paths.contains("config.json"))
        XCTAssertTrue(paths.contains("model.safetensors.index.json"))   // 分片索引必收
        XCTAssertTrue(paths.contains("tokenizer.json"))
        XCTAssertEqual(paths.filter { $0.hasSuffix(".safetensors") }.count, 2)
        XCTAssertFalse(paths.contains("README.md"))
        XCTAssertFalse(paths.contains("train.py"))
    }

    func testGGUFTakesPrecedenceOverMLX() throws {
        let vs = try ModelScopeFormatDetector.detectVariants(files: [
            f("config.json"), f("weights.safetensors", 9_000), f("m-q4_k_m.gguf", 3_000),
        ])
        XCTAssertEqual(vs.count, 1)
        XCTAssertEqual(vs[0].format, .gguf)
    }

    func testUnsupportedPyTorchRepo() {
        XCTAssertThrowsError(try ModelScopeFormatDetector.detectVariants(files: [
            f("config.json"), f("pytorch_model.bin", 9_000), f("tokenizer.json"),
        ])) { e in
            guard case NativeModelScopeError.unsupportedFormat(let m) = e else {
                return XCTFail("应抛 unsupportedFormat，得到 \(e)")
            }
            XCTAssertTrue(m.contains("暂不支持该格式"))
            XCTAssertTrue(m.contains("GGUF"))
            XCTAssertTrue(m.contains("MLX"))
        }
    }

    func testUnsupportedSafetensorsWithoutConfig() {
        // 裸 safetensors 无 config.json —— mlx-swift-lm 载不动，不算 MLX 仓
        XCTAssertThrowsError(try ModelScopeFormatDetector.detectVariants(files: [
            f("weights.safetensors", 9_000),
        ])) { e in
            guard case NativeModelScopeError.unsupportedFormat = e else {
                return XCTFail("应抛 unsupportedFormat，得到 \(e)")
            }
        }
    }
}

final class ModelScopeManifestBuilderTests: XCTestCase {

    private let ref = ModelScopeRepoRef(org: "Qwen", name: "Qwen2.5-0.5B-Instruct-GGUF")
    private func variant(_ id: String, _ fmt: ModelScopeFormat,
                         _ paths: [String]) -> ModelScopeVariant {
        ModelScopeVariant(id: id, title: id, format: fmt, files: paths.map {
            ModelScopeRepoFile(path: $0, sizeBytes: 100, sha256: String(repeating: "B", count: 64),
                               isLFS: true)
        })
    }

    func testPackIdSlugValidAndDistinct() {
        let gguf = variant("qwen2.5-0.5b-instruct-q4_k_m", .gguf, ["m.gguf"])
        let mlx = variant("mlx", .mlx, ["w.safetensors"])
        let pidG = ModelScopeManifestBuilder.packId(ref: ref, variant: gguf)
        let pidM = ModelScopeManifestBuilder.packId(ref: ref, variant: mlx)
        XCTAssertTrue(NativeModelPackManifest.validPackId(pidG), "slug 须过 validPackId：\(pidG)")
        XCTAssertTrue(NativeModelPackManifest.validPackId(pidM))
        XCTAssertNotEqual(pidG, pidM)                      // 档位间不撞
        XCTAssertTrue(pidG.hasPrefix("ms-qwen-"))
        XCTAssertLessThanOrEqual(pidG.count, 64)
    }

    func testPackIdTruncatesAt64() {
        let longRef = ModelScopeRepoRef(
            org: "some-very-long-organization-name",
            name: "SomeExtremelyLongModelName.With-Dots_and_underscores-2026")
        let pid = ModelScopeManifestBuilder.packId(ref: longRef, variant: variant("mlx", .mlx, []))
        XCTAssertLessThanOrEqual(pid.count, 64)
        XCTAssertTrue(NativeModelPackManifest.validPackId(pid))
        XCTAssertFalse(pid.hasSuffix("-"))
    }

    func testFileSpecsResolveURLAndLowerSha() {
        let v = variant("m-q4", .gguf, ["sub dir/m.gguf"])
        let specs = ModelScopeManifestBuilder.fileSpecs(ref: ref, variant: v)
        XCTAssertEqual(specs.count, 1)
        // W11（L6）：直链 path 逐段百分号编码——空格 → %20（原样插值口径已随
        // L6 修复作废：含空格文件名 URL(string:) 返 nil 必败）
        XCTAssertEqual(specs[0].sources,
                       ["https://modelscope.cn/api/v1/models/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/master/sub%20dir/m.gguf"])
        XCTAssertEqual(specs[0].sha256, String(repeating: "b", count: 64))   // 小写化
    }

    func testPackManifestGGUFDriverMapping() {
        let m = ModelScopeManifestBuilder.packManifest(
            ref: ref, variant: variant("q4", .gguf, ["m.gguf"]), license: "apache-2.0")
        XCTAssertEqual(m["format"]?.string, "gguf")
        XCTAssertEqual(m["driver"]?.string, "llamacpp")     // 现有 llama.cpp 链直接可载
        XCTAssertEqual(m["task"]?.string, "chat")
        XCTAssertEqual(m["license"]?.string, "apache-2.0")
        XCTAssertEqual(m["source"]?.string, ref.pageURL)
        XCTAssertTrue(m["description"]?.string?.contains("许可由模型作者定义，商用前请自查。") ?? false)
    }

    func testPackManifestMLXMappingAndLicenseFallback() {
        let m = ModelScopeManifestBuilder.packManifest(
            ref: ref, variant: variant("mlx", .mlx, ["w.safetensors"]), license: "")
        XCTAssertEqual(m["format"]?.string, "mlx")
        XCTAssertEqual(m["driver"]?.string, "mlxswift")
        XCTAssertEqual(m["license"]?.string, "未标注")
    }
}

// MARK: - 安装编排（注入缝全链，不触网）

final class NativeModelScopeInstallerTests: XCTestCase {

    private var tmp: URL!
    private var store: NativeModelPackStore!
    private var installer: NativeModelScopeInstaller!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("msinst_\(UUID().uuidString)")
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

    /// GGUF 仓桩：文件列表（真实结构同款）+ license；源重写 file:// 本地权重
    private func stubGGUFRepo(weight: Data) throws -> (local: URL, sha: String) {
        let sha = shaHex(weight)
        let local = tmp.appendingPathComponent("local-weight.gguf")
        try weight.write(to: local)
        let files: [[String: Any]] = [
            ["Path": "m-q4_k_m.gguf", "Size": weight.count, "Sha256": sha,
             "Type": "blob", "IsLFS": true],
            ["Path": "README.md", "Size": 10, "Sha256": shaHex(Data("0123456789".utf8)),
             "Type": "blob", "IsLFS": false],
        ]
        installer.fetchData = { url in
            if url.contains("/repo/files") {
                return (200, try JSONSerialization.data(withJSONObject:
                    ["Code": 200, "Data": ["Files": files]]))
            }
            return (200, try JSONSerialization.data(withJSONObject:
                ["Code": 200, "Data": ["License": "qwen"]]))
        }
        return (local, sha)
    }

    func testResolveUnparseableInput() async {
        do {
            _ = try await installer.resolve("hello world")
            XCTFail("应抛 unparseableInput")
        } catch {
            XCTAssertEqual(error as? NativeModelScopeError, .unparseableInput)
        }
    }

    func testResolveGGUFRepoSnapshot() async throws {
        _ = try stubGGUFRepo(weight: Data(repeating: 0x7, count: 500))
        let snap = try await installer.resolve("snapshot_download('Qwen/M-GGUF')")
        XCTAssertEqual(snap.ref.org, "Qwen")
        XCTAssertEqual(snap.ref.name, "M-GGUF")
        XCTAssertEqual(snap.license, "qwen")
        XCTAssertEqual(snap.variants.count, 1)
        XCTAssertEqual(snap.variants[0].format, .gguf)
    }

    func testResolveHTTPErrorMaps() async {
        installer.fetchData = { _ in (404, Data()) }
        do {
            _ = try await installer.resolve("Qwen/Nope-GGUF")
            XCTFail("应抛 httpStatus")
        } catch {
            XCTAssertEqual(error as? NativeModelScopeError, .httpStatus(404))
        }
    }

    /// 全链：解析 → 选档 → file:// 源下载（NativeModelDownloader 真实链路）→ 登记平级
    func testInstallEndToEndWithLocalFileSource() async throws {
        let weight = Data(repeating: 0x61, count: 2_048)
        let (local, _) = try stubGGUFRepo(weight: weight)
        let snap = try await installer.resolve("https://modelscope.cn/models/Qwen/M-GGUF")

        // 源重写缝：resolve 直链 → file:// 本地权重（不触网）
        installer.makeDownloader = { onProgress in
            NativeModelDownloader(onProgress: onProgress)
        }
        // fileSpecs 由 install 内部经 resolveURLForFile 组装——重写为本地源
        installer.resolveURLForFile = { _, _ in local.absoluteString }

        var sawProgress = false
        let pid = try await installer.install(snapshot: snap, variantId: snap.variants[0].id) { p in
            if p.receivedBytes > 0 { sawProgress = true }
        }
        XCTAssertEqual(pid, "ms-qwen-m-gguf-m-q4_k_m")   // _ 为 validPackId 合法字符保留
        XCTAssertTrue(sawProgress)
        // 权重落位 + manifest.json 副本 + 登记
        let dir = tmp.appendingPathComponent("packs/\(pid)")
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("m-q4_k_m.gguf")), weight)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("manifest.json").path))
        let entry = store.getEntry(pid)
        XCTAssertEqual(entry?["format"]?.string, "gguf")
        XCTAssertEqual(entry?["driver"]?.string, "llamacpp")
        XCTAssertEqual(entry?["status"]?.string, "installed")
        // list_installed 平级可见（与目录源安装同一注册表）
        let listed = store.listInstalled().first { $0["pack_id"]?.string == pid }
        XCTAssertNotNil(listed)
        XCTAssertEqual(listed?["sha256_ok"]?.bool, true)
    }

    func testInstallUnknownVariantThrows() async throws {
        _ = try stubGGUFRepo(weight: Data(repeating: 0x1, count: 10))
        let snap = try await installer.resolve("Qwen/M-GGUF")
        do {
            _ = try await installer.install(snapshot: snap, variantId: "不存在的档")
            XCTFail("应抛档位不存在")
        } catch {
            guard case NativeModelScopeError.apiError = error else {
                return XCTFail("应抛 apiError，得到 \(error)")
            }
        }
    }
}


// MARK: - M4（0.7.5 收口审查）：仓库文件 Path 消毒（路径穿越防线）

final class ModelScopePathSanitizerTests: XCTestCase {

    private var tmp: URL!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mspath_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    private func filesJSON(_ files: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["Code": 200, "Data": ["Files": files]])
    }

    private func assertUnsafe(_ path: String, file: StaticString = #filePath, line: UInt = #line) {
        let data = filesJSON([["Path": path, "Size": 1, "Sha256": "ab",
                               "Type": "blob", "IsLFS": false]])
        XCTAssertThrowsError(try ModelScopeAPI.decodeFiles(data), file: file, line: line) { e in
            guard case NativeModelScopeError.unsafePath(let p) = e else {
                return XCTFail("应抛 unsafePath，得到 \(e)", file: file, line: line)
            }
            XCTAssertEqual(p, path, "报错必须含肇事路径（不静默跳过单文件）",
                           file: file, line: line)
        }
    }

    // MARK: - decodeFiles 拒收（含 ../、绝对路径、. 段、重复段用例）

    func testM4_rejectDotDotTraversal() {
        assertUnsafe("../../registry.json")     // 报告点名用例：穿出模型包根
        assertUnsafe("a/../b.gguf")             // 中段 ..
        assertUnsafe("..")                      // 整串 ..
        assertUnsafe("a/..")
    }

    func testM4_rejectAbsolutePath() {
        assertUnsafe("/etc/passwd")
        assertUnsafe("/tmp/evil.gguf")
    }

    func testM4_rejectDotSegment() {
        assertUnsafe("a/./b.gguf")
        assertUnsafe(".")
        assertUnsafe("./a.gguf")
    }

    func testM4_rejectDuplicateSlashSegment() {
        assertUnsafe("a//b.gguf")               // 空段（重复分隔符）
        assertUnsafe("a/b/")                    // 尾斜杠空段
    }

    func testM4_rejectBackslashAndEmpty() {
        assertUnsafe("a\\..\\b.gguf")           // Windows 分隔符混入
        assertUnsafe("")                        // 空路径
    }

    func testM4_errorDescriptionContainsPath() {
        let desc = NativeModelScopeError.unsafePath("../../registry.json").errorDescription
        XCTAssertTrue(desc?.contains("../../registry.json") == true)
        XCTAssertTrue(desc?.contains("已拦截") == true)
    }

    // MARK: - 合法路径不受影响（嵌套目录正常入列）

    func testM4_acceptSafeNestedPaths() throws {
        let data = filesJSON([
            ["Path": "sub/dir/model-q4.gguf", "Size": 3, "Sha256": "AB",
             "Type": "blob", "IsLFS": true],
            ["Path": "config.json", "Size": 1, "Sha256": "cd",
             "Type": "blob", "IsLFS": false],
        ])
        let files = try ModelScopeAPI.decodeFiles(data)
        XCTAssertEqual(files.map(\.path), ["sub/dir/model-q4.gguf", "config.json"])
    }

    func testM4_sanitizePure() {
        XCTAssertEqual(ModelScopePathSanitizer.sanitize("config.json"), "config.json")
        XCTAssertEqual(ModelScopePathSanitizer.sanitize("a/b/c.safetensors"),
                       "a/b/c.safetensors")
        XCTAssertNil(ModelScopePathSanitizer.sanitize(".."))
        XCTAssertNil(ModelScopePathSanitizer.sanitize("/a"))
        XCTAssertNil(ModelScopePathSanitizer.sanitize("a//b"))
    }

    // MARK: - 纵深防御：规范化落点必须留在目标目录内

    func testM4_containedURLStaysInsideBase() {
        let base = tmp.appendingPathComponent("pack")
        let dest = ModelScopePathSanitizer.containedURL(base: base, relativePath: "a/b.gguf")
        XCTAssertNotNil(dest)
        XCTAssertTrue(dest!.path.hasPrefix(base.standardizedFileURL.path + "/"))
        XCTAssertNil(ModelScopePathSanitizer.containedURL(base: base, relativePath: "../x"))
        XCTAssertNil(ModelScopePathSanitizer.containedURL(base: base, relativePath: "/abs"))
    }

    /// 绕过 decode 直喂 install 的手工快照（防御纵深第二道）：同样整体判失败
    func testM4_installRejectsCraftedSnapshotPath() async throws {
        let store = NativeModelPackStore(
            configProvider: { [:] },
            dataRootProvider: { self.tmp },
            environment: [NativeModelPackStore.envPacksDir: self.tmp
                .appendingPathComponent("packs").path])
        let installer = NativeModelScopeInstaller(store: store)
        installer.resolveURLForFile = { ref, path in
            ModelScopeAPI.resolveURL(ref, path: path)
        }
        let ref = ModelScopeRepoRef(org: "Qwen", name: "M-GGUF")
        let evil = ModelScopeRepoFile(path: "../../escape.gguf", sizeBytes: 1,
                                      sha256: "ab", isLFS: false)
        let variant = ModelScopeVariant(id: "evil", title: "evil", format: .gguf,
                                        files: [evil])
        let snap = ModelScopeRepoSnapshot(ref: ref, license: "", variants: [variant])
        do {
            _ = try await installer.install(snapshot: snap, variantId: "evil")
            XCTFail("可疑路径必须整个模型判失败")
        } catch {
            guard case NativeModelScopeError.unsafePath(let p) = error else {
                return XCTFail("应抛 unsafePath，得到 \(error)")
            }
            XCTAssertEqual(p, "../../escape.gguf")
        }
    }
}


// MARK: - W11（L6，0.7.5 收口审查）：直链 path 逐段 URL 编码

final class ModelScopeURLEncodingW11Tests: XCTestCase {

    private let ref = ModelScopeRepoRef(org: "Qwen", name: "M-GGUF")
    private let prefix = "https://modelscope.cn/api/v1/models/Qwen/M-GGUF/resolve/master/"

    /// 空格文件名：原实现 URL(string:) 返 nil 必败（L6 实录），编码后可构造合法 URL
    func testW11_spaceInPathEncoded() {
        let url = ModelScopeAPI.resolveURL(ref, path: "sub dir/m v2.gguf")
        XCTAssertEqual(url, prefix + "sub%20dir/m%20v2.gguf")
        XCTAssertNotNil(URL(string: url), "编码后 URL(string:) 必须可构造（L6 修复点）")
    }

    /// 中文等非 ASCII 文件名：UTF-8 百分号编码（逐字钉死，防大小写/形态漂移）
    func testW11_nonASCIIPathEncoded() {
        let url = ModelScopeAPI.resolveURL(ref, path: "模型 v2/权重.gguf")
        XCTAssertEqual(url, prefix + "%E6%A8%A1%E5%9E%8B%20v2/%E6%9D%83%E9%87%8D.gguf")
        XCTAssertNotNil(URL(string: url))
    }

    /// 已编码形态的文件名：字面量 % 编成 %25——服务端一次解码还原原名，
    /// 不发生双重解码错位
    func testW11_literalPercentDoubleEncoded() {
        let url = ModelScopeAPI.resolveURL(ref, path: "a%20b.gguf")
        XCTAssertEqual(url, prefix + "a%2520b.gguf")
        XCTAssertNotNil(URL(string: url))
    }

    /// 常规路径不变（回归：编码不改变已合法字符集）
    func testW11_plainPathUnchanged() {
        XCTAssertEqual(ModelScopeAPI.resolveURL(ref, path: "a/b-c_d.e.gguf"),
                       prefix + "a/b-c_d.e.gguf")
    }

    /// 顺序铁律（与 M4 共存）：先消毒后编码——含 .. 的穿越路径消毒不过 → nil
    /// （若顺序反了，%2E%2E 会躲过逐段消毒比对）
    func testW11_sanitizeBeforeEncodeOrder() {
        XCTAssertNil(ModelScopePathSanitizer.urlEncodedPath("../../x.gguf"))
        XCTAssertNil(ModelScopePathSanitizer.urlEncodedPath("a/../b.gguf"))
        XCTAssertNil(ModelScopePathSanitizer.urlEncodedPath("/abs/x.gguf"))
        XCTAssertNil(ModelScopePathSanitizer.urlEncodedPath("a//b.gguf"))
        XCTAssertNil(ModelScopePathSanitizer.urlEncodedPath("a\\b.gguf"))
        // 消毒通过的路径正常编码/透传
        XCTAssertEqual(ModelScopePathSanitizer.urlEncodedPath("ok/f.gguf"), "ok/f.gguf")
        XCTAssertEqual(ModelScopePathSanitizer.urlEncodedPath("o k/f.gguf"), "o%20k/f.gguf")
    }

    /// 端到端构造性：各类特殊字符文件名的编码产物 URL(string:) 均可构造
    ///（L6 原始失败面 URLError.badURL 清零）
    func testW11_encodedURLsAlwaysConstructible() {
        for p in ["a b.gguf", "权重.gguf", "m (1).gguf", "q&k=x.gguf", "100%.gguf",
                  "deep/嵌套 目录/f.bin"] {
            let url = ModelScopeAPI.resolveURL(ref, path: p)
            XCTAssertNotNil(URL(string: url), "应可构造：\(p) → \(url)")
        }
    }
}


// MARK: - W12（L7，0.7.5 收口审查）：安装失败半成品清理

final class ModelScopeInstallCleanupW12Tests: XCTestCase {

    private var tmp: URL!
    private var store: NativeModelPackStore!
    private var installer: NativeModelScopeInstaller!
    private let fm = FileManager.default

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("msclean_\(UUID().uuidString)")
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        store = NativeModelPackStore(
            configProvider: { [:] },
            dataRootProvider: { self.tmp },
            environment: [NativeModelPackStore.envPacksDir: self.tmp.appendingPathComponent("packs").path])
        installer = NativeModelScopeInstaller(store: store)
    }

    override func tearDown() {
        try? fm.removeItem(at: tmp)
        super.tearDown()
    }

    private func shaHex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 三文件手工快照（a.gguf 根目录 / dir/c.gguf 嵌套 / b.gguf 尾文件——
    /// 尾文件失败时前两文件已落位，正中 L7 半成品形态），pid 恒为
    /// ms-qwen-m-gguf-v1（GGUF 档 id=v1）。
    private func makeSnapshot(dataA: Data, dataC: Data, dataB: Data)
        -> (ModelScopeRepoSnapshot, String) {
        let ref = ModelScopeRepoRef(org: "Qwen", name: "M-GGUF")
        let files = [
            ModelScopeRepoFile(path: "a.gguf", sizeBytes: Int64(dataA.count),
                               sha256: shaHex(dataA), isLFS: true),
            ModelScopeRepoFile(path: "dir/c.gguf", sizeBytes: Int64(dataC.count),
                               sha256: shaHex(dataC), isLFS: true),
            ModelScopeRepoFile(path: "b.gguf", sizeBytes: Int64(dataB.count),
                               sha256: shaHex(dataB), isLFS: true),
        ]
        let variant = ModelScopeVariant(id: "v1", title: "v1", format: .gguf, files: files)
        return (ModelScopeRepoSnapshot(ref: ref, license: "", variants: [variant]),
                "ms-qwen-m-gguf-v1")
    }

    /// 中途失败不残留 destDir：尾文件源不存在 → install 抛 allSourcesFailed；
    /// 已完成的 a/dir-c 挪入 .partial 续传区，destDir 根不留完成文件、无 manifest、
    /// 注册表无登记（列表不见却占盘的 L7 形态清零）
    func testW12_failureRetractsCompletedFilesToPartial() async throws {
        let dataA = Data(repeating: 0x61, count: 700)
        let dataC = Data(repeating: 0x63, count: 500)
        let dataB = Data(repeating: 0x62, count: 300)
        let (snap, pid) = makeSnapshot(dataA: dataA, dataC: dataC, dataB: dataB)
        let localA = tmp.appendingPathComponent("src-a.gguf")
        let localC = tmp.appendingPathComponent("src-c.gguf")
        try dataA.write(to: localA)
        try dataC.write(to: localC)
        // b 的源从不创建 → copyLocal 抛「本地源不存在」→ 全部源失败
        installer.resolveURLForFile = { _, path in
            switch path {
            case "a.gguf": return localA.absoluteString
            case "dir/c.gguf": return localC.absoluteString
            default: return self.tmp.appendingPathComponent("src-b-missing.gguf").absoluteString
            }
        }
        let destDir = tmp.appendingPathComponent("packs/\(pid)")
        let partDir = destDir.appendingPathComponent(".partial")

        do {
            _ = try await installer.install(snapshot: snap, variantId: "v1")
            XCTFail("尾文件源缺失必须抛错")
        } catch {
            guard case NativeModelDownloadError.allSourcesFailed = error else {
                return XCTFail("应抛 allSourcesFailed，得到 \(error)")
            }
        }

        // 核心断言①：destDir 根不残留完成文件（含嵌套骨架清空）
        XCTAssertFalse(fm.fileExists(atPath: destDir.appendingPathComponent("a.gguf").path),
                       "失败后半成品完成文件不得残留 destDir（L7）")
        XCTAssertFalse(fm.fileExists(atPath: destDir.appendingPathComponent("dir").path),
                       "挪空的目录骨架应顺手清掉")
        XCTAssertFalse(fm.fileExists(atPath: destDir.appendingPathComponent("manifest.json").path))
        // 核心断言②：完成文件字节挪入 .partial 续传区（自愈素材不丢）
        XCTAssertEqual(try Data(contentsOf: partDir.appendingPathComponent("a.gguf.part")), dataA)
        XCTAssertEqual(try Data(contentsOf: partDir.appendingPathComponent("dir/c.gguf.part")), dataC)
        // 核心断言③：注册表无登记（不变式维持：未成功不登记）
        XCTAssertNil(store.getEntry(pid))
    }

    /// 重试可续（自愈不破坏）：失败后修好 b 源、并删掉 a/c 的原始本地源——
    /// 若 a/c 仍能落位，证明全靠挪入 .partial 的完成文件经下载器快速路径②
    ///（.part 恰好完整 → 补校验+rename）自愈，而非重新下载
    func testW12_retryHealsFromRetractedPartial() async throws {
        let dataA = Data(repeating: 0x61, count: 700)
        let dataC = Data(repeating: 0x63, count: 500)
        let dataB = Data(repeating: 0x62, count: 300)
        let (snap, pid) = makeSnapshot(dataA: dataA, dataC: dataC, dataB: dataB)
        let localA = tmp.appendingPathComponent("src-a.gguf")
        let localC = tmp.appendingPathComponent("src-c.gguf")
        let localB = tmp.appendingPathComponent("src-b.gguf")
        try dataA.write(to: localA)
        try dataC.write(to: localC)
        installer.resolveURLForFile = { _, path in
            switch path {
            case "a.gguf": return localA.absoluteString
            case "dir/c.gguf": return localC.absoluteString
            default: return localB.absoluteString
            }
        }
        // 第一次：b 源缺失 → 失败（半成品挪 .partial）
        _ = try? await installer.install(snapshot: snap, variantId: "v1")
        let destDir = tmp.appendingPathComponent("packs/\(pid)")
        let partDir = destDir.appendingPathComponent(".partial")
        XCTAssertTrue(fm.fileExists(atPath: partDir.appendingPathComponent("a.gguf.part").path),
                      "前置：失败清理已把 a 挪入续传区")

        // 重试姿态：b 源修好；a/c 源删除（断掉重下可能——只能靠 .part 自愈）
        try dataB.write(to: localB)
        try fm.removeItem(at: localA)
        try fm.removeItem(at: localC)

        let pid2 = try await installer.install(snapshot: snap, variantId: "v1")
        XCTAssertEqual(pid2, pid)
        // a/c 从 .partial 自愈落位（源已删，重下必败——成功即快速路径②实证）
        XCTAssertEqual(try Data(contentsOf: destDir.appendingPathComponent("a.gguf")), dataA)
        XCTAssertEqual(try Data(contentsOf: destDir.appendingPathComponent("dir/c.gguf")), dataC)
        XCTAssertEqual(try Data(contentsOf: destDir.appendingPathComponent("b.gguf")), dataB)
        XCTAssertTrue(fm.fileExists(atPath: destDir.appendingPathComponent("manifest.json").path))
        // 登记平级 + 空暂存目录顺手清掉（成功路径既有口径）
        XCTAssertEqual(store.getEntry(pid)?["status"]?.string, "installed")
        XCTAssertFalse(fm.fileExists(atPath: partDir.path),
                       "全部落位后空 .partial 应由成功路径顺手清掉")
    }

    /// manifest 已落位的 destDir 不动（registerPack 失败边角口径，纯函数面）：
    /// 现场保留——重试走快速路径①（dest 已在且哈希对）+ 重写 manifest + 补登记
    func testW12_retractKeepsManifestedDestUntouched() throws {
        let destDir = tmp.appendingPathComponent("pack")
        let partDir = destDir.appendingPathComponent(".partial")
        try fm.createDirectory(at: partDir, withIntermediateDirectories: true)
        let payload = Data(repeating: 0x7, count: 64)
        try payload.write(to: destDir.appendingPathComponent("m.gguf"))
        try Data("{}".utf8).write(to: destDir.appendingPathComponent("manifest.json"))
        let specs = [RequiredFileSpec(path: "m.gguf", sizeBytes: Int64(payload.count),
                                      sha256: shaHex(payload), sources: [])]
        NativeModelScopeInstaller.retractUnmanifestedDest(destDir: destDir,
                                                          partDir: partDir, specs: specs)
        XCTAssertEqual(try Data(contentsOf: destDir.appendingPathComponent("m.gguf")), payload,
                       "manifest 已落位 → 完成文件原地保留（快速路径①现场）")
        XCTAssertFalse(fm.fileExists(atPath: partDir.appendingPathComponent("m.gguf.part").path))
    }

    /// 无 manifest 纯函数面对照：完成文件挪 .partial（与 install catch 同函数）
    func testW12_retractMovesFilesWhenManifestMissing() throws {
        let destDir = tmp.appendingPathComponent("pack")
        let partDir = destDir.appendingPathComponent(".partial")
        try fm.createDirectory(at: destDir.appendingPathComponent("sub"),
                               withIntermediateDirectories: true)
        let payload = Data(repeating: 0x9, count: 32)
        try payload.write(to: destDir.appendingPathComponent("sub/m.gguf"))
        let specs = [RequiredFileSpec(path: "sub/m.gguf", sizeBytes: Int64(payload.count),
                                      sha256: shaHex(payload), sources: [])]
        NativeModelScopeInstaller.retractUnmanifestedDest(destDir: destDir,
                                                          partDir: partDir, specs: specs)
        XCTAssertFalse(fm.fileExists(atPath: destDir.appendingPathComponent("sub/m.gguf").path))
        XCTAssertEqual(try Data(contentsOf: partDir.appendingPathComponent("sub/m.gguf.part")),
                       payload)
        XCTAssertFalse(fm.fileExists(atPath: destDir.appendingPathComponent("sub").path),
                       "挪空的嵌套骨架应清掉")
        XCTAssertTrue(fm.fileExists(atPath: partDir.path), ".partial 续传区本身保留")
    }
}


// MARK: - Bug7 收口（业主 2026-09-28 拍板）：魔塔链端到端钉桩
//
//  实测原景（app-20260928.log L1774-1795）：魔塔单源直链首次下载 3.1s 被
//  -1005 掐断 → 旧链「源失败换下一源」→ 单源=判死 → 业主手动再点立即满速
//  成功。修复后 install 一次到位，不再需要手动重试。stub 复刻该现场
//  （connLostPlan 剧本缝；URLProtocol 只吞 msstub7.local 域，绝不触网）。

/// Bug7 专用 URLProtocol stub（精简同款 StubURLProtocol 口径）：
/// 头+首块（1000 字节）即到后 didFailWithError(.networkConnectionLost)，
/// connLostPlan 次数耗尽后走 handlers 正常投递；ranges 录证 Range 续传基线。
private final class MSStub7URLProtocol: URLProtocol {
    static let lock = NSLock()
    static var handlers: [String: (URLRequest) -> (Int, Data)] = [:]
    static var ranges: [String?] = []
    static var connLostPlan: [String: Int] = [:]
    private var pending: DispatchWorkItem?

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        handlers = [:]; ranges = []; connLostPlan = [:]
    }
    static func recordedRanges() -> [String?] {
        lock.lock(); defer { lock.unlock() }; return ranges
    }
    /// Range 感知响应：bytes=N- → 206 尾段；无 Range → 200 全量
    static func rangeAware(_ full: Data) -> (URLRequest) -> (Int, Data) {
        { req in
            guard let range = req.value(forHTTPHeaderField: "Range"),
                  range.hasPrefix("bytes="), range.hasSuffix("-"),
                  let n = Int64(range.dropFirst(6).dropLast()), n > 0, n < full.count else {
                return (200, full)
            }
            return (206, full.subdata(in: Int(n)..<full.count))
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "msstub7.local"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock()
        Self.ranges.append(request.value(forHTTPHeaderField: "Range"))
        let rule = Self.handlers[url.absoluteString]
        var connLost = false
        if let n = Self.connLostPlan[url.absoluteString], n > 0 {
            Self.connLostPlan[url.absoluteString] = n - 1
            connLost = true
        }
        Self.lock.unlock()
        let (status, body) = rule?(request) ?? (404, Data())
        let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                   headerFields: ["Content-Length": "\(body.count)"])!
        schedule(0.02) { [weak self] in
            guard let self else { return }
            self.client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            if connLost {
                self.schedule(0.3) { [weak self] in
                    guard let self else { return }
                    self.client?.urlProtocol(self, didLoad: body.prefix(1000))
                    self.schedule(0.2) { [weak self] in
                        guard let self else { return }
                        self.client?.urlProtocol(self,
                            didFailWithError: URLError(.networkConnectionLost))
                    }
                }
            } else {
                self.schedule(0.3) { [weak self] in self?.deliver(body, from: 0) }
            }
        }
    }

    private func deliver(_ body: Data, from offset: Int) {
        guard offset < body.count else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let end = min(offset + 65536, body.count)
        let piece = Data(body[offset..<end])
        schedule(0.01) { [weak self] in
            guard let self else { return }
            self.client?.urlProtocol(self, didLoad: piece)
            self.deliver(body, from: end)
        }
    }

    private func schedule(_ delay: TimeInterval, _ block: @escaping () -> Void) {
        let work = DispatchWorkItem(block: block)
        pending = work
        DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work)
    }

    override func stopLoading() { pending?.cancel() }
}

extension NativeModelScopeInstallerTests {

    /// Bug7 端到端（魔塔链原景钉桩）：单源直链首次 -1005 掐断（已收 1000 字节）
    /// → 下载器自动同源原地重试（Range: bytes=1000- 续传）→ install 一次成功
    /// 返回 pid，落位逐字节一致 + manifest + 登记平级——业主不再需要手动再点。
    func testInstallRecoversFromTransientConnLostWithoutManualRetry() async throws {
        let weight = Data((0..<6000).map { UInt8($0 % 241) })
        _ = try stubGGUFRepo(weight: weight)
        let snap = try await installer.resolve("https://modelscope.cn/models/Qwen/M-GGUF")
        let url = "https://msstub7.local/resolve/m-q4_k_m.gguf"
        MSStub7URLProtocol.reset()
        MSStub7URLProtocol.handlers[url] = MSStub7URLProtocol.rangeAware(weight)
        MSStub7URLProtocol.connLostPlan[url] = 1   // 首发 -1005，重试走正常投递
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MSStub7URLProtocol.self]
        let httpSession = URLSession(configuration: cfg)
        let oldBackoff = NativeModelDownloader.transientBackoffSeconds
        NativeModelDownloader.transientBackoffSeconds = [0.05, 0.05]   // 提速（生产 1s/3s）
        defer { NativeModelDownloader.transientBackoffSeconds = oldBackoff }
        installer.makeDownloader = { onProgress in
            NativeModelDownloader(session: httpSession, onProgress: onProgress)
        }
        installer.resolveURLForFile = { _, _ in url }

        let pid = try await installer.install(snapshot: snap, variantId: snap.variants[0].id)
        XCTAssertEqual(pid, "ms-qwen-m-gguf-m-q4_k_m")
        XCTAssertEqual(
            try Data(contentsOf: tmp.appendingPathComponent("packs/\(pid)/m-q4_k_m.gguf")),
            weight, "首次 -1005 自动重试后落位逐字节一致（install 一次成功）")
        XCTAssertEqual(MSStub7URLProtocol.recordedRanges(), [nil, "bytes=1000-"],
                       "首发无 Range；重试带断点续传基线 1000——恰好 2 次请求")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tmp.appendingPathComponent("packs/\(pid)/manifest.json").path),
            "manifest 副本落位（登记平级，与既有端到端同口径）")
    }
}
