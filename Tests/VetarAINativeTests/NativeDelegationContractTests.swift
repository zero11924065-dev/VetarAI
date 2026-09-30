//
//  NativeDelegationContractTests.swift
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

//  逐条翻译（⛔ 行为规格源 Python，语义以源码为准）：
//    · test_delegation.py §A parse_report 交卷契约（A1-A6b）/ §B resolve_target
//      （B10-B12）/ §C tools_spec 防递归（C13）/ §E agent_tasks 存储层（E15a-e）
//    · test_delegation2.py §3 auto_create_agent（3a-3d）
//    · test_p7_delegation_body.py T1-T8（#7 JSON 块外正文并入 summary）
//    · test_p15_delegation_files.py T1-T7（file_paths 通道/只解析不读内容/
//      真实清单/任务书注入/工具规格/委派纪律/签名）
//    · test_req_agt019.py ⑥（委派纪律分批委派图片规则 + _IMAGE_INTENT_RE 边界）
//
//  ⚠️VERIFY 未翻（原因）：
//    · test_delegation2.py §1（旧表迁移 1a-1c）——已由 NativeDatabaseTests 的
//      0.2 时代旧库迁移用例覆盖（同 schema 同断言：CHECK 含 queued/数据无损/
//      幂等重连），不重复搬运。
//    · test_p7_delegation_body.py T9a/T9b——Python 源文本静态断言（loop.py /
//      delegation.py 字符串锚点），Swift 无对应物；行为面由 Engine 套件 D6 覆盖
//      （summary 经 tool_result 回主会话）。
//    · test_p7_delegation_body.py T10——用户真实库回归样本，测试环境无此库。
//    · 变异机制（MUTATE=1|2|3）——Python 源码打补丁+reload 基建，Swift 编译期
//      绑定无法同法实施（同 W4a 先例）；对应行为锚点均以强断言直译。
//  形态适配（非规格偏差）：
//    · E15c：Python 传非白名单 kwargs 被拒；Swift 白名单是编译期显式形参
//      （非白名单字段无从传入），等价断言为「全空字段更新返回 false」。
//    · T7：Python inspect 签名断言；Swift 编译期形参即证据，运行时断言改为
//      「NativeDelegationTaskRequest 正确携带 filePaths」。
//

import XCTest
@testable import VetarAINative

// MARK: - 共享夹具：锁内数组 / 假 connector（本 target 内各委派套件复用）

/// 锁内数组（并发顺序记录/跨任务收集用）。
final class LockedList<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func append(_ v: T) { lock.lock(); items.append(v); lock.unlock() }
    var snapshot: [T] { lock.lock(); defer { lock.unlock() }; return items }
    var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }
}

/// test_delegation.ScriptConn 等价：按脚本回吐一段文本；dynamic 项接 DB 最新任务 id
/// （委派执行器在跑 loop 前已落库）。
final class DelegScriptConn: NativeChatConnector, @unchecked Sendable {
    enum Item {
        case text(String)
        case dynamic(@Sendable (String) -> String)
    }
    let scripts: [Item]
    let db: NativeDatabase?
    let pid: String
    private(set) var calls = 0

    init(_ scripts: [Item], db: NativeDatabase? = nil, pid: String = "") {
        self.scripts = scripts
        self.db = db
        self.pid = pid
    }
    convenience init(_ texts: [String], db: NativeDatabase? = nil, pid: String = "") {
        self.init(texts.map { .text($0) }, db: db, pid: pid)
    }

    private func currentTid() -> String {
        guard let db else { return "" }
        return (try? db.listAgentTasks(projectId: pid, limit: 1))?.first?.id ?? ""
    }

    func chatStream(model: String, messages: [[String: JSONValue]],
                    tools: [JSONValue]?, images: [String]?)
        -> AsyncThrowingStream<NativeChatStreamEvent, Error> {
        let i = min(calls, scripts.count - 1)
        calls += 1
        let item = scripts[max(i, 0)]
        let tid = currentTid()
        return AsyncThrowingStream { cont in
            switch item {
            case .text(let t): cont.yield(.contentDelta(t))
            case .dynamic(let f): cont.yield(.contentDelta(f(tid)))
            }
            cont.yield(.done(promptEvalCount: 10, evalCount: 5))
            cont.finish()
        }
    }

    func chat(model: String, messages: [[String: JSONValue]]) async throws -> String { "" }
}

/// test_delegation2.SimpleConn 等价：主会话决策轮（content + tool_calls），
/// 记录每轮送入模型的 messages 快照（供断言 tool_report 回注内容）。
final class DelegRoundConn: NativeChatConnector, @unchecked Sendable {
    typealias Round = (content: [String], tools: [(String, [String: JSONValue])])
    let rounds: [Round]
    private(set) var calls = 0
    private(set) var seen: [[[String: JSONValue]]] = []

    init(_ rounds: [Round]) { self.rounds = rounds }

