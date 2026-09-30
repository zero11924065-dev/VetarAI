//
//  NativeModelPackStoreTests.swift
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

//  逐条锚定（⛔ 行为规格源 subagent/sidecar/model_packs/{manifest,store}.py）：
//    · valid_pack_id slug 域；validate_rel_path 七类拒绝逐字文案
//    · validate_pack 全字段/逐文件/去重/Σ 一致性；validate_catalog version/数组/去重
//    · packs_root 解析链（env > config > data_root）+ .app 拒绝铁律
//    · registry 读（损坏→{}）/ 原子写（tmp 不残留）/ register·unregister·set_enabled
//    · list_installed 磁盘探测（缺文件/实际占用/.partial 残留/manifest 合并）
//    · remove_pack 顺序（先删目录再清注册表；两者皆无 → false）
//
//  全程不触网：store 注入临时 data_root 与环境表，无内核依赖。
//

import XCTest
@testable import VetarAINative

final class NativeModelPackStoreTests: XCTestCase {

    private var tmp: URL!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mpstore_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    // MARK: 夹具

    private func makeStore(cfg: [String: JSONValue] = [:],
                           env: [String: String] = [:]) -> NativeModelPackStore {
        NativeModelPackStore(
            configProvider: { cfg },
            dataRootProvider: { self.tmp },
            environment: env)
    }

    /// 最小合法 chat 包条目（gguf 单文件）。
    private func samplePack(_ pid: String = "qwen-mini", size: Int64 = 4) -> [String: JSONValue] {
        [
            "pack_id": .string(pid),
            "name": .string("迷你对话包"),
            "task": .string("chat"),
            "format": .string("gguf"),
            "driver": .string("llamacpp"),
            "version": .string("1.0.0"),
            "size_bytes": .int(size),
            "files": .array([.object([
                "path": .string("model.gguf"),
                "size_bytes": .int(size),
                "sha256": .string(String(repeating: "a", count: 64)),
                "sources": .array([.string("file:///tmp/model.gguf")]),
            ])]),
        ]
    }

    // MARK: - valid_pack_id / validate_rel_path

    func testValidPackId() {
        XCTAssertTrue(NativeModelPackManifest.validPackId("qwen-7b_gguf"))
        XCTAssertFalse(NativeModelPackManifest.validPackId(""))
        XCTAssertFalse(NativeModelPackManifest.validPackId("UPPER"))
        XCTAssertFalse(NativeModelPackManifest.validPackId("has/slash"))
        XCTAssertFalse(NativeModelPackManifest.validPackId("has.dot"))
        XCTAssertFalse(NativeModelPackManifest.validPackId(String(repeating: "a", count: 65)))
        XCTAssertFalse(NativeModelPackManifest.validPackId(.int(1)))
    }

    func testValidateRelPathRejections() {
        let V = NativeModelPackManifest.validateRelPath
        XCTAssertEqual(V(.null), "files[].path 必须是非空字符串（相对路径）")
        XCTAssertEqual(V(.string("")), "files[].path 必须是非空字符串（相对路径）")
        XCTAssertEqual(V(.string("/etc/passwd")),
                       "files[].path 不允许绝对路径: '/etc/passwd'")
        XCTAssertEqual(V(.string("C:/win/model")),
                       "files[].path 不允许 Windows 盘符绝对路径: 'C:/win/model'")
        XCTAssertEqual(V(.string("a\\b")),
                       "files[].path 含反斜杠（路径分隔符统一为 /）: 'a\\\\b'")
        XCTAssertEqual(V(.string("../escape")),
                       "files[].path 含 '..' 段（路径穿越风险）: '../escape'")
        XCTAssertEqual(V(.string("./dot")),
                       "files[].path 含 '.' 段（路径穿越风险）: './dot'")
        XCTAssertEqual(V(.string("a//b")),
                       "files[].path 含空路径段（形如 a//b）: 'a//b'")
        XCTAssertEqual(V(.string(" lead")),
                       "files[].path 首尾含空白字符: ' lead'")
        XCTAssertEqual(V(.string(".partial/x.gguf")),
                       "files[].path 占用保留目录 .partial/: '.partial/x.gguf'")
        XCTAssertEqual(V(.string("manifest.json")),
                       "files[].path 占用保留名 manifest.json（安装时写入的清单副本）")
        XCTAssertEqual(V(.string("a\u{1}b")),
                       "files[].path 含控制字符: 'a\\x01b'")
        let long = String(repeating: "x", count: 241)
        XCTAssertEqual(V(.string(long)),
                       "files[].path 超过 240 字符上限: '\(String(repeating: "x", count: 40))'...")
        // 合法形态
        XCTAssertNil(V(.string("model.gguf")))
        XCTAssertNil(V(.string("sub/dir/model.onnx")))
        XCTAssertNil(V(.string(".hidden/ok.bin")))
    }

