//
//  VetarOOXMLTests.swift
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
import zlib
@testable import VetarOOXML

/// VetarOOXML XCTest 单测（用 swift-testing 风格亦可，这里用 XCTest 保持兼容）。
/// 覆盖：CRC32 正确性、ZIP 结构读回、XML 转义、三种文档生成不抛错且结构完整。
final class VetarOOXMLTests: XCTestCase {

    // MARK: CRC32

    func testCRC32KnownVectors() {
        // 标准测试向量：CRC32("123456789") = 0xCBF43926
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF43926)
        XCTAssertEqual(CRC32.checksum(Data()), 0x00000000)
        XCTAssertEqual(CRC32.checksum(Data("The quick brown fox jumps over the lazy dog".utf8)),
                       0x414FA339)
        // 中文 UTF-8
        XCTAssertEqual(CRC32.checksum(Data("你好".utf8)), 0x50A2B841)
    }

    // MARK: ZIP

    func testZipStructureRoundTrip() throws {
        var zip = ZipWriter(date: Date(timeIntervalSince1970: 1_700_000_000))
        let content = Data("hello ooxml 你好，世界".utf8)
        try zip.addFile(name: "word/document.xml", data: content)
        try zip.addFile(name: "empty.xml", data: Data())
        try zip.addFile(name: "xl/worksheets/sheet1.xml", data: Data(String(repeating: "abc<>", count: 5000).utf8))
        let zipData = zip.finalize()

        let reader = try ZipArchiveReader(data: zipData)
        XCTAssertEqual(reader.entries.count, 3)
        XCTAssertEqual(reader.entries.map(\.name),
                       ["word/document.xml", "empty.xml", "xl/worksheets/sheet1.xml"])
        XCTAssertEqual(reader.entries[0].crc32, CRC32.checksum(content))
        XCTAssertEqual(reader.entries[0].uncompressedSize, UInt32(content.count))
        XCTAssertEqual(reader.entries[0].method, 8)
        XCTAssertEqual(reader.entries[1].uncompressedSize, 0)
        XCTAssertEqual(reader.entries[1].crc32, 0)
        // 重复内容应被压缩到更小
        XCTAssertLessThan(reader.entries[2].compressedSize, reader.entries[2].uncompressedSize)
    }

    func testZipDeflateRoundTripViaZlib() throws {
        // 用 libz inflate 验证我们的 raw deflate 输出可被标准解压
        var zip = ZipWriter()
        let original = Data(String(repeating: "VetarOOXML 测试文本 ", count: 1000).utf8)
        try zip.addFile(name: "a.txt", data: original)
        let zipData = zip.finalize()

        // 找到 local header 之后的数据段起点
        let bytes = [UInt8](zipData)
        XCTAssertEqual(UInt32(bytes[0]) | UInt32(bytes[1]) << 8, 0x4B50)
        let nameLen = Int(ZipArchiveReader.u16(bytes, 26))
        let extraLen = Int(ZipArchiveReader.u16(bytes, 28))
        let dataStart = 30 + nameLen + extraLen
        let reader = try ZipArchiveReader(data: zipData)
        let comp = Data(bytes[dataStart..<(dataStart + Int(reader.entries[0].compressedSize))])

        let inflated = try inflateRaw(comp, expectedSize: original.count)
        XCTAssertEqual(inflated, original)
    }

    // MARK: XML 转义

    func testXMLEscaping() {
        XCTAssertEqual(XMLEscaping.escapeText("a<b>&\"'\""), "a&lt;b&gt;&amp;\"'\"")
        XCTAssertEqual(XMLEscaping.escapeAttribute("a\"b\nc"), "a&quot;b&#10;c")
        XCTAssertEqual(XMLEscaping.escapeText("]]>"), "]]&gt;")
        XCTAssertEqual(XMLEscaping.escapeText("中文无需转义"), "中文无需转义")
    }

    // MARK: docx

    func testDocXGeneration() throws {
        var doc = DocXBuilder()
        doc.add(.title("证据目录"))
        doc.add(.heading(level: 1, text: "一、合同文件"))
        doc.add(.heading(level: 2, text: "1.1 主合同"))
        doc.add(.paragraph([DocXBuilder.Run("原告"), DocXBuilder.Run("张三", bold: true),
                            DocXBuilder.Run("与被告"), DocXBuilder.Run("李四", italic: true),
                            DocXBuilder.Run("签订《买卖合同》。")]))
        doc.add(.bullets(["合同编号 HT-2026-001", "签订日期 2026-01-05"]))
        doc.add(.table(rows: [["序号", "证据名称", "页码"],
                              ["1", "买卖合同", "3-8"],
                              ["2", "付款凭证 <银行>", "9-12"]]))
        doc.add(.pageBreak)
        doc.add(.heading(level: 1, text: "二、付款记录"))
        let data = try doc.data()

        let reader = try ZipArchiveReader(data: data)
        let names = Set(reader.entries.map(\.name))
        XCTAssertTrue(names.contains("[Content_Types].xml"))
        XCTAssertTrue(names.contains("_rels/.rels"))
        XCTAssertTrue(names.contains("word/document.xml"))
        XCTAssertTrue(names.contains("word/styles.xml"))
        XCTAssertTrue(names.contains("word/numbering.xml"))
        XCTAssertTrue(names.contains("word/footer1.xml"))
        XCTAssertTrue(names.contains("word/_rels/document.xml.rels"))
    }

    // MARK: xlsx

    func testXlsxGeneration() throws {
        var wb = XlsxBuilder()
        wb.addSheet(name: "资产负债表", rows: [
            [.string("项目"), .string("金额"), .string("备注")],
            [.string("资产总计"), .number(1_234_567.89), .string("<含应收>")],
            [.string("负债合计"), .number(654_321), .blank],
            [.string("校验"), .formula("B2-B3"), .string("公式留位")],
        ])
        wb.addSheet(name: "Sheet2", rows: [[.string("第二表"), .number(42)]])
        let data = try wb.data()

        let reader = try ZipArchiveReader(data: data)
        let names = Set(reader.entries.map(\.name))
        XCTAssertTrue(names.contains("xl/workbook.xml"))
        XCTAssertTrue(names.contains("xl/sharedStrings.xml"))
        XCTAssertTrue(names.contains("xl/worksheets/sheet1.xml"))
        XCTAssertTrue(names.contains("xl/worksheets/sheet2.xml"))
        XCTAssertEqual(reader.entries.count, 7)  // CT + .rels + workbook + wbRels + sst + 2 sheets
    }

    func testXlsxColumnName() {
        XCTAssertEqual(XlsxBuilder.columnName(0), "A")
        XCTAssertEqual(XlsxBuilder.columnName(25), "Z")
        XCTAssertEqual(XlsxBuilder.columnName(26), "AA")
        XCTAssertEqual(XlsxBuilder.columnName(27), "AB")
        XCTAssertEqual(XlsxBuilder.columnName(701), "ZZ")
        XCTAssertEqual(XlsxBuilder.columnName(702), "AAA")
    }

    // MARK: pptx

    func testPptxGeneration() throws {
        var prs = PptxBuilder()
        prs.addSlide(title: "发布会", bullets: [])
        prs.addSlide(title: "产品亮点", bullets: ["全原生 Swift", "零外部依赖", "中文 <友好>"])
        var s3 = PptxBuilder.Slide(title: "第三页", bullets: ["要点A"])
        s3.textBoxes.append(PptxBuilder.TextBox(x: 914400, y: 5000000,
                                                cx: 4000000, cy: 800000,
                                                paragraphs: ["页脚文本框"]))
        prs.addSlide(s3)
        let data = try prs.data()

        let reader = try ZipArchiveReader(data: data)
        let names = Set(reader.entries.map(\.name))
        for required in ["ppt/presentation.xml", "ppt/theme/theme1.xml",
                         "ppt/slideMasters/slideMaster1.xml",
                         "ppt/slideLayouts/slideLayout1.xml",
                         "ppt/slides/slide1.xml", "ppt/slides/slide2.xml", "ppt/slides/slide3.xml",
                         "ppt/slides/_rels/slide3.xml.rels"] {
            XCTAssertTrue(names.contains(required), "缺少 \(required)")
        }
    }

    // MARK: 大文档性能（粗测，非断言型）

    func testLargeDocXPerformance() throws {
        var doc = DocXBuilder()
        for i in 1...100 {
            doc.add(.heading(level: 1, text: "第 \(i) 章"))
            for j in 1...10 {
                doc.add(.paragraph([DocXBuilder.Run("这是第 \(i) 章第 \(j) 段，"),
                                    DocXBuilder.Run("包含粗体", bold: true),
                                    DocXBuilder.Run("与"),
                                    DocXBuilder.Run("斜体", italic: true),
                                    DocXBuilder.Run("混排中文文本，用于压力测试。")]))
            }
            if i % 5 == 0 {
                doc.add(.table(rows: [["列1", "列2", "列3"]] + (1...5).map { ["\($0)-A", "\($0)-B", "\($0)-C"] }))
            }
            doc.add(.pageBreak)
        }
        let start = Date()
        let data = try doc.data()
        let elapsed = Date().timeIntervalSince(start)
        print("PERF docx-100page: \(data.count) bytes in \(elapsed * 1000) ms")
        XCTAssertGreaterThan(data.count, 5_000)
        XCTAssertLessThan(elapsed, 5.0, "100 页级 docx 生成应远快于 5 秒")
    }

    // MARK: - 辅助

    private func inflateRaw(_ compressed: Data, expectedSize: Int) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, -15, ZLIB_VERSION,
                            Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw NSError(domain: "test", code: 1)
        }
        defer { inflateEnd(&stream) }
        var out = Data(count: expectedSize)
        let result: Int32 = compressed.withUnsafeBytes { src in
            out.withUnsafeMutableBytes { dst in
                stream.next_in = UnsafeMutablePointer(mutating: src.baseAddress?.assumingMemoryBound(to: Bytef.self))
                stream.avail_in = uInt(compressed.count)
                stream.next_out = dst.baseAddress?.assumingMemoryBound(to: Bytef.self)
                stream.avail_out = uInt(expectedSize)
                return inflate(&stream, Z_FINISH)
            }
        }
        guard result == Z_STREAM_END else { throw NSError(domain: "test", code: 2) }
        return out
    }
}