    func chatStream(model: String, messages: [[String: JSONValue]],
                    tools: [JSONValue]?, images: [String]?)
        -> AsyncThrowingStream<NativeChatStreamEvent, Error> {
        let i = min(calls, rounds.count - 1)
        calls += 1
        seen.append(messages)
        let round = rounds[i]
        let callNo = calls
        return AsyncThrowingStream { cont in
            for ch in round.content { cont.yield(.contentDelta(ch)) }
            if !round.tools.isEmpty {
                let tcs: [[String: JSONValue]] = round.tools.enumerated().map { (j, pair) in
                    ["id": .string("mock_\(callNo)_\(j)"),
                     "function": .object([
                        "name": .string(pair.0),
                        "arguments": .string(NativeDatabase.dumpsUTF8(.object(pair.1))),
                     ])]
                }
                cont.yield(.toolCalls(tcs))
            }
            cont.yield(.done(promptEvalCount: 10, evalCount: 5))
            cont.finish()
        }
    }

    func chat(model: String, messages: [[String: JSONValue]]) async throws -> String { "" }
}

/// 合法交卷 JSON（test_delegation.good_report 等价）。
func delegGoodReport(summary: String = "子任务完成",
                     artifacts: [String] = ["out.md"]) -> @Sendable (String) -> String {
    { tid in
        NativeDatabase.dumpsUTF8(.object([
            "task_id": .string(tid), "status": .string("success"),
            "summary": .string(summary),
            "artifacts": .array(artifacts.map { .string($0) }),
        ]))
    }
}

// MARK: - 测试本体

final class NativeDelegationContractTests: XCTestCase {

