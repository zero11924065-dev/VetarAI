//
//  NativeDelegationRouteTests.swift
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
//    · test_req_agt019.py ①-⑤（零图片+图片意图守卫 / image_paths 放行 /
//      附着图放行 / 非图片任务不误伤 / 裸「识别」关键词边界）——经真实
//      runToolLoop 驱动，run_delegated_task 以 coreOverride 打桩
//      （等价 Python patch delegation.run_delegated_task 模块属性）。
//    · test_req_agt020.py S1/S3/S4（委派写子会话消息 → 变更通知）——
//      childSessionNotifier 通知钩层面对账：写点对（任务书 user / 首轮
//      assistant / 追问 user / 追问 assistant）、session_id 归属、role 序、
//      主热路径零通知（P2-W4d 起四处写点默认硬连线真总线、钩层叠加触发，
//      钩层对账仍有效）。
//    · test_req_agt020.py S2（在线订阅者经总线队列直投实时收到 session
//      事件）——P2-W4d A13 NativeAppEvents 落地后真翻：不注入通知钩，
//      走默认总线硬连线，在线订阅者实时收 user+assistant 两条。
//
//  ⚠️VERIFY 未翻（原因）：无（S1c/S2e 的 app_events payload 字段形态由
//  NativeAppEventsTests.testAGT020_childSessionNotifyPayloadShape 对账）。
//  形态适配（非规格偏差）：
//    · AGT019 ②的 images_loaded 断言：Python 断言 tool_report 回注串含
//      '"images_loaded": 2'（json.dumps 带空格）；Swift dumps 紧凑无空格，
//      等价断言改为「回注消息含 images_loaded 键且值为 2」（解析 JSON 判定）。
//

import XCTest
@testable import VetarAINative

final class NativeDelegationRouteTests: XCTestCase {

    private var tmp: URL!
    private var db: NativeDatabase!
    private var sandbox: URL!
    private var pid: String!
    private var mainId: String!
    private var stubCalls: LockedList<NativeDelegationTaskRequest>!
    private var engine: NativeDelegationEngine!

