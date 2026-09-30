//
//  NativeRoundtableTests.swift
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

//  逐条翻译 subagent/sidecar/agent_engine/test_roundtable.py（⛔ 行为规格源
//  Python，语义以源码为准）：
//    1  create 校验链（topic 空/参与者<2/参与者不存在/AI 主持不在参与者中）
//    2  用户主持：一轮发言 + 纪要更新 + waiting_user
//    3  发言失败跳过继续（ok=0 落「（本轮发言失败）」，整场不中断）
//    4  AI 主持：否→锁内自动续轮→是→confirm_end
//    5  AI 主持达 max_rounds 未共识 → waiting_user（交用户决定）
//    6  finish：总结成功 → done；6b 总结失败 → 纪要兜底仍 done
//    7  纪要更新失败 → 保留旧纪要（含【议题】初始结构）
//    8  共识宽松判定（是/否/乱答/异常四分支）
//    9  TS-109 增强：附件注入发言提示词（每轮独立注入，不依赖纪要保留）
//    10 TS-109 增强：导出 Markdown（默认存项目工作目录 roundtables/，非数据目录）
//    11 TS-109 增强：删除圆桌（全清）
//
//  隔离纪律：mktemp 数据根 + 假 connector（ScriptConn 按调用序回吐，"__RAISE__"
//  抛错），不打真网络/模型；取消标志各用例 setUp 复位。
//  ⚠️VERIFY 未翻（原因）：无（本文件全量直译；端点层附件预处理/600s 客户端
//  超时不属内核——见 NativeRoundtable.swift 头注偏差②③）。
//  形态适配（非规格偏差）：
//    · Python 单脚本 main() 顺序段间共享 rt2/rt3 → XCTest 各用例自建圆桌
//      （同一规格，无顺序依赖）。
//    · Python ValueError → NativeRoundtableError（message 逐字）。
//

import XCTest
@testable import VetarAINative

/// test_roundtable.ScriptConn 等价：按调用序返回脚本的假 connector。
/// 脚本项 "__RAISE__" 抛错；超界钳到最后一项（Python min(calls, len-1)）。
private final class RTScriptConn: NativeChatConnector, @unchecked Sendable {
    struct Boom: Error, CustomStringConvertible { var description: String { "模型调用失败(模拟)" } }
    let scripts: [String]
    private(set) var calls = 0
    private(set) var callsLog: [(model: String, messages: [[String: JSONValue]])] = []

    init(_ scripts: [String]) { self.scripts = scripts }

    func chat(model: String, messages: [[String: JSONValue]]) async throws -> String {
        let i = min(calls, scripts.count - 1)
        let item = scripts[i]
        calls += 1
        callsLog.append((model, messages))
        if item == "__RAISE__" { throw Boom() }
        return item
    }

    func chatStream(model: String, messages: [[String: JSONValue]],
                    tools: [JSONValue]?, images: [String]?)
        -> AsyncThrowingStream<NativeChatStreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }   // 圆桌全走 chat 非流式
    }
}

final class NativeRoundtableTests: XCTestCase {

