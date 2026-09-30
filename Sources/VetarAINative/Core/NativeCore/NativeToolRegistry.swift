//
//  NativeToolRegistry.swift
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

//  逐行为移植 subagent/sidecar/tools/registry.py（⛔ 只读行为规格源，556 行）：
//    · TOOLS 注册表（10 工具 params/return_schema 逐字段；create_document 于
//      P2-W3b 点亮——NativeDocWriter/NativeDocReader，见对应文件头注）
//    · execute() 统一入口：web_search / install_* 独立分支 → unknown_tool →
//      路径解析 → 标点笔误硬拦（仅 write/mkdir）→ 敏感判定（delete/write/mkdir）
//      → 越界 advisory（方案 B 放行+提示）→ 执行 → schema 校验（错误结果不校验）
//    · NoopAuthorizer 语义：无真实授权器时敏感操作一律拒绝（安全优先）；
//      工作流引擎场景 authorizer=nil → 对齐 Python execute(..., None) 拒绝文案
//    · _exec_on_path 六工具：list_dir / read_file / write_file / create_dir /
//      create_document / delete_path（含 1MB 截断、200KB 大文本软提示、图片 base64
//      分支、doc_reader 解析通道「📄 已解析」头部与预算共用口径）
//
//  偏差（汇报清单同步）：
//    ① OSError 文案取 POSIX strerror 等价（NSError 桥接），Python e.strerror 同口径。
//    ② doc_reader 解析的 PDF 引擎为 PDFKit（pypdf 细节差异见 NativeDocReader 头注）。
//

import Foundation

// MARK: - Python ValueError 等价（execute 捕获后文案逐字回传）

struct NativeToolValueError: Error {
    let message: String
}

// MARK: - RETURN_SCHEMA 声明（registry.py L125-160 移植；types 保插入序）

public enum NativePySchemaType: Sendable {
    case bool, int, str, list
}

public struct NativeReturnSchema: Sendable {
    public var required: [String] = []
    /// 保 Python dict 插入序（schema_violation 文案拼接顺序可比）。
    public var types: [(String, NativePySchemaType)] = []
    public var entryKeys: Set<String>? = nil
    /// TS-104：条目字段名（默认 entries；web_search 用 results）。
    public var entryField: String = "entries"

    public init(required: [String], types: [(String, NativePySchemaType)],
                entryKeys: Set<String>? = nil, entryField: String = "entries") {
        self.required = required
        self.types = types
        self.entryKeys = entryKeys
        self.entryField = entryField
    }
}

// MARK: - 工具声明（registry.py TOOLS L162-209 逐字段）

public struct NativeToolSpec: Sendable {
    /// params 保插入序（展示用；值为 Python 原文案）。
    public let params: [(String, String)]
    public let returnSchema: NativeReturnSchema
}

// MARK: - 授权器（NoopAuthorizer L212-220 + 联网安装四参形态 L315-321）

/// Python authorizer 回调双形态：
/// ① 敏感路径确认 authorizer(tool, path, action) -> bool
/// ② 联网安装确认 authorizer(tool, src, "net_install", extra) -> dict|bool
public protocol NativeToolAuthorizer: Sendable {
    /// 敏感删除/写入/建目录确认。false → denied_by_user。
    func authorize(tool: String, path: String, action: String) async -> Bool
    /// 联网安装确认（0.4.9 任务152）。dict 形态归一化为（allowed, enableNetwork）。
    func authorizeNetInstall(tool: String, source: String,
                             extra: [String: JSONValue]) async -> (allowed: Bool, enableNetwork: Bool)
}

/// NoopAuthorizer：无真实授权器时的默认语义——敏感操作一律拒绝（安全优先）。
public struct NativeNoopAuthorizer: NativeToolAuthorizer {
    public init() {}
    public func authorize(tool: String, path: String, action: String) async -> Bool { false }
    public func authorizeNetInstall(tool: String, source: String,
                                    extra: [String: JSONValue]) async -> (allowed: Bool, enableNetwork: Bool) {
        (false, false)
    }
}

