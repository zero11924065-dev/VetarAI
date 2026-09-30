//
//  NativeWebSearch.swift
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

//  逐行为移植两个只读规格源：
//    · subagent/sidecar/network/guard.py（356 行，出站唯一漏斗）：
//      网络模式归一化 / 本地·境内判定 / 「需代理」名单 / 熔断器（阈值 2、窗口 300s）
//      / guard_request 五分支 / assert_guard / 熔断触发写名单（三约束保真）
//    · subagent/sidecar/tools/web_search.py（252 行，多源自动降级）：
//      auto→国内源优先 / proxy→国际源优先；DuckDuckGo(POST) / 百度(GET wd) / 360(GET q)
//      三套 HTML 解析器；熔断预检与熔断感知停止文案（含两种引号形态原文）
//
//  传输层抽象（NativeHTTPTransport）：生产 URLSession（trust_env=False 等价——
//  不继承系统代理，代理 100% 由 guard 裁决后挂 connectionProxyDictionary）；
//  测试注入假传输层，不打真网络。
//
//  微差（汇报清单同步）：
//    ① URLSession 无独立 connect 超时（Python httpx connect=5s）——仅单 request
//       超时（=SEARCH_READ_TIMEOUT 30s）；连接/超时错误的 httpx 类型名按
//       NSURLError 映射（ConnectError/ReadTimeout），仅出现在聚合错误详情里；
//    ② html.unescape 全覆盖 HTML5 命名实体，本实现覆盖常见实体+数值引用
//       （搜索页高频实体齐全；冷僻实体按原样保留，Python 的部分无分号遗留
//       实体转换不支持）；
//    ③ GET 查询串按 Python urlencode(quote_via=quote_plus) 手工编码
//       （空格→"+"，非保留字符→%XX 大写）——与 httpx params= 字节级一致。
//

import Foundation

// MARK: - 传输层抽象

public struct NativeHTTPRequest: Sendable {
    public var method: String
    public var url: String
    public var headers: [String: String]
    public var body: Data?
    public var timeout: Double
    /// guard 裁决的代理（"http://127.0.0.1:<port>"）；nil = 直连。
    public var proxy: String?

    public init(method: String, url: String, headers: [String: String] = [:],
                body: Data? = nil, timeout: Double, proxy: String? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
        self.proxy = proxy
    }
}

public struct NativeHTTPResponse: Sendable {
    public let status: Int
    public let body: String
    public init(status: Int, body: String) {
        self.status = status
        self.body = body
    }
}

/// 传输错误（httpx 异常族映射；pyTypeName 进聚合错误详情文案）。
public enum NativeHTTPTransportError: Error {
    case connect(String)     // httpx.ConnectError
    case timeout(String)     // httpx.TimeoutException（ReadTimeout）
    case http(String)        // httpx.HTTPError
    case other(String)       // 其余异常（不计熔断桶）

    public var pyTypeName: String {
        switch self {
        case .connect: return "ConnectError"
        case .timeout: return "ReadTimeout"
        case .http: return "HTTPError"
        case .other: return "RuntimeError"
        }
    }
}

public protocol NativeHTTPTransport: Sendable {
    func send(_ request: NativeHTTPRequest) async throws -> NativeHTTPResponse
}

/// 生产传输层：URLSession。trust_env=False 等价——默认不继承系统代理；
/// guard 裁决代理时经 connectionProxyDictionary 挂载（唯一漏斗契约）。
public struct URLSessionHTTPTransport: NativeHTTPTransport {
    public init() {}

