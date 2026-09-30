//
//  NativeModelPackDownloader.swift
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

//  逐行为移植（⛔ 只读行为规格源：subagent/sidecar/model_packs/downloader.py，458 行）：
//    · 出站纪律（L20-24 + L114-127）：http(s) 源先过 assert_guard 漏斗；被拒按
//      「源不可用」回退下一源，全源失败汇总 PackDownloadError（中文明细）；
//      成功 guard_report_success / 失败 guard_report_failure；file:// 本地源不过 guard
//    · 下载语义（L26-35）：流式落盘 .partial/<path>.part + Range 断点续传
//      （206 追加 / 200 覆盖 / 416 删 .part 重下一次）；字节数预检 → SHA256 校验，
//      不符换下一源；os.replace 原子 rename 到位；全完成 → manifest.json 副本
//      （原子写）+ 登记 registry + download_done；取消保留 .partial 发
//      download_cancelled 再上抛；其余失败保留现场发 download_error
//    · _Progress（L130-166）：进度聚合 + 0.15s 节流（每文件起止各一次必发）
//    · ModelPackDownloadManager（L347-395）：每 pack_id 至多一个任务，重复启动
//      PackDownloadError（端点转 409）；cancel 送达取消并 ≤10s 等收尾
//    · fetch_catalog（L402-458）：file:// 本地目录（相对 sources 改写绝对 file://）
//      / http(s) 过 guard；validate_catalog 校验；单源失败返回 error 不拖死整列
//
//  偏差（汇报清单同步）：
//    ① 超时为 URLSession 整体 timeoutInterval（read 60s 同值），不细分 httpx
//       connect/read 双超时（同 P2-W2 偏差③ / P3-W2b 偏差①）。
//    ② 代理不经 URLSession 注入：guard 只做放行/拦截判定（NativeNetworkGuard 全仓
//       同款，P3-W2b 偏差②同口径）；Python 经 httpx proxy 参数应用代理。
//    ③ 传输错误文案的类型名（Python httpx.ConnectError 等）以 URLError 描述代替，
//       语义等价；JSON 解析错误明细同理（JSONSerialization vs json.JSONDecodeError）。
//    ④ 端点 install 的 `except RuntimeError → 500（安装根解析失败）`在 Python 实为
//       不可达分支（pack_dir 解析在后台任务内，失败走 download_error 事件）——
//       按实际行为复刻：.app 拒绝经 download_error 事件送达，端点仍 202 accepted。
//    ⑤ 消费端取消在 Swift 流上可表现为 next()→nil 提前结束（Python 于 aiter_bytes
//       抛 CancelledError）；写循环后补 checkCancellation 归取消语义，避免半截
//       文件误报「字节数不符」。
//

import Foundation
import CryptoKit

/// PackDownloadError 等价物：全源回退用尽 / 校验不过 / IO 错误（中文明细）。
public struct NativePackDownloadError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

// ════════════════════════════════════════════════════════════
// MARK: - 传输缝（FakeTransport 先例：单测注入脚本化假传输，绝不触网）
// ════════════════════════════════════════════════════════════

/// 模型包下载/catalog 的传输层。生产 = URLSession；测试 = 脚本化假传输。
public protocol NativeMPDownloadTransport: Sendable {
    /// httpx client.stream("GET", url, headers=headers) 等价：返回（状态码，字节块流）。
    /// 连接级错误（含超时）直接 throw；流中途错误经流上抛。
    func streamBytes(url: String, headers: [String: String]) async throws
        -> (status: Int, bytes: AsyncThrowingStream<Data, Error>)
    /// httpx client.get(url) 等价（catalog 拉取）：返回（状态码，全量响应体）。
    func getData(url: String) async throws -> (status: Int, data: Data)
}

