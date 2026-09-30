//
//  NativeToolInstallTests.swift
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

//  逐条对照 subagent/sidecar/plugin_loader/loader.py install_from_github 与
//  subagent/sidecar/skills_mgr/manager.py install_skill_from_repo + registry.py
//  安装分支（0.4.9 任务152 联网授权流，⛔ 只读行为规格源）：
//    · 本地插件仓库 git clone 安装（manifest 缺失写默认 / 已存在先删再装）
//    · 远程 URL 取名正则 / Invalid GitHub URL / 联网授权三态
//    · （拒绝无授权通道 network_install_denied / 用户拒绝 denied_by_user /
//       放行+enable_network 自动切 proxy 并清熔断）
//    · 技能本地直拷（SKILL.md rglob / frontmatter 取名 / 名清洗 / 已存在拒绝）
//    · 技能远程 --depth 1 克隆（假 runner 造源，clone 失败文案逐字）
//
//  隔离纪律：临时目录造源；真实 git 仅用于本地仓库（不联网）；
//  远程安装一律注入假 git runner（拷贝 fixture 造克隆产物），不打真网络。
//

import XCTest
@testable import VetarAINative

final class NativeToolInstallTests: XCTestCase {

    private var tmp: URL!
    private var dataRoot: URL!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("w3ains_\(UUID().uuidString)")
        dataRoot = tmp.appendingPathComponent("dataroot")
        try? FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    // MARK: - 假 git runner（记录 argv；把 fixture 拷到 dest 模拟 clone 产物）

    private final class FakeGit: @unchecked Sendable {
        var calls: [[String]] = []
        var fixture: URL?          // 非 nil：拷贝到 argv 末参（dest）
        var failure: NativeGitError?
        var runner: NativeGitRunner {
            NativeGitRunner { argv, _ in
                self.calls.append(argv)
                if let failure = self.failure { return failure }
                if let fixture = self.fixture, let dest = argv.last {
                    try? FileManager.default.removeItem(atPath: dest)
                    try? FileManager.default.copyItem(atPath: fixture.path, toPath: dest)
                }
                return nil
            }
        }
    }

    private func makeContext(gitRunner: NativeGitRunner,
                             patch: [String: JSONValue] = [:]) throws -> (NativeToolContext, NativeConfigStore) {
        let store = NativeConfigStore(environment: ["VETARAI_DATA_ROOT": dataRoot.path])
        if !patch.isEmpty { _ = try store.reloadConfig(patch: patch) }
        let netGuard = NativeNetworkGuard(
            configProvider: { (try? store.getConfig()) ?? NativeConfigStore.defaultConfig },
            configWriter: { _ = try store.reloadConfig(patch: $0) })
        let ctx = NativeToolContext(
            config: { (try? store.getConfig()) ?? NativeConfigStore.defaultConfig },
            reloadConfig: { try store.reloadConfig(patch: $0) },
            pluginsRoot: { store.pluginsRoot() },
            skillsRoot: {
                let url = store.dataRoot().appendingPathComponent("skills")
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                return url
            },
            networkGuard: netGuard,
            transport: FailingInstallTransport(),
            gitRunner: gitRunner)
        return (ctx, store)
    }

    private struct FailingInstallTransport: NativeHTTPTransport {
        func send(_ request: NativeHTTPRequest) async throws -> NativeHTTPResponse {
            throw NativeHTTPTransportError.connect("tests must not hit network")
        }
    }

    private func errOf(_ r: [String: JSONValue]) -> String { r["error"]?.string ?? "" }

    // MARK: - 真 git 辅助（仅本地仓库，不联网）