    public func send(_ request: NativeHTTPRequest) async throws -> NativeHTTPResponse {
        guard let url = URL(string: request.url) else {
            throw NativeHTTPTransportError.other("invalid_url: \(request.url)")
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = request.timeout
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if let proxy = request.proxy, let proxyURL = URL(string: proxy),
           let proxyHost = proxyURL.host {
            let proxyPort = proxyURL.port ?? 80
            config.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: true,
                kCFNetworkProxiesHTTPProxy as String: proxyHost,
                kCFNetworkProxiesHTTPPort as String: proxyPort,
                "HTTPSEnable": true,
                "HTTPSProxy": proxyHost,
                "HTTPSPort": proxyPort,
            ]
        } else {
            config.connectionProxyDictionary = [:]   // 显式空表 = 禁用系统代理
        }
        var req = URLRequest(url: url)
        req.httpMethod = request.method
        for (k, v) in request.headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = request.body
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // httpx r.text：按响应声明编码解码；搜索页均 UTF-8（replace 容错）
            return NativeHTTPResponse(status: status, body: String(decoding: data, as: UTF8.self))
        } catch let e as NSError where e.domain == NSURLErrorDomain {
            switch e.code {
            case NSURLErrorTimedOut:
                throw NativeHTTPTransportError.timeout(e.localizedDescription)
            case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost,
                 NSURLErrorNotConnectedToInternet, NSURLErrorCannotFindHost,
                 NSURLErrorDNSLookupFailed:
                throw NativeHTTPTransportError.connect(e.localizedDescription)
            default:
                throw NativeHTTPTransportError.http(e.localizedDescription)
            }
        }
    }
}

// MARK: - 出站守卫（guard.py 移植）

public struct NativeNetworkGuardError: Error, Equatable {
    public let message: String
    public let host: String
    public init(_ message: String, _ host: String) {
        self.message = message
        self.host = host
    }
}

/// Network egress guard（进程级熔断器，对齐 guard.py 模块全局 _circuit）。
public final class NativeNetworkGuard: @unchecked Sendable {

    /// 熔断器常量（协议常量：防死循环的行为边界）。
    public static let circuitThreshold = 2      // CIRCUIT_THRESHOLD：连续失败达阈值即熔断
    public static let circuitWindow = 300.0     // CIRCUIT_WINDOW：熔断持续秒数

    /// _LOCAL_HOSTNAMES。
    static let localHostnames: Set<String> = ["localhost", ""]

    private let lock = NSLock()
    private var circuit: [String: (fails: Int, until: Double)] = [:]

    /// get_config() 延迟读（对齐 guard._cfg()）。
    public var configProvider: @Sendable () -> [String: JSONValue]
    /// reload_config(patch)（熔断触发写「需代理」名单用；异常静默降级为日志）。
    public var configWriter: @Sendable ([String: JSONValue]) throws -> Void
    /// 单调时钟（time.monotonic 等价；测试注入假时钟验窗口过期）。
    public var now: @Sendable () -> Double
    public var log: @Sendable (String) -> Void

    public init(configProvider: @escaping @Sendable () -> [String: JSONValue] = { [:] },
                configWriter: @escaping @Sendable ([String: JSONValue]) throws -> Void = { _ in },
                now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.configProvider = configProvider
        self.configWriter = configWriter
        self.now = now
        self.log = log
    }