/// 闭包授权器（测试/面板注入用）。
public struct NativeCallbackAuthorizer: NativeToolAuthorizer {
    private let onAuthorize: @Sendable (String, String, String) async -> Bool
    private let onNetInstall: @Sendable (String, String, [String: JSONValue]) async -> (allowed: Bool, enableNetwork: Bool)
    public init(onAuthorize: @escaping @Sendable (String, String, String) async -> Bool,
                onNetInstall: @escaping @Sendable (String, String, [String: JSONValue]) async -> (allowed: Bool, enableNetwork: Bool) = { _, _, _ in (false, false) }) {
        self.onAuthorize = onAuthorize
        self.onNetInstall = onNetInstall
    }
    public func authorize(tool: String, path: String, action: String) async -> Bool {
        await onAuthorize(tool, path, action)
    }
    public func authorizeNetInstall(tool: String, source: String,
                                    extra: [String: JSONValue]) async -> (allowed: Bool, enableNetwork: Bool) {
        await onNetInstall(tool, source, extra)
    }
}

// MARK: - 工具上下文（Python 侧车全局态的注入等价物）

public struct NativeToolContext: Sendable {
    /// get_config() 延迟读（设置面板改配置即时生效，对齐 Python 函数内延迟导入）。
    public var config: @Sendable () -> [String: JSONValue]
    /// reload_config(patch)（enable_network / 熔断写名单用）。
    public var reloadConfig: @Sendable ([String: JSONValue]) throws -> [String: JSONValue]
    /// plugins_root()（data_root/plugins，mkdir -p 副作用对齐）。
    public var pluginsRoot: @Sendable () throws -> URL
    /// skills_root()（data_root/skills，mkdir -p 副作用对齐 manager.py L36-40）。
    public var skillsRoot: @Sendable () throws -> URL
    /// 出站守卫（熔断器进程级，对齐 guard.py 模块全局 _circuit）。
    public var networkGuard: NativeNetworkGuard
    /// HTTP 传输层（web_search；生产 URLSession，测试注入假传输）。
    public var transport: any NativeHTTPTransport
    /// git clone 执行器（install_*；生产 /usr/bin/git 子进程，测试注入假 runner）。
    public var gitRunner: NativeGitRunner
    /// is_sensitive_path 判定（测试注入伪造敏感区，对齐 Python monkeypatch 用例）。
    public var isSensitive: @Sendable (String) -> Bool

    public init(config: @escaping @Sendable () -> [String: JSONValue],
                reloadConfig: @escaping @Sendable ([String: JSONValue]) throws -> [String: JSONValue],
                pluginsRoot: @escaping @Sendable () throws -> URL,
                skillsRoot: @escaping @Sendable () throws -> URL,
                networkGuard: NativeNetworkGuard,
                transport: any NativeHTTPTransport,
                gitRunner: NativeGitRunner,
                isSensitive: @escaping @Sendable (String) -> Bool = { NativeToolSandbox.isSensitivePath($0) }) {
        self.config = config
        self.reloadConfig = reloadConfig
        self.pluginsRoot = pluginsRoot
        self.skillsRoot = skillsRoot
        self.networkGuard = networkGuard
        self.transport = transport
        self.gitRunner = gitRunner
        self.isSensitive = isSensitive
    }

    /// 生产装配（内核注入）：配置经 NativeConfigStore 解析链（env > config.json > 默认）。
    public static func live(config store: NativeConfigStore, guard networkGuard: NativeNetworkGuard) -> NativeToolContext {
        NativeToolContext(
            config: { (try? store.getConfig()) ?? NativeConfigStore.defaultConfig },
            reloadConfig: { try store.reloadConfig(patch: $0) },
            pluginsRoot: { store.pluginsRoot() },
            skillsRoot: {
                let url = store.dataRoot().appendingPathComponent("skills")
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                return url
            },
            networkGuard: networkGuard,
            transport: URLSessionHTTPTransport(),
            gitRunner: .system)
    }
}

// MARK: - 注册表与统一入口

public enum NativeToolRegistry {

    public static let maxReadBytes = 1 * 1024 * 1024        // MAX_READ_BYTES（协议常量）
    public static let largeTextAdvisoryBytes = 200 * 1024   // LARGE_TEXT_ADVISORY_BYTES（B2 0.4.8）

