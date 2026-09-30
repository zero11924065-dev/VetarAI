//
//  DocXBuilder.swift
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

/// 图片尺寸嗅探（P2-W3b）：PNG / JPEG / GIF / BMP 头部直读像素尺寸，
/// 供 docx image 块按比例推算未指定维度（对齐 python-docx add_picture 单维给定时
/// 另一维按原图宽高比自动推算的语义）。不依赖 ImageIO，纯字节解析。
public enum ImageSize {
    public static func sniff(_ data: Data) -> (width: Int, height: Int)? {
        let b = [UInt8](data)
        // PNG：8 字节签名 + IHDR 宽/高（big-endian，offset 16/20）
        if b.count > 24, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 {
            let w = Int(b[16]) << 24 | Int(b[17]) << 16 | Int(b[18]) << 8 | Int(b[19])
            let h = Int(b[20]) << 24 | Int(b[21]) << 16 | Int(b[22]) << 8 | Int(b[23])
            return (w, h)
        }
        // GIF：'GIF8' + 逻辑屏幕宽/高（little-endian，offset 6/8）
        if b.count > 10, b[0] == 0x47, b[1] == 0x49, b[2] == 0x46, b[3] == 0x38 {
            let w = Int(b[6]) | Int(b[7]) << 8
            let h = Int(b[8]) | Int(b[9]) << 8
            return (w, h)
        }
        // BMP：'BM' + 信息头宽/高（little-endian，offset 18/22）
        if b.count > 26, b[0] == 0x42, b[1] == 0x4D {
            let w = Int(b[18]) | Int(b[19]) << 8 | Int(b[20]) << 16 | Int(b[21]) << 24
            let h = Int(b[22]) | Int(b[23]) << 8 | Int(b[24]) << 16 | Int(b[25]) << 24
            return (abs(w), abs(h))
        }
        // JPEG：SOI 后逐段扫 SOF0-SOF15（排除 DHT/DAC/RST），段内 offset 5/7 为高/宽
        if b.count > 4, b[0] == 0xFF, b[1] == 0xD8 {
            var i = 2
            while i + 9 < b.count {
                guard b[i] == 0xFF else { i += 1; continue }
                let marker = b[i + 1]
                if marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7) {
                    i += 2; continue
                }
                let segLen = Int(b[i + 2]) << 8 | Int(b[i + 3])
                if segLen < 2 { return nil }
                if (marker >= 0xC0 && marker <= 0xCF) && marker != 0xC4 && marker != 0xC8 && marker != 0xCC {
                    let h = Int(b[i + 5]) << 8 | Int(b[i + 6])
                    let w = Int(b[i + 7]) << 8 | Int(b[i + 8])
                    return (w, h)
                }
                i += 2 + segLen
            }
        }
        return nil
    }
}

/// docx 生成器：段落 / 1-4 级标题 / 粗斜体 run / 项目符号 / 表格（首行表头加粗）/
/// 分页符 / 页脚页码（PAGE/NUMPAGES 域）/ A4 页面 / 中文宋体+西文 Times New Roman。
/// 对标 sidecar doc_writer.py 的元素契约。
///
/// P2-W3b 扩展（doc_writer.py 0.4.20 #14 参考格式 + 0.4.12 A7 图片块）：
///   · `style`：Normal 字体（eastAsia/ascii）与字号、页面尺寸边距、正文段落
///     对齐/首行缩进/行距（倍数优先于固定磅）——逐项回退默认，与 Python 同口径；
///   · `pageNumberFormat`：页脚模板 {p}/{t} 切分（默认「第{p}页 共{t}页」）；
///   · `.image` 块：single 居中 / grid 3 列表格承载；widthCm/heightCm 单维按比例
///     推算（两者都缺 → width=13cm 默认，向后兼容口径）。
public struct DocXBuilder {

    /// 一个 run：文本 + 粗/斜体开关。
    public struct Run {
        public let text: String
        public let bold: Bool
        public let italic: Bool
        public init(_ text: String, bold: Bool = false, italic: Bool = false) {
            self.text = text; self.bold = bold; self.italic = italic
        }
    }

