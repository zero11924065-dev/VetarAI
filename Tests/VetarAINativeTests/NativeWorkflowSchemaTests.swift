//
//  NativeWorkflowSchemaTests.swift
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

//  逐条对照 subagent/sidecar/workflow/schema.py（⛔ 只读行为规格源，346 行）：
//    · NODE_TYPES 15 类 / CONDITION_OPERATORS 7 种（顺序保真，校验文案整串内嵌）
//    · validate_definition(strict:)：创建/保存 strict=false 容忍半成品（0.2.1 修正），
//      运行前 strict=true 把关完整性（恰好一个 start / 至少一个 end / 无孤岛）
//    · 各节点必填字段与错误文案逐字（含 Python repr/tuple repr 形态）
//    · REQ-WF-015：inference/condition 的 timeout_s 校验（strict 与非 strict 同校，
//      对齐 test_req_wf_015_timeout.py A1-A12）
//    · 隐式可达边：parallel.branches 与 loop.branch（逗号串/数组）不算孤岛（G6）
//

import XCTest
@testable import VetarAINative

final class NativeWorkflowSchemaTests: XCTestCase {

    // MARK: - 构造助手

    private func node(_ id: String, _ type: String,
                      _ props: [String: JSONValue] = [:]) -> JSONValue {
        var o = props
        o["id"] = .string(id)
        o["type"] = .string(type)
        return .object(o)
    }

    private func edge(_ from: String, _ to: String, _ when: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["from": .string(from), "to": .string(to)]
        if let when { o["when"] = .string(when) }
        return .object(o)
    }

    private func def(_ nodes: [JSONValue], _ edges: [JSONValue] = [],
                     params: [String: JSONValue] = [:]) -> JSONValue {
        .object(["nodes": .array(nodes), "edges": .array(edges), "params": .object(params)])
    }

    /// Python NODE_TYPES tuple repr（schema.py L45-48 顺序）。
    private let nodeTypesRepr = "('start', 'inference', 'tool', 'condition', 'parallel', 'loop', "
        + "'approval', 'file_input', 'file_output', 'file_read', "
        + "'text_output', 'variable_set', 'code', 'reply', 'end')"
    /// Python CONDITION_OPERATORS tuple repr（schema.py L51）。
    private let condOpsRepr = "('contains', 'not_contains', 'equals', 'starts_with', "
        + "'regex', 'empty', 'not_empty')"

    // MARK: - 常量表（schema.py L45-51）

    func testNodeTypesAndOperatorsExact() {
        XCTAssertEqual(NativeWorkflowSchema.nodeTypes, [
            "start", "inference", "tool", "condition", "parallel", "loop",
            "approval", "file_input", "file_output", "file_read",
            "text_output", "variable_set", "code", "reply", "end",
        ])
        XCTAssertEqual(NativeWorkflowSchema.conditionOperators, [
            "contains", "not_contains", "equals", "starts_with", "regex", "empty", "not_empty",
        ])
    }

    // MARK: - default_start_definition（schema.py L175-181）

    func testDefaultStartDefinition() {
        let def = NativeWorkflowSchema.defaultStartDefinition()
        // 逐字段：仅一个 start 节点、label 开始、空 edges、空 params
        XCTAssertEqual(def.object?["nodes"]?.array?.count, 1)
        XCTAssertEqual(def.object?["nodes"]?.array?.first?.object?["id"], .string("start"))
        XCTAssertEqual(def.object?["nodes"]?.array?.first?.object?["type"], .string("start"))
        XCTAssertEqual(def.object?["nodes"]?.array?.first?.object?["label"], .string("开始"))
        XCTAssertEqual(def.object?["edges"], .array([]))
        XCTAssertEqual(def.object?["params"], .object([:]))
        // 半成品：宽松可存，严格被拦（缺 end）
        XCTAssertEqual(NativeWorkflowSchema.validateDefinition(def, strict: false), [])
        XCTAssertEqual(NativeWorkflowSchema.validateDefinition(def, strict: true),
                       ["必须至少有一个结束节点"])
    }

    // MARK: - 定义形态（schema.py L266-273）

