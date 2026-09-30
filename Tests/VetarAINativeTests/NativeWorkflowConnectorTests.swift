//
//  NativeWorkflowConnectorTests.swift
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

//  两段覆盖（均不触网——connector 只测纯函数/配置映射，端点走原生内核）：
//
//  A. NativeWorkflowHTTPConnector 纯函数面（对照 sidecar/ollama/connector.py、
//     openai_compat.py、infer_options.py）：
//     · timeout_reading/timeout_connect：默认 300/10，钳 10~7200 / 1~600，非法回落
//     · model_options：三级键匹配 + 后端参数映射 + coerce 范围；空 → 完全不注入
//     · _parse_image：data URI / 文件 / >50 视为已编码 / >8MB 丢弃
//     · WorkflowConnectorError 的 pyTypeName/pyMessage（_exc_text 对齐载体）
//
//  B. WorkflowPanelClient 端点语义（对照 app.py L2226-2365）：
//     · create/update：宽松校验（strict=False）→ 422「；」拼前 5 条；name strip 空 →
//       「未命名工作流」；404/403 守卫序
//     · run：404 → 严格校验 422「工作流定义有错误：…」（契约点 1 的运行关）
//     · approve：404 → 409「当前状态 X 不在等待审批」→ 409「审批已失效」（契约点 5）
//     · stop：404；非进行中 → ok:false 不抛错**且不置取消标志**（契约点 3）；
//       进行中 → 置取消 + 驳回审批解锁
//

import XCTest
@testable import VetarAINative

final class NativeWorkflowConnectorTests: XCTestCase {

    private var tmp: URL!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("w2wfconn_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    private func makeClient() -> (NativeSidecarClient, NativeKernel) {
        let kernel = NativeKernel(dataRoot: tmp.appendingPathComponent(UUID().uuidString))
        return (NativeSidecarClient(kernel: kernel), kernel)
    }

    // ════════════════════════════════════════════════════════════
    // MARK: A. connector 超时配置（infer_options.py L124-145 逐条）
    // ════════════════════════════════════════════════════════════

    func testTimeoutConfigClamp() {
        func reading(_ raw: JSONValue?) -> Double {
            let conn = NativeWorkflowHTTPConnector(configProvider: {
                raw.map { ["timeout_reading": $0] } ?? [:]
            })
            return conn.timeoutReading()
        }
        XCTAssertEqual(reading(nil), 300)                 // 未配 → 默认
        XCTAssertEqual(reading(.double(900)), 900)        // 正常
        XCTAssertEqual(reading(.int(1200)), 1200)
        XCTAssertEqual(reading(.int(5)), 10)              // clamp 下界
        XCTAssertEqual(reading(.double(99999)), 7200)     // clamp 上界
        XCTAssertEqual(reading(.double(0)), 300)          // 0/负 → 回落默认
        XCTAssertEqual(reading(.double(-3)), 300)
        XCTAssertEqual(reading(.string("abc")), 300)      // 非法 → 回落
        XCTAssertEqual(reading(.string("450")), 450)      // 数值字符串宽松（float(raw)）
        XCTAssertEqual(reading(.bool(true)), 300)         // bool 拒绝

        func connect(_ raw: JSONValue?) -> Double {
            let conn = NativeWorkflowHTTPConnector(configProvider: {
                raw.map { ["timeout_connect": $0] } ?? [:]
            })
            return conn.timeoutConnect()
        }
        XCTAssertEqual(connect(nil), 10)
        XCTAssertEqual(connect(.double(30)), 30)
        XCTAssertEqual(connect(.double(0.5)), 1)          // clamp 1
        XCTAssertEqual(connect(.int(9999)), 600)          // clamp 600
    }

    // ════════════════════════════════════════════════════════════
    // MARK: A. model_options（infer_options.py L148-188 + L323-387）
    // ════════════════════════════════════════════════════════════

    private func optionsConfig(_ mo: [String: JSONValue]) -> [String: JSONValue] {
        ["model_options": .object(mo)]
    }