// MARK: - 追加性能粗测（xlsx / pptx / zip 吞吐）
extension VetarOOXMLTests {
    func testLargeXlsxPerformance() throws {
        var wb = XlsxBuilder()
        for s in 1...10 {
            var rows: [[XlsxBuilder.Cell]] = [[.string("编号"), .string("名称"), .string("金额"), .string("公式")]]
            for r in 1...1000 {
                rows.append([.string("EV-\(s)-\(r)"), .string("证据材料 \(r)"),
                             .number(Double(r) * 1.5), .formula("C\(r + 1)*2")])
            }
            wb.addSheet(name: "Sheet\(s)", rows: rows)
        }
        let start = Date()
        let data = try wb.data()
        let elapsed = Date().timeIntervalSince(start)
        print("PERF xlsx-10sheet-x-1001row-x-4col: \(data.count) bytes in \(elapsed * 1000) ms")
        XCTAssertLessThan(elapsed, 10.0)
    }

    func testLargePptxPerformance() throws {
        var prs = PptxBuilder()
        for i in 1...100 {
            prs.addSlide(title: "第 \(i) 页标题",
                         bullets: ["要点一：内容 \(i)", "要点二：中文混排 <test>", "要点三：条目"])
        }
        let start = Date()
        let data = try prs.data()
        let elapsed = Date().timeIntervalSince(start)
        print("PERF pptx-100slide: \(data.count) bytes in \(elapsed * 1000) ms")
        XCTAssertLessThan(elapsed, 5.0)
    }
}