    func testDefinitionShapeErrors() {
        XCTAssertEqual(NativeWorkflowSchema.validateDefinition(.string("junk"), strict: false),
                       ["定义必须是 JSON 对象"])
        XCTAssertEqual(NativeWorkflowSchema.validateDefinition(.null, strict: true),
                       ["定义必须是 JSON 对象"])
        // nodes 缺失 / 空 / 非列表
        XCTAssertEqual(NativeWorkflowSchema.validateDefinition(.object(["edges": .array([])]),
                                                               strict: false),
                       ["nodes 必须是非空列表"])
        XCTAssertEqual(NativeWorkflowSchema.validateDefinition(
            def([], []), strict: false), ["nodes 必须是非空列表"])
        XCTAssertEqual(NativeWorkflowSchema.validateDefinition(
            .object(["nodes": .string("x"), "edges": .array([])]), strict: false),
            ["nodes 必须是非空列表"])
        // edges 缺失 / 非列表
        XCTAssertEqual(NativeWorkflowSchema.validateDefinition(
            .object(["nodes": .array([node("s", "start")])]), strict: false),
            ["edges 必须是列表"])
        XCTAssertEqual(NativeWorkflowSchema.validateDefinition(
            .object(["nodes": .array([node("s", "start")]), "edges": .int(1)]), strict: false),
            ["edges 必须是列表"])
    }

    // MARK: - 宽松 vs 严格（0.2.1 修正口径；checkpoint077 A1a/A1b/A1c）

    func testLooseToleratesHalfBuilt() {
        // 只有 start 的半成品：strict=false 全绿
        let half = def([node("s", "start")])
        XCTAssertEqual(NativeWorkflowSchema.validateDefinition(half, strict: false), [])
        // strict=true：缺 end + start 数校验
        let errs = NativeWorkflowSchema.validateDefinition(half, strict: true)
        XCTAssertEqual(errs, ["必须至少有一个结束节点"])
    }

    func testStrictStartEndCounts() {
        let endNode = node("e", "end")
        // 0 个 start
        let noStart = def([endNode])
        XCTAssertTrue(NativeWorkflowSchema.validateDefinition(noStart, strict: true)
            .contains("必须恰好有一个开始节点（当前 0 个）"))
        // 2 个 start
        let twoStart = def([node("s1", "start"), node("s2", "start"), endNode],
                           [edge("s1", "e"), edge("s2", "e")])
        XCTAssertTrue(NativeWorkflowSchema.validateDefinition(twoStart, strict: true)
            .contains("必须恰好有一个开始节点（当前 2 个）"))
        // 非 strict 不校 start/end 数量
        XCTAssertEqual(NativeWorkflowSchema.validateDefinition(noStart, strict: false), [])
    }

    // MARK: - 节点硬伤（类型/id/边引用）

    func testInvalidNodeTypeMessage() {
        let d = def([node("s", "start"), node("n1", "bogus"), node("e", "end")],
                    [edge("s", "n1"), edge("n1", "e")])
        let errs = NativeWorkflowSchema.validateDefinition(d, strict: false)
        XCTAssertEqual(errs, ["节点[1] 类型无效：'bogus'（应为 \(nodeTypesRepr)）"])
    }

    func testMissingNodeTypeRendersNone() {
        // Python node.get("type") → None → repr None（schema.py L189-190）
        let d = def([.object(["id": .string("n1")])])
        let errs = NativeWorkflowSchema.validateDefinition(d, strict: false)
        XCTAssertEqual(errs, ["节点[0] 类型无效：None（应为 \(nodeTypesRepr)）"])
    }

    func testNodeIdMissingAndDuplicate() {
        let d = def([
            node("n1", "start"),
            .object(["type": .string("tool")]),          // 缺 id
            node("n1", "end"),                            // 重复 id
        ])
        let errs = NativeWorkflowSchema.validateDefinition(d, strict: false)
        XCTAssertTrue(errs.contains("节点[1] 缺少 id"))
        XCTAssertTrue(errs.contains("节点 id 重复：n1"))
    }

