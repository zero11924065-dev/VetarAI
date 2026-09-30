//
//  NativeToolRegistryTests.swift
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

//  把 subagent/sidecar/tools/test_tools.py（284 行，⛔ 只读行为规格源）当行为
//  规格逐条翻译（Office 相关用例跳过——doc_reader/create_document 属 P2-W3b，
//  此处仅断言 not_ported 占位如实报错）：
//    · 第 1 节 工作目录内 4 工具 / 第 2 节 截断 / 第 3 节 越界放行
//    · 第 4 节 敏感删除授权（注入伪造敏感区，对齐 Python monkeypatch 用例）
//    · 4f 真实敏感目录写/建/读（/etc /usr 只读安全路径，授权拒绝先于执行）
//    · 第 5 节 delete_path 语义 / 第 6 节 schema 与入参契约 / 第 7 节 NoopAuthorizer
//    · 第 8 节 标点笔误硬拦 + 越界 advisory
//    · 图片 base64 分支（checkpoint-067 R-4）/ 大文本软提示（B2 0.4.8）
//    · NativeRegistryToolExecutor 工作流 tool 节点端到端（engine 装配点亮）
//
//  隔离纪律：全部 mktemp 临时目录；不触真网络（context 传输层注入必失败假实现）。
//

import XCTest
@testable import VetarAINative

// MARK: - 必失败传输层（registry 用例不触网；触网即测试缺陷）

private struct FailingTransport: NativeHTTPTransport {
    func send(_ request: NativeHTTPRequest) async throws -> NativeHTTPResponse {
        throw NativeHTTPTransportError.connect("tests must not hit network")
    }
}

// MARK: - 测试上下文构造

enum NativeToolTestSupport {
    static func makeContext(
        dataRoot: URL,
        transport: any NativeHTTPTransport = FailingTransport(),
        gitRunner: NativeGitRunner = NativeGitRunner { _, _ in .launchFailed("tests stub") },
        guardClock: (() -> Double)? = nil,
        isSensitive: (@Sendable (String) -> Bool)? = nil
    ) -> NativeToolContext {
        let store = NativeConfigStore(environment: ["VETARAI_DATA_ROOT": dataRoot.path])
        let now: @Sendable () -> Double = guardClock.map { c in { c() } }
            ?? { ProcessInfo.processInfo.systemUptime }
        let netGuard = NativeNetworkGuard(
            configProvider: { (try? store.getConfig()) ?? NativeConfigStore.defaultConfig },
            configWriter: { _ = try store.reloadConfig(patch: $0) },
            now: now)
        return NativeToolContext(
            config: { (try? store.getConfig()) ?? NativeConfigStore.defaultConfig },
            reloadConfig: { try store.reloadConfig(patch: $0) },
            pluginsRoot: { store.pluginsRoot() },
            skillsRoot: {
                let url = store.dataRoot().appendingPathComponent("skills")
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                return url
            },
            networkGuard: netGuard,
            transport: transport,
            gitRunner: gitRunner,
            isSensitive: isSensitive ?? { NativeToolSandbox.isSensitivePath($0) })
    }

    static func resolve(_ p: String) -> String { NativePyPath.resolve(p) }
}

// MARK: - 测试体

final class NativeToolRegistryTests: XCTestCase {