    /// 参考格式配置（extract_docx_style 的消费面；全部可选、逐项回退默认）。
    public struct StyleConfig {
        public var normalEastAsiaFont: String = "宋体"
        public var normalAsciiFont: String = "Times New Roman"
        /// 正文字号（磅）；≤0 视为未指定 → 12pt（小四）。
        public var normalSizePt: Double = 12.0
        public var pageWidthCm: Double = 21.0
        public var pageHeightCm: Double = 29.7
        public var marginTopCm: Double = 2.54
        public var marginBottomCm: Double = 2.54
        public var marginLeftCm: Double = 3.18
        public var marginRightCm: Double = 3.18
        /// 正文段落对齐（WD_ALIGN_PARAGRAPH 0-4）；nil 不动。
        public var bodyAlignValue: Int?
        /// 正文段落首行缩进 cm；>0 才套用。
        public var bodyFirstLineIndentCm: Double?
        /// 倍数行距（与固定磅二选一，倍数优先）。
        public var bodyLineSpacingMultiple: Double?
        /// 固定行距（磅）。
        public var bodyLineSpacingPt: Double?
        public init() {}
    }

    /// 图片引用：原始字节 + 像素尺寸（调用方经 ImageSize.sniff 取得）。
    public struct ImageRef {
        public let name: String
        public let data: Data
        public let pixelWidth: Int
        public let pixelHeight: Int
        public init(name: String, data: Data, pixelWidth: Int, pixelHeight: Int) {
            self.name = name; self.data = data
            self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        }
        /// 未指定维度按像素宽高比推算后的 EMU 尺寸（1cm = 360000 EMU）。
        func emuSize(widthCm: Double?, heightCm: Double?) -> (cx: Int, cy: Int) {
            if let w = widthCm, let h = heightCm {
                return (Int((w * 360000).rounded()), Int((h * 360000).rounded()))
            }
            if let w = widthCm {
                let h = w * Double(pixelHeight) / Double(max(pixelWidth, 1))
                return (Int((w * 360000).rounded()), Int((h * 360000).rounded()))
            }
            if let h = heightCm {
                let w = h * Double(pixelWidth) / Double(max(pixelHeight, 1))
                return (Int((w * 360000).rounded()), Int((h * 360000).rounded()))
            }
            // 两者都缺 → width 13.0 默认（python 口径：A4 正文宽，保持原图比例）
            let w = 13.0
            let h = w * Double(pixelHeight) / Double(max(pixelWidth, 1))
            return (Int((w * 360000).rounded()), Int((h * 360000).rounded()))
        }
    }

    public enum ImageLayout { case single, grid }

    public enum Block {
        case title(String)
        case heading(level: Int, text: String)
        case paragraph([Run])
        case bullets([String])
        case table(rows: [[String]])          // 首行视为表头
        case pageBreak
        /// 图片块（paths 已过滤为存在的文件；caption 可空串）。
        case image(images: [ImageRef], layout: ImageLayout, caption: String,
                   widthCm: Double?, heightCm: Double?)
    }

    private var blocks: [Block] = []
    public var pageNumberFooter: Bool = true
    /// 页脚模板（{p}=当前页 {t}=总页数；对齐 _add_page_number_footer 的 fmt 切分）。
    public var pageNumberFormat: String = "第{p}页 共{t}页"
    public var style = StyleConfig()

    public init() {}

    public mutating func add(_ block: Block) { blocks.append(block) }
    public mutating func addParagraph(_ text: String) {
        blocks.append(.paragraph([Run(text)]))
    }

    // MARK: - 打包

    private struct MediaItem {
        let partName: String   // word/media/imageN.ext
        let ext: String
        let data: Data
    }

    /// 收集全部图片（按出现序编号），块内引用与媒体条目一一对应。
    private func collectMedia() -> [MediaItem] {
        var items: [MediaItem] = []
        for b in blocks {
            if case .image(let images, _, _, _, _) = b {
                for img in images {
                    let ext = (img.name as NSString).pathExtension.lowercased()
                    let safeExt = ext.isEmpty ? "png" : ext
                    items.append(MediaItem(
                        partName: "word/media/image\(items.count + 1).\(safeExt)",
                        ext: safeExt, data: img.data))
                }
            }
        }
        return items
    }