    func testEdgeEndpointErrors() {
        let d = def([node("s", "start"), node("e", "end")],
                    [edge("ghost", "e"), edge("s", "nope"), .string("bad"), .object([:])])
        let errs = NativeWorkflowSchema.validateDefinition(d, strict: false)
        XCTAssertTrue(errs.contains("边[0] 起点不存在：'ghost'"))
        XCTAssertTrue(errs.contains("边[1] 终点不存在：'nope'"))
        XCTAssertTrue(errs.contains("边[2] 必须是对象"))
        // 缺 from/to → str(...)="" 不在 ids → repr 渲染 None
        XCTAssertTrue(errs.contains("边[3] 起点不存在：None"))
        XCTAssertTrue(errs.contains("边[3] 终点不存在：None"))
    }

    // MARK: - 孤岛检测（strict 限定；label 优先；隐式边）

    func testIslandDetectionStrictOnly() {
        let island = node("iso", "text_output", ["template": .string("x"), "label": .string("孤立")])
        let d = def([node("s", "start"), node("e", "end"), island], [edge("s", "e")])
        XCTAssertEqual(NativeWorkflowSchema.validateDefinition(d, strict: false), [])
        XCTAssertEqual(NativeWorkflowSchema.validateDefinition(d, strict: true),
                       ["节点「孤立」未与开始节点连通"])
        // 无 label → 回退 id
        var noLabel = island.object!
        noLabel.removeValue(forKey: "label")
        let d2 = def([node("s", "start"), node("e", "end"), .object(noLabel)], [edge("s", "e")])
        XCTAssertEqual(NativeWorkflowSchema.validateDefinition(d2, strict: true),
                       ["节点「iso」未与开始节点连通"])
    }

    func testImplicitReachabilityParallelAndLoop() {
        // G6：parallel.branches 与 loop.branch（逗号串/数组）算可达边，不报孤岛
        let d = def([
            node("s", "start"),
            node("p", "parallel", ["branches": .array([.string("b1"), .string("b2")])]),
            node("b1", "text_output", ["template": .string("A")]),
            node("b2", "text_output", ["template": .string("B")]),
            node("lp", "loop", ["items": .array([.string("x")]),
                                "branch": .string("c1, c2")]),   // 逗号链字符串
            node("c1", "text_output", ["template": .string("C1")]),
            node("c2", "text_output", ["template": .string("C2")]),
            node("lp2", "loop", ["items": .array([.string("y")]),
                                 "branch": .array([.string("d1")])]),  // 数组形态
            node("d1", "text_output", ["template": .string("D1")]),
            node("e", "end"),
        ], [
            edge("s", "p"), edge("p", "lp"), edge("lp", "lp2"), edge("lp2", "e"),
        ])
        XCTAssertEqual(NativeWorkflowSchema.validateDefinition(d, strict: true), [])
    }

    // MARK: - 各节点必填（schema.py _node_errors）

    func testInferenceRequiresModel() {
        let d = def([node("s", "start"), node("n1", "inference"), node("e", "end")],
                    [edge("s", "n1"), edge("n1", "e")])
        XCTAssertEqual(NativeWorkflowSchema.validateDefinition(d, strict: false),
                       ["节点[1]（推理）缺少 model"])
        // 空白 model 同样拦截
        let d2 = def([node("s", "start"), node("n1", "inference", ["model": .string("  ")]),
                      node("e", "end")], [edge("s", "n1"), edge("n1", "e")])
        XCTAssertEqual(NativeWorkflowSchema.validateDefinition(d2, strict: true),
                       ["节点[1]（推理）缺少 model"])
    }

