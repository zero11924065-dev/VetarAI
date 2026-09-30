//
//  NativeAsrEndpoints.swift
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

//  逐行为移植（⛔ 只读行为规格源：subagent/sidecar/app.py L2917-3027）：
//    · GET /api/asr/status（L2917-2946）：{available, state, pack_id, message}
//      三态 ready/disabled/none；判定与转写端点共用同一事实源
//      （asr_driver.resolve_asr_pack）；容错契约：无注册表/损坏/任何意外一律
//      200 返回，永不 5xx（前端据此渲染引导）
//    · POST /api/asr/transcribe（L2960-3027）：入参 {path, pack_id?, language,
//      project_id?, session_id?} → {text, duration_s, model_pack_id, saved_path,
//      save_error}；400 校验链七步逐字（空 path/非绝对/不存在/格式/读 stat/
//      500MB 上限/非法 pack_id）；C7 落盘归属（pid+sid 齐全才复制原件进会话
//      附件目录，落盘失败降级 save_error 不谎称已保存）；错误映射
//      PackUnavailable→409 / AudioDecode→422 / ValueError→400
//    · _ASR_MAX_BYTES（L2914）= 500MB
//
//  微差（汇报清单同步）：
//    ① save_error 文案同 NativeAttachmentEndpoints 微差②——Python
//       f"{type(e).__name__}: {e}" 的 errno 串无法逐字复刻，按
//       "OSError: <localizedDescription>" 形态对齐（W1b 既定口径沿用）。
//    ② Python 端点把 transcribe 放 run_in_executor（CPU 密集不堵事件循环）——
//       原生侧 transcribe 本体同步，端点层 Task.detached 等价承载。
//

import Foundation

public final class NativeAsrEndpoints: @unchecked Sendable {

    /// AUDIO_EXTS（attachments/parser.py L54-55 逐字；sorted 序即错误文案序）。
    public static let audioExts: Set<String> = [".wav", ".mp3", ".m4a", ".aac", ".aiff",
                                                ".aif", ".caf", ".flac", ".ogg", ".opus", ".webm"]
    /// _ASR_MAX_BYTES（app.py L2914）。
    public static let maxBytes = 500 * 1024 * 1024

    public let store: NativeModelPackStore
    public let driver: NativeAsrDriver
    /// projects_root 缝（save_attachment_from_path 落盘根；kernel 注入 config 解析链）。
    public var projectsRootProvider: @Sendable () -> URL
    public var log: @Sendable (String) -> Void = { _ in }

    public init(store: NativeModelPackStore, driver: NativeAsrDriver,
                projectsRootProvider: @escaping @Sendable () -> URL) {
        self.store = store
        self.driver = driver
        self.projectsRootProvider = projectsRootProvider
    }

    private func httpError(_ status: Int, _ detail: String) -> SidecarError {
        .httpError(status: status, detail: detail)
    }

    // MARK: - GET /api/asr/status（L2917-2946；永不 5xx）

    public func status() -> AsrStatusInfo {
        do {
            let pid = try driver.resolveAsrPack()
            return AsrStatusInfo(available: true, state: "ready", pack_id: pid, message: nil)
        } catch let e as NativeAsrPackUnavailableError {
            // 注册表读在原生侧不抛（损坏即空，Python try/except 同款效果）
            let hasAsr = store.readRegistry().values.contains { $0["task"]?.string == "asr" }
            return AsrStatusInfo(available: false, state: hasAsr ? "disabled" : "none",
                                 pack_id: nil, message: e.message)
        } catch {
            // 防御兜底（L2943-2946）：任何意外也不得 5xx，如实报 none + 原因
            return AsrStatusInfo(available: false, state: "none", pack_id: nil,
                                 message: "ASR 状态检测失败: \(error)")
        }
    }

    // MARK: - POST /api/asr/transcribe（L2960-3027）

