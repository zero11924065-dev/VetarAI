//
//  NativeModelScopeInstaller.swift
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

//  链路：粘贴输入 → 解析 org/name → 官方 API 拉仓库文件列表+license →
//    识别可运行格式（GGUF 仓 / MLX 仓；其余「暂不支持该格式」）→ 用户选档位 →
//    复用 NativeModelDownloader（0.7.4 W2：Range 续传/低速换源/SHA256/原子落位/
//    速率上屏）下载 → 落模型包目录 + manifest.json + 登记 registry ——
//    安装后与 ollama/应用内模型/.vmodel 全场景平级可选（GGUF 走 llama.cpp 驱动链；
//    MLX 仓 0.7.7 W3 起走 NativeMPMLXDriver → mlx-swift-lm 进程内链，闭环同级）。
//
//  官方 API 端点形态（2026-09-27 curl 实测，国内直连可达，无需鉴权）：
//    · 文件列表 GET https://modelscope.cn/api/v1/models/{org}/{name}/repo/files?Recursive=true
//      → {"Code":200,"Data":{"Files":[{"Path","Size","Sha256","Type":"blob","IsLFS",…}]}}
//      ⚠️VERIFY 复核结论：Code==200 为成功；Sha256 字段实测即文件内容 SHA-256
//      （小文件 configuration.json 下载比对一致），可直接作下载校验值。
//    · 模型信息 GET https://modelscope.cn/api/v1/models/{org}/{name}
//      → {"Code":200,"Data":{"License":"apache-2.0",…}}（License 可能为空串）
//    · 单文件直下 https://modelscope.cn/api/v1/models/{org}/{name}/resolve/master/{path}
//      （支持重定向/Range 断点续传，与 W2 分块下载器同栈）
//
//  合规红线（REQ-FUT-021 拍板）：只走官方接口直下，不抓页面 HTML、不转存再分发；
//  安装界面展示 license 标签 + 源链接 +「许可由模型作者定义，商用前请自查」提示
//  （UI 层文案常量见 complianceNotice）。
//

import Foundation

// ════════════════════════════════════════════════════════════
// MARK: - 输入解析（三形态 → org/name）
// ════════════════════════════════════════════════════════════

/// 魔塔仓库引用（org + name 均已校验字符集：字母/数字/./_/-）
public struct ModelScopeRepoRef: Equatable, Sendable {
    public let org: String
    public let name: String
    /// 模型页链接（源链接展示用）
    public var pageURL: String { "https://modelscope.cn/models/\(org)/\(name)" }
}

public enum NativeModelScopeError: LocalizedError, Equatable {
    case unparseableInput
    case httpStatus(Int)
    case apiError(String)
    case emptyRepo
    case unsupportedFormat(String)
    case unsafePath(String)
    /// 0.7.7 W3：MLX 仓落盘后完整性校验不过（config.json 缺失/不可解析/未声明
    /// model_type、权重未落位、分片索引引用缺件；文案自持）。
    case incompleteMLX(String)

    public var errorDescription: String? {
        switch self {
        case .unparseableInput:
            return "无法识别输入——请粘贴魔塔模型页链接（https://modelscope.cn/models/组织/模型名）、"
                + "ollama 风格标识（modelscope.cn/组织/模型名）或 SDK 代码片段（如 snapshot_download('组织/模型名')）。"
        case .httpStatus(let s): return "魔塔接口返回 HTTP \(s)（仓库不存在或网络异常）"
        case .apiError(let m): return "魔塔接口报错：\(m)"
        case .emptyRepo: return "该魔塔仓库文件列表为空"
        case .unsupportedFormat(let m): return m
        case .unsafePath(let p):
            return "仓库文件列表含不安全路径（疑似路径穿越，已拦截整个模型安装）：\(p)"
        case .incompleteMLX(let m):
            return "MLX 模型仓不完整：\(m)。安装未完成（半成品已清退，可直接重试）；"
                + "若反复失败，说明该仓不适合本机 MLX 推理。"
        }
    }
}

/// M4 修复（0.7.5 收口审查）：API 返回仓库文件路径消毒——org/name 有字符集
/// 白名单，但文件 Path 此前完全信任 API 响应，恶意 "../../registry.json" 可经
/// destDir.appendingPathComponent 解析到模型包目录外。消毒纪律（对齐
/// validSegment 逐段思路）：拒绝绝对路径、反斜杠、空段（含 // 重复段）、
/// "." 段、".." 段；可疑条目整个模型判失败（不静默跳过单文件）。
public enum ModelScopePathSanitizer {

