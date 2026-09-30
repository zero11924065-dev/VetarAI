//
//  NativeLlamaCppDriver.swift
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

//  逐行为移植（⛔ 只读行为规格源：subagent/sidecar/model_packs/llamacpp_driver.py，
//  440 行）。职责边界同 Python：本模块只管「进程」（spawn/健康探测/停止/换装），
//  不管「协议」（OpenAI 兼容 SSE 在 MP connector → NativeOpenAIChatConnector）。
//
//  语义锚定：
//    · 二进制三态解析链（L107-142 移植；P3-W6④ 驱动进 bundle 优先级翻转）：
//      Bundle.main Resources/drivers/llama-server > env VETARAI_LLAMA_SERVER >
//      {data_root}/drivers/llama-server。bundle 最高——包内驱动与 app 同版本发行，
//      接管 0.4.x 数据根后不受其中旧驱动影响；env 保留为开发期显式覆盖
//      （swift run 无 bundle 时自然生效）；数据根 drivers/ 降为兜底（开发期与
//      0.4.x 共存场景兼容）。env 非法继续回退；要求 is_file + 可执行；
//      找不到 → 中文明细（含已查找列表）
//    · 注册表门禁（L145-159）：未安装/已禁用 → LlamaServerError 中文明细；
//      失效包正是活动服务对象时先回收子进程再抛（0.4.29 缺陷修复 A）
//    · GGUF = files[] 首个 .gguf 结尾（L162-180）；ctx 优先级 显式 > manifest
//      context_length > 不带 -c（L376-379）
//    · 同一时刻只跑一个对话包（L23-28）：同包同档复用 / 异包换装停旧启新 /
//      同包异档（懒加载升档 D5）同路径停旧启新；全部判定在锁内依据状态完成
//    · 停止双防护（L288-326）：先 poll 在跑再动手；SIGTERM ≤20s 宽限 → SIGKILL 再等 5s
//    · 启动失败回收现场再抛（L393-397），不留半截状态
//    · 健康探测 GET /v1/models 直到 200，0.5s 间隔；早死/超时两种失败均带日志尾巴
//    · 子进程 env 剥离 6 个代理键（L209-213）；日志 {logs}/llama-server-<pack>.log
//      append 模式（换装重启不抹上次日志）
//    · atexit 兜底（L416-440）：terminate 只等 5s 未死再 kill
//
//  偏差（汇报清单同步）：
//    ① 日志目录：Python resolve_log_dir 应用目录 logs/ 优先、data_root/logs 兜底；
//       native 直接用 {data_root}/logs（原生应用目录语义不同，既有决议）。
//    ② asyncio.Lock 等价物为内置 AsyncMutex（NSLock+continuation 串行闸门）——
//       Swift actor 在 await 点可重入，无法保证「锁内完成全部判定」。
//    ③ 健康探测用 URLSession（2s 整体超时）：URLSession 本就不读 HTTP_PROXY 系
//       环境变量（httpx trust_env=False 的等价语义），回环不绕守卫漏斗。
//    ④ Python docstring 称「context_length 负值按未显式传入回落 manifest」，但代码
//       `context_length if context_length else …` 对负值为 truthy 会直传 -c（潜在
//       上游 bug）——按代码行为复刻，矛盾已记录汇报。
//
//  W5 KV 前缀复用·llama.cpp 路侦察结论（0.7.5 W5 拍板项，诚实登记）：
//    · 调用形态：HTTP（NativeOpenAIChatConnector → 驱动动态端口的 llama-server
//      OpenAI 兼容端点），非进程内；
//    · 服务端现状：本驱动未传 --parallel，llama-server 默认单 slot——同 slot 内
//      顺序到达的同前缀请求由服务端自动复用已算 KV（只增量 prefill 差异后缀），
//      客户端零改动即得 W5 拍板收益的主路径（换装串行通道天然顺序请求）；
//    · 未落地项：--prompt-cache 文件持久化 / cache_prompt 请求参数——本仓捆绑
//      llama-server 版本的旗标兼容性未经真机验证，盲加启动参数有起不来风险
//      （spawn 失败=对话全断），且文件缓存跨进程收益场景在本 app 顺序单 slot
//      流量下边际很小；登记留待后续波次真机验证后再定；
//    · 可验证收益层：NativeKVPrefixPolicy（缓存键/命中判定/TTL 纯函数）+
//      kv.hit/kv.miss 埋点契约由本层承载，MLX 路（NativeVModelMLXEngine）真接；
//    · Ollama 路同登记：服务端 keep_alive 内同模型同前缀自动复用，客户端无可开关。
//

import Foundation

