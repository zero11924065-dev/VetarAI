//
//  NativeAppControlTests.swift
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

//  逐条对照 subagent/sidecar/app_modules/registry.py（⛔ 只读行为规格源）与
//  subagent/sidecar/app_modules/test_app_modules.py + sidecar/loop.py app_control 路由段：
//    · A 组：注册表结构（3 模块 12 动作、needsConfirm 默认、confirm_list 优先、catalog 文本）
//    · B 组：unknown_module / unknown_action 列可用项
//    · C 组：真存储 dispatch（workflow.list/get/get_runs、knowledge.search/inject/groups、
//      roundtable 校验链 + 砍项① creator 未装配如实报错）
//    · F 组：NODE_FIELD_SPECS 与 nodeTypes 漂移守护 + get_node_schema
//    · T 组：a6 写面（create/update/delete + coerceDefinition 容错 + 内置不可改删）
//    · W 组：wait_s 有界等待（真引擎 start→end 秒级 done / 非法回落后台 / 上限 120 常量 /
//      超时未结束回 running——假驱动不完结，避免真等 120s）
//    · D 组：NativeAgentLoop.routeAppControl 确认分级（查询直通 / 副作用无通道拒 /
//      用户拒 / authorizer 收 app_control:workflow.run + app_module / 配置放宽也确认）
//
//  ⚠️VERIFY 未翻：H 组 SSE 推送（原生内核不推，运行状态以 workflow.get_runs 承载）；
//  I 组 HTTP 端点语义（原生为进程内 dispatch，无 HTTP 层）。
//
//  隔离纪律：mktemp 全真 SQLite/文件；假 connector 不起网络/模型；真引擎只跑
//  start→end 空调（不调模型）；不触发任何真授权弹窗（authorizer 为记录型桩）。
//

import XCTest
@testable import VetarAINative

// MARK: - 记录型桩

/// 假 connector：start→end 空调用不到模型；被调用即失败以暴露意外推理。
private final class AppCtlFakeConnector: NativeWorkflowConnector, @unchecked Sendable {
    func chat(model: String, messages: [[String: JSONValue]], images: [String]?,
              readTimeoutS: Double?) async throws -> String {
        XCTFail("start→end 流程不应触发模型调用（model=\(model)）")
        return ""
    }
    func unloadModel(_ model: String) async -> Bool { true }
}

/// 记录型 authorizer（D 组断言 tool/path/action 三参）。
private final class RecAuthorizer: NativeToolAuthorizer, @unchecked Sendable {
    struct Call { let tool: String; let path: String; let action: String }
    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }
    var decision: Bool
    init(_ decision: Bool) { self.decision = decision }
    func authorize(tool: String, path: String, action: String) async -> Bool {
        lock.lock(); _calls.append(Call(tool: tool, path: path, action: action)); lock.unlock()
        return decision
    }
    func authorizeNetInstall(tool: String, source: String,
                             extra: [String: JSONValue]) async -> (allowed: Bool, enableNetwork: Bool) {
        (false, false)
    }
}

/// 记录型圆桌创建器（观测 maxRounds 收敛与透传字段）。
private final class RecRoundtableCreator: NativeRoundtableCreator, @unchecked Sendable {
    struct Call {
        let projectId: String; let topic: String; let agentIds: [String]
        let moderator: String; let maxRounds: Int
    }
    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }
    func createRoundtable(projectId: String, topic: String, agentIds: [String],
                          moderator: String, moderatorAgentId: String?,
                          maxRounds: Int) async -> [String: JSONValue] {
        lock.lock()
        _calls.append(Call(projectId: projectId, topic: topic, agentIds: agentIds,
                           moderator: moderator, maxRounds: maxRounds))
        lock.unlock()
        return ["ok": .bool(true), "roundtable_id": .string("rt-fake")]
    }
}

// MARK: - 测试

final class NativeAppControlTests: XCTestCase {

    private var tmp: URL!
    private var kernel: NativeKernel!
    private var connector: AppCtlFakeConnector!
    private var registry: NativeAppModuleRegistry!

    /// 合法最小定义（start→end；strict 校验可通过）。
    private let goodDefn: JSONValue = .object([
        "nodes": .array([
            .object(["id": .string("s"), "type": .string("start")]),
            .object(["id": .string("e"), "type": .string("end")]),
        ]),
        "edges": .array([
            .object(["from": .string("s"), "to": .string("e")]),
        ]),
    ])

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("p2w4c_app_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let emptyModels = tmp.appendingPathComponent("empty-models", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyModels, withIntermediateDirectories: true)
        kernel = NativeKernel(dataRoot: tmp, modelDir: emptyModels)
        connector = AppCtlFakeConnector()
        registry = NativeAppModuleRegistry(
            workflowStore: kernel.workflow, knowledge: kernel.knowledge,
            workflowRuntime: kernel.workflowRuntime, connector: connector)
    }

