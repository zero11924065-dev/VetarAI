//
//  DocXReader.swift
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

import Foundation

/// docx 结构化读取（P2-W3b）：对齐 doc_reader.py 经 python-docx 消费的语义面——
///   · 流序 blocks（w:p / w:tbl 按 body 子序，表格不后移）
///   · 段落：文本 / 样式名（styles.xml styleId→name 解析）/ 首 run 字体（ascii+eastAsia、
///     半磅字号→pt、bold 三态）/ 直接对齐（w:jc→WD_ALIGN_PARAGRAPH 0-4）/
///     首行缩进（twips→cm）/ 行距（auto=倍数、exact/atLeast=磅）
///   · 表格：行×单元格文本（单元格多段 \n 连接，对齐 _Cell.text）
///   · 页面：body sectPr 的 pgSz/pgMar（twips→cm，未换算前保留 nil 语义）
///   · 内嵌图片：word/media/* 条目数与解压前声明大小
/// 不做样式继承解析（python-docx 的 run.font.* 同样只读 run 直接 rPr，口径一致）。
public enum DocXReaderError: Error {
    case missingPart(String)
    case badXML(String)
}

public struct DocXRunProps: Equatable {
    /// w:rFonts/@w:ascii（python-docx font.name 的映射源）。
    public var fontAscii: String?
    /// w:rFonts/@w:eastAsia（中文字体挂载点；python-docx font.name 不覆盖，doc_reader 正则补取）。
    public var fontEastAsia: String?
    /// w:sz/@w:val 半磅 → 磅。
    public var sizePt: Double?
    /// 三态：w:b 存在且非 off → true；显式 off → false；缺省 → nil。
    public var bold: Bool?

    /// doc_reader._docx_run_font 的合并名口径：ea 优先，ascii 与 ea 相异时 "ascii/ea"。
    public var combinedFontName: String? {
        var name = fontAscii
        if let ea = fontEastAsia, !ea.isEmpty {
            if name == nil || name == ea { name = ea } else { name = "\(name!)/\(ea)" }
        }
        return name
    }
}

public struct DocXParagraph {
    public var text: String = ""
    /// 样式名（styles.xml 解析后）；未知样式 → ""（对齐 python-docx 异常兜底）。
    public var styleName: String = ""
    public var firstRun: DocXRunProps?
    /// WD_ALIGN_PARAGRAPH 0-4；无直接 jc → nil。
    public var alignmentValue: Int?
    public var firstLineIndentCm: Double?
    /// lineRule=auto（或缺省）→ 倍数；exact/atLeast → nil。
    public var lineSpacingMultiple: Double?
    /// lineRule=exact/atLeast → 磅；否则 nil。
    public var lineSpacingPt: Double?
}

public struct DocXTable {
    /// rows[r][c]：单元格内多段文本以 \n 连接（python-docx _Cell.text 口径）。
    public var rows: [[String]] = []
}

public enum DocXBlock {
    case paragraph(DocXParagraph)
    case table(DocXTable)
}

public struct DocXPageSetup {
    public var widthCm: Double?
    public var heightCm: Double?
    public var topCm: Double?
    public var bottomCm: Double?
    public var leftCm: Double?
    public var rightCm: Double?
}

public struct DocXDocument {
    public var blocks: [DocXBlock] = []
    /// 顶层段落（d.paragraphs 口径：仅 body 直接子级，不含表格单元格内段落）。
    public var paragraphs: [DocXParagraph] = []
    /// 顶层表格数（d.tables 口径）。
    public var tableCount: Int = 0
    public var page: DocXPageSetup?
    public var mediaImageCount: Int = 0
    public var mediaImageBytes: Int = 0
}

public enum DocXReader {

    /// twips → cm（python-docx Length.cm：EMU/360000；1 twip = 635 EMU）。
    static func twipsToCm(_ twips: Double) -> Double { twips * 635.0 / 360000.0 }
    /// twips → pt（1 pt = 20 twips）。
    static func twipsToPt(_ twips: Double) -> Double { twips / 20.0 }

    public static func load(data: Data) throws -> DocXDocument {
        let zip = try ZipArchiveReader(data: data)   // 坏 zip 在此抛出（调用方映射 corrupt）
        let docData = try zip.data(named: "word/document.xml", from: data)
        let root: XMLNode
        do {
            root = try XMLMiniDOM.parse(docData)
        } catch {
            throw DocXReaderError.badXML("word/document.xml")
        }
        // styles.xml：styleId → 显示名（缺件按空映射，不致命）
        var styleNames: [String: String] = [:]
        if let stylesData = try? zip.data(named: "word/styles.xml", from: data),
           let stylesRoot = try? XMLMiniDOM.parse(stylesData) {
            for st in stylesRoot.childrenNamed("w:style") {
                if let sid = st.attributes["w:styleId"],
                   let nm = st.child("w:name")?.attributes["w:val"] {
                    styleNames[sid] = nm
                }
            }
        }

        var doc = DocXDocument()
        // 内嵌图片统计（_docx_image_count 口径：word/media/ 前缀条目数 + 声明大小）
        for e in zip.entries where e.name.hasPrefix("word/media/") {
            doc.mediaImageCount += 1
            doc.mediaImageBytes += Int(e.uncompressedSize)
        }

        guard let body = root.child("w:body") else {
            throw DocXReaderError.badXML("w:body")
        }
        for child in body.children {
            switch child.name {
            case "w:p":
                let p = parseParagraph(child, styleNames: styleNames)
                doc.blocks.append(.paragraph(p))
                doc.paragraphs.append(p)
            case "w:tbl":
                let t = parseTable(child)
                doc.blocks.append(.table(t))
                doc.tableCount += 1
            case "w:sectPr":
                doc.page = parseSectPr(child)
            default:
                continue
            }
        }
        return doc
    }