    public func data() throws -> Data {
        let media = collectMedia()
        var zip = ZipWriter()
        try zip.addFile(name: "[Content_Types].xml",
                        data: contentTypes(withFooter: pageNumberFooter, media: media))
        try zip.addFile(name: "_rels/.rels", data: Self.rootRels)
        try zip.addFile(name: "word/document.xml", data: documentXML())
        try zip.addFile(name: "word/styles.xml", data: stylesXML())
        try zip.addFile(name: "word/numbering.xml", data: Self.numberingXML)
        if pageNumberFooter {
            try zip.addFile(name: "word/footer1.xml", data: footerXML())
        }
        try zip.addFile(name: "word/_rels/document.xml.rels",
                        data: documentRels(withFooter: pageNumberFooter, media: media))
        for m in media {
            try zip.addFile(name: m.partName, data: m.data)
        }
        return zip.finalize()
    }

    public func save(to url: URL) throws {
        try data().write(to: url, options: .atomic)
    }

    // MARK: - document.xml

    private func documentXML() -> Data {
        var x = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><w:body>

        """
        var mediaIndex = 0
        for b in blocks {
            switch b {
            case .title(let text):
                x += paragraphXML(style: "Title", runs: [Run(text)])
            case .heading(let level, let text):
                let lv = min(max(level, 1), 4)
                x += paragraphXML(style: "Heading\(lv)", runs: [Run(text)])
            case .paragraph(let runs):
                // #14：正文段落套用参考格式（对齐/首行缩进/行距，逐项判空）
                x += paragraphXML(style: nil, runs: runs, bodyFmt: bodyParagraphPr())
            case .bullets(let items):
                for it in items {
                    x += paragraphXML(style: "ListParagraph", runs: [Run(it)], numPr: true)
                }
            case .table(let rows):
                x += tableXML(rows)
            case .pageBreak:
                x += "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>"
            case .image(let images, let layout, let caption, let w, let h):
                x += imageBlockXML(images, layout: layout, caption: caption,
                                   widthCm: w, heightCm: h, mediaStartIndex: &mediaIndex)
            }
        }
        // sectPr：页面尺寸边距（参考文件逐项回退 A4 默认）+ 页脚引用
        let pgW = twips(style.pageWidthCm), pgH = twips(style.pageHeightCm)
        let mT = twips(style.marginTopCm), mB = twips(style.marginBottomCm)
        let mL = twips(style.marginLeftCm), mR = twips(style.marginRightCm)
        x += "<w:sectPr>"
        if pageNumberFooter {
            x += "<w:footerReference w:type=\"default\" r:id=\"rId3\"/>"
        }
        x += """
        <w:pgSz w:w="\(pgW)" w:h="\(pgH)"/>
        <w:pgMar w:top="\(mT)" w:right="\(mR)" w:bottom="\(mB)" w:left="\(mL)" w:header="720" w:footer="720" w:gutter="0"/>
        </w:sectPr></w:body></w:document>
        """
        return Data(x.utf8)
    }

    /// cm → twips（1cm = 360000 EMU = 566.929 twips；python-docx Length.twips 等价）。
    private func twips(_ cm: Double) -> Int {
        Int((cm * 360000.0 / 635.0).rounded())
    }

    /// 正文段落 pPr 片段（对齐/首行缩进/行距；行距倍数优先于固定磅——_apply_body_fmt 口径）。
    private func bodyParagraphPr() -> String {
        var p = ""
        if let av = style.bodyAlignValue {
            let jc = ["left", "center", "right", "both", "distribute"]
            if av >= 0 && av < jc.count { p += "<w:jc w:val=\"\(jc[av])\"/>" }
        }
        if let fli = style.bodyFirstLineIndentCm, fli > 0 {
            p += "<w:ind w:firstLine=\"\(twips(fli))\"/>"
        }
        if let mult = style.bodyLineSpacingMultiple, mult > 0 {
            p += "<w:spacing w:line=\"\(Int((mult * 240).rounded()))\" w:lineRule=\"auto\"/>"
        } else if let pt = style.bodyLineSpacingPt, pt > 0 {
            p += "<w:spacing w:line=\"\(Int((pt * 20).rounded()))\" w:lineRule=\"exact\"/>"
        }
        return p
    }

    private func paragraphXML(style styleName: String?, runs: [Run], numPr: Bool = false,
                              bodyFmt: String = "") -> String {
        var p = "<w:p><w:pPr>"
        if let styleName { p += "<w:pStyle w:val=\"\(styleName)\"/>" }
        if numPr { p += "<w:numPr><w:ilvl w:val=\"0\"/><w:numId w:val=\"1\"/></w:numPr>" }
        p += bodyFmt
        p += "</w:pPr>"
        for r in runs {
            p += "<w:r>"
            if r.bold || r.italic {
                p += "<w:rPr>"
                if r.bold { p += "<w:b/>" }
                if r.italic { p += "<w:i/>" }
                p += "</w:rPr>"
            }
            p += "<w:t xml:space=\"preserve\">\(XMLEscaping.escapeText(r.text))</w:t></w:r>"
        }
        return p + "</w:p>"
    }

    // MARK: - 图片块（0.4.6+ / 0.4.12 A7）

    private func imageBlockXML(_ images: [ImageRef], layout: ImageLayout, caption: String,
                               widthCm: Double?, heightCm: Double?,
                               mediaStartIndex: inout Int) -> String {
        var x = ""
        // grid 固定列宽 4.4cm（(21-6.36)/3≈4.4，3列适配A4左右边距）
        let effW: Double? = (layout == .grid) ? 4.4 : widthCm
        let effH: Double? = heightCm
        if layout == .grid {
            // 一行 3 列：表格承载，每格一图
            var idx = 0
            while idx < images.count {
                let chunk = Array(images[idx..<min(idx + 3, images.count)])
                x += "<w:tbl><w:tblPr><w:tblStyle w:val=\"TableGrid\"/><w:tblW w:w=\"0\" w:type=\"auto\"/></w:tblPr><w:tblGrid>"
                for _ in chunk { x += "<w:gridCol w:w=\"\(twips(4.4))\"/>" }
                x += "</w:tblGrid><w:tr>"
                for img in chunk {
                    mediaStartIndex += 1
                    let (cx, cy) = img.emuSize(widthCm: effW, heightCm: effH)
                    x += "<w:tc><w:tcPr><w:tcW w:w=\"\(twips(4.4))\" w:type=\"dxa\"/></w:tcPr>"
                    x += "<w:p><w:pPr><w:jc w:val=\"center\"/></w:pPr>"
                    x += drawingRun(rid: "rId\(100 + mediaStartIndex - 1)", cx: cx, cy: cy,
                                    docPrId: mediaStartIndex, name: img.name)
                    x += "</w:p></w:tc>"
                }
                x += "</w:tr></w:tbl>"
                idx += 3
            }
        } else {
            for img in images {
                mediaStartIndex += 1
                let (cx, cy) = img.emuSize(widthCm: effW, heightCm: effH)
                x += "<w:p><w:pPr><w:jc w:val=\"center\"/></w:pPr>"
                x += drawingRun(rid: "rId\(100 + mediaStartIndex - 1)", cx: cx, cy: cy,
                                docPrId: mediaStartIndex, name: img.name)
                x += "</w:p>"
            }
        }
        if !caption.isEmpty {
            x += "<w:p><w:pPr><w:jc w:val=\"center\"/></w:pPr><w:r>"
            x += "<w:t xml:space=\"preserve\">\(XMLEscaping.escapeText(caption))</w:t></w:r></w:p>"
        }
        return x
    }

    private func drawingRun(rid: String, cx: Int, cy: Int, docPrId: Int, name: String) -> String {
        let escName = XMLEscaping.escapeAttribute(name)
        return """
        <w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0" \
        xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">\
        <wp:extent cx="\(cx)" cy="\(cy)"/>\
        <wp:docPr id="\(docPrId)" name="\(escName)"/>\
        <a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">\
        <a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">\
        <pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">\
        <pic:nvPicPr><pic:cNvPr id="\(docPrId)" name="\(escName)"/><pic:cNvPicPr/></pic:nvPicPr>\
        <pic:blipFill><a:blip r:embed="\(rid)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
        <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm>\
        <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>\
        </pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>
        """
    }

    private func tableXML(_ rows: [[String]]) -> String {
        guard let first = rows.first, !first.isEmpty else { return "" }
        let ncols = rows.map(\.count).max() ?? 0
        var t = """
        <w:tbl><w:tblPr><w:tblStyle w:val="TableGrid"/><w:tblW w:w="0" w:type="auto"/>\
        <w:tblBorders><w:top w:val="single" w:sz="4" w:space="0" w:color="auto"/>\
        <w:left w:val="single" w:sz="4" w:space="0" w:color="auto"/>\
        <w:bottom w:val="single" w:sz="4" w:space="0" w:color="auto"/>\
        <w:right w:val="single" w:sz="4" w:space="0" w:color="auto"/>\
        <w:insideH w:val="single" w:sz="4" w:space="0" w:color="auto"/>\
        <w:insideV w:val="single" w:sz="4" w:space="0" w:color="auto"/></w:tblBorders></w:tblPr><w:tblGrid>

        """
        for _ in 0..<ncols { t += "<w:gridCol w:w=\"2160\"/>" }
        t += "</w:tblGrid>"
        for (i, row) in rows.enumerated() {
            let isHeader = i == 0
            t += "<w:tr>"
            if isHeader { t += "<w:trPr><w:tblHeader/></w:trPr>" }
            for j in 0..<ncols {
                let cell = j < row.count ? row[j] : ""
                t += "<w:tc><w:tcPr><w:tcW w:w=\"2160\" w:type=\"dxa\"/></w:tcPr>"
                t += paragraphXML(style: nil,
                                  runs: [Run(cell, bold: isHeader)])
                t += "</w:tc>"
            }
            t += "</w:tr>"
        }
        return t + "</w:tbl>"
    }

    // MARK: - 静态部件

    private func contentTypes(withFooter: Bool, media: [MediaItem]) -> Data {
        var x = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>
        """
        // 图片扩展名 → MIME（docx 常用族）
        let mime: [String: String] = ["png": "image/png", "jpg": "image/jpeg",
                                      "jpeg": "image/jpeg", "gif": "image/gif",
                                      "bmp": "image/bmp", "tiff": "image/tiff"]
        var declared: Set<String> = []
        for m in media where !declared.contains(m.ext) {
            declared.insert(m.ext)
            x += "<Default Extension=\"\(m.ext)\" ContentType=\"\(mime[m.ext] ?? "image/png")\"/>"
        }
        x += "<Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>"
        x += "<Override PartName=\"/word/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml\"/>"
        x += "<Override PartName=\"/word/numbering.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml\"/>"
        if withFooter {
            x += "<Override PartName=\"/word/footer1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml\"/>"
        }
        x += "</Types>"
        return Data(x.utf8)
    }