    /// 占位 PNG 字节（按扩展名选 mime + base64，不校验 PNG 结构——同 Python 纪律）。
    private let minPNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        + Data("placeholder-png-bytes-for-agt019".utf8)

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("p2w4b_route_\(UUID().uuidString)")
        sandbox = tmp.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        // 工作目录下放 3 张真图（子目录"票据"）——供 image_paths 加载与 F1 真实清单 hint
        let receipts = sandbox.appendingPathComponent("票据")
        try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
        for i in 1...3 {
            try (minPNG + Data("\(i)".utf8))
                .write(to: receipts.appendingPathComponent("\(i).png"))
        }
        db = NativeDatabase(projectsRoot: tmp.appendingPathComponent("projects"))
        pid = try db.createProject(name: "agt019", workingDir: tmp.appendingPathComponent("wd").path)
        mainId = try db.addAgentConfig(projectId: pid, name: "Main", type: "main", modelName: "m")
        _ = try db.addAgentConfig(projectId: pid, name: "OCR专员", type: "sub", modelName: "m")
        stubCalls = LockedList<NativeDelegationTaskRequest>()
        // 打桩 run_delegated_task：记录调用 + 直接交卷（Python patch 模块属性等价）
        let calls = stubCalls!
        engine = NativeDelegationEngine(db: db,
                                        connector: DelegScriptConn([.text("unused")]),
                                        configProvider: { [:] })
        engine.coreOverride = { req in
            calls.append(req)
            return ["ok": .bool(true), "task_id": .string("t-stub"),
                    "status": .string("success"), "summary": .string("stub 交卷"),
                    "artifacts": .array([])]
        }
        NativeDelegationEngine.resetSharedState()
        NativeDelegationEvents.clearAll()
    }

    override func tearDownWithError() throws {
        NativeDelegationEvents.clearAll()
        NativeDelegationEngine.resetSharedState()
        try? FileManager.default.removeItem(at: tmp)
        try super.tearDownWithError()
    }

    /// 驱动一轮真实 runToolLoop：模型首轮发 delegate_task，次轮收尾。
    private func drive(_ task: String, expect: String = "按要求产出",
                       imagePaths: [String]? = nil, attach: [String]? = nil)
        async -> (tr: [String: JSONValue], conn: DelegRoundConn) {
        var args: [String: JSONValue] = ["target": .string("OCR专员"),
                                         "task": .string(task),
                                         "expect": .string(expect)]
        if let imagePaths { args["image_paths"] = .array(imagePaths.map { .string($0) }) }
        let conn = DelegRoundConn([
            (content: [], tools: [("delegate_task", args)]),
            (content: ["收尾"], tools: []),
        ])
        let dctx = NativeDelegationContext(projectId: pid, agentId: mainId,
                                           sessionId: "sess-1", model: "m", runner: engine)
        var tr: [String: JSONValue] = [:]
        for await ev in NativeAgentLoop.runToolLoop(
            model: "m", messages: [["role": .string("user"), "content": .string("hi")]],
            toolsSpecList: NativeAgentLoop.toolsSpec(withDelegation: true),
            sandboxRoot: sandbox.path, connector: conn, maxRounds: 4,
            firstRoundImages: attach, delegationCtx: dctx) {
            if ev.event == "tool_result" { tr = ev.data }
        }
        return (tr, conn)
    }

    // ══ ① 任务书含"图片" + 零图片零附着 → 拦截，委派未发起，回传两通道指引 ══

    func test1_zeroImageWithIntentBlocked() async throws {
        let n0 = stubCalls.count
        let (tr, _) = await drive("把本批图片逐张转写为文字", expect: "每张图的文字内容")
        let err = tr["error"]?.string ?? ""
        XCTAssertEqual(tr["ok"], .bool(false), "1a 零图片+图片意图 → tool_result ok=False")
        XCTAssertTrue(err.contains("images_missing"), "1b 错误码 images_missing")
        XCTAssertEqual(stubCalls.count, n0, "1c ⛔ 委派未真正发起（桩未被调用）")
        XCTAssertTrue(err.contains("image_paths") && err.contains("list_dir"),
                      "1d 指引含通道② image_paths + list_dir 盘点")
        XCTAssertTrue(err.contains("附着") && err.contains("自动携带"),
                      "1e 指引含通道① 聊天附着图全量自动携带")
        XCTAssertTrue(err.contains("1.png") && err.contains("共"),
                      "1f 回传 F1 风格真实图片清单（含子目录内 1.png）")
    }

    // ══ ② 传了 image_paths（真实加载成功）→ 放行，图片随委派传给子 Agent ══

    func test2_imagePathsPassThrough() async throws {
        let n0 = stubCalls.count
        let (tr, conn2) = await drive("把本批图片逐张转写为文字", expect: "每张图的文字内容",
                                      imagePaths: ["票据/1.png", "票据/2.png"])
        XCTAssertEqual(tr["ok"], .bool(true), "2a 传 image_paths → 放行（ok=True）")
        XCTAssertEqual(stubCalls.count, n0 + 1, "2b ⛔ 委派真正发起（桩被调用 1 次）")
        let imgs = stubCalls.snapshot.last?.images
        XCTAssertEqual(imgs?.count, 2, "2c 加载的 2 张图经 images 传给子 Agent")
        XCTAssertTrue(imgs?.allSatisfy { $0.hasPrefix("data:image/png;base64,") } ?? false)
        // 2d 结果如实报告 images_loaded=2（tool_report 回注模型；形态适配：解析 JSON 判值）
        let round2 = try XCTUnwrap(conn2.seen.dropFirst().first, "round2 missing")
        let reportMsg = round2.first {
            ($0["content"]?.string ?? "").contains("images_loaded")
        }
        let content = try XCTUnwrap(reportMsg?["content"]?.string,
                                    "2d 回注消息含 images_loaded")
        let parsed = try JSONDecoder().decode(JSONValue.self, from: Data(content.utf8))
        let loaded = parsed.object?["tool_report"]?.object?["result"]?
            .object?["images_loaded"]?.int
        XCTAssertEqual(loaded, 2, "2d 结果如实报告 images_loaded=2（tool_report 回注模型）")
    }

    // ══ ③ 有聊天附着图 → 放行（附着图场景不拦；附着图全量自动携带）══

    func test3_attachedImagesPassThrough() async throws {
        let n0 = stubCalls.count
        let attach = ["data:image/png;base64,QUFB"]
        let (tr, _) = await drive("将附图逐张转写为文字", expect: "转写结果", attach: attach)
        XCTAssertEqual(tr["ok"], .bool(true), "3a 附着图场景 → 放行（ok=True）")
        XCTAssertEqual(stubCalls.count, n0 + 1, "3b ⛔ 委派真正发起")
        XCTAssertEqual(stubCalls.snapshot.last?.images, attach,
                       "3c 附着图经 images 传给子 Agent（全量自动携带）")
    }

    // ══ ④ 非图片任务零图片 → 放行，守卫不误伤 ══

    func test4_nonImageTaskPasses() async throws {
        let n0 = stubCalls.count
        let (tr, _) = await drive("总结这段文字的核心观点", expect: "三段式摘要")
        XCTAssertEqual(tr["ok"], .bool(true), "4a 非图片任务零图片 → 放行（ok=True）")
        XCTAssertEqual(stubCalls.count, n0 + 1, "4b ⛔ 委派真正发起")
        XCTAssertNil(stubCalls.snapshot.last?.images,
                     "4c 无图任务的 images=None（不凭空塞图）")
    }

    // ══ ⑤ 关键词边界：含裸"识别"但不含图片词 → 放行 ══

    func test5_bareRecognizeKeywordPasses() async throws {
        let n0 = stubCalls.count
        let (tr, _) = await drive("识别这段文字的语种并给出置信度", expect: "语种+置信度")
        XCTAssertEqual(tr["ok"], .bool(true), "5a 含裸「识别」非图片任务 → 放行（ok=True）")
        XCTAssertEqual(stubCalls.count, n0 + 1, "5b ⛔ 委派真正发起")
    }
}

