//
//  NativeDocWriter.swift
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

//  逐行为移植 subagent/sidecar/tools/doc_writer.py（465 行，⛔ 只读行为规格源）：
//    · write_document 分发：md/markdown、docx（含 reference_path 参考格式）、
//      xlsx/xls、pptx/ppt；未知类型 bad_arg（文案逐字）
//    · _write_md：title + blocks（page_break→--- / heading 1-6 / bullets / table / 段落）
//    · _write_docx：结构化 blocks 契约 + #14 参考格式（字体/字号/对齐/首行缩进/行距/
//      页面尺寸边距，逐项回退默认）+ 0.4.6 页码页脚（{p}/{t} 模板）+ 0.4.12 A7 图片块
//      （width_cm/height_cm 单维按比例、grid 3 列、加载失败如实占位）
//    · _write_xlsx：数字字符串自动转 int/float（isdigit 口径）、31 字符表名上限
//    · _write_pptx：slides 契约（title/bullets/notes）、空 slides 兜底「演示文稿」
//
//  载体：VetarOOXML（DocXBuilder/XlsxBuilder/PptxBuilder + StyleConfig/ImageRef/notes）。
//
//  偏差（⚠️VERIFY，汇报清单同步）：
//    ① 表格样式：Python "Light Grid Accent 1" → 本库 TableGrid（边框视觉等价，样式名不同）。
//    ② 数字字符串转数值仅认 ASCII 数字（Python isdigit 含 Unicode 数字字形的边角不覆盖）。
//    ③ rows 内非数组行：Python 会迭代字符串逐字符写格——此处跳过该行（异常输入，不静默改义）。
//    ④ pptx 版式：Python 依内容选 title/bullet/blank 三版式——本库单一自绘版式，
//       文本与备注内容等价，占位几何不同。
//

import Foundation
import VetarOOXML

public enum NativeDocWriter {

    /// _clean_text：str(v)（None → ""）。
    static func cleanText(_ v: JSONValue?) -> String {
        guard let v else { return "" }
        switch v {
        case .null: return ""
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return NativeDocReader.pyFloatStr(d)
        case .bool(let b): return b ? "True" : "False"
        case .array, .object: return WFText.pyStr(v)
        }
    }

    /// Python 真值判定（or/三元/if 口径）。
    static func truthy(_ v: JSONValue?) -> Bool {
        guard let v else { return false }
        switch v {
        case .null: return false
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .double(let d): return d != 0
        case .string(let s): return !s.isEmpty
        case .array(let a): return !a.isEmpty
        case .object(let o): return !o.isEmpty
        }
    }