    // MARK: - validate_pack

    func testValidatePackHappy() {
        XCTAssertEqual(NativeModelPackManifest.validatePack(.object(samplePack())), [])
        // 可选键 context_length/sample_rate 正整数合法
        var p = samplePack()
        p["context_length"] = .int(32768)
        p["sample_rate"] = .int(16000)
        XCTAssertEqual(NativeModelPackManifest.validatePack(.object(p)), [])
    }

    func testValidatePackFieldErrors() {
        XCTAssertEqual(NativeModelPackManifest.validatePack(.int(3)), ["pack 条目必须是对象"])
        var p = samplePack()
        p["pack_id"] = .string("BAD ID")
        p["name"] = .string("  ")
        p["task"] = .string("image")
        p["format"] = .string("safetensors")
        p["driver"] = .string("mlx")
        p["version"] = .string("")
        p["description"] = .int(7)
        p["size_bytes"] = .int(0)
        p["context_length"] = .int(-5)
        p["sample_rate"] = .bool(true)
        let errs = NativeModelPackManifest.validatePack(.object(p))
        XCTAssertTrue(errs.contains("pack_id 必须是 slug（小写字母/数字/-/_，1~64 长），得到 'BAD ID'"), "\(errs)")
        XCTAssertTrue(errs.contains("name 必须是非空字符串"), "\(errs)")
        XCTAssertTrue(errs.contains("task 必须是 asr/chat/embedding 之一，得到 'image'"), "\(errs)")
        XCTAssertTrue(errs.contains("format 必须是 onnx/gguf 之一，得到 'safetensors'"), "\(errs)")
        XCTAssertTrue(errs.contains("driver 必须是 onnxruntime/llamacpp 之一，得到 'mlx'"), "\(errs)")
        XCTAssertTrue(errs.contains("version 必须是非空字符串（语义化版本，如 1.0.0）"), "\(errs)")
        XCTAssertTrue(errs.contains("description 必须是字符串（可空），得到 int"), "\(errs)")
        XCTAssertTrue(errs.contains("size_bytes 必须是正整数（包总字节数），得到 0"), "\(errs)")
        XCTAssertTrue(errs.contains("context_length 必须是正整数（可选键，不需要请整键省略），得到 -5"), "\(errs)")
        XCTAssertTrue(errs.contains("sample_rate 必须是正整数（可选键，不需要请整键省略），得到 True"), "\(errs)")
    }

    func testValidatePackFilesErrors() {
        var p = samplePack()
        p["files"] = .array([])
        XCTAssertEqual(NativeModelPackManifest.validatePack(.object(p)),
                       ["files 必须是非空数组（多文件是硬需求：模型本体+tokenizer 等）"])

        p["files"] = .array([
            .object(["path": .string("a.gguf"), "size_bytes": .int(4),
                     "sha256": .string(String(repeating: "a", count: 64)),
                     "sources": .array([.string("ftp://x/a.gguf")])]),
            .object(["path": .string("a.gguf"), "size_bytes": .int(0),
                     "sha256": .string("zz"),
                     "sources": .array([])]),
        ])
        p["size_bytes"] = .int(999)
        let errs = NativeModelPackManifest.validatePack(.object(p))
        XCTAssertTrue(errs.contains("files[0].sources[0] 必须是 http(s):// 或 file:// URL（得到 'ftp://x/a.gguf'）"), "\(errs)")
        XCTAssertTrue(errs.contains("files[1].path 重复: 'a.gguf'"), "\(errs)")
        XCTAssertTrue(errs.contains("files[1].size_bytes 必须是正整数（得到 0）"), "\(errs)")
        XCTAssertTrue(errs.contains("files[1].sha256 必须是 64 位十六进制字符串（得到 'zz'）"), "\(errs)")
        XCTAssertTrue(errs.contains("files[1].sources 必须是非空 URL 数组（多源按序回退）"), "\(errs)")
        // Σ 一致性只在全字段合法时判（size_bytes=999 ≠ 4+0，但 files[1].size 非法 → 不判）
        XCTAssertFalse(errs.contains { $0.hasPrefix("size_bytes(999)") }, "\(errs)")
    }