    func testRawModelOptionsThreeLevelMatch() {
        let cfg = optionsConfig([
            "qwen3.8": .object(["temperature": .double(0.5)]),
            "qwen3.8:latest": .object(["temperature": .double(0.9)]),
        ])
        // 第一级：精确命中
        XCTAssertEqual(NativeWorkflowHTTPConnector.rawModelOptions(
            model: "qwen3.8:latest", config: cfg), ["temperature": .double(0.9)])
        // 第二级：查询名去 tag 命中配置键
        XCTAssertEqual(NativeWorkflowHTTPConnector.rawModelOptions(
            model: "qwen3.8", config: cfg), ["temperature": .double(0.5)])
        XCTAssertEqual(NativeWorkflowHTTPConnector.rawModelOptions(
            model: "qwen3.8:v2", config: cfg), ["temperature": .double(0.5)])
        // 第三级：配置键去 tag 命中（仅配带 tag 键时）
        let cfg2 = optionsConfig(["qwen3.8:latest": .object(["seed": .int(7)])])
        XCTAssertEqual(NativeWorkflowHTTPConnector.rawModelOptions(
            model: "qwen3.8:v2", config: cfg2), ["seed": .int(7)])
        // 未命中 / 空配置 / 空白模型名 → 空
        XCTAssertEqual(NativeWorkflowHTTPConnector.rawModelOptions(model: "other", config: cfg),
                       [:])
        XCTAssertEqual(NativeWorkflowHTTPConnector.rawModelOptions(model: "qwen3.8", config: [:]),
                       [:])
        XCTAssertEqual(NativeWorkflowHTTPConnector.rawModelOptions(model: "  ", config: cfg), [:])
    }

    func testModelOptionsBackendMapping() {
        let cfg = optionsConfig(["m1": .object([
            "num_ctx": .int(4096), "temperature": .double(0.5), "top_k": .int(40),
            "repeat_penalty": .double(1.1), "num_predict": .int(512), "seed": .int(42),
            "stop": .string("停"),
        ])])
        // Ollama：包 options 壳，键名原样
        let ollama = NativeWorkflowHTTPConnector.modelOptions(model: "m1", backend: "ollama",
                                                              config: cfg)
        XCTAssertEqual(ollama, ["options": .object([
            "num_ctx": .int(4096), "temperature": .double(0.5), "top_k": .int(40),
            "repeat_penalty": .double(1.1), "num_predict": .int(512), "seed": .int(42),
            "stop": .array([.string("停")]),
        ])])
        // OpenAI 兼容：顶层字段；num_ctx/top_k 不支持静默丢弃；repeat_penalty→frequency_penalty；
        // num_predict→max_tokens
        let openai = NativeWorkflowHTTPConnector.modelOptions(
            model: "m1", backend: "openai_compatible", config: cfg)
        XCTAssertEqual(openai, [
            "temperature": .double(0.5), "frequency_penalty": .double(1.1),
            "max_tokens": .int(512), "seed": .int(42), "stop": .array([.string("停")]),
        ])
    }

    func testModelOptionsCoerceAndEmpty() {
        // 越界/非法 → 该参数丢弃；全丢 → 空 dict（绝不注入空 options）
        let bad = optionsConfig(["m1": .object([
            "temperature": .double(5.0),      // 超 0~2
            "num_ctx": .int(100),             // 低于 256
            "top_p": .double(1.5),            // 超 0~1
        ])])
        XCTAssertEqual(NativeWorkflowHTTPConnector.modelOptions(model: "m1", backend: "ollama",
                                                                config: bad), [:])
        // 单参数 coerce：stop 字符串 → 数组；空串丢弃；seed 字符串数字宽松
        let stopCfg = optionsConfig(["m1": .object(["stop": .string("")])])
        XCTAssertEqual(NativeWorkflowHTTPConnector.modelOptions(model: "m1", backend: "ollama",
                                                                config: stopCfg), [:])
        let seedCfg = optionsConfig(["m1": .object(["seed": .string("42")])])
        XCTAssertEqual(NativeWorkflowHTTPConnector.modelOptions(model: "m1", backend: "ollama",
                                                                config: seedCfg),
                       ["options": .object(["seed": .int(42)])])
        // bool seed 拒绝
        let boolSeed = optionsConfig(["m1": .object(["seed": .bool(true)])])
        XCTAssertEqual(NativeWorkflowHTTPConnector.modelOptions(model: "m1", backend: "ollama",
                                                                config: boolSeed), [:])
        // stripTag
        XCTAssertEqual(NativeWorkflowHTTPConnector.stripTag("qwen3.8:latest"), "qwen3.8")
        XCTAssertEqual(NativeWorkflowHTTPConnector.stripTag("plain"), "plain")
    }

