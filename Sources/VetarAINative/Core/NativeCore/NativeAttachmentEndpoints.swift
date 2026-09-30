//
//  NativeAttachmentEndpoints.swift
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

//  逐行为移植（⛔ 只读行为规格源）：
//    · app.py L936-975（POST /api/attachments/parse）：b64 解码失败 400 /
//      10MB 上限 400 / parse_attachment 提取 / 单件 200k 字符截断 / C7 归属
//      齐全才落盘（落盘失败降级为只解析，save_error 如实告知不谎称已保存）
//    · attachments/parser.py L243-279（kind 分类分支序）——文本提取归
//      P2-W1 NativeDocParser（23 package tests 已锚定）
//    · storage/store.py L653-690（_sanitize_attachment_name + save_attachment）：
//      单层安全文件名（分隔符/控制字符/首尾点空格剔除，≤120 字符保扩展名）；
//      同名不覆盖追加 "-<8hex>" 后缀两份都保留（用户铁律）
//
//  微差（汇报清单同步）：
//    ① base64 解码：Python b64decode(validate=False) 忽略非字母表字符——
//       先剥离字母表外字符再严格解码（等价口径）；填充错误两侧都 → 400。
//    ② save_error 文案：Python f"{type(e).__name__}: {e}"（如
//       "OSError: [Errno 28] No space left on device"）——原生侧无法逐字
//       复刻 errno 串，按 "OSError: <localizedDescription>" 形态对齐。
//    ③ 文本截断按 unicodeScalars 计（同 NativeStreamEndpoints 偏差⑥）。
//

import Foundation

public enum NativeAttachmentEndpoints {

    /// _CHAT_ATT_MAX_BYTES / _CHAT_ATT_MAX_CHARS_EACH（app.py L1852-1853）。
    public static let chatAttMaxBytes = 10 * 1024 * 1024
    public static let chatAttMaxCharsEach = 200_000
    /// _ATTACH_MAX_NAME_LEN（store.py L643）。
    public static let attMaxNameLen = 120

    // MARK: - kind 分类（parser.py parse_attachment L243-279 分支序逐字）

    /// _ext_of（L70-72）：lowercase 后 rfind(".")；无点号 → ""。
    public static func extOf(_ name: String) -> String {
        let lower = name.lowercased()
        guard let dot = lower.lastIndex(of: ".") else { return "" }
        return String(lower[dot...])
    }

    /// parse_attachment 的 kind 分流：pdf/docx/doc/xlsx/pptx/csv 在 TEXT_EXTS 之前
    /// 逐字判定（.csv 虽在 TEXT_EXTS 内但先走 _parse_csv）；图片/音频两段式占位。
    public static func kindOf(_ name: String) -> String {
        switch extOf(name) {
        case ".pdf": return "pdf"
        case ".docx": return "docx"
        case ".doc": return "doc"                       // LEGACY_WORD_EXTS
        case ".xlsx", ".xlsm": return "xlsx"
        case ".pptx": return "pptx"
        case ".csv": return "csv"
        case ".png", ".jpg", ".jpeg", ".gif", ".webp": return "image"
        case ".wav", ".mp3", ".m4a", ".aac", ".aiff", ".aif", ".caf",
             ".flac", ".ogg", ".opus", ".webm": return "audio"
        default:
            // TEXT_EXTS（parser.py L44-46 逐字，.csv 靠前分流不会走到这里）
            let textExts: Set<String> = [".txt", ".md", ".markdown", ".json", ".yaml", ".yml",
                                         ".ini", ".log", ".py", ".js", ".ts", ".tsx", ".jsx",
                                         ".html", ".htm", ".xml", ".toml", ".cfg", ".conf",
                                         ".sh", ".css", ".csv"]
            return textExts.contains(extOf(name)) ? "text" : "binary"
        }
    }

    // MARK: - POST /api/attachments/parse（app.py L936-975）