    private var tmp: URL!
    private var db: NativeDatabase!
    private var pid: String!
    private var a1: String!
    private var a2: String!
    private var a3: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("p2w4d_rt_\(UUID().uuidString)")
        db = NativeDatabase(projectsRoot: tmp.appendingPathComponent("projects"))
        pid = try db.createProject(name: "rt-proj",
                                   workingDir: tmp.appendingPathComponent("wd").path)
        a1 = try db.addAgentConfig(projectId: pid, name: "产品", type: "main",
                                   role: "产品经理", modelName: "qwen3.8")
        a2 = try db.addAgentConfig(projectId: pid, name: "技术", type: "main",
                                   role: "技术负责人", modelName: "qwen3.8")
        a3 = try db.addAgentConfig(projectId: pid, name: "法务", type: "sub",
                                   role: "法务", modelName: "qwen3.8")
        NativeRoundtable.resetSharedState()
    }

    override func tearDownWithError() throws {
        NativeRoundtable.resetSharedState()
        try? FileManager.default.removeItem(at: tmp)
        try super.tearDownWithError()
    }

    private func makeEngine(_ conn: any NativeChatConnector) -> NativeRoundtableEngine {
        NativeRoundtableEngine(db: db, connector: conn)
    }

    /// 断言抛 NativeRoundtableError 且文案逐字（Python ValueError 等价）。
    private func assertValueError(_ expected: String,
                                  _ body: () async throws -> Void,
                                  _ label: String) async {
        do {
            try await body()
            XCTFail("\(label)：未抛错")
        } catch let e as NativeRoundtableError {
            XCTAssertEqual(e.message, expected, label)
        } catch {
            XCTFail("\(label)：错误类型不符 \(error)")
        }
    }

    // ══ 1. create 校验 ══

    func test1_createValidation() async throws {
        await assertValueError("议题不能为空", {
            _ = try await makeEngine(RTScriptConn(["x"]))
                .createAndStart(projectId: pid, topic: "  ", agentIds: [a1, a2])
        }, "1a topic 空 报错")
        await assertValueError("圆桌至少需要 2 个参与者", {
            _ = try await makeEngine(RTScriptConn(["x"]))
                .createAndStart(projectId: pid, topic: "t", agentIds: [a1])
        }, "1b 参与者<2 报错")
        await assertValueError("参与者不存在: ghost", {
            _ = try await makeEngine(RTScriptConn(["x"]))
                .createAndStart(projectId: pid, topic: "t", agentIds: [a1, "ghost"])
        }, "1c 参与者不存在 报错")
        await assertValueError("AI 主持时 moderator_agent_id 必须是参与者之一", {
            _ = try await makeEngine(RTScriptConn(["x"]))
                .createAndStart(projectId: pid, topic: "t", agentIds: [a1, a2],
                                moderator: "ai", moderatorAgentId: "ghost")
        }, "1d AI 主持不在参与者中 报错")
    }

    // ══ 2. 用户主持：一轮发言 + 纪要更新 + waiting_user ══

    func test2_userModeratorOneRound() async throws {
        let conn = RTScriptConn(["产品观点：应当做", "技术观点：成本高", "【共识】都想做好产品"])
        let rt = try await makeEngine(conn)
            .createAndStart(projectId: pid, topic: "要不要做 X 功能", agentIds: [a1, a2])
        XCTAssertEqual(rt.status, "waiting_user", "2a 用户主持一轮后 waiting_user")
        XCTAssertEqual(rt.round, 1, "2b round=1")
        XCTAssertEqual(rt.minutes, "【共识】都想做好产品", "2c 纪要已更新")
        let msgs = try db.listRoundtableMessages(projectId: pid, rtId: rt.id)
        XCTAssertEqual(msgs.count, 2, "2d 两参与者各发言 1 条落库")
        XCTAssertEqual(Set(msgs.map { $0.agentName }), ["产品", "技术"])
        XCTAssertTrue(msgs.allSatisfy { $0.ok }, "2d 全部 ok")
    }

    // ══ 3. 发言失败跳过继续 ══

    func test3_speechFailureSkips() async throws {
        let conn = RTScriptConn(["产品观点 ok", "__RAISE__", "纪要v2"])
        let rt = try await makeEngine(conn)
            .createAndStart(projectId: pid, topic: "议题 3", agentIds: [a1, a2])
        let msgs = try db.listRoundtableMessages(projectId: pid, rtId: rt.id)
        XCTAssertEqual(msgs.count, 2, "3a 两条发言均落库")
        XCTAssertTrue(msgs[0].ok, "3a 首条 ok=1")
        XCTAssertFalse(msgs[1].ok, "3a 次条 ok=0")
        XCTAssertEqual(msgs[1].content, "（本轮发言失败）", "3a 失败占位文案")
        XCTAssertEqual(rt.status, "waiting_user", "3b 状态仍 waiting_user（整场继续）")
        XCTAssertEqual(rt.minutes, "纪要v2", "3b 纪要照常更新（不中断）")
    }

    // ══ 4. AI 主持：否→自动续轮→是→confirm_end ══

    func test4_aiModeratorAutoContinueToConsensus() async throws {
        // 调用序：轮1 发言x2 纪要x1 判定(否) 轮2 发言x2 纪要x1 判定(是)
        let conn = RTScriptConn(["A1观点", "A2观点", "纪要r1", "达成共识：否，尚有分歧",
                                 "A1观点2", "A2观点2", "纪要r2", "达成共识：是，各方一致"])
        let rt = try await makeEngine(conn)
            .createAndStart(projectId: pid, topic: "议题 4", agentIds: [a1, a2],
                            moderator: "ai", moderatorAgentId: a1)
        XCTAssertEqual(rt.status, "confirm_end", "4a 共识后 confirm_end")
        XCTAssertEqual(rt.round, 2, "4a 未共识自动续轮到 round=2")
        let msgs = try db.listRoundtableMessages(projectId: pid, rtId: rt.id)
        XCTAssertEqual(msgs.count, 4, "4b 两轮共 4 条发言")
        XCTAssertEqual(conn.calls, 8, "4b 调用序完整消费（发言x4+纪要x2+判定x2）")
    }

    // ══ 5. AI 主持达 max_rounds 未共识 → waiting_user ══

    func test5_aiModeratorMaxRoundsToWaitingUser() async throws {
        // max_rounds=2：轮1 否 + 轮2 否 → waiting_user
        let conn = RTScriptConn(["v1", "v2", "纪要1", "达成共识：否",
                                 "v3", "v4", "纪要2", "达成共识：否"])
        let rt = try await makeEngine(conn)
            .createAndStart(projectId: pid, topic: "议题 5", agentIds: [a1, a2],
                            moderator: "ai", moderatorAgentId: a1, maxRounds: 2)
        XCTAssertEqual(rt.status, "waiting_user", "5 达上限未共识 → waiting_user（交用户决定）")
        XCTAssertEqual(rt.round, 2)
    }

    // ══ 6. finish：总结成功 → done ══

    func test6_finishDoneAndSummary() async throws {
        let rt0 = try await makeEngine(RTScriptConn(["观点一", "观点二", "纪要"]))
            .createAndStart(projectId: pid, topic: "议题 6", agentIds: [a1, a2])
        let conn = RTScriptConn(["【共识】都好【分歧】无【结论】做【建议】尽快"])
        let rt = try await makeEngine(conn).finishRoundtable(projectId: pid, rtId: rt0.id)
        XCTAssertEqual(rt.status, "done", "6a finish 后 done")
        XCTAssertTrue(rt.summary?.hasPrefix("【共识】") == true, "6a summary 落库")
    }

    // ══ 6b. finish：总结失败 → 纪要兜底仍 done ══

    func test6b_finishFailureFallback() async throws {
        let rt0 = try await makeEngine(RTScriptConn(["观点一", "观点二", "纪要"]))
            .createAndStart(projectId: pid, topic: "议题 6b", agentIds: [a1, a2])
        let rt = try await makeEngine(RTScriptConn(["__RAISE__"]))
            .finishRoundtable(projectId: pid, rtId: rt0.id)
        XCTAssertEqual(rt.status, "done", "6b 总结失败仍 done")
        XCTAssertTrue(rt.summary?.hasPrefix("（总结生成失败") == true,
                      "6b 纪要兜底（含失败标注）")
    }

    // ══ 7. 纪要更新失败 → 保留旧纪要 ══

    func test7_minutesUpdateFailureKeepsOld() async throws {
        let conn = RTScriptConn(["观点一", "观点二", "__RAISE__"])   // 纪要调用抛错
        let rt = try await makeEngine(conn)
            .createAndStart(projectId: pid, topic: "议题 7", agentIds: [a1, a2])
        XCTAssertTrue(rt.minutes?.contains("【议题】议题 7") == true,
                      "7 纪要更新失败保留旧纪要（含【议题】初始结构）")
    }

    // ══ 8. 共识宽松判定 ══

    func test8_consensusLooseJudgement() async throws {
        let moderator: [String: JSONValue] = ["name": .string("主持")]
        let (yes, _) = await NativeRoundtableEngine.judgeConsensus(
            conn: RTScriptConn(["达成共识：是\n理由"]), moderator: moderator,
            topic: "t", minutes: "m")
        XCTAssertTrue(yes, "8a 首行'达成共识：是' → 共识")
        let (no, _) = await NativeRoundtableEngine.judgeConsensus(
            conn: RTScriptConn(["达成共识：否"]), moderator: moderator,
            topic: "t", minutes: "m")
        XCTAssertFalse(no, "8b 首行'达成共识：否' → 不共识")
        let (gibberish, _) = await NativeRoundtableEngine.judgeConsensus(
            conn: RTScriptConn(["这个嘛，很难说"]), moderator: moderator,
            topic: "t", minutes: "m")
        XCTAssertFalse(gibberish, "8c 乱答 → 按未共识")
        let (boom, _) = await NativeRoundtableEngine.judgeConsensus(
            conn: RTScriptConn(["__RAISE__"]), moderator: moderator,
            topic: "t", minutes: "m")
        XCTAssertFalse(boom, "8d 判定调用异常 → 按未共识")
    }

    // ══ 9. TS-109 增强：附件注入发言提示词（每轮独立注入）══

    func test9_attachmentsInjectedIntoSpeechPrompts() async throws {
        let conn = RTScriptConn(["P发言", "T发言", "纪要v"])
        let attachments: [[String: JSONValue]] = [[
            "name": .string("材料.txt"), "text": .string("材料正文ABC"),
            "truncated": .bool(false)]]
        let rt = try await makeEngine(conn)
            .createAndStart(projectId: pid, topic: "带材料的议题", agentIds: [a1, a2],
                            attachments: attachments)
        // 两次发言调用的 user 提示词都应含材料正文（纪要被重写也不丢失）
        let speechPrompts = conn.callsLog.prefix(2)
            .compactMap { $0.messages.last?["content"]?.string }
        XCTAssertEqual(speechPrompts.count, 2, "9a 两次发言调用")
        XCTAssertTrue(speechPrompts.allSatisfy { $0.contains("材料正文ABC") },
                      "9a 每轮发言提示词均注入材料正文")
        XCTAssertEqual(rt.attachments.count, 1, "9b attachments 元数据落库")
        XCTAssertEqual(rt.attachments.first?["name"], .string("材料.txt"))
    }

    // ══ 10. TS-109 增强：导出 Markdown ══

    func test10_exportMarkdown() async throws {
        let conn = RTScriptConn(["P发言", "T发言", "纪要v"])
        let attachments: [[String: JSONValue]] = [[
            "name": .string("材料.txt"), "text": .string("材料正文ABC"),
            "truncated": .bool(false)]]
        let rt = try await makeEngine(conn)
            .createAndStart(projectId: pid, topic: "带材料的议题", agentIds: [a1, a2],
                            attachments: attachments)
        let out = try makeEngine(conn).exportRoundtableMd(projectId: pid, rtId: rt.id)
        let outURL = URL(fileURLWithPath: out.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path),
                      "10a 导出返回路径且文件存在")
        let content = try String(contentsOf: outURL, encoding: .utf8)
        XCTAssertTrue(content.contains("带材料的议题")
                      && content.contains("## 讨论纪要")
                      && content.contains("P发言")
                      && content.contains("材料.txt"),
                      "10b 导出内容含议题/纪要/发言/附件标注")
        // 10c：默认保存到项目工作目录（建项目时选的文件夹）下的 roundtables/
        let wdResolved = NativeConfigStore.resolvePath(
            NativeConfigStore.expandUser(tmp.appendingPathComponent("wd").path)
                .standardizedFileURL)
        XCTAssertEqual(outURL.deletingLastPathComponent().path,
                       wdResolved.appendingPathComponent("roundtables").path,
                       "10c 默认保存到项目工作目录下的 roundtables/（非软件数据目录）")
    }

    // ══ 11. TS-109 增强：删除圆桌（全清）══

    func test11_deleteRoundtable() async throws {
        let rt = try await makeEngine(RTScriptConn(["P发言", "T发言", "纪要v"]))
            .createAndStart(projectId: pid, topic: "待删除议题", agentIds: [a1, a2])
        let before = try db.listRoundtableMessages(projectId: pid, rtId: rt.id).count
        let deleted = try db.deleteRoundtable(projectId: pid, rtId: rt.id)
        XCTAssertTrue(deleted, "11a 删除返回 True")
        XCTAssertNil(try db.getRoundtable(projectId: pid, rtId: rt.id),
                     "11b 删除后详情为 nil")
        let after = try db.listRoundtableMessages(projectId: pid, rtId: rt.id).count
        XCTAssertTrue(after == 0 && before > 0, "11c 删除后发言全清")
    }
}
