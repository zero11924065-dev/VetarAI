//
//  XMLMiniDOM.swift
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

/// 轻量 XML DOM（P2-W3b 读取侧）：Foundation XMLParser（SAX）→ 内存节点树。
/// OOXML 部件体量小（document.xml 数 MB 内），整树驻留可接受；
/// 命名空间不展开，节点名保留前缀（"w:p"），属性同名保留（"w:val"）。
public final class XMLNode {
    public let name: String
    public let attributes: [String: String]
    public var children: [XMLNode] = []
    public var text: String = ""

    public init(name: String, attributes: [String: String] = [:]) {
        self.name = name
        self.attributes = attributes
    }

    /// 首个匹配直接子节点。
    public func child(_ name: String) -> XMLNode? {
        children.first { $0.name == name }
    }

    /// 全部匹配直接子节点。
    public func childrenNamed(_ name: String) -> [XMLNode] {
        children.filter { $0.name == name }
    }

    /// 深度优先收集全部后代文本（w:p 段落文本 = 其下全部 w:t 拼接，调用方按元素过滤）。
    public func descendantText() -> String {
        var out = text
        for c in children { out += c.descendantText() }
        return out
    }

    /// 深度优先找全部匹配后代（不含自身）。
    public func descendants(_ name: String) -> [XMLNode] {
        var out: [XMLNode] = []
        for c in children {
            if c.name == name { out.append(c) }
            out.append(contentsOf: c.descendants(name))
        }
        return out
    }
}

public enum XMLMiniDOMError: Error {
    case parseFailed(line: Int, message: String)
    case emptyDocument
}

public enum XMLMiniDOM {
    /// 解析 XML 数据为节点树（根元素）。
    public static func parse(_ data: Data) throws -> XMLNode {
        let delegate = TreeBuilder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else {
            let err = parser.parserError
            throw XMLMiniDOMError.parseFailed(line: parser.lineNumber,
                                              message: err?.localizedDescription ?? "unknown")
        }
        guard let root = delegate.root else { throw XMLMiniDOMError.emptyDocument }
        return root
    }

    public static func parse(_ string: String) throws -> XMLNode {
        try parse(Data(string.utf8))
    }
}

private final class TreeBuilder: NSObject, XMLParserDelegate {
    private var stack: [XMLNode] = []
    private(set) var root: XMLNode?

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let node = XMLNode(name: elementName, attributes: attributeDict)
        if let parent = stack.last {
            parent.children.append(node)
        } else {
            root = node
        }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard let last = stack.last else { return }
        last.text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        _ = stack.popLast()
    }

    // CDATA 与实体由 XMLParser 合并进 foundCharacters；忽略注释/PI。
}
