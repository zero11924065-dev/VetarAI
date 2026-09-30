//
//  NativeAgentLoopTests.swift
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

//  逐条翻译 subagent/sidecar/agent_engine/test_loop.py（825 行，⛔ 行为规格）：
//    1 单轮无工具 done / 2 单轮 list_dir 全链路 / 3 两轮工具 state 步数 /
//    4 max_rounds 熔断 / 5 越界读取默认放行 / 6 连续2轮失败熔断 / 7 token 累加 /
//    9a/9b authorizer 分工 / 10+10b+10c+10d 系统提示词 / 11 流内超时兜底 /
//    12a/12b 权限宽松化 / 14 thinking 透传 / 15a-e web_search 去重拦截 /
//    16 MAX_ROUNDS_DEFAULT=200 / 17a-c circuit_open 熔断停止 / 18a-b 非熔断正常 /
//    19a-b compact_required / 20a-b compact_auto / 21 est_rounds_left /
//    22a-h segment_break 插入点分裂 / 22i-o 最后一轮插入补救 / 22p 预算耗尽仍 done /
//    23a-c ctx_chars 轮末重算
//  checkpoint 直译：070 附着图片每轮重发（70a/70b）；073 任务2 委派串行约束
//    （提示词静态断言）；074 T1/T2 委派图片告知（spec/提示词静态断言）。
//  cancel/inject 检查点专例（本波新增，覆盖 cancel.py / inject.py 登记语义）。
//  占位路由报错专例：delegate_task / app_control / computer_use / archive_work_unit /
//    read_skill / search_knowledge 的 ctx 未注入原文案。
//
//  ⚠️VERIFY 未翻（原因）：
//    · test 8（SSE 事件行格式）——属 app.py SSE 序列化层，W4c 路由翻转时覆盖。
//    · test 13（gen() 心跳竞争 15s 定时器 vs 下一事件）——属 app.py gen() SSE
//      驱动层，loop 内核无此结构，W4c 覆盖。
//    · 变异测试机制（MUTATE=1|2|3）——Python 源码打补丁+reload 基建，Swift 编译期
//      绑定无法同法实施；对应断言已直译（22a~22g / 10d3 / 10d4 均为强锚点断言）。
//
//  隔离纪律：mktemp 沙盒 + 假 connector（脚本化轮次）+ 假传输层，不打真网络/模型。
//

import XCTest
@testable import VetarAINative

// MARK: - 测试夹具：假 connector / 假传输 / 上下文

/// 按序返回预置脚本的假 connector。每轮脚本 = (content_chunks, tool_calls)。
private final class FakeConn: NativeChatConnector, @unchecked Sendable {
    typealias Round = (content: [String], tools: [(String, [String: JSONValue])])
    let rounds: [Round]
    let timeoutAfter: Int?      // 第 N 轮 yield stream_error（模拟流内超时兜底）
    private(set) var calls = 0
    private(set) var messagesPerRound: [[[String: JSONValue]]] = []
    private(set) var imagesPerRound: [[String]] = []
    private(set) var toolsSeen: [JSONValue]?

    init(_ rounds: [Round], timeoutAfter: Int? = nil) {
        self.rounds = rounds
        self.timeoutAfter = timeoutAfter
    }