    override func tearDown() {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
        registry = nil; connector = nil; kernel = nil
        super.tearDown()
    }

    // MARK: 工具

    private func dispatch(_ module: String, _ action: String,
                          _ params: [String: JSONValue] = [:]) async -> [String: JSONValue] {
        await registry.dispatch(module, action, params: params,
                                projectId: "", sessionId: "sess-t",
                                sandboxRoot: tmp.path)
    }

    @discardableResult
    private func errString(_ r: [String: JSONValue],
                           file: StaticString = #filePath, line: UInt = #line) -> String {
        XCTAssertEqual(r["ok"], .bool(false), "应为失败：\(r)", file: file, line: line)
        guard case .string(let s)? = r["error"] else {
            XCTFail("缺 error 字段：\(r)", file: file, line: line); return ""
        }
        return s
    }

    /// 断言结果为失败且错误文案含 needle（await 已在实参求值完成，绕开 autoclosure 限制）。
    private func assertErrContains(_ r: [String: JSONValue], _ needle: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let e = errString(r, file: file, line: line)
        XCTAssertTrue(e.contains(needle), "错误文案应包含「\(needle)」，实际：\(e)",
                      file: file, line: line)
    }

    // ════════════════════════ A 组：注册表结构 ════════════════════════

    /// A1：3 模块 12 动作（workflow 8 + knowledge 3 + roundtable 1）。
    func testA1_registryShape() {
        let reg = NativeAppModuleRegistry.registry()
        XCTAssertEqual(reg.map { $0.0 }, ["workflow", "knowledge", "roundtable"])
        XCTAssertEqual(reg[0].1.actions.map { $0.0 },
                       ["list", "get", "get_node_schema", "run", "get_runs",
                        "create", "update", "delete"])
        XCTAssertEqual(reg[1].1.actions.map { $0.0 }, ["search", "inject", "groups"])
        XCTAssertEqual(reg[2].1.actions.map { $0.0 }, ["create"])
        XCTAssertEqual(NativeAppModuleRegistry.listActions().count, 12)
        XCTAssertTrue(NativeAppModuleRegistry.listActions().contains("workflow_run"))
        XCTAssertTrue(NativeAppModuleRegistry.listActions().contains("roundtable_create"))
    }

    /// A2：needsConfirm 默认值（副作用/高成本 true；查询/可逆写 false）。
    func testA2_needsConfirmDefaults() {
        XCTAssertTrue(registry.actionNeedsConfirm("workflow", "run", confirmList: nil))
        XCTAssertTrue(registry.actionNeedsConfirm("workflow", "delete", confirmList: nil))
        XCTAssertTrue(registry.actionNeedsConfirm("roundtable", "create", confirmList: nil))
        XCTAssertFalse(registry.actionNeedsConfirm("workflow", "list", confirmList: nil))
        XCTAssertFalse(registry.actionNeedsConfirm("workflow", "get", confirmList: nil))
        XCTAssertFalse(registry.actionNeedsConfirm("workflow", "create", confirmList: nil))
        XCTAssertFalse(registry.actionNeedsConfirm("workflow", "update", confirmList: nil))
        XCTAssertFalse(registry.actionNeedsConfirm("knowledge", "search", confirmList: nil))
        XCTAssertFalse(registry.actionNeedsConfirm("knowledge", "inject", confirmList: nil))
        // 未知模块/动作 → false（不拦截，由 dispatch 报 unknown_*）
        XCTAssertFalse(registry.actionNeedsConfirm("nope", "x", confirmList: nil))
    }

    /// A3：confirm_list 非 nil 时优先于注册表默认（Python isinstance list 判定）。
    func testA3_confirmListOverrides() {
        // 白名单含 knowledge_search → 查询类也要确认
        XCTAssertTrue(registry.actionNeedsConfirm("knowledge", "search",
                                                  confirmList: ["knowledge_search"]))
        // 白名单为空数组 → 连 workflow_run 也不确认（配置全权接管）
        XCTAssertFalse(registry.actionNeedsConfirm("workflow", "run", confirmList: []))
        XCTAssertTrue(registry.actionNeedsConfirm("workflow", "run",
                                                  confirmList: ["workflow_run"]))
    }

