//
//  NativePluginEndpointsTests.swift
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

//  逐条对照 subagent/sidecar/app.py L844-913 八端点 handler + ADR-0046 P-A：
//    · 安装：本地 git 仓库真 clone（临时 repo，只碰 /tmp）/ manifest 缺省生成 /
//      已有目录 rmtree 重装 / 非法 URL 400 / A13 create
//    · 列表：两态合并 + entry_point/hooks 缺省补齐（app.py L856-860）
//    · 卸载 404 逐字 + A13 delete plugin_name；toggle 400 逐字 + A13 update；
//      note GET 未安装也 200 / PUT 空串=清除 + A13 update；hooks 清单 404 逐字
//    · hook 触发：禁用 403 逐字 / 未安装 404 / 无 hook 404 / 同步 hook result /
//      async hook asyncio 驱动 / 异常 hook error=str(e) / 模块加载异常 500 /
//      python3 缺席（注入缝）error 字段不 5xx / 超时杀进程 error 字段
//    · 面板调用点：NativeSidecarClient 经 kernel 全原生（P3-W6 起无 HTTP fallback 层）
//
//  隔离纪律：真 git 仅本地临时仓库（不联网）；真 python3 仅跑临时目录测试插件；
//  绝不碰 ~/.subagent/plugins/。python3 缺席的机器跳过桥真跑用例（XCTSkip）。
//

import XCTest
@testable import VetarAINative

final class NativePluginEndpointsTests: XCTestCase {

    private var tmp: URL!
    private var dataRoot: URL!
    private var cfgStore: NativeConfigStore!
    private var store: NativePluginStore!
    private var endpoints: NativePluginEndpoints!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("w5ep_\(UUID().uuidString)")
        dataRoot = tmp.appendingPathComponent("dataroot")
        try? FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        cfgStore = NativeConfigStore(environment: ["VETARAI_DATA_ROOT": dataRoot.path])
        store = NativePluginStore(pluginsRoot: cfgStore.pluginsRoot())
        endpoints = NativePluginEndpoints(store: store, installContext: makeContext(gitRunner: .system))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    // MARK: - 装配辅助

    private func makeContext(gitRunner: NativeGitRunner) -> NativeToolContext {
        let cfg = cfgStore!
        let netGuard = NativeNetworkGuard(
            configProvider: { (try? cfg.getConfig()) ?? NativeConfigStore.defaultConfig },
            configWriter: { _ = try cfg.reloadConfig(patch: $0) })
        return NativeToolContext(
            config: { (try? cfg.getConfig()) ?? NativeConfigStore.defaultConfig },
            reloadConfig: { try cfg.reloadConfig(patch: $0) },
            pluginsRoot: { cfg.pluginsRoot() },
            skillsRoot: {
                let url = cfg.dataRoot().appendingPathComponent("skills")
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                return url
            },
            networkGuard: netGuard,
            transport: FailingTransport(),
            gitRunner: gitRunner)
    }

    private struct FailingTransport: NativeHTTPTransport {
        func send(_ request: NativeHTTPRequest) async throws -> NativeHTTPResponse {
            throw NativeHTTPTransportError.connect("tests must not hit network")
        }
    }

    private var pluginsRoot: URL { cfgStore.pluginsRoot() }

    private func makePluginDir(_ name: String, manifest: String? = nil,
                               pluginPy: String? = nil) -> URL {
        let dir = pluginsRoot.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let manifest {
            try? manifest.write(to: dir.appendingPathComponent("manifest.json"),
                                atomically: false, encoding: .utf8)
        }
        if let pluginPy {
            try? pluginPy.write(to: dir.appendingPathComponent("plugin.py"),
                                atomically: false, encoding: .utf8)
        }
        return dir
    }

    // MARK: - 真 git 辅助（仅本地仓库，不联网；同 NativeToolInstallTests 纪律）

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