    // ════════════════════════════════════════════════════════════
    // MARK: A. _parse_image / 错误载体
    // ════════════════════════════════════════════════════════════

    func testParseImage() throws {
        // data URI → 取逗号后段
        XCTAssertEqual(NativeWorkflowHTTPConnector.parseImage("data:image/png;base64,QUJD"),
                       "QUJD")
        // data: 无逗号 → ""（Python split 兜底怪癖保留）
        XCTAssertEqual(NativeWorkflowHTTPConnector.parseImage("data:"), "")
        // 存在的文件 → base64
        let f = tmp.appendingPathComponent("img.bin")
        try Data([0x41, 0x42]).write(to: f)
        XCTAssertEqual(NativeWorkflowHTTPConnector.parseImage(f.path), "QUI=")
        // >50 字符视为已编码 base64
        let long = String(repeating: "A", count: 51)
        XCTAssertEqual(NativeWorkflowHTTPConnector.parseImage(long), long)
        // >8MB 丢弃
        let huge = String(repeating: "A", count: 8_000_001)
        XCTAssertNil(NativeWorkflowHTTPConnector.parseImage(huge))
        // 短无效路径 → nil
        XCTAssertNil(NativeWorkflowHTTPConnector.parseImage("/no/such/file.jpg"))
    }

    func testConnectorErrorPythonNames() {
        XCTAssertEqual(WorkflowConnectorError.timeout.pyTypeName, "TimeoutError")
        XCTAssertEqual(WorkflowConnectorError.timeout.pyMessage, "")
        XCTAssertEqual(WorkflowConnectorError.api(status: 500, prefix: "对话请求失败").pyTypeName,
                       "OllamaAPIError")
        XCTAssertEqual(WorkflowConnectorError.api(status: 500, prefix: "对话请求失败").pyMessage,
                       "对话请求失败（HTTP 500）")
        XCTAssertEqual(WorkflowConnectorError.network("拒绝").pyTypeName, "ConnectError")
        XCTAssertEqual(WorkflowConnectorError.unsupportedBackend("x").pyTypeName, "RuntimeError")
    }

    // ════════════════════════════════════════════════════════════
    // MARK: B. create/update/delete 端点语义（app.py L2231-2282）
    // ════════════════════════════════════════════════════════════

    private func typedDef(_ nodes: [WorkflowNode],
                          _ edges: [WorkflowEdge] = []) -> WorkflowDefinition {
        WorkflowDefinition(nodes: nodes, edges: edges)
    }

    func testCreateWorkflowLooseValidation() async throws {
        let (client, kernel) = makeClient()
        // 硬伤（非法节点类型）→ 422，detail = 前 5 条「；」拼接（app.py L2238）
        let bad = typedDef([WorkflowNode(id: "s", type: "bogus")])
        do {
            _ = try await client.createWorkflow(name: "x", description: "", definition: bad)
            XCTFail("应抛 422")
        } catch SidecarError.httpError(let status, let detail) {
            XCTAssertEqual(status, 422)
            XCTAssertEqual(detail, "节点[0] 类型无效：'bogus'（应为 "
                + "('start', 'inference', 'tool', 'condition', 'parallel', 'loop', "
                + "'approval', 'file_input', 'file_output', 'file_read', "
                + "'text_output', 'variable_set', 'code', 'reply', 'end')）")
        }
        // 多条错误 → 「；」拼接
        let multi = typedDef([WorkflowNode(id: "s", type: "bogus"),
                              WorkflowNode(id: "t", type: "inference")])   // 缺 model
        do {
            _ = try await client.createWorkflow(name: "x", description: "", definition: multi)
            XCTFail("应抛 422")
        } catch SidecarError.httpError(let status, let detail) {
            XCTAssertEqual(status, 422)
            XCTAssertTrue(detail.contains("；"), detail)
            XCTAssertTrue(detail.contains("节点[1]（推理）缺少 model"), detail)
        }
        // 半成品（仅 start）→ 宽松校验放行（A1a，0.2.1 修正）
        let half = typedDef([WorkflowNode(id: "s", type: "start",
                                        props: ["label": .string("开始")])])
        let wid = try await client.createWorkflow(name: "半成品", description: "", definition: half)
        XCTAssertEqual(try kernel.workflow.getWorkflowRow(wid)?.name, "半成品")
    }

