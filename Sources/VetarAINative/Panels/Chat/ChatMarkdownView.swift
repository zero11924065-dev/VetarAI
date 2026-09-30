//
//  ChatMarkdownView.swift
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

//  Markdown 流式渲染（对照现状 StreamingMarkdown，M1-4 / B3 / F2）：
//    · 未闭合 ``` 代码围栏 → 整段按纯文本 pre-wrap（避免半截 markdown 抖动）
//    · 闭合后分块渲染：标题/段落/代码块/列表/表格/引用/分隔线
//    · 行内样式经 AttributedString(markdown:)（粗体/斜体/行内代码/链接）
//    · 代码块：等宽字体 + 底色 + 横向滚动 + 轻量语法着色（关键词/字符串/注释/数字）
//      —— 纪律口径「代码块高亮从简但要有」
//    · 长串不断行撑破气泡的根治（B3）：溢出换行交给 Text 自然折行；
//      代码块与表格各自有独立横向滚动层
//

import SwiftUI

// MARK: - 块解析（纯函数，可单测）

public enum MDBlock: Equatable {
    case paragraph(String)
    case code(lang: String, code: String)
    case heading(level: Int, text: String)
    case list(ordered: Bool, items: [String])
    case table(rows: [[String]])       // rows[0] = 表头
    case quote(String)
    case hr
}

public enum MarkdownBlocks {
    /// 代码围栏是否闭合（现状：``` 计数为偶）。
    public static func fencesBalanced(_ text: String) -> Bool {
        let count = text.components(separatedBy: "```").count - 1
        return count % 2 == 0
    }

    public static func parse(_ text: String) -> [MDBlock] {
        var blocks: [MDBlock] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        var para: [String] = []

        func flushPara() {
            let t = para.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { blocks.append(.paragraph(t)) }
            para = []
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 代码围栏
            if trimmed.hasPrefix("```") {
                flushPara()
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i]); i += 1
                }
                i += 1  // 跳过闭合围栏（未闭合时调用方已拦，见 ChatMarkdownView）
                blocks.append(.code(lang: lang, code: code.joined(separator: "\n")))
                continue
            }
            // 分隔线
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushPara(); blocks.append(.hr); i += 1; continue
            }
            // 标题
            if let m = trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flushPara()
                let level = trimmed[m].filter { $0 == "#" }.count
                blocks.append(.heading(level: level,
                                       text: String(trimmed[m.upperBound...]).trimmingCharacters(in: .whitespaces)))
                i += 1; continue
            }
            // 引用
            if trimmed.hasPrefix(">") {
                flushPara()
                var quote: [String] = []
                while i < lines.count && lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quote.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst())
                        .trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(quote.joined(separator: "\n")))
                continue
            }
            // 表格（GFM：| … | 次行分隔 ---）
            if trimmed.hasPrefix("|") && i + 1 < lines.count
                && lines[i + 1].trimmingCharacters(in: .whitespaces)
                    .range(of: #"^\|?[\s:|-]+\|?$"#, options: .regularExpression) != nil
                && lines[i + 1].contains("-") {
                flushPara()
                var rows: [[String]] = []
                func splitRow(_ l: String) -> [String] {
                    var s = l.trimmingCharacters(in: .whitespaces)
                    if s.hasPrefix("|") { s.removeFirst() }
                    if s.hasSuffix("|") { s.removeLast() }
                    return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                }
                rows.append(splitRow(line))
                i += 2  // 跳过分隔行
                while i < lines.count && lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(splitRow(lines[i])); i += 1
                }
                blocks.append(.table(rows: rows))
                continue
            }
            // 列表（-/*/+ 或 1.）
            if trimmed.range(of: #"^([-*+]|\d+[.)])\s+"#, options: .regularExpression) != nil {
                flushPara()
                let ordered = trimmed.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) != nil
                var items: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard let r = t.range(of: #"^([-*+]|\d+[.)])\s+"#, options: .regularExpression) else { break }
                    items.append(String(t[r.upperBound...]))
                    i += 1
                }
                blocks.append(.list(ordered: ordered, items: items))
                continue
            }
            // 空行 = 段落分隔
            if trimmed.isEmpty { flushPara(); i += 1; continue }
            para.append(line)
            i += 1
        }
        flushPara()
        return blocks
    }
}

// MARK: - 行内渲染（AttributedString markdown：粗体/斜体/行内代码/链接）

func inlineText(_ s: String) -> Text {
    var options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    if let attr = try? AttributedString(markdown: s, options: options) {
        return Text(attr)
    }
    return Text(s)
}

// MARK: - 代码块轻量高亮（从简但要有：注释/字符串/数字/关键词四类）

private enum CodeHighlighter {
    static let keywords: Set<String> = [
        "func","let","var","if","else","for","while","return","import","from","class","struct",
        "enum","protocol","extension","public","private","internal","static","final","guard",
        "switch","case","default","break","continue","in","try","catch","throw","throws","async",
        "await","def","print","pass","None","True","False","self","self.","new","const","null",
        "undefined","true","false","fn","pub","impl","match","use","mod","where","do","then",
        "elif","with","as","yield","lambda","not","and","or","in","is","raise","except","finally",
    ]