    private func makeLocalRepo(name: String, manifest: String?) throws -> URL {
        // 本地路径安装以目录尾段为插件名（loader.py L163）——目录名即插件名
        let repo = tmp.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        if let manifest {
            try manifest.write(to: repo.appendingPathComponent("manifest.json"),
                               atomically: false, encoding: .utf8)
        }
        try "def on_message(ctx):\n    return 'hi'\n".write(
            to: repo.appendingPathComponent("plugin.py"), atomically: false, encoding: .utf8)
        XCTAssertEqual(try runGit(["init", "-q"], cwd: repo), 0)
        XCTAssertEqual(try runGit(["config", "user.email", "t@t.local"], cwd: repo), 0)
        XCTAssertEqual(try runGit(["config", "user.name", "t"], cwd: repo), 0)
        XCTAssertEqual(try runGit(["add", "-A"], cwd: repo), 0)
        XCTAssertEqual(try runGit(["commit", "-q", "-m", "init"], cwd: repo), 0)
        return repo
    }

    /// A13 事件捕获（clearAll 后动作 → 订阅扫描；NativeCUMacroEndpointTests 同款）。
    private func awaitPluginEvent() async -> [String: JSONValue]? {
        let events = NativeAppEvents.subscribe(sinceSeq: 0, idleTimeout: 0.05)
        var saw: [String: JSONValue]?
        for await ev in events where ev.event == "resource_changed" {
            if ev.data["resource"]?.string == "plugin" {
                saw = ev.data
                break
            }
        }
        return saw
    }

    // MARK: - ① 安装（POST /api/plugins/install，app.py L844-851）

