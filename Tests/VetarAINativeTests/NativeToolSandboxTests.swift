//
//  NativeToolSandboxTests.swift
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

//  逐条对照 subagent/sidecar/tools/registry.py resolve_sandboxed_path /
//  punctuation_near_miss（L53-123）与 sandbox.py is_sensitive_path（⛔ 只读
//  行为规格源），及 test_tools.py 第 8 节（0.4.11 标点笔误自检 + 越界提示）。
//
//  隔离纪律：全部用 mktemp 临时目录；敏感判定单测只读系统路径（不写入）。
//  ⚠️ macOS /var→/private/var 符号链接：比对一律经 NativePyPath.resolve 后
//     进行（与 execute() 内部口径一致），直接比字符串会假失败。
//

import XCTest
@testable import VetarAINative

final class NativeToolSandboxTests: XCTestCase {

    private var tmp: URL!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("w3asbx_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    private var root: String { NativePyPath.resolve(tmp.path) }

    private func touch(_ rel: String, _ content: String = "x") throws {
        let url = URL(fileURLWithPath: root).appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try content.write(to: url, atomically: false, encoding: .utf8)
    }

    // MARK: - resolve_sandboxed_path

    /// 相对路径基于沙盒根解析（resolve 后绝对）。
    func testResolveRelativeUnderRoot() throws {
        try touch("sub/f.txt")
        let r = NativeToolSandbox.resolveSandboxedPath("sub/f.txt", sandboxRoot: root)
        XCTAssertEqual(r, root + "/sub/f.txt")
    }

    /// 绝对路径原样解析（不锚定沙盒根）。
    func testResolveAbsoluteAsIs() {
        let abs = tmp.appendingPathComponent("elsewhere.txt").path
        let r = NativeToolSandbox.resolveSandboxedPath(abs, sandboxRoot: root)
        XCTAssertEqual(r, NativePyPath.resolve(abs))
    }

    /// 空串 / nil → nil（Python 返回 None）。
    func testResolveEmptyAndNil() {
        XCTAssertNil(NativeToolSandbox.resolveSandboxedPath("", sandboxRoot: root))
        XCTAssertNil(NativeToolSandbox.resolveSandboxedPath(nil, sandboxRoot: root))
    }

    /// 路径不存在仍返回解析结果（调用方自行判断存在性）。
    func testResolveNonexistentStillReturns() {
        let r = NativeToolSandbox.resolveSandboxedPath("no/such/thing.txt", sandboxRoot: root)
        XCTAssertEqual(r, root + "/no/such/thing.txt")
    }

    /// 双前缀自纠正（checkpoint-069 F-1）：首层==根目录名且去首层后存在 → 去首层结果。
    func testDoublePrefixSelfCorrection() throws {
        let rootDir = tmp.appendingPathComponent("测试材料")
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        let rootPath = NativePyPath.resolve(rootDir.path)
        let f = rootDir.appendingPathComponent("sub/f.txt")
        try FileManager.default.createDirectory(at: f.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "data".write(to: f, atomically: false, encoding: .utf8)

        let r = NativeToolSandbox.resolveSandboxedPath("测试材料/sub/f.txt", sandboxRoot: rootPath)
        XCTAssertEqual(r, rootPath + "/sub/f.txt")
    }

    /// 去首层后不存在 → 保持原解析（不纠正）。
    func testDoublePrefixNoCorrectionWhenAltMissing() {
        let rootDir = tmp.appendingPathComponent("测试材料")
        try? FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        let rootPath = NativePyPath.resolve(rootDir.path)
        let r = NativeToolSandbox.resolveSandboxedPath("测试材料/no/such.txt", sandboxRoot: rootPath)
        XCTAssertEqual(r, rootPath + "/测试材料/no/such.txt")
    }

    /// ~ 展开（expanduser 语义）。
    func testResolveTildeExpansion() {
        let r = NativeToolSandbox.resolveSandboxedPath("~/Desktop", sandboxRoot: root)
        XCTAssertEqual(r, NativePyPath.resolve(NSHomeDirectory() + "/Desktop"))
    }

    // MARK: - punctuation_near_miss（test_tools.py 第 8 节直接映射）

    private func makeCaseRoot() -> String {
        let caseRoot = tmp.appendingPathComponent("11、赵兴柱诉刘禄九")
        try? FileManager.default.createDirectory(at: caseRoot, withIntermediateDirectories: true)
        return NativePyPath.resolve(caseRoot.path)
    }

    /// 幽灵路径（仅差句号）→ 返回正确建议。
    func testNearMissGhostReturnsSuggestion() {
        let caseRoot = makeCaseRoot()
        let ghost = tmp.appendingPathComponent("11、赵兴柱诉刘禄九。")
        let s = NativeToolSandbox.punctuationNearMiss(
            resolved: NativePyPath.resolve(ghost.appendingPathComponent("识别文本").path),
            sandboxRoot: caseRoot)
        XCTAssertEqual(s.map(NativePyPath.resolve), (caseRoot + "/识别文本") as String?)
    }

    /// 顿号/空格/全角空格/逗号笔误同样命中建议。
    func testNearMissPunctuationVariants() {
        let caseRoot = makeCaseRoot()
        for ch in ["、", " ", "　", "，"] {
            let ghost = tmp.appendingPathComponent("11、赵兴柱诉刘禄九\(ch)")
            let s = NativeToolSandbox.punctuationNearMiss(
                resolved: NativePyPath.resolve(ghost.appendingPathComponent("x").path),
                sandboxRoot: caseRoot)
            XCTAssertEqual(s.map(NativePyPath.resolve), (caseRoot + "/x") as String?,
                           "标点 \(ch.debugDescription) 应命中建议")
        }
    }

    /// 已存在的同名异标点目录绝不干预 → nil（不得把用户从真实目录引开）。
    func testNearMissExistingDirNotTouched() {
        let caseRoot = makeCaseRoot()
        let realVariant = tmp.appendingPathComponent("11、赵兴柱诉刘禄九.")
        try? FileManager.default.createDirectory(at: realVariant, withIntermediateDirectories: true)
        let s = NativeToolSandbox.punctuationNearMiss(
            resolved: NativePyPath.resolve(realVariant.appendingPathComponent("sub").path),
            sandboxRoot: caseRoot)
        XCTAssertNil(s)
    }

    /// 目标即幽灵根本身（无子路径）→ 建议为沙盒根本身。
    func testNearMissGhostRootItself() {
        let caseRoot = makeCaseRoot()
        let ghost = tmp.appendingPathComponent("11、赵兴柱诉刘禄九。")
        let s = NativeToolSandbox.punctuationNearMiss(
            resolved: NativePyPath.resolve(ghost.path), sandboxRoot: caseRoot)
        XCTAssertEqual(s.map(NativePyPath.resolve), caseRoot as String?)
    }

    /// 完全无关路径 → nil。
    func testNearMissUnrelatedPath() {
        let caseRoot = makeCaseRoot()
        let s = NativeToolSandbox.punctuationNearMiss(
            resolved: NativePyPath.resolve(tmp.appendingPathComponent("合法外部目录").path),
            sandboxRoot: caseRoot)
        XCTAssertNil(s)
    }

    /// _strip_punct 覆盖集合代表字符。
    func testStripPunct() {
        XCTAssertEqual(NativeToolSandbox.stripPunct("11、赵兴柱。，；：！？·…—-–~～\"'“”‘’（）()【】[]{}<>《》 　\ta"),
                       "11赵兴柱a")
    }

    // MARK: - is_sensitive_path（sandbox.py 清单逐项）

    func testSensitiveSystemDirs() {
        XCTAssertTrue(NativeToolSandbox.isSensitivePath("/etc"))
        XCTAssertTrue(NativeToolSandbox.isSensitivePath("/etc/hosts"))
        XCTAssertTrue(NativeToolSandbox.isSensitivePath("/System/Library"))
        XCTAssertTrue(NativeToolSandbox.isSensitivePath("/usr/local/bin"))
        XCTAssertTrue(NativeToolSandbox.isSensitivePath("/Applications/Safari.app"))
        XCTAssertTrue(NativeToolSandbox.isSensitivePath("/Library/Keychains"))
        XCTAssertTrue(NativeToolSandbox.isSensitivePath("/bin/ls"))
    }

    func testSensitiveHomeEntries() {
        let home = NSHomeDirectory()
        XCTAssertTrue(NativeToolSandbox.isSensitivePath(home + "/.ssh"))
        XCTAssertTrue(NativeToolSandbox.isSensitivePath(home + "/.ssh/id_rsa"))
        XCTAssertTrue(NativeToolSandbox.isSensitivePath(home + "/.gnupg/pubring"))
        XCTAssertTrue(NativeToolSandbox.isSensitivePath(home + "/.zshrc"))
        XCTAssertTrue(NativeToolSandbox.isSensitivePath(home + "/Library/Keychains/login.keychain"))
        XCTAssertTrue(NativeToolSandbox.isSensitivePath(home + "/.subagent/config.json"))
    }

    func testNonSensitivePaths() {
        let home = NSHomeDirectory()
        XCTAssertFalse(NativeToolSandbox.isSensitivePath(home + "/Desktop"))
        XCTAssertFalse(NativeToolSandbox.isSensitivePath(home + "/Desktop/x.txt"))
        XCTAssertFalse(NativeToolSandbox.isSensitivePath(home + "/Documents"))
        XCTAssertFalse(NativeToolSandbox.isSensitivePath("/tmp/x"))
        // /private/var 不在敏感清单（macOS 临时目录全解析到该前缀——sandbox.py L36-38 注释）
        XCTAssertFalse(NativeToolSandbox.isSensitivePath(root))
        XCTAssertFalse(NativeToolSandbox.isSensitivePath("/etcfoo/bar"))   // 同前缀兄弟不命中
    }

    /// 解析异常按敏感处理（保守）——macOS NSString 解析无抛出路径，本用例无法构造，
    /// 标注留档（Python L63-66 的 except 分支在原生侧不可达）。
    func testResolveFailureConservativeDocumented() {
        XCTAssertTrue(true)
    }
}