    private var tmp: URL!
    private var db: NativeDatabase!
    private var sandbox: URL!
    private var pid: String!
    private var mainId: String!
    private var betaId: String!
    private var bwId: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("p2w4b_contract_\(UUID().uuidString)")
        sandbox = tmp.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        db = NativeDatabase(projectsRoot: tmp.appendingPathComponent("projects"))
        pid = try db.createProject(name: "m31", workingDir: tmp.appendingPathComponent("wd").path)
        mainId = try db.addAgentConfig(projectId: pid, name: "Alpha", type: "main",
                                       modelName: "qwen3.8")
        betaId = try db.addAgentConfig(projectId: pid, name: "Beta", type: "sub",
                                       role: "写手", systemPrompt: "简洁", modelName: "qwen3.8")
        bwId = try db.addAgentConfig(projectId: pid, name: "Beta Writer", type: "sub",
                                     modelName: "qwen3.8")
        _ = try db.addAgentConfig(projectId: pid, name: "Gamma", type: "sub",
                                  modelName: "qwen3.8")
        NativeDelegationEngine.resetSharedState()
        NativeDelegationEvents.clearAll()
    }

    override func tearDownWithError() throws {
        NativeDelegationEvents.clearAll()
        try? FileManager.default.removeItem(at: tmp)
        try super.tearDownWithError()
    }

    /// Python Path.resolve() 等价（macOS /var → /private/var 符号链接，对齐 _rp 纪律）。
    private func rp(_ url: URL) -> String { url.resolvingSymlinksInPath().path }

    private func mk(_ rel: String, _ content: String = "x") throws {
        let p = sandbox.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: p.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try content.write(to: p, atomically: true, encoding: .utf8)
    }

    // ══ A. parse_report 交卷契约（test_delegation.py 任务单用例 1-5 + H17）══

    func testA_parseReport() throws {
        let tid = "task-xyz"
        let okJson = "{\"task_id\": \"\(tid)\", \"status\": \"success\", "
            + "\"summary\": \"完成了\", \"artifacts\": [\"a.md\"]}"

        let r = NativeDelegation.parseReport(okJson, taskId: tid)
        XCTAssertEqual(r?["status"]?.string, "success", "A1 纯 JSON 合法")
        XCTAssertEqual(r?["summary"]?.string, "完成了")
        XCTAssertEqual(r?["artifacts"], .array([.string("a.md")]))

        XCTAssertNotNil(NativeDelegation.parseReport("```json\n" + okJson + "\n```",
                                                     taskId: tid),
                        "A2 ```json 围栏包裹合法")
        XCTAssertNotNil(NativeDelegation.parseReport("好的，交卷：" + okJson + "（完）",
                                                     taskId: tid),
                        "A2b JSON 前后混文字可解析")

        // M7（TS-113）：≤1000 字全文接收不截断；>1000 字不在此截断但标记修正
        let j301 = "{\"task_id\": \"\(tid)\", \"status\": \"success\", "
            + "\"summary\": \"\(String(repeating: "字", count: 301))\", \"artifacts\": []}"
        let r3 = NativeDelegation.parseReport(j301, taskId: tid)
        XCTAssertNotNil(r3, "A3 summary 301 字（≤1000）→ 全文接收不截断（无修正标记）")
        XCTAssertEqual(r3?["summary"]?.string?.unicodeScalars.count, 301)
        XCTAssertNotEqual(r3?["format_corrected"], .bool(true))
        let j1001 = "{\"task_id\": \"\(tid)\", \"status\": \"success\", "
            + "\"summary\": \"\(String(repeating: "字", count: 1001))\", \"artifacts\": []}"
        let r3b = NativeDelegation.parseReport(j1001, taskId: tid)
        XCTAssertNotNil(r3b, "A3b summary 1001 字（>1000）→ 保留全文并标记修正")
        XCTAssertEqual(r3b?["summary"]?.string?.unicodeScalars.count, 1001)
        XCTAssertEqual(r3b?["format_corrected"], .bool(true))

        let r4a = NativeDelegation.parseReport(okJson, taskId: "other-id")
        XCTAssertEqual(r4a?["task_id"]?.string, "other-id",
                       "A4a task_id 不一致 → 修正为实际 id（标记修正）")
        XCTAssertEqual(r4a?["format_corrected"], .bool(true))
        let jBad = "{\"task_id\": \"\(tid)\", \"status\": \"finished\", "
            + "\"summary\": \"x\", \"artifacts\": []}"
        let r4b = NativeDelegation.parseReport(jBad, taskId: tid)
        XCTAssertEqual(r4b?["status"]?.string, "partial",
                       "A4b status 非法 → 归一 partial（标记修正）")
        XCTAssertEqual(r4b?["format_corrected"], .bool(true))
        XCTAssertNil(NativeDelegation.parseReport("我完成了任务，没有 JSON", taskId: tid),
                     "A4c 非 JSON 判不合法（走兜底打包路径）")
        let jNoSummary = "{\"task_id\": \"\(tid)\", \"status\": \"success\"}"
        XCTAssertNil(NativeDelegation.parseReport(jNoSummary, taskId: tid),
                     "A4d 缺 summary 字段判不合法")

        let jNoArt = "{\"task_id\": \"\(tid)\", \"status\": \"partial\", "
            + "\"summary\": \"部分完成\"}"
        let r5 = NativeDelegation.parseReport(jNoArt, taskId: tid)
        XCTAssertEqual(r5?["artifacts"], .array([]),
                       "A5 artifacts 缺失补 [] 后合法（无修正标记）")
        XCTAssertNotEqual(r5?["format_corrected"], .bool(true))

        let fb = NativeDelegation.buildFallbackReport(
            "重庆 2026 年养老最低基数 4359 元/月，数据来源市人社局公告。", taskId: tid)
        XCTAssertEqual(fb?["status"]?.string, "partial",
                       "A6 兜底打包：实质回复 → partial 交卷 + 标注")
        XCTAssertEqual(fb?["fallback"], .bool(true))
        XCTAssertTrue(fb?["summary"]?.string?.contains("未按契约交卷") ?? false)
        XCTAssertTrue(fb?["summary"]?.string?.contains("4359") ?? false)
        XCTAssertNil(NativeDelegation.buildFallbackReport("", taskId: tid),
                     "A6b 兜底打包：空/过短回复 → None")
        XCTAssertNil(NativeDelegation.buildFallbackReport("   ", taskId: tid))
        XCTAssertNil(NativeDelegation.buildFallbackReport("短", taskId: tid))
    }

    // ══ B. resolve_target 目标解析（test_delegation.py 用例 10-12）══

    func testB_resolveTarget() throws {
        let r1 = NativeDelegationEngine.resolveTarget(db: db, projectId: pid,
                                                target: "Beta", selfAgentId: mainId)
        XCTAssertEqual(r1.0?.id, betaId, "B10a 精确匹配 name")
        XCTAssertEqual(r1.1, "")
        let r2 = NativeDelegationEngine.resolveTarget(db: db, projectId: pid,
                                                target: betaId, selfAgentId: mainId)
        XCTAssertEqual(r2.0?.id, betaId, "B10b 精确匹配 id")
        let r3 = NativeDelegationEngine.resolveTarget(db: db, projectId: pid,
                                                target: "  bEtA  ", selfAgentId: mainId)
        XCTAssertEqual(r3.0?.id, betaId, "B10c 忽略大小写+首尾空白")

        let r4 = NativeDelegationEngine.resolveTarget(db: db, projectId: pid,
                                                target: "Writer", selfAgentId: mainId)
        XCTAssertEqual(r4.0?.id, bwId, "B11a 模糊子串命中")
        let r5 = NativeDelegationEngine.resolveTarget(db: db, projectId: pid,
                                                target: "e", selfAgentId: mainId)
        XCTAssertEqual(r5.0?.id, betaId, "B11b 多命中取 name 最短")

        let r6 = NativeDelegationEngine.resolveTarget(db: db, projectId: pid,
                                                target: "Omega", selfAgentId: mainId)
        XCTAssertNil(r6.0, "B12a 未命中返回错误+可用名单")
        XCTAssertTrue(r6.1.contains("未找到") && r6.1.contains("Beta")
                      && r6.1.contains("Gamma"), r6.1)
        XCTAssertFalse(r6.1.contains("Alpha"), "B12b 名单排除发起者自己")
        let r7 = NativeDelegationEngine.resolveTarget(db: db, projectId: pid,
                                                target: "   ", selfAgentId: mainId)
        XCTAssertNil(r7.0, "B12c 空目标提示补全参数")
        XCTAssertTrue(r7.1.contains("参数"), r7.1)
    }

    // ══ C. tools_spec 防递归（test_delegation.py 用例 13）══

    func testC_toolsSpecAntiRecursion() throws {
        let namesMain = NativeAgentLoop.toolsSpec(withDelegation: true)
            .compactMap { $0.object?["function"]?.object?["name"]?.string }
        let namesSub = NativeAgentLoop.toolsSpec(withDelegation: false)
            .compactMap { $0.object?["function"]?.object?["name"]?.string }
        XCTAssertTrue(namesMain.contains("delegate_task"), "C13a 主会话 spec 含 delegate_task")
        XCTAssertFalse(namesSub.contains("delegate_task"),
                       "C13b 子会话 spec 剔除 delegate_task")
    }

    // ══ E. agent_tasks 存储层（test_delegation.py 用例 15）══

    func testE_agentTaskStore() throws {
        let parentSid = try db.createSession(projectId: pid, agentId: mainId, title: "主会话")
        let tidE1 = try db.createAgentTask(projectId: pid, parentAgentId: mainId,
                                           parentSessionId: parentSid, targetAgentId: betaId,
                                           targetAgentName: "Beta", task: "任务1", expect: "标准1")
        let tidE2 = try db.createAgentTask(projectId: pid, parentAgentId: mainId,
                                           parentSessionId: parentSid, targetAgentId: "gid",
                                           targetAgentName: "Gamma", task: "任务2", expect: "标准2")
        let got = try db.getAgentTask(projectId: pid, taskId: tidE1)
        XCTAssertEqual(got?.targetAgentName, "Beta", "E15a create/get 字段完整")
        XCTAssertEqual(got?.task, "任务1")
        XCTAssertEqual(got?.expect, "标准1")
        XCTAssertEqual(got?.status, "queued")   // TS-108：落库初始态改排队
        XCTAssertEqual(got?.validationFailures, 0)

        let reportJson = NativeDatabase.dumpsUTF8(.object([
            "task_id": .string(tidE1), "status": .string("success"),
            "summary": .string("s"), "artifacts": .array([]),
        ]))
        let upd = try db.updateAgentTask(projectId: pid, taskId: tidE1,
                                         status: "done", report: reportJson)
        let got2 = try db.getAgentTask(projectId: pid, taskId: tidE1)
        XCTAssertTrue(upd, "E15b update 白名单字段生效 + report 反序列化")
        XCTAssertEqual(got2?.status, "done")
        XCTAssertEqual(got2?.report?.object?["summary"]?.string, "s")

        // E15c 形态适配：Swift 白名单为编译期显式形参（hack_field 无从传入）；
        // 等价断言 = 全空字段更新返回 false（Python update_agent_task 无白名单命中返 False）。
        let updAll = try db.updateAgentTask(projectId: pid, taskId: tidE1)
        XCTAssertFalse(updAll, "E15c 无白名单字段命中 → false（Python 非白名单被拒等价）")

        let lst = try db.listAgentTasks(projectId: pid)
        let ids = lst.map { $0.id }
        XCTAssertGreaterThanOrEqual(lst.count, 2, "E15d list 倒序（最新在前）")
        XCTAssertEqual(ids.first, tidE2)
        XCTAssertTrue(ids.contains(tidE1))
        XCTAssertEqual(try db.listAgentTasks(projectId: pid, limit: 1).count, 1,
                       "E15e list limit 生效")
    }

    // ══ §3. auto_create_agent（test_delegation2.py）══

    func testAutoCreateAgent() throws {
        let a1 = NativeDelegationEngine.autoCreateAgent(db: db, projectId: pid,
                                                        suggestedRole: "数据分析师",
                                                        modelName: "qwen3.8")
        XCTAssertEqual(a1.type_, "sub", "3a 正常新建（type_=sub + role 正确 + name=角色）")
        XCTAssertEqual(a1.role, "数据分析师")
        XCTAssertEqual(a1.name, "数据分析师")
        XCTAssertEqual(a1.modelName, "qwen3.8")
        let a2 = NativeDelegationEngine.autoCreateAgent(db: db, projectId: pid,
                                                        suggestedRole: "数据分析师",
                                                        modelName: "qwen3.8")
        XCTAssertEqual(a2.name, "数据分析师-2", "3b 重名追加 -2")
        let a3 = NativeDelegationEngine.autoCreateAgent(db: db, projectId: pid,
                                                        suggestedRole: "数据分析师",
                                                        modelName: "qwen3.8")
        XCTAssertEqual(a3.name, "数据分析师-3", "3c 再重名追加 -3")
        let names = try db.listAgentConfigs(projectId: pid).map { $0.name }
        XCTAssertTrue(names.contains("数据分析师"), "3d 新建后可在 Agent 列表复用")
    }

    // ══ #7 委派交卷保全文（test_p7_delegation_body.py T1-T8）══

    private func J(_ tid: String, summary: String) -> String {
        "{\"task_id\": \"\(tid)\", \"status\": \"success\", \"artifacts\": [], "
            + "\"summary\": \"\(summary)\"}"
    }

    func testP7_outsideBodyMerge() throws {
        let tid = "task-abc-123"

        // T1 核心：JSON + 块外大段正文 → 正文并入 summary
        let seg = "根据《中华人民共和国民法典》第六百七十五条，借款人应当按照约定的期限返还借款。尚欠本金 234700 元。"
        let txt = J(tid, summary: "审查完成") + "\n\n" + seg + seg
        let r = NativeDelegation.parseReport(txt, taskId: tid)
        XCTAssertNotNil(r, "T1a 解析成功")
        XCTAssertTrue(r?["summary"]?.string?.contains("民法典") ?? false,
                      "T1b ⛔ 块外正文已并入 summary（旧实现会丢弃）")
        XCTAssertTrue(r?["summary"]?.string?.contains("234700") ?? false)
        XCTAssertTrue(r?["summary"]?.string?.contains("审查完成") ?? false,
                      "T1c 原 summary 概述也保留（不是被正文替换）")
        let iS = r?["summary"]?.string?.range(of: "审查完成")
        let iB = r?["summary"]?.string?.range(of: "民法典")
        XCTAssertNotNil(iS)
        XCTAssertNotNil(iB)
        if let iS, let iB {
            XCTAssertTrue(iS.lowerBound < iB.lowerBound,
                          "T1d 概述在前、正文在后（顺序合理）")
        }
        XCTAssertEqual(r?["status"]?.string, "success",
                       "T1e status/artifacts 等结构字段不受影响")
        XCTAssertEqual(r?["task_id"]?.string, tid)

        // T2 用户实测场景规模：并入后 summary 超 1000 字 → 触发落盘
        let bigBody = String(repeating: "律师函正文内容。", count: 200)
        let r2 = NativeDelegation.parseReport(J(tid, summary: "完成审查") + "\n" + bigBody,
                                              taskId: tid)
        XCTAssertGreaterThan(r2?["summary"]?.string?.unicodeScalars.count ?? 0,
                             NativeDelegation.summaryMaxLen,
                             "T2a 大块外正文并入后 summary > SUMMARY_MAX_LEN")
        XCTAssertTrue(r2?["summary"]?.string?.contains("律师函正文内容") ?? false,
                      "T2b 正文实质内容确在 summary 内")

        // T3 短块外噪声不并入（阈值保护）
        let r3 = NativeDelegation.parseReport("好的，交卷：" + J(tid, summary: "完成了") + "（完）",
                                              taskId: tid)
        XCTAssertEqual(r3?["summary"]?.string, "完成了",
                       "T3a 块外仅短噪声（<20字）→ 不并入")
        XCTAssertGreaterThanOrEqual(NativeDelegation.outsideBodyMinLen, 10,
                                    "T3b 阈值常量存在且合理（≥10）")

        // T4 纯 JSON 无块外正文 → 行为完全不变（回归保护）
        let r4 = NativeDelegation.parseReport(J(tid, summary: "纯JSON概述"), taskId: tid)
        XCTAssertEqual(r4?["summary"]?.string, "纯JSON概述", "T4a 纯 JSON 的 summary 原样不变")
        XCTAssertEqual(r4?["summary"]?.string?.count, "纯JSON概述".count,
                       "T4b 纯 JSON 不误加任何正文")

        // T5 块外正文与 summary 已相同 → 不重复并入（防膨胀）
        let same = "这段正文同时出现在 summary 和块外，不应被并两次。"
        let r5 = NativeDelegation.parseReport(J(tid, summary: same) + "\n" + same, taskId: tid)
        XCTAssertEqual(r5?["summary"]?.string?
            .components(separatedBy: "不应被并两次").count, 2,
            "T5 块外正文已在 summary 中 → 不重复并入")

        // T6 ```json 围栏 + 块外正文 → 围栏剥离、正文仍提取
        let fenced = "前置说明文字超过二十个字符以满足最小长度阈值要求。\n```json\n"
            + J(tid, summary: "ok") + "\n```\n后置成果正文也超过二十个字符以触发并入。"
        let r6 = NativeDelegation.parseReport(fenced, taskId: tid)
        XCTAssertEqual(r6?["status"]?.string, "success", "T6a 围栏内 JSON 正常解析")
        XCTAssertTrue(r6?["summary"]?.string?.contains("前置说明文字") ?? false,
                      "T6b 围栏外的前置/后置正文都并入")
        XCTAssertTrue(r6?["summary"]?.string?.contains("后置成果正文") ?? false)
        XCTAssertFalse(r6?["summary"]?.string?.contains("```") ?? true,
                       "T6c 围栏标记 ``` 不残留在 summary")

        // T8 fallback 路径不受影响
        let noJson = "子 Agent 没输出 JSON，但写了实质成果：" + String(repeating: "成果正文内容。", count: 10)
        XCTAssertNil(NativeDelegation.parseReport(noJson, taskId: tid),
                     "T8a 无 JSON → parse_report 返回 None（走 fallback）")
        let fb = NativeDelegation.buildFallbackReport(noJson, taskId: tid)
        XCTAssertTrue(fb?["summary"]?.string?.contains("成果正文内容") ?? false,
                      "T8b fallback 仍打包全文（既有行为不变）")
        XCTAssertEqual(fb?["fallback"], .bool(true))
    }

    /// T7 _extract_outside_body 单元行为。
    func testP7_extractOutsideBody() throws {
        let tid = "task-abc-123"
        let cand = NativeDelegation.extractJsonCandidate(J(tid, summary: "x"))
        XCTAssertNotNil(cand)
        let ob = NativeDelegation.extractOutsideBody("AAA" + (cand ?? "") + "BBB",
                                                     candidate: cand)
        XCTAssertTrue(ob.contains("AAA") && ob.contains("BBB"),
                      "T7a 提取 JSON 块前后正文（块以换行替换，不粘连）")
        XCTAssertEqual(NativeDelegation.extractOutsideBody("---\n正文甲\n***\n正文乙\n===",
                                                           candidate: nil),
                       "正文甲\n正文乙",
                       "T7b 独占整行的分隔线被剥离（--- *** ===）")
        XCTAssertEqual(NativeDelegation.extractOutsideBody("", candidate: nil), "",
                       "T7c 空文本返回空串")
        XCTAssertEqual(NativeDelegation.extractOutsideBody("  全部正文  ", candidate: nil),
                       "全部正文", "T7d candidate=None 时返回全文 strip")
        XCTAssertTrue(NativeDelegation.extractOutsideBody(
            "成果：\n| 项目 | 金额 |\n|---|---|\n| 本金 | 234700 |", candidate: nil)
            .contains("|---|---|"),
            "T7e ⛔ markdown 表格分隔行 |---|---| 不被打散")
        XCTAssertTrue(NativeDelegation.extractOutsideBody("这是***非常重要***的结论",
                                                          candidate: nil)
            .contains("***非常重要***"),
            "T7g ⛔ 行内粗斜体 ***重要*** 不被拆行")
        XCTAssertTrue(NativeDelegation.extractOutsideBody("金额 2024---2025 年度",
                                                          candidate: nil)
            .contains("2024---2025"),
            "T7h ⛔ 行内破折号 2024---2025 不被切断")
    }

    // ══ #15 委派传文档路径（test_p15_delegation_files.py T1-T7）══

    func testFiles_T1_resolvePaths() throws {
        try mk("证据/律师函.docx")
        try mk("借条.txt")
        try mk("目录A/合同.docx")
        try mk("目录B/合同.docx")   // 与 A 同名 → 裸名多处命中，不猜
        try mk("图.png")           // 非文档扩展名 → 应跳过（图片走 image_paths）

        let (ok, skipped) = NativeDelegation.resolveDelegationFiles(
            ["证据/律师函.docx", "借条.txt"], sandboxRoot: sandbox.path)
        XCTAssertEqual(ok.count, 2, "相对路径解析为绝对路径")
        XCTAssertTrue(ok.allSatisfy { $0.hasPrefix("/") })
        XCTAssertTrue(ok.allSatisfy { FileManager.default.fileExists(atPath: $0) },
                      "解析结果文件真实存在")
        XCTAssertTrue(skipped.isEmpty, "相对路径无跳过")

        let abs = sandbox.appendingPathComponent("证据/律师函.docx")
        let (ok2, _) = NativeDelegation.resolveDelegationFiles([abs.path],
                                                               sandboxRoot: sandbox.path)
        XCTAssertEqual(ok2, [rp(abs)], "绝对路径直接采用")

        let (ok3, _) = NativeDelegation.resolveDelegationFiles(["律师函.docx"],
                                                               sandboxRoot: sandbox.path)
        XCTAssertEqual(ok3.count, 1, "裸文件名唯一命中 → 自纠正到子目录")
        XCTAssertTrue(ok3.first?.contains("证据") ?? false)

        let (ok4, sk4) = NativeDelegation.resolveDelegationFiles(["合同.docx"],
                                                                 sandboxRoot: sandbox.path)
        XCTAssertEqual(ok4.count, 0, "裸文件名多处同名 → 不猜、跳过")
        XCTAssertEqual(sk4, ["合同.docx"])

        let (ok5, sk5) = NativeDelegation.resolveDelegationFiles(["不存在的.docx"],
                                                                 sandboxRoot: sandbox.path)
        XCTAssertEqual(ok5.count, 0, "不存在的文件 → 跳过")
        XCTAssertEqual(sk5, ["不存在的.docx"])

        let (ok6, sk6) = NativeDelegation.resolveDelegationFiles(["图.png"],
                                                                 sandboxRoot: sandbox.path)
        XCTAssertEqual(ok6.count, 0, "非文档扩展名（图片）→ 跳过（应走 image_paths）")
        XCTAssertEqual(sk6, ["图.png"])

        let many = Array(repeating: "借条.txt", count: NativeDelegation.maxDelegationFiles + 5)
        let (ok7, sk7) = NativeDelegation.resolveDelegationFiles(many,
                                                                 sandboxRoot: sandbox.path)
        XCTAssertLessThanOrEqual(ok7.count, NativeDelegation.maxDelegationFiles,
                                 "超上限（>20）→ 截断且多余标跳过")
        XCTAssertGreaterThanOrEqual(sk7.count, 5)

        let (ok8, sk8) = NativeDelegation.resolveDelegationFiles([],
                                                                 sandboxRoot: sandbox.path)
        XCTAssertEqual(ok8, [], "空列表 → 空结果不报错")
        XCTAssertEqual(sk8, [])
        let (ok9, sk9) = NativeDelegation.resolveDelegationFiles(nil,
                                                                 sandboxRoot: sandbox.path)
        XCTAssertEqual(ok9, [], "None → 空结果不报错")
        XCTAssertEqual(sk9, [])
    }

    func testFiles_T2_noContentRead() throws {
        // ⛔ 损坏的 docx（不是合法 zip）和 0 字节文件——若"代读内容"必然失败，
        // 但它只校验路径，所以应解析成功。以此间接守住"不代读"设计。
        try mk("损坏.docx", "这不是合法 zip，只是扩展名叫 docx")
        let emptyP = sandbox.appendingPathComponent("空.docx")
        FileManager.default.createFile(atPath: emptyP.path, contents: Data())
        try mk("正常.txt", "内容")

        let (ok, skipped) = NativeDelegation.resolveDelegationFiles(
            ["损坏.docx", "空.docx", "正常.txt"], sandboxRoot: sandbox.path)
        XCTAssertTrue(ok.contains(rp(sandbox.appendingPathComponent("损坏.docx"))),
                      "损坏文档仍解析成功（证明未读内容）")
        XCTAssertTrue(ok.contains(rp(emptyP)), "0 字节文档仍解析成功（证明未读内容）")
        XCTAssertEqual(ok.count, 3, "三个路径全部解析、无跳过")
        XCTAssertTrue(skipped.isEmpty)
        XCTAssertTrue(ok.allSatisfy { FileManager.default.fileExists(atPath: $0) },
                      "返回值是路径而非内容")
    }

    func testFiles_T3_realDocsHint() throws {
        try mk("证据/律师函.docx")
        try mk("借条.txt")
        try mk("图.png")   // 图片不该出现在文档清单里
        let hint = NativeDelegation.realDocsHint(sandbox.path)
        XCTAssertTrue(hint.contains(sandbox.appendingPathComponent("证据/律师函.docx").path),
                      "清单含 docx 绝对路径")
        XCTAssertTrue(hint.contains("借条.txt"), "清单含 txt")
        XCTAssertFalse(hint.contains("图.png"), "清单不含图片（图片走 image_paths）")
        XCTAssertTrue(hint.contains("共 2 个"), "清单标注总数")

        let emptyDir = tmp.appendingPathComponent("sb3empty")
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        let hint2 = NativeDelegation.realDocsHint(emptyDir.path)
        XCTAssertTrue(hint2.contains("未找到任何文档"), "空目录如实说明未找到")
    }

    func testFiles_T4_taskMessageInjection() throws {
        let files = ["/abs/证据/律师函.docx", "/abs/借条.txt"]

        let msg = NativeDelegation.taskUserMessage(taskId: "tid-1", task: "整理证据",
                                                   expect: "输出清单", filePaths: files)
        XCTAssertTrue(msg.contains("【必读文件】"), "普通模式含【必读文件】标题")
        XCTAssertTrue(msg.contains("/abs/证据/律师函.docx") && msg.contains("/abs/借条.txt"),
                      "普通模式列出全部绝对路径")
        XCTAssertTrue(msg.contains("read_file"), "普通模式要求子 Agent 自己 read_file")
        XCTAssertTrue(msg.contains("禁止凭文件名臆测") || msg.contains("臆测"),
                      "普通模式禁止臆测内容")

        let smsg = NativeDelegation.taskUserMessageSimple(taskId: "tid-2", task: "转写",
                                                          expect: "输出文字", filePaths: files)
        XCTAssertTrue(smsg.contains("【必读文件】"), "简单模式含【必读文件】")
        XCTAssertTrue(smsg.contains("/abs/证据/律师函.docx"), "简单模式列出绝对路径")
        XCTAssertTrue(smsg.contains("read_file"), "简单模式仍要求 read_file")

        let msgNone = NativeDelegation.taskUserMessage(taskId: "tid-3", task: "算个数",
                                                       expect: "给结果", filePaths: nil)
        XCTAssertFalse(msgNone.contains("【必读文件】"), "普通模式无文件时不注入【必读文件】")
        let smsgNone = NativeDelegation.taskUserMessageSimple(taskId: "tid-4", task: "算个数",
                                                              expect: "给结果", filePaths: [])
        XCTAssertFalse(smsgNone.contains("【必读文件】"), "简单模式空列表不注入【必读文件】")

        XCTAssertTrue(msg.contains("整理证据"), "任务目标仍在")
        XCTAssertTrue(msg.contains("输出清单"), "交卷标准仍在")
    }

    func testFiles_T5_toolSpec() throws {
        let spec = NativeAgentLoop.toolsSpec(withDelegation: true)
        let dt = spec.first { $0.object?["function"]?.object?["name"]?.string == "delegate_task" }
        XCTAssertNotNil(dt, "delegate_task 工具存在")
        let props = dt?.object?["function"]?.object?["parameters"]?
            .object?["properties"]?.object ?? [:]
        XCTAssertNotNil(props["file_paths"], "含 file_paths 参数")
        XCTAssertEqual(props["file_paths"]?.object?["type"]?.string, "array",
                       "file_paths 是数组类型")
        let desc = props["file_paths"]?.object?["description"]?.string ?? ""
        XCTAssertTrue(desc.contains("read_file") || desc.contains("子 Agent"),
                      "file_paths 描述强调子 Agent 自己读")
        XCTAssertTrue(desc.contains("绝不要自己先读") || desc.contains("不要自己先读"),
                      "file_paths 描述禁止主 Agent 自读")
        let specChild = NativeAgentLoop.toolsSpec(withDelegation: false)
        XCTAssertFalse(specChild.contains {
            $0.object?["function"]?.object?["name"]?.string == "delegate_task"
        }, "子会话无 delegate_task（防递归未回归）")
    }

    func testFiles_T6_delegationDiscipline() throws {
        let prompt = NativeAgentLoop.buildSystemPrompt(
            agentName: "主理人", agentRole: "lawyer", sandboxRoot: "/tmp/sb",
            networkSwitch: "off", canDelegate: true)
        XCTAssertTrue(prompt.contains("文档传递"), "提示词含【文档传递】纪律")
        XCTAssertTrue(prompt.contains("file_paths"), "纪律要求用 file_paths 传路径")
        XCTAssertTrue(
            prompt.contains("绝不要自己先 read_file") || prompt.contains("不要自己先 read_file"),
            "纪律禁止主 Agent 自己先读全文")
        XCTAssertTrue(prompt.contains("不委派") && prompt.contains("才自己 read_file"),
                      "纪律说明只有不委派时才自读")
        XCTAssertTrue(prompt.contains("【图片传递】"), "图片传递纪律仍在（未回归）")
        let p2 = NativeAgentLoop.buildSystemPrompt(
            agentName: "子", agentRole: "x", sandboxRoot: "/tmp/sb",
            networkSwitch: "off", canDelegate: false)
        XCTAssertFalse(p2.contains("文档传递"), "can_delegate=False 不注入文档纪律")
    }

    /// T7 形态适配：Swift 编译期形参即签名证据；运行时断言请求体正确携带 filePaths。
    func testFiles_T7_signature() throws {
        let agent = try db.getAgentConfig(projectId: pid, agentId: betaId)!
        let req = NativeDelegationTaskRequest(
            projectId: pid, parentAgentId: mainId, parentSessionId: "s",
            targetAgent: agent, task: "t", expect: "e",
            sandboxRoot: sandbox.path, filePaths: ["/a/借条.txt"])
        XCTAssertEqual(req.filePaths, ["/a/借条.txt"],
                       "run_delegated_task 入参包含 file_paths（缺省 nil 不破坏既有调用方）")
        let reqDefault = NativeDelegationTaskRequest(
            projectId: pid, parentAgentId: mainId, parentSessionId: "s",
            targetAgent: agent, task: "t", expect: "e", sandboxRoot: sandbox.path)
        XCTAssertNil(reqDefault.filePaths, "file_paths 缺省 nil")
    }

    // ══ REQ-AGT-019 ⑥：提示层（分批委派图片规则 + 关键词表边界）══

    func testAgt019_promptLayerAndIntentRegex() throws {
        let sp = NativeAgentLoop.buildSystemPrompt(
            agentName: "小助手", agentRole: "工程师", sandboxRoot: "/data/ws",
            networkSwitch: "auto", canDelegate: true)
        XCTAssertTrue(sp.contains("【分批委派图片"), "6a 委派纪律含【分批委派图片】规则")
        XCTAssertTrue(sp.contains("image_paths") && sp.contains("绝对路径子集"),
                      "6b 规则要求每批经 image_paths 传该批绝对路径子集")
        XCTAssertTrue(sp.contains("无法按批拆分"),
                      "6c 规则讲明附着图无法按批拆分（分批一律 image_paths）")
        XCTAssertNotNil(NativeDelegation.imageIntentMatch("帮我做 ocr 转写"),
                        "6d 关键词表大小写不敏感（小写 ocr 命中）")
        for t in ["看这张截图", "扫描件转文字", "图中的人"] {
            XCTAssertNotNil(NativeDelegation.imageIntentMatch(t),
                            "6e 关键词表覆盖 截图/扫描件/图中：\(t)")
        }
        XCTAssertNil(NativeDelegation.imageIntentMatch("识别这段文字的语种"),
                     "6f ⛔ 裸「识别」不在关键词表（守护 ⑤ 的前提）")
    }
}