    private static let rootRels = Data("""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
    </Relationships>
    """.utf8)

    private func documentRels(withFooter: Bool, media: [MediaItem]) -> Data {
        var x = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>
        """
        if withFooter {
            x += "<Relationship Id=\"rId3\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer\" Target=\"footer1.xml\"/>"
        }
        for (i, m) in media.enumerated() {
            let target = String(m.partName.dropFirst("word/".count))
            x += "<Relationship Id=\"rId\(100 + i)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"\(target)\"/>"
        }
        x += "</Relationships>"
        return Data(x.utf8)
    }

    /// Normal：西文 Times New Roman / 中文宋体 / 12pt（小四）；含 1-4 级标题、Title、ListParagraph、TableGrid。
    /// P2-W3b：Normal 字体/字号按 style 配置（参考文件 extract_docx_style → doc_writer 套用口径）。
    private func stylesXML() -> Data {
        let szVal = Int((style.normalSizePt * 2).rounded())
        let x = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/>\
        <w:rPr><w:rFonts w:ascii="\(XMLEscaping.escapeAttribute(style.normalAsciiFont))" w:hAnsi="\(XMLEscaping.escapeAttribute(style.normalAsciiFont))" w:eastAsia="\(XMLEscaping.escapeAttribute(style.normalEastAsiaFont))"/>\
        <w:sz w:val="\(szVal)"/><w:szCs w:val="\(szVal)"/></w:rPr></w:style>\
        <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/>\
        <w:pPr><w:jc w:val="center"/></w:pPr>\
        <w:rPr><w:b/><w:rFonts w:ascii="Times New Roman" w:hAnsi="Times New Roman" w:eastAsia="黑体"/>\
        <w:sz w:val="44"/></w:rPr></w:style>\
        <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/>\
        <w:pPr><w:outlineLvl w:val="0"/></w:pPr>\
        <w:rPr><w:b/><w:rFonts w:eastAsia="黑体"/><w:sz w:val="32"/></w:rPr></w:style>\
        <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/>\
        <w:pPr><w:outlineLvl w:val="1"/></w:pPr>\
        <w:rPr><w:b/><w:rFonts w:eastAsia="黑体"/><w:sz w:val="28"/></w:rPr></w:style>\
        <w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/><w:basedOn w:val="Normal"/>\
        <w:pPr><w:outlineLvl w:val="2"/></w:pPr>\
        <w:rPr><w:b/><w:rFonts w:eastAsia="黑体"/><w:sz w:val="26"/></w:rPr></w:style>\
        <w:style w:type="paragraph" w:styleId="Heading4"><w:name w:val="heading 4"/><w:basedOn w:val="Normal"/>\
        <w:pPr><w:outlineLvl w:val="3"/></w:pPr>\
        <w:rPr><w:b/><w:rFonts w:eastAsia="黑体"/><w:sz w:val="24"/></w:rPr></w:style>\
        <w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/>\
        <w:basedOn w:val="Normal"/><w:pPr><w:ind w:left="720"/></w:pPr></w:style>\
        <w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/>\
        <w:tblPr><w:tblBorders><w:top w:val="single" w:sz="4" w:space="0" w:color="auto"/>\
        <w:left w:val="single" w:sz="4" w:space="0" w:color="auto"/>\
        <w:bottom w:val="single" w:sz="4" w:space="0" w:color="auto"/>\
        <w:right w:val="single" w:sz="4" w:space="0" w:color="auto"/>\
        <w:insideH w:val="single" w:sz="4" w:space="0" w:color="auto"/>\
        <w:insideV w:val="single" w:sz="4" w:space="0" w:color="auto"/></w:tblBorders></w:tblPr></w:style>\
        </w:styles>
        """
        return Data(x.utf8)
    }

