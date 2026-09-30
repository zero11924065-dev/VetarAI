//
//  NativeDocParser.swift
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

//  移植 subagent/sidecar/attachments/parser.py 中知识索引用到的解析面（⛔ 只读行为规格）：
//    · 文本族（.txt/.json/.yaml/.log/.py/.html/.csv…）：utf-8 → gbk → latin-1 逐序解码
//    · .csv：逐行 " | " 拼接（前 500 行、单元格截 200 字符，同 _parse_csv）
//    · .doc：macOS 自带 textutil stdin/stdout（-format doc 强制声明；exit code 不可信，
//      stdout 空 = 失败；30s 超时）——逐字移植 C3 实测口径
//    · .pdf：PDFKit 逐页取文本（[第N页] 前缀格式对齐 pypdf 路径）
//    · .docx/.xlsx/.xlsm/.pptx（P2-W3b 接通）：VetarOOXML 读取面，逐字对齐
//      _parse_docx（段落先行表格后至）/ _parse_xlsx（200 行/表、单元格截 200、
//      省略标注）/ _parse_pptx（标题/形状/表格/备注）——知识索引与工作流 file_read
//      节点的 OOXML 解析自此点亮（W1/W2 留白的偏差③消除）
//
//  解析失败一律返回 nil（对齐 parse_attachment 的 None 语义：调用方跳过，不阻塞整批）。
//

import Foundation
import PDFKit
import VetarOOXML

public enum NativeDocParser {

    /// warehouse.py INDEXABLE_DOC_EXTS 等价集（= SUPPORTED_EXTS − 图片 − .md；
    /// 音频族虽在集合内但解析恒失败，与侧车一致）。
    public static let indexableDocExts: Set<String> = [
        ".txt", ".markdown", ".json", ".yaml", ".yml", ".ini", ".log", ".py", ".js",
        ".ts", ".tsx", ".jsx", ".html", ".htm", ".xml", ".toml", ".cfg", ".conf",
        ".sh", ".css", ".csv", ".doc", ".pdf", ".docx", ".xlsx", ".xlsm", ".pptx",
        ".wav", ".mp3", ".m4a", ".aac", ".aiff", ".aif", ".caf", ".flac", ".ogg",
        ".opus", ".webm",
    ]

    /// 单 sheet 最多行数 / 单元格截断（parser.py _XLSX_MAX_ROWS_PER_SHEET / _MAX_CELL_LEN）。
    private static let csvMaxRows = 500
    private static let maxCellLen = 200
    /// _XLSX_MAX_ROWS_PER_SHEET（xlsx 每表最多行数，超出如实标注）。
    private static let xlsxMaxRowsPerSheet = 200
    private static let docConvertTimeout: TimeInterval = 30

    /// parse_attachment(name, raw) → 文本 or nil（kind 分类略——知识索引只用文本）。
    public static func parse(name: String, raw: Data) -> String? {
        // 对齐 _ext_of：无点号 → ""；多点号取末段（rfind）。
        let lower = name.lowercased()
        let ext = lower.contains(".") ? "." + (lower.split(separator: ".").last.map(String.init) ?? "") : ""
        switch ext {
        case ".csv":
            return parseCSV(raw)
        case ".doc":
            return parseDoc(raw)
        case ".pdf":
            return parsePDF(raw)
        case ".docx":
            return parseDocx(raw)
        case ".xlsx", ".xlsm":
            return parseXlsx(raw)
        case ".pptx":
            return parsePptx(raw)
        default:
            // 对齐 parse_attachment 分流：仅 TEXT_EXTS 走文本解码；
            // 图片/音频/未知扩展名 → (None, "image"/"audio"/"binary") 即 nil。
            // （此前 default 一律 parseText，.bin 等二进制被 gbk/latin-1 兜底误解析入库。）
            guard Self.textExts.contains(ext) else { return nil }
            return parseText(raw)
        }
    }

    /// parser.py TEXT_EXTS 逐字（.csv 虽在集合内但分流靠前，先走 _parse_csv）。
    public static let textExts: Set<String> = [
        ".txt", ".md", ".markdown", ".json", ".yaml", ".yml", ".ini",
        ".log", ".py", ".js", ".ts", ".tsx", ".jsx", ".html", ".htm",
        ".xml", ".toml", ".cfg", ".conf", ".sh", ".css", ".csv",
    ]

    // MARK: - 文本族（_parse_text：utf-8 → gbk → latin-1）

    static func parseText(_ raw: Data) -> String? {
        if let s = String(data: raw, encoding: .utf8) { return s }
        // gbk = CFStringEncoding GB_18030_2000（GBK 超集，Python gbk codec 近似）
        let gbk = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let s = String(data: raw, encoding: gbk) { return s }
        // latin-1 永不失败（全字节映射）——对齐 Python 兜底
        return String(data: raw, encoding: .isoLatin1)
    }

    // MARK: - CSV（_parse_csv：csv.reader → 前 500 行 → 单元格截 200 → " | " 拼接）