    // MARK: - 段落

    static func parseParagraph(_ node: XMLNode, styleNames: [String: String]) -> DocXParagraph {
        var p = DocXParagraph()
        p.text = paragraphText(node)
        let pPr = node.child("w:pPr")
        if let styleId = pPr?.child("w:pStyle")?.attributes["w:val"] {
            p.styleName = styleNames[styleId] ?? ""
        }
        // 首 run 的直接 rPr（python-docx 不做样式继承，口径一致）
        if let firstR = node.childrenNamed("w:r").first {
            p.firstRun = parseRunProps(firstR.child("w:rPr"))
        }
        if let jc = pPr?.child("w:jc")?.attributes["w:val"] {
            p.alignmentValue = alignmentForJc(jc)
        }
        if let ind = pPr?.child("w:ind"),
           let fl = ind.attributes["w:firstLine"], let tw = Double(fl) {
            p.firstLineIndentCm = twipsToCm(tw)
        }
        if let sp = pPr?.child("w:spacing"),
           let line = sp.attributes["w:line"], let lv = Double(line) {
            let rule = sp.attributes["w:lineRule"] ?? "auto"
            if rule == "exact" || rule == "atLeast" {
                p.lineSpacingPt = twipsToPt(lv)
            } else {
                p.lineSpacingMultiple = lv / 240.0
            }
        }
        return p
    }

    /// python-docx Paragraph.text 口径：后代 w:t 文本 + w:tab→\t + w:br/w:cr→\n，按文档序。
    static func paragraphText(_ node: XMLNode) -> String {
        var out = ""
        func walk(_ n: XMLNode) {
            switch n.name {
            case "w:t": out += n.text
            case "w:tab": out += "\t"
            case "w:br", "w:cr": out += "\n"
            default: break
            }
            for c in n.children { walk(c) }
        }
        for c in node.children where c.name != "w:pPr" { walk(c) }
        return out
    }

    static func parseRunProps(_ rPr: XMLNode?) -> DocXRunProps {
        var rp = DocXRunProps()
        guard let rPr else { return rp }
        if let rf = rPr.child("w:rFonts") {
            rp.fontAscii = rf.attributes["w:ascii"]
            rp.fontEastAsia = rf.attributes["w:eastAsia"]
        }
        if let sz = rPr.child("w:sz")?.attributes["w:val"], let v = Double(sz) {
            rp.sizePt = v / 2.0
        }
        if let b = rPr.child("w:b") {
            let val = (b.attributes["w:val"] ?? "true").lowercased()
            rp.bold = !(val == "false" || val == "0" || val == "off")
        }
        return rp
    }

    /// w:jc → WD_ALIGN_PARAGRAPH（python-docx ST_Jc 映射的常用子集）。
    static func alignmentForJc(_ jc: String) -> Int? {
        switch jc {
        case "left", "start": return 0
        case "center": return 1
        case "right", "end": return 2
        case "both": return 3
        case "distribute": return 4
        default: return nil
        }
    }

    // MARK: - 表格

    static func parseTable(_ node: XMLNode) -> DocXTable {
        var t = DocXTable()
        for tr in node.childrenNamed("w:tr") {
            var row: [String] = []
            for tc in tr.childrenNamed("w:tc") {
                // _Cell.text：单元格内段落文本 \n 连接
                let parts = tc.childrenNamed("w:p").map { paragraphText($0) }
                row.append(parts.joined(separator: "\n"))
            }
            t.rows.append(row)
        }
        return t
    }

    // MARK: - 页面

    static func parseSectPr(_ node: XMLNode) -> DocXPageSetup {
        var page = DocXPageSetup()
        if let sz = node.child("w:pgSz") {
            if let w = sz.attributes["w:w"], let v = Double(w) { page.widthCm = twipsToCm(v) }
            if let h = sz.attributes["w:h"], let v = Double(h) { page.heightCm = twipsToCm(v) }
        }
        if let mar = node.child("w:pgMar") {
            if let v = mar.attributes["w:top"].flatMap(Double.init) { page.topCm = twipsToCm(v) }
            if let v = mar.attributes["w:bottom"].flatMap(Double.init) { page.bottomCm = twipsToCm(v) }
            if let v = mar.attributes["w:left"].flatMap(Double.init) { page.leftCm = twipsToCm(v) }
            if let v = mar.attributes["w:right"].flatMap(Double.init) { page.rightCm = twipsToCm(v) }
        }
        return page
    }
}
