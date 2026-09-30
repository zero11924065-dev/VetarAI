//
//  SettingsPanelW2Tests.swift
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

//  设置面板单测：
//    · JSONValue 编解码保真（int/double/bool/string/嵌套不串型）
//    · SidecarConfig 未知键往返保留（⭐ 硬约束：设置读写丢键是灾难）
//    · 类型化访问器默认值与宽松解码（类型不符不炸）
//    · ConfigValidator 与后端 store.py _validate 同范围同文案
//    · SettingsViewModel：load/save 流程、勾选即存、名单增删、
//      auth_grants 逐条移除、模型特长 100 字截断、network_switch 显示映射、
//      保存响应只回灌涉及键（不打断其他输入中草稿）
//

import XCTest
@testable import VetarAINative

// MARK: - JSONValue 编解码

final class JSONValueTests: XCTestCase {

    private func roundTrip(_ json: String) throws -> String {
        let v = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        let data = try JSONEncoder().encode(v)
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 语义相等比较（NSNumber 桥接：15 与 15.0 在 JSONSerialization 层面同为 NSNumber）。
    private func assertSemanticEqual(_ a: String, _ b: String, _ message: String = "") {
        let objA = try? JSONSerialization.jsonObject(with: Data(a.utf8))
        let objB = try? JSONSerialization.jsonObject(with: Data(b.utf8))
        XCTAssertEqual(objA as? NSObject, objB as? NSObject, message)
    }

    func testScalarRoundTrip() throws {
        XCTAssertEqual(try roundTrip("21081"), "21081")                       // int 保持 int
        XCTAssertEqual(try roundTrip("\"auto\""), "\"auto\"")
        XCTAssertEqual(try roundTrip("true"), "true")
        XCTAssertEqual(try roundTrip("null"), "null")
        assertSemanticEqual(try roundTrip("15.5"), "15.5")
    }

    func testIntNotAbsorbedByDouble() throws {
        // 600（无小数点）解码为 int，编码回 600
        let v = try JSONDecoder().decode(JSONValue.self, from: Data("600".utf8))
        guard case .int(let i) = v else { return XCTFail("600 应为 int，实际 \(v)") }
        XCTAssertEqual(i, 600)
        // 15.0：Darwin JSONDecoder 的 NSNumber 桥接可能把整值小数读成 int——
        // JSON 数字本无 int/double 之分，语义等价即可（15 == 15.0）。
        let d = try JSONDecoder().decode(JSONValue.self, from: Data("15.0".utf8))
        XCTAssertEqual(d.double, 15.0)
        assertSemanticEqual(try roundTrip("15.0"), "15.0")
        // 15.5（真小数）绝不能被 int 截断吞掉
        let frac = try JSONDecoder().decode(JSONValue.self, from: Data("15.5".utf8))
        guard case .double(let f) = frac, f == 15.5 else {
            return XCTFail("15.5 应为 double(15.5)，实际 \(frac)")
        }
    }

    func testNestedRoundTrip() throws {
        let json = #"{"a":[1,"x",true,{"b":null}],"c":{"d":2.5}}"#
        assertSemanticEqual(try roundTrip(json), json, "嵌套结构往返应语义相等")
    }

    func testLenientAccessors() {
        XCTAssertEqual(JSONValue.string("x").string, "x")
        XCTAssertNil(JSONValue.string("x").int)
        XCTAssertEqual(JSONValue.int(7).double, 7.0)
        XCTAssertEqual(JSONValue.double(8).int, 8)          // 整值 double 可读 int
        XCTAssertNil(JSONValue.double(8.5).int)             // 非整值不可读 int
        XCTAssertEqual(JSONValue.array([.string("a"), .int(1)]).stringArray, ["a"])  // 混合数组取字符串项
        XCTAssertNil(JSONValue.object(["a": .int(1)]).stringDict)  // 值非字符串 → 整体 nil
    }
}

// MARK: - SidecarConfig 未知键往返保留（⭐ 任务硬约束）

final class SidecarConfigRoundTripTests: XCTestCase {

