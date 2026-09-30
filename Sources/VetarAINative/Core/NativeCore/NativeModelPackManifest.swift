//
//  NativeModelPackManifest.swift
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

//  逐行为移植（⛔ 只读行为规格源：subagent/sidecar/model_packs/manifest.py，230 行；
//  纯函数，无 IO、无配置依赖）：
//    · 枚举域 TASKS/FORMATS/DRIVERS 与 CATALOG_VERSION=1（L48-52）
//    · valid_pack_id（L68-70）：slug 小写字母/数字/-/_，1~64 长
//    · validate_rel_path（L73-110）：七类拒绝（非串/空、绝对路径三形态、反斜杠、
//      ./.. 段、空段、控制字符、保留名 manifest.json 与 .partial/）——校验**拒绝**
//      而非净化（清单来自外部源，净化会静默改路径导致下载落点与声明不符）
//    · validate_pack（L144-205）：全字段校验 + files[] 逐条 + path 去重 +
//      size_bytes=Σfiles 一致性；错误文案逐字（字段/期望/实际值三件套）
//    · validate_catalog（L208-230）：version==1 + packs 数组 + pack_id 跨条去重
//
//  偏差：无（纯函数逐字；Python len()/切片按码点计 → Swift unicodeScalars 同口径，
//  与 NativeAgentLoop.pyPrefix 先例一致）。
//

import Foundation

public enum NativeModelPackManifest {

    // 枚举域（L48-50；新任务类型/格式/驱动随应用版本扩展）
    public static let tasks = ["asr", "chat", "embedding"]
    public static let formats = ["onnx", "gguf"]
    public static let drivers = ["onnxruntime", "llamacpp"]
    public static let catalogVersion = 1

    /// _REL_PATH_MAX（L60）：相对路径长度上限（码点计）。
    public static let relPathMax = 240
    /// _SOURCE_SCHEMES（L65）：允许的来源 URL scheme。
    public static let sourceSchemes = ["http://", "https://", "file://"]

    // MARK: - valid_pack_id（L68-70）

    /// pack_id 是否为合法 slug（小写字母数字 `-` `_`，1~64 长）。
    public static func validPackId(_ s: String) -> Bool {
        s.range(of: #"^[a-z0-9_-]{1,64}$"#, options: .regularExpression) != nil
    }

    /// JSONValue 形态（isinstance(pack_id, str) 前置）。
    public static func validPackId(_ v: JSONValue?) -> Bool {
        guard case .string(let s) = v else { return false }
        return validPackId(s)
    }

    // MARK: - validate_rel_path（L73-110）

    /// 校验 files[].path 为安全的相对路径。合法返回 nil，非法返回中文错误文案（逐字）。
    public static func validateRelPath(_ v: JSONValue?) -> String? {
        guard case .string(let path) = v, !path.isEmpty else {
            return "files[].path 必须是非空字符串（相对路径）"
        }
        let r = PySem.reprString(path)
        // Python len() 按码点；_REL_PATH_MAX 上限（L87-88：path[:40] 截断同理）
        if path.unicodeScalars.count > relPathMax {
            return "files[].path 超过 \(relPathMax) 字符上限: "
                + PySem.reprString(String(path.unicodeScalars.prefix(40))) + "..."
        }
        // 控制字符（含 NUL，0~31 与 127）
        if path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) {
            return "files[].path 含控制字符: \(r)"
        }
        if path.contains("\\") {
            return "files[].path 含反斜杠（路径分隔符统一为 /）: \(r)"
        }
        if path.hasPrefix("/") {
            return "files[].path 不允许绝对路径: \(r)"
        }
        // Windows 盘符（C:/x）与 UNC 形态在 POSIX 字符串里不以 / 开头，单独挡
        let chars = Array(path)
        if chars.count >= 2, chars[1] == ":", chars[0].isLetter {
            return "files[].path 不允许 Windows 盘符绝对路径: \(r)"
        }
        if path != path.trimmingCharacters(in: .whitespacesAndNewlines) {
            return "files[].path 首尾含空白字符: \(r)"
        }
        let segs = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for seg in segs {
            if seg.isEmpty {
                return "files[].path 含空路径段（形如 a//b）: \(r)"
            }
            if seg == "." || seg == ".." {
                return "files[].path 含 '\(seg)' 段（路径穿越风险）: \(r)"
            }
        }
        if segs.first == ".partial" {
            return "files[].path 占用保留目录 .partial/: \(r)"
        }
        if path == "manifest.json" {
            return "files[].path 占用保留名 manifest.json（安装时写入的清单副本）"
        }
        return nil
    }