    func chatStream(model: String, messages: [[String: JSONValue]],
                    tools: [JSONValue]?, images: [String]?)
        -> AsyncThrowingStream<NativeChatStreamEvent, Error> {
        let i = min(calls, rounds.count - 1)
        calls += 1
        messagesPerRound.append(messages)
        imagesPerRound.append(images ?? [])
        toolsSeen = tools
        let round = rounds[i]
        let doTimeout = timeoutAfter.map { calls >= $0 } ?? false
        let callNo = calls
        return AsyncThrowingStream { cont in
            if doTimeout {
                cont.yield(.contentDelta("部分"))
                cont.yield(.streamError("模型响应超时，已停止。已完成部分见上方事件。"))
                cont.finish()
                return
            }
            for ch in round.content { cont.yield(.contentDelta(ch)) }
            if !round.tools.isEmpty {
                let tcs: [[String: JSONValue]] = round.tools.map { (n, a) in
                    ["id": .string("mock_\(callNo)"),
                     "function": .object([
                        "name": .string(n),
                        "arguments": .string(NativeAgentLoop.dumps(.object(a))),
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

/// 假 HTTP 传输层（web_search 真路径不触网；本文件 web_search 用假执行器拦截）。
private struct StubTransport: NativeHTTPTransport {
    func send(_ request: NativeHTTPRequest) async throws -> NativeHTTPResponse {
        NativeHTTPResponse(status: 200, body: "")
    }
}

final class NativeAgentLoopTests: XCTestCase {

    private var base: URL!
    private var sandbox: URL!
    private var dataRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("p2w4a_\(UUID().uuidString)")
        sandbox = base.appendingPathComponent("ws")
        dataRoot = base.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        try "hello".write(to: sandbox.appendingPathComponent("a.txt"),
                          atomically: true, encoding: .utf8)
        try "n1".write(to: sandbox.appendingPathComponent("notes.md"),
                       atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
        try super.tearDownWithError()
    }

    /// 造工具上下文（数据根独立；isSensitive 可注入伪造敏感区，对齐 Python monkeypatch 用例）。
    private func makeToolContext(
        isSensitive: (@Sendable (String) -> Bool)? = nil
    ) throws -> NativeToolContext {
        let store = NativeConfigStore(environment: ["VETARAI_DATA_ROOT": dataRoot.path])
        let netGuard = NativeNetworkGuard(
            configProvider: { (try? store.getConfig()) ?? NativeConfigStore.defaultConfig },
            configWriter: { _ = try store.reloadConfig(patch: $0) })
        return NativeToolContext(
            config: { (try? store.getConfig()) ?? NativeConfigStore.defaultConfig },
            reloadConfig: { try store.reloadConfig(patch: $0) },
            pluginsRoot: { store.pluginsRoot() },
            skillsRoot: {
                let url = store.dataRoot().appendingPathComponent("skills")
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                return url
            },
            networkGuard: netGuard,
            transport: StubTransport(),
            gitRunner: NativeGitRunner { _, _ in .launchFailed("stub") },
            isSensitive: isSensitive ?? { NativeToolSandbox.isSensitivePath($0) })
    }

    /// collect：跑一遍 loop 收集全部事件（对齐 test_loop.collect）。
    private func collect(
        _ conn: any NativeChatConnector,
        authorizer: (any NativeToolAuthorizer)? = nil,
        maxRounds: Int = 5,
        contextLimit: Int = 0,
        firstRoundImages: [String]? = nil,
        cancel: (@Sendable () -> Bool)? = nil,
        inject: (@Sendable () -> [String])? = nil,
        knowledgeCtx: NativeKnowledgeContext? = nil,
        toolContext: NativeToolContext? = nil,
        toolExecutor: (any NativeLoopToolExecutor)? = nil,
        config: [String: JSONValue] = [:]
    ) async -> [NativeAgentLoopEvent] {
        let ctx = toolContext ?? (try? makeToolContext())
        var evs: [NativeAgentLoopEvent] = []
        let stream = NativeAgentLoop.runToolLoop(
            model: "m",
            messages: [["role": .string("user"), "content": .string("hi")]],
            toolsSpecList: NativeAgentLoop.toolsSpec(),
            sandboxRoot: sandbox.path,
            connector: conn,
            authorizer: authorizer,
            maxRounds: maxRounds,
            contextLimit: contextLimit,
            firstRoundImages: firstRoundImages,
            cancelCheck: cancel,
            injectCheck: inject,
            knowledgeCtx: knowledgeCtx,
            toolContext: ctx,
            toolExecutor: toolExecutor,
            configProvider: { config })
        for await ev in stream { evs.append(ev) }
        return evs
    }

    private func names(_ evs: [NativeAgentLoopEvent]) -> [String] { evs.map(\.event) }
    private func first(_ evs: [NativeAgentLoopEvent], _ kind: String) -> NativeAgentLoopEvent? {
        evs.first { $0.event == kind }
    }
}


// MARK: - test_loop.py 逐条翻译（1 ~ 12b）

extension NativeAgentLoopTests {

    /// 1. 单轮无工具 → done + 完整 content + 有 token 事件
    func test01_singleRoundNoToolDone() async throws {
        let evs = await collect(FakeConn([(["你好", "。"], [])]))
        let done = first(evs, "done")
        XCTAssertEqual(done?.data["content"]?.string, "你好。", "1 单轮无工具 done+完整content")
        XCTAssertTrue(names(evs).contains("token"))
    }

    /// 2. 单轮 1 工具 → tool_call + tool_result(ok) + done
    func test02_singleToolListDir() async throws {
        let evs = await collect(FakeConn([
            ([], [("list_dir", [:])]),
            (["目录里有 a.txt 和 notes.md"], []),
        ]))
        XCTAssertTrue(evs.contains { $0.event == "tool_call" && $0.data["name"]?.string == "list_dir" })
        let tr = first(evs, "tool_result")
        XCTAssertEqual(tr?.data["ok"]?.bool, true, "2 list_dir tool_result ok")
        let done = first(evs, "done")
        XCTAssertTrue(done?.data["content"]?.string?.contains("a.txt") ?? false)
    }

    /// 3. 2 轮工具 → state 步数 1,2,3
    func test03_twoToolRoundsStateSteps() async throws {
        let evs = await collect(FakeConn([
            ([], [("write_file", ["path": .string("w1.txt"), "content": .string("x")])]),
            ([], [("list_dir", [:])]),
            (["完成"], []),
        ]))
        let steps = evs.filter { $0.event == "state" }.compactMap { $0.data["step"]?.int }
        XCTAssertEqual(steps, [1, 2, 3], "3 两轮工具 state 步数 1,2,3")
    }

    /// 4. max_rounds 熔断 → error 含「最大轮次」
    func test04_maxRoundsCircuit() async throws {
        let loopRound: FakeConn.Round = ([], [("list_dir", [:])])
        let evs = await collect(FakeConn(Array(repeating: loopRound, count: 5)), maxRounds: 3)
        let err = first(evs, "error")
        XCTAssertTrue(err?.data["detail"]?.string?.contains("最大轮次") ?? false,
                      "4 max_rounds 达到上限 error")
    }

    /// 5. 越界工具默认放行（2026-08-28 权限宽松化：工作目录不作围栏）
    func test05_outOfBoundsReadAllowed() async throws {
        try "OUTSIDE".write(to: base.appendingPathComponent("outside.txt"),
                            atomically: true, encoding: .utf8)
        let evs = await collect(FakeConn([
            ([], [("read_file", ["path": .string("../outside.txt")])]),
            (["读到了越界文件"], []),
        ]))
        let tr = first(evs, "tool_result")
        XCTAssertEqual(tr?.data["ok"]?.bool, true, "5 越界读取默认放行")
        XCTAssertNotNil(first(evs, "done"), "5 loop 继续走到 done")
    }

    /// 6. 连续 2 轮工具失败 → error 含「连续工具失败」
    func test06_consecutiveFailCircuit() async throws {
        let evs = await collect(FakeConn([
            ([], [("read_file", ["path": .string("no_such.bin")])]),
            ([], [("read_file", ["path": .string("still_missing.bin")])]),
        ]))
        let err = first(evs, "error")
        XCTAssertTrue(err?.data["detail"]?.string?.contains("连续工具失败") ?? false,
                      "6 连续2轮失败熔断")
    }

    /// 7. token 计数累加（mock 每轮 10+5=15）
    func test07_tokenAccumulation() async throws {
        let evs = await collect(FakeConn([
            ([], [("list_dir", [:])]),
            (["ok"], []),
        ]))
        let states = evs.filter { $0.event == "state" }.compactMap { $0.data["tokens_used"]?.int }
        XCTAssertEqual(states, [15, 30], "7 token 计数单调累加")
    }

    /// 9a. 普通 list_dir → authorizer 不被调用（不弹窗骚扰）
    func test09a_normalOpNoAuthorizerCall() async throws {
        final class Recorder: NativeToolAuthorizer, @unchecked Sendable {
            private(set) var seen: [(String, String, String)] = []
            func authorize(tool: String, path: String, action: String) async -> Bool {
                seen.append((tool, path, action)); return true
            }
            func authorizeNetInstall(tool: String, source: String,
                                     extra: [String: JSONValue]) async -> (allowed: Bool, enableNetwork: Bool) {
                (true, false)
            }
        }
        let rec = Recorder()
        let evs = await collect(FakeConn([
            ([], [("list_dir", [:])]),
            (["done"], []),
        ]), authorizer: rec)
        XCTAssertEqual(rec.seen.count, 0, "9a 普通操作不调用 authorizer")
        XCTAssertTrue(names(evs).contains("done"))
    }

    /// 9b. 敏感删除 → authorizer 以三元组 (tool, path, 'delete') 调用；放行后删除生效
    func test09b_sensitiveDeleteAuthorizerTriple() async throws {
        final class Recorder: NativeToolAuthorizer, @unchecked Sendable {
            private(set) var seen: [(String, String, String)] = []
            func authorize(tool: String, path: String, action: String) async -> Bool {
                seen.append((tool, path, action)); return true
            }
            func authorizeNetInstall(tool: String, source: String,
                                     extra: [String: JSONValue]) async -> (allowed: Bool, enableNetwork: Bool) {
                (true, false)
            }
        }
        let rec = Recorder()
        let fakeSensitive = base.appendingPathComponent("fake_sensitive_loop")
        try FileManager.default.createDirectory(at: fakeSensitive, withIntermediateDirectories: true)
        let victim = fakeSensitive.appendingPathComponent("victim.txt")
        try "s".write(to: victim, atomically: true, encoding: .utf8)
        let real = (fakeSensitive.path as NSString).resolvingSymlinksInPath
        let ctx = try makeToolContext(isSensitive: { p in
            p.hasPrefix(real) || (p as NSString).resolvingSymlinksInPath.hasPrefix(real)
        })
        let evs = await collect(FakeConn([
            ([], [("delete_path", ["path": .string(victim.path)])]),
            (["done"], []),
        ]), authorizer: rec, toolContext: ctx)
        XCTAssertEqual(rec.seen.count, 1, "9b 敏感删除调用 authorizer 一次")
        XCTAssertEqual(rec.seen.first?.0, "delete_path")
        XCTAssertEqual(rec.seen.first?.2, "delete", "9b 三元组 action='delete'")
        XCTAssertFalse(FileManager.default.fileExists(atPath: victim.path),
                       "9b authorizer 放行后删除生效")
        XCTAssertTrue(names(evs).contains("done"))
    }

    /// 10/10b/10c/10c2/10d~10d6. system prompt 结构与纪律静态断言
    func test10_systemPromptStructure() throws {
        let sp = NativeAgentLoop.buildSystemPrompt(
            agentName: "小助手", agentRole: "工程师", sandboxRoot: "/data/ws",
            networkSwitch: "on", currentTime: "2026-08-25 10:00", systemPrompt: "简洁回答")
        // 10 四段齐全
        XCTAssertTrue(sp.hasPrefix("【禁止事项】"))
        XCTAssertTrue(sp.contains("你是 小助手"))
        XCTAssertTrue(sp.contains("角色：工程师"))
        XCTAssertTrue(sp.contains("工作目录：/data/ws"))
        XCTAssertTrue(sp.contains("2026-08-25 10:00"))
        XCTAssertTrue(sp.contains("ON"))   // 经「JSON」等文本命中（与 Python 断言同口径）
        XCTAssertTrue(sp.contains("简洁回答"))
        // 10b 敏感位置写/删需确认说明
        XCTAssertTrue(sp.contains("系统敏感位置（系统目录、~/.ssh、应用数据目录等）的写入/删除，系统会向你请求确认"))
        // 10d 文件路径纪律（表#5，拉模式的后端配套必需项）
        XCTAssertTrue(sp.contains("【文件路径纪律】"))
        XCTAssertTrue(sp.contains("只代表文件") && sp.contains("不会"))
        // 10d3 ⛔ 锚定完整措辞（防空转断言，变异3 对应）
        XCTAssertTrue(sp.contains("也可能是导出产物、用户指定的任意路径"))
        // 10d4 不再只限「上传的附件」窄口径
        XCTAssertFalse(sp.contains("用户上传的文件"))
        // 10d5 强制 read_file 指令
        XCTAssertTrue(sp.contains("必须先用 read_file"))
        // 10d6 禁止「看不到文件」推诿话术
        XCTAssertTrue(sp.contains("看不到文件"))

        // 10c 委派纪律含强制委派约束
        let sp2 = NativeAgentLoop.buildSystemPrompt(
            agentName: "小助手", agentRole: "工程师", sandboxRoot: "/data/ws",
            networkSwitch: "auto", canDelegate: true)
        XCTAssertTrue(sp2.contains("必须先调用 delegate_task"))
        XCTAssertTrue(sp2.contains("不得自己直接做该事"))
        XCTAssertTrue(sp2.contains("不得在未调用 delegate_task 的情况下"))
        // 10c2 canDelegate=false 不含委派纪律
        let sp3 = NativeAgentLoop.buildSystemPrompt(
            agentName: "小助手", agentRole: "工程师", sandboxRoot: "/data/ws",
            networkSwitch: "auto", canDelegate: false)
        XCTAssertFalse(sp3.contains("【委派纪律】"))
    }

    /// 11. 流内超时兜底 → event: error 优雅结束（无 done）
    func test11_streamTimeoutGracefulError() async throws {
        let evs = await collect(FakeConn([(["x"], [])], timeoutAfter: 1))
        let err = first(evs, "error")
        XCTAssertTrue(err?.data["detail"]?.string?.contains("超时") ?? false,
                      "11 流内超时→error 含「超时」")
        XCTAssertNil(first(evs, "done"), "11 无 done")
    }

    /// 12a. 普通写入 + DenyAll authorizer → 不询问、直接写入成功（宽松模型）
    func test12a_plainWriteNotAsked() async throws {
        let denyAll = NativeCallbackAuthorizer(onAuthorize: { _, _, _ in false })
        let evs = await collect(FakeConn([
            ([], [("write_file", ["path": .string("plain_probe.txt"), "content": .string("x")])]),
            (["好"], []),
        ]), authorizer: denyAll)
        let tr = first(evs, "tool_result")
        XCTAssertEqual(tr?.data["ok"]?.bool, true, "12a 普通写入不询问直接执行")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: sandbox.appendingPathComponent("plain_probe.txt").path))
    }

    /// 12b. 敏感删除 + DenyAll → denied_by_user，目标保留
    func test12b_sensitiveDeleteDenied() async throws {
        let denyAll = NativeCallbackAuthorizer(onAuthorize: { _, _, _ in false })
        let fakeSensitive = base.appendingPathComponent("fake_sensitive_deny")
        try FileManager.default.createDirectory(at: fakeSensitive, withIntermediateDirectories: true)
        let victim = fakeSensitive.appendingPathComponent("protected.txt")
        try "keep me".write(to: victim, atomically: true, encoding: .utf8)
        let real = (fakeSensitive.path as NSString).resolvingSymlinksInPath
        let ctx = try makeToolContext(isSensitive: { p in
            p.hasPrefix(real) || (p as NSString).resolvingSymlinksInPath.hasPrefix(real)
        })
        let evs = await collect(FakeConn([
            ([], [("delete_path", ["path": .string(victim.path)])]),
            (["好"], []),
        ]), authorizer: denyAll, toolContext: ctx)
        let tr = first(evs, "tool_result")
        XCTAssertEqual(tr?.data["ok"]?.bool, false, "12b 敏感删除被拒")
        XCTAssertEqual(tr?.data["error"]?.string, "denied_by_user", "12b denied_by_user")
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.path), "12b 文件保留")
    }
}


// MARK: - test_loop.py 逐条翻译（14 ~ 21）

extension NativeAgentLoopTests {

    /// 14. thinking 透传（TS-102 B13）：思考增量 → event:thinking，且不计入正文/done
    func test14_thinkingPassthrough() async throws {
        final class ThinkingConn: NativeChatConnector, @unchecked Sendable {
            func chatStream(model: String, messages: [[String: JSONValue]],
                            tools: [JSONValue]?, images: [String]?)
                -> AsyncThrowingStream<NativeChatStreamEvent, Error> {
                AsyncThrowingStream { cont in
                    cont.yield(.thinkingDelta("让我想想"))
                    cont.yield(.thinkingDelta("……再想"))
                    cont.yield(.contentDelta("答案"))
                    cont.yield(.done(promptEvalCount: 5, evalCount: 2))
                    cont.finish()
                }
            }
            func chat(model: String, messages: [[String: JSONValue]]) async throws -> String { "" }
        }
        let evs = await collect(ThinkingConn())
        let ths = evs.filter { $0.event == "thinking" }
        XCTAssertEqual(ths.count, 2, "14 thinking 透传为 thinking 事件")
        XCTAssertEqual(ths.first?.data["delta"]?.string, "让我想想")
        XCTAssertEqual(ths.last?.data["delta"]?.string, "……再想")
        let done = first(evs, "done")
        XCTAssertEqual(done?.data["content"]?.string, "答案", "14 thinking 不计入正文")
    }

    /// web_search 假执行器：只拦 web_search（对齐 test_loop patch _registry._web_search），
    /// 其余工具仍走真实注册表。
    private final class FakeWebSearchExecutor: NativeLoopToolExecutor, @unchecked Sendable {
        private(set) var calls: [String] = []
        var handler: ([String: JSONValue]) -> [String: JSONValue]
        let inner: NativeRegistryLoopToolExecutor
        init(context: NativeToolContext,
             handler: @escaping ([String: JSONValue]) -> [String: JSONValue]) {
            self.inner = NativeRegistryLoopToolExecutor(context: context)
            self.handler = handler
        }
        func executeLoopTool(_ name: String, args: [String: JSONValue],
                             sandboxRoot: String) async -> [String: JSONValue] {
            if name == "web_search" {
                calls.append(args["query"]?.string ?? "")
                return handler(args)
            }
            return await inner.executeLoopTool(name, args: args, sandboxRoot: sandboxRoot)
        }
    }

    private func okSearchResult(_ args: [String: JSONValue]) -> [String: JSONValue] {
        ["ok": .bool(true), "query": args["query"] ?? .null,
         "results": .array([.object(["title": .string("t"), "url": .string("http://u"),
                                     "snippet": .string("s")])])]
    }

    /// 15a-d. web_search 去重拦截（2026-08-28 问题2）
    func test15_webSearchDedupIntercept() async throws {
        let ctx = try makeToolContext()
        let exec = FakeWebSearchExecutor(context: ctx) { [weak self] args in
            self?.okSearchResult(args) ?? [:]
        }
        let evs = await collect(FakeConn([
            ([], [("web_search", ["query": .string("北京天气")])]),   // 第1次：真实执行
            ([], [("web_search", ["query": .string("北京天气")])]),   // 第2次：相同关键词 → 拦截
            ([], [("web_search", ["query": .string("上海交通")])]),   // 第3次：不同关键词 → 不拦截
            (["ok"], []),
        ]), toolExecutor: exec)
        let trs = evs.filter { $0.event == "tool_result" }
        XCTAssertGreaterThanOrEqual(trs.count, 3)
        XCTAssertEqual(trs[0].data["ok"]?.bool, true, "15a 首次搜索真实执行成功")
        XCTAssertEqual(trs[1].data["ok"]?.bool, false, "15b 相同关键词重复搜索被拦截")
        XCTAssertTrue(trs[1].data["error"]?.string?.contains("duplicate_search") ?? false)
        XCTAssertEqual(trs[2].data["ok"]?.bool, true, "15c 不同关键词不被拦截")
        XCTAssertEqual(exec.calls, ["北京天气", "上海交通"], "15d 仅真实执行非重复搜索")
    }

    /// 15e. 持续相同搜索触发熔断（防死循环）：首次成功，后续重复被拦截→连续失败→熔断
    func test15e_repeatedSearchCircuitBreak() async throws {
        let ctx = try makeToolContext()
        let exec = FakeWebSearchExecutor(context: ctx) { [weak self] args in
            self?.okSearchResult(args) ?? [:]
        }
        let evs = await collect(FakeConn([
            ([], [("web_search", ["query": .string("死循环")])]),
            ([], [("web_search", ["query": .string("死循环")])]),
            ([], [("web_search", ["query": .string("死循环")])]),
        ]), maxRounds: 10, toolExecutor: exec)
        let err = first(evs, "error")
        XCTAssertTrue(err?.data["detail"]?.string?.contains("连续工具失败") ?? false,
                      "15e 持续重复搜索触发熔断防死循环")
        XCTAssertEqual(exec.calls, ["死循环"], "15e 重复搜索仅真实执行一次")
    }

    /// 16. 轮次默认上限 200（范围 1-1000）
    func test16_maxRoundsDefaultIs200() {
        XCTAssertEqual(NativeAgentLoop.maxRoundsDefault, 200, "16 轮次默认上限 200")
    }

    /// 17a-c. TS-105 熔断感知停止：circuit_open=True → 立即停止（SEARCH_CIRCUIT_STOP=1）
    func test17_circuitOpenImmediateStop() async throws {
        let ctx = try makeToolContext()
        let exec = FakeWebSearchExecutor(context: ctx) { _ in
            ["ok": .bool(false),
             "error": .string("search_failed: 境外搜索源已熔断（300 秒内重试无效）"),
             "circuit_open": .bool(true), "retry_after_seconds": .int(300)]
        }
        let evs = await collect(FakeConn([
            ([], [("web_search", ["query": .string("今日金价")])]),
            ([], [("web_search", ["query": .string("黄金价格")])]),
            (["不应到达"], []),
        ]), maxRounds: 200, toolExecutor: exec)
        let err = first(evs, "error")
        XCTAssertTrue(err?.data["detail"]?.string?.contains("境外搜索已被系统熔断") ?? false,
                      "17a circuit_open → error 含「境外搜索已被系统熔断」")
        XCTAssertLessThan(evs.count, 10, "17b ≤2 轮内停止（不再跑 200 轮）")
        XCTAssertEqual(exec.calls.count, 1, "17c 第2次搜索未被执行")
    }

    /// 18a-b. TS-105 非熔断路径不受影响：web_search 正常成功 → loop 继续走到 done
    func test18_normalSearchNoCircuitStop() async throws {
        let ctx = try makeToolContext()
        let exec = FakeWebSearchExecutor(context: ctx) { [weak self] args in
            self?.okSearchResult(args) ?? [:]
        }
        let evs = await collect(FakeConn([
            ([], [("web_search", ["query": .string("q1")])]),
            (["done 正常收尾"], []),
        ]), toolExecutor: exec)
        XCTAssertNil(first(evs, "error"), "18a 正常成功不触发熔断停止")
        let done = first(evs, "done")
        XCTAssertTrue(done?.data["content"]?.string?.contains("done 正常收尾") ?? false,
                      "18b loop 正常走到 done")
    }

    /// 19a-b. M2 溢出预警：未勾自动压缩 → compact_required 且不再请求模型
    func test19_compactRequired() async throws {
        let conn = FakeConn([
            ([], [("list_dir", [:])]),   // 第 1 轮：工具调用（不 done）
            (["b"], []),                // 第 2 轮：不应到达
        ])
        let evs = await collect(conn, maxRounds: 5, contextLimit: 10,
                                config: ["allow_auto_compact": .bool(false)])
        let cr = first(evs, "compact_required")
        XCTAssertNotNil(cr, "19a 溢出预警 → compact_required")
        XCTAssertGreaterThan(cr?.data["used"]?.int ?? 0, 0, "19b compact_required 含 used")
        XCTAssertEqual(cr?.data["limit"]?.int, 10, "19b compact_required 含 limit")
        XCTAssertEqual(conn.calls, 1, "19a 触发预警后不再请求模型")
    }

    /// 20a-b. M2 自动压缩：allow_auto_compact=true → compact_auto 后返回（不 continue 烧轮次）
    func test20_compactAuto() async throws {
        let conn = FakeConn([
            ([], [("list_dir", [:])]),
            ([], [("list_dir", [:])]),
            (["done"], []),
        ])
        let evs = await collect(conn, maxRounds: 5, contextLimit: 10,
                                config: ["allow_auto_compact": .bool(true)])
        let ca = first(evs, "compact_auto")
        XCTAssertNotNil(ca, "20a 自动压缩 → compact_auto")
        XCTAssertNil(first(evs, "done"), "20b compact_auto 后 loop 返回（无 done/无死循环）")
        XCTAssertEqual(names(evs).filter { $0 == "compact_auto" }.count, 1,
                       "20b compact_auto 只发一次")
    }

    /// 21. M2 est_rounds_left：增量 100/轮、距上限剩 20 → est=0（300/320=94% 触发）
    func test21_estRoundsLeft() async throws {
        final class IncrConn: NativeChatConnector, @unchecked Sendable {
            private(set) var calls = 0
            func chatStream(model: String, messages: [[String: JSONValue]],
                            tools: [JSONValue]?, images: [String]?)
                -> AsyncThrowingStream<NativeChatStreamEvent, Error> {
                calls += 1
                let n = calls
                return AsyncThrowingStream { cont in
                    cont.yield(.toolCalls([["id": .string("t\(n)"),
                                            "function": .object(["name": .string("list_dir"),
                                                                 "arguments": .string("{}")])]]))
                    cont.yield(.done(promptEvalCount: n * 100, evalCount: 1))
                    cont.finish()
                }
            }
            func chat(model: String, messages: [[String: JSONValue]]) async throws -> String { "" }
        }
        let evs = await collect(IncrConn(), maxRounds: 10, contextLimit: 320,
                                config: ["allow_auto_compact": .bool(false)])
        // 第 4 轮开始前：last_pe=300, 300/320=0.94 ≥ 0.9 → 触发
        // history=[100,200,300] deltas=[100,100] avg=100, remaining=20 → est=0
        let cr = first(evs, "compact_required")
        XCTAssertNotNil(cr, "21 溢出预警触发（300/320=94%）")
        XCTAssertEqual(cr?.data["est_rounds_left"]?.int, 0,
                       "21 est_rounds_left=0（remaining 20 / avg_delta 100）")
    }
}


// MARK: - test_loop.py 逐条翻译（22 ~ 23）+ checkpoint 070/073/074

extension NativeAgentLoopTests {

    /// 注入序列探针：第 N 次 injectCheck 调用返回 probes[N]，耗尽后恒 []。
    private final class InjectProbe: @unchecked Sendable {
        private(set) var calls = 0
        let probes: [[String]]
        init(_ probes: [[String]]) { self.probes = probes }
        func next() -> [String] {
            let r = calls < probes.count ? probes[calls] : []
            calls += 1
            return r
        }
    }

    /// 22a-h. #1（0.4.20）插入点分裂：生成途中插入 → segment_break + 并入上下文
    func test22_segmentBreakOnInject() async throws {
        let conn = FakeConn([
            (["第一段"], [("list_dir", ["path": .string(".")])]),
            (["第二段甲"], [("list_dir", ["path": .string(".")])]),
            (["收尾"], []),
        ])
        let probe = InjectProbe([[], ["请改正方向"], [], [], []])
        let evs = await collect(conn, inject: { probe.next() })
        let segs = evs.filter { $0.event == "segment_break" }
        XCTAssertGreaterThanOrEqual(segs.count, 1, "22a 插入消息 → segment_break")
        XCTAssertEqual(segs.count, 1, "22b 只发一次 segment_break")
        XCTAssertEqual(segs.first?.data["injected_messages"],
                       .array([.object(["role": .string("user"),
                                        "content": .string("请改正方向")])]),
                       "22c payload 携带注入消息")
        XCTAssertEqual(segs.first?.data["break_at"]?.int, 3,
                       "22d break_at=3（「第一段」码点数）")
        let done = first(evs, "done")
        XCTAssertNotNil(done, "22e 有 done")
        let content = done?.data["content"]?.string ?? ""
        XCTAssertTrue(content.hasPrefix("第一段"), "22f content 以「第一段」开头")
        let after = String(content.unicodeScalars.dropFirst(3))
        XCTAssertEqual(after, "第二段甲收尾", "22g 分裂点之后为「第二段甲收尾」")
        XCTAssertFalse(after.hasPrefix("第一段"), "22g 分裂点后不再重复第一段")
    }

    /// 22h. injectCheck 恒 [] → 无 segment_break
    func test22h_noInjectNoSegmentBreak() async throws {
        let conn = FakeConn([
            (["甲"], [("list_dir", ["path": .string(".")])]),
            (["乙"], []),
        ])
        let probe = InjectProbe([[], [], [], []])
        let evs = await collect(conn, inject: { probe.next() })
        XCTAssertFalse(names(evs).contains("segment_break"), "22h 无注入 → 无 segment_break")
        XCTAssertEqual(first(evs, "done")?.data["content"]?.string, "甲乙")
    }

    /// 22i-o. 0.4.23 最后一轮插入补救：done 前补 drain，continue 让模型真读到
    func test22i_lastRoundInjectRemedy() async throws {
        let center = NativeChatRuntimeCenter()
        let sid = "s22i"
        center.beginStream(sid)
        defer { center.endStream(sid) }
        final class LastRoundConn: NativeChatConnector, @unchecked Sendable {
            let center: NativeChatRuntimeCenter
            let sid: String
            private(set) var calls = 0
            private(set) var messagesPerRound: [[[String: JSONValue]]] = []
            private(set) var pushed = false
            init(center: NativeChatRuntimeCenter, sid: String) {
                self.center = center; self.sid = sid
            }
            func chatStream(model: String, messages: [[String: JSONValue]],
                            tools: [JSONValue]?, images: [String]?)
                -> AsyncThrowingStream<NativeChatStreamEvent, Error> {
                let i = min(calls, 2)
                calls += 1
                messagesPerRound.append(messages)
                return AsyncThrowingStream { cont in
                    switch i {
                    case 0:
                        cont.yield(.contentDelta("前段"))
                        cont.yield(.toolCalls([["id": .string("lr_1"),
                                                "function": .object([
                                                    "name": .string("list_dir"),
                                                    "arguments": .string("{\"path\":\".\"}")])]]))
                    case 1:
                        // 生成途中用户插入消息
                        self.pushed = self.center.push(self.sid, content: "最后一轮插入的消息")
                        cont.yield(.contentDelta("终段"))
                    default:
                        cont.yield(.contentDelta("针对插入的回复"))
                    }
                    cont.yield(.done(promptEvalCount: 10, evalCount: 5))
                    cont.finish()
                }
            }
            func chat(model: String, messages: [[String: JSONValue]]) async throws -> String { "" }
        }
        let conn = LastRoundConn(center: center, sid: sid)
        let evs = await collect(conn, inject: center.makeInjectCheck(sid))
        XCTAssertTrue(conn.pushed, "22i push 发生在活流内（返回 true）")
        let segs = evs.filter { $0.event == "segment_break" }
        XCTAssertEqual(segs.count, 1, "22j 补救触发恰好一次 segment_break")
        XCTAssertEqual(segs.first?.data["injected_messages"],
                       .array([.object(["role": .string("user"),
                                        "content": .string("最后一轮插入的消息")])]),
                       "22k payload 携带最后一轮插入消息")
        XCTAssertEqual(segs.first?.data["break_at"]?.int, 4,
                       "22k break_at=4（「前段终段」码点数）")
        XCTAssertGreaterThanOrEqual(conn.messagesPerRound.count, 3, "22l 补救后继续跑了第 3 轮")
        let round3 = conn.messagesPerRound.count >= 3 ? conn.messagesPerRound[2] : []
        XCTAssertTrue(round3.contains {
            $0["role"]?.string == "user" && $0["content"]?.string == "最后一轮插入的消息"
        }, "22l 第 3 轮上下文真读到注入消息")
        XCTAssertEqual(center.pending(sid), 0, "22m 队列 drain 后为空（取出即清空）")
        XCTAssertNotNil(first(evs, "done"), "22n 有 done")
        XCTAssertNil(first(evs, "error"), "22n 无 error")
        XCTAssertEqual(first(evs, "done")?.data["content"]?.string, "前段终段针对插入的回复",
                       "22o done 全文含补救后续段")
    }

    /// 22p. 轮次预算耗尽（step == maxRounds）→ 不补救，如实保留 done
    func test22p_budgetExhaustedStillDone() async throws {
        let conn = FakeConn([
            (["前段"], [("list_dir", ["path": .string(".")])]),
            (["终段"], []),
        ])
        let probe = InjectProbe([[], [], ["预算外插入"]])
        let evs = await collect(conn, maxRounds: 2, inject: { probe.next() })
        let done = first(evs, "done")
        XCTAssertNotNil(done, "22p 预算耗尽仍 done（不变成最大轮次 error）")
        XCTAssertNil(first(evs, "error"), "22p 无 error")
        XCTAssertEqual(done?.data["content"]?.string, "前段终段")
    }

    /// 23a-c. 0.4.22（checkpoint-109）：轮末 state 前重算 ctx_chars
    func test23_ctxCharsEndOfRoundRecompute() async throws {
        let conn = FakeConn([
            ([], [("list_dir", ["path": .string(".")])]),
            (["x"], []),
        ])
        let evs = await collect(conn)
        let states = evs.filter { $0.event == "state" }
        XCTAssertGreaterThanOrEqual(states.count, 2, "23a 防空转：state ≥ 2")
        XCTAssertGreaterThanOrEqual(conn.messagesPerRound.count, 2, "23a 防空转：轮次消息 ≥ 2")
        let tools = conn.toolsSeen ?? []
        let ctxOfRound1Start = NativeAgentLoop.measureCtxChars(conn.messagesPerRound[0], tools)
        let ctxOfRound2Start = NativeAgentLoop.measureCtxChars(conn.messagesPerRound[1], tools)
        XCTAssertGreaterThan(ctxOfRound2Start, ctxOfRound1Start,
                             "23b tool_report 回注后上下文变长（防空转锚点）")
        XCTAssertEqual(states[0].data["ctx_chars"]?.int, Int64(ctxOfRound2Start),
                       "23b 第 1 轮末 state.ctx_chars = 第 2 轮轮初口径（含 tool_report）")
        XCTAssertEqual(states[1].data["ctx_chars"]?.int, Int64(ctxOfRound2Start),
                       "23c 第 2 轮 state.ctx_chars 同口径")
    }

    /// 70a/70b. checkpoint-070：用户附着图片【每轮都重发】（不能只发第一轮）
    func test70_attachedImagesResentEveryRound() async throws {
        let img = "data:image/png;base64,QUJD"
        let conn = FakeConn([
            ([], [("list_dir", ["path": .string(".")])]),
            (["转写结果"], []),
        ])
        let evs = await collect(conn, firstRoundImages: [img])
        XCTAssertEqual(conn.imagesPerRound.count, 2, "70 防空转：两轮都请求了模型")
        XCTAssertEqual(conn.imagesPerRound[0], [img], "70a 第 1 轮携带附着图")
        XCTAssertEqual(conn.imagesPerRound[1], [img], "70b 第 2 轮仍携带附着图（每轮重发）")
        XCTAssertNotNil(first(evs, "done"))
    }

    /// 073 任务2 + 074 T1/T2：委派串行约束与图片传递告知（静态断言）
    func test073_074_delegationPromptStatics() throws {
        // 073 任务2：【串行约束】同一时间只委派一个子任务
        let sp = NativeAgentLoop.buildSystemPrompt(
            agentName: "小助手", agentRole: nil, sandboxRoot: "/data/ws",
            networkSwitch: "auto", canDelegate: true)
        XCTAssertTrue(sp.contains("同一时间只委派一个子任务"), "073 任务2 委派串行约束")
        // 074 T2：提示词告知图片自动随委派传递
        XCTAssertTrue(sp.contains("会自动随 delegate_task 传给子 Agent"), "074 T2 委派图片告知")
        // 074 T1：delegate_task 工具描述含「附图」
        let spec = NativeAgentLoop.toolsSpec(withDelegation: true)
        var desc = ""
        for t in spec {
            guard case .object(let o) = t, case .object(let fn)? = o["function"],
                  fn["name"]?.string == "delegate_task",
                  case .string(let d)? = fn["description"] else { continue }
            desc = d
        }
        XCTAssertFalse(desc.isEmpty, "074 T1 防空转：找到 delegate_task spec")
        XCTAssertTrue(desc.contains("附图"), "074 T1 delegate_task 描述含「附图」")
    }
}


// MARK: - cancel / inject 检查点专例（TS-114 + A5；cancel.py / inject.py 登记语义）

extension NativeAgentLoopTests {

    /// 取消检查点：cancelCheck 恒 true → 第 1 轮开始前即 cancelled，未请求模型
    func testCancelCheckpoint_alwaysTrueNoModelCall() async throws {
        let conn = FakeConn([(["x"], [])])
        let evs = await collect(conn, cancel: { true })
        XCTAssertEqual(evs.count, 1, "仅 cancelled 一个事件")
        XCTAssertEqual(evs.first?.event, "cancelled")
        XCTAssertEqual(evs.first?.data["detail"]?.string, "已停止")
        XCTAssertEqual(conn.calls, 0, "未发起模型调用")
    }

    /// 取消检查点：第 2 轮变 true → 第 1 轮工具执行完毕后 cancelled（不打断当前轮）
    func testCancelCheckpoint_becomesTrueAtRound2() async throws {
        final class Counter: @unchecked Sendable { var n = 0 }
        let counter = Counter()
        let conn = FakeConn([
            ([], [("list_dir", ["path": .string(".")])]),
            (["不该出现"], []),
        ])
        let evs = await collect(conn, cancel: {
            counter.n += 1
            return counter.n >= 2   // 第 1 轮 false，第 2 轮 true
        })
        XCTAssertTrue(names(evs).contains("tool_result"), "第 1 轮工具已执行")
        XCTAssertEqual(evs.last?.event, "cancelled")
        XCTAssertEqual(evs.last?.data["detail"]?.string, "已停止")
        XCTAssertNil(first(evs, "error"), "取消不是错误")
        XCTAssertNil(first(evs, "done"))
        XCTAssertEqual(conn.calls, 1, "第 2 轮未发起模型调用")
    }

    /// NativeChatRuntimeCenter 登记语义单测（cancel.py + inject.py 逐行为）
    func testRuntimeCenter_registerCancelInjectSemantics() throws {
        let c = NativeChatRuntimeCenter()
        // cancel.py：只有已注册（确有活流）的会话才接受取消请求
        XCTAssertFalse(c.requestChatCancel("s"), "未注册 → 取消请求拒绝")
        XCTAssertTrue(c.registerStream("s"))
        XCTAssertFalse(c.isChatCancelled("s"), "注册时是全新未置位状态")
        XCTAssertTrue(c.requestChatCancel("s"))
        XCTAssertTrue(c.isChatCancelled("s"))
        c.unregisterStream("s")
        XCTAssertFalse(c.requestChatCancel("s"), "注销后 → 取消请求拒绝")
        XCTAssertTrue(c.registerStream("s"), "重新注册成功")
        XCTAssertFalse(c.isChatCancelled("s"), "重新注册 = 全新未置位（无残留）")
        XCTAssertFalse(c.registerStream(""), "空 sid → 注册拒绝")
        // inject.py：begin/end 配对；只在有活流时接受 push；drain 取出即清空
        XCTAssertFalse(c.push("s", content: "x"), "无活流 → push 拒绝")
        c.beginStream("s")
        XCTAssertTrue(c.isActive("s"))
        XCTAssertTrue(c.push("s", content: "m1"))
        XCTAssertTrue(c.push("s", content: "m2"))
        XCTAssertEqual(c.pending("s"), 2)
        XCTAssertEqual(c.drain("s"), ["m1", "m2"], "drain 取出全部")
        XCTAssertEqual(c.pending("s"), 0, "取出即清空")
        XCTAssertEqual(c.drain("s"), [], "再 drain 为空")
        // end_stream 清残留队列（防下一轮流读到旧消息）
        XCTAssertTrue(c.push("s", content: "leftover"))
        c.endStream("s")
        XCTAssertFalse(c.isActive("s"))
        XCTAssertEqual(c.pending("s"), 0, "end_stream 清残留")
        XCTAssertFalse(c.push("s", content: "x"), "活流结束后 push 拒绝")
    }
}


// MARK: - 占位路由报错专例（ctx 未注入 → 按 Python 原文案 / 如实报错，绝不静默吞）

extension NativeAgentLoopTests {

    /// 取第 2 轮消息中指定工具的 tool_report.result（结果回注 JSON）。
    private func toolReportResult(_ messages: [[String: JSONValue]],
                                  _ name: String) -> [String: JSONValue]? {
        for m in messages.reversed() {
            guard let s = m["content"]?.string, let d = s.data(using: .utf8),
                  let v = NativeJSONWriter.loads(d), case .object(let o) = v,
                  case .object(let rep)? = o["tool_report"],
                  rep["name"]?.string == name,
                  case .object(let res)? = rep["result"] else { continue }
            return res
        }
        return nil
    }

    /// 跑一轮占位工具调用，返回 (事件, 第2轮消息中的 result)
    private func runPlaceholder(_ name: String, _ args: [String: JSONValue],
                                knowledgeCtx: NativeKnowledgeContext? = nil
    ) async -> (evs: [NativeAgentLoopEvent], result: [String: JSONValue]?) {
        let conn = FakeConn([
            ([], [(name, args)]),
            (["收尾"], []),
        ])
        let evs = await collect(conn, knowledgeCtx: knowledgeCtx)
        let result = conn.messagesPerRound.count >= 2
            ? toolReportResult(conn.messagesPerRound[1], name) : nil
        return (evs, result)
    }

    /// delegate_task 无 delegation_ctx → 「当前会话不允许委派」
    func testPlaceholder_delegateNoCtx() async throws {
        let (evs, result) = await runPlaceholder("delegate_task", ["task": .string("t")])
        let tr = first(evs, "tool_result")
        XCTAssertEqual(tr?.data["ok"]?.bool, false)
        XCTAssertTrue(tr?.data["error"]?.string?.contains("当前会话不允许委派") ?? false)
        XCTAssertEqual(result?["ok"], .bool(false), "回注 result 同样为失败")
    }

    /// app_control：缺参报错在前；无 ctx 报未启用
    func testPlaceholder_appControl() async throws {
        let r1 = await runPlaceholder("app_control", ["action": .string("a")])
        XCTAssertTrue(first(r1.evs, "tool_result")?.data["error"]?.string?
            .contains("app_control 需要 module 与 action 两个参数") ?? false,
                      "缺 module → 参数错")
        let r2 = await runPlaceholder("app_control",
                                      ["module": .string("m"), "action": .string("a")])
        XCTAssertTrue(first(r2.evs, "tool_result")?.data["error"]?.string?
            .contains("当前会话未启用应用内模块控制") ?? false,
                      "无 ctx → 未启用应用内模块控制")
    }

    /// screen_view 无 computer_use_ctx → 「当前会话未启用 Computer Use」
    func testPlaceholder_computerUseNoCtx() async throws {
        let (evs, _) = await runPlaceholder("screen_view", [:])
        XCTAssertTrue(first(evs, "tool_result")?.data["error"]?.string?
            .contains("当前会话未启用 Computer Use") ?? false)
    }

    /// archive_work_unit：缺 title 报错在前；无 ctx 报未开启
    func testPlaceholder_archive() async throws {
        let r1 = await runPlaceholder("archive_work_unit", [:])
        XCTAssertTrue(first(r1.evs, "tool_result")?.data["error"]?.string?
            .contains("archive_work_unit 需要 title 参数") ?? false, "缺 title → 参数错")
        let r2 = await runPlaceholder("archive_work_unit", ["title": .string("《某案件》案情分析")])
        XCTAssertTrue(first(r2.evs, "tool_result")?.data["error"]?.string?
            .contains("当前会话未开启「单元归档」") ?? false, "无 ctx → 未开启归档")
    }

    /// read_skill 无 reader → 「技能读取尚未原生接管」
    func testPlaceholder_readSkillNoReader() async throws {
        let (evs, _) = await runPlaceholder("read_skill", ["name": .string("某技能")])
        XCTAssertTrue(first(evs, "tool_result")?.data["error"]?.string?
            .contains("技能读取执行器未装配") ?? false,
                      "W4c 起 reader 为 nil 属装配缺失——如实报错，不静默吞")
    }

    /// search_knowledge：无 ctx / 空 query / 假 searcher 成功路径
    func testSearchKnowledge_routes() async throws {
        // 无 ctx → 未启用知识仓库检索
        let r1 = await runPlaceholder("search_knowledge", ["query": .string("q")])
        XCTAssertTrue(first(r1.evs, "tool_result")?.data["error"]?.string?
            .contains("当前会话未启用知识仓库检索") ?? false)
        // 假 searcher（固定 hits；长 body 验证 ≤2000 截断）
        final class FakeSearcher: NativeKnowledgeSearcher {
            let hits: [NativeKnowledgeSearchHit]
            init(_ hits: [NativeKnowledgeSearchHit]) { self.hits = hits }
            func searchScoped(_ query: String, scope: String, projectId: String?,
                              limit: Int, mode: String) -> [NativeKnowledgeSearchHit] { hits }
        }
        let longBody = String(repeating: "字", count: 3000)
        let kctx = NativeKnowledgeContext(projectId: "p1", searcher: FakeSearcher([
            NativeKnowledgeSearchHit(title: "条目甲", scope: "project", score: 0.9, body: longBody),
        ]))
        // 空 query → 参数错（先于 ctx 判定）
        let r2 = await runPlaceholder("search_knowledge", ["query": .string("  ")],
                                      knowledgeCtx: kctx)
        XCTAssertTrue(first(r2.evs, "tool_result")?.data["error"]?.string?
            .contains("search_knowledge 需要 query 参数") ?? false, "空 query → 参数错")
        // 成功路径：ok/count/note/items body ≤ 2000
        let r3 = await runPlaceholder("search_knowledge", ["query": .string("案情")],
                                      knowledgeCtx: kctx)
        let tr = first(r3.evs, "tool_result")
        XCTAssertEqual(tr?.data["ok"]?.bool, true, "search_knowledge 成功")
        let result = r3.result
        XCTAssertEqual(result?["ok"], .bool(true))
        XCTAssertEqual(result?["count"]?.int, 1)
        XCTAssertEqual(result?["note"]?.string, "检索结果仅本轮可见，不会写入对话上下文。")
        guard case .array(let items)? = result?["items"],
              case .object(let item0) = items.first,
              case .string(let body)? = item0["body"] else {
            return XCTFail("search_knowledge result.items 结构缺失")
        }
        XCTAssertEqual(body.unicodeScalars.count, 2000, "items body 截断到 2000 码点")
        XCTAssertEqual(item0["title"]?.string, "条目甲")
    }
}


// MARK: - REQ-PERF-002 重复动作熔断（0.7.4 W3）

extension NativeAgentLoopTests {

    /// ① 触发（默认阈值 3）：同一工具+相同参数在【一轮内】连败 3 次
    /// → error 含「重复动作熔断」与工具名。
    /// （连败 3 轮会被轮级熔断「连续 2 轮全败」抢先，故触发路径走轮内多调用。）
    func testRepeatActionFuseTriggersWithinRound() async throws {
        let call: (String, [String: JSONValue]) = ("read_file", ["path": .string("missing.bin")])
        let evs = await collect(FakeConn([([], [call, call, call])]))
        let err = first(evs, "error")
        XCTAssertTrue(err?.data["detail"]?.string?.contains("重复动作熔断") ?? false,
                      "同参数连败 3 次触发重复动作熔断")
        XCTAssertTrue(err?.data["detail"]?.string?.contains("read_file") ?? false,
                      "熔断文案含工具名")
    }

    /// ①b 阈值 clamp：配置 1 被抬到 2（阈值 1 会误伤首次重试）——
    /// 一轮内同参数连败 2 次即触发。
    func testRepeatActionFuseThresholdClampedToTwo() async throws {
        let call: (String, [String: JSONValue]) = ("read_file", ["path": .string("missing.bin")])
        let evs = await collect(FakeConn([([], [call, call])]),
                                config: ["agent.repeatActionFuse": .int(1)])
        let err = first(evs, "error")
        XCTAssertTrue(err?.data["detail"]?.string?.contains("重复动作熔断") ?? false,
                      "配置阈值 1 clamp 到 2：连败 2 次即熔断")
    }

    /// ② 不触发 a：参数不同的连败走轮级熔断，不报「重复动作熔断」。
    func testRepeatActionFuseNotTriggeredDifferentArgs() async throws {
        let evs = await collect(FakeConn([
            ([], [("read_file", ["path": .string("no1.bin")])]),
            ([], [("read_file", ["path": .string("no2.bin")])]),
        ]))
        let err = first(evs, "error")
        XCTAssertTrue(err?.data["detail"]?.string?.contains("连续工具失败") ?? false,
                      "参数不同连败仍走轮级熔断")
        XCTAssertFalse(err?.data["detail"]?.string?.contains("重复动作熔断") ?? true,
                       "参数不同不触发重复动作熔断")
    }

    /// ② 不触发 b：成功调用清零重计——失败→成功→再失败 不累计。
    func testRepeatActionFuseResetOnSuccess() async throws {
        let evs = await collect(FakeConn([
            ([], [("read_file", ["path": .string("missing.bin")]),
                  ("write_file", ["path": .string("w.txt"), "content": .string("x")])]),
            ([], [("read_file", ["path": .string("missing.bin")])]),
            (["完成"], []),
        ]))
        XCTAssertNil(first(evs, "error"), "成功清零后未达阈值，无任何熔断报错")
        XCTAssertNotNil(first(evs, "done"), "loop 正常走到 done")
    }

    /// ③ 关闭：config agent.repeatActionFuse=0 时同参数连败不触发本熔断
    /// （仍会撞轮级熔断「连续工具失败」，两者不冲突）。
    func testRepeatActionFuseDisabledByConfig() async throws {
        let call: (String, [String: JSONValue]) = ("read_file", ["path": .string("missing.bin")])
        // FakeConn 轮脚本耗尽后重复最后一轮 → 第 2 轮触发轮级熔断兜底
        let evs = await collect(FakeConn([([], [call, call, call])]),
                                config: ["agent.repeatActionFuse": .int(0)])
        let err = first(evs, "error")
        XCTAssertFalse(err?.data["detail"]?.string?.contains("重复动作熔断") ?? true,
                       "配置 0 关闭时不报重复动作熔断")
        XCTAssertTrue(err?.data["detail"]?.string?.contains("连续工具失败") ?? false,
                      "关闭后由轮级熔断兜底")
    }
}