    /// base64 字母表（Python b64decode validate=False 的忽略口径：表外字符先剥离）。
    private static let b64Alphabet = Set<Character>(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")

    /// 端点等价：解析 + 截断 + C7 落盘。校验失败抛 400（原文案）；解析失败不抛
    /// （text=nil，调用方仅标注文件名）；落盘失败不抛（save_error 如实）。
    public static func parseChatAttachment(name: String, contentBase64: String,
                                           projectId: String, sessionId: String,
                                           projectsRoot: URL) throws -> AttachmentParseResult {
        let cleaned = contentBase64.filter { b64Alphabet.contains($0) }
        guard let raw = Data(base64Encoded: cleaned) else {
            throw SidecarError.httpError(status: 400, detail: "附件 \(name) 编码非法")
        }
        guard raw.count <= chatAttMaxBytes else {
            throw SidecarError.httpError(status: 400, detail: "附件 \(name) 超过 10MB 限制")
        }
        var text = NativeDocParser.parse(name: name, raw: raw)
        var truncated = false
        if let t = text, t.unicodeScalars.count > chatAttMaxCharsEach {
            text = String(t.unicodeScalars.prefix(chatAttMaxCharsEach))
            truncated = true
        }

        var result = AttachmentParseResult()
        result.name = name
        result.kind = kindOf(name)
        result.text = text
        result.truncated = truncated

        // C7：落盘（仅当归属齐全且内容非空——`if pid and sid and raw:` 逐字）；
        // 失败降级为"只解析"，save_error 如实告知不谎称已保存
        let pid = projectId.trimmingCharacters(in: .whitespacesAndNewlines)   // Python str().strip()
        let sid = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pid.isEmpty && !sid.isEmpty && !raw.isEmpty {
            do {
                result.savedPath = try saveAttachment(projectsRoot: projectsRoot,
                                                      projectId: pid, sessionId: sid,
                                                      name: name, raw: raw).path
            } catch {
                result.saveError = "OSError: \(error.localizedDescription)"   // 微差②
            }
        }
        return result
    }

    // MARK: - _sanitize_attachment_name（store.py L653-672 逐行为）

    /// _ATTACH_FORBIDDEN_CHARS：'/' '\\' \x00 + chr(1..31) + chr(127)。
    private static let forbiddenScalars: Set<UnicodeScalar> = {
        var s = Set<UnicodeScalar>(["/", "\\", "\0"])
        for c in 1..<32 { s.insert(UnicodeScalar(c)!) }
        s.insert(UnicodeScalar(127)!)
        return s
    }()

    /// 把用户可控文件名净化为单层安全文件名（保留扩展名供解析器按扩展名分发）。
    /// 空 → "attachment"；超长按码点截断并保住扩展名。
    public static func sanitizeAttachmentName(_ name: String) -> String {
        // 只取最后一段（先统一替换两种分隔符再 split）
        let unified = name.replacingOccurrences(of: "\\", with: "/")
        let base = unified.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        var cleaned = String(base.unicodeScalars.filter { !forbiddenScalars.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)   // Python .strip()
        // 去首尾点与空格（防 "." ".." 与 Windows 结尾点）——strip(". ")
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        guard !cleaned.isEmpty else { return "attachment" }
        // 限长但保住扩展名（C4/A10 靠扩展名分发解析器）
        if cleaned.unicodeScalars.count > attMaxNameLen {
            var ext = ""
            if let dot = cleaned.lastIndex(of: "."), dot > cleaned.startIndex {
                ext = String(cleaned[dot...])
            }
            let keep = attMaxNameLen - ext.unicodeScalars.count
            cleaned = String(cleaned.unicodeScalars.prefix(max(keep, 0))) + ext
        }
        return cleaned
    }

    // MARK: - save_attachment（store.py L675-690 逐行为）

    /// 附件落盘到会话附件目录：<projects_root>/<pid>/attachments/<sid>/<净化名>。
    /// 同名不覆盖：追加 "-<8hex>" 后缀，两份都保留。返回绝对路径（回传前端 →
    /// 写进消息正文，agent 据此 read_file 原件）。
    public static func saveAttachment(projectsRoot: URL, projectId: String,
                                      sessionId: String, name: String, raw: Data) throws -> URL {
        let dir = projectsRoot.appendingPathComponent(projectId)
            .appendingPathComponent("attachments").appendingPathComponent(sessionId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = sanitizeAttachmentName(name)
        var target = dir.appendingPathComponent(safe)
        if FileManager.default.fileExists(atPath: target.path) {
            var stem = safe, ext = ""
            if let dot = safe.lastIndex(of: "."), dot > safe.startIndex {
                stem = String(safe[..<dot])
                ext = String(safe[dot...])
            }
            // uuid4().hex[:8]（小写 8 位十六进制）
            let hex = String(UUID().uuidString.replacingOccurrences(of: "-", with: "")
                .prefix(8)).lowercased()
            target = dir.appendingPathComponent("\(stem)-\(hex)\(ext)")
        }
        try raw.write(to: target)
        return target
    }
}
