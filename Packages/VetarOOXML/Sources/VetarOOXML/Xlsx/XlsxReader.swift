//
//  XlsxReader.swift
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

/// xlsx/xlsm 结构化读取（P2-W3b）：对齐 doc_reader._read_xlsx 经 openpyxl 消费的语义面——
///   · 双视图：缓存值（data_only=True 等价：<v> 计算结果）+ 公式原文（data_only=False
///     等价：<f> 串）。程序新建未过 Excel 的表，公式格 <v> 缺失 → value=.blank，
///     由调用方按「公式未计算」口径兜底显示。
///   · 类型：t="s" 共享字符串 / t="str" 公式串结果 / t="b" 布尔 / t="e" 错误 /
///     t="inlineStr" 内联 / 缺省数字（整型模式 → int，其余 → double，对齐 openpyxl 推断）。
///   · maxRow/maxColumn：实有单元格的最大行列（空表回退 1×1，对齐 openpyxl）。
/// ⚠️ 偏差：日期/时间格式的数字格 openpyxl 会转 datetime，本读取面保持原始数字
///    （规格测试不含日期格；差异已在 P2-W3b 汇报记录）。
public enum XlsxReaderError: Error {
    case missingPart(String)
    case badXML(String)
}

public enum XlsxCellValue: Equatable {
    case blank
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case error(String)
}

public struct XlsxCell {
    /// 缓存计算结果（data_only 视图）；无缓存 → .blank。
    public var value: XlsxCellValue = .blank
    /// 公式原文（不带前导 =）；非公式格 → nil。
    public var formula: String?
}

public struct XlsxSheet {
    public var name: String = ""
    public var maxRow: Int = 1
    public var maxColumn: Int = 1
    /// 实有单元格：[row: [col: cell]]，1 起。
    public var cells: [Int: [Int: XlsxCell]] = [:]
}

public enum XlsxReader {

    public static func load(data: Data) throws -> [XlsxSheet] {
        let zip = try ZipArchiveReader(data: data)
        let wbData = try zip.data(named: "xl/workbook.xml", from: data)
        let wbRoot: XMLNode
        do { wbRoot = try XMLMiniDOM.parse(wbData) } catch { throw XlsxReaderError.badXML("xl/workbook.xml") }

        // workbook.xml.rels：rId → worksheets/sheetN.xml
        var relTargets: [String: String] = [:]
        if let relsData = try? zip.data(named: "xl/_rels/workbook.xml.rels", from: data),
           let relsRoot = try? XMLMiniDOM.parse(relsData) {
            for rel in relsRoot.childrenNamed("Relationship") {
                if let rid = rel.attributes["Id"], let target = rel.attributes["Target"] {
                    relTargets[rid] = target
                }
            }
        }

        // sharedStrings.xml（缺件按空表；<si> 多 run 拼接）
        var shared: [String] = []
        if let ssData = try? zip.data(named: "xl/sharedStrings.xml", from: data),
           let ssRoot = try? XMLMiniDOM.parse(ssData) {
            for si in ssRoot.childrenNamed("si") {
                // <si> 直挂 <t> 或多 <r><t> 富文本段——后代 <t> 全量拼接
                shared.append(collectText(si, tag: "t"))
            }
        }

        guard let sheetsNode = wbRoot.child("sheets") else {
            throw XlsxReaderError.badXML("sheets")
        }
        var out: [XlsxSheet] = []
        for sh in sheetsNode.childrenNamed("sheet") {
            var sheet = XlsxSheet()
            sheet.name = sh.attributes["name"] ?? ""
            guard let rid = sh.attributes["r:id"] ?? sh.attributes["id"],
                  let target = relTargets[rid] else { continue }
            // Target 可能是 "worksheets/sheet1.xml" 或 "/xl/worksheets/sheet1.xml"
            let part: String
            if target.hasPrefix("/") {
                part = String(target.dropFirst())
            } else {
                part = "xl/" + target
            }
            guard let sheetData = try? zip.data(named: part, from: data),
                  let sheetRoot = try? XMLMiniDOM.parse(sheetData) else { continue }
            parseSheetData(sheetRoot, shared: shared, into: &sheet)
            out.append(sheet)
        }
        return out
    }

    /// <si> 文本：直接 <t> 或多个 <r><t> 拼接。
    private static func collectText(_ si: XMLNode, tag: String) -> String {
        si.descendants(tag).map(\.text).joined()
    }

    static func parseSheetData(_ root: XMLNode, shared: [String], into sheet: inout XlsxSheet) {
        guard let sheetData = root.child("sheetData") else { return }
        for rowNode in sheetData.childrenNamed("row") {
            let rowIdx = Int(rowNode.attributes["r"] ?? "") ?? 0
            var colCursor = 0
            for c in rowNode.childrenNamed("c") {
                let colIdx: Int
                if let ref = c.attributes["r"], let col = columnIndex(from: ref) {
                    colIdx = col
                } else {
                    colCursor += 1
                    colIdx = colCursor
                }
                colCursor = colIdx
                var cell = XlsxCell()
                if let f = c.child("f") { cell.formula = f.text }
                cell.value = parseValue(c, shared: shared)
                sheet.cells[rowIdx, default: [:]][colIdx] = cell
                sheet.maxRow = max(sheet.maxRow, rowIdx)
                sheet.maxColumn = max(sheet.maxColumn, colIdx)
            }
        }
    }

    /// "B12" → 2。
    static func columnIndex(from ref: String) -> Int? {
        var n = 0
        for ch in ref {
            guard ch.isLetter, let ascii = ch.uppercased().first?.asciiValue else {
                return n > 0 ? n : nil
            }
            n = n * 26 + Int(ascii - 64)
        }
        return n > 0 ? n : nil
    }

    static func parseValue(_ c: XMLNode, shared: [String]) -> XlsxCellValue {
        let t = c.attributes["t"] ?? ""
        switch t {
        case "s":
            guard let v = c.child("v")?.text, let idx = Int(v),
                  idx >= 0, idx < shared.count else { return .blank }
            return .string(shared[idx])
        case "inlineStr":
            guard let isNode = c.child("is") else { return .blank }
            return .string(isNode.descendants("t").map(\.text).joined())
        case "str":
            guard let v = c.child("v")?.text else { return .blank }
            return .string(v)
        case "b":
            guard let v = c.child("v")?.text else { return .blank }
            return .bool(v == "1")
        case "e":
            return .error(c.child("v")?.text ?? "")
        default:
            guard let vText = c.child("v")?.text, !vText.isEmpty else { return .blank }
            // openpyxl：整型模式 → int，其余 → float
            if let i = Int64(vText) { return .int(i) }
            if let d = Double(vText) { return .double(d) }
            return .string(vText)
        }
    }
}