    /// A4：catalog 文本含三模块描述行与动作行（供系统提示词注入）。
    func testA4_catalogText() {
        let text = NativeAppModuleRegistry.buildModuleCatalogText()
        XCTAssertTrue(text.contains("- workflow：流程中心"))
        XCTAssertTrue(text.contains("- knowledge：知识仓库"))
        XCTAssertTrue(text.contains("- roundtable：圆桌讨论"))
        XCTAssertTrue(text.contains("· workflow.run —"))
        XCTAssertTrue(text.contains("· knowledge.search —"))
        XCTAssertTrue(text.contains("· roundtable.create —"))
    }

    // ════════════════════════ B 组：未知模块/动作 ════════════════════════

    /// B1：unknown_module 列出可用模块。
    func testB1_unknownModule() async {
        let e = errString(await dispatch("nosuch", "run"))
        XCTAssertTrue(e.contains("unknown_module"))
        XCTAssertTrue(e.contains("没有名为「nosuch」的应用模块"))
        XCTAssertTrue(e.contains("可用模块：workflow、knowledge、roundtable"))
    }

    /// B2：unknown_action 列出该模块可用动作。
    func testB2_unknownAction() async {
        let e = errString(await dispatch("workflow", "bogus"))
        XCTAssertTrue(e.contains("unknown_action"))
        XCTAssertTrue(e.contains("模块「workflow」没有动作「bogus」"))
        XCTAssertTrue(e.contains("该模块可用动作："))
        XCTAssertTrue(e.contains("run"))
    }

    /// B3：空模块名同样走 unknown_module（registry 层；路由层另有拦截见 D1）。
    func testB3_emptyModule() async {
        let e = errString(await dispatch("", "run"))
        XCTAssertTrue(e.contains("unknown_module"))
    }

    // ════════════════════════ C 组：真存储 dispatch ════════════════════════

    /// C1：workflow.list 空库 → ok + count 0。
    func testC1_workflowListEmpty() async {
        let r = await dispatch("workflow", "list")
        XCTAssertEqual(r["ok"], .bool(true))
        XCTAssertEqual(r["count"], .int(0))
        XCTAssertEqual(r["workflows"], .array([]))
    }

    /// C2：workflow.list/get 真行（摘要描述裁剪 120 字；get 回完整定义）。
    func testC2_workflowListAndGet() async throws {
        let longDesc = String(repeating: "描", count: 200)
        let wfId = try kernel.workflow.createWorkflow(
            name: "识图流水线", definition: goodDefn, description: longDesc)
        let list = await dispatch("workflow", "list")
        XCTAssertEqual(list["count"], .int(1))
        guard case .array(let rows)? = list["workflows"],
              case .object(let row) = rows.first else {
            return XCTFail("list 行结构异常：\(list)")
        }
        XCTAssertEqual(row["id"], .string(wfId))
        XCTAssertEqual(row["name"], .string("识图流水线"))
        XCTAssertEqual(row["description"]?.string?.count, 120)   // 裁剪 120 字
        // get：完整定义 + built_in 标记
        let get = await dispatch("workflow", "get", ["workflow_id": .string(wfId)])
        XCTAssertEqual(get["ok"], .bool(true))
        guard case .object(let wf)? = get["workflow"] else {
            return XCTFail("get 缺 workflow：\(get)")
        }
        XCTAssertEqual(wf["built_in"], .bool(false))
        XCTAssertEqual(wf["description"], .string(longDesc))   // get 不裁剪
        guard case .object(let def)? = wf["definition"],
              case .array(let nodes)? = def["nodes"] else {
            return XCTFail("definition 未回传：\(get)")
        }
        XCTAssertEqual(nodes.count, 2)
    }

    /// C3：workflow.get 缺 id / 不存在。
    func testC3_workflowGetErrors() async {
        assertErrContains(await dispatch("workflow", "get"),
                          "bad_arg: 需要 workflow_id")
        assertErrContains(await dispatch("workflow", "get",
                                         ["workflow_id": .string("wf-none")]),
                          "workflow_not_found: 工作流 wf-none 不存在")
    }

    /// C4：knowledge.search 缺 query / 空库 0 命中 / 拉模式 note 逐字。
    func testC4_knowledgeSearch() async {
        assertErrContains(await dispatch("knowledge", "search"),
                          "bad_arg: 需要 query")
        let r = await dispatch("knowledge", "search", ["query": .string("不存在的词")])
        XCTAssertEqual(r["ok"], .bool(true))
        XCTAssertEqual(r["count"], .int(0))
        XCTAssertEqual(r["note"],
                       .string("检索结果仅本轮可见，不会写入对话上下文（拉模式）。"))
    }

