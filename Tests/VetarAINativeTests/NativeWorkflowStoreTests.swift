//
//  NativeWorkflowStoreTests.swift
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

//  逐条对照 subagent/sidecar/storage/store.py 工作流段（L1103-1283，⛔ 只读行为规格源）：
//    · create_workflow / update_workflow（显式分支，B12）/ list_workflows（新→旧，
//      created_at DESC + rowid DESC）/ get_workflow / delete_workflow（内置不可删）
//    · definition 落库 json.dumps(ensure_ascii=False)；读回 JSONDecodeError →
//      {"nodes": [], "edges": []} 兜底（L1150-1154 / L1168-1171）
//    · workflow_runs：create（status='running' + variables JSON）/ update 显式分支 /
//      get（variables json.loads 兜底 {}）/ list（workflow_id 过滤 + limit）
//    · workflow_node_events：append（input/output_summary 截 2000）/ list（id 升序回放）
//
//  隔离纪律：mktemp 临时目录建库，绝不碰真实数据目录。
//

import XCTest
@testable import VetarAINative

final class NativeWorkflowStoreTests: XCTestCase {

    private var tmp: URL!
    private var db: NativeDatabase!
    private var store: NativeWorkflowStore!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("w2wfstore_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        db = NativeDatabase(projectsRoot: tmp.appendingPathComponent("projects"))
        store = NativeWorkflowStore(database: db)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    private func sampleDef(_ tag: String = "x") -> JSONValue {
        .object([
            "nodes": .array([
                .object(["id": .string("s"), "type": .string("start"), "label": .string("开始")]),
                .object(["id": .string("e"), "type": .string("end"),
                         "output": .string("结果\(tag)")]),
            ]),
            "edges": .array([.object(["from": .string("s"), "to": .string("e")])]),
            "params": .object(["dir": .string("/tmp/目录\(tag)")]),
        ])
    }

    // MARK: - 工作流定义 CRUD（store.py L1108-1183）

    func testWorkflowCRUD() throws {
        // create：返回小写 uuid（str(uuid.uuid4()) 形态）
        let wid = try store.createWorkflow(name: "存储测试", definition: sampleDef(),
                                           description: "描述甲")
        XCTAssertTrue(wid.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#,
                                options: .regularExpression) != nil)

        // get：字段逐条（definition 读回为解析后 JSON）
        let row = try XCTUnwrap(try store.getWorkflowRow(wid))
        XCTAssertEqual(row.name, "存储测试")
        XCTAssertEqual(row.description, "描述甲")
        XCTAssertFalse(row.builtIn)
        XCTAssertEqual(NativeWorkflowStore.parseDefinition(row.definitionText), sampleDef())
        XCTAssertFalse(row.createdAt.isEmpty)
        XCTAssertFalse(row.updatedAt.isEmpty)
        // 面板契约读面：definition 类型化 + built_in bool
        XCTAssertEqual(row.record.definition.nodes.map(\.id), ["s", "e"])
        XCTAssertEqual(row.record.definition.nodes[0].label, "开始")
        XCTAssertEqual(row.record.definition.params["dir"], .string("/tmp/目录x"))
        XCTAssertNil(try store.getWorkflowRow("nonexistent"))

        // list：新→旧（同秒靠 rowid DESC 决序——后建的排前）
        let wid2 = try store.createWorkflow(name: "第二个", definition: sampleDef("y"))
        let rows = try store.listWorkflowRows()
        XCTAssertEqual(rows.map(\.id), [wid2, wid])

        // update：显式分支部分更新（B12）
        XCTAssertTrue(try store.updateWorkflow(wid, name: "改名"))
        XCTAssertEqual(try store.getWorkflowRow(wid)?.name, "改名")
        XCTAssertEqual(try store.getWorkflowRow(wid)?.description, "描述甲")   // 未动的字段不变
        XCTAssertTrue(try store.updateWorkflow(wid, definition: sampleDef("z")))
        XCTAssertEqual(NativeWorkflowStore.parseDefinition(
            try XCTUnwrap(try store.getWorkflowRow(wid)).definitionText), sampleDef("z"))
        XCTAssertTrue(try store.updateWorkflow(wid, description: ""))   // 空串是有效值
        XCTAssertEqual(try store.getWorkflowRow(wid)?.description, "")
        // 全 nil → false（无有效更新）
        XCTAssertFalse(try store.updateWorkflow(wid))
        // 不存在 → false
        XCTAssertFalse(try store.updateWorkflow("nonexistent", name: "x"))

        // delete：内置不可删 / 不存在 false / 正常 true
        let builtInId = try store.createWorkflow(name: "内置", definition: sampleDef(),
                                                 builtIn: true)
        XCTAssertFalse(try store.deleteWorkflow(builtInId))
        XCTAssertNotNil(try store.getWorkflowRow(builtInId))
        XCTAssertFalse(try store.deleteWorkflow("nonexistent"))
        XCTAssertTrue(try store.deleteWorkflow(wid))
        XCTAssertNil(try store.getWorkflowRow(wid))
        XCTAssertFalse(try store.deleteWorkflow(wid))   // 幂等 false
    }