    /// IMAGE_EXTS（checkpoint-067 R-4）：图片不读字节成乱码，改返回 base64 标记。
    public static let imageExts: Set<String> = [".png", ".jpg", ".jpeg", ".gif", ".webp",
                                                ".bmp", ".heic", ".heif", ".tiff", ".svg"]

    /// doc_reader.is_parseable 的扩展名集（DOC_EXTS ∪ LEGACY_EXTS）——
    /// read_file 命中后走 NativeDocReader 解析通道（P2-W3b 点亮）。
    public static let docParseableExts: Set<String> = [".docx", ".xlsx", ".xlsm", ".pptx", ".pdf",
                                                       ".doc", ".xls", ".ppt"]

    public static let listDirReturn = NativeReturnSchema(
        required: ["ok", "entries"],
        types: [("ok", .bool), ("entries", .list)],
        entryKeys: ["name", "type", "size"])
    public static let readFileReturn = NativeReturnSchema(
        required: ["ok", "content", "size"],
        types: [("ok", .bool), ("content", .str), ("size", .int)])
    public static let writeFileReturn = NativeReturnSchema(
        required: ["ok", "path", "bytes"],
        types: [("ok", .bool), ("path", .str), ("bytes", .int)])
    public static let createDirReturn = NativeReturnSchema(
        required: ["ok", "path"],
        types: [("ok", .bool), ("path", .str)])
    public static let createDocReturn = NativeReturnSchema(
        required: ["ok", "path", "bytes"],
        types: [("ok", .bool), ("path", .str), ("bytes", .int)])
    public static let deletePathReturn = NativeReturnSchema(
        required: ["ok", "path"],
        types: [("ok", .bool), ("path", .str)])
    public static let installPluginReturn = NativeReturnSchema(
        required: ["ok", "name"],
        types: [("ok", .bool), ("name", .str)])
    public static let installSkillReturn = NativeReturnSchema(
        required: ["ok", "name"],
        types: [("ok", .bool), ("name", .str)])

    /// TOOLS（注册表全量 10 工具；create_document 于 P2-W3b 点亮）。
    public static let tools: [String: NativeToolSpec] = [
        "list_dir": NativeToolSpec(
            params: [("path", "str (optional, 默认 working_dir)")],
            returnSchema: listDirReturn),
        "read_file": NativeToolSpec(
            params: [("path", "str")],
            returnSchema: readFileReturn),
        "write_file": NativeToolSpec(
            params: [("path", "str"), ("content", "str")],
            returnSchema: writeFileReturn),
        "create_dir": NativeToolSpec(
            params: [("path", "str")],
            returnSchema: createDirReturn),
        "create_document": NativeToolSpec(
            params: [
                ("path", "str（保存路径，扩展名决定类型 .docx/.xlsx/.pptx/.md）"),
                ("doc_type", "str（docx/xlsx/pptx/md，可选，默认从扩展名推断）"),
                ("content", "dict（结构化内容，契约见 doc_writer：blocks/sheets/slides）"),
                ("reference_path", "str（可选，参考 .docx 绝对路径；给了就按它的字体/字号/对齐/首行缩进/行距/页面边距生成，仅 docx 生效——#14）"),
            ],
            returnSchema: createDocReturn),
        "delete_path": NativeToolSpec(
            params: [("path", "str")],
            returnSchema: deletePathReturn),
        "web_search": NativeToolSpec(
            params: [("query", "str (required)"), ("max_results", "int (optional, 默认5 上限10)")],
            returnSchema: NativeWebSearch.returnSchema),
        "install_plugin": NativeToolSpec(
            params: [("source", "str (required，GitHub 仓库 URL 或本地插件目录绝对路径)")],
            returnSchema: installPluginReturn),
        "install_skill": NativeToolSpec(
            params: [("source", "str (required，git 仓库 URL 或含 SKILL.md 的本地目录绝对路径)")],
            returnSchema: installSkillReturn),
    ]

    /// _TOOL_NAMES（存在性判定）。
    public static let toolNames: Set<String> = Set(tools.keys)

    /// _ACTION（工具 → 动作类型；敏感判定：delete/write/mkdir 需确认）。
    public static let action: [String: String] = [
        "list_dir": "list", "read_file": "read", "write_file": "write",
        "create_dir": "mkdir", "delete_path": "delete", "create_document": "write",
    ]

