//
//  NativeToolWebSearchTests.swift
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

//  逐条对照 subagent/sidecar/tools/web_search.py（252 行）与
//  subagent/sidecar/network/guard.py（356 行，⛔ 只读行为规格源）：
//    · 三套引擎 HTML 解析器（DDG/百度/360；uddg 解包、标签剥离、实体反转义）
//    · 入参契约（bad_arg query / max_results 默认5 上限10 非法回默认）
//    · 源链排序（auto 国内优先 / proxy 国际优先）与端点未配置
//    · 多源自动降级（首选失败/解析0条 → 次选；连接失败计熔断，解析0条不计）
//    · 熔断预检（未发起真实请求文案，ASCII 引号后缀）与熔断感知停止（curly 引号后缀）
//    · guard：normalize_switch / 私网·境内判定 / domain_match / 五分支 request /
//      熔断阈值与窗口（注入假时钟）/ 熔断触发写名单（三约束）
//
//  隔离纪律：NativeHTTPTransport 注入假传输层（记录请求、返回罐头 HTML），
//  全程不打真网络；配置用 mktemp 数据根的 NativeConfigStore。
//

import XCTest
@testable import VetarAINative

// MARK: - 假传输层

private final class FakeTransport: NativeHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [NativeHTTPRequest] = []
    /// host → 响应/错误闭包（缺省 200 空体）。
    var handler: (String, NativeHTTPRequest) throws -> NativeHTTPResponse = { _, _ in
        NativeHTTPResponse(status: 200, body: "")
    }

    func send(_ request: NativeHTTPRequest) async throws -> NativeHTTPResponse {
        lock.lock(); requests.append(request); lock.unlock()
        let host = URL(string: request.url)?.host ?? ""
        return try handler(host, request)
    }
}

final class NativeToolWebSearchTests: XCTestCase {

    private var tmp: URL!
    private var transport: FakeTransport!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("w3aws_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        transport = FakeTransport()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    /// 造上下文（数据根独立；可选配置补丁与假时钟）。
    private func makeContext(
        patch: [String: JSONValue] = [:],
        now: (() -> Double)? = nil
    ) throws -> (NativeToolContext, NativeConfigStore, NativeNetworkGuard) {
        let store = NativeConfigStore(environment: ["VETARAI_DATA_ROOT": tmp.path])
        if !patch.isEmpty { _ = try store.reloadConfig(patch: patch) }
        let clock: @Sendable () -> Double = now.map { c in { c() } }
            ?? { ProcessInfo.processInfo.systemUptime }
        let netGuard = NativeNetworkGuard(
            configProvider: { (try? store.getConfig()) ?? NativeConfigStore.defaultConfig },
            configWriter: { _ = try store.reloadConfig(patch: $0) },
            now: clock)
        let ctx = NativeToolContext(
            config: { (try? store.getConfig()) ?? NativeConfigStore.defaultConfig },
            reloadConfig: { try store.reloadConfig(patch: $0) },
            pluginsRoot: { store.pluginsRoot() },
            skillsRoot: { store.dataRoot().appendingPathComponent("skills") },
            networkGuard: netGuard,
            transport: transport!,
            gitRunner: NativeGitRunner { _, _ in .launchFailed("stub") })
        return (ctx, store, netGuard)
    }

    private func errOf(_ r: [String: JSONValue]) -> String { r["error"]?.string ?? "" }

    // MARK: - 解析器（三套引擎）

    func testParseDuckDuckGo() {
        let html = """
            <html><body>
            <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fa%3Fx%3D1&rut=abc">Example <b>Title</b> A</a>
            <a class="result__snippet" href="//duckduckgo.com/l/?uddg=x">Snippet &amp; text A</a>
            <a class="result__a" href="https://example.org/b">Title &quot;B&quot;</a>
            <a class="result__snippet">第二条 &#25253; 摘要</a>
            </body></html>
            """
        let results = NativeWebSearch.parseDuckDuckGo(html, maxResults: 5)
        XCTAssertEqual(results.count, 2)
        // uddg= 跳转解包（unquote）
        XCTAssertEqual(results[0].url, "https://example.com/a?x=1")
        // 标签剥离 + strip
        XCTAssertEqual(results[0].title, "Example Title A")
        // 实体反转义
        XCTAssertEqual(results[0].snippet, "Snippet & text A")
        XCTAssertEqual(results[1].url, "https://example.org/b")
        XCTAssertEqual(results[1].title, "Title \"B\"")
        XCTAssertEqual(results[1].snippet, "第二条 报 摘要")
    }

    /// max_results 截断（enumerate 下标语义：i >= max_results 即 break）。
    func testParseDuckDuckGoMaxResults() {
        var anchors = ""
        for i in 1...6 {
            anchors += #"<a class="result__a" href="https://e.com/\#(i)">T\#(i)</a>"#
        }
        let results = NativeWebSearch.parseDuckDuckGo(anchors, maxResults: 3)
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results.map(\.title), ["T1", "T2", "T3"])
    }

