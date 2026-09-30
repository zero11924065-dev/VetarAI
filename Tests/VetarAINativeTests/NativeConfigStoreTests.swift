//
//  NativeConfigStoreTests.swift
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

//  逐条对照 subagent/sidecar/config/store.py（注释标 Python 侧行号）；
//  含 subagent/sidecar/test_config.py（L1 原子写专项）的 XCTest 翻译
//  （关键用例注释标 Python 侧出处行号）。
//
//  覆盖：默认值合并 / 未知键往返保留 / 遗留迁移 / 校验文案逐字 /
//        Python isinstance 怪癖 / 原子写（含注入失败）/ 路径解析链。
//

import XCTest
@testable import VetarAINative

final class NativeConfigStoreTests: XCTestCase {

    private var tmp: URL!
    private var store: NativeConfigStore!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("w0cfg_\(UUID().uuidString)")
        // 先建目录：部分用例直接向 tmp/config.json 写文件
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        store = NativeConfigStore(environment: ["VETARAI_DATA_ROOT": tmp.path])
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    // MARK: - DEFAULT_CONFIG（store.py L41-186）

    func testDefaultConfigKeyCountAndOrder() {
        // 55 键（0.7.5 W13 末位新增 error_analysis_timeout_s）；前 54 键顺序即
        // Python dict 插入序（写盘字节可比的前提），新增键排最末不影响既有键序
        XCTAssertEqual(NativeConfigStore.defaultKeys.count, 55)
        XCTAssertEqual(Set(NativeConfigStore.defaultKeys), Set(NativeConfigStore.defaultConfig.keys))
        XCTAssertEqual(NativeConfigStore.defaultKeys.prefix(5),
                       ["ollama_base_url", "proxy_http_port", "proxy_socks_port", "data_root", "default_model"])
        XCTAssertEqual(NativeConfigStore.defaultKeys.suffix(3),
                       ["confirm_model_pack_download", "model_pack_boot_timeout_s", "error_analysis_timeout_s"])
    }

    func testDefaultValues() {
        let d = NativeConfigStore.defaultConfig
        XCTAssertEqual(d["ollama_base_url"], .string("http://localhost:11434"))
        XCTAssertEqual(d["sidecar_port"], .int(8765))
        XCTAssertEqual(d["network_switch"], .string("auto"))
        XCTAssertEqual(d["heartbeat_interval"], .double(15.0))
        XCTAssertEqual(d["max_tool_rounds"], .int(200))
        XCTAssertEqual(d["ctx_lazy_start"], .int(12288))
        XCTAssertEqual(d["auto_create_sub_agents"], .bool(true))
        XCTAssertEqual(d["app_control_confirm"],
                       .array([.string("workflow_run"), .string("roundtable_create")]))
        XCTAssertEqual(d["auth_grants"], .array([]))
    }

    // MARK: - get_config（store.py L461-488）