    /// definition JSON 落库形态：json.dumps(ensure_ascii=False) 默认分隔（', ' / ': '）。
    func testDefinitionJSONEncoding() throws {
        let wid = try store.createWorkflow(name: "编码", definition: sampleDef())
        let text = try XCTUnwrap(try store.getWorkflowRow(wid)).definitionText
        // 中文不转义（ensure_ascii=False）+ Python 默认分隔符
        XCTAssertTrue(text.hasPrefix("{"), text)
        XCTAssertTrue(text.contains("\"开始\""), text)
        XCTAssertTrue(text.contains("\": "), text)   // ': ' 键分隔
        XCTAssertTrue(text.contains(", "), text)     // ', ' 项分隔
        XCTAssertFalse(text.contains("\\u"), text)
    }

    /// definition 解析兜底：坏 JSON → {"nodes": [], "edges": []}（list/get 同路径）。
    func testParseDefinitionFallback() throws {
        let wid = try store.createWorkflow(name: "坏定义", definition: sampleDef())
        // 直接写坏 definition 文本（模拟历史脏数据）
        try db.withWriteConn(global: true) { conn in
            try conn.execute("UPDATE workflows SET definition = '{broken json' WHERE id = ?",
                             [.text(wid)])
        }
        let row = try XCTUnwrap(try store.getWorkflowRow(wid))
        let parsed = NativeWorkflowStore.parseDefinition(row.definitionText)
        XCTAssertEqual(parsed.object?["nodes"], .array([]))
        XCTAssertEqual(parsed.object?["edges"], .array([]))
        XCTAssertNil(parsed.object?["params"])   // Python 兜底 dict 无 params 键
        // 类型化读面：空定义
        XCTAssertEqual(row.record.definition, WorkflowDefinition())
    }

    // MARK: - 运行记录（store.py L1186-1254）

    func testWorkflowRunLifecycle() throws {
        let wid = try store.createWorkflow(name: "wf", definition: sampleDef())
        // create：status='running' + variables JSON
        let rid = try store.createWorkflowRun(workflowId: wid,
                                              variables: .object(["params": .object(["dir": .string("/tmp")])]))
        var run = try XCTUnwrap(try store.getWorkflowRun(rid))
        XCTAssertEqual(run.workflowId, wid)
        XCTAssertEqual(run.status, "running")
        XCTAssertNil(run.currentNode)
        XCTAssertEqual(run.variables, .object(["params": .object(["dir": .string("/tmp")])]))
        XCTAssertNil(run.result)
        XCTAssertNil(run.error)

        // create 缺省 variables → 落 {}
        let rid2 = try store.createWorkflowRun(workflowId: wid)
        XCTAssertEqual(try XCTUnwrap(try store.getWorkflowRun(rid2)).variables, .object([:]))

        // update 显式分支（逐字段）
        XCTAssertTrue(try store.updateWorkflowRun(rid, status: "awaiting_approval"))
        XCTAssertEqual(try XCTUnwrap(try store.getWorkflowRun(rid)).status, "awaiting_approval")
        XCTAssertTrue(try store.updateWorkflowRun(rid, currentNode: "n1"))
        XCTAssertEqual(try XCTUnwrap(try store.getWorkflowRun(rid)).currentNode, "n1")
        XCTAssertTrue(try store.updateWorkflowRun(rid, variables: .object(["k": .int(1)])))
        XCTAssertEqual(try XCTUnwrap(try store.getWorkflowRun(rid)).variables,
                       .object(["k": .int(1)]))
        XCTAssertTrue(try store.updateWorkflowRun(rid, result: "完成"))
        XCTAssertEqual(try XCTUnwrap(try store.getWorkflowRun(rid)).result, "完成")
        XCTAssertTrue(try store.updateWorkflowRun(rid, error: "出错了"))
        XCTAssertEqual(try XCTUnwrap(try store.getWorkflowRun(rid)).error, "出错了")
        // 全 nil → false；不存在 → false
        XCTAssertFalse(try store.updateWorkflowRun(rid))
        XCTAssertFalse(try store.updateWorkflowRun("nonexistent", status: "done"))
        run = try XCTUnwrap(try store.getWorkflowRun(rid))
        XCTAssertEqual(run.status, "awaiting_approval")   // 不被误改
    }

    /// variables 坏 JSON → json.loads 兜底 {}（store.py L1232-1234）。
    func testWorkflowRunVariablesFallback() throws {
        let wid = try store.createWorkflow(name: "wf", definition: sampleDef())
        let rid = try store.createWorkflowRun(workflowId: wid)
        try db.withWriteConn(global: true) { conn in
            try conn.execute("UPDATE workflow_runs SET variables = 'not-json' WHERE id = ?",
                             [.text(rid)])
        }
        XCTAssertEqual(try XCTUnwrap(try store.getWorkflowRun(rid)).variables, .object([:]))
    }