    func testConditionValidation() {
        // operator 缺失 → None repr + tuple 清单
        let d = def([node("s", "start"), node("c", "condition"), node("e", "end")],
                    [edge("s", "c"), edge("c", "e")])
        let errs = NativeWorkflowSchema.validateDefinition(d, strict: false)
        XCTAssertEqual(errs, [
            "节点[1]（条件）operator 无效：None（应为 \(condOpsRepr)）",
            "节点[1]（条件）静态匹配缺少 value，或需配置 model 走动态裁判",
        ])
        // operator 非法值
        let bad = def([node("s", "start"),
                       node("c", "condition", ["match": .object(["operator": .string("bogus")])]),
                       node("e", "end")], [edge("s", "c"), edge("c", "e")])
        XCTAssertTrue(NativeWorkflowSchema.validateDefinition(bad, strict: false)
            .contains("节点[1]（条件）operator 无效：'bogus'（应为 \(condOpsRepr)）"))
        // empty/not_empty 不需要 value
        let ok = def([node("s", "start"),
                      node("c", "condition", ["match": .object(["operator": .string("empty"),
                                                                "variable": .string("{{x}}")])]),
                      node("e", "end")], [edge("s", "c"), edge("c", "e")])
        XCTAssertEqual(NativeWorkflowSchema.validateDefinition(ok, strict: true), [])
        // 有 model 走动态裁判 → 不需要静态 value；operator 给了且合法 → 两路皆不报错
        // （REQ-WF-016 后 model 存在时 operator 校验整体跳过，见下方两向用例）
        let dyn = def([node("s", "start"),
                       node("c", "condition", ["model": .string("judge"),
                                               "match": .object(["operator": .string("contains")])]),
                       node("e", "end")], [edge("s", "c"), edge("c", "e")])
        XCTAssertEqual(NativeWorkflowSchema.validateDefinition(dyn, strict: true), [])
        // 怪癖保留：value 为 null → str(None)="None" 非空 → 不报缺 value
        let nullVal = def([node("s", "start"),
                           node("c", "condition", ["match": .object(["operator": .string("contains"),
                                                                     "value": .null])]),
                           node("e", "end")], [edge("s", "c"), edge("c", "e")])
        XCTAssertEqual(NativeWorkflowSchema.validateDefinition(nullVal, strict: true), [])
    }

    // MARK: - REQ-WF-016（0.7.4 判缺陷修）：动态裁判跳过 operator 必填

    /// 两向：①有 model 无 operator → 通过（动态裁判不读 match.operator）；
    /// ②无 model 无 operator → 仍报 operator 无效（静态匹配唯一判定，必填保留）。
    func testConditionDynamicJudgeSkipsOperator() {
        // ① 只配 model 不配 match（旧 schema.py:207-211 复刻缺陷的原始翻车形态）
        let dynOnly = def([node("s", "start"),
                           node("c", "condition", ["model": .string("judge")]),
                           node("e", "end")], [edge("s", "c"), edge("c", "e")])
        XCTAssertEqual(NativeWorkflowSchema.validateDefinition(dynOnly, strict: true), [],
                       "有 model 无 operator → 通过（动态裁判）")
        XCTAssertEqual(NativeWorkflowSchema.validateDefinition(dynOnly, strict: false), [],
                       "strict=false 同样通过（保存态口径一致）")
        // ①b 有 model 且 operator 是非法值：动态裁判路径不读 operator → 不报错
        let dynBadOp = def([node("s", "start"),
                            node("c", "condition", ["model": .string("judge"),
                                                    "match": .object(["operator": .string("bogus")])]),
                            node("e", "end")], [edge("s", "c"), edge("c", "e")])
        XCTAssertEqual(NativeWorkflowSchema.validateDefinition(dynBadOp, strict: true), [],
                       "有 model + operator 非法值 → 跳过 operator 校验")
        // ② 无 model 无 operator → 仍报（含缺 value 指引，与旧口径逐字一致）
        let stat = def([node("s", "start"), node("c", "condition"), node("e", "end")],
                       [edge("s", "c"), edge("c", "e")])
        XCTAssertEqual(NativeWorkflowSchema.validateDefinition(stat, strict: true), [
            "节点[1]（条件）operator 无效：None（应为 \(condOpsRepr)）",
            "节点[1]（条件）静态匹配缺少 value，或需配置 model 走动态裁判",
        ], "无 model 无 operator → operator 必填校验保留")
    }