    func testValidatePackSizeSumMismatch() {
        var p = samplePack("s", size: 10)
        p["files"] = .array([
            .object(["path": .string("a.bin"), "size_bytes": .int(4),
                     "sha256": .string(String(repeating: "a", count: 64)),
                     "sources": .array([.string("file:///a.bin")])]),
            .object(["path": .string("b.bin"), "size_bytes": .int(5),
                     "sha256": .string(String(repeating: "b", count: 64)),
                     "sources": .array([.string("file:///b.bin")])]),
        ])
        XCTAssertEqual(NativeModelPackManifest.validatePack(.object(p)),
                       ["size_bytes(10) 与 files 之和(9) 不一致"])
    }

    // MARK: - validate_catalog

    func testValidateCatalog() {
        XCTAssertEqual(NativeModelPackManifest.validateCatalog(.int(1)), ["catalog 必须是 JSON 对象"])
        XCTAssertEqual(NativeModelPackManifest.validateCatalog(.object(["version": .int(2), "packs": .array([])])),
                       ["catalog.version 必须是 1，得到 2"])
        XCTAssertEqual(NativeModelPackManifest.validateCatalog(.object(["version": .int(1)])),
                       ["catalog.packs 必须是数组"])
        let cat: JSONValue = .object([
            "version": .int(1),
            "packs": .array([.object(samplePack("dup")), .object(samplePack("dup"))]),
        ])
        XCTAssertEqual(NativeModelPackManifest.validateCatalog(cat),
                       ["packs[1]: pack_id 重复: 'dup'"])
        let ok: JSONValue = .object(["version": .int(1), "packs": .array([.object(samplePack())])])
        XCTAssertEqual(NativeModelPackManifest.validateCatalog(ok), [])
    }

    // MARK: - packs_root 解析链 + .app 拒绝