    // MARK: - _validate（registry.py L233-249 移植）

    public static func validate(_ result: [String: JSONValue], schema: NativeReturnSchema) -> [String] {
        var problems: [String] = []
        for key in schema.required where result[key] == nil {
            problems.append("missing:\(key)")
        }
        for (key, typ) in schema.types {
            guard let v = result[key] else { continue }
            let ok: Bool
            switch (typ, v) {
            case (.bool, .bool): ok = true
            case (.int, .int), (.int, .bool): ok = true   // isinstance(True, int)==True
            case (.str, .string): ok = true
            case (.list, .array): ok = true
            default: ok = false
            }
            if !ok { problems.append("bad_type:\(key)") }
        }
        if let ek = schema.entryKeys, case .array(let arr)? = result[schema.entryField] {
            for e in arr {
                guard case .object(let o) = e, ek.isSubset(of: o.keys) else {
                    problems.append("bad_entry")
                    break
                }
            }
        }
        return problems
    }

    // MARK: - execute（registry.py L253-435 统一入口移植）

    public static func execute(_ toolName: String,
                               args: [String: JSONValue]?,
                               sandboxRoot: String,
                               authorizer: (any NativeToolAuthorizer)?,
                               context: NativeToolContext) async -> [String: JSONValue] {
        let args = args ?? [:]

        // TS-104 R01：网络工具独立分支（出站 100% 过 guard，见 NativeWebSearch）
        if toolName == "web_search" {
            let result: [String: JSONValue]
            do {
                result = try await NativeWebSearch.search(args: args, context: context)
            } catch let e as NativeNetworkGuardError {
                return err("network_guard_denied: \(e.message)")
            } catch {
                return err("search_failed: \(error.localizedDescription)")
            }
            // 错误结果直接返回（不走 schema 校验，避免覆盖原始错误）
            guard result["ok"] == .bool(true) else { return result }
            let problems = validate(result, schema: NativeWebSearch.returnSchema)
            if !problems.isEmpty {
                return err("schema_violation: \(problems.joined(separator: ", "))")
            }
            return result
        }

        // checkpoint-066：对话内安装插件/技能
        if toolName == "install_plugin" || toolName == "install_skill" {
            return await executeInstall(toolName, args: args, authorizer: authorizer, context: context)
        }

        guard toolNames.contains(toolName) else {
            return err("unknown_tool: \(toolName)")
        }

        let root = NativePyPath.resolve(sandboxRoot)
        let toolAction = action[toolName] ?? ""

        // 解析目标路径（相对基于工作目录；绝对原样；符号链接跟随；双前缀自纠正）
        let relRaw = args["path"]
        let resolved: String
        if relRaw == nil || relRaw == .null {
            if toolName == "list_dir" {
                resolved = root
            } else {
                return err("bad_arg: path")
            }
        } else {
            guard let rel = relRaw?.string, !rel.isEmpty else {
                return err("bad_arg: path")
            }
            guard let r = NativeToolSandbox.resolveSandboxedPath(rel, sandboxRoot: sandboxRoot) else {
                return err("bad_path: \(rel)")
            }
            resolved = r
        }

        // 0.4.11（第六十四章）：路径标点笔误硬拦——仅对【创建类】动作。
        // 只拦"带标点的祖先目录不存在"的幽灵路径；不静默改写，只拒绝+建议。
        var oobAdvisory = ""
        if toolAction == "write" || toolAction == "mkdir" {
            if let suggestion = NativeToolSandbox.punctuationNearMiss(resolved: resolved,
                                                                      sandboxRoot: sandboxRoot) {
                return err("path_typo_rejected: 目标路径与当前项目工作目录【仅差标点符号】，"
                    + "疑似路径笔误，已拒绝创建（否则会凭空多出一个目录，并导致后续步骤连锁失败）。\n"
                    + "  你给的：\(resolved)\n"
                    + "  应为：  \(suggestion)\n"
                    + "⛔ 路径中的项目目录名必须【原样】使用，禁止增删任何标点（句号/顿号/引号/空格等）。\n"
                    + "请改用上面的正确路径重试。")
            }
        }

        // 敏感判定（2026-08-29 方案 B）：仅【系统敏感位置】的 删除/写入/建目录 需确认；
        // 非敏感越界放行；读取任何位置都不拦截。无 authorizer → 敏感操作拒绝（不静默执行）。
        let needsConfirm = ["delete", "write", "mkdir"].contains(toolAction)
        if needsConfirm && context.isSensitive(resolved) {
            guard let authorizer else {
                let actionCN = ["delete": "删除", "write": "写入", "mkdir": "建目录"][toolAction] ?? toolAction
                return err("denied: 敏感路径\(actionCN)需用户确认（当前无授权通道）: \(resolved)")
            }
            let allowed = await authorizer.authorize(tool: toolName, path: resolved, action: toolAction)
            if !allowed {
                return err("denied_by_user")
            }
        } else if toolAction == "write" || toolAction == "mkdir" {
            // 0.4.11：越界【提示】而非拦截——成功后附 advisory，给模型"被提醒的机会"。
            if !NativePyPath.isWithin(resolved, root: root) {
                oobAdvisory = "⚠️ 该路径在项目工作目录之外（工作目录：\(root)）。"
                    + "若本意是操作本项目文件，请改用工作目录内的相对路径；"
                    + "若确需写到外部位置，可忽略本提示。"
            }
        }

        // 执行（路径校验已在上面完成）
        let result: [String: JSONValue]
        do {
            result = try execOnPath(toolName, args: args, target: resolved, root: root)
        } catch let e as NativeToolValueError {
            return err(e.message)
        } catch {
            // T1（0.4.8）：非预期异常也把真实原因回传（类型名+消息）
            return err("\(String(describing: type(of: error))): \(error.localizedDescription)")
        }
        // T1（0.4.8）：错误结果直接返回，不走 schema 校验（真实错误原因不被覆盖）。
        guard result["ok"] == .bool(true) else { return result }
        let problems = validate(result, schema: tools[toolName]!.returnSchema)
        if !problems.isEmpty {
            return err("schema_violation: \(problems.joined(separator: ", "))")
        }
        // 0.4.11：越界提示在校验【之后】挂载——避免额外键触发 required 校验失败。
        var final = result
        if !oobAdvisory.isEmpty {
            final["advisory"] = .string(oobAdvisory)
        }
        return final
    }

