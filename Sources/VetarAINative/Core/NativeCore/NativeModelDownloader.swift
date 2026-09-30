//
//  NativeModelDownloader.swift
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

//  逐语义移植 sidecar/model_packs/downloader.py（0.4.29 P1 唯一先例）：
//    · 多源 failover：按 sources 序——连接失败/超时/HTTP 非 200·206/低速
//      （滑动窗速率持续低于阈值）→ 换下一源；SHA256 不符 → 删 .part 换源重下；
//      全部源失败 → DownloadError 中文明细汇总（前 3 条）
//    · 断点续传：.part 已存在 → Range: bytes=<已有>-；206 追加 / 200 覆盖重下 /
//      416 删半截从头（只一次）；取消/失败保留 .part 现场
//    · 完整性：先字节数比对（免哈希浪费），再 SHA256 全量校验；通过才
//      os.replace 同款原子 rename 到位（同目录同文件系统）
//    · 快速路径：最终文件已在且哈希对 → 直接复用；.part 恰好完整 → 补校验+rename
//    · file:// 源：本地分块拷贝（冒烟/导入用），不过网络语义
//    · 0.7.4 W2：HTTP 消费改 URLSessionDataDelegate 分块桥（弃 AsyncBytes 逐字节
//      迭代），取消显式桥接（onCancel→task.cancel）；滚动窗速率随进度快照上屏
//    · 0.7.6 收口（业主实测三链）：停滞看门狗——末次流事件超 stallTimeout 无
//      活动即掐停连接，Range 重连续传（上限 maxStallRetries 次，进度快照 note
//      上屏「重连续传中」），耗尽才 failed（错误上屏，不静默挂起）；
//      206 续传校验 Content-Range 起点（错位按 416 同款删 .part 从头，
//      不盲拼接带病文件）
//    · ⚠️VERIFY 占位源（非 http/file 开头）跳过记明细，不拖死链路
//    · 进度节流：每 0.15s 至多一次 + 每文件起止各一次（SSE 暴雨教训同款）
//    · 0.7.7 W4：下载链失败明细接 AppLogger 落盘（业主拍板）——开始/每 10%
//      进度一跳/停滞看门狗触发与重连次数/重连耗尽/416·206 起点校验不符清退/
//      完成（字节+耗时）/失败原因全链留痕；脱敏红线：URL 只落文件名
//      （logSafeName），query/token 绝不落盘
//    · Bug7 收口（业主 2026-09-28 拍板，app-20260928.log 铁证）：瞬时网络错误
//      （-1005 connectionLost/-1004 cannotConnectToHost/-1009 notConnectedToInternet
//      及底层 POSIX ECONNRESET 类）判「源失败换下一源」之前先同源原地重试——
//      实测魔塔/CDN 首发连接 1~3s 被链路侧掐断、手动重试即满速成功；单源文件
//      「换源」= 直接判死，必须先在原地自愈。Range 断点续传基线（不重下已收
//      字节），上限 maxTransientRetries 次 + 短退避（总时长 ≤4s，真死链接不被
//      拖三倍）；耗尽上抛原错误走既有换源/判死。-1001 timedOut 与停滞掐停
//      仍走既有停滞看门狗重连链（已是同源重试），不在本链重复计。
//
//  macOS 后台口径：URLSession 默认配置进程内下载——macOS 不挂起前台转后台的
//  App 进程，切换模块/最小化均不中断（与 Python 侧车 asyncio 后台任务同语义）。
//

import Foundation
import CryptoKit

public enum NativeModelDownloadError: LocalizedError {
    case allSourcesFailed(String)
    case invalidManifest(String)
    public var errorDescription: String? {
        switch self {
        case .allSourcesFailed(let m): return m
        case .invalidManifest(let m): return "模型清单无效：\(m)"
        }
    }
}

/// 单文件清单项
public struct RequiredFileSpec: Sendable, Equatable {
    public let path: String
    public let sizeBytes: Int64
    public let sha256: String
    public let sources: [String]
}

/// 下载进度快照（UI 展示：文件/字节/速率/当前源）
public struct DownloadProgress: Sendable, Equatable {
    public var file: String = ""
    public var fileReceived: Int64 = 0
    public var fileTotal: Int64 = 0
    public var receivedBytes: Int64 = 0
    public var totalBytes: Int64 = 0
    public var bytesPerSecond: Double = 0
    public var currentSource: String = ""
    /// 停滞/重连提示（0.7.6 收口；常态为空）——数据恢复流动即清。
    public var note: String = ""
}

