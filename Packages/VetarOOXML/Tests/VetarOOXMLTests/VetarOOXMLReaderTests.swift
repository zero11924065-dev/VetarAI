//
//  VetarOOXMLReaderTests.swift
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
import XCTest
@testable import VetarOOXML

/// P2-W3b：VetarOOXML 读取面与写入扩展的单测。
/// 覆盖：ZIP inflate 数据提取（含 CRC 校验）、XMLMiniDOM、DocXReader（流序/字体/对齐/
/// 缩进/行距/页面/媒体统计）、XlsxReader（双视图公式/共享串/类型）、PptxReader
/// （标题/正文/备注）、DocXBuilder StyleConfig 与 image 块、PptxBuilder notes。
final class VetarOOXMLReaderTests: XCTestCase {

    // MARK: - ZIP 数据提取

    func testZipDataExtractionRoundTrip() throws {
        var zip = ZipWriter()
        let a = Data("document 内容 你好".utf8)
        let b = Data(String(repeating: "重复文本 compress me ", count: 2000).utf8)
        try zip.addFile(name: "word/document.xml", data: a)
        try zip.addFile(name: "xl/sharedStrings.xml", data: b)
        let data = zip.finalize()
        let reader = try ZipArchiveReader(data: data)
        XCTAssertEqual(try reader.data(named: "word/document.xml", from: data), a)
        XCTAssertEqual(try reader.data(named: "xl/sharedStrings.xml", from: data), b)
        XCTAssertThrowsError(try reader.data(named: "不存在.xml", from: data)) { e in
            guard case ZipExtractError.entryNotFound = e else { return XCTFail("\(e)") }
        }
    }

    func testZipExtractionRejectsGarbage() {
        let garbage = Data("这不是 zip 文件，只是一段中文文本".utf8)
        XCTAssertThrowsError(try ZipArchiveReader(data: garbage))
    }

    // MARK: - XMLMiniDOM

    func testXMLMiniDOM() throws {
        let root = try XMLMiniDOM.parse("""
        <?xml version="1.0"?><w:document><w:body>\
        <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>标题 &amp; 实体</w:t></w:r></w:p>\
        <w:tbl><w:tr><w:tc><w:p><w:r><w:t>格1</w:t></w:r></w:p></w:tc></w:tr></w:tbl>\
        </w:body></w:document>
        """)
        XCTAssertEqual(root.name, "w:document")
        let body = root.child("w:body")
        XCTAssertEqual(body?.children.count, 2)
        let p = body?.child("w:p")
        XCTAssertEqual(p?.child("w:pPr")?.child("w:pStyle")?.attributes["w:val"], "Heading1")
        XCTAssertEqual(p?.descendants("w:t").first?.text, "标题 & 实体")
        XCTAssertEqual(body?.child("w:tbl")?.descendants("w:t").first?.text, "格1")
    }

    // MARK: - DocXReader

