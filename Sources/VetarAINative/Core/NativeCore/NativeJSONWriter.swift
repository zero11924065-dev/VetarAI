//
//  NativeJSONWriter.swift
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

//  Python `json.dumps(obj, ensure_ascii=False, indent=2)` 的保真复刻。
//  用途：config.json / state.json 落盘字节与侧车写出的文件**逐字节可比**
//  （双跑对照测试直接 diff 文件），Phase 3 接管 ~/.subagent 时不留格式漂移。
//
//  复刻要点（逐条对照 CPython json/encoder.py）：
//    · 键分隔 `": "`，项分隔 `",\n<indent>`；空 dict/list 输出 `{}` / `[]`（无内部空白）
//    · 字符串只转义 " \ 与 <0x20 控制符（\b \f \n \r \t 有简写，其余 \u00xx 小写 hex）；
//      非 ASCII 原样 UTF-8 输出（ensure_ascii=False），/ 不转义
//    · Bool 先于 Int 判定（Python true/false）；Double 整数值补 ".0"（15.0 不落 15），
//      其余走最短往返表示（对齐 Python repr）
//    · 键序：调用方给定有序键清单时照其排列（DEFAULT_CONFIG 顺序），
//      额外键按 UTF-8 字典序追加（Python 侧为磁盘原序——语义等价，字节仅在此情形可能不同，
//      属已知可接受偏差：JSON 对象无序，Python 读回不保序断言）
//

import Foundation

public enum NativeJSONWriter {

    // MARK: - Python json.loads 保真读入