    private var tmp: URL!
    private var sandbox: URL!
    private var context: NativeToolContext!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("w3areg_\(UUID().uuidString)")
        sandbox = tmp.appendingPathComponent("sandbox")
        try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        context = NativeToolTestSupport.makeContext(dataRoot: tmp.appendingPathComponent("dataroot"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    private var root: String { NativePyPath.resolve(sandbox.path) }

    private func write(_ rel: String, _ content: String) throws {
        let url = sandbox.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try content.write(to: url, atomically: false, encoding: .utf8)
    }

    private func exec(_ tool: String, _ args: [String: JSONValue],
                      authorizer: (any NativeToolAuthorizer)? = nil,
                      ctx: NativeToolContext? = nil) async -> [String: JSONValue] {
        await NativeToolRegistry.execute(tool, args: args, sandboxRoot: root,
                                         authorizer: authorizer, context: ctx ?? context)
    }

    private func errOf(_ r: [String: JSONValue]) -> String { r["error"]?.string ?? "" }

    // MARK: - 1. 工作目录内 4 工具

    func testListDirBasic() async throws {
        try write("a.txt", "hello m1")
        try FileManager.default.createDirectory(at: sandbox.appendingPathComponent("sub"),
                                                withIntermediateDirectories: true)
        try write("big.bin", String(repeating: "x", count: 100))
        let r = await exec("list_dir", [:])
        XCTAssertEqual(r["ok"], .bool(true))
        guard case .array(let entries) = r["entries"] else { return XCTFail("entries 缺失") }
        let names = Set(entries.compactMap { $0.object?["name"]?.string })
        XCTAssertTrue(names.isSuperset(of: ["a.txt", "sub", "big.bin"]))
        for e in entries {
            guard case .object(let o) = e else { return XCTFail("entry 非 dict") }
            XCTAssertTrue(Set(["name", "type", "size"]).isSubset(of: Set(o.keys)))
        }
        // 类型与尺寸语义（dir size=0；file size=字节数）
        let byName = Dictionary(uniqueKeysWithValues: entries.compactMap { e -> (String, [String: JSONValue])? in
            guard case .object(let o) = e, let n = o["name"]?.string else { return nil }
            return (n, o)
        })
        XCTAssertEqual(byName["sub"]?["type"], .string("dir"))
        XCTAssertEqual(byName["sub"]?["size"], .int(0))
        XCTAssertEqual(byName["a.txt"]?["type"], .string("file"))
        XCTAssertEqual(byName["a.txt"]?["size"], .int(8))
    }

    /// list_dir 缺省 path → 沙盒根本身（Python rel is None 分支）。
    func testListDirDefaultPath() async throws {
        try write("a.txt", "x")
        let r = await exec("list_dir", [:])
        XCTAssertEqual(r["ok"], .bool(true))
    }

    /// list_dir 命中文件 → not_a_dir【文件】文案；不存在 → 尚不存在文案。
    func testListDirNotADir() async throws {
        try write("f.txt", "x")
        let r1 = await exec("list_dir", ["path": .string("f.txt")])
        XCTAssertEqual(r1["ok"], .bool(false))
        XCTAssertTrue(errOf(r1).hasPrefix("not_a_dir: f.txt（该路径是【文件】不是目录"), errOf(r1))
        let r2 = await exec("list_dir", ["path": .string("no_such_dir")])
        XCTAssertEqual(r2["ok"], .bool(false))
        XCTAssertTrue(errOf(r2).contains("not_a_dir: no_such_dir（解析后:"), errOf(r2))
        XCTAssertTrue(errOf(r2).contains("该目录尚不存在"), errOf(r2))
        XCTAssertTrue(errOf(r2).contains("沙盒根: \(root)"), errOf(r2))
    }

    func testReadFileRelative() async throws {
        try write("a.txt", "hello m1")
        let r = await exec("read_file", ["path": .string("a.txt")])
        XCTAssertEqual(r["ok"], .bool(true))
        XCTAssertEqual(r["content"], .string("hello m1"))
        XCTAssertEqual(r["size"], .int(8))
    }

    func testWriteFileNestedAllowed() async throws {
        let r = await exec("write_file", ["path": .string("sub/nested/new.txt"),
                                          "content": .string("abc")])
        XCTAssertEqual(r["ok"], .bool(true), errOf(r))
        XCTAssertEqual(r["bytes"], .int(3))
        XCTAssertEqual(r["path"], .string(root + "/sub/nested/new.txt"))
        XCTAssertEqual(try String(contentsOf: sandbox.appendingPathComponent("sub/nested/new.txt"),
                                  encoding: .utf8), "abc")
    }

    /// write_file 覆盖已存在文件（非敏感）→ 放行（写入/修改一律放行）。
    func testWriteFileOverwriteAllowed() async throws {
        try write("x.txt", "old")
        let r = await exec("write_file", ["path": .string("x.txt"), "content": .string("new")])
        XCTAssertEqual(r["ok"], .bool(true), errOf(r))
        XCTAssertEqual(try String(contentsOf: sandbox.appendingPathComponent("x.txt"),
                                  encoding: .utf8), "new")
    }

    func testCreateDirAllowed() async throws {
        let r = await exec("create_dir", ["path": .string("d1/d2")])
        XCTAssertEqual(r["ok"], .bool(true), errOf(r))
        var isDir = ObjCBool(false)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: sandbox.appendingPathComponent("d1/d2").path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    // MARK: - 2. 截断 + 大文本软提示（B2 0.4.8）

    func testReadFile2MBTruncated() async throws {
        let big = sandbox.appendingPathComponent("big.bin")
        try Data(repeating: UInt8(ascii: "x"), count: 2 * 1024 * 1024)
            .write(to: big)
        let r = await exec("read_file", ["path": .string("big.bin")])
        XCTAssertEqual(r["ok"], .bool(true))
        XCTAssertEqual(r["truncated"], .bool(true))
        XCTAssertEqual(r["size"], .int(2 * 1024 * 1024))
        let content = r["content"]?.string ?? ""
        XCTAssertLessThanOrEqual(content.count, 1024 * 1024)
        // 2MB > 200KB 软提示阈值 → 头部嵌引导（占预算，正文按剩余截取）
        XCTAssertTrue(content.hasPrefix("⚠️ 大文件提示：本文件 2097152 字节（超过 204800 字节）"),
                      String(content.prefix(120)))
        XCTAssertTrue(content.contains("若确需全文分析再继续使用以下内容。\n\n---\n\n"))
    }

    /// 200KB 阈值边界：恰好 200KB 不提示，200KB+1 提示。
    func testReadFileAdvisoryThreshold() async throws {
        let exact = sandbox.appendingPathComponent("exact.bin")
        try Data(repeating: UInt8(ascii: "y"), count: 200 * 1024).write(to: exact)
        let r1 = await exec("read_file", ["path": .string("exact.bin")])
        XCTAssertEqual(r1["ok"], .bool(true))
        XCTAssertFalse((r1["content"]?.string ?? "").contains("大文件提示"))
        XCTAssertEqual(r1["truncated"], .bool(false))

        let over = sandbox.appendingPathComponent("over.bin")
        try Data(repeating: UInt8(ascii: "y"), count: 200 * 1024 + 1).write(to: over)
        let r2 = await exec("read_file", ["path": .string("over.bin")])
        XCTAssertTrue((r2["content"]?.string ?? "").hasPrefix("⚠️ 大文件提示"))
        XCTAssertEqual(r2["truncated"], .bool(false))
    }

    // MARK: - 3. 越界默认放行（2026-08-28 宽松化）

    func testOutOfBoundsReadWriteDeleteAllowed() async throws {
        let outside = tmp.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "TOPSECRET".write(to: outside.appendingPathComponent("secret.txt"),
                              atomically: false, encoding: .utf8)

        let r1 = await exec("read_file", ["path": .string(outside.appendingPathComponent("secret.txt").path)])
        XCTAssertEqual(r1["ok"], .bool(true), errOf(r1))
        XCTAssertEqual(r1["content"], .string("TOPSECRET"))

        let newFile = outside.appendingPathComponent("new.txt")
        let r2 = await exec("write_file", ["path": .string(newFile.path), "content": .string("out")])
        XCTAssertEqual(r2["ok"], .bool(true), errOf(r2))
        XCTAssertEqual(try String(contentsOf: newFile, encoding: .utf8), "out")
        // 越界写 → 附 advisory（方案 B 放行+提示）
        XCTAssertTrue((r2["advisory"]?.string ?? "").contains("工作目录之外"),
                      r2["advisory"]?.string ?? "nil")

        let r3 = await exec("delete_path", ["path": .string(newFile.path)])
        XCTAssertEqual(r3["ok"], .bool(true), errOf(r3))
        XCTAssertFalse(FileManager.default.fileExists(atPath: newFile.path))
    }

    // MARK: - 4. 敏感位置删除/写入授权（注入伪造敏感区 = Python monkeypatch 用例）

    private func makeFakeSensitiveContext() throws -> (NativeToolContext, URL) {
        let fakeSensitive = tmp.appendingPathComponent("fake_sensitive")
        try FileManager.default.createDirectory(at: fakeSensitive, withIntermediateDirectories: true)
        let prefix = NativePyPath.resolve(fakeSensitive.path)
        let ctx = NativeToolTestSupport.makeContext(
            dataRoot: tmp.appendingPathComponent("dataroot"),
            isSensitive: { $0.hasPrefix(prefix) })
        return (ctx, fakeSensitive)
    }

    func testSensitiveDeleteNoAuthorizerDenied() async throws {
        let (ctx, dir) = try makeFakeSensitiveContext()
        let victim = dir.appendingPathComponent("victim.txt")
        try "sensitive data".write(to: victim, atomically: false, encoding: .utf8)
        let r = await exec("delete_path", ["path": .string(victim.path)], ctx: ctx)
        XCTAssertEqual(r["ok"], .bool(false))
        XCTAssertTrue(errOf(r).contains("denied"), errOf(r))
        XCTAssertTrue(errOf(r).contains("敏感路径删除需用户确认（当前无授权通道）"), errOf(r))
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.path))
    }

    func testSensitiveDeleteAuthorizerDeny() async throws {
        let (ctx, dir) = try makeFakeSensitiveContext()
        let victim = dir.appendingPathComponent("victim.txt")
        try "sensitive data".write(to: victim, atomically: false, encoding: .utf8)
        let deny = NativeCallbackAuthorizer { _, _, _ in false }
        let r = await exec("delete_path", ["path": .string(victim.path)],
                           authorizer: deny, ctx: ctx)
        XCTAssertEqual(errOf(r), "denied_by_user")
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.path))
    }

    func testSensitiveDeleteAuthorizerAllow() async throws {
        let (ctx, dir) = try makeFakeSensitiveContext()
        let victim = dir.appendingPathComponent("victim.txt")
        try "sensitive data".write(to: victim, atomically: false, encoding: .utf8)
        let allow = NativeCallbackAuthorizer { _, _, _ in true }
        let r = await exec("delete_path", ["path": .string(victim.path)],
                           authorizer: allow, ctx: ctx)
        XCTAssertEqual(r["ok"], .bool(true), errOf(r))
        XCTAssertFalse(FileManager.default.fileExists(atPath: victim.path))
    }

    /// 4d：敏感位置的【写入/修改】需确认——无 authorizer 拒绝（未落盘）；放行 → 成功。
    func testSensitiveWriteConfirmFlow() async throws {
        let (ctx, dir) = try makeFakeSensitiveContext()
        let cfgFile = dir.appendingPathComponent("config.yaml")
        try "key: old".write(to: cfgFile, atomically: false, encoding: .utf8)

        let r1 = await exec("write_file", ["path": .string(cfgFile.path),
                                           "content": .string("key: new")], ctx: ctx)
        XCTAssertEqual(r1["ok"], .bool(false))
        XCTAssertTrue(errOf(r1).contains("需用户确认"), errOf(r1))
        XCTAssertEqual(try String(contentsOf: cfgFile, encoding: .utf8), "key: old")

        let allow = NativeCallbackAuthorizer { _, _, _ in true }
        let r2 = await exec("write_file", ["path": .string(cfgFile.path),
                                           "content": .string("key: new")],
                            authorizer: allow, ctx: ctx)
        XCTAssertEqual(r2["ok"], .bool(true), errOf(r2))
        XCTAssertEqual(try String(contentsOf: cfgFile, encoding: .utf8), "key: new")
    }

    /// 4e：敏感位置的读取不需确认，直接放行（读任何位置都不拦截）。
    func testSensitiveReadNoConfirm() async throws {
        let (ctx, dir) = try makeFakeSensitiveContext()
        let cfgFile = dir.appendingPathComponent("config.yaml")
        try "key: new".write(to: cfgFile, atomically: false, encoding: .utf8)
        let r = await exec("read_file", ["path": .string(cfgFile.path)], ctx: ctx)
        XCTAssertEqual(r["ok"], .bool(true), errOf(r))
        XCTAssertEqual(r["content"], .string("key: new"))
    }

    // MARK: - 4f. 真实敏感目录（不 mock；授权拒绝先于执行，零系统写入）

    private final class Recorder: @unchecked Sendable {
        var calls: [(String, String, String)] = []
        let allow: Bool
        init(allow: Bool) { self.allow = allow }
        var authorizer: NativeCallbackAuthorizer {
            NativeCallbackAuthorizer { tool, path, action in
                self.calls.append((tool, path, action))
                return self.allow
            }
        }
    }

    func testRealSensitiveWriteEtcAuthorizerCalled() async throws {
        let rec = Recorder(allow: false)
        let r = await exec("write_file", ["path": .string("/etc/w3a_test_s1.txt"),
                                          "content": .string("x")],
                           authorizer: rec.authorizer)
        XCTAssertEqual(rec.calls.count, 1)
        XCTAssertEqual(rec.calls.first?.0, "write_file")
        XCTAssertEqual(rec.calls.first?.2, "write")
        XCTAssertEqual(errOf(r), "denied_by_user")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/etc/w3a_test_s1.txt"))
    }

    func testNonSensitiveWriteAuthorizerNotCalled() async throws {
        // 非敏感越界（临时目录）→ 直接放行，authorizer 未被调用
        let target = tmp.appendingPathComponent("oob_non_sensitive.txt")
        let rec = Recorder(allow: false)
        let r = await exec("write_file", ["path": .string(target.path), "content": .string("ok")],
                           authorizer: rec.authorizer)
        XCTAssertEqual(r["ok"], .bool(true), errOf(r))
        XCTAssertEqual(rec.calls.count, 0)
    }

    func testRealSensitiveMkdirUsrAuthorizerCalled() async throws {
        let rec = Recorder(allow: false)
        let r = await exec("create_dir", ["path": .string("/usr/w3a_test_s1")],
                           authorizer: rec.authorizer)
        XCTAssertEqual(rec.calls.count, 1)
        XCTAssertEqual(rec.calls.first?.0, "create_dir")
        XCTAssertEqual(rec.calls.first?.2, "mkdir")
        XCTAssertEqual(errOf(r), "denied_by_user")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/usr/w3a_test_s1"))
    }

    func testRealSensitiveReadEtcHostsAllowed() async throws {
        guard FileManager.default.fileExists(atPath: "/etc/hosts") else {
            throw XCTSkip("无 /etc/hosts 环境")
        }
        let r = await exec("read_file", ["path": .string("/etc/hosts")])
        XCTAssertEqual(r["ok"], .bool(true), errOf(r))   // 读不受限
    }

    // MARK: - 5. delete_path 基础语义

    func testDeleteRelativeFile() async throws {
        try write("todel.txt", "x")
        let r = await exec("delete_path", ["path": .string("todel.txt")])
        XCTAssertEqual(r["ok"], .bool(true), errOf(r))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: sandbox.appendingPathComponent("todel.txt").path))
    }

    func testDeleteDirectoryRecursive() async throws {
        try write("todel_dir/inner.txt", "y")
        let r = await exec("delete_path", ["path": .string("todel_dir")])
        XCTAssertEqual(r["ok"], .bool(true), errOf(r))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: sandbox.appendingPathComponent("todel_dir").path))
    }

    func testDeleteNotFound() async {
        let r = await exec("delete_path", ["path": .string("no_such_thing")])
        XCTAssertEqual(r["ok"], .bool(false))
        XCTAssertTrue(errOf(r).contains("not_found"), errOf(r))
    }

    // MARK: - 6. schema / 入参契约

    func testReadFileNotAFile() async {
        let r = await exec("read_file", ["path": .string("nope_missing.txt")])
        XCTAssertEqual(r["ok"], .bool(false))
        XCTAssertTrue(errOf(r).contains("not_a_file"), errOf(r))
        XCTAssertTrue(errOf(r).contains("沙盒根: \(root)"), errOf(r))
    }

    func testWriteFileMissingContent() async {
        let r = await exec("write_file", ["path": .string("x.txt")])
        XCTAssertEqual(r["ok"], .bool(false))
        XCTAssertTrue(errOf(r).contains("bad_arg"), errOf(r))
    }

    func testUnknownTool() async {
        let r = await exec("nope_tool", [:])
        XCTAssertEqual(r["ok"], .bool(false))
        XCTAssertTrue(errOf(r).contains("unknown_tool"), errOf(r))
    }

    func testBadArgPath() async {
        let r1 = await exec("read_file", [:])
        XCTAssertEqual(errOf(r1), "bad_arg: path")
        let r2 = await exec("read_file", ["path": .string("")])
        XCTAssertEqual(errOf(r2), "bad_arg: path")
        let r3 = await exec("read_file", ["path": .int(5)])
        XCTAssertEqual(errOf(r3), "bad_arg: path")
    }

    /// RETURN_SCHEMA 校验器自校验（test_tools.py L211-214 + 补 missing/bad_type/entry_field）。
    func testSchemaValidate() {
        // 缺 entry 字段 → bad_entry
        let bad: [String: JSONValue] = ["ok": .bool(true),
                                        "entries": .array([.object(["name": .string("x")])])]
        let probs = NativeToolRegistry.validate(bad, schema: NativeToolRegistry.listDirReturn)
        XCTAssertTrue(probs.contains(where: { $0.hasPrefix("bad_entry") }), "\(probs)")
        // 缺 required → missing:*
        let probs2 = NativeToolRegistry.validate([:], schema: NativeToolRegistry.readFileReturn)
        XCTAssertEqual(probs2, ["missing:ok", "missing:content", "missing:size"])
        // 类型不符 → bad_type:*；Python isinstance(True, int)==True 保真
        let probs3 = NativeToolRegistry.validate(
            ["ok": .int(1), "content": .string("x"), "size": .bool(true)],
            schema: NativeToolRegistry.readFileReturn)
        XCTAssertEqual(probs3, ["bad_type:ok"])
        // web_search schema：条目字段名 results（entry_field 覆盖）
        let probs4 = NativeToolRegistry.validate(
            ["ok": .bool(true),
             "results": .array([.object(["title": .string("t"), "url": .string("u")])])],
            schema: NativeWebSearch.returnSchema)
        XCTAssertEqual(probs4, ["bad_entry"])
        // 全合法 → 无问题
        let probs5 = NativeToolRegistry.validate(
            ["ok": .bool(true), "path": .string("/x"), "bytes": .int(3)],
            schema: NativeToolRegistry.writeFileReturn)
        XCTAssertEqual(probs5, [])
    }

    // MARK: - 7. NoopAuthorizer 语义

    func testNoopAuthorizerAlwaysFalse() async {
        let n = await NativeNoopAuthorizer().authorize(tool: "delete_path",
                                                       path: "/etc/passwd", action: "delete")
        XCTAssertFalse(n)   // 敏感操作恒 False（安全优先）
    }

    // MARK: - 8. 0.4.11 路径标点笔误自检 + 越界提示

    private func makeCaseRoot() -> String {
        let caseRoot = tmp.appendingPathComponent("11、赵兴柱诉刘禄九")
        try? FileManager.default.createDirectory(at: caseRoot, withIntermediateDirectories: true)
        return NativePyPath.resolve(caseRoot.path)
    }

    func testPunctuationTypoRejected() async throws {
        let caseRoot = makeCaseRoot()
        let ghost = tmp.appendingPathComponent("11、赵兴柱诉刘禄九。")
        let r = await NativeToolRegistry.execute(
            "create_dir", args: ["path": .string(ghost.appendingPathComponent("识别文本").path)],
            sandboxRoot: caseRoot, authorizer: nil, context: context)
        XCTAssertEqual(r["ok"], .bool(false))
        XCTAssertTrue(errOf(r).contains("path_typo_rejected"), errOf(r))
        // ⛔ 幽灵目录绝未被创建（此前会凭空建出）
        XCTAssertFalse(FileManager.default.fileExists(atPath: ghost.path))
        // 报错给出正确路径建议（让模型自行纠正）
        XCTAssertTrue(errOf(r).contains(caseRoot + "/识别文本"), errOf(r))
        // 报错写明禁止增删标点的纪律
        XCTAssertTrue(errOf(r).contains("禁止增删任何标点"), errOf(r))
    }

    func testPunctuationTypoVariantsRejected() async throws {
        let caseRoot = makeCaseRoot()
        for ch in ["、", " ", "　", "，"] {
            let ghost = tmp.appendingPathComponent("11、赵兴柱诉刘禄九\(ch)")
            let r = await NativeToolRegistry.execute(
                "create_dir", args: ["path": .string(ghost.appendingPathComponent("x").path)],
                sandboxRoot: caseRoot, authorizer: nil, context: context)
            XCTAssertEqual(r["ok"], .bool(false), "标点 \(ch.debugDescription)")
            XCTAssertTrue(errOf(r).contains("path_typo_rejected"), errOf(r))
            XCTAssertFalse(FileManager.default.fileExists(atPath: ghost.path))
        }
    }

    func testNormalPathInsideWorkingDirAllowed() async throws {
        let caseRoot = makeCaseRoot()
        let r = await NativeToolRegistry.execute(
            "create_dir", args: ["path": .string("识别文本")],
            sandboxRoot: caseRoot, authorizer: nil, context: context)
        XCTAssertEqual(r["ok"], .bool(true), errOf(r))
    }

    /// 真实越界（非笔误）：方案 B 放行 + advisory 提示（schema 校验之后挂载）。
    func testRealOutOfBoundsAdvisory() async throws {
        let caseRoot = makeCaseRoot()
        let oob = tmp.appendingPathComponent("合法外部目录")
        let r = await NativeToolRegistry.execute(
            "create_dir", args: ["path": .string(oob.path)],
            sandboxRoot: caseRoot, authorizer: nil, context: context)
        XCTAssertEqual(r["ok"], .bool(true), errOf(r))
        XCTAssertTrue((r["advisory"]?.string ?? "").contains("工作目录之外"),
                      r["advisory"]?.string ?? "nil")
        // advisory 在 schema 校验之后挂载（path 字段仍为解析后正确路径）
        XCTAssertEqual(r["path"], .string(NativePyPath.resolve(oob.path)))
    }

    /// 已存在的同名异标点目录绝不干预（不判为笔误、正常放行）。
    func testExistingVariantDirNotIntercepted() async throws {
        let caseRoot = makeCaseRoot()
        let realVariant = tmp.appendingPathComponent("11、赵兴柱诉刘禄九.")
        try FileManager.default.createDirectory(at: realVariant, withIntermediateDirectories: true)
        let r = await NativeToolRegistry.execute(
            "create_dir", args: ["path": .string(realVariant.appendingPathComponent("sub").path)],
            sandboxRoot: caseRoot, authorizer: nil, context: context)
        XCTAssertEqual(r["ok"], .bool(true), errOf(r))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: realVariant.appendingPathComponent("sub").path))
    }

    /// 双前缀自纠正端到端（checkpoint-069 F-1：read_file 经去首层命中）。
    func testDoublePrefixReadFile() async throws {
        let caseRoot = tmp.appendingPathComponent("测试材料")
        try FileManager.default.createDirectory(at: caseRoot, withIntermediateDirectories: true)
        let f = caseRoot.appendingPathComponent("sub/f.txt")
        try FileManager.default.createDirectory(at: f.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "data".write(to: f, atomically: false, encoding: .utf8)
        let r = await NativeToolRegistry.execute(
            "read_file", args: ["path": .string("测试材料/sub/f.txt")],
            sandboxRoot: NativePyPath.resolve(caseRoot.path), authorizer: nil, context: context)
        XCTAssertEqual(r["ok"], .bool(true), errOf(r))
        XCTAssertEqual(r["content"], .string("data"))
    }

    // MARK: - 图片 base64 分支（checkpoint-067 R-4）

    func testReadFileImageReturnsBase64() async throws {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0xFF])
        try bytes.write(to: sandbox.appendingPathComponent("img.png"))
        let r = await exec("read_file", ["path": .string("img.png")])
        XCTAssertEqual(r["ok"], .bool(true), errOf(r))
        XCTAssertEqual(r["_kind"], .string("image"))
        XCTAssertEqual(r["image_base64"], .string(bytes.base64EncodedString()))
        XCTAssertEqual(r["size"], .int(Int64(bytes.count)))
        XCTAssertEqual(r["content"],
                       .string("[图片文件 img.png，\(bytes.count) 字节，已转为图像输入]"))
        // 图片结果同样过 schema（required ok/content/size）
        XCTAssertNil(r["error"])
    }

    /// 大写扩展名同样命中图片分支（suffix.lower()）。
    func testReadFileImageUppercaseExt() async throws {
        try Data([0xFF, 0xD8, 0xFF]).write(to: sandbox.appendingPathComponent("p.JPG"))
        let r = await exec("read_file", ["path": .string("p.JPG")])
        XCTAssertEqual(r["_kind"], .string("image"), errOf(r))
    }

    // MARK: - P2-W3b Office 生成/解析已点亮（create_document / read_file 解析通道）

    /// 空 content 对齐 Python doc_writer 口径（blocks 缺省 []）：生成合法空文档、ok:true 落盘。
    func testCreateDocumentEmptyContent() async throws {
        let r = await exec("create_document", ["path": .string("a.docx"),
                                               "content": .object([:])])
        XCTAssertEqual(r["ok"], .bool(true), errOf(r))
        let path = sandbox.appendingPathComponent("a.docx").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertGreaterThan(r["bytes"]?.int ?? 0, 0)
        // 生成物可被 NativeDocReader 读回（合法 zip/OOXML 结构，非损坏文件）
        let parsed = NativeDocReader.extract(path: path, budget: 1_000_000)
        XCTAssertTrue(parsed.ok, parsed.content)
    }

    /// 假 docx（仅 PK 魔数、zip 结构损坏）：ok 一律 true（Python 口径），损坏说明进 content。
    func testReadFileOfficeDocBadZip() async throws {
        try Data([0x50, 0x4B, 0x03, 0x04]).write(to: sandbox.appendingPathComponent("doc.docx"))
        let r = await exec("read_file", ["path": .string("doc.docx")])
        XCTAssertEqual(r["ok"], .bool(true), errOf(r))
        XCTAssertTrue(r["content"]?.string?.contains("不是有效的 .docx 文档") == true,
                      r["content"]?.string ?? "nil")
    }

    // MARK: - 符号链接条目（list_dir 类型判定）

    func testListDirSymlinkEntry() async throws {
        try write("real.txt", "abcd")
        let link = sandbox.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(
            atPath: link.path, withDestinationPath: sandbox.appendingPathComponent("real.txt").path)
        let r = await exec("list_dir", [:])
        XCTAssertEqual(r["ok"], .bool(true))
        guard case .array(let entries) = r["entries"] else { return XCTFail() }
        let linkEntry = entries.first { $0.object?["name"]?.string == "link.txt" }?.object
        XCTAssertEqual(linkEntry?["type"], .string("symlink"))
        // p.stat() 跟随符号链接 → 目标文件大小
        XCTAssertEqual(linkEntry?["size"], .int(4))
    }

    // MARK: - 工作流 tool 节点端到端（NativeRegistryToolExecutor 装配点亮）

    private final class StubConnector: NativeWorkflowConnector, @unchecked Sendable {
        func chat(model: String, messages: [[String: JSONValue]], images: [String]?,
                  readTimeoutS: Double?) async throws -> String { "unused" }
        func unloadModel(_ model: String) async -> Bool { true }
    }

    private func jnode(_ id: String, _ type: String,
                       _ props: [String: JSONValue] = [:]) -> JSONValue {
        var o = props
        o["id"] = .string(id)
        o["type"] = .string(type)
        return .object(o)
    }

    private func jedge(_ from: String, _ to: String) -> JSONValue {
        .object(["from": .string(from), "to": .string(to)])
    }

    private func jdef(_ nodes: [JSONValue], _ edges: [JSONValue]) -> JSONValue {
        .object(["nodes": .array(nodes), "edges": .array(edges), "params": .object([:])])
    }

    private func runWorkflow(_ def: JSONValue,
                             executor: (any NativeWorkflowToolExecutor)?) async throws
        -> [WorkflowEngineEvent] {
        let db = NativeDatabase(projectsRoot: tmp.appendingPathComponent("projects"))
        let store = NativeWorkflowStore(database: db)
        let runId = try store.createWorkflowRun(workflowId: "wf-tool", variables: .object([:]))
        let engine = NativeWorkflowEngine(
            runId: runId, definition: def, connector: StubConnector(), store: store,
            runtime: NativeWorkflowRuntimeCenter(), sandboxRoot: root,
            toolExecutor: executor)
        var evs: [WorkflowEngineEvent] = []
        let stream = await engine.run()
        for await ev in stream { evs.append(ev) }
        return evs
    }

    /// tool 节点 write_file 全链路：节点输出为工具结果 dict，文件真实落盘。
    func testWorkflowToolNodeWriteFile() async throws {
        let executor = NativeRegistryToolExecutor(context: context)
        let def = jdef([
            jnode("s", "start"),
            jnode("t", "tool", ["tool": .string("write_file"),
                                "args": .object(["path": .string("out/result.txt"),
                                                 "content": .string("wf-写入")])]),
            jnode("e", "end"),
        ], [jedge("s", "t"), jedge("t", "e")])
        let evs = try await runWorkflow(def, executor: executor)
        XCTAssertEqual(evs.last?.event, "workflow_done")
        let written = sandbox.appendingPathComponent("out/result.txt")
        XCTAssertEqual(try String(contentsOf: written, encoding: .utf8), "wf-写入")
        // 节点输出透传工具结果（ok/path/bytes）
        let run = evs.first { $0.event == "node_done" && $0.data["node_id"] == .string("t") }
        XCTAssertNotNil(run)
    }

    /// tool 节点 create_document → P2-W3b 已点亮：workflow_done + 文档落盘可读回。
    func testWorkflowToolNodeCreateDocument() async throws {
        let executor = NativeRegistryToolExecutor(context: context)
        let def = jdef([
            jnode("s", "start"),
            jnode("t", "tool", ["tool": .string("create_document"),
                                "args": .object(["path": .string("a.docx"),
                                                 "content": .object([:])])]),
            jnode("e", "end"),
        ], [jedge("s", "t"), jedge("t", "e")])
        let evs = try await runWorkflow(def, executor: executor)
        XCTAssertEqual(evs.last?.event, "workflow_done",
                       evs.map { $0.event }.joined(separator: ","))
        let path = sandbox.appendingPathComponent("a.docx").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(NativeDocReader.extract(path: path, budget: 1_000_000).ok)
    }

    /// 工作流引擎场景 authorizer=nil → 敏感删除按 Python execute(..., None) 原文案拒绝。
    func testWorkflowToolNodeSensitiveDeleteDenied() async throws {
        let (ctx, dir) = try makeFakeSensitiveContext()
        let victim = dir.appendingPathComponent("victim.txt")
        try "x".write(to: victim, atomically: false, encoding: .utf8)
        let executor = NativeRegistryToolExecutor(context: ctx)   // authorizer 缺省 nil
        let def = jdef([
            jnode("s", "start"),
            jnode("t", "tool", ["tool": .string("delete_path"),
                                "args": .object(["path": .string(victim.path)])]),
            jnode("e", "end"),
        ], [jedge("s", "t"), jedge("t", "e")])
        let evs = try await runWorkflow(def, executor: executor)
        XCTAssertEqual(evs.last?.event, "workflow_failed")
        let errEv = evs.first { $0.event == "node_error" }
        XCTAssertTrue(errEv?.data["error"]?.string?
            .contains("敏感路径删除需用户确认（当前无授权通道）") == true,
                      errEv?.data["error"]?.string ?? "nil")
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.path))
    }

    /// 未知工具节点 → unknown_tool 如实失败。
    func testWorkflowToolNodeUnknownTool() async throws {
        let executor = NativeRegistryToolExecutor(context: context)
        let def = jdef([
            jnode("s", "start"),
            jnode("t", "tool", ["tool": .string("nope"), "args": .object([:])]),
            jnode("e", "end"),
        ], [jedge("s", "t"), jedge("t", "e")])
        let evs = try await runWorkflow(def, executor: executor)
        XCTAssertEqual(evs.last?.event, "workflow_failed")
        let errEv = evs.first { $0.event == "node_error" }
        XCTAssertTrue(errEv?.data["error"]?.string?.contains("unknown_tool: nope") == true)
    }
}