    /// list_workflow_runs：workflow_id 过滤 + limit + 新→旧（created_at DESC）。
    func testListWorkflowRuns() throws {
        let widA = try store.createWorkflow(name: "A", definition: sampleDef())
        let widB = try store.createWorkflow(name: "B", definition: sampleDef())
        let r1 = try store.createWorkflowRun(workflowId: widA)
        let r2 = try store.createWorkflowRun(workflowId: widA)
        let r3 = try store.createWorkflowRun(workflowId: widB)
        // 钉死 created_at 以确定性排序（同秒不靠未定义序）
        try db.withWriteConn(global: true) { conn in
            for (rid, ts) in [(r1, "2026-01-01 10:00:00"), (r2, "2026-01-01 10:00:01"),
                              (r3, "2026-01-01 10:00:02")] {
                try conn.execute("UPDATE workflow_runs SET created_at = ? WHERE id = ?",
                                 [.text(ts), .text(rid)])
            }
        }
        // 全部：新→旧
        XCTAssertEqual(try store.listWorkflowRuns().map(\.id), [r3, r2, r1])
        // 按工作流过滤
        XCTAssertEqual(try store.listWorkflowRuns(workflowId: widA).map(\.id), [r2, r1])
        // limit 生效
        XCTAssertEqual(try store.listWorkflowRuns(limit: 2).map(\.id), [r3, r2])
        // 字段形态（列表行无 variables）
        let rec = try XCTUnwrap(try store.listWorkflowRuns().first)
        XCTAssertEqual(rec.status, "running")
        XCTAssertEqual(rec.workflowId, widB)
        XCTAssertNil(rec.result)
        // WorkflowRunRow.listRecord 映射
        let detail = try XCTUnwrap(try store.getWorkflowRun(r1))
        XCTAssertEqual(detail.listRecord.id, r1)
        XCTAssertEqual(detail.listRecord.status, "running")
        XCTAssertEqual(detail.listRecord.createdAt, "2026-01-01 10:00:00")
    }

    // MARK: - 节点事件（store.py L1257-1282）

    func testNodeEvents() throws {
        let wid = try store.createWorkflow(name: "wf", definition: sampleDef())
        let rid = try store.createWorkflowRun(workflowId: wid)
        // 追加两条（running → done），字段全给
        try store.appendWorkflowNodeEvent(runId: rid, nodeId: "n1", nodeType: "inference",
                                          status: "running")
        try store.appendWorkflowNodeEvent(runId: rid, nodeId: "n1", nodeType: "inference",
                                          status: "done", modelUsed: "qwen3.8:latest",
                                          outputSummary: "输出摘要", retryCount: 1,
                                          durationMs: 1234)
        let events = try store.listWorkflowNodeEvents(rid)
        XCTAssertEqual(events.count, 2)
        // id 升序（执行序回放）
        XCTAssertLessThan(events[0].id, events[1].id)
        XCTAssertEqual(events[0].nodeId, "n1")
        XCTAssertEqual(events[0].nodeType, "inference")
        XCTAssertEqual(events[0].status, "running")
        XCTAssertNil(events[0].modelUsed)          // 未传 → NULL → nil
        XCTAssertEqual(events[0].inputSummary, "")   // 缺省空串
        XCTAssertEqual(events[0].retryCount, 0)
        XCTAssertNil(events[0].durationMs)           // 未传 → NULL → nil
        XCTAssertEqual(events[1].modelUsed, "qwen3.8:latest")
        XCTAssertEqual(events[1].outputSummary, "输出摘要")
        XCTAssertEqual(events[1].retryCount, 1)
        XCTAssertEqual(events[1].durationMs, 1234)
        // 空 run → []
        XCTAssertEqual(try store.listWorkflowNodeEvents("nonexistent"), [])
    }

    /// input/output_summary 落库截 2000（store.py L1273-1274）。
    func testNodeEventSummaryTruncation() throws {
        let rid = try store.createWorkflowRun(workflowId: "wf-x")
        let long = String(repeating: "字", count: 2500)
        try store.appendWorkflowNodeEvent(runId: rid, nodeId: "n", nodeType: "t",
                                          status: "done", inputSummary: long,
                                          outputSummary: long)
        let ev = try XCTUnwrap(try store.listWorkflowNodeEvents(rid).first)
        XCTAssertEqual(ev.inputSummary.count, 2000)
        XCTAssertEqual(ev.outputSummary.count, 2000)
    }

    /// 删除工作流后运行记录与节点事件保留作历史（store.py L1177-1183 口径）。
    func testDeleteWorkflowKeepsRunHistory() throws {
        let wid = try store.createWorkflow(name: "wf", definition: sampleDef())
        let rid = try store.createWorkflowRun(workflowId: wid)
        try store.appendWorkflowNodeEvent(runId: rid, nodeId: "s", nodeType: "start",
                                          status: "done")
        XCTAssertTrue(try store.deleteWorkflow(wid))
        XCTAssertNotNil(try store.getWorkflowRun(rid))
        XCTAssertEqual(try store.listWorkflowNodeEvents(rid).count, 1)
        XCTAssertEqual(try store.listWorkflowRuns(workflowId: wid).count, 1)
    }
}