    /// 模拟真实 GET /api/config 响应：已知键 + 三类未知键（字符串/数字/嵌套对象数组）。
    private let sampleResponse = """
    {
        "default_model": "qwen3.8",
        "data_root": "~/.subagent",
        "max_tool_rounds": 200,
        "proxy_http_port": 21081,
        "network_switch": "auto",
        "heartbeat_interval": 15.0,
        "auth_confirm_timeout": 600,
        "compact_keep_recent": 10,
        "model_parallel": false,
        "delegation_model_swap": true,
        "auto_create_sub_agents": true,
        "confirm_network_install": true,
        "plugin_repos": ["https://github.com/a/b"],
        "egress_proxy_required": ["openai.com", "*.github.com"],
        "app_control_confirm": ["workflow_run", "roundtable_create"],
        "computer_use_app_whitelist": ["Finder"],
        "model_strengths": {"qwen3.8": "长文推理"},
        "auth_grants": [{"tool": "fs_delete", "action": "delete", "granted_at": "2026-09-01T10:00:00"}],
        "ctx_lazy_enabled": true,
        "ctx_lazy_start": 12288,
        "future_feature_flag": true,
        "future_limit": 42,
        "future_nested": {"x": [1, 2, {"y": "z"}], "w": null}
    }
    """

    /// ⭐ 核心：解码 → 再编码，未知键一个不少、值不变。
    func testUnknownKeysSurviveRoundTrip() throws {
        let cfg = try JSONDecoder().decode(SidecarConfig.self, from: Data(sampleResponse.utf8))
        // 未知键被识别
        XCTAssertEqual(cfg.unknownKeys, ["future_feature_flag", "future_limit", "future_nested"])

        let data = try JSONEncoder().encode(cfg)
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])

        // 未知键原样保留
        XCTAssertEqual(obj["future_feature_flag"] as? Bool, true)
        XCTAssertEqual(obj["future_limit"] as? NSNumber, 42)
        let nested = try XCTUnwrap(obj["future_nested"] as? [String: Any])
        XCTAssertEqual((nested["x"] as? [Any])?.count, 3)
        XCTAssertTrue(nested["w"] is NSNull)