public actor NativeModelDownloader {

    /// 低速换源阈值：滑动窗（10s）均速持续低于 32KB/s 判慢源（业主口径「按速率切换」）
    public static var lowSpeedThreshold: Double = 32 * 1024
    public static var lowSpeedWindowSeconds: TimeInterval = 10
    /// 读超时 60s：timeoutIntervalForRequest 语义=「等下一字节的空闲上限」（数据到达
    /// 即复位，GB 级大文件照样下完——py _READ_TIMEOUT 同款）。py 的 connect=10s 无
    /// URLSession 等价物（连接阶段一并受空闲超时覆盖）——与 NativeChatRuntime 同款偏差。
    /// 维持写死（0.7.5 W13 口径）：换源敏感值——与 Python 侧 _READ_TIMEOUT 逐字对齐，
    /// 双端漂移比写死更危险；且语义为空闲上限而非总时限，大文件下载不受其限。
    public static var readTimeout: TimeInterval = 60
    /// 速率显示滚动窗（0.7.4 W2）：进度快照 bytesPerSecond 的样本窗长。
    public static var rateWindowSeconds: TimeInterval = 3.0
    /// 停滞看门狗（0.7.6 收口）：末次流事件后的无活动上限——超时掐停连接走
    /// Range 重连续传（downloadHTTP，上限 maxStallRetries 次）。读超时 60s 仍作
    /// 系统级兜底；看门狗把「卡住不动」的自愈提前到秒级，进度行经 note
    /// 上屏「重连续传中」——不静默挂起。
    public static var stallTimeout: TimeInterval = 20
    /// 停滞重连上限（每文件每源）；耗尽上抛中文明细走 failed（错误上屏）。
    public static var maxStallRetries = 3
    /// 瞬时网络错误同源原地重试上限（Bug7 收口，每文件每源）：-1005/-1004/-1009
    /// 及 POSIX ECONNRESET 类。判「源失败换下一源」之前先原地自愈（Range 续传）。
    public static var maxTransientRetries = 2
    /// 同源原地重试退避表（秒）：第 n 次重试前睡 backoff[n-1]（超出表长取末档）。
    /// 退避总时长上限 = 表和（默认 1+3=4s）——真死链接不被拖慢三倍时长。
    /// 测试可覆盖提速（同 stallTimeout 先例，defer 还原）。
    public static var transientBackoffSeconds: [TimeInterval] = [1, 3]

    private let session: URLSession
    /// 进度回调（节流后）；actor 隔离外用 @Sendable 闭包
    private let onProgress: @Sendable (DownloadProgress) -> Void
    /// 失败明细落盘（0.7.7 W4）：默认全局单例；测试注入独立 logDirectory 实例。
    private let logger: AppLogger

    public init(session: URLSession? = nil,
                onProgress: @escaping @Sendable (DownloadProgress) -> Void = { _ in },
                logger: AppLogger = .shared) {
        if let session {
            self.session = session   // 测试注入（URLProtocol mock 等）
        } else {
            // ⚠️ 不能改 .shared 的 configuration（副本语义，改了不生效）——自建会话
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = Self.readTimeout
            cfg.timeoutIntervalForResource = 0   // 资源总时长不设限
            cfg.waitsForConnectivity = false
            self.session = URLSession(configuration: cfg)
        }
        self.onProgress = onProgress
        self.logger = logger
    }

    // MARK: - 日志脱敏（0.7.7 W4 红线）

    /// 源地址脱敏：只取末段文件名落日志——query/token 绝不落盘；模型名/文件名可落。
    /// 非 URL 形态（⚠️VERIFY 占位源等）URL(string:) 解析为相对 URL 时同样只取末段；
    /// 实在取不到就截断到 60 字符（不夹带 query 分隔符之后的部分）。
    public static func logSafeName(_ source: String) -> String {
        if let u = URL(string: source), !u.lastPathComponent.isEmpty {
            return u.lastPathComponent
        }
        let noQuery = source.split(separator: "?", maxSplits: 1).first.map(String.init) ?? source
        return String(noQuery.prefix(60))
    }

    /// 错误明细脱敏（0.7.7 W4 日志边界）：错误文案里可能嵌着带 query 的完整 URL
    /// （如全部源失败汇总），落盘前把 URL 的 query 段剥掉——只剥 URL（? 前有 ://），
    /// query 到下一个空白或全角/半角分隔符为止，其后的明细（如「：HTTP 404」）保留。
    static func logSafeDetail(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var rest = s[...]
        let delims: Set<Character> = [" ", "：", "，", ",", "；", ";", ")", "）", "]", "］"]
        while let q = rest.firstIndex(of: "?") {
            let head = rest[..<q]
            guard head.contains("://") else { out += rest; return out }
            out += head
            let after = rest[rest.index(after: q)...]
            if let end = after.firstIndex(where: { delims.contains($0) }) {
                rest = after[end...]
            } else {
                rest = after[after.endIndex...]   // query 一直到串尾
            }
        }
        out += rest
        return out
    }

    // MARK: - 主入口：按清单下载一组文件到 destDir（.part 暂存于 partDir）

    /// 逐文件多源下载 + 校验 + 原子落位。取消抛 CancellationError（.part 保留续传）。
    public func downloadFiles(_ files: [RequiredFileSpec],
                              destDir: URL, partDir: URL) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: partDir, withIntermediateDirectories: true)
        let total = files.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let t0 = Date()
        logger.info("下载开始：共 \(files.count) 个文件 / \(total) 字节（\(files.map { $0.path }.joined(separator: ", "))）")
        var progress = ProgressTracker(total: total, emit: onProgress)
        // 每 10% 进度一跳（W4；按文件计，不每条 chunk 都记）
        progress.onDecile = { [logger] file, decile in
            logger.info("下载进度 \(decile * 10)%：\(file)")
        }
        do {
            for f in files {
                try Task.checkCancellation()
                try await fetchOne(f,
                                   dest: destDir.appendingPathComponent(f.path),
                                   part: partDir.appendingPathComponent(f.path + ".part"),
                                   progress: &progress)
            }
        } catch {
            let elapsed = String(format: "%.1f", Date().timeIntervalSince(t0))
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                logger.info("下载已取消（.part 保留续传）：\(files.count) 个文件批次，耗时 \(elapsed)s")
            } else {
                logger.error("下载批次失败：\(Self.logSafeDetail(error.localizedDescription))"
                    + "（耗时 \(elapsed)s）")
            }
            throw error
        }
        logger.info("下载批次完成：\(files.count) 个文件 / \(total) 字节，"
            + String(format: "耗时 %.1fs", Date().timeIntervalSince(t0)))
    }

    // MARK: - 单文件：多源回退 + 校验 + rename

    private func fetchOne(_ spec: RequiredFileSpec, dest: URL, part: URL,
                          progress: inout ProgressTracker) async throws {
        let fm = FileManager.default
        let baseline = Self.fileSize(onDisk: part)
        let t0 = Date()
        progress.startFile(spec.path, total: spec.sizeBytes, baseline: baseline)

        // 快速路径①：最终文件已在且哈希正确（上次中断在 rename 之后）
        if fm.fileExists(atPath: dest.path),
           (try? await sha256File(dest)) == spec.sha256 {
            progress.finishFile()
            logger.info("文件已在且哈希正确，免下载：\(spec.path)")
            return
        }
        // 快速路径②：.part 恰好完整（中断在 rename 之前）→ 补校验+rename
        if fm.fileExists(atPath: part.path) {
            let partSize = Self.fileSize(onDisk: part)
            if partSize == spec.sizeBytes {
                if (try? await sha256File(part)) == spec.sha256 {
                    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try atomicReplace(part, to: dest)
                    progress.fileReceived = spec.sizeBytes
                    progress.finishFile()
                    logger.info("续传现场恰好完整，补校验落位：\(spec.path)")
                    return
                }
                try? fm.removeItem(at: part)   // 尺寸对哈希错：内容不可信
                logger.warn("续传现场哈希不符，删 .part 重下：\(spec.path)")
            } else if partSize > spec.sizeBytes {
                try? fm.removeItem(at: part)   // 比声明还长（远端变了）→ Range 必 416，直接重下
                logger.warn("续传现场比声明还长（\(partSize) > \(spec.sizeBytes)），删 .part 重下：\(spec.path)")
            }
        }

        logger.info("文件下载开始：\(spec.path)（\(spec.sizeBytes) 字节"
            + (baseline > 0 ? "，续传基线 \(baseline) 字节" : "") + "）")
        var errors: [String] = []
        for src in spec.sources {
            try Task.checkCancellation()
            let srcTag = Self.logSafeName(src)   // 脱敏红线：日志只落文件名，不落 query/token
            guard src.hasPrefix("http://") || src.hasPrefix("https://") || src.hasPrefix("file://") else {
                errors.append("\(src)：占位源未配置（⚠️VERIFY 待业主提供真实地址）")
                logger.warn("占位源跳过：\(srcTag)")
                continue
            }
            do {
                if src.hasPrefix("file://") {
                    try await copyLocal(src, to: part, progress: &progress)
                } else {
                    try await downloadHTTP(src, to: part, expectedSize: spec.sizeBytes,
                                           progress: &progress)
                }
                let got = try await sha256File(part)
                if got != spec.sha256 {
                    // 哈希不符 = 源内容不可信（不是网络故障）——删了换源
                    errors.append("\(src)：SHA256 不符（\(got.prefix(12))… ≠ \(spec.sha256.prefix(12))…）")
                    logger.warn("SHA256 不符，删 .part 换源：\(spec.path) @ \(srcTag)"
                        + "（\(got.prefix(12))… ≠ \(spec.sha256.prefix(12))…）")
                    try? fm.removeItem(at: part)
                    progress.fileReceived = 0
                    continue
                }
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try atomicReplace(part, to: dest)
                progress.fileReceived = spec.sizeBytes
                progress.finishFile()
                logger.info("文件下载完成：\(spec.path)（\(spec.sizeBytes) 字节，"
                    + String(format: "耗时 %.1fs", Date().timeIntervalSince(t0)) + "）")
                return
            } catch is CancellationError {
                throw CancellationError()   // 取消语义不得被源回退吞掉
            } catch let e as URLError where e.code == .cancelled {
                // URLSession 任务被 Swift 取消协作掐断时抛 URLError.cancelled 而非
                // CancellationError——归一化，否则单源清单会把取消误判成 failed
                throw CancellationError()
            } catch {
                errors.append("\(src)：\(error.localizedDescription)")
                logger.warn("源失败换下一源：\(spec.path) @ \(srcTag)"
                    + " —— \(Self.logSafeDetail(error.localizedDescription))")
                continue
            }
        }
        logger.error("文件全部源失败：\(spec.path)（共 \(spec.sources.count) 个源，"
            + "逐源明细见上方 WARN）")
        throw NativeModelDownloadError.allSourcesFailed(
            "文件 \(spec.path) 全部源失败 —— " + errors.prefix(3).joined(separator: "；"))
    }

    // MARK: - HTTP(S)：Range 三态 + 低速换源（W2 分块桥）

    /// 流事件：响应头先到（状态判定），随后数据分块。
    private enum ChunkEvent {
        case response(URLResponse)
        case data(Data)
    }

    /// URLSessionDataDelegate → AsyncThrowingStream 分块桥（0.7.4 W2）。
    /// 旧实现 bytes(for:) 的 AsyncBytes 逐字节吐（Element=UInt8）——per-byte 迭代
    /// 开销在 GB 级文件上真实存在；桥按系统回调天然分块，且 AsyncStream 自带缓冲
    /// （迭代器挂上前的数据不丢）。桥强持 session 防提前释放；完成（成/败）时
    /// finish + finishTasksAndInvalidate 断「桥 ↔ 会话（delegate 强持）」引用环。
    private final class ChunkedBridge: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private var continuation: AsyncThrowingStream<ChunkEvent, Error>.Continuation?
        private var session: URLSession?
        private var task: URLSessionDataTask?

        /// 开流：配置副本继承注入会话的 protocolClasses/超时设置
        /// （URLProtocol mock 挂 configuration——测试路径不受影响）。
        func open(_ req: URLRequest, base baseSession: URLSession)
            -> AsyncThrowingStream<ChunkEvent, Error> {
            AsyncThrowingStream { cont in
                self.continuation = cont
                let s = URLSession(configuration: baseSession.configuration,
                                   delegate: self, delegateQueue: nil)
                self.session = s
                let t = s.dataTask(with: req)
                self.task = t
                // ⛔ 取消桥接的实际机制（0.7.4 收口实证，勿改回 withTaskCancellationHandler）：
                // 本运行时里【消费 Task 被取消】会令挂起的 next() 终止流并触发
                // onTermination（栈：swift_task_cancelImpl → Scs Storage.cancel）——
                // 此处反打 task.cancel() 掐停 URLSession 任务（停写盘、触发
                // didCompleteWithError 收尾断引用环）；挂起的 next() 以 nil 恢复，
                // 由消费侧 checkCancellation 归一化为 CancellationError。
                cont.onTermination = { [weak self] _ in self?.cancel() }
                t.resume()
            }
        }

        /// 取消：掐断底层任务（统一由 didCompleteWithError 收尾 finish/invalidate）。
        func cancel() { task?.cancel() }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            continuation?.yield(.response(response))
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive data: Data) {
            continuation?.yield(.data(data))
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didCompleteWithError error: Error?) {
            if let error { continuation?.finish(throwing: error) }
            else { continuation?.finish() }
            continuation = nil
            session.finishTasksAndInvalidate()
            self.session = nil
            self.task = nil
        }
    }

    private enum HTTPAttempt { case retry416, done }

    /// 瞬时网络错误判定（Bug7）：-1005 connectionLost / -1004 cannotConnectToHost /
    /// -1009 notConnectedToInternet + 底层 POSIX ECONNRESET·ECONNABORTED·ETIMEDOUT·EPIPE
    /// 类（URLSession 常把 RST 映成 -1005，部分链路以 NSUnderlyingErrorKey 内
    /// POSIXError 形态回传——兜底识别）。判定是防线不是门禁：只决定「判死前先
    /// 同源原地重试」，重试耗尽仍败照常上抛走换源/判死，不误赦真死链接。
    /// -1001 timedOut 不在此列——它走既有停滞看门狗重连链（downloadHTTP 前序
    /// catch 先行捕获，上限 maxStallRetries 次），不重复计。
    static func isTransientNetworkError(_ e: URLError) -> Bool {
        switch e.code {
        case .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet:
            return true
        default: break
        }
        if let u = e.userInfo[NSUnderlyingErrorKey] as? NSError,
           u.domain == NSPOSIXErrorDomain {
            return [ECONNRESET, ECONNABORTED, ETIMEDOUT, EPIPE].map(Int.init).contains(u.code)
        }
        return false
    }

    private func downloadHTTP(_ url: String, to part: URL, expectedSize: Int64,
                              progress: inout ProgressTracker) async throws {
        var retried416 = false
        var stallRetries = 0
        var transientRetries = 0
        while true {
            try Task.checkCancellation()
            // ⛔ 勿用 URL.resourceValues：同 URL 复读拿缓存旧值（416 删完仍读 300
            // 实证）——attributesOfItem 无缓存现读
            let existing = Self.fileSize(onDisk: part)
            var req = URLRequest(url: URL(string: url)!)
            if existing > 0 { req.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range") }
            progress.currentSource = URL(string: url)?.host ?? url
            do {
                switch try await httpAttempt(req, part: part, existing: existing,
                                             retried416: retried416, expectedSize: expectedSize,
                                             progress: &progress) {
                case .retry416:
                    try? FileManager.default.removeItem(at: part)
                    retried416 = true
                    logger.warn("续传起点不符（416/Content-Range 错位），删 .part 从头重下："
                        + "\(part.lastPathComponent)（原断点 \(existing) 字节）")
                    continue       // 416/续传错位删半截从头（只一次）
                case .done:
                    return
                }
            } catch let e as URLError where (e.code == .cancelled || e.code == .timedOut)
                        && !Task.isCancelled {
                // 停滞看门狗掐停（cancelled）/ 60s 空闲兜底（timedOut）——非用户取消
                // （Task.isCancelled 排除；用户取消照旧上抛给 fetchOne 的
                // URLError.cancelled 闸归一化为 CancellationError）→ Range 重连续传，
                // 上限 maxStallRetries 次，耗尽上抛中文明细（错误上屏，不静默挂起）。
                stallRetries += 1
                guard stallRetries <= Self.maxStallRetries else {
                    logger.error("停滞重连耗尽（\(Self.maxStallRetries) 次）：\(part.lastPathComponent)")
                    throw NativeModelDownloadError.allSourcesFailed(
                        "连接反复停滞（重连续传 \(Self.maxStallRetries) 次未果）")
                }
                logger.warn("停滞看门狗触发：\(part.lastPathComponent)，Range 重连续传"
                    + "（第 \(stallRetries)/\(Self.maxStallRetries) 次，已收 \(existing) 字节）")
                progress.setNote("连接停滞，重连续传中（第 \(stallRetries) 次）…")
                continue
            } catch let e as URLError where !Task.isCancelled && Self.isTransientNetworkError(e) {
                // Bug7 收口（业主 2026-09-28 拍板）：瞬时网络错误判「源失败换下一源」
                // 之前先同源原地重试——实测魔塔/CDN 首发连接 1~3s 被链路侧掐断
                // （-1005，app-20260928.log L1776），手动重试即满速成功；单源文件
                // 「换源」= 直接判死，必须先在原地自愈。Range 断点续传基线由循环顶
                // existing 现读盘上 .part（重试不重下已收字节）；上限
                // maxTransientRetries 次 + 短退避（transientBackoffSeconds 表和
                // ≤4s——真死链接不被拖慢三倍时长）；耗尽上抛原错误，fetchOne 走既有
                // 换源/判死。用户取消（Task.isCancelled）不进本分支；退避睡
                // Task.sleep 取消即抛 CancellationError——取消语义分毫不改。
                transientRetries += 1
                guard transientRetries <= Self.maxTransientRetries else { throw e }
                let backoff = Self.transientBackoffSeconds[
                    min(transientRetries - 1, Self.transientBackoffSeconds.count - 1)]
                let received = Self.fileSize(onDisk: part)   // 现读：含本次尝试已收字节
                logger.warn("瞬时网络错误，同源原地重试：\(part.lastPathComponent)"
                    + "（第 \(transientRetries)/\(Self.maxTransientRetries) 次，"
                    + String(format: "%.1f", backoff) + "s 后续传，已收 \(received) 字节）"
                    + " —— \(Self.logSafeDetail(e.localizedDescription))")
                progress.setNote("连接中断，自动重试中（第 \(transientRetries) 次）…")
                try await Task.sleep(nanoseconds: UInt64(max(0, backoff) * 1_000_000_000))
                continue
            }
        }
    }

    /// 看门狗活动戳（锁保护；流每吐一事件即刷新）。
    private final class StallActivity: @unchecked Sendable {
        private let lock = NSLock()
        private var last = Date()
        func touch() { lock.lock(); last = Date(); lock.unlock() }
        func stamp() -> Date { lock.lock(); defer { lock.unlock() }; return last }
    }

    /// 解析 Content-Range「bytes <start>-<end>/<total>」的 start
    /// （形态不符 → nil，调用方按现状信任——校验是防线不是门禁）。
    private static func contentRangeStart(_ v: String) -> Int64? {
        guard v.hasPrefix("bytes ") else { return nil }
        let rest = v.dropFirst(6)
        guard let dash = rest.firstIndex(of: "-") else { return nil }
        return Int64(rest[rest.startIndex..<dash])
    }

    /// 单次 HTTP 尝试（分块桥消费）。defer 保每次尝试都取消桥——416 重试不泄漏会话。
    private func httpAttempt(_ req: URLRequest, part: URL, existing: Int64,
                             retried416: Bool, expectedSize: Int64,
                             progress: inout ProgressTracker) async throws -> HTTPAttempt {
        let bridge = ChunkedBridge()
        defer { bridge.cancel() }
        let stream = bridge.open(req, base: session)
        // 保活到本函数退出：防优化期提前释放 stream 值触发 onTermination 误取消
        defer { withExtendedLifetime(stream) {} }
        // 停滞看门狗（0.7.6 实测「首次下载卡住不动」收口）：末次流事件超
        // stallTimeout 无新事件即掐停底层连接——URLError.cancelled 回流，由
        // downloadHTTP 凭 Task.isCancelled 区分用户取消（照旧归一化）与停滞
        // （Range 重连续传）。只掐连接不动消费 Task——用户取消的 Swift 取消
        // 协作语义（nil 恢复 + checkCancellation 归一化）分毫不改。
        let activity = StallActivity()
        let stallWatchdog = Task.detached(priority: .utility) { [bridge, activity] in
            let step = max(0.1, min(2.0, Self.stallTimeout / 4))
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
                if Task.isCancelled { break }
                if Date().timeIntervalSince(activity.stamp()) >= Self.stallTimeout {
                    bridge.cancel()
                    break
                }
            }
        }
        defer { stallWatchdog.cancel() }
        var iter = stream.makeAsyncIterator()
        // 首事件必须是响应头（连接失败由 didCompleteWithError 经迭代器直接抛出）。
        // 任务取消会令挂起的 next() 以 nil 恢复（本运行时实证）——先归一化取消。
        guard case .response(let response)? = try await iter.next() else {
            if Task.isCancelled { throw CancellationError() }
            throw NativeModelDownloadError.allSourcesFailed("连接失败（无响应头）")
        }
        activity.touch()
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 416, existing > 0, !retried416 { return .retry416 }
        guard status == 200 || status == 206 else {
            throw NativeModelDownloadError.allSourcesFailed("HTTP \(status)")
        }
        let append = (status == 206)
        // 206 续传必验 Content-Range 起点 == 本地 .part 长度——CDN 边缘错位响应
        // （起点不符仍 206）盲追加必烂尾（SHA/字节不符，0.7.6 实测「恢复后安装
        // 失败」疑似点）。错位按 416 同款清退：删 .part 从头（只一次，不带病拼接）；
        // 头缺失/形态不符按现状信任（校验是防线不是门禁）。
        if append, !retried416,
           let cr = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"),
           let start = Self.contentRangeStart(cr), start != existing {
            return .retry416
        }
        if !append { progress.fileReceived = 0 }   // 覆盖重下基线归零（防进度超 100%）

        try FileManager.default.createDirectory(at: part.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if !append {
            // createFile 对已存在文件不清空（实测截断不发生）——先删再建
            try? FileManager.default.removeItem(at: part)
            FileManager.default.createFile(atPath: part.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: part)
        if append { try handle.seekToEnd() }
        defer { try? handle.close() }

        var windowBytes: Int64 = 0
        var windowStart = Date()
        var samples: [(Date, Int64)] = []
        // 低速窗语义同旧（tumbling 10s 窗，窗内均速 <32KB/s 判死换源，文案逐字）。
        // 取消语义（0.7.4 收口实证）：消费 Task 被取消 → 运行时终止流、挂起的
        // next() 以 nil 恢复（循环照常退出）→ 循环后 checkCancellation 归一化为
        // CancellationError；onTermination 同步掐停 URLSession 任务，不泄漏。
        // 块边界的 checkCancellation 兜住「取消落在两次 next() 之间」的情形。
        while let event = try await iter.next() {
            activity.touch()
            guard case .data(let chunk) = event, !chunk.isEmpty else { continue }
            try Task.checkCancellation()
            try handle.write(contentsOf: chunk)
            progress.advance(Int64(chunk.count))
            windowBytes += Int64(chunk.count)
            // 滚动速率窗（W2）：3s 样本剔旧求均速，随进度快照上屏
            let now = Date()
            samples.append((now, Int64(chunk.count)))
            progress.bytesPerSecond = Self.displayRate(samples: &samples, now: now)
            let winElapsed = now.timeIntervalSince(windowStart)
            if winElapsed >= Self.lowSpeedWindowSeconds {
                let rate = Double(windowBytes) / winElapsed
                if rate < Self.lowSpeedThreshold {
                    throw NativeModelDownloadError.allSourcesFailed(
                        String(format: "速率过低（%.0f KB/s 持续 %.0fs），换源",
                               rate / 1024, winElapsed))
                }
                windowBytes = 0; windowStart = now
            }
        }
        // nil 收口的取消归一化（循环因取消终止而退出时必抛；正常完成则 Task 未取消）
        try Task.checkCancellation()
        // 完整性预检：字节不符不浪费哈希
        let got = Self.fileSize(onDisk: part)
        if expectedSize > 0 && got != expectedSize {
            throw NativeModelDownloadError.allSourcesFailed(
                "字节数不符：\(part.lastPathComponent) 收到 \(got)，应为 \(expectedSize)")
        }
        return .done
    }

    // MARK: - file:// 本地源

    private func copyLocal(_ url: String, to part: URL,
                           progress: inout ProgressTracker) async throws {
        guard let src = URL(string: url) else {
            throw NativeModelDownloadError.allSourcesFailed("非法 file:// 源：\(url)")
        }
        guard FileManager.default.fileExists(atPath: src.path) else {
            throw NativeModelDownloadError.allSourcesFailed("本地源不存在：\(src.path)")
        }
        try FileManager.default.createDirectory(at: part.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: part.path, contents: nil)
        let handle = try FileHandle(forWritingTo: part)
        defer { try? handle.close() }
        let reader = try FileHandle(forReadingFrom: src)
        defer { try? reader.close() }
        while true {
            try Task.checkCancellation()
            let chunk = try reader.read(upToCount: 256 * 1024)
            guard let chunk, !chunk.isEmpty else { break }
            try handle.write(contentsOf: chunk)
            progress.advance(Int64(chunk.count))
        }
    }

    // MARK: - 文件大小现读（无缓存）

    /// 滚动窗均速（W2）：剔除窗龄超 rateWindowSeconds 的样本，sum/span
    /// （span 下限 0.5s 防首块瞬时尖刺）；空窗 → 0。
    static func displayRate(samples: inout [(Date, Int64)], now: Date) -> Double {
        samples.removeAll { now.timeIntervalSince($0.0) > Self.rateWindowSeconds }
        guard let oldest = samples.first else { return 0 }
        let span = max(now.timeIntervalSince(oldest.0), 0.5)
        let sum = samples.reduce(Int64(0)) { $0 + $1.1 }
        return Double(sum) / span
    }

    /// 盘上文件大小（不存在/不可读 → 0）。勿换成 URL.resourceValues(forKeys:)——
    /// 它按 URL 实例缓存资源值，同 URL 删后/写后复读拿旧值（416 删重下分支实测踩雷）。
    private static func fileSize(onDisk url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }

    // MARK: - 原子落位（os.replace 等价）

    /// rename(2) 原子覆盖到位（part/dest 同卷——同在数据根下，无跨卷面）。
    /// 不走 FileManager.replaceItem：现行 SDK 导入签名参差，rename 语义最稳。
    private func atomicReplace(_ src: URL, to dst: URL) throws {
        if rename(src.path, dst.path) != 0 {
            throw NativeModelDownloadError.allSourcesFailed(
                "原子落位失败（errno=\(errno)）：\(dst.lastPathComponent)")
        }
    }

    // MARK: - SHA256（流式，大文件不爆内存）

    public static func sha256FileSync(_ url: URL) throws -> String {
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        var h = SHA256()
        while true {
            let chunk = try reader.read(upToCount: 1024 * 1024)
            guard let chunk, !chunk.isEmpty else { break }
            h.update(data: chunk)
        }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func sha256File(_ url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            try Self.sha256FileSync(url)
        }.value
    }

    // MARK: - 进度聚合（节流 0.15s + 文件起止）

    private struct ProgressTracker {
        var total: Int64
        let emit: @Sendable (DownloadProgress) -> Void
        /// 每 10% 进度一跳（0.7.7 W4 日志里程碑；参数=文件路径、十分位数）
        var onDecile: (@Sendable (String, Int) -> Void)? = nil
        var snapshot = DownloadProgress()
        var doneBytes: Int64 = 0
        private var lastEmit = Date.distantPast
        private var lastDecile = -1
        var fileReceived: Int64 {
            get { snapshot.fileReceived }
            set { snapshot.fileReceived = newValue }
        }
        var currentSource: String {
            get { snapshot.currentSource }
            set { snapshot.currentSource = newValue }
        }
        /// 滚动速率（W2）：写路径透传到快照，随 advance 节流 0.15s 上屏。
        var bytesPerSecond: Double {
            get { snapshot.bytesPerSecond }
            set { snapshot.bytesPerSecond = newValue }
        }

        init(total: Int64, emit: @escaping @Sendable (DownloadProgress) -> Void) {
            snapshot.totalBytes = total
            self.total = total
            self.emit = emit
        }

        mutating func startFile(_ path: String, total: Int64, baseline: Int64) {
            snapshot.file = path
            snapshot.fileTotal = total
            snapshot.fileReceived = baseline
            snapshot.bytesPerSecond = 0   // 新文件速率归零（不带上一文件残值）
            snapshot.note = ""            // 新文件提示归零（同上）
            lastDecile = baseline > 0 && total > 0
                ? Int(baseline * 10 / total) : -1   // 续传基线以下的跳数不补记
            emitNow()
        }
        mutating func advance(_ n: Int64) {
            snapshot.fileReceived += n
            snapshot.receivedBytes = doneBytes + snapshot.fileReceived
            snapshot.note = ""   // 数据恢复流动即清停滞/重连提示
            if snapshot.fileTotal > 0 {
                let decile = min(10, Int(snapshot.fileReceived * 10 / snapshot.fileTotal))
                if decile > lastDecile, decile > 0 {
                    lastDecile = decile
                    onDecile?(snapshot.file, decile)
                }
            }
            let now = Date()
            if now.timeIntervalSince(lastEmit) >= 0.15 { emitNow() }
        }
        /// 停滞/重连提示（0.7.6 收口）：即时上屏（不等 0.15s 节流）；
        /// 数据恢复流动时由 advance 清掉。
        mutating func setNote(_ s: String) {
            snapshot.note = s
            emitNow()
        }
        mutating func finishFile() {
            doneBytes += snapshot.fileTotal
            snapshot.receivedBytes = doneBytes
            emitNow()
        }
        private mutating func emitNow() {
            lastEmit = Date()
            emit(snapshot)
        }
    }
}