    /// C5：knowledge.search/inject 真条目（addEntry 直接种库；embedder 不可用走 FTS 降级）。
    func testC5_knowledgeSearchInjectReal() async {
        let entry = kernel.knowledge.addEntry(
            scope: "global", projectId: nil, title: "Swift 重写笔记",
            body: "VetarAI 内核已用 Swift 原生重写，替代 Python 侧车。",
            category: "笔记", keywords: ["swift"], source: "chat")
        XCTAssertNotNil(entry)
        // search：keyword 模式（FTS 不依赖嵌入模型）
        let s = await dispatch("knowledge", "search",
                               ["query": .string("Swift"), "mode": .string("keyword")])
        XCTAssertEqual(s["ok"], .bool(true))
        guard case .array(let items)? = s["items"] else {
            return XCTFail("items 缺失：\(s)")
        }
        XCTAssertTrue(items.contains {
            $0.object?["id"]?.string == entry!.id
                && ($0.object?["body"]?.string?.contains("Swift 原生重写") ?? false)
        }, "检索应命中刚种的条目：\(s)")
        // inject：按 id 取正文
        let inj = await dispatch("knowledge", "inject",
                                 ["entry_ids": .array([.string(entry!.id)])])
        XCTAssertEqual(inj["ok"], .bool(true))
        XCTAssertEqual(inj["count"], .int(1))
        XCTAssertTrue(inj["text"]?.string?.contains("## Swift 重写笔记") ?? false)
        XCTAssertTrue(inj["text"]?.string?.contains("替代 Python 侧车") ?? false)
        // inject 不存在的 id → entries_not_found；缺失与命中混合 → ok + missing 列表
        assertErrContains(await dispatch("knowledge", "inject",
                                         ["entry_ids": .array([.string("e-none")])]),
                          "entries_not_found: 条目不存在或已被删除（e-none）")
        let mixed = await dispatch("knowledge", "inject",
                                   ["entry_ids": .array([.string(entry!.id), .string("e-none")])])
        XCTAssertEqual(mixed["ok"], .bool(true))
        XCTAssertEqual(mixed["missing"], .array([.string("e-none")]))
        // inject 缺 entry_ids → bad_arg
        assertErrContains(await dispatch("knowledge", "inject"),
                          "bad_arg: 需要 entry_ids")
    }

    /// C6：knowledge.groups 概览（全局组计数含刚种条目）。
    func testC6_knowledgeGroups() async {
        _ = kernel.knowledge.addEntry(scope: "global", projectId: nil,
                                      title: "组测试条目", body: "正文")
        let r = await dispatch("knowledge", "groups")
        XCTAssertEqual(r["ok"], .bool(true))
        guard case .array(let groups)? = r["groups"] else {
            return XCTFail("groups 缺失：\(r)")
        }
        let global = groups.first { $0.object?["scope"]?.string == "global" }
        XCTAssertNotNil(global, "应有 global 分组：\(r)")
        XCTAssertEqual(global?.object?["count"], .int(1))
    }

    /// C7：roundtable.create 校验链（topic / ≥2 agents / project_id）。
    func testC7_roundtableValidation() async {
        assertErrContains(await dispatch("roundtable", "create"),
                          "bad_arg: 需要 topic")
        assertErrContains(await dispatch("roundtable", "create", [
            "topic": .string("架构评审"),
            "agent_ids": .array([.string("a1")]),
        ]), "bad_arg: agent_ids 至少需要 2 个 Agent（圆桌是多方会诊）")
        // project_id 空（参数与 ctx 都空）→ bad_arg
        assertErrContains(await dispatch("roundtable", "create", [
            "topic": .string("架构评审"),
            "agent_ids": .array([.string("a1"), .string("a2")]),
        ]), "bad_arg: 需要 project_id")
    }

    /// C8：原生偏差①——校验通过但 creator 未装配 → 如实报 roundtable_create_failed。
    func testC8_roundtableCreatorMissing() async {
        let r = await registry.dispatch("roundtable", "create", params: [
            "topic": .string("架构评审"),
            "agent_ids": .array([.string("a1"), .string("a2")]),
            "project_id": .string("p1"),
        ], projectId: "", sessionId: "sess-t", sandboxRoot: tmp.path)
        let e = errString(r)
        XCTAssertTrue(e.contains("roundtable_create_failed: 圆桌执行链路尚未原生接管"))
        XCTAssertTrue(e.contains("参数校验已通过"))
    }