    static func parseCSV(_ raw: Data) -> String? {
        guard let text = parseText(raw) else { return nil }
        let rows = parseCSVRows(text)
        let lines = rows.prefix(csvMaxRows).compactMap { row -> String? in
            guard !row.isEmpty else { return nil }
            return row.map { String($0.prefix(maxCellLen)) }.joined(separator: " | ")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// 紧凑 RFC4180 解析（Python csv.reader 默认方言：双引号转义、内嵌换行/逗号）。
    static func parseCSVRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if inQuotes {
                if c == "\"" {
                    let next = text.index(after: i)
                    if next < text.endIndex && text[next] == "\"" {
                        field.append("\""); i = text.index(after: next)
                    } else {
                        inQuotes = false; i = next
                    }
                } else {
                    field.append(c); i = text.index(after: i)
                }
            } else if c == "\"" && field.isEmpty {
                inQuotes = true; i = text.index(after: i)
            } else if c == "," {
                row.append(field); field = ""; i = text.index(after: i)
            } else if c == "\n" || c == "\r" {
                var next = text.index(after: i)
                if c == "\r" && next < text.endIndex && text[next] == "\n" { next = text.index(after: next) }
                row.append(field); field = ""
                rows.append(row); row = []
                i = next
            } else {
                field.append(c); i = text.index(after: i)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    // MARK: - .doc（textutil：-stdin -format doc -convert txt -stdout；stdout 空 = 失败）

    static func parseDoc(_ raw: Data) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        proc.arguments = ["-stdin", "-format", "doc", "-convert", "txt", "-stdout"]
        let inPipe = Pipe()
        let outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return nil
        }
        // 防挂死：超时 watchdog（对齐 _DOC_CONVERT_TIMEOUT=30）
        let done = DispatchSemaphore(value: 0)
        var outData = Data()
        DispatchQueue.global().async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        inPipe.fileHandleForWriting.write(raw)
        try? inPipe.fileHandleForWriting.close()
        if done.wait(timeout: .now() + docConvertTimeout) == .timedOut {
            proc.terminate()
            return nil
        }
        proc.waitUntilExit()
        let out = String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }

    // MARK: - .pdf（PDFKit 逐页；[第N页] 前缀对齐 pypdf 路径）

    static func parsePDF(_ raw: Data) -> String? {
        guard let doc = PDFDocument(data: raw) else { return nil }
        var parts: [String] = []
        for i in 0..<doc.pageCount {
            let t = (doc.page(at: i)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { parts.append("[第\(i + 1)页]\n\(t)") }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    // MARK: - OOXML（P2-W3b 接通：VetarOOXML 读取面；_parse_docx/_parse_xlsx/_parse_pptx 逐行）

    /// 表格行 → "a | b | c" 一行（_row_to_line：strip + 去换行 + " | " 拼接 + 过滤空格）。
    static func rowToLine(_ cells: [String]) -> String {
        cells.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
        }.filter { !$0.isEmpty }.joined(separator: " | ")
    }

    /// _parse_docx：段落先行、表格后至（parser.py 口径——非文档流顺序，与 doc_reader 不同链）。
    static func parseDocx(_ raw: Data) -> String? {
        guard let doc = try? DocXReader.load(data: raw) else { return nil }
        var parts: [String] = []
        for p in doc.paragraphs {
            let t = p.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { parts.append(t) }
        }
        for block in doc.blocks {
            guard case .table(let t) = block else { continue }
            for row in t.rows {
                let line = rowToLine(row)
                if !line.isEmpty { parts.append(line) }
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// _parse_xlsx：data_only 缓存值；前 200 行/表；单元格截 200；" | " 拼接；
    /// 超 200 行如实标注（公式格无缓存 → 空串，与 openpyxl data_only 同口径）。
    static func parseXlsx(_ raw: Data) -> String? {
        guard let sheets = try? XlsxReader.load(data: raw) else { return nil }
        var parts: [String] = []
        for ws in sheets {
            var lines = ["[工作表: \(ws.name)]"]
            var emitted = 0
            for ri in 1...ws.maxRow {
                if emitted >= xlsxMaxRowsPerSheet {
                    lines.append("（后续行已省略，共超 \(emitted) 行）")
                    break
                }
                let vals = (1...ws.maxColumn).map { ci -> String in
                    guard let v = ws.cells[ri]?[ci]?.value, v != .blank else { return "" }
                    return WFText.pyPrefix(NativeDocReader.cellStr(v), maxCellLen)
                }
                let line = vals.filter { !$0.isEmpty }.joined(separator: " | ")
                if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lines.append(line)
                }
                emitted += 1
            }
            if lines.count > 1 { parts.append(lines.joined(separator: "\n")) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// _parse_pptx：逐页标题/正文形状/表格/备注（python-pptx 口径）。
    static func parsePptx(_ raw: Data) -> String? {
        guard let slides = try? PptxReader.load(data: raw) else { return nil }
        var parts: [String] = []
        for (i, slide) in slides.enumerated() {
            var lines = ["[第\(i + 1)页]"]
            if let title = slide.title?
                .trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                lines.append("标题: \(title)")
            }
            for shape in slide.shapes {
                switch shape {
                case .text(let t):
                    let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !s.isEmpty { lines.append(s) }
                case .table(let rows):
                    for row in rows {
                        let line = rowToLine(row)
                        if !line.isEmpty { lines.append(line) }
                    }
                }
            }
            if let note = slide.notes?
                .trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                lines.append("备注: \(note)")
            }
            if lines.count > 1 { parts.append(lines.joined(separator: "\n")) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }
}
