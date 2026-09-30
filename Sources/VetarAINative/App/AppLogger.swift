//
//  AppLogger.swift
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

//  简单日志落盘：~/Library/Application Support/VetarAI/logs/app-yyyyMMdd.log
//  · 串行队列写文件，线程安全；同时 print 到 stdout（开发期可见）
//  · 按天一个文件，启动时清理 7 天前的旧日志
//  · S3-N1（2026-09-30）：xctest 宿主默认目录改向 tmp/vetarai-xctest-logs——
//    测试进程不写真实用户日志（判定见 defaultLogDirectory）
//  · 全局单例 AppLogger.shared；面板统一经它落日志，不要各自 print
//  · 改名留痕（0.7.5 W13）：旧目录 Application Support/VetarAINative/logs 为
//    产品改名前残留——不删不迁（旧日志原样保留可查），自本版起新目录接管写入
//

import Foundation
#if canImport(AppKit)
import AppKit
#endif

public final class AppLogger: @unchecked Sendable {

    public enum Level: String {
        case debug = "DEBUG"
        case info = "INFO"
        case warn = "WARN"
        case error = "ERROR"
    }

    public static let shared = AppLogger()

    /// 日志目录（生产 = Application Support/VetarAI/logs；xctest 宿主默认改向
    /// tmp/vetarai-xctest-logs，S3-N1 2026-09-30）。
    /// 改名留痕（0.7.5 W13）：旧目录 VetarAINative/logs 不删不迁——旧日志原样保留，
    /// 新目录自本版接管；两目录并存期「打开日志目录」只指新目录（当日活动日志在此）。
    public let logDirectory: URL
    private let queue = DispatchQueue(label: "ai.vetar.native.logger")
    private var fileHandle: FileHandle?
    private var currentDay: String = ""

    public init(logDirectory: URL? = nil) {
        let dir = logDirectory ?? Self.defaultLogDirectory()
        self.logDirectory = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        pruneOldFiles(keepDays: 7)
    }

    /// 默认日志目录解析（显式传 logDirectory 的注入缝不受本判定影响）。
    /// S3-N1（2026-09-30）真因：原实现无宿主判定恒写 ~/Library/Application Support/
    /// VetarAI/logs——xctest 进程（全量单测/CI）也落真实用户日志目录，噪音污染
    /// 生产日志与「一键上传日志」收集。现 XCTest 宿主改向临时目录（不静默——
    /// 测试期日志仍可查，只是不再写用户域）；与 LicenseStore.defaultBaseDir 的
    /// VETARAI_LICENSE_SMOKE_DIR 环境变量隔离先例同风格。
    /// 判定三路冗余（任一为真即测试宿主）：① XCTestConfigurationFilePath /
    /// XCTestBundlePath 环境变量（xcodebuild 注入宿主场景）；② 进程路径即
    /// xctest runner（`swift test` 直跑形态——实测该形态两枚环境变量都不在，
    /// 单靠 ① 会漏判）；③ XCTest 框架已载入进程（测试 bundle 注入无环境变量
    /// 场景的兜底）。
    public static func defaultLogDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if isXCTestHost(environment: environment,
                        arguments: ProcessInfo.processInfo.arguments)
            || NSClassFromString("XCTestCase") != nil {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("vetarai-xctest-logs", isDirectory: true)
        }
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VetarAI/logs", isDirectory: true)
    }

    /// xctest 宿主判定（纯函数，环境变量与进程参数注入以便单测）：
    /// 两枚 XCTest 环境变量任一为真，或进程路径末段即 xctest runner。
    static func isXCTestHost(environment: [String: String], arguments: [String]) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || arguments.first.map { URL(fileURLWithPath: $0).lastPathComponent } == "xctest"
    }

    /// 当前日志文件路径（诊断/「打开日志目录」用）。
    public var currentLogFile: URL {
        logDirectory.appendingPathComponent("app-\(Self.dayStamp()).log")
    }

    public func log(_ level: Level, _ message: String) {
        let line = "\(Self.timestamp()) [\(level.rawValue)] \(message)\n"
        #if DEBUG
        print(line, terminator: "")
        #endif
        queue.async { [weak self] in
            guard let self else { return }
            self.rotateIfNeeded()
            if let data = line.data(using: .utf8) {
                self.fileHandle?.write(data)
            }
        }
    }

    /// 便捷方法
    public func debug(_ message: String) { log(.debug, message) }   // 0.7.7：诊断级（预热等静默链路）
    public func info(_ message: String) { log(.info, message) }
    public func warn(_ message: String) { log(.warn, message) }
    public func error(_ message: String) { log(.error, message) }

    /// 在 Finder 中打开日志目录。
    public func openLogDirectory() {
        #if canImport(AppKit)
        NSWorkspace.shared.open(logDirectory)
        #endif
    }

    // MARK: - 私有

    private func rotateIfNeeded() {
        let day = Self.dayStamp()
        guard day != currentDay else { return }
        try? fileHandle?.close()
        let url = currentLogFile
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: url)
        fileHandle?.seekToEndOfFile()
        currentDay = day
    }

    private func pruneOldFiles(keepDays: Int) {
        let cutoff = Date().addingTimeInterval(-TimeInterval(keepDays) * 86400)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: logDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for file in files where file.lastPathComponent.hasPrefix("app-") && file.pathExtension == "log" {
            let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let mtime, mtime < cutoff { try? FileManager.default.removeItem(at: file) }
        }
    }

    private static func dayStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        return f.string(from: Date())
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}