    /// 合法相对路径原样返回；任何可疑形态 → nil（调用层抛 unsafePath）
    public static func sanitize(_ path: String) -> String? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return nil }
        let segs = path.split(separator: "/", omittingEmptySubsequences: false)
        for seg in segs {
            if seg.isEmpty || seg == "." || seg == ".." { return nil }
        }
        return path
    }

    /// 规范化拼接落盘 URL 并校验仍落在 base 内（纵深防御：即使上游漏消毒，
    /// standardizedFileURL 归一后越界必被拦）。
    public static func containedURL(base: URL, relativePath: String) -> URL? {
        guard sanitize(relativePath) != nil else { return nil }
        let dest = base.appendingPathComponent(relativePath).standardizedFileURL
        var basePath = base.standardizedFileURL.path
        if !basePath.hasSuffix("/") { basePath += "/" }
        guard dest.path.hasPrefix(basePath) else { return nil }
        return dest
    }

    /// W11（L6，0.7.5 收口审查）：下载 URL 用逐段百分号编码——含空格/非 ASCII
    /// 文件名的仓库直链 URL(string:) 返 nil 必败（URLError.badURL）。
    /// 顺序铁律：先消毒（M4，拒 ../绝对路径/反斜杠/空段）再编码——反了会把
    /// ".." 编成 %2E%2E 躲过逐段消毒比对。消毒不过 → nil（调用层按诚实失败处理）。
    /// 逐段而非整串：段内结构性地不可能含 "/"（.urlPathAllowed 保 "/" 的隐患
    /// 从结构排除）；字面量 "%" 编成 %25（已编码形态文件名经服务端一次解码
    /// 还原，语义正确——不会出现双重解码错位）。
    public static func urlEncodedPath(_ path: String) -> String? {
        guard sanitize(path) != nil else { return nil }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
                ?? String($0) }
            .joined(separator: "/")
    }
}

public enum ModelScopeLinkParser {

    /// org/name 合法字符集（防路径穿越与注入：拒绝 /、..、空白等）
    private static let segmentPattern = #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#

    static func validSegment(_ s: String) -> Bool {
        s.range(of: segmentPattern, options: .regularExpression) != nil
            && !s.contains("..")
    }

    /// 三形态解析：
    ///   ① 模型页链接 https://modelscope.cn/models/{org}/{name}（可带尾缀路径/参数）
    ///   ② ollama 风格 modelscope.cn/{org}/{name}
    ///   ③ SDK 代码片段中抠出的 org/name（snapshot_download('org/name') 等；裸 org/name 同收）
    /// 非法/抠不出 → nil（调用层映 unparseableInput）。
    public static func parse(_ input0: String) -> ModelScopeRepoRef? {
        let input = input0.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }

        // 形态①：模型页链接（http/https 均可，www. 前缀容忍）
        if let m = firstMatch(#"modelscope\.cn/models/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)"#, in: input) {
            return makeRef(m.0, m.1)
        }
        // 形态②：ollama 风格 modelscope.cn/{org}/{name}（不带 /models/ 段）
        if let m = firstMatch(#"modelscope\.cn/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)"#, in: input) {
            return makeRef(m.0, m.1)
        }
        // 形态③：SDK 片段/裸标识——抠引号内或裸的 org/name token
        //   snapshot_download('Qwen/Qwen2.5-0.5B-Instruct-GGUF')
        //   snapshot_download(model_id="Qwen/Qwen2.5-0.5B-Instruct-GGUF", ...)
        //   from modelscope import ...; ... 'org/name'
        if let m = firstMatch(#"["']([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)["']"#, in: input) {
            return makeRef(m.0, m.1)
        }
        // 裸 org/name（整串即标识；输入含空白/多段时拒收，防把散文首词当仓库）
        if !input.contains(where: { $0.isWhitespace }),
           let m = firstMatch(#"^([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)/?$"#, in: input) {
            return makeRef(m.0, m.1)
        }
        return nil
    }

    private static func makeRef(_ org: String, _ name: String) -> ModelScopeRepoRef? {
        guard validSegment(org), validSegment(name) else { return nil }
        return ModelScopeRepoRef(org: org, name: name)
    }

    /// 首个正则命中返回两个捕获组
    private static func firstMatch(_ pattern: String, in s: String) -> (String, String)? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              m.numberOfRanges >= 3,
              let r1 = Range(m.range(at: 1), in: s),
              let r2 = Range(m.range(at: 2), in: s) else { return nil }
        return (String(s[r1]), String(s[r2]))
    }
}