// ════════════════════════════════════════════════════════════
// MARK: - REQ-AGT-020：委派写子会话 → childSessionNotifier 通知钩对账
// ════════════════════════════════════════════════════════════

final class NativeDelegationNotifyTests: XCTestCase {

    private var tmp: URL!
    private var db: NativeDatabase!
    private var sandbox: URL!
    private var pid: String!
    private var mainId: String!
    private var notifications: LockedList<(projectId: String, sessionId: String, role: String)>!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("p2w4b_notify_\(UUID().uuidString)")
        sandbox = tmp.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        db = NativeDatabase(projectsRoot: tmp.appendingPathComponent("projects"))
        pid = try db.createProject(name: "agt020", workingDir: sandbox.path)
        mainId = try db.addAgentConfig(projectId: pid, name: "主 Agent", type: "main",
                                       modelName: "qwen3.6:35b")
        notifications = LockedList()
        NativeDelegationEngine.resetSharedState()
        NativeDelegationEvents.clearAll()
        NativeAppEvents.clearAll()
    }

    override func tearDownWithError() throws {
        NativeDelegationEvents.clearAll()
        NativeAppEvents.clearAll()
        NativeDelegationEngine.resetSharedState()
        try? FileManager.default.removeItem(at: tmp)
        try super.tearDownWithError()
    }

    private func makeEngine(_ conn: any NativeChatConnector) -> NativeDelegationEngine {
        let notes = notifications!
        return NativeDelegationEngine(db: db, connector: conn, configProvider: { [:] },
                                      childSessionNotifier: { p, s, r in
            notes.append((p, s, r))
        })
    }

    // ══ S1 简单模式成功路径：对账出 user+assistant 两条通知 ══

    func testS1_simpleModeNotifiesUserThenAssistant() async throws {
        let subId = try db.addAgentConfig(projectId: pid, name: "ocr专员", type: "sub",
                                          modelName: "glm-ocr:latest")
        let sub = try XCTUnwrap(try db.getAgentConfig(projectId: pid, agentId: subId))
        let imgs = ["data:image/png;base64,QUJD"]   // 带图 → 简单模式
        let res = try await makeEngine(DelegScriptConn(["识别结果：ABC"]))
            .runDelegatedTask(NativeDelegationTaskRequest(
                projectId: pid, parentAgentId: mainId, parentSessionId: "sess-main",
                targetAgent: sub, task: "识别附图文字", expect: "输出纯文字",
                sandboxRoot: sandbox.path, maxRounds: 10, images: imgs))
        XCTAssertEqual(res["ok"], .bool(true), "S1a 委派本身成功")
        let tid = try XCTUnwrap(res["task_id"]?.string)
        let childSid = try db.getAgentTask(projectId: pid, taskId: tid)?.sessionId
        let roles = notifications.snapshot.map { $0.role }
        XCTAssertEqual(roles, ["user", "assistant"],
                       "S1b 通知序为 user+assistant 两条 session 变更")
        XCTAssertNotNil(childSid, "S1c 通知 session_id 全部指向子会话")
        XCTAssertTrue(notifications.snapshot.allSatisfy { $0.sessionId == childSid })
        XCTAssertTrue(notifications.snapshot.allSatisfy { $0.projectId == pid },
                      "S1d project_id 正确")
    }

    // ══ S3 追问路径（普通模式第一轮非 JSON）：四条，role 序 u/a/u/a ══

    func testS3_retryPathNotifiesFourWrites() async throws {
        let subId = try db.addAgentConfig(projectId: pid, name: "文本专员", type: "sub",
                                          modelName: "qwen3.6:35b")
        let sub = try XCTUnwrap(try db.getAgentConfig(projectId: pid, agentId: subId))
        let conn = DelegScriptConn([
            .text("这是纯文字回复不是JSON"),
            .dynamic(delegGoodReport(summary: "补交", artifacts: [])),
        ], db: db, pid: pid)
        let res = try await makeEngine(conn)
            .runDelegatedTask(NativeDelegationTaskRequest(
                projectId: pid, parentAgentId: mainId, parentSessionId: "sess-main",
                targetAgent: sub, task: "写一段文字", expect: "输出文字",
                sandboxRoot: sandbox.path, maxRounds: 10))
        XCTAssertEqual(res["ok"], .bool(true), "S3a 追问后委派成功")
        XCTAssertEqual(notifications.snapshot.map { $0.role },
                       ["user", "assistant", "user", "assistant"],
                       "S3b 四条通知 role 序 user/assistant/user/assistant")
    }

    // ══ S4 ⛔ 主热路径守卫：直接 save_message 不产生任何通知 ══

    func testS4_hotPathSaveMessageDoesNotNotify() async throws {
        try db.saveMessage(projectId: pid, sessionId: "sess-main", agentId: mainId,
                           role: "user", content: "主会话热路径消息")
        XCTAssertEqual(notifications.count, 0,
                       "S4 直接 saveMessage（主聊天热路径）→ 零通知（不挂全局，防事件风暴）")
        XCTAssertEqual(NativeAppEvents.latestSeq(), 0,
                       "S4 直接 saveMessage → 真总线同样零事件")
    }

    // ══ S2 在线订阅者实时收到（总线队列直投，不靠缓冲补发）══
    // P2-W4d 真翻（W4b 挂起项）：⛔ 不注入 childSessionNotifier——四处写点走
    // 默认真总线硬连线（对齐 Python delegation.py 直调 app_events.notify）。

    func testS2_onlineSubscriberReceivesLiveBusEvents() async throws {
        let subId = try db.addAgentConfig(projectId: pid, name: "ocr专员", type: "sub",
                                          modelName: "glm-ocr:latest")
        let sub = try XCTUnwrap(try db.getAgentConfig(projectId: pid, agentId: subId))
        let live = LockedList<NativeAppBusEvent>()
        let consumer = Task {
            for await e in NativeAppEvents.subscribe(sinceSeq: 0, idleTimeout: 0.2) {
                if e.event == "resource_changed" { live.append(e) }
                if live.count >= 2 { break }
            }
        }
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            consumer.cancel()
        }
        // S2a/S2b：握手 + 订阅者已注册
        var ok = false
        for _ in 0..<200 where !ok {
            if NativeAppEvents.subscriberCount() == 1 { ok = true; break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(ok, "S2a/S2b 订阅握手且订阅者已注册")
        let imgs = ["data:image/png;base64,QUJD"]   // 带图 → 简单模式
        let engine = NativeDelegationEngine(db: db,
                                            connector: DelegScriptConn(["识别结果：XYZ"]),
                                            configProvider: { [:] })
        let res = try await engine.runDelegatedTask(NativeDelegationTaskRequest(
            projectId: pid, parentAgentId: mainId, parentSessionId: "sess-main",
            targetAgent: sub, task: "识别附图文字", expect: "输出纯文字",
            sandboxRoot: sandbox.path, maxRounds: 10, images: imgs))
        XCTAssertEqual(res["ok"], .bool(true), "S2c 委派本身成功")
        let tid = try XCTUnwrap(res["task_id"]?.string)
        let childSid = try db.getAgentTask(projectId: pid, taskId: tid)?.sessionId
        _ = await consumer.value
        watchdog.cancel()
        let roles = live.snapshot.map { $0.data["message_role"] }
        XCTAssertEqual(roles, [.string("user"), .string("assistant")],
                       "S2d 在线订阅者实时收到 user+assistant 两条")
        XCTAssertNotNil(childSid, "S2e 子会话 id 可得")
        XCTAssertTrue(live.snapshot.allSatisfy { $0.data["session_id"]?.string == childSid },
                      "S2e 实时事件 session_id 指向子会话")
        XCTAssertTrue(live.snapshot.allSatisfy {
            $0.data["resource"] == .string("session")
                && $0.data["action"] == .string("create")
                && $0.data["project_id"] == .string(pid)
        }, "S2e payload 字段齐全（resource/action/project_id）")
        var gone = false
        for _ in 0..<200 where !gone {
            if NativeAppEvents.subscriberCount() == 0 { gone = true; break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(gone, "S2f aclose 后订阅者注销无泄漏")
    }
}