    func testFileNodeRequiredFields() {
        func errs(_ n: JSONValue) -> [String] {
            NativeWorkflowSchema.validateDefinition(
                def([node("s", "start"), n, node("e", "end")],
                    [edge("s", "n1"), edge("n1", "e")]), strict: true)
        }
        XCTAssertEqual(errs(node("n1", "file_input")), ["节点[1]（文件输入）缺少 path"])
        XCTAssertEqual(errs(node("n1", "file_read")), ["节点[1]（文件读取）缺少 path"])
        XCTAssertEqual(errs(node("n1", "file_output")),
                       ["节点[1]（文件输出）缺少 dir", "节点[1]（文件输出）缺少 filename"])
        XCTAssertEqual(errs(node("n1", "file_input", ["path": .string("/tmp")])), [])
        XCTAssertEqual(errs(node("n1", "file_output", ["dir": .string("/tmp/o"),
                                                       "filename": .string("r.txt"),
                                                       "content": .string("x")])), [])
    }

    func testTS121NodeRequiredFields() {
        func errs(_ n: JSONValue) -> [String] {
            NativeWorkflowSchema.validateDefinition(
                def([node("s", "start"), n, node("e", "end")],
                    [edge("s", "n1"), edge("n1", "e")]), strict: true)
        }
        XCTAssertEqual(errs(node("n1", "text_output")), ["节点[1]（文本输出）缺少 template（内容模板）"])
        XCTAssertEqual(errs(node("n1", "variable_set")), ["节点[1]（变量赋值）缺少变量名"])
        XCTAssertEqual(errs(node("n1", "code")), ["节点[1]（代码执行）缺少 code"])
        XCTAssertEqual(errs(node("n1", "reply")), ["节点[1]（消息回复）缺少 text"])
    }

    func testVariableSetNameRules() {
        func errs(_ name: String) -> [String] {
            NativeWorkflowSchema.validateDefinition(
                def([node("s", "start"),
                     node("n1", "variable_set", ["name": .string(name)]),
                     node("e", "end")], [edge("s", "n1"), edge("n1", "e")]), strict: true)
        }
        XCTAssertEqual(errs("a.b"), ["节点[1]（变量赋值）变量名不能含 . 或 /：'a.b'"])
        XCTAssertEqual(errs("a/b"), ["节点[1]（变量赋值）变量名不能含 . 或 /：'a/b'"])
        for reserved in ["params", "item", "item_index", "batch"] {
            XCTAssertEqual(errs(reserved),
                           ["节点[1]（变量赋值）'\(reserved)' 是保留名，请换一个变量名"])
        }
        XCTAssertEqual(errs("total"), [])
    }

    // MARK: - REQ-WF-015：timeout_s 校验（test_req_wf_015_timeout.py A1-A12 逐条）

    private func timeoutDefn(_ ntype: String, _ ts: JSONValue?) -> JSONValue {
        var props: [String: JSONValue] = [:]
        if ntype == "inference" { props["model"] = .string("m1") }
        if ntype == "condition" {
            props["match"] = .object(["operator": .string("contains"), "value": .string("y")])
        }
        if let ts { props["timeout_s"] = ts }
        return def([node("s", "start"), node("n1", ntype, props), node("e", "end")],
                   [edge("s", "n1"), edge("n1", "e")])
    }

    func testTimeoutSAccepted() {
        for ts in [JSONValue.int(1200), .int(10), .int(7200), .double(600.5)] {
            XCTAssertEqual(NativeWorkflowSchema.validateDefinition(timeoutDefn("inference", ts),
                                                                   strict: true), [], "\(ts)")
            XCTAssertEqual(NativeWorkflowSchema.validateDefinition(timeoutDefn("inference", ts),
                                                                   strict: false), [], "\(ts)")
        }
        // 不配 timeout_s → 照旧通过（可选字段）
        XCTAssertEqual(NativeWorkflowSchema.validateDefinition(timeoutDefn("inference", nil),
                                                               strict: true), [])
        // 条件节点合法值
        XCTAssertEqual(NativeWorkflowSchema.validateDefinition(timeoutDefn("condition", .int(900)),
                                                               strict: true), [])
    }

