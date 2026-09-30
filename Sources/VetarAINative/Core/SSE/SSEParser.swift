//
//  SSEParser.swift
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

//  SSE 事件解析器：纯 Swift 值类型，无网络依赖，可单测。
//  语义逐条对齐 subagent/renderer/src/lib/sseParser.ts（前端现行契约）：
//    · 事件块以空行分隔（\n\n 与 \r\n\r\n 均识别，取靠后者消费）
//    · 块内 `event:` 取类型；`data:` 多行拼接（剥离 data: 后任意数量空格）
//    · `:` 开头为注释/心跳行，忽略
//    · 缺 event 行 → 默认 "message"；空 data → data 为空字典
//    · data JSON 解析失败 → data = ["raw": 原文]，不抛异常
//    · data JSON 为非对象（如数字/数组）→ data = ["value": 解析值]
//    · `data: [DONE]`（OpenAI 式终止哨兵，侧车当前不发）→ isDoneSentinel = true
//

import Foundation

/// 一条 SSE 事件。data 为 JSON 对象解码后的字典；解析失败时退化见上。
public struct SSEEvent {
    public let event: String
    public let data: [String: Any]
    /// data: 行的原始拼接文本（JSON 未解析）；空 data 时为空串。
    public let rawData: String

    public init(event: String, data: [String: Any], rawData: String) {
        self.event = event
        self.data = data
        self.rawData = rawData
    }

    /// OpenAI 式 `[DONE]` 终止哨兵（侧车实际用 `event: done`，此属性为兼容预留）。
    public var isDoneSentinel: Bool { rawData == "[DONE]" }

    // MARK: 便捷取值（SSE data 来自 JSONSerialization，数字为 NSNumber）
    public func string(_ key: String) -> String? { data[key] as? String }
    public func int(_ key: String) -> Int? {
        if let n = data[key] as? NSNumber { return n.intValue }
        return data[key] as? Int
    }
    public func bool(_ key: String) -> Bool? {
        if let n = data[key] as? NSNumber { return n.boolValue }
        return data[key] as? Bool
    }
    /// 浮点取值（0.7.5 W7：下载速率等 Double 字段；int() 会截断故单列）
    public func double(_ key: String) -> Double? {
        if let n = data[key] as? NSNumber { return n.doubleValue }
        return data[key] as? Double
    }
}

/// 增量 SSE 解析器：跨分片维护行缓冲，只按完整事件块产出。
public struct SSEParser {
    private var buffer = ""

    public init() {}

    /// 喂入一段文本分片，返回本批新解析出的完整事件。
    /// 与前端 SSEStreamParser.push 同口径：分隔符未到则留存尾部，避免半截事件误解析。
    public mutating func push(_ text: String) -> [SSEEvent] {
        buffer += text
        guard let cut = Self.lastDelimiterEnd(in: buffer) else { return [] }
        let consumable = String(buffer.prefix(cut))
        buffer = String(buffer.suffix(buffer.count - cut))
        return Self.parseChunk(consumable)
    }

    /// 流结束时冲刷残留缓冲（侧车正常收尾总会带结尾空行，flush 是兜底）。
    public mutating func flush() -> [SSEEvent] {
        guard !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            buffer = ""
            return []
        }
        let rest = buffer
        buffer = ""
        return Self.parseChunk(rest)
    }

    /// 找最后一个事件分隔符（\n\n 或 \r\n\r\n）的结束偏移；无则 nil。
    /// 与 TS 版一致：两者都命中时取「消费位置更靠后」的那个。
    static func lastDelimiterEnd(in s: String) -> Int? {
        let lf = s.range(of: "\n\n", options: .backwards)
        let crlf = s.range(of: "\r\n\r\n", options: .backwards)
        if lf == nil && crlf == nil { return nil }
        let lfEnd = lf.map { s.distance(from: s.startIndex, to: $0.upperBound) } ?? -1
        let crlfEnd = crlf.map { s.distance(from: s.startIndex, to: $0.upperBound) } ?? -1
        return max(lfEnd, crlfEnd)
    }

    /// 解析一段（可能含多个完整事件的）文本块。等价前端 parseSSEChunk。
    public static func parseChunk(_ chunk: String) -> [SSEEvent] {
        let normalized = chunk.replacingOccurrences(of: "\r\n", with: "\n")
        var events: [SSEEvent] = []
        for block in normalized.components(separatedBy: "\n\n") {
            guard !block.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            var type = ""
            var dataLines: [String] = []
            for line in block.components(separatedBy: "\n") {
                if line.hasPrefix(":") { continue }                 // 注释/心跳
                if line.hasPrefix("event:") {
                    type = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("data:") {
                    // TS-102 B16：剥离 data: 后任意数量前导空格
                    var payload = String(line.dropFirst(5))
                    while payload.hasPrefix(" ") { payload.removeFirst() }
                    dataLines.append(payload)
                }
            }
            if type.isEmpty && dataLines.isEmpty { continue }
            if type.isEmpty { type = "message" }
            let raw = dataLines.joined(separator: "\n")
            var data: [String: Any] = [:]
            if !raw.isEmpty {
                if let parsed = try? JSONSerialization.jsonObject(with: Data(raw.utf8),
                                                                  options: [.fragmentsAllowed]) {
                    if let obj = parsed as? [String: Any] {
                        data = obj
                    } else {
                        data = ["value": parsed]
                    }
                } else {
                    data = ["raw": raw]
                }
            }
            events.append(SSEEvent(event: type, data: data, rawData: raw))
        }
        return events
    }
}

/// 增量 UTF-8 解码器：URLSession 字节块可能在多字节字符中间切断，
/// 先把残尾字节留存，凑齐完整标量后再交付字符串（非法字节兜底为 U+FFFD）。
public struct UTF8StreamDecoder {
    private var leftover = Data()

    public init() {}

    public mutating func push(_ bytes: [UInt8]) -> String {
        guard !bytes.isEmpty else { return "" }
        leftover.append(contentsOf: bytes)
        // 一个不完整 UTF-8 序列的残尾至多 3 字节：依次尝试整段、去尾 1~3 字节解码。
        for drop in 0..<min(4, leftover.count) {
            let head = drop == 0 ? leftover : leftover.dropLast(drop)
            if let s = String(data: head, encoding: .utf8) {
                leftover = drop == 0 ? Data() : Data(leftover.suffix(drop))
                return s
            }
        }
        // 含真正非法字节（非截断）→ 带替换符整体解码，清空缓冲
        let s = String(decoding: leftover, as: UTF8.self)
        leftover = Data()
        return s
    }

    /// 流结束冲刷：残尾（若有）以替换符解码。
    public mutating func finish() -> String {
        guard !leftover.isEmpty else { return "" }
        let s = String(decoding: leftover, as: UTF8.self)
        leftover = Data()
        return s
    }
}