    /// C9：creator 装配后透传字段 + maxRounds 收敛 [1,20]。
    func testC9_roundtableCreatorCalled() async {
        let creator = RecRoundtableCreator()
        let reg = NativeAppModuleRegistry(
            workflowStore: kernel.workflow, knowledge: kernel.knowledge,
            workflowRuntime: kernel.workflowRuntime, connector: connector,
            roundtableCreator: creator)
        let r = await reg.dispatch("roundtable", "create", params: [
            "topic": .string("  架构评审  "),
            "agent_ids": .array([.string("a1"), .string("a2"), .string("a3")]),
            "project_id": .string("p1"),
            "max_rounds": .int(99),
        ], projectId: "", sessionId: "sess-t", sandboxRoot: tmp.path)
        XCTAssertEqual(r["ok"], .bool(true))
        XCTAssertEqual(r["roundtable_id"], .string("rt-fake"))
        XCTAssertEqual(creator.calls.count, 1)
        XCTAssertEqual(creator.calls[0].topic, "架构评审")   // trim
        XCTAssertEqual(creator.calls[0].agentIds, ["a1", "a2", "a3"])
        XCTAssertEqual(creator.calls[0].maxRounds, 20)       // 上限收敛
        XCTAssertEqual(creator.calls[0].moderator, "user")   // 默认
    }

    // ════════════════════════ F 组：节点字段表 ════════════════════════

    /// F1：NODE_FIELD_SPECS 键集 == NativeWorkflowSchema.nodeTypes（漂移守护）。
    func testF1_nodeFieldSpecsCoverAllTypes() {
        XCTAssertEqual(Set(NativeNodeFieldSpecs.table.keys),
                       Set(NativeWorkflowSchema.nodeTypes))
    }

    /// F2：inference 字段表含 0.4.28 新增 timeout_s。
    func testF2_inferenceHasTimeoutField() {
        let names = (NativeNodeFieldSpecs.table["inference"] ?? []).map { $0.name }
        XCTAssertTrue(names.contains("model"))
        XCTAssertTrue(names.contains("timeout_s"))
    }

    /// F3：get_node_schema 单查 / 全量 / 未知类型。
    func testF3_getNodeSchema() async {
        let one = await dispatch("workflow", "get_node_schema",
                                 ["node_type": .string("inference")])
        XCTAssertEqual(one["ok"], .bool(true))
        XCTAssertEqual(one["node_type"], .string("inference"))
        guard case .array(let fields)? = one["fields"] else {
            return XCTFail("fields 缺失：\(one)")
        }
        XCTAssertTrue(fields.contains { $0.object?["name"]?.string == "timeout_s" })
        // 全量：count == nodeTypes.count
        let all = await dispatch("workflow", "get_node_schema")
        XCTAssertEqual(all["count"], .int(Int64(NativeWorkflowSchema.nodeTypes.count)))
        // 未知类型：列合法类型
        let e = errString(await dispatch("workflow", "get_node_schema",
                                         ["node_type": .string("bogus")]))
        XCTAssertTrue(e.contains("unknown_node_type: 没有名为 'bogus' 的节点类型"))
        XCTAssertTrue(e.contains("合法节点类型："))
    }

    // ════════════════════════ T 组：写面（create/update/delete） ════════════════════════

    /// T1：create 全链路（definition 对象 + JSON 字符串两种形态）+ list 可见。
    func testT1_createHappyPath() async throws {
        let r = await dispatch("workflow", "create", [
            "name": .string("批量转写"),
            "definition": goodDefn,
            "description": .string("T1 创建"),
        ])
        XCTAssertEqual(r["ok"], .bool(true))
        guard case .string(let wfId)? = r["workflow_id"] else {
            return XCTFail("缺 workflow_id：\(r)")
        }
        XCTAssertEqual(r["note"]?.string,
                       "工作流定义已创建（半成品也允许保存）。运行前会自动做完整性校验"
                           + "（需恰好一个 start、至少一个 end、start 可达全部节点）。")
        // JSON 字符串形态（模型常把嵌套对象序列化）
        let r2 = await dispatch("workflow", "create", [
            "name": .string("字符串定义"),
            "definition": .string("""
                {"nodes":[{"id":"s","type":"start"},{"id":"e","type":"end"}],
                 "edges":[{"from":"s","to":"e"}]}
                """),
        ])
        XCTAssertEqual(r2["ok"], .bool(true))
        // 两个都进 list
        let list = await dispatch("workflow", "list")
        XCTAssertEqual(list["count"], .int(2))
        XCTAssertEqual(try kernel.workflow.getWorkflowRow(wfId)?.name, "批量转写")
    }