    /// `json.loads(data)` 等价：文本层区分 int/float（`15.0`→double、`15`→int）。
    ///
    /// 为何不用 JSONValue 的 Codable 解码：Darwin Foundation 的 JSONDecoder 对数字
    /// 走 NSNumber 宽松转换，`15.0` 也能 `decode(Int64.self)` 成功 → 浮点默认值
    /// （heartbeat_interval 15.0）落盘回读漂移成 int(15)，与 Python json.loads
    /// 的文本保真（15.0 → float）不等价。JSONSerialization 保留词法类型
    /// （整数 → objCType "q"，带小数点/指数 → "d"，true/false → CFBoolean）。
    public static func loads(_ data: Data) -> JSONValue? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return fromCocoa(obj)
    }

    /// 允许顶层片段（数字/字符串/布尔/null）的 loads 变体。
    ///
    /// Python `json.loads` 接受任意顶层 JSON 值；Foundation JSONSerialization 缺省
    /// 只接受顶层 array/object，片段需显式 `.allowFragments`。code 节点 result 经
    /// JSON 跨进程传出（偏差②），可为任意标量（如 `6`、`"文本"`、`None`→null），
    /// 故读回必须用本变体，否则标量 result 会被误判「未产出」。
    public static func loadsFragment(_ data: Data) -> JSONValue? {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.allowFragments])
        else { return nil }
        return fromCocoa(obj)
    }

    private static func fromCocoa(_ obj: Any) -> JSONValue {
        if obj is NSNull { return .null }
        if let num = obj as? NSNumber {
            // ⚠️ 先判 CFBoolean（true/false 的 NSNumber 桥接；1/0 不属此类）
            if CFGetTypeID(num) == CFBooleanGetTypeID() { return .bool(num.boolValue) }
            let t = String(cString: num.objCType)
            if t == "d" || t == "f" { return .double(num.doubleValue) }
            return .int(num.int64Value)
        }
        if let s = obj as? String { return .string(s) }
        if let arr = obj as? [Any] { return .array(arr.map(fromCocoa)) }
        if let dict = obj as? [String: Any] {
            return .object(dict.mapValues(fromCocoa))
        }
        return .null   // 不可达（JSONSerialization 只产上述类型）；兜底对齐 None
    }

    /// 序列化 JSONValue。`keyOrder` 仅对**首层对象**生效（config.json 即首层对象语义）。
    public static func dumps(_ value: JSONValue, keyOrder: [String]? = nil) -> String {
        var out = ""
        write(value, into: &out, level: 0, keyOrder: keyOrder)
        return out
    }

    /// 有序字典便捷入口（config 用）：keys 顺序 + storage 取值。
    public static func dumpsObject(_ storage: [String: JSONValue], keyOrder: [String]) -> String {
        var out = "{"
        var emitted = Set<String>()
        var first = true
        let orderedKeys = keyOrder.filter { storage[$0] != nil }
            + storage.keys.filter { !keyOrder.contains($0) }.sorted()
        for key in orderedKeys {
            guard let v = storage[key], !emitted.contains(key) else { continue }
            emitted.insert(key)
            if !first { out.append(",") }
            first = false
            out.append("\n  ")
            writeString(key, into: &out)
            out.append(": ")
            write(v, into: &out, level: 1, keyOrder: nil)
        }
        out.append(first ? "}" : "\n}")
        return out
    }

    // MARK: - 递归写出

    private static func write(_ value: JSONValue, into out: inout String, level: Int, keyOrder: [String]?) {
        switch value {
        case .null:
            out.append("null")
        case .bool(let b):
            out.append(b ? "true" : "false")
        case .int(let i):
            out.append(String(i))
        case .double(let d):
            out.append(pyFloatRepr(d))
        case .string(let s):
            writeString(s, into: &out)
        case .array(let arr):
            if arr.isEmpty { out.append("[]"); return }
            out.append("[")
            let pad = String(repeating: "  ", count: level + 1)
            for (idx, item) in arr.enumerated() {
                if idx > 0 { out.append(",") }
                out.append("\n\(pad)")
                write(item, into: &out, level: level + 1, keyOrder: nil)
            }
            out.append("\n\(String(repeating: "  ", count: level))]")
        case .object(let obj):
            if obj.isEmpty { out.append("{}"); return }
            // 嵌套对象：Python 保插入序；JSONValue 无序，排字典序（确定性优先）。
            let keys = obj.keys.sorted()
            out.append("{")
            let pad = String(repeating: "  ", count: level + 1)
            for (idx, key) in keys.enumerated() {
                if idx > 0 { out.append(",") }
                out.append("\n\(pad)")
                writeString(key, into: &out)
                out.append(": ")
                write(obj[key]!, into: &out, level: level + 1, keyOrder: nil)
            }
            out.append("\n\(String(repeating: "  ", count: level))}")
        }
    }

    /// Python json 字符串转义表（ensure_ascii=False）逐字复刻。
    private static func writeString(_ s: String, into out: inout String) {
        out.append("\"")
        for ch in s {
            switch ch {
            case "\"": out.append("\\\"")
            case "\\": out.append("\\\\")
            case "\u{08}": out.append("\\b")
            case "\u{0C}": out.append("\\f")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\t": out.append("\\t")
            default:
                if ch.unicodeScalars.contains(where: { $0.value < 0x20 }) {
                    for scalar in ch.unicodeScalars {
                        out.append(String(format: "\\u%04x", scalar.value))
                    }
                } else {
                    out.append(ch)
                }
            }
        }
        out.append("\"")
    }

    /// Python repr(float) 的常用子集：整数浮点补 .0；其余用 Swift 最短往返表示。
    /// NaN/Inf 在 Python json 中是 `NaN`/`Infinity`（非法 JSON 但 Python 默认放行）——
    /// 本路径的配置/状态值不会出现，遇到按 0.0 兜底并在测试中禁入。
    static func pyFloatRepr(_ d: Double) -> String {
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d > 0 ? "Infinity" : "-Infinity" }
        if d == d.rounded() && abs(d) < 1e16 {
            return String(format: "%.1f", d)   // 15.0 / 300.0 / -2.0
        }
        return String(describing: d)
    }
}