    /// 手工夹具：标题段（居中 22pt 加粗 仿宋）+ 正文段（两端对齐 14pt 首行缩进 0.99cm）+
    /// 引导段 + 表格 + 结尾段；A4 21×29.7；页边距 2.54/3.18。
    private func makeDocxFixture(cjkFont: String = "仿宋") throws -> Data {
        func rpr(_ font: String, _ szHalf: Int, _ bold: Bool) -> String {
            "<w:rPr><w:rFonts w:ascii=\"Times New Roman\" w:hAnsi=\"Times New Roman\" w:eastAsia=\"\(font)\"/>"
                + (bold ? "<w:b/>" : "")
                + "<w:sz w:val=\"\(szHalf)\"/></w:rPr>"
        }
        let doc = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>
        <w:p><w:pPr><w:jc w:val="center"/></w:pPr><w:r>\(rpr(cjkFont, 44, true))<w:t>民事起诉状</w:t></w:r></w:p>
        <w:p><w:pPr><w:jc w:val="both"/><w:ind w:firstLine="561"/></w:pPr><w:r>\(rpr(cjkFont, 28, false))<w:t>原告：王永斌，男，汉族，住重庆市渝北区。</w:t></w:r></w:p>
        <w:p><w:r><w:t>诉讼请求如下表所列：</w:t></w:r></w:p>
        <w:tbl><w:tr><w:tc><w:p><w:r><w:t>请求事项</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>金额</w:t></w:r></w:p></w:tc></w:tr>
        <w:tr><w:tc><w:p><w:r><w:t>返还借款本金</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>239900元</w:t></w:r></w:p></w:tc></w:tr>
        <w:tr><w:tc><w:p><w:r><w:t>支付资金占用损失</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>5972元</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
        <w:p><w:r><w:t>事实与理由：被告拖欠设备意向金，经多次催告拒不返还。</w:t></w:r></w:p>
        <w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1803" w:bottom="1440" w:left="1803" w:header="720" w:footer="720" w:gutter="0"/></w:sectPr>
        </w:body></w:document>
        """
        var zip = ZipWriter()
        try zip.addFile(name: "word/document.xml", data: Data(doc.utf8))
        return zip.finalize()
    }

    func testDocXReaderFlowOrderAndProps() throws {
        let data = try makeDocxFixture()
        let doc = try DocXReader.load(data: data)
        // 流序：p p p tbl p（表格不后移）
        XCTAssertEqual(doc.blocks.count, 5)
        guard case .paragraph(let p0) = doc.blocks[0],
              case .paragraph(let p1) = doc.blocks[1],
              case .table(let tbl) = doc.blocks[3],
              case .paragraph = doc.blocks[4] else {
            return XCTFail("blocks 流序不符: \(doc.blocks)")
        }
        XCTAssertEqual(p0.text, "民事起诉状")
        XCTAssertEqual(p0.alignmentValue, 1)            // center
        XCTAssertEqual(p0.firstRun?.combinedFontName, "Times New Roman/仿宋")
        XCTAssertEqual(p0.firstRun?.sizePt, 22.0)
        XCTAssertEqual(p0.firstRun?.bold, true)
        XCTAssertEqual(p1.alignmentValue, 3)            // both → JUSTIFY
        XCTAssertEqual(p1.firstLineIndentCm ?? 0, 0.99, accuracy: 0.01)
        XCTAssertEqual(p1.firstRun?.sizePt, 14.0)
        XCTAssertEqual(tbl.rows.count, 3)
        XCTAssertEqual(tbl.rows[1], ["返还借款本金", "239900元"])
        XCTAssertEqual(doc.tableCount, 1)
        XCTAssertEqual(doc.paragraphs.count, 4)
        // 页面：twips → cm
        XCTAssertEqual(doc.page?.widthCm ?? 0, 21.0, accuracy: 0.01)
        XCTAssertEqual(doc.page?.heightCm ?? 0, 29.7, accuracy: 0.01)
        XCTAssertEqual(doc.page?.topCm ?? 0, 2.54, accuracy: 0.01)
        XCTAssertEqual(doc.page?.leftCm ?? 0, 3.18, accuracy: 0.01)
        XCTAssertEqual(doc.mediaImageCount, 0)
    }

    func testDocXReaderLineSpacingAndStyles() throws {
        // 倍数行距 + 固定磅行距 + 样式名解析 + 媒体统计
        let doc = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>
        <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>章节标题</w:t></w:r></w:p>
        <w:p><w:pPr><w:spacing w:line="360" w:lineRule="auto"/></w:pPr><w:r><w:t>倍数行距段</w:t></w:r></w:p>
        <w:p><w:pPr><w:spacing w:line="440" w:lineRule="exact"/></w:pPr><w:r><w:t>固定行距段</w:t></w:r></w:p>
        <w:sectPr><w:pgSz w:w="16838" w:h="11906"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr>
        </w:body></w:document>
        """
        let styles = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
        <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/></w:style></w:styles>
        """
        var zip = ZipWriter()
        try zip.addFile(name: "word/document.xml", data: Data(doc.utf8))
        try zip.addFile(name: "word/styles.xml", data: Data(styles.utf8))
        try zip.addFile(name: "word/media/image1.png", data: Data(repeating: 0x89, count: 5000))
        let data = zip.finalize()
        let d = try DocXReader.load(data: data)
        guard case .paragraph(let h) = d.blocks[0],
              case .paragraph(let mult) = d.blocks[1],
              case .paragraph(let exact) = d.blocks[2] else {
            return XCTFail("blocks 不符")
        }
        XCTAssertEqual(h.styleName, "heading 1")
        XCTAssertEqual(mult.lineSpacingMultiple ?? 0, 1.5, accuracy: 0.001)
        XCTAssertNil(mult.lineSpacingPt)
        XCTAssertEqual(exact.lineSpacingPt ?? 0, 22.0, accuracy: 0.001)
        XCTAssertNil(exact.lineSpacingMultiple)
        XCTAssertEqual(d.mediaImageCount, 1)
        XCTAssertEqual(d.mediaImageBytes, 5000)
        // 横向：w > h
        XCTAssertEqual(d.page?.widthCm ?? 0, 29.7, accuracy: 0.01)
    }

    func testDocXReaderRoundTripsBuilderOutput() throws {
        var b = DocXBuilder()
        b.add(.title("闭环标题"))
        b.add(.heading(level: 2, text: "二级标题"))
        b.add(.paragraph([DocXBuilder.Run("正文段落")]))
        b.add(.bullets(["要点一", "要点二"]))
        b.add(.table(rows: [["表头A", "表头B"], ["1", "2"]]))
        b.add(.pageBreak)
        let data = try b.data()
        let d = try DocXReader.load(data: data)
        // pageBreak 段按 python-docx 口径产出 "\n"（w:br→\n）；Python doc_reader 以
        // strip 后为空跳过此类段（doc_reader.py:306），此处同口径过滤再比对。
        XCTAssertEqual(d.paragraphs.map(\.text).filter {
                           !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
                       ["闭环标题", "二级标题", "正文段落", "要点一", "要点二"])
        XCTAssertEqual(d.paragraphs[0].styleName, "Title")
        XCTAssertEqual(d.paragraphs[1].styleName, "heading 2")
        XCTAssertEqual(d.tableCount, 1)
        guard case .table(let t) = d.blocks.first(where: {
            if case .table = $0 { return true }; return false
        })! else { return XCTFail() }
        XCTAssertEqual(t.rows[1], ["1", "2"])
        // 默认页面：A4 纵向 + 法律边距
        XCTAssertEqual(d.page?.widthCm ?? 0, 21.0, accuracy: 0.01)
        XCTAssertEqual(d.page?.leftCm ?? 0, 3.18, accuracy: 0.01)
    }

    // MARK: - DocXBuilder StyleConfig / footer / image

    func testDocXBuilderStyleConfig() throws {
        var b = DocXBuilder()
        b.style.normalEastAsiaFont = "楷体"
        b.style.normalAsciiFont = "Arial"
        b.style.normalSizePt = 16
        b.style.marginTopCm = 5.0
        b.style.marginLeftCm = 5.0
        b.style.bodyAlignValue = 2              // right
        b.style.bodyFirstLineIndentCm = 1.5
        b.style.bodyLineSpacingMultiple = 1.5
        b.add(.paragraph([DocXBuilder.Run("新文档正文段落")]))
        let data = try b.data()
        let zip = try ZipArchiveReader(data: data)
        let styles = String(decoding: try zip.data(named: "word/styles.xml", from: data), as: UTF8.self)
        XCTAssertTrue(styles.contains("w:eastAsia=\"楷体\""), styles)
        XCTAssertTrue(styles.contains("w:ascii=\"Arial\""), styles)
        XCTAssertTrue(styles.contains("<w:sz w:val=\"32\"/>"), styles)   // 16pt → 半磅 32
        let doc = String(decoding: try zip.data(named: "word/document.xml", from: data), as: UTF8.self)
        XCTAssertTrue(doc.contains("w:jc w:val=\"right\""), doc)
        XCTAssertTrue(doc.contains("<w:ind w:firstLine=\"850\"/>") || doc.contains("<w:ind w:firstLine=\"851\"/>"), doc)
        XCTAssertTrue(doc.contains("<w:spacing w:line=\"360\" w:lineRule=\"auto\"/>"), doc)
        // 5cm 边距（twips≈2835）落在 sectPr
        XCTAssertTrue(doc.contains("w:top=\"2835\"") || doc.contains("w:top=\"2834\""), doc)
    }

    func testDocXBuilderFooterFormatAndToggle() throws {
        var b = DocXBuilder()
        b.pageNumberFormat = "P{p}/{t}"
        b.add(.paragraph([DocXBuilder.Run("x")]))
        var data = try b.data()
        var zip = try ZipArchiveReader(data: data)
        let footer = String(decoding: try zip.data(named: "word/footer1.xml", from: data), as: UTF8.self)
        XCTAssertTrue(footer.contains(">P<"), footer)
        XCTAssertTrue(footer.contains("PAGE"), footer)
        XCTAssertTrue(footer.contains("NUMPAGES"), footer)
        // 关闭页脚：无 footer part、无 footerReference
        var b2 = DocXBuilder()
        b2.pageNumberFooter = false
        b2.add(.paragraph([DocXBuilder.Run("x")]))
        data = try b2.data()
        zip = try ZipArchiveReader(data: data)
        XCTAssertNil(zip.entries.first(where: { $0.name == "word/footer1.xml" }))
        let doc = String(decoding: try zip.data(named: "word/document.xml", from: data), as: UTF8.self)
        XCTAssertFalse(doc.contains("footerReference"), doc)
    }

    /// 最小合法 PNG（zlib stored 块，无需真实像素内容之外的依赖）。
    static func makePNG(width: Int, height: Int) -> Data {
        func be32(_ v: UInt32) -> [UInt8] {
            [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
        }
        func chunk(_ type: String, _ payload: [UInt8]) -> [UInt8] {
            var out = be32(UInt32(payload.count))
            let typeBytes = Array(type.utf8)
            out += typeBytes + payload
            var crcData = Data(typeBytes)
            crcData.append(contentsOf: payload)
            out += be32(CRC32.checksum(crcData))
            return out
        }
        // IHDR：宽/高/位深8/真彩2/压缩0/过滤0/隔行0
        var ihdr = be32(UInt32(width)) + be32(UInt32(height))
        ihdr += [8, 2, 0, 0, 0]
        // 原始像素：每行 filter 0 + RGB
        let rowLen = 1 + width * 3
        var raw: [UInt8] = []
        raw.reserveCapacity(rowLen * height)
        for _ in 0..<height {
            raw.append(0)
            for _ in 0..<(width * 3) { raw.append(200) }
        }
        // zlib stored：0x78 0x01 + stored deflate 块 + adler32
        var z: [UInt8] = [0x78, 0x01]
        var pos = 0
        while pos < raw.count {
            let n = min(65535, raw.count - pos)
            let final: UInt8 = (pos + n == raw.count) ? 1 : 0
            z.append(final)
            z.append(UInt8(n & 0xFF)); z.append(UInt8(n >> 8 & 0xFF))
            z.append(UInt8(~n & 0xFF)); z.append(UInt8(~n >> 8 & 0xFF))
            z += raw[pos..<(pos + n)]
            pos += n
        }
        // adler32
        var s1: UInt32 = 1, s2: UInt32 = 0
        for byte in raw {
            s1 = (s1 + UInt32(byte)) % 65521
            s2 = (s2 + s1) % 65521
        }
        z += be32((s2 << 16) | s1)
        var png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        png += chunk("IHDR", ihdr)
        png += chunk("IDAT", z)
        png += chunk("IEND", [])
        return Data(png)
    }

    func testImageSizeSniff() {
        let png = Self.makePNG(width: 800, height: 400)
        XCTAssertEqual(ImageSize.sniff(png)?.width, 800)
        XCTAssertEqual(ImageSize.sniff(png)?.height, 400)
        XCTAssertNil(ImageSize.sniff(Data("not an image".utf8)))
    }

    func testDocXBuilderImageBlockSizing() throws {
        let png = Self.makePNG(width: 800, height: 400)   // 宽高比 2.0
        let img = DocXBuilder.ImageRef(name: "probe.png", data: png,
                                       pixelWidth: 800, pixelHeight: 400)
        // 默认：width=13cm，height 按比例 6.5cm
        var b = DocXBuilder()
        b.add(.image(images: [img], layout: .single, caption: "图注", widthCm: nil, heightCm: nil))
        let data = try b.data()
        let zip = try ZipArchiveReader(data: data)
        XCTAssertNotNil(zip.entries.first(where: { $0.name == "word/media/image1.png" }))
        let doc = String(decoding: try zip.data(named: "word/document.xml", from: data), as: UTF8.self)
        XCTAssertTrue(doc.contains("cx=\"4680000\""), doc)             // 13cm
        XCTAssertTrue(doc.contains("cy=\"2340000\""), doc)             // 6.5cm
        XCTAssertTrue(doc.contains("图注"), doc)
        let rels = String(decoding: try zip.data(named: "word/_rels/document.xml.rels", from: data), as: UTF8.self)
        XCTAssertTrue(rels.contains("relationships/image"), rels)
        // 只给 height=5cm → width 按比例 10cm
        var b2 = DocXBuilder()
        b2.add(.image(images: [img], layout: .single, caption: "", widthCm: nil, heightCm: 5))
        let doc2 = String(decoding: try ZipArchiveReader(data: b2.data())
            .data(named: "word/document.xml", from: b2.data()), as: UTF8.self)
        XCTAssertTrue(doc2.contains("cx=\"3600000\""), doc2)           // 10cm
        XCTAssertTrue(doc2.contains("cy=\"1800000\""), doc2)           // 5cm
    }

    // MARK: - XlsxReader

    func testXlsxReaderValuesAndFormula() throws {
        var wb = XlsxBuilder()
        wb.addSheet(name: "借款明细", rows: [
            [.string("项目"), .string("金额"), .string("日期")],
            [.string("本金"), .number(239900), .string("2023-02-01")],
            [.string("利息"), .number(5972), .string("2026-06-03")],
            [.string("合计"), .formula("SUM(B2:B3)"), .blank],
        ])
        wb.addSheet(name: "空工作表", rows: [])
        let data = try wb.data()
        let sheets = try XlsxReader.load(data: data)
        XCTAssertEqual(sheets.count, 2)
        let s0 = sheets[0]
        XCTAssertEqual(s0.name, "借款明细")
        XCTAssertEqual(s0.cells[2]?[2]?.value, .int(239900))
        XCTAssertEqual(s0.cells[1]?[1]?.value, .string("项目"))
        // 公式格：缓存值缺失 + 公式原文（双视图）
        XCTAssertEqual(s0.cells[4]?[2]?.value, .blank)
        XCTAssertEqual(s0.cells[4]?[2]?.formula, "SUM(B2:B3)")
        XCTAssertEqual(s0.maxRow, 4)
        XCTAssertEqual(s0.maxColumn, 3)
        XCTAssertEqual(sheets[1].name, "空工作表")
        XCTAssertEqual(sheets[1].maxRow, 1)   // 空表回退 1×1（openpyxl 口径）
    }

    // MARK: - PptxReader / notes

    func testPptxReaderTitleBodyNotes() throws {
        var prs = PptxBuilder()
        prs.addSlide(PptxBuilder.Slide(title: "封面", notes: "封面备注"))
        prs.addSlide(PptxBuilder.Slide(title: "页2", bullets: ["要点A", "要点B"]))
        let data = try prs.data()
        let slides = try PptxReader.load(data: data)
        XCTAssertEqual(slides.count, 2)
        XCTAssertEqual(slides[0].title, "封面")
        XCTAssertEqual(slides[0].notes, "封面备注")
        XCTAssertEqual(slides[1].title, "页2")
        guard case .text(let body) = slides[1].shapes.first else {
            return XCTFail("页2 缺正文形状: \(slides[1].shapes)")
        }
        XCTAssertTrue(body.contains("要点A") && body.contains("要点B"), body)
        XCTAssertNil(slides[1].notes)
        // notes 部件存在性
        let zip = try ZipArchiveReader(data: data)
        XCTAssertNotNil(zip.entries.first(where: { $0.name == "ppt/notesSlides/notesSlide1.xml" }))
        XCTAssertNotNil(zip.entries.first(where: { $0.name == "ppt/notesMasters/notesMaster1.xml" }))
    }
}