/// LlamaServerError 等价物：二进制缺失/包缺 GGUF/启动失败/健康探测超时（中文明细，
/// connector 层转 400 直达用户）。
public struct NativeLlamaServerError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

// ════════════════════════════════════════════════════════════
// MARK: - 进程缝（FakeProcess 先例：单测注入假进程，绝不要求真模型）
// ════════════════════════════════════════════════════════════

/// subprocess.Popen 等价物的最小面。
public protocol NativeLlamaServerProcess: Sendable {
    /// poll() is None 等价：仍在跑。
    var isRunning: Bool { get }
    /// returncode 等价（未退出为 nil）。
    var exitCode: Int32? { get }
    /// SIGTERM 礼让。
    func terminate()
    /// SIGKILL 强杀。
    func kill()
    /// 等退出，true=宽限内已退出。
    func wait(timeout: Double) async -> Bool
    /// 进程已确认回收/退出后调用（atexit 跟踪摘除；假进程空实现即可）。
    func untrack()
}

/// _spawn 等价物：argv + 剥离后的 env + 日志句柄（driver 持有并负责关闭）。
public protocol NativeLlamaSpawner: Sendable {
    func spawn(argv: [String], env: [String: String], log: FileHandle) throws
        -> any NativeLlamaServerProcess
}

/// atexit 兜底登记表（仅生产 spawner 登记；测试用假 spawner 不触碰）。
final class NativeLlamaAtexit: @unchecked Sendable {
    static let shared = NativeLlamaAtexit()
    private let lock = NSLock()
    private var pids = Set<pid_t>()
    private var installed = false

    func track(_ pid: pid_t) {
        lock.lock()
        if !installed {
            installed = true
            atexit { NativeLlamaAtexit.shared.cleanup() }
        }
        pids.insert(pid)
        lock.unlock()
    }

    func untrack(_ pid: pid_t) {
        lock.lock(); pids.remove(pid); lock.unlock()
    }

    /// terminate 只等 5s（应用退出不该被拖 20s），未死再 kill。
    func cleanup() {
        lock.lock(); let snapshot = Array(pids); lock.unlock()
        for pid in snapshot where kill(pid, 0) == 0 { kill(pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let alive = snapshot.contains { kill($0, 0) == 0 }
            if !alive { return }
            usleep(50_000)
        }
        for pid in snapshot where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }
}

/// 生产进程包装（Foundation.Process；stdout/stderr 同导流进日志句柄）。
final class NativeServerProcess: NativeLlamaServerProcess, @unchecked Sendable {
    private let proc: Process
    init(_ proc: Process) {
        self.proc = proc
        NativeLlamaAtexit.shared.track(proc.processIdentifier)
    }
    var isRunning: Bool { proc.isRunning }
    var exitCode: Int32? { proc.isRunning ? nil : proc.terminationStatus }
    func terminate() { if proc.isRunning { proc.terminate() } }
    func kill() { if proc.isRunning { Darwin.kill(proc.processIdentifier, SIGKILL) } }
    func untrack() { NativeLlamaAtexit.shared.untrack(proc.processIdentifier) }
    /// asyncio.to_thread(proc.wait, timeout) 等价：后台轮询，不阻塞协作线程池。
    func wait(timeout: Double) async -> Bool {
        await Task.detached(priority: .utility) { [proc] in
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if !proc.isRunning { return true }
                usleep(50_000)
            }
            return !proc.isRunning
        }.value
    }
}

/// 生产 spawner。
public struct NativeProcessSpawner: NativeLlamaSpawner {
    public init() {}
    public func spawn(argv: [String], env: [String: String], log: FileHandle) throws
        -> any NativeLlamaServerProcess {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        p.environment = env
        p.standardOutput = log
        p.standardError = log
        try p.run()
        return NativeServerProcess(p)
    }
}

// ════════════════════════════════════════════════════════════
// MARK: - 串行闸门（asyncio.Lock 等价物，偏差②）
// ════════════════════════════════════════════════════════════

/// 非可重入异步互斥：ensure/stop 全判定在闸门内完成；await 点不放行第二个调用方。
final class NativeAsyncMutex: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    func acquire() async {
        let immediate = withLock { () -> Bool in
            if !held { held = true; return true }
            return false
        }
        if immediate { return }
        await withCheckedContinuation { cont in
            withLock { waiters.append(cont) }
        }
    }

    func release() {
        let next = withLock { () -> CheckedContinuation<Void, Never>? in
            if !waiters.isEmpty { return waiters.removeFirst() }
            held = false
            return nil
        }
        next?.resume()   // held 保持 true，直接移交给下一位
    }
}