    /// 逐行扫描：// 与 # 注释、"…"/'…' 字符串、数字、关键词。plain 兜底。
    static func highlight(_ code: String, base: Color) -> Text {
        var out = Text("")
        for line in code.components(separatedBy: "\n") {
            out = out + highlightLine(line, base: base) + Text("\n")
        }
        return out
    }

    private static func highlightLine(_ line: String, base: Color) -> Text {
        // 整行注释
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("//") || t.hasPrefix("#") || t.hasPrefix("--") {
            return Text(line).foregroundColor(VTheme.ok)
        }
        var result = Text("")
        var token = ""
        var i = line.startIndex
        func flushToken() {
            guard !token.isEmpty else { return }
            if keywords.contains(token) {
                result = result + Text(token).foregroundColor(VTheme.accentText)
            } else if Double(token) != nil {
                result = result + Text(token).foregroundColor(VTheme.warnText)
            } else {
                result = result + Text(token).foregroundColor(base)
            }
            token = ""
        }
        while i < line.endIndex {
            let c = line[i]
            if c == "\"" || c == "'" {
                flushToken()
                var str = String(c)
                var j = line.index(after: i)
                while j < line.endIndex {
                    let cc = line[j]
                    str.append(cc)
                    j = line.index(after: j)
                    if cc == c { break }
                }
                result = result + Text(str).foregroundColor(VTheme.dangerText)
                i = j
                continue
            }
            if c.isLetter || c == "_" || c.isNumber || c == "." {
                token.append(c)
            } else {
                flushToken()
                if c == "/" {
                    let next = line.index(after: i)
                    if next < line.endIndex && line[next] == "/" {
                        result = result + Text(line[i...]).foregroundColor(VTheme.ok)
                        return result
                    }
                }
                result = result + Text(String(c)).foregroundColor(base)
            }
            i = line.index(after: i)
        }
        flushToken()
        return result
    }
}

// MARK: - 视图

/// 流式 Markdown（现状 StreamingMarkdown）：未闭合围栏按纯文本，闭合后分块渲染。
/// 0.7.7 联调跟进：渲染前先经 ChatTextFilter.stripEmptyThinkBlocks 剔除空
/// think 块（vmodel 路思考内容随 chunk 原文透出，空块是 Qwen 系底座正常产物；
/// 只剥闭合空块，流式中间态未闭合块与非空块原样保留）。
public struct ChatMarkdownView: View {
    public let text: String

    public init(text: String) { self.text = text }

    public var body: some View {
        let filtered = ChatTextFilter.stripEmptyThinkBlocks(text)
        if filtered.isEmpty {
            EmptyView()
        } else if !MarkdownBlocks.fencesBalanced(filtered) {
            // 代码块未闭合 → 整段 pre-wrap 纯文本（避免半截 markdown 抖动）
            Text(filtered)
                .font(VTheme.Typo.msgBody)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(MarkdownBlocks.parse(filtered).enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func blockView(_ block: MDBlock) -> some View {
        switch block {
        case .paragraph(let s):
            inlineText(s)
                .font(VTheme.Typo.msgBody)
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .heading(let level, let s):
            inlineText(s)
                .font(level <= 2 ? VTheme.Typo.sectionTitle : VTheme.Typo.body.weight(.semibold))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        case .code(let lang, let code):
            VStack(alignment: .leading, spacing: 0) {
                if !lang.isEmpty {
                    Text(lang)
                        .font(VTheme.Typo.micro)
                        .foregroundStyle(VTheme.textTertiary)
                        .padding(.horizontal, 10).padding(.top, 6)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    CodeHighlighter.highlight(code, base: VTheme.textPrimary)
                        .font(.system(size: 12.5, design: .monospaced))
                        .lineSpacing(3)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .textSelection(.enabled)
                }
            }
            .background(VTheme.bgHover, in: RoundedRectangle(cornerRadius: VTheme.Radius.s))
            .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.s).stroke(VTheme.borderSubtle))
            .frame(maxWidth: .infinity, alignment: .leading)
        case .list(let ordered, let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text(ordered ? "\(idx + 1)." : "•")
                            .font(VTheme.Typo.msgBody)
                            .foregroundStyle(VTheme.textSecondary)
                            .frame(minWidth: 16, alignment: .trailing)
                        inlineText(item)
                            .font(VTheme.Typo.msgBody)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        case .table(let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                inlineText(cell)
                                    .font(VTheme.Typo.caption)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .frame(maxWidth: 260, alignment: .leading)
                                    .background(r == 0 ? VTheme.bgHover : Color.clear)
                                    .overlay(Rectangle().stroke(VTheme.borderSubtle, lineWidth: 0.5))
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        case .quote(let s):
            HStack(spacing: 8) {
                Rectangle().fill(VTheme.borderStrong).frame(width: 2)
                inlineText(s)
                    .font(VTheme.Typo.caption)
                    .foregroundStyle(VTheme.textSecondary)
                    .textSelection(.enabled)
            }
        case .hr:
            Divider().padding(.vertical, 4)
        }
    }
}