    func testTimeoutSOutOfRange() {
        // 越界：strict 与非 strict 同样拦截（_node_errors 两路共用）
        XCTAssertEqual(NativeWorkflowSchema.validateDefinition(timeoutDefn("inference", .int(5)),
                                                               strict: false),
                       ["节点[1]（推理）timeout_s 越界：5（合法范围 10~7200 秒）"])
        XCTAssertEqual(NativeWorkflowSchema.validateDefinition(timeoutDefn("inference", .int(99999)),
                                                               strict: true),
                       ["节点[1]（推理）timeout_s 越界：99999（合法范围 10~7200 秒）"])
        XCTAssertEqual(NativeWorkflowSchema.validateDefinition(timeoutDefn("condition", .int(1)),
                                                               strict: false),
                       ["节点[1]（条件）timeout_s 越界：1（合法范围 10~7200 秒）"])
        // 浮点越界：repr 保真（600.5 形态）
        XCTAssertEqual(NativeWorkflowSchema.validateDefinition(timeoutDefn("inference",
                                                                           .double(99999.5)),
                                                               strict: false),
                       ["节点[1]（推理）timeout_s 越界：99999.5（合法范围 10~7200 秒）"])
    }

    func testTimeoutSNonNumeric() {
        // 字符串（A8）：type 名 str + repr 引号
        XCTAssertEqual(NativeWorkflowSchema.validateDefinition(timeoutDefn("inference",
                                                                           .string("1200")),
                                                               strict: false),
                       ["节点[1]（推理）timeout_s 必须是数值（秒），实为 str：'1200'"])
        // bool（A9：True 会变 1.0，常见误配）
        XCTAssertEqual(NativeWorkflowSchema.validateDefinition(timeoutDefn("inference",
                                                                           .bool(true)),
                                                               strict: false),
                       ["节点[1]（推理）timeout_s 必须是数值（秒），实为 bool：True"])
        // 列表
        XCTAssertEqual(NativeWorkflowSchema.validateDefinition(timeoutDefn("condition",
                                                                           .array([.int(10)])),
                                                               strict: true),
                       ["节点[1]（条件）timeout_s 必须是数值（秒），实为 list：[10]"])
    }

    func testTimeoutSIgnoredForOtherTypes() {
        // A12：code 节点自己的 timeout_s（1~300）不受新校验影响
        let d = def([node("s", "start"),
                     node("n1", "code", ["code": .string("result=1"), "timeout_s": .int(60)]),
                     node("e", "end")], [edge("s", "n1"), edge("n1", "e")])
        XCTAssertEqual(NativeWorkflowSchema.validateDefinition(d, strict: false), [])
        // code 越界也不管（引擎侧 clamp 1~300 兜底，schema 不拦）
        let d2 = def([node("s", "start"),
                      node("n1", "code", ["code": .string("result=1"), "timeout_s": .int(9999)]),
                      node("e", "end")], [edge("s", "n1"), edge("n1", "e")])
        XCTAssertEqual(NativeWorkflowSchema.validateDefinition(d2, strict: true), [])
    }

    // MARK: - 错误排序（节点错 → start/end → 边错 → 孤岛）

    func testErrorOrdering() {
        let d = def([node("n1", "inference"), node("n1", "end")],
                    [edge("ghost", "n1")])
        let errs = NativeWorkflowSchema.validateDefinition(d, strict: true)
        XCTAssertEqual(errs, [
            "节点[0]（推理）缺少 model",
            "节点 id 重复：n1",
            "必须恰好有一个开始节点（当前 0 个）",
            "边[0] 起点不存在：'ghost'",
        ])
    }

    // MARK: - WorkflowDefinition ↔ JSONValue 桥（props 保真）

    func testTypedBridgeRoundtrip() {
        let typed = WorkflowDefinition(
            nodes: [
                WorkflowNode(id: "s", type: "start", props: ["label": .string("开始")]),
                WorkflowNode(id: "n1", type: "inference",
                             props: ["model": .string("qwen3.8:latest"),
                                     "timeout_s": .int(1200),
                                     "match": .object(["op": .string("x")])]),  // 未知键保真
                WorkflowNode(id: "e", type: "end"),
            ],
            edges: [WorkflowEdge(from: "s", to: "n1"), WorkflowEdge(from: "n1", to: "e", when: "true")],
            params: ["dir": .string("/tmp")])
        let json = typed.asJSONValue
        // 引擎消费形态：when 缺省键省略（Python dict 无该键）
        let edges = json.object?["edges"]?.array
        XCTAssertEqual(edges?.count, 2)
        XCTAssertNil(edges?[0].object?["when"])
        XCTAssertEqual(edges?[1].object?["when"], .string("true"))
        // props 合入节点对象顶层（与 Python 节点 dict 同构）
        XCTAssertEqual(json.object?["nodes"]?.array?[1].object?["timeout_s"], .int(1200))
        // 往返无损
        XCTAssertEqual(WorkflowDefinition.fromJSONValue(json), typed)
    }