    /// _normalize_switch：on→proxy / off→auto（遗留值），其余原样；未知→auto。
    public static func normalizeSwitch(_ raw: JSONValue?) -> String {
        let s = (raw?.string ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if s == "on" { return "proxy" }
        if s == "off" { return "auto" }
        return (s == "auto" || s == "proxy") ? s : "auto"
    }

    // MARK: 熔断器

    static func circuitKey(_ host: String) -> String {
        host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    /// guard_circuit_open：该域名当前是否处于熔断状态（未过期）。
    public func circuitOpen(_ host: String) -> Bool {
        let key = Self.circuitKey(host)
        lock.lock()
        defer { lock.unlock() }
        guard let entry = circuit[key] else { return false }
        guard entry.until > 0 else { return false }   // 仅累计失败、尚未熔断 → 不拦截
        if now() >= entry.until {
            circuit.removeValue(forKey: key)          // 窗口过期 → 自动恢复重试
            return false
        }
        return true
    }

    /// guard_report_failure：累计失败，达阈值即熔断；
    /// 熔断触发一刻把境外域名持久化写入「需代理」名单（B11 三约束保真）。
    public func reportFailure(_ host: String) {
        let key = Self.circuitKey(host)
        guard !key.isEmpty else { return }
        var newlyTripped = false
        lock.lock()
        var entry = circuit[key] ?? (fails: 0, until: 0)
        entry.fails += 1
        if entry.fails >= Self.circuitThreshold {
            let already = entry.until > 0 && now() < entry.until
            entry.until = now() + Self.circuitWindow
            newlyTripped = !already                    // 只在"本次刚跨入熔断"时入名单一次
        }
        circuit[key] = entry
        lock.unlock()
        // ── 约束①：锁已释放，以下才碰 config（防锁顺序反转死锁）──
        guard newlyTripped else { return }
        do {
            let cfg = configProvider()
            if isLocalOrCN(key, cfg: cfg) { return }                       // 约束②：境内/本地不入名单
            if Self.normalizeSwitch(cfg["network_switch"]) != "auto" { return }   // 约束③：仅 auto
            var cur = cfg["egress_proxy_required"]?.stringArray ?? []
            if Self.domainMatch(key, entries: cur) { return }              // 已被现有条目覆盖
            cur.append(key)
            try configWriter(["egress_proxy_required": .array(cur.map { .string($0) })])
        } catch {
            // 名单写入是优化项，失败不得影响调用方的降级/重试流程
            log("写入「需代理」名单失败（\(key)）: \(error.localizedDescription)")
        }
    }

    /// guard_report_success：清零该域名的失败计数与熔断。
    public func reportSuccess(_ host: String) {
        let key = Self.circuitKey(host)
        lock.lock()
        circuit.removeValue(forKey: key)
        lock.unlock()
    }

    /// guard_reset_circuit：清空全部熔断状态（切换网络模式/手动恢复用）。
    public func resetCircuit() {
        lock.lock()
        circuit.removeAll()
        lock.unlock()
    }

    // MARK: 本地/境内判定

    /// _host_is_private_ip：IPv4 私网段（RFC1918 + loopback）；IPv6 仅 loopback。
    static func hostIsPrivateIP(_ host: String) -> Bool {
        if host.contains(":") {
            // IPv6：仅 loopback 视为本地（收紧：不放行 unique-local/私网段）
            return host == "::1" || host == "0:0:0:0:0:0:0:1"
        }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var octets: [Int] = []
        for p in parts {
            // Python ipaddress 拒绝前导零（"010.x" 非合法 IPv4）
            let s = String(p)
            guard !s.isEmpty, s.allSatisfy({ $0.isNumber }),
                  !(s.count > 1 && s.hasPrefix("0")),
                  let v = Int(s), v <= 255 else { return false }
            octets.append(v)
        }
        // 127.0.0.0/8 · 10.0.0.0/8 · 172.16.0.0/12 · 192.168.0.0/16
        if octets[0] == 127 || octets[0] == 10 { return true }
        if octets[0] == 172 && (16...31).contains(octets[1]) { return true }
        if octets[0] == 192 && octets[1] == 168 { return true }
        return false
    }

    /// _host_is_cn：.cn / .com.cn 后缀。
    static func hostIsCN(_ host: String) -> Bool {
        let h = host.lowercased()
        for suf in [".cn", ".com.cn"] {
            if h == String(suf.dropFirst()) || h.hasSuffix(suf) { return true }
        }
        return false
    }

    /// is_local_or_cn：本地（loopback/RFC1918/localhost/配置的 sidecar 或 Ollama host）
    /// 或境内（.cn/.com.cn）域名。
    public func isLocalOrCN(_ host: String, cfg: [String: JSONValue]? = nil) -> Bool {
        guard !host.isEmpty else { return true }
        let cfg = cfg ?? configProvider()
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if Self.localHostnames.contains(h) { return true }
        if Self.hostIsPrivateIP(h) { return true }
        if let v = cfg["sidecar_host"]?.string, !v.isEmpty, h == v.lowercased() { return true }
        let ollamaHost = (URL(string: cfg["ollama_base_url"]?.string ?? "")?.host ?? "").lowercased()
        if !ollamaHost.isEmpty && h == ollamaHost { return true }
        return Self.hostIsCN(h)
    }

    /// _domain_match：精确匹配、*.xxx 通配、或裸域名匹配子域名。
    public static func domainMatch(_ host: String, entries: [String]) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !h.isEmpty else { return false }
        for raw in entries {
            let e = raw.trimmingCharacters(in: .whitespaces).lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard !e.isEmpty else { continue }
            if e.hasPrefix("*.") {
                let base = String(e.dropFirst(2))
                // news.qq.com 命中 *.qq.com；qq.com 本身不命中
                if h.hasSuffix("." + base) && h.count > base.count + 1 { return true }
            } else if h == e {
                return true
            } else if h.hasSuffix("." + e) && h.count > e.count + 1 {
                // 裸域名匹配子域名：so.com → www.so.com / m.so.com
                return true
            }
        }
        return false
    }

    // MARK: guard_request / assert_guard

    /// guard_request：(proxies, reason)。proxies nil = 直连；reason 非 nil = 必须拦截。
    public func request(_ host: String) -> (proxies: [String: String]?, reason: String?) {
        let cfg = configProvider()
        let mode = Self.normalizeSwitch(cfg["network_switch"])

        // 1) 本地段 / 内网 / localhost / 配置 host / 境内 .cn → 放行（直连）
        if isLocalOrCN(host, cfg: cfg) { return (nil, nil) }

        // 2) proxy（全量）模式：境外一律走配置代理；「需代理」名单不拦截
        if mode == "proxy" {
            // 真不可达的站点仍受熔断保护（用户拍板：全量下"也要注意熔断"）
            if circuitOpen(host) {
                return (nil, "境外域名 \(host) 在全量模式下仍连续 \(Self.circuitThreshold) 次访问失败，"
                    + "已暂停自动重试以避免空转（\(Int(Self.circuitWindow)) 秒后可再试）。"
                    + "该站点可能确实无法访问，或代理软件未正常运行。")
            }
            let proxyPort = Int(cfg["proxy_http_port"]?.int ?? 0)
            if proxyPort == 0 {
                return (nil, "域名 \(host) 需经代理访问，但网络模式为「全量」却未配置代理端口"
                    + "（proxy_http_port），无法访问。")
            }
            let base = "http://127.0.0.1:\(proxyPort)"
            return (["http": base, "https": base], nil)
        }

        // 3) auto（标准）模式：先查「需代理」名单（持久记忆），再查熔断（兜底新站点）
        let proxyRequired = cfg["egress_proxy_required"]?.stringArray ?? []
        if Self.domainMatch(host, entries: proxyRequired) {
            return (nil, "域名 \(host) 在「需代理」名单内，标准模式下无法直连。"
                + "如需访问，请先启动代理软件，再把网络模式切为「全量」；"
                + "或在 设置→网络 中把它移出「需代理」名单。")
        }
        if circuitOpen(host) {
            return (nil, "境外域名 \(host) 近期连续 \(Self.circuitThreshold) 次访问失败（可能未开代理），"
                + "已暂停自动重试以避免空转（\(Int(Self.circuitWindow)) 秒后可再试），"
                + "并已记入「需代理」名单。如需访问境外网站，请先启动代理软件，"
                + "再把网络模式切为「全量」。")
        }
        return (nil, nil)
    }

    /// assert_guard：被拒直接抛 NativeNetworkGuardError；返回 proxies（nil = 直连）。
    @discardableResult
    public func assertGuard(_ host: String) throws -> [String: String]? {
        let (proxies, reason) = request(host)
        if let reason { throw NativeNetworkGuardError(reason, host) }
        return proxies
    }
}

// MARK: - 联网搜索（web_search.py 移植）

public struct NativeSearchResult: Sendable, Equatable {
    public let title: String
    public let url: String
    public let snippet: String
}

public enum NativeWebSearch {

