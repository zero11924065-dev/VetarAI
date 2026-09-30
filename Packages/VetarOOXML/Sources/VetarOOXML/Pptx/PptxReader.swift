//
//  PptxReader.swift
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

/// pptx 结构化读取（P2-W3b）：对齐 attachments/parser.py _parse_pptx 经 python-pptx
/// 消费的语义面（知识索引 / 工作流 file_read 链）——
///   · 页序：ppt/slides/slideN.xml 按 N 升序
///   · 标题：sp 中 ph type="title"/"ctrTitle" 的占位（无 → nil）
///   · 形状：非标题 sp 的 txBody 文本（段落 \n 连接）；graphicFrame 的 a:tbl → 行×格
///   · 备注：slideN.xml.rels 的 notesSlide 关系 → notesSlideN.xml 的 body 占位文本
/// （doc_reader._read_pptx 的 zip+正则兜底路径不消费本结构，另由主仓按原文口径实现。）
public struct PptxSlide {
    public enum Shape {
        case text(String)
        case table([[String]])
    }
    public var number: Int = 0
    public var title: String?
    public var shapes: [Shape] = []
    public var notes: String?
}

public enum PptxReader {

    public static func load(data: Data) throws -> [PptxSlide] {
        let zip = try ZipArchiveReader(data: data)
        let slideNames = zip.entries.map(\.name)
            .filter { $0.range(of: #"^ppt/slides/slide\d+\.xml$"#, options: .regularExpression) != nil }
            .sorted { slideNumber($0) < slideNumber($1) }
        var out: [PptxSlide] = []
        for name in slideNames {
            guard let xml = try? zip.data(named: name, from: data),
                  let root = try? XMLMiniDOM.parse(xml) else { continue }
            var slide = PptxSlide()
            slide.number = slideNumber(name)
            parseSlide(root, into: &slide)
            // 备注：rels 定位 notesSlide
            let relsName = "ppt/slides/_rels/slide\(slide.number).xml.rels"
            if let relsData = try? zip.data(named: relsName, from: data),
               let relsRoot = try? XMLMiniDOM.parse(relsData) {
                for rel in relsRoot.childrenNamed("Relationship") {
                    guard (rel.attributes["Type"] ?? "").hasSuffix("/notesSlide"),
                          let target = rel.attributes["Target"] else { continue }
                    let part = target.hasPrefix("/") ? String(target.dropFirst())
                        : "ppt/slides/" + target
                    // 规整 ../ 段（notesSlide 目标通常为 ../notesSlides/notesSlideN.xml）
                    let normalized = normalizePath(part)
                    if let nData = try? zip.data(named: normalized, from: data),
                       let nRoot = try? XMLMiniDOM.parse(nData) {
                        slide.notes = notesText(nRoot)
                    }
                }
            }
            out.append(slide)
        }
        return out
    }

    static func slideNumber(_ name: String) -> Int {
        guard let slideRange = name.range(of: "slide", options: .backwards),
              let m = name.range(of: #"\d+"#, options: .regularExpression,
                                 range: slideRange.lowerBound..<name.endIndex) else { return 0 }
        return Int(name[m]) ?? 0
    }

    /// "ppt/slides/../notesSlides/notesSlide1.xml" → "ppt/notesSlides/notesSlide1.xml"。
    static func normalizePath(_ path: String) -> String {
        var parts: [String] = []
        for seg in path.split(separator: "/") {
            if seg == ".." { _ = parts.popLast() } else if seg != "." { parts.append(String(seg)) }
        }
        return parts.joined(separator: "/")
    }

    static func parseSlide(_ root: XMLNode, into slide: inout PptxSlide) {
        guard let spTree = root.child("p:cSld")?.child("p:spTree") else { return }
        for child in spTree.children {
            switch child.name {
            case "p:sp":
                let phType = child.child("p:nvSpPr")?.child("p:nvPr")?.child("p:ph")?.attributes["type"]
                let text = shapeText(child)
                if phType == "title" || phType == "ctrTitle" {
                    slide.title = text
                } else if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    slide.shapes.append(.text(text))
                }
            case "p:graphicFrame":
                if let tbl = child.child("a:graphic")?.child("a:graphicData")?.child("a:tbl") {
                    slide.shapes.append(.table(parseTable(tbl)))
                }
            default:
                continue
            }
        }
    }

    /// sp 文本：a:p 段落各自拼接 run 文本，段落间 \n（python-pptx text_frame.text 口径）。
    static func shapeText(_ sp: XMLNode) -> String? {
        guard let txBody = sp.child("p:txBody") else { return nil }
        let paras = txBody.childrenNamed("a:p").map { p in
            p.descendants("a:t").map(\.text).joined()
        }
        return paras.joined(separator: "\n")
    }

    static func parseTable(_ tbl: XMLNode) -> [[String]] {
        tbl.childrenNamed("a:tr").map { tr in
            tr.childrenNamed("a:tc").map { tc in
                tc.descendants("a:t").map(\.text).joined()
            }
        }
    }

    /// notesSlide 正文占位（ph type="body"）文本。
    static func notesText(_ root: XMLNode) -> String? {
        guard let spTree = root.child("p:cSld")?.child("p:spTree") else { return nil }
        for sp in spTree.childrenNamed("p:sp") {
            let phType = sp.child("p:nvSpPr")?.child("p:nvPr")?.child("p:ph")?.attributes["type"]
            if phType == "body", let text = shapeText(sp) {
                return text
            }
        }
        return nil
    }
}