// ════════════════════════════════════════════════════════════
// MARK: - 官方 API：端点 / 解码（纯函数，网络走注入缝）
// ════════════════════════════════════════════════════════════

/// 仓库单文件条目（只留安装所需字段；LFS 标记展示用）
public struct ModelScopeRepoFile: Equatable, Sendable {
    public let path: String
    public let sizeBytes: Int64
    public let sha256: String
    public let isLFS: Bool
}

public enum ModelScopeAPI {

    public static let base = "https://modelscope.cn"

    /// 仓库文件列表端点（实测形态见文件头注）
    public static func filesURL(_ ref: ModelScopeRepoRef) -> String {
        "\(base)/api/v1/models/\(ref.org)/\(ref.name)/repo/files?Recursive=true"
    }

    /// 模型信息端点（license 标签来源）
    public static func infoURL(_ ref: ModelScopeRepoRef) -> String {
        "\(base)/api/v1/models/\(ref.org)/\(ref.name)"
    }

    /// 单文件直链（resolve/master 支持重定向/Range 续传）。
    /// W11（L6）：path 经 ModelScopePathSanitizer.urlEncodedPath 逐段编码
    /// （先消毒后编码，顺序铁律见该函数注释）。消毒不过属 M4 双防线漏网
    /// （decodeFiles 入库消毒 + install 落盘前校验已先拦）——退回原样插值，
    /// 维持诚实失败不静默。
    public static func resolveURL(_ ref: ModelScopeRepoRef, path: String) -> String {
        let encoded = ModelScopePathSanitizer.urlEncodedPath(path) ?? path
        return "\(base)/api/v1/models/\(ref.org)/\(ref.name)/resolve/master/\(encoded)"
    }

    /// 文件列表响应解码：{"Code":200,"Data":{"Files":[…]}}；Code≠200 → apiError(Message)。
    /// 只收 Type=="blob" 条目（tree 目录行跳过）；Sha256 小写化。
    public static func decodeFiles(_ data: Data) throws -> [ModelScopeRepoFile] {
        guard let root = NativeJSONWriter.loads(data), case .object(let o) = root else {
            throw NativeModelScopeError.apiError("响应不是合法 JSON")
        }
        let code = o["Code"].flatMap(PySem.toFloat).map { Int($0) } ?? 0
        guard code == 200 else {
            let msg = o["Message"]?.string ?? "Code=\(code)"
            throw NativeModelScopeError.apiError(msg)
        }
        guard case .object(let d)? = o["Data"], case .array(let files)? = d["Files"] else {
            throw NativeModelScopeError.apiError("响应缺 Data.Files")
        }
        var out: [ModelScopeRepoFile] = []
        for f in files {
            guard case .object(let fo) = f,
                  case .string(let path) = fo["Path"],
                  (fo["Type"]?.string ?? "blob") == "blob" else { continue }
            // M4：入库前逐路径消毒——可疑条目整个模型判失败（不静默跳过单文件）
            guard let safePath = ModelScopePathSanitizer.sanitize(path) else {
                throw NativeModelScopeError.unsafePath(path)
            }
            let size = fo["Size"].flatMap(PySem.toFloat).map { Int64($0) } ?? 0
            let sha = (fo["Sha256"]?.string ?? "").lowercased()
            let lfs = fo["IsLFS"]?.bool ?? false
            out.append(ModelScopeRepoFile(path: safePath, sizeBytes: size,
                                          sha256: sha, isLFS: lfs))
        }
        if out.isEmpty { throw NativeModelScopeError.emptyRepo }
        return out
    }