    private func runGit(_ args: [String], cwd: URL? = nil) throws -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = args
        proc.currentDirectoryURL = cwd
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus
    }

    /// 造本地 git 仓库（可选 manifest.json 内容）。
    private func makeLocalRepo(name: String, manifest: String?) throws -> URL {
        let repo = tmp.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        if let manifest {
            try manifest.write(to: repo.appendingPathComponent("manifest.json"),
                               atomically: false, encoding: .utf8)
        }
        try "print('hi')".write(to: repo.appendingPathComponent("plugin.py"),
                                atomically: false, encoding: .utf8)
        XCTAssertEqual(try runGit(["init", "-q"], cwd: repo), 0)
        XCTAssertEqual(try runGit(["config", "user.email", "t@t.local"], cwd: repo), 0)
        XCTAssertEqual(try runGit(["config", "user.name", "t"], cwd: repo), 0)
        XCTAssertEqual(try runGit(["add", "-A"], cwd: repo), 0)
        XCTAssertEqual(try runGit(["commit", "-q", "-m", "init"], cwd: repo), 0)
        return repo
    }

    // MARK: - install_plugin：本地仓库

    /// 本地仓库无 manifest.json → 安装到 plugins/<repo 名>，写默认 manifest，name=目录名。
    func testInstallPluginLocalRepoDefaultManifest() async throws {
        let repo = try makeLocalRepo(name: "my-plugin", manifest: nil)
        let (ctx, _) = try makeContext(gitRunner: .system)
        let r = await NativeToolRegistry.execute("install_plugin",
                                                 args: ["source": .string(repo.path)],
                                                 sandboxRoot: tmp.path,
                                                 authorizer: nil, context: ctx)
        XCTAssertEqual(r["ok"], .bool(true), errOf(r))
        XCTAssertEqual(r["name"], .string("my-plugin"))
        let dir = dataRoot.appendingPathComponent("plugins/my-plugin")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("plugin.py").path))
        // 默认 manifest 落盘（json.dumps indent=2 形态）
        let manifestText = try String(
            contentsOf: dir.appendingPathComponent("manifest.json"), encoding: .utf8)
        XCTAssertTrue(manifestText.contains("\"name\": \"my-plugin\""), manifestText)
        XCTAssertTrue(manifestText.contains("\"entry_point\": \"plugin.py\""), manifestText)
        XCTAssertTrue(manifestText.contains("\"hooks\": [\n    \"on_message\"\n  ]"), manifestText)
    }

    /// 本地仓库带 manifest.json → name 取 manifest.name。
    func testInstallPluginLocalRepoWithManifest() async throws {
        let repo = try makeLocalRepo(
            name: "repo-dir",
            manifest: #"{"name": "fancy-plugin", "version": "2.0", "description": "d"}"#)
        let (ctx, _) = try makeContext(gitRunner: .system)
        let r = await NativeToolRegistry.execute("install_plugin",
                                                 args: ["source": .string(repo.path)],
                                                 sandboxRoot: tmp.path,
                                                 authorizer: nil, context: ctx)
        XCTAssertEqual(r["ok"], .bool(true), errOf(r))
        XCTAssertEqual(r["name"], .string("fancy-plugin"))
        // 安装目录按仓库目录名（不是 manifest 名）
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dataRoot.appendingPathComponent("plugins/repo-dir/plugin.py").path))
    }

    /// 已存在 → 先删再装（rmtree 语义：旧文件被清掉）。
    func testInstallPluginReinstallWipesOld() async throws {
        let repo = try makeLocalRepo(name: "my-plugin", manifest: nil)
        let dir = dataRoot.appendingPathComponent("plugins/my-plugin")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "stale".write(to: dir.appendingPathComponent("stale.txt"),
                          atomically: false, encoding: .utf8)
        let (ctx, _) = try makeContext(gitRunner: .system)
        let r = await NativeToolRegistry.execute("install_plugin",
                                                 args: ["source": .string(repo.path)],
                                                 sandboxRoot: tmp.path,
                                                 authorizer: nil, context: ctx)
        XCTAssertEqual(r["ok"], .bool(true), errOf(r))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("stale.txt").path))
    }

    /// 本地路径不存在 + 非远程前缀 → 走 loader（loader 内 git clone 失败 → install_failed）。
    func testInstallPluginLocalPathMissing() async throws {
        let (ctx, _) = try makeContext(gitRunner: .system)
        let r = await NativeToolRegistry.execute("install_plugin",
                                                 args: ["source": .string("/no/such/repo")],
                                                 sandboxRoot: tmp.path,
                                                 authorizer: nil, context: ctx)
        XCTAssertEqual(r["ok"], .bool(false))
        XCTAssertTrue(errOf(r).hasPrefix("install_failed: "), errOf(r))
    }

    // MARK: - install_plugin：远程授权流（0.4.9 任务152）

    /// 无授权通道 → network_install_denied（不静默联网）。
    func testRemotePluginNoAuthorizerDenied() async throws {
        let (ctx, _) = try makeContext(gitRunner: .system)
        let r = await NativeToolRegistry.execute(
            "install_plugin", args: ["source": .string("https://github.com/foo/bar")],
            sandboxRoot: tmp.path, authorizer: nil, context: ctx)
        XCTAssertEqual(r["ok"], .bool(false))
        XCTAssertTrue(errOf(r).hasPrefix("network_install_denied: 需要联网下载安装"), errOf(r))
        XCTAssertTrue(errOf(r).contains("或改用本地目录安装"), errOf(r))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dataRoot.appendingPathComponent("plugins/bar").path))
    }

    /// 用户拒绝 → denied_by_user 文案（来源内嵌；不得重试/换源绕过）。
    func testRemotePluginUserDenied() async throws {
        let (ctx, _) = try makeContext(gitRunner: .system)
        let deny = NativeCallbackAuthorizer(
            onAuthorize: { _, _, _ in false },
            onNetInstall: { _, _, _ in (false, false) })
        let r = await NativeToolRegistry.execute(
            "install_plugin", args: ["source": .string("https://github.com/foo/bar")],
            sandboxRoot: tmp.path, authorizer: deny, context: ctx)
        XCTAssertTrue(errOf(r).hasPrefix(
            "denied_by_user: 用户拒绝了本次联网安装（来源：https://github.com/foo/bar）"), errOf(r))
    }

    /// 授权放行（不勾 enable_network）→ 假 runner 安装成功；auto 模式直连无代理参数。
    func testRemotePluginAllowedInstalls() async throws {
        let fake = FakeGit()
        fake.fixture = tmp.appendingPathComponent("remote-fixture")
        try FileManager.default.createDirectory(at: fake.fixture!, withIntermediateDirectories: true)
        try #"{"name": "bar-plugin"}"#.write(
            to: fake.fixture!.appendingPathComponent("manifest.json"),
            atomically: false, encoding: .utf8)
        let (ctx, _) = try makeContext(gitRunner: fake.runner)
        var receivedExtra: [String: JSONValue] = [:]
        let allow = NativeCallbackAuthorizer(
            onAuthorize: { _, _, _ in true },
            onNetInstall: { _, _, extra in receivedExtra = extra; return (true, false) })
        let r = await NativeToolRegistry.execute(
            "install_plugin", args: ["source": .string("https://github.com/foo/bar")],
            sandboxRoot: tmp.path, authorizer: allow, context: ctx)
        XCTAssertEqual(r["ok"], .bool(true), errOf(r))
        XCTAssertEqual(r["name"], .string("bar-plugin"))
        // 授权 extra 契约（kind/source_url/install_type/current_mode/need_enable_network）
        XCTAssertEqual(receivedExtra["kind"], .string("net_install"))
        XCTAssertEqual(receivedExtra["source_url"], .string("https://github.com/foo/bar"))
        XCTAssertEqual(receivedExtra["install_type"], .string("插件（Plugin）"))
        XCTAssertEqual(receivedExtra["need_enable_network"], .bool(true))   // auto 非全量
        // clone argv：URL + 目标目录；auto 模式直连（无 -c http.proxy）
        XCTAssertEqual(fake.calls.count, 1)
        XCTAssertEqual(fake.calls[0].filter { $0.hasPrefix("-c") }.count, 0)
        XCTAssertTrue(fake.calls[0].contains("https://github.com/foo/bar"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dataRoot.appendingPathComponent("plugins/bar/manifest.json").path))
    }

    /// proxy 模式放行 → git 挂 -c http.proxy 参数（guard 裁决唯一漏斗）。
    func testRemotePluginProxyModeGitProxyArgs() async throws {
        let fake = FakeGit()
        fake.fixture = tmp.appendingPathComponent("remote-fixture2")
        try FileManager.default.createDirectory(at: fake.fixture!, withIntermediateDirectories: true)
        let (ctx, _) = try makeContext(gitRunner: fake.runner,
                                       patch: ["network_switch": .string("proxy")])
        let allow = NativeCallbackAuthorizer(
            onAuthorize: { _, _, _ in true },
            onNetInstall: { _, _, _ in (true, false) })
        let r = await NativeToolRegistry.execute(
            "install_plugin", args: ["source": .string("https://github.com/foo/bar")],
            sandboxRoot: tmp.path, authorizer: allow, context: ctx)
        XCTAssertEqual(r["ok"], .bool(true), errOf(r))
        let argv = fake.calls[0]
        XCTAssertTrue(argv.contains("http.proxy=http://127.0.0.1:21081"), argv.joined(separator: " "))
        XCTAssertTrue(argv.contains("https.proxy=http://127.0.0.1:21081"), argv.joined(separator: " "))
    }

    /// 放行 + 勾选开启全量联网 → 自动切 proxy 并清熔断（registry L327-336）。
    func testRemotePluginEnableNetworkSwitchesProxy() async throws {
        let fake = FakeGit()
        fake.fixture = tmp.appendingPathComponent("remote-fixture3")
        try FileManager.default.createDirectory(at: fake.fixture!, withIntermediateDirectories: true)
        let (ctx, store) = try makeContext(gitRunner: fake.runner)
        let allow = NativeCallbackAuthorizer(
            onAuthorize: { _, _, _ in true },
            onNetInstall: { _, _, _ in (true, true) })   // allowed + enable_network
        let r = await NativeToolRegistry.execute(
            "install_plugin", args: ["source": .string("https://github.com/foo/bar")],
            sandboxRoot: tmp.path, authorizer: allow, context: ctx)
        XCTAssertEqual(r["ok"], .bool(true), errOf(r))
        let cfg = try store.getConfig()
        XCTAssertEqual(cfg["network_switch"], .string("proxy"))
    }

    /// confirm_network_install=false → 不弹窗直走 loader；非法 URL → Invalid GitHub URL。
    func testRemotePluginNoConfirmInvalidURL() async throws {
        let (ctx, _) = try makeContext(gitRunner: .system,
                                       patch: ["confirm_network_install": .bool(false)])
        let r = await NativeToolRegistry.execute(
            "install_plugin", args: ["source": .string("https://github.com")],
            sandboxRoot: tmp.path, authorizer: nil, context: ctx)
        XCTAssertEqual(errOf(r), "install_failed: Invalid GitHub URL: https://github.com")
    }

    /// bad_arg source（空/缺失/非串）。
    func testInstallBadArgSource() async throws {
        let (ctx, _) = try makeContext(gitRunner: .system)
        for args: [String: JSONValue] in [[:], ["source": .string("  ")],
                                          ["source": .int(1)]] {
            for tool in ["install_plugin", "install_skill"] {
                let r = await NativeToolRegistry.execute(tool, args: args,
                                                         sandboxRoot: tmp.path,
                                                         authorizer: nil, context: ctx)
                XCTAssertEqual(errOf(r),
                               "bad_arg: source（需要 GitHub 仓库 URL 或本地目录绝对路径）",
                               "\(tool) \(args)")
            }
        }
    }

    // MARK: - install_skill：本地直拷

    private func makeSkillDir(_ rel: String, frontmatter: String?,
                              nested: String? = nil) throws -> URL {
        let dir = nested.map { tmp.appendingPathComponent($0).appendingPathComponent(rel) }
            ?? tmp.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var text = ""
        if let frontmatter { text = frontmatter }
        text += "\n\n# 技能正文\n"
        try text.write(to: dir.appendingPathComponent("SKILL.md"),
                       atomically: false, encoding: .utf8)
        try "helper".write(to: dir.appendingPathComponent("helper.txt"),
                           atomically: false, encoding: .utf8)
        return dir
    }

    /// frontmatter name → 安装到 skills/<name>（copytree 整目录）。
    func testInstallSkillLocalWithName() async throws {
        _ = try makeSkillDir("whatever", frontmatter: "---\nname: demo-skill\ndescription: d\n---")
        let (ctx, _) = try makeContext(gitRunner: .system)
        let r = await NativeToolRegistry.execute(
            "install_skill", args: ["source": .string(tmp.appendingPathComponent("whatever").path)],
            sandboxRoot: tmp.path, authorizer: nil, context: ctx)
        XCTAssertEqual(r["ok"], .bool(true), errOf(r))
        XCTAssertEqual(r["name"], .string("demo-skill"))
        let dest = dataRoot.appendingPathComponent("skills/demo-skill")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dest.appendingPathComponent("SKILL.md").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dest.appendingPathComponent("helper.txt").path))
    }

    /// frontmatter 无 name → 取 SKILL.md 父目录名。
    func testInstallSkillNameFromParentDir() async throws {
        _ = try makeSkillDir("myskill", frontmatter: nil)
        let (ctx, _) = try makeContext(gitRunner: .system)
        let r = await NativeToolRegistry.execute(
            "install_skill", args: ["source": .string(tmp.appendingPathComponent("myskill").path)],
            sandboxRoot: tmp.path, authorizer: nil, context: ctx)
        XCTAssertEqual(r["ok"], .bool(true), errOf(r))
        XCTAssertEqual(r["name"], .string("myskill"))
    }

    /// 根目录无 SKILL.md → rglob 找嵌套（copytree 自 SKILL.md 所在目录）。
    func testInstallSkillNestedSKILLmd() async throws {
        _ = try makeSkillDir("inner/deep", frontmatter: "---\nname: nested-skill\n---",
                             nested: "outer")
        let (ctx, _) = try makeContext(gitRunner: .system)
        let r = await NativeToolRegistry.execute(
            "install_skill", args: ["source": .string(tmp.appendingPathComponent("outer").path)],
            sandboxRoot: tmp.path, authorizer: nil, context: ctx)
        XCTAssertEqual(r["ok"], .bool(true), errOf(r))
        XCTAssertEqual(r["name"], .string("nested-skill"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dataRoot.appendingPathComponent("skills/nested-skill/helper.txt").path))
    }

    /// 目录内无 SKILL.md → install_failed: 该目录内未找到 SKILL.md。
    func testInstallSkillNoSKILLmd() async throws {
        let dir = tmp.appendingPathComponent("empty-dir")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (ctx, _) = try makeContext(gitRunner: .system)
        let r = await NativeToolRegistry.execute(
            "install_skill", args: ["source": .string(dir.path)],
            sandboxRoot: tmp.path, authorizer: nil, context: ctx)
        XCTAssertEqual(errOf(r), "install_failed: 该目录内未找到 SKILL.md")
    }

    /// 技能名非法（含空格/叹号——[\w一-龥-] 之外字符）。
    func testInstallSkillInvalidName() async throws {
        _ = try makeSkillDir("bad", frontmatter: "---\nname: bad name!\n---")
        let (ctx, _) = try makeContext(gitRunner: .system)
        let r = await NativeToolRegistry.execute(
            "install_skill", args: ["source": .string(tmp.appendingPathComponent("bad").path)],
            sandboxRoot: tmp.path, authorizer: nil, context: ctx)
        XCTAssertEqual(errOf(r), "install_failed: 技能名非法: bad name!")
    }

    /// 技能已存在 → 拒绝（不覆盖）。
    func testInstallSkillAlreadyExists() async throws {
        _ = try makeSkillDir("whatever", frontmatter: "---\nname: demo-skill\n---")
        let (ctx, _) = try makeContext(gitRunner: .system)
        let src = tmp.appendingPathComponent("whatever").path
        let r1 = await NativeToolRegistry.execute(
            "install_skill", args: ["source": .string(src)],
            sandboxRoot: tmp.path, authorizer: nil, context: ctx)
        XCTAssertEqual(r1["ok"], .bool(true), errOf(r1))
        let r2 = await NativeToolRegistry.execute(
            "install_skill", args: ["source": .string(src)],
            sandboxRoot: tmp.path, authorizer: nil, context: ctx)
        XCTAssertEqual(errOf(r2), "install_failed: 技能已存在: demo-skill")
    }

    /// 中文技能名合法（[\w一-龥-] 覆盖）。
    func testInstallSkillChineseName() async throws {
        _ = try makeSkillDir("whatever", frontmatter: "---\nname: 案件处理-v2\n---")
        let (ctx, _) = try makeContext(gitRunner: .system)
        let r = await NativeToolRegistry.execute(
            "install_skill", args: ["source": .string(tmp.appendingPathComponent("whatever").path)],
            sandboxRoot: tmp.path, authorizer: nil, context: ctx)
        XCTAssertEqual(r["ok"], .bool(true), errOf(r))
        XCTAssertEqual(r["name"], .string("案件处理-v2"))
    }

    // MARK: - install_skill：远程克隆（假 runner 造源）

    /// 远程：git clone --depth 1 到临时目录 → 找到 SKILL.md → copytree。
    func testInstallSkillRemoteViaClone() async throws {
        let fake = FakeGit()
        fake.fixture = tmp.appendingPathComponent("skill-fixture")
        try FileManager.default.createDirectory(at: fake.fixture!, withIntermediateDirectories: true)
        try "---\nname: remote-skill\n---\n\n正文".write(
            to: fake.fixture!.appendingPathComponent("SKILL.md"),
            atomically: false, encoding: .utf8)
        let (ctx, _) = try makeContext(gitRunner: fake.runner)
        let allow = NativeCallbackAuthorizer(
            onAuthorize: { _, _, _ in true },
            onNetInstall: { _, _, _ in (true, false) })
        let r = await NativeToolRegistry.execute(
            "install_skill", args: ["source": .string("https://github.com/foo/sk")],
            sandboxRoot: tmp.path, authorizer: allow, context: ctx)
        XCTAssertEqual(r["ok"], .bool(true), errOf(r))
        XCTAssertEqual(r["name"], .string("remote-skill"))
        // clone argv：--depth 1 契约
        XCTAssertEqual(fake.calls.count, 1)
        XCTAssertEqual(Array(fake.calls[0][0...3]), ["git", "clone", "--depth", "1"])
        XCTAssertEqual(fake.calls[0][4], "https://github.com/foo/sk")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dataRoot.appendingPathComponent("skills/remote-skill/SKILL.md").path))
    }

    /// clone 失败 → install_failed: git clone 失败：<stderr 前200>。
    func testInstallSkillRemoteCloneFails() async throws {
        let fake = FakeGit()
        fake.failure = .failed(exitCode: 128,
                               stderr: "fatal: repository 'x' not found\n",
                               argv: ["git", "clone", "--depth", "1", "u", "d"])
        let (ctx, _) = try makeContext(gitRunner: fake.runner)
        let allow = NativeCallbackAuthorizer(
            onAuthorize: { _, _, _ in true },
            onNetInstall: { _, _, _ in (true, false) })
        let r = await NativeToolRegistry.execute(
            "install_skill", args: ["source": .string("https://github.com/foo/sk")],
            sandboxRoot: tmp.path, authorizer: allow, context: ctx)
        XCTAssertEqual(errOf(r), "install_failed: git clone 失败：fatal: repository 'x' not found")
    }

    /// clone 超时 → install_failed: git clone 超时（120s）。
    func testInstallSkillRemoteCloneTimeout() async throws {
        let fake = FakeGit()
        fake.failure = .timeout
        let (ctx, _) = try makeContext(gitRunner: fake.runner)
        let allow = NativeCallbackAuthorizer(
            onAuthorize: { _, _, _ in true },
            onNetInstall: { _, _, _ in (true, false) })
        let r = await NativeToolRegistry.execute(
            "install_skill", args: ["source": .string("https://github.com/foo/sk")],
            sandboxRoot: tmp.path, authorizer: allow, context: ctx)
        XCTAssertEqual(errOf(r), "install_failed: git clone 超时（120s）")
    }

    /// 技能远程无授权通道 → network_install_denied（与插件同口径）。
    func testRemoteSkillNoAuthorizerDenied() async throws {
        let (ctx, _) = try makeContext(gitRunner: .system)
        let r = await NativeToolRegistry.execute(
            "install_skill", args: ["source": .string("https://github.com/foo/sk")],
            sandboxRoot: tmp.path, authorizer: nil, context: ctx)
        XCTAssertTrue(errOf(r).hasPrefix("network_install_denied: "), errOf(r))
    }

    // MARK: - frontmatter / 技能名单元

    func testParseFrontmatter() {
        let (meta, body) = NativeToolInstall.parseFrontmatter(
            "---\nname: \"quoted-name\"\ndescription: '单引号'\nempty:\n---\n\n正文第一行\n第二行")
        XCTAssertEqual(meta["name"], "quoted-name")
        XCTAssertEqual(meta["description"], "单引号")
        XCTAssertEqual(meta["empty"], "")
        XCTAssertEqual(body, "\n正文第一行\n第二行")
    }

    func testParseFrontmatterNoFrontmatter() {
        let (meta, body) = NativeToolInstall.parseFrontmatter("# 标题\n正文")
        XCTAssertTrue(meta.isEmpty)
        XCTAssertEqual(body, "# 标题\n正文")
    }

    /// 无收尾 --- → 视为无 frontmatter（Python end_idx is None 分支）。
    func testParseFrontmatterUnterminated() {
        let (meta, body) = NativeToolInstall.parseFrontmatter("---\nname: x\n正文无收尾")
        XCTAssertTrue(meta.isEmpty)
        XCTAssertEqual(body, "---\nname: x\n正文无收尾")
    }

    func testValidSkillName() {
        XCTAssertTrue(NativeToolInstall.validSkillName("abc"))
        XCTAssertTrue(NativeToolInstall.validSkillName("a-b_c1"))
        XCTAssertTrue(NativeToolInstall.validSkillName("中文名"))
        XCTAssertTrue(NativeToolInstall.validSkillName(String(repeating: "a", count: 64)))
        XCTAssertFalse(NativeToolInstall.validSkillName(""))
        XCTAssertFalse(NativeToolInstall.validSkillName(String(repeating: "a", count: 65)))
        XCTAssertFalse(NativeToolInstall.validSkillName("bad name"))
        XCTAssertFalse(NativeToolInstall.validSkillName("bad/name"))
        XCTAssertFalse(NativeToolInstall.validSkillName("bad.name"))
        XCTAssertFalse(NativeToolInstall.validSkillName("bad!"))
    }
}