    /// T2：coerceDefinition 容错（经 dispatch 实测）：坏 JSON / 数组 / 整数 / 空定义。
    func testT2_createBadDefinitions() async {
        // 缺 name
        assertErrContains(await dispatch("workflow", "create",
                                         ["definition": goodDefn]),
                          "bad_arg: 需要 name")
        // 缺 definition
        assertErrContains(await dispatch("workflow", "create",
                                         ["name": .string("x")]),
                          "bad_arg: 需要 definition")
        // 坏 JSON 字符串
        assertErrContains(await dispatch("workflow", "create", [
            "name": .string("x"), "definition": .string("{"),
        ]), "bad_arg: definition 不是合法 JSON")
        // JSON 字符串解析成数组
        assertErrContains(await dispatch("workflow", "create", [
            "name": .string("x"), "definition": .string("[1,2]"),
        ]), "bad_arg: definition 解析后应为对象（nodes/edges）")
        // 数组类型
        assertErrContains(await dispatch("workflow", "create", [
            "name": .string("x"), "definition": .array([]),
        ]), "bad_arg: definition 类型非法：应为对象或 JSON 字符串")
        // 整数类型
        assertErrContains(await dispatch("workflow", "create", [
            "name": .string("x"), "definition": .int(3),
        ]), "bad_arg: definition 类型非法")
        // 空对象 → 宽松校验硬伤（无 nodes）→ workflow_create_failed + hint
        let bad = await dispatch("workflow", "create", [
            "name": .string("x"), "definition": .object([:]),
        ])
        assertErrContains(bad, "workflow_create_failed")
        XCTAssertTrue(bad["hint"]?.string?.contains("workflow.get_node_schema") ?? false)
    }

    /// T3：update 部分更新 / 缺字段 / 不存在 / 内置不可改。
    func testT3_update() async throws {
        let wfId = try kernel.workflow.createWorkflow(name: "旧名", definition: goodDefn,
                                                      description: "旧描述")
        // 未提供任何字段
        assertErrContains(await dispatch("workflow", "update",
                                         ["workflow_id": .string(wfId)]),
                          "bad_arg: 未提供任何要更新的字段")
        // 部分更新：只改名
        let ok = await dispatch("workflow", "update", [
            "workflow_id": .string(wfId), "name": .string("新名"),
        ])
        XCTAssertEqual(ok["ok"], .bool(true))
        let row = try kernel.workflow.getWorkflowRow(wfId)
        XCTAssertEqual(row?.name, "新名")
        XCTAssertEqual(row?.description, "旧描述")   // 未传不动
        // 不存在
        assertErrContains(await dispatch("workflow", "update", [
            "workflow_id": .string("wf-none"), "name": .string("n"),
        ]), "workflow_update_failed: 工作流不存在")
        // 内置不可改
        let builtIn = try kernel.workflow.createWorkflow(
            name: "内置流", definition: goodDefn, builtIn: true)
        assertErrContains(await dispatch("workflow", "update", [
            "workflow_id": .string(builtIn), "name": .string("改内置"),
        ]), "workflow_update_failed: 内置工作流不可修改")
    }

    /// T4：delete 成功 / 不存在 / 内置不可删；历史运行记录保留。
    func testT4_delete() async throws {
        let wfId = try kernel.workflow.createWorkflow(name: "待删", definition: goodDefn)
        // 先跑一次留下运行记录
        let runId = try kernel.workflow.createWorkflowRun(workflowId: wfId)
        let ok = await dispatch("workflow", "delete", ["workflow_id": .string(wfId)])
        XCTAssertEqual(ok["ok"], .bool(true))
        XCTAssertEqual(ok["note"]?.string, "工作流定义已删除（历史运行记录保留）")
        XCTAssertNil(try kernel.workflow.getWorkflowRow(wfId))
        XCTAssertNotNil(try kernel.workflow.getWorkflowRun(runId), "运行记录应保留")
        // 不存在
        assertErrContains(await dispatch("workflow", "delete",
                                         ["workflow_id": .string(wfId)]),
                          "workflow_delete_failed: 工作流不存在")
        // 内置不可删
        let builtIn = try kernel.workflow.createWorkflow(
            name: "内置流", definition: goodDefn, builtIn: true)
        assertErrContains(await dispatch("workflow", "delete",
                                         ["workflow_id": .string(builtIn)]),
                          "workflow_delete_failed: 内置工作流不可删除")
    }

    // ════════════════════════ W 组：wait_s 有界等待 ════════════════════════

    /// W1：真引擎驱动 start→end，wait_s=5 → 等待窗口内 done + 结果透传。
    func testW1_waitSyncDone() async throws {
        let wfId = try kernel.workflow.createWorkflow(name: "秒完", definition: goodDefn)
        let r = await dispatch("workflow", "run", [
            "workflow_id": .string(wfId), "wait_s": .int(5),
        ])
        XCTAssertEqual(r["ok"], .bool(true))
        XCTAssertEqual(r["status"], .string("done"), "start→end 应在窗口内完结：\(r)")
        XCTAssertEqual(r["workflow_name"], .string("秒完"))
        XCTAssertEqual(r["note"]?.string, "工作流已结束（在等待窗口内完成），无需再轮询。")
        guard case .string(let runId)? = r["run_id"] else {
            return XCTFail("缺 run_id：\(r)")
        }
        // 运行记录落库终态
        XCTAssertEqual(try kernel.workflow.getWorkflowRun(runId)?.status, "done")
    }

