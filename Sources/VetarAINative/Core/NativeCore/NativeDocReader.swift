//
//  NativeDocReader.swift
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

//  逐行为移植 subagent/sidecar/tools/doc_reader.py（562 行，⛔ 只读行为规格源）：
//    · is_parseable：DOC_EXTS ∪ LEGACY_EXTS
//    · extract(path, budget)：格式概要在前正文在后；失败回说明性文字（ok=False 不抛异常）；
//      UTF-8 字节预算截断 + 截断标记；空文档/图片型如实提示
//    · _read_docx：流序 blocks、标题 markdown 化、表格 markdown 化、格式概要聚合
//      （页面/段落格式众数/表格数/内嵌图片数——eastAsia 中文字体、行距倍数与磅分流）
//    · _read_xlsx（含 .xlsm）：双视图公式兜底「=SUM(...)（公式未计算）」、结构统计
//    · _read_pptx：zip + <a:t> 正则兜底（实体解码顺序 lt/gt/quot/apos/amp）
//    · _read_pdf：PDFKit 逐页（对齐 pypdf 输出结构；提取引擎差异见偏差注记）
//    · 旧式 .doc：textutil -convert docx 临时转换后复用 docx 链；.xls/.ppt 如实提示另存
//    · extract_docx_style：参考 docx 结构化格式提取（doc_writer reference_path 消费）
//
//  偏差（⚠️VERIFY，汇报清单同步）：
//    ① PDF 提取引擎 pypdf → PDFKit：结构/提示文案逐字对齐，文本层的换行/连字细节
//       与 pypdf 可能存在差异（规格测试的最小 PDF 样本两者输出一致）。
//    ② 异常类型名：Python type(e).__name__ → Swift 内部错误类型名（ZipExtractError/
//       DocXReaderError 等），"解析出错（X: ...）" 句式不变。
//    ③ xlsx 日期格式格：openpyxl 会转 datetime，本实现保持原始数值（规格测试不含日期格）。
//    ④ Python 的 missing_dependency 分支不存在（Swift 无运行期缺库）。
//

import Foundation
import PDFKit
import VetarOOXML

public enum NativeDocReader {

    /// DOC_EXTS（可解析新格式）。
    public static let docExts: Set<String> = [".docx", ".xlsx", ".xlsm", ".pptx", ".pdf"]
    /// LEGACY_EXTS（旧式 OLE；.doc 走 textutil，.xls/.ppt 如实提示）。
    public static let legacyExts: Set<String> = [".doc", ".xls", ".ppt"]
    /// _TEXTUTIL_TARGET：textutil 支持的旧格式 → 目标新格式。
    static let textutilTarget: [String: String] = [".doc": "docx", ".rtf": "docx", ".odt": "docx"]

    /// WD_ALIGN_PARAGRAPH 枚举值 → 人话。
    static let alignLabel: [Int: String] = [0: "左对齐", 1: "居中", 2: "右对齐", 3: "两端对齐", 4: "分散对齐"]
    /// 人话 → 枚举值（_ALIGN_VALUE，extract_docx_style 反查）。
    static let alignValue: [String: Int] = ["左对齐": 0, "居中": 1, "右对齐": 2, "两端对齐": 3, "分散对齐": 4]

    public static func isParseable(_ path: String) -> Bool {
        let ext = pySuffixLower(path)
        return docExts.contains(ext) || legacyExts.contains(ext)
    }

    static func pySuffixLower(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        guard let dot = name.lastIndex(of: "."), dot > name.startIndex else { return "" }
        return String(name[dot...]).lowercased()
    }

    // MARK: - extract（doc_reader.extract 逐行）

    public struct ExtractResult {
        public let ok: Bool
        public let content: String
        public let parseKind: String
        public let parseError: String
        /// 仅 ok=true 且发生截断时为 true（Python 契约：ok=False 路径无此键）。
        public let truncated: Bool?
    }