    // MARK: - 内部判定

    /// _is_pos_int（L113-115）：int 非 bool 且 >0（bool 是 int 子类，语义上非法）。
    static func isPosInt(_ v: JSONValue?) -> Bool {
        guard case .int(let i) = v else { return false }
        return i > 0
    }

    /// _SHA256_RE（L118）：64 位十六进制。
    static func isSHA256(_ s: String) -> Bool {
        s.range(of: #"^[0-9a-fA-F]{64}$"#, options: .regularExpression) != nil
    }

    /// type(v).__name__（L172）：JSONValue → Python 类型名。
    static func pyTypeName(_ v: JSONValue?) -> String {
        guard let v else { return "NoneType" }
        switch v {
        case .null: return "NoneType"
        case .bool: return "bool"
        case .int: return "int"
        case .double: return "float"
        case .string: return "str"
        case .array: return "list"
        case .object: return "dict"
        }
    }

    /// str(v)[:n]（码点截断；{x!r} 前的 str() 化）。
    static func strPrefix(_ v: JSONValue?, _ n: Int) -> String {
        let s = v.map(WFText.pyStr) ?? "None"
        return String(s.unicodeScalars.prefix(n))
    }

    // MARK: - _validate_file_entry（L121-141）

    static func validateFileEntry(_ f: JSONValue?, idx: Int, into errors: inout [String]) {
        let tag = "files[\(idx)]"
        guard case .object(let fo) = f else {
            errors.append("\(tag) 必须是对象")
            return
        }
        if let pErr = validateRelPath(fo["path"]) {
            // p_err.replace("files[]", tag, 1)
            errors.append(pErr.replacingOccurrences(of: "files[]", with: tag))
        }
        if !isPosInt(fo["size_bytes"]) {
            errors.append("\(tag).size_bytes 必须是正整数（得到 \(PySem.repr(fo["size_bytes"] ?? .null))）")
        }
        let sha = fo["sha256"]
        let shaOK: Bool = { if case .string(let s) = sha { return isSHA256(s) }; return false }()
        if !shaOK {
            errors.append("\(tag).sha256 必须是 64 位十六进制字符串（得到 \(PySem.reprString(strPrefix(sha, 40)))）")
        }
        guard case .array(let sources) = fo["sources"], !sources.isEmpty else {
            errors.append("\(tag).sources 必须是非空 URL 数组（多源按序回退）")
            return
        }
        for (si, s) in sources.enumerated() {
            guard case .string(let url) = s,
                  sourceSchemes.contains(where: { url.hasPrefix($0) }) else {
                errors.append("\(tag).sources[\(si)] 必须是 http(s):// 或 file:// URL"
                    + "（得到 \(PySem.reprString(strPrefix(s, 60)))）")
                continue
            }
        }
    }

    // MARK: - validate_pack（L144-205）

    /// 校验单个 PACK 条目，返回错误文案列表（空 = 合法）。
    public static func validatePack(_ v: JSONValue?) -> [String] {
        guard case .object(let pack) = v else { return ["pack 条目必须是对象"] }
        var errors: [String] = []
        if !validPackId(pack["pack_id"]) {
            errors.append("pack_id 必须是 slug（小写字母/数字/-/_，1~64 长），得到 "
                + PySem.reprString(strPrefix(pack["pack_id"], 40)))
        }
        if case .string(let name) = pack["name"],
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {} else {
            errors.append("name 必须是非空字符串")
        }
        let task = pack["task"]
        if case .string(let t) = task, tasks.contains(t) {} else {
            errors.append("task 必须是 \(tasks.joined(separator: "/")) 之一，得到 \(PySem.repr(task ?? .null))")
        }
        let fmt = pack["format"]
        if case .string(let f) = fmt, formats.contains(f) {} else {
            errors.append("format 必须是 \(formats.joined(separator: "/")) 之一，得到 \(PySem.repr(fmt ?? .null))")
        }
        let drv = pack["driver"]
        if case .string(let d) = drv, drivers.contains(d) {} else {
            errors.append("driver 必须是 \(drivers.joined(separator: "/")) 之一，得到 \(PySem.repr(drv ?? .null))")
        }
        if case .string(let ver) = pack["version"],
           !ver.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {} else {
            errors.append("version 必须是非空字符串（语义化版本，如 1.0.0）")
        }
        for opt in ["description", "min_app_version", "homepage", "license"] {
            let v = pack[opt] ?? .string("")   // pack.get(opt, "")
            if case .string = v {} else {
                errors.append("\(opt) 必须是字符串（可空），得到 \(pyTypeName(v))")
            }
        }
        if !isPosInt(pack["size_bytes"]) {
            errors.append("size_bytes 必须是正整数（包总字节数），得到 \(PySem.repr(pack["size_bytes"] ?? .null))")
        }
        // context_length：可选键（写了就必须是正整数；整键省略才合法）
        if let cl = pack["context_length"], !isPosInt(cl) {
            errors.append("context_length 必须是正整数（可选键，不需要请整键省略），得到 \(PySem.repr(cl))")
        }
        // sample_rate：可选键（ASR 包；同口径）
        if let sr = pack["sample_rate"], !isPosInt(sr) {
            errors.append("sample_rate 必须是正整数（可选键，不需要请整键省略），得到 \(PySem.repr(sr))")
        }
        guard case .array(let files) = pack["files"], !files.isEmpty else {
            errors.append("files 必须是非空数组（多文件是硬需求：模型本体+tokenizer 等）")
            return errors
        }
        var seenPaths: Set<String> = []
        for (i, f) in files.enumerated() {
            validateFileEntry(f, idx: i, into: &errors)
            if case .object(let fo) = f, case .string(let p) = fo["path"] {
                if seenPaths.contains(p) {
                    errors.append("files[\(i)].path 重复: \(PySem.reprString(p))")
                }
                seenPaths.insert(p)
            }
        }
        // 一致性：pack.size_bytes 应等于 files 之和（各字段错误各自独立报告）
        if isPosInt(pack["size_bytes"]),
           files.allSatisfy({ isPosInt($0.object?["size_bytes"]) }),
           case .int(let declared) = pack["size_bytes"] {
            let total = files.reduce(Int64(0)) { acc, f in
                acc + (f.object?["size_bytes"]?.int ?? 0)
            }
            if total != declared {
                errors.append("size_bytes(\(declared)) 与 files 之和(\(total)) 不一致")
            }
        }
        return errors
    }

    // MARK: - validate_catalog（L208-230）

    /// 校验整个 catalog.json，返回错误文案列表（空 = 合法）。
    public static func validateCatalog(_ v: JSONValue?) -> [String] {
        guard case .object(let data) = v else { return ["catalog 必须是 JSON 对象"] }
        var errors: [String] = []
        if data["version"] != .int(Int64(catalogVersion)) {
            errors.append("catalog.version 必须是 \(catalogVersion)，得到 \(PySem.repr(data["version"] ?? .null))")
        }
        guard case .array(let packs) = data["packs"] else {
            errors.append("catalog.packs 必须是数组")
            return errors
        }
        var seenIds: Set<String> = []
        for (i, p) in packs.enumerated() {
            for e in validatePack(p) {
                errors.append("packs[\(i)]: \(e)")
            }
            if case .object(let po) = p, case .string(let pid) = po["pack_id"] {
                if seenIds.contains(pid) {
                    errors.append("packs[\(i)]: pack_id 重复: \(PySem.reprString(pid))")
                }
                seenIds.insert(pid)
            }
        }
        return errors
    }
}