    func testCreateWorkflowNameFallback() async throws {
        let (client, kernel) = makeClient()
        // name.strip() 空 → 「未命名工作流」（app.py L2239）
        let wid = try await client.createWorkflow(
            name: "   ", description: "", definition: .startOnly())
        XCTAssertEqual(try kernel.workflow.getWorkflowRow(wid)?.name, "未命名工作流")
        let wid2 = try await client.createWorkflow(
            name: "  带名  ", description: "", definition: .startOnly())
        XCTAssertEqual(try kernel.workflow.getWorkflowRow(wid2)?.name, "带名")
    }

    func testUpdateWorkflowGuards() async throws {
        let (client, kernel) = makeClient()
        let wid = try await client.createWorkflow(name: "旧名", description: "",
                                                  definition: .startOnly())
        // 404 → 403（内置）→ 422（定义硬伤）→ 成功 的守卫序（app.py L2252-2269）
        do {
            try await client.updateWorkflow(id: "ghost", update: .init(name: "x"))
            XCTFail("应抛 404")
        } catch SidecarError.httpError(let status, let detail) {
            XCTAssertEqual(status, 404)
            XCTAssertEqual(detail, "工作流不存在")
        }
        let builtInId = try kernel.workflow.createWorkflow(name: "内置",
                                                           definition: .object([:]),
                                                           builtIn: true)
        do {
            try await client.updateWorkflow(id: builtInId, update: .init(name: "x"))
            XCTFail("应抛 403")
        } catch SidecarError.httpError(let status, let detail) {
            XCTAssertEqual(status, 403)
            XCTAssertEqual(detail, "内置工作流不可修改")
        }
        do {
            try await client.updateWorkflow(
                id: wid, update: .init(definition: typedDef([WorkflowNode(id: "s", type: "bogus")])))
            XCTFail("应抛 422")
        } catch SidecarError.httpError(let status, _) {
            XCTAssertEqual(status, 422)
        }
        // definition 为 nil 不校验；部分更新只动 name
        try await client.updateWorkflow(id: wid, update: .init(name: "新名"))
        XCTAssertEqual(try kernel.workflow.getWorkflowRow(wid)?.name, "新名")
    }

    func testDeleteWorkflowGuards() async throws {
        let (client, kernel) = makeClient()
        do {
            try await client.deleteWorkflow(id: "ghost")
            XCTFail("应抛 404")
        } catch SidecarError.httpError(let status, let detail) {
            XCTAssertEqual(status, 404)
            XCTAssertEqual(detail, "工作流不存在")
        }
        let builtInId = try kernel.workflow.createWorkflow(name: "内置",
                                                           definition: .object([:]),
                                                           builtIn: true)
        do {
            try await client.deleteWorkflow(id: builtInId)
            XCTFail("应抛 403")
        } catch SidecarError.httpError(let status, let detail) {
            XCTAssertEqual(status, 403)
            XCTAssertEqual(detail, "内置工作流不可删除")
        }
        let wid = try await client.createWorkflow(name: "可删", description: "",
                                                  definition: .startOnly())
        try await client.deleteWorkflow(id: wid)
        XCTAssertNil(try kernel.workflow.getWorkflowRow(wid))
    }

    // ════════════════════════════════════════════════════════════
    // MARK: B. run 端点（app.py L2285-2321）
    // ════════════════════════════════════════════════════════════

    func testRunWorkflowNotFound() async throws {
        let (client, _) = makeClient()
        let stream = client.runWorkflow(id: "ghost", params: [:])
        do {
            for try await _ in stream {}
            XCTFail("应抛 404")
        } catch SidecarError.httpError(let status, let detail) {
            XCTAssertEqual(status, 404)
            XCTAssertEqual(detail, "工作流不存在")
        }
    }

    /// 契约点 1：保存时宽松（strict=false 可存半成品）→ 运行前严格（422）。
    func testRunWorkflowStrict422() async throws {
        let (client, kernel) = makeClient()
        // 经端点保存半成品（宽松放行），再运行 → 严格校验拦截
        let wid = try await client.createWorkflow(name: "半成品", description: "",
                                                  definition: .startOnly())
        let stream = client.runWorkflow(id: wid, params: [:])
        do {
            for try await _ in stream {}
            XCTFail("应抛 422")
        } catch SidecarError.httpError(let status, let detail) {
            XCTAssertEqual(status, 422)
            XCTAssertEqual(detail, "工作流定义有错误：必须至少有一个结束节点")
        }
        // 422 时未建运行记录（校验在建记录之前——app.py L2292 vs L2296）
        XCTAssertEqual(try kernel.workflow.listWorkflowRuns(workflowId: wid).count, 0)
    }