    func testPacksRootDefaultIsDataRootModelsPacks() throws {
        let store = makeStore()
        let root = try store.packsRoot()
        XCTAssertEqual(root.path, tmp.appendingPathComponent("models/packs").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))   // mkdir 副作用
    }

    func testPacksRootConfigBeatsDefault() throws {
        let custom = tmp.appendingPathComponent("custom-packs").path
        let store = makeStore(cfg: ["model_packs_dir": .string(custom)])
        XCTAssertEqual(try store.packsRoot().path, custom)
    }

    func testPacksRootEnvBeatsConfig() throws {
        let envDir = tmp.appendingPathComponent("env-packs").path
        let store = makeStore(cfg: ["model_packs_dir": .string("/elsewhere")],
                              env: ["VETARAI_MODEL_PACKS_DIR": envDir])
        XCTAssertEqual(try store.packsRoot().path, envDir)
    }

    func testPacksRootAppBundleRefused() {
        let appDir = tmp.appendingPathComponent("VetarAI.app/Contents/Resources/packs").path
        let store = makeStore(cfg: ["model_packs_dir": .string(appDir)])
        XCTAssertThrowsError(try store.packsRoot()) { err in
            guard case .packsRootForbidden(let p) = err as? NativeModelPackError else {
                return XCTFail("应为 packsRootForbidden：\(err)")
            }
            XCTAssertEqual("模型包安装根不允许位于 .app 包内: \(p)",
                           (err as? NativeModelPackError)?.message)
        }
    }

    // MARK: - registry 读写

    func testRegistryCorruptReadsEmpty() throws {
        let store = makeStore()
        let root = try store.packsRoot()
        try "not json{{".write(to: root.appendingPathComponent("registry.json"),
                               atomically: true, encoding: .utf8)
        XCTAssertEqual(store.readRegistry(), [:])
    }

    func testRegisterWritesAtomicallyAndRoundTrips() throws {
        let store = makeStore()
        try store.registerPack("qwen-mini", pack: samplePack())
        // tmp 文件不残留（原子 rename）
        let names = try FileManager.default.contentsOfDirectory(atPath: store.packsRoot().path)
        XCTAssertFalse(names.contains("registry.json.tmp"), "\(names)")
        let entry = store.getEntry("qwen-mini")
        XCTAssertEqual(entry?["status"]?.string, "installed")
        XCTAssertEqual(entry?["task"]?.string, "chat")
        XCTAssertEqual(entry?["sha256_ok"]?.bool, true)
        XCTAssertEqual(entry?["files"]?.array?.first?.object?["sha256"]?.string,
                       String(repeating: "a", count: 64))
        XCTAssertFalse((entry?["installed_at"]?.string ?? "").isEmpty)
        XCTAssertTrue(store.isInstalled("qwen-mini"))
    }

    func testRegisterRejectsBadPackId() {
        let store = makeStore()
        XCTAssertThrowsError(try store.registerPack("BAD", pack: samplePack())) { err in
            XCTAssertEqual((err as? NativeModelPackError)?.message,
                           "非法 pack_id（须 slug 小写字母/数字/-/_，1~64 长）: 'BAD'")
        }
    }

    func testUnregisterAndSetEnabled() throws {
        let store = makeStore()
        XCTAssertFalse(store.unregisterPack("ghost"))
        XCTAssertNil(store.setEnabled("ghost", enabled: false))
        try store.registerPack("qwen-mini", pack: samplePack())
        XCTAssertEqual(store.setEnabled("qwen-mini", enabled: false), false)
        XCTAssertEqual(store.getEntry("qwen-mini")?["status"]?.string, "disabled")
        XCTAssertEqual(store.setEnabled("qwen-mini", enabled: true), true)
        XCTAssertTrue(store.unregisterPack("qwen-mini"))
        XCTAssertFalse(store.isInstalled("qwen-mini"))
    }

    // MARK: - list_installed 磁盘探测

    func testListInstalledDiskProbe() throws {
        let store = makeStore()
        try store.registerPack("qwen-mini", pack: samplePack(size: 4))
        let dir = try store.packDir("qwen-mini")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // manifest.json 副本（name/description 以它为准；context_length 经它合并）
        try NativeJSONWriter.dumps(.object([
            "name": .string("展示名"), "description": .string("描述"),
            "context_length": .int(32768),
        ])).write(to: dir.appendingPathComponent("manifest.json"),
                  atomically: true, encoding: .utf8)
        // 权重落盘 4 字节 + .partial 残留
        try Data(count: 4).write(to: dir.appendingPathComponent("model.gguf"))
        let partDir = try store.partialDir("qwen-mini")
        try FileManager.default.createDirectory(at: partDir, withIntermediateDirectories: true)
        try Data(count: 2).write(to: partDir.appendingPathComponent("other.bin.part"))

        let rows = store.listInstalled()
        XCTAssertEqual(rows.count, 1)
        let r = rows[0]
        XCTAssertEqual(r["pack_id"]?.string, "qwen-mini")
        XCTAssertEqual(r["name"]?.string, "展示名")
        XCTAssertEqual(r["description"]?.string, "描述")
        XCTAssertEqual(r["context_length"]?.int, 32768)
        XCTAssertEqual(r["enabled"]?.bool, true)
        XCTAssertEqual(r["size_bytes"]?.int, 4)
        XCTAssertEqual(r["missing_files"]?.array, [])
        XCTAssertEqual(r["has_partial"]?.bool, true)
        XCTAssertEqual(r["dir"]?.string, dir.path)

        // 删掉权重 → missing_files 标出（以磁盘为准而非盲信注册表）
        try FileManager.default.removeItem(at: dir.appendingPathComponent("model.gguf"))
        let r2 = store.listInstalled()[0]
        XCTAssertEqual(r2["missing_files"]?.array?.first?.string, "model.gguf")
        XCTAssertEqual(r2["size_bytes"]?.int, 0)
    }

    func testListInstalledDisabledAndManifestFallback() throws {
        let store = makeStore()
        try store.registerPack("b-pack", pack: samplePack("b-pack"))
        _ = store.setEnabled("b-pack", enabled: false)
        let r = store.listInstalled()[0]
        XCTAssertEqual(r["name"]?.string, "b-pack")   // 无 manifest 副本 → pack_id 兜底
        XCTAssertEqual(r["status"]?.string, "disabled")
        XCTAssertEqual(r["enabled"]?.bool, false)
        XCTAssertEqual(r["context_length"]?.int, 0)   // 未声明 → 0
    }

    // MARK: - remove_pack

    func testRemovePackOrderAndMissing() throws {
        let store = makeStore()
        XCTAssertFalse(try store.removePack("ghost"))
        try store.registerPack("qwen-mini", pack: samplePack())
        let dir = try store.packDir("qwen-mini")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(count: 1).write(to: dir.appendingPathComponent("model.gguf"))
        XCTAssertTrue(try store.removePack("qwen-mini"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertFalse(store.isInstalled("qwen-mini"))
        // 只有磁盘目录（无注册表条目）也返回 true
        let orphan = try store.packDir("orphan")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        XCTAssertTrue(try store.removePack("orphan"))
    }
}