    /// _to_pos_float（0.4.12 A7）：安全转正浮点；无效 → nil（区分「未指定」与「0」）。
    /// 容忍数字 / 数字字符串 / 带单位（"13cm"/"13厘米"）。
    static func toPosFloat(_ v: JSONValue?) -> Double? {
        guard let v else { return nil }
        if case .bool = v { return nil }
        let f: Double?
        switch v {
        case .int(let i): f = Double(i)
        case .double(let d): f = d
        default:
            let s = cleanText(v).trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "cm", with: "")
                .replacingOccurrences(of: "厘米", with: "")
            f = Double(s)
        }
        guard let val = f, val > 0, val == val else { return nil }   // 非正数或 NaN
        return val
    }

    static func extractBlocks(_ content: [String: JSONValue]) -> (title: String, blocks: [[String: JSONValue]]) {
        let title = truthy(content["title"]) ? cleanText(content["title"]) : ""
        var blocks: [[String: JSONValue]] = []
        if case .array(let arr) = content["blocks"] {
            for b in arr {
                if case .object(let o) = b { blocks.append(o) }
            }
        }
        return (title, blocks)
    }

    // MARK: - write_document（doc_writer.write_document 逐行）

    /// 按类型生成文档，返回写入字节数。不支持的类型抛 NativeToolValueError（bad_arg）。
    @discardableResult
    public static func writeDocument(docType: String, target: String,
                                     content: [String: JSONValue],
                                     referencePath: String? = nil) throws -> Int {
        let dt = docType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch dt {
        case "md", "markdown":
            return try writeMd(target: target, content: content)
        case "docx":
            // #14：参考格式仅 docx 生效；提取失败一律静默回退默认，绝不阻断写出
            var refStyle: NativeDocReader.NativeDocxStyle? = nil
            if let rp = referencePath {
                let exists = FileManager.default.fileExists(atPath: rp)
                var isDir = ObjCBool(false)
                _ = FileManager.default.fileExists(atPath: rp, isDirectory: &isDir)
                if exists && !isDir.boolValue && NativeDocReader.pySuffixLower(rp) == ".docx" {
                    refStyle = NativeDocReader.extractDocxStyle(path: rp)
                }
            }
            return try writeDocx(target: target, content: content, refStyle: refStyle)
        case "xlsx", "xls":
            return try writeXlsx(target: target, content: content)
        case "pptx", "ppt":
            return try writePptx(target: target, content: content)
        default:
            throw NativeToolValueError(message:
                "bad_arg: doc_type '\(docType)' 不支持（可选 docx/xlsx/pptx/md）")
        }
    }

    // MARK: - _write_md

    static func writeMd(target: String, content: [String: JSONValue]) throws -> Int {
        let (title, blocks) = extractBlocks(content)
        var lines: [String] = []
        if !title.isEmpty {
            lines.append("# \(title)\n")
        }
        for b in blocks {
            let t = (b["type"]?.string ?? "paragraph")
            switch t {
            case "page_break":
                lines.append("\n---\n")
            case "heading":
                let lv = max(1, min(levelArg(b["level"], default: 2), 6))
                lines.append("\(String(repeating: "#", count: lv)) \(cleanText(b["text"]))\n")
            case "bullets":
                if case .array(let items) = b["items"] {
                    for it in items { lines.append("- \(cleanText(it))") }
                }
                lines.append("")
            case "table":
                if case .array(let rows) = b["rows"], !rows.isEmpty {
                    let table = rows.map { rowCells($0) }
                    let header = table[0].map { cleanText($0) }
                    lines.append("| " + header.joined(separator: " | ") + " |")
                    lines.append("| " + Array(repeating: "---", count: header.count).joined(separator: " | ") + " |")
                    for r in table.dropFirst() {
                        lines.append("| " + r.map { cleanText($0) }.joined(separator: " | ") + " |")
                    }
                    lines.append("")
                }
            default:
                lines.append(cleanText(b["text"]) + "\n")
            }
        }
        let text = lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        let data = Data(text.utf8)
        try data.write(to: URL(fileURLWithPath: target))
        return data.count
    }

    /// int(x)：可转整的 JSONValue（Python int() 截断语义）；失败 → nil。
    static func intArg(_ v: JSONValue?) -> Int? {
        guard let v else { return nil }
        switch v {
        case .int(let i): return Int(i)
        case .double(let d): return d.isFinite ? Int(d) : nil
        case .string(let s):
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return Int(t)
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    /// Python `int(b.get("level") or default)`：falsy（缺省/0/""/null）→ default。
    static func levelArg(_ v: JSONValue?, default def: Int) -> Int {
        truthy(v) ? (intArg(v) ?? def) : def
    }

    static func rowCells(_ v: JSONValue) -> [JSONValue] {
        if case .array(let a) = v { return a }
        return []
    }

    // MARK: - _write_docx

    static func writeDocx(target: String, content: [String: JSONValue],
                          refStyle: NativeDocReader.NativeDocxStyle?) throws -> Int {
        let (title, blocks) = extractBlocks(content)
        var builder = DocXBuilder()

        // #14：ref_style → StyleConfig（逐项回退默认；无效值同缺省）
        if let body = refStyle?.body {
            if let f = body.font, !f.isEmpty { builder.style.normalEastAsiaFont = f }
            if let f = body.asciiFont, !f.isEmpty { builder.style.normalAsciiFont = f }
            if let s = body.sizePt, s > 0 { builder.style.normalSizePt = s }
            builder.style.bodyAlignValue = body.alignValue
            if let fli = body.firstLineIndentCm, fli > 0 {
                builder.style.bodyFirstLineIndentCm = fli
            }
            if let lsp = body.lineSpacing, lsp > 0 {
                builder.style.bodyLineSpacingMultiple = lsp
            } else if let pt = body.lineSpacingPt, pt > 0 {
                builder.style.bodyLineSpacingPt = pt
            }
        }
        func pick(_ v: Double?, _ def: Double) -> Double {
            (v != nil && v! > 0) ? v! : def
        }
        if let page = refStyle?.page {
            builder.style.pageWidthCm = pick(page.widthCm, 21.0)
            builder.style.pageHeightCm = pick(page.heightCm, 29.7)
            builder.style.marginTopCm = pick(page.topCm, 2.54)
            builder.style.marginBottomCm = pick(page.bottomCm, 2.54)
            builder.style.marginLeftCm = pick(page.leftCm, 3.18)
            builder.style.marginRightCm = pick(page.rightCm, 3.18)
        }

        // 0.4.6+：整体页码页脚（默认开启）
        let pageNumber = content["page_number"] == nil ? true : truthy(content["page_number"])
        builder.pageNumberFooter = pageNumber
        if let fmt = content["page_number_format"], truthy(fmt) {
            builder.pageNumberFormat = cleanText(fmt)
        }

        if !title.isEmpty {
            builder.add(.title(title))
        }
        for b in blocks {
            let t = (b["type"]?.string ?? "paragraph")
            switch t {
            case "page_break":
                builder.add(.pageBreak)
            case "heading":
                let lv = max(1, min(levelArg(b["level"], default: 2), 4))
                builder.add(.heading(level: lv, text: cleanText(b["text"])))
            case "bullets":
                if case .array(let items) = b["items"] {
                    builder.add(.bullets(items.map { cleanText($0) }))
                } else {
                    builder.add(.bullets([]))
                }
            case "table":
                let rows = (b["rows"].map { v -> [[JSONValue]] in
                    if case .array(let arr) = v { return arr.map { rowCells($0) } }
                    return []
                }) ?? []
                if !rows.isEmpty {
                    let ncols = rows.map(\.count).max() ?? 0
                    let grid = rows.map { r in
                        (0..<ncols).map { j in j < r.count ? cleanText(r[j]) : "" }
                    }
                    builder.add(.table(rows: grid))
                }
            case "image":
                appendImageBlock(b, to: &builder)
            default:
                builder.add(.paragraph([DocXBuilder.Run(cleanText(b["text"]))]))
            }
        }
        try builder.save(to: URL(fileURLWithPath: target))
        let attrs = try FileManager.default.attributesOfItem(atPath: target)
        return Int(attrs[.size] as? Int64 ?? 0)
    }

    /// image 块（0.4.6+ / 0.4.12 A7）：paths/path、layout（single/grid）、caption、
    /// width_cm/height_cm（单维按比例，都不给 → width 13.0，由 ImageRef.emuSize 落实）。
    static func appendImageBlock(_ b: [String: JSONValue], to builder: inout DocXBuilder) {
        var paths: [String] = []
        if case .array(let arr) = b["paths"] {
            paths = arr.compactMap { $0.string }
        } else if let p = b["path"]?.string {
            paths = [p]
        }
        let layout: DocXBuilder.ImageLayout =
            (b["layout"]?.string == "grid") ? .grid : .single
        let caption = truthy(b["caption"]) ? cleanText(b["caption"]) : ""
        var widthCm = toPosFloat(b["width_cm"])
        let heightCm = toPosFloat(b["height_cm"])
        if widthCm == nil && heightCm == nil {
            widthCm = 13.0   // 默认：A4 正文宽，保持原图比例
        }
        let fm = FileManager.default
        let valid = paths.filter { p in
            var isDir = ObjCBool(false)
            return fm.fileExists(atPath: p, isDirectory: &isDir) && !isDir.boolValue
        }
        guard !valid.isEmpty else { return }   // 全部无效 → 整块跳过（Python `if paths:` 口径）
        var images: [DocXBuilder.ImageRef] = []
        for p in valid {
            let name = (p as NSString).lastPathComponent
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: p)),
                  let dims = ImageSize.sniff(data) else {
                // add_picture 失败 → 如实占位文本（Python except → run.text 口径）
                builder.add(.paragraph([DocXBuilder.Run("[图片加载失败: \(name)]")]))
                continue
            }
            images.append(.init(name: name, data: data,
                                pixelWidth: dims.width, pixelHeight: dims.height))
        }
        if !images.isEmpty {
            builder.add(.image(images: images, layout: layout, caption: caption,
                               widthCm: widthCm, heightCm: heightCm))
        }
    }

    // MARK: - _write_xlsx

    static func writeXlsx(target: String, content: [String: JSONValue]) throws -> Int {
        var sheetsArg: [JSONValue] = []
        if case .array(let arr) = content["sheets"] { sheetsArg = arr }
        var builder = XlsxBuilder()
        for (idx, sh) in sheetsArg.enumerated() {
            guard case .object(let o) = sh else { continue }
            let rawName = truthy(o["name"]) ? cleanText(o["name"]) : "Sheet\(idx + 1)"
            var name = String(rawName.prefix(31))
            if name.isEmpty { name = "Sheet\(idx + 1)" }
            var rows: [[XlsxBuilder.Cell]] = []
            if case .array(let arr) = o["rows"] {
                for row in arr {
                    guard case .array(let cells) = row else { continue }   // 偏差③
                    rows.append(cells.map { xlsxCell($0) })
                }
            }
            builder.addSheet(name: name, rows: rows)
        }
        try builder.save(to: URL(fileURLWithPath: target))
        let attrs = try FileManager.default.attributesOfItem(atPath: target)
        return Int(attrs[.size] as? Int64 ?? 0)
    }

    /// 单元格：纯数字字符串转数字（便于 Excel 计算）；int/float/bool 保型；null → 空。
    static func xlsxCell(_ v: JSONValue) -> XlsxBuilder.Cell {
        switch v {
        case .null: return .blank
        case .int(let i): return .number(Double(i))
        case .double(let d): return .number(d)
        case .bool(let b): return .bool(b)
        case .string(let str):
            let s = str.trimmingCharacters(in: .whitespacesAndNewlines)
            if pyIsDigit(String(s.drop(while: { $0 == "-" }))) {
                if let i = Int64(s) { return .number(Double(i)) }
            } else {
                let noDot = s.replacingOccurrences(of: ".", with: "", count: 1)
                if noDot != s, s.filter({ $0 == "." }).count == 1,
                   pyIsDigit(String(noDot.drop(while: { $0 == "-" }))),
                   let d = Double(s) {
                    return .number(d)
                }
            }
            return .string(str)
        case .array, .object:
            return .string(WFText.pyStr(v))   // 偏差：Python openpyxl 会抛错
        }
    }

    /// Python str.isdigit 的 ASCII 子集（空串 → false）。
    static func pyIsDigit(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber }
    }

    // MARK: - _write_pptx

    static func writePptx(target: String, content: [String: JSONValue]) throws -> Int {
        var slidesArg: [JSONValue] = []
        if case .array(let arr) = content["slides"] { slidesArg = arr }
        if slidesArg.isEmpty {
            let t = truthy(content["title"]) ? cleanText(content["title"]) : "演示文稿"
            slidesArg = [.object(["title": .string(t), "bullets": .array([])])]
        }
        var builder = PptxBuilder()
        for sl in slidesArg {
            guard case .object(let o) = sl else { continue }
            let title = truthy(o["title"]) ? cleanText(o["title"]) : ""
            var bullets: [String] = []
            if case .array(let arr) = o["bullets"] {
                bullets = arr.map { cleanText($0) }
            }
            let notes = truthy(o["notes"]) ? cleanText(o["notes"]) : ""
            builder.addSlide(PptxBuilder.Slide(title: title, bullets: bullets, notes: notes))
        }
        try builder.save(to: URL(fileURLWithPath: target))
        let attrs = try FileManager.default.attributesOfItem(atPath: target)
        return Int(attrs[.size] as? Int64 ?? 0)
    }
}

private extension String {
    func replacingOccurrences(of target: String, with replacement: String, count: Int) -> String {
        var result = self
        var remaining = count
        while remaining > 0, let range = result.range(of: target) {
            result.replaceSubrange(range, with: replacement)
            remaining -= 1
        }
        return result
    }
}