    public func transcribe(path rawPath0: String, packId: String?, language: String,
                           projectId: String, sessionId: String) async throws -> AsrTranscribeOutcome {
        // ── 400 校验链（L2973-2998 逐字，顺序勿动）──
        let rawPath = rawPath0.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPath.isEmpty else {
            throw httpError(400, "path 不能为空（须本地音频绝对路径）")
        }
        let expanded = (rawPath as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {   // Path.expanduser().is_absolute() 等价
            throw httpError(400, "path 须为绝对路径: \(PySem.reprString(rawPath))")
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir),
              !isDir.boolValue else {   // p.is_file()
            throw httpError(400, "音频文件不存在: \(PySem.reprString(rawPath))")
        }
        let ext = Self.pyPathSuffix(expanded)
        guard Self.audioExts.contains(ext) else {
            throw httpError(400, "不支持的音频格式 \(ext.isEmpty ? "（无扩展名）" : ext)；"
                + "支持: \(Self.audioExts.sorted().joined(separator: " "))")
        }
        let size: Int
        do {
            size = try FileManager.default.attributesOfItem(atPath: expanded)[.size] as? Int ?? 0
        } catch {
            throw httpError(400, "无法读取音频文件: \(error.localizedDescription)")
        }
        guard size <= Self.maxBytes else {
            throw httpError(400, "音频文件超过 \(Self.maxBytes / (1024 * 1024))MB 上限"
                + "（实际 \(Self.pyFormat0f(Double(size) / (1024.0 * 1024.0)))MB），请切分后再转写")
        }
        if let packId, !NativeModelPackManifest.validPackId(packId) {
            throw httpError(400, "非法 pack_id: \(PySem.reprString(packId))")
        }

        // ── C7 落盘归属（L3000-3013）：复制原件进会话附件目录（流式，大文件不进
        // 内存）；落盘失败不得让转写失败——文稿是主价值，路径是增益
        var savedPath: String?
        var saveError: String?
        let pid = projectId.trimmingCharacters(in: .whitespacesAndNewlines)
        let sid = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pid.isEmpty && !sid.isEmpty {
            do {
                savedPath = try Self.saveAttachmentFromPath(
                    projectsRoot: projectsRootProvider(), projectId: pid, sessionId: sid,
                    name: URL(fileURLWithPath: expanded).lastPathComponent,
                    src: URL(fileURLWithPath: expanded)).path
            } catch {
                saveError = "OSError: \(error.localizedDescription)"   // 微差①
            }
        }

        // ── 转写（run_in_executor 等价：Task.detached 承载同步 CPU 密集本体，微差②）──
        let driver = self.driver
        let audioURL = URL(fileURLWithPath: expanded)
        let lang = language
        let result: NativeAsrDriver.TranscribeResult
        do {
            result = try await Task.detached(priority: .userInitiated) {
                try driver.transcribe(path: audioURL, packId: packId, language: lang)
            }.value
        } catch let e as NativeAsrPackUnavailableError {
            throw httpError(409, e.message)   // 先装/启用 ASR 模型包再来（L3019-3022）
        } catch let e as NativeAsrAudioDecodeError {
            throw httpError(422, e.message)   // L3023-3024
        } catch let e as NativeAsrValueError {
            throw httpError(400, e.message)   // L3025-3026
        }
        return AsrTranscribeOutcome(text: result.text, duration_s: result.durationS,
                                    model_pack_id: result.modelPackId,
                                    saved_path: savedPath, save_error: saveError)
    }

    // MARK: - save_attachment_from_path（storage/store.py L693-712 逐行为）

    /// save_attachment 的路径版：流式复制而非读整文件进内存（copyfileobj 1MB 块
    /// 等价）；同名不覆盖的 "-<8位uuid>" 铁律保持一致（复用 sanitize + 撞名分支）。
    public static func saveAttachmentFromPath(projectsRoot: URL, projectId: String,
                                              sessionId: String, name: String,
                                              src: URL) throws -> URL {
        let dir = projectsRoot.appendingPathComponent(projectId)
            .appendingPathComponent("attachments").appendingPathComponent(sessionId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = NativeAttachmentEndpoints.sanitizeAttachmentName(name)
        var target = dir.appendingPathComponent(safe)
        if FileManager.default.fileExists(atPath: target.path) {
            var stem = safe, ext = ""
            if let dot = safe.lastIndex(of: "."), dot > safe.startIndex {
                stem = String(safe[..<dot])
                ext = String(safe[dot...])
            }
            let hex = String(UUID().uuidString.replacingOccurrences(of: "-", with: "")
                .prefix(8)).lowercased()
            target = dir.appendingPathComponent("\(stem)-\(hex)\(ext)")
        }
        // shutil.copyfileobj(length=1MB) 等价：分块流式复制
        let input = try FileHandle(forReadingFrom: src)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: target.path, contents: nil)
        let output = try FileHandle(forWritingTo: target)
        defer { try? output.close() }
        while true {
            let chunk = try input.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            try output.write(contentsOf: chunk)
        }
        return target
    }

    /// Python f"{x:.0f}"：四舍六入五成双（round-half-even 格式化）。
    static func pyFormat0f(_ x: Double) -> String {
        let floor = x.rounded(.down)
        let frac = x - floor
        var r: Double
        if frac < 0.5 { r = floor }
        else if frac > 0.5 { r = floor + 1 }
        else { r = floor.truncatingRemainder(dividingBy: 2) == 0 ? floor : floor + 1 }
        return String(Int64(r))
    }

    /// pathlib `Path.suffix.lower()` 语义（与 attachments _ext_of 不同源——ASR 端点
    /// 用的是 pathlib）：取**末级文件名**的 rfind(".")，dotfile（".wav"）与尾随点
    /// （"x."）均为 ""，目录名含点不影响（"/a.d/x" → ""）。
    static func pyPathSuffix(_ path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        guard let dot = name.lastIndex(of: "."),
              dot > name.startIndex, dot < name.index(before: name.endIndex)
        else { return "" }
        return String(name[dot...])
    }
}