/// 生产传输（URLSession；follow_redirects=True 等价 = URLSession 默认跟随重定向）。
public struct NativeURLSessionMPTransport: NativeMPDownloadTransport {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func streamBytes(url: String, headers: [String: String]) async throws
        -> (status: Int, bytes: AsyncThrowingStream<Data, Error>) {
        guard let u = URL(string: url) else { throw URLError(.badURL) }
        var req = URLRequest(url: u)
        req.timeoutInterval = NativeModelPackDownloader.readTimeout
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let chunks = AsyncThrowingStream<Data, Error> { cont in
            let task = Task {
                do {
                    var buf = Data()
                    buf.reserveCapacity(NativeModelPackDownloader.chunkSize)
                    for try await b in bytes {
                        buf.append(b)
                        if buf.count >= NativeModelPackDownloader.chunkSize {
                            cont.yield(buf)
                            buf = Data()
                            buf.reserveCapacity(NativeModelPackDownloader.chunkSize)
                        }
                    }
                    if !buf.isEmpty { cont.yield(buf) }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { @Sendable _ in task.cancel() }
        }
        return (http.statusCode, chunks)
    }

    public func getData(url: String) async throws -> (status: Int, data: Data) {
        guard let u = URL(string: url) else { throw URLError(.badURL) }
        var req = URLRequest(url: u)
        req.timeoutInterval = NativeModelPackDownloader.readTimeout
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (http.statusCode, data)
    }
}

// ════════════════════════════════════════════════════════════
// MARK: - 下载器
// ════════════════════════════════════════════════════════════

public final class NativeModelPackDownloader: @unchecked Sendable {

    public static let chunkSize = 256 * 1024      // _CHUNK：流式写盘块大小
    public static let progressInterval = 0.15     // _PROGRESS_INTERVAL：进度节流（秒）
    /// 0.7.5 W7：进度事件实时速率滚动窗（秒）——与 NativeModelDownloader.rateWindowSeconds
    /// 同口径（必备模型首装弹窗/设置-模型包两处 0.7.4 新组件的速率语义）。
    public static let rateWindowSeconds = 3.0
    public static let connectTimeout = 10.0       // _CONNECT_TIMEOUT（偏差①：整体超时参看）
    // 维持写死（0.7.5 W13 口径）：换源敏感值——与 Python 侧 _READ_TIMEOUT 逐字对齐防双端漂移
    public static let readTimeout = 60.0          // _READ_TIMEOUT
    /// fetch_catalog 相对 sources 判据（L432）：已是绝对形态的 scheme 前缀。
    public static let absSchemes = ["http://", "https://", "file://"]

    // 事件 action 名（resource 恒为 model_pack，前端按 action 分流）
    public static let evtStart = "download_start"
    public static let evtProgress = "download_progress"
    public static let evtDone = "download_done"
    public static let evtError = "download_error"
    public static let evtCancelled = "download_cancelled"

    public let store: NativeModelPackStore
    public let networkGuard: NativeNetworkGuard
    /// 生产 = URLSession；测试 = 脚本化假传输（绝不触网）。
    public var transport: any NativeMPDownloadTransport
    /// 失败明细落盘（0.7.7 W4）：默认全局单例；测试注入独立 logDirectory 实例。
    /// 脱敏红线：源 URL 只落文件名（NativeModelDownloader.logSafeName），query/token 不落盘。
    public var logger: AppLogger = .shared
    /// time.monotonic 缝（节流测试注入脚本时钟）。
    public var now: @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }
    /// sha256 计算缝（asyncio.to_thread 等价；测试可注入直算）。
    public var sha256Async: @Sendable (URL) async throws -> String = { url in
        try await Task.detached(priority: .utility) {
            try NativeModelPackDownloader.sha256File(url)
        }.value
    }
    /// emit 回调（action, pack_id, fields）——默认经原生总线推 SSE（资源变更旁路，
    /// 失败绝不影响下载主流程）；测试注入捕获器验证节流与生命周期语义。
    public var emit: @Sendable (String, String, [String: JSONValue]) -> Void = { action, packId, fields in
        var extra = fields
        extra["pack_id"] = .string(packId)
        NativeEndpointNotify.change(NativeAppEvents.resourceModelPack, action, extra: extra)
    }

    /// W7（0.7.4）：本地 catalog 读取超时（秒）。
    /// 实证：file:// 分支原先用同步 `Data(contentsOf:)`——TCC 保护目录的 open()
    /// 会在内核态悬挂等待授权决策，同步读取把整个调用线程卡死。改为竞速超时兜底。
    public var localCatalogReadTimeout: TimeInterval = 8
    /// W7 注入缝：本地 catalog 原始读取器（默认 = 真实 Data(contentsOf:)，
    /// 失败/不存在 → nil；测试注入假实现——勿真读 TCC 保护目录）。
    /// 无论默认还是注入实现，调用侧一律套 localCatalogReadTimeout 竞速。
    public var localCatalogReader: @Sendable (URL) async throws -> Data? = { url in
        try? Data(contentsOf: url)
    }

    /// W7 超时竞速：读取任务 vs 计时器，先到者赢。
    /// ⚠️ TCC 内核态阻塞线程无法强杀——超时后读取任务可能永久悬挂（线程泄漏），
    /// 但调用方由计时器分支脱身；这是 macOS 隐私保护目录阻塞的既定代价。
    static func withReadTimeout(
        seconds: TimeInterval,
        read: @Sendable @escaping () async throws -> Data?
    ) async throws -> Data? {
        try await withThrowingTaskGroup(of: Data?.self) { group in
            group.addTask { try await read() }
            group.addTask { () -> Data? in
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw NativePackDownloadError(
                    "读取本地 catalog 超时（\(String(format: "%g", seconds)) 秒无响应）。"
                    + "该目录可能受 macOS 隐私保护——请检查 系统设置→隐私与安全性 "
                    + "中的文件夹访问授权（桌面/文稿/下载等目录需单独授权）")
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    public init(store: NativeModelPackStore, networkGuard: NativeNetworkGuard,
                transport: any NativeMPDownloadTransport = NativeURLSessionMPTransport()) {
        self.store = store
        self.networkGuard = networkGuard
        self.transport = transport
    }

    // MARK: - 纯函数片段

    /// _file_url_to_path（L94-98）：file:///abs/path → /abs/path（百分号解码）。
    public static func fileURLToPath(_ url: String) -> URL {
        guard let u = URL(string: url) else { return URL(fileURLWithPath: url) }
        // file://localhost/... 与 file:///... 等价；其余 host 形态不支持（path 照取）
        return URL(fileURLWithPath: u.path)
    }

    /// _sha256_file（L101-106）：1MB 块流式哈希。
    public static func sha256File(_ url: URL) throws -> String {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        var h = SHA256()
        while true {
            let block = try fh.read(upToCount: chunkSize * 4) ?? Data()
            if block.isEmpty { break }
            h.update(data: block)
        }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func fileSize(_ url: URL) -> Int64? {
        guard let n = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        else { return nil }
        return n.int64Value
    }

    /// 滚动窗均速（0.7.5 W7）：剔除窗龄超 rateWindowSeconds 的样本，sum/span
    /// （span 下限 0.5s 防首块瞬时尖刺）；空窗 → 0。与 NativeModelDownloader.displayRate
    /// 同口径（此处时钟为 owner.now() 的 Double 秒，便于测试注入脚本时钟）。
    static func displayRate(samples: inout [(Double, Int64)], now: Double) -> Double {
        samples.removeAll { now - $0.0 > Self.rateWindowSeconds }
        guard let oldest = samples.first else { return 0 }
        let span = max(now - oldest.0, 0.5)
        let sum = samples.reduce(Int64(0)) { $0 + $1.1 }
        return Double(sum) / span
    }

    // MARK: - _Progress（L130-166）

    /// 单包进度聚合与节流发射器。
    final class Progress {
        let packId: String
        let totalBytes: Int64
        unowned let owner: NativeModelPackDownloader
        var doneBytes: Int64 = 0          // 已完成文件的累计字节（按清单声明值计）
        var fileReceived: Int64 = 0       // 当前文件已收字节（含续传基线）
        var filePath = ""
        var fileTotal: Int64 = 0
        var last: Double = 0.0
        /// 0.7.5 W7：滚动速率样本（owner.now() 时钟，秒）与最近一次均速
        var rateSamples: [(Double, Int64)] = []
        var bytesPerSecond: Double = 0

        init(packId: String, totalBytes: Int64, owner: NativeModelPackDownloader) {
            self.packId = packId
            self.totalBytes = totalBytes
            self.owner = owner
        }

        func startFile(_ path: String, total: Int64, baseline: Int64) {
            filePath = path
            fileTotal = total
            fileReceived = baseline
            rateSamples = []          // 新文件速率归零（不带上一文件残值，同 W2 口径）
            bytesPerSecond = 0
            emitNow()
        }

        func advance(_ n: Int64) {
            fileReceived += n
            // 滚动窗速率（W7）：3s 样本剔旧求均速，随进度事件上屏
            let now = owner.now()
            rateSamples.append((now, n))
            bytesPerSecond = NativeModelPackDownloader.displayRate(samples: &rateSamples, now: now)
            if owner.now() - last >= NativeModelPackDownloader.progressInterval {
                emitNow()
            }
        }

        func finishFile() {
            doneBytes += fileTotal
            emitNow()
        }

        func emitNow() {
            last = owner.now()
            owner.emit(NativeModelPackDownloader.evtProgress, packId, [
                "file": .string(filePath),
                "file_received": .int(fileReceived),
                "file_total": .int(fileTotal),
                "received_bytes": .int(doneBytes + fileReceived),
                "total_bytes": .int(totalBytes),
                "bytes_per_second": .double(bytesPerSecond),   // 0.7.5 W7：实时速率字段
            ])
        }
    }

    // MARK: - _download_http_file（L169-218）

    /// 从单个 http(s) 源流式下载到 part（支持续传）。失败抛异常（调用方回退下一源）。
    /// Range 三态：206 追加 / 200 覆盖 / 416 删 .part 从头重下（只重试一次）。
    private func downloadHTTPFile(_ url: String, part: URL, expectedSize: Int64,
                                  progress: Progress) async throws {
        let host = URL(string: url)?.host ?? ""
        _ = try networkGuard.assertGuard(host)   // NativeNetworkGuardError → 源回退
        var retried416 = false
        while true {
            let existing = Self.fileSize(part) ?? 0
            var headers: [String: String] = [:]
            if existing > 0 { headers["Range"] = "bytes=\(existing)-" }
            let (status, bytes) = try await transport.streamBytes(url: url, headers: headers)
            if status == 416, existing > 0, !retried416 {
                // 本地续传点越界：删半截从头再来
                try? FileManager.default.removeItem(at: part)
                retried416 = true
                logger.warn("续传点越界（416），删 .part 从头重下：\(part.lastPathComponent) @ \(host)")
                continue
            }
            guard status == 200 || status == 206 else {
                networkGuard.reportFailure(host)
                logger.warn("源返回 HTTP \(status)，换下一源：\(part.lastPathComponent) @ \(host)")
                throw NativePackDownloadError("\(host): HTTP \(status)")
            }
            let baseline: Int64 = status == 200 ? 0 : existing
            if baseline != progress.fileReceived {
                // 基线可能因 416/200 重下而重置，校准进度计数（防进度条>100%）
                progress.fileReceived = baseline
            }
            try FileManager.default.createDirectory(
                at: part.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: part.path) {
                FileManager.default.createFile(atPath: part.path, contents: nil)
            }
            let fh = try FileHandle(forWritingTo: part)
            do {
                if status == 200 {
                    try fh.truncate(atOffset: 0)   // 覆盖写
                } else {
                    try fh.seekToEnd()             // 206 追加写
                }
                for try await chunk in bytes {
                    try Task.checkCancellation()   // 取消点（CancelledError 等价）
                    try fh.write(contentsOf: chunk)
                    progress.advance(Int64(chunk.count))
                }
                // 消费端取消可表现为流提前结束（next()→nil 而非抛错）：补一刀归取消语义，
                // 否则半截文件会落到字节数预检报「全部源失败」（Python 在 aiter_bytes 抛
                // CancelledError，不会走到尺寸校验）。
                try Task.checkCancellation()
                try fh.close()
            } catch {
                try? fh.close()
                if let u = error as? URLError, u.code == .cancelled { throw CancellationError() }
                throw error
            }
            break
        }
        // 完整性预检：字节数对不上不必浪费哈希
        let got = Self.fileSize(part) ?? 0
        if expectedSize > 0, got != expectedSize {
            throw NativePackDownloadError(
                "字节数不符：\(part.lastPathComponent) 收到 \(got)，应为 \(expectedSize)")
        }
    }

    /// _copy_local_file（L221-228）：file:// 源本地分块拷贝。
    private func copyLocalFile(_ src: URL, part: URL, progress: Progress) throws {
        try FileManager.default.createDirectory(
            at: part.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fin = try FileHandle(forReadingFrom: src)
        defer { try? fin.close() }
        if !FileManager.default.fileExists(atPath: part.path) {
            FileManager.default.createFile(atPath: part.path, contents: nil)
        }
        let fout = try FileHandle(forWritingTo: part)
        defer { try? fout.close() }
        try fout.truncate(atOffset: 0)
        while true {
            try Task.checkCancellation()
            let block = try fin.read(upToCount: Self.chunkSize) ?? Data()
            if block.isEmpty { break }
            try fout.write(contentsOf: block)
            progress.advance(Int64(block.count))
        }
    }

    // MARK: - _fetch_one_file（L231-300）

    /// 按 sources 顺序回退下载单个文件，SHA256 校验通过后原子 rename 到位。
    private func fetchOneFile(_ fileEntry: [String: JSONValue], dest: URL, part: URL,
                              progress: Progress) async throws {
        let fm = FileManager.default
        let expectedSha = (fileEntry["sha256"]?.string ?? "").lowercased()
        let expectedSize = fileEntry["size_bytes"].flatMap(PySem.toFloat).map { Int64($0) } ?? 0
        let relPath = fileEntry["path"]?.string ?? ""
        // 续传基线：.part 已有字节从断点继续（进度条不应从 0 起跳再猛蹿）
        let baseline = Self.fileSize(part) ?? 0
        progress.startFile(relPath, total: expectedSize, baseline: baseline)

        // 快速路径：最终文件已存在且哈希正确（中断在 rename 之后）→ 直接复用
        if fm.fileExists(atPath: dest.path),
           (try? await sha256Async(dest)) == expectedSha {
            progress.fileReceived = expectedSize
            progress.finishFile()
            return
        }
        // 续传快捷路径：.part 恰好完整（中断在 rename 之前）→ 只补校验+rename
        if let partSize = Self.fileSize(part), fm.fileExists(atPath: part.path) {
            if partSize == expectedSize {
                if (try? await sha256Async(part)) == expectedSha {
                    try fm.createDirectory(at: dest.deletingLastPathComponent(),
                                           withIntermediateDirectories: true)
                    try Self.atomicReplace(part, dest)
                    progress.fileReceived = expectedSize
                    progress.finishFile()
                    return
                }
                try? fm.removeItem(at: part)   // 尺寸对但哈希错：内容不可信，重下
            } else if partSize > expectedSize {
                try? fm.removeItem(at: part)   // 半截比声明还长（远端变了）→ 重下
            }
        }

        var errors: [String] = []
        for srcV in fileEntry["sources"]?.array ?? [] {
            let src = srcV.string ?? ""
            do {
                if src.hasPrefix("file://") {
                    let local = Self.fileURLToPath(src)
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: local.path, isDirectory: &isDir),
                          !isDir.boolValue else {
                        throw NativePackDownloadError("本地源不存在: \(local.path)")
                    }
                    try copyLocalFile(local, part: part, progress: progress)
                } else {
                    try await downloadHTTPFile(src, part: part, expectedSize: expectedSize,
                                               progress: progress)
                }
                let gotSha = try await sha256Async(part)
                if gotSha != expectedSha {
                    // 哈希不符不记 guard 失败——这不是网络故障，是源内容不可信
                    errors.append("\(src): SHA256 不符（\(gotSha.prefix(12))… ≠ \(expectedSha.prefix(12))…）")
                    logger.warn("SHA256 不符，删 .part 换源：\(relPath) @ "
                        + "\(NativeModelDownloader.logSafeName(src))")
                    try? fm.removeItem(at: part)
                    progress.fileReceived = 0
                    continue
                }
                try fm.createDirectory(at: dest.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try Self.atomicReplace(part, dest)   // 同目录原子替换
                if !src.hasPrefix("file://") {
                    networkGuard.reportSuccess(URL(string: src)?.host ?? "")
                }
                progress.fileReceived = expectedSize
                progress.finishFile()
                return
            } catch is CancellationError {
                throw CancellationError()   // 取消是主流程语义，不得被源回退吞掉
            } catch let e as NativePackDownloadError {
                logger.warn("源失败换下一源：\(relPath) —— \(e.message)")
                errors.append(e.message)
                continue
            } catch let e as NativeNetworkGuardError {
                logger.warn("源被出站守卫拦截：\(relPath) @ \(e.host)")
                errors.append("\(e.host): \(e.message)")
                continue
            } catch let e as URLError {
                if e.code == .cancelled { throw CancellationError() }
                let host = URL(string: src)?.host ?? ""
                networkGuard.reportFailure(host)
                logger.warn("源连接失败/超时（码 \(e.code.rawValue)）：\(relPath) @ \(host)")
                errors.append("\(host): 连接失败/超时（\(e.code.rawValue)）")
                continue
            } catch {
                logger.warn("源失败换下一源：\(relPath) @ "
                    + "\(NativeModelDownloader.logSafeName(src)) —— "
                    + NativeModelDownloader.logSafeDetail(error.localizedDescription))
                errors.append("\(src): \(type(of: error)): \(error.localizedDescription)")
                continue
            }
        }
        logger.error("文件全部源失败：\(relPath)（共 \(fileEntry["sources"]?.array?.count ?? 0) 个源，"
            + "逐源明细见上方 WARN）")
        throw NativePackDownloadError(
            "文件 \(relPath) 全部源失败 —— " + errors.prefix(3).joined(separator: "；"))
    }

    /// os.replace 原子 rename（同目录同文件系统；目标存在则覆盖）。
    static func atomicReplace(_ src: URL, _ dst: URL) throws {
        if rename(src.path, dst.path) != 0 {
            throw NativePackDownloadError("原子替换失败: \(String(cString: strerror(errno)))")
        }
    }

    // MARK: - download_pack（L303-344）

    /// 下载并安装一个模型包（取消/失败均保留 .partial 现场）。
    /// 成功返回注册表条目；失败抛 NativePackDownloadError；取消抛 CancellationError。
    @discardableResult
    public func downloadPack(_ pack: [String: JSONValue]) async throws -> [String: JSONValue] {
        let fm = FileManager.default
        let packId = pack["pack_id"].map(WFText.pyStr) ?? ""
        let files = pack["files"]?.array ?? []
        let total = pack["size_bytes"].flatMap(PySem.toFloat).map { Int64($0) }
            ?? files.reduce(Int64(0)) { $0 + ($1.object?["size_bytes"].flatMap(PySem.toFloat).map { Int64($0) } ?? 0) }
        let t0 = Date()
        do {
            let destDir = try store.packDir(packId)
            let partDir = try store.partialDir(packId)
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: partDir, withIntermediateDirectories: true)

            let progress = Progress(packId: packId, totalBytes: total, owner: self)
            let name = WFText.truthy(pack["name"]) ? (pack["name"].map(WFText.pyStr) ?? "") : packId
            let version = WFText.truthy(pack["version"]) ? (pack["version"].map(WFText.pyStr) ?? "") : ""
            logger.info("模型包下载开始：\(name)（\(packId)，\(files.count) 个文件 / \(total) 字节）")
            emit(Self.evtStart, packId, [
                "total_bytes": .int(total),
                "file_count": .int(Int64(files.count)),
                "name": .string(name),
                "version": .string(version),
            ])
            do {
                for f in files {
                    guard case .object(let fo) = f, case .string(let rel) = fo["path"] else { continue }
                    try await fetchOneFile(fo,
                                           dest: destDir.appendingPathComponent(rel),
                                           part: partDir.appendingPathComponent(rel + ".part"),
                                           progress: progress)
                }
                // manifest.json 副本（原子写；manifest 校验已拒绝包内同名保留名）
                let manTmp = partDir.appendingPathComponent("manifest.json.tmp")
                try NativeJSONWriter.dumps(.object(pack)).write(
                    to: manTmp, atomically: false, encoding: .utf8)
                try Self.atomicReplace(manTmp, destDir.appendingPathComponent("manifest.json"))
                try store.registerPack(packId, pack: pack)
                // 空暂存目录顺手清掉；有残留（别的中断文件）则保留
                if let contents = try? fm.contentsOfDirectory(atPath: partDir.path),
                   contents.isEmpty {
                    try? fm.removeItem(at: partDir)
                }
                emit(Self.evtDone, packId, ["total_bytes": .int(total)])
                logger.info("模型包下载完成：\(packId)（\(total) 字节，"
                    + String(format: "耗时 %.1fs", Date().timeIntervalSince(t0)) + "）")
                return store.getEntry(packId) ?? [:]
            } catch is CancellationError {
                // 取消友好：.partial 原地保留，下次安装从断点续传
                emit(Self.evtCancelled, packId, [
                    "received_bytes": .int(progress.doneBytes + progress.fileReceived),
                    "total_bytes": .int(total),
                ])
                logger.info("模型包下载已取消（.partial 保留续传）：\(packId)"
                    + "（已收 \(progress.doneBytes + progress.fileReceived)/\(total) 字节）")
                throw CancellationError()
            } catch {
                emit(Self.evtError, packId, ["error": .string(Self.errorMessage(of: error))])
                logger.error("模型包下载失败：\(packId) —— "
                    + NativeModelDownloader.logSafeDetail(Self.errorMessage(of: error)))
                throw error
            }
        }
    }

    /// str(e) 等价（NativePackDownloadError/NativeModelPackError 取中文明细）。
    static func errorMessage(of error: Error) -> String {
        if let e = error as? NativePackDownloadError { return e.message }
        if let e = error as? NativeModelPackError { return e.message }
        return String(describing: error)
    }

    // MARK: - fetch_catalog（L402-458）

    /// 拉取并校验一个 catalog 源。返回 (packs, error)；成功 error 为 nil。
    public func fetchCatalog(_ url0: String) async -> (packs: [[String: JSONValue]]?, error: String?) {
        let fm = FileManager.default
        let url = url0.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.isEmpty { return (nil, "空 catalog 源地址") }
        var raw: JSONValue? = nil
        if url.hasPrefix("file://") {
            var path = Self.fileURLToPath(url)
            var isDir: ObjCBool = false
            do {
                if fm.fileExists(atPath: path.path, isDirectory: &isDir), isDir.boolValue {
                    path = path.appendingPathComponent("catalog.json")
                }
                // W7：读取走注入缝 + 超时竞速（TCC 保护目录 open() 内核态悬挂会卡死
                // 同步读取）；nil = 不存在（旧文案），超时 = NativePackDownloadError 直展。
                let data = try await Self.withReadTimeout(seconds: localCatalogReadTimeout) {
                    try await self.localCatalogReader(path)
                }
                guard let data else {
                    return (nil, "本地 catalog 不存在: \(path.path)")
                }
                guard let v = NativeJSONWriter.loads(data) else {
                    return (nil, "本地 catalog 不是合法 JSON: \(Self.jsonErrorHint(data))")
                }
                raw = v
            } catch let e as NativePackDownloadError {
                return (nil, e.message)
            } catch {
                // 注入读取器抛出其他错误的兜底（默认实现已 try? 映射 nil，走不到这里）
                return (nil, "本地 catalog 读取失败: \(error.localizedDescription)")
            }
            // 相对 sources → 绝对 file://（仅 file 型 catalog 支持相对写法）
            let base = path.deletingLastPathComponent()
            if case .object(var root) = raw, case .array(let packs)? = root["packs"] {
                var newPacks: [JSONValue] = []
                for p in packs {
                    guard case .object(var po) = p, case .array(let files)? = po["files"] else {
                        newPacks.append(p)
                        continue
                    }
                    var newFiles: [JSONValue] = []
                    for f in files {
                        guard case .object(var fo) = f, case .array(let sources)? = fo["sources"] else {
                            newFiles.append(f)
                            continue
                        }
                        fo["sources"] = .array(sources.map { s -> JSONValue in
                            guard case .string(let str) = s,
                                  !Self.absSchemes.contains(where: { str.hasPrefix($0) })
                            else { return s }
                            return .string(URL(fileURLWithPath:
                                base.appendingPathComponent(str).path).absoluteString)
                        })
                        newFiles.append(.object(fo))
                    }
                    po["files"] = .array(newFiles)
                    newPacks.append(.object(po))
                }
                root["packs"] = .array(newPacks)
                raw = .object(root)
            }
        } else {
            let host = URL(string: url)?.host ?? ""
            do {
                _ = try networkGuard.assertGuard(host)
            } catch let e as NativeNetworkGuardError {
                return (nil, e.message)
            } catch {
                return (nil, "\(host): \(error.localizedDescription)")
            }
            do {
                let (status, data) = try await transport.getData(url: url)
                if status != 200 {
                    networkGuard.reportFailure(host)
                    return (nil, "\(host): HTTP \(status)")
                }
                guard let v = NativeJSONWriter.loads(data) else {
                    networkGuard.reportSuccess(host)
                    return (nil, "\(host): catalog 不是合法 JSON: \(Self.jsonErrorHint(data))")
                }
                raw = v
                networkGuard.reportSuccess(host)
            } catch let e as NativeNetworkGuardError {
                return (nil, e.message)
            } catch {
                networkGuard.reportFailure(host)
                return (nil, "\(host): 连接失败/超时（\(type(of: error))）")
            }
        }
        let errors = NativeModelPackManifest.validateCatalog(raw)
        if !errors.isEmpty {
            return (nil, "catalog 校验失败: " + errors.prefix(3).joined(separator: "；"))
        }
        return (raw?.object?["packs"]?.array?.compactMap { $0.object } ?? [], nil)
    }

    /// json.JSONDecodeError 明细的近似（偏差③：只保留可定位信息）。
    static func jsonErrorHint(_ data: Data) -> String {
        let head = String(decoding: data.prefix(60), as: UTF8.self)
        return "文档开头附近解析失败: \(head)"
    }
}

// ════════════════════════════════════════════════════════════
// MARK: - 下载任务管理器（L347-399）
// ════════════════════════════════════════════════════════════

/// 进行中的下载任务注册表（每 pack_id 至多一个任务；进程级内存态，重启即清空——
/// .partial 仍在磁盘，重新安装即续传，无需任务态持久化）。
public final class NativeModelPackDownloadManager: @unchecked Sendable {

    private let lock = NSLock()
    private var tasks: [String: Task<Void, Never>] = [:]
    public let downloader: NativeModelPackDownloader
    /// cancel 等收尾上限（asyncio.wait_for shield timeout=10.0 等价）。
    public var cancelWaitTimeout: Double = 10.0
    /// 失败日志缝（0.7.7 W4 起默认落 AppLogger——此前默认 noop，后台任务失败零痕迹）。
    /// 明细过 logSafeDetail 脱敏闸（错误文案可能嵌带 query 的完整源 URL）。
    public var log: @Sendable (String) -> Void = {
        AppLogger.shared.error(NativeModelDownloader.logSafeDetail($0))
    }

    public init(downloader: NativeModelPackDownloader) {
        self.downloader = downloader
    }

    /// NSLock 在 async 上下文直接调用会触发 Swift 6 告警；经同步助手收敛。
    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    private func removeTask(_ packId: String) {
        withLock { tasks[packId] = nil }
    }

    public func activeIds() -> [String] {
        withLock { tasks.keys.sorted() }
    }

    public func isActive(_ packId: String) -> Bool {
        withLock { tasks[packId] != nil }
    }

    /// 起后台下载任务。重复启动抛 NativePackDownloadError（端点层转 409）。
    public func start(_ packId: String, pack: [String: JSONValue]) throws {
        try withLock {
            if tasks[packId] != nil {
                throw NativePackDownloadError("模型包 \(packId) 正在下载中")
            }
            let task = Task { [weak self] in
                defer { self?.removeTask(packId) }
                do {
                    _ = try await self?.downloader.downloadPack(pack)
                } catch is CancellationError {
                    // 取消语义（.partial 保留，事件已发）——任务正常收尾
                } catch {
                    self?.log("模型包下载失败 \(packId): \(NativeModelPackDownloader.errorMessage(of: error))")
                }
            }
            tasks[packId] = task
        }
    }

    /// 取消进行中的下载并等它收尾（.partial 保留）。无进行中任务返回 false。
    public func cancel(_ packId: String) async -> Bool {
        let task = withLock { tasks[packId] }
        guard let task else { return false }
        task.cancel()
        // asyncio.wait_for(shield(task), 10) 等价：取消信号已送达，超时仍返回 true
        let timeout = cancelWaitTimeout
        _ = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await task.value; return true }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        return true
    }
}