    static func err(_ message: String) -> [String: JSONValue] {
        ["ok": .bool(false), "error": .string(message)]
    }

    // MARK: - install_plugin / install_skill（registry.py L283-357 移植）

    static func executeInstall(_ toolName: String,
                               args: [String: JSONValue],
                               authorizer: (any NativeToolAuthorizer)?,
                               context: NativeToolContext) async -> [String: JSONValue] {
        let srcRaw = args["source"]?.string ?? ""
        guard !srcRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return err("bad_arg: source（需要 GitHub 仓库 URL 或本地目录绝对路径）")
        }
        let src = srcRaw.trimmingCharacters(in: .whitespacesAndNewlines)

        // 0.4.9 任务152：联网安装必须先询问用户。本地目录安装不弹窗。
        let isRemote = !FileManager.default.fileExists(atPath: NativePyPath.expanduser(src))
            && ["http://", "https://", "git@", "ssh://", "git://"].contains(where: { src.hasPrefix($0) })
        if isRemote {
            let cfg = context.config()
            let confirmInstall: Bool = {
                guard let v = cfg["confirm_network_install"], v != .null else { return true }
                return WFText.truthy(v)
            }()
            if confirmInstall {
                guard let authorizer else {
                    // 无授权通道（如后台任务/测试）→ 不静默联网，直接拒绝
                    return err("network_install_denied: 需要联网下载安装，但当前无用户授权通道，"
                        + "已拒绝执行（不静默联网）。请在会话中让主 Agent 发起，"
                        + "或改用本地目录安装。")
                }
                let curMode = cfg["network_switch"]?.string ?? "auto"
                let kind = toolName == "install_plugin" ? "插件（Plugin）" : "技能（Skill）"
                let extra: [String: JSONValue] = [
                    "kind": .string("net_install"),
                    "source_url": .string(src),
                    "install_type": .string(kind),
                    "current_mode": .string(curMode),
                    // 当前不是全量联网（proxy）→ GitHub 大概率连不上，需一并请求开启
                    "need_enable_network": .bool(curMode != "proxy"),
                ]
                let decision = await authorizer.authorizeNetInstall(tool: toolName, source: src, extra: extra)
                guard decision.allowed else {
                    return err("denied_by_user: 用户拒绝了本次联网安装（来源：\(src)）。"
                        + "不要再重试安装，也不要改换其他来源绕过；"
                        + "请如实告知用户已取消，并询问是否需要改用本地目录安装。")
                }
                // 用户同意 + 勾选"开启全量联网" → 自动切 proxy 模式并清空熔断
                if decision.enableNetwork && curMode != "proxy" {
                    do {
                        _ = try context.reloadConfig(["network_switch": .string("proxy")])
                        context.networkGuard.resetCircuit()
                    } catch {
                        return err("enable_network_failed: 已同意安装，但切换全量联网失败"
                            + "（\(error.localizedDescription)）。"
                            + "请手动在 设置→网络 切为「全量」后重试。")
                    }
                }
            }
        }