// ════════════════════════════════════════════════════════════
// MARK: - 驱动
// ════════════════════════════════════════════════════════════

public final class NativeLlamaCppDriver: @unchecked Sendable {

    public static let envLlamaServer = "VETARAI_LLAMA_SERVER"
    /// terminate 宽限默认（秒）；具名可写以便测试收窄（Python 同款注释语义）。
    public var terminateGrace = 20.0
    /// SIGKILL 后再等上限（_stop_locked L322 / atexit L433 同款 5s）。
    public var killWait = 5.0
    public static let defaultBootTimeout = 600.0
    /// 子进程环境剥离清单（L74-75）。
    public static let proxyEnvKeys = ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY",
                                      "http_proxy", "https_proxy", "all_proxy"]

    public let store: NativeModelPackStore
    public var spawner: any NativeLlamaSpawner
    public var environment: [String: String]
    public var dataRootProvider: @Sendable () -> URL
    public var configProvider: @Sendable () -> [String: JSONValue]
    /// 冻结包内 Resources 候选（native = Bundle.main.resourceURL；测试注入临时目录/nil）。
    public var bundleResourceURL: URL?
    /// time.monotonic 缝。
    public var now: @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }
    /// asyncio.sleep 缝（测试注入脚本时钟推进，绝不真等）。
    public var sleep: @Sendable (UInt64) async -> Void = { ns in
        try? await Task.sleep(nanoseconds: ns)
    }
    /// 健康探测缝：GET 127.0.0.1:port/v1/models → true=200（httpx trust_env=False 等价，
    /// 偏差③）。连接被拒/超时一律 false（还没起好，继续等）。
    public var probe: @Sendable (Int) async -> Bool = { port in
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/models") else { return false }
        var req = URLRequest(url: url)
        // 维持写死 2s（0.7.5 W13 口径）：内部心跳——本机回环健康探测的快速失败窗口，
        // 超时即「还没起好，继续等」语义的一环；放长只会拖慢启动/换包判定
        req.timeoutInterval = 2.0
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }
    /// _free_port 缝（bind 0 即得即放；bind/spawn 竞态由健康探测兜住——Python 同款注释）。
    public var freePort: @Sendable () -> Int = {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return 0 }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        let bindOk = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindOk == 0 else { return 0 }
        var out = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameOk = withUnsafeMutablePointer(to: &out) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard nameOk == 0 else { return 0 }
        return Int(UInt16(bigEndian: out.sin_port))
    }
    /// 日志目录缝（偏差①：{data_root}/logs）。
    public var logDirProvider: @Sendable () -> URL

    // 活动服务状态（进程级单例等价；同一时刻至多一个对话包在跑）
    private struct Active {
        var packId: String?
        var proc: (any NativeLlamaServerProcess)?
        var port = 0
        var log: FileHandle?
        /// 启动时的 -c 档位；nil = 未显式指定（llama-server 自身默认）。
        var ctx: Int?
    }
    private var state = Active()
    private let mutex = NativeAsyncMutex()
    public var log: @Sendable (String) -> Void = { _ in }

    public init(store: NativeModelPackStore,
                spawner: any NativeLlamaSpawner = NativeProcessSpawner(),
                environment: [String: String] = ProcessInfo.processInfo.environment,
                dataRootProvider: @escaping @Sendable () -> URL,
                configProvider: @escaping @Sendable () -> [String: JSONValue] = { [:] },
                bundleResourceURL: URL? = Bundle.main.resourceURL) {
        self.store = store
        self.spawner = spawner
        self.environment = environment
        self.dataRootProvider = dataRootProvider
        self.configProvider = configProvider
        self.bundleResourceURL = bundleResourceURL
        self.logDirProvider = { dataRootProvider().appendingPathComponent("logs") }
    }

    // MARK: - 解析（二进制 / GGUF / 超时）

    /// resolve_server_binary（L107-142；P3-W6④ 翻转）：bundle > env > dataRoot，
    /// env 非法继续回退。
    public func resolveServerBinary() throws -> URL {
        var candidates: [URL] = []
        if let res = bundleResourceURL {
            candidates.append(res.appendingPathComponent("drivers/llama-server"))
        }
        let raw = (environment[Self.envLlamaServer] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty {
            candidates.append(URL(fileURLWithPath: (raw as NSString).expandingTildeInPath))
        }
        candidates.append(dataRootProvider().appendingPathComponent("drivers/llama-server"))
        let fm = FileManager.default
        for c in candidates {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: c.path, isDirectory: &isDir),
               !isDir.boolValue, fm.isExecutableFile(atPath: c.path) {
                return c
            }
        }
        let tried = candidates.map(\.path).joined(separator: "、")
        throw NativeLlamaServerError(
            "未找到 llama-server 二进制（模型包对话后端的本体）。"
            + "请到「模型包」面板查看安装指引，或由设置/部署方将 llama-server 放入 "
            + "数据目录 drivers/ 下（亦可用环境变量 VETARAI_LLAMA_SERVER 指定路径）。"
            + "已查找: \(tried.isEmpty ? "（无候选路径）" : tried)")
    }

    /// _enabled_entry（L145-159）：注册表状态门禁（热路径短路前必过）。
    @discardableResult
    private func enabledEntry(_ packId: String) throws -> [String: JSONValue] {
        guard let entry = store.getEntry(packId) else {
            throw NativeLlamaServerError(
                "模型包 \(PySem.reprString(packId)) 未安装。请到「模型包」面板安装后再对话。")
        }
        guard entry["status"]?.string == "installed" else {
            throw NativeLlamaServerError(
                "模型包 \(PySem.reprString(packId)) 已禁用。请到「模型包」面板启用后再对话。")
        }
        return entry
    }

    /// _gguf_path（L162-180）：注册表 files[] 首个 .gguf 结尾条目 → 绝对路径。
    private func ggufPath(_ packId: String) throws -> URL {
        let entry = try enabledEntry(packId)
        var ggufRel = ""
        for f in entry["files"]?.array ?? [] {
            let p = f.object?["path"].map(WFText.pyStr) ?? ""
            if p.lowercased().hasSuffix(".gguf") { ggufRel = p; break }
        }
        guard !ggufRel.isEmpty else {
            throw NativeLlamaServerError(
                "模型包 \(PySem.reprString(packId)) 的清单中没有 .gguf 权重文件，"
                + "llama.cpp 驱动无法加载。请检查该包的 catalog 清单（files[].path 须含 .gguf 条目）。")
        }
        let path = try store.packDir(packId).appendingPathComponent(ggufRel)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDir),
              !isDir.boolValue else {
            throw NativeLlamaServerError(
                "模型包 \(PySem.reprString(packId)) 的权重文件缺失: \(ggufRel)"
                + "（安装不完整或文件被手动删除），请到「模型包」面板重新安装。")
        }
        return path
    }

    /// _context_length_of（L183-188）：manifest 可选键（正整数才采纳）。
    private func manifestContextLength(_ packId: String) -> Int? {
        guard let cl = store.readManifest(packId)["context_length"],
              case .int(let n) = cl, n > 0 else { return nil }
        return Int(n)
    }

    /// _boot_timeout（L199-206）：config model_pack_boot_timeout_s 钳 [10, 7200]。
    func bootTimeout() -> Double {
        guard let v = configProvider()["model_pack_boot_timeout_s"].flatMap(PySem.toFloat),
              v != 0 else { return Self.defaultBootTimeout }
        return max(10.0, min(v, 7200.0))
    }

    /// _subprocess_env（L209-213）：剥离 6 个代理键。
    func subprocessEnv() -> [String: String] {
        environment.filter { !Self.proxyEnvKeys.contains($0.key) }
    }

    private func serverLogPath(_ packId: String) -> URL {
        logDirProvider().appendingPathComponent("llama-server-\(packId).log")
    }

    // MARK: - spawn / 健康探测

    /// _spawn（L224-243）：日志 append 打开 → spawner；失败关句柄再抛。
    private func spawnServer(_ packId: String, binary: URL, gguf: URL, port: Int,
                             contextLength: Int?) throws
        -> (proc: any NativeLlamaServerProcess, log: FileHandle, logPath: URL) {
        var argv = [binary.path, "--model", gguf.path,
                    "--port", String(port), "--host", "127.0.0.1"]
        if let cl = contextLength, cl != 0 { argv += ["-c", String(cl)] }
        let logPath = serverLogPath(packId)
        try FileManager.default.createDirectory(at: logPath.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logPath.path) {
            FileManager.default.createFile(atPath: logPath.path, contents: nil)
        }
        let fh = try FileHandle(forWritingTo: logPath)
        do {
            try fh.seekToEnd()   // append：换装重启不抹掉上一次日志
            let proc = try spawner.spawn(argv: argv, env: subprocessEnv(), log: fh)
            log("llama-server 已拉起: pack=\(packId) port=\(port) argv=\(argv) log=\(logPath.path)")
            return (proc, fh, logPath)
        } catch {
            try? fh.close()
            throw error
        }
    }

    /// _log_tail（L246-252）：错误信息用的日志尾巴。
    func logTail(_ path: URL, limit: Int = 2000) -> String {
        do {
            let data = try Data(contentsOf: path)
            let tail = data.suffix(limit)
            let text = String(decoding: tail, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "（日志为空）" : text
        } catch {
            return "（读取日志失败: \(error.localizedDescription)）"
        }
    }

    /// _wait_ready（L255-283）：poll 早死 → 探测 → 超时 → sleep 0.5s。
    private func waitReady(_ proc: any NativeLlamaServerProcess, port: Int,
                           logPath: URL, timeout: Double) async throws {
        let deadline = now() + timeout
        while true {
            if !proc.isRunning {
                throw NativeLlamaServerError(
                    "llama-server 启动后立即退出（exit=\(proc.exitCode ?? -1)）。"
                    + "日志尾巴：\(logTail(logPath))")
            }
            if await probe(port) { return }
            if now() >= deadline {
                throw NativeLlamaServerError(
                    "llama-server 启动超时（\(String(format: "%.0f", timeout))s 内 "
                    + "/v1/models 未就绪）。日志尾巴：\(logTail(logPath))")
            }
            await sleep(500_000_000)
        }
    }

    // MARK: - 停止（双防护，调用方须持闸门）

    /// _stop_locked（L288-326）：True=本次活动进程已处理；False=本无活动进程。
    @discardableResult
    private func stopLocked() async -> Bool {
        let proc = state.proc
        let logHandle = state.log
        state = Active()
        if let logHandle { try? logHandle.close() }
        guard let proc else { return false }
        // 防护①：先查进程在跑再动手（0.4.7「为卸载而加载」教训）
        if !proc.isRunning {
            log("llama-server 子进程已自行退出（exit=\(proc.exitCode ?? -1)），仅清理状态")
            proc.untrack()
            return true
        }
        // 防护②：SIGTERM 带宽限，未死再 SIGKILL
        proc.terminate()
        if await proc.wait(timeout: terminateGrace) {
            proc.untrack()
            return true
        }
        proc.kill()
        _ = await proc.wait(timeout: killWait)
        proc.untrack()
        return true
    }

    // MARK: - 对外 API

    /// active_pack（L331-336）：子进程活着才算数（只读查询，无清理副作用）。
    public func activePack() -> String? {
        guard let proc = state.proc, proc.isRunning else { return nil }
        return state.packId
    }

    /// active_base_url（L339-343）：含 /v1；无活动服务 nil。
    public func activeBaseURL() -> String? {
        guard activePack() != nil else { return nil }
        return "http://127.0.0.1:\(state.port)/v1"
    }

    /// ensure_server（L346-398）：全部判定在闸门内依据 state 完成。
    @discardableResult
    public func ensureServer(_ packId: String, contextLength: Int? = nil) async throws -> String {
        await mutex.acquire()
        defer { mutex.release() }
        // 门禁必须在热路径短路之前（缺陷修复 A）；失效包正在服务先停再抛
        do {
            try enabledEntry(packId)
        } catch {
            if state.packId == packId { await stopLocked() }
            throw error
        }
        // 期望档解析（显式 > manifest > 默认；Python truthiness：0/nil 回落，
        // 负值 truthy 直传——docstring 与代码矛盾，按代码复刻，见偏差④）
        var wantCtx = contextLength
        if wantCtx == 0 { wantCtx = nil }
        if wantCtx == nil { wantCtx = manifestContextLength(packId) }
        if state.packId == packId, let proc = state.proc, proc.isRunning,
           state.ctx == wantCtx {
            return "http://127.0.0.1:\(state.port)/v1"   // 同包同档复用
        }
        if state.proc != nil {
            await stopLocked()   // 换装/异档：先停旧、再启新（Ollama 同款）
        }
        let binary = try resolveServerBinary()
        let gguf = try ggufPath(packId)
        let port = freePort()
        let (proc, logHandle, logPath) = try spawnServer(packId, binary: binary, gguf: gguf,
                                                         port: port, contextLength: wantCtx)
        state = Active(packId: packId, proc: proc, port: port, log: logHandle, ctx: wantCtx)
        do {
            try await waitReady(proc, port: port, logPath: logPath, timeout: bootTimeout())
        } catch {
            await stopLocked()   // 启动失败回收现场
            throw error
        }
        return "http://127.0.0.1:\(port)/v1"
    }

    /// stop_server（L401-413）：packId 给定时只停匹配的包（不匹配=不动，False）。
    @discardableResult
    public func stopServer(_ packId: String? = nil) async -> Bool {
        await mutex.acquire()
        defer { mutex.release() }
        if state.proc == nil { return false }
        if let packId, state.packId != packId { return false }
        return await stopLocked()
    }
}