    func testGetConfigInitializesFileWithDefaults() throws {
        let cfg = try store.getConfig()
        XCTAssertEqual(cfg.count, 55)   // 0.7.5 W13：+error_analysis_timeout_s
        // 首次运行写盘（missing 补写）
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("config.json").path))
        // 二次读取不漂移（幂等）
        let cfg2 = try store.getConfig()
        XCTAssertEqual(cfg, cfg2)
    }

    /// 未知键往返保留（0.4.34 教训；get_config 合并含磁盘未知键并随写回保留）。
    func testUnknownKeysSurviveRoundtrip() throws {
        let path = tmp.appendingPathComponent("config.json")
        try """
        {"data_root": "~/.subagent", "future_plugin_flag": {"x": 1}, "zzz_unknown": [1, 2]}
        """.write(to: path, atomically: false, encoding: .utf8)
        let cfg = try store.getConfig()
        XCTAssertEqual(cfg["future_plugin_flag"], .object(["x": .int(1)]))
        XCTAssertEqual(cfg["zzz_unknown"], .array([.int(1), .int(2)]))
        // 触发写盘（missing 补写）后未知键仍在磁盘上
        let onDisk = try JSONDecoder().decode([String: JSONValue].self,
                                              from: Data(contentsOf: path))
        XCTAssertEqual(onDisk["future_plugin_flag"], .object(["x": .int(1)]))
        XCTAssertEqual(onDisk["zzz_unknown"], .array([.int(1), .int(2)]))
    }

    /// 磁盘 config.json 损坏 → 按空处理（_load_from_disk except 告警路径，L242-243）。
    func testCorruptConfigFallsBackToDefaults() throws {
        try "{ not json".write(to: tmp.appendingPathComponent("config.json"),
                               atomically: false, encoding: .utf8)
        let cfg = try store.getConfig()
        XCTAssertEqual(cfg["default_model"], .string("qwen3.8"))
        // 数组而非对象 → 同样按空处理（L240 isinstance dict 检查）
        try "[1,2]".write(to: tmp.appendingPathComponent("config.json"),
                          atomically: false, encoding: .utf8)
        _ = try store.getConfig()
    }

    /// network_switch 遗留值迁移（L469-473：off→auto / on→proxy，幂等写回）。
    func testNetworkSwitchLegacyMigration() throws {
        let path = tmp.appendingPathComponent("config.json")
        try #"{"network_switch": "off"}"#.write(to: path, atomically: false, encoding: .utf8)
        var cfg = try store.getConfig()
        XCTAssertEqual(cfg["network_switch"], .string("auto"))
        var onDisk = String(data: try Data(contentsOf: path), encoding: .utf8)!
        XCTAssertTrue(onDisk.contains("\"auto\""))
        try #"{"network_switch": "on"}"#.write(to: path, atomically: false, encoding: .utf8)
        cfg = try store.getConfig()
        XCTAssertEqual(cfg["network_switch"], .string("proxy"))
        onDisk = String(data: try Data(contentsOf: path), encoding: .utf8)!
        XCTAssertTrue(onDisk.contains("\"proxy\""))
    }

    /// 废弃键清除（L480-484：plugins_enabled/skills_enabled/egress_allowlist 只删不迁移）。
    func testLegacyKeysPurged() throws {
        let path = tmp.appendingPathComponent("config.json")
        try """
        {"plugins_enabled": false, "skills_enabled": true,
         "egress_allowlist": ["example.com"], "egress_proxy_required": []}
        """.write(to: path, atomically: false, encoding: .utf8)
        let cfg = try store.getConfig()
        XCTAssertNil(cfg["plugins_enabled"])
        XCTAssertNil(cfg["skills_enabled"])
        XCTAssertNil(cfg["egress_allowlist"])
        // 白名单条目**不得**搬进需代理名单（语义相反，L476-479）
        XCTAssertEqual(cfg["egress_proxy_required"], .array([]))
        let onDisk = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: path))
        XCTAssertNil(onDisk["plugins_enabled"])
        XCTAssertNil(onDisk["egress_allowlist"])
    }

    // MARK: - reload_config（store.py L491-520）

    func testReloadConfigMergesPatch() throws {
        let cfg = try store.reloadConfig(patch: ["max_tool_rounds": .int(250),
                                                 "network_switch": .string("proxy")])
        XCTAssertEqual(cfg["max_tool_rounds"], .int(250))
        XCTAssertEqual(cfg["network_switch"], .string("proxy"))
        XCTAssertEqual(cfg["default_model"], .string("qwen3.8"))   // 未动键保留
        // 磁盘回读一致
        let back = try store.getConfig()
        XCTAssertEqual(back["max_tool_rounds"], .int(250))
    }

    /// 未知键拒绝（L500-501：「未知配置项: k」）。
    func testReloadConfigRejectsUnknownKey() {
        XCTAssertThrowsError(try store.reloadConfig(patch: ["not_a_key": .int(1)])) { err in
            guard case .invalidConfig(let msg) = err as? NativeCoreError else {
                return XCTFail("应为 invalidConfig，实际 \(err)")
            }
            XCTAssertEqual(msg, "未知配置项: not_a_key")
        }
    }

    // MARK: - _validate 文案逐字（store.py L291-458）

    private func assertInvalid(_ patch: [String: JSONValue], _ expect: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try store.reloadConfig(patch: patch), file: file, line: line) { err in
            guard case .invalidConfig(let msg) = err as? NativeCoreError else {
                return XCTFail("应为 invalidConfig，实际 \(err)", file: file, line: line)
            }
            XCTAssertEqual(msg, expect, file: file, line: line)
        }
    }

    func testValidatePorts() {
        assertInvalid(["sidecar_port": .int(0)], "sidecar_port 必须是 1-65535 的整数")
        assertInvalid(["vite_port": .int(70000)], "vite_port 必须是 1-65535 的整数")
        assertInvalid(["proxy_http_port": .double(1.5)], "proxy_http_port 必须是 1-65535 的整数")
        assertInvalid(["proxy_socks_port": .string("21080")], "proxy_socks_port 必须是 1-65535 的整数")
    }

    /// Python 怪癖保真：isinstance(True, int)==True → sidecar_port=true 按 1 通过（L295-298 未排 bool）。
    func testValidatePortBoolQuirkAccepted() throws {
        let cfg = try store.reloadConfig(patch: ["sidecar_port": .bool(true)])
        XCTAssertEqual(cfg["sidecar_port"], .bool(true))   // 原样落库（1 的布尔形态）
    }

    /// 同怪癖：max_tool_rounds=true 按 1 通过（L317-319 未排 bool）。
    func testValidateMaxToolRoundsBoolQuirkAccepted() throws {
        _ = try store.reloadConfig(patch: ["max_tool_rounds": .bool(true)])
    }

    /// 对照组：reconnect_max_attempts 显式排 bool（L336-338）。
    func testValidateReconnectBoolRejected() {
        assertInvalid(["reconnect_max_attempts": .bool(true)], "reconnect_max_attempts 必须是 1-10 的整数")
        assertInvalid(["reconnect_max_attempts": .int(0)], "reconnect_max_attempts 必须是 1-10 的整数")
        assertInvalid(["reconnect_max_attempts": .int(11)], "reconnect_max_attempts 必须是 1-10 的整数")
    }

    func testValidateBasics() {
        assertInvalid(["ollama_base_url": .string("ftp://x")], "ollama_base_url 必须是 http(s):// 地址")
        assertInvalid(["data_root": .string("  ")], "data_root 不能为空")
        assertInvalid(["default_model": .string("")], "default_model 不能为空")
        assertInvalid(["plugin_repos": .array([.int(1)])], "plugin_repos 必须是字符串数组")
        assertInvalid(["network_switch": .string("wifi")],
                      "network_switch 必须是 auto/proxy（遗留值 on/off 会自动迁移）")
        assertInvalid(["max_tool_rounds": .int(0)], "max_tool_rounds 必须是 1-1000 的整数")
        assertInvalid(["max_tool_rounds": .int(1001)], "max_tool_rounds 必须是 1-1000 的整数")
        assertInvalid(["compact_archive_dir": .string("relative/path")],
                      "compact_archive_dir 必须是绝对路径或含 ~ 的合法路径")
        assertInvalid(["allow_auto_compact": .int(1)], "allow_auto_compact 必须是 bool")
        assertInvalid(["compact_keep_recent": .int(1)], "compact_keep_recent 必须是 2-100 的整数")
        assertInvalid(["auto_create_sub_agents": .int(0)], "auto_create_sub_agents 必须是 bool")
        assertInvalid(["heartbeat_interval": .double(4.9)], "heartbeat_interval 必须是 5-60 的秒数")
        assertInvalid(["heartbeat_interval": .bool(true)], "heartbeat_interval 必须是 5-60 的秒数")
        assertInvalid(["inference_backend": .string("vllm")],
                      "inference_backend 必须是 ollama、openai_compatible 或 model_package")
        assertInvalid(["openai_compat_supports_tools": .int(1)], "openai_compat_supports_tools 必须是 bool")
        assertInvalid(["ctx_lazy_enabled": .int(1)], "ctx_lazy_enabled 必须是 bool")
        assertInvalid(["ctx_lazy_start": .int(2047)], "ctx_lazy_start 必须是 2048-1048576 的整数")
        assertInvalid(["ctx_lazy_start": .bool(true)], "ctx_lazy_start 必须是 2048-1048576 的整数")
        assertInvalid(["default_export_dir": .int(3)], "default_export_dir 必须是字符串（空=项目工作目录）")
        assertInvalid(["vision_parse_attachments": .string("yes")], "vision_parse_attachments 必须是 bool")
        assertInvalid(["delegation_activity_timeout": .double(-1)],
                      "delegation_activity_timeout 必须是 0-86400 的秒数（0=关闭）")
        assertInvalid(["auth_confirm_timeout": .int(86401)],
                      "auth_confirm_timeout 必须是 0-86400 的秒数（0=无限等待）")
        assertInvalid(["cu_user_record_max_seconds": .int(9)],
                      "cu_user_record_max_seconds 必须是 10-86400 的秒数")
        assertInvalid(["delegation_max_retries": .int(11)],
                      "delegation_max_retries 必须是 0-10 的整数（0=不限）")
        assertInvalid(["delegation_max_retries": .bool(true)],
                      "delegation_max_retries 必须是 0-10 的整数（0=不限）")
        assertInvalid(["model_parallel": .string("yes")], "model_parallel 必须是 bool")
        assertInvalid(["error_analysis_model": .int(1)],
                      "error_analysis_model 必须是字符串（模型名，空=用默认模型）")
        assertInvalid(["app_control_confirm": .string("x")],
                      "app_control_confirm 必须是字符串数组（需确认的动作名）")
        assertInvalid(["computer_use_app_whitelist": .string("x")],
                      "computer_use_app_whitelist 必须是字符串数组（应用名）")
        assertInvalid(["model_packs_dir": .string("relative/dir")],
                      "model_packs_dir 必须是绝对路径或 ~ 开头（空 = 默认安装根）")
        assertInvalid(["model_pack_boot_timeout_s": .int(7201)],
                      "model_pack_boot_timeout_s 必须是 10-7200 的秒数")
        assertInvalid(["model_pack_boot_timeout_s": .bool(true)],
                      "model_pack_boot_timeout_s 必须是 10-7200 的秒数")
    }

    func testValidateOpenAICompatibleRequiresBaseURL() {
        assertInvalid(["inference_backend": .string("openai_compatible")],
                      "openai_compatible 后端必须填写 inference_base_url（如 http://localhost:1234/v1）")
        // 补上 base_url 即通过
        XCTAssertNoThrow(try store.reloadConfig(patch: [
            "inference_backend": .string("openai_compatible"),
            "inference_base_url": .string("http://localhost:1234/v1"),
        ]))
        // model_package 不要求 base_url（L348-350）
        XCTAssertNoThrow(try store.reloadConfig(patch: [
            "inference_backend": .string("model_package"),
            "inference_base_url": .string(""),
        ]))
    }

    func testValidateEgressProxyRequired() {
        assertInvalid(["egress_proxy_required": .string("x")], "egress_proxy_required 必须是字符串数组")
        assertInvalid(["egress_proxy_required": .array([.string("1.2.3.4")])],
                      "egress_proxy_required 含非法域名: '1.2.3.4'（需为合法域名，支持 *.xxx 通配）")
        assertInvalid(["egress_proxy_required": .array([.string("bad_host.com")])],
                      "egress_proxy_required 含非法域名: 'bad_host.com'（需为合法域名，支持 *.xxx 通配）")
        // 合法：普通域名 + 通配
        XCTAssertNoThrow(try store.reloadConfig(patch: [
            "egress_proxy_required": .array([.string("google.com"), .string("*.qq.com")]),
        ]))
    }

    func testValidateAuthGrants() {
        assertInvalid(["auth_grants": .array([.string("x")])],
                      "auth_grants 必须是对象数组（{tool, action, granted_at}）")
        assertInvalid(["auth_grants": .array([.object(["tool": .string("t")])])],
                      "auth_grants 元素必须含非空字符串 tool 与 action")
        XCTAssertNoThrow(try store.reloadConfig(patch: [
            "auth_grants": .array([.object(["tool": .string("web_search"),
                                            "action": .string("search"),
                                            "granted_at": .string("2026-01-01T00:00:00")])]),
        ]))
    }

    func testValidateModelStrengths() {
        assertInvalid(["model_strengths": .array([])],
                      "model_strengths 必须是 {模型名: 特长描述} 的字符串字典")
        let long = String(repeating: "长", count: 101)
        assertInvalid(["model_strengths": .object(["qwen3.8": .string(long)])],
                      "model_strengths[qwen3.8] 特长描述超过 100 字，请精简")
    }

    // MARK: - infer_options 校验（ollama/infer_options.py L390-434）

    func testValidateTimeouts() {
        // timeout_validate：0 合法（=默认）；范围内合法；超界报错（:g 格式化文案）
        XCTAssertNoThrow(try store.reloadConfig(patch: ["timeout_connect": .int(0)]))
        XCTAssertNoThrow(try store.reloadConfig(patch: ["timeout_reading": .double(600.5)]))
        assertInvalid(["timeout_connect": .int(601)],
                      "timeout_connect 必须在 1~600 秒之间（0=用默认值 10）")
        assertInvalid(["timeout_reading": .double(0.5)],
                      "timeout_reading 必须在 10~7200 秒之间（0=用默认值 300）")
        assertInvalid(["timeout_stream_reading": .int(7201)],
                      "timeout_stream_reading 必须在 10~7200 秒之间（0=用默认值 1800）")
        // M11（0.7.4）：范围对齐两连接器 10~7200——10 秒段现在合法可写
        XCTAssertNoThrow(try store.reloadConfig(patch: ["timeout_stream_reading": .int(15)]))
        // 怪癖保真：数值字符串 float("300") 合法（_to_float 宽松）
        XCTAssertNoThrow(try store.reloadConfig(patch: ["timeout_connect": .string("30")]))
        assertInvalid(["timeout_connect": .string("abc")], "timeout_connect 必须是数值（秒）")
        assertInvalid(["timeout_connect": .bool(true)], "timeout_connect 必须是数值（秒）")
    }

    func testValidateModelOptions() {
        assertInvalid(["model_options": .array([])], "model_options 必须是 {模型名: {参数名: 值}} 的字典")
        assertInvalid(["model_options": .object(["": .object([:])])], "model_options 的键必须是非空模型名")
        assertInvalid(["model_options": .object(["qwen": .int(1)])], "model_options['qwen'] 必须是参数字典")
        assertInvalid(["model_options": .object(["qwen": .object(["bogus": .int(1)])])],
                      "model_options['qwen'] 含未知参数 'bogus'（可用：num_ctx, num_predict, repeat_penalty, seed, stop, temperature, top_k, top_p）")
        assertInvalid(["model_options": .object(["qwen": .object(["num_ctx": .int(100)])])],
                      "model_options['qwen'].num_ctx 的值非法：100，合法范围 256~1048576")
        assertInvalid(["model_options": .object(["qwen": .object(["temperature": .double(2.5)])])],
                      "model_options['qwen'].temperature 的值非法：2.5，合法范围 0.0~2.0")
        assertInvalid(["model_options": .object(["qwen": .object(["stop": .string("")])])],
                      "model_options['qwen'].stop 的值非法：''（须为字符串或字符串数组）")
        // 合法形态
        XCTAssertNoThrow(try store.reloadConfig(patch: [
            "model_options": .object(["qwen3.8": .object(["num_ctx": .int(8192),
                                                          "temperature": .double(0.3),
                                                          "stop": .array([.string("<|end|>")])])]),
        ]))
    }

    // MARK: - 原子写（翻译 subagent/sidecar/test_config.py L40-71）

    /// test_config.py 用例8 前半（L48-64）：os.replace 抛异常 → config.json 仍是完整 JSON。
    func testAtomicWriteReplaceFailureKeepsOriginal() throws {
        // 先正常写一次（对齐 Python L54-56 的 good 文件）
        _ = try store.getConfig()
        let path = tmp.appendingPathComponent("config.json")
        let before = try String(data: Data(contentsOf: path), encoding: .utf8)

        store.replacer = { _, _ in throw NativeCoreError.io("simulated kill mid-write") }
        XCTAssertThrowsError(try store.reloadConfig(patch: ["max_tool_rounds": .int(99)]))
        // 原文件未被半截内容破坏
        let after = try String(data: Data(contentsOf: path), encoding: .utf8)
        XCTAssertEqual(before, after)
    }

    /// test_config.py 用例8 后半（L66-71）：正常原子写完整、无 .tmp 残留。
    func testAtomicWriteSuccessNoTmpResidue() throws {
        _ = try store.reloadConfig(patch: ["max_tool_rounds": .int(99)])
        let path = tmp.appendingPathComponent("config.json")
        let onDisk = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: path))
        XCTAssertEqual(onDisk["max_tool_rounds"], .int(99))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tmp.appendingPathComponent("config.json.tmp").path))
    }

    // MARK: - data_root 解析链（store.py L195-215）

    func testDataRootResolutionPriority() throws {
        // env 优先
        XCTAssertEqual(store.dataRoot().path, tmp.path)
        // 无 env、_MEM 未载 → DEFAULT_CONFIG["data_root"]（纯路径计算，无 IO；
        // ⚠️ 绝不调无 env 实例的 getConfig——会写真实 ~/.subagent）
        let noEnv = NativeConfigStore(environment: [:])
        XCTAssertEqual(noEnv.dataRoot().path, NSHomeDirectory() + "/.subagent")
        // _MEM["data_root"] 次级（含 ~ 展开）
        noEnv.mem["data_root"] = .string("~/w0alt")
        XCTAssertEqual(noEnv.dataRoot().path, NSHomeDirectory() + "/w0alt")
        // env 覆盖 _MEM
        let both = NativeConfigStore(environment: ["VETARAI_DATA_ROOT": tmp.path])
        both.mem["data_root"] = .string("~/w0alt")
        XCTAssertEqual(both.dataRoot().path, tmp.path)
    }

    /// configPath / projectsRoot 派生（L230-231 / L218-221）。
    func testPathDerivations() throws {
        XCTAssertEqual(store.configPath().path, tmp.path + "/config.json")
        let pr = store.projectsRoot()
        XCTAssertEqual(pr.path, tmp.path + "/projects")
        XCTAssertTrue(FileManager.default.fileExists(atPath: pr.path))   // mkdir 副作用
    }

    // MARK: - error_analysis_timeout_s（0.7.5 W13 新增键，原生独占/Python 无对应）

    /// 写入校验：5-600，显式排 bool；合法值与边界可写。
    func testValidateErrorAnalysisTimeout() {
        assertInvalid(["error_analysis_timeout_s": .int(4)],
                      "error_analysis_timeout_s 必须是 5-600 的秒数")
        assertInvalid(["error_analysis_timeout_s": .int(601)],
                      "error_analysis_timeout_s 必须是 5-600 的秒数")
        assertInvalid(["error_analysis_timeout_s": .bool(true)],
                      "error_analysis_timeout_s 必须是 5-600 的秒数")
        assertInvalid(["error_analysis_timeout_s": .string("x")],
                      "error_analysis_timeout_s 必须是 5-600 的秒数")
        XCTAssertNoThrow(try store.reloadConfig(patch: ["error_analysis_timeout_s": .int(120)]))
        XCTAssertNoThrow(try store.reloadConfig(patch: ["error_analysis_timeout_s": .int(5)]))
        XCTAssertNoThrow(try store.reloadConfig(patch: ["error_analysis_timeout_s": .double(600.0)]))
    }

    /// 读路径钳制（NativeChatRuntime / NativeOpenAIChatConnector 两处同源）：
    /// 缺键/<=0/非法 → 60（等价 0.7.4 前写死旧行为）；>0 钳 5~600。
    func testErrorAnalysisTimeoutSReadPath() {
        XCTAssertEqual(NativeConfigStore.errorAnalysisTimeoutS([:]), 60.0)
        XCTAssertEqual(NativeConfigStore.errorAnalysisTimeoutS(
            ["error_analysis_timeout_s": .string("abc")]), 60.0)
        XCTAssertEqual(NativeConfigStore.errorAnalysisTimeoutS(
            ["error_analysis_timeout_s": .int(0)]), 60.0)
        XCTAssertEqual(NativeConfigStore.errorAnalysisTimeoutS(
            ["error_analysis_timeout_s": .int(-5)]), 60.0)
        XCTAssertEqual(NativeConfigStore.errorAnalysisTimeoutS(
            ["error_analysis_timeout_s": .int(120)]), 120.0)
        // 磁盘手改绕过写入校验时，读路径兜底钳制
        XCTAssertEqual(NativeConfigStore.errorAnalysisTimeoutS(
            ["error_analysis_timeout_s": .int(1)]), 5.0)
        XCTAssertEqual(NativeConfigStore.errorAnalysisTimeoutS(
            ["error_analysis_timeout_s": .int(9999)]), 600.0)
    }

    /// getConfig 对存量配置（磁盘无新键）自动补写并落盘（老用户迁移路径）。
    func testGetConfigBackfillsErrorAnalysisTimeout() throws {
        let path = tmp.appendingPathComponent("config.json")
        try """
        {"ollama_base_url": "http://localhost:11434"}
        """.write(to: path, atomically: false, encoding: .utf8)
        let cfg = try store.getConfig()
        XCTAssertEqual(cfg["error_analysis_timeout_s"], .int(60))
        let onDisk = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: path))
        XCTAssertEqual(onDisk["error_analysis_timeout_s"], .int(60))
    }
}