    /// run 成功路径：引擎事件映射 SSE（rawData 为可解析 JSON、逐事件带 run_id）。
    func testRunWorkflowEventMapping() async throws {
        let (client, kernel) = makeClient()
        let def = WorkflowDefinition(
            nodes: [WorkflowNode(id: "s", type: "start", props: ["label": .string("开始")]),
                    WorkflowNode(id: "t1", type: "text_output",
                                 props: ["template": .string("结果 {{params.x}}")]),
                    WorkflowNode(id: "e", type: "end",
                                 props: ["output": .string("{{t1.output}}")])],
            edges: [WorkflowEdge(from: "s", to: "t1"), WorkflowEdge(from: "t1", to: "e")])
        let wid = try await client.createWorkflow(name: "跑通", description: "", definition: def)
        let stream = client.runWorkflow(id: wid, params: ["x": .string("甲")])
        var events: [SSEEvent] = []
        for try await ev in stream { events.append(ev) }
        XCTAssertEqual(events.last?.event, "workflow_done")
        // 每帧 rawData 可解析且带 run_id（_sse_format 对齐）
        var runId = ""
        for ev in events {
            let parsed = NativeJSONWriter.loads(Data(ev.rawData.utf8))
            XCTAssertNotNil(parsed, ev.rawData)
            XCTAssertNotNil(parsed?.object?["run_id"]?.string, ev.rawData)
            runId = parsed?.object?["run_id"]?.string ?? runId
        }
        // 终态落库 + 结果透传
        let run = try XCTUnwrap(try kernel.workflow.getWorkflowRun(runId))
        XCTAssertEqual(run.status, "done")
        XCTAssertEqual(run.result, "结果 甲")
    }

    /// list_workflow_runs：limit 端点层钳 min(max(1),100)（app.py L2326）。
    func testListWorkflowRunsLimitClamp() async throws {
        let (client, kernel) = makeClient()
        let wid = try await client.createWorkflow(name: "wf", description: "",
                                                  definition: .startOnly())
        for _ in 0..<3 { _ = try kernel.workflow.createWorkflowRun(workflowId: wid) }
        let clampedLow = try await client.listWorkflowRuns(workflowId: wid, limit: 0)
        let two = try await client.listWorkflowRuns(workflowId: wid, limit: 2)
        let clampedHigh = try await client.listWorkflowRuns(workflowId: wid, limit: 500)
        XCTAssertEqual(clampedLow.count, 1)
        XCTAssertEqual(two.count, 2)
        XCTAssertEqual(clampedHigh.count, 3)
    }

    // ════════════════════════════════════════════════════════════
    // MARK: B. approve 端点（app.py L2338-2351；契约点 5）
    // ════════════════════════════════════════════════════════════

    func testApproveConflictSemantics() async throws {
        let (client, kernel) = makeClient()
        let wid = try await client.createWorkflow(name: "wf", description: "",
                                                  definition: .startOnly())
        // 404
        do {
            try await client.approveWorkflowRun(runId: "ghost", approved: true, comment: "")
            XCTFail("应抛 404")
        } catch SidecarError.httpError(let status, let detail) {
            XCTAssertEqual(status, 404)
            XCTAssertEqual(detail, "运行记录不存在")
        }
        // 非 awaiting_approval → 409「当前状态 X 不在等待审批」
        let rid = try kernel.workflow.createWorkflowRun(workflowId: wid)
        do {
            try await client.approveWorkflowRun(runId: rid, approved: true, comment: "")
            XCTFail("应抛 409")
        } catch SidecarError.httpError(let status, let detail) {
            XCTAssertEqual(status, 409)
            XCTAssertEqual(detail, "当前状态 running 不在等待审批")
        }
        // awaiting_approval 但注册表无条目（运行已结束）→ 409「审批已失效」
        _ = try kernel.workflow.updateWorkflowRun(rid, status: "awaiting_approval")
        do {
            try await client.approveWorkflowRun(runId: rid, approved: true, comment: "")
            XCTFail("应抛 409")
        } catch SidecarError.httpError(let status, let detail) {
            XCTAssertEqual(status, 409)
            XCTAssertEqual(detail, "审批已失效（运行可能已结束）")
        }
        // 注册表有条目 → 决议成功 + 状态恢复 running（app.py L2350）
        kernel.workflowRuntime.registerApproval(rid)
        try await client.approveWorkflowRun(runId: rid, approved: false, comment: "驳回")
        XCTAssertEqual(kernel.workflowRuntime.approvalDecision(rid)?.approved, false)
        XCTAssertEqual(kernel.workflowRuntime.approvalDecision(rid)?.comment, "驳回")
        XCTAssertEqual(try kernel.workflow.getWorkflowRun(rid)?.status, "running")
    }