    /// 空标题/空链接条目跳过但消耗下标（Python continue 语义）。
    func testParseSkipsEmptyButConsumesIndex() {
        let html = """
            <a class="result__a" href="https://e.com/1"></a>
            <a class="result__a" href="https://e.com/2">T2</a>
            <a class="result__a" href="https://e.com/3">T3</a>
            """
        // 空标题占位 i=0 → maxResults=2 时只剩 i=1 一条
        let results = NativeWebSearch.parseDuckDuckGo(html, maxResults: 2)
        XCTAssertEqual(results.map(\.title), ["T2"])
    }

    func testParseBaidu() {
        let html = """
            <h3 class="t"><a href="http://www.baidu.com/link?url=abc">百度<b>标题</b></a></h3>
            <span class="content-right_1THTn">百度摘要</span>
            """
        let results = NativeWebSearch.parseBaidu(html, maxResults: 5)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].title, "百度标题")
        XCTAssertEqual(results[0].url, "http://www.baidu.com/link?url=abc")
        XCTAssertEqual(results[0].snippet, "百度摘要")
    }

    func testParseSo() {
        let html = """
            <h3 class="res-title"><a href="https://www.so.com/link?m=abc">360标题</a></h3>
            <p class="res-desc">360摘要</p>
            """
        let results = NativeWebSearch.parseSo(html, maxResults: 5)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].title, "360标题")
        XCTAssertEqual(results[0].snippet, "360摘要")
    }

    /// parser_for：so.com / baidu / 其余→DDG。
    func testParserFor() {
        let soBody = #"<h3 class="res-title"><a href="https://x.com">T</a></h3>"#
        XCTAssertEqual(NativeWebSearch.parserFor("www.so.com")(soBody, 5).count, 1)
        let baiduBody = #"<h3><a href="https://x.com">T</a></h3>"#
        XCTAssertEqual(NativeWebSearch.parserFor("www.baidu.com")(baiduBody, 5).count, 1)
        let ddgBody = #"<a class="result__a" href="https://x.com">T</a>"#
        XCTAssertEqual(NativeWebSearch.parserFor("html.duckduckgo.com")(ddgBody, 5).count, 1)
    }

    // MARK: - 入参契约

    func testBadArgQuery() async throws {
        let (ctx, _, _) = try makeContext()
        for args: [String: JSONValue] in [[:], ["query": .string("  ")],
                                          ["query": .int(3)], ["query": .null]] {
            let r = await NativeToolRegistry.execute("web_search", args: args,
                                                     sandboxRoot: tmp.path,
                                                     authorizer: nil, context: ctx)
            XCTAssertEqual(errOf(r), "bad_arg: query")
        }
    }

    /// max_results：缺省 5；>10 钳 10；非法（0/负/字符串/浮点）回 5；bool 按 int 子类。
    func testMaxResultsClamp() async throws {
        let (ctx, _, _) = try makeContext()
        var anchors = ""
        for i in 1...12 { anchors += #"<a class="result__a" href="https://e.com/\#(i)">T\#(i)</a>"# }
        transport.handler = { host, _ in
            host.contains("so.com")
                ? NativeHTTPResponse(status: 200, body: "")
                : NativeHTTPResponse(status: 200, body: anchors)
        }
        // so.com 空体 → 解析 0 条降级到 DDG
        func resultCount(_ args: [String: JSONValue]) async -> Int {
            let r = await NativeToolRegistry.execute("web_search", args: args,
                                                     sandboxRoot: tmp.path,
                                                     authorizer: nil, context: ctx)
            return r["results"]?.array?.count ?? -1
        }
        let defaultN = await resultCount(["query": .string("q")])                 // 缺省 5
        let clampedN = await resultCount(["query": .string("q"),
                                          "max_results": .int(20)])               // 上限 10
        let zeroN = await resultCount(["query": .string("q"),
                                       "max_results": .int(0)])                   // <1 回默认
        let strN = await resultCount(["query": .string("q"),
                                      "max_results": .string("7")])               // 非 int 回默认
        let doubleN = await resultCount(["query": .string("q"),
                                         "max_results": .double(7.0)])            // float 非 int
        let boolN = await resultCount(["query": .string("q"),
                                       "max_results": .bool(true)])               // isinstance(True,int)
        XCTAssertEqual(defaultN, 5)
        XCTAssertEqual(clampedN, 10)
        XCTAssertEqual(zeroN, 5)
        XCTAssertEqual(strN, 5)
        XCTAssertEqual(doubleN, 5)
        XCTAssertEqual(boolN, 1)
    }

    /// 端点未配置（两 url 均空）→ 结构化错误。
    func testEndpointsUnconfigured() async throws {
        let (ctx, _, _) = try makeContext(patch: [
            "web_search_url": .string(""), "web_search_url_cn": .string(""),
        ])
        let r = await NativeToolRegistry.execute("web_search", args: ["query": .string("x")],
                                                 sandboxRoot: tmp.path,
                                                 authorizer: nil, context: ctx)
        XCTAssertEqual(errOf(r), "search_failed: 搜索端点未配置（web_search_url / web_search_url_cn）")
    }

    // MARK: - 源链排序与请求形态

    func testSourceChainOrderByMode() throws {
        var cfg = NativeConfigStore.defaultConfig
        XCTAssertEqual(NativeWebSearch.sourceChain(cfg).map(\.host),
                       ["www.so.com", "html.duckduckgo.com"])   // auto：国内优先
        cfg["network_switch"] = .string("proxy")
        XCTAssertEqual(NativeWebSearch.sourceChain(cfg).map(\.host),
                       ["html.duckduckgo.com", "www.so.com"])   // proxy：国际优先
    }

    /// auto 模式：国内源 GET（q 参数 + 桌面 UA）；国际源 POST（q 表单 + 工具 UA）。
    func testRequestShapes() async throws {
        let (ctx, _, _) = try makeContext()
        transport.handler = { host, _ in
            if host.contains("so.com") { return NativeHTTPResponse(status: 500, body: "") }
            return NativeHTTPResponse(status: 200, body:
                #"<a class="result__a" href="https://e.com/1">T1</a>"#)
        }
        let r = await NativeToolRegistry.execute(
            "web_search", args: ["query": .string("swift 并发")],
            sandboxRoot: tmp.path, authorizer: nil, context: ctx)
        XCTAssertEqual(r["ok"], .bool(true), errOf(r))
        XCTAssertEqual(r["source"], .string("html.duckduckgo.com"))
        XCTAssertEqual(transport.requests.count, 2)
        // 第一跳：so.com GET，urlencode(quote_plus) 编码
        let first = transport.requests[0]
        XCTAssertEqual(first.method, "GET")
        XCTAssertTrue(first.url.hasPrefix("https://www.so.com/s?q="), first.url)
        XCTAssertTrue(first.url.contains("swift+%E5%B9%B6%E5%8F%91"), first.url)
        XCTAssertEqual(first.headers["User-Agent"],
                       "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 SubAgent")
        // 第二跳：DDG POST 表单
        let second = transport.requests[1]
        XCTAssertEqual(second.method, "POST")
        XCTAssertEqual(second.url, "https://html.duckduckgo.com/html/")
        XCTAssertEqual(String(decoding: second.body ?? Data(), as: UTF8.self),
                       "q=swift+%E5%B9%B6%E5%8F%91")
        XCTAssertEqual(second.headers["User-Agent"], "Mozilla/5.0 (SubAgent local tool)")
        XCTAssertEqual(second.headers["Content-Type"], "application/x-www-form-urlencoded")
    }

    /// baidu 源 GET 用 wd 参数（params_key 分支）。
    func testBaiduUsesWdParam() async throws {
        let (ctx, _, _) = try makeContext(patch: [
            "web_search_url_cn": .string("https://www.baidu.com/s"),
        ])
        transport.handler = { _, _ in
            NativeHTTPResponse(status: 200, body:
                #"<h3 class="t"><a href="https://x.com">T</a></h3>"#)
        }
        let r = await NativeToolRegistry.execute("web_search", args: ["query": .string("kw")],
                                                 sandboxRoot: tmp.path,
                                                 authorizer: nil, context: ctx)
        XCTAssertEqual(r["ok"], .bool(true), errOf(r))
        XCTAssertEqual(r["source"], .string("www.baidu.com"))
        XCTAssertTrue(transport.requests.first?.url.contains("?wd=kw") == true,
                      transport.requests.first?.url ?? "nil")
    }

    // MARK: - 多源自动降级

    /// 首选 HTTP 500（计熔断）→ 降级次选成功。
    func testFallbackOnHttpError() async throws {
        let (ctx, _, netGuard) = try makeContext()
        transport.handler = { host, _ in
            host.contains("so.com")
                ? NativeHTTPResponse(status: 500, body: "")
                : NativeHTTPResponse(status: 200, body:
                    #"<a class="result__a" href="https://e.com/1">T1</a>"#)
        }
        let r = await NativeToolRegistry.execute("web_search", args: ["query": .string("x")],
                                                 sandboxRoot: tmp.path,
                                                 authorizer: nil, context: ctx)
        XCTAssertEqual(r["ok"], .bool(true), errOf(r))
        XCTAssertEqual(netGuard.circuitOpen("www.so.com"), false)   // 1 次未达阈值
        // 失败计入熔断：第二次失败即熔断
        transport.handler = { host, _ in NativeHTTPResponse(status: 500, body: "") }
        _ = await NativeToolRegistry.execute("web_search", args: ["query": .string("x")],
                                             sandboxRoot: tmp.path, authorizer: nil, context: ctx)
        XCTAssertTrue(netGuard.circuitOpen("www.so.com"))
    }

    /// 解析 0 条 → 降级但不计熔断（反爬/结构变更语义）。
    func testEmptyParseFallbackNoCircuit() async throws {
        let (ctx, _, netGuard) = try makeContext()
        transport.handler = { host, _ in
            host.contains("so.com")
                ? NativeHTTPResponse(status: 200, body: "<html>验证码</html>")
                : NativeHTTPResponse(status: 200, body:
                    #"<a class="result__a" href="https://e.com/1">T1</a>"#)
        }
        let r = await NativeToolRegistry.execute("web_search", args: ["query": .string("x")],
                                                 sandboxRoot: tmp.path,
                                                 authorizer: nil, context: ctx)
        XCTAssertEqual(r["ok"], .bool(true), errOf(r))
        XCTAssertEqual(r["source"], .string("html.duckduckgo.com"))
        XCTAssertFalse(netGuard.circuitOpen("www.so.com"))
    }

    /// 全源失败（未熔断）→ "所有搜索源均不可用 —— detail"，circuit_open=false，retry=0。
    func testAllSourcesFailed() async throws {
        let (ctx, _, _) = try makeContext()
        transport.handler = { _, _ in NativeHTTPResponse(status: 404, body: "") }
        let r = await NativeToolRegistry.execute("web_search", args: ["query": .string("x")],
                                                 sandboxRoot: tmp.path,
                                                 authorizer: nil, context: ctx)
        XCTAssertEqual(r["ok"], .bool(false))
        XCTAssertTrue(errOf(r).hasPrefix("search_failed: 所有搜索源均不可用 —— "), errOf(r))
        XCTAssertTrue(errOf(r).contains("www.so.com: HTTP 404"), errOf(r))
        XCTAssertEqual(r["circuit_open"], .bool(false))
        XCTAssertEqual(r["retry_after_seconds"], .int(0))
    }

    /// 本次搜索导致境外源熔断 → 熔断感知停止文案（curly 引号后缀）+ retry 300。
    func testCircuitOpenedByThisSearch() async throws {
        let (ctx, _, _) = try makeContext()
        transport.handler = { _, _ in throw NativeHTTPTransportError.connect("boom") }
        // 第一次：两源各失败 1 次（未熔断）→ 所有源不可用
        let r1 = await NativeToolRegistry.execute("web_search", args: ["query": .string("x")],
                                                  sandboxRoot: tmp.path,
                                                  authorizer: nil, context: ctx)
        XCTAssertTrue(errOf(r1).contains("所有搜索源均不可用"), errOf(r1))
        XCTAssertEqual(r1["circuit_open"], .bool(false))
        // 第二次：境外源达阈值 → error 必须表达"已熔断"（不得误导换近义词重试）
        let r2 = await NativeToolRegistry.execute("web_search", args: ["query": .string("x")],
                                                  sandboxRoot: tmp.path,
                                                  authorizer: nil, context: ctx)
        XCTAssertEqual(r2["circuit_open"], .bool(true))
        XCTAssertEqual(r2["retry_after_seconds"], .int(300))
        XCTAssertTrue(errOf(r2).hasPrefix(
            "search_failed: 境外搜索源已熔断（连续失败触发熔断器，300 秒内重试无效）—— "), errOf(r2))
        XCTAssertTrue(errOf(r2).contains("html.duckduckgo.com: 连接失败/超时（ConnectError）"), errOf(r2))
        // auto 模式后缀（curly 引号形态——web_search.py L245-247 原文）
        XCTAssertTrue(errOf(r2).contains("并把网络模式切为“走代理”，然后我会自动恢复。"), errOf(r2))
    }

    /// 熔断预检：国际源已熔断 → 未发起真实请求（ASCII 引号后缀）。
    func testPreCircuitCheckNoRealRequest() async throws {
        let (ctx, _, netGuard) = try makeContext()
        netGuard.reportFailure("html.duckduckgo.com")
        netGuard.reportFailure("html.duckduckgo.com")   // 达阈值熔断
        transport.handler = { _, _ in XCTFail("不应发起真实请求"); fatalError() }
        let r = await NativeToolRegistry.execute("web_search", args: ["query": .string("x")],
                                                 sandboxRoot: tmp.path,
                                                 authorizer: nil, context: ctx)
        XCTAssertEqual(r["ok"], .bool(false))
        XCTAssertTrue(errOf(r).contains("（熔断器已开启，未发起真实请求）"), errOf(r))
        XCTAssertTrue(errOf(r).contains("并把网络模式切为\"走代理\"，然后我会自动恢复。"), errOf(r))
        XCTAssertEqual(r["circuit_open"], .bool(true))
        XCTAssertEqual(r["retry_after_seconds"], .int(300))
        XCTAssertEqual(transport.requests.count, 0)
    }

    /// proxy 模式熔断预检：不带 auto 专属后缀。
    func testPreCircuitProxyModeNoSuffix() async throws {
        let (ctx, _, netGuard) = try makeContext(patch: ["network_switch": .string("proxy")])
        netGuard.reportFailure("html.duckduckgo.com")
        netGuard.reportFailure("html.duckduckgo.com")
        let r = await NativeToolRegistry.execute("web_search", args: ["query": .string("x")],
                                                 sandboxRoot: tmp.path,
                                                 authorizer: nil, context: ctx)
        XCTAssertTrue(errOf(r).contains("（熔断器已开启，未发起真实请求）"), errOf(r))
        XCTAssertFalse(errOf(r).contains("请停止尝试境外源"), errOf(r))
    }

    /// 名单命中（auto）→ guard 拒绝详情进 errors，继续降级下一源。
    func testGuardDeniedByProxyRequiredList() async throws {
        let (ctx, _, _) = try makeContext(patch: [
            "egress_proxy_required": .array([.string("html.duckduckgo.com")]),
        ])
        transport.handler = { host, _ in
            host.contains("so.com")
                ? NativeHTTPResponse(status: 200, body:
                    #"<h3 class="res-title"><a href="https://x.com">T</a></h3>"#)
                : NativeHTTPResponse(status: 200, body: "")
        }
        let r = await NativeToolRegistry.execute("web_search", args: ["query": .string("x")],
                                                 sandboxRoot: tmp.path,
                                                 authorizer: nil, context: ctx)
        XCTAssertEqual(r["ok"], .bool(true), errOf(r))
        XCTAssertEqual(r["source"], .string("www.so.com"))
        // 国际源被名单拦截（未发起请求）
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertTrue(transport.requests[0].url.contains("so.com"))
    }

    /// proxy 模式：国际源走代理（transport 收到 guard 裁决的 proxy 地址）。
    func testProxyModePassesProxyToTransport() async throws {
        let (ctx, _, _) = try makeContext(patch: ["network_switch": .string("proxy")])
        transport.handler = { _, _ in
            NativeHTTPResponse(status: 200, body:
                #"<a class="result__a" href="https://e.com/1">T1</a>"#)
        }
        let r = await NativeToolRegistry.execute("web_search", args: ["query": .string("x")],
                                                 sandboxRoot: tmp.path,
                                                 authorizer: nil, context: ctx)
        XCTAssertEqual(r["ok"], .bool(true), errOf(r))
        // proxy 模式国际源优先 → 第一跳即 DDG，挂代理 http://127.0.0.1:21081
        XCTAssertEqual(transport.requests.first?.proxy, "http://127.0.0.1:21081")
    }

    /// 成功路径经注册表 schema 校验（results 条目 title/url/snippet 齐）。
    func testSuccessSchemaShape() async throws {
        let (ctx, _, _) = try makeContext()
        transport.handler = { _, _ in
            NativeHTTPResponse(status: 200, body:
                #"<a class="result__a" href="https://e.com/1">T1</a>"#
                    + #"<a class="result__snippet">S1</a>"#)
        }
        let r = await NativeToolRegistry.execute("web_search", args: ["query": .string("x")],
                                                 sandboxRoot: tmp.path,
                                                 authorizer: nil, context: ctx)
        XCTAssertEqual(r["ok"], .bool(true), errOf(r))
        XCTAssertEqual(r["query"], .string("x"))
        guard case .array(let results) = r["results"], case .object(let first) = results.first else {
            return XCTFail("results 结构错误")
        }
        XCTAssertEqual(first["title"], .string("T1"))
        XCTAssertEqual(first["url"], .string("https://e.com/1"))
        XCTAssertEqual(first["snippet"], .string("S1"))
    }

    // MARK: - guard 单元（guard.py 逐项）

    func testNormalizeSwitch() {
        XCTAssertEqual(NativeNetworkGuard.normalizeSwitch(.string("on")), "proxy")
        XCTAssertEqual(NativeNetworkGuard.normalizeSwitch(.string("off")), "auto")
        XCTAssertEqual(NativeNetworkGuard.normalizeSwitch(.string("AUTO")), "auto")
        XCTAssertEqual(NativeNetworkGuard.normalizeSwitch(.string(" Proxy ")), "proxy")
        XCTAssertEqual(NativeNetworkGuard.normalizeSwitch(.string("garbage")), "auto")
        XCTAssertEqual(NativeNetworkGuard.normalizeSwitch(nil), "auto")
        XCTAssertEqual(NativeNetworkGuard.normalizeSwitch(.null), "auto")
    }

    func testIsLocalOrCN() {
        let g = NativeNetworkGuard()
        XCTAssertTrue(g.isLocalOrCN(""))
        XCTAssertTrue(g.isLocalOrCN("localhost"))
        XCTAssertTrue(g.isLocalOrCN("127.0.0.1"))
        XCTAssertTrue(g.isLocalOrCN("10.1.2.3"))
        XCTAssertTrue(g.isLocalOrCN("172.16.0.1"))
        XCTAssertTrue(g.isLocalOrCN("172.31.255.255"))
        XCTAssertTrue(g.isLocalOrCN("192.168.1.1"))
        XCTAssertTrue(g.isLocalOrCN("::1"))
        XCTAssertTrue(g.isLocalOrCN("example.cn"))
        XCTAssertTrue(g.isLocalOrCN("www.gov.com.cn"))
        XCTAssertFalse(g.isLocalOrCN("172.32.0.1"))
        XCTAssertFalse(g.isLocalOrCN("www.so.com"))
        XCTAssertFalse(g.isLocalOrCN("html.duckduckgo.com"))
        XCTAssertFalse(g.isLocalOrCN("example.cn.evil.com"))
        // 配置声明的本机出口（sidecar / Ollama）视为本地
        let cfg: [String: JSONValue] = ["sidecar_host": .string("192.168.1.10"),
                                        "ollama_base_url": .string("http://192.168.1.20:11434")]
        XCTAssertTrue(g.isLocalOrCN("192.168.1.10", cfg: cfg))
        XCTAssertTrue(g.isLocalOrCN("192.168.1.20", cfg: cfg))
        // 未声明的公网 host 不视为本地（192.168.x 本身即私网——不能当反例）
        XCTAssertFalse(g.isLocalOrCN("8.8.8.8", cfg: cfg))
    }

    func testDomainMatch() {
        XCTAssertTrue(NativeNetworkGuard.domainMatch("news.qq.com", entries: ["*.qq.com"]))
        XCTAssertFalse(NativeNetworkGuard.domainMatch("qq.com", entries: ["*.qq.com"]))
        XCTAssertTrue(NativeNetworkGuard.domainMatch("so.com", entries: ["so.com"]))
        XCTAssertTrue(NativeNetworkGuard.domainMatch("www.so.com", entries: ["so.com"]))
        XCTAssertTrue(NativeNetworkGuard.domainMatch("m.so.com", entries: ["so.com"]))
        XCTAssertFalse(NativeNetworkGuard.domainMatch("notso.com", entries: ["so.com"]))
        XCTAssertFalse(NativeNetworkGuard.domainMatch("so.com.cn", entries: ["so.com"]))
        XCTAssertFalse(NativeNetworkGuard.domainMatch("", entries: ["so.com"]))
    }

    func testCircuitThresholdAndWindow() {
        var fakeNow = 1000.0
        let g = NativeNetworkGuard(now: { fakeNow })
        XCTAssertFalse(g.circuitOpen("x.com"))
        g.reportFailure("x.com")
        XCTAssertFalse(g.circuitOpen("x.com"))              // 1 次未达阈值
        g.reportFailure("x.com")
        XCTAssertTrue(g.circuitOpen("x.com"))               // 2 次熔断
        fakeNow += 299
        XCTAssertTrue(g.circuitOpen("x.com"))               // 窗口内
        fakeNow += 2                                        // 301s 后过期自动恢复
        XCTAssertFalse(g.circuitOpen("x.com"))
    }

    func testCircuitReportSuccessClears() {
        let g = NativeNetworkGuard()
        g.reportFailure("x.com")
        g.reportFailure("x.com")
        XCTAssertTrue(g.circuitOpen("x.com"))
        g.reportSuccess("x.com")
        XCTAssertFalse(g.circuitOpen("x.com"))
        g.reportFailure("x.com")
        g.reportFailure("x.com")
        g.resetCircuit()
        XCTAssertFalse(g.circuitOpen("x.com"))
    }

    /// guard_request 五分支（B11 名单制）。
    func testGuardRequestBranches() {
        var cfg: [String: JSONValue] = [
            "network_switch": .string("auto"),
            "proxy_http_port": .int(21081),
            "egress_proxy_required": .array([.string("blocked.com")]),
        ]
        let g = NativeNetworkGuard(configProvider: { cfg })
        // 1) 本地/境内 → 直连
        XCTAssertNil(g.request("example.cn").reason)
        XCTAssertNil(g.request("127.0.0.1").proxies)
        // 3) auto + 名单命中 → 拒绝（提示切全量）
        let denied = g.request("blocked.com")
        XCTAssertNil(denied.proxies)
        XCTAssertTrue(denied.reason?.contains("在「需代理」名单内") == true, denied.reason ?? "nil")
        // 3) auto + 境外未名单未熔断 → 直连尝试
        XCTAssertNil(g.request("free.com").reason)
        XCTAssertNil(g.request("free.com").proxies)
        // 3) auto + 已熔断 → 秒拒
        g.reportFailure("tripped.com")
        g.reportFailure("tripped.com")
        let tripped = g.request("tripped.com")
        XCTAssertTrue(tripped.reason?.contains("近期连续 2 次访问失败") == true, tripped.reason ?? "nil")
        // 2) proxy 模式：境外走代理
        cfg["network_switch"] = .string("proxy")
        let proxied = g.request("free.com")
        XCTAssertEqual(proxied.proxies?["http"], "http://127.0.0.1:21081")
        XCTAssertNil(proxied.reason)
        // 2) proxy + 名单不拦截（用户拍板）
        XCTAssertNil(g.request("blocked.com").reason)
        // 2) proxy + 熔断仍保护
        let stillTripped = g.request("tripped.com")
        XCTAssertTrue(stillTripped.reason?.contains("全量模式下仍连续 2 次访问失败") == true,
                      stillTripped.reason ?? "nil")
        // 2) proxy 未配端口 → 拒绝
        cfg["proxy_http_port"] = .int(0)
        let noPort = g.request("free.com")
        XCTAssertTrue(noPort.reason?.contains("未配置代理端口") == true, noPort.reason ?? "nil")
    }

    /// assert_guard：拒绝抛 NativeNetworkGuardError（message/host 字段齐）。
    func testAssertGuardThrows() {
        let g = NativeNetworkGuard(configProvider: {
            ["network_switch": .string("auto"),
             "egress_proxy_required": .array([.string("blocked.com")])]
        })
        do {
            _ = try g.assertGuard("blocked.com")
            XCTFail("应抛错")
        } catch let e as NativeNetworkGuardError {
            XCTAssertEqual(e.host, "blocked.com")
            XCTAssertTrue(e.message.contains("在「需代理」名单内"))
        } catch { XCTFail("错误类型不对") }
    }

    /// 熔断触发写名单（B11 三约束：auto 模式 + 境外才写；写经 configWriter）。
    func testReportFailureWritesProxyRequiredList() {
        var written: [[String: JSONValue]] = []
        var cfg: [String: JSONValue] = ["network_switch": .string("auto")]
        // 境外 auto → 熔断一刻写名单
        let g1 = NativeNetworkGuard(configProvider: { cfg },
                                    configWriter: { written.append($0) })
        g1.reportFailure("foreign.com")
        g1.reportFailure("foreign.com")
        XCTAssertEqual(written.count, 1)
        XCTAssertEqual(written.first?["egress_proxy_required"],
                       .array([.string("foreign.com")]))
        // 境内 → 不写
        written = []
        let g2 = NativeNetworkGuard(configProvider: { cfg },
                                    configWriter: { written.append($0) })
        g2.reportFailure("example.cn")
        g2.reportFailure("example.cn")
        XCTAssertEqual(written.count, 0)
        // proxy 模式 → 不写（失败说明真不可达，不代表需代理）
        cfg["network_switch"] = .string("proxy")
        written = []
        let g3 = NativeNetworkGuard(configProvider: { cfg },
                                    configWriter: { written.append($0) })
        g3.reportFailure("foreign2.com")
        g3.reportFailure("foreign2.com")
        XCTAssertEqual(written.count, 0)
        // 未达阈值 → 不写；已达阈值后的继续失败不重复写
        cfg["network_switch"] = .string("auto")
        written = []
        let g4 = NativeNetworkGuard(configProvider: { cfg },
                                    configWriter: { written.append($0) })
        g4.reportFailure("foreign3.com")
        XCTAssertEqual(written.count, 0)
        g4.reportFailure("foreign3.com")
        g4.reportFailure("foreign3.com")
        XCTAssertEqual(written.count, 1)
        // 名单已被通配条目覆盖 → 不重复写
        cfg["egress_proxy_required"] = .array([.string("*.dup.com")])
        written = []
        let g5 = NativeNetworkGuard(configProvider: { cfg },
                                    configWriter: { written.append($0) })
        g5.reportFailure("a.dup.com")
        g5.reportFailure("a.dup.com")
        XCTAssertEqual(written.count, 0)
    }

    /// quote_plus 编码（urlencode 语义：空格→"+"，保留字符不编码）。
    func testQuotePlus() {
        XCTAssertEqual(NativeWebSearch.pyQuotePlus("a b+c&d=中"), "a+b%2Bc%26d%3D%E4%B8%AD")
        XCTAssertEqual(NativeWebSearch.pyQuotePlus("_.-~"), "_.-~")
    }

    /// html 反转义：数值引用（十进制/十六进制）+ 未知实体原样保留。
    func testHtmlUnescape() {
        XCTAssertEqual(NativeWebSearch.htmlUnescape("&#65;&#x42;&amp;&unknown;"), "AB&&unknown;")
        XCTAssertEqual(NativeWebSearch.htmlUnescape("无&符号"), "无&符号")
    }
}
