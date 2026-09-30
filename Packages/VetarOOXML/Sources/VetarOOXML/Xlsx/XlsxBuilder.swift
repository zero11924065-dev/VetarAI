//
//  XlsxBuilder.swift
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

/// xlsx 生成器：多 sheet、字符串/数字/公式单元格。
/// 字符串走 sharedStrings（t="s"），数字内联 <v>，公式写 <f> 留待 Excel 重算。
public struct XlsxBuilder {

    public enum Cell {
        case string(String)
        case number(Double)
        case formula(String)   // 不带前导 =
        case bool(Bool)        // t="b"（openpyxl 布尔格）
        case blank
    }

    public struct Sheet {
        public var name: String
        /// rows[r][c]，r/c 从 0 起；稀疏行用 .blank 占位。
        public var rows: [[Cell]]
        public init(name: String, rows: [[Cell]]) { self.name = name; self.rows = rows }
    }

    private var sheets: [Sheet] = []

    public init() {}

    public mutating func addSheet(_ sheet: Sheet) { sheets.append(sheet) }

    /// 便捷接口：Any? 数组自动归类（数字→number，可转数字的字符串仍保持字符串以保可控）。
    public mutating func addSheet(name: String, rows: [[Cell]]) {
        sheets.append(Sheet(name: name, rows: rows))
    }

    public func data() throws -> Data {
        let sheetList = sheets.isEmpty ? [Sheet(name: "Sheet1", rows: [])] : sheets

        // 收集共享字符串
        var stringIndex: [String: Int] = [:]
        var sharedStrings: [String] = []
        for s in sheetList {
            for row in s.rows {
                for cell in row {
                    if case .string(let v) = cell, stringIndex[v] == nil {
                        stringIndex[v] = sharedStrings.count
                        sharedStrings.append(v)
                    }
                }
            }
        }

        var zip = ZipWriter()
        try zip.addFile(name: "[Content_Types].xml", data: Self.contentTypes(sheetCount: sheetList.count))
        try zip.addFile(name: "_rels/.rels", data: Self.rootRels)
        try zip.addFile(name: "xl/workbook.xml", data: Self.workbookXML(sheetList))
        try zip.addFile(name: "xl/_rels/workbook.xml.rels", data: Self.workbookRels(sheetCount: sheetList.count))
        try zip.addFile(name: "xl/sharedStrings.xml", data: Self.sharedStringsXML(sharedStrings))
        for (i, s) in sheetList.enumerated() {
            try zip.addFile(name: "xl/worksheets/sheet\(i + 1).xml",
                            data: Self.sheetXML(s, stringIndex: stringIndex))
        }
        return zip.finalize()
    }

    public func save(to url: URL) throws {
        try data().write(to: url, options: .atomic)
    }

    // MARK: - 内部

    /// 列号 → Excel 列名（0→A, 26→AA）。
    static func columnName(_ col: Int) -> String {
        var n = col + 1, s = ""
        while n > 0 {
            n -= 1
            s = String(UnicodeScalar(65 + n % 26)!) + s
            n /= 26
        }
        return s
    }

    private static func sheetXML(_ sheet: Sheet, stringIndex: [String: Int]) -> Data {
        var x = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>

        """
        for (r, row) in sheet.rows.enumerated() {
            let rowNum = r + 1
            // 全 blank 的行跳过，减小体积
            guard row.contains(where: { if case .blank = $0 { return false } else { return true } }) else { continue }
            x += "<row r=\"\(rowNum)\">"
            for (c, cell) in row.enumerated() {
                let ref = "\(columnName(c))\(rowNum)"
                switch cell {
                case .string(let v):
                    x += "<c r=\"\(ref)\" t=\"s\"><v>\(stringIndex[v]!)</v></c>"
                case .number(let n):
                    x += "<c r=\"\(ref)\"><v>\(Self.formatNumber(n))</v></c>"
                case .formula(let f):
                    x += "<c r=\"\(ref)\"><f>\(XMLEscaping.escapeText(f))</f></c>"
                case .bool(let bv):
                    x += "<c r=\"\(ref)\" t=\"b\"><v>\(bv ? 1 : 0)</v></c>"
                case .blank:
                    continue
                }
            }
            x += "</row>"
        }
        x += "</sheetData></worksheet>"
        return Data(x.utf8)
    }

    private static func formatNumber(_ n: Double) -> String {
        if n == n.rounded() && abs(n) < 1e15 {
            return String(Int64(n))
        }
        return String(n)
    }

    private static func contentTypes(sheetCount: Int) -> Data {
        var x = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
        <Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>

        """
        for i in 1...sheetCount {
            x += "<Override PartName=\"/xl/worksheets/sheet\(i).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }
        x += "</Types>"
        return Data(x.utf8)
    }

    private static let rootRels = Data("""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>\
    </Relationships>
    """.utf8)

    private static func workbookXML(_ sheets: [Sheet]) -> Data {
        var x = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>

        """
        for (i, s) in sheets.enumerated() {
            let name = String(s.name.prefix(31))
            x += "<sheet name=\"\(XMLEscaping.escapeAttribute(name))\" sheetId=\"\(i + 1)\" r:id=\"rId\(i + 1)\"/>"
        }
        x += "</sheets></workbook>"
        return Data(x.utf8)
    }

    private static func workbookRels(sheetCount: Int) -> Data {
        var x = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">

        """
        for i in 1...sheetCount {
            x += "<Relationship Id=\"rId\(i)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(i).xml\"/>"
        }
        x += "<Relationship Id=\"rId\(sheetCount + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings\" Target=\"sharedStrings.xml\"/>"
        x += "</Relationships>"
        return Data(x.utf8)
    }

    private static func sharedStringsXML(_ strings: [String]) -> Data {
        var x = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
        count="\(strings.count)" uniqueCount="\(strings.count)">

        """
        for s in strings {
            x += "<si><t xml:space=\"preserve\">\(XMLEscaping.escapeText(s))</t></si>"
        }
        x += "</sst>"
        return Data(x.utf8)
    }
}