        let info: [String: JSONValue]
        do {
            if toolName == "install_plugin" {
                info = try await NativeToolInstall.installPlugin(src, context: context)
            } else {
                let res = try await NativeToolInstall.installSkillFromRepo(src, context: context)
                guard res["ok"] == .bool(true) else {
                    return err("install_failed: \(res["error"]?.string ?? "未知错误")")
                }
                info = ["name": res["name"] ?? .string("")]
            }
        } catch let e as NativeToolValueError {
            return err("install_failed: \(e.message)")
        } catch let e as NativeNetworkGuardError {
            return err("install_failed: \(e.message)")
        } catch let e as NativeGitError {
            return err("install_failed: \(e.pyDescription)")
        } catch {
            return err("install_failed: \(error.localizedDescription)")
        }
        let result: [String: JSONValue] = ["ok": .bool(true), "name": info["name"] ?? .string("")]
        // 0.4.9 T1：成功路径才走 schema 校验（错误路径已在上方直接返回）
        let problems = validate(result, schema: tools[toolName]!.returnSchema)
        if !problems.isEmpty {
            return err("schema_violation: \(problems.joined(separator: ", "))")
        }
        return result
    }

    // MARK: - _exec_on_path（registry.py L438-556 移植）

    static func execOnPath(_ toolName: String, args: [String: JSONValue],
                           target: String, root: String) throws -> [String: JSONValue] {
        do {
            switch toolName {
            case "list_dir": return try execListDir(args: args, target: target, root: root)
            case "read_file": return try execReadFile(target: target, root: root)
            case "write_file": return try execWriteFile(args: args, target: target)
            case "create_dir": return try execCreateDir(target: target)
            case "create_document": return try execCreateDocument(args: args, target: target)
            case "delete_path": return try execDeletePath(target: target)
            default:
                return err("unknown_tool: \(toolName)")
            }
        } catch let e as NativeToolValueError {
            throw e   // ValueError 由 execute() 捕获后文案逐字回传
        } catch {
            return err("os_error: \(osErrorText(error))")
        }
    }

    /// Python OSError.strerror 等价（NSError → POSIX 桥接）。
    static func osErrorText(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain {
            return String(cString: strerror(Int32(ns.code)))
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain {
            return String(cString: strerror(Int32(underlying.code)))
        }
        return ns.localizedDescription
    }

    /// Python sorted(key=str)（码点序）。
    static func pySorted(_ items: [String]) -> [String] {
        items.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
    }

    /// Path.suffix 小写（无点/点前无名 → ""）。
    static func pySuffixLower(_ path: String) -> String {
        let name = NativePyPath.name(path)
        guard let dot = name.lastIndex(of: "."), dot > name.startIndex else { return "" }
        return String(name[dot...]).lowercased()
    }

    // ---- list_dir ----

    static func execListDir(args: [String: JSONValue], target: String,
                            root: String) throws -> [String: JSONValue] {
        let fm = FileManager.default
        var isDir = ObjCBool(false)
        let exists = fm.fileExists(atPath: target, isDirectory: &isDir)
        guard exists && isDir.boolValue else {
            let origPath = args["path"]?.string ?? ""
            if fm.fileExists(atPath: target) {
                throw NativeToolValueError(message:
                    "not_a_dir: \(origPath)（该路径是【文件】不是目录；"
                    + "请用 read_file 读取: \(target)）")
            }
            throw NativeToolValueError(message:
                "not_a_dir: \(origPath)（解析后: \(target)，该目录尚不存在"
                + "——可能还未创建；如需创建请用 create_dir/mkdir，或先 list_dir 其父目录确认结构；"
                + "沙盒根: \(root)）")
        }
        let names = try fm.contentsOfDirectory(atPath: target)
        var entries: [JSONValue] = []
        for name in pySorted(names) {
            let p = (target as NSString).appendingPathComponent(name)
            var ftype = "file"
            var size = 0
            do {
                let attrs = try fm.attributesOfItem(atPath: p)
                let isSymlink = (attrs[.type] as? FileAttributeType) == .typeSymbolicLink
                var dirFlag = ObjCBool(false)
                let reachable = fm.fileExists(atPath: p, isDirectory: &dirFlag)
                if isSymlink { ftype = "symlink" }
                else if dirFlag.boolValue { ftype = "dir" }
                // p.stat() 跟随符号链接（is_file 同理）
                if reachable && !dirFlag.boolValue {
                    let real = (p as NSString).resolvingSymlinksInPath
                    size = Int((try fm.attributesOfItem(atPath: real)[.size] as? Int64) ?? 0)
                }
            } catch {
                ftype = "file"; size = 0   // OSError → ("file", 0)
            }
            entries.append(.object([
                "name": .string(name), "type": .string(ftype), "size": .int(Int64(size)),
            ]))
        }
        return ["ok": .bool(true), "entries": .array(entries)]
    }

    // ---- read_file ----

    static func execReadFile(target: String, root: String) throws -> [String: JSONValue] {
        let fm = FileManager.default
        var isDir = ObjCBool(false)
        guard fm.fileExists(atPath: target, isDirectory: &isDir), !isDir.boolValue else {
            throw NativeToolValueError(message:
                "not_a_file: \(NativePyPath.name(target))（解析后: \(target)，文件不存在；沙盒根: \(root)。"
                + "请先 list_dir 确认目录内容，或使用绝对路径）")
        }
        let attrs = try fm.attributesOfItem(atPath: target)
        let size = Int((attrs[.size] as? Int64) ?? 0)
        let suffix = pySuffixLower(target)

        // checkpoint-067 R-4：图片 → base64 + 图片标记（多模态模型读图而非乱码）
        if imageExts.contains(suffix) {
            let data = try Data(contentsOf: URL(fileURLWithPath: target))
            return [
                "ok": .bool(true),
                "_kind": .string("image"),
                "path": .string(target),
                "image_base64": .string(data.base64EncodedString()),
                "size": .int(Int64(size)),
                "content": .string("[图片文件 \(NativePyPath.name(target))，\(size) 字节，已转为图像输入]"),
            ]
        }

        // #4（0.4.19）：doc_reader 解析通道（P2-W3b 原生移植 NativeDocReader）。
        // 头部提示语与正文共用 1MB 预算：先算提示长度，剩余给解析内容，总长仍 ≤1MB。
        if docParseableExts.contains(suffix) {
            let head = "📄 已解析 \(suffix.dropFirst()) 文档"
                + "（\(size) 字节，提取为文本+格式概要）：\n\n"
            let parsed = NativeDocReader.extract(
                path: target, budget: max(0, maxReadBytes - head.utf8.count))
            // ok 一律 True：解析器即便读不出内容（损坏/旧格式无法转换），
            // 也在 content 里给了说明性文字——对模型比 error 更有用。
            return [
                "ok": .bool(true),
                "content": .string(head + parsed.content),
                "size": .int(Int64(size)),
                "truncated": .bool(parsed.truncated ?? false),
            ]
        }

        // B2（0.4.8）：大文本软提示——头部嵌入引导，正文按剩余预算截取（总长仍 ≤1MB）。
        var advisory = ""
        if size > largeTextAdvisoryBytes {
            advisory = "⚠️ 大文件提示：本文件 \(size) 字节（超过 \(largeTextAdvisoryBytes) 字节）。"
                + "全文读入会大量占用上下文并显著拖慢推理。"
                + "如需转写/OCR/摘要，建议委派子 Agent 或走工作流（传【文件路径】而非【文件内容】），"
                + "只回传结果。若确需全文分析再继续使用以下内容。\n\n---\n\n"
        }
        let budget = max(0, maxReadBytes - advisory.utf8.count)
        // Python read_bytes()[:budget]：前缀截取语义；FileHandle 限量读避免整载大文件。
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: target))
        let raw = (try handle.read(upToCount: budget)) ?? Data()
        try handle.close()
        var content = String(decoding: raw, as: UTF8.self)   // decode(errors="replace") 等价
        if !advisory.isEmpty { content = advisory + content }
        return [
            "ok": .bool(true),
            "content": .string(content),
            "size": .int(Int64(size)),
            "truncated": .bool(size > maxReadBytes),
        ]
    }

    // ---- write_file ----

    static func execWriteFile(args: [String: JSONValue], target: String) throws -> [String: JSONValue] {
        guard let content = args["content"]?.string else {
            throw NativeToolValueError(message: "bad_arg: content")
        }
        let data = Data(content.utf8)
        let parent = (target as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: target))
        return ["ok": .bool(true), "path": .string(target), "bytes": .int(Int64(data.count))]
    }

    // ---- create_dir ----

    static func execCreateDir(target: String) throws -> [String: JSONValue] {
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
        return ["ok": .bool(true), "path": .string(target)]
    }

    // ---- create_document（0.4.6；registry.py L528-545 移植，P2-W3b 点亮）----

    static func execCreateDocument(args: [String: JSONValue], target: String) throws -> [String: JSONValue] {
        // 类型默认从扩展名推断（模型可显式覆盖）
        var docType = (args["doc_type"]?.string ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if docType.isEmpty {
            let ext = String(pySuffixLower(target).dropFirst())
            docType = ["docx": "docx", "xlsx": "xlsx", "pptx": "pptx",
                       "md": "md", "markdown": "md"][ext] ?? ""
        }
        guard case .object(let content) = args["content"] else {
            throw NativeToolValueError(message:
                "bad_arg: content 必须是结构化 JSON 对象"
                + "（docx/md 用 title+blocks；xlsx 用 sheets；pptx 用 slides）")
        }
        let parent = (target as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        // #14：参考文件路径透传（仅 docx 生效，提取失败在 writeDocument 内静默回退）
        var ref: String? = nil
        if let r = args["reference_path"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
           !r.isEmpty {
            ref = r
        }
        let nbytes = try NativeDocWriter.writeDocument(docType: docType, target: target,
                                                       content: content, referencePath: ref)
        return ["ok": .bool(true), "path": .string(target), "bytes": .int(Int64(nbytes))]
    }

    // ---- delete_path ----

    static func execDeletePath(target: String) throws -> [String: JSONValue] {
        guard FileManager.default.fileExists(atPath: target) else {
            throw NativeToolValueError(message: "not_found: \(target)")
        }
        // 目录递归 / 文件单删（removeItem 对目录即 rmtree 语义）
        try FileManager.default.removeItem(atPath: target)
        return ["ok": .bool(true), "path": .string(target)]
    }
}

// MARK: - 工作流 tool 节点执行器（NativeWorkflowToolExecutor 协议实现）

/// 内核装配处注入的具体执行器：工作流 tool 节点 → 注册表 execute()。
/// authorizer 缺省 nil（工作流引擎场景 = Python execute(..., None)：敏感操作拒绝）。
public final class NativeRegistryToolExecutor: NativeWorkflowToolExecutor, @unchecked Sendable {
    public let context: NativeToolContext
    public let authorizer: (any NativeToolAuthorizer)?

    public init(context: NativeToolContext, authorizer: (any NativeToolAuthorizer)? = nil) {
        self.context = context
        self.authorizer = authorizer
    }

    public func executeTool(_ tool: String, args: [String: JSONValue],
                            sandboxRoot: String) async throws -> [String: JSONValue] {
        await NativeToolRegistry.execute(tool, args: args, sandboxRoot: sandboxRoot,
                                         authorizer: authorizer, context: context)
    }
}