    func testTypedBridgeTolerantDecode() {
        // store.py JSONDecodeError 兜底等价：坏形态 → 空 nodes/edges
        XCTAssertEqual(WorkflowDefinition.fromJSONValue(.string("junk")), WorkflowDefinition())
        XCTAssertEqual(WorkflowDefinition.fromJSONValue(.object(["nodes": .string("bad")])),
                       WorkflowDefinition())
        // 边缺 from/to（非字符串）→ 跳过该边
        let v = WorkflowDefinition.fromJSONValue(.object([
            "nodes": .array([.object(["id": .string("s"), "type": .string("start")])]),
            "edges": .array([.object(["from": .int(1), "to": .string("e")]),
                             .object(["from": .string("s"), "to": .string("e")])]),
        ]))
        XCTAssertEqual(v.nodes.count, 1)
        XCTAssertEqual(v.edges, [WorkflowEdge(from: "s", to: "e")])
    }

    // MARK: - WFText Python 文本语义（文案保真基石抽查）

    func testWFTextPythonSemantics() {
        // pyStr
        XCTAssertEqual(WFText.pyStr(.null), "None")
        XCTAssertEqual(WFText.pyStr(.bool(true)), "True")
        XCTAssertEqual(WFText.pyStr(.int(3)), "3")
        XCTAssertEqual(WFText.pyStr(.double(15.0)), "15.0")
        XCTAssertEqual(WFText.pyStr(.array([.int(1), .string("a")])),
                       "[1, 'a']")   // list 容器走 repr 元素
        XCTAssertEqual(WFText.pyStr(.object(["b": .int(2), "a": .int(1)])),
                       "{'a': 1, 'b': 2}")   // 字典序（确定性口径）
        // pyRepr / pyReprString
        XCTAssertEqual(WFText.pyRepr(.string("abc")), "'abc'")
        XCTAssertEqual(WFText.pyRepr(.string("it's")), "\"it's\"")
        XCTAssertEqual(WFText.pyReprString("a\"b"), "'a\"b'")
        XCTAssertEqual(WFText.pyReprString("a\nb"), "'a\\nb'")
        XCTAssertEqual(WFText.pyRepr(.null), "None")
        // truthy（Python 真值表）
        for falsy in [JSONValue.null, .bool(false), .int(0), .double(0),
                      .string(""), .array([]), .object([:])] {
            XCTAssertFalse(WFText.truthy(falsy), "\(falsy)")
        }
        for truthy in [JSONValue.bool(true), .int(-1), .string("0"), .array([.null])] {
            XCTAssertTrue(WFText.truthy(truthy), "\(truthy)")
        }
        // strOrEmpty：假值 → ""
        XCTAssertEqual(WFText.strOrEmpty(.int(0)), "")
        XCTAssertEqual(WFText.strOrEmpty(.string("x")), "x")
        XCTAssertEqual(WFText.strOrEmpty(nil), "")
        // pyTypeName
        XCTAssertEqual(WFText.pyTypeName(.object([:])), "dict")
        XCTAssertEqual(WFText.pyTypeName(.double(1.5)), "float")
        XCTAssertEqual(WFText.pyTypeName(.null), "NoneType")
        // pyPrefix（码点切片）
        XCTAssertEqual(WFText.pyPrefix("abcdef", 3), "abc")
        XCTAssertEqual(WFText.pyPrefix("汉字𠀀", 2), "汉字")
        XCTAssertEqual(WFText.pyPrefix("ab", 5), "ab")
        // pyTupleRepr
        XCTAssertEqual(WFText.pyTupleRepr(["a", "b"]), "('a', 'b')")
        XCTAssertEqual(WFText.pyListRepr(["jpg", "png"]), "['jpg', 'png']")
    }
}