    /// 一个无序列表编号定义（•）。
    private static let numberingXML = Data("""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
    <w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:start w:val="1"/>\
    <w:numFmt w:val="bullet"/><w:lvlText w:val="•"/><w:lvlJc w:val="left"/>\
    <w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr></w:lvl></w:abstractNum>\
    <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num></w:numbering>
    """.utf8)

    /// 页脚：居中，按 pageNumberFormat 模板切分 {p}/NUMPAGES 域（_add_page_number_footer 口径）。
    /// 字面文本 run 带 sz 18（9pt 页脚小字）。
    private func footerXML() -> Data {
        var runs = ""
        var rest = Substring(pageNumberFormat)
        func textRun(_ t: String) -> String {
            "<w:r><w:rPr><w:sz w:val=\"18\"/></w:rPr><w:t xml:space=\"preserve\">\(XMLEscaping.escapeText(t))</w:t></w:r>"
        }
        func fieldRun(_ instr: String) -> String {
            "<w:r><w:fldChar w:fldCharType=\"begin\"/></w:r>"
                + "<w:r><w:instrText xml:space=\"preserve\">\(instr)</w:instrText></w:r>"
                + "<w:r><w:fldChar w:fldCharType=\"end\"/></w:r>"
        }
        while let r = rest.range(of: #"\{(p|t)\}"#, options: .regularExpression) {
            let literal = String(rest[rest.startIndex..<r.lowerBound])
            if !literal.isEmpty { runs += textRun(literal) }
            runs += fieldRun(rest[r].contains("p") ? "PAGE" : "NUMPAGES")
            rest = rest[r.upperBound...]
        }
        if !rest.isEmpty { runs += textRun(String(rest)) }
        let x = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:ftr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
        <w:p><w:pPr><w:jc w:val="center"/></w:pPr>\(runs)</w:p></w:ftr>
        """
        return Data(x.utf8)
    }
}