    public static let connectTimeout = 5.0        // CONNECT_TIMEOUT（境外失败快速熔断）
    public static let searchReadTimeout = 30.0    // SEARCH_READ_TIMEOUT
    public static let defaultMaxResults = 5
    public static let maxMaxResults = 10

    /// WEB_SEARCH_RETURN（条目字段名 results，覆盖默认 entries）。
    public static let returnSchema = NativeReturnSchema(
        required: ["ok", "results"],
        types: [("ok", .bool), ("results", .list)],
        entryKeys: ["title", "url", "snippet"],
        entryField: "results")

    /// _mode()：归一化网络模式（与 guard._normalize_switch 同语义）。
    public static func mode(_ cfg: [String: JSONValue]) -> String {
        NativeNetworkGuard.normalizeSwitch(cfg["network_switch"])
    }

    /// _source_chain()：按网络模式返回有序源链；proxy → 国际源排前（sorted 稳定序）。
    public static func sourceChain(_ cfg: [String: JSONValue]) -> [(url: String, host: String, isCN: Bool)] {
        let cnURL = (cfg["web_search_url_cn"]?.string ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let intlURL = (cfg["web_search_url"]?.string ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var chain: [(url: String, host: String, isCN: Bool)] = []
        for (url, isCN) in [(cnURL, true), (intlURL, false)] where !url.isEmpty {
            chain.append((url, URL(string: url)?.host ?? "", isCN))
        }
        if mode(cfg) == "proxy" {
            // sorted(chain, key=lambda x: x[2])——False（国际源）排前，稳定序
            chain.sort { !$0.isCN && $1.isCN }
        }
        return chain
    }

    // MARK: HTML 解析助手

    static func regexPairs(_ pattern: String, _ body: String) -> [(String, String)] {
        guard let re = try? NSRegularExpression(pattern: pattern,
                                                options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = body as NSString
        return re.matches(in: body, range: NSRange(location: 0, length: ns.length)).map {
            (ns.substring(with: $0.range(at: 1)), ns.substring(with: $0.range(at: 2)))
        }
    }

    static func regexGroup1(_ pattern: String, _ body: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern,
                                                options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = body as NSString
        return re.matches(in: body, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1))
        }
    }

    static func regexFirstGroup1(_ pattern: String, _ body: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = body as NSString
        guard let m = re.firstMatch(in: body, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    /// re.sub(r'<[^>]+>', '', s)。
    static func stripTags(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "<[^>]+>") else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    /// html.unescape 子集：常见命名实体 + 十进制/十六进制数值引用（未知实体原样保留）。
    static let htmlEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{A0}",
        "mdash": "—", "ndash": "–", "hellip": "…", "middot": "·",
        "laquo": "«", "raquo": "»", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
        "times": "×", "divide": "÷", "copy": "©", "reg": "®", "trade": "™",
        "deg": "°", "plusmn": "±", "micro": "µ", "para": "¶", "sect": "§",
    ]

    static func htmlUnescape(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].dropFirst().firstIndex(of: ";"),
               s.distance(from: i, to: semi) <= 32 {
                let entity = String(s[s.index(after: i)..<semi])
                var rep: String?
                if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                    rep = UInt32(entity.dropFirst(2), radix: 16)
                        .flatMap(Unicode.Scalar.init).map(String.init)
                } else if entity.hasPrefix("#") {
                    rep = UInt32(entity.dropFirst())
                        .flatMap(Unicode.Scalar.init).map(String.init)
                } else {
                    rep = htmlEntities[entity]
                }
                if let rep {
                    out += rep
                    i = s.index(after: semi)
                    continue
                }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }

    /// urllib.parse.unquote（%XX → UTF-8 字节解码，'+' 不转空格）。
    static func pyUnquote(_ s: String) -> String {
        s.removingPercentEncoding ?? s
    }

    /// urllib.parse.urlencode(quote_via=quote_plus)：空格→"+"，非保留字符→%XX（大写）。
    static func pyQuotePlus(_ s: String) -> String {
        var out = ""
        for byte in [UInt8](s.utf8) {
            switch byte {
            case UInt8(ascii: " "):
                out += "+"
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39,   // A-Z a-z 0-9
                 0x5F, 0x2E, 0x2D, 0x7E:                  // _ . - ~
                out.append(Character(UnicodeScalar(byte)))
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    static func pyStrip(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: 三套引擎解析器（正则与 Python 逐字一致）

    /// _parse_duckduckgo_html：result__a 锚点 + result__snippet 摘要；uddg= 跳转解包。
    public static func parseDuckDuckGo(_ body: String, maxResults: Int) -> [NativeSearchResult] {
        let anchors = regexPairs(#"class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#, body)
        let snippets = regexGroup1(#"class="result__snippet"[^>]*>(.*?)</a>"#, body)
        var results: [NativeSearchResult] = []
        for (i, pair) in anchors.enumerated() {
            if i >= maxResults { break }
            var url = htmlUnescape(pair.0)
            if let m = regexFirstGroup1(#"uddg=([^&]+)"#, url) {
                url = pyUnquote(m)
            }
            let title = pyStrip(htmlUnescape(stripTags(pair.1)))
            var snippet = ""
            if i < snippets.count {
                snippet = pyStrip(htmlUnescape(stripTags(snippets[i])))
            }
            if title.isEmpty || url.isEmpty { continue }
            results.append(NativeSearchResult(title: title, url: url, snippet: snippet))
        }
        return results
    }

    /// _parse_baidu_html：<h3><a> 锚点 + content-right/c-abstract 摘要。
    public static func parseBaidu(_ body: String, maxResults: Int) -> [NativeSearchResult] {
        let anchors = regexPairs(#"<h3[^>]*>\s*<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#, body)
        let snippets = regexGroup1(
            #"class="[^"]*(?:content-right|c-abstract)[^"]*"[^>]*>(.*?)</(?:span|div)>"#, body)
        var results: [NativeSearchResult] = []
        for (i, pair) in anchors.enumerated() {
            if i >= maxResults { break }
            let url = pyStrip(htmlUnescape(pair.0))
            let title = pyStrip(htmlUnescape(stripTags(pair.1)))
            var snippet = ""
            if i < snippets.count {
                snippet = pyStrip(htmlUnescape(stripTags(snippets[i])))
            }
            if title.isEmpty || url.isEmpty { continue }
            results.append(NativeSearchResult(title: title, url: url, snippet: snippet))
        }
        return results
    }

    /// _parse_so_html：360 搜索（res-title/title 锚点 + res-desc 摘要）。
    public static func parseSo(_ body: String, maxResults: Int) -> [NativeSearchResult] {
        let anchors = regexPairs(
            #"<h3[^>]*class="[^"]*(?:res-title|title)[^"]*"[^>]*>\s*<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#,
            body)
        let snippets = regexGroup1(#"class="[^"]*res-desc[^"]*"[^>]*>(.*?)</p>"#, body)
        var results: [NativeSearchResult] = []
        for (i, pair) in anchors.enumerated() {
            if i >= maxResults { break }
            let url = pyStrip(htmlUnescape(pair.0))
            let title = pyStrip(htmlUnescape(stripTags(pair.1)))
            var snippet = ""
            if i < snippets.count {
                snippet = pyStrip(htmlUnescape(stripTags(snippets[i])))
            }
            if title.isEmpty || url.isEmpty { continue }
            results.append(NativeSearchResult(title: title, url: url, snippet: snippet))
        }
        return results
    }

    /// _parser_for：按域名选解析器。
    public static func parserFor(_ host: String) -> (String, Int) -> [NativeSearchResult] {
        let hn = host.lowercased()
        if hn.contains("so.com") { return parseSo }
        if hn.contains("baidu") { return parseBaidu }
        return parseDuckDuckGo
    }

    // MARK: web_search 主流程（多源自动降级）

    public static func search(args: [String: JSONValue],
                              context: NativeToolContext) async throws -> [String: JSONValue] {
        guard let query = args["query"]?.string,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ["ok": .bool(false), "error": .string("bad_arg: query")]
        }
        var maxResults = defaultMaxResults
        if let raw = args["max_results"] {
            // isinstance(max_results, int)（Python bool 是 int 子类）且 >= 1，否则回默认
            let asInt: Int? = {
                switch raw {
                case .int(let i): return Int(i)
                case .bool(let b): return b ? 1 : 0
                default: return nil
                }
            }()
            if let asInt, asInt >= 1 { maxResults = asInt }
        }
        maxResults = min(maxResults, maxMaxResults)

        let cfg = context.config()
        let chain = sourceChain(cfg)
        guard !chain.isEmpty else {
            return ["ok": .bool(false),
                    "error": .string("search_failed: 搜索端点未配置（web_search_url / web_search_url_cn）")]
        }

        // TS-105：循环前预检——若国际源已熔断，直接返回（不发起真实请求）
        let preCircuit = chain.contains { !$0.isCN && context.networkGuard.circuitOpen($0.host) }
        if preCircuit {
            var errText = "search_failed: 境外搜索源已熔断（连续失败触发熔断器，300 秒内重试无效）"
                + "（熔断器已开启，未发起真实请求）"
            if mode(cfg) == "auto" {
                errText += "；请停止尝试境外源；如用户需要境外信息，请告知用户先启动代理软件"
                    + "并把网络模式切为\"走代理\"，然后我会自动恢复。"
            }
            return ["ok": .bool(false), "error": .string(errText),
                    "circuit_open": .bool(true),
                    "retry_after_seconds": .int(Int64(NativeNetworkGuard.circuitWindow))]
        }

        var errors: [String] = []
        for (url, host, isCN) in chain {
            // 安全红线：出站必过 guard（熔断后秒拒 / 名单命中 → NetworkGuardError）
            let proxies: [String: String]?
            do {
                proxies = try context.networkGuard.assertGuard(host)
            } catch let e as NativeNetworkGuardError {
                errors.append("\(host): \(e.message)")
                continue   // 自动降级：切下一源
            }
            let request: NativeHTTPRequest
            if isCN {
                let paramsKey = host.contains("baidu") ? "wd" : "q"
                let sep = url.contains("?") ? "&" : "?"
                request = NativeHTTPRequest(
                    method: "GET", url: "\(url)\(sep)\(paramsKey)=\(pyQuotePlus(query))",
                    headers: ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                        + "AppleWebKit/537.36 SubAgent"],
                    timeout: searchReadTimeout, proxy: proxies?["http"])
            } else {
                request = NativeHTTPRequest(
                    method: "POST", url: url,
                    headers: ["User-Agent": "Mozilla/5.0 (SubAgent local tool)",
                              "Content-Type": "application/x-www-form-urlencoded"],
                    body: Data("q=\(pyQuotePlus(query))".utf8),
                    timeout: searchReadTimeout, proxy: proxies?["http"])
            }
            do {
                let resp = try await context.transport.send(request)
                if resp.status != 200 {
                    context.networkGuard.reportFailure(host)
                    errors.append("\(host): HTTP \(resp.status)")
                    continue   // 自动降级
                }
                let results = parserFor(host)(resp.body, maxResults)
                if results.isEmpty {
                    // 解析 0 条（反爬/验证码/结构变更）→ 视为该源不可用，降级（不计熔断）
                    errors.append("\(host): 无可用结果")
                    continue
                }
                context.networkGuard.reportSuccess(host)
                return [
                    "ok": .bool(true),
                    "results": .array(results.map {
                        .object(["title": .string($0.title),
                                 "url": .string($0.url),
                                 "snippet": .string($0.snippet)])
                    }),
                    "query": .string(query),
                    "source": .string(host),
                ]
            } catch let e as NativeHTTPTransportError {
                switch e {
                case .connect, .timeout, .http:
                    // 连接级失败 → 计入熔断（防无代理空转），自动降级下一源
                    context.networkGuard.reportFailure(host)
                    errors.append("\(host): 连接失败/超时（\(e.pyTypeName)）")
                case .other:
                    errors.append("\(host): \(e.pyTypeName)")
                }
                continue
            } catch {
                errors.append("\(host): \(String(describing: type(of: error)))")
                continue
            }
        }

        // TS-105 搜索熔断感知停止：全源失败时若熔断器已开启（含本次搜索导致打开），
        // error 必须表达"已熔断"（不得说"所有搜索源均不可用"——会误导模型换近义词无限重试）
        let circuitOpen = chain.contains { !$0.isCN && context.networkGuard.circuitOpen($0.host) }
        let detail = errors.prefix(3).joined(separator: "；")
        var errText: String
        if circuitOpen {
            errText = "search_failed: 境外搜索源已熔断（连续失败触发熔断器，300 秒内重试无效）—— \(detail)"
            if mode(cfg) == "auto" {
                errText += "；请停止尝试境外源；如用户需要境外信息，请告知用户先启动代理软件"
                    + "并把网络模式切为“走代理”，然后我会自动恢复。"
            }
        } else {
            errText = "search_failed: 所有搜索源均不可用 —— \(detail)"
        }
        return ["ok": .bool(false), "error": .string(errText),
                "circuit_open": .bool(circuitOpen),
                "retry_after_seconds": .int(circuitOpen ? Int64(NativeNetworkGuard.circuitWindow) : 0)]
    }
}