        // 已知键也无损
        XCTAssertEqual(obj["default_model"] as? String, "qwen3.8")
        XCTAssertEqual(obj["max_tool_rounds"] as? NSNumber, 200)
        XCTAssertEqual(obj["heartbeat_interval"] as? NSNumber, 15.0)
        XCTAssertEqual(obj["app_control_confirm"] as? [String], ["workflow_run", "roundtable_create"])
    }

    /// 编辑已知键 → 编码后未知键仍保留（编辑不丢键）。
    func testEditingKnownKeyKeepsUnknownKeys() throws {
        var cfg = try JSONDecoder().decode(SidecarConfig.self, from: Data(sampleResponse.utf8))
        cfg.maxToolRounds = 300
        cfg.pluginRepos = []
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(cfg)) as? [String: Any])
        XCTAssertEqual(obj["max_tool_rounds"] as? NSNumber, 300)
        XCTAssertEqual(obj["plugin_repos"] as? [String], [])
        XCTAssertEqual(obj["future_feature_flag"] as? Bool, true)
        XCTAssertNotNil(obj["future_nested"])
    }

    /// 类型化访问器默认值（逐条对齐 tsx 的 ?? 兜底）。
    func testTypedAccessorDefaults() {
        let cfg = SidecarConfig()
        XCTAssertEqual(cfg.maxToolRounds, 200)
        XCTAssertEqual(cfg.reconnectMaxAttempts, 3)
        XCTAssertEqual(cfg.heartbeatInterval, 15)
        XCTAssertEqual(cfg.authConfirmTimeout, 600)
        XCTAssertEqual(cfg.compactKeepRecent, 10)
        XCTAssertEqual(cfg.proxyHTTPPort, 21081)
        XCTAssertFalse(cfg.modelParallel)
        XCTAssertFalse(cfg.taskConcurrency)
        XCTAssertTrue(cfg.delegationModelSwap)
        XCTAssertTrue(cfg.computerUseConfirmEach)
        XCTAssertTrue(cfg.cuElementLocateEnabled)
        XCTAssertFalse(cfg.computerUseEnabled)
        XCTAssertTrue(cfg.autoCreateSubAgents)          // !== false 口径：缺省 true
        XCTAssertFalse(cfg.visionParseAttachments)      // === true 口径：缺省 false
        XCTAssertTrue(cfg.confirmNetworkInstall)
        XCTAssertTrue(cfg.confirmModelPackDownload)
        XCTAssertEqual(cfg.networkSwitch, "auto")
        XCTAssertTrue(cfg.authGrants.isEmpty)
        XCTAssertTrue(cfg.pluginRepos.isEmpty)
    }

    /// 类型不符不炸：max_tool_rounds 被写成字符串时回退默认值，键不丢。
    func testTypeMismatchIsLenient() throws {
        let cfg = try JSONDecoder().decode(SidecarConfig.self,
            from: Data(#"{"max_tool_rounds": "oops", "auto_create_sub_agents": false}"#.utf8))
        XCTAssertEqual(cfg.maxToolRounds, 200)          // 宽松回退
        XCTAssertFalse(cfg.autoCreateSubAgents)
        XCTAssertEqual(cfg.value("max_tool_rounds"), .string("oops"))  // 原值仍在 storage
    }

    /// auth_grants 元素解码（granted_at 可缺省）+ 序列化回写。
    func testAuthGrantCodec() throws {
        let cfg = try JSONDecoder().decode(SidecarConfig.self, from: Data(sampleResponse.utf8))
        XCTAssertEqual(cfg.authGrants.count, 1)
        XCTAssertEqual(cfg.authGrants[0].tool, "fs_delete")
        XCTAssertEqual(cfg.authGrants[0].action, "delete")
        XCTAssertEqual(cfg.authGrants[0].granted_at, "2026-09-01T10:00:00")
        XCTAssertEqual(cfg.authGrants[0].id, "fs_delete|delete")

        // 缺 granted_at 的元素也能解码（后端不强校验）
        let bare = AuthGrant(json: .object(["tool": .string("t"), "action": .string("a")]))
        XCTAssertEqual(bare, AuthGrant(tool: "t", action: "a"))
        // 缺 action → nil
        XCTAssertNil(AuthGrant(json: .object(["tool": .string("t")])))
    }

    /// network_switch 显示映射（tsx L763：on→proxy，off→auto，其余原样）。
    func testNetworkSwitchDisplayMapping() {
        var cfg = SidecarConfig()
        cfg.networkSwitch = "on"
        XCTAssertEqual(cfg.networkSwitchDisplay, "proxy")
        cfg.networkSwitch = "off"
        XCTAssertEqual(cfg.networkSwitchDisplay, "auto")
        cfg.networkSwitch = "auto"
        XCTAssertEqual(cfg.networkSwitchDisplay, "auto")
        cfg.networkSwitch = "proxy"
        XCTAssertEqual(cfg.networkSwitchDisplay, "proxy")
    }

    /// patch(_:) 子集提取：只含存在的键。
    func testPatchSubset() {
        var cfg = SidecarConfig()
        cfg.allowAutoCompact = true
        cfg.compactKeepRecent = 20
        let patch = cfg.patch([SidecarConfig.Key.allowAutoCompact,
                               SidecarConfig.Key.compactKeepRecent,
                               SidecarConfig.Key.compactArchiveDir])  // 未设置 → 跳过
        XCTAssertEqual(patch.count, 2)
        XCTAssertEqual(patch[SidecarConfig.Key.allowAutoCompact], .bool(true))
        XCTAssertEqual(patch[SidecarConfig.Key.compactKeepRecent], .int(20))
    }
}

// MARK: - ConfigValidator（与 store.py _validate 同范围同文案）

final class ConfigValidatorTests: XCTestCase {

    private func err(_ key: String, _ v: JSONValue) -> String? {
        ConfigValidator.validateKey(key, value: v)
    }

    func testNumericRanges() {
        XCTAssertNil(err(SidecarConfig.Key.maxToolRounds, .int(1)))
        XCTAssertNil(err(SidecarConfig.Key.maxToolRounds, .int(1000)))
        XCTAssertEqual(err(SidecarConfig.Key.maxToolRounds, .int(0)), "max_tool_rounds 必须是 1-1000 的整数")
        XCTAssertEqual(err(SidecarConfig.Key.maxToolRounds, .int(1001)), "max_tool_rounds 必须是 1-1000 的整数")
        XCTAssertEqual(err(SidecarConfig.Key.maxToolRounds, .string("x")), "max_tool_rounds 必须是 1-1000 的整数")

        XCTAssertNil(err(SidecarConfig.Key.reconnectMaxAttempts, .int(10)))
        XCTAssertEqual(err(SidecarConfig.Key.reconnectMaxAttempts, .int(11)),
                       "reconnect_max_attempts 必须是 1-10 的整数")

        XCTAssertNil(err(SidecarConfig.Key.heartbeatInterval, .double(5)))
        XCTAssertNil(err(SidecarConfig.Key.heartbeatInterval, .int(60)))   // 后端允许 int/float
        XCTAssertEqual(err(SidecarConfig.Key.heartbeatInterval, .double(61)),
                       "heartbeat_interval 必须是 5-60 的秒数")

        XCTAssertNil(err(SidecarConfig.Key.authConfirmTimeout, .int(0)))   // 0=无限等待
        XCTAssertEqual(err(SidecarConfig.Key.authConfirmTimeout, .double(86401)),
                       "auth_confirm_timeout 必须是 0-86400 的秒数（0=无限等待）")

        XCTAssertNil(err(SidecarConfig.Key.compactKeepRecent, .int(2)))
        XCTAssertEqual(err(SidecarConfig.Key.compactKeepRecent, .int(1)),
                       "compact_keep_recent 必须是 2-100 的整数")

        XCTAssertNil(err(SidecarConfig.Key.proxyHTTPPort, .int(7890)))
        XCTAssertEqual(err(SidecarConfig.Key.proxyHTTPPort, .int(70000)),
                       "proxy_http_port 必须是 1-65535 的整数")

        XCTAssertNil(err(SidecarConfig.Key.ctxLazyStart, .int(12288)))
        XCTAssertEqual(err(SidecarConfig.Key.ctxLazyStart, .int(1000)),
                       "ctx_lazy_start 必须是 2048-1048576 的整数")
    }

    func testNonEmptyStrings() {
        XCTAssertEqual(err(SidecarConfig.Key.dataRoot, .string("  ")), "data_root 不能为空")
        XCTAssertEqual(err(SidecarConfig.Key.defaultModel, .string("")), "default_model 不能为空")
        XCTAssertNil(err(SidecarConfig.Key.defaultModel, .string("qwen3.8")))
    }

    func testNetworkSwitch() {
        XCTAssertNil(err(SidecarConfig.Key.networkSwitch, .string("proxy")))
        XCTAssertNil(err(SidecarConfig.Key.networkSwitch, .string("on")))   // 遗留值允许（后端自动迁移）
        XCTAssertNotNil(err(SidecarConfig.Key.networkSwitch, .string("bogus")))
    }

    func testCompactArchiveDir() {
        XCTAssertNil(err(SidecarConfig.Key.compactArchiveDir, .string("~/.subagent/compressed")))
        XCTAssertNil(err(SidecarConfig.Key.compactArchiveDir, .string("/tmp/x")))
        XCTAssertEqual(err(SidecarConfig.Key.compactArchiveDir, .string("relative/dir")),
                       "compact_archive_dir 必须是绝对路径或含 ~ 的合法路径")
    }

    func testModelStrengthsLimit() {
        XCTAssertNil(err(SidecarConfig.Key.modelStrengths,
                         .object(["qwen3.8": .string(String(repeating: "字", count: 100))])))
        XCTAssertEqual(err(SidecarConfig.Key.modelStrengths,
                           .object(["qwen3.8": .string(String(repeating: "字", count: 101))])),
                       "model_strengths[qwen3.8] 特长描述超过 100 字，请精简")
    }

    /// _valid_domain_entry 移植核对（普通域名 / *.通配；拒绝 IP、单标签、URL、下划线）。
    func testDomainEntries() {
        for good in ["openai.com", "*.github.com", "a-b.co.cn", "sub.domain.org"] {
            XCTAssertTrue(ConfigValidator.isValidDomainEntry(good), good)
            XCTAssertNil(err(SidecarConfig.Key.egressProxyRequired, .array([.string(good)])))
        }
        for bad in ["", "localhost", "1.2.3.4", "999.999.999", "http://x.com", "bad_domain.com", "*.com"] {
            XCTAssertFalse(ConfigValidator.isValidDomainEntry(bad), bad)
        }
        XCTAssertNotNil(err(SidecarConfig.Key.egressProxyRequired, .array([.string("1.2.3.4")])))
    }

    func testAuthGrantsStructure() {
        XCTAssertNil(err(SidecarConfig.Key.authGrants,
                         .array([AuthGrant(tool: "t", action: "a").json])))
        XCTAssertEqual(err(SidecarConfig.Key.authGrants, .array([.object(["tool": .string("t")])])),
                       "auth_grants 元素必须含非空字符串 tool 与 action")
        XCTAssertEqual(err(SidecarConfig.Key.authGrants, .string("x")),
                       "auth_grants 必须是对象数组（{tool, action, granted_at}）")
    }
}

// MARK: - ViewModel 流程（Mock 客户端注入）

/// 设置面板 Mock 客户端（SettingsPanelClient 子协议；Wave 0 基础端点借默认桩/最小实现）。
final class MockSettingsClient: SettingsPanelClient {
    let baseURL = URL(string: "http://127.0.0.1:1/api")!

    var configResult: Result<SidecarConfig, Error>
    var modelsResult: Result<[InferenceModelItem], Error> = .success([])
    var cuResult: Result<CUCapabilities, Error> = .success(CUCapabilities(ok: true, problems: [], facts: [:]))
    var compactLogResult: Result<[CompactLogEntry], Error> = .success([])

    /// 记录每次 PUT 的补丁（顺序保留）。
    private(set) var putPatches: [[String: JSONValue]] = []
    /// PUT 响应工厂：默认「补丁合并进最近配置」模拟后端 reload_config 返回新全量。
    var onUpdate: (([String: JSONValue]) -> Result<SidecarConfig, Error>)?

    init(config: SidecarConfig) { configResult = .success(config) }

    // SettingsPanelClient
    func getConfig() async throws -> SidecarConfig { try configResult.get() }
    func updateConfig(_ patch: [String: JSONValue]) async throws -> SidecarConfig {
        putPatches.append(patch)
        if let onUpdate { return try onUpdate(patch).get() }
        var merged = (try? configResult.get()) ?? SidecarConfig()
        for (k, v) in patch { merged.set(k, v) }
        configResult = .success(merged)
        return merged
    }
    func listInferenceModels() async throws -> [InferenceModelItem] { try modelsResult.get() }
    func computerUseCapabilities() async throws -> CUCapabilities { try cuResult.get() }
    func compactLog(projectId: String, sessionId: String) async throws -> [CompactLogEntry] {
        try compactLogResult.get()
    }

    // SidecarClientProtocol 最小实现（Wave 1 端点走协议缺省桩）
    func probeReady() async throws -> Bool { true }
    func listModels() async throws -> [OllamaModel] { [] }
    func listProjects() async throws -> [SidecarProject] { [] }
    func createProject(name: String, workingDir: String) async throws -> String { "p1" }
    func listAgents(projectId: String) async throws -> [SidecarAgent] { [] }
    func createAgent(projectId: String, name: String, type: String, modelName: String?) async throws -> String { "a1" }
    func listSessions(projectId: String, agentId: String) async throws -> [ChatSession] { [] }
    func createSession(projectId: String, agentId: String, title: String) async throws -> String { "s1" }
    func loadMessages(projectId: String, sessionId: String) async throws -> [ChatMessage] { [] }
    func stopChat(sessionId: String) async throws {}
    func respondAuth(_ body: AuthRespondRequest) async throws {}
    func chatStream(_ body: ChatStreamRequest) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@MainActor
final class SettingsViewModelTests: XCTestCase {

    private func makeVM(client: MockSettingsClient, sessionId: String? = nil) -> SettingsViewModel {
        SettingsViewModel(
            clientProvider: { client },
            sessionIdProvider: { sessionId },
            logger: AppLogger(logDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("vetarai-test-logs-\(UUID().uuidString)"))
        )
    }

    private func sampleConfig() -> SidecarConfig {
        try! JSONDecoder().decode(SidecarConfig.self, from: Data("""
        {
            "default_model": "qwen3.8",
            "data_root": "~/.subagent",
            "max_tool_rounds": 200,
            "proxy_http_port": 21081,
            "network_switch": "auto",
            "compact_archive_dir": "~/.subagent/compressed",
            "allow_auto_compact": false,
            "compact_keep_recent": 10,
            "auth_grants": [
                {"tool": "fs_delete", "action": "delete", "granted_at": "2026-09-01T10:00:00"},
                {"tool": "app_control", "action": "workflow_run"}
            ],
            "plugin_repos": ["https://github.com/a/b"],
            "future_unknown_key": {"keep": "me"}
        }
        """.utf8))
    }

    // load 成功：config 就位 + 数值草稿回灌
    func testLoadPopulatesConfigAndDrafts() async {
        let client = MockSettingsClient(config: sampleConfig())
        let vm = makeVM(client: client)
        await vm.load()
        XCTAssertEqual(vm.config?.defaultModel, "qwen3.8")
        XCTAssertEqual(vm.draftMaxToolRounds, "200")
        XCTAssertEqual(vm.draftAuthConfirmTimeout, "600")
        XCTAssertEqual(vm.config?.authGrants.count, 2)
        XCTAssertNil(vm.errorMessage)
    }

    // load 失败：文案「读取配置失败: …」（P3-W6 原生口径）
    func testLoadFailureMessage() async {
        let client = MockSettingsClient(config: sampleConfig())
        client.configResult = .failure(SidecarError.offline("内核不可用"))
        let vm = makeVM(client: client)
        await vm.load()
        XCTAssertNil(vm.config)
        XCTAssertTrue(vm.errorMessage?.hasPrefix("读取配置失败: ") == true)
    }

    // 勾选即存：单键补丁 + 默认成功文案
    func testToggleSavesSingleKeyPatch() async {
        let client = MockSettingsClient(config: sampleConfig())
        let vm = makeVM(client: client)
        await vm.load()
        vm.saveBool(SidecarConfig.Key.allowAutoCompact, true)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(client.putPatches.count, 1)
        XCTAssertEqual(client.putPatches[0], [SidecarConfig.Key.allowAutoCompact: .bool(true)])
        XCTAssertEqual(vm.message, "已保存（端口类改动需重启应用生效）")
        XCTAssertEqual(vm.config?.allowAutoCompact, true)
    }

    // 保存全部：整包回写（含未知键透传 + 数值草稿转换）
    func testSaveAllSendsWholeConfigIncludingUnknownKeys() async {
        let client = MockSettingsClient(config: sampleConfig())
        let vm = makeVM(client: client)
        await vm.load()
        vm.draftMaxToolRounds = "300"
        vm.setDraftString(SidecarConfig.Key.dataRoot, "/tmp/newroot")
        await vm.saveAll()
        let patch = client.putPatches.last
        XCTAssertEqual(patch?["max_tool_rounds"], .int(300))
        XCTAssertEqual(patch?["data_root"], .string("/tmp/newroot"))
        // ⭐ 未知键随整包回写，不丢
        XCTAssertEqual(patch?["future_unknown_key"], .object(["keep": .string("me")]))
        XCTAssertEqual(vm.config?.maxToolRounds, 300)
    }

    // 保存全部：非法数值拦截（不进网络层）
    func testSaveAllRejectsInvalidNumber() async {
        let client = MockSettingsClient(config: sampleConfig())
        let vm = makeVM(client: client)
        await vm.load()
        vm.draftMaxToolRounds = "9999"
        await vm.saveAll()
        XCTAssertTrue(client.putPatches.isEmpty, "越界值不应发出 PUT")
        XCTAssertEqual(vm.errorMessage, "max_tool_rounds 必须是 1-1000 的整数")
    }

    // 保存全部：非数字拦截
    func testSaveAllRejectsNonNumeric() async {
        let client = MockSettingsClient(config: sampleConfig())
        let vm = makeVM(client: client)
        await vm.load()
        vm.draftHeartbeatInterval = "abc"
        await vm.saveAll()
        XCTAssertTrue(client.putPatches.isEmpty)
        XCTAssertEqual(vm.errorMessage, "heartbeat_interval 必须是数字")
    }

    // auth_grants 逐条移除：写回过滤后的完整数组（0.4.33 R2 口径）
    func testRemoveAuthGrant() async {
        let client = MockSettingsClient(config: sampleConfig())
        let vm = makeVM(client: client)
        await vm.load()
        let first = vm.config!.authGrants[0]
        vm.removeAuthGrant(first)
        try? await Task.sleep(nanoseconds: 100_000_000)
        let patch = client.putPatches.last
        XCTAssertEqual(patch?["auth_grants"],
                       .array([AuthGrant(tool: "app_control", action: "workflow_run").json]))
        XCTAssertEqual(vm.config?.authGrants.count, 1)
        XCTAssertEqual(vm.config?.authGrants.first?.tool, "app_control")
    }

    // 「需代理」名单追加：独立成功文案 + 输入框清空
    func testAddProxyRequiredCustomMessage() async {
        let client = MockSettingsClient(config: sampleConfig())
        let vm = makeVM(client: client)
        await vm.load()
        vm.newProxyRequired = " openai.com "
        vm.addProxyRequired()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(client.putPatches.last?["egress_proxy_required"],
                       .array([.string("openai.com")]))
        XCTAssertEqual(vm.message, "已加入「需代理」名单：标准模式下将不再尝试直连该域名")
        XCTAssertEqual(vm.newProxyRequired, "")
    }

    // 「需代理」名单追加：非法域名本地拦截（错误前缀同 tsx）
    func testAddProxyRequiredInvalidDomain() async {
        let client = MockSettingsClient(config: sampleConfig())
        let vm = makeVM(client: client)
        await vm.load()
        vm.newProxyRequired = "1.2.3.4"
        vm.addProxyRequired()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(client.putPatches.isEmpty)
        XCTAssertTrue(vm.errorMessage?.hasPrefix("加入「需代理」名单失败: ") == true)
    }

    // 插件仓库增删
    func testPluginRepoAddRemove() async {
        let client = MockSettingsClient(config: sampleConfig())
        let vm = makeVM(client: client)
        await vm.load()
        vm.newRepo = "https://github.com/c/d"
        vm.addPluginRepo()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(vm.config?.pluginRepos, ["https://github.com/a/b", "https://github.com/c/d"])
        vm.removePluginRepo("https://github.com/a/b")
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(vm.config?.pluginRepos, ["https://github.com/c/d"])
        XCTAssertEqual(client.putPatches.count, 2)
    }

    // 应用内模块控制动作勾选/取消
    func testAppControlConfirmToggle() async {
        let client = MockSettingsClient(config: sampleConfig())
        let vm = makeVM(client: client)
        await vm.load()
        vm.setAppControlConfirm("workflow_run", on: true)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(vm.config?.appControlConfirm, ["workflow_run"])
        vm.setAppControlConfirm("workflow_run", on: false)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(vm.config?.appControlConfirm, [])
        vm.setAppControlConfirm("knowledge_search", on: true)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(client.putPatches.last?["app_control_confirm"], .array([.string("knowledge_search")]))
    }

    // 网络模式切换：立即保存 + storage 更新
    func testNetworkSwitchSave() async {
        let client = MockSettingsClient(config: sampleConfig())
        let vm = makeVM(client: client)
        await vm.load()
        vm.saveNetworkSwitch("proxy")
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(client.putPatches.last?["network_switch"], .string("proxy"))
        XCTAssertEqual(vm.config?.networkSwitch, "proxy")
    }

    // 模型特长：100 字截断 + 空串删除 + 独立保存
    func testStrengthsDraftRules() async {
        let client = MockSettingsClient(config: sampleConfig())
        let vm = makeVM(client: client)
        await vm.load()
        vm.setStrength("qwen3.8", String(repeating: "字", count: 120))
        XCTAssertEqual(vm.strengthsDraft["qwen3.8"]?.count, 100, "单条限 100 字截断")
        vm.setStrength("qwen3.8", "   ")
        XCTAssertNil(vm.strengthsDraft["qwen3.8"], "空白 = 删除该模型记录")
        vm.setStrength("ocr-model", "OCR/图片转写专用")
        await vm.saveStrengths()
        XCTAssertEqual(client.putPatches.last?["model_strengths"],
                       .object(["ocr-model": .string("OCR/图片转写专用")]))
    }

    // 保存响应只回灌涉及键：勾选无关开关不打断数值输入草稿
    func testUnrelatedSaveDoesNotClobberDrafts() async {
        let client = MockSettingsClient(config: sampleConfig())
        let vm = makeVM(client: client)
        await vm.load()
        vm.draftMaxToolRounds = "333"            // 用户正在改，尚未保存
        vm.saveBool(SidecarConfig.Key.modelParallel, true)   // 无关开关即存
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(vm.draftMaxToolRounds, "333", "无关开关的保存响应不得覆盖输入中草稿")
    }

    // 保存失败：后端 400 detail 上屏（SidecarError.describe 口径）
    func testSaveFailureSurfacesBackendDetail() async {
        let client = MockSettingsClient(config: sampleConfig())
        client.onUpdate = { _ in
            .failure(SidecarError.httpError(status: 400, detail: "未知配置项: bogus"))
        }
        let vm = makeVM(client: client)
        await vm.load()
        vm.saveBool(SidecarConfig.Key.modelParallel, true)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(vm.errorMessage, "HTTP 400：未知配置项: bogus")
        XCTAssertNil(vm.message)
    }

    // 压缩记录：无当前会话 → []（渲染「暂无压缩记录」）；有会话 → 读取
    func testCompactLogLoading() async {
        let client = MockSettingsClient(config: sampleConfig())
        client.compactLogResult = .success([
            CompactLogEntry(ts: "2026-09-01 10:00", beforeTokens: 9000, afterTokens: 1200,
                            archivePath: nil, error: nil),
        ])
        let vmNoSession = makeVM(client: client, sessionId: nil)
        vmNoSession.loadCompactLogs()
        XCTAssertEqual(vmNoSession.compactLogs, [])

        let vm = makeVM(client: client, sessionId: "s1")
        vm.loadCompactLogs()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(vm.compactLogs?.count, 1)
        XCTAssertEqual(vm.compactLogs?.first?.beforeTokens, 9000)
    }

    // CU 探测：成功/失败两路
    func testCUProbe() async {
        let client = MockSettingsClient(config: sampleConfig())
        client.cuResult = .success(CUCapabilities(
            ok: false, problems: ["缺辅助功能权限"],
            facts: ["accessibility_trusted": .bool(false), "retina_scale": .int(2)]))
        let vm = makeVM(client: client)
        await vm.probeCU()
        XCTAssertEqual(vm.cuCapabilities?.ok, false)
        XCTAssertEqual(vm.cuCapabilities?.problems, ["缺辅助功能权限"])
        XCTAssertEqual(vm.cuCapabilities?.factBool("accessibility_trusted"), false)
        XCTAssertNil(vm.cuCapabilities?.factBool("screen_capture_access"))   // 三态：缺省=nil
        XCTAssertEqual(vm.cuCapabilities?.factString("retina_scale"), "2")

        client.cuResult = .failure(SidecarError.offline("侧车未运行"))
        await vm.probeCU()
        XCTAssertEqual(vm.cuCapabilities?.ok, false)
        XCTAssertTrue(vm.cuCapabilities?.problems.first?.contains("探测失败") == true)
    }

    // 模型列表：失败回退空列表（手动输入路径）
    func testLoadModelsFailureFallback() async {
        let client = MockSettingsClient(config: sampleConfig())
        client.modelsResult = .success([InferenceModelItem(name: "qwen3.8"), InferenceModelItem(name: "bge-m3")])
        let vm = makeVM(client: client)
        await vm.loadModels()
        XCTAssertEqual(vm.modelOptions, ["qwen3.8", "bge-m3"])
        client.modelsResult = .failure(SidecarError.httpError(status: 502, detail: "推理后端不可达"))
        await vm.loadModels()
        XCTAssertEqual(vm.modelOptions, [])
    }

    // 上下文管理分区保存：只发三个键
    func testSaveContextSectionSendsThreeKeys() async {
        let client = MockSettingsClient(config: sampleConfig())
        let vm = makeVM(client: client)
        await vm.load()
        vm.draftCompactKeepRecent = "20"
        await vm.saveContextSection()
        let patch = client.putPatches.last
        XCTAssertEqual(patch?.keys.sorted(),
                       ["allow_auto_compact", "compact_archive_dir", "compact_keep_recent"])
        XCTAssertEqual(patch?["compact_keep_recent"], .int(20))
    }
}