    /// 模型信息响应解码 license 标签（空/缺失 → 空串，UI 显示「未标注」）
    public static func decodeLicense(_ data: Data) -> String {
        guard let root = NativeJSONWriter.loads(data), case .object(let o) = root,
              case .object(let d)? = o["Data"] else { return "" }
        return (d["License"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// ════════════════════════════════════════════════════════════
// MARK: - 格式识别与档位组装（纯逻辑）
// ════════════════════════════════════════════════════════════

/// 可运行格式族（REQ-FUT-021 红线：仅 GGUF/MLX 两族，端侧不做转换）
public enum ModelScopeFormat: String, Equatable, Sendable {
    case gguf
    case mlx
}

/// 可选档位：GGUF 仓每个 .gguf 文件一档；MLX 仓整仓权重+配置为一档
public struct ModelScopeVariant: Equatable, Sendable {
    public let id: String            // 档位标识（GGUF=文件名主干；MLX="mlx"）
    public let title: String         // 展示名
    public let format: ModelScopeFormat
    public let files: [ModelScopeRepoFile]
    public var totalBytes: Int64 { files.reduce(Int64(0)) { $0 + $1.sizeBytes } }
}

public enum ModelScopeFormatDetector {

    /// MLX 仓随权重一并下载的配置/分词文件白名单（存在才收；mlx-swift-lm 装载要件；
    /// 分片权重的 model.safetensors.index.json 必收，否则分片仓载不动）
    static let mlxAuxFiles: [String] = [
        "config.json", "generation_config.json",
        "model.safetensors.index.json",
        "tokenizer.json", "tokenizer.model", "tokenizer_config.json",
        "special_tokens_map.json", "chat_template.jinja", "added_tokens.json",
        "merges.txt", "vocab.json",
    ]

    /// 识别仓库可运行格式并组装档位。GGUF 优先（同仓两族并存按 GGUF 族处理——
    /// 一档一文件语义最清晰）；皆无 → unsupportedFormat（文案含两族说明）。
    public static func detectVariants(files: [ModelScopeRepoFile]) throws -> [ModelScopeVariant] {
        let ggufs = files
            .filter { $0.path.lowercased().hasSuffix(".gguf") }
            .sorted { $0.path < $1.path }
        if !ggufs.isEmpty {
            return ggufs.map { f in
                let stem = (f.path as NSString).lastPathComponent
                let title = stem.replacingOccurrences(of: ".gguf", with: "", options: .caseInsensitive)
                return ModelScopeVariant(id: title, title: title, format: .gguf, files: [f])
            }
        }
        let hasConfig = files.contains { $0.path == "config.json" }
        let tensors = files.filter { $0.path.lowercased().hasSuffix(".safetensors") }
            .sorted { $0.path < $1.path }
        if hasConfig, !tensors.isEmpty {
            let aux = files.filter { Self.mlxAuxFiles.contains($0.path) && $0.path != "config.json" }
            let picked = (tensors + files.filter { $0.path == "config.json" } + aux)
            return [ModelScopeVariant(id: "mlx", title: "MLX 整仓（safetensors）",
                                      format: .mlx, files: picked)]
        }
        throw NativeModelScopeError.unsupportedFormat(
            "暂不支持该格式——当前仅支持 GGUF 仓（llama.cpp 直跑）与 MLX 仓"
            + "（safetensors+config.json，mlx-swift-lm 可载）两族；"
            + "PyTorch 原始权重等格式端侧不做转换。")
    }
}

// ════════════════════════════════════════════════════════════
// MARK: - 清单组装（档位 → 模型包 manifest / 下载 specs）
// ════════════════════════════════════════════════════════════

public enum ModelScopeManifestBuilder {

    /// pack_id：ms-<org>-<name>[-<档位>] 的 slug 化（小写字母/数字/-/_，≤64，
    /// 对齐 NativeModelPackManifest.validPackId 口径）
    public static func packId(ref: ModelScopeRepoRef, variant: ModelScopeVariant) -> String {
        let base = variant.format == .gguf
            ? "ms-\(ref.org)-\(ref.name)-\(variant.id)"
            : "ms-\(ref.org)-\(ref.name)"
        return slug(base)
    }

    static func slug(_ s: String) -> String {
        var out = ""
        var lastDash = false
        for ch in s.lowercased() {
            let ok = ch.isASCII && (ch.isLetter || ch.isNumber || ch == "-" || ch == "_")
            if ok {
                out.append(ch); lastDash = false
            } else if !lastDash, !out.isEmpty {
                out.append("-"); lastDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        if out.count > 64 { out = String(out.prefix(64)) }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    /// 档位 → NativeModelDownloader 清单（sources = 官方 resolve 直链）
    public static func fileSpecs(ref: ModelScopeRepoRef,
                                 variant: ModelScopeVariant) -> [RequiredFileSpec] {
        variant.files.map { f in
            RequiredFileSpec(path: f.path, sizeBytes: f.sizeBytes,
                             sha256: f.sha256.lowercased(),
                             sources: [ModelScopeAPI.resolveURL(ref, path: f.path)])
        }
    }

    /// 档位 → 模型包 manifest（registerPack 与 manifest.json 副本共用此对象）。
    /// GGUF → format=gguf / driver=llamacpp（llama.cpp 链装载）；
    /// MLX  → format=mlx / driver=mlxswift（0.7.7 W3 起接通：NativeMPChatConnector
    /// 按本键分派 NativeMPMLXDriver → mlx-swift-lm 进程内装载推理）。
    public static func packManifest(ref: ModelScopeRepoRef, variant: ModelScopeVariant,
                                    license: String) -> [String: JSONValue] {
        let pid = packId(ref: ref, variant: variant)
        let format = variant.format == .gguf ? "gguf" : "mlx"
        let driver = variant.format == .gguf ? "llamacpp" : "mlxswift"
        let lic = license.isEmpty ? "未标注" : license
        var desc = "来自魔塔社区 \(ref.org)/\(ref.name)；许可：\(lic)。"
        desc += NativeModelScopeInstaller.complianceNotice
        let files: [JSONValue] = variant.files.map { f in
            .object([
                "path": .string(f.path),
                "size_bytes": .int(f.sizeBytes),
                "sha256": .string(f.sha256.lowercased()),
            ])
        }
        return [
            "pack_id": .string(pid),
            "name": .string("\(ref.name) · \(variant.title)"),
            "description": .string(desc),
            "version": .string("1.0.0"),
            "task": .string("chat"),
            "format": .string(format),
            "driver": .string(driver),
            "size_bytes": .int(variant.totalBytes),
            "license": .string(lic),
            "source": .string(ref.pageURL),
            "files": .array(files),
        ]
    }
}

// ════════════════════════════════════════════════════════════
// MARK: - MLX 仓落盘完整性校验（0.7.7 W3）
// ════════════════════════════════════════════════════════════

/// 下载完成后、登记前的 MLX 仓结构校验（魔塔 MLX Community 典型平铺目录）：
///   ① config.json 在盘且可解析为 JSON 对象、含非空 model_type；
///   ② 档位清单至少一件 .safetensors 权重且逐件在盘（下载器已逐件 SHA256
///     核验，此处验「落位存在」纵深防御）；
///   ③ 带 model.safetensors.index.json 的分片仓——weight_map 引用的每个
///     分片必须在盘（缺一即不完整；分片路径经 M4 同款消毒，拒路径穿越）。
/// 不过 → NativeModelScopeError.incompleteMLX（install catch 复用 W12 半成品
/// 清退：无 manifest 无登记，完成文件挪 .partial 续传区，不留半成品）。
/// 边界声明：本校验只验「仓完整」，不验「能不能跑」——架构是否在
/// mlx-swift-lm 支持表由装载侧（NativeMPMLXDriver）把关，诚实报「该模型
/// 暂不支持」。
public enum ModelScopeMLXValidator {

    public static func validate(dir: URL, files: [ModelScopeRepoFile]) throws {
        let fm = FileManager.default
        // ① config.json
        let cfgURL = dir.appendingPathComponent("config.json")
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: cfgURL.path, isDirectory: &isDir), !isDir.boolValue else {
            throw NativeModelScopeError.incompleteMLX("缺 config.json")
        }
        guard let data = try? Data(contentsOf: cfgURL),
              case .object(let cfg)? = NativeJSONWriter.loads(data) else {
            throw NativeModelScopeError.incompleteMLX("config.json 不是合法 JSON")
        }
        guard let mt = cfg["model_type"]?.string, !mt.isEmpty else {
            throw NativeModelScopeError.incompleteMLX("config.json 未声明 model_type")
        }
        // ② 权重逐件在盘
        let tensors = files.filter { $0.path.lowercased().hasSuffix(".safetensors") }
        guard !tensors.isEmpty else {
            throw NativeModelScopeError.incompleteMLX("档位清单不含 .safetensors 权重")
        }
        for t in tensors {
            guard ModelScopePathSanitizer.containedURL(base: dir, relativePath: t.path) != nil
            else { throw NativeModelScopeError.unsafePath(t.path) }
            guard fm.fileExists(atPath: dir.appendingPathComponent(t.path).path) else {
                throw NativeModelScopeError.incompleteMLX("权重文件未落位：\(t.path)")
            }
        }
        // ③ 分片索引核验（分片仓缺索引内任何一件 = 载不动）
        let indexRel = "model.safetensors.index.json"
        guard files.contains(where: { $0.path == indexRel }) else { return }
        let indexURL = dir.appendingPathComponent(indexRel)
        guard let idata = try? Data(contentsOf: indexURL),
              case .object(let idx)? = NativeJSONWriter.loads(idata),
              case .object(let weightMap)? = idx["weight_map"] else {
            throw NativeModelScopeError.incompleteMLX(
                "model.safetensors.index.json 不可解析（缺 weight_map）")
        }
        var shards = Set<String>()
        for (_, v) in weightMap {
            if case .string(let s) = v { shards.insert(s) }
        }
        guard !shards.isEmpty else {
            throw NativeModelScopeError.incompleteMLX(
                "model.safetensors.index.json 的 weight_map 为空")
        }
        for shard in shards {
            guard let dest = ModelScopePathSanitizer.containedURL(base: dir,
                                                                  relativePath: shard)
            else { throw NativeModelScopeError.unsafePath(shard) }
            guard fm.fileExists(atPath: dest.path) else {
                throw NativeModelScopeError.incompleteMLX(
                    "分片权重未落位：\(shard)（model.safetensors.index.json 引用）")
            }
        }
    }
}


// ════════════════════════════════════════════════════════════
// MARK: - 安装编排（拉列表 → 下载 → 落位登记；网络全走注入缝）
// ════════════════════════════════════════════════════════════

/// 仓库快照（解析+拉取后的展示/选择数据）
public struct ModelScopeRepoSnapshot: Equatable, Sendable {
    public let ref: ModelScopeRepoRef
    public let license: String
    public let variants: [ModelScopeVariant]
}

public final class NativeModelScopeInstaller: @unchecked Sendable {

    /// 合规提示文案（REQ-FUT-021 红线，安装界面逐字展示）
    public static let complianceNotice = "许可由模型作者定义，商用前请自查。"

    public let store: NativeModelPackStore
    /// GET 注入缝（生产 = URLSession；测试 = 桩，绝不触网）。返回（状态码，响应体）。
    public var fetchData: @Sendable (String) async throws -> (status: Int, data: Data)
    /// 失败明细落盘（0.7.7 W4）：默认全局单例；测试注入独立 logDirectory 实例。
    public var logger: AppLogger = .shared
    /// 下载器工厂缝（生产 = 真实 NativeModelDownloader；测试可注入 file:// 源短路）。
    public var makeDownloader: @Sendable (@escaping @Sendable (DownloadProgress) -> Void)
        -> NativeModelDownloader
    /// 直链组装缝（生产 = 官方 resolve URL；测试重写为 file:// 本地源，不触网）。
    public var resolveURLForFile: @Sendable (ModelScopeRepoRef, String) -> String = {
        ModelScopeAPI.resolveURL($0, path: $1)
    }

    public init(store: NativeModelPackStore) {
        self.store = store
        self.fetchData = { url in
            guard let u = URL(string: url) else { throw URLError(.badURL) }
            var req = URLRequest(url: u)
            req.timeoutInterval = 30
            let (data, resp) = try await URLSession.shared.data(for: req)
            return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
        }
        self.makeDownloader = { onProgress in
            NativeModelDownloader(onProgress: onProgress)
        }
    }

    /// 解析输入并拉取仓库快照（文件列表 + license 并联；格式识别不过抛 unsupportedFormat）
    public func resolve(_ input: String) async throws -> ModelScopeRepoSnapshot {
        guard let ref = ModelScopeLinkParser.parse(input) else {
            throw NativeModelScopeError.unparseableInput
        }
        // 文件列表（硬依赖）与 license（软依赖，挂了不拖死链路）并联
        async let filesReq = fetch(ModelScopeAPI.filesURL(ref))
        async let lic = licenseOf(ref)
        let files = try await filesReq
        let license = await lic
        let variants = try ModelScopeFormatDetector.detectVariants(files: files)
        return ModelScopeRepoSnapshot(ref: ref, license: license, variants: variants)
    }

    private func fetch(_ url: String) async throws -> [ModelScopeRepoFile] {
        let (status, data) = try await fetchData(url)
        guard status == 200 else { throw NativeModelScopeError.httpStatus(status) }
        return try ModelScopeAPI.decodeFiles(data)
    }

    private func fetchRaw(_ url: String) async throws -> Data {
        let (status, data) = try await fetchData(url)
        guard status == 200 else { throw NativeModelScopeError.httpStatus(status) }
        return data
    }

    /// 下载选定档位 → 落模型包目录 + manifest.json + 登记 registry。
    /// 取消抛 CancellationError（.partial 保留续传）；失败/取消均不留「无 manifest
    /// 无登记」的半成品完成文件——W12（L7）：catch 里把已落位完成文件挪入
    /// .partial 续传区（retractUnmanifestedDest），重试经下载器快速路径②
    /// （.part 恰好完整 → 补校验+rename 落位）自愈，自愈能力不丢。
    @discardableResult
    public func install(snapshot: ModelScopeRepoSnapshot, variantId: String,
                        onProgress: @escaping @Sendable (DownloadProgress) -> Void = { _ in })
        async throws -> String {
        guard let variant = snapshot.variants.first(where: { $0.id == variantId }) else {
            throw NativeModelScopeError.apiError("档位不存在：\(variantId)")
        }
        let manifest = ModelScopeManifestBuilder.packManifest(
            ref: snapshot.ref, variant: variant, license: snapshot.license)
        let pid = ModelScopeManifestBuilder.packId(ref: snapshot.ref, variant: variant)
        // 清单经直链缝组装（测试重写 file:// 本地源；口径与静态 builder 一致）
        let specs = variant.files.map { f in
            RequiredFileSpec(path: f.path, sizeBytes: f.sizeBytes,
                             sha256: f.sha256.lowercased(),
                             sources: [resolveURLForFile(snapshot.ref, f.path)])
        }
        let destDir = try store.packDir(pid)
        let partDir = try store.partialDir(pid)
        // M4 纵深防御：落盘前逐文件校验规范化落点仍在目标目录内
        // （decodeFiles 已消毒；此处防「快照绕过 decode 直喂 install」路径）
        for f in variant.files {
            guard ModelScopePathSanitizer.containedURL(base: destDir, relativePath: f.path) != nil,
                  ModelScopePathSanitizer.containedURL(base: partDir,
                                                       relativePath: f.path + ".part") != nil
            else { throw NativeModelScopeError.unsafePath(f.path) }
        }
        let downloader = makeDownloader(onProgress)
        let fm = FileManager.default
        logger.info("魔塔安装开始：\(snapshot.ref.org)/\(snapshot.ref.name)"
            + " · \(variant.title)（\(pid)，\(variant.files.count) 个文件 / \(variant.totalBytes) 字节）")
        let t0 = Date()
        do {
            // Range 续传/低速换源/SHA256/原子落位全部复用 W2 下载器
            try await downloader.downloadFiles(specs, destDir: destDir, partDir: partDir)
            // 0.7.7 W3：MLX 仓落盘完整性校验（config.json + 权重 + 分片索引；
            // 不过抛 incompleteMLX——下方 catch 复用 W12 半成品清退，不留
            // 「无 manifest 无登记」的完成文件）
            if variant.format == .mlx {
                try ModelScopeMLXValidator.validate(dir: destDir, files: variant.files)
            }
            // manifest.json 副本（tmp+rename 原子写，与 NativeModelPackDownloader 同款）
            let manTmp = partDir.appendingPathComponent("manifest.json.tmp")
            try NativeJSONWriter.dumps(.object(manifest)).write(
                to: manTmp, atomically: false, encoding: .utf8)
            if rename(manTmp.path, destDir.appendingPathComponent("manifest.json").path) != 0 {
                throw NativePackDownloadError("原子替换失败: \(String(cString: strerror(errno)))")
            }
            try store.registerPack(pid, pack: manifest)
        } catch {
            // W12（L7，0.7.5 收口审查）：下载/落 manifest/登记任一环失败（含取消），
            // 已完成文件若留 destDir 而无 manifest 无登记 → 列表不见却占盘 GB 级。
            // 挪入 .partial 清回（安全口径见函数注释）；manifest 已落位的
            // registerPack 失败边角不动（重试走快速路径①现场更优）。
            Self.retractUnmanifestedDest(destDir: destDir, partDir: partDir, specs: specs)
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                logger.info("魔塔安装已取消（半成品清退回 .partial 续传区）：\(pid)")
            } else {
                logger.error("魔塔安装失败：\(pid) —— "
                    + NativeModelDownloader.logSafeDetail(error.localizedDescription)
                    + "（半成品清退：无 manifest 的完成文件已挪回 .partial 续传区）")
            }
            throw error
        }
        // 空暂存目录顺手清掉（有半截残留则保留——下次同档安装续传）。
        // W12：先清落位 rename 留下的空目录骨架（嵌套路径文件在 .partial 内
        // 同样产生骨架），否则嵌套仓成功安装后 .partial 恒残留。
        Self.pruneEmptyDirectorySkeletons(under: partDir)
        if let contents = try? fm.contentsOfDirectory(atPath: partDir.path), contents.isEmpty {
            try? fm.removeItem(at: partDir)
        }
        logger.info("魔塔安装完成：\(pid)（\(variant.totalBytes) 字节，"
            + String(format: "耗时 %.1fs", Date().timeIntervalSince(t0)) + "）")
        return pid
    }

    /// 清 root 下的空目录骨架（深的先删——子目录空壳清了父目录才可能变空壳；
    /// root 本身不动）。excludingSubtree 子树整体跳过（续传区内容不碰）。
    /// 非空目录 removeItem 抛错由 try? 跳过——只真空壳被清。
    static func pruneEmptyDirectorySkeletons(under root: URL, excludingSubtree: URL? = nil) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        else { return }
        var dirs: [URL] = []
        for case let u as URL in enumerator {
            guard (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            dirs.append(u)
        }
        let excluded = excludingSubtree?.standardizedFileURL.path
        for d in dirs.sorted(by: { $0.path.count > $1.path.count }) {
            if let excluded {
                let p = d.standardizedFileURL.path
                if p == excluded || p.hasPrefix(excluded + "/") { continue }
            }
            try? fm.removeItem(at: d)
        }
    }

    /// W12（L7）半成品清理：把「无 manifest.json 的 destDir」里已落位的完成文件
    /// 改名挪入 .partial 续传区（同卷 rename，GB 级瞬时）——
    ///   · 磁盘占用从「隐形完成文件」归位到「可续传现场」（与下载器取消/中断后的
    ///     既有 .partial 现场同形态，注册表未登记的 pid 目录只剩续传区）；
    ///   · 重试经下载器快速路径②（.part 恰好完整 → 补校验+rename 落位）自愈——
    ///     与快速路径①（dest 已在且哈希对）等效，「重装同档经 sha 比对自愈」不丢；
    ///   · manifest.json 已落位（registerPack 失败边角）→ 整体不动：重试走
    ///     快速路径① + 重写 manifest + 补登记，现场保留更优。
    /// 全部 try? 兜底：清理失败不遮蔽原始错误（原错照常上抛）。
    static func retractUnmanifestedDest(destDir: URL, partDir: URL, specs: [RequiredFileSpec]) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destDir.appendingPathComponent("manifest.json").path)
        else { return }
        for spec in specs {
            let dest = destDir.appendingPathComponent(spec.path)
            guard fm.fileExists(atPath: dest.path) else { continue }
            let part = partDir.appendingPathComponent(spec.path + ".part")
            try? fm.createDirectory(at: part.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            // 防御：同名旧 .part 碎片（正常不存在——完成文件落位即 rename 走）
            try? fm.removeItem(at: part)
            try? fm.moveItem(at: dest, to: part)
        }
        // 完成文件挪走后清空目录骨架（.partial 续传区及其内容整体排除不碰）
        Self.pruneEmptyDirectorySkeletons(under: destDir, excludingSubtree: partDir)
    }

    /// license 拉取容错封装（resolve 内部用；信息端点挂不拖死文件列表链路）
    func licenseOf(_ ref: ModelScopeRepoRef) async -> String {
        (try? await fetchRaw(ModelScopeAPI.infoURL(ref)))
            .map(ModelScopeAPI.decodeLicense) ?? ""
    }
}