    /// W2：wait_s 缺省/0/非法 → 立即返回 running（后台模式，note 逐字）。
    func testW2_waitBackground() async throws {
        let wfId = try kernel.workflow.createWorkflow(name: "后台流", definition: goodDefn)
        for params: [String: JSONValue] in [
            ["workflow_id": .string(wfId)],
            ["workflow_id": .string(wfId), "wait_s": .int(0)],
            ["workflow_id": .string(wfId), "wait_s": .string("abc")],   // 非法 → 0
        ] {
            let r = await dispatch("workflow", "run", params)
            XCTAssertEqual(r["ok"], .bool(true))
            XCTAssertEqual(r["status"], .string("running"))
            XCTAssertEqual(r["note"]?.string,
                           "工作流已在后台开始运行。用 workflow_get_runs(run_id=...) 查询进度与结果；"
                               + "若想在本轮直接拿到结果，可传 wait_s（秒，上限 120）等待其结束。")
        }
        // 上限常量 120（WORKFLOW_RUN_MAX_WAIT）
        XCTAssertEqual(NativeAppModuleRegistry.workflowRunMaxWait, 120.0)
    }

    /// W3：假驱动永不完结 + wait_s=1 → 超时回 running + run_id（退回轮询文案）。
    func testW3_waitTimeoutFallsBackToPolling() async throws {
        let stuck = NativeAppModuleRegistry(
            workflowStore: kernel.workflow, knowledge: kernel.knowledge,
            workflowRuntime: kernel.workflowRuntime, connector: connector,
            engineDriver: { _, _, _, _ in /* 永不驱动 → 恒 running */ })
        let wfId = try kernel.workflow.createWorkflow(name: "长任务", definition: goodDefn)
        let start = Date()
        let r = await stuck.dispatch("workflow", "run", params: [
            "workflow_id": .string(wfId), "wait_s": .double(1.0),
        ], projectId: "", sessionId: "sess-t", sandboxRoot: tmp.path)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(r["ok"], .bool(true))
        XCTAssertEqual(r["status"], .string("running"))
        XCTAssertTrue(r["note"]?.string?.contains("仍未结束") ?? false)
        XCTAssertTrue(r["note"]?.string?.contains("已转为后台运行") ?? false)
        XCTAssertNotNil(r["run_id"]?.string)
        XCTAssertGreaterThanOrEqual(elapsed, 0.9, "应真等了约 1s")
        XCTAssertLessThan(elapsed, 10, "有界等待不可失控")
    }

    /// W4：run 不存在的工作流 / 缺 id。
    func testW4_runErrors() async {
        assertErrContains(await dispatch("workflow", "run"),
                          "bad_arg: 需要 workflow_id")
        assertErrContains(await dispatch("workflow", "run",
                                         ["workflow_id": .string("wf-none")]),
                          "workflow_not_found: 工作流 wf-none 不存在")
    }

    /// W5：get_runs 三形态（run_id 单查 / workflow_id 过滤 / 不存在）。
    func testW5_getRuns() async throws {
        let wfId = try kernel.workflow.createWorkflow(name: "运行史", definition: goodDefn)
        let r = await dispatch("workflow", "run",
                               ["workflow_id": .string(wfId), "wait_s": .int(5)])
        guard case .string(let runId)? = r["run_id"] else {
            return XCTFail("缺 run_id：\(r)")
        }
        // run_id 单查
        let one = await dispatch("workflow", "get_runs", ["run_id": .string(runId)])
        XCTAssertEqual(one["ok"], .bool(true))
        XCTAssertEqual(one["run"]?.object?["status"], .string("done"))
        XCTAssertEqual(one["run"]?.object?["workflow_id"], .string(wfId))
        // workflow_id 过滤
        let byWf = await dispatch("workflow", "get_runs", ["workflow_id": .string(wfId)])
        XCTAssertEqual(byWf["count"], .int(1))
        // run_not_found
        assertErrContains(await dispatch("workflow", "get_runs",
                                         ["run_id": .string("r-none")]),
                          "run_not_found: 运行记录 r-none 不存在")
    }

    // ════════════════════════ D 组：路由确认分级（routeAppControl） ════════════════════════

    private func route(_ args: [String: JSONValue],
                       ctx: NativeAppControlContext?,
                       config: [String: JSONValue] = [:]) async -> [String: JSONValue] {
        await NativeAgentLoop.routeAppControl(args: args, ctx: ctx,
                                              sandboxRoot: tmp.path, config: { config })
    }