    // ════════════════════════════════════════════════════════════
    // MARK: B. stop 端点（app.py L2354-2365；契约点 3）
    // ════════════════════════════════════════════════════════════

    func testStopNonRunningReturnsOkFalse() async throws {
        let (client, kernel) = makeClient()
        let wid = try await client.createWorkflow(name: "wf", description: "",
                                                  definition: .startOnly())
        // 404 仍抛错
        do {
            try await client.stopWorkflowRun(runId: "ghost")
            XCTFail("应抛 404")
        } catch SidecarError.httpError(let status, let detail) {
            XCTAssertEqual(status, 404)
            XCTAssertEqual(detail, "运行记录不存在")
        }
        // 非进行中（done/failed/stopped）→ ok:false 语义：不抛错返回，**且不动取消标志**
        for status in ["done", "failed", "stopped"] {
            let rid = try kernel.workflow.createWorkflowRun(workflowId: wid)
            _ = try kernel.workflow.updateWorkflowRun(rid, status: status)
            try await client.stopWorkflowRun(runId: rid)   // 不抛错 = ok:false 路径
            XCTAssertFalse(kernel.workflowRuntime.isCancelled(rid),
                           "status=\(status) 不应置取消标志")
            // 状态不被改写
            XCTAssertEqual(try kernel.workflow.getWorkflowRun(rid)?.status, status)
        }
    }

    func testStopRunningRequestsCancel() async throws {
        let (client, kernel) = makeClient()
        let wid = try await client.createWorkflow(name: "wf", description: "",
                                                  definition: .startOnly())
        let rid = try kernel.workflow.createWorkflowRun(workflowId: wid)
        try await client.stopWorkflowRun(runId: rid)
        // running → 置取消标志（app.py L2362）
        XCTAssertTrue(kernel.workflowRuntime.isCancelled(rid))
        // 取消后清理（clear_workflow_cancel 语义：下次同 id 运行不被误取消）
        kernel.workflowRuntime.clearCancel(rid)
        XCTAssertFalse(kernel.workflowRuntime.isCancelled(rid))
    }

    /// awaiting_approval 停止：置取消 + 驳回审批解锁（app.py L2363-2364 双动作）。
    func testStopAwaitingApprovalResolvesRejection() async throws {
        let (client, kernel) = makeClient()
        let wid = try await client.createWorkflow(name: "wf", description: "",
                                                  definition: .startOnly())
        let rid = try kernel.workflow.createWorkflowRun(workflowId: wid)
        _ = try kernel.workflow.updateWorkflowRun(rid, status: "awaiting_approval")
        kernel.workflowRuntime.registerApproval(rid)   // 模拟引擎挂起中
        try await client.stopWorkflowRun(runId: rid)
        XCTAssertTrue(kernel.workflowRuntime.isCancelled(rid))
        // 审批被驳回解锁（comment「用户已停止」——引擎醒后走取消路径）
        XCTAssertEqual(kernel.workflowRuntime.approvalDecision(rid)?.approved, false)
        XCTAssertEqual(kernel.workflowRuntime.approvalDecision(rid)?.comment, "用户已停止")
    }

    /// 工作流为原生模块：端点直落内核（P3-W6 起 HTTP fallback 层已退役，
    /// 历史上经 WFMockFallback 录证「不触网」——如今无网可触，直验行为）。
    func testWorkflowEndpointsServedNatively() async throws {
        let (client, _) = makeClient()
        _ = try await client.listWorkflows()
        _ = try await client.createWorkflow(name: "x", description: "", definition: .startOnly())
        client.ollamaTagsFetcher = { _ in [] }   // 钉空名单保确定性
        let models = try await client.listModels()   // ollama 空名单直返空（与侧车代理同源）
        XCTAssertEqual(models, [])
    }
}