    /// 本地仓库真 clone：{success:true, name, version, path, entry_point, hooks, description}
    /// + manifest 缺省生成 + A13 create。
    func testInstallLocalRepoRealGit() async throws {
        let repo = try makeLocalRepo(name: "demo-plugin", manifest: nil)
        NativeAppEvents.clearAll()
        let r = try await endpoints.install(repoUrl: repo.path)
        XCTAssertEqual(r["success"]?.bool, true)
        XCTAssertEqual(r["name"]?.string, "demo-plugin")
        XCTAssertEqual(r["version"]?.string, "0.1.0")
        XCTAssertEqual(r["entry_point"]?.string, "plugin.py")
        XCTAssertEqual(r["hooks"]?.stringArray, ["on_message"])
        XCTAssertEqual(r["description"]?.string, "")
        XCTAssertEqual(r["path"]?.string,
                       pluginsRoot.appendingPathComponent("demo-plugin").path)
        // manifest 缺省生成（loader.py L206-216）
        let mf = try String(contentsOf: pluginsRoot
            .appendingPathComponent("demo-plugin/manifest.json"), encoding: .utf8)
        XCTAssertTrue(mf.contains("\"name\": \"demo-plugin\""), mf)
        XCTAssertTrue(mf.contains("\"api_version\": \"1.0\""), mf)
        // 真 clone 产物（.git 存在 = 不是拷贝）
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: pluginsRoot.appendingPathComponent("demo-plugin/.git").path))
        let ev = await awaitPluginEvent()
        XCTAssertEqual(ev?["action"]?.string, "create")
        XCTAssertNil(ev?["plugin_name"])               // install A13 无 extra（L848）
    }

    /// 已有目录 rmtree 重装（loader.py L165-167）：旧文件被清掉。
    func testInstallReinstallRmtree() async throws {
        let repo = try makeLocalRepo(name: "demo-plugin", manifest: nil)
        _ = try await endpoints.install(repoUrl: repo.path)
        let stale = pluginsRoot.appendingPathComponent("demo-plugin/stale.txt")
        try "old".write(to: stale, atomically: false, encoding: .utf8)
        _ = try await endpoints.install(repoUrl: repo.path)      // 重装
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: pluginsRoot.appendingPathComponent("demo-plugin/plugin.py").path))
    }

    /// 仓库自带 manifest → 读它的字段（loader.py L217-218）。
    func testInstallRepoWithManifest() async throws {
        let repo = try makeLocalRepo(name: "rich", manifest:
            #"{"name": "rich", "version": "2.0.0", "entry_point": "main.py", "hooks": ["a", "b"], "description": "富插件"}"#)
        let r = try await endpoints.install(repoUrl: repo.path)
        XCTAssertEqual(r["version"]?.string, "2.0.0")
        XCTAssertEqual(r["entry_point"]?.string, "main.py")
        XCTAssertEqual(r["hooks"]?.stringArray, ["a", "b"])
        XCTAssertEqual(r["description"]?.string, "富插件")
    }

    /// 非法 URL → 400「Invalid GitHub URL: …」（L181 → app.py 400 str(e)）。
    func testInstallInvalidURL400() async throws {
        do {
            _ = try await endpoints.install(repoUrl: "not-a-url-at-all")
            XCTFail("应抛 400")
        } catch SidecarError.httpError(let status, let detail) {
            XCTAssertEqual(status, 400)
            XCTAssertEqual(detail, "Invalid GitHub URL: not-a-url-at-all")
        }
    }

    /// git clone 失败 → 400 CalledProcessError 形态文案（NativeGitError.pyDescription）。
    func testInstallCloneFailure400() async throws {
        do {
            _ = try await endpoints.install(repoUrl: "/nonexistent/repo-\(UUID().uuidString)")
            XCTFail("应抛 400")
        } catch SidecarError.httpError(let status, let detail) {
            XCTAssertEqual(status, 400)
            XCTAssertTrue(detail.contains("returned non-zero exit status"), detail)
        }
    }

    // MARK: - ② 列表（GET /api/plugins，L853-861）

    /// 缺省补齐：无 manifest 目录 → entry_point="plugin.py" / hooks=[]（端点层职责）。
    func testListDefaultsFilled() throws {
        makePluginDir("raw")
        makePluginDir("mf", manifest: #"{"name": "mf", "hooks": ["on_message"]}"#)
        let list = try endpoints.list()
        XCTAssertEqual(list.count, 2)
        let raw = list.first { $0["name"]?.string == "raw" }!
        XCTAssertEqual(raw["entry_point"]?.string, "plugin.py")
        XCTAssertEqual(raw["hooks"]?.array, [])
        XCTAssertEqual(raw["enabled"]?.bool, true)
        XCTAssertEqual(raw["note"]?.string, "")
        let mf = list.first { $0["name"]?.string == "mf" }!
        XCTAssertEqual(mf["hooks"]?.stringArray, ["on_message"])
    }

    // MARK: - ③ 卸载（DELETE /api/plugins/{name}，L863-869）

    func testUninstall404AndSuccess() async throws {
        do {
            _ = try endpoints.uninstall(name: "ghost")
            XCTFail("应抛 404")
        } catch SidecarError.httpError(let status, let detail) {
            XCTAssertEqual(status, 404)
            XCTAssertEqual(detail, "插件 ghost 未安装")
        }
        makePluginDir("real")
        _ = try store.toggleEnabled("real")
        _ = store.setNote("real", note: "n")
        NativeAppEvents.clearAll()
        let r = try endpoints.uninstall(name: "real")
        XCTAssertEqual(r["deleted"]?.bool, true)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: pluginsRoot.appendingPathComponent("real").path))
        XCTAssertEqual(try store.listInstalled().count, 0)
        let ev = await awaitPluginEvent()
        XCTAssertEqual(ev?["action"]?.string, "delete")
        XCTAssertEqual(ev?["plugin_name"]?.string, "real")
    }

    // MARK: - ④ toggle（POST /api/plugins/{name}/toggle，L871-878）

    func testToggle400AndSuccess() async throws {
        do {
            _ = try endpoints.toggle(name: "ghost")
            XCTFail("应抛 400")
        } catch SidecarError.httpError(let status, let detail) {
            XCTAssertEqual(status, 400)
            XCTAssertEqual(detail, "切换失败（插件不存在）")
        }
        makePluginDir("real")
        NativeAppEvents.clearAll()
        XCTAssertEqual(try endpoints.toggle(name: "real"), false)
        XCTAssertFalse(store.isEnabled("real"))
        let ev = await awaitPluginEvent()
        XCTAssertEqual(ev?["action"]?.string, "update")
        XCTAssertEqual(ev?["plugin_name"]?.string, "real")
        XCTAssertEqual(try endpoints.toggle(name: "real"), true)
    }

    // MARK: - ⑤⑥ note（GET/PUT /api/plugins/{name}/note，L883-893）

    /// GET 未安装也 200（Python 不查存在性）；PUT 空串=清除；PUT 才发 A13。
    func testNoteGetPut() async throws {
        XCTAssertEqual(endpoints.getNote(name: "ghost")["note"]?.string, "")
        makePluginDir("real")
        NativeAppEvents.clearAll()
        XCTAssertEqual(endpoints.setNote(name: "real", note: "  备注  "), "备注")
        let ev = await awaitPluginEvent()
        XCTAssertEqual(ev?["action"]?.string, "update")
        XCTAssertEqual(ev?["plugin_name"]?.string, "real")
        XCTAssertEqual(endpoints.getNote(name: "real")["note"]?.string, "备注")
        // 空串=清除
        XCTAssertEqual(endpoints.setNote(name: "real", note: ""), "")
        XCTAssertEqual(endpoints.getNote(name: "real")["note"]?.string, "")
    }

    // MARK: - ⑧ hooks 清单（GET /api/plugins/{name}/hooks，L907-914）

    func testHooksList() throws {
        makePluginDir("mf", manifest: #"{"name": "mf", "entry_point": "main.py", "hooks": ["a"]}"#)
        let r = try endpoints.hooksList(name: "mf")
        XCTAssertEqual(r["name"]?.string, "mf")
        XCTAssertEqual(r["hooks"]?.stringArray, ["a"])
        XCTAssertEqual(r["entry_point"]?.string, "main.py")
        // 无 manifest 目录：hooks=[] / entry_point=plugin.py 缺省
        makePluginDir("raw")
        let r2 = try endpoints.hooksList(name: "raw")
        XCTAssertEqual(r2["hooks"]?.array, [])
        XCTAssertEqual(r2["entry_point"]?.string, "plugin.py")
        do {
            _ = try endpoints.hooksList(name: "ghost")
            XCTFail("应抛 404")
        } catch SidecarError.httpError(let status, let detail) {
            XCTAssertEqual(status, 404)
            XCTAssertEqual(detail, "插件 ghost 未安装")
        }
    }

    // MARK: - ⑦ hook 触发（POST /api/plugins/{name}/hooks/{hook}，L895-905）

    /// 禁用 403 逐字（L898-900）；未安装/入口缺席 404 逐字。
    func testHookDisabled403AndMissing404() async throws {
        makePluginDir("real", pluginPy: "def on_message(ctx):\n    return 1\n")
        _ = try store.toggleEnabled("real")     // 禁用
        do {
            _ = try await endpoints.triggerHook(plugin: "real", hook: "on_message", agentContext: [:])
            XCTFail("应抛 403")
        } catch SidecarError.httpError(let status, let detail) {
            XCTAssertEqual(status, 403)
            XCTAssertEqual(detail, "插件「real」已被禁用（设置 → 插件与技能），无法调用")
        }
        // 未安装（目录缺席 → mod None → 404 同文案）
        do {
            _ = try await endpoints.triggerHook(plugin: "ghost", hook: "on_message", agentContext: [:])
            XCTFail("应抛 404")
        } catch SidecarError.httpError(let status, let detail) {
            XCTAssertEqual(status, 404)
            XCTAssertEqual(detail, "插件 ghost 没有 hook: on_message")
        }
        // 入口文件缺席（manifest 指向不存在文件 → mod None → 404）
        makePluginDir("noentry", manifest: #"{"entry_point": "missing.py"}"#)
        do {
            _ = try await endpoints.triggerHook(plugin: "noentry", hook: "on_message", agentContext: [:])
            XCTFail("应抛 404")
        } catch SidecarError.httpError(let status, let detail) {
            XCTAssertEqual(status, 404)
            XCTAssertEqual(detail, "插件 noentry 没有 hook: on_message")
        }
    }

    // ── 子进程桥真跑（/usr/bin/python3；缺席机器 XCTSkip）──

    private func requirePython3() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"),
                          "/usr/bin/python3 缺席——桥真跑用例跳过")
    }

    /// 四形态插件真跑：同步 result / async asyncio 驱动 / 异常 error=str(e) / 无 hook 404。
    func testHookBridgeFourFormsRealPython3() async throws {
        try requirePython3()
        makePluginDir("four", pluginPy: """
            def sync_hook(ctx):
                return {"echo": ctx.get("trigger"), "n": 1}

            async def async_hook(ctx):
                import asyncio
                await asyncio.sleep(0.01)
                return "async-ok"

            def boom_hook(ctx):
                raise ValueError("砰")

            """)
        // 同步
        let r1 = try await endpoints.triggerHook(
            plugin: "four", hook: "sync_hook",
            agentContext: ["trigger": .string("manual"), "source": .string("plugin_panel")])
        XCTAssertEqual(r1["plugin"]?.string, "four")
        XCTAssertEqual(r1["hook"]?.string, "sync_hook")
        XCTAssertEqual(r1["result"]?.object?["echo"]?.string, "manual")
        XCTAssertEqual(r1["result"]?.object?["n"]?.int, 1)
        // async（__await__ → asyncio 驱动）
        let r2 = try await endpoints.triggerHook(plugin: "four", hook: "async_hook", agentContext: [:])
        XCTAssertEqual(r2["result"]?.string, "async-ok")
        // 异常（str(e) 原文）
        let r3 = try await endpoints.triggerHook(plugin: "four", hook: "boom_hook", agentContext: [:])
        XCTAssertEqual(r3["plugin"]?.string, "four")
        XCTAssertEqual(r3["hook"]?.string, "boom_hook")
        XCTAssertEqual(r3["error"]?.string, "砰")
        XCTAssertNil(r3["result"])
        // 无 hook（getattr None → 404）
        do {
            _ = try await endpoints.triggerHook(plugin: "four", hook: "no_such", agentContext: [:])
            XCTFail("应抛 404")
        } catch SidecarError.httpError(let status, let detail) {
            XCTAssertEqual(status, 404)
            XCTAssertEqual(detail, "插件 four 没有 hook: no_such")
        }
    }

    /// hook 返回 None → result: null（Python {"result": None}；VM 映射「（无返回值）」）。
    /// 插件自身 print 污染 stdout 不影响协议（哨兵行兜底）。
    func testHookNoneResultAndStdoutNoise() async throws {
        try requirePython3()
        makePluginDir("noise", pluginPy: """
            def quiet_hook(ctx):
                print("插件自己的日志输出")
                return None

            """)
        let r = try await endpoints.triggerHook(plugin: "noise", hook: "quiet_hook", agentContext: [:])
        XCTAssertEqual(r["result"], .null)
    }

    /// 模块加载异常（顶层 raise）→ 500（Python 进程内语义：exec_module 异常
    /// 不被 execute_hook 捕获 → 框架 500；微差④ detail 带 str(e)）。
    func testHookLoadError500() async throws {
        try requirePython3()
        makePluginDir("badload", pluginPy: "raise RuntimeError('装载即炸')\n")
        do {
            _ = try await endpoints.triggerHook(plugin: "badload", hook: "on_message", agentContext: [:])
            XCTFail("应抛 500")
        } catch SidecarError.httpError(let status, let detail) {
            XCTAssertEqual(status, 500)
            XCTAssertEqual(detail, "装载即炸")
        }
    }

    /// manifest entry_point 自定义入口真跑（loader.py L286-292 读取链）。
    func testHookCustomEntryPoint() async throws {
        try requirePython3()
        let dir = makePluginDir("custom", manifest: #"{"entry_point": "main.py"}"#)
        try "def on_message(ctx):\n    return 'from-main'\n".write(
            to: dir.appendingPathComponent("main.py"), atomically: false, encoding: .utf8)
        let r = try await endpoints.triggerHook(plugin: "custom", hook: "on_message", agentContext: [:])
        XCTAssertEqual(r["result"]?.string, "from-main")
    }

    /// 超时杀进程（ADR-0046 新增 60s——测试用 2s 档验证同一代码路径）。
    func testHookTimeoutKillsProcess() async throws {
        try requirePython3()
        endpoints.hookRunner = .systemWithTimeout(2)
        makePluginDir("sleeper", pluginPy: """
            import time
            def slow_hook(ctx):
                time.sleep(30)
                return "never"

            """)
        let start = Date()
        let r = try await endpoints.triggerHook(plugin: "sleeper", hook: "slow_hook", agentContext: [:])
        XCTAssertLessThan(Date().timeIntervalSince(start), 15)   // 真杀进程，不等满 30s
        XCTAssertEqual(r["plugin"]?.string, "sleeper")
        XCTAssertEqual(r["error"]?.string, "插件 hook 执行超时（2s），已终止")
    }

    /// python3 缺席路径（注入缝模拟，ADR：error 字段形如执行异常，不 5xx）。
    func testHookPython3MissingSeam() async throws {
        makePluginDir("real", pluginPy: "def on_message(ctx):\n    return 1\n")
        endpoints.hookRunner = NativePluginHookRunner { _, _, _, _, _ in
            .error("无法执行插件 hook：/usr/bin/python3 不存在或不可执行"
                + "（插件 hook 需要系统 Python 3，请安装 Xcode Command Line Tools）")
        }
        let r = try await endpoints.triggerHook(plugin: "real", hook: "on_message", agentContext: [:])
        XCTAssertEqual(r["plugin"]?.string, "real")
        XCTAssertEqual(r["hook"]?.string, "on_message")
        XCTAssertTrue(r["error"]?.string?.contains("python3") ?? false, "\(r)")
        XCTAssertNil(r["result"])
    }

    // MARK: - 面板调用点（NativeSidecarClient 全原生）

    /// PluginsPanelClient 经 kernel 原生：列表/切换/备注/卸载/hook 触发全落内核
    /// （历史上经未实现 PluginsPanelClient 的 BareFallbackClient 录证「零触达」——
    ///  P3-W6 fallback 层删除后无网可触，直验行为）。
    func testPanelClientNativeRouting() async throws {
        try requirePython3()
        let kernel = NativeKernel(dataRoot: dataRoot)
        let client = NativeSidecarClient(kernel: kernel)
        // 经内核端点装一个真插件（假 git runner 造产物，不触网）
        makePluginDir("panelled", pluginPy:
            "def on_message(ctx):\n    return 'panel-ok'\n")
        // 列表（两态 + 缺省补齐）
        let plugins = try await client.listPlugins()
        XCTAssertEqual(plugins.map(\.name), ["panelled"])
        XCTAssertEqual(plugins[0].entry_point, "plugin.py")
        XCTAssertEqual(plugins[0].hooks, [])
        XCTAssertEqual(plugins[0].enabled, true)
        // hook 触发（真 python3 桥；返回 {plugin, hook, result} 字典）
        let raw = try await client.triggerPluginHook(plugin: "panelled", hook: "on_message")
        XCTAssertEqual(raw["plugin"] as? String, "panelled")
        XCTAssertEqual(raw["hook"] as? String, "on_message")
        XCTAssertEqual(raw["result"] as? String, "panel-ok")
        // toggle（协议 enabled 入参被忽略，服务端翻转语义）
        let toggled = try await client.togglePlugin(name: "panelled", enabled: false)
        XCTAssertEqual(toggled, false)
        // 禁用后 hook 触发 403（面板同步禁用按钮的后端兜底）
        do {
            _ = try await client.triggerPluginHook(plugin: "panelled", hook: "on_message")
            XCTFail("应抛 403")
        } catch SidecarError.httpError(let status, _) {
            XCTAssertEqual(status, 403)
        }
        _ = try await client.togglePlugin(name: "panelled", enabled: true)
        // 备注
        let savedNote = try await client.setPluginNote(name: "panelled", note: "面板备注")
        XCTAssertEqual(savedNote, "面板备注")
        // 卸载
        try await client.uninstallPlugin(name: "panelled")
        let afterUninstall = try await client.listPlugins()
        XCTAssertEqual(afterUninstall.count, 0)
        // 错误形态与 HTTP 同形：404 detail 逐字
        do {
            try await client.uninstallPlugin(name: "panelled")
            XCTFail("应抛 404")
        } catch SidecarError.httpError(let status, let detail) {
            XCTAssertEqual(status, 404)
            XCTAssertEqual(detail, "插件 panelled 未安装")
        }
    }

    /// installPlugin 面板口径：返回 name/version；400 原文案。
    func testPanelInstallPlugin() async throws {
        let kernel = NativeKernel(dataRoot: dataRoot)
        let client = NativeSidecarClient(kernel: kernel)
        let repo = try makeLocalRepo(name: "panel-install", manifest:
            #"{"name": "panel-install", "version": "3.1.4"}"#)
        let res = try await client.installPlugin(repoUrl: repo.path)
        XCTAssertEqual(res.name, "panel-install")
        XCTAssertEqual(res.version, "3.1.4")
        do {
            _ = try await client.installPlugin(repoUrl: "bad-url")
            XCTFail("应抛 400")
        } catch SidecarError.httpError(let status, let detail) {
            XCTAssertEqual(status, 400)
            XCTAssertEqual(detail, "Invalid GitHub URL: bad-url")
        }
    }
}