    private func makeCtx(authorizer: RecAuthorizer? = nil) -> NativeAppControlContext {
        NativeAppControlContext(projectId: "", sessionId: "sess-t",
                                sandboxRoot: tmp.path,
                                authorizer: authorizer, dispatcher: registry)
    }

    /// D1：缺 module/action 与 ctx/dispatcher 未装配的三条前置拦截。
    func testD1_routePreconditions() async {
        assertErrContains(await route([:], ctx: makeCtx()),
                          "app_control 需要 module 与 action 两个参数")
        assertErrContains(await route(
            ["module": .string("workflow"), "action": .string("list")], ctx: nil),
            "当前会话未启用应用内模块控制")
        var bare = makeCtx()
        bare.dispatcher = nil
        assertErrContains(await route(
            ["module": .string("workflow"), "action": .string("list")], ctx: bare),
            "应用内模块控制分发链路尚未原生接管")
    }

    /// D2：查询类动作无 authorizer 也直通 dispatch。
    func testD2_querySkipsConfirm() async {
        let r = await route([
            "module": .string("knowledge"), "action": .string("search"),
            "params": .object(["query": .string("x")]),
        ], ctx: makeCtx())   // authorizer=nil
        XCTAssertEqual(r["ok"], .bool(true), "查询类不应弹确认：\(r)")
        XCTAssertEqual(r["count"], .int(0))
    }

    /// D3：副作用动作无授权通道 → app_module_denied 逐字，且未触达 dispatch。
    func testD3_mutatingDeniedWithoutAuthorizer() async {
        let r = await route([
            "module": .string("workflow"), "action": .string("run"),
            "params": .object(["workflow_id": .string("wf-none")]),
        ], ctx: makeCtx())
        let e = errString(r)
        XCTAssertTrue(e.contains("app_module_denied: 「workflow.run」属高成本操作需用户确认"))
        XCTAssertTrue(e.contains("当前无授权通道，已拒绝执行"))
        XCTAssertFalse(e.contains("workflow_not_found"), "不应触达 dispatch 层")
    }

    /// D4：用户拒绝 → denied_by_user 逐字 + authorizer 三参契约（原生偏差：
    /// Python extra{desc,app} 未翻——原生协议仅 tool/path/action，args 随 path JSON）。
    func testD4_deniedByUser() async {
        let auth = RecAuthorizer(false)
        let r = await route([
            "module": .string("workflow"), "action": .string("run"),
            "params": .object(["workflow_id": .string("wf-1")]),
        ], ctx: makeCtx(authorizer: auth))
        let e = errString(r)
        XCTAssertTrue(e.contains("denied_by_user: 用户拒绝了「workflow.run」"))
        XCTAssertTrue(e.contains("不要再重试该动作"))
        XCTAssertEqual(auth.calls.count, 1)
        XCTAssertEqual(auth.calls[0].tool, "app_control:workflow.run")
        XCTAssertEqual(auth.calls[0].action, "app_module")
        XCTAssertTrue(auth.calls[0].path.contains("wf-1"), "params JSON 随 path：\(auth.calls[0])")
        XCTAssertLessThanOrEqual(auth.calls[0].path.count, 400, "path 截断 400")
    }

    /// D5：用户放行 → 触达 dispatch（以 workflow_not_found 证明穿过确认层）。
    func testD5_allowedReachesDispatch() async {
        let auth = RecAuthorizer(true)
        let r = await route([
            "module": .string("workflow"), "action": .string("run"),
            "params": .object(["workflow_id": .string("wf-none")]),
        ], ctx: makeCtx(authorizer: auth))
        assertErrContains(r, "workflow_not_found")
        XCTAssertEqual(auth.calls.count, 1)
    }

    /// D6：配置 app_control_confirm 把查询类也升级为确认（无通道 → 拒绝）。
    func testD6_configConfirmListUpgradesQuery() async {
        let r = await route([
            "module": .string("knowledge"), "action": .string("search"),
            "params": .object(["query": .string("x")]),
        ], ctx: makeCtx(),
        config: ["app_control_confirm": .array([.string("knowledge_search")])])
        assertErrContains(r, "app_module_denied: 「knowledge.search」属高成本操作需用户确认")
    }

    /// D7：配置 app_control_confirm 为空数组 → workflow.run 免确认直通。
    func testD7_configEmptyConfirmListRelaxes() async {
        let r = await route([
            "module": .string("workflow"), "action": .string("run"),
            "params": .object(["workflow_id": .string("wf-none")]),
        ], ctx: makeCtx(),   // authorizer=nil，但配置空名单 → 不确认
        config: ["app_control_confirm": .array([])])
        assertErrContains(r, "workflow_not_found")
    }
}