    /// Python round(x, ndigits)：round-half-to-even（与 CPython 浮点语义一致）。
    static func pyRound(_ x: Double, _ ndigits: Int) -> Double {
        let m = pow(10.0, Double(ndigits))
        return (x * m).rounded(.toNearestOrEven) / m
    }

    /// Python str(float)：整数补 .0，其余最短往返表示。
    public static func pyFloatStr(_ d: Double) -> String {
        if d == d.rounded() && abs(d) < 1e16 {
            return "\(Int64(d)).0"
        }
        return String(d)
    }

    static func hasTextutil() -> Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/textutil")
    }

    /// 旧式 Office → OOXML 临时文件（_convert_legacy 逐行）。
    /// 返回 (临时目录, 转换后路径, 新小写扩展名)；不可行 → nil。
    static func convertLegacy(_ path: String) -> (tmpDir: URL, outPath: String, newExt: String)? {
        let ext = pySuffixLower(path)
        guard let targetFmt = textutilTarget[ext] else { return nil }
        guard hasTextutil() else { return nil }
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory
            .appendingPathComponent("docreader_\(UUID().uuidString)", isDirectory: true)
        guard let _ = try? fm.createDirectory(at: tmpDir, withIntermediateDirectories: true) else {
            return nil
        }
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let out = tmpDir.appendingPathComponent("\(stem).\(targetFmt)")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        proc.arguments = ["-convert", targetFmt, path, "-output", out.path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            // timeout 60s 防坏文件挂死（doc_reader 原文口径）
            let deadline = Date().addingTimeInterval(60)
            while proc.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if proc.isRunning { proc.terminate() }
            proc.waitUntilExit()
        } catch {
            try? fm.removeItem(at: tmpDir)
            return nil
        }
        guard proc.terminationStatus == 0,
              let attrs = try? fm.attributesOfItem(atPath: out.path),
              (attrs[.size] as? Int64 ?? 0) > 0 else {
            try? fm.removeItem(at: tmpDir)
            return nil
        }
        return (tmpDir, out.path, "." + targetFmt)
    }

    public static func extract(path origPath: String, budget: Int) -> ExtractResult {
        let origName = (origPath as NSString).lastPathComponent
        var path = origPath
        var ext = pySuffixLower(path)
        var tmpDir: URL? = nil
        defer { if let t = tmpDir { try? FileManager.default.removeItem(at: t) } }

        var body = "", detail = ""
        do {
            if legacyExts.contains(ext) {
                guard let conv = convertLegacy(path) else {
                    let newFmt = ["doc": "docx", "xls": "xlsx", "ppt": "pptx"][String(ext.dropFirst())] ?? "新格式"
                    let plat = hasTextutil() ? "" : "（当前平台无 textutil，该能力仅 macOS 可用）"
                    return ExtractResult(
                        ok: false,
                        content: "文件 \(origName) 是旧式 \(ext) 格式，当前环境无法直接解析\(plat)。"
                            + "请如实告知用户：需要另存为 .\(newFmt) 后才能读取，不要编造文件内容。",
                        parseKind: String(ext.dropFirst()),
                        parseError: "unsupported_legacy:\(ext)",
                        truncated: nil)
                }
                tmpDir = conv.tmpDir
                path = conv.outPath
                ext = conv.newExt
            }
            switch ext {
            case ".docx":
                (body, detail) = try readDocx(path: path)
            case ".xlsx", ".xlsm":
                (body, detail) = try readXlsx(path: path)
            case ".pptx":
                (body, detail) = try readPptx(path: path)
            case ".pdf":
                (body, detail) = try readPdf(path: path)
            default:
                return ExtractResult(ok: false, content: "暂不支持解析 \(ext) 格式。",
                                     parseKind: String(ext.dropFirst()),
                                     parseError: "unsupported_ext:\(ext)", truncated: nil)
            }
        } catch let e as ZipExtractError {
            // zip 魔数/结构损坏（Python zipfile.BadZipFile 分支）
            _ = e
            return ExtractResult(
                ok: false,
                content: "文件 \(origName) 不是有效的 \(ext) 文档（zip 结构损坏，"
                    + "或扩展名与实际格式不符）。请如实告知用户，不要编造内容。",
                parseKind: String(ext.dropFirst()),
                parseError: "corrupt_or_not_ooxml", truncated: nil)
        } catch {
            let typeName = String(describing: type(of: error))
            return ExtractResult(
                ok: false,
                content: "解析 \(origName) 时出错（\(typeName): \(String(describing: error))）。"
                    + "请如实告知用户无法读取，不要编造内容。",
                parseKind: String(ext.dropFirst()),
                parseError: "parse_error:\(typeName)", truncated: nil)
        }

        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let detailTrim = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        var full = detailTrim.isEmpty ? text : detailTrim + "\n\n" + text
        if full.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ExtractResult(
                ok: true,
                content: "文件 \(origName) 已解析，但未提取到任何文本（可能是空文档，"
                    + "或内容为图片/扫描型，需走图像识别）。",
                parseKind: String(ext.dropFirst()), parseError: "", truncated: nil)
        }
        let raw = Data(full.utf8)
        var truncated = false
        if raw.count > budget {
            truncated = true
            full = String(decoding: raw.prefix(budget), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                + "\n\n…（内容过长，已截断）"
        }
        return ExtractResult(ok: true, content: full,
                             parseKind: String(ext.dropFirst()), parseError: "",
                             truncated: truncated)
    }

    // MARK: - docx（_read_docx / _docx_format_summary 逐行）

    static func readDocx(path: String) throws -> (body: String, detail: String) {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        // ZipArchiveReader init 失败（非 zip/坏档）→ NSError 抛出——映射 corrupt 分支：
        // 统一在 extract 捕获；此处先把 NSError 换成 ZipExtractError 语义。
        let doc: DocXDocument
        do {
            doc = try DocXReader.load(data: data)
        } catch let e as ZipExtractError {
            throw e
        } catch {
            // ZipArchiveReader init 的 NSError（EOCD not found 等）→ corrupt 口径
            if (error as NSError).domain == "ZipArchiveReader" {
                throw ZipExtractError.badLocalHeader("word/document.xml")
            }
            throw error
        }

        var lines: [String] = []
        for block in doc.blocks {
            switch block {
            case .paragraph(let p):
                let text = p.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { continue }
                let style = p.styleName
                let low = style.lowercased()
                if low.hasPrefix("heading") || style.hasPrefix("标题") {
                    // re.search(r"(\d+)", style)：首个连续数字串；无 → 1
                    var digits = ""
                    for ch in style {
                        if ch.isNumber { digits.append(ch) } else if !digits.isEmpty { break }
                    }
                    let lvl = min(Int(digits) ?? 1, 6)
                    lines.append(String(repeating: "#", count: lvl) + " " + text)
                } else {
                    lines.append(text)
                }
            case .table(let t):
                var rows: [String] = []
                for row in t.rows {
                    let cells = row.map {
                        $0.replacingOccurrences(of: "\n", with: " ")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    rows.append("| " + cells.joined(separator: " | ") + " |")
                }
                if !rows.isEmpty {
                    // 首行按表头处理，补 markdown 分隔行
                    let width = rows[0].filter { $0 == "|" }.count - 1
                    lines.append("")
                    lines.append(rows[0])
                    lines.append("|" + String(repeating: "---|", count: max(width, 1)))
                    lines.append(contentsOf: rows.dropFirst())
                    lines.append("")
                }
            }
        }
        return (lines.joined(separator: "\n"), docxFormatSummary(doc))
    }

    /// 文档级 + 样式级格式概要（聚合去重，防上下文爆炸）。
    static func docxFormatSummary(_ d: DocXDocument) -> String {
        var out: [String] = ["【格式概要】"]

        // ── 内嵌图片 ──（含图为主的文档必须提示，否则模型会误判文件是空的）
        if d.mediaImageCount > 0 {
            let mb = pyRound(Double(d.mediaImageBytes) / 1048576.0, 2)
            out.append("内嵌图片：\(d.mediaImageCount) 张（约 \(pyFloatStr(mb))MB）。"
                + "⛔ 图片内容无法由文本解析获得，若任务需要图中文字/信息，"
                + "必须走图像识别（read_file 逐张读图或委派视觉子 Agent），"
                + "不得据本文本臆测图片内容。")
        }

        // ── 页面设置 ──
        if let s = d.page {
            let pw = s.widthCm.map { pyRound($0, 2) }
            let ph = s.heightCm.map { pyRound($0, 2) }
            let orient = (pw != nil && ph != nil && pw! > ph!) ? "横向" : "纵向"
            func cm(_ v: Double?) -> String { v.map { pyFloatStr(pyRound($0, 2)) } ?? "None" }
            out.append("页面：\(orient)，\(cm(pw))×\(cm(ph))cm；页边距 上\(cm(s.topCm)) "
                + "下\(cm(s.bottomCm)) 左\(cm(s.leftCm)) 右\(cm(s.rightCm))cm")
        }

        // ── 段落格式聚合 ──
        struct ComboKey: Equatable {
            var style: String
            var name: String?
            var size: Double?
            var bold: Bool?
            var align: String?
            var fli: Double?
            var lsp: String?
        }
        var combos: [(key: ComboKey, count: Int)] = []
        for p in d.paragraphs {
            if p.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let style = p.styleName.isEmpty ? "Normal" : p.styleName
            let rp = p.firstRun
            let name = rp?.combinedFontName
            let size = rp?.sizePt.map { pyRound($0, 1) }
            let bold = rp?.bold
            var fli: Double? = nil
            if let v = p.firstLineIndentCm { fli = pyRound(v, 2) }
            var lsp: String? = nil
            if let pt = p.lineSpacingPt {
                lsp = "\(pyFloatStr(pyRound(pt, 1)))磅"
            } else if let mult = p.lineSpacingMultiple {
                lsp = "\(pyFloatStr(pyRound(mult, 2)))倍"
            }
            let align = p.alignmentValue.flatMap { alignLabel[$0] ?? String($0) }
            let key = ComboKey(style: style, name: name, size: size, bold: bold,
                               align: align, fli: fli, lsp: lsp)
            if let idx = combos.firstIndex(where: { $0.key == key }) {
                combos[idx].count += 1
            } else {
                combos.append((key, 1))
            }
        }
        if !combos.isEmpty {
            out.append("段落格式（样式 / 字体 / 字号pt / 加粗 / 对齐 / 首行缩进cm / 行距 → 段数）：")
            // 按出现次数降序、首次出现序稳定（Python sorted 稳定性口径），最多 12 行
            let sorted = combos.enumerated().sorted { a, b in
                a.element.count != b.element.count
                    ? a.element.count > b.element.count : a.offset < b.offset
            }
            for (_, e) in sorted.prefix(12) {
                var parts: [String] = [e.key.style.isEmpty ? "Normal" : e.key.style]
                parts.append(e.key.name.map { "字体=\($0)" } ?? "字体=继承")
                if let s = e.key.size, s != 0 {
                    parts.append("字号=\(pyFloatStr(s))")
                } else {
                    parts.append("字号=继承")
                }
                if let b = e.key.bold { parts.append("加粗=\(b ? "是" : "否")") }
                if let a = e.key.align { parts.append("对齐=\(a)") }
                if let f = e.key.fli, f != 0 { parts.append("首行缩进=\(pyFloatStr(f))") }
                if let l = e.key.lsp { parts.append("行距=\(l)") }
                out.append("  " + parts.joined(separator: " / ") + " → \(e.count) 段")
            }
        }

        // ── 规模统计 ──
        if d.tableCount > 0 {
            out.append("表格：\(d.tableCount) 个")
        }
        return out.count > 1 ? out.joined(separator: "\n") : ""
    }

    // MARK: - extract_docx_style（#14 参考格式结构化提取）

    public struct NativeDocxStyle {
        public struct Page {
            public var widthCm: Double?; public var heightCm: Double?
            public var topCm: Double?; public var bottomCm: Double?
            public var leftCm: Double?; public var rightCm: Double?
        }
        public struct Body {
            public var font: String?          // eastAsia 中文字体
            public var asciiFont: String?
            public var sizePt: Double?
            public var alignValue: Int?
            public var firstLineIndentCm: Double?
            public var lineSpacing: Double?   // 倍数
            public var lineSpacingPt: Double? // 固定磅
        }
        /// nil = 该组提取失败（Python 空 dict 语义）。
        public var page: Page?
        public var body: Body?
        public init(page: Page? = nil, body: Body? = nil) {
            self.page = page; self.body = body
        }
    }

    /// 提取参考 .docx 的结构化格式（doc_writer reference_path 消费）。
    /// 任一环节失败 → 对应组 nil，绝不抛出（Python 全 try 包裹口径）。
    public static func extractDocxStyle(path: String) -> NativeDocxStyle {
        var result = NativeDocxStyle()
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let d = try? DocXReader.load(data: data) else {
            return result
        }
        // ── 页面设置 ──
        if let s = d.page {
            result.page = .init(
                widthCm: s.widthCm.map { pyRound($0, 2) },
                heightCm: s.heightCm.map { pyRound($0, 2) },
                topCm: s.topCm.map { pyRound($0, 2) },
                bottomCm: s.bottomCm.map { pyRound($0, 2) },
                leftCm: s.leftCm.map { pyRound($0, 2) },
                rightCm: s.rightCm.map { pyRound($0, 2) })
        }
        // ── 正文主格式（跳过标题；按出现次数聚合取众数，平局取先见）──
        struct Key: Equatable {
            var ascii: String?; var east: String?; var size: Double?
            var align: String?; var fli: Double?; var lspMult: Double?; var lspPt: Double?
        }
        var combos: [(key: Key, count: Int)] = []
        for p in d.paragraphs {
            if p.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let sname = p.styleName.isEmpty ? "Normal" : p.styleName
            let low = sname.lowercased()
            if low.hasPrefix("heading") || sname.hasPrefix("标题") { continue }
            let rp = p.firstRun
            // 合并名拆回 ascii/eastAsia（_docx_run_font 合并串的逆操作）
            var asciiFont: String? = nil, eastAsia: String? = nil
            if let name = rp?.combinedFontName {
                if let slash = name.firstIndex(of: "/") {
                    asciiFont = String(name[name.startIndex..<slash])
                    eastAsia = String(name[name.index(after: slash)...])
                } else {
                    eastAsia = name   // 只有 eastAsia 时（中文文档常见）
                }
            }
            let size = rp?.sizePt.map { pyRound($0, 1) }
            let fli = p.firstLineIndentCm.map { pyRound($0, 2) }
            let lspPt = p.lineSpacingPt.map { pyRound($0, 1) }
            let lspMult = p.lineSpacingPt == nil ? p.lineSpacingMultiple.map { pyRound($0, 2) } : nil
            let align = p.alignmentValue.flatMap { alignLabel[$0] ?? String($0) }
            let key = Key(ascii: asciiFont, east: eastAsia, size: size,
                          align: align, fli: fli, lspMult: lspMult, lspPt: lspPt)
            if let idx = combos.firstIndex(where: { $0.key == key }) {
                combos[idx].count += 1
            } else {
                combos.append((key, 1))
            }
        }
        if let best = combos.max(by: { a, b in a.count < b.count }) {
            // max(by:) 取"更大"者——count 升序比较下返回最大；平局 Swift max 取后者，
            // Python max 取先见者 → 显式按先见序扫描保证口径
            let winner = combos.filter { $0.count == best.count }.first ?? best
            result.body = .init(
                font: winner.key.east, asciiFont: winner.key.ascii,
                sizePt: winner.key.size,
                alignValue: winner.key.align.flatMap { alignValue[$0] },
                firstLineIndentCm: winner.key.fli,
                lineSpacing: winner.key.lspMult, lineSpacingPt: winner.key.lspPt)
        }
        return result
    }

    // MARK: - xlsx（_read_xlsx 逐行）

    static func readXlsx(path: String) throws -> (body: String, detail: String) {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let sheets: [XlsxSheet]
        do {
            sheets = try XlsxReader.load(data: data)
        } catch let e as ZipExtractError {
            throw e
        } catch {
            if (error as NSError).domain == "ZipArchiveReader" {
                throw ZipExtractError.badLocalHeader("xl/workbook.xml")
            }
            throw error
        }

        var out: [String] = []
        var stats: [String] = []
        var nFormula = 0
        for ws in sheets {
            // data_only 视图 + 公式兜底（缓存缺失 → 「=...（公式未计算）」）
            var grid: [[XlsxCellValue?]] = []
            for ri in 1...ws.maxRow {
                var vals: [XlsxCellValue?] = []
                for ci in 1...ws.maxColumn {
                    let cell = ws.cells[ri]?[ci]
                    var v = cell?.value
                    if (v == nil || v == .blank), let f = cell?.formula {
                        v = .string("=\(f)（公式未计算）")
                        nFormula += 1
                    }
                    vals.append(v)
                }
                grid.append(vals)
            }
            // 非空行过滤：任一格 str 非空即保留
            let rows = grid.filter { row in
                row.contains { v in
                    guard let v, v != .blank else { return false }
                    return !cellStr(v).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
            }
            stats.append("「\(ws.name)」\(ws.maxRow)行×\(ws.maxColumn)列（非空 \(rows.count) 行）")
            if rows.isEmpty { continue }
            out.append("## 工作表：\(ws.name)")
            let width = rows.map(\.count).max() ?? 0
            for (i, row) in rows.enumerated() {
                var cells = row.map { v in
                    v.map { cellStr($0).replacingOccurrences(of: "\n", with: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
                }
                while cells.count < width { cells.append("") }
                out.append("| " + cells.joined(separator: " | ") + " |")
                if i == 0 {
                    out.append("|" + String(repeating: "---|", count: width))
                }
            }
            out.append("")
        }
        var detail = stats.isEmpty ? "" : "【表格结构】" + stats.joined(separator: "；")
        if nFormula > 0 {
            detail += "。⚠️ 有 \(nFormula) 个公式单元格缺少计算缓存（文件未被 Excel 打开计算过），"
                + "已原样显示公式；如需其数值请如实说明无法获得，不要自行推算并当作原表数据。"
        }
        return (out.joined(separator: "\n"), detail)
    }

    /// Python str(cell_value)：int 去 .0、bool True/False、其余最短表示。
    static func cellStr(_ v: XlsxCellValue) -> String {
        switch v {
        case .blank: return ""
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return pyFloatStr(d)
        case .bool(let b): return b ? "True" : "False"
        case .error(let e): return e
        }
    }

    // MARK: - pptx（_read_pptx 逐行：zip + <a:t> 正则兜底）

    static func readPptx(path: String) throws -> (body: String, detail: String) {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let zip: ZipArchiveReader
        do {
            zip = try ZipArchiveReader(data: data)
        } catch {
            throw ZipExtractError.badLocalHeader("ppt/slides")
        }
        let names = zip.entries.map(\.name)
            .filter { $0.range(of: #"^ppt/slides/slide\d+\.xml$"#,
                               options: .regularExpression) != nil }
            .sorted { slideNo($0) < slideNo($1) }
        var slides: [String] = []
        for n in names {
            guard let xmlData = try? zip.data(named: n, from: data) else { continue }
            let xml = String(decoding: xmlData, as: UTF8.self)   // decode errors="ignore" 等价
            var texts: [String] = []
            for (_, capture) in xml.captureGroups(of: "<a:t>(.*?)</a:t>", dotMatchesNewlines: true) {
                let t = xmlUnescape(String(capture))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { texts.append(t) }
            }
            let idx = slideNo(n)
            let bodyText = texts.isEmpty
                ? "（本页无文本，可能为纯图片版式）"
                : texts.map { "- \($0)" }.joined(separator: "\n")
            slides.append("## 第 \(idx) 页\n\(bodyText)")
        }
        let detail = "【PPTX 结构】共 \(slides.count) 页。"
            + "（未安装 python-pptx，按 OOXML 文本节点提取，故不含版式/母版/动画细节）"
        return (slides.joined(separator: "\n\n"), detail)
    }

    static func slideNo(_ name: String) -> Int {
        // re.search(r"(\d+)", n)：首个连续数字串
        guard let m = name.ranges(of: "\\d+").first else { return 0 }
        return Int(name[m]) ?? 0
    }

    /// _xml_unescape：&amp; 必须最后替换（否则 &amp;lt; 被二次解成 <）。
    static func xmlUnescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: - pdf（_read_pdf 逐行；引擎 pypdf → PDFKit，见偏差①）

    /// 内部错误（走 extract 通用「解析出错」分支；description 即 Python e 的消息位）。
    enum NativeDocReaderError: Error, CustomStringConvertible {
        case pdfUnreadable
        var description: String { "PDF 文档无法打开（结构损坏或加密）" }
    }

    static func readPdf(path: String) throws -> (body: String, detail: String) {
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else {
            throw NativeDocReaderError.pdfUnreadable
        }
        let n = doc.pageCount
        var out: [String] = []
        var emptyPages = 0
        for i in 0..<n {
            let t = (doc.page(at: i)?.string ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let head = "\n----- 第 \(i + 1)/\(n) 页 -----"
            if !t.isEmpty {
                out.append(head + "\n" + t)
            } else {
                emptyPages += 1
                out.append(head + "\n（本页无可提取文本，可能是扫描件/图片型 PDF，需走图像识别）")
            }
        }
        var detail = "【PDF 结构】共 \(n) 页"
        if emptyPages > 0 {
            detail += "，其中 \(emptyPages) 页无文本层"
        }
        if let attrs = doc.documentAttributes,
           let title = attrs[PDFDocumentAttribute.titleAttribute] as? String, !title.isEmpty {
            detail += "；标题：\(title)"
        }
        return (out.joined(separator: "\n"), detail)
    }
}

private extension String {
    /// NSRegularExpression 捕获组 1 的全部匹配（re.S 可选）。
    func captureGroups(of pattern: String,
                       dotMatchesNewlines: Bool = false) -> [(Range<String.Index>, Substring)] {
        var out: [(Range<String.Index>, Substring)] = []
        guard let re = try? NSRegularExpression(
            pattern: pattern,
            options: dotMatchesNewlines ? [.dotMatchesLineSeparators] : []) else { return out }
        for m in re.matches(in: self, range: NSRange(startIndex..., in: self)) {
            if m.numberOfRanges >= 2, let r = Range(m.range(at: 1), in: self) {
                out.append((r, self[r]))
            }
        }
        return out
    }
    func ranges(of pattern: String) -> [Range<String.Index>] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: self, range: NSRange(startIndex..., in: self))
            .compactMap { Range($0.range, in: self) }
    }
}
